module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Word (Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (pokeArray)
import Foreign.Ptr (plusPtr)
import NovaNet.Config
import NovaNet.FFI.Bandwidth (bandwidthBps, bandwidthRecord, newBandwidthTracker)
import NovaNet.FFI.CRC32C (crc32c)
import NovaNet.FFI.Crypto (cryptoNonceSize, decrypt, encrypt)
import NovaNet.FFI.Fragment (fragmentCount)
import NovaNet.FFI.Packet (packetHeaderSize, packetRead, packetWrite)
import NovaNet.FFI.Seq (seqDiff, seqGt)
import NovaNet.Types
import System.Exit (exitFailure)
import Test.QuickCheck (elements, forAll, isSuccess, quickCheckResult)

-- ---------------------------------------------------------------------------
-- Test harness
-- ---------------------------------------------------------------------------

data TestState = TestState {tsRun :: !Int, tsPassed :: !Int}

type T = IORef TestState

newT :: IO T
newT = newIORef (TestState 0 0)

assert :: T -> String -> Bool -> IO ()
assert ref label cond = do
  modifyIORef' ref $ \s -> s {tsRun = tsRun s + 1}
  if cond
    then modifyIORef' ref $ \s -> s {tsPassed = tsPassed s + 1}
    else putStrLn $ "FAIL " ++ label

assertEqual :: (Eq a, Show a) => T -> String -> a -> a -> IO ()
assertEqual ref label expected actual
  | expected == actual =
      modifyIORef' ref $ \s -> s {tsRun = tsRun s + 1, tsPassed = tsPassed s + 1}
  | otherwise = do
      modifyIORef' ref $ \s -> s {tsRun = tsRun s + 1}
      putStrLn $ "FAIL " ++ label ++ ": expected " ++ show expected ++ ", got " ++ show actual

assertElem :: (Eq a, Show a) => T -> String -> a -> [a] -> IO ()
assertElem ref label x xs = assert ref label (x `elem` xs)

assertNotElem :: (Eq a, Show a) => T -> String -> a -> [a] -> IO ()
assertNotElem ref label x xs = assert ref label (x `notElem` xs)

-- ---------------------------------------------------------------------------
-- Main
-- ---------------------------------------------------------------------------

main :: IO ()
main = do
  t <- newT

  -- Types
  testChannelId t
  testSequenceNum t
  testMessageId t
  testNonce t
  testMonoTime t
  testMilliseconds t
  testPacketType t
  testDeliveryMode t
  testDisconnectReason t
  testEncryptionKey t

  -- Config
  testConfig t

  -- FFI
  testFFI t

  TestState ran passed <- readIORef t
  putStrLn $ show passed ++ "/" ++ show ran ++ " tests passed"
  unless (ran == passed) exitFailure

-- ---------------------------------------------------------------------------
-- Types
-- ---------------------------------------------------------------------------

testChannelId :: T -> IO ()
testChannelId t = do
  assertEqual t "mkChannelId 0" (Just (mkCid 0)) (mkChannelId 0)
  assertEqual t "mkChannelId 7" (Just (mkCid 7)) (mkChannelId 7)
  assertEqual t "mkChannelId 8" Nothing (mkChannelId 8)
  assertEqual t "mkChannelId 255" Nothing (mkChannelId 255)
  case mkChannelId 5 of
    Just cid -> assertEqual t "channelIdToInt" 5 (channelIdToInt cid)
    Nothing -> assert t "channelIdToInt" False
  where
    mkCid :: Word8 -> ChannelId
    mkCid w = case mkChannelId w of
      Just c -> c
      Nothing -> error "mkCid: impossible"

testSequenceNum :: T -> IO ()
testSequenceNum t = do
  assertEqual t "initialSeq" 0 (unSequenceNum initialSeq)
  assertEqual t "nextSeq" 1 (unSequenceNum (nextSeq initialSeq))
  assertEqual t "nextSeq wraps" 0 (unSequenceNum (nextSeq (SequenceNum 65535)))

testMessageId :: T -> IO ()
testMessageId t = do
  assertEqual t "initialMessageId" 0 (unMessageId initialMessageId)
  assertEqual t "nextMessageId" 1 (unMessageId (nextMessageId initialMessageId))
  assertEqual t "nextMessageId wraps" 0 (unMessageId (nextMessageId (MessageId maxBound)))

testNonce :: T -> IO ()
testNonce t = do
  assertEqual t "initialNonce" 0 (unNonceCounter initialNonce)
  assertEqual t "nextNonce" 1 (unNonceCounter (nextNonce initialNonce))

testMonoTime :: T -> IO ()
testMonoTime t = do
  assertEqual t "diffNs" 400 (diffNs (MonoTime 100) (MonoTime 500))
  assertEqual t "addNs" (MonoTime 300) (addNs (MonoTime 100) 200)
  let start = MonoTime 1000
      delta = 500
      end = addNs start delta
  assertEqual t "addNs/diffNs roundtrip" delta (diffNs start end)

testMilliseconds :: T -> IO ()
testMilliseconds t = do
  assertEqual t "msToNs 1ms" 1000000 (msToNs (Milliseconds 1.0))
  assertEqual t "msToNs 0ms" 0 (msToNs (Milliseconds 0.0))
  assertEqual t "nsToMs 1000000" (Milliseconds 1.0) (nsToMs 1000000)
  assertEqual t "addMs" (Milliseconds 150.0) (addMs (Milliseconds 100.0) (Milliseconds 50.0))
  assertEqual t "scaleMs" (Milliseconds 250.0) (scaleMs (Milliseconds 100.0) 2.5)

testPacketType :: T -> IO ()
testPacketType t = do
  qcResult <-
    quickCheckResult $
      forAll (elements [minBound .. maxBound]) $ \pt ->
        packetTypeFromWord8 (packetTypeToWord8 pt) == Just pt
  assert t "packetType roundtrip" (isSuccess qcResult)
  assertEqual t "invalid type 8" Nothing (packetTypeFromWord8 8)
  assertEqual t "invalid type 255" Nothing (packetTypeFromWord8 255)
  assertEqual t "ConnectionRequest is 0" 0 (packetTypeToWord8 ConnectionRequest)
  assertEqual t "ConnectionResponse is 7" 7 (packetTypeToWord8 ConnectionResponse)

testDeliveryMode :: T -> IO ()
testDeliveryMode t = do
  assertEqual t "Unreliable not reliable" False (isReliable Unreliable)
  assertEqual t "ReliableOrdered reliable" True (isReliable ReliableOrdered)
  assertEqual t "ReliableSequenced sequenced" True (isSequenced ReliableSequenced)
  assertEqual t "ReliableOrdered ordered" True (isOrdered ReliableOrdered)
  assertEqual t "Unreliable not ordered" False (isOrdered Unreliable)
  assertEqual t "UnreliableSequenced sequenced" True (isSequenced UnreliableSequenced)

testDisconnectReason :: T -> IO ()
testDisconnectReason t = do
  assertEqual t "Timeout roundtrip" ReasonTimeout (parseDisconnectReason (disconnectReasonCode ReasonTimeout))
  assertEqual t "Requested roundtrip" ReasonRequested (parseDisconnectReason (disconnectReasonCode ReasonRequested))
  assertEqual t "ProtocolMismatch code" 4 (disconnectReasonCode ReasonProtocolMismatch)
  assertEqual t "Unknown preserved" (ReasonUnknown 99) (parseDisconnectReason 99)
  assertEqual t "Unknown roundtrip" 42 (disconnectReasonCode (ReasonUnknown 42))

testEncryptionKey :: T -> IO ()
testEncryptionKey t = do
  case mkEncryptionKey (BS.replicate 32 0xAA) of
    Just k -> assertEqual t "key length" 32 (BS.length (unEncryptionKey k))
    Nothing -> assert t "mkEncryptionKey 32" False
  assertEqual t "key rejects 31" Nothing (mkEncryptionKey (BS.replicate 31 0xAA))
  assertEqual t "key rejects 33" Nothing (mkEncryptionKey (BS.replicate 33 0xAA))
  assertEqual t "key rejects empty" Nothing (mkEncryptionKey BS.empty)
  let key = case mkEncryptionKey (BS.replicate 32 0) of
        Just k -> k
        Nothing -> error "impossible"
  assertEqual t "show redacts" "EncryptionKey <redacted>" (show key)

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

testConfig :: T -> IO ()
testConfig t = do
  assertEqual t "default validates" [] (validateConfig defaultNetworkConfig)

  let mtuLow = defaultNetworkConfig {ncMtu = 100}
  assertElem t "MTU too low" (ConfigValueTooLow FieldMtu) (validateConfig mtuLow)

  let mtuHigh = defaultNetworkConfig {ncMtu = 70000}
  assertElem t "MTU too high" (ConfigValueTooHigh FieldMtu) (validateConfig mtuHigh)

  assertEqual t "MTU min boundary" [] (filter isMtuError (validateConfig defaultNetworkConfig {ncMtu = minMtu}))
  assertEqual t "MTU max boundary" [] (filter isMtuError (validateConfig defaultNetworkConfig {ncMtu = maxMtu}))

  let kaExceeds =
        defaultNetworkConfig
          { ncKeepaliveIntervalMs = Milliseconds 20000.0,
            ncConnectionTimeoutMs = Milliseconds 10000.0
          }
  assertElem t "keepalive exceeds timeout" ConfigKeepaliveExceedsTimeout (validateConfig kaExceeds)

  let fragExceeds = defaultNetworkConfig {ncFragmentThreshold = 2000, ncMtu = 1200}
  assertElem t "fragment exceeds MTU" ConfigFragmentExceedsMtu (validateConfig fragExceeds)

  let migNoKey =
        defaultNetworkConfig
          { ncMigrationPolicy = MigrationEnabled,
            ncEncryptionKey = Nothing
          }
  assertElem t "migration requires encryption" ConfigMigrationRequiresEncryption (validateConfig migNoKey)

  let migDisabled =
        defaultNetworkConfig
          { ncMigrationPolicy = MigrationDisabled,
            ncEncryptionKey = Nothing
          }
  assertNotElem t "migration disabled ok" ConfigMigrationRequiresEncryption (validateConfig migDisabled)

  let tooManyChan =
        defaultNetworkConfig
          { ncMaxChannels = 2,
            ncChannelConfigs = replicate 5 defaultChannelConfig
          }
  assertElem t "too many channel configs" ConfigTooManyChannelConfigs (validateConfig tooManyChan)

  let notPow2 = defaultNetworkConfig {ncPacketBufferSize = 100}
  assertElem t "non-power-of-two" (ConfigNotPowerOfTwo FieldPacketBufferSize) (validateConfig notPow2)

  assertEqual t "power-of-two ok" [] (filter isPow2Err (validateConfig defaultNetworkConfig {ncPacketBufferSize = 512}))

  let zeroSeq = defaultNetworkConfig {ncMaxSequenceDistance = 0}
  assertElem t "zero maxSeqDist" (ConfigValueTooLow FieldMaxSequenceDistance) (validateConfig zeroSeq)

  -- H-3: maxSequenceDistance upper bound
  let highSeq = defaultNetworkConfig {ncMaxSequenceDistance = 32769}
  assertElem t "maxSeqDist too high" (ConfigValueTooHigh FieldMaxSequenceDistance) (validateConfig highSeq)

  let boundarySeq = defaultNetworkConfig {ncMaxSequenceDistance = seqHalfRange}
  assertNotElem t "maxSeqDist boundary ok" (ConfigValueTooHigh FieldMaxSequenceDistance) (validateConfig boundarySeq)

  -- T-3: SimulationConfig validation
  let sim0 =
        SimulationConfig
          { simPacketLoss = 0.0,
            simLatencyMs = Milliseconds 0.0,
            simJitterMs = Milliseconds 0.0,
            simDuplicateChance = 0.0,
            simOutOfOrderChance = 0.0,
            simOutOfOrderMaxDelayMs = Milliseconds 0.0,
            simBandwidthLimitBytesPerSec = 0
          }

  assertElem t "sim: loss > 1" (ConfigValueTooHigh FieldSimPacketLoss) (validateConfig defaultNetworkConfig {ncSimulation = Just sim0 {simPacketLoss = 1.5}})
  assertElem t "sim: neg latency" (ConfigValueTooLow FieldSimLatency) (validateConfig defaultNetworkConfig {ncSimulation = Just sim0 {simLatencyMs = Milliseconds (-5.0)}})
  assertElem t "sim: NaN jitter" (ConfigValueNaN FieldSimJitter) (validateConfig defaultNetworkConfig {ncSimulation = Just sim0 {simJitterMs = Milliseconds (0.0 / 0.0)}})
  assertElem t "sim: dup > 1" (ConfigValueTooHigh FieldSimDuplicateChance) (validateConfig defaultNetworkConfig {ncSimulation = Just sim0 {simDuplicateChance = 2.0}})

  -- T-4: ChannelConfig validation
  let ccBadMsg = defaultChannelConfig {ccMaxMessageSize = 0}
  assertElem t "chan: maxMsgSize 0" (ConfigValueTooLow FieldCcMaxMessageSize) (validateConfig defaultNetworkConfig {ncDefaultChannelConfig = ccBadMsg})

  let ccBadBuf = defaultChannelConfig {ccMessageBufferSize = 0}
  assertElem t "chan: msgBufSize 0" (ConfigValueTooLow FieldCcMessageBufferSize) (validateConfig defaultNetworkConfig {ncDefaultChannelConfig = ccBadBuf})

  -- T-5: NaN/Infinity
  assertElem t "sendRate NaN" (ConfigValueNaN FieldSendRate) (validateConfig defaultNetworkConfig {ncSendRate = 0.0 / 0.0})
  assertElem t "sendRate Infinity" (ConfigValueNaN FieldSendRate) (validateConfig defaultNetworkConfig {ncSendRate = 1.0 / 0.0})
  where
    isMtuError (ConfigValueTooLow FieldMtu) = True
    isMtuError (ConfigValueTooHigh FieldMtu) = True
    isMtuError _ = False

    isPow2Err (ConfigNotPowerOfTwo FieldPacketBufferSize) = True
    isPow2Err _ = False

-- ---------------------------------------------------------------------------
-- FFI bridge tests (T-1)
-- ---------------------------------------------------------------------------

testFFI :: T -> IO ()
testFFI t = do
  -- seqGt
  assert t "seqGt 1>0" (seqGt 1 0)
  assert t "seqGt !(0>1)" (not (seqGt 0 1))
  assert t "seqGt !(5>5)" (not (seqGt 5 5))
  assert t "seqGt 0>65535 wrap" (seqGt 0 65535)

  -- seqDiff
  assertEqual t "seqDiff(10,5)" 5 (seqDiff 10 5)
  assertEqual t "seqDiff(5,10)" (-5) (seqDiff 5 10)
  assertEqual t "seqDiff(2,65534)" 4 (seqDiff 2 65534)

  -- packetWrite/Read roundtrip
  allocaBytes packetHeaderSize $ \buf -> do
    written <- packetWrite 3 100 200 0xDEADBEEF buf
    assertEqual t "packet written" packetHeaderSize written
    result <- packetRead buf packetHeaderSize
    assertEqual t "packet roundtrip" (Just (3, 100, 200, 0xDEADBEEF)) result

  -- crc32c
  allocaBytes 16 $ \buf -> do
    pokeArray buf ([0x68, 0x65, 0x6C, 0x6C, 0x6F] :: [Word8])
    val <- crc32c buf 5
    assert t "crc32c nonzero" (val /= 0)

  -- encrypt/decrypt roundtrip
  allocaBytes 32 $ \keyBuf ->
    allocaBytes (cryptoNonceSize + 16 + 16) $ \buf -> do
      pokeArray keyBuf (replicate 32 (0xAA :: Word8))
      pokeArray (buf `plusPtr` cryptoNonceSize) (replicate 16 (0xCD :: Word8))
      encResult <- encrypt keyBuf 42 0x12345678 buf 16
      case encResult of
        Left err -> assert t ("encrypt: " ++ show err) False
        Right encLen -> do
          decResult <- decrypt keyBuf 0x12345678 buf encLen
          case decResult of
            Left err -> assert t ("decrypt: " ++ show err) False
            Right (counter, plainLen) -> do
              assertEqual t "decrypt counter" 42 counter
              assertEqual t "decrypt len" 16 plainLen

  -- bandwidth tracker
  bw <- newBandwidthTracker 1000.0
  bandwidthRecord bw 1000 (100 * 1000000)
  bps <- bandwidthBps bw (200 * 1000000)
  assert t "bandwidth > 0" (bps > 0.0)

  -- fragmentCount
  r1 <- fragmentCount 250 100
  assertEqual t "fragmentCount 250/100" (Just 3) r1
  r2 <- fragmentCount 0 100
  assertEqual t "fragmentCount 0/100" (Just 0) r2
  r3 <- fragmentCount 100 0
  assertEqual t "fragmentCount 100/0" Nothing r3
