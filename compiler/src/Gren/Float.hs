{-# LANGUAGE EmptyDataDecls #-}
{-# LANGUAGE FlexibleInstances #-}
{-# OPTIONS_GHC -Wall #-}

module Gren.Float
  ( Float,
    fromPtr,
    toBuilder,
  )
where

import Data.Binary (Binary, get, put)
import qualified Data.ByteString.Builder as B
import qualified Data.Utf8 as Utf8
import Data.Word (Word8)
import Foreign.Ptr (Ptr)
import Prelude hiding (Float)

-- FLOATS

type Float =
  Utf8.Utf8 GREN_FLOAT

data GREN_FLOAT

-- HELPERS

fromPtr :: Ptr Word8 -> Ptr Word8 -> Float
fromPtr =
  Utf8.fromPtr

{-# INLINE toBuilder #-}
toBuilder :: Float -> B.Builder
toBuilder =
  Utf8.toBuilder

-- BINARY

instance Binary (Utf8.Utf8 GREN_FLOAT) where
  get = Utf8.getUnder256
  put = Utf8.putUnder256