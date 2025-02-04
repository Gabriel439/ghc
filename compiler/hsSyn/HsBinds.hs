{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998

\section[HsBinds]{Abstract syntax: top-level bindings and signatures}

Datatype for: @BindGroup@, @Bind@, @Sig@, @Bind@.
-}

{-# LANGUAGE DeriveDataTypeable #-}
{-# LANGUAGE StandaloneDeriving #-}
{-# LANGUAGE FlexibleContexts #-}
{-# LANGUAGE UndecidableInstances #-} -- Note [Pass sensitive types]
                                      -- in module PlaceHolder
{-# LANGUAGE ConstraintKinds #-}
{-# LANGUAGE BangPatterns #-}

module HsBinds where

import {-# SOURCE #-} HsExpr ( pprExpr, LHsExpr,
                               MatchGroup, pprFunBind,
                               GRHSs, pprPatBind )
import {-# SOURCE #-} HsPat  ( LPat )

import PlaceHolder ( PostTc,PostRn,DataId )
import HsTypes
import PprCore ()
import CoreSyn
import TcEvidence
import Type
import Name
import NameSet
import BasicTypes
import Outputable
import SrcLoc
import Var
import Bag
import FastString
import BooleanFormula (LBooleanFormula)
import DynFlags

import Data.Data hiding ( Fixity )
import Data.List hiding ( foldr )
import Data.Ord
import Data.Foldable ( Foldable(..) )

{-
************************************************************************
*                                                                      *
\subsection{Bindings: @BindGroup@}
*                                                                      *
************************************************************************

Global bindings (where clauses)
-}

-- During renaming, we need bindings where the left-hand sides
-- have been renamed but the the right-hand sides have not.
-- the ...LR datatypes are parametrized by two id types,
-- one for the left and one for the right.
-- Other than during renaming, these will be the same.

type HsLocalBinds id = HsLocalBindsLR id id

-- | Bindings in a 'let' expression
-- or a 'where' clause
data HsLocalBindsLR idL idR
  = HsValBinds (HsValBindsLR idL idR)
         -- There should be no pattern synonyms in the HsValBindsLR
         -- These are *local* (not top level) bindings
         -- The parser accepts them, however, leaving the the
         -- renamer to report them

  | HsIPBinds  (HsIPBinds idR)

  | EmptyLocalBinds
  deriving (Typeable)

deriving instance (DataId idL, DataId idR)
  => Data (HsLocalBindsLR idL idR)

type HsValBinds id = HsValBindsLR id id

-- | Value bindings (not implicit parameters)
-- Used for both top level and nested bindings
-- May contain pattern synonym bindings
data HsValBindsLR idL idR
  = -- | Before renaming RHS; idR is always RdrName
    -- Not dependency analysed
    -- Recursive by default
    ValBindsIn
        (LHsBindsLR idL idR) [LSig idR]

    -- | After renaming RHS; idR can be Name or Id
    --  Dependency analysed,
    -- later bindings in the list may depend on earlier
    -- ones.
  | ValBindsOut
        [(RecFlag, LHsBinds idL)]
        [LSig Name]
  deriving (Typeable)

deriving instance (DataId idL, DataId idR)
  => Data (HsValBindsLR idL idR)

type LHsBind  id = LHsBindLR  id id
type LHsBinds id = LHsBindsLR id id
type HsBind   id = HsBindLR   id id

type LHsBindsLR idL idR = Bag (LHsBindLR idL idR)
type LHsBindLR  idL idR = Located (HsBindLR idL idR)

data HsBindLR idL idR
  = -- | FunBind is used for both functions   @f x = e@
    -- and variables                          @f = \x -> e@
    --
    -- Reason 1: Special case for type inference: see 'TcBinds.tcMonoBinds'.
    --
    -- Reason 2: Instance decls can only have FunBinds, which is convenient.
    --           If you change this, you'll need to change e.g. rnMethodBinds
    --
    -- But note that the form                 @f :: a->a = ...@
    -- parses as a pattern binding, just like
    --                                        @(f :: a -> a) = ... @
    --
    --  'ApiAnnotation.AnnKeywordId's
    --
    --  - 'ApiAnnotation.AnnFunId', attached to each element of fun_matches
    --
    --  - 'ApiAnnotation.AnnEqual','ApiAnnotation.AnnWhere',
    --    'ApiAnnotation.AnnOpen','ApiAnnotation.AnnClose',

    -- For details on above see note [Api annotations] in ApiAnnotation
    FunBind {

        fun_id :: Located idL, -- Note [fun_id in Match] in HsExpr

        fun_matches :: MatchGroup idR (LHsExpr idR),  -- ^ The payload

        fun_co_fn :: HsWrapper, -- ^ Coercion from the type of the MatchGroup to the type of
                                -- the Id.  Example:
                                --
                                -- @
                                --      f :: Int -> forall a. a -> a
                                --      f x y = y
                                -- @
                                --
                                -- Then the MatchGroup will have type (Int -> a' -> a')
                                -- (with a free type variable a').  The coercion will take
                                -- a CoreExpr of this type and convert it to a CoreExpr of
                                -- type         Int -> forall a'. a' -> a'
                                -- Notice that the coercion captures the free a'.

        bind_fvs :: PostRn idL NameSet, -- ^ After the renamer, this contains
                                --  the locally-bound
                                -- free variables of this defn.
                                -- See Note [Bind free vars]


        fun_tick :: [Tickish Id]  -- ^ Ticks to put on the rhs, if any
    }

  -- | The pattern is never a simple variable;
  -- That case is done by FunBind
  --
  --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnBang',
  --       'ApiAnnotation.AnnEqual','ApiAnnotation.AnnWhere',
  --       'ApiAnnotation.AnnOpen','ApiAnnotation.AnnClose',

  -- For details on above see note [Api annotations] in ApiAnnotation
  | PatBind {
        pat_lhs    :: LPat idL,
        pat_rhs    :: GRHSs idR (LHsExpr idR),
        pat_rhs_ty :: PostTc idR Type,      -- ^ Type of the GRHSs
        bind_fvs   :: PostRn idL NameSet, -- ^ See Note [Bind free vars]
        pat_ticks  :: ([Tickish Id], [[Tickish Id]])
               -- ^ Ticks to put on the rhs, if any, and ticks to put on
               -- the bound variables.
    }

  -- | Dictionary binding and suchlike.
  -- All VarBinds are introduced by the type checker
  | VarBind {
        var_id     :: idL,
        var_rhs    :: LHsExpr idR,   -- ^ Located only for consistency
        var_inline :: Bool           -- ^ True <=> inline this binding regardless
                                     -- (used for implication constraints only)
    }

  | AbsBinds {                      -- Binds abstraction; TRANSLATION
        abs_tvs     :: [TyVar],
        abs_ev_vars :: [EvVar],  -- ^ Includes equality constraints

       -- | AbsBinds only gets used when idL = idR after renaming,
       -- but these need to be idL's for the collect... code in HsUtil
       -- to have the right type
        abs_exports :: [ABExport idL],

        -- | Evidence bindings
        -- Why a list? See TcInstDcls
        -- Note [Typechecking plan for instance declarations]
        abs_ev_binds :: [TcEvBinds],

        -- | Typechecked user bindings
        abs_binds    :: LHsBinds idL
    }

  | AbsBindsSig {  -- Simpler form of AbsBinds, used with a type sig
                   -- in tcPolyCheck. Produces simpler desugaring and
                   -- is necessary to avoid #11405, comment:3.
        abs_tvs     :: [TyVar],
        abs_ev_vars :: [EvVar],

        abs_sig_export :: idL,  -- like abe_poly
        abs_sig_prags  :: TcSpecPrags,

        abs_sig_ev_bind :: TcEvBinds,  -- no list needed here
        abs_sig_bind    :: LHsBind idL -- always only one, and it's always a
                                       -- FunBind
    }

  | PatSynBind (PatSynBind idL idR)
        -- ^ - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnPattern',
        --          'ApiAnnotation.AnnLarrow','ApiAnnotation.AnnEqual',
        --          'ApiAnnotation.AnnWhere'
        --          'ApiAnnotation.AnnOpen' @'{'@,'ApiAnnotation.AnnClose' @'}'@

        -- For details on above see note [Api annotations] in ApiAnnotation

  deriving (Typeable)
deriving instance (DataId idL, DataId idR)
  => Data (HsBindLR idL idR)

        -- Consider (AbsBinds tvs ds [(ftvs, poly_f, mono_f) binds]
        --
        -- Creates bindings for (polymorphic, overloaded) poly_f
        -- in terms of monomorphic, non-overloaded mono_f
        --
        -- Invariants:
        --      1. 'binds' binds mono_f
        --      2. ftvs is a subset of tvs
        --      3. ftvs includes all tyvars free in ds
        --
        -- See Note [AbsBinds]

data ABExport id
  = ABE { abe_poly      :: id    -- ^ Any INLINE pragmas is attached to this Id
        , abe_mono      :: id
        , abe_wrap      :: HsWrapper    -- ^ See Note [ABExport wrapper]
             -- Shape: (forall abs_tvs. abs_ev_vars => abe_mono) ~ abe_poly
        , abe_prags     :: TcSpecPrags  -- ^ SPECIALISE pragmas
  } deriving (Data, Typeable)

-- | - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnPattern',
--             'ApiAnnotation.AnnEqual','ApiAnnotation.AnnLarrow'
--             'ApiAnnotation.AnnWhere','ApiAnnotation.AnnOpen' @'{'@,
--             'ApiAnnotation.AnnClose' @'}'@,

-- For details on above see note [Api annotations] in ApiAnnotation
data PatSynBind idL idR
  = PSB { psb_id   :: Located idL,             -- ^ Name of the pattern synonym
          psb_fvs  :: PostRn idR NameSet,      -- ^ See Note [Bind free vars]
          psb_args :: HsPatSynDetails (Located idR), -- ^ Formal parameter names
          psb_def  :: LPat idR,                      -- ^ Right-hand side
          psb_dir  :: HsPatSynDir idR                -- ^ Directionality
  } deriving (Typeable)
deriving instance (DataId idL, DataId idR)
  => Data (PatSynBind idL idR)

{-
Note [AbsBinds]
~~~~~~~~~~~~~~~
The AbsBinds constructor is used in the output of the type checker, to record
*typechecked* and *generalised* bindings.  Consider a module M, with this
top-level binding, where there is no type signature for M.reverse,
    M.reverse []     = []
    M.reverse (x:xs) = M.reverse xs ++ [x]

In Hindley-Milner, a recursive binding is typechecked with the *recursive* uses
being *monomorphic*.  So after typechecking *and* desugaring we will get something
like this

    M.reverse :: forall a. [a] -> [a]
      = /\a. letrec
                reverse :: [a] -> [a] = \xs -> case xs of
                                                []     -> []
                                                (x:xs) -> reverse xs ++ [x]
             in reverse

Notice that 'M.reverse' is polymorphic as expected, but there is a local
definition for plain 'reverse' which is *monomorphic*.  The type variable
'a' scopes over the entire letrec.

That's after desugaring.  What about after type checking but before
desugaring?  That's where AbsBinds comes in.  It looks like this:

   AbsBinds { abs_tvs     = [a]
            , abs_exports = [ABE { abe_poly = M.reverse :: forall a. [a] -> [a],
                                 , abe_mono = reverse :: [a] -> [a]}]
            , abs_binds = { reverse :: [a] -> [a]
                               = \xs -> case xs of
                                            []     -> []
                                            (x:xs) -> reverse xs ++ [x] } }

Here,
  * abs_tvs says what type variables are abstracted over the binding group,
    just 'a' in this case.
  * abs_binds is the *monomorphic* bindings of the group
  * abs_exports describes how to get the polymorphic Id 'M.reverse' from the
    monomorphic one 'reverse'

Notice that the *original* function (the polymorphic one you thought
you were defining) appears in the abe_poly field of the
abs_exports. The bindings in abs_binds are for fresh, local, Ids with
a *monomorphic* Id.

If there is a group of mutually recursive (see Note [Polymorphic
recursion]) functions without type signatures, we get one AbsBinds
with the monomorphic versions of the bindings in abs_binds, and one
element of abe_exports for each variable bound in the mutually
recursive group.  This is true even for pattern bindings.  Example:
        (f,g) = (\x -> x, f)
After type checking we get
   AbsBinds { abs_tvs     = [a]
            , abs_exports = [ ABE { abe_poly = M.f :: forall a. a -> a
                                  , abe_mono = f :: a -> a }
                            , ABE { abe_poly = M.g :: forall a. a -> a
                                  , abe_mono = g :: a -> a }]
            , abs_binds = { (f,g) = (\x -> x, f) }

Note [Polymorphic recursion]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   Rec { f x = ...(g ef)...

       ; g :: forall a. [a] -> [a]
       ; g y = ...(f eg)...  }

These bindings /are/ mutually recursive (f calls g, and g calls f).
But we can use the type signature for g to break the recursion,
like this:

  1. Add g :: forall a. [a] -> [a] to the type environment

  2. Typecheck the definition of f, all by itself,
     including generalising it to find its most general
     type, say f :: forall b. b -> b -> [b]

  3. Extend the type environment with that type for f

  4. Typecheck the definition of g, all by itself,
     checking that it has the type claimed by its signature

Steps 2 and 4 each generate a separate AbsBinds, so we end
up with
   Rec { AbsBinds { ...for f ... }
       ; AbsBinds { ...for g ... } }

This approach allows both f and to call each other
polymorphically, even though only g has a signature.

We get an AbsBinds that encompasses multiple source-program
bindings only when
 * Each binding in the group has at least one binder that
   lacks a user type signature
 * The group forms a strongly connected component

Note [ABExport wrapper]
~~~~~~~~~~~~~~~~~~~~~~~
Consider
   (f,g) = (\x.x, \y.y)
This ultimately desugars to something like this:
   tup :: forall a b. (a->a, b->b)
   tup = /\a b. (\x:a.x, \y:b.y)
   f :: forall a. a -> a
   f = /\a. case tup a Any of
               (fm::a->a,gm:Any->Any) -> fm
   ...similarly for g...

The abe_wrap field deals with impedance-matching between
    (/\a b. case tup a b of { (f,g) -> f })
and the thing we really want, which may have fewer type
variables.  The action happens in TcBinds.mkExport.

Note [Bind free vars]
~~~~~~~~~~~~~~~~~~~~~
The bind_fvs field of FunBind and PatBind records the free variables
of the definition.  It is used for two purposes

a) Dependency analysis prior to type checking
    (see TcBinds.tc_group)

b) Deciding whether we can do generalisation of the binding
    (see TcBinds.decideGeneralisationPlan)

Specifically,

  * bind_fvs includes all free vars that are defined in this module
    (including top-level things and lexically scoped type variables)

  * bind_fvs excludes imported vars; this is just to keep the set smaller

  * Before renaming, and after typechecking, the field is unused;
    it's just an error thunk
-}

instance (OutputableBndr idL, OutputableBndr idR) => Outputable (HsLocalBindsLR idL idR) where
  ppr (HsValBinds bs) = ppr bs
  ppr (HsIPBinds bs)  = ppr bs
  ppr EmptyLocalBinds = empty

instance (OutputableBndr idL, OutputableBndr idR) => Outputable (HsValBindsLR idL idR) where
  ppr (ValBindsIn binds sigs)
   = pprDeclList (pprLHsBindsForUser binds sigs)

  ppr (ValBindsOut sccs sigs)
    = getPprStyle $ \ sty ->
      if debugStyle sty then    -- Print with sccs showing
        vcat (map ppr sigs) $$ vcat (map ppr_scc sccs)
     else
        pprDeclList (pprLHsBindsForUser (unionManyBags (map snd sccs)) sigs)
   where
     ppr_scc (rec_flag, binds) = pp_rec rec_flag <+> pprLHsBinds binds
     pp_rec Recursive    = text "rec"
     pp_rec NonRecursive = text "nonrec"

pprLHsBinds :: (OutputableBndr idL, OutputableBndr idR) => LHsBindsLR idL idR -> SDoc
pprLHsBinds binds
  | isEmptyLHsBinds binds = empty
  | otherwise = pprDeclList (map ppr (bagToList binds))

pprLHsBindsForUser :: (OutputableBndr idL, OutputableBndr idR, OutputableBndr id2)
                   => LHsBindsLR idL idR -> [LSig id2] -> [SDoc]
--  pprLHsBindsForUser is different to pprLHsBinds because
--  a) No braces: 'let' and 'where' include a list of HsBindGroups
--     and we don't want several groups of bindings each
--     with braces around
--  b) Sort by location before printing
--  c) Include signatures
pprLHsBindsForUser binds sigs
  = map snd (sort_by_loc decls)
  where

    decls :: [(SrcSpan, SDoc)]
    decls = [(loc, ppr sig)  | L loc sig <- sigs] ++
            [(loc, ppr bind) | L loc bind <- bagToList binds]

    sort_by_loc decls = sortBy (comparing fst) decls

pprDeclList :: [SDoc] -> SDoc   -- Braces with a space
-- Print a bunch of declarations
-- One could choose  { d1; d2; ... }, using 'sep'
-- or      d1
--         d2
--         ..
--    using vcat
-- At the moment we chose the latter
-- Also we do the 'pprDeeperList' thing.
pprDeclList ds = pprDeeperList vcat ds

------------
emptyLocalBinds :: HsLocalBindsLR a b
emptyLocalBinds = EmptyLocalBinds

isEmptyLocalBinds :: HsLocalBindsLR a b -> Bool
isEmptyLocalBinds (HsValBinds ds) = isEmptyValBinds ds
isEmptyLocalBinds (HsIPBinds ds)  = isEmptyIPBinds ds
isEmptyLocalBinds EmptyLocalBinds = True

isEmptyValBinds :: HsValBindsLR a b -> Bool
isEmptyValBinds (ValBindsIn ds sigs)  = isEmptyLHsBinds ds && null sigs
isEmptyValBinds (ValBindsOut ds sigs) = null ds && null sigs

emptyValBindsIn, emptyValBindsOut :: HsValBindsLR a b
emptyValBindsIn  = ValBindsIn emptyBag []
emptyValBindsOut = ValBindsOut []      []

emptyLHsBinds :: LHsBindsLR idL idR
emptyLHsBinds = emptyBag

isEmptyLHsBinds :: LHsBindsLR idL idR -> Bool
isEmptyLHsBinds = isEmptyBag

------------
plusHsValBinds :: HsValBinds a -> HsValBinds a -> HsValBinds a
plusHsValBinds (ValBindsIn ds1 sigs1) (ValBindsIn ds2 sigs2)
  = ValBindsIn (ds1 `unionBags` ds2) (sigs1 ++ sigs2)
plusHsValBinds (ValBindsOut ds1 sigs1) (ValBindsOut ds2 sigs2)
  = ValBindsOut (ds1 ++ ds2) (sigs1 ++ sigs2)
plusHsValBinds _ _
  = panic "HsBinds.plusHsValBinds"


{-
What AbsBinds means
~~~~~~~~~~~~~~~~~~~
         AbsBinds tvs
                  [d1,d2]
                  [(tvs1, f1p, f1m),
                   (tvs2, f2p, f2m)]
                  BIND
means

        f1p = /\ tvs -> \ [d1,d2] -> letrec DBINDS and BIND
                                     in fm

        gp = ...same again, with gm instead of fm

This is a pretty bad translation, because it duplicates all the bindings.
So the desugarer tries to do a better job:

        fp = /\ [a,b] -> \ [d1,d2] -> case tp [a,b] [d1,d2] of
                                        (fm,gm) -> fm
        ..ditto for gp..

        tp = /\ [a,b] -> \ [d1,d2] -> letrec DBINDS and BIND
                                      in (fm,gm)
-}

instance (OutputableBndr idL, OutputableBndr idR) => Outputable (HsBindLR idL idR) where
    ppr mbind = ppr_monobind mbind

ppr_monobind :: (OutputableBndr idL, OutputableBndr idR) => HsBindLR idL idR -> SDoc

ppr_monobind (PatBind { pat_lhs = pat, pat_rhs = grhss })
  = pprPatBind pat grhss
ppr_monobind (VarBind { var_id = var, var_rhs = rhs })
  = sep [pprBndr CaseBind var, nest 2 $ equals <+> pprExpr (unLoc rhs)]
ppr_monobind (FunBind { fun_id = fun,
                        fun_co_fn = wrap,
                        fun_matches = matches,
                        fun_tick = ticks })
  = pprTicks empty (if null ticks then empty
                    else text "-- ticks = " <> ppr ticks)
    $$  ifPprDebug (pprBndr LetBind (unLoc fun))
    $$  pprFunBind (unLoc fun) matches
    $$  ifPprDebug (ppr wrap)
ppr_monobind (PatSynBind psb) = ppr psb
ppr_monobind (AbsBinds { abs_tvs = tyvars, abs_ev_vars = dictvars
                       , abs_exports = exports, abs_binds = val_binds
                       , abs_ev_binds = ev_binds })
  = sdocWithDynFlags $ \ dflags ->
    if gopt Opt_PrintTypecheckerElaboration dflags then
      -- Show extra information (bug number: #10662)
      hang (text "AbsBinds" <+> brackets (interpp'SP tyvars)
                                    <+> brackets (interpp'SP dictvars))
         2 $ braces $ vcat
      [ text "Exports:" <+>
          brackets (sep (punctuate comma (map ppr exports)))
      , text "Exported types:" <+>
          vcat [pprBndr LetBind (abe_poly ex) | ex <- exports]
      , text "Binds:" <+> pprLHsBinds val_binds
      , text "Evidence:" <+> ppr ev_binds ]
    else
      pprLHsBinds val_binds
ppr_monobind (AbsBindsSig { abs_tvs         = tyvars
                          , abs_ev_vars     = dictvars
                          , abs_sig_ev_bind = ev_bind
                          , abs_sig_bind    = bind })
  = sdocWithDynFlags $ \ dflags ->
    if gopt Opt_PrintTypecheckerElaboration dflags then
      hang (text "AbsBindsSig" <+> brackets (interpp'SP tyvars)
                               <+> brackets (interpp'SP dictvars))
         2 $ braces $ vcat
      [ text "Bind:"     <+> ppr bind
      , text "Evidence:" <+> ppr ev_bind ]
    else
      ppr bind

instance (OutputableBndr id) => Outputable (ABExport id) where
  ppr (ABE { abe_wrap = wrap, abe_poly = gbl, abe_mono = lcl, abe_prags = prags })
    = vcat [ ppr gbl <+> text "<=" <+> ppr lcl
           , nest 2 (pprTcSpecPrags prags)
           , nest 2 (text "wrap:" <+> ppr wrap)]

instance (OutputableBndr idL, OutputableBndr idR) => Outputable (PatSynBind idL idR) where
  ppr (PSB{ psb_id = L _ psyn, psb_args = details, psb_def = pat, psb_dir = dir })
      = ppr_lhs <+> ppr_rhs
    where
      ppr_lhs = text "pattern" <+> ppr_details
      ppr_simple syntax = syntax <+> ppr pat

      ppr_details = case details of
          InfixPatSyn v1 v2 -> hsep [ppr v1, pprInfixOcc psyn, ppr v2]
          PrefixPatSyn vs   -> hsep (pprPrefixOcc psyn : map ppr vs)
          RecordPatSyn vs   ->
            pprPrefixOcc psyn
                      <> braces (sep (punctuate comma (map ppr vs)))

      ppr_rhs = case dir of
          Unidirectional           -> ppr_simple (text "<-")
          ImplicitBidirectional    -> ppr_simple equals
          ExplicitBidirectional mg -> ppr_simple (text "<-") <+> ptext (sLit "where") $$
                                      (nest 2 $ pprFunBind psyn mg)

pprTicks :: SDoc -> SDoc -> SDoc
-- Print stuff about ticks only when -dppr-debug is on, to avoid
-- them appearing in error messages (from the desugarer); see Trac # 3263
-- Also print ticks in dumpStyle, so that -ddump-hpc actually does
-- something useful.
pprTicks pp_no_debug pp_when_debug
  = getPprStyle (\ sty -> if debugStyle sty || dumpStyle sty
                             then pp_when_debug
                             else pp_no_debug)

{-
************************************************************************
*                                                                      *
                Implicit parameter bindings
*                                                                      *
************************************************************************
-}

data HsIPBinds id
  = IPBinds
        [LIPBind id]
        TcEvBinds       -- Only in typechecker output; binds
                        -- uses of the implicit parameters
  deriving (Typeable)
deriving instance (DataId id) => Data (HsIPBinds id)

isEmptyIPBinds :: HsIPBinds id -> Bool
isEmptyIPBinds (IPBinds is ds) = null is && isEmptyTcEvBinds ds

type LIPBind id = Located (IPBind id)
-- ^ May have 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnSemi' when in a
--   list

-- For details on above see note [Api annotations] in ApiAnnotation

-- | Implicit parameter bindings.
--
-- These bindings start off as (Left "x") in the parser and stay
-- that way until after type-checking when they are replaced with
-- (Right d), where "d" is the name of the dictionary holding the
-- evidence for the implicit parameter.
--
-- - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnEqual'

-- For details on above see note [Api annotations] in ApiAnnotation
data IPBind id
  = IPBind (Either (Located HsIPName) id) (LHsExpr id)
  deriving (Typeable)
deriving instance (DataId name) => Data (IPBind name)

instance (OutputableBndr id) => Outputable (HsIPBinds id) where
  ppr (IPBinds bs ds) = pprDeeperList vcat (map ppr bs)
                        $$ ifPprDebug (ppr ds)

instance (OutputableBndr id) => Outputable (IPBind id) where
  ppr (IPBind lr rhs) = name <+> equals <+> pprExpr (unLoc rhs)
    where name = case lr of
                   Left (L _ ip) -> pprBndr LetBind ip
                   Right     id  -> pprBndr LetBind id

{-
************************************************************************
*                                                                      *
\subsection{@Sig@: type signatures and value-modifying user pragmas}
*                                                                      *
************************************************************************

It is convenient to lump ``value-modifying'' user-pragmas (e.g.,
``specialise this function to these four types...'') in with type
signatures.  Then all the machinery to move them into place, etc.,
serves for both.
-}

type LSig name = Located (Sig name)

-- | Signatures and pragmas
data Sig name
  =   -- | An ordinary type signature
      --
      -- > f :: Num a => a -> a
      --
      -- After renaming, this list of Names contains the named and unnamed
      -- wildcards brought into scope by this signature. For a signature
      -- @_ -> _a -> Bool@, the renamer will give the unnamed wildcard @_@
      -- a freshly generated name, e.g. @_w@. @_w@ and the named wildcard @_a@
      -- are then both replaced with fresh meta vars in the type. Their names
      -- are stored in the type signature that brought them into scope, in
      -- this third field to be more specific.
      --
      --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnDcolon',
      --          'ApiAnnotation.AnnComma'

      -- For details on above see note [Api annotations] in ApiAnnotation
    TypeSig
       [Located name]        -- LHS of the signature; e.g.  f,g,h :: blah
       (LHsSigWcType name)   -- RHS of the signature; can have wildcards

      -- | A pattern synonym type signature
      --
      -- > pattern Single :: () => (Show a) => a -> [a]
      --
      --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnPattern',
      --           'ApiAnnotation.AnnDcolon','ApiAnnotation.AnnForall'
      --           'ApiAnnotation.AnnDot','ApiAnnotation.AnnDarrow'

      -- For details on above see note [Api annotations] in ApiAnnotation
  | PatSynSig (Located name) (LHsSigType name)
      -- P :: forall a b. Prov => Req => ty

      -- | A signature for a class method
      --   False: ordinary class-method signature
      --   True:  default class method signature
      -- e.g.   class C a where
      --          op :: a -> a                   -- Ordinary
      --          default op :: Eq a => a -> a   -- Generic default
      -- No wildcards allowed here
      --
      --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnDefault',
      --           'ApiAnnotation.AnnDcolon'
  | ClassOpSig Bool [Located name] (LHsSigType name)

        -- | A type signature in generated code, notably the code
        -- generated for record selectors.  We simply record
        -- the desired Id itself, replete with its name, type
        -- and IdDetails.  Otherwise it's just like a type
        -- signature: there should be an accompanying binding
  | IdSig Id

        -- | An ordinary fixity declaration
        --
        -- >     infixl 8 ***
        --
        --
        --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnInfix',
        --           'ApiAnnotation.AnnVal'

        -- For details on above see note [Api annotations] in ApiAnnotation
  | FixSig (FixitySig name)

        -- | An inline pragma
        --
        -- > {#- INLINE f #-}
        --
        --  - 'ApiAnnotation.AnnKeywordId' :
        --       'ApiAnnotation.AnnOpen' @'{-\# INLINE'@ and @'['@,
        --       'ApiAnnotation.AnnClose','ApiAnnotation.AnnOpen',
        --       'ApiAnnotation.AnnVal','ApiAnnotation.AnnTilde',
        --       'ApiAnnotation.AnnClose'

        -- For details on above see note [Api annotations] in ApiAnnotation
  | InlineSig   (Located name)  -- Function name
                InlinePragma    -- Never defaultInlinePragma

        -- | A specialisation pragma
        --
        -- > {-# SPECIALISE f :: Int -> Int #-}
        --
        --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnOpen',
        --      'ApiAnnotation.AnnOpen' @'{-\# SPECIALISE'@ and @'['@,
        --      'ApiAnnotation.AnnTilde',
        --      'ApiAnnotation.AnnVal',
        --      'ApiAnnotation.AnnClose' @']'@ and @'\#-}'@,
        --      'ApiAnnotation.AnnDcolon'

        -- For details on above see note [Api annotations] in ApiAnnotation
  | SpecSig     (Located name)     -- Specialise a function or datatype  ...
                [LHsSigType name]  -- ... to these types
                InlinePragma       -- The pragma on SPECIALISE_INLINE form.
                                   -- If it's just defaultInlinePragma, then we said
                                   --    SPECIALISE, not SPECIALISE_INLINE

        -- | A specialisation pragma for instance declarations only
        --
        -- > {-# SPECIALISE instance Eq [Int] #-}
        --
        -- (Class tys); should be a specialisation of the
        -- current instance declaration
        --
        --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnOpen',
        --      'ApiAnnotation.AnnInstance','ApiAnnotation.AnnClose'

        -- For details on above see note [Api annotations] in ApiAnnotation
  | SpecInstSig SourceText (LHsSigType name)
                  -- Note [Pragma source text] in BasicTypes

        -- | A minimal complete definition pragma
        --
        -- > {-# MINIMAL a | (b, c | (d | e)) #-}
        --
        --  - 'ApiAnnotation.AnnKeywordId' : 'ApiAnnotation.AnnOpen',
        --      'ApiAnnotation.AnnVbar','ApiAnnotation.AnnComma',
        --      'ApiAnnotation.AnnClose'

        -- For details on above see note [Api annotations] in ApiAnnotation
  | MinimalSig SourceText (LBooleanFormula (Located name))
               -- Note [Pragma source text] in BasicTypes

  deriving (Typeable)
deriving instance (DataId name) => Data (Sig name)


type LFixitySig name = Located (FixitySig name)
data FixitySig name = FixitySig [Located name] Fixity
  deriving (Data, Typeable)

-- | TsSpecPrags conveys pragmas from the type checker to the desugarer
data TcSpecPrags
  = IsDefaultMethod     -- ^ Super-specialised: a default method should
                        -- be macro-expanded at every call site
  | SpecPrags [LTcSpecPrag]
  deriving (Data, Typeable)

type LTcSpecPrag = Located TcSpecPrag

data TcSpecPrag
  = SpecPrag
        Id
        HsWrapper
        InlinePragma
  -- ^ The Id to be specialised, an wrapper that specialises the
  -- polymorphic function, and inlining spec for the specialised function
  deriving (Data, Typeable)

noSpecPrags :: TcSpecPrags
noSpecPrags = SpecPrags []

hasSpecPrags :: TcSpecPrags -> Bool
hasSpecPrags (SpecPrags ps) = not (null ps)
hasSpecPrags IsDefaultMethod = False

isDefaultMethod :: TcSpecPrags -> Bool
isDefaultMethod IsDefaultMethod = True
isDefaultMethod (SpecPrags {})  = False


isFixityLSig :: LSig name -> Bool
isFixityLSig (L _ (FixSig {})) = True
isFixityLSig _                 = False

isTypeLSig :: LSig name -> Bool  -- Type signatures
isTypeLSig (L _(TypeSig {}))    = True
isTypeLSig (L _(ClassOpSig {})) = True
isTypeLSig (L _(IdSig {}))      = True
isTypeLSig _                    = False

isSpecLSig :: LSig name -> Bool
isSpecLSig (L _(SpecSig {})) = True
isSpecLSig _                 = False

isSpecInstLSig :: LSig name -> Bool
isSpecInstLSig (L _ (SpecInstSig {})) = True
isSpecInstLSig _                      = False

isPragLSig :: LSig name -> Bool
-- Identifies pragmas
isPragLSig (L _ (SpecSig {}))   = True
isPragLSig (L _ (InlineSig {})) = True
isPragLSig _                    = False

isInlineLSig :: LSig name -> Bool
-- Identifies inline pragmas
isInlineLSig (L _ (InlineSig {})) = True
isInlineLSig _                    = False

isMinimalLSig :: LSig name -> Bool
isMinimalLSig (L _ (MinimalSig {})) = True
isMinimalLSig _                    = False

hsSigDoc :: Sig name -> SDoc
hsSigDoc (TypeSig {})           = text "type signature"
hsSigDoc (PatSynSig {})         = text "pattern synonym signature"
hsSigDoc (ClassOpSig is_deflt _ _)
 | is_deflt                     = text "default type signature"
 | otherwise                    = text "class method signature"
hsSigDoc (IdSig {})             = text "id signature"
hsSigDoc (SpecSig {})           = text "SPECIALISE pragma"
hsSigDoc (InlineSig _ prag)     = ppr (inlinePragmaSpec prag) <+> text "pragma"
hsSigDoc (SpecInstSig {})       = text "SPECIALISE instance pragma"
hsSigDoc (FixSig {})            = text "fixity declaration"
hsSigDoc (MinimalSig {})        = text "MINIMAL pragma"

{-
Check if signatures overlap; this is used when checking for duplicate
signatures. Since some of the signatures contain a list of names, testing for
equality is not enough -- we have to check if they overlap.
-}

instance (OutputableBndr name) => Outputable (Sig name) where
    ppr sig = ppr_sig sig

ppr_sig :: OutputableBndr name => Sig name -> SDoc
ppr_sig (TypeSig vars ty)    = pprVarSig (map unLoc vars) (ppr ty)
ppr_sig (ClassOpSig is_deflt vars ty)
  | is_deflt                 = text "default" <+> pprVarSig (map unLoc vars) (ppr ty)
  | otherwise                = pprVarSig (map unLoc vars) (ppr ty)
ppr_sig (IdSig id)           = pprVarSig [id] (ppr (varType id))
ppr_sig (FixSig fix_sig)     = ppr fix_sig
ppr_sig (SpecSig var ty inl)
  = pragBrackets (pprSpec (unLoc var) (interpp'SP ty) inl)
ppr_sig (InlineSig var inl)       = pragBrackets (ppr inl <+> pprPrefixOcc (unLoc var))
ppr_sig (SpecInstSig _ ty)
  = pragBrackets (text "SPECIALIZE instance" <+> ppr ty)
ppr_sig (MinimalSig _ bf)         = pragBrackets (pprMinimalSig bf)
ppr_sig (PatSynSig name sig_ty)
  = text "pattern" <+> pprPrefixOcc (unLoc name) <+> dcolon
                           <+> ppr sig_ty

pprPatSynSig :: (OutputableBndr name)
             => name -> Bool -> SDoc -> Maybe SDoc -> Maybe SDoc -> SDoc -> SDoc
pprPatSynSig ident _is_bidir tvs req prov ty
  = text "pattern" <+> pprPrefixOcc ident <+> dcolon <+>
    tvs <+> context <+> ty
  where
    context = case (req, prov) of
        (Nothing, Nothing)    -> empty
        (Nothing, Just prov)  -> parens empty <+> darrow <+> prov <+> darrow
        (Just req, Nothing)   -> req <+> darrow
        (Just req, Just prov) -> req <+> darrow <+> prov <+> darrow

instance OutputableBndr name => Outputable (FixitySig name) where
  ppr (FixitySig names fixity) = sep [ppr fixity, pprops]
    where
      pprops = hsep $ punctuate comma (map (pprInfixOcc . unLoc) names)

pragBrackets :: SDoc -> SDoc
pragBrackets doc = text "{-#" <+> doc <+> ptext (sLit "#-}")

pprVarSig :: (OutputableBndr id) => [id] -> SDoc -> SDoc
pprVarSig vars pp_ty = sep [pprvars <+> dcolon, nest 2 pp_ty]
  where
    pprvars = hsep $ punctuate comma (map pprPrefixOcc vars)

pprSpec :: (OutputableBndr id) => id -> SDoc -> InlinePragma -> SDoc
pprSpec var pp_ty inl = text "SPECIALIZE" <+> pp_inl <+> pprVarSig [var] pp_ty
  where
    pp_inl | isDefaultInlinePragma inl = empty
           | otherwise = ppr inl

pprTcSpecPrags :: TcSpecPrags -> SDoc
pprTcSpecPrags IsDefaultMethod = text "<default method>"
pprTcSpecPrags (SpecPrags ps)  = vcat (map (ppr . unLoc) ps)

instance Outputable TcSpecPrag where
  ppr (SpecPrag var _ inl) = pprSpec var (text "<type>") inl

pprMinimalSig :: OutputableBndr name => LBooleanFormula (Located name) -> SDoc
pprMinimalSig (L _ bf) = text "MINIMAL" <+> ppr (fmap unLoc bf)

{-
************************************************************************
*                                                                      *
\subsection[PatSynBind]{A pattern synonym definition}
*                                                                      *
************************************************************************
-}

data HsPatSynDetails a
  = InfixPatSyn a a
  | PrefixPatSyn [a]
  | RecordPatSyn [RecordPatSynField a]
  deriving (Typeable, Data)


-- See Note [Record PatSyn Fields]
data RecordPatSynField a
  = RecordPatSynField {
      recordPatSynSelectorId :: a  -- Selector name visible in rest of the file
      , recordPatSynPatVar :: a
      -- Filled in by renamer, the name used internally
      -- by the pattern
      } deriving (Typeable, Data)



{-
Note [Record PatSyn Fields]

Consider the following two pattern synonyms.

pattern P x y = ([x,True], [y,'v'])
pattern Q{ x, y } =([x,True], [y,'v'])

In P, we just have two local binders, x and y.

In Q, we have local binders but also top-level record selectors
x :: ([Bool], [Char]) -> Bool and similarly for y.

It would make sense to support record-like syntax

pattern Q{ x=x1, y=y1 } = ([x1,True], [y1,'v'])

when we have a different name for the local and top-level binder
the distinction between the two names clear

-}
instance Functor RecordPatSynField where
    fmap f (RecordPatSynField visible hidden) =
      RecordPatSynField (f visible) (f hidden)

instance Outputable a => Outputable (RecordPatSynField a) where
    ppr (RecordPatSynField v _) = ppr v

instance Foldable RecordPatSynField  where
    foldMap f (RecordPatSynField visible hidden) =
      f visible `mappend` f hidden

instance Traversable RecordPatSynField where
    traverse f (RecordPatSynField visible hidden) =
      RecordPatSynField <$> f visible <*> f hidden


instance Functor HsPatSynDetails where
    fmap f (InfixPatSyn left right) = InfixPatSyn (f left) (f right)
    fmap f (PrefixPatSyn args) = PrefixPatSyn (fmap f args)
    fmap f (RecordPatSyn args) = RecordPatSyn (map (fmap f) args)

instance Foldable HsPatSynDetails where
    foldMap f (InfixPatSyn left right) = f left `mappend` f right
    foldMap f (PrefixPatSyn args) = foldMap f args
    foldMap f (RecordPatSyn args) = foldMap (foldMap f) args

    foldl1 f (InfixPatSyn left right) = left `f` right
    foldl1 f (PrefixPatSyn args) = Data.List.foldl1 f args
    foldl1 f (RecordPatSyn args) =
      Data.List.foldl1 f (map (Data.Foldable.foldl1 f) args)

    foldr1 f (InfixPatSyn left right) = left `f` right
    foldr1 f (PrefixPatSyn args) = Data.List.foldr1 f args
    foldr1 f (RecordPatSyn args) =
      Data.List.foldr1 f (map (Data.Foldable.foldr1 f) args)

    length (InfixPatSyn _ _) = 2
    length (PrefixPatSyn args) = Data.List.length args
    length (RecordPatSyn args) = Data.List.length args

    null (InfixPatSyn _ _) = False
    null (PrefixPatSyn args) = Data.List.null args
    null (RecordPatSyn args) = Data.List.null args

    toList (InfixPatSyn left right) = [left, right]
    toList (PrefixPatSyn args) = args
    toList (RecordPatSyn args) = foldMap toList args

instance Traversable HsPatSynDetails where
    traverse f (InfixPatSyn left right) = InfixPatSyn <$> f left <*> f right
    traverse f (PrefixPatSyn args) = PrefixPatSyn <$> traverse f args
    traverse f (RecordPatSyn args) = RecordPatSyn <$> traverse (traverse f) args

data HsPatSynDir id
  = Unidirectional
  | ImplicitBidirectional
  | ExplicitBidirectional (MatchGroup id (LHsExpr id))
  deriving (Typeable)
deriving instance (DataId id) => Data (HsPatSynDir id)
