{-# LANGUAGE LambdaCase, TupleSections, RecordWildCards, OverloadedStrings #-}
module Lambda.ToStg where

-- Compiler
import GHC
import DynFlags
import Outputable

-- Stg Types
import Module
import Name
import Id
import Unique
import OccName
import StgSyn
import CostCentre
import ForeignCall
import FastString
import BasicTypes
import CoreSyn (AltCon(..))

import PrimOp
import TysWiredIn
import Literal
import MkId
import TyCon

import Control.Monad.State
import Data.List (partition)

import qualified Data.ByteString.Char8 as BS8
import Data.Map (Map)
import qualified Data.Map as Map
import qualified Lambda.Syntax2 as L2

-------------------------------------------------------------------------------
-- Utility
-------------------------------------------------------------------------------

modl :: Module
modl = mkModule mainUnitId (mkModuleName ":Main")

noType :: Type
noType = error "[noType] missing Type value"

primOpMap :: Map L2.Name PrimOp
primOpMap = Map.fromList [(L2.packName . occNameString . primOpOcc $ op, op) | op <- allThePrimOps]

---------------

data Env
  = Env
  { topBindings     :: [StgTopBinding]
  , nameMap         :: Map L2.Name Unique
  , externalMap     :: Map L2.Name L2.External
  , ffiUniqueCount  :: Int
  }

type StgM = State Env

freshFFIUnique :: StgM Unique
freshFFIUnique = state $ \env@Env{..} -> (mkUnique 'f' ffiUniqueCount, env {ffiUniqueCount = succ ffiUniqueCount})

addTopBinding :: StgTopBinding -> StgM ()
addTopBinding b = modify' $ \env@Env{..} -> env {topBindings = b : topBindings}

setExternals :: [L2.External] -> StgM ()
setExternals exts = modify' $ \env@Env{..} -> env {externalMap = Map.fromList [(L2.eName e, e) | e <- exts]}

getNameUnique :: L2.Name -> StgM Unique
getNameUnique n = state $ \env@Env{..} -> case Map.lookup n nameMap of
  Nothing -> (u, env {nameMap = Map.insert n u nameMap}) where u = mkUnique 'u' $ Map.size nameMap
  Just u  -> (u, env)

convertName :: L2.Name -> StgM Name
convertName n = do
  u <- getNameUnique n
  pure $ mkExternalName u modl (mkOccName OccName.varName $ L2.unpackName n) noSrcSpan

convertProgram :: L2.Program -> StgM ()
convertProgram (L2.Program exts sdata defs) = do
  setExternals exts
  mapM_ convertStaticData sdata
  mapM_ convertDef defs

convertStaticData :: L2.StaticData -> StgM ()
convertStaticData L2.StaticData{..} = case sValue of
  L2.StaticString s -> do
    n <- convertName sName
    addTopBinding $ StgTopStringLit (mkVanillaGlobal n noType) s

convertDef :: L2.Def -> StgM ()
convertDef (L2.Def name args exp) = do
  name2 <- convertName name
  args2 <- mapM convertName args
  exp2 <- convertExp exp
  let nameId = mkVanillaGlobal name2 noType
  addTopBinding $ StgTopLifted $ StgNonRec nameId $ StgRhsClosure dontCareCCS stgUnsatOcc [] Updatable [mkVanillaGlobal a noType | a <- args2] exp2

convertRHS :: L2.SimpleExp -> StgM StgRhs
convertRHS = \case
  L2.Con con args -> do
    let dataCon = error "TODO: construct GHC DataCon value"
    args2 <- mapM convertName args
    let stgArgs = [StgVarArg $ mkVanillaGlobal a noType | a <- args2]
    pure $ StgRhsCon dontCareCCS dataCon stgArgs

  L2.Closure vars args body -> do
    vars2 <- mapM convertName vars
    args2 <- mapM convertName args
    body2 <- convertExp body
    pure $ StgRhsClosure dontCareCCS stgUnsatOcc [mkVanillaGlobal a noType | a <- vars2] Updatable [mkVanillaGlobal a noType | a <- args2] body2

  sexp -> error $ "invalid RHS simple exp " ++ show sexp

convertExp :: L2.Bind -> StgM StgExpr
convertExp = \case
  L2.Var name -> do
    name2 <- convertName name
    pure $ StgApp (mkVanillaGlobal name2 noType) []

  L2.Let binds bind -> do
    bind2 <- convertExp bind
    binds2 <- forM binds $ \(name, sexp) -> do
      name2 <- convertName name
      let nameId = mkVanillaGlobal name2 noType
      stgRhs <- convertRHS sexp
      pure $ StgNonRec nameId stgRhs
    pure $ foldr StgLet bind2 binds2

  L2.LetRec binds bind -> do
    bind2 <- convertExp bind
    binds2 <- forM binds $ \(name, sexp) -> do
      name2 <- convertName name
      let nameId = mkVanillaGlobal name2 noType
      stgRhs <- convertRHS sexp
      pure (nameId, stgRhs)
    pure $ StgLet (StgRec binds2) bind2

  L2.LetS binds bind -> do
    bind2 <- convertExp bind
    binds2 <- forM binds $ \(name, sexp) -> do
      name2 <- convertName name
      let nameId  = mkVanillaGlobal name2 noType
          altKind = PrimAlt IntRep -- TODO: use proper type rep
      sexp2 <- convertStrictExp nameId sexp
      pure (nameId, sexp2, altKind)

    let mkCase (nameId, exp, altKind) tailExp = StgCase exp nameId altKind [(DEFAULT, [], tailExp)]
    pure $ foldr mkCase bind2 binds2


convertLiteral :: L2.Lit -> Literal
convertLiteral = \case
  L2.LInt64 a     -> LitNumber LitNumInt64  (fromIntegral a) noType
  L2.LWord64 a    -> LitNumber LitNumWord64 (fromIntegral a) noType
  L2.LFloat a     -> MachFloat a
  L2.LDouble a    -> MachDouble a
  L2.LChar a      -> MachChar a
  L2.LString a    -> MachStr a
  L2.LLabelAddr a -> MachLabel (mkFastString $ BS8.unpack a) (error "L2.LLabelAddr - arg size in bytes TODO") (error "L2.LLabelAddr - funcion or data TODO")
  L2.LNullAddr    -> MachNullAddr
  l               -> error $ "unsupported literal: " ++ show l

convertStrictExp :: Id -> L2.SimpleExp -> StgM StgExpr
convertStrictExp resultId = \case
  L2.App name args -> do
    name2 <- convertName name
    args2 <- mapM convertName args
    extMap <- gets externalMap
    let stgArgs = [StgVarArg $ mkVanillaGlobal a noType | a <- args2]
    case Map.lookup name extMap of
      Nothing -> pure $ StgApp (mkVanillaGlobal name2 noType) stgArgs
      Just L2.External{..} -> case eKind of
        L2.PrimOp -> case Map.lookup name primOpMap of
          Nothing -> error $ "unknown primop: " ++ show (L2.unpackName name)
          Just op -> pure $ StgOpApp (StgPrimOp op) stgArgs noType -- TODO: result type
        L2.FFI -> do
          let callSpec = CCallSpec (StaticTarget NoSourceText (mkFastString $ L2.unpackName name) Nothing True) CCallConv PlayRisky
          u <- freshFFIUnique
          pure $ StgOpApp (StgFCallOp (CCall callSpec) u) stgArgs noType -- TODO: result type

  L2.Con name args -> do
    let dataCon = error "TODO: construct GHC DataCon value"
    name2 <- convertName name
    args2 <- mapM convertName args
    let types = error "TODO: construct StgConApp [Type] value"
    pure $ StgConApp dataCon [StgVarArg $ mkVanillaGlobal a noType | a <- args2] types

  L2.Lit L2.LToken{} -> pure $ StgApp voidPrimId []
  L2.Lit l -> pure . StgLit $ convertLiteral l

  L2.Case name alts -> do
    name2 <- convertName name
    let altType = error "TODO: alt type"
        (defaultAlts, normalAlts) = partition (\(L2.Alt _ pat _) -> pat == L2.DefaultPat) alts
    alts2 <- mapM convertAlt $ defaultAlts ++ normalAlts
    pure $ StgCase (StgApp (mkVanillaGlobal name2 noType) []) resultId altType alts2

convertAlt :: L2.Alt -> StgM StgAlt
convertAlt (L2.Alt name pat bind) = do
  bind2 <- convertExp bind
  (altCon, params) <- case pat of
        L2.NodePat conName args -> do
          let dataCon = error "DataAlt TODO: create DataCon properly"
          args2 <- mapM convertName args
          pure (DataAlt dataCon, [mkVanillaGlobal a noType | a <- args2])
        L2.LitPat l -> pure (LitAlt $ convertLiteral l, [])
        L2.DefaultPat -> pure (DEFAULT, [])
  pure $ (altCon, params, bind2)
