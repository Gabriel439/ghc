{-# LANGUAGE CPP, ScopedTypeVariables #-}

module TcErrors(
       reportUnsolved, reportAllUnsolved, warnAllUnsolved,
       warnDefaulting,

       solverDepthErrorTcS
  ) where

#include "HsVersions.h"

import TcRnTypes
import TcRnMonad
import TcMType
import TcType
import RnEnv( unknownNameSuggestions )
import Type
import TyCoRep
import Kind
import Unify            ( tcMatchTys )
import Module
import FamInst
import FamInstEnv       ( flattenTys )
import Inst
import InstEnv
import TyCon
import Class
import DataCon
import TcEvidence
import Name
import RdrName ( lookupGRE_Name, GlobalRdrEnv, mkRdrUnqual )
import PrelNames ( typeableClassName, hasKey
                 , liftedDataConKey, unliftedDataConKey )
import Id
import Var
import VarSet
import VarEnv
import NameSet
import Bag
import ErrUtils         ( ErrMsg, errDoc, pprLocErrMsg )
import BasicTypes
import Util
import FastString
import Outputable
import SrcLoc
import DynFlags
import StaticFlags      ( opt_PprStyle_Debug )
import ListSetOps       ( equivClasses )
import Maybes
import qualified GHC.LanguageExtensions as LangExt

import Control.Monad    ( when )
import Data.List        ( partition, mapAccumL, nub, sortBy )

#if __GLASGOW_HASKELL__ > 710
import Data.Semigroup   ( Semigroup )
import qualified Data.Semigroup as Semigroup
#endif


{-
************************************************************************
*                                                                      *
\section{Errors and contexts}
*                                                                      *
************************************************************************

ToDo: for these error messages, should we note the location as coming
from the insts, or just whatever seems to be around in the monad just
now?

Note [Deferring coercion errors to runtime]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
While developing, sometimes it is desirable to allow compilation to succeed even
if there are type errors in the code. Consider the following case:

  module Main where

  a :: Int
  a = 'a'

  main = print "b"

Even though `a` is ill-typed, it is not used in the end, so if all that we're
interested in is `main` it is handy to be able to ignore the problems in `a`.

Since we treat type equalities as evidence, this is relatively simple. Whenever
we run into a type mismatch in TcUnify, we normally just emit an error. But it
is always safe to defer the mismatch to the main constraint solver. If we do
that, `a` will get transformed into

  co :: Int ~ Char
  co = ...

  a :: Int
  a = 'a' `cast` co

The constraint solver would realize that `co` is an insoluble constraint, and
emit an error with `reportUnsolved`. But we can also replace the right-hand side
of `co` with `error "Deferred type error: Int ~ Char"`. This allows the program
to compile, and it will run fine unless we evaluate `a`. This is what
`deferErrorsToRuntime` does.

It does this by keeping track of which errors correspond to which coercion
in TcErrors. TcErrors.reportTidyWanteds does not print the errors
and does not fail if -fdefer-type-errors is on, so that we can continue
compilation. The errors are turned into warnings in `reportUnsolved`.
-}

-- | Report unsolved goals as errors or warnings. We may also turn some into
-- deferred run-time errors if `-fdefer-type-errors` is on.
reportUnsolved :: WantedConstraints -> TcM (Bag EvBind)
reportUnsolved wanted
  = do { binds_var <- newTcEvBinds
       ; defer_errors <- goptM Opt_DeferTypeErrors
       ; warn_errors <- woptM Opt_WarnDeferredTypeErrors -- implement #10283
       ; let type_errors | not defer_errors = TypeError
                         | warn_errors      = TypeWarn
                         | otherwise        = TypeDefer

       ; defer_holes <- goptM Opt_DeferTypedHoles
       ; warn_holes  <- woptM Opt_WarnTypedHoles
       ; let expr_holes | not defer_holes = HoleError
                        | warn_holes      = HoleWarn
                        | otherwise       = HoleDefer

       ; partial_sigs      <- xoptM LangExt.PartialTypeSignatures
       ; warn_partial_sigs <- woptM Opt_WarnPartialTypeSignatures
       ; let type_holes | not partial_sigs  = HoleError
                        | warn_partial_sigs = HoleWarn
                        | otherwise         = HoleDefer

       ; report_unsolved (Just binds_var) False type_errors expr_holes type_holes wanted
       ; getTcEvBinds binds_var }

-- | Report *all* unsolved goals as errors, even if -fdefer-type-errors is on
-- See Note [Deferring coercion errors to runtime]
reportAllUnsolved :: WantedConstraints -> TcM ()
reportAllUnsolved wanted
  = report_unsolved Nothing False TypeError HoleError HoleError wanted

-- | Report all unsolved goals as warnings (but without deferring any errors to
-- run-time). See Note [Safe Haskell Overlapping Instances Implementation] in
-- TcSimplify
warnAllUnsolved :: WantedConstraints -> TcM ()
warnAllUnsolved wanted
  = report_unsolved Nothing True TypeWarn HoleWarn HoleWarn wanted

-- | Report unsolved goals as errors or warnings.
report_unsolved :: Maybe EvBindsVar  -- cec_binds
                -> Bool              -- Errors as warnings
                -> TypeErrorChoice   -- Deferred type errors
                -> HoleChoice        -- Expression holes
                -> HoleChoice        -- Type holes
                -> WantedConstraints -> TcM ()
report_unsolved mb_binds_var err_as_warn type_errors expr_holes type_holes wanted
  | isEmptyWC wanted
  = return ()
  | otherwise
  = do { traceTc "reportUnsolved (before zonking and tidying)" (ppr wanted)

       ; wanted <- zonkWC wanted   -- Zonk to reveal all information
       ; env0 <- tcInitTidyEnv
            -- If we are deferring we are going to need /all/ evidence around,
            -- including the evidence produced by unflattening (zonkWC)
       ; let tidy_env = tidyFreeTyCoVars env0 free_tvs
             free_tvs = tyCoVarsOfWC wanted

       ; traceTc "reportUnsolved (after zonking and tidying):" $
         vcat [ pprTvBndrs (varSetElems free_tvs)
              , ppr wanted ]

       ; warn_redundant <- woptM Opt_WarnRedundantConstraints
       ; let err_ctxt = CEC { cec_encl  = []
                            , cec_tidy  = tidy_env
                            , cec_defer_type_errors = type_errors
                            , cec_errors_as_warns = err_as_warn
                            , cec_expr_holes = expr_holes
                            , cec_type_holes = type_holes
                            , cec_suppress = False -- See Note [Suppressing error messages]
                            , cec_warn_redundant = warn_redundant
                            , cec_binds    = mb_binds_var }

       ; tc_lvl <- getTcLevel
       ; reportWanteds err_ctxt tc_lvl wanted }

--------------------------------------------
--      Internal functions
--------------------------------------------

-- | An error Report collects messages categorised by their importance.
-- See Note [Error report] for details.
data Report
  = Report { report_important :: [SDoc]
           , report_relevant_bindings :: [SDoc]
           }

{- Note [Error report]
The idea is that error msgs are divided into three parts: the main msg, the
context block (\"In the second argument of ...\"), and the relevant bindings
block, which are displayed in that order, with a mark to divide them.  The
idea is that the main msg ('report_important') varies depending on the error
in question, but context and relevant bindings are always the same, which
should simplify visual parsing.

The context is added when the the Report is passed off to 'mkErrorReport'.
Unfortunately, unlike the context, the relevant bindings are added in
multiple places so they have to be in the Report.
-}

#if __GLASGOW_HASKELL__ > 710
instance Semigroup Report where
    Report a1 b1 <> Report a2 b2 = Report (a1 ++ a2) (b1 ++ b2)
#endif

instance Monoid Report where
    mempty = Report [] []
    mappend (Report a1 b1) (Report a2 b2) = Report (a1 ++ a2) (b1 ++ b2)

-- | Put a doc into the important msgs block.
important :: SDoc -> Report
important doc = mempty { report_important = [doc] }

-- | Put a doc into the relevant bindings block.
relevant_bindings :: SDoc -> Report
relevant_bindings doc = mempty { report_relevant_bindings = [doc] }

data TypeErrorChoice   -- What to do for type errors found by the type checker
  = TypeError     -- A type error aborts compilation with an error message
  | TypeWarn      -- A type error is deferred to runtime, plus a compile-time warning
  | TypeDefer     -- A type error is deferred to runtime; no error or warning at compile time

data HoleChoice
  = HoleError     -- A hole is a compile-time error
  | HoleWarn      -- Defer to runtime, emit a compile-time warning
  | HoleDefer     -- Defer to runtime, no warning

data ReportErrCtxt
    = CEC { cec_encl :: [Implication]  -- Enclosing implications
                                       --   (innermost first)
                                       -- ic_skols and givens are tidied, rest are not
          , cec_tidy  :: TidyEnv
          , cec_binds :: Maybe EvBindsVar
                         -- Nothinng <=> Report all errors, including holes; no bindings
                         -- Just ev  <=> make some errors (depending on cec_defer)
                         --              into warnings, and emit evidence bindings
                         --              into 'ev' for unsolved constraints

          , cec_errors_as_warns :: Bool   -- Turn all errors into warnings
                                          -- (except for Holes, which are
                                          -- controlled by cec_type_holes and
                                          -- cec_expr_holes)
          , cec_defer_type_errors :: TypeErrorChoice -- Defer type errors until runtime
                                                     -- Irrelevant if cec_binds = Nothing

          , cec_expr_holes :: HoleChoice  -- Holes in expressions
          , cec_type_holes :: HoleChoice  -- Holes in types

          , cec_warn_redundant :: Bool    -- True <=> -Wredundant-constraints

          , cec_suppress :: Bool    -- True <=> More important errors have occurred,
                                    --          so create bindings if need be, but
                                    --          don't issue any more errors/warnings
                                    -- See Note [Suppressing error messages]
      }

{-
Note [Suppressing error messages]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The cec_suppress flag says "don't report any errors".  Instead, just create
evidence bindings (as usual).  It's used when more important errors have occurred.

Specifically (see reportWanteds)
  * If there are insoluble Givens, then we are in unreachable code and all bets
    are off.  So don't report any further errors.
  * If there are any insolubles (eg Int~Bool), here or in a nested implication,
    then suppress errors from the simple constraints here.  Sometimes the
    simple-constraint errors are a knock-on effect of the insolubles.
-}

reportImplic :: ReportErrCtxt -> Implication -> TcM ()
reportImplic ctxt implic@(Implic { ic_skols = tvs, ic_given = given
                                 , ic_wanted = wanted, ic_binds = m_evb
                                 , ic_status = status, ic_info = info
                                 , ic_env = tcl_env, ic_tclvl = tc_lvl })
  | BracketSkol <- info
  , not insoluble
  = return ()        -- For Template Haskell brackets report only
                     -- definite errors. The whole thing will be re-checked
                     -- later when we plug it in, and meanwhile there may
                     -- certainly be un-satisfied constraints

  | otherwise
  = do { reportWanteds ctxt' tc_lvl wanted
       ; traceTc "reportImplic" (ppr implic)
       ; when (cec_warn_redundant ctxt) $
         warnRedundantConstraints ctxt' tcl_env info' dead_givens }
  where
    insoluble    = isInsolubleStatus status
    (env1, tvs') = mapAccumL tidyTyCoVarBndr (cec_tidy ctxt) tvs
    info'        = tidySkolemInfo env1 info
    implic' = implic { ic_skols = tvs'
                     , ic_given = map (tidyEvVar env1) given
                     , ic_info  = info' }
    ctxt' = ctxt { cec_tidy     = env1
                 , cec_encl     = implic' : cec_encl ctxt
                 , cec_suppress = insoluble  -- Suppress inessential errors if there
                                             -- are are insolubles anywhere in the
                                             -- tree rooted here
                 , cec_binds    = cec_binds ctxt *> m_evb }
                                  -- if cec_binds ctxt is Nothing, that means
                                  -- we're reporting *all* errors. Don't change
                                  -- that behavior just because we're going into
                                  -- an implication.
    dead_givens = case status of
                    IC_Solved { ics_dead = dead } -> dead
                    _                             -> []

warnRedundantConstraints :: ReportErrCtxt -> TcLclEnv -> SkolemInfo -> [EvVar] -> TcM ()
warnRedundantConstraints ctxt env info ev_vars
 | null redundant_evs
 = return ()

 | SigSkol {} <- info
 = setLclEnv env $  -- We want to add "In the type signature for f"
                    -- to the error context, which is a bit tiresome
   addErrCtxt (text "In" <+> ppr info) $
   do { env <- getLclEnv
      ; msg <- mkErrorReport ctxt env (important doc)
      ; reportWarning msg }

 | otherwise  -- But for InstSkol there already *is* a surrounding
              -- "In the instance declaration for Eq [a]" context
              -- and we don't want to say it twice. Seems a bit ad-hoc
 = do { msg <- mkErrorReport ctxt env (important doc)
      ; reportWarning msg }
 where
   doc = text "Redundant constraint" <> plural redundant_evs <> colon
         <+> pprEvVarTheta redundant_evs

   redundant_evs = case info of -- See Note [Redundant constraints in instance decls]
                     InstSkol -> filterOut improving ev_vars
                     _        -> ev_vars

   improving ev_var = any isImprovementPred $
                      transSuperClasses (idType ev_var)

{- Note [Redundant constraints in instance decls]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
For instance declarations, we don't report unused givens if
they can give rise to improvement.  Example (Trac #10100):
    class Add a b ab | a b -> ab, a ab -> b
    instance Add Zero b b
    instance Add a b ab => Add (Succ a) b (Succ ab)
The context (Add a b ab) for the instance is clearly unused in terms
of evidence, since the dictionary has no feilds.  But it is still
needed!  With the context, a wanted constraint
   Add (Succ Zero) beta (Succ Zero)
we will reduce to (Add Zero beta Zero), and thence we get beta := Zero.
But without the context we won't find beta := Zero.

This only matters in instance declarations..
-}

reportWanteds :: ReportErrCtxt -> TcLevel -> WantedConstraints -> TcM ()
reportWanteds ctxt tc_lvl (WC { wc_simple = simples, wc_insol = insols, wc_impl = implics })
  = do { traceTc "reportWanteds" (vcat [ text "Simples =" <+> ppr simples
                                       , text "Suppress =" <+> ppr (cec_suppress ctxt)])
       ; let tidy_cts = bagToList (mapBag (tidyCt env) (insols `unionBags` simples))

         -- First deal with things that are utterly wrong
         -- Like Int ~ Bool (incl nullary TyCons)
         -- or  Int ~ t a   (AppTy on one side)
         -- These ones are not suppressed by the incoming context
       ; let ctxt_for_insols = ctxt { cec_suppress = False }
       ; (ctxt1, cts1) <- tryReporters ctxt_for_insols report1 tidy_cts

         -- Now all the other constraints.  We suppress errors here if
         -- any of the first batch failed, or if the enclosing context
         -- says to suppress
       ; let ctxt2 = ctxt { cec_suppress = cec_suppress ctxt || cec_suppress ctxt1 }
       ; (_, leftovers) <- tryReporters ctxt2 report2 cts1
       ; MASSERT2( null leftovers, ppr leftovers )

            -- All the Derived ones have been filtered out of simples
            -- by the constraint solver. This is ok; we don't want
            -- to report unsolved Derived goals as errors
            -- See Note [Do not report derived but soluble errors]

     ; mapBagM_ (reportImplic ctxt2) implics }
            -- NB ctxt1: don't suppress inner insolubles if there's only a
            -- wanted insoluble here; but do suppress inner insolubles
            -- if there's a *given* insoluble here (= inaccessible code)
 where
    env = cec_tidy ctxt

    -- report1: ones that should *not* be suppresed by
    --          an insoluble somewhere else in the tree
    -- It's crucial that anything that is considered insoluble
    -- (see TcRnTypes.trulyInsoluble) is caught here, otherwise
    -- we might suppress its error message, and proceed on past
    -- type checking to get a Lint error later
    report1 = [ ("custom_error", is_user_type_error,
                                                  True, mkUserTypeErrorReporter)
              , ("insoluble1",   is_given_eq,     True, mkGroupReporter mkEqErr)
              , ("insoluble2",   utterly_wrong,   True, mkGroupReporter mkEqErr)
              , ("skolem eq1",   very_wrong,      True, mkSkolReporter)
              , ("skolem eq2",   skolem_eq,       True, mkSkolReporter)
              , ("non-tv eq",    non_tv_eq,       True, mkSkolReporter)
              , ("Out of scope", is_out_of_scope, True,  mkHoleReporter)
              , ("Holes",        is_hole,         False, mkHoleReporter)

                  -- The only remaining equalities are alpha ~ ty,
                  -- where alpha is untouchable; and representational equalities
              , ("Other eqs",    is_equality,     False, mkGroupReporter mkEqErr) ]

    -- report2: we suppress these if there are insolubles elsewhere in the tree
    report2 = [ ("Implicit params", is_ip,           False, mkGroupReporter mkIPErr)
              , ("Irreds",          is_irred,        False, mkGroupReporter mkIrredErr)
              , ("Dicts",           is_dict,         False, mkGroupReporter mkDictErr) ]

    -- rigid_nom_eq, rigid_nom_tv_eq,
    is_hole, is_dict,
      is_equality, is_ip, is_irred :: Ct -> PredTree -> Bool

    is_given_eq ct pred
       | EqPred {} <- pred = arisesFromGivens ct
       | otherwise         = False
       -- I think all given residuals are equalities

    -- Things like (Int ~N Bool)
    utterly_wrong _ (EqPred NomEq ty1 ty2) = isRigidTy ty1 && isRigidTy ty2
    utterly_wrong _ _                      = False

    -- Things like (a ~N Int)
    very_wrong _ (EqPred NomEq ty1 ty2) = isSkolemTy tc_lvl ty1 && isRigidTy ty2
    very_wrong _ _                      = False

    -- Things like (a ~N b) or (a  ~N  F Bool)
    skolem_eq _ (EqPred NomEq ty1 _) =  isSkolemTy tc_lvl ty1
    skolem_eq _ _                    = False

    -- Things like (F a  ~N  Int)
    non_tv_eq _ (EqPred NomEq ty1 _) = not (isTyVarTy ty1)
    non_tv_eq _ _                    = False

--    rigid_nom_eq _ pred = isRigidEqPred tc_lvl pred
--
--    rigid_nom_tv_eq _ pred
--      | EqPred _ ty1 _ <- pred = isRigidEqPred tc_lvl pred && isTyVarTy ty1
--      | otherwise              = False

    is_out_of_scope ct _ = isOutOfScopeCt ct
    is_hole         ct _ = isHoleCt ct

    is_user_type_error ct _ = isUserTypeErrorCt ct

    is_equality _ (EqPred {}) = True
    is_equality _ _           = False

    is_dict _ (ClassPred {}) = True
    is_dict _ _              = False

    is_ip _ (ClassPred cls _) = isIPClass cls
    is_ip _ _                 = False

    is_irred _ (IrredPred {}) = True
    is_irred _ _              = False


---------------
isSkolemTy :: TcLevel -> Type -> Bool
isSkolemTy tc_lvl ty
  = case getTyVar_maybe ty of
      Nothing -> False
      Just tv -> isSkolemTyVar tv
              || (isSigTyVar tv && isTouchableMetaTyVar tc_lvl tv)
         -- The latter case is for touchable SigTvs
         -- we postpone untouchables to a latter test (too obscure)

isTyFun_maybe :: Type -> Maybe TyCon
isTyFun_maybe ty = case tcSplitTyConApp_maybe ty of
                      Just (tc,_) | isTypeFamilyTyCon tc -> Just tc
                      _ -> Nothing


--------------------------------------------
--      Reporters
--------------------------------------------

type Reporter
  = ReportErrCtxt -> [Ct] -> TcM ()
type ReporterSpec
  = ( String                     -- Name
    , Ct -> PredTree -> Bool     -- Pick these ones
    , Bool                       -- True <=> suppress subsequent reporters
    , Reporter)                  -- The reporter itself

mkSkolReporter :: Reporter
-- Suppress duplicates with either the same LHS, or same location
mkSkolReporter ctxt cts
  = mapM_ (reportGroup mkEqErr ctxt) (group cts)
  where
     group [] = []
     group (ct:cts) = (ct : yeses) : group noes
        where
          (yeses, noes) = partition (group_with ct) cts

     group_with ct1 ct2
       | EQ <- cmp_loc      ct1 ct2 = True
       | EQ <- cmp_lhs_type ct1 ct2 = True
       | otherwise                  = False

mkHoleReporter :: Reporter
-- Reports errors one at a time
mkHoleReporter ctxt
  = mapM_ $ \ct ->
    do { err <- mkHoleError ctxt ct
       ; maybeReportHoleError ctxt ct err
       ; maybeAddDeferredHoleBinding ctxt err ct }

mkUserTypeErrorReporter :: Reporter
mkUserTypeErrorReporter ctxt
  = mapM_ $ \ct -> maybeReportError ctxt =<< mkUserTypeError ctxt ct

mkUserTypeError :: ReportErrCtxt -> Ct -> TcM ErrMsg
mkUserTypeError ctxt ct = mkErrorMsgFromCt ctxt ct
                        $ important
                        $ pprUserTypeErrorTy
                        $ case getUserTypeErrorMsg ct of
                            Just msg -> msg
                            Nothing  -> pprPanic "mkUserTypeError" (ppr ct)


mkGroupReporter :: (ReportErrCtxt -> [Ct] -> TcM ErrMsg)
                             -- Make error message for a group
                -> Reporter  -- Deal with lots of constraints
-- Group together errors from same location,
-- and report only the first (to avoid a cascade)
mkGroupReporter mk_err ctxt cts
  = mapM_ (reportGroup mk_err ctxt) (equivClasses cmp_loc cts)
  where

cmp_lhs_type :: Ct -> Ct -> Ordering
cmp_lhs_type ct1 ct2
  = case (classifyPredType (ctPred ct1), classifyPredType (ctPred ct2)) of
       (EqPred eq_rel1 ty1 _, EqPred eq_rel2 ty2 _) ->
         (eq_rel1 `compare` eq_rel2) `thenCmp` (ty1 `cmpType` ty2)
       _ -> pprPanic "mkSkolReporter" (ppr ct1 $$ ppr ct2)

cmp_loc :: Ct -> Ct -> Ordering
cmp_loc ct1 ct2 = ctLocSpan (ctLoc ct1) `compare` ctLocSpan (ctLoc ct2)

reportGroup :: (ReportErrCtxt -> [Ct] -> TcM ErrMsg) -> ReportErrCtxt
            -> [Ct] -> TcM ()
reportGroup mk_err ctxt cts =
  case partition isMonadFailInstanceMissing cts of
        -- Only warn about missing MonadFail constraint when
        -- there are no other missing contstraints!
        (monadFailCts, []) -> do { err <- mk_err ctxt monadFailCts
                                 ; reportWarning err }

        (_, cts') -> do { err <- mk_err ctxt cts'
                        ; maybeReportError ctxt err
                        ; mapM_ (maybeAddDeferredBinding ctxt err) cts' }
                                -- Add deferred bindings for all
                                -- But see Note [Always warn with -fdefer-type-errors]
  where
    isMonadFailInstanceMissing ct =
        case ctLocOrigin (ctLoc ct) of
            FailablePattern _pat -> True
            _otherwise           -> False

maybeReportHoleError :: ReportErrCtxt -> Ct -> ErrMsg -> TcM ()
maybeReportHoleError ctxt ct err
  -- When -XPartialTypeSignatures is on, warnings (instead of errors) are
  -- generated for holes in partial type signatures.
  -- Unless -fwarn_partial_type_signatures is not on,
  -- in which case the messages are discarded.
  | isTypeHoleCt ct
  = -- For partial type signatures, generate warnings only, and do that
    -- only if -fwarn_partial_type_signatures is on
    case cec_type_holes ctxt of
       HoleError -> reportError err
       HoleWarn  -> reportWarning err
       HoleDefer -> return ()

  -- Otherwise this is a typed hole in an expression
  | otherwise
  = -- If deferring, report a warning only if -Wtyped-holds is on
    case cec_expr_holes ctxt of
       HoleError -> reportError err
       HoleWarn  -> reportWarning err
       HoleDefer -> return ()

maybeReportError :: ReportErrCtxt -> ErrMsg -> TcM ()
-- Report the error and/or make a deferred binding for it
maybeReportError ctxt err
  | cec_suppress ctxt    -- Some worse error has occurred;
  = return ()            -- so suppress this error/warning

  | cec_errors_as_warns ctxt
  = reportWarning err

  | otherwise
  = case cec_defer_type_errors ctxt of
      TypeDefer -> return ()
      TypeWarn  -> reportWarning err
      TypeError -> reportError err

addDeferredBinding :: ReportErrCtxt -> ErrMsg -> Ct -> TcM ()
-- See Note [Deferring coercion errors to runtime]
addDeferredBinding ctxt err ct
  | CtWanted { ctev_pred = pred, ctev_dest = dest } <- ctEvidence ct
    -- Only add deferred bindings for Wanted constraints
  , Just ev_binds_var <- cec_binds ctxt  -- We have somewhere to put the bindings
  = do { dflags <- getDynFlags
       ; let err_msg = pprLocErrMsg err
             err_fs  = mkFastString $ showSDoc dflags $
                       err_msg $$ text "(deferred type error)"
             err_tm  = EvDelayedError pred err_fs

       ; case dest of
           EvVarDest evar
             -> addTcEvBind ev_binds_var $ mkWantedEvBind evar err_tm
           HoleDest hole
             -> do { -- See Note [Deferred errors for coercion holes]
                     evar <- newEvVar pred
                   ; addTcEvBind ev_binds_var $ mkWantedEvBind evar err_tm
                   ; fillCoercionHole hole (mkTcCoVarCo evar) }}

  | otherwise   -- Do not set any evidence for Given/Derived
  = return ()

maybeAddDeferredHoleBinding :: ReportErrCtxt -> ErrMsg -> Ct -> TcM ()
maybeAddDeferredHoleBinding ctxt err ct
    | isExprHoleCt ct
    , case cec_expr_holes ctxt of
        HoleDefer -> True
        HoleWarn  -> True
        HoleError -> False
    = addDeferredBinding ctxt err ct  -- Only add bindings for holes in expressions
    | otherwise                       -- not for holes in partial type signatures
    = return ()

maybeAddDeferredBinding :: ReportErrCtxt -> ErrMsg -> Ct -> TcM ()
maybeAddDeferredBinding ctxt err ct =
  case cec_defer_type_errors ctxt of
        TypeDefer -> deferred
        TypeWarn -> deferred
        TypeError -> return ()
  where
    deferred = addDeferredBinding ctxt err ct

tryReporters :: ReportErrCtxt -> [ReporterSpec] -> [Ct] -> TcM (ReportErrCtxt, [Ct])
-- Use the first reporter in the list whose predicate says True
tryReporters ctxt reporters cts
  = do { traceTc "tryReporters {" (ppr cts)
       ; (ctxt', cts') <- go ctxt reporters cts
       ; traceTc "tryReporters }" (ppr cts')
       ; return (ctxt', cts') }
  where
    go ctxt [] cts
      = return (ctxt, cts)

    go ctxt (r : rs) cts
      = do { (ctxt', cts') <- tryReporter ctxt r cts
           ; go ctxt' rs cts' }
                -- Carry on with the rest, because we must make
                -- deferred bindings for them if we have -fdefer-type-errors
                -- But suppress their error messages

tryReporter :: ReportErrCtxt -> ReporterSpec -> [Ct] -> TcM (ReportErrCtxt, [Ct])
tryReporter ctxt (str, keep_me,  suppress_after, reporter) cts
  | null yeses = return (ctxt, cts)
  | otherwise  = do { traceTc "tryReporter:" (text str <+> ppr yeses)
                    ; reporter ctxt yeses
                    ; let ctxt' = ctxt { cec_suppress = suppress_after || cec_suppress ctxt }
                    ; return (ctxt', nos) }
  where
    (yeses, nos) = partition (\ct -> keep_me ct (classifyPredType (ctPred ct))) cts


pprArising :: CtOrigin -> SDoc
-- Used for the main, top-level error message
-- We've done special processing for TypeEq, KindEq, Given
pprArising (TypeEqOrigin {}) = empty
pprArising (KindEqOrigin {}) = empty
pprArising (GivenOrigin {})  = empty
pprArising orig              = pprCtOrigin orig

-- Add the "arising from..." part to a message about bunch of dicts
addArising :: CtOrigin -> SDoc -> SDoc
addArising orig msg = hang msg 2 (pprArising orig)

pprWithArising :: [Ct] -> (CtLoc, SDoc)
-- Print something like
--    (Eq a) arising from a use of x at y
--    (Show a) arising from a use of p at q
-- Also return a location for the error message
-- Works for Wanted/Derived only
pprWithArising []
  = panic "pprWithArising"
pprWithArising (ct:cts)
  | null cts
  = (loc, addArising (ctLocOrigin loc)
                     (pprTheta [ctPred ct]))
  | otherwise
  = (loc, vcat (map ppr_one (ct:cts)))
  where
    loc = ctLoc ct
    ppr_one ct' = hang (parens (pprType (ctPred ct')))
                     2 (pprCtLoc (ctLoc ct'))

mkErrorMsgFromCt :: ReportErrCtxt -> Ct -> Report -> TcM ErrMsg
mkErrorMsgFromCt ctxt ct report
  = mkErrorReport ctxt (ctLocEnv (ctLoc ct)) report

mkErrorReport :: ReportErrCtxt -> TcLclEnv -> Report -> TcM ErrMsg
mkErrorReport ctxt tcl_env (Report important relevant_bindings)
  = do { context <- mkErrInfo (cec_tidy ctxt) (tcl_ctxt tcl_env)
       ; mkErrDocAt (RealSrcSpan (tcl_loc tcl_env))
            (errDoc important [context] relevant_bindings)
       }

type UserGiven = ([EvVar], SkolemInfo, Bool, RealSrcSpan)

getUserGivens :: ReportErrCtxt -> [UserGiven]
-- One item for each enclosing implication
getUserGivens (CEC {cec_encl = ctxt})
  = reverse $
    [ (givens, info, no_eqs, tcl_loc env)
    | Implic { ic_given = givens, ic_env = env
             , ic_no_eqs = no_eqs, ic_info = info } <- ctxt
    , not (null givens) ]

{-
Note [Always warn with -fdefer-type-errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When -fdefer-type-errors is on we warn about *all* type errors, even
if cec_suppress is on.  This can lead to a lot more warnings than you
would get errors without -fdefer-type-errors, but if we suppress any of
them you might get a runtime error that wasn't warned about at compile
time.

This is an easy design choice to change; just flip the order of the
first two equations for maybeReportError

To be consistent, we should also report multiple warnings from a single
location in mkGroupReporter, when -fdefer-type-errors is on.  But that
is perhaps a bit *over*-consistent! Again, an easy choice to change.

With #10283, you can now opt out of deferred type error warnings.

Note [Deferred errors for coercion holes]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Suppose we need to defer a type error where the destination for the evidence
is a coercion hole. We can't just put the error in the hole, because we can't
make an erroneous coercion. (Remember that coercions are erased for runtime.)
Instead, we invent a new EvVar, bind it to an error and then make a coercion
from that EvVar, filling the hole with that coercion. Because coercions'
types are unlifted, the error is guaranteed to be hit before we get to the
coercion.

Note [Do not report derived but soluble errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The wc_simples include Derived constraints that have not been solved, but are
not insoluble (in that case they'd be in wc_insols).  We do not want to report
these as errors:

* Superclass constraints. If we have an unsolved [W] Ord a, we'll also have
  an unsolved [D] Eq a, and we do not want to report that; it's just noise.

* Functional dependencies.  For givens, consider
      class C a b | a -> b
      data T a where
         MkT :: C a d => [d] -> T a
      f :: C a b => T a -> F Int
      f (MkT xs) = length xs
  Then we get a [D] b~d.  But there *is* a legitimate call to
  f, namely   f (MkT [True]) :: T Bool, in which b=d.  So we should
  not reject the program.

  For wanteds, something similar
      data T a where
        MkT :: C Int b => a -> b -> T a
      g :: C Int c => c -> ()
      f :: T a -> ()
      f (MkT x y) = g x
  Here we get [G] C Int b, [W] C Int a, hence [D] a~b.
  But again f (MkT True True) is a legitimate call.

(We leave the Deriveds in wc_simple until reportErrors, so that we don't lose
derived superclasses between iterations of the solver.)

For functional dependencies, here is a real example,
stripped off from libraries/utf8-string/Codec/Binary/UTF8/Generic.hs

  class C a b | a -> b
  g :: C a b => a -> b -> ()
  f :: C a b => a -> b -> ()
  f xa xb =
      let loop = g xa
      in loop xb

We will first try to infer a type for loop, and we will succeed:
    C a b' => b' -> ()
Subsequently, we will type check (loop xb) and all is good. But,
recall that we have to solve a final implication constraint:
    C a b => (C a b' => .... cts from body of loop .... ))
And now we have a problem as we will generate an equality b ~ b' and fail to
solve it.


************************************************************************
*                                                                      *
                Irreducible predicate errors
*                                                                      *
************************************************************************
-}

mkIrredErr :: ReportErrCtxt -> [Ct] -> TcM ErrMsg
mkIrredErr ctxt cts
  = do { (ctxt, binds_msg, ct1) <- relevantBindings True ctxt ct1
       ; let orig = ctOrigin ct1
             msg  = couldNotDeduce (getUserGivens ctxt) (map ctPred cts, orig)
       ; mkErrorMsgFromCt ctxt ct1 $
            important msg `mappend` relevant_bindings binds_msg }
  where
    (ct1:_) = cts

----------------
mkHoleError :: ReportErrCtxt -> Ct -> TcM ErrMsg
mkHoleError ctxt ct@(CHoleCan { cc_occ = occ, cc_hole = hole_sort })
  | isOutOfScopeCt ct  -- Out of scope variables, like 'a', where 'a' isn't bound
                       -- Suggest possible in-scope variables in the message
  = do { dflags  <- getDynFlags
       ; rdr_env <- getGlobalRdrEnv
       ; impInfo <- getImports
       ; mkErrDocAt (RealSrcSpan (tcl_loc lcl_env)) $
                    errDoc [out_of_scope_msg] []
                           [unknownNameSuggestions dflags rdr_env
                            (tcl_rdr lcl_env) impInfo (mkRdrUnqual occ)] }

  | otherwise  -- Explicit holes, like "_" or "_f"
  = do { (ctxt, binds_msg, ct) <- relevantBindings False ctxt ct
               -- The 'False' means "don't filter the bindings"; see Trac #8191
       ; mkErrorMsgFromCt ctxt ct $
            important hole_msg `mappend` relevant_bindings binds_msg }

  where
    ct_loc      = ctLoc ct
    lcl_env     = ctLocEnv ct_loc
    hole_ty     = ctEvPred (ctEvidence ct)
    tyvars      = tyCoVarsOfTypeList hole_ty
    boring_type = isTyVarTy hole_ty

    out_of_scope_msg -- Print v :: ty only if the type has structure
      | boring_type = hang herald 2 (ppr occ)
      | otherwise   = hang herald 2 pp_with_type

    pp_with_type = hang (pprPrefixOcc occ) 2 (dcolon <+> pprType hole_ty)
    herald | isDataOcc occ = text "Data constructor not in scope:"
           | otherwise     = text "Variable not in scope:"

    hole_msg = case hole_sort of
      ExprHole -> vcat [ hang (text "Found hole:")
                            2 pp_with_type
                       , tyvars_msg, expr_hole_hint ]
      TypeHole -> vcat [ hang (text "Found type wildcard" <+> quotes (ppr occ))
                            2 (text "standing for" <+> quotes (pprType hole_ty))
                       , tyvars_msg, type_hole_hint ]

    tyvars_msg = ppUnless (null tyvars) $
                 text "Where:" <+> vcat (map loc_msg tyvars)

    type_hole_hint
         | HoleError <- cec_type_holes ctxt
         = text "To use the inferred type, enable PartialTypeSignatures"
         | otherwise
         = empty

    expr_hole_hint                       -- Give hint for, say,   f x = _x
         | lengthFS (occNameFS occ) > 1  -- Don't give this hint for plain "_"
         = text "Or perhaps" <+> quotes (ppr occ)
           <+> text "is mis-spelled, or not in scope"
         | otherwise
         = empty

    loc_msg tv
       | isTyVar tv
       = case tcTyVarDetails tv of
          SkolemTv {} -> pprSkol (cec_encl ctxt) tv
          MetaTv {}   -> quotes (ppr tv) <+> text "is an ambiguous type variable"
          det -> pprTcTyVarDetails det
       | otherwise
       = sdocWithDynFlags $ \dflags ->
         if gopt Opt_PrintExplicitCoercions dflags
         then quotes (ppr tv) <+> text "is a coercion variable"
         else empty

mkHoleError _ ct = pprPanic "mkHoleError" (ppr ct)

----------------
mkIPErr :: ReportErrCtxt -> [Ct] -> TcM ErrMsg
mkIPErr ctxt cts
  = do { (ctxt, binds_msg, ct1) <- relevantBindings True ctxt ct1
       ; let orig    = ctOrigin ct1
             preds   = map ctPred cts
             givens  = getUserGivens ctxt
             msg | null givens
                 = addArising orig $
                   sep [ text "Unbound implicit parameter" <> plural cts
                       , nest 2 (pprTheta preds) ]
                 | otherwise
                 = couldNotDeduce givens (preds, orig)

       ; mkErrorMsgFromCt ctxt ct1 $
            important msg `mappend` relevant_bindings binds_msg }
  where
    (ct1:_) = cts

{-
************************************************************************
*                                                                      *
                Equality errors
*                                                                      *
************************************************************************

Note [Inaccessible code]
~~~~~~~~~~~~~~~~~~~~~~~~
Consider
   data T a where
     T1 :: T a
     T2 :: T Bool

   f :: (a ~ Int) => T a -> Int
   f T1 = 3
   f T2 = 4   -- Unreachable code

Here the second equation is unreachable. The original constraint
(a~Int) from the signature gets rewritten by the pattern-match to
(Bool~Int), so the danger is that we report the error as coming from
the *signature* (Trac #7293).  So, for Given errors we replace the
env (and hence src-loc) on its CtLoc with that from the immediately
enclosing implication.
-}

mkEqErr :: ReportErrCtxt -> [Ct] -> TcM ErrMsg
-- Don't have multiple equality errors from the same location
-- E.g.   (Int,Bool) ~ (Bool,Int)   one error will do!
mkEqErr ctxt (ct:_) = mkEqErr1 ctxt ct
mkEqErr _ [] = panic "mkEqErr"

mkEqErr1 :: ReportErrCtxt -> Ct -> TcM ErrMsg
mkEqErr1 ctxt ct
  | arisesFromGivens ct
  = do { (ctxt, binds_msg, ct) <- relevantBindings True ctxt ct
       ; let (given_loc, given_msg) = mk_given (ctLoc ct) (cec_encl ctxt)
       ; dflags <- getDynFlags
       ; let report = important given_msg `mappend` relevant_bindings binds_msg
       ; mkEqErr_help dflags ctxt report
                      (setCtLoc ct given_loc) -- Note [Inaccessible code]
                      Nothing ty1 ty2 }

  | otherwise   -- Wanted or derived
  = do { (ctxt, binds_msg, ct) <- relevantBindings True ctxt ct
       ; rdr_env <- getGlobalRdrEnv
       ; fam_envs <- tcGetFamInstEnvs
       ; exp_syns <- goptM Opt_PrintExpandedSynonyms
       ; let (keep_going, is_oriented, wanted_msg)
                           = mk_wanted_extra (ctLoc ct) exp_syns
             coercible_msg = case ctEqRel ct of
               NomEq  -> empty
               ReprEq -> mkCoercibleExplanation rdr_env fam_envs ty1 ty2
       ; dflags <- getDynFlags
       ; traceTc "mkEqErr1" (ppr ct $$ pprCtOrigin (ctOrigin ct))
       ; let report = mconcat [important wanted_msg, important coercible_msg,
                               relevant_bindings binds_msg]
       ; if keep_going
         then mkEqErr_help dflags ctxt report ct is_oriented ty1 ty2
         else mkErrorMsgFromCt ctxt ct report }
  where
    (ty1, ty2) = getEqPredTys (ctPred ct)

    mk_given :: CtLoc -> [Implication] -> (CtLoc, SDoc)
    -- For given constraints we overwrite the env (and hence src-loc)
    -- with one from the implication.  See Note [Inaccessible code]
    mk_given loc []           = (loc, empty)
    mk_given loc (implic : _) = (setCtLocEnv loc (ic_env implic)
                                , hang (text "Inaccessible code in")
                                     2 (ppr (ic_info implic)))

       -- If the types in the error message are the same as the types
       -- we are unifying, don't add the extra expected/actual message
    mk_wanted_extra :: CtLoc -> Bool -> (Bool, Maybe SwapFlag, SDoc)
    mk_wanted_extra loc expandSyns
      = case ctLocOrigin loc of
          orig@TypeEqOrigin {} -> mkExpectedActualMsg ty1 ty2 orig
                                                      t_or_k expandSyns
            where
              t_or_k = ctLocTypeOrKind_maybe loc

          KindEqOrigin cty1 mb_cty2 sub_o sub_t_or_k
            -> (True, Nothing, msg1 $$ msg2)
            where
              sub_what = case sub_t_or_k of Just KindLevel -> text "kinds"
                                            _              -> text "types"
              msg1 = sdocWithDynFlags $ \dflags ->
                     case mb_cty2 of
                       Just cty2
                         |  gopt Opt_PrintExplicitCoercions dflags
                         || not (cty1 `pickyEqType` cty2)
                         -> hang (text "When matching" <+> sub_what)
                               2 (vcat [ ppr cty1 <+> dcolon <+>
                                         ppr (typeKind cty1)
                                       , ppr cty2 <+> dcolon <+>
                                         ppr (typeKind cty2) ])
                       _ -> text "When matching the kind of" <+> quotes (ppr cty1)
              msg2 = case sub_o of
                       TypeEqOrigin {}
                         | Just cty2 <- mb_cty2 ->
                         thdOf3 (mkExpectedActualMsg cty1 cty2 sub_o sub_t_or_k
                                                     expandSyns)
                       _ -> empty
          _ -> (True, Nothing, empty)

-- | This function tries to reconstruct why a "Coercible ty1 ty2" constraint
-- is left over.
mkCoercibleExplanation :: GlobalRdrEnv -> FamInstEnvs
                       -> TcType -> TcType -> SDoc
mkCoercibleExplanation rdr_env fam_envs ty1 ty2
  | Just (tc, tys) <- tcSplitTyConApp_maybe ty1
  , (rep_tc, _, _) <- tcLookupDataFamInst fam_envs tc tys
  , Just msg <- coercible_msg_for_tycon rep_tc
  = msg
  | Just (tc, tys) <- splitTyConApp_maybe ty2
  , (rep_tc, _, _) <- tcLookupDataFamInst fam_envs tc tys
  , Just msg <- coercible_msg_for_tycon rep_tc
  = msg
  | Just (s1, _) <- tcSplitAppTy_maybe ty1
  , Just (s2, _) <- tcSplitAppTy_maybe ty2
  , s1 `eqType` s2
  , has_unknown_roles s1
  = hang (text "NB: We cannot know what roles the parameters to" <+>
          quotes (ppr s1) <+> text "have;")
       2 (text "we must assume that the role is nominal")
  | otherwise
  = empty
  where
    coercible_msg_for_tycon tc
        | isAbstractTyCon tc
        = Just $ hsep [ text "NB: The type constructor"
                      , quotes (pprSourceTyCon tc)
                      , text "is abstract" ]
        | isNewTyCon tc
        , [data_con] <- tyConDataCons tc
        , let dc_name = dataConName data_con
        , null (lookupGRE_Name rdr_env dc_name)
        = Just $ hang (text "The data constructor" <+> quotes (ppr dc_name))
                    2 (sep [ text "of newtype" <+> quotes (pprSourceTyCon tc)
                           , text "is not in scope" ])
        | otherwise = Nothing

    has_unknown_roles ty
      | Just (tc, tys) <- tcSplitTyConApp_maybe ty
      = length tys >= tyConArity tc  -- oversaturated tycon
      | Just (s, _) <- tcSplitAppTy_maybe ty
      = has_unknown_roles s
      | isTyVarTy ty
      = True
      | otherwise
      = False

{-
-- | Make a listing of role signatures for all the parameterised tycons
-- used in the provided types


-- SLPJ Jun 15: I could not convince myself that these hints were really
-- useful.  Maybe they are, but I think we need more work to make them
-- actually helpful.
mkRoleSigs :: Type -> Type -> SDoc
mkRoleSigs ty1 ty2
  = ppUnless (null role_sigs) $
    hang (text "Relevant role signatures:")
       2 (vcat role_sigs)
  where
    tcs = nameEnvElts $ tyConsOfType ty1 `plusNameEnv` tyConsOfType ty2
    role_sigs = mapMaybe ppr_role_sig tcs

    ppr_role_sig tc
      | null roles  -- if there are no parameters, don't bother printing
      = Nothing
      | isBuiltInSyntax (tyConName tc)  -- don't print roles for (->), etc.
      = Nothing
      | otherwise
      = Just $ hsep $ [text "type role", ppr tc] ++ map ppr roles
      where
        roles = tyConRoles tc
-}

mkEqErr_help :: DynFlags -> ReportErrCtxt -> Report
             -> Ct
             -> Maybe SwapFlag   -- Nothing <=> not sure
             -> TcType -> TcType -> TcM ErrMsg
mkEqErr_help dflags ctxt report ct oriented ty1 ty2
  | Just tv1 <- tcGetTyVar_maybe ty1 = mkTyVarEqErr dflags ctxt report ct oriented tv1 ty2
  | Just tv2 <- tcGetTyVar_maybe ty2 = mkTyVarEqErr dflags ctxt report ct swapped  tv2 ty1
  | otherwise                        = reportEqErr ctxt report ct oriented ty1 ty2
  where
    swapped = fmap flipSwap oriented

reportEqErr :: ReportErrCtxt -> Report
            -> Ct
            -> Maybe SwapFlag   -- Nothing <=> not sure
            -> TcType -> TcType -> TcM ErrMsg
reportEqErr ctxt report ct oriented ty1 ty2
  = mkErrorMsgFromCt ctxt ct (mconcat [misMatch, eqInfo, report])
  where misMatch = important $ misMatchOrCND ctxt ct oriented ty1 ty2
        eqInfo = important $ mkEqInfoMsg ct ty1 ty2

mkTyVarEqErr :: DynFlags -> ReportErrCtxt -> Report -> Ct
             -> Maybe SwapFlag -> TcTyVar -> TcType -> TcM ErrMsg
-- tv1 and ty2 are already tidied
mkTyVarEqErr dflags ctxt report ct oriented tv1 ty2
  | isUserSkolem ctxt tv1   -- ty2 won't be a meta-tyvar, or else the thing would
                            -- be oriented the other way round;
                            -- see TcCanonical.canEqTyVarTyVar
  || isSigTyVar tv1 && not (isTyVarTy ty2)
  || ctEqRel ct == ReprEq && not (isTyVarUnderDatatype tv1 ty2)
     -- the cases below don't really apply to ReprEq (except occurs check)
  = mkErrorMsgFromCt ctxt ct $ mconcat
        [ important $ misMatchOrCND ctxt ct oriented ty1 ty2
        , important $ extraTyVarInfo ctxt tv1 ty2
        , report
        ]

  -- So tv is a meta tyvar (or started that way before we
  -- generalised it).  So presumably it is an *untouchable*
  -- meta tyvar or a SigTv, else it'd have been unified
  | OC_Occurs <- occ_check_expand
  , ctEqRel ct == NomEq || isTyVarUnderDatatype tv1 ty2
         -- See Note [Occurs check error] in TcCanonical
  = do { let occCheckMsg = important $ addArising (ctOrigin ct) $
                           hang (text "Occurs check: cannot construct the infinite" <+> what <> colon)
                              2 (sep [ppr ty1, char '~', ppr ty2])
             extra2 = important $ mkEqInfoMsg ct ty1 ty2
       ; mkErrorMsgFromCt ctxt ct $ mconcat [occCheckMsg, extra2, report] }

  | OC_Forall <- occ_check_expand
  = do { let msg = vcat [ text "Cannot instantiate unification variable"
                          <+> quotes (ppr tv1)
                        , hang (text "with a" <+> what <+> text "involving foralls:") 2 (ppr ty2)
                        , nest 2 (text "GHC doesn't yet support impredicative polymorphism") ]
       -- Unlike the other reports, this discards the old 'report_important'
       -- instead of augmenting it.  This is because the details are not likely
       -- to be helpful since this is just an unimplemented feature.
       ; mkErrorMsgFromCt ctxt ct $ report { report_important = [msg] } }

  -- If the immediately-enclosing implication has 'tv' a skolem, and
  -- we know by now its an InferSkol kind of skolem, then presumably
  -- it started life as a SigTv, else it'd have been unified, given
  -- that there's no occurs-check or forall problem
  | (implic:_) <- cec_encl ctxt
  , Implic { ic_skols = skols } <- implic
  , tv1 `elem` skols
  = mkErrorMsgFromCt ctxt ct $ mconcat
        [ important $ misMatchMsg ct oriented ty1 ty2
        , important $ extraTyVarInfo ctxt tv1 ty2
        , report
        ]

  -- Check for skolem escape
  | (implic:_) <- cec_encl ctxt   -- Get the innermost context
  , Implic { ic_env = env, ic_skols = skols, ic_info = skol_info } <- implic
  , let esc_skols = filter (`elemVarSet` (tyCoVarsOfType ty2)) skols
  , not (null esc_skols)
  = do { let msg = important $ misMatchMsg ct oriented ty1 ty2
             esc_doc = sep [ text "because" <+> what <+> text "variable" <> plural esc_skols
                             <+> pprQuotedList esc_skols
                           , text "would escape" <+>
                             if isSingleton esc_skols then text "its scope"
                                                      else text "their scope" ]
             tv_extra = important $
                        vcat [ nest 2 $ esc_doc
                             , sep [ (if isSingleton esc_skols
                                      then text "This (rigid, skolem)" <+>
                                           what <+> text "variable is"
                                      else text "These (rigid, skolem)" <+>
                                           what <+> text "variables are")
                               <+> text "bound by"
                             , nest 2 $ ppr skol_info
                             , nest 2 $ text "at" <+> ppr (tcl_loc env) ] ]
       ; mkErrorMsgFromCt ctxt ct (mconcat [msg, tv_extra, report]) }

  -- Nastiest case: attempt to unify an untouchable variable
  | (implic:_) <- cec_encl ctxt   -- Get the innermost context
  , Implic { ic_env = env, ic_given = given, ic_info = skol_info } <- implic
  = do { let msg = important $ misMatchMsg ct oriented ty1 ty2
             tclvl_extra = important $
                  nest 2 $
                  sep [ quotes (ppr tv1) <+> text "is untouchable"
                      , nest 2 $ text "inside the constraints:" <+> pprEvVarTheta given
                      , nest 2 $ text "bound by" <+> ppr skol_info
                      , nest 2 $ text "at" <+> ppr (tcl_loc env) ]
             tv_extra = important $ extraTyVarInfo ctxt tv1 ty2
             add_sig  = important $ suggestAddSig ctxt ty1 ty2
       ; mkErrorMsgFromCt ctxt ct $ mconcat
            [msg, tclvl_extra, tv_extra, add_sig, report] }

  | otherwise
  = reportEqErr ctxt report ct oriented (mkTyVarTy tv1) ty2
        -- This *can* happen (Trac #6123, and test T2627b)
        -- Consider an ambiguous top-level constraint (a ~ F a)
        -- Not an occurs check, because F is a type function.
  where
    occ_check_expand = occurCheckExpand dflags tv1 ty2
    ty1    = mkTyVarTy tv1

    what = case ctLocTypeOrKind_maybe (ctLoc ct) of
      Just KindLevel -> text "kind"
      _              -> text "type"

mkEqInfoMsg :: Ct -> TcType -> TcType -> SDoc
-- Report (a) ambiguity if either side is a type function application
--            e.g. F a0 ~ Int
--        (b) warning about injectivity if both sides are the same
--            type function application   F a ~ F b
--            See Note [Non-injective type functions]
--        (c) warning about -fprint-explicit-kinds if that might be helpful
mkEqInfoMsg ct ty1 ty2
  = tyfun_msg $$ ambig_msg $$ invis_msg
  where
    mb_fun1 = isTyFun_maybe ty1
    mb_fun2 = isTyFun_maybe ty2

    ambig_msg | isJust mb_fun1 || isJust mb_fun2
              = snd (mkAmbigMsg False ct)
              | otherwise = empty

    invis_msg | Just vis <- tcEqTypeVis ty1 ty2
              , vis /= Visible
              = sdocWithDynFlags $ \dflags ->
                if gopt Opt_PrintExplicitKinds dflags
                then text "Use -fprint-explicit-kinds to see the kind arguments"
                else empty

              | otherwise
              = empty

    tyfun_msg | Just tc1 <- mb_fun1
              , Just tc2 <- mb_fun2
              , tc1 == tc2
              = text "NB:" <+> quotes (ppr tc1)
                <+> text "is a type function, and may not be injective"
              | otherwise = empty

isUserSkolem :: ReportErrCtxt -> TcTyVar -> Bool
-- See Note [Reporting occurs-check errors]
isUserSkolem ctxt tv
  = isSkolemTyVar tv && any is_user_skol_tv (cec_encl ctxt)
  where
    is_user_skol_tv (Implic { ic_skols = sks, ic_info = skol_info })
      = tv `elem` sks && is_user_skol_info skol_info

    is_user_skol_info (InferSkol {}) = False
    is_user_skol_info _ = True

misMatchOrCND :: ReportErrCtxt -> Ct
              -> Maybe SwapFlag -> TcType -> TcType -> SDoc
-- If oriented then ty1 is actual, ty2 is expected
misMatchOrCND ctxt ct oriented ty1 ty2
  | null givens ||
    (isRigidTy ty1 && isRigidTy ty2) ||
    isGivenCt ct
       -- If the equality is unconditionally insoluble
       -- or there is no context, don't report the context
  = misMatchMsg ct oriented ty1 ty2
  | otherwise
  = couldNotDeduce givens ([eq_pred], orig)
  where
    ev      = ctEvidence ct
    eq_pred = ctEvPred ev
    orig    = ctEvOrigin ev
    givens  = [ given | given@(_, _, no_eqs, _) <- getUserGivens ctxt, not no_eqs]
              -- Keep only UserGivens that have some equalities

couldNotDeduce :: [UserGiven] -> (ThetaType, CtOrigin) -> SDoc
couldNotDeduce givens (wanteds, orig)
  = vcat [ addArising orig (text "Could not deduce:" <+> pprTheta wanteds)
         , vcat (pp_givens givens)]

pp_givens :: [UserGiven] -> [SDoc]
pp_givens givens
   = case givens of
         []     -> []
         (g:gs) ->      ppr_given (text "from the context:") g
                 : map (ppr_given (text "or from:")) gs
    where
       ppr_given herald (gs, skol_info, _, loc)
           = hang (herald <+> pprEvVarTheta gs)
                2 (sep [ text "bound by" <+> ppr skol_info
                       , text "at" <+> ppr loc])

extraTyVarInfo :: ReportErrCtxt -> TcTyVar -> TcType -> SDoc
-- Add on extra info about skolem constants
-- NB: The types themselves are already tidied
extraTyVarInfo ctxt tv1 ty2
  = tv_extra tv1 $$ ty_extra ty2
  where
    implics = cec_encl ctxt
    ty_extra ty = case tcGetTyVar_maybe ty of
                    Just tv -> tv_extra tv
                    Nothing -> empty

    tv_extra tv | isTcTyVar tv, isSkolemTyVar tv
                , let pp_tv = quotes (ppr tv)
                = case tcTyVarDetails tv of
                    SkolemTv {}   -> pprSkol implics tv
                    FlatSkol {}   -> pp_tv <+> text "is a flattening type variable"
                    RuntimeUnk {} -> pp_tv <+> text "is an interactive-debugger skolem"
                    MetaTv {}     -> empty

                | otherwise             -- Normal case
                = empty

suggestAddSig :: ReportErrCtxt -> TcType -> TcType -> SDoc
-- See Note [Suggest adding a type signature]
suggestAddSig ctxt ty1 ty2
  | null inferred_bndrs
  = empty
  | [bndr] <- inferred_bndrs
  = text "Possible fix: add a type signature for" <+> quotes (ppr bndr)
  | otherwise
  = text "Possible fix: add type signatures for some or all of" <+> (ppr inferred_bndrs)
  where
    inferred_bndrs = nub (get_inf ty1 ++ get_inf ty2)
    get_inf ty | Just tv <- tcGetTyVar_maybe ty
               , isTcTyVar tv, isSkolemTyVar tv
               , (_, InferSkol prs) <- getSkolemInfo (cec_encl ctxt) tv
               = map fst prs
               | otherwise
               = []

--------------------
misMatchMsg :: Ct -> Maybe SwapFlag -> TcType -> TcType -> SDoc
-- Types are already tidy
-- If oriented then ty1 is actual, ty2 is expected
misMatchMsg ct oriented ty1 ty2
  | Just NotSwapped <- oriented
  = misMatchMsg ct (Just IsSwapped) ty2 ty1

  | Just (tc1, []) <- splitTyConApp_maybe ty1
  , Just (tc2, []) <- splitTyConApp_maybe ty2
  , (tc1 `hasKey` liftedDataConKey && tc2 `hasKey` unliftedDataConKey) ||
    (tc2 `hasKey` liftedDataConKey && tc1 `hasKey` unliftedDataConKey)
  = addArising orig $
    text "Couldn't match a lifted type with an unlifted type"

  | otherwise  -- So now we have Nothing or (Just IsSwapped)
               -- For some reason we treat Nothign like IsSwapped
  = addArising orig $
    sep [ text herald1 <+> quotes (ppr ty1)
        , nest padding $
          text herald2 <+> quotes (ppr ty2)
        , sameOccExtra ty2 ty1 ]
  where
    herald1 = conc [ "Couldn't match"
                   , if is_repr     then "representation of" else ""
                   , if is_oriented then "expected"          else ""
                   , what ]
    herald2 = conc [ "with"
                   , if is_repr     then "that of"           else ""
                   , if is_oriented then ("actual " ++ what) else "" ]
    padding = length herald1 - length herald2

    is_repr = case ctEqRel ct of { ReprEq -> True; NomEq -> False }
    is_oriented = isJust oriented

    orig = ctOrigin ct
    what = case ctLocTypeOrKind_maybe (ctLoc ct) of
      Just KindLevel -> "kind"
      _              -> "type"

    conc :: [String] -> String
    conc = foldr1 add_space

    add_space :: String -> String -> String
    add_space s1 s2 | null s1   = s2
                    | null s2   = s1
                    | otherwise = s1 ++ (' ' : s2)

mkExpectedActualMsg :: Type -> Type -> CtOrigin -> Maybe TypeOrKind -> Bool
                    -> (Bool, Maybe SwapFlag, SDoc)
-- NotSwapped means (actual, expected), IsSwapped is the reverse
-- First return val is whether or not to print a herald above this msg
mkExpectedActualMsg ty1 ty2 (TypeEqOrigin { uo_actual = act
                                          , uo_expected = Check exp
                                          , uo_thing = maybe_thing })
                    m_level printExpanded
  | KindLevel <- level, occurs_check_error       = (True, Nothing, empty)
  | isUnliftedTypeKind act, isLiftedTypeKind exp = (False, Nothing, msg2)
  | isLiftedTypeKind act, isUnliftedTypeKind exp = (False, Nothing, msg3)
  | isLiftedTypeKind exp && not (isConstraintKind exp)
                                                 = (False, Nothing, msg4)
  | Just msg <- num_args_msg                     = (False, Nothing, msg $$ msg1)
  | KindLevel <- level, Just th <- maybe_thing   = (False, Nothing, msg5 th)
  | act `pickyEqType` ty1, exp `pickyEqType` ty2 = (True, Just NotSwapped, empty)
  | exp `pickyEqType` ty1, act `pickyEqType` ty2 = (True, Just IsSwapped, empty)
  | otherwise                                    = (True, Nothing, msg1)
  where
    level = m_level `orElse` TypeLevel

    occurs_check_error
      | Just act_tv <- tcGetTyVar_maybe act
      , act_tv `elemVarSet` tyCoVarsOfType exp
      = True
      | Just exp_tv <- tcGetTyVar_maybe exp
      , exp_tv `elemVarSet` tyCoVarsOfType act
      = True
      | otherwise
      = False

    sort = case level of
      TypeLevel -> text "type"
      KindLevel -> text "kind"

    msg1 = case level of
      KindLevel
        | Just th <- maybe_thing
        -> msg5 th

      _ | not (act `pickyEqType` exp)
        -> vcat [ text "Expected" <+> sort <> colon <+> ppr exp
                , text "  Actual" <+> sort <> colon <+> ppr act
                , if printExpanded then expandedTys else empty ]

        | otherwise
        -> empty

    thing_msg = case maybe_thing of
                  Just thing -> \_ -> quotes (ppr thing) <+> text "is"
                  Nothing    -> \vowel -> text "got a" <>
                                          if vowel then char 'n' else empty
    msg2 = sep [ text "Expecting a lifted type, but"
               , thing_msg True, text "unlifted" ]
    msg3 = sep [ text "Expecting an unlifted type, but"
               , thing_msg False, text "lifted" ]
    msg4 = maybe_num_args_msg $$
           sep [ text "Expected a type, but"
               , maybe (text "found something with kind")
                       (\thing -> quotes (ppr thing) <+> text "has kind")
                       maybe_thing
               , quotes (ppr act) ]

    msg5 th = hang (text "Expected" <+> kind_desc <> comma)
                 2 (text "but" <+> quotes (ppr th) <+> text "has kind" <+>
                    quotes (ppr act))
      where
        kind_desc | isConstraintKind exp = text "a constraint"
                  | otherwise            = text "kind" <+> quotes (ppr exp)

    num_args_msg = case level of
      TypeLevel -> Nothing
      KindLevel
        -> let n_act = count_args act
               n_exp = count_args exp in
           case n_act - n_exp of
             n | n /= 0
               , Just thing <- maybe_thing
               , case errorThingNumArgs_maybe thing of
                   Nothing           -> n > 0
                   Just num_act_args -> num_act_args >= -n
                     -- don't report to strip off args that aren't there
               -> Just $ text "Expecting" <+> speakN (abs n) <+>
                         more_or_fewer <+> plural_n (abs n) (text "argument")
                                       <+> text "to" <+> quotes (ppr thing)
               where
                 more_or_fewer | n < 0     = text "fewer"
                               | otherwise = text "more"
             _ -> Nothing


    maybe_num_args_msg = case num_args_msg of
      Nothing -> empty
      Just m  -> m

    count_args ty = count isVisibleBinder $ fst $ splitPiTys ty

    plural_n 1 doc = doc
    plural_n _ doc = doc <> char 's'

    expandedTys =
      ppUnless (expTy1 `pickyEqType` exp && expTy2 `pickyEqType` act) $ vcat
        [ text "Type synonyms expanded:"
        , text "Expected type:" <+> ppr expTy1
        , text "  Actual type:" <+> ppr expTy2
        ]

    (expTy1, expTy2) = expandSynonymsToMatch exp act

mkExpectedActualMsg _ _ _ _ _ = panic "mkExpectedAcutalMsg"

{-
Note [Expanding type synonyms to make types similar]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

In type error messages, if -fprint-expanded-types is used, we want to expand
type synonyms to make expected and found types as similar as possible, but we
shouldn't expand types too much to make type messages even more verbose and
harder to understand. The whole point here is to make the difference in expected
and found types clearer.

`expandSynonymsToMatch` does this, it takes two types, and expands type synonyms
only as much as necessary. It should work like this:

Given two types t1 and t2:

  * If they're already same, it shouldn't expand any type synonyms and
    just return.

  * If they're in form `C1 t1_1 .. t1_n` and `C2 t2_1 .. t2_m` (C1 and C2 are
    type constructors), it should expand C1 and C2 if they're different type
    synonyms. Then it should continue doing same thing on expanded types. If C1
    and C2 are same, then we should apply same procedure to arguments of C1
    and argument of C2 to make them as similar as possible.

    Most important thing here is to keep number of synonym expansions at
    minimum. For example, if t1 is `T (T3, T5, Int)` and t2 is
    `T (T5, T3, Bool)` where T5 = T4, T4 = T3, ..., T1 = X, we should return
    `T (T3, T3, Int)` and `T (T3, T3, Bool)`.

In the implementation, we just search in all possible solutions for a solution
that does minimum amount of expansions. This leads to a complex algorithm: If
we have two synonyms like X_m = X_{m-1} = .. X and Y_n = Y_{n-1} = .. Y, where
X and Y are rigid types, we expand m * n times. But in practice it's not a
problem because deeply nested synonyms with no intervening rigid type
constructors are vanishingly rare.

-}

-- | Expand type synonyms in given types only enough to make them as equal as
-- possible. Returned types are the same in terms of used type synonyms.
--
-- To expand all synonyms, see 'Type.expandTypeSynonyms'.
expandSynonymsToMatch :: Type -> Type -> (Type, Type)
expandSynonymsToMatch ty1 ty2 = (ty1_ret, ty2_ret)
  where
    (_, ty1_ret, ty2_ret) = go 0 ty1 ty2

    -- | Returns (number of synonym expansions done to make types similar,
    --            type synonym expanded version of first type,
    --            type synonym expanded version of second type)
    --
    -- Int argument is number of synonym expansions done so far.
    go :: Int -> Type -> Type -> (Int, Type, Type)
    go exps t1 t2
      | t1 `pickyEqType` t2 =
        -- Types are same, nothing to do
        (exps, t1, t2)

    go exps t1@(TyConApp tc1 tys1) t2@(TyConApp tc2 tys2)
      | tc1 == tc2 =
        -- Type constructors are same. They may be synonyms, but we don't
        -- expand further.
        let (exps', tys1', tys2') = unzip3 $ zipWith (go 0) tys1 tys2
         in (exps + sum exps', TyConApp tc1 tys1', TyConApp tc2 tys2')
      | otherwise =
        -- Try to expand type constructors
        case (coreView t1, coreView t2) of
          -- When only one of the constructors is a synonym, we just
          -- expand it and continue search
          (Just t1', Nothing) ->
            go (exps + 1) t1' t2
          (Nothing, Just t2') ->
            go (exps + 1) t1 t2'
          (Just t1', Just t2') ->
            -- Both constructors are synonyms, but they may be synonyms of
            -- each other. We just search for minimally expanded solution.
            -- See Note [Expanding type synonyms to make types similar].
            let sol1@(exp1, _, _) = go (exps + 1) t1' t2
                sol2@(exp2, _, _) = go (exps + 1) t1 t2'
             in if exp1 < exp2 then sol1 else sol2
          (Nothing, Nothing) ->
            -- None of the constructors are synonyms, nothing to do
            (exps, t1, t2)

    go exps t1@TyConApp{} t2
      | Just t1' <- coreView t1 = go (exps + 1) t1' t2
      | otherwise               = (exps, t1, t2)

    go exps t1 t2@TyConApp{}
      | Just t2' <- coreView t2 = go (exps + 1) t1 t2'
      | otherwise               = (exps, t1, t2)

    go exps (AppTy t1_1 t1_2) (AppTy t2_1 t2_2) =
      let (exps1, t1_1', t2_1') = go 0 t1_1 t2_1
          (exps2, t1_2', t2_2') = go 0 t1_2 t2_2
       in (exps + exps1 + exps2, mkAppTy t1_1' t1_2', mkAppTy t2_1' t2_2')

    go exps (ForAllTy (Anon t1_1) t1_2) (ForAllTy (Anon t2_1) t2_2) =
      let (exps1, t1_1', t2_1') = go 0 t1_1 t2_1
          (exps2, t1_2', t2_2') = go 0 t1_2 t2_2
       in (exps + exps1 + exps2, mkFunTy t1_1' t1_2', mkFunTy t2_1' t2_2')

    go exps (ForAllTy (Named tv1 vis1) t1) (ForAllTy (Named tv2 vis2) t2) =
      -- NOTE: We may have a bug here, but we just can't reproduce it easily.
      -- See D1016 comments for details and our attempts at producing a test
      -- case. Short version: We probably need RnEnv2 to really get this right.
      let (exps1, t1', t2') = go exps t1 t2
       in (exps1, ForAllTy (Named tv1 vis1) t1', ForAllTy (Named tv2 vis2) t2')

    go exps (CastTy ty1 _) ty2 = go exps ty1 ty2
    go exps ty1 (CastTy ty2 _) = go exps ty1 ty2

    go exps t1 t2 = (exps, t1, t2)

sameOccExtra :: TcType -> TcType -> SDoc
-- See Note [Disambiguating (X ~ X) errors]
sameOccExtra ty1 ty2
  | Just (tc1, _) <- tcSplitTyConApp_maybe ty1
  , Just (tc2, _) <- tcSplitTyConApp_maybe ty2
  , let n1 = tyConName tc1
        n2 = tyConName tc2
        same_occ = nameOccName n1                   == nameOccName n2
        same_pkg = moduleUnitId (nameModule n1) == moduleUnitId (nameModule n2)
  , n1 /= n2   -- Different Names
  , same_occ   -- but same OccName
  = text "NB:" <+> (ppr_from same_pkg n1 $$ ppr_from same_pkg n2)
  | otherwise
  = empty
  where
    ppr_from same_pkg nm
      | isGoodSrcSpan loc
      = hang (quotes (ppr nm) <+> text "is defined at")
           2 (ppr loc)
      | otherwise  -- Imported things have an UnhelpfulSrcSpan
      = hang (quotes (ppr nm))
           2 (sep [ text "is defined in" <+> quotes (ppr (moduleName mod))
                  , ppUnless (same_pkg || pkg == mainUnitId) $
                    nest 4 $ text "in package" <+> quotes (ppr pkg) ])
       where
         pkg = moduleUnitId mod
         mod = nameModule nm
         loc = nameSrcSpan nm

{-
Note [Suggest adding a type signature]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The OutsideIn algorithm rejects GADT programs that don't have a principal
type, and indeed some that do.  Example:
   data T a where
     MkT :: Int -> T Int

   f (MkT n) = n

Does this have type f :: T a -> a, or f :: T a -> Int?
The error that shows up tends to be an attempt to unify an
untouchable type variable.  So suggestAddSig sees if the offending
type variable is bound by an *inferred* signature, and suggests
adding a declared signature instead.

This initially came up in Trac #8968, concerning pattern synonyms.

Note [Disambiguating (X ~ X) errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
See Trac #8278

Note [Reporting occurs-check errors]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Given (a ~ [a]), if 'a' is a rigid type variable bound by a user-supplied
type signature, then the best thing is to report that we can't unify
a with [a], because a is a skolem variable.  That avoids the confusing
"occur-check" error message.

But nowadays when inferring the type of a function with no type signature,
even if there are errors inside, we still generalise its signature and
carry on. For example
   f x = x:x
Here we will infer somethiing like
   f :: forall a. a -> [a]
with a suspended error of (a ~ [a]).  So 'a' is now a skolem, but not
one bound by the programmer!  Here we really should report an occurs check.

So isUserSkolem distinguishes the two.

Note [Non-injective type functions]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It's very confusing to get a message like
     Couldn't match expected type `Depend s'
            against inferred type `Depend s1'
so mkTyFunInfoMsg adds:
       NB: `Depend' is type function, and hence may not be injective

Warn of loopy local equalities that were dropped.


************************************************************************
*                                                                      *
                 Type-class errors
*                                                                      *
************************************************************************
-}

mkDictErr :: ReportErrCtxt -> [Ct] -> TcM ErrMsg
mkDictErr ctxt cts
  = ASSERT( not (null cts) )
    do { inst_envs <- tcGetInstEnvs
       ; let (ct1:_) = cts  -- ct1 just for its location
             min_cts = elim_superclasses cts
             lookups = map (lookup_cls_inst inst_envs) min_cts
             (no_inst_cts, overlap_cts) = partition is_no_inst lookups

       -- Report definite no-instance errors,
       -- or (iff there are none) overlap errors
       -- But we report only one of them (hence 'head') because they all
       -- have the same source-location origin, to try avoid a cascade
       -- of error from one location
       ; (ctxt, err) <- mk_dict_err ctxt (head (no_inst_cts ++ overlap_cts))
       ; mkErrorMsgFromCt ctxt ct1 (important err) }
  where
    no_givens = null (getUserGivens ctxt)

    is_no_inst (ct, (matches, unifiers, _))
      =  no_givens
      && null matches
      && (null unifiers || all (not . isAmbiguousTyVar) (varSetElems (tyCoVarsOfCt ct)))

    lookup_cls_inst inst_envs ct
                -- Note [Flattening in error message generation]
      = (ct, lookupInstEnv True inst_envs clas (flattenTys emptyInScopeSet tys))
      where
        (clas, tys) = getClassPredTys (ctPred ct)


    -- When simplifying [W] Ord (Set a), we need
    --    [W] Eq a, [W] Ord a
    -- but we really only want to report the latter
    elim_superclasses cts
      = filter (\ct -> any (eqType (ctPred ct)) min_preds) cts
      where
        min_preds = mkMinimalBySCs (map ctPred cts)

mk_dict_err :: ReportErrCtxt -> (Ct, ClsInstLookupResult)
            -> TcM (ReportErrCtxt, SDoc)
-- Report an overlap error if this class constraint results
-- from an overlap (returning Left clas), otherwise return (Right pred)
mk_dict_err ctxt (ct, (matches, unifiers, unsafe_overlapped))
  | null matches  -- No matches but perhaps several unifiers
  = do { (ctxt, binds_msg, ct) <- relevantBindings True ctxt ct
       ; return (ctxt, cannot_resolve_msg ct binds_msg) }

  | null unsafe_overlapped   -- Some matches => overlap errors
  = return (ctxt, overlap_msg)

  | otherwise
  = return (ctxt, safe_haskell_msg)
  where
    orig          = ctOrigin ct
    pred          = ctPred ct
    (clas, tys)   = getClassPredTys pred
    ispecs        = [ispec | (ispec, _) <- matches]
    unsafe_ispecs = [ispec | (ispec, _) <- unsafe_overlapped]
    givens        = getUserGivens ctxt
    all_tyvars    = all isTyVarTy tys


    cannot_resolve_msg :: Ct -> SDoc -> SDoc
    cannot_resolve_msg ct binds_msg
      = vcat [ no_inst_msg
             , nest 2 extra_note
             , vcat (pp_givens givens)
             , ppWhen (has_ambig_tvs && not (null unifiers && null givens))
               (vcat [ ppUnless lead_with_ambig ambig_msg, binds_msg, potential_msg ])
             , show_fixes (add_to_ctxt_fixes has_ambig_tvs ++ drv_fixes) ]
      where
        orig = ctOrigin ct
        -- See Note [Highlighting ambiguous type variables]
        lead_with_ambig = has_ambig_tvs && not (any isRuntimeUnkSkol ambig_tvs)
                        && not (null unifiers) && null givens

        (has_ambig_tvs, ambig_msg) = mkAmbigMsg lead_with_ambig ct
        ambig_tvs = uncurry (++) (getAmbigTkvs ct)

        no_inst_msg
          | lead_with_ambig
          = ambig_msg <+> pprArising orig
              $$ text "prevents the constraint" <+>  quotes (pprParendType pred)
              <+> text "from being solved."

          | null givens
          = addArising orig $ text "No instance for"
            <+> pprParendType pred

          | otherwise
          = addArising orig $ text "Could not deduce"
            <+> pprParendType pred

        potential_msg
          = ppWhen (not (null unifiers) && want_potential orig) $
            sdocWithDynFlags $ \dflags ->
            getPprStyle $ \sty ->
            pprPotentials dflags sty potential_hdr unifiers

        potential_hdr
          = vcat [ ppWhen lead_with_ambig $
                     text "Probable fix: use a type annotation to specify what"
                     <+> pprQuotedList ambig_tvs <+> text "should be."
                 , text "These potential instance" <> plural unifiers
                   <+> text "exist:"]

    -- Report "potential instances" only when the constraint arises
    -- directly from the user's use of an overloaded function
    want_potential (TypeEqOrigin {}) = False
    want_potential _                 = True

    add_to_ctxt_fixes has_ambig_tvs
      | not has_ambig_tvs && all_tyvars
      , (orig:origs) <- usefulContext ctxt pred
      = [sep [ text "add" <+> pprParendType pred
               <+> text "to the context of"
             , nest 2 $ ppr_skol orig $$
                        vcat [ text "or" <+> ppr_skol orig
                             | orig <- origs ] ] ]
      | otherwise = []

    ppr_skol (PatSkol dc _) = text "the data constructor" <+> quotes (ppr dc)
    ppr_skol skol_info      = ppr skol_info

    extra_note | any isFunTy (filterOutInvisibleTypes (classTyCon clas) tys)
               = text "(maybe you haven't applied a function to enough arguments?)"
               | className clas == typeableClassName  -- Avoid mysterious "No instance for (Typeable T)
               , [_,ty] <- tys                        -- Look for (Typeable (k->*) (T k))
               , Just (tc,_) <- tcSplitTyConApp_maybe ty
               , not (isTypeFamilyTyCon tc)
               = hang (text "GHC can't yet do polykinded")
                    2 (text "Typeable" <+>
                       parens (ppr ty <+> dcolon <+> ppr (typeKind ty)))
               | otherwise
               = empty

    drv_fixes = case orig of
                   DerivOrigin      -> [drv_fix]
                   DerivOriginDC {} -> [drv_fix]
                   DerivOriginCoerce {} -> [drv_fix]
                   _                -> []

    drv_fix = hang (text "use a standalone 'deriving instance' declaration,")
                 2 (text "so you can specify the instance context yourself")

    -- Normal overlap error
    overlap_msg
      = ASSERT( not (null matches) )
        vcat [  addArising orig (text "Overlapping instances for"
                                <+> pprType (mkClassPred clas tys))

             ,  ppUnless (null matching_givens) $
                  sep [text "Matching givens (or their superclasses):"
                      , nest 2 (vcat matching_givens)]

             ,  sdocWithDynFlags $ \dflags ->
                getPprStyle $ \sty ->
                pprPotentials dflags sty (text "Matching instances:") $
                ispecs ++ unifiers

             ,  ppWhen (null matching_givens && isSingleton matches && null unifiers) $
                -- Intuitively, some given matched the wanted in their
                -- flattened or rewritten (from given equalities) form
                -- but the matcher can't figure that out because the
                -- constraints are non-flat and non-rewritten so we
                -- simply report back the whole given
                -- context. Accelerate Smart.hs showed this problem.
                  sep [ text "There exists a (perhaps superclass) match:"
                      , nest 2 (vcat (pp_givens givens))]

             ,  ppWhen (isSingleton matches) $
                parens (vcat [ text "The choice depends on the instantiation of" <+>
                                  quotes (pprWithCommas ppr (tyCoVarsOfTypesList tys))
                             , ppWhen (null (matching_givens)) $
                               vcat [ text "To pick the first instance above, use IncoherentInstances"
                                    , text "when compiling the other instance declarations"]
                        ])]
        where
            givens = getUserGivens ctxt
            matching_givens = mapMaybe matchable givens

            matchable (evvars,skol_info,_,loc)
              = case ev_vars_matching of
                     [] -> Nothing
                     _  -> Just $ hang (pprTheta ev_vars_matching)
                                    2 (sep [ text "bound by" <+> ppr skol_info
                                           , text "at" <+> ppr loc])
                where ev_vars_matching = filter ev_var_matches (map evVarPred evvars)
                      ev_var_matches ty = case getClassPredTys_maybe ty of
                         Just (clas', tys')
                           | clas' == clas
                           , Just _ <- tcMatchTys tys tys'
                           -> True
                           | otherwise
                           -> any ev_var_matches (immSuperClasses clas' tys')
                         Nothing -> False

    -- Overlap error because of Safe Haskell (first
    -- match should be the most specific match)
    safe_haskell_msg
     = ASSERT( length matches == 1 && not (null unsafe_ispecs) )
       vcat [ addArising orig (text "Unsafe overlapping instances for"
                       <+> pprType (mkClassPred clas tys))
            , sep [text "The matching instance is:",
                   nest 2 (pprInstance $ head ispecs)]
            , vcat [ text "It is compiled in a Safe module and as such can only"
                   , text "overlap instances from the same module, however it"
                   , text "overlaps the following instances from different" <+>
                     text "modules:"
                   , nest 2 (vcat [pprInstances $ unsafe_ispecs])
                   ]
            ]

{- Note [Highlighting ambiguous type variables]
-----------------------------------------------
When we encounter ambiguous type variables (i.e. type variables
that remain metavariables after type inference), we need a few more
conditions before we can reason that *ambiguity* prevents constraints
from being solved:
  - We can't have any givens, as encountering a typeclass error
    with given constraints just means we couldn't deduce
    a solution satisfying those constraints and as such couldn't
    bind the type variable to a known type.
  - If we don't have any unifiers, we don't even have potential
    instances from which an ambiguity could arise.
  - Lastly, I don't want to mess with error reporting for
    unknown runtime types so we just fall back to the old message there.
Once these conditions are satisfied, we can safely say that ambiguity prevents
the constraint from being solved. -}


usefulContext :: ReportErrCtxt -> TcPredType -> [SkolemInfo]
usefulContext ctxt pred
  = go (cec_encl ctxt)
  where
    pred_tvs = tyCoVarsOfType pred
    go [] = []
    go (ic : ics)
       | implausible ic = rest
       | otherwise      = ic_info ic : rest
       where
          -- Stop when the context binds a variable free in the predicate
          rest | any (`elemVarSet` pred_tvs) (ic_skols ic) = []
               | otherwise                                 = go ics

    implausible ic
      | null (ic_skols ic)            = True
      | implausible_info (ic_info ic) = True
      | otherwise                     = False

    implausible_info (SigSkol (InfSigCtxt {}) _) = True
    implausible_info _                           = False
    -- Do not suggest adding constraints to an *inferred* type signature!

show_fixes :: [SDoc] -> SDoc
show_fixes []     = empty
show_fixes (f:fs) = sep [ text "Possible fix:"
                        , nest 2 (vcat (f : map (text "or" <+>) fs))]

pprPotentials :: DynFlags -> PprStyle -> SDoc -> [ClsInst] -> SDoc
-- See Note [Displaying potential instances]
pprPotentials dflags sty herald insts
  | null insts
  = empty

  | null show_these
  = hang herald
       2 (vcat [ not_in_scope_msg empty
               , flag_hint ])

  | otherwise
  = hang herald
       2 (vcat [ pprInstances show_these
               , ppWhen (n_in_scope_hidden > 0) $
                 text "...plus"
                   <+> speakNOf n_in_scope_hidden (text "other")
               , not_in_scope_msg (text "...plus")
               , flag_hint ])
  where
    n_show = 3 :: Int
    show_potentials = gopt Opt_PrintPotentialInstances dflags

    (in_scope, not_in_scope) = partition inst_in_scope insts
    sorted = sortBy fuzzyClsInstCmp in_scope
    show_these | show_potentials = sorted
               | otherwise       = take n_show sorted
    n_in_scope_hidden = length sorted - length show_these

       -- "in scope" means that all the type constructors
       -- are lexically in scope; these instances are likely
       -- to be more useful
    inst_in_scope :: ClsInst -> Bool
    inst_in_scope cls_inst = foldNameSet ((&&) . name_in_scope) True $
                             orphNamesOfTypes (is_tys cls_inst)

    name_in_scope name
      | isBuiltInSyntax name
      = True -- E.g. (->)
      | Just mod <- nameModule_maybe name
      = qual_in_scope (qualName sty mod (nameOccName name))
      | otherwise
      = True

    qual_in_scope :: QualifyName -> Bool
    qual_in_scope NameUnqual    = True
    qual_in_scope (NameQual {}) = True
    qual_in_scope _             = False

    not_in_scope_msg herald
      | null not_in_scope
      = empty
      | otherwise
      = hang (herald <+> speakNOf (length not_in_scope) (text "instance")
                     <+> text "involving out-of-scope types")
           2 (ppWhen show_potentials (pprInstances not_in_scope))

    flag_hint = ppUnless (show_potentials || length show_these == length insts) $
                text "(use -fprint-potential-instances to see them all)"

{- Note [Displaying potential instances]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When showing a list of instances for
  - overlapping instances (show ones that match)
  - no such instance (show ones that could match)
we want to give it a bit of structure.  Here's the plan

* Say that an instance is "in scope" if all of the
  type constructors it mentions are lexically in scope.
  These are the ones most likely to be useful to the programmer.

* Show at most n_show in-scope instances,
  and summarise the rest ("plus 3 others")

* Summarise the not-in-scope instances ("plus 4 not in scope")

* Add the flag -fshow-potential-instances which replaces the
  summary with the full list
-}

{-
Note [Flattening in error message generation]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider (C (Maybe (F x))), where F is a type function, and we have
instances
                C (Maybe Int) and C (Maybe a)
Since (F x) might turn into Int, this is an overlap situation, and
indeed (because of flattening) the main solver will have refrained
from solving.  But by the time we get to error message generation, we've
un-flattened the constraint.  So we must *re*-flatten it before looking
up in the instance environment, lest we only report one matching
instance when in fact there are two.

Re-flattening is pretty easy, because we don't need to keep track of
evidence.  We don't re-use the code in TcCanonical because that's in
the TcS monad, and we are in TcM here.

Note [Suggest -fprint-explicit-kinds]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It can be terribly confusing to get an error message like (Trac #9171)
    Couldn't match expected type ‘GetParam Base (GetParam Base Int)’
                with actual type ‘GetParam Base (GetParam Base Int)’
The reason may be that the kinds don't match up.  Typically you'll get
more useful information, but not when it's as a result of ambiguity.
This test suggests -fprint-explicit-kinds when all the ambiguous type
variables are kind variables.
-}

mkAmbigMsg :: Bool -- True when message has to be at beginning of sentence
           -> Ct -> (Bool, SDoc)
mkAmbigMsg prepend_msg ct
  | null ambig_kvs && null ambig_tvs = (False, empty)
  | otherwise                        = (True,  msg)
  where
    (ambig_kvs, ambig_tvs) = getAmbigTkvs ct

    msg |  any isRuntimeUnkSkol ambig_kvs  -- See Note [Runtime skolems]
        || any isRuntimeUnkSkol ambig_tvs
        = vcat [ text "Cannot resolve unknown runtime type"
                 <> plural ambig_tvs <+> pprQuotedList ambig_tvs
               , text "Use :print or :force to determine these types"]

        | not (null ambig_tvs)
        = pp_ambig (text "type") ambig_tvs

        | otherwise  -- All ambiguous kind variabes; suggest -fprint-explicit-kinds
        = vcat [ pp_ambig (text "kind") ambig_kvs
               , sdocWithDynFlags suggest_explicit_kinds ]

    pp_ambig what tkvs
      | prepend_msg -- "Ambiguous type variable 't0'"
      = text "Ambiguous" <+> what <+> text "variable"
        <> plural tkvs <+> pprQuotedList tkvs

      | otherwise -- "The type variable 't0' is ambiguous"
      = text "The" <+> what <+> text "variable" <> plural tkvs
        <+> pprQuotedList tkvs <+> is_or_are tkvs <+> text "ambiguous"

    is_or_are [_] = text "is"
    is_or_are _   = text "are"

    suggest_explicit_kinds dflags  -- See Note [Suggest -fprint-explicit-kinds]
      | gopt Opt_PrintExplicitKinds dflags = empty
      | otherwise = text "Use -fprint-explicit-kinds to see the kind arguments"

pprSkol :: [Implication] -> TcTyVar -> SDoc
pprSkol implics tv
  | (skol_tvs, skol_info) <- getSkolemInfo implics tv
  = case skol_info of
      UnkSkol         -> pp_tv <+> text "is an unknown type variable"
      SigSkol ctxt ty -> ppr_rigid (pprSigSkolInfo ctxt
                                      (mkCheckExpType $
                                       mkSpecForAllTys skol_tvs
                                         (checkingExpType "pprSkol" ty)))
      _               -> ppr_rigid (pprSkolInfo skol_info)
  where
    pp_tv = quotes (ppr tv)
    ppr_rigid pp_info = hang (pp_tv <+> text "is a rigid type variable bound by")
                           2 (sep [ pp_info
                                  , text "at" <+> ppr (getSrcLoc tv) ])

getAmbigTkvs :: Ct -> ([Var],[Var])
getAmbigTkvs ct
  = partition (`elemVarSet` dep_tkv_set) ambig_tkvs
  where
    tkv_set       = tyCoVarsOfCt ct
    ambig_tkv_set = filterVarSet isAmbiguousTyVar tkv_set
    dep_tkv_set   = tyCoVarsOfTypes (map tyVarKind (varSetElems tkv_set))
    ambig_tkvs    = varSetElems ambig_tkv_set

getSkolemInfo :: [Implication] -> TcTyVar -> ([TcTyVar], SkolemInfo)
-- Get the skolem info for a type variable
-- from the implication constraint that binds it
getSkolemInfo [] tv
  = pprPanic "No skolem info:" (ppr tv)

getSkolemInfo (implic:implics) tv
  | let skols = ic_skols implic
  , tv `elem` ic_skols implic = (skols, ic_info implic)
  | otherwise                 = getSkolemInfo implics tv

-----------------------
-- relevantBindings looks at the value environment and finds values whose
-- types mention any of the offending type variables.  It has to be
-- careful to zonk the Id's type first, so it has to be in the monad.
-- We must be careful to pass it a zonked type variable, too.
--
-- We always remove closed top-level bindings, though,
-- since they are never relevant (cf Trac #8233)

relevantBindings :: Bool  -- True <=> filter by tyvar; False <=> no filtering
                          -- See Trac #8191
                 -> ReportErrCtxt -> Ct
                 -> TcM (ReportErrCtxt, SDoc, Ct)
-- Also returns the zonked and tidied CtOrigin of the constraint
relevantBindings want_filtering ctxt ct
  = do { dflags <- getDynFlags
       ; (env1, tidy_orig) <- zonkTidyOrigin (cec_tidy ctxt) (ctLocOrigin loc)
       ; let ct_tvs = tyCoVarsOfCt ct `unionVarSet` extra_tvs

             -- For *kind* errors, report the relevant bindings of the
             -- enclosing *type* equality, because that's more useful for the programmer
             extra_tvs = case tidy_orig of
                             KindEqOrigin t1 m_t2 _ _ -> tyCoVarsOfTypes $
                                                         t1 : maybeToList m_t2
                             _                        -> emptyVarSet
       ; traceTc "relevantBindings" $
           vcat [ ppr ct
                , pprCtOrigin (ctLocOrigin loc)
                , ppr ct_tvs
                , pprWithCommas id [ ppr id <+> dcolon <+> ppr (idType id)
                                   | TcIdBndr id _ <- tcl_bndrs lcl_env ]
                , pprWithCommas id
                    [ ppr id | TcIdBndr_ExpType id _ _ <- tcl_bndrs lcl_env ] ]

       ; (tidy_env', docs, discards)
              <- go env1 ct_tvs (maxRelevantBinds dflags)
                    emptyVarSet [] False
                    (tcl_bndrs lcl_env)
         -- tcl_bndrs has the innermost bindings first,
         -- which are probably the most relevant ones

       ; let doc = ppUnless (null docs) $
                   hang (text "Relevant bindings include")
                      2 (vcat docs $$ ppWhen discards discardMsg)

             -- Put a zonked, tidied CtOrigin into the Ct
             loc'  = setCtLocOrigin loc tidy_orig
             ct'   = setCtLoc ct loc'
             ctxt' = ctxt { cec_tidy = tidy_env' }

       ; return (ctxt', doc, ct') }
  where
    ev      = ctEvidence ct
    loc     = ctEvLoc ev
    lcl_env = ctLocEnv loc

    run_out :: Maybe Int -> Bool
    run_out Nothing = False
    run_out (Just n) = n <= 0

    dec_max :: Maybe Int -> Maybe Int
    dec_max = fmap (\n -> n - 1)

    go :: TidyEnv -> TcTyVarSet -> Maybe Int -> TcTyVarSet -> [SDoc]
       -> Bool                          -- True <=> some filtered out due to lack of fuel
       -> [TcIdBinder]
       -> TcM (TidyEnv, [SDoc], Bool)   -- The bool says if we filtered any out
                                        -- because of lack of fuel
    go tidy_env _ _ _ docs discards []
      = return (tidy_env, reverse docs, discards)
    go tidy_env ct_tvs n_left tvs_seen docs discards (tc_bndr : tc_bndrs)
      = case tc_bndr of
          TcIdBndr id top_lvl -> go2 (idName id) (idType id) top_lvl
          TcIdBndr_ExpType name et top_lvl ->
            do { mb_ty <- readExpType_maybe et
                   -- et really should be filled in by now. But there's a chance
                   -- it hasn't, if, say, we're reporting a kind error en route to
                   -- checking a term. See test indexed-types/should_fail/T8129
               ; ty <- case mb_ty of
                   Just ty -> return ty
                   Nothing -> do { traceTc "Defaulting an ExpType in relevantBindings"
                                     (ppr et)
                                 ; expTypeToType et }
               ; go2 name ty top_lvl }
      where
        go2 id_name id_type top_lvl
          = do { (tidy_env', tidy_ty) <- zonkTidyTcType tidy_env id_type
               ; traceTc "relevantBindings 1" (ppr id_name <+> dcolon <+> ppr tidy_ty)
               ; let id_tvs = tyCoVarsOfType tidy_ty
                     doc = sep [ pprPrefixOcc id_name <+> dcolon <+> ppr tidy_ty
                               , nest 2 (parens (text "bound at"
                                    <+> ppr (getSrcLoc id_name)))]
                     new_seen = tvs_seen `unionVarSet` id_tvs

               ; if (want_filtering && not opt_PprStyle_Debug
                                    && id_tvs `disjointVarSet` ct_tvs)
                          -- We want to filter out this binding anyway
                          -- so discard it silently
                 then go tidy_env ct_tvs n_left tvs_seen docs discards tc_bndrs

                 else if isTopLevel top_lvl && not (isNothing n_left)
                          -- It's a top-level binding and we have not specified
                          -- -fno-max-relevant-bindings, so discard it silently
                 then go tidy_env ct_tvs n_left tvs_seen docs discards tc_bndrs

                 else if run_out n_left && id_tvs `subVarSet` tvs_seen
                          -- We've run out of n_left fuel and this binding only
                          -- mentions aleady-seen type variables, so discard it
                 then go tidy_env ct_tvs n_left tvs_seen docs True tc_bndrs

                          -- Keep this binding, decrement fuel
                 else go tidy_env' ct_tvs (dec_max n_left) new_seen (doc:docs) discards tc_bndrs }

discardMsg :: SDoc
discardMsg = text "(Some bindings suppressed;" <+>
             text "use -fmax-relevant-binds=N or -fno-max-relevant-binds)"

-----------------------
warnDefaulting :: [Ct] -> Type -> TcM ()
warnDefaulting wanteds default_ty
  = do { warn_default <- woptM Opt_WarnTypeDefaults
       ; env0 <- tcInitTidyEnv
       ; let tidy_env = tidyFreeTyCoVars env0 $
                        foldr (unionVarSet . tyCoVarsOfCt) emptyVarSet wanteds
             tidy_wanteds = map (tidyCt tidy_env) wanteds
             (loc, ppr_wanteds) = pprWithArising tidy_wanteds
             warn_msg =
                hang (hsep [ text "Defaulting the following"
                           , text "constraint" <> plural tidy_wanteds
                           , text "to type"
                           , quotes (ppr default_ty) ])
                     2
                     ppr_wanteds
       ; setCtLocM loc $ warnTc warn_default warn_msg }

{-
Note [Runtime skolems]
~~~~~~~~~~~~~~~~~~~~~~
We want to give a reasonably helpful error message for ambiguity
arising from *runtime* skolems in the debugger.  These
are created by in RtClosureInspect.zonkRTTIType.

************************************************************************
*                                                                      *
                 Error from the canonicaliser
         These ones are called *during* constraint simplification
*                                                                      *
************************************************************************
-}

solverDepthErrorTcS :: CtLoc -> TcType -> TcM a
solverDepthErrorTcS loc ty
  = setCtLocM loc $
    do { ty <- zonkTcType ty
       ; env0 <- tcInitTidyEnv
       ; let tidy_env     = tidyFreeTyCoVars env0 (tyCoVarsOfType ty)
             tidy_ty      = tidyType tidy_env ty
             msg
               = vcat [ text "Reduction stack overflow; size =" <+> ppr depth
                      , hang (text "When simplifying the following type:")
                           2 (ppr tidy_ty)
                      , note ]
       ; failWithTcM (tidy_env, msg) }
  where
    depth = ctLocDepth loc
    note = vcat
      [ text "Use -freduction-depth=0 to disable this check"
      , text "(any upper bound you could choose might fail unpredictably with"
      , text " minor updates to GHC, so disabling the check is recommended if"
      , text " you're sure that type checking should terminate)" ]
