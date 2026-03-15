{-# LANGUAGE DeriveFunctor #-}
{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- |
-- Module      : NovaNet.Net
-- Description : Real UDP socket wrapper and MonadNetwork IO instance
--
-- Provides a concrete UDP networking backend using the network library.
-- Includes a dedicated receive thread that feeds a TQueue, allowing
-- non-blocking recv from the application thread.
module NovaNet.Net
  ( -- * Socket
    UdpSocket,
    openSocket,
    closeSocket,
    socketLocalAddr,

    -- * MonadNetwork instance
    NetT,
    runNetT,
    withNetT,
  )
where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM (TQueue, atomically, newTQueueIO, tryReadTQueue, writeTQueue)
import Control.Exception (IOException, catch, finally)
import Control.Monad (forever)
import Control.Monad.IO.Class (MonadIO (..))
import Control.Monad.Trans.State.Strict (StateT (..), get)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import GHC.Clock (getMonotonicTimeNSec)
import Network.Socket
  ( AddrInfo (..),
    AddrInfoFlag (..),
    SockAddr,
    Socket,
    SocketOption (..),
    SocketType (..),
    addrAddress,
    bind,
    close,
    defaultHints,
    getAddrInfo,
    setSocketOption,
    socket,
  )
import Network.Socket.ByteString (recvFrom, sendTo)
import NovaNet.Class
import NovaNet.Config (maxUdpPacketSize)
import NovaNet.Types (MonoTime (..))

-- ---------------------------------------------------------------------------
-- UDP Socket
-- ---------------------------------------------------------------------------

-- | A UDP socket with its local address.
data UdpSocket = UdpSocket
  { usSocket :: !Socket,
    usLocalAddr :: !SockAddr
  }

-- | Open a UDP socket bound to the given address/port string.
-- Example: openSocket "0.0.0.0" "0" for any available port.
openSocket :: String -> String -> IO UdpSocket
openSocket host port = do
  let hints =
        defaultHints
          { addrFlags = [AI_PASSIVE],
            addrSocketType = Datagram
          }
  addrs <- getAddrInfo (Just hints) (Just host) (Just port)
  case addrs of
    [] -> ioError (userError ("openSocket: no addresses for " ++ host ++ ":" ++ port))
    (addr : _) -> do
      sock <- socket (addrFamily addr) (addrSocketType addr) (addrProtocol addr)
      setSocketOption sock ReuseAddr 1
      bind sock (addrAddress addr)
      pure UdpSocket {usSocket = sock, usLocalAddr = addrAddress addr}

-- | Close the UDP socket.
closeSocket :: UdpSocket -> IO ()
closeSocket = close . usSocket

-- | Get the local address the socket is bound to.
socketLocalAddr :: UdpSocket -> SockAddr
socketLocalAddr = usLocalAddr

-- ---------------------------------------------------------------------------
-- Net state
-- ---------------------------------------------------------------------------

-- | Internal state for the networking monad.
data NetState = NetState
  { nsSocket :: !UdpSocket,
    nsRecvQueue :: !(TQueue (ByteString, SockAddr)),
    nsRecvThread :: !ThreadId
  }

-- ---------------------------------------------------------------------------
-- NetT monad transformer
-- ---------------------------------------------------------------------------

-- | Networking monad transformer that provides 'MonadNetwork' via a
-- real UDP socket.
newtype NetT m a = NetT {unNetT :: StateT NetState m a}
  deriving (Functor, Applicative, Monad, MonadIO)

-- | Run a 'NetT' action with the given socket. Starts a background
-- receive thread that is killed on completion.  Exception-safe: the
-- recv thread is always killed even if the action throws.
runNetT :: UdpSocket -> NetT IO a -> IO a
runNetT sock (NetT action) = do
  q <- newTQueueIO
  tid <- forkIO (recvLoop sock q)
  let ns = NetState sock q tid
  (result, _) <- runStateT action ns `finally` killThread tid
  pure result

-- | Bracket-style: open socket, run action, close socket.
-- Exception-safe: the recv thread and socket are always cleaned up.
withNetT :: String -> String -> (SockAddr -> NetT IO a) -> IO a
withNetT host port action = do
  sock <- openSocket host port
  let localAddr = socketLocalAddr sock
  q <- newTQueueIO
  tid <- forkIO (recvLoop sock q)
  let ns = NetState sock q tid
  (result, _) <-
    runStateT (unNetT (action localAddr)) ns
      `finally` (killThread tid >> closeSocket sock)
  pure result

-- | Background receive loop.
-- Only catches IOExceptions — async exceptions (e.g. ThreadKilled)
-- propagate so that killThread can shut this loop down cleanly.
recvLoop :: UdpSocket -> TQueue (ByteString, SockAddr) -> IO ()
recvLoop sock q = forever $ do
  result <-
    (Just <$> recvFrom (usSocket sock) maxUdpPacketSize)
      `catch` (\(_ :: IOException) -> pure Nothing)
  case result of
    Nothing -> pure ()
    Just (bs, addr)
      | BS.null bs -> pure ()
      | otherwise -> atomically $ writeTQueue q (bs, addr)

-- ---------------------------------------------------------------------------
-- MonadTime instance
-- ---------------------------------------------------------------------------

instance (MonadIO m) => MonadTime (NetT m) where
  getMonoTime = NetT $ do
    ns <- liftIO getMonotonicTimeNSec
    pure (MonoTime (fromIntegral ns))

-- ---------------------------------------------------------------------------
-- MonadNetwork instance
-- ---------------------------------------------------------------------------

instance (MonadIO m) => MonadNetwork (NetT m) where
  netSend addr bs = NetT $ do
    ns <- get
    liftIO $
      (Right () <$ sendTo (usSocket (nsSocket ns)) bs addr)
        `catch` (\(_ :: IOException) -> pure (Left (NetSendFailed (SendErrno 0))))

  netRecv = NetT $ do
    ns <- get
    mPkt <- liftIO $ atomically $ tryReadTQueue (nsRecvQueue ns)
    case mPkt of
      Nothing -> pure (Right Nothing)
      Just (bs, addr) -> pure (Right (Just (bs, addr)))

  netClose = NetT $ do
    ns <- get
    liftIO $ killThread (nsRecvThread ns)
    liftIO $ closeSocket (nsSocket ns)
