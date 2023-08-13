{-# LANGUAGE DerivingStrategies #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}

{-# OPTIONS_GHC -Wno-orphans #-}

{- HLINT ignore "Use camelCase" -}

module Test.Cardano.Api.Typed.JSON
  ( tests
  ) where

import           Cardano.Api.Eras

import           Data.Aeson (eitherDecode, encode)

import           Test.Gen.Cardano.Api.Typed (genMaybePraosNonce, genProtocolParameters)

import           Test.Cardano.Api.Typed.Orphans ()

import           Hedgehog (Property, forAll, tripping)
import qualified Hedgehog as H
import qualified Hedgehog.Gen as Gen
import           Test.Tasty (TestTree, testGroup)
import           Test.Tasty.Hedgehog (testProperty)

prop_roundtrip_praos_nonce_JSON :: Property
prop_roundtrip_praos_nonce_JSON = H.property $ do
  pNonce <- forAll $ Gen.just genMaybePraosNonce
  tripping pNonce encode eitherDecode

prop_roundtrip_protocol_parameters_JSON :: Property
prop_roundtrip_protocol_parameters_JSON = H.property $ do
  AnyCardanoEra era <- forAll $ Gen.element [minBound .. maxBound]
  pp <- forAll (genProtocolParameters era)
  tripping pp encode eitherDecode

-- -----------------------------------------------------------------------------

tests :: TestTree
tests = testGroup "Test.Cardano.Api.Typed.JSON"
  [ testProperty "roundtrip praos nonce JSON"         prop_roundtrip_praos_nonce_JSON
  , testProperty "roundtrip protocol parameters JSON" prop_roundtrip_protocol_parameters_JSON
  ]
