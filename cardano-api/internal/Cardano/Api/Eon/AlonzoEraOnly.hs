{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE DataKinds #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE LambdaCase #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE TypeOperators #-}

module Cardano.Api.Eon.AlonzoEraOnly
  ( AlonzoEraOnly(..)
  , alonzoEraOnlyConstraints
  , alonzoEraOnlyToCardanoEra
  , alonzoEraOnlyToShelleyBasedEra

  , AlonzoEraOnlyConstraints
  ) where

import           Cardano.Api.Eon.ShelleyBasedEra
import           Cardano.Api.Eras.Core
import           Cardano.Api.Modes
import           Cardano.Api.Query.Types

import           Cardano.Binary
import qualified Cardano.Crypto.Hash.Blake2b as Blake2b
import qualified Cardano.Crypto.Hash.Class as C
import qualified Cardano.Crypto.VRF as C
import qualified Cardano.Ledger.Api as L
import qualified Cardano.Ledger.BaseTypes as L
import qualified Cardano.Ledger.Core as L
import qualified Cardano.Ledger.Mary.Value as L
import qualified Cardano.Ledger.SafeHash as L
import qualified Ouroboros.Consensus.Protocol.Abstract as Consensus
import qualified Ouroboros.Consensus.Protocol.Praos.Common as Consensus
import qualified Ouroboros.Consensus.Shelley.Ledger as Consensus

import           Data.Aeson
import           Data.Typeable (Typeable)

data AlonzoEraOnly era where
  AlonzoEraOnlyAlonzo  :: AlonzoEraOnly AlonzoEra

deriving instance Show (AlonzoEraOnly era)
deriving instance Eq (AlonzoEraOnly era)

instance Eon AlonzoEraOnly where
  inEonForEra no yes = \case
    ByronEra    -> no
    ShelleyEra  -> no
    AllegraEra  -> no
    MaryEra     -> no
    AlonzoEra   -> yes AlonzoEraOnlyAlonzo
    BabbageEra  -> no
    ConwayEra   -> no

instance ToCardanoEra AlonzoEraOnly where
  toCardanoEra = \case
    AlonzoEraOnlyAlonzo  -> AlonzoEra

type AlonzoEraOnlyConstraints era =
  ( C.HashAlgorithm (L.HASH (L.EraCrypto (ShelleyLedgerEra era)))
  , C.Signable (L.VRF (L.EraCrypto (ShelleyLedgerEra era))) L.Seed
  , Consensus.PraosProtocolSupportsNode (ConsensusProtocol era)
  , Consensus.ShelleyCompatible (ConsensusProtocol era) (ShelleyLedgerEra era)
  , L.ADDRHASH (Consensus.PraosProtocolSupportsNodeCrypto (ConsensusProtocol era)) ~ Blake2b.Blake2b_224
  , L.AlonzoEraPParams (ShelleyLedgerEra era)
  , L.AlonzoEraTx (ShelleyLedgerEra era)
  , L.AlonzoEraTxBody (ShelleyLedgerEra era)
  , L.AlonzoEraTxOut (ShelleyLedgerEra era)
  , L.AlonzoEraTxWits (ShelleyLedgerEra era)
  , L.Crypto (L.EraCrypto (ShelleyLedgerEra era))
  , L.Era (ShelleyLedgerEra era)
  , L.EraCrypto (ShelleyLedgerEra era) ~ L.StandardCrypto
  , L.EraPParams (ShelleyLedgerEra era)
  , L.EraTx (ShelleyLedgerEra era)
  , L.EraTxBody (ShelleyLedgerEra era)
  , L.ExactEra L.AlonzoEra (ShelleyLedgerEra era)
  , L.HashAnnotated (L.TxBody (ShelleyLedgerEra era)) L.EraIndependentTxBody L.StandardCrypto
  , L.ProtVerAtMost (ShelleyLedgerEra era) 6
  , L.ProtVerAtMost (ShelleyLedgerEra era) 8
  , L.ShelleyEraTxBody (ShelleyLedgerEra era)
  , L.ShelleyEraTxCert (ShelleyLedgerEra era)
  , L.Value (ShelleyLedgerEra era) ~ L.MaryValue L.StandardCrypto

  , FromCBOR (Consensus.ChainDepState (ConsensusProtocol era))
  , FromCBOR (DebugLedgerState era)
  , IsCardanoEra era
  , IsShelleyBasedEra era
  , ToJSON (DebugLedgerState era)
  , Typeable era
  )

alonzoEraOnlyConstraints :: ()
  => AlonzoEraOnly era
  -> (AlonzoEraOnlyConstraints era => a)
  -> a
alonzoEraOnlyConstraints = \case
  AlonzoEraOnlyAlonzo  -> id

alonzoEraOnlyToCardanoEra :: AlonzoEraOnly era -> CardanoEra era
alonzoEraOnlyToCardanoEra = shelleyBasedToCardanoEra . alonzoEraOnlyToShelleyBasedEra

alonzoEraOnlyToShelleyBasedEra :: AlonzoEraOnly era -> ShelleyBasedEra era
alonzoEraOnlyToShelleyBasedEra = \case
  AlonzoEraOnlyAlonzo  -> ShelleyBasedEraAlonzo
