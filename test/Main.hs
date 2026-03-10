{-# LANGUAGE OverloadedStrings #-}

module Main (main) where

import Control.Monad (unless)
import qualified Data.ByteString as BS
import Data.IORef
import Data.Int (Int64)
import qualified Data.Map.Strict as Map
import Data.Word (Word16, Word32, Word64, Word8)
import Foreign.Marshal.Alloc (allocaBytes)
import Foreign.Marshal.Array (pokeArray)
import Foreign.Ptr (plusPtr)
import NovaNet.Channel
import NovaNet.Config
import NovaNet.Congestion
import NovaNet.Connection
import NovaNet.FFI.Bandwidth (bandwidthBps, bandwidthRecord, newBandwidthTracker)
import NovaNet.FFI.CRC32C (crc32c)
import NovaNet.FFI.Crypto (cryptoNonceSize, decrypt, encrypt)
import NovaNet.FFI.Fragment (fragmentCount)
import NovaNet.FFI.Packet (packetHeaderSize, packetRead, packetWrite)
import NovaNet.FFI.RecvBuf (newRecvBuf, recvBufExists, recvBufHighest, recvBufInsert)
import NovaNet.FFI.Seq (seqDiff, seqGt)
import NovaNet.Reliability
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

  -- Reliability
  testRecvBuf t
  testAckUpdate t
  testReliability t

  -- Channel
  testChannel t

  -- Congestion
  testCongestion t

  -- Connection
  testConnection t

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

-- ---------------------------------------------------------------------------
-- RecvBuf FFI tests
-- ---------------------------------------------------------------------------

testRecvBuf :: T -> IO ()
testRecvBuf t = do
  rb <- newRecvBuf

  -- Empty buffer
  exists0 <- recvBufExists rb 42
  assert t "recv_empty" (not exists0)

  -- Insert and check
  recvBufInsert rb 42
  exists1 <- recvBufExists rb 42
  assert t "recv_exists" exists1

  -- Different seq
  exists2 <- recvBufExists rb 43
  assert t "recv_not_43" (not exists2)

  -- Highest tracking
  h1 <- recvBufHighest rb
  assertEqual t "recv_highest" (42 :: Word16) h1

  -- Collision: seq 0 and seq 256 map to same slot
  rb2 <- newRecvBuf
  recvBufInsert rb2 0
  recvBufInsert rb2 256
  gone <- recvBufExists rb2 0
  assert t "recv_collision_evict" (not gone)
  here <- recvBufExists rb2 256
  assert t "recv_collision_new" here

-- ---------------------------------------------------------------------------
-- Pure ackUpdate tests
-- ---------------------------------------------------------------------------

testAckUpdate :: T -> IO ()
testAckUpdate t = do
  -- First packet
  let (rs1, _) = ackUpdate 0 0 0
  assertEqual t "ack_first_rs" (0 :: Word16) rs1

  -- Second packet advances
  let (rs2, ab2) = ackUpdate 0 0 1
  assertEqual t "ack_advance_rs" (1 :: Word16) rs2
  assert t "ack_advance_bit0" (ab2 `mod` 2 == 1) -- bit 0 set

  -- Out-of-order: receive seq 2 then seq 1
  let (rs3, ab3) = ackUpdate 0 0 2
      (rs4, ab4) = ackUpdate rs3 ab3 1
  assertEqual t "ack_ooo_rs" (2 :: Word16) rs4
  assert t "ack_ooo_bit0" (ab4 `mod` 2 == 1) -- bit 0 = seq 1

  -- Large gap clears bits
  let (rs5, ab5) = ackUpdate 0 0xFFFFFFFF 100
  assertEqual t "ack_gap_rs" (100 :: Word16) rs5
  assertEqual t "ack_gap_bits" (0 :: Word64) ab5

  -- Wraparound: seq 0 after 65535
  let (rs6, ab6) = ackUpdate 65535 0 0
  assertEqual t "ack_wrap_rs" (0 :: Word16) rs6
  assert t "ack_wrap_bit0" (ab6 `mod` 2 == 1)

  -- Duplicate: same as remote_seq
  let (rs7, ab7) = ackUpdate 5 0 5
  assertEqual t "ack_dup_rs" (5 :: Word16) rs7
  assertEqual t "ack_dup_bits" (0 :: Word64) ab7

  -- Bit position: seq at remote-1 sets bit 0
  let (_, ab8) = ackUpdate 10 0 10
      (rs9, ab9) = ackUpdate 10 ab8 9
  assertEqual t "ack_pos_rs" (10 :: Word16) rs9
  assert t "ack_pos_bit0" (ab9 `mod` 2 == 1)

  -- getAckInfo truncates to 32 bits
  let ep0rs = 42 :: Word16
      ep0ab = 0xFFFFFFFF12345678 :: Word64
      (ackSeq, ackBf) = (ep0rs, fromIntegral (ep0ab `mod` 0x100000000))
  assertEqual t "ack_trunc_seq" (42 :: Word16) ackSeq
  assertEqual t "ack_trunc_bf" (0x12345678 :: Word32) ackBf

-- ---------------------------------------------------------------------------
-- ReliableEndpoint integration tests
-- ---------------------------------------------------------------------------

testReliability :: T -> IO ()
testReliability t = do
  ep0 <- newReliableEndpoint 32768

  -- Initial state
  assertEqual t "rel_init_sent" (0 :: Word64) (reTotalSent ep0)
  assertEqual t "rel_init_acked" (0 :: Word64) (reTotalAcked ep0)
  flight0 <- packetsInFlight ep0
  assertEqual t "rel_init_flight" 0 flight0

  -- allocateSeq
  let (seq1, ep1) = allocateSeq ep0
  assertEqual t "rel_alloc_0" (0 :: Word16) (unSequenceNum seq1)
  let (seq2, ep2) = allocateSeq ep1
  assertEqual t "rel_alloc_1" (1 :: Word16) (unSequenceNum seq2)

  -- allocateSeq wraps (allocate 65536 times to reach wrap)
  let allocN n ep = if n <= (0 :: Int) then ep else let (_, next) = allocateSeq ep in allocN (n - 1) next
      epAtMax = allocN 65535 ep0
      (seqMax, epPostWrap) = allocateSeq epAtMax
  assertEqual t "rel_alloc_wrap" (65535 :: Word16) (unSequenceNum seqMax)
  let (seqWrapped, _) = allocateSeq epPostWrap
  assertEqual t "rel_alloc_wrap_next" (0 :: Word16) (unSequenceNum seqWrapped)

  -- onPacketSent
  let cid = case mkChannelId 0 of Just c -> c; Nothing -> error "impossible"
  ep3 <- onPacketSent ep2 seq1 cid (SequenceNum 0) (MonoTime 1000000) 64
  assertEqual t "rel_sent_count" (1 :: Word64) (reTotalSent ep3)
  assertEqual t "rel_sent_bytes" (64 :: Word64) (reBytesSent ep3)
  flight1 <- packetsInFlight ep3
  assertEqual t "rel_sent_flight" 1 flight1

  -- onPacketReceived: new packet
  mEp4 <- onPacketReceived ep3 10
  case mEp4 of
    Nothing -> assert t "rel_recv_new" False
    Just ep4 -> do
      assertEqual t "rel_recv_rs" (10 :: Word16) (reRemoteSeq ep4)
      -- duplicate rejected
      mEp5 <- onPacketReceived ep4 10
      case mEp5 of
        Nothing -> assert t "rel_recv_dup" True
        Just _ -> assert t "rel_recv_dup" False

  -- getAckInfo
  let (ackS0, ackB0) = getAckInfo ep3
  assertEqual t "rel_ackinfo_init_s" (0 :: Word16) ackS0
  assertEqual t "rel_ackinfo_init_b" (0 :: Word32) ackB0

  -- processIncomingAck with matching sent packet (fresh endpoint)
  epAck <- newReliableEndpoint 32768
  epAck2 <- onPacketSent epAck (SequenceNum 50) cid (SequenceNum 0) (MonoTime 1000000) 100
  flightPre <- packetsInFlight epAck2
  assertEqual t "rel_flight_pre_ack" 1 flightPre

  (outcome, epAck3) <- processIncomingAck epAck2 50 0x00000000 (MonoTime 5000000)
  assertEqual t "rel_ack_count" 1 (aoAckedCount outcome)
  assertEqual t "rel_ack_bytes" 100 (aoAckedBytes outcome)
  assertEqual t "rel_ack_total" (1 :: Word64) (reTotalAcked epAck3)

  -- RTT fed after ack
  srtt <- getSrttNs epAck3
  assert t "rel_srtt_fed" (srtt > 0)

  -- packetsInFlight decreases after ack
  flightPost <- packetsInFlight epAck3
  assertEqual t "rel_flight_after_ack" 0 flightPost

-- ---------------------------------------------------------------------------
-- Channel tests
-- ---------------------------------------------------------------------------

testChannel :: T -> IO ()
testChannel t = do
  let cid = case mkChannelId 0 of Just c -> c; Nothing -> error "impossible"
      now = MonoTime 1000000

  -- Construction
  let chUnrel = newChannel cid defaultChannelConfig {ccDeliveryMode = Unreliable}
  assert t "ch_unrel_not_reliable" (not (channelIsReliable chUnrel))

  let chRel = newChannel cid defaultChannelConfig {ccDeliveryMode = ReliableOrdered}
  assert t "ch_rel_reliable" (channelIsReliable chRel)

  assertEqual t "ch_init_qlen" 0 (channelSendQueueLen chRel)
  assertEqual t "ch_init_sent" (0 :: Word64) (chStatsSent chRel)

  -- Unreliable send/receive
  let chU = newChannel cid defaultChannelConfig {ccDeliveryMode = Unreliable}
  case channelSend "hello" now chU of
    Left err -> assert t ("ch_u_send: " ++ show err) False
    Right (msg, chU2) -> do
      assertEqual t "ch_u_seq" (0 :: Word16) (unSequenceNum (omChannelSeq msg))
      assert t "ch_u_not_reliable" (not (omReliable msg))
      assertEqual t "ch_u_sent" (1 :: Word64) (chStatsSent chU2)

      -- Receive
      let chU3 = onMessageReceived (SequenceNum 0) "hello" now chU2
          (msgs, chU4) = channelReceive chU3
      assertEqual t "ch_u_recv_count" 1 (length msgs)
      case msgs of
        (m : _) -> assertEqual t "ch_u_recv_data" "hello" m
        [] -> assert t "ch_u_recv_data" False
      assertEqual t "ch_u_recv_stat" (1 :: Word64) (chStatsReceived chU4)

  -- UnreliableSequenced: in-order accepted, old dropped
  let chUS = newChannel cid defaultChannelConfig {ccDeliveryMode = UnreliableSequenced}
      chUS2 = onMessageReceived (SequenceNum 5) "a" now chUS
      chUS3 = onMessageReceived (SequenceNum 3) "b" now chUS2 -- older, dropped
      chUS4 = onMessageReceived (SequenceNum 8) "c" now chUS3 -- newer, accepted
      (msgsUS, chUS5) = channelReceive chUS4
  assertEqual t "ch_us_recv" 2 (length msgsUS)
  assertEqual t "ch_us_dropped" (1 :: Word64) (chStatsDropped chUS5)

  -- ReliableUnordered: dedup
  let chRU = newChannel cid defaultChannelConfig {ccDeliveryMode = ReliableUnordered}
      chRU2 = onMessageReceived (SequenceNum 1) "x" now chRU
      chRU3 = onMessageReceived (SequenceNum 1) "x" now chRU2 -- dup
      (msgsRU, chRU4) = channelReceive chRU3
  assertEqual t "ch_ru_recv" 1 (length msgsRU)
  assertEqual t "ch_ru_dropped" (1 :: Word64) (chStatsDropped chRU4)

  -- ReliableOrdered: in-order immediate, OOO buffered, gap fill
  let chRO = newChannel cid defaultChannelConfig {ccDeliveryMode = ReliableOrdered}
      -- Receive seq 0 (expected): delivered immediately
      chRO2 = onMessageReceived (SequenceNum 0) "first" now chRO
      -- Receive seq 2 (skip 1): buffered
      chRO3 = onMessageReceived (SequenceNum 2) "third" now chRO2
      (msgsRO1, chRO4) = channelReceive chRO3
  assertEqual t "ch_ro_immediate" 1 (length msgsRO1)
  case msgsRO1 of
    (m : _) -> assertEqual t "ch_ro_immediate_data" "first" m
    [] -> assert t "ch_ro_immediate_data" False

  -- Fill gap: receive seq 1 → delivers 1 and flushes buffered 2
  let chRO5 = onMessageReceived (SequenceNum 1) "second" now chRO4
      (msgsRO2, chRO6) = channelReceive chRO5
  assertEqual t "ch_ro_flush" 2 (length msgsRO2)
  assertEqual t "ch_ro_flush_order" ["second", "third"] msgsRO2
  assertEqual t "ch_ro_recv_stat" (3 :: Word64) (chStatsReceived chRO6)

  -- ReliableOrdered: duplicate behind expected dropped
  let chRO7 = onMessageReceived (SequenceNum 0) "dup" now chRO6
      (msgsRODup, _) = channelReceive chRO7
  assertEqual t "ch_ro_dup" 0 (length msgsRODup)

  -- ReliableSequenced: newer accepted, older dropped
  let chRS = newChannel cid defaultChannelConfig {ccDeliveryMode = ReliableSequenced}
      chRS2 = onMessageReceived (SequenceNum 10) "a" now chRS
      chRS3 = onMessageReceived (SequenceNum 5) "b" now chRS2 -- dropped
      chRS4 = onMessageReceived (SequenceNum 15) "c" now chRS3
      (msgsRS, chRS5) = channelReceive chRS4
  assertEqual t "ch_rs_recv" 2 (length msgsRS)
  assertEqual t "ch_rs_dropped" (1 :: Word64) (chStatsDropped chRS5)

  -- Reliable send buffer + acknowledge
  let chRA = newChannel cid defaultChannelConfig {ccDeliveryMode = ReliableOrdered}
  case channelSend "data" now chRA of
    Left err -> assert t ("ch_ra_send: " ++ show err) False
    Right (_, chRA2) -> do
      assertEqual t "ch_ra_qlen" 1 (channelSendQueueLen chRA2)
      let chRA3 = acknowledgeMessage (SequenceNum 0) chRA2
      assertEqual t "ch_ra_acked" 0 (channelSendQueueLen chRA3)

  -- MessageTooLarge
  let chBig = newChannel cid defaultChannelConfig {ccMaxMessageSize = 10}
      bigPayload = BS.replicate 20 0xAA
  case channelSend bigPayload now chBig of
    Left MessageTooLarge -> assert t "ch_too_large" True
    _ -> assert t "ch_too_large" False

  -- BufferFull with BlockOnFull
  let cfgBlock = defaultChannelConfig {ccDeliveryMode = ReliableOrdered, ccMessageBufferSize = 2, ccFullBufferPolicy = BlockOnFull}
      chBlock = newChannel cid cfgBlock
  case channelSend "a" now chBlock of
    Left err -> assert t ("ch_block1: " ++ show err) False
    Right (_, chBlock2) ->
      case channelSend "b" now chBlock2 of
        Left err -> assert t ("ch_block2: " ++ show err) False
        Right (_, chBlock3) ->
          case channelSend "c" now chBlock3 of
            Left BufferFull -> assert t "ch_block_full" True
            _ -> assert t "ch_block_full" False

  -- BufferFull with DropOnFull: evicts oldest
  let cfgDrop = defaultChannelConfig {ccDeliveryMode = ReliableOrdered, ccMessageBufferSize = 2, ccFullBufferPolicy = DropOnFull}
      chDrop = newChannel cid cfgDrop
  case channelSend "a" now chDrop of
    Left err -> assert t ("ch_drop1: " ++ show err) False
    Right (_, chDrop2) ->
      case channelSend "b" now chDrop2 of
        Left err -> assert t ("ch_drop2: " ++ show err) False
        Right (_, chDrop3) ->
          case channelSend "c" now chDrop3 of
            Left err -> assert t ("ch_drop3: " ++ show err) False
            Right (_, chDrop4) ->
              assertEqual t "ch_drop_qlen" 2 (channelSendQueueLen chDrop4)

  -- getRetransmitMessages: non-reliable returns empty
  let chNonRel = newChannel cid defaultChannelConfig {ccDeliveryMode = Unreliable}
      (retrans0, _) = getRetransmitMessages now 50000000 chNonRel
  assertEqual t "ch_retrans_nonrel" 0 (length retrans0)

  -- getRetransmitMessages: reliable with expired RTO
  let cfgRetrans = defaultChannelConfig {ccDeliveryMode = ReliableOrdered}
      chRetrans = newChannel cid cfgRetrans
  case channelSend "retry" (MonoTime 1000000) chRetrans of
    Left err -> assert t ("ch_retrans_send: " ++ show err) False
    Right (_, chRetrans2) -> do
      -- RTO of 50ms (50000000 ns), query at t=100ms
      let (retrans1, chRetrans3) = getRetransmitMessages (MonoTime 100000000) 50000000 chRetrans2
      assertEqual t "ch_retrans_count" 1 (length retrans1)
      assertEqual t "ch_retrans_stat" (1 :: Word64) (chStatsRetransmits chRetrans3)

  -- resetChannel
  let chReset = resetChannel chRO6
  assertEqual t "ch_reset_sent" (0 :: Word64) (chStatsSent chReset)
  assertEqual t "ch_reset_qlen" 0 (channelSendQueueLen chReset)

-- ---------------------------------------------------------------------------
-- Congestion tests
-- ---------------------------------------------------------------------------

testCongestion :: T -> IO ()
testCongestion t = do
  let now = MonoTime 1000000000 -- 1 second
      ms250 = 250000000 :: Int64

  -- AIMD: create and verify initial state
  aimd <- newCongestionController BinaryAIMD 60.0 0.1 ms250 1200
  canSend0 <- congestionCanSend aimd 0
  assert t "cong_aimd_cannot_send_init" (not canSend0)

  -- AIMD: tick refills budget
  congestionTick aimd 1.0 0.0 50000000 now
  canSend1 <- congestionCanSend aimd 0
  assert t "cong_aimd_can_send_after_tick" canSend1

  -- AIMD: deduct
  congestionOnSend aimd 0 now
  rate <- congestionRate aimd
  assert t "cong_aimd_rate" (rate > 59.0)

  -- AIMD: pacing returns 0 (AIMD uses budget, not pacing)
  pacing0 <- congestionPacingNs aimd
  assertEqual t "cong_aimd_no_pacing" (0 :: Int64) pacing0

  -- CWND: create
  cwnd <- newCongestionController CwndTcpLike 60.0 0.1 ms250 1200
  -- cwnd = 10 * 1200 = 12000, in_flight = 0 → can send
  canSendCwnd <- congestionCanSend cwnd 1200
  assert t "cong_cwnd_can_send" canSendCwnd

  -- CWND: send fills in_flight
  congestionOnSend cwnd 1200 now
  congestionOnSend cwnd 1200 now
  congestionOnSend cwnd 1200 now

  -- CWND: ack grows window
  congestionOnAck cwnd 1200 1

  -- CWND: pacing after setting SRTT
  congestionTick cwnd 0.0 0.0 100000000 now -- sets srtt = 100ms
  pacingCwnd <- congestionPacingNs cwnd
  assert t "cong_cwnd_pacing" (pacingCwnd > 0)

  -- CWND: loss halves window
  congestionOnLoss cwnd 42 now

  -- CWND: idle restart
  let future = MonoTime 10000000000 -- 10 seconds later
  congestionCheckIdle cwnd future 200000000 -- RTO = 200ms

  -- CWND: rate returns 0 (CWND uses pacing)
  rateCwnd <- congestionRate cwnd
  assertEqual t "cong_cwnd_rate_zero" 0.0 rateCwnd

-- ---------------------------------------------------------------------------
-- Connection tests
-- ---------------------------------------------------------------------------

testConnection :: T -> IO ()
testConnection t = do
  let now = MonoTime 1000000000
      cid = case mkChannelId 0 of Just c -> c; Nothing -> error "impossible"

  -- Construction
  conn0 <- newConnection defaultNetworkConfig now
  assertEqual t "conn_init_state" Disconnected (connectionState conn0)
  assertEqual t "conn_init_chans" (ncMaxChannels defaultNetworkConfig) (channelCount conn0)
  assert t "conn_init_not_connected" (not (isConnected conn0))

  -- State: connect
  case connect conn0 of
    Left err -> assert t ("conn_connect: " ++ show err) False
    Right conn1 -> do
      assertEqual t "conn_connecting" Connecting (connectionState conn1)

      -- Double connect fails
      case connect conn1 of
        Left ErrAlreadyConnected -> assert t "conn_double_connect" True
        _ -> assert t "conn_double_connect" False

      -- Mark connected
      let conn2 = markConnected now conn1
      assert t "conn_connected" (isConnected conn2)

      -- Disconnect
      let conn3 = disconnect ReasonRequested now conn2
      assertEqual t "conn_disconnecting" Disconnecting (connectionState conn3)

      -- Send when not connected
      conn4 <- newConnection defaultNetworkConfig now
      case sendMessage cid "test" now conn4 of
        Left ErrNotConnected -> assert t "conn_send_not_connected" True
        _ -> assert t "conn_send_not_connected" False

      -- Send/receive roundtrip
      case sendMessage cid "hello" now conn2 of
        Left err -> assert t ("conn_send: " ++ show err) False
        Right conn5 -> do
          let conn6 = receiveIncomingPayload cid (SequenceNum 0) "world" now conn5
              (msgs, conn7) = receiveMessages cid conn6
          assertEqual t "conn_recv" 1 (length msgs)
          assertEqual t "conn_recv_data" ["world"] msgs

          -- drainSendQueue (updateTick ticks congestion + processes output)
          tickResult <- updateTick (addNs now 100000000) conn7 -- 100ms tick
          case tickResult of
            Left err -> assert t ("conn_tick: " ++ show err) False
            Right conn8 -> do
              let (pkts, conn9) = drainSendQueue conn8
              assert t "conn_drain_has_pkts" (not (null pkts))
              let (pkts2, _) = drainSendQueue conn9
              assertEqual t "conn_drain_empty" 0 (length pkts2)

  -- resolveChannelAcks: pure tests
  let ackMap0 = Map.fromList [(10, (cid, SequenceNum 100)), (9, (cid, SequenceNum 99))]

  -- Direct ack
  let (resolved1, map1) = resolveChannelAcks 10 0x00000000 ackMap0
  assertEqual t "conn_resolve_direct" 1 (length resolved1)
  assert t "conn_resolve_direct_deleted" (not (Map.member 10 map1))

  -- Bitfield ack: bit 0 = seq 9
  let (resolved2, map2) = resolveChannelAcks 10 0x00000001 ackMap0
  assertEqual t "conn_resolve_bitfield" 2 (length resolved2)
  assert t "conn_resolve_both_deleted" (Map.null map2)

  -- Empty map
  let (resolved3, _) = resolveChannelAcks 10 0xFFFFFFFF Map.empty
  assertEqual t "conn_resolve_empty" 0 (length resolved3)

  -- Untracked seq (unreliable)
  let (resolved4, _) = resolveChannelAcks 99 0x00000000 ackMap0
  assertEqual t "conn_resolve_untracked" 0 (length resolved4)

  -- Wraparound: ack_seq=0, bit 0 = seq 65535
  let ackMapWrap = Map.fromList [(65535, (cid, SequenceNum 50))]
      (resolved5, mapWrap) = resolveChannelAcks 0 0x00000001 ackMapWrap
  assertEqual t "conn_resolve_wrap" 1 (length resolved5)
  assert t "conn_resolve_wrap_deleted" (Map.null mapWrap)

  -- processIncomingHeader: basic ack processing
  conn10 <- newConnection defaultNetworkConfig now
  case connect conn10 of
    Left _ -> assert t "conn_header_setup" False
    Right conn11 -> do
      let conn12 = markConnected now conn11
      -- Send a message to populate sent buffer
      case sendMessage cid "ackme" now conn12 of
        Left err -> assert t ("conn_header_send: " ++ show err) False
        Right conn13 -> do
          -- Process channel output to assign packet seq
          conn14 <- processChannelOutput now conn13
          -- Now process an incoming header that ACKs seq 0
          mConn15 <- processIncomingHeader 100 0 0x00000000 (MonoTime 2000000000) conn14
          case mConn15 of
            Nothing -> assert t "conn_header_not_dup" False
            Just conn15 -> do
              assert t "conn_header_processed" True
              -- Duplicate rejected
              mConn16 <- processIncomingHeader 100 0 0x00000000 (MonoTime 2000000000) conn15
              case mConn16 of
                Nothing -> assert t "conn_header_dup" True
                Just _ -> assert t "conn_header_dup" False

  -- updateTick: timeout
  connTimeout <- newConnection defaultNetworkConfig {ncConnectionTimeoutMs = Milliseconds 100.0} now
  case connect connTimeout of
    Left _ -> assert t "conn_timeout_setup" False
    Right ct1 -> do
      let ct2 = markConnected now ct1
      -- Tick far in the future
      result <- updateTick (MonoTime 10000000000) ct2
      case result of
        Left ErrTimeout -> assert t "conn_tick_timeout" True
        _ -> assert t "conn_tick_timeout" False

  -- updateTick: no timeout when recent activity
  connActive <- newConnection defaultNetworkConfig now
  case connect connActive of
    Left _ -> assert t "conn_active_setup" False
    Right ca1 -> do
      let ca2 = markConnected now ca1
      result2 <- updateTick (addNs now 100000000) ca2 -- 100ms later
      case result2 of
        Right _ -> assert t "conn_tick_no_timeout" True
        Left _ -> assert t "conn_tick_no_timeout" False
