{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE TypeFamilies #-}
{-# LANGUAGE CPP #-}

import qualified Control.Monad.State as S (State, gets, modify, evalState)
import Data.List (partition)
import qualified Data.Map as Map
import Data.Maybe (listToMaybe)
import qualified Data.Set as Set
import Text.Show (showListWith)

import Curry_Prelude
import Debug (internalError)

import qualified Control.CP.ComposableTransformers as MCP (solve)
import Control.CP.EnumTerm (assignments, labelling, inOrder, firstFail, middleOut, endsOut, EnumTerm(..))
import Control.CP.FD.FD (FDInstance, FDSolver(..))
import Control.CP.FD.Interface (labelCol)
import Control.CP.FD.Model (Model, ModelInt, ModelCol, ModelIntTerm(..), ModelFunctions, asExpr)
import Control.CP.FD.OvertonFD.OvertonFD (OvertonFD)
import Control.CP.FD.Solvers (dfs, it, fs)
import Control.CP.SearchTree (Tree, MonadTree(..))
import Data.Expr.Data (BoolExpr (BoolConst), ColExpr (ColList))
import Data.Expr.Sugar ((!), (@=), (@/=), (@<), (@<=), (@+), (@-), (@*), (@&&), (@:), xsum, allDiff, list, forall, loopall, ToBoolExpr(..), size)

#ifdef GECODE
import Control.CP.FD.GecodeExample (setSearchMinimize)
import Control.CP.FD.Gecode.Common (GecodeWrappedSolver)
import Control.CP.FD.Gecode.Runtime (RuntimeGecodeSolver)
import Control.CP.FD.Gecode.RuntimeSearch (SearchGecodeSolver)
#endif

-- -----------------------------------------------------------------------------
-- Representation of FD expressions
-- -----------------------------------------------------------------------------

type FDIdent = Integer

data ArithOp = Plus | Minus | Mult
  deriving (Eq, Ord)

data C_FDExpr = FDVal Int
              | FDVar FDIdent Domain
              | FDParam FDIdent
              | ExprHole Int
              | FDAt [C_FDExpr] C_FDExpr
              | FDArith ArithOp C_FDExpr C_FDExpr
              | FDSum [C_FDExpr]
              | Choice_C_FDExpr Cover ID C_FDExpr C_FDExpr
              | Choices_C_FDExpr Cover ID [C_FDExpr]
              | Fail_C_FDExpr Cover FailInfo
              | Guard_C_FDExpr Cover Constraints C_FDExpr

instance Show C_FDExpr where
  showsPrec d (Choice_C_FDExpr cd i x y) = showsChoice d cd i x y
  showsPrec d (Choices_C_FDExpr cd i xs) = showsChoices d cd i xs
  showsPrec d (Guard_C_FDExpr cd cs e) = showsGuard d cd cs e
  showsPrec _ (Fail_C_FDExpr _ _) = showChar '!'
  showsPrec _ (FDVal x) = shows x
  showsPrec _ (FDVar i _) = showString $ 'x' : show i
  showsPrec _ (FDParam i) = showString $ 'p' : show i
  showsPrec _ (ExprHole i) = showString $ "par" ++ show i
  showsPrec d (FDAt c e) = showChar '(' . showListWith (showsPrec d) c
                            . showChar '!' . showsPrec d e . showChar ')'
  showsPrec d (FDArith op x y) = showChar '(' . showsPrec d x . showArithOP op
                               . showsPrec d y . showChar ')'
    where showArithOP Plus  = showString " +# "
          showArithOP Minus = showString " -# "
          showArithOP Mult  = showString " *# "
  showsPrec d (FDSum xs) = showChar '(' . showString "sum "
                         . showListWith (showsPrec d) xs . showChar ')'

instance Read C_FDExpr where
  readsPrec = internalError "read for FDExpr is undefined"

instance NonDet C_FDExpr where
  choiceCons = Choice_C_FDExpr
  choicesCons = Choices_C_FDExpr
  failCons = Fail_C_FDExpr
  guardCons = Guard_C_FDExpr
  try (Choice_C_FDExpr cd i x y) = tryChoice cd i x y
  try (Choices_C_FDExpr cd i xs) = tryChoices cd i xs
  try (Fail_C_FDExpr cd info) = Fail cd info
  try (Guard_C_FDExpr cd cs e) = Guard cd cs e
  try x = Val x
  match f _ _ _ _ _ (Choice_C_FDExpr cd i x y) = f cd i x y
  match _ f _ _ _ _ (Choices_C_FDExpr cd i@(NarrowedID _ _) xs) = f cd i xs
  match _ _ f _ _ _ (Choices_C_FDExpr cd i@(FreeID _ _) xs) = f cd i xs
  match _ _ _ _ _ _ (Choices_C_FDExpr _  i@(ChoiceID _) _) = internalError ("CLPFD2.FDExpr.match: Choices with ChoiceID " ++ (show i))
  match _ _ _ f _ _ (Fail_C_FDExpr cd info) = f cd info
  match _ _ _ _ f _ (Guard_C_FDExpr cd cs e) = f cd cs e
  match _ _ _ _ _ f x = f x

instance Generable C_FDExpr where
  generate = internalError "generate for FDExpr is undefined"

instance NormalForm C_FDExpr where
  ($!!) cont x@(FDVal _) d cs = cont x d cs
  ($!!) cont x@(FDVar _ _) d cs = cont x d cs
  ($!!) cont x@(FDParam _) d cs = cont x d cs
  ($!!) cont x@(ExprHole _) d cs = cont x d cs
  ($!!) cont x@(FDAt _ _) d cs = cont x d cs
  ($!!) cont x@(FDArith _ _ _) d cs = cont x d cs
  ($!!) cont x@(FDSum _) d cs = cont x d cs
  ($!!) cont (Choice_C_FDExpr cd i x y) d cs = nfChoice cont cd i x y cd cs
  ($!!) cont (Choices_C_FDExpr cd i xs) d cs = nfChoices cont cd i xs d cs
  ($!!) cont (Guard_C_FDExpr cd c e) d cs = guardCons cd c (((cont $!! e) d) (addCs c cs))
  ($!!) _ (Fail_C_FDExpr cd info) _ _ = failCons cd info
  ($##) cont x@(FDVal _) d cs = cont x d cs
  ($##) cont x@(FDVar _ _) d cs = cont x d cs
  ($##) cont x@(FDParam _) d cs = cont x d cs
  ($##) cont x@(ExprHole _) d cs = cont x d cs
  ($##) cont x@(FDAt _ _) d cs = cont x d cs
  ($##) cont x@(FDArith _ _ _) d cs = cont x d cs
  ($##) cont x@(FDSum _) d cs = cont x d cs
  ($##) cont (Choice_C_FDExpr cd i x y) d cs = gnfChoice cont cd i x y cd cs
  ($##) cont (Choices_C_FDExpr cd i xs) d cs = gnfChoices cont cd i xs d cs
  ($##) cont (Guard_C_FDExpr cd c e) d cs = guardCons cd c (((cont $## e) d) (addCs c cs))
  ($##) _ (Fail_C_FDExpr cd info) _ _ = failCons cd info
  showCons x@(FDVal _) = "CLPFD2.FDVal _"
  showCons x@(FDVar _ _) = "CLPFD2.FDVar _ _"
  showCons x@(FDParam _) = "CLPFD2.FDParam _"
  showCons x@(ExprHole _) = "CLPFD2.ExprHole _"
  showCons x@(FDAt _ _) = "CLPFD2.FDAt _ _"
  showCons x@(FDArith _ _ _) = "CLPFD2.FDArith _ _ _"
  showCons x@(FDSum _) = "CLPFD2.FDSum _"
  showCons x = error ("CLPFD2.FDExpr.showCons: no constructor: " ++ (show x))
  searchNF _ cont x@(FDVal _) = cont x
  searchNF _ cont x@(FDVar _ _) = cont x
  searchNF _ cont x@(FDParam _) = cont x
  searchNF _ cont x@(ExprHole _) = cont x
  searchNF _ cont x@(FDAt _ _) = cont x
  searchNF _ cont x@(FDArith _ _ _) = cont x
  searchNF _ cont x@(FDSum _) = cont x
  searchNF _ _ x = error ("CLPFD2.FDExpr.searchNF: no constructor: " ++ (show x))

instance Unifiable C_FDExpr where
  (=.=)    = internalError "(=.=) for FDExpr is undefined"
  (=.<=)   = internalError "(=.<=) for FDExpr is undefined"
  bind     = internalError "bind for FDExpr is undefined"
  lazyBind = internalError "lazyBind for FDExpr is undefined"
  fromDecision _ _ _ = error "fromDecision for FDExpr is undefined"

instance Curry C_FDExpr where
  (=?=) (Choice_C_FDExpr cd i x y) z d cs = narrow cd i (((x =?= z) d) cs) (((y =?= z) d) cs)
  (=?=) (Choices_C_FDExpr cd i xs) y d cs = narrows cs cd i (\x -> ((x =?= y) d) cs) xs
  (=?=) (Guard_C_FDExpr cd c e) y d cs = guardCons cd c (((e =?= y) d) (addCs c cs))
  (=?=) (Fail_C_FDExpr cd info) _ _ _ = failCons cd info
  (=?=) z (Choice_C_FDExpr cd i x y) d cs = narrow cd i (((z =?= x) d) cs) (((z =?= y) d) cs)
  (=?=) y (Choices_C_FDExpr cd i xs) d cs = narrows cs cd i (\x -> ((y =?= x) d) cs) xs
  (=?=) y (Guard_C_FDExpr cd c e) d cs = guardCons cd c (((y =?= e) d) (addCs c cs))
  (=?=) _ (Fail_C_FDExpr cd info) _ _ = failCons cd info
  (=?=) (FDVal x) (FDVal y) _ _ = toCurry (x == y)
  (=?=) (FDVar i _) (FDVar j _) _ _ = toCurry (i == j)
  (=?=) (FDParam i) (FDParam j) _ _ = toCurry (i == j)
  (=?=) (FDAt c1 e1) (FDAt c2 e2) d cs =
    d_OP_amp_amp (foldr (\(x,y) z -> d_OP_amp_amp ((x =?= y) d cs) z d cs) C_True (zip c1 c2)) ((e1 =?= e2) d cs) d cs
  (=?=) (FDArith op1 x1 y1) (FDArith op2 x2 y2) d cs =
    d_OP_amp_amp (d_OP_amp_amp ((x1 =?= x2) d cs) ((y1 =?= y2) d cs) d cs) (toCurry (op1 == op2)) d cs
  (=?=) (FDSum xs) (FDSum ys) d cs =
    foldr (\(x,y) z -> d_OP_amp_amp ((x =?= y) d cs) z d cs) C_True (zip xs ys)
  (=?=) _ _ _ _ = C_False
  (<?=) (Choice_C_FDExpr cd i x y) z d cs = narrow cd i (((x <?= z) d) cs) (((y <?= z) d) cs)
  (<?=) (Choices_C_FDExpr cd i xs) y d cs = narrows cs cd i (\x -> ((x <?= y) d) cs) xs
  (<?=) (Guard_C_FDExpr cd c e) y d cs = guardCons cd c (((e <?= y) d) (addCs c cs))
  (<?=) (Fail_C_FDExpr cd info) _ _ _ = failCons cd info
  (<?=) z (Choice_C_FDExpr cd i x y) d cs = narrow cd i (((z <?= x) d) cs) (((z <?= y) d) cs)
  (<?=) y (Choices_C_FDExpr cd i xs) d cs = narrows cs cd i (\x -> ((y <?= x) d) cs) xs
  (<?=) y (Guard_C_FDExpr cd c e) d cs = guardCons cd c (((y <?= e) d) (addCs c cs))
  (<?=) _ (Fail_C_FDExpr cd info) _ _ = failCons cd info
  (<?=) (FDVal x1) (FDVal y1) _ _ = toCurry (x1 <= y1)
  (<?=) (FDVal _) (FDVar _ _) _ _ = C_True
  (<?=) (FDVal _) (FDParam _) _ _ = C_True
  (<?=) (FDVal _) (FDAt _ _) _ _ = C_True
  (<?=) (FDVal _) (FDArith _ _ _) _ _ = C_True
  (<?=) (FDVal _) (FDSum _) _ _ = C_True
  (<?=) (FDVar x1 _) (FDVar y1 _) _ _ = toCurry (x1 <= y1)
  (<?=) (FDVar _ _) (FDParam _) _ _ = C_True
  (<?=) (FDVar _ _) (FDAt _ _) _ _ = C_True
  (<?=) (FDVar _ _) (FDArith _ _ _) _ _ = C_True
  (<?=) (FDVar _ _) (FDSum _) _ _ = C_True
  (<?=) (FDParam x1) (FDParam y1) _ _ = toCurry (x1 <= y1)
  (<?=) (FDParam _) (FDAt _ _) _ _ = C_True
  (<?=) (FDParam _) (FDArith _ _ _) _ _ = C_True
  (<?=) (FDParam _) (FDSum _) _ _ = C_True
  (<?=) (FDAt c1 e1) (FDAt c2 e2) d cs =
    d_OP_bar_bar (foldr (\(x,y) z -> d_OP_amp_amp ((x <?= y) d cs) z d cs) C_True (zip c1 c2)) ((e1 <?= e2) d cs) d cs
  (<?=) (FDAt _ _) (FDArith _ _ _) _ _ = C_True
  (<?=) (FDAt _ _) (FDSum _) _ _ = C_True
  (<?=) (FDArith x1 x2 x3) (FDArith y1 y2 y3) d cs = d_OP_bar_bar (toCurry (x1 < y1)) (d_OP_amp_amp (toCurry (x1 == y1)) (d_OP_bar_bar (d_OP_lt x2 y2 d cs) (d_OP_amp_amp (((x2 =?= y2) d) cs) (((x3 <?= y3) d) cs) d cs) d cs) d cs) d cs
  (<?=) (FDArith _ _ _) (FDSum _) _ _ = C_True
  (<?=) (FDSum xs) (FDSum ys) d cs =
    foldr (\(x,y) z -> d_OP_amp_amp ((x <?= y) d cs) z d cs) C_True (zip xs ys)
  (<?=) _ _ d _ = C_False

instance ConvertCurryHaskell C_FDExpr C_FDExpr where
  toCurry   = id
  fromCurry = id

instance ConvertCurryHaskell C_Option C_Option where
  toCurry   = id
  fromCurry = id

-- -----------------------------------------------------------------------------
-- Representation of FD constraints
-- -----------------------------------------------------------------------------

data RelOp = Equal | Diff | Less | LessEqual
  deriving (Eq, Ord)

data C_FDConstr = FDConst Bool
                | FDRel RelOp C_FDExpr C_FDExpr
                | FDAllDifferent [C_FDExpr]
                | FDLoopAll C_FDExpr C_FDExpr (C_FDExpr -> C_FDConstr)
                | FDAnd C_FDConstr C_FDConstr
                | Choice_C_FDConstr Cover ID C_FDConstr C_FDConstr
                | Choices_C_FDConstr Cover ID [C_FDConstr]
                | Fail_C_FDConstr Cover FailInfo
                | Guard_C_FDConstr Cover Constraints C_FDConstr

instance Show C_FDConstr where
  showsPrec d (Choice_C_FDConstr cd i x y) = showsChoice d cd i x y
  showsPrec d (Choices_C_FDConstr cd i xs) = showsChoices d cd i xs
  showsPrec d (Guard_C_FDConstr cd cs e) = showsGuard d cd cs e
  showsPrec _ (Fail_C_FDConstr _ _) = showChar '!'
  showsPrec _ (FDConst b) = shows b
  showsPrec d (FDRel op x y) = showChar '(' . showsPrec d x . showRelOp op
                             . showsPrec d y . showChar ')'
    where showRelOp Equal     = showString " =# "
          showRelOp Diff      = showString " /=# "
          showRelOp Less      = showString " <# "
          showRelOp LessEqual = showString " <=# "
  showsPrec d (FDAllDifferent xs) = showChar '(' . showString "allDifferent "
                         . showListWith (showsPrec d) xs . showChar ')'
  showsPrec d (FDLoopAll from to constr) = showString "loopall "
                         . showsPrec d from . showString " " . showsPrec d to
                         . showString " $ \\par" . shows d . showString " -> "
                         . showsPrec (d+1) (constr (ExprHole d))
  showsPrec d (FDAnd c1 c2) =  showChar '(' . showsPrec d c1 . showString " /\\ "
                             . showsPrec d c2 . showChar ')'

instance Read C_FDConstr where
  readsPrec = internalError "read for FDConstr is undefined"

instance NonDet C_FDConstr where
  choiceCons = Choice_C_FDConstr
  choicesCons = Choices_C_FDConstr
  failCons = Fail_C_FDConstr
  guardCons = Guard_C_FDConstr
  try (Choice_C_FDConstr cd i x y) = tryChoice cd i x y
  try (Choices_C_FDConstr cd i xs) = tryChoices cd i xs
  try (Fail_C_FDConstr cd info) = Fail cd info
  try (Guard_C_FDConstr cd cs e) = Guard cd cs e
  try x = Val x
  match f _ _ _ _ _ (Choice_C_FDConstr cd i x y) = f cd i x y
  match _ f _ _ _ _ (Choices_C_FDConstr cd i@(NarrowedID _ _) xs) = f cd i xs
  match _ _ f _ _ _ (Choices_C_FDConstr cd i@(FreeID _ _) xs) = f cd i xs
  match _ _ _ _ _ _ (Choices_C_FDConstr _  i@(ChoiceID _) _) = internalError ("CLPFD2.FDConstr.match: Choices with ChoiceID " ++ (show i))
  match _ _ _ f _ _ (Fail_C_FDConstr cd info) = f cd info
  match _ _ _ _ f _ (Guard_C_FDConstr cd cs e) = f cd cs e
  match _ _ _ _ _ f x = f x

instance Generable C_FDConstr where
  generate = internalError "generate for FDConstr is undefined"

instance NormalForm C_FDConstr where
  ($!!) cont x@(FDConst _) d cs = cont x d cs
  ($!!) cont x@(FDRel _ _ _) d cs = cont x d cs
  ($!!) cont x@(FDAllDifferent _) d cs = cont x d cs
  ($!!) cont x@(FDLoopAll _ _ _) d cs = cont x d cs
  ($!!) cont x@(FDAnd _ _) d cs = cont x d cs
  ($!!) cont (Choice_C_FDConstr cd i x y) d cs = nfChoice cont cd i x y cd cs
  ($!!) cont (Choices_C_FDConstr cd i xs) d cs = nfChoices cont cd i xs d cs
  ($!!) cont (Guard_C_FDConstr cd c e) d cs = guardCons cd c (((cont $!! e) d) (addCs c cs))
  ($!!) _ (Fail_C_FDConstr cd info) _ _ = failCons cd info
  ($##) cont x@(FDConst _) d cs = cont x d cs
  ($##) cont x@(FDRel _ _ _) d cs = cont x d cs
  ($##) cont x@(FDAllDifferent _) d cs = cont x d cs
  ($##) cont x@(FDLoopAll _ _ _) d cs = cont x d cs
  ($##) cont x@(FDAnd _ _) d cs = cont x d cs
  ($##) cont (Choice_C_FDConstr cd i x y) d cs = gnfChoice cont cd i x y cd cs
  ($##) cont (Choices_C_FDConstr cd i xs) d cs = gnfChoices cont cd i xs d cs
  ($##) cont (Guard_C_FDConstr cd c e) d cs = guardCons cd c (((cont $## e) d) (addCs c cs))
  ($##) _ (Fail_C_FDConstr cd info) _ _ = failCons cd info
  showCons x@(FDConst _) = "CLPFD2.FDConst _"
  showCons x@(FDRel _ _ _) = "CLPFD2.FDRel _ _ _"
  showCons x@(FDAllDifferent _) = "CLPFD2.FDAllDifferent _"
  showCons x@(FDLoopAll _ _ _) = "CLPFD2.FDLoopAll _ _ _"
  showCons x@(FDAnd _ _) = "CLPFD2.FDAnd _ _"
  showCons x = error ("CLPFD2.FDConstr.showCons: no constructor: " ++ (show x))
  searchNF _ cont x@(FDConst _) = cont x
  searchNF _ cont x@(FDRel _ _ _) = cont x
  searchNF _ cont x@(FDAllDifferent _) = cont x
  searchNF _ cont x@(FDLoopAll _ _ _) = cont x
  searchNF _ cont x@(FDAnd _ _) = cont x
  searchNF _ _ x = error ("CLPFD2.FDConstr.searchNF: no constructor: " ++ (show x))

instance Unifiable C_FDConstr where
  (=.=)    = internalError "(=.=) for FDConstr is undefined"
  (=.<=)   = internalError "(=.<=) for FDConstr is undefined"
  bind     = internalError "bind for FDConstr is undefined"
  lazyBind = internalError "lazyBind for FDConstr is undefined"
  fromDecision _ _ _ = error "fromDecision for FDConstr is undefined"

instance Curry C_FDConstr where
  (=?=) (Choice_C_FDConstr cd i x y) z d cs = narrow cd i (((x =?= z) d) cs) (((y =?= z) d) cs)
  (=?=) (Choices_C_FDConstr cd i xs) y d cs = narrows cs cd i (\x -> ((x =?= y) d) cs) xs
  (=?=) (Guard_C_FDConstr cd c e) y d cs = guardCons cd c (((e =?= y) d) (addCs c cs))
  (=?=) (Fail_C_FDConstr cd info) _ _ _ = failCons cd info
  (=?=) z (Choice_C_FDConstr cd i x y) d cs = narrow cd i (((z =?= x) d) cs) (((z =?= y) d) cs)
  (=?=) y (Choices_C_FDConstr cd i xs) d cs = narrows cs cd i (\x -> ((y =?= x) d) cs) xs
  (=?=) y (Guard_C_FDConstr cd c e) d cs = guardCons cd c (((y =?= e) d) (addCs c cs))
  (=?=) _ (Fail_C_FDConstr cd info) _ _ = failCons cd info
  (=?=) (FDConst b1) (FDConst b2) d cs = toCurry (b1 == b2)
  (=?=) (FDRel op1 x1 y1) (FDRel op2 x2 y2) d cs =
    d_OP_amp_amp (d_OP_amp_amp ((x1 =?= x2) d cs) ((y1 =?= y2) d cs) d cs) (toCurry (op1 == op2)) d cs
  (=?=) (FDAllDifferent xs) (FDAllDifferent ys) d cs =
    foldr (\(x,y) z -> d_OP_amp_amp ((x =?= y) d cs) z d cs) C_True (zip xs ys)
  (=?=) (FDAnd c1 d1) (FDAnd c2 d2) d cs = d_OP_amp_amp ((c1 =?= c2) d cs) ((d1 =?= d2) d cs) d cs
  (=?=) _ _ _ _ = C_False
  (<?=) (Choice_C_FDConstr cd i x y) z d cs = narrow cd i (((x <?= z) d) cs) (((y <?= z) d) cs)
  (<?=) (Choices_C_FDConstr cd i xs) y d cs = narrows cs cd i (\x -> ((x <?= y) d) cs) xs
  (<?=) (Guard_C_FDConstr cd c e) y d cs = guardCons cd c (((e <?= y) d) (addCs c cs))
  (<?=) (Fail_C_FDConstr cd info) _ _ _ = failCons cd info
  (<?=) z (Choice_C_FDConstr cd i x y) d cs = narrow cd i (((z <?= x) d) cs) (((z <?= y) d) cs)
  (<?=) y (Choices_C_FDConstr cd i xs) d cs = narrows cs cd i (\x -> ((y <?= x) d) cs) xs
  (<?=) y (Guard_C_FDConstr cd c e) d cs = guardCons cd c (((y <?= e) d) (addCs c cs))
  (<?=) _ (Fail_C_FDConstr cd info) _ _ = failCons cd info
  (<?=) (FDConst b1) (FDConst b2) _ _ = toCurry (b1 <= b2)
  (<?=) (FDConst _) (FDRel _ _ _) _ _ = C_True
  (<?=) (FDConst _) (FDAllDifferent _) _ _ = C_True
  (<?=) (FDConst _) (FDAnd _ _) _ _ = C_True
  (<?=) (FDRel x1 x2 x3) (FDRel y1 y2 y3) d cs = d_OP_bar_bar (toCurry (x1 < y1)) (d_OP_amp_amp (toCurry (x1 == y1)) (d_OP_bar_bar (d_OP_lt x2 y2 d cs) (d_OP_amp_amp (((x2 =?= y2) d) cs) (((x3 <?= y3) d) cs) d cs) d cs) d cs) d cs
  (<?=) (FDRel _ _ _) (FDAllDifferent _) _ _ = C_True
  (<?=) (FDRel _ _ _) (FDAnd _ _) _ _ = C_True
  (<?=) (FDAllDifferent xs) (FDAllDifferent ys) d cs =
    foldr (\(x,y) z -> d_OP_amp_amp ((x <?= y) d cs) z d cs) C_True (zip xs ys)
  (<?=) (FDAllDifferent _) (FDAnd _ _) _ _ = C_True
  (<?=) (FDAnd c1 d1) (FDAnd c2 d2) d cs = d_OP_bar_bar (d_OP_lt c1 c2 d cs) (d_OP_amp_amp ((c1 =?= c2) d cs) ((d1 <?= d2) d cs) d cs) d cs
  (<?=) _ _ d _ = C_False

-- -----------------------------------------------------------------------------
-- Representation of FD domains
-- -----------------------------------------------------------------------------

data Domain = Range Int Int
  deriving (Eq, Ord, Show)

external_d_C_prim_FD_domain :: C_Int -> C_Int -> C_Int -> Cover
                         -> ConstStore -> OP_List C_FDExpr
external_d_C_prim_FD_domain l u (Choices_C_Int _ (FreeID _ s) _) _ _ =
  newFDVars s
  where dom          = Range (fromCurry l) (fromCurry u)
        newFDVars s' = let i   = getKey $ thisID $ leftSupply s'
                           s1 = rightSupply s'
                       in OP_Cons (FDVar i dom) (newFDVars s1)

-- -----------------------------------------------------------------------------
-- Arithmetic FD constraints
-- -----------------------------------------------------------------------------

external_d_C_prim_fdc :: C_Int -> Cover -> ConstStore -> C_FDExpr
external_d_C_prim_fdc x@(Choices_C_Int _ _ _) _ _ =
  internalError $ "CLPFD2.fdc: Expected ground value but got " ++ (show x)
external_d_C_prim_fdc x                       _ _ = FDVal (fromCurry x)

external_d_C_prim_FD_plus :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                          -> C_FDExpr
external_d_C_prim_FD_plus (FDVal v1) (FDVal v2) _ _ = FDVal (v1 + v2)
external_d_C_prim_FD_plus e1         e2         _ _ = FDArith Plus e1 e2

external_d_C_prim_FD_minus :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                           -> C_FDExpr
external_d_C_prim_FD_minus (FDVal v1) (FDVal v2) _ _ = FDVal (v1 - v2)
external_d_C_prim_FD_minus e1         e2         _ _ = FDArith Minus e1 e2

external_d_C_prim_FD_mult :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                          -> C_FDExpr
external_d_C_prim_FD_mult (FDVal v1) (FDVal v2) _ _ = FDVal (v1 * v2)
external_d_C_prim_FD_mult e1         e2         _ _ = FDArith Mult e1 e2

-- -----------------------------------------------------------------------------
-- Relational FD constraints
-- -----------------------------------------------------------------------------

external_d_C_prim_FD_equal :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                           -> C_FDConstr
external_d_C_prim_FD_equal (FDVal v1) (FDVal v2) _ _ = FDConst (v1 == v2)
external_d_C_prim_FD_equal e1         e2         _ _ = FDRel Equal e1 e2

external_d_C_prim_FD_diff :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                          -> C_FDConstr
external_d_C_prim_FD_diff (FDVal v1) (FDVal v2) _ _ = FDConst (v1 /= v2)
external_d_C_prim_FD_diff e1         e2         _ _ = FDRel Diff e1 e2

external_d_C_prim_FD_less :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                          -> C_FDConstr
external_d_C_prim_FD_less (FDVal v1) (FDVal v2) _ _ = FDConst (v1 < v2)
external_d_C_prim_FD_less e1         e2         _ _ = FDRel Less e1 e2

external_d_C_prim_FD_lessEqual :: C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                               -> C_FDConstr
external_d_C_prim_FD_lessEqual (FDVal v1) (FDVal v2) _ _ = FDConst (v1 == v2)
external_d_C_prim_FD_lessEqual e1         e2         _ _ = FDRel LessEqual e1 e2

external_d_C_prim_FD_and :: C_FDConstr -> C_FDConstr -> Cover -> ConstStore
                         -> C_FDConstr
external_d_C_prim_FD_and (FDConst True)  c2              _ _ = c2
external_d_C_prim_FD_and (FDConst False) _               _ _ = FDConst False
external_d_C_prim_FD_and c1              (FDConst True)  _ _ = c1
external_d_C_prim_FD_and c1              (FDConst False) _ _ = FDConst False
external_d_C_prim_FD_and c1              c2              _ _ = FDAnd c1 c2

-- -----------------------------------------------------------------------------
-- Global FD constraints
-- -----------------------------------------------------------------------------

external_d_C_prim_FD_sum :: OP_List C_FDExpr -> Cover -> ConstStore -> C_FDExpr
external_d_C_prim_FD_sum xs _ _ = FDSum (fromCurry xs)

external_d_C_prim_FD_allDifferent :: OP_List C_FDExpr -> Cover -> ConstStore
                                  -> C_FDConstr
external_d_C_prim_FD_allDifferent xs _ _ = FDAllDifferent (fromCurry xs)

-- -----------------------------------------------------------------------------
-- Access FD expression list
-- -----------------------------------------------------------------------------

external_d_C_prim_FD_at :: OP_List C_FDExpr -> C_FDExpr -> Cover -> ConstStore
                        -> C_FDExpr
external_d_C_prim_FD_at xs e _ _ = FDAt (fromCurry xs) e

-- -----------------------------------------------------------------------------
-- Higher-order FD constraints
-- -----------------------------------------------------------------------------

external_d_C_prim_FD_loopall :: C_FDExpr -> C_FDExpr
                             -> (C_FDExpr -> Cover -> ConstStore -> C_FDConstr)
                             -> Cover -> ConstStore -> C_FDConstr
external_d_C_prim_FD_loopall from to constr cd cs
  = FDLoopAll from to (\e -> constr e cd cs)

external_nd_C_prim_FD_loopall :: C_FDExpr -> C_FDExpr
                              -> (Func C_FDExpr C_FDConstr) -> IDSupply -> Cover
                              -> ConstStore -> C_FDConstr
external_nd_C_prim_FD_loopall from to constr s cd cs
  = FDLoopAll from to (\e -> nd_apply constr e s cd cs)

-- -----------------------------------------------------------------------------
-- MCP solver translation
-- -----------------------------------------------------------------------------

-- translation monad
type TLM = S.State TLState

-- mapping of domains to FD variables
type VarMap = Map.Map Domain (Set.Set ModelInt)

-- translation state
-- stores all FD variables occurring during translation
-- with their corresponding domain
data TLState = TLState { varMap :: VarMap
                       , nextId :: FDIdent
                       }

-- initial translation state
initState :: TLState
initState = TLState { varMap = Map.empty
                    , nextId = -1
                    }

getVarMap :: TLM VarMap
getVarMap = S.gets varMap

getIdent :: TLM FDIdent
getIdent = S.gets nextId

setVarMap :: VarMap -> TLM ()
setVarMap vm = S.modify $ \s -> s { varMap = vm }

decIdent :: TLM ()
decIdent = S.modify $ \s -> s { nextId = (nextId s) - 1 }

-- get new FD parameter (for higher-order constraints)
newParam :: TLM C_FDExpr
newParam = do
  i <- getIdent
  decIdent
  return (FDParam i)

-- get a MCP collection of all FD variables
-- which were (so far) collected in the varMap during the translation process
getAllVars :: TLM ModelCol
getAllVars = do
  vm <- getVarMap
  let col = (list . Set.elems . Set.unions . Map.elems) vm
  return col

-- Translation of FD expressions into MCP terms
tlFDExpr :: C_FDExpr -> TLM ModelInt
tlFDExpr (FDVal v) = return (asExpr v)
tlFDExpr (FDVar i dom) = do
  vm <- getVarMap
  let i'  = fromInteger i
      var = asExpr (ModelIntVar i' :: ModelIntTerm ModelFunctions)
  setVarMap $ Map.insertWith Set.union dom (Set.singleton var) vm
  return var
tlFDExpr (FDParam i) = do
  let i'  = fromInteger i
      par = asExpr (ModelIntVar i' :: ModelIntTerm ModelFunctions)
  return par
tlFDExpr (FDAt xs e) = do
  xs' <- tlFDExprList xs
  e'  <- tlFDExpr e
  return (xs' ! e')
tlFDExpr (FDArith op e1 e2) = do
  e1' <- tlFDExpr e1
  e2' <- tlFDExpr e2
  return (e1' `op'` e2')
  where op' = tlArithOp op
        tlArithOp Plus  = (@+)
        tlArithOp Minus = (@-)
        tlArithOp Mult  = (@*)
tlFDExpr (FDSum xs) = do
  xs' <- tlFDExprList xs
  return (xsum xs')

-- Translation of lists of FD expressions into MCP collections
tlFDExprList :: [C_FDExpr] -> TLM ModelCol
tlFDExprList xs = do
  xs' <- mapM tlFDExpr xs
  return (list xs')

-- Translation of FD constraints into MCP constraints
tlFDConstr :: C_FDConstr -> TLM Model
tlFDConstr (FDConst b) = return (toBoolExpr b)
tlFDConstr (FDRel op e1 e2) = do
  e1' <- tlFDExpr e1
  e2' <- tlFDExpr e2
  return (e1' `op'` e2')
  where op' = tlRelOp op
        tlRelOp Equal     = (@=)
        tlRelOp Diff      = (@/=)
        tlRelOp Less      = (@<)
        tlRelOp LessEqual = (@<=)
tlFDConstr (FDAllDifferent xs) = do
  xs' <- tlFDExprList xs
  return (allDiff xs')
tlFDConstr (FDLoopAll from to constr) = do
  from'   <- tlFDExpr from
  to'     <- tlFDExpr to
  param   <- newParam   -- introduce new parameter of type C_FDExpr
  param'  <- tlFDExpr param
  constr' <- tlFDConstr (constr param)
  return (loopall (from', to') (\x -> ((x @= param') :: Model) @&& constr'))
tlFDConstr (FDAnd c1 c2) = do
  c1' <- tlFDConstr c1
  c2' <- tlFDConstr c2
  return (c1' @&& c2')
tlFDConstr c = error $ "unknown constraint: " ++ show c

-- -----------------------------------------------------------------------------
-- MCP solver solving
-- -----------------------------------------------------------------------------

type OvertonTree = Tree (FDInstance OvertonFD) ModelCol

type GecodeRuntimeTree
  = Tree (FDInstance (GecodeWrappedSolver RuntimeGecodeSolver)) ModelCol

type GecodeSearchTree
  = Tree (FDInstance (GecodeWrappedSolver SearchGecodeSolver)) ModelCol

genMCPModel :: FDSolver s => C_FDConstr -> [C_FDExpr]
            -> TLM (Tree (FDInstance s) ModelCol)
genMCPModel cs lvars = do
  mcpConstr <- tlFDConstr cs
  domConstr <- genDomConstr
  mcpLVars  <- getLabelVars lvars
  let model = domConstr @&& mcpConstr
  return $ genModelTree model mcpLVars
  where
    getLabelVars :: [C_FDExpr] -> TLM ModelCol
    getLabelVars []   = getAllVars
    getLabelVars vars = tlFDExprList vars

    genModelTree :: FDSolver s => Model -> ModelCol
                 -> Tree (FDInstance s) ModelCol
    genModelTree (BoolConst True)  t = return t
    genModelTree (BoolConst False) _ = false
    genModelTree c                 t = (Left c) `addTo` (return t)

genDomConstr :: TLM Model
genDomConstr = do
  vm <- getVarMap
  let domConstrs = map genDomConstr' $ Map.assocs vm
  return $ foldr (@&&) (BoolConst True) domConstrs
  where
    genDomConstr' ((Range l u), vars) = let col = list (Set.elems vars)
                                            dom = (asExpr l, asExpr u)
                                        in forall col (\v -> v @: dom)

external_d_C_solve :: OP_List C_Option -> C_FDConstr -> Cover -> ConstStore
                   -> OP_List (OP_List C_Int)
external_d_C_solve opts cs _ _ = let (solver,strategy) = getOpts opts
                                     solutions = runSolver solver strategy cs []
                                 in toCurry solutions

external_d_C_solveVars :: OP_List C_Option -> C_FDConstr -> OP_List C_FDExpr
                       -> Cover -> ConstStore -> OP_List (OP_List C_Int)
external_d_C_solveVars opts cs lvars _ _
  = let (solver,strategy) = getOpts opts
        solutions = runSolver solver strategy cs (fromCurry lvars)
    in toCurry solutions

isSolver :: C_Option -> Bool
isSolver C_Overton       = True
isSolver C_GecodeRuntime = True
isSolver C_GecodeSearch  = True
isSolver _               = False

-- only the first labeling and the first solving option are used
getOpts :: OP_List C_Option -> (Maybe C_Option, Maybe C_Option)
getOpts opts = let (solver, strategy) = partition isSolver $ fromCurry opts
               in (listToMaybe solver, listToMaybe strategy)

runSolver :: Maybe C_Option -> Maybe C_Option -> C_FDConstr -> [C_FDExpr]
          -> [[Int]]
#ifdef GECODE
runSolver (Just C_GecodeRuntime) mstrat cs lvars = gecodeRuntime mstrat cs lvars
runSolver (Just C_GecodeSearch)  _      cs lvars = gecodeSearch cs lvars
runSolver _                      mstrat cs lvars = overton mstrat cs lvars
#else
runSolver _                      mstrat cs lvars = overton mstrat cs lvars
#endif

gecodeRuntime :: Maybe C_Option -> C_FDConstr -> [C_FDExpr] -> [[Int]]
gecodeRuntime mstrat cs lvars
  = let model = S.evalState (genMCPModel cs lvars) initState
    in map (map fromInteger) $ snd $ MCP.solve dfs fs $
         (model :: GecodeRuntimeTree) >>= labelWith mstrat

gecodeSearch :: C_FDConstr -> [C_FDExpr] -> [[Int]]
gecodeSearch cs lvars
  = let model = S.evalState (genMCPModel cs lvars) initState
    in map (map fromInteger) $ snd $ MCP.solve dfs fs $
        (model :: GecodeSearchTree) >>= (\x -> setSearchMinimize >> return x) >>= labelCol

overton :: Maybe C_Option -> C_FDConstr -> [C_FDExpr] -> [[Int]]
overton mstrat cs lvars
  = let model = S.evalState (genMCPModel cs lvars) initState
    in snd $ MCP.solve dfs fs $ (model :: OvertonTree) >>= labelWith mstrat

-- Label MCP collection with given strategy
labelWith :: (FDSolver s, MonadTree m, TreeSolver m ~ FDInstance s,
              EnumTerm s (FDIntTerm s)) => Maybe C_Option -> ModelCol
                                        -> m [TermBaseType s (FDIntTerm s)]
labelWith mstrat (ColList l) = label $ do
  return $ do
    labelling (maybe inOrder getStrat mstrat) l
    assignments l
  where getStrat C_FirstFail = firstFail
        getStrat C_MiddleOut = middleOut
        getStrat C_EndsOut   = endsOut