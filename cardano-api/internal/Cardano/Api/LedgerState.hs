{-# LANGUAGE DataKinds #-}
{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TypeOperators #-}

{- HLINT ignore "Redundant fmap" -}

module Cardano.Api.LedgerState
  ( -- * Initialization / Accumulation
    envSecurityParam
  , LedgerState
      ( ..
      , LedgerStateByron
      , LedgerStateShelley
      , LedgerStateAllegra
      , LedgerStateMary
      , LedgerStateAlonzo
      , LedgerStateBabbage
      , LedgerStateConway
      )
  , encodeLedgerState
  , decodeLedgerState
  , initialLedgerState
  , applyBlock
  , ValidationMode(..)
  , applyBlockWithEvents

    -- * Traversing the block chain
  , foldBlocks
  , chainSyncClientWithLedgerState
  , chainSyncClientPipelinedWithLedgerState

   -- * Errors
  , LedgerStateError(..)
  , FoldBlocksError(..)
  , GenesisConfigError(..)
  , InitialLedgerStateError(..)
  , renderLedgerStateError
  , renderFoldBlocksError
  , renderGenesisConfigError
  , renderInitialLedgerStateError

  -- * Leadership schedule
  , LeadershipError(..)
  , constructGlobals
  , currentEpochEligibleLeadershipSlots
  , nextEpochEligibleLeadershipSlots
  -- * Node Config
  , NodeConfig(..)
  -- ** Network Config
  , NodeConfigFile
  , readNodeConfig
  -- ** Genesis Config
  , GenesisConfig (..)
  , readCardanoGenesisConfig
  , mkProtocolInfoCardano
  -- *** Byron Genesis Config
  , readByronGenesisConfig
  -- *** Shelley Genesis Config
  , ShelleyConfig (..)
  , GenesisHashShelley (..)
  , readShelleyGenesisConfig
  , shelleyPraosNonce
  -- *** Alonzo Genesis Config
  , GenesisHashAlonzo (..)
  , readAlonzoGenesisConfig
  -- *** Conway Genesis Config
  , GenesisHashConway (..)
  , readConwayGenesisConfig
  -- ** Environment
  , Env(..)
  , genesisConfigToEnv

  )
  where

import           Cardano.Api.Block
import           Cardano.Api.Certificate
import           Cardano.Api.Eras
import           Cardano.Api.Error
import           Cardano.Api.Genesis
import           Cardano.Api.IO
import           Cardano.Api.IPC (ConsensusModeParams (..),
                   LocalChainSyncClient (LocalChainSyncClientPipelined),
                   LocalNodeClientProtocols (..), LocalNodeClientProtocolsInMode,
                   LocalNodeConnectInfo (..), connectToLocalNode)
import           Cardano.Api.Keys.Praos
import           Cardano.Api.LedgerEvent (LedgerEvent, toLedgerEvent)
import           Cardano.Api.Modes (CardanoMode, EpochSlots (..))
import qualified Cardano.Api.Modes as Api
import           Cardano.Api.NetworkId (NetworkId (..), NetworkMagic (NetworkMagic))
import           Cardano.Api.Query (CurrentEpochState (..), PoolDistribution (unPoolDistr),
                   ProtocolState, SerialisedCurrentEpochState (..), SerialisedPoolDistribution,
                   decodeCurrentEpochState, decodePoolDistribution, decodeProtocolState)
import qualified Cardano.Api.ReexposeLedger as Ledger
import           Cardano.Api.SpecialByron as Byron
import           Cardano.Api.Utils (textShow)

import qualified Cardano.Binary as CBOR
import qualified Cardano.Chain.Genesis
import qualified Cardano.Chain.Update
import           Cardano.Crypto (ProtocolMagicId (unProtocolMagicId), RequiresNetworkMagic (..))
import qualified Cardano.Crypto.Hash.Blake2b
import qualified Cardano.Crypto.Hash.Class
import qualified Cardano.Crypto.Hashing
import qualified Cardano.Crypto.ProtocolMagic
import qualified Cardano.Crypto.VRF as Crypto
import qualified Cardano.Crypto.VRF.Class as VRF
import           Cardano.Ledger.Alonzo.Genesis (AlonzoGenesis (..))
import           Cardano.Ledger.BaseTypes (Globals (..), Nonce, ProtVer (..), natVersion, (⭒))
import qualified Cardano.Ledger.BaseTypes as Ledger
import qualified Cardano.Ledger.BHeaderView as Ledger
import           Cardano.Ledger.Binary (DecoderError, FromCBOR)
import           Cardano.Ledger.Conway.Genesis (ConwayGenesis (..))
import qualified Cardano.Ledger.Keys as SL
import qualified Cardano.Ledger.PoolDistr as SL
import qualified Cardano.Ledger.Shelley.API as ShelleyAPI
import qualified Cardano.Ledger.Shelley.Core as Core
import qualified Cardano.Ledger.Shelley.Genesis as Ledger
import           Cardano.Ledger.Shelley.Translation (emptyFromByronTranslationContext)
import qualified Cardano.Protocol.TPraos.API as TPraos
import           Cardano.Protocol.TPraos.BHeader (checkLeaderNatValue)
import qualified Cardano.Protocol.TPraos.BHeader as TPraos
import           Cardano.Slotting.EpochInfo (EpochInfo)
import qualified Cardano.Slotting.EpochInfo.API as Slot
import           Cardano.Slotting.Slot (WithOrigin (At, Origin))
import qualified Cardano.Slotting.Slot as Slot
import qualified Ouroboros.Consensus.Block.Abstract as Consensus
import           Ouroboros.Consensus.Block.Forging (BlockForging)
import qualified Ouroboros.Consensus.Byron.Ledger.Block as Byron
import qualified Ouroboros.Consensus.Byron.Ledger.Ledger as Byron
import qualified Ouroboros.Consensus.Cardano as Consensus
import qualified Ouroboros.Consensus.Cardano.Block as Consensus
import qualified Ouroboros.Consensus.Cardano.CanHardFork as Consensus
import qualified Ouroboros.Consensus.Cardano.Node as Consensus
import qualified Ouroboros.Consensus.Config as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator as Consensus
import qualified Ouroboros.Consensus.HardFork.Combinator.AcrossEras as HFC
import qualified Ouroboros.Consensus.HardFork.Combinator.Basics as HFC
import qualified Ouroboros.Consensus.HardFork.Combinator.Serialisation.Common as HFC
import qualified Ouroboros.Consensus.Ledger.Abstract as Ledger
import           Ouroboros.Consensus.Ledger.Basics (LedgerResult (lrEvents), lrResult)
import qualified Ouroboros.Consensus.Ledger.Extended as Ledger
import qualified Ouroboros.Consensus.Mempool.Capacity as TxLimits
import qualified Ouroboros.Consensus.Node.ProtocolInfo as Consensus
import           Ouroboros.Consensus.Protocol.Abstract (ChainDepState, ConsensusProtocol (..))
import qualified Ouroboros.Consensus.Protocol.Abstract as Consensus
import qualified Ouroboros.Consensus.Protocol.Praos.Common as Consensus
import           Ouroboros.Consensus.Protocol.Praos.VRF (mkInputVRF, vrfLeaderValue)
import           Ouroboros.Consensus.Protocol.TPraos (TPraos)
import qualified Ouroboros.Consensus.Protocol.TPraos as TPraos
import qualified Ouroboros.Consensus.Shelley.Eras as Shelley
import qualified Ouroboros.Consensus.Shelley.Ledger.Block as Shelley
import qualified Ouroboros.Consensus.Shelley.Ledger.Ledger as Shelley
import           Ouroboros.Consensus.TypeFamilyWrappers (WrapLedgerEvent (WrapLedgerEvent))
import qualified Ouroboros.Network.Block
import qualified Ouroboros.Network.Protocol.ChainSync.Client as CS
import qualified Ouroboros.Network.Protocol.ChainSync.ClientPipelined as CSP
import           Ouroboros.Network.Protocol.ChainSync.PipelineDecision

import           Control.Exception
import           Control.Monad (when)
import           Control.Monad.Trans.Class
import           Control.Monad.Trans.Except
import           Control.Monad.Trans.Except.Extra (firstExceptT, handleIOExceptT, hoistEither, left)
import           Data.Aeson as Aeson
import           Data.Aeson.Types (Parser)
import           Data.Bifunctor
import           Data.ByteArray (ByteArrayAccess)
import qualified Data.ByteArray
import           Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import qualified Data.ByteString.Base16 as Base16
import qualified Data.ByteString.Lazy as LB
import           Data.ByteString.Short as BSS
import           Data.Foldable
import           Data.IORef
import           Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import           Data.Maybe (mapMaybe)
import           Data.Proxy (Proxy (Proxy))
import           Data.Sequence (Seq)
import qualified Data.Sequence as Seq
import           Data.Set (Set)
import qualified Data.Set as Set
import           Data.SOP (K (K), (:.:) (Comp))
import           Data.SOP.Strict (NP (..), fn)
import           Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Text.Encoding as Text
import qualified Data.Text.Lazy as LT
import           Data.Text.Lazy.Builder (toLazyText)
import           Data.Type.Nat (queueFDepthNat)
import           Data.Type.Queue (SingQueueF (..))
import qualified Data.Type.Queue as Queue
import           Data.Word
import qualified Data.Yaml as Yaml
import           Formatting.Buildable (build)
import           Lens.Micro
import           System.FilePath

data InitialLedgerStateError
  = ILSEConfigFile Text
  -- ^ Failed to read or parse the network config file.
  | ILSEGenesisFile GenesisConfigError
  -- ^ Failed to read or parse a genesis file linked from the network config file.
  | ILSELedgerConsensusConfig GenesisConfigError
  -- ^ Failed to derive the Ledger or Consensus config.
  deriving Show

instance Exception InitialLedgerStateError

renderInitialLedgerStateError :: InitialLedgerStateError -> Text
renderInitialLedgerStateError ilse = case ilse of
  ILSEConfigFile err ->
    "Failed to read or parse the network config file: " <> err
  ILSEGenesisFile err ->
    "Failed to read or parse a genesis file linked from the network config file: "
    <> renderGenesisConfigError err
  ILSELedgerConsensusConfig err ->
    "Failed to derive the Ledger or Consensus config: "
    <> renderGenesisConfigError err

data LedgerStateError
  = ApplyBlockHashMismatch Text
  -- ^ When using QuickValidation, the block hash did not match the expected
  -- block hash after applying a new block to the current ledger state.
  | ApplyBlockError (Consensus.HardForkLedgerError (Consensus.CardanoEras Consensus.StandardCrypto))
  -- ^ When using FullValidation, an error occurred when applying a new block
  -- to the current ledger state.
  | InvalidRollback
  -- ^ Encountered a rollback larger than the security parameter.
      SlotNo     -- ^ Oldest known slot number that we can roll back to.
      ChainPoint -- ^ Rollback was attempted to this point.
  deriving (Show)

instance Exception LedgerStateError


renderLedgerStateError :: LedgerStateError -> Text
renderLedgerStateError = \case
  ApplyBlockHashMismatch err -> "Applying a block did not result in the expected block hash: " <> err
  ApplyBlockError hardForkLedgerError -> "Applying a block resulted in an error: " <> textShow hardForkLedgerError
  InvalidRollback oldestSupported rollbackPoint ->
      "Encountered a rollback larger than the security parameter. Attempted to roll back to "
      <> textShow rollbackPoint
      <> ", but oldest supported slot is "
      <> textShow oldestSupported

-- | Get the environment and initial ledger state.
initialLedgerState
  :: NodeConfigFile 'In
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> ExceptT InitialLedgerStateError IO (Env, LedgerState)
  -- ^ The environment and initial ledger state
initialLedgerState nodeConfigFile = do
  -- TODO Once support for querying the ledger config is added to the node, we
  -- can remove the nodeConfigFile argument and much of the code in this
  -- module.
  config <- withExceptT ILSEConfigFile (readNodeConfig nodeConfigFile)
  genesisConfig <- withExceptT ILSEGenesisFile (readCardanoGenesisConfig config)
  env <- withExceptT ILSELedgerConsensusConfig (except (genesisConfigToEnv genesisConfig))
  let ledgerState = initLedgerStateVar genesisConfig
  return (env, ledgerState)

-- | Apply a single block to the current ledger state.
applyBlock
  :: Env
  -- ^ The environment returned by @initialLedgerState@
  -> LedgerState
  -- ^ The current ledger state
  -> ValidationMode
  -> Block era
  -- ^ Some block to apply
  -> Either LedgerStateError (LedgerState, [LedgerEvent])
  -- ^ The new ledger state (or an error).
applyBlock env oldState validationMode block
  = applyBlock' env oldState validationMode $ case block of
      ByronBlock byronBlock -> Consensus.BlockByron byronBlock
      ShelleyBlock blockEra shelleyBlock -> case blockEra of
        ShelleyBasedEraShelley -> Consensus.BlockShelley shelleyBlock
        ShelleyBasedEraAllegra -> Consensus.BlockAllegra shelleyBlock
        ShelleyBasedEraMary    -> Consensus.BlockMary shelleyBlock
        ShelleyBasedEraAlonzo  -> Consensus.BlockAlonzo shelleyBlock
        ShelleyBasedEraBabbage -> Consensus.BlockBabbage shelleyBlock
        ShelleyBasedEraConway  -> Consensus.BlockConway shelleyBlock

pattern LedgerStateByron
  :: Ledger.LedgerState Byron.ByronBlock
  -> LedgerState
pattern LedgerStateByron st <- LedgerState (Consensus.LedgerStateByron st)

pattern LedgerStateShelley
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.ShelleyEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateShelley st <- LedgerState  (Consensus.LedgerStateShelley st)

pattern LedgerStateAllegra
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.AllegraEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateAllegra st <- LedgerState  (Consensus.LedgerStateAllegra st)

pattern LedgerStateMary
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.MaryEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateMary st <- LedgerState  (Consensus.LedgerStateMary st)

pattern LedgerStateAlonzo
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.AlonzoEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateAlonzo st <- LedgerState  (Consensus.LedgerStateAlonzo st)

pattern LedgerStateBabbage
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.BabbageEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateBabbage st <- LedgerState  (Consensus.LedgerStateBabbage st)

pattern LedgerStateConway
  :: Ledger.LedgerState (Shelley.ShelleyBlock protocol (Shelley.ConwayEra Shelley.StandardCrypto))
  -> LedgerState
pattern LedgerStateConway st <- LedgerState  (Consensus.LedgerStateConway st)

{-# COMPLETE LedgerStateByron
           , LedgerStateShelley
           , LedgerStateAllegra
           , LedgerStateMary
           , LedgerStateAlonzo
           , LedgerStateBabbage
           , LedgerStateConway #-}

data FoldBlocksError
  = FoldBlocksInitialLedgerStateError InitialLedgerStateError
  | FoldBlocksApplyBlockError LedgerStateError

renderFoldBlocksError :: FoldBlocksError -> Text
renderFoldBlocksError fbe = case fbe of
  FoldBlocksInitialLedgerStateError err -> renderInitialLedgerStateError err
  FoldBlocksApplyBlockError err -> "Failed when applying a block: " <> renderLedgerStateError err

-- | Monadic fold over all blocks and ledger states. Stopping @k@ blocks before
-- the node's tip where @k@ is the security parameter.
foldBlocks
  :: forall a. ()
  => NodeConfigFile 'In
  -- ^ Path to the cardano-node config file (e.g. <path to cardano-node project>/configuration/cardano/mainnet-config.json)
  -> SocketPath
  -- ^ Path to local cardano-node socket. This is the path specified by the @--socket-path@ command line option when running the node.
  -> ValidationMode
  -> a
  -- ^ The initial accumulator state.
  -> (Env -> LedgerState -> [LedgerEvent] -> BlockInMode CardanoMode -> a -> IO a)
  -- ^ Accumulator function Takes:
  --
  --  * Environment (this is a constant over the whole fold).
  --  * The Ledger state (with block @i@ applied) at block @i@.
  --  * The Ledger events resulting from applying block @i@.
  --  * Block @i@.
  --  * The accumulator state at block @i - 1@.
  --
  -- And returns:
  --
  --  * The accumulator state at block @i@
  --
  -- Note: This function can safely assume no rollback will occur even though
  -- internally this is implemented with a client protocol that may require
  -- rollback. This is achieved by only calling the accumulator on states/blocks
  -- that are older than the security parameter, k. This has the side effect of
  -- truncating the last k blocks before the node's tip.
  -> ExceptT FoldBlocksError IO a
  -- ^ The final state
foldBlocks nodeConfigFilePath socketPath validationMode state0 accumulate = do
  -- NOTE this was originally implemented with a non-pipelined client then
  -- changed to a pipelined client for a modest speedup:
  --  * Non-pipelined: 1h  0m  19s
  --  * Pipelined:        46m  23s

  (env, ledgerState) <- withExceptT FoldBlocksInitialLedgerStateError $ initialLedgerState nodeConfigFilePath

  -- Place to store the accumulated state
  -- This is a bit ugly, but easy.
  errorIORef <- lift $ newIORef Nothing
  stateIORef <- lift $ newIORef state0

  -- Derive the NetworkId as described in network-magic.md from the
  -- cardano-ledger-specs repo.
  let byronConfig
        = (\(Consensus.WrapPartialLedgerConfig (Consensus.ByronPartialLedgerConfig bc _) :* _) -> bc)
        . HFC.getPerEraLedgerConfig
        . HFC.hardForkLedgerConfigPerEra
        $ envLedgerConfig env

      networkMagic
        = NetworkMagic
        $ unProtocolMagicId
        $ Cardano.Chain.Genesis.gdProtocolMagicId
        $ Cardano.Chain.Genesis.configGenesisData byronConfig

      networkId' = case Cardano.Chain.Genesis.configReqNetMagic byronConfig of
        RequiresNoMagic -> Mainnet
        RequiresMagic -> Testnet networkMagic

      cardanoModeParams = CardanoModeParams . EpochSlots $ 10 * envSecurityParam env

  -- Connect to the node.
  let connectInfo :: LocalNodeConnectInfo CardanoMode
      connectInfo =
          LocalNodeConnectInfo {
            localConsensusModeParams = cardanoModeParams,
            localNodeNetworkId       = networkId',
            localNodeSocketPath      = socketPath
          }

  lift $ connectToLocalNode
    connectInfo
    (protocols stateIORef errorIORef env ledgerState)

  lift (readIORef errorIORef) >>= \case
    Just err -> throwE (FoldBlocksApplyBlockError err)
    Nothing -> lift $ readIORef stateIORef
  where

    protocols :: IORef a -> IORef (Maybe LedgerStateError) -> Env -> LedgerState -> LocalNodeClientProtocolsInMode CardanoMode
    protocols stateIORef errorIORef env ledgerState =
        LocalNodeClientProtocols {
          localChainSyncClient    = LocalChainSyncClientPipelined (chainSyncClient 50 stateIORef errorIORef env ledgerState),
          localTxSubmissionClient = Nothing,
          localStateQueryClient   = Nothing,
          localTxMonitoringClient = Nothing
        }

    -- | Defines the client side of the chain sync protocol.
    chainSyncClient :: Word32
                    -- ^ The maximum number of concurrent requests.
                    -> IORef a
                    -> IORef (Maybe LedgerStateError)
                    -- ^ Resulting error if any. Written to once on protocol
                    -- completion.
                    -> Env
                    -> LedgerState
                    -> CSP.ChainSyncClientPipelined
                        (BlockInMode CardanoMode)
                        ChainPoint
                        ChainTip
                        IO ()
                    -- ^ Client returns maybe an error.
    chainSyncClient pipelineSize stateIORef errorIORef env ledgerState0
      = CSP.ChainSyncClientPipelined $ pure $ clientIdle_RequestMoreN Origin Origin SingEmptyF initialLedgerStateHistory
      where
          initialLedgerStateHistory = Seq.singleton (0, (ledgerState0, []), Origin)

          clientIdle_RequestMoreN
            :: WithOrigin BlockNo
            -> WithOrigin BlockNo
            -> SingQueueF CSP.F q -- Queue of requests inflight.
            -> LedgerStateHistory
            -> CSP.ClientPipelinedStIdle (BlockInMode CardanoMode) ChainPoint ChainTip q IO ()
          clientIdle_RequestMoreN clientTip serverTip q knownLedgerStates
            = case pipelineDecisionMax pipelineSize (queueFDepthNat q) clientTip serverTip  of
                Collect -> case q of
                  SingConsF CSP.FCanAwait  q' -> CSP.CollectResponse Nothing (clientNextN q' knownLedgerStates)
                  SingConsF CSP.FMustReply q' -> CSP.CollectResponse Nothing (clientNextN q' knownLedgerStates)
                _ -> CSP.SendMsgRequestNextPipelined (clientIdle_RequestMoreN clientTip serverTip (q Queue.|> CSP.FCanAwait) knownLedgerStates)

          clientNextN
            :: SingQueueF CSP.F q -- Queue of requests inflight.
            -> LedgerStateHistory
            -> CSP.ClientStNext (BlockInMode CardanoMode) ChainPoint ChainTip q IO ()
          clientNextN q knownLedgerStates =
            CSP.ClientStNext {
                CSP.recvMsgRollForward = \blockInMode@(BlockInMode block@(Block (BlockHeader slotNo _ currBlockNo) _) _era) serverChainTip -> do
                  let newLedgerStateE = applyBlock
                        env
                        (maybe
                          (error "Impossible! Missing Ledger state")
                          (\(_,(ledgerState, _),_) -> ledgerState)
                          (Seq.lookup 0 knownLedgerStates)
                        )
                        validationMode
                        block
                  case newLedgerStateE of
                    Left err -> clientIdle_DoneN q (Just err)
                    Right newLedgerState -> do
                      let (knownLedgerStates', committedStates) = pushLedgerState env knownLedgerStates slotNo newLedgerState blockInMode
                          newClientTip = At currBlockNo
                          newServerTip = fromChainTip serverChainTip
                      forM_ committedStates $ \(_, (ledgerState, ledgerEvents), currBlockMay) -> case currBlockMay of
                          Origin -> return ()
                          At currBlock -> do
                            newState <- accumulate
                              env
                              ledgerState
                              ledgerEvents
                              currBlock
                              =<< readIORef stateIORef
                            writeIORef stateIORef newState
                      if newClientTip == newServerTip
                        then  clientIdle_DoneN q Nothing
                        else return (clientIdle_RequestMoreN newClientTip newServerTip q knownLedgerStates')
              , CSP.recvMsgRollBackward = \chainPoint serverChainTip -> do
                  let newClientTip = Origin -- We don't actually keep track of blocks so we temporarily "forget" the tip.
                      newServerTip = fromChainTip serverChainTip
                      truncatedKnownLedgerStates = case chainPoint of
                          ChainPointAtGenesis -> initialLedgerStateHistory
                          ChainPoint slotNo _ -> rollBackLedgerStateHist knownLedgerStates slotNo
                  return (clientIdle_RequestMoreN newClientTip newServerTip q truncatedKnownLedgerStates)
              }

          clientIdle_DoneN
            :: SingQueueF CSP.F q -- Queue of requests inflight.
            -> Maybe LedgerStateError -- Return value (maybe an error)
            -> IO (CSP.ClientPipelinedStIdle (BlockInMode CardanoMode) ChainPoint ChainTip q IO ())
          clientIdle_DoneN q errorMay = case q of
            SingConsF CSP.FCanAwait  q' -> return (CSP.CollectResponse Nothing (clientNext_DoneN q' errorMay)) -- Ignore remaining message responses
            SingConsF CSP.FMustReply q' -> return (CSP.CollectResponse Nothing (clientNext_DoneN q' errorMay)) -- Ignore remaining message responses
            SingEmptyF -> do
              writeIORef errorIORef errorMay
              return (CSP.SendMsgDone ())

          clientNext_DoneN
            :: SingQueueF CSP.F q -- Queue of requests inflight.
            -> Maybe LedgerStateError -- Return value (maybe an error)
            -> CSP.ClientStNext (BlockInMode CardanoMode) ChainPoint ChainTip q IO ()
          clientNext_DoneN q errorMay =
            CSP.ClientStNext {
                CSP.recvMsgRollForward = \_ _ -> clientIdle_DoneN q errorMay
              , CSP.recvMsgRollBackward = \_ _ -> clientIdle_DoneN q errorMay
              }

          fromChainTip :: ChainTip -> WithOrigin BlockNo
          fromChainTip ct = case ct of
            ChainTipAtGenesis -> Origin
            ChainTip _ _ bno -> At bno

-- | Wrap a 'ChainSyncClient' with logic that tracks the ledger state.
chainSyncClientWithLedgerState
  :: forall m a.
     Monad m
  => Env
  -> LedgerState
  -- ^ Initial ledger state
  -> ValidationMode
  -> CS.ChainSyncClient (BlockInMode CardanoMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
                        ChainPoint
                        ChainTip
                        m
                        a
  -- ^ A client to wrap. The block is annotated with a 'Either LedgerStateError
  -- LedgerState'. This is either an error from validating a block or
  -- the current 'LedgerState' from applying the current block. If we
  -- trust the node, then we generally expect blocks to validate. Also note that
  -- after a block fails to validate we may still roll back to a validated
  -- block, in which case the valid 'LedgerState' will be passed here again.
  -> CS.ChainSyncClient (BlockInMode CardanoMode)
                        ChainPoint
                        ChainTip
                        m
                        a
  -- ^ A client that acts just like the wrapped client but doesn't require the
  -- 'LedgerState' annotation on the block type.
chainSyncClientWithLedgerState env ledgerState0 validationMode =
    CS.mapChainSyncClientSt id id id forward backward (Right initialLedgerStateHistory)
  where
    -- called on every 'MsgRollForward'
    forward :: HistoryState
            -> BlockInMode CardanoMode
            -> ( (BlockInMode CardanoMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
               , HistoryState
               )
    forward state@(Left err) blkInMode = ((blkInMode, Left err), state)
    forward (Right history)  blkInMode@(BlockInMode blk@(Block (BlockHeader slotNo _ _) _) _) =
      let newLedgerStateE = case Seq.lookup 0 history of
            Nothing -> error "Impossible! History should always be non-empty"
            Just (_, Left err, _) -> Left err
            Just (_, Right (oldLedgerState, _), _) -> applyBlock
                  env
                  oldLedgerState
                  validationMode
                  blk
          (history', _) = pushLedgerState env history slotNo newLedgerStateE blkInMode
      in ((blkInMode, newLedgerStateE), Right history')

    -- called on every 'MsgRollBackward'
    backward :: HistoryState -> ChainPoint -> HistoryState
    backward state@Left {} _ = state
    backward (Right history) point =
      let oldestSlot = case history of
            _ Seq.:|> (s, _, _) -> s
            Seq.Empty -> error "Impossible! History should always be non-empty"
          state' :: HistoryState
          state' =
            (\h -> if Seq.null h
                   then Left (InvalidRollback oldestSlot point)
                   else Right h
            ) $ case point of
                  ChainPointAtGenesis -> initialLedgerStateHistory
                  ChainPoint slotNo _ -> rollBackLedgerStateHist history slotNo
      in state'

    initialLedgerStateHistory :: History (Either LedgerStateError LedgerStateEvents)
    initialLedgerStateHistory = Seq.singleton (0, Right (ledgerState0, []), Origin)

-- | See 'chainSyncClientWithLedgerState'.
chainSyncClientPipelinedWithLedgerState
  :: forall m a.
     Monad m
  => Env
  -> LedgerState
  -> ValidationMode
  -> CSP.ChainSyncClientPipelined
                        (BlockInMode CardanoMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
                        ChainPoint
                        ChainTip
                        m
                        a
  -> CSP.ChainSyncClientPipelined
                        (BlockInMode CardanoMode)
                        ChainPoint
                        ChainTip
                        m
                        a
chainSyncClientPipelinedWithLedgerState env ledgerState0 validationMode =
    CSP.mapChainSyncClientPipelinedSt id id id forward backward (Right initialLedgerStateHistory)
  where
    -- called on every 'MsgRollForward'
    forward :: HistoryState
            -> BlockInMode CardanoMode
            -> ( (BlockInMode CardanoMode, Either LedgerStateError (LedgerState, [LedgerEvent]))
               , HistoryState
               )
    forward state@(Left err) blkInMode = ((blkInMode, Left err), state)
    forward (Right history)  blkInMode@(BlockInMode blk@(Block (BlockHeader slotNo _ _) _) _) =
      let newLedgerStateE = case Seq.lookup 0 history of
            Nothing -> error "Impossible! History should always be non-empty"
            Just (_, Left err, _) -> Left err
            Just (_, Right (oldLedgerState, _), _) -> applyBlock
                  env
                  oldLedgerState
                  validationMode
                  blk
          (history', _) = pushLedgerState env history slotNo newLedgerStateE blkInMode
      in ((blkInMode, newLedgerStateE), Right history')

    -- called on every 'MsgRollBackward'
    backward :: HistoryState -> ChainPoint -> HistoryState
    backward state@Left {} _ = state
    backward (Right history) point =
      let oldestSlot = case history of
            _ Seq.:|> (s, _, _) -> s
            Seq.Empty -> error "Impossible! History should always be non-empty"
          state' :: HistoryState
          state' =
            (\h -> if Seq.null h
                   then Left (InvalidRollback oldestSlot point)
                   else Right h
            ) $ case point of
                  ChainPointAtGenesis -> initialLedgerStateHistory
                  ChainPoint slotNo _ -> rollBackLedgerStateHist history slotNo
      in state'

    initialLedgerStateHistory :: History (Either LedgerStateError LedgerStateEvents)
    initialLedgerStateHistory = Seq.singleton (0, Right (ledgerState0, []), Origin)

-- | A history of k (security parameter) recent ledger states. The head is the
-- most recent item. Elements are:
--
-- * Slot number that a new block occurred
-- * The ledger state and events after applying the new block
-- * The new block
--
type LedgerStateHistory = History LedgerStateEvents
type History a = Seq (SlotNo, a, WithOrigin (BlockInMode CardanoMode))
type HistoryState = Either LedgerStateError (History (Either LedgerStateError LedgerStateEvents))

-- | Add a new ledger state to the history
pushLedgerState
  :: Env                -- ^ Environment used to get the security param, k.
  -> History a          -- ^ History of k items.
  -> SlotNo             -- ^ Slot number of the new item.
  -> a                  -- ^ New item to add to the history
  -> BlockInMode CardanoMode
                        -- ^ The block that (when applied to the previous
                        -- item) resulted in the new item.
  -> (History a, History a)
  -- ^ ( The new history with the new item appended
  --   , Any existing items that are now past the security parameter
  --      and hence can no longer be rolled back.
  --   )
pushLedgerState env hist sn st block
  = Seq.splitAt
      (fromIntegral $ envSecurityParam env + 1)
      ((sn, st, At block) Seq.:<| hist)

rollBackLedgerStateHist :: History a -> SlotNo -> History a
rollBackLedgerStateHist hist maxInc = Seq.dropWhileL ((> maxInc) . (\(x,_,_) -> x)) hist

--------------------------------------------------------------------------------
-- Everything below was copied/adapted from db-sync                           --
--------------------------------------------------------------------------------

genesisConfigToEnv
  :: GenesisConfig
  -> Either GenesisConfigError Env
genesisConfigToEnv
  -- enp
  genCfg =
    case genCfg of
      GenesisCardano _ bCfg sCfg _ _
        | Cardano.Crypto.ProtocolMagic.unProtocolMagicId (Cardano.Chain.Genesis.configProtocolMagicId bCfg) /= Ledger.sgNetworkMagic (scConfig sCfg) ->
            Left . NECardanoConfig $
              mconcat
                [ "ProtocolMagicId ", textShow (Cardano.Crypto.ProtocolMagic.unProtocolMagicId $ Cardano.Chain.Genesis.configProtocolMagicId bCfg)
                , " /= ", textShow (Ledger.sgNetworkMagic $ scConfig sCfg)
                ]
        | Cardano.Chain.Genesis.gdStartTime (Cardano.Chain.Genesis.configGenesisData bCfg) /= Ledger.sgSystemStart (scConfig sCfg) ->
            Left . NECardanoConfig $
              mconcat
                [ "SystemStart ", textShow (Cardano.Chain.Genesis.gdStartTime $ Cardano.Chain.Genesis.configGenesisData bCfg)
                , " /= ", textShow (Ledger.sgSystemStart $ scConfig sCfg)
                ]
        | otherwise ->
            let
              topLevelConfig = Consensus.pInfoConfig $ fst $ mkProtocolInfoCardano genCfg
            in
            Right $ Env
                  { envLedgerConfig = Consensus.topLevelConfigLedger topLevelConfig
                  , envProtocolConfig = Consensus.topLevelConfigProtocol topLevelConfig
                  }

readNodeConfig :: NodeConfigFile 'In -> ExceptT Text IO NodeConfig
readNodeConfig (File ncf) = do
    ncfg <- (except . parseNodeConfig) =<< readByteString ncf "node"
    return ncfg
      { ncByronGenesisFile = mapFile (mkAdjustPath ncf) (ncByronGenesisFile ncfg)
      , ncShelleyGenesisFile = mapFile (mkAdjustPath ncf) (ncShelleyGenesisFile ncfg)
      , ncAlonzoGenesisFile = mapFile (mkAdjustPath ncf) (ncAlonzoGenesisFile ncfg)
      , ncConwayGenesisFile = mapFile (mkAdjustPath ncf) (ncConwayGenesisFile ncfg)
      }

data NodeConfig = NodeConfig
  { ncPBftSignatureThreshold :: !(Maybe Double)
  , ncByronGenesisFile :: !(File ByronGenesisConfig 'In)
  , ncByronGenesisHash :: !GenesisHashByron
  , ncShelleyGenesisFile :: !(File ShelleyGenesisConfig 'In)
  , ncShelleyGenesisHash :: !GenesisHashShelley
  , ncAlonzoGenesisFile :: !(File AlonzoGenesis 'In)
  , ncAlonzoGenesisHash :: !GenesisHashAlonzo
  , ncConwayGenesisFile :: !(File ConwayGenesisConfig 'In)
  , ncConwayGenesisHash :: !GenesisHashConway
  , ncRequiresNetworkMagic :: !Cardano.Crypto.RequiresNetworkMagic
  , ncByronProtocolVersion :: !Cardano.Chain.Update.ProtocolVersion

  -- Per-era parameters for the hardfok transitions:
  , ncByronToShelley   :: !(Consensus.ProtocolTransitionParams
                              Byron.ByronBlock
                              (Shelley.ShelleyBlock (TPraos Shelley.StandardCrypto) Shelley.StandardShelley)
                           )
  , ncShelleyToAllegra :: !(Consensus.ProtocolTransitionParams
                              (Shelley.ShelleyBlock (TPraos Shelley.StandardCrypto) Shelley.StandardShelley)
                              (Shelley.ShelleyBlock (TPraos Shelley.StandardCrypto) Shelley.StandardAllegra)
                           )
  , ncAllegraToMary    :: !(Consensus.ProtocolTransitionParams
                              (Shelley.ShelleyBlock (TPraos Shelley.StandardCrypto) Shelley.StandardAllegra)
                              (Shelley.ShelleyBlock (TPraos Shelley.StandardCrypto) Shelley.StandardMary)
                           )
  , ncMaryToAlonzo     :: !Consensus.TriggerHardFork
  , ncAlonzoToBabbage  :: !Consensus.TriggerHardFork
  , ncBabbageToConway  :: !Consensus.TriggerHardFork
  }

instance FromJSON NodeConfig where
  parseJSON =
      Aeson.withObject "NodeConfig" parse
    where
      parse :: Object -> Parser NodeConfig
      parse o =
        NodeConfig
          <$> o .:? "PBftSignatureThreshold"
          <*> fmap File (o .: "ByronGenesisFile")
          <*> fmap GenesisHashByron (o .: "ByronGenesisHash")
          <*> fmap File (o .: "ShelleyGenesisFile")
          <*> fmap GenesisHashShelley (o .: "ShelleyGenesisHash")
          <*> fmap File (o .: "AlonzoGenesisFile")
          <*> fmap GenesisHashAlonzo (o .: "AlonzoGenesisHash")
          <*> fmap File (o .: "ConwayGenesisFile")
          <*> fmap GenesisHashConway (o .: "ConwayGenesisHash")
          <*> o .: "RequiresNetworkMagic"
          <*> parseByronProtocolVersion o
          <*> (Consensus.ProtocolTransitionParamsByronToShelley emptyFromByronTranslationContext
                 <$> parseShelleyHardForkEpoch o)
          <*> (Consensus.ProtocolTransitionParamsIntraShelley ()
                 <$> parseAllegraHardForkEpoch o)
          <*> (Consensus.ProtocolTransitionParamsIntraShelley ()
                 <$> parseMaryHardForkEpoch o)
          <*> parseAlonzoHardForkEpoch o
          <*> parseBabbageHardForkEpoch o
          <*> parseConwayHardForkEpoch o

      parseByronProtocolVersion :: Object -> Parser Cardano.Chain.Update.ProtocolVersion
      parseByronProtocolVersion o =
        Cardano.Chain.Update.ProtocolVersion
          <$> o .: "LastKnownBlockVersion-Major"
          <*> o .: "LastKnownBlockVersion-Minor"
          <*> o .: "LastKnownBlockVersion-Alt"

      parseShelleyHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseShelleyHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestShelleyHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 2 -- Mainnet default
          ]

      parseAllegraHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseAllegraHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestAllegraHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 3 -- Mainnet default
          ]

      parseMaryHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseMaryHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestMaryHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 4 -- Mainnet default
          ]

      parseAlonzoHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseAlonzoHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestAlonzoHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 5 -- Mainnet default
          ]
      parseBabbageHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseBabbageHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestBabbageHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 7 -- Mainnet default
          ]

      parseConwayHardForkEpoch :: Object -> Parser Consensus.TriggerHardFork
      parseConwayHardForkEpoch o =
        asum
          [ Consensus.TriggerHardForkAtEpoch <$> o .: "TestConwayHardForkAtEpoch"
          , pure $ Consensus.TriggerHardForkAtVersion 9 -- Mainnet default
          ]

      ----------------------------------------------------------------------
      -- WARNING When adding new entries above, be aware that if there is an
      -- intra-era fork, then the numbering is not consecutive.
      ----------------------------------------------------------------------

parseNodeConfig :: ByteString -> Either Text NodeConfig
parseNodeConfig bs =
  case Yaml.decodeEither' bs of
    Left err -> Left $ "Error parsing node config: " <> textShow err
    Right nc -> Right nc

mkAdjustPath :: FilePath -> (FilePath -> FilePath)
mkAdjustPath nodeConfigFilePath fp = takeDirectory nodeConfigFilePath </> fp

readByteString :: FilePath -> Text -> ExceptT Text IO ByteString
readByteString fp cfgType = ExceptT $
  catch (Right <$> BS.readFile fp) $ \(_ :: IOException) ->
    return $ Left $ mconcat
      [ "Cannot read the ", cfgType, " configuration file at : ", Text.pack fp ]

initLedgerStateVar :: GenesisConfig -> LedgerState
initLedgerStateVar genesisConfig = LedgerState
  { clsState = Ledger.ledgerState $ Consensus.pInfoInitLedger $ fst protocolInfo
  }
  where
    protocolInfo = mkProtocolInfoCardano genesisConfig

newtype LedgerState = LedgerState
  { clsState :: Ledger.LedgerState
                  (HFC.HardForkBlock
                    (Consensus.CardanoEras Consensus.StandardCrypto))
  }

encodeLedgerState :: LedgerState -> CBOR.Encoding
encodeLedgerState (LedgerState (HFC.HardForkLedgerState st)) =
  HFC.encodeTelescope
    (byron :* shelley :* allegra :* mary :* alonzo :* babbage :* conway :* Nil)
    st
  where
    byron = fn (K . Byron.encodeByronLedgerState)
    shelley = fn (K . Shelley.encodeShelleyLedgerState)
    allegra = fn (K . Shelley.encodeShelleyLedgerState)
    mary = fn (K . Shelley.encodeShelleyLedgerState)
    alonzo = fn (K . Shelley.encodeShelleyLedgerState)
    babbage = fn (K . Shelley.encodeShelleyLedgerState)
    conway = fn (K . Shelley.encodeShelleyLedgerState)

decodeLedgerState :: forall s. CBOR.Decoder s LedgerState
decodeLedgerState =
  LedgerState . HFC.HardForkLedgerState
    <$> HFC.decodeTelescope (byron :* shelley :* allegra :* mary :* alonzo :* babbage :* conway :* Nil)
  where
    byron = Comp Byron.decodeByronLedgerState
    shelley = Comp Shelley.decodeShelleyLedgerState
    allegra = Comp Shelley.decodeShelleyLedgerState
    mary = Comp Shelley.decodeShelleyLedgerState
    alonzo = Comp Shelley.decodeShelleyLedgerState
    babbage = Comp Shelley.decodeShelleyLedgerState
    conway = Comp Shelley.decodeShelleyLedgerState

type LedgerStateEvents = (LedgerState, [LedgerEvent])

toLedgerStateEvents ::
  LedgerResult
    ( Shelley.LedgerState
        (HFC.HardForkBlock (Consensus.CardanoEras Shelley.StandardCrypto))
    )
    ( Shelley.LedgerState
        (HFC.HardForkBlock (Consensus.CardanoEras Shelley.StandardCrypto))
    ) ->
  LedgerStateEvents
toLedgerStateEvents lr = (ledgerState, ledgerEvents)
  where
    ledgerState = LedgerState (lrResult lr)
    ledgerEvents = mapMaybe (toLedgerEvent
      . WrapLedgerEvent @(HFC.HardForkBlock (Consensus.CardanoEras Shelley.StandardCrypto)))
      $ lrEvents lr

-- Usually only one constructor, but may have two when we are preparing for a HFC event.
data GenesisConfig
  = GenesisCardano
      !NodeConfig
      !Cardano.Chain.Genesis.Config
      !ShelleyConfig
      !AlonzoGenesis
      !(ConwayGenesis Shelley.StandardCrypto)

newtype LedgerStateDir = LedgerStateDir
  {  unLedgerStateDir :: FilePath
  } deriving Show

newtype NetworkName = NetworkName
  { unNetworkName :: Text
  } deriving Show

type NodeConfigFile = File NodeConfig

mkProtocolInfoCardano ::
  GenesisConfig ->
  (Consensus.ProtocolInfo
    (HFC.HardForkBlock
            (Consensus.CardanoEras Consensus.StandardCrypto))
  , IO [BlockForging IO (HFC.HardForkBlock
                              (Consensus.CardanoEras Consensus.StandardCrypto))])
mkProtocolInfoCardano (GenesisCardano dnc byronGenesis shelleyGenesis alonzoGenesis conwayGenesis)
  = Consensus.protocolInfoCardano Consensus.CardanoProtocolParams
      { Consensus.paramsByron =
          Consensus.ProtocolParamsByron
            { Consensus.byronGenesis = byronGenesis
            , Consensus.byronPbftSignatureThreshold = Consensus.PBftSignatureThreshold <$> ncPBftSignatureThreshold dnc
            , Consensus.byronProtocolVersion = ncByronProtocolVersion dnc
            , Consensus.byronSoftwareVersion = Byron.softwareVersion
            , Consensus.byronLeaderCredentials = Nothing
            , Consensus.byronMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsShelleyBased =
          Consensus.ProtocolParamsShelleyBased
            { Consensus.shelleyBasedGenesis = scConfig shelleyGenesis
            , Consensus.shelleyBasedInitialNonce = shelleyPraosNonce shelleyGenesis
            , Consensus.shelleyBasedLeaderCredentials = []
            }
      , Consensus.paramsShelley =
          Consensus.ProtocolParamsShelley
            { Consensus.shelleyProtVer = ProtVer (natVersion @3) 0
            , Consensus.shelleyMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsAllegra =
          Consensus.ProtocolParamsAllegra
            { Consensus.allegraProtVer = ProtVer (natVersion @4) 0
            , Consensus.allegraMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsMary =
          Consensus.ProtocolParamsMary
            { Consensus.maryProtVer = ProtVer (natVersion @5) 0
            , Consensus.maryMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsAlonzo =
          Consensus.ProtocolParamsAlonzo
            { Consensus.alonzoProtVer = ProtVer (natVersion @7) 0
            , Consensus.alonzoMaxTxCapacityOverrides  = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsBabbage =
          Consensus.ProtocolParamsBabbage
            { Consensus.babbageProtVer = ProtVer (natVersion @9) 0
            , Consensus.babbageMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.paramsConway =
          Consensus.ProtocolParamsConway
            { Consensus.conwayProtVer = ProtVer (natVersion @10) 0
            , Consensus.conwayMaxTxCapacityOverrides = TxLimits.mkOverrides TxLimits.noOverridesMeasure
            }
      , Consensus.transitionParamsByronToShelley =
          ncByronToShelley dnc
      , Consensus.transitionParamsShelleyToAllegra =
          ncShelleyToAllegra dnc
      , Consensus.transitionParamsAllegraToMary =
          ncAllegraToMary dnc
      , Consensus.transitionParamsMaryToAlonzo =
          Consensus.ProtocolTransitionParamsIntraShelley
            { Consensus.transitionIntraShelleyTranslationContext = alonzoGenesis
            , Consensus.transitionIntraShelleyTrigger            = ncMaryToAlonzo dnc
            }
      , Consensus.transitionParamsAlonzoToBabbage =
          Consensus.ProtocolTransitionParamsIntraShelley
            { Consensus.transitionIntraShelleyTranslationContext = ()
            , Consensus.transitionIntraShelleyTrigger            = ncAlonzoToBabbage dnc
            }
      , Consensus.transitionParamsBabbageToConway =
          Consensus.ProtocolTransitionParamsIntraShelley
            { Consensus.transitionIntraShelleyTranslationContext = conwayGenesis
            , Consensus.transitionIntraShelleyTrigger            = ncBabbageToConway dnc
            }
      }

-- | Compute the Nonce from the ShelleyGenesis file.
shelleyPraosNonce :: ShelleyConfig -> Ledger.Nonce
shelleyPraosNonce sCfg =
  Ledger.Nonce (Cardano.Crypto.Hash.Class.castHash . unGenesisHashShelley $ scGenesisHash sCfg)

readCardanoGenesisConfig
        :: NodeConfig
        -> ExceptT GenesisConfigError IO GenesisConfig
readCardanoGenesisConfig enc =
  GenesisCardano enc
    <$> readByronGenesisConfig enc
    <*> readShelleyGenesisConfig enc
    <*> readAlonzoGenesisConfig enc
    <*> readConwayGenesisConfig enc

data GenesisConfigError
  = NEError !Text
  | NEByronConfig !FilePath !Cardano.Chain.Genesis.ConfigurationError
  | NEShelleyConfig !FilePath !Text
  | NEAlonzoConfig !FilePath !Text
  | NEConwayConfig !FilePath !Text
  | NECardanoConfig !Text
  deriving Show

instance Exception GenesisConfigError

renderGenesisConfigError :: GenesisConfigError -> Text
renderGenesisConfigError ne =
  case ne of
    NEError t -> "Error: " <> t
    NEByronConfig fp ce ->
      mconcat
        [ "Failed reading Byron genesis file ", textShow fp, ": ", textShow ce
        ]
    NEShelleyConfig fp txt ->
      mconcat
        [ "Failed reading Shelley genesis file ", textShow fp, ": ", txt
        ]
    NEAlonzoConfig fp txt ->
      mconcat
        [ "Failed reading Alonzo genesis file ", textShow fp, ": ", txt
        ]
    NEConwayConfig fp txt ->
      mconcat
        [ "Failed reading Conway genesis file ", textShow fp, ": ", txt
        ]
    NECardanoConfig err ->
      mconcat
        [ "With Cardano protocol, Byron/Shelley config mismatch:\n"
        , "   ", err
        ]

readByronGenesisConfig
        :: NodeConfig
        -> ExceptT GenesisConfigError IO Cardano.Chain.Genesis.Config
readByronGenesisConfig enc = do
  let file = unFile $ ncByronGenesisFile enc
  genHash <- firstExceptT NEError
                . hoistEither
                $ Cardano.Crypto.Hashing.decodeAbstractHash (unGenesisHashByron $ ncByronGenesisHash enc)
  firstExceptT (NEByronConfig file)
                $ Cardano.Chain.Genesis.mkConfigFromFile (ncRequiresNetworkMagic enc) file genHash

readShelleyGenesisConfig
    :: NodeConfig
    -> ExceptT GenesisConfigError IO ShelleyConfig
readShelleyGenesisConfig enc = do
  let file = ncShelleyGenesisFile enc
  firstExceptT (NEShelleyConfig (unFile file) . renderShelleyGenesisError)
    $ readShelleyGenesis file (ncShelleyGenesisHash enc)

readAlonzoGenesisConfig
    :: NodeConfig
    -> ExceptT GenesisConfigError IO AlonzoGenesis
readAlonzoGenesisConfig enc = do
  let file = ncAlonzoGenesisFile enc
  firstExceptT (NEAlonzoConfig (unFile file) . renderAlonzoGenesisError)
    $ readAlonzoGenesis file (ncAlonzoGenesisHash enc)

readConwayGenesisConfig
    :: NodeConfig
    -> ExceptT GenesisConfigError IO (ConwayGenesis Shelley.StandardCrypto)
readConwayGenesisConfig enc = do
  let file = ncConwayGenesisFile enc
  firstExceptT (NEConwayConfig (unFile file) . renderConwayGenesisError)
    $ readConwayGenesis file (ncConwayGenesisHash enc)

readShelleyGenesis
    :: ShelleyGenesisFile 'In
    -> GenesisHashShelley
    -> ExceptT ShelleyGenesisError IO ShelleyConfig
readShelleyGenesis (File file) expectedGenesisHash = do
    content <- handleIOExceptT (ShelleyGenesisReadError file . textShow) $ BS.readFile file
    let genesisHash = GenesisHashShelley (Cardano.Crypto.Hash.Class.hashWith id content)
    checkExpectedGenesisHash genesisHash
    genesis <- firstExceptT (ShelleyGenesisDecodeError file . Text.pack)
                  . hoistEither
                  $ Aeson.eitherDecodeStrict' content
    pure $ ShelleyConfig genesis genesisHash
  where
    checkExpectedGenesisHash :: GenesisHashShelley -> ExceptT ShelleyGenesisError IO ()
    checkExpectedGenesisHash actual =
      when (actual /= expectedGenesisHash) $
        left (ShelleyGenesisHashMismatch actual expectedGenesisHash)

data ShelleyGenesisError
     = ShelleyGenesisReadError !FilePath !Text
     | ShelleyGenesisHashMismatch !GenesisHashShelley !GenesisHashShelley -- actual, expected
     | ShelleyGenesisDecodeError !FilePath !Text
     deriving Show

instance Exception ShelleyGenesisError

renderShelleyGenesisError :: ShelleyGenesisError -> Text
renderShelleyGenesisError sge =
    case sge of
      ShelleyGenesisReadError fp err ->
        mconcat
          [ "There was an error reading the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

      ShelleyGenesisHashMismatch actual expected ->
        mconcat
          [ "Wrong Shelley genesis file: the actual hash is ", renderHash (unGenesisHashShelley actual)
          , ", but the expected Shelley genesis hash given in the node "
          , "configuration file is ", renderHash (unGenesisHashShelley expected), "."
          ]

      ShelleyGenesisDecodeError fp err ->
        mconcat
          [ "There was an error parsing the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

readAlonzoGenesis
    :: File AlonzoGenesis 'In
    -> GenesisHashAlonzo
    -> ExceptT AlonzoGenesisError IO AlonzoGenesis
readAlonzoGenesis (File file) expectedGenesisHash = do
    content <- handleIOExceptT (AlonzoGenesisReadError file . textShow) $ BS.readFile file
    let genesisHash = GenesisHashAlonzo (Cardano.Crypto.Hash.Class.hashWith id content)
    checkExpectedGenesisHash genesisHash
    firstExceptT (AlonzoGenesisDecodeError file . Text.pack)
                  . hoistEither
                  $ Aeson.eitherDecodeStrict' content
  where
    checkExpectedGenesisHash :: GenesisHashAlonzo -> ExceptT AlonzoGenesisError IO ()
    checkExpectedGenesisHash actual =
      when (actual /= expectedGenesisHash) $
        left (AlonzoGenesisHashMismatch actual expectedGenesisHash)

data AlonzoGenesisError
     = AlonzoGenesisReadError !FilePath !Text
     | AlonzoGenesisHashMismatch !GenesisHashAlonzo !GenesisHashAlonzo -- actual, expected
     | AlonzoGenesisDecodeError !FilePath !Text
     deriving Show

instance Exception AlonzoGenesisError

renderAlonzoGenesisError :: AlonzoGenesisError -> Text
renderAlonzoGenesisError sge =
    case sge of
      AlonzoGenesisReadError fp err ->
        mconcat
          [ "There was an error reading the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

      AlonzoGenesisHashMismatch actual expected ->
        mconcat
          [ "Wrong Alonzo genesis file: the actual hash is ", renderHash (unGenesisHashAlonzo actual)
          , ", but the expected Alonzo genesis hash given in the node "
          , "configuration file is ", renderHash (unGenesisHashAlonzo expected), "."
          ]

      AlonzoGenesisDecodeError fp err ->
        mconcat
          [ "There was an error parsing the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

readConwayGenesis
    :: ConwayGenesisFile 'In
    -> GenesisHashConway
    -> ExceptT ConwayGenesisError IO (ConwayGenesis Shelley.StandardCrypto)
readConwayGenesis (File file) expectedGenesisHash = do
    content <- handleIOExceptT (ConwayGenesisReadError file . textShow) $ BS.readFile file
    let genesisHash = GenesisHashConway (Cardano.Crypto.Hash.Class.hashWith id content)
    checkExpectedGenesisHash genesisHash
    firstExceptT (ConwayGenesisDecodeError file . Text.pack)
                  . hoistEither
                  $ Aeson.eitherDecodeStrict' content
  where
    checkExpectedGenesisHash :: GenesisHashConway -> ExceptT ConwayGenesisError IO ()
    checkExpectedGenesisHash actual =
      when (actual /= expectedGenesisHash) $
        left (ConwayGenesisHashMismatch actual expectedGenesisHash)

data ConwayGenesisError
     = ConwayGenesisReadError !FilePath !Text
     | ConwayGenesisHashMismatch !GenesisHashConway !GenesisHashConway -- actual, expected
     | ConwayGenesisDecodeError !FilePath !Text
     deriving Show

instance Exception ConwayGenesisError

renderConwayGenesisError :: ConwayGenesisError -> Text
renderConwayGenesisError sge =
    case sge of
      ConwayGenesisReadError fp err ->
        mconcat
          [ "There was an error reading the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

      ConwayGenesisHashMismatch actual expected ->
        mconcat
          [ "Wrong Conway genesis file: the actual hash is ", renderHash (unGenesisHashConway actual)
          , ", but the expected Conway genesis hash given in the node "
          , "configuration file is ", renderHash (unGenesisHashConway expected), "."
          ]

      ConwayGenesisDecodeError fp err ->
        mconcat
          [ "There was an error parsing the genesis file: ", Text.pack fp
          , " Error: ", err
          ]

renderHash :: Cardano.Crypto.Hash.Class.Hash Cardano.Crypto.Hash.Blake2b.Blake2b_256 ByteString -> Text
renderHash h = Text.decodeUtf8 $ Base16.encode (Cardano.Crypto.Hash.Class.hashToBytes h)

newtype StakeCred
  = StakeCred { _unStakeCred :: Ledger.Credential 'Ledger.Staking Consensus.StandardCrypto }
  deriving (Eq, Ord)

data Env = Env
  { envLedgerConfig :: HFC.HardForkLedgerConfig (Consensus.CardanoEras Shelley.StandardCrypto)
  , envProtocolConfig :: TPraos.ConsensusConfig (HFC.HardForkProtocol (Consensus.CardanoEras Shelley.StandardCrypto))
  }

envSecurityParam :: Env -> Word64
envSecurityParam env = k
  where
    Consensus.SecurityParam k
      = HFC.hardForkConsensusConfigK
      $ envProtocolConfig env

-- | How to do validation when applying a block to a ledger state.
data ValidationMode
  -- | Do all validation implied by the ledger layer's 'applyBlock`.
  = FullValidation
  -- | Only check that the previous hash from the block matches the head hash of
  -- the ledger state.
  | QuickValidation

-- The function 'tickThenReapply' does zero validation, so add minimal
-- validation ('blockPrevHash' matches the tip hash of the 'LedgerState'). This
-- was originally for debugging but the check is cheap enough to keep.
applyBlock'
  :: Env
  -> LedgerState
  -> ValidationMode
  ->  HFC.HardForkBlock
            (Consensus.CardanoEras Consensus.StandardCrypto)
  -> Either LedgerStateError LedgerStateEvents
applyBlock' env oldState validationMode block = do
  let config = envLedgerConfig env
      stateOld = clsState oldState
  case validationMode of
    FullValidation -> tickThenApply config block stateOld
    QuickValidation -> tickThenReapplyCheckHash config block stateOld

applyBlockWithEvents
  :: Env
  -> LedgerState
  -> Bool
  -- ^ True to validate
  ->  HFC.HardForkBlock
            (Consensus.CardanoEras Consensus.StandardCrypto)
  -> Either LedgerStateError LedgerStateEvents
applyBlockWithEvents env oldState enableValidation block = do
  let config = envLedgerConfig env
      stateOld = clsState oldState
  if enableValidation
    then tickThenApply config block stateOld
    else tickThenReapplyCheckHash config block stateOld

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from
-- the block matches the head hash of the ledger state.
tickThenReapplyCheckHash
    :: HFC.HardForkLedgerConfig
        (Consensus.CardanoEras Shelley.StandardCrypto)
    -> Consensus.CardanoBlock Consensus.StandardCrypto
    -> Shelley.LedgerState
        (HFC.HardForkBlock
            (Consensus.CardanoEras Shelley.StandardCrypto))
    -> Either LedgerStateError LedgerStateEvents
tickThenReapplyCheckHash cfg block lsb =
  if Consensus.blockPrevHash block == Ledger.ledgerTipHash lsb
    then Right . toLedgerStateEvents
          $ Ledger.tickThenReapplyLedgerResult cfg block lsb
    else Left $ ApplyBlockHashMismatch $ mconcat
                  [ "Ledger state hash mismatch. Ledger head is slot "
                  , textShow
                      $ Slot.unSlotNo
                      $ Slot.fromWithOrigin
                          (Slot.SlotNo 0)
                          (Ledger.ledgerTipSlot lsb)
                  , " hash "
                  , renderByteArray
                      $ unChainHash
                      $ Ledger.ledgerTipHash lsb
                  , " but block previous hash is "
                  , renderByteArray (unChainHash $ Consensus.blockPrevHash block)
                  , " and block current hash is "
                  , renderByteArray
                      $ BSS.fromShort
                      $ HFC.getOneEraHash
                      $ Ouroboros.Network.Block.blockHash block
                  , "."
                  ]

-- Like 'Consensus.tickThenReapply' but also checks that the previous hash from
-- the block matches the head hash of the ledger state.
tickThenApply
    :: HFC.HardForkLedgerConfig
        (Consensus.CardanoEras Shelley.StandardCrypto)
    -> Consensus.CardanoBlock Consensus.StandardCrypto
    -> Shelley.LedgerState
        (HFC.HardForkBlock
            (Consensus.CardanoEras Shelley.StandardCrypto))
    -> Either LedgerStateError LedgerStateEvents
tickThenApply cfg block lsb
  = either (Left . ApplyBlockError) (Right . toLedgerStateEvents)
  $ runExcept
  $ Ledger.tickThenApplyLedgerResult cfg block lsb

renderByteArray :: ByteArrayAccess bin => bin -> Text
renderByteArray =
  Text.decodeUtf8 . Base16.encode . Data.ByteArray.convert

unChainHash :: Ouroboros.Network.Block.ChainHash (Consensus.CardanoBlock era) -> ByteString
unChainHash ch =
  case ch of
    Ouroboros.Network.Block.GenesisHash -> "genesis"
    Ouroboros.Network.Block.BlockHash bh -> BSS.fromShort (HFC.getOneEraHash bh)

data LeadershipError = LeaderErrDecodeLedgerStateFailure
                     | LeaderErrDecodeProtocolStateFailure (LB.ByteString, DecoderError)
                     | LeaderErrDecodeProtocolEpochStateFailure DecoderError
                     | LeaderErrGenesisSlot
                     | LeaderErrStakePoolHasNoStake PoolId
                     | LeaderErrStakeDistribUnstable
                         SlotNo
                         -- ^ Current slot
                         SlotNo
                         -- ^ Stable after
                         SlotNo
                         -- ^ Stability window size
                         SlotNo
                         -- ^ Predicted last slot of the epoch
                     | LeaderErrSlotRangeCalculationFailure Text
                     | LeaderErrCandidateNonceStillEvolving
                     deriving Show

instance Error LeadershipError where
  displayError LeaderErrDecodeLedgerStateFailure =
    "Failed to successfully decode ledger state"
  displayError (LeaderErrDecodeProtocolStateFailure (_, decErr)) =
    "Failed to successfully decode protocol state: " <> Text.unpack (LT.toStrict . toLazyText $ build decErr)
  displayError LeaderErrGenesisSlot =
    "Leadership schedule currently cannot be calculated from genesis"
  displayError (LeaderErrStakePoolHasNoStake poolId) =
    "The stake pool: " <> show poolId <> " has no stake"
  displayError (LeaderErrDecodeProtocolEpochStateFailure decoderError) =
    "Failed to successfully decode the current epoch state: " <> show decoderError
  displayError (LeaderErrStakeDistribUnstable curSlot stableAfterSlot stabWindow predictedLastSlot) =
    "The current stake distribution is currently unstable and therefore we cannot predict " <>
    "the following epoch's leadership schedule. Please wait until : " <> show stableAfterSlot <>
    " before running the leadership-schedule command again. \nCurrent slot: " <> show curSlot <>
    " \nStability window: " <> show stabWindow <>
    " \nCalculated last slot of current epoch: " <> show predictedLastSlot
  displayError (LeaderErrSlotRangeCalculationFailure e) =
    "Error while calculating the slot range: " <> Text.unpack e
  displayError LeaderErrCandidateNonceStillEvolving = "Candidate nonce is still evolving"

nextEpochEligibleLeadershipSlots
  :: forall era. ()
  => FromCBOR (Consensus.ChainDepState (Api.ConsensusProtocol era))
  => Consensus.PraosProtocolSupportsNode (Api.ConsensusProtocol era)
  => ShelleyBasedEra era
  -> ShelleyGenesis Shelley.StandardCrypto
  -> SerialisedCurrentEpochState era
  -- ^ We need the mark stake distribution in order to predict
  --   the following epoch's leadership schedule
  -> ProtocolState era
  -> PoolId
  -- ^ Potential slot leading stake pool
  -> SigningKey VrfKey
  -- ^ VRF signing key of the stake pool
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> EpochInfo (Either Text)
  -> (ChainTip, EpochNo)
  -> Either LeadershipError (Set SlotNo)
nextEpochEligibleLeadershipSlots sbe sGen serCurrEpochState ptclState poolid (VrfSigningKey vrfSkey) pp eInfo (cTip, currentEpoch) = do
  (_, currentEpochLastSlot) <- first LeaderErrSlotRangeCalculationFailure
                                 $ Slot.epochInfoRange eInfo currentEpoch

  (firstSlotOfEpoch, lastSlotofEpoch) <- first LeaderErrSlotRangeCalculationFailure
                  $ Slot.epochInfoRange eInfo (currentEpoch + 1)


  -- First we check if we are within 3k/f slots of the end of the current epoch.
  -- Why? Because the stake distribution is stable at this point.
  -- k is the security parameter
  -- f is the active slot coefficient
  let stabilityWindowR :: Rational
      stabilityWindowR = fromIntegral (3 * sgSecurityParam sGen) / Ledger.unboundRational (sgActiveSlotsCoeff sGen)
      stabilityWindowSlots :: SlotNo
      stabilityWindowSlots = fromIntegral @Word64 $ floor $ fromRational @Double stabilityWindowR
      stableStakeDistribSlot = currentEpochLastSlot - stabilityWindowSlots


  case cTip of
    ChainTipAtGenesis -> Left LeaderErrGenesisSlot
    ChainTip tip _ _ ->
      if tip > stableStakeDistribSlot
      then return ()
      else Left $ LeaderErrStakeDistribUnstable tip stableStakeDistribSlot stabilityWindowSlots currentEpochLastSlot

  chainDepState <- first LeaderErrDecodeProtocolStateFailure
                     $ decodeProtocolState ptclState

  -- We need the candidate nonce, the previous epoch's last block header hash
  -- and the extra entropy from the protocol parameters. We then need to combine them
  -- with the (⭒) operator.
  let Consensus.PraosNonces { Consensus.candidateNonce, Consensus.evolvingNonce } =
        Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState

  -- Let's do a nonce check. The candidate nonce and the evolving nonce should not be equal.
  when (evolvingNonce == candidateNonce)
   $ Left LeaderErrCandidateNonceStillEvolving

  -- Get the previous epoch's last block header hash nonce
  let previousLabNonce = Consensus.previousLabNonce (Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState)
      extraEntropy :: Nonce
      extraEntropy =
        caseShelleyToAlonzoOrBabbageEraOnwards
          (const (pp ^. Core.ppExtraEntropyL))
          (const Ledger.NeutralNonce)
          sbe

      nextEpochsNonce = candidateNonce ⭒ previousLabNonce ⭒ extraEntropy

  -- Then we get the "mark" snapshot. This snapshot will be used for the next
  -- epoch's leadership schedule.
  CurrentEpochState cEstate <- first LeaderErrDecodeProtocolEpochStateFailure $
                                decodeCurrentEpochState sbe serCurrEpochState

  let snapshot :: ShelleyAPI.SnapShot Shelley.StandardCrypto
      snapshot = ShelleyAPI.ssStakeMark $ withShelleyBasedEraConstraintsForLedger sbe $ ShelleyAPI.esSnapshots cEstate
      markSnapshotPoolDistr :: Map (SL.KeyHash 'SL.StakePool Shelley.StandardCrypto) (SL.IndividualPoolStake Shelley.StandardCrypto)
      markSnapshotPoolDistr = ShelleyAPI.unPoolDistr . ShelleyAPI.calculatePoolDistr $ snapshot

  let slotRangeOfInterest :: Core.EraPParams ledgerera => Core.PParams ledgerera -> Set SlotNo
      slotRangeOfInterest pp' = Set.filter
        (not . Ledger.isOverlaySlot firstSlotOfEpoch (pp' ^. Core.ppDG))
        $ Set.fromList [firstSlotOfEpoch .. lastSlotofEpoch]

  shelleyBasedEraConstraints sbe
    $ isLeadingSlotsTPraos (slotRangeOfInterest pp) poolid markSnapshotPoolDistr nextEpochsNonce vrfSkey f
 where
  globals = shelleyBasedEraConstraints sbe
              $ constructGlobals sGen eInfo $ pp ^. Core.ppProtocolVersionL

  f :: Ledger.ActiveSlotCoeff
  f = activeSlotCoeff globals


-- | Return slots a given stake pool operator is leading.
-- See Leader Value Calculation in the Shelley ledger specification.
-- We need the certified natural value from the VRF, active slot coefficient
-- and the stake proportion of the stake pool.
isLeadingSlotsTPraos :: forall v. ()
  => Crypto.Signable v Ledger.Seed
  => Crypto.VRFAlgorithm v
  => Crypto.ContextVRF v ~ ()
  => Set SlotNo
  -> PoolId
  -> Map (SL.KeyHash 'SL.StakePool Shelley.StandardCrypto) (SL.IndividualPoolStake Shelley.StandardCrypto)
  -> Consensus.Nonce
  -> Crypto.SignKeyVRF v
  -> Ledger.ActiveSlotCoeff
  -> Either LeadershipError (Set SlotNo)
isLeadingSlotsTPraos slotRangeOfInterest poolid snapshotPoolDistr eNonce vrfSkey activeSlotCoeff' = do
  let StakePoolKeyHash poolHash = poolid

  let certifiedVrf s = Crypto.evalCertified () (TPraos.mkSeed TPraos.seedL s eNonce) vrfSkey

  stakePoolStake <- maybe (Left $ LeaderErrStakePoolHasNoStake poolid) Right $
    ShelleyAPI.individualPoolStake <$> Map.lookup poolHash snapshotPoolDistr

  let isLeader s = TPraos.checkLeaderValue (Crypto.certifiedOutput (certifiedVrf s)) stakePoolStake activeSlotCoeff'

  return $ Set.filter isLeader slotRangeOfInterest

isLeadingSlotsPraos :: ()
  => Set SlotNo
  -> PoolId
  -> Map (SL.KeyHash 'SL.StakePool Shelley.StandardCrypto) (SL.IndividualPoolStake Shelley.StandardCrypto)
  -> Consensus.Nonce
  -> SL.SignKeyVRF Shelley.StandardCrypto
  -> Ledger.ActiveSlotCoeff
  -> Either LeadershipError (Set SlotNo)
isLeadingSlotsPraos slotRangeOfInterest poolid snapshotPoolDistr eNonce vrfSkey activeSlotCoeff' = do
  let StakePoolKeyHash poolHash = poolid

  stakePoolStake <- maybe (Left $ LeaderErrStakePoolHasNoStake poolid) Right $
    ShelleyAPI.individualPoolStake <$> Map.lookup poolHash snapshotPoolDistr

  let isLeader slotNo = checkLeaderNatValue certifiedNatValue stakePoolStake activeSlotCoeff'
        where rho = VRF.evalCertified () (mkInputVRF slotNo eNonce) vrfSkey
              certifiedNatValue = vrfLeaderValue (Proxy @Shelley.StandardCrypto) rho

  Right $ Set.filter isLeader slotRangeOfInterest

-- | Return the slots at which a particular stake pool operator is
-- expected to mint a block.
currentEpochEligibleLeadershipSlots :: forall era. ()
  => Consensus.PraosProtocolSupportsNode (Api.ConsensusProtocol era)
  => FromCBOR (Consensus.ChainDepState (Api.ConsensusProtocol era))
  => Shelley.EraCrypto (ShelleyLedgerEra era) ~ Shelley.StandardCrypto
  => ShelleyBasedEra era
  -> ShelleyGenesis Shelley.StandardCrypto
  -> EpochInfo (Either Text)
  -> Ledger.PParams (ShelleyLedgerEra era)
  -> ProtocolState era
  -> PoolId
  -> SigningKey VrfKey
  -> SerialisedPoolDistribution era
  -> EpochNo -- ^ Current EpochInfo
  -> Either LeadershipError (Set SlotNo)
currentEpochEligibleLeadershipSlots sbe sGen eInfo pp ptclState poolid (VrfSigningKey vrkSkey) serPoolDistr currentEpoch = do

  chainDepState :: ChainDepState (Api.ConsensusProtocol era) <-
    first LeaderErrDecodeProtocolStateFailure $ decodeProtocolState ptclState

  -- We use the current epoch's nonce for the current leadership schedule
  -- calculation because the TICKN transition updates the epoch nonce
  -- at the start of the epoch.
  let epochNonce :: Nonce = Consensus.epochNonce (Consensus.getPraosNonces (Proxy @(Api.ConsensusProtocol era)) chainDepState)

  (firstSlotOfEpoch, lastSlotofEpoch) :: (SlotNo, SlotNo) <- first LeaderErrSlotRangeCalculationFailure
    $ Slot.epochInfoRange eInfo currentEpoch

  setSnapshotPoolDistr <-
    first LeaderErrDecodeProtocolEpochStateFailure . fmap (SL.unPoolDistr . unPoolDistr)
      $ decodePoolDistribution sbe serPoolDistr

  let slotRangeOfInterest :: Core.EraPParams ledgerera => Core.PParams ledgerera -> Set SlotNo
      slotRangeOfInterest pp' = Set.filter
        (not . Ledger.isOverlaySlot firstSlotOfEpoch (pp' ^. Core.ppDG))
        $ Set.fromList [firstSlotOfEpoch .. lastSlotofEpoch]

  caseShelleyToAlonzoOrBabbageEraOnwards
    (const (isLeadingSlotsTPraos (slotRangeOfInterest pp) poolid setSnapshotPoolDistr epochNonce vrkSkey f))
    (const (isLeadingSlotsPraos  (slotRangeOfInterest pp) poolid setSnapshotPoolDistr epochNonce vrkSkey f))
    sbe

 where
  globals = shelleyBasedEraConstraints sbe
              $ constructGlobals sGen eInfo $ pp ^. Core.ppProtocolVersionL

  f :: Ledger.ActiveSlotCoeff
  f = activeSlotCoeff globals

constructGlobals
  :: ShelleyGenesis Shelley.StandardCrypto
  -> EpochInfo (Either Text)
  -> Ledger.ProtVer
  -> Globals
constructGlobals sGen eInfo (Ledger.ProtVer majorPParamsVer _) =
  Ledger.mkShelleyGlobals sGen eInfo majorPParamsVer
