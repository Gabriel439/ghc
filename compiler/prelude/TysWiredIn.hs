{-
(c) The GRASP Project, Glasgow University, 1994-1998

\section[TysWiredIn]{Wired-in knowledge about {\em non-primitive} types}
-}

{-# LANGUAGE CPP #-}

-- | This module is about types that can be defined in Haskell, but which
--   must be wired into the compiler nonetheless.  C.f module TysPrim
module TysWiredIn (
        -- * All wired in things
        wiredInTyCons, isBuiltInOcc_maybe,

        -- * Bool
        boolTy, boolTyCon, boolTyCon_RDR, boolTyConName,
        trueDataCon,  trueDataConId,  true_RDR,
        falseDataCon, falseDataConId, false_RDR,
        promotedFalseDataCon, promotedTrueDataCon,

        -- * Ordering
        orderingTyCon,
        ltDataCon, ltDataConId,
        eqDataCon, eqDataConId,
        gtDataCon, gtDataConId,
        promotedLTDataCon, promotedEQDataCon, promotedGTDataCon,

        -- * Char
        charTyCon, charDataCon, charTyCon_RDR,
        charTy, stringTy, charTyConName,

        -- * Double
        doubleTyCon, doubleDataCon, doubleTy, doubleTyConName,

        -- * Float
        floatTyCon, floatDataCon, floatTy, floatTyConName,

        -- * Int
        intTyCon, intDataCon, intTyCon_RDR, intDataCon_RDR, intTyConName,
        intTy,

        -- * Word
        wordTyCon, wordDataCon, wordTyConName, wordTy,

        -- * Word8
        word8TyCon, word8DataCon, word8TyConName, word8Ty,

        -- * List
        listTyCon, listTyCon_RDR, listTyConName, listTyConKey,
        nilDataCon, nilDataConName, nilDataConKey,
        consDataCon_RDR, consDataCon, consDataConName,
        promotedNilDataCon, promotedConsDataCon,

        mkListTy,

        -- * Maybe
        maybeTyCon, maybeTyConName,
        nothingDataCon, nothingDataConName, promotedNothingDataCon,
        justDataCon, justDataConName, promotedJustDataCon,

        -- * Tuples
        mkTupleTy, mkBoxedTupleTy,
        tupleTyCon, tupleDataCon, tupleTyConName,
        promotedTupleDataCon,
        unitTyCon, unitDataCon, unitDataConId, unitTy, unitTyConKey,
        pairTyCon,
        unboxedUnitTyCon, unboxedUnitDataCon,
        cTupleTyConName, cTupleTyConNames, isCTupleTyConName,

        -- * Kinds
        typeNatKindCon, typeNatKind, typeSymbolKindCon, typeSymbolKind,
        isLiftedTypeKindTyConName, liftedTypeKind, constraintKind,
        starKindTyCon, starKindTyConName,
        unicodeStarKindTyCon, unicodeStarKindTyConName,
        liftedTypeKindTyCon, constraintKindTyCon,

        -- * Parallel arrays
        mkPArrTy,
        parrTyCon, parrFakeCon, isPArrTyCon, isPArrFakeCon,
        parrTyCon_RDR, parrTyConName,

        -- * Equality predicates
        heqTyCon, heqClass, heqDataCon,
        coercibleTyCon, coercibleDataCon, coercibleClass,

        mkWiredInTyConName, -- This is used in TcTypeNats to define the
                            -- built-in functions for evaluation.

        mkWiredInIdName,    -- used in MkId

        -- * Type representations
        trModuleTyCon, trModuleDataCon,
        trNameTyCon, trNameSDataCon, trNameDDataCon,
        trTyConTyCon, trTyConDataCon,

        -- * Levity
        levityTy, levityTyCon, liftedDataCon, unliftedDataCon,
        liftedPromDataCon, unliftedPromDataCon,
        liftedDataConTy, unliftedDataConTy,
        liftedDataConName, unliftedDataConName,
    ) where

#include "HsVersions.h"
#include "MachDeps.h"

import {-# SOURCE #-} MkId( mkDataConWorkId, mkDictSelId )

-- friends:
import PrelNames
import TysPrim

-- others:
import CoAxiom
import Id
import Constants        ( mAX_TUPLE_SIZE, mAX_CTUPLE_SIZE )
import Module           ( Module )
import Type
import DataCon
import {-# SOURCE #-} ConLike
import TyCon
import Class            ( Class, mkClass )
import RdrName
import Name
import NameSet          ( NameSet, mkNameSet, elemNameSet )
import BasicTypes       ( Arity, RecFlag(..), Boxity(..),
                          TupleSort(..) )
import ForeignCall
import SrcLoc           ( noSrcSpan )
import Unique
import Data.Array
import FastString
import Outputable
import Util
import BooleanFormula   ( mkAnd )

alpha_tyvar :: [TyVar]
alpha_tyvar = [alphaTyVar]

alpha_ty :: [Type]
alpha_ty = [alphaTy]

{-
************************************************************************
*                                                                      *
\subsection{Wired in type constructors}
*                                                                      *
************************************************************************

If you change which things are wired in, make sure you change their
names in PrelNames, so they use wTcQual, wDataQual, etc
-}

-- This list is used only to define PrelInfo.wiredInThings. That in turn
-- is used to initialise the name environment carried around by the renamer.
-- This means that if we look up the name of a TyCon (or its implicit binders)
-- that occurs in this list that name will be assigned the wired-in key we
-- define here.
--
-- Because of their infinite nature, this list excludes tuples, Any and implicit
-- parameter TyCons. Instead, we have a hack in lookupOrigNameCache to deal with
-- these names.
--
-- See also Note [Known-key names]
wiredInTyCons :: [TyCon]

wiredInTyCons = [ unitTyCon     -- Not treated like other tuples, because
                                -- it's defined in GHC.Base, and there's only
                                -- one of it.  We put it in wiredInTyCons so
                                -- that it'll pre-populate the name cache, so
                                -- the special case in lookupOrigNameCache
                                -- doesn't need to look out for it
              , boolTyCon
              , charTyCon
              , doubleTyCon
              , floatTyCon
              , intTyCon
              , wordTyCon
              , word8TyCon
              , listTyCon
              , maybeTyCon
              , parrTyCon
              , heqTyCon
              , coercibleTyCon
              , typeNatKindCon
              , typeSymbolKindCon
              , levityTyCon
              , constraintKindTyCon
              , liftedTypeKindTyCon
              , starKindTyCon
              , unicodeStarKindTyCon
              , trModuleTyCon
              , trTyConTyCon
              , trNameTyCon
              ]

mkWiredInTyConName :: BuiltInSyntax -> Module -> FastString -> Unique -> TyCon -> Name
mkWiredInTyConName built_in modu fs unique tycon
  = mkWiredInName modu (mkTcOccFS fs) unique
                  (ATyCon tycon)        -- Relevant TyCon
                  built_in

mkWiredInDataConName :: BuiltInSyntax -> Module -> FastString -> Unique -> DataCon -> Name
mkWiredInDataConName built_in modu fs unique datacon
  = mkWiredInName modu (mkDataOccFS fs) unique
                  (AConLike (RealDataCon datacon))    -- Relevant DataCon
                  built_in

mkWiredInIdName :: Module -> FastString -> Unique -> Id -> Name
mkWiredInIdName mod fs uniq id
 = mkWiredInName mod (mkOccNameFS Name.varName fs) uniq (AnId id) UserSyntax

-- See Note [Kind-changing of (~) and Coercible]
-- in libraries/ghc-prim/GHC/Types.hs
heqTyConName, heqDataConName, heqSCSelIdName :: Name
heqTyConName   = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "~~")   heqTyConKey      heqTyCon
heqDataConName = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "Eq#")  heqDataConKey heqDataCon
heqSCSelIdName = mkWiredInIdName gHC_TYPES (fsLit "HEq_sc") heqSCSelIdKey heqSCSelId

-- See Note [Kind-changing of (~) and Coercible] in libraries/ghc-prim/GHC/Types.hs
coercibleTyConName, coercibleDataConName, coercibleSCSelIdName :: Name
coercibleTyConName   = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Coercible")  coercibleTyConKey   coercibleTyCon
coercibleDataConName = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "MkCoercible") coercibleDataConKey coercibleDataCon
coercibleSCSelIdName = mkWiredInIdName gHC_TYPES (fsLit "Coercible_sc") coercibleSCSelIdKey coercibleSCSelId

charTyConName, charDataConName, intTyConName, intDataConName :: Name
charTyConName     = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Char") charTyConKey charTyCon
charDataConName   = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "C#") charDataConKey charDataCon
intTyConName      = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Int") intTyConKey   intTyCon
intDataConName    = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "I#") intDataConKey  intDataCon

boolTyConName, falseDataConName, trueDataConName :: Name
boolTyConName     = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Bool") boolTyConKey boolTyCon
falseDataConName  = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "False") falseDataConKey falseDataCon
trueDataConName   = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "True")  trueDataConKey  trueDataCon

listTyConName, nilDataConName, consDataConName :: Name
listTyConName     = mkWiredInTyConName   BuiltInSyntax gHC_TYPES (fsLit "[]") listTyConKey listTyCon
nilDataConName    = mkWiredInDataConName BuiltInSyntax gHC_TYPES (fsLit "[]") nilDataConKey nilDataCon
consDataConName   = mkWiredInDataConName BuiltInSyntax gHC_TYPES (fsLit ":") consDataConKey consDataCon

maybeTyConName, nothingDataConName, justDataConName :: Name
maybeTyConName     = mkWiredInTyConName   UserSyntax gHC_BASE (fsLit "Maybe")
                                          maybeTyConKey maybeTyCon
nothingDataConName = mkWiredInDataConName UserSyntax gHC_BASE (fsLit "Nothing")
                                          nothingDataConKey nothingDataCon
justDataConName    = mkWiredInDataConName UserSyntax gHC_BASE (fsLit "Just")
                                          justDataConKey justDataCon

wordTyConName, wordDataConName, word8TyConName, word8DataConName :: Name
wordTyConName      = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Word")   wordTyConKey     wordTyCon
wordDataConName    = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "W#")     wordDataConKey   wordDataCon
word8TyConName     = mkWiredInTyConName   UserSyntax gHC_WORD  (fsLit "Word8")  word8TyConKey    word8TyCon
word8DataConName   = mkWiredInDataConName UserSyntax gHC_WORD  (fsLit "W8#")    word8DataConKey  word8DataCon

floatTyConName, floatDataConName, doubleTyConName, doubleDataConName :: Name
floatTyConName     = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Float")  floatTyConKey    floatTyCon
floatDataConName   = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "F#")     floatDataConKey  floatDataCon
doubleTyConName    = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Double") doubleTyConKey   doubleTyCon
doubleDataConName  = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "D#")     doubleDataConKey doubleDataCon

-- Kinds
typeNatKindConName, typeSymbolKindConName :: Name
typeNatKindConName    = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "Nat")    typeNatKindConNameKey    typeNatKindCon
typeSymbolKindConName = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "Symbol") typeSymbolKindConNameKey typeSymbolKindCon

constraintKindTyConName :: Name
constraintKindTyConName = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "Constraint") constraintKindTyConKey   constraintKindTyCon

liftedTypeKindTyConName, starKindTyConName, unicodeStarKindTyConName
  :: Name
liftedTypeKindTyConName = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "Type") liftedTypeKindTyConKey liftedTypeKindTyCon
starKindTyConName = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "*") starKindTyConKey starKindTyCon
unicodeStarKindTyConName = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "★") unicodeStarKindTyConKey unicodeStarKindTyCon

levityTyConName, liftedDataConName, unliftedDataConName :: Name
levityTyConName     = mkWiredInTyConName   UserSyntax gHC_TYPES (fsLit "Levity") levityTyConKey levityTyCon
liftedDataConName   = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "Lifted") liftedDataConKey liftedDataCon
unliftedDataConName = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "Unlifted") unliftedDataConKey unliftedDataCon

parrTyConName, parrDataConName :: Name
parrTyConName   = mkWiredInTyConName   BuiltInSyntax
                    gHC_PARR' (fsLit "[::]") parrTyConKey parrTyCon
parrDataConName = mkWiredInDataConName UserSyntax
                    gHC_PARR' (fsLit "PArr") parrDataConKey parrDataCon

boolTyCon_RDR, false_RDR, true_RDR, intTyCon_RDR, charTyCon_RDR,
    intDataCon_RDR, listTyCon_RDR, consDataCon_RDR, parrTyCon_RDR :: RdrName
boolTyCon_RDR   = nameRdrName boolTyConName
false_RDR       = nameRdrName falseDataConName
true_RDR        = nameRdrName trueDataConName
intTyCon_RDR    = nameRdrName intTyConName
charTyCon_RDR   = nameRdrName charTyConName
intDataCon_RDR  = nameRdrName intDataConName
listTyCon_RDR   = nameRdrName listTyConName
consDataCon_RDR = nameRdrName consDataConName
parrTyCon_RDR   = nameRdrName parrTyConName

{-
************************************************************************
*                                                                      *
\subsection{mkWiredInTyCon}
*                                                                      *
************************************************************************
-}

pcNonRecDataTyCon :: Name -> Maybe CType -> [TyVar] -> [DataCon] -> TyCon
-- Not an enumeration
pcNonRecDataTyCon = pcTyCon False NonRecursive

-- This function assumes that the types it creates have all parameters at
-- Representational role, and that there is no kind polymorphism.
pcTyCon :: Bool -> RecFlag -> Name -> Maybe CType -> [TyVar] -> [DataCon] -> TyCon
pcTyCon is_enum is_rec name cType tyvars cons
  = mkAlgTyCon name
                (mkFunTys (map tyVarKind tyvars) liftedTypeKind)
                tyvars
                (map (const Representational) tyvars)
                cType
                []              -- No stupid theta
                (DataTyCon cons is_enum)
                (VanillaAlgTyCon (mkPrelTyConRepName name))
                is_rec
                False           -- Not in GADT syntax

pcDataCon :: Name -> [TyVar] -> [Type] -> TyCon -> DataCon
pcDataCon n univs = pcDataConWithFixity False n univs []  -- no ex_tvs

pcDataConWithFixity :: Bool      -- ^ declared infix?
                    -> Name      -- ^ datacon name
                    -> [TyVar]   -- ^ univ tyvars
                    -> [TyVar]   -- ^ ex tyvars
                    -> [Type]    -- ^ args
                    -> TyCon
                    -> DataCon
pcDataConWithFixity infx n = pcDataConWithFixity' infx n (incrUnique (nameUnique n))
-- The Name's unique is the first of two free uniques;
-- the first is used for the datacon itself,
-- the second is used for the "worker name"
--
-- To support this the mkPreludeDataConUnique function "allocates"
-- one DataCon unique per pair of Ints.

pcDataConWithFixity' :: Bool -> Name -> Unique -> [TyVar] -> [TyVar]
                     -> [Type] -> TyCon -> DataCon
-- The Name should be in the DataName name space; it's the name
-- of the DataCon itself.

pcDataConWithFixity' declared_infix dc_name wrk_key tyvars ex_tyvars arg_tys tycon
  = data_con
  where
    data_con = mkDataCon dc_name declared_infix prom_info
                (map (const no_bang) arg_tys)
                []      -- No labelled fields
                tyvars
                ex_tyvars
                []      -- No equality spec
                []      -- No theta
                arg_tys (mkTyConApp tycon (mkTyVarTys tyvars))
                tycon
                []      -- No stupid theta
                (mkDataConWorkId wrk_name data_con)
                NoDataConRep    -- Wired-in types are too simple to need wrappers

    no_bang = HsSrcBang Nothing NoSrcUnpack NoSrcStrict

    modu     = ASSERT( isExternalName dc_name )
               nameModule dc_name
    dc_occ   = nameOccName dc_name
    wrk_occ  = mkDataConWorkerOcc dc_occ
    wrk_name = mkWiredInName modu wrk_occ wrk_key
                             (AnId (dataConWorkId data_con)) UserSyntax

    prom_info = mkPrelTyConRepName dc_name

{-
************************************************************************
*                                                                      *
      Kinds
*                                                                      *
************************************************************************
-}

typeNatKindCon, typeSymbolKindCon :: TyCon
-- data Nat
-- data Symbol
typeNatKindCon    = pcTyCon False NonRecursive typeNatKindConName    Nothing [] []
typeSymbolKindCon = pcTyCon False NonRecursive typeSymbolKindConName Nothing [] []

typeNatKind, typeSymbolKind :: Kind
typeNatKind    = mkTyConTy typeNatKindCon
typeSymbolKind = mkTyConTy typeSymbolKindCon

constraintKindTyCon :: TyCon
constraintKindTyCon = pcTyCon False NonRecursive constraintKindTyConName
                              Nothing [] []

liftedTypeKind, constraintKind :: Kind
liftedTypeKind   = tYPE liftedDataConTy
constraintKind   = mkTyConApp constraintKindTyCon []


{-
************************************************************************
*                                                                      *
                Stuff for dealing with tuples
*                                                                      *
************************************************************************

Note [How tuples work]  See also Note [Known-key names] in PrelNames
~~~~~~~~~~~~~~~~~~~~~~
* There are three families of tuple TyCons and corresponding
  DataCons, expressed by the type BasicTypes.TupleSort:
    data TupleSort = BoxedTuple | UnboxedTuple | ConstraintTuple

* All three families are AlgTyCons, whose AlgTyConRhs is TupleTyCon

* BoxedTuples
    - A wired-in type
    - Data type declarations in GHC.Tuple
    - The data constructors really have an info table

* UnboxedTuples
    - A wired-in type
    - Have a pretend DataCon, defined in GHC.Prim,
      but no actual declaration and no info table

* ConstraintTuples
    - Are known-key rather than wired-in. Reason: it's awkward to
      have all the superclass selectors wired-in.
    - Declared as classes in GHC.Classes, e.g.
         class (c1,c2) => (c1,c2)
    - Given constraints: the superclasses automatically become available
    - Wanted constraints: there is a built-in instance
         instance (c1,c2) => (c1,c2)
    - Currently just go up to 16; beyond that
      you have to use manual nesting
    - Their OccNames look like (%,,,%), so they can easily be
      distinguished from term tuples.  But (following Haskell) we
      pretty-print saturated constraint tuples with round parens; see
      BasicTypes.tupleParens.

* In quite a lot of places things are restrcted just to
  BoxedTuple/UnboxedTuple, and then we used BasicTypes.Boxity to distinguish
  E.g. tupleTyCon has a Boxity argument

* When looking up an OccName in the original-name cache
  (IfaceEnv.lookupOrigNameCache), we spot the tuple OccName to make sure
  we get the right wired-in name.  This guy can't tell the difference
  between BoxedTuple and ConstraintTuple (same OccName!), so tuples
  are not serialised into interface files using OccNames at all.
-}

isBuiltInOcc_maybe :: OccName -> Maybe Name
-- Built in syntax isn't "in scope" so these OccNames
-- map to wired-in Names with BuiltInSyntax
isBuiltInOcc_maybe occ
  = case occNameString occ of
        "[]"             -> choose_ns listTyConName nilDataConName
        ":"              -> Just consDataConName
        "[::]"           -> Just parrTyConName
        "()"             -> tup_name Boxed      0
        "(##)"           -> tup_name Unboxed    0
        '(':',':rest     -> parse_tuple Boxed   2 rest
        '(':'#':',':rest -> parse_tuple Unboxed 2 rest
        _other           -> Nothing
  where
    ns = occNameSpace occ

    parse_tuple sort n rest
      | (',' : rest2) <- rest   = parse_tuple sort (n+1) rest2
      | tail_matches sort rest  = tup_name sort n
      | otherwise               = Nothing

    tail_matches Boxed   ")" = True
    tail_matches Unboxed "#)" = True
    tail_matches _       _    = False

    tup_name boxity arity
      = choose_ns (getName (tupleTyCon   boxity arity))
                  (getName (tupleDataCon boxity arity))

    choose_ns tc dc
      | isTcClsNameSpace ns   = Just tc
      | isDataConNameSpace ns = Just dc
      | otherwise             = pprPanic "tup_name" (ppr occ)

mkTupleOcc :: NameSpace -> Boxity -> Arity -> OccName
mkTupleOcc ns sort ar = mkOccName ns str
  where
    -- No need to cache these, the caching is done in mk_tuple
    str = case sort of
                Unboxed    -> '(' : '#' : commas ++ "#)"
                Boxed      -> '(' : commas ++ ")"

    commas = take (ar-1) (repeat ',')

mkCTupleOcc :: NameSpace -> Arity -> OccName
mkCTupleOcc ns ar = mkOccName ns str
  where
    str    = "(%" ++ commas ++ "%)"
    commas = take (ar-1) (repeat ',')

cTupleTyConName :: Arity -> Name
cTupleTyConName arity
  = mkExternalName (mkCTupleTyConUnique arity) gHC_CLASSES
                   (mkCTupleOcc tcName arity) noSrcSpan
  -- The corresponding DataCon does not have a known-key name

cTupleTyConNames :: [Name]
cTupleTyConNames = map cTupleTyConName (0 : [2..mAX_CTUPLE_SIZE])

cTupleTyConNameSet :: NameSet
cTupleTyConNameSet = mkNameSet cTupleTyConNames

isCTupleTyConName :: Name -> Bool
-- Use Type.isCTupleClass where possible
isCTupleTyConName n
 = ASSERT2( isExternalName n, ppr n )
   nameModule n == gHC_CLASSES
   && n `elemNameSet` cTupleTyConNameSet

tupleTyCon :: Boxity -> Arity -> TyCon
tupleTyCon sort i | i > mAX_TUPLE_SIZE = fst (mk_tuple sort i)  -- Build one specially
tupleTyCon Boxed   i = fst (boxedTupleArr   ! i)
tupleTyCon Unboxed i = fst (unboxedTupleArr ! i)

tupleTyConName :: TupleSort -> Arity -> Name
tupleTyConName ConstraintTuple a = cTupleTyConName a
tupleTyConName BoxedTuple      a = tyConName (tupleTyCon Boxed a)
tupleTyConName UnboxedTuple    a = tyConName (tupleTyCon Unboxed a)

promotedTupleDataCon :: Boxity -> Arity -> TyCon
promotedTupleDataCon boxity i = promoteDataCon (tupleDataCon boxity i)

tupleDataCon :: Boxity -> Arity -> DataCon
tupleDataCon sort i | i > mAX_TUPLE_SIZE = snd (mk_tuple sort i)    -- Build one specially
tupleDataCon Boxed   i = snd (boxedTupleArr   ! i)
tupleDataCon Unboxed i = snd (unboxedTupleArr ! i)

boxedTupleArr, unboxedTupleArr :: Array Int (TyCon,DataCon)
boxedTupleArr   = listArray (0,mAX_TUPLE_SIZE) [mk_tuple Boxed   i | i <- [0..mAX_TUPLE_SIZE]]
unboxedTupleArr = listArray (0,mAX_TUPLE_SIZE) [mk_tuple Unboxed i | i <- [0..mAX_TUPLE_SIZE]]

mk_tuple :: Boxity -> Int -> (TyCon,DataCon)
mk_tuple boxity arity = (tycon, tuple_con)
  where
        tycon   = mkTupleTyCon tc_name tc_kind tc_arity tyvars tuple_con
                               tup_sort flavour

        (tup_sort, modu, tc_kind, tc_arity, tyvars, tyvar_tys, flavour)
          = case boxity of
          Boxed ->
            let boxed_tyvars = take arity alphaTyVars in
            ( BoxedTuple
            , gHC_TUPLE
            , mkFunTys (nOfThem arity liftedTypeKind) liftedTypeKind
            , arity
            , boxed_tyvars
            , mkTyVarTys boxed_tyvars
            , VanillaAlgTyCon (mkPrelTyConRepName tc_name)
            )
            -- See Note [Unboxed tuple levity vars] in TyCon
          Unboxed ->
            let all_tvs = mkTemplateTyVars (replicate arity levityTy ++
                                            map (tYPE . mkTyVarTy) (take arity all_tvs))
                   -- NB: This must be one call to mkTemplateTyVars, to make
                   -- sure that all the uniques are different
                (lev_tvs, open_tvs) = splitAt arity all_tvs
            in
            ( UnboxedTuple
            , gHC_PRIM
            , mkSpecForAllTys lev_tvs $
              mkFunTys (map tyVarKind open_tvs) $
              unliftedTypeKind
            , arity * 2
            , all_tvs
            , mkTyVarTys open_tvs
            , UnboxedAlgTyCon
            )

        tc_name = mkWiredInName modu (mkTupleOcc tcName boxity arity) tc_uniq
                                (ATyCon tycon) BuiltInSyntax
        tuple_con = pcDataCon dc_name tyvars tyvar_tys tycon
        dc_name   = mkWiredInName modu (mkTupleOcc dataName boxity arity) dc_uniq
                                  (AConLike (RealDataCon tuple_con)) BuiltInSyntax
        tc_uniq   = mkTupleTyConUnique   boxity arity
        dc_uniq   = mkTupleDataConUnique boxity arity

unitTyCon :: TyCon
unitTyCon = tupleTyCon Boxed 0

unitTyConKey :: Unique
unitTyConKey = getUnique unitTyCon

unitDataCon :: DataCon
unitDataCon   = head (tyConDataCons unitTyCon)

unitDataConId :: Id
unitDataConId = dataConWorkId unitDataCon

pairTyCon :: TyCon
pairTyCon = tupleTyCon Boxed 2

unboxedUnitTyCon :: TyCon
unboxedUnitTyCon = tupleTyCon Unboxed 0

unboxedUnitDataCon :: DataCon
unboxedUnitDataCon = tupleDataCon   Unboxed 0


{- *********************************************************************
*                                                                      *
              Equality types and classes
*                                                                      *
********************************************************************* -}

-- See Note [The equality types story] in TysPrim
heqTyCon, coercibleTyCon :: TyCon
heqClass, coercibleClass :: Class
heqDataCon, coercibleDataCon :: DataCon
heqSCSelId, coercibleSCSelId :: Id

(heqTyCon, heqClass, heqDataCon, heqSCSelId)
  = (tycon, klass, datacon, sc_sel_id)
  where
    tycon     = mkClassTyCon heqTyConName kind tvs roles
                             rhs klass NonRecursive
                             (mkPrelTyConRepName heqTyConName)
    klass     = mkClass tvs [] [sc_pred] [sc_sel_id] [] [] (mkAnd []) tycon
    datacon   = pcDataCon heqDataConName tvs [sc_pred] tycon

    kind      = mkSpecForAllTys [kv1, kv2] $ mkFunTys [k1, k2] constraintKind
    kv1:kv2:_ = drop 9 alphaTyVars -- gets "j" and "k"
    k1        = mkTyVarTy kv1
    k2        = mkTyVarTy kv2
    [av,bv]   = mkTemplateTyVars [k1, k2]
    tvs       = [kv1, kv2, av, bv]
    roles     = [Nominal, Nominal, Nominal, Nominal]
    rhs       = DataTyCon { data_cons = [datacon], is_enum = False }

    sc_pred   = mkTyConApp eqPrimTyCon (mkTyVarTys tvs)
    sc_sel_id = mkDictSelId heqSCSelIdName klass

(coercibleTyCon, coercibleClass, coercibleDataCon, coercibleSCSelId)
  = (tycon, klass, datacon, sc_sel_id)
  where
    tycon     = mkClassTyCon coercibleTyConName kind tvs roles
                             rhs klass NonRecursive
                             (mkPrelTyConRepName coercibleTyConName)
    klass     = mkClass tvs [] [sc_pred] [sc_sel_id] [] [] (mkAnd []) tycon
    datacon   = pcDataCon coercibleDataConName tvs [sc_pred] tycon

    kind      = mkSpecForAllTys [kKiVar] $ mkFunTys [k, k] constraintKind
    k         = mkTyVarTy kKiVar
    [av,bv]   = mkTemplateTyVars [k, k]
    tvs       = [kKiVar, av, bv]
    roles     = [Nominal, Representational, Representational]
    rhs       = DataTyCon { data_cons = [datacon], is_enum = False }

    sc_pred   = mkTyConApp eqReprPrimTyCon [k, k, mkTyVarTy av, mkTyVarTy bv]
    sc_sel_id = mkDictSelId coercibleSCSelIdName klass


{- *********************************************************************
*                                                                      *
                Kinds and levity
*                                                                      *
********************************************************************* -}

-- For information about the usage of the following type, see Note [TYPE]
-- in module TysPrim
levityTy :: Type
levityTy = mkTyConTy levityTyCon

levityTyCon :: TyCon
levityTyCon = pcTyCon True NonRecursive levityTyConName
                      Nothing [] [liftedDataCon, unliftedDataCon]

liftedDataCon, unliftedDataCon :: DataCon
liftedDataCon   = pcDataCon liftedDataConName [] [] levityTyCon
unliftedDataCon = pcDataCon unliftedDataConName [] [] levityTyCon

liftedPromDataCon, unliftedPromDataCon :: TyCon
liftedPromDataCon   = promoteDataCon liftedDataCon
unliftedPromDataCon = promoteDataCon unliftedDataCon

liftedDataConTy, unliftedDataConTy :: Type
liftedDataConTy   = mkTyConTy liftedPromDataCon
unliftedDataConTy = mkTyConTy unliftedPromDataCon

liftedTypeKindTyCon, starKindTyCon, unicodeStarKindTyCon :: TyCon

   -- See Note [TYPE] in TysPrim
liftedTypeKindTyCon   = mkSynonymTyCon liftedTypeKindTyConName
                                       liftedTypeKind
                                       [] []
                                       (tYPE liftedDataConTy)

starKindTyCon         = mkSynonymTyCon starKindTyConName
                                       liftedTypeKind
                                       [] []
                                       (tYPE liftedDataConTy)

unicodeStarKindTyCon  = mkSynonymTyCon unicodeStarKindTyConName
                                       liftedTypeKind
                                       [] []
                                       (tYPE liftedDataConTy)

{- *********************************************************************
*                                                                      *
     The boxed primitive types: Char, Int, etc
*                                                                      *
********************************************************************* -}

charTy :: Type
charTy = mkTyConTy charTyCon

charTyCon :: TyCon
charTyCon   = pcNonRecDataTyCon charTyConName
                       (Just (CType "" Nothing ("HsChar",fsLit "HsChar")))
                       [] [charDataCon]
charDataCon :: DataCon
charDataCon = pcDataCon charDataConName [] [charPrimTy] charTyCon

stringTy :: Type
stringTy = mkListTy charTy -- convenience only

intTy :: Type
intTy = mkTyConTy intTyCon

intTyCon :: TyCon
intTyCon = pcNonRecDataTyCon intTyConName
                            (Just (CType "" Nothing ("HsInt",fsLit "HsInt"))) []
                            [intDataCon]
intDataCon :: DataCon
intDataCon = pcDataCon intDataConName [] [intPrimTy] intTyCon

wordTy :: Type
wordTy = mkTyConTy wordTyCon

wordTyCon :: TyCon
wordTyCon = pcNonRecDataTyCon wordTyConName
                      (Just (CType "" Nothing ("HsWord", fsLit "HsWord"))) []
                      [wordDataCon]
wordDataCon :: DataCon
wordDataCon = pcDataCon wordDataConName [] [wordPrimTy] wordTyCon

word8Ty :: Type
word8Ty = mkTyConTy word8TyCon

word8TyCon :: TyCon
word8TyCon = pcNonRecDataTyCon word8TyConName
                      (Just (CType "" Nothing ("HsWord8", fsLit "HsWord8"))) []
                      [word8DataCon]
word8DataCon :: DataCon
word8DataCon = pcDataCon word8DataConName [] [wordPrimTy] word8TyCon

floatTy :: Type
floatTy = mkTyConTy floatTyCon

floatTyCon :: TyCon
floatTyCon   = pcNonRecDataTyCon floatTyConName
                      (Just (CType "" Nothing ("HsFloat", fsLit "HsFloat"))) []
                      [floatDataCon]
floatDataCon :: DataCon
floatDataCon = pcDataCon         floatDataConName [] [floatPrimTy] floatTyCon

doubleTy :: Type
doubleTy = mkTyConTy doubleTyCon

doubleTyCon :: TyCon
doubleTyCon = pcNonRecDataTyCon doubleTyConName
                      (Just (CType "" Nothing ("HsDouble",fsLit "HsDouble"))) []
                      [doubleDataCon]

doubleDataCon :: DataCon
doubleDataCon = pcDataCon doubleDataConName [] [doublePrimTy] doubleTyCon

{-
************************************************************************
*                                                                      *
              The Bool type
*                                                                      *
************************************************************************

An ordinary enumeration type, but deeply wired in.  There are no
magical operations on @Bool@ (just the regular Prelude code).

{\em BEGIN IDLE SPECULATION BY SIMON}

This is not the only way to encode @Bool@.  A more obvious coding makes
@Bool@ just a boxed up version of @Bool#@, like this:
\begin{verbatim}
type Bool# = Int#
data Bool = MkBool Bool#
\end{verbatim}

Unfortunately, this doesn't correspond to what the Report says @Bool@
looks like!  Furthermore, we get slightly less efficient code (I
think) with this coding. @gtInt@ would look like this:

\begin{verbatim}
gtInt :: Int -> Int -> Bool
gtInt x y = case x of I# x# ->
            case y of I# y# ->
            case (gtIntPrim x# y#) of
                b# -> MkBool b#
\end{verbatim}

Notice that the result of the @gtIntPrim@ comparison has to be turned
into an integer (here called @b#@), and returned in a @MkBool@ box.

The @if@ expression would compile to this:
\begin{verbatim}
case (gtInt x y) of
  MkBool b# -> case b# of { 1# -> e1; 0# -> e2 }
\end{verbatim}

I think this code is a little less efficient than the previous code,
but I'm not certain.  At all events, corresponding with the Report is
important.  The interesting thing is that the language is expressive
enough to describe more than one alternative; and that a type doesn't
necessarily need to be a straightforwardly boxed version of its
primitive counterpart.

{\em END IDLE SPECULATION BY SIMON}
-}

boolTy :: Type
boolTy = mkTyConTy boolTyCon

boolTyCon :: TyCon
boolTyCon = pcTyCon True NonRecursive boolTyConName
                    (Just (CType "" Nothing ("HsBool", fsLit "HsBool")))
                    [] [falseDataCon, trueDataCon]

falseDataCon, trueDataCon :: DataCon
falseDataCon = pcDataCon falseDataConName [] [] boolTyCon
trueDataCon  = pcDataCon trueDataConName  [] [] boolTyCon

falseDataConId, trueDataConId :: Id
falseDataConId = dataConWorkId falseDataCon
trueDataConId  = dataConWorkId trueDataCon

orderingTyCon :: TyCon
orderingTyCon = pcTyCon True NonRecursive orderingTyConName Nothing
                        [] [ltDataCon, eqDataCon, gtDataCon]

ltDataCon, eqDataCon, gtDataCon :: DataCon
ltDataCon = pcDataCon ltDataConName  [] [] orderingTyCon
eqDataCon = pcDataCon eqDataConName  [] [] orderingTyCon
gtDataCon = pcDataCon gtDataConName  [] [] orderingTyCon

ltDataConId, eqDataConId, gtDataConId :: Id
ltDataConId = dataConWorkId ltDataCon
eqDataConId = dataConWorkId eqDataCon
gtDataConId = dataConWorkId gtDataCon

{-
************************************************************************
*                                                                      *
            The List type
   Special syntax, deeply wired in,
   but otherwise an ordinary algebraic data type
*                                                                      *
************************************************************************

       data [] a = [] | a : (List a)
-}

mkListTy :: Type -> Type
mkListTy ty = mkTyConApp listTyCon [ty]

listTyCon :: TyCon
listTyCon = buildAlgTyCon listTyConName alpha_tyvar [Representational]
                          Nothing []
                          (DataTyCon [nilDataCon, consDataCon] False )
                          Recursive False
                          (VanillaAlgTyCon $ mkPrelTyConRepName listTyConName)

nilDataCon :: DataCon
nilDataCon  = pcDataCon nilDataConName alpha_tyvar [] listTyCon

consDataCon :: DataCon
consDataCon = pcDataConWithFixity True {- Declared infix -}
               consDataConName
               alpha_tyvar [] [alphaTy, mkTyConApp listTyCon alpha_ty] listTyCon
-- Interesting: polymorphic recursion would help here.
-- We can't use (mkListTy alphaTy) in the defn of consDataCon, else mkListTy
-- gets the over-specific type (Type -> Type)

-- Wired-in type Maybe

maybeTyCon :: TyCon
maybeTyCon = pcTyCon False NonRecursive maybeTyConName Nothing alpha_tyvar
                     [nothingDataCon, justDataCon]

nothingDataCon :: DataCon
nothingDataCon = pcDataCon nothingDataConName alpha_tyvar [] maybeTyCon

justDataCon :: DataCon
justDataCon = pcDataCon justDataConName alpha_tyvar [alphaTy] maybeTyCon

{-
** *********************************************************************
*                                                                      *
            The tuple types
*                                                                      *
************************************************************************

The tuple types are definitely magic, because they form an infinite
family.

\begin{itemize}
\item
They have a special family of type constructors, of type @TyCon@
These contain the tycon arity, but don't require a Unique.

\item
They have a special family of constructors, of type
@Id@. Again these contain their arity but don't need a Unique.

\item
There should be a magic way of generating the info tables and
entry code for all tuples.

But at the moment we just compile a Haskell source
file\srcloc{lib/prelude/...} containing declarations like:
\begin{verbatim}
data Tuple0             = Tup0
data Tuple2  a b        = Tup2  a b
data Tuple3  a b c      = Tup3  a b c
data Tuple4  a b c d    = Tup4  a b c d
...
\end{verbatim}
The print-names associated with the magic @Id@s for tuple constructors
``just happen'' to be the same as those generated by these
declarations.

\item
The instance environment should have a magic way to know
that each tuple type is an instances of classes @Eq@, @Ix@, @Ord@ and
so on. \ToDo{Not implemented yet.}

\item
There should also be a way to generate the appropriate code for each
of these instances, but (like the info tables and entry code) it is
done by enumeration\srcloc{lib/prelude/InTup?.hs}.
\end{itemize}
-}

-- | Make a tuple type. The list of types should /not/ include any
-- levity specifications.
mkTupleTy :: Boxity -> [Type] -> Type
-- Special case for *boxed* 1-tuples, which are represented by the type itself
mkTupleTy Boxed   [ty] = ty
mkTupleTy Boxed   tys  = mkTyConApp (tupleTyCon Boxed (length tys)) tys
mkTupleTy Unboxed tys  = mkTyConApp (tupleTyCon Unboxed (length tys))
                                        (map (getLevity "mkTupleTy") tys ++ tys)

-- | Build the type of a small tuple that holds the specified type of thing
mkBoxedTupleTy :: [Type] -> Type
mkBoxedTupleTy tys = mkTupleTy Boxed tys

unitTy :: Type
unitTy = mkTupleTy Boxed []


{- *********************************************************************
*                                                                      *
        The parallel-array type,  [::]
*                                                                      *
************************************************************************

Special syntax for parallel arrays needs some wired in definitions.
-}

-- | Construct a type representing the application of the parallel array constructor
mkPArrTy    :: Type -> Type
mkPArrTy ty  = mkTyConApp parrTyCon [ty]

-- | Represents the type constructor of parallel arrays
--
--  * This must match the definition in @PrelPArr@
--
-- NB: Although the constructor is given here, it will not be accessible in
--     user code as it is not in the environment of any compiled module except
--     @PrelPArr@.
--
parrTyCon :: TyCon
parrTyCon  = pcNonRecDataTyCon parrTyConName Nothing alpha_tyvar [parrDataCon]

parrDataCon :: DataCon
parrDataCon  = pcDataCon
                 parrDataConName
                 alpha_tyvar            -- forall'ed type variables
                 [intTy,                -- 1st argument: Int
                  mkTyConApp            -- 2nd argument: Array# a
                    arrayPrimTyCon
                    alpha_ty]
                 parrTyCon

-- | Check whether a type constructor is the constructor for parallel arrays
isPArrTyCon    :: TyCon -> Bool
isPArrTyCon tc  = tyConName tc == parrTyConName

-- | Fake array constructors
--
-- * These constructors are never really used to represent array values;
--   however, they are very convenient during desugaring (and, in particular,
--   in the pattern matching compiler) to treat array pattern just like
--   yet another constructor pattern
--
parrFakeCon                        :: Arity -> DataCon
parrFakeCon i | i > mAX_TUPLE_SIZE  = mkPArrFakeCon  i  -- build one specially
parrFakeCon i                       = parrFakeConArr!i

-- pre-defined set of constructors
--
parrFakeConArr :: Array Int DataCon
parrFakeConArr  = array (0, mAX_TUPLE_SIZE) [(i, mkPArrFakeCon i)
                                            | i <- [0..mAX_TUPLE_SIZE]]

-- build a fake parallel array constructor for the given arity
--
mkPArrFakeCon       :: Int -> DataCon
mkPArrFakeCon arity  = data_con
  where
        data_con  = pcDataCon name [tyvar] tyvarTys parrTyCon
        tyvar     = head alphaTyVars
        tyvarTys  = replicate arity $ mkTyVarTy tyvar
        nameStr   = mkFastString ("MkPArr" ++ show arity)
        name      = mkWiredInName gHC_PARR' (mkDataOccFS nameStr) unique
                                  (AConLike (RealDataCon data_con)) UserSyntax
        unique      = mkPArrDataConUnique arity

-- | Checks whether a data constructor is a fake constructor for parallel arrays
isPArrFakeCon      :: DataCon -> Bool
isPArrFakeCon dcon  = dcon == parrFakeCon (dataConSourceArity dcon)

-- Promoted Booleans

promotedFalseDataCon, promotedTrueDataCon :: TyCon
promotedTrueDataCon   = promoteDataCon trueDataCon
promotedFalseDataCon  = promoteDataCon falseDataCon

-- Promoted Maybe
promotedNothingDataCon, promotedJustDataCon :: TyCon
promotedNothingDataCon = promoteDataCon nothingDataCon
promotedJustDataCon    = promoteDataCon justDataCon

-- Promoted Ordering

promotedLTDataCon
  , promotedEQDataCon
  , promotedGTDataCon
  :: TyCon
promotedLTDataCon     = promoteDataCon ltDataCon
promotedEQDataCon     = promoteDataCon eqDataCon
promotedGTDataCon     = promoteDataCon gtDataCon

-- Promoted List
promotedConsDataCon, promotedNilDataCon :: TyCon
promotedConsDataCon   = promoteDataCon consDataCon
promotedNilDataCon    = promoteDataCon nilDataCon

-- * Type representation types
-- See Note [Grand plan for Typable] in TcTypeable.
trModuleTyConName, trNameTyConName, trTyConTyConName :: Name
trModuleTyConName   = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "Module")
                        trModuleTyConKey trModuleTyCon
trNameTyConName     = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "TrName")
                        trNameTyConKey trNameTyCon
trTyConTyConName    = mkWiredInTyConName UserSyntax gHC_TYPES (fsLit "TyCon")
                        trTyConTyConKey trTyConTyCon

trModuleDataConName, trTyConDataConName,
  trNameSDataConName, trNameDDataConName :: Name
trModuleDataConName = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "Module")
                        trModuleDataConKey trModuleDataCon
trTyConDataConName  = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "TyCon")
                        trTyConDataConKey trTyConDataCon
trNameSDataConName  = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "TrNameS")
                        trNameSDataConKey trNameSDataCon
trNameDDataConName  = mkWiredInDataConName UserSyntax gHC_TYPES (fsLit "TrNameD")
                        trNameDDataConKey trNameDDataCon

trModuleTyCon :: TyCon
trModuleTyCon = pcNonRecDataTyCon trModuleTyConName Nothing [] [trModuleDataCon]

trModuleDataCon :: DataCon
trModuleDataCon = pcDataCon trModuleDataConName [] [trNameTy, trNameTy] trModuleTyCon

trModuleTy :: Type
trModuleTy = mkTyConTy trModuleTyCon

trNameTyCon :: TyCon
trNameTyCon = pcNonRecDataTyCon trNameTyConName Nothing [] [trNameSDataCon, trNameDDataCon]

trNameSDataCon, trNameDDataCon :: DataCon
trNameSDataCon = pcDataCon trNameSDataConName [] [addrPrimTy] trNameTyCon
trNameDDataCon = pcDataCon trNameDDataConName [] [stringTy] trNameTyCon

trNameTy :: Type
trNameTy = mkTyConTy trNameTyCon

trTyConTyCon :: TyCon
trTyConTyCon = pcNonRecDataTyCon trTyConTyConName Nothing [] [trTyConDataCon]

trTyConDataCon :: DataCon
trTyConDataCon = pcDataCon trTyConDataConName [] [fprint, fprint, trModuleTy, trNameTy] trTyConTyCon
  where
    -- TODO: This should be for the target, no?
#if WORD_SIZE_IN_BITS < 64
    fprint = word64PrimTy
#else
    fprint = wordPrimTy
#endif
