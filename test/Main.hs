module Main (main) where

import qualified Data.ByteString as BS
import Data.Word (Word8)
import NovaNet.Config
import NovaNet.Types
import Test.QuickCheck (elements, forAll)
import Test.Tasty
import Test.Tasty.HUnit
import Test.Tasty.QuickCheck (testProperty)

main :: IO ()
main = defaultMain tests

tests :: TestTree
tests =
  testGroup
    "nova-net"
    [ typesTests,
      configTests
    ]

-- ---------------------------------------------------------------------------
-- Types tests
-- ---------------------------------------------------------------------------

typesTests :: TestTree
typesTests =
  testGroup
    "Types"
    [ channelIdTests,
      sequenceNumTests,
      messageIdTests,
      nonceTests,
      monoTimeTests,
      millisecondsTests,
      packetTypeTests,
      deliveryModeTests,
      disconnectReasonTests,
      encryptionKeyTests
    ]

-- ChannelId

channelIdTests :: TestTree
channelIdTests =
  testGroup
    "ChannelId"
    [ testCase "mkChannelId accepts 0" $
        mkChannelId 0 @?= Just (mkCid 0),
      testCase "mkChannelId accepts 7" $
        mkChannelId 7 @?= Just (mkCid 7),
      testCase "mkChannelId rejects 8" $
        mkChannelId 8 @?= Nothing,
      testCase "mkChannelId rejects 255" $
        mkChannelId 255 @?= Nothing,
      testCase "channelIdToInt roundtrip" $
        case mkChannelId 5 of
          Just cid -> channelIdToInt cid @?= 5
          Nothing -> assertFailure "mkChannelId 5 returned Nothing"
    ]
  where
    mkCid :: Word8 -> ChannelId
    mkCid w = case mkChannelId w of
      Just c -> c
      Nothing -> error "mkCid: impossible"

-- SequenceNum

sequenceNumTests :: TestTree
sequenceNumTests =
  testGroup
    "SequenceNum"
    [ testCase "initialSeq is 0" $
        unSequenceNum initialSeq @?= 0,
      testCase "nextSeq increments" $
        unSequenceNum (nextSeq initialSeq) @?= 1,
      testCase "nextSeq wraps at 65535" $
        unSequenceNum (nextSeq (SequenceNum 65535)) @?= 0
    ]

-- MessageId

messageIdTests :: TestTree
messageIdTests =
  testGroup
    "MessageId"
    [ testCase "initialMessageId is 0" $
        unMessageId initialMessageId @?= 0,
      testCase "nextMessageId increments" $
        unMessageId (nextMessageId initialMessageId) @?= 1,
      testCase "nextMessageId wraps" $
        unMessageId (nextMessageId (MessageId maxBound)) @?= 0
    ]

-- NonceCounter

nonceTests :: TestTree
nonceTests =
  testGroup
    "NonceCounter"
    [ testCase "initialNonce is 0" $
        unNonceCounter initialNonce @?= 0,
      testCase "nextNonce increments" $
        unNonceCounter (nextNonce initialNonce) @?= 1
    ]

-- MonoTime

monoTimeTests :: TestTree
monoTimeTests =
  testGroup
    "MonoTime"
    [ testCase "diffNs basic" $
        diffNs (MonoTime 100) (MonoTime 500) @?= 400,
      testCase "addNs basic" $
        addNs (MonoTime 100) 200 @?= MonoTime 300,
      testCase "addNs then diffNs roundtrip" $
        let start = MonoTime 1000
            delta = 500
            end = addNs start delta
         in diffNs start end @?= delta
    ]

-- Milliseconds

millisecondsTests :: TestTree
millisecondsTests =
  testGroup
    "Milliseconds"
    [ testCase "msToNs 1ms = 1000000ns" $
        msToNs (Milliseconds 1.0) @?= 1000000,
      testCase "msToNs 0ms = 0ns" $
        msToNs (Milliseconds 0.0) @?= 0,
      testCase "nsToMs 1000000ns = 1ms" $
        nsToMs 1000000 @?= Milliseconds 1.0,
      testCase "addition" $
        Milliseconds 100.0 + Milliseconds 50.0 @?= Milliseconds 150.0
    ]

-- PacketType

packetTypeTests :: TestTree
packetTypeTests =
  testGroup
    "PacketType"
    [ testProperty "roundtrip" $
        forAll (elements [minBound .. maxBound]) $ \pt ->
          packetTypeFromWord8 (packetTypeToWord8 pt) == Just pt,
      testCase "invalid type 8 rejected" $
        packetTypeFromWord8 8 @?= Nothing,
      testCase "invalid type 255 rejected" $
        packetTypeFromWord8 255 @?= Nothing,
      testCase "ConnectionRequest is 0" $
        packetTypeToWord8 ConnectionRequest @?= 0,
      testCase "ConnectionResponse is 7" $
        packetTypeToWord8 ConnectionResponse @?= 7
    ]

-- DeliveryMode

deliveryModeTests :: TestTree
deliveryModeTests =
  testGroup
    "DeliveryMode"
    [ testCase "Unreliable is not reliable" $
        isReliable Unreliable @?= False,
      testCase "ReliableOrdered is reliable" $
        isReliable ReliableOrdered @?= True,
      testCase "ReliableSequenced is sequenced" $
        isSequenced ReliableSequenced @?= True,
      testCase "ReliableOrdered is ordered" $
        isOrdered ReliableOrdered @?= True,
      testCase "Unreliable is not ordered" $
        isOrdered Unreliable @?= False,
      testCase "UnreliableSequenced is sequenced" $
        isSequenced UnreliableSequenced @?= True
    ]

-- DisconnectReason

disconnectReasonTests :: TestTree
disconnectReasonTests =
  testGroup
    "DisconnectReason"
    [ testCase "Timeout roundtrip" $
        parseDisconnectReason (disconnectReasonCode ReasonTimeout)
          @?= ReasonTimeout,
      testCase "Requested roundtrip" $
        parseDisconnectReason (disconnectReasonCode ReasonRequested)
          @?= ReasonRequested,
      testCase "ProtocolMismatch code is 4" $
        disconnectReasonCode ReasonProtocolMismatch @?= 4,
      testCase "Unknown code preserved" $
        parseDisconnectReason 99 @?= ReasonUnknown 99,
      testCase "Unknown roundtrip" $
        disconnectReasonCode (ReasonUnknown 42) @?= 42
    ]

-- EncryptionKey

encryptionKeyTests :: TestTree
encryptionKeyTests =
  testGroup
    "EncryptionKey"
    [ testCase "mkEncryptionKey accepts 32 bytes" $
        case mkEncryptionKey (BS.replicate 32 0xAA) of
          Just k -> BS.length (unEncryptionKey k) @?= 32
          Nothing -> assertFailure "mkEncryptionKey rejected 32 bytes",
      testCase "mkEncryptionKey rejects 31 bytes" $
        mkEncryptionKey (BS.replicate 31 0xAA) @?= Nothing,
      testCase "mkEncryptionKey rejects 33 bytes" $
        mkEncryptionKey (BS.replicate 33 0xAA) @?= Nothing,
      testCase "mkEncryptionKey rejects empty" $
        mkEncryptionKey BS.empty @?= Nothing,
      testCase "show redacts key" $
        let key = case mkEncryptionKey (BS.replicate 32 0) of
              Just k -> k
              Nothing -> error "impossible"
         in show key @?= "EncryptionKey <redacted>"
    ]

-- ---------------------------------------------------------------------------
-- Config tests
-- ---------------------------------------------------------------------------

configTests :: TestTree
configTests =
  testGroup
    "Config"
    [ testCase "defaultNetworkConfig validates clean" $
        validateConfig defaultNetworkConfig @?= [],
      testCase "MTU too low" $
        let cfg = defaultNetworkConfig {ncMtu = 100}
         in assertBool "expected ConfigValueTooLow FieldMtu" $
              ConfigValueTooLow FieldMtu `elem` validateConfig cfg,
      testCase "MTU too high" $
        let cfg = defaultNetworkConfig {ncMtu = 70000}
         in assertBool "expected ConfigValueTooHigh FieldMtu" $
              ConfigValueTooHigh FieldMtu `elem` validateConfig cfg,
      testCase "MTU at min boundary (576) valid" $
        let cfg = defaultNetworkConfig {ncMtu = minMtu}
         in filter isMtuError (validateConfig cfg) @?= [],
      testCase "MTU at max boundary (65535) valid" $
        let cfg = defaultNetworkConfig {ncMtu = maxMtu}
         in filter isMtuError (validateConfig cfg) @?= [],
      testCase "keepalive exceeds timeout" $
        let cfg =
              defaultNetworkConfig
                { ncKeepaliveIntervalMs = Milliseconds 20000.0,
                  ncConnectionTimeoutMs = Milliseconds 10000.0
                }
         in assertBool "expected ConfigKeepaliveExceedsTimeout" $
              ConfigKeepaliveExceedsTimeout `elem` validateConfig cfg,
      testCase "fragment threshold exceeds MTU" $
        let cfg = defaultNetworkConfig {ncFragmentThreshold = 2000, ncMtu = 1200}
         in assertBool "expected ConfigFragmentExceedsMtu" $
              ConfigFragmentExceedsMtu `elem` validateConfig cfg,
      testCase "migration requires encryption" $
        let cfg =
              defaultNetworkConfig
                { ncMigrationPolicy = MigrationEnabled,
                  ncEncryptionKey = Nothing
                }
         in assertBool "expected ConfigMigrationRequiresEncryption" $
              ConfigMigrationRequiresEncryption `elem` validateConfig cfg,
      testCase "migration disabled without encryption is ok" $
        let cfg =
              defaultNetworkConfig
                { ncMigrationPolicy = MigrationDisabled,
                  ncEncryptionKey = Nothing
                }
         in assertBool "should not require encryption when migration disabled" $
              ConfigMigrationRequiresEncryption `notElem` validateConfig cfg,
      testCase "too many channel configs" $
        let cfg =
              defaultNetworkConfig
                { ncMaxChannels = 2,
                  ncChannelConfigs = replicate 5 defaultChannelConfig
                }
         in assertBool "expected ConfigTooManyChannelConfigs" $
              ConfigTooManyChannelConfigs `elem` validateConfig cfg,
      testCase "non-power-of-two buffer rejected" $
        let cfg = defaultNetworkConfig {ncPacketBufferSize = 100}
         in assertBool "expected ConfigNotPowerOfTwo FieldPacketBufferSize" $
              ConfigNotPowerOfTwo FieldPacketBufferSize `elem` validateConfig cfg,
      testCase "power-of-two buffer accepted" $
        let cfg = defaultNetworkConfig {ncPacketBufferSize = 512}
         in filter isPowerOfTwoError (validateConfig cfg) @?= [],
      testCase "zero maxSequenceDistance" $
        let cfg = defaultNetworkConfig {ncMaxSequenceDistance = 0}
         in assertBool "expected ConfigValueTooLow FieldMaxSequenceDistance" $
              ConfigValueTooLow FieldMaxSequenceDistance `elem` validateConfig cfg
    ]

isMtuError :: ConfigError -> Bool
isMtuError (ConfigValueTooLow FieldMtu) = True
isMtuError (ConfigValueTooHigh FieldMtu) = True
isMtuError _ = False

isPowerOfTwoError :: ConfigError -> Bool
isPowerOfTwoError (ConfigNotPowerOfTwo FieldPacketBufferSize) = True
isPowerOfTwoError _ = False
