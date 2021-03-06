{-# LANGUAGE CPP #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE RankNTypes #-}

{- |
Module      : Verifier.SAW.Typechecker.Monad
Copyright   : Galois, Inc. 2012-2015
License     : BSD3
Maintainer  : jhendrix@galois.com
Stability   : experimental
Portability : non-portable (language extensions)
-}

module Verifier.SAW.Typechecker.Monad
  ( TC
  , liftST
  , runTC
  , tcFail
  , tcFailD
  , TCRef
  , NodeName
  , newRef
  , assignRef
  , eval
  , evaluatedRef
  , tryEval
  ) where

#if !MIN_VERSION_base(4,8,0)
import Control.Applicative
#endif
import Control.Monad.ST
import qualified Data.Map as Map
import Data.STRef
import Text.PrettyPrint.ANSI.Leijen hiding ((<$>))

import Verifier.SAW.Position

-- | State for continuations.
data TCState s = TS { tsErrors :: [FailReason]
                    , tsRefCount :: !Int
                    }

-- | Record the given error reason.
addError :: TCState s -> FailReason -> TCState s
addError s e = s { tsErrors = e : tsErrors s }

-- NB. Haddock will not parse documentation on GADT
-- constructors :-(
data FailReason where
  -- This is raised by bugs in the typechecker.
  InternalError :: String -> FailReason
  -- This is raised when a type error in user code is found.
  TypeError :: Pos -> String -> FailReason
  -- A cyclic dependency is found.  Contains the reference that lead to cycle detection,
  -- the name of the most recent edge, and a STReference that points to the references involved
  -- in the cycle.
  CycleFound :: [CycleEdge] -> FailReason
 deriving (Show)

-- A cycle edge contains the positon of edge, the name of the thing being defined, and
-- the name of the entity referenced.
type CycleEdge = (Pos, NodeName, NodeName)

type NodeName = String

ppFailReasons :: [FailReason] -> Doc
ppFailReasons rl = do
  case [ m | InternalError m <- rl ] of
    [] -> vcat $ tpErrors ++ cycErrors
      where ppTpError p m = text (ppPos p) <+> text m
            tpErrors = fmap (uncurry ppTpError)
                     $ Map.toList $ Map.fromList
                     $ [ (p,m) | TypeError p m <- rl ]
            cycErrors = [ ppCycle el | CycleFound el <- rl ]
    im -> ppInternalErrors im

ppCycle :: [CycleEdge] -> Doc
ppCycle edges = vcat $ header : fmap ppEdge edges
  where ppEdge (p,fr,to) = text (ppPos p) <+> text (fr ++ " references " ++ to)
        header = text "Unresolvable cyclic dependency involving"

ppInternalErrors :: [String] -> Doc
ppInternalErrors im =
  text "Internal" <+> emsg <+> text "during typechecking:" <$$>
    nest 2 (vcat (text <$> im))
 where emsg = text $ if length im > 1 then "errors" else "error"

-- | A data type defining what to do next what unifier finishes.

-- Note: Haddock cannot parse documenation on GADT constructors :-(
data TCCont s a where
  --  Applies a function to the input a before passing it to b.
  TCFMap :: (a -> b) -> TCCont s b -> TCCont s a
  --  Runs the unifer, and applies its result to the function @f@ passed in
  -- before calling the continuation argument.  This will also run the
  -- continuation even if an error is passed to this continuation.
  TCApp :: TC s a
        -> TCCont s b
        -> TCCont s (a -> b)
  TCBind :: (a -> TC s b)
         -> TCCont s b
         -> TCCont s a
  --  Continuation that resumes computation with failure regardless of whether
  -- current task succeeds or fails.
  TCFail :: TCCont s a -> TCCont s b
  --  Continuation for resuming computation after the current task finishes.
  TCTry :: TCRef s a
        -> TCCont s (Maybe a)
        -> TCCont s a
  --  Set a lazy value when task succeeds, and provide the value to the given continuations.
  TCSet :: TCRef s a
        -> Maybe (Pos, TCCont s a)
        -> TC s a --  Action that we are doing for evaluating.
        -> TCCont s a

-- | Called when computation completes succcessfully.
tcDone :: v -> TCCont s v -> TCState s -> ST s (TCState s)
tcDone v tc0 s =
  case tc0 of
    TCFMap fn tc -> tcDone (fn v) tc s
    TCApp (TC g) tc -> g (TCFMap v tc) s
    TCBind g tc -> unTC (g v) tc s
    TCFail tc -> tcError tc s
    TCTry r tc -> do
      writeSTRef (tcrRef r) $! TRSDone v
      tcDone (Just v) tc s
    TCSet r mcl _ -> do
      TRSActive <- readSTRef (tcrRef r)
      writeSTRef (tcrRef r) $! TRSDone v
      case mcl of
        Nothing -> return s
        Just (_,tc) -> tcDone v tc s


tcError :: TCCont s a
        -> TCState s
        -> ST s (TCState s)
tcError tc0 s =
  case tc0 of
    TCFMap _ tc -> tcError tc s
    TCApp (TC g) tc -> g (TCFail tc) s
    TCBind _ tc -> tcError tc s
    TCFail tc -> tcError tc s
    TCTry _ tc -> tcDone Nothing tc s
    TCSet r mcl _ -> do
      rs <- readSTRef (tcrRef r)
      let intErr msg = tcError tc0 (s `addError` fr1)
            where fr1 = InternalError msg
      case rs of
        TRSActive -> do
          writeSTRef (tcrRef r) TRSFailed
          case mcl of
            Nothing -> return s
            Just (_,tc') -> tcError tc' s
        _ -> intErr "Illegal attempt to error value."

-- | Continuation monad for typechecking computations.
newtype TC s v = TC { unTC :: TCCont s v
                                -> TCState s
                                -> ST s (TCState s)
                    }

instance Functor (TC s) where
  fmap f (TC g) = TC $ \c s -> g (TCFMap f c) s

instance Applicative (TC s) where
  pure v = TC (tcDone v)
  TC f <*> g = TC $ \c s -> f (TCApp g c) s

instance Monad (TC s) where
  return v = TC (tcDone v)
  TC f >>= g = TC $ \c s -> f (TCBind g c) s
  fail msg = TC $ \c s -> tcError c (s `addError` fr)
    where fr = InternalError msg

-- | Run typechecker and return either errors or result.
runTC :: (forall s . TC s v) -> Either Doc v
runTC tc = runST $ do
  vr <- newSTRef TRSActive
  let ts0 = TS { tsErrors = []
               , tsRefCount = 1
               }
  s <- unTC tc (TCSet (TCRef "Initial node" 0 vr) Nothing tc) ts0
  case tsErrors s of
    [] -> do
     r <- readSTRef vr
     case r of
       TRSDone v -> return (Right v)
       _ -> return $ Left $ ppInternalErrors ["Failed to set final reference"]
    rsns -> return $ Left $ ppFailReasons rsns

-- | Lift ST to TC monad.
liftST :: ST s a -> TC s a
liftST m = TC $ \c s -> m >>= \v -> tcDone v c s

-- | Fail with a typechecker error.  Position is required for all non-internal errors.
tcFail :: Pos -> String -> TC s a
tcFail p nm = TC $ \tc s -> tcError tc (s `addError` TypeError p nm)

tcFailD :: Pos -> Doc -> TC s a
tcFailD p d = tcFail p $ show d

data TCRefState s v
  = TRSUnassigned
  | TRSAssigned (TC s v)
  | TRSActive
  | TRSDone !v
  | TRSFailed

data TCRef s v = TCRef { tcrName :: NodeName
                       , tcrIdx :: Int
                       , tcrRef :: STRef s (TCRefState s v)
                       }

instance Show (TCRef s v) where
  show r = tcrName r

newRef :: NodeName -> TC s (TCRef s v)
newRef nm = TC $ \tc s -> do
  r <- newSTRef TRSUnassigned
  let c = tsRefCount s
  tcDone (TCRef nm c r) tc s { tsRefCount = c + 1 }

assignRef :: TCRef s v -> TC s v -> TC s ()
assignRef r h  = TC $ \tc s -> do
  m <- readSTRef (tcrRef r)
  case m of
    TRSUnassigned -> do
      writeSTRef (tcrRef r) (TRSAssigned h)
      tcDone () tc s
    _ -> tcError tc (s `addError` fr)
      where fr = InternalError "Duplicate ref assignment"

data SomeTCRef s where
  SomeTCRef :: TCRef s v -> TC s v -> SomeTCRef s

tryEval :: forall s v . TCRef s v -> TC s (Maybe v)
tryEval r = TC $ \tc0 s0 -> do
  m <- readSTRef (tcrRef r)
  case m of
    TRSUnassigned -> fail "Attempt to evaluate reference before it is assigned"
    TRSAssigned h -> do
      writeSTRef (tcrRef r) $! TRSActive
      unTC h (TCTry r tc0) s0
    TRSActive -> tcDone Nothing tc0 s0
    TRSDone v -> tcDone (Just v) tc0 s0
    TRSFailed -> tcDone Nothing tc0 s0

eval :: forall s v . Pos -> TCRef s v -> TC s v
eval p0 r = TC $ \tc0 s0 -> do
  m <- readSTRef (tcrRef r)
  case m of
    TRSUnassigned -> fail "Attempt to evaluate reference before it is assigned"
    TRSAssigned h -> do
      writeSTRef (tcrRef r) $! TRSActive
      unTC h (TCSet r (Just (p0,tc0)) h) s0
    TRSActive -> resolveCycle (p0,r,[],[],s0) tc0
      where resetSet (SomeTCRef r' h) = writeSTRef (tcrRef r') $! TRSAssigned h
            failSet (SomeTCRef r' _) = writeSTRef (tcrRef r') TRSFailed
            resolveCycle :: (Pos,TCRef s a, [CycleEdge], [SomeTCRef s], TCState s)
                         -> TCCont s b
                         -> ST s (TCState s)
            resolveCycle c (TCFMap _ tc) = resolveCycle c tc
            resolveCycle c (TCApp _ tc)  = resolveCycle c tc
            resolveCycle c (TCBind _ tc) = resolveCycle c tc
            resolveCycle (_,_,_,l,s) (TCFail tc) =
              mapM_ resetSet l >> tcError tc s
            resolveCycle (_,_,_,l,s) (TCTry _ tc) =
              mapM_ resetSet l >> tcDone Nothing tc s
            -- We found the end of the cycle
            resolveCycle (p,rn,el,l,s) (TCSet rp mcl _) | tcrIdx r == tcrIdx rp = do
              mapM_ failSet l
              writeSTRef (tcrRef rp) TRSFailed
              let el' = (p, tcrName r, tcrName rn):el
              let s' = s `addError` CycleFound el'
              case mcl of
                Nothing -> return s'
                Just (_,tc') -> tcError tc' s'
            resolveCycle (_,_,el,l,s) (TCSet rp Nothing _) = do
                mapM_ failSet l
                writeSTRef (tcrRef rp) TRSFailed
                return (s `addError` InternalError msg)
              where msg = "Encountered terminating continuation before end of cycle:\n"
                            ++ show (ppCycle el)
            resolveCycle (p,rn,el,l,s) (TCSet rp (Just (p',tc)) h) = do
                writeSTRef (tcrRef rp) TRSFailed
                resolveCycle (p',rp,el',SomeTCRef rp h:l, s) tc
              where el' = (p, tcrName rp, tcrName rn):el
    TRSDone v -> tcDone v tc0 s0
    TRSFailed -> tcError tc0 s0

-- | Create a ref that is already fully evaluated.
evaluatedRef :: NodeName -> v -> TC s (TCRef s v)
evaluatedRef nm v = TC $ \tc s -> do
  r <- newSTRef (TRSDone v)
  let c = tsRefCount s
  tcDone (TCRef nm c r) tc s { tsRefCount = c + 1 }
