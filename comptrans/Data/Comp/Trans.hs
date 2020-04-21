{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE CPP             #-}

-- |
-- 
-- GHC has a phase restriction which prevents code generated by Template Haskell
-- being referred to by Template Haskell in the same file. Thus, when using this
-- library, you will need to spread invocations out over several files.
-- 
-- We will refer to the following example in the documentation:
-- 
-- @
-- module Foo where
-- data Arith = Add Atom Atom
-- data Atom = Var String | Const Lit
-- data Lit = Lit Int
-- @
module Data.Comp.Trans (
    runCompTrans
  , withSubstitutions
  , withExcludedNames
  , withAnnotationProp

  , standardExcludedNames
  , defaultPropAnn
  , defaultUnpropAnn
  
  , deriveMultiComp
  , generateNameLists
  , makeSumType

  , getLabels
  , getTypeParamVars

  , T.deriveTrans
  , U.deriveUntrans
  ) where

import Control.Monad ( liftM )
import Control.Monad.Trans ( lift )

import Data.Comp.Multi ( (:+:) )
import Data.Data ( Data )

import Language.Haskell.TH.Quote ( dataToExpQ )
import Language.Haskell.TH

import qualified Data.Comp.Trans.DeriveTrans as T
import qualified Data.Comp.Trans.DeriveUntrans as U
import Data.Comp.Trans.DeriveMulti
import Data.Comp.Trans.Collect
import Data.Comp.Trans.Util as Util


-- |
-- Declares a multi-sorted compositional datatype isomorphic to the
-- given ADT.
-- 
-- /e.g./
-- 
-- @
-- import qualified Foo as F
-- runCompTrans $ deriveMultiComp ''F.Arith
-- @
-- 
-- will create
-- 
-- @
-- data ArithL
-- data AtomL
-- data LitL
-- 
-- data Arith e l where
--   Add :: e AtomL -> e AtomL -> Arith e ArithL
-- 
-- data Atom e l where
--   Var :: String -> Atom e AtomL
--   Const :: e LitL -> Atom e AtomL
-- 
-- data Lit (e :: * -> *) l where
--   Lit :: Int -> Lit e LitL
-- @
deriveMultiComp :: Name -> CompTrans [Dec]
deriveMultiComp root = do descs <- collectTypes root
                          withAllTypes descs $ liftM concat $ mapM deriveMulti descs

-- |
-- 
-- /e.g./
-- 
-- @
-- runCompTrans $ generateNameLists ''Arith
-- @
-- 
-- will create
-- 
-- @
-- origASTTypes = [mkName "Foo.Arith", mkName "Foo.Atom", mkName "Foo.Lit"]
-- newASTTypes  = [mkName "Arith", mkName "Atom", mkName "Lit"]
-- newASTLabels = map ConT [mkName "ArithL", mkName "AtomL', mkName "LitL"]
-- @
generateNameLists :: Name -> CompTrans [Dec]
generateNameLists root = do
    descs <- collectTypes root
    nameList1 <- lift $ mkList ''Name (mkName "origASTTypes") descs
    nameList2 <- lift $ mkList ''Name (mkName "newASTTypes") (map transName descs)

    return $ nameList1 ++ nameList2
  where

    mkList :: Data t => Name -> Name -> [t] -> Q [Dec]
    mkList tNm name contents = sequence [ sigD name (appT listT (conT tNm))
                                        , valD (varP name) (normalB namesExp) []
                                        ]
      where
        namesExp = dataToExpQ (const Nothing) contents

getLabels :: [Name] -> CompTrans [Type]
getLabels nms = mapM toLabel nms
  where
    toLabel n = do
#if __GLASGOW_HASKELL__ < 800
      TyConI (DataD _ n' _ _ _) <- lift $ reify $ nameLab n
#else
      TyConI (DataD _ n' _ _ _ _) <- lift $ reify $ nameLab n
#endif
      return $ ConT n'

getTypeParamVars :: [Name] -> CompTrans [Name]
getTypeParamVars = liftM concat . mapM getTypeArgs

-- |
-- Folds together names with @(`:+:`)@.
-- 
-- /e.g./
-- 
-- @
-- import qualified Foo as F
-- runCompTrans $ deriveMult ''F.Arith
-- runCompTrans $ makeSumType \"ArithSig\" [''Arith, ''Atom, ''Lit]
-- @
-- 
-- will create
-- 
-- @
-- type ArithSig = Arith :+: Atom :+: Lit
-- @
-- 
-- You can use `generateNameLists` to avoid spelling out the names manually
makeSumType :: String -> [Name] -> CompTrans [Dec]
makeSumType nm types = lift $ sequence $ [tySynD (mkName nm) [] $ sumType types]
  where
    sumType []     = fail "Attempting to make empty sum type"
    sumType [t]    = conT t
    sumType (t:ts) = appT (appT (conT ''(:+:)) (conT t)) (sumType ts)
