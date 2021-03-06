-- Lightweight calculus for composing patterns as functions.
{-# LANGUAGE FlexibleInstances #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TypeOperators #-}
{-# LANGUAGE ViewPatterns #-}

{- |
Module      : Verifier.SAW.Recognizer
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Recognizer
  ( Recognizer
  , (<:), emptyl, endl
  , (:*:)(..)
  , asFTermF

  , asGlobalDef
  , isGlobalDef
  , asApp
  , (<@>), (@>)
  , asApplyAll
  , asPairType
  , asPairValue
  , asPairSelector
  , asTupleType
  , asTupleValue
  , asTupleSelector
  , asFieldType
  , asFieldValue
  , asRecordType
  , asRecordValue
  , asRecordSelector
  , asCtor
  , asDataType
  , isDataType
  , asNatLit
  , asStringLit
  , asLambda
  , asLambdaList
  , asPi
  , asPiList
  , asLocalVar
  , asExtCns
  , asSort
    -- * Prelude recognizers.
  , asBool
  , asBoolType
  , asIntegerType
  , Nat
  , asBitvectorType
  , asVectorType
  , asVecType
  , isVecType
  , asMux
  ) where

import Control.Applicative
import Control.Lens
import Control.Monad
import Data.Map (Map)
import qualified Data.Map as Map
import Verifier.SAW.Prim
import Verifier.SAW.Term.Functor
import Verifier.SAW.Term.Pretty

data a :*: b = (:*:) a b
  deriving (Eq,Ord,Show)

instance Field1 (a :*: b) (a' :*: b) a a' where
  _1 k (a :*: b) = indexed k (0 :: Int) a <&> (:*: b)

instance Field2 (a :*: b) (a :*: b') b b' where
  _2 k (a :*: b) = (a :*:) <$> indexed k (1 :: Int) b

type Recognizer m t a = t -> m a

-- | Tries both recognizers.
(<>) :: Alternative f => Recognizer f t a -> Recognizer f t a -> Recognizer f t a
(<>) f g t = f t <|> g t

-- | Recognizes the head and tail of a list, and returns head.
(<:) :: Monad f
     => Recognizer f t a -> Recognizer f [t] () -> Recognizer f [t] a
(<:) f g (h:r) = do x <- f h; _ <- g r; return x
(<:) _ _ [] = fail "empty-list"

-- | Recognizes the head and tail of a list, and returns head.
(<:>) :: Monad f
     => Recognizer f t a -> Recognizer f [t] b -> Recognizer f [t] (a :*: b)
(<:>) f g (h:r) = do x <- f h; y <- g r; return (x :*: y)
(<:>) _ _ [] = fail "empty-list"

-- | Recognizes empty list
emptyl :: Monad m => Recognizer m [t] ()
emptyl [] = return ()
emptyl _ = fail "non-empty"

-- | Recognizes singleton list
endl :: Monad f => Recognizer f t a -> Recognizer f [t] a
endl f = f <: emptyl

asFTermF :: (Monad f, Termlike t) => Recognizer f t (FlatTermF t)
asFTermF (unwrapTermF -> FTermF ftf) = return ftf
asFTermF _ = fail "not ftermf"

asGlobalDef :: (Monad f, Termlike t) => Recognizer f t Ident
asGlobalDef t = do GlobalDef i <- asFTermF t; return i

isGlobalDef :: (Monad f, Termlike t) => Ident -> Recognizer f t ()
isGlobalDef i t = do
  o <- asGlobalDef t
  if i == o then return () else fail ("not " ++ show i)

asApp :: (Monad f, Termlike t) => Recognizer f t (t, t)
asApp (unwrapTermF -> App x y) = return (x, y)
asApp _ = fail "not app"

(<@>) :: (Monad f, Termlike t)
      => Recognizer f t a -> Recognizer f t b -> Recognizer f t (a :*: b)
(<@>) f g t = do
  (a,b) <- asApp t
  liftM2 (:*:) (f a) (g b)

-- | Recognizes a function application, and returns argument.
(@>) :: (Monad f, Termlike t) => Recognizer f t () -> Recognizer f t b -> Recognizer f t b
(@>) f g t = do
  (x, y) <- asApp t
  liftM2 (const id) (f x) (g y)

asApplyAll :: Termlike t => t -> (t, [t])
asApplyAll = go []
  where go xs t =
          case asApp t of
            Nothing -> (t, xs)
            Just (t', x) -> go (x : xs) t'

asPairType :: (Monad m, Termlike t) => Recognizer m t (t, t)
asPairType t = do
  ftf <- asFTermF t
  case ftf of
    PairType x y -> return (x, y)
    _            -> fail "asPairType"

asPairValue :: (Monad m, Termlike t) => Recognizer m t (t, t)
asPairValue t = do
  ftf <- asFTermF t
  case ftf of
    PairValue x y -> return (x, y)
    _             -> fail "asPairValue"

asPairSelector :: (Monad m, Termlike t) => Recognizer m t (t, Bool)
asPairSelector t = do
  ftf <- asFTermF t
  case ftf of
    PairLeft x  -> return (x, False)
    PairRight x -> return (x, True)
    _           -> fail "asPairSelector"

asTupleType :: (Monad m, Termlike t) => Recognizer m t [t]
asTupleType t = do
  ftf <- asFTermF t
  case ftf of
    UnitType     -> return []
    PairType x y -> do xs <- asTupleType y; return (x : xs)
    _            -> fail "asTupleType"

asTupleValue :: (Monad m, Termlike t) => Recognizer m t [t]
asTupleValue t = do
  ftf <- asFTermF t
  case ftf of
    UnitValue     -> return []
    PairValue x y -> do xs <- asTupleValue y; return (x : xs)
    _             -> fail "asTupleValue"

asTupleSelector :: (Monad m, Termlike t) => Recognizer m t (t, Int)
asTupleSelector t = do
  ftf <- asFTermF t
  case ftf of
    PairLeft x  -> return (x, 1)
    PairRight y -> do (x, i) <- asTupleSelector y; return (x, i+1)
    _           -> fail "asTupleSelector"

asFieldType :: (Monad m, Termlike t) => Recognizer m t (t, t, t)
asFieldType t = do
  ftf <- asFTermF t
  case ftf of
    FieldType x y z -> return (x, y, z)
    _               -> fail "asFieldType"

asFieldValue :: (Monad m, Termlike t) => Recognizer m t (t, t, t)
asFieldValue t = do
  ftf <- asFTermF t
  case ftf of
    FieldValue x y z -> return (x, y, z)
    _                -> fail "asFieldValue"

asRecordType :: (Monad m, Termlike t) => Recognizer m t (Map FieldName t)
asRecordType t = do
  ftf <- asFTermF t
  case ftf of
    EmptyType       -> return Map.empty
    FieldType f x y -> do m <- asRecordType y
                          s <- asStringLit f
                          return (Map.insert s x m)
    _               -> fail $ "asRecordType: " ++ showTermlike t

asRecordValue :: (Monad m, Termlike t) => Recognizer m t (Map FieldName t)
asRecordValue t = do
  ftf <- asFTermF t
  case ftf of
    EmptyValue       -> return Map.empty
    FieldValue f x y -> do m <- asRecordValue y
                           s <- asStringLit f
                           return (Map.insert s x m)
    _                -> fail $ "asRecordValue: " ++ showTermlike t

asRecordSelector :: (Monad m, Termlike t) => Recognizer m t (t, FieldName)
asRecordSelector t = do
  RecordSelector u i <- asFTermF t
  s <- asStringLit i
  return (u, s)

asCtor :: (Monad f, Termlike t) => Recognizer f t (Ident, [t])
asCtor t = do CtorApp c l <- asFTermF t; return (c,l)

asDataType :: (Monad f, Termlike t) => Recognizer f t (Ident, [t])
asDataType t = do DataTypeApp c l <- asFTermF t; return (c,l)

isDataType :: (Monad f, Termlike t) => Ident -> Recognizer f [t] a -> Recognizer f t a
isDataType i p t = do
  (o,l) <- asDataType t
  if i == o then p l else fail "not datatype"

asNatLit :: (Monad f, Termlike t) => Recognizer f t Nat
asNatLit t = do NatLit i <- asFTermF t; return (fromInteger i)

asStringLit :: (Monad f, Termlike t) => Recognizer f t String
asStringLit t = do StringLit i <- asFTermF t; return i

asLambda :: (Monad m, Termlike t) => Recognizer m t (String, t, t)
asLambda (unwrapTermF -> Lambda s ty body) = return (s, ty, body)
asLambda _ = fail "not a lambda"

asLambdaList :: Termlike t => t -> ([(String, t)], t)
asLambdaList = go []
  where go r (asLambda -> Just (nm,tp,rhs)) = go ((nm,tp):r) rhs
        go r rhs = (reverse r, rhs)

asPi :: (Monad m, Termlike t) => Recognizer m t (String, t, t)
asPi (unwrapTermF -> Pi nm tp body) = return (nm, tp, body)
asPi _ = fail "not a Pi term"

-- | Decomposes a term into a list of pi bindings, followed by a right
-- term that is not a pi binding.
asPiList :: Termlike t => t -> ([(String, t)], t)
asPiList = go []
  where go r (asPi -> Just (nm,tp,rhs)) = go ((nm,tp):r) rhs
        go r rhs = (reverse r, rhs)

asLocalVar :: (Monad m, Termlike t) => Recognizer m t DeBruijnIndex
asLocalVar (unwrapTermF -> LocalVar i) = return i
asLocalVar _ = fail "not a local variable"

asExtCns :: (Monad m, Termlike t) => Recognizer m t (ExtCns t)
asExtCns t = do
  ftf <- asFTermF t
  case ftf of
    ExtCns ec -> return ec
    _         -> fail "asExtCns"

asSort :: (Monad m, Termlike t) => Recognizer m t Sort
asSort t = do
  ftf <- asFTermF t
  case ftf of
    Sort s -> return s
    _      -> fail $ "asSort: " ++ showTermlike t

-- | Returns term as a constant Boolean if it is one.
asBool :: (Monad f, Termlike t) => Recognizer f t Bool
asBool (asCtor -> Just ("Prelude.True",  [])) = return True
asBool (asCtor -> Just ("Prelude.False", [])) = return False
asBool _ = fail "not bool"

asBoolType :: (Monad f, Termlike t) => Recognizer f t ()
asBoolType = isDataType "Prelude.Bool" emptyl

asIntegerType :: (Monad f, Termlike t) => Recognizer f t ()
asIntegerType = isDataType "Prelude.Integer" emptyl

asVectorType :: (Monad f, Termlike t) => Recognizer f t (t, t)
asVectorType = isDataType "Prelude.Vec" r
  where r [n, t] = return (n, t)
        r _ = fail "asVectorType: wrong number of arguments"

isVecType :: (Monad f, Termlike t)
          => Recognizer f t a -> Recognizer f t (Nat :*: a)
isVecType tp = isDataType "Prelude.Vec" (asNatLit <:> endl tp)

asVecType :: (Monad f, Termlike t) => Recognizer f t (Nat :*: t)
asVecType = isVecType return

asBitvectorType :: (Alternative f, Monad f, Termlike t) => Recognizer f t Nat
asBitvectorType =
  (isGlobalDef "Prelude.bitvector" @> asNatLit)
  <> isDataType "Prelude.Vec"
                (asNatLit <: endl (isDataType "Prelude.Bool" emptyl))

asMux :: (Monad f, Termlike t) => Recognizer f t (t :*: t :*: t :*: t)
asMux = isGlobalDef "Prelude.ite" @> return <@> return <@> return <@> return
