{-
(c) The University of Glasgow 2006
(c) The GRASP/AQUA Project, Glasgow University, 1992-1998


Typechecking class declarations
-}

{-# LANGUAGE CPP #-}

module TcClassDcl ( tcClassSigs, tcClassDecl2,
                    findMethodBind, instantiateMethod,
                    tcClassMinimalDef,
                    HsSigFun, mkHsSigFun, lookupHsSig, emptyHsSigs,
                    tcMkDeclCtxt, tcAddDeclCtxt, badMethodErr,
                    tcATDefault
                  ) where

#include "HsVersions.h"

import HsSyn
import TcEnv
import TcPat( addInlinePrags, lookupPragEnv, emptyPragEnv )
import TcEvidence( idHsWrapper )
import TcBinds
import TcUnify
import TcHsType
import TcMType
import Type     ( getClassPredTys_maybe, varSetElemsWellScoped )
import TcType
import TcRnMonad
import BuildTyCl( TcMethInfo )
import Class
import Coercion ( pprCoAxiom )
import DynFlags
import FamInst
import FamInstEnv
import Id
import Name
import NameEnv
import NameSet
import Var
import VarEnv
import VarSet
import Outputable
import SrcLoc
import TyCon
import Maybes
import BasicTypes
import Bag
import FastString
import BooleanFormula
import Util

import Control.Monad
import Data.List ( mapAccumL )

{-
Dictionary handling
~~~~~~~~~~~~~~~~~~~
Every class implicitly declares a new data type, corresponding to dictionaries
of that class. So, for example:

        class (D a) => C a where
          op1 :: a -> a
          op2 :: forall b. Ord b => a -> b -> b

would implicitly declare

        data CDict a = CDict (D a)
                             (a -> a)
                             (forall b. Ord b => a -> b -> b)

(We could use a record decl, but that means changing more of the existing apparatus.
One step at at time!)

For classes with just one superclass+method, we use a newtype decl instead:

        class C a where
          op :: forallb. a -> b -> b

generates

        newtype CDict a = CDict (forall b. a -> b -> b)

Now DictTy in Type is just a form of type synomym:
        DictTy c t = TyConTy CDict `AppTy` t

Death to "ExpandingDicts".


************************************************************************
*                                                                      *
                Type-checking the class op signatures
*                                                                      *
************************************************************************
-}

tcClassSigs :: Name                -- Name of the class
            -> [LSig Name]
            -> LHsBinds Name
            -> TcM [TcMethInfo]    -- Exactly one for each method
tcClassSigs clas sigs def_methods
  = do { traceTc "tcClassSigs 1" (ppr clas)

       ; gen_dm_prs <- concat <$> mapM (addLocM tc_gen_sig) gen_sigs
       ; let gen_dm_env :: NameEnv Type
             gen_dm_env = mkNameEnv gen_dm_prs

       ; op_info <- concat <$> mapM (addLocM (tc_sig gen_dm_env)) vanilla_sigs

       ; let op_names = mkNameSet [ n | (n,_,_) <- op_info ]
       ; sequence_ [ failWithTc (badMethodErr clas n)
                   | n <- dm_bind_names, not (n `elemNameSet` op_names) ]
                   -- Value binding for non class-method (ie no TypeSig)

       ; sequence_ [ failWithTc (badGenericMethod clas n)
                   | (n,_) <- gen_dm_prs, not (n `elem` dm_bind_names) ]
                   -- Generic signature without value binding

       ; traceTc "tcClassSigs 2" (ppr clas)
       ; return op_info }
  where
    vanilla_sigs = [L loc (nm,ty) | L loc (ClassOpSig False nm ty) <- sigs]
    gen_sigs     = [L loc (nm,ty) | L loc (ClassOpSig True  nm ty) <- sigs]
    dm_bind_names :: [Name]     -- These ones have a value binding in the class decl
    dm_bind_names = [op | L _ (FunBind {fun_id = L _ op}) <- bagToList def_methods]

    tc_sig :: NameEnv Type -> ([Located Name], LHsSigType Name)
           -> TcM [TcMethInfo]
    tc_sig gen_dm_env (op_names, op_hs_ty)
      = do { traceTc "ClsSig 1" (ppr op_names)
           ; op_ty <- tcClassSigType op_names op_hs_ty   -- Class tyvars already in scope
           ; traceTc "ClsSig 2" (ppr op_names)
           ; return [ (op_name, op_ty, f op_name) | L _ op_name <- op_names ] }
           where
             f nm | Just ty <- lookupNameEnv gen_dm_env nm = Just (GenericDM ty)
                  | nm `elem` dm_bind_names                = Just VanillaDM
                  | otherwise                              = Nothing

    tc_gen_sig (op_names, gen_hs_ty)
      = do { gen_op_ty <- tcClassSigType op_names gen_hs_ty
           ; return [ (op_name, gen_op_ty) | L _ op_name <- op_names ] }

{-
************************************************************************
*                                                                      *
                Class Declarations
*                                                                      *
************************************************************************
-}

tcClassDecl2 :: LTyClDecl Name          -- The class declaration
             -> TcM (LHsBinds Id)

tcClassDecl2 (L loc (ClassDecl {tcdLName = class_name, tcdSigs = sigs,
                                tcdMeths = default_binds}))
  = recoverM (return emptyLHsBinds)     $
    setSrcSpan loc                      $
    do  { clas <- tcLookupLocatedClass class_name

        -- We make a separate binding for each default method.
        -- At one time I used a single AbsBinds for all of them, thus
        -- AbsBind [d] [dm1, dm2, dm3] { dm1 = ...; dm2 = ...; dm3 = ... }
        -- But that desugars into
        --      ds = \d -> (..., ..., ...)
        --      dm1 = \d -> case ds d of (a,b,c) -> a
        -- And since ds is big, it doesn't get inlined, so we don't get good
        -- default methods.  Better to make separate AbsBinds for each
        ; let (tyvars, _, _, op_items) = classBigSig clas
              prag_fn     = mkPragEnv sigs default_binds
              sig_fn      = mkHsSigFun sigs
              clas_tyvars = snd (tcSuperSkolTyVars tyvars)
              pred        = mkClassPred clas (mkTyVarTys clas_tyvars)
        ; this_dict <- newEvVar pred

        ; let tc_item = tcDefMeth clas clas_tyvars this_dict
                                  default_binds sig_fn prag_fn
        ; dm_binds <- tcExtendTyVarEnv clas_tyvars $
                      mapM tc_item op_items

        ; return (unionManyBags dm_binds) }

tcClassDecl2 d = pprPanic "tcClassDecl2" (ppr d)

tcDefMeth :: Class -> [TyVar] -> EvVar -> LHsBinds Name
          -> HsSigFun -> TcPragEnv -> ClassOpItem
          -> TcM (LHsBinds TcId)
-- Generate code for default methods
-- This is incompatible with Hugs, which expects a polymorphic
-- default method for every class op, regardless of whether or not
-- the programmer supplied an explicit default decl for the class.
-- (If necessary we can fix that, but we don't have a convenient Id to hand.)

tcDefMeth _ _ _ _ _ prag_fn (sel_id, Nothing)
  = do { -- No default method
         mapM_ (addLocM (badDmPrag sel_id))
               (lookupPragEnv prag_fn (idName sel_id))
       ; return emptyBag }

tcDefMeth clas tyvars this_dict binds_in hs_sig_fn prag_fn
          (sel_id, Just (dm_name, dm_spec))
  | Just (L bind_loc dm_bind, bndr_loc) <- findMethodBind sel_name binds_in
  = do { -- First look up the default method -- It should be there!
         global_dm_id  <- tcLookupId dm_name
       ; global_dm_id  <- addInlinePrags global_dm_id prags
       ; local_dm_name <- setSrcSpan bndr_loc (newLocalName sel_name)
            -- Base the local_dm_name on the selector name, because
            -- type errors from tcInstanceMethodBody come from here

       ; spec_prags <- discardConstraints $
                       tcSpecPrags global_dm_id prags
       ; warnTc (not (null spec_prags))
                (text "Ignoring SPECIALISE pragmas on default method"
                 <+> quotes (ppr sel_name))

       ; let hs_ty = lookupHsSig hs_sig_fn sel_name
                     `orElse` pprPanic "tc_dm" (ppr sel_name)
             -- We need the HsType so that we can bring the right
             -- type variables into scope
             --
             -- Eg.   class C a where
             --          op :: forall b. Eq b => a -> [b] -> a
             --          gen_op :: a -> a
             --          generic gen_op :: D a => a -> a
             -- The "local_dm_ty" is precisely the type in the above
             -- type signatures, ie with no "forall a. C a =>" prefix

             local_dm_ty = instantiateMethod clas global_dm_id (mkTyVarTys tyvars)

             lm_bind     = dm_bind { fun_id = L bind_loc local_dm_name }
                             -- Substitute the local_meth_name for the binder
                             -- NB: the binding is always a FunBind

             warn_redundant = case dm_spec of
                                GenericDM {} -> True
                                VanillaDM    -> False
                -- For GenericDM, warn if the user specifies a signature
                -- with redundant constraints; but not for VanillaDM, where
                -- the default method may well be 'error' or something

             ctxt = FunSigCtxt sel_name warn_redundant

       ; local_dm_sig <- instTcTySig ctxt hs_ty local_dm_ty local_dm_name
        ; (ev_binds, (tc_bind, _))
               <- checkConstraints (ClsSkol clas) tyvars [this_dict] $
                  tcPolyCheck NonRecursive no_prag_fn local_dm_sig
                              (L bind_loc lm_bind)

        ; let export = ABE { abe_poly      = global_dm_id
                           -- We have created a complete type signature in
                           -- instTcTySig, hence it is safe to call
                           -- completeSigPolyId
                           , abe_mono      = completeIdSigPolyId local_dm_sig
                           , abe_wrap      = idHsWrapper
                           , abe_prags     = IsDefaultMethod }
              full_bind = AbsBinds { abs_tvs      = tyvars
                                   , abs_ev_vars  = [this_dict]
                                   , abs_exports  = [export]
                                   , abs_ev_binds = [ev_binds]
                                   , abs_binds    = tc_bind }

        ; return (unitBag (L bind_loc full_bind)) }

  | otherwise = pprPanic "tcDefMeth" (ppr sel_id)
  where
    sel_name = idName sel_id
    prags    = lookupPragEnv prag_fn sel_name
    no_prag_fn = emptyPragEnv   -- No pragmas for local_meth_id;
                                -- they are all for meth_id

---------------
tcClassMinimalDef :: Name -> [LSig Name] -> [TcMethInfo] -> TcM ClassMinimalDef
tcClassMinimalDef _clas sigs op_info
  = case findMinimalDef sigs of
      Nothing -> return defMindef
      Just mindef -> do
        -- Warn if the given mindef does not imply the default one
        -- That is, the given mindef should at least ensure that the
        -- class ops without default methods are required, since we
        -- have no way to fill them in otherwise
        whenIsJust (isUnsatisfied (mindef `impliesAtom`) defMindef) $
                   (\bf -> addWarnTc (warningMinimalDefIncomplete bf))
        return mindef
  where
    -- By default require all methods without a default
    -- implementation whose names don't start with '_'
    defMindef :: ClassMinimalDef
    defMindef = mkAnd [ noLoc (mkVar name)
                      | (name, _, Nothing) <- op_info
                      , not (startsWithUnderscore (getOccName name)) ]

instantiateMethod :: Class -> Id -> [TcType] -> TcType
-- Take a class operation, say
--      op :: forall ab. C a => forall c. Ix c => (b,c) -> a
-- Instantiate it at [ty1,ty2]
-- Return the "local method type":
--      forall c. Ix x => (ty2,c) -> ty1
instantiateMethod clas sel_id inst_tys
  = ASSERT( ok_first_pred ) local_meth_ty
  where
    rho_ty = applyTys (idType sel_id) inst_tys
    (first_pred, local_meth_ty) = tcSplitPredFunTy_maybe rho_ty
                `orElse` pprPanic "tcInstanceMethod" (ppr sel_id)

    ok_first_pred = case getClassPredTys_maybe first_pred of
                      Just (clas1, _tys) -> clas == clas1
                      Nothing -> False
              -- The first predicate should be of form (C a b)
              -- where C is the class in question


---------------------------
type HsSigFun = NameEnv (LHsSigType Name)

emptyHsSigs :: HsSigFun
emptyHsSigs = emptyNameEnv

mkHsSigFun :: [LSig Name] -> HsSigFun
mkHsSigFun sigs = mkNameEnv [(n, hs_ty)
                            | L _ (ClassOpSig False ns hs_ty) <- sigs
                            , L _ n <- ns ]

lookupHsSig :: HsSigFun -> Name -> Maybe (LHsSigType Name)
lookupHsSig = lookupNameEnv

---------------------------
findMethodBind  :: Name                 -- Selector name
                -> LHsBinds Name        -- A group of bindings
                -> Maybe (LHsBind Name, SrcSpan)
                -- Returns the binding, and the binding
                -- site of the method binder
findMethodBind sel_name binds
  = foldlBag mplus Nothing (mapBag f binds)
  where
    f bind@(L _ (FunBind { fun_id = L bndr_loc op_name }))
      | op_name == sel_name
             = Just (bind, bndr_loc)
    f _other = Nothing

---------------------------
findMinimalDef :: [LSig Name] -> Maybe ClassMinimalDef
findMinimalDef = firstJusts . map toMinimalDef
  where
    toMinimalDef :: LSig Name -> Maybe ClassMinimalDef
    toMinimalDef (L _ (MinimalSig _ (L _ bf))) = Just (fmap unLoc bf)
    toMinimalDef _                             = Nothing

{-
Note [Polymorphic methods]
~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider
    class Foo a where
        op :: forall b. Ord b => a -> b -> b -> b
    instance Foo c => Foo [c] where
        op = e

When typechecking the binding 'op = e', we'll have a meth_id for op
whose type is
      op :: forall c. Foo c => forall b. Ord b => [c] -> b -> b -> b

So tcPolyBinds must be capable of dealing with nested polytypes;
and so it is. See TcBinds.tcMonoBinds (with type-sig case).

Note [Silly default-method bind]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
When we pass the default method binding to the type checker, it must
look like    op2 = e
not          $dmop2 = e
otherwise the "$dm" stuff comes out error messages.  But we want the
"$dm" to come out in the interface file.  So we typecheck the former,
and wrap it in a let, thus
          $dmop2 = let op2 = e in op2
This makes the error messages right.


************************************************************************
*                                                                      *
                Error messages
*                                                                      *
************************************************************************
-}

tcMkDeclCtxt :: TyClDecl Name -> SDoc
tcMkDeclCtxt decl = hsep [text "In the", pprTyClDeclFlavour decl,
                      text "declaration for", quotes (ppr (tcdName decl))]

tcAddDeclCtxt :: TyClDecl Name -> TcM a -> TcM a
tcAddDeclCtxt decl thing_inside
  = addErrCtxt (tcMkDeclCtxt decl) thing_inside

badMethodErr :: Outputable a => a -> Name -> SDoc
badMethodErr clas op
  = hsep [text "Class", quotes (ppr clas),
          text "does not have a method", quotes (ppr op)]

badGenericMethod :: Outputable a => a -> Name -> SDoc
badGenericMethod clas op
  = hsep [text "Class", quotes (ppr clas),
          text "has a generic-default signature without a binding", quotes (ppr op)]

{-
badGenericInstanceType :: LHsBinds Name -> SDoc
badGenericInstanceType binds
  = vcat [text "Illegal type pattern in the generic bindings",
          nest 2 (ppr binds)]

missingGenericInstances :: [Name] -> SDoc
missingGenericInstances missing
  = text "Missing type patterns for" <+> pprQuotedList missing

dupGenericInsts :: [(TyCon, InstInfo a)] -> SDoc
dupGenericInsts tc_inst_infos
  = vcat [text "More than one type pattern for a single generic type constructor:",
          nest 2 (vcat (map ppr_inst_ty tc_inst_infos)),
          text "All the type patterns for a generic type constructor must be identical"
    ]
  where
    ppr_inst_ty (_,inst) = ppr (simpleInstInfoTy inst)
-}
badDmPrag :: Id -> Sig Name -> TcM ()
badDmPrag sel_id prag
  = addErrTc (text "The" <+> hsSigDoc prag <+> ptext (sLit "for default method")
              <+> quotes (ppr sel_id)
              <+> text "lacks an accompanying binding")

warningMinimalDefIncomplete :: ClassMinimalDef -> SDoc
warningMinimalDefIncomplete mindef
  = vcat [ text "The MINIMAL pragma does not require:"
         , nest 2 (pprBooleanFormulaNice mindef)
         , text "but there is no default implementation." ]

tcATDefault :: Bool -- If a warning should be emitted when a default instance
                    -- definition is not provided by the user
            -> SrcSpan
            -> TCvSubst
            -> NameSet
            -> ClassATItem
            -> TcM [FamInst]
-- ^ Construct default instances for any associated types that
-- aren't given a user definition
-- Returns [] or singleton
tcATDefault emit_warn loc inst_subst defined_ats (ATI fam_tc defs)
  -- User supplied instances ==> everything is OK
  | tyConName fam_tc `elemNameSet` defined_ats
  = return []

  -- No user instance, have defaults ==> instatiate them
   -- Example:   class C a where { type F a b :: *; type F a b = () }
   --            instance C [x]
   -- Then we want to generate the decl:   type F [x] b = ()
  | Just (rhs_ty, _loc) <- defs
  = do { let (subst', pat_tys') = mapAccumL subst_tv inst_subst
                                            (tyConTyVars fam_tc)
             rhs'     = substTyUnchecked subst' rhs_ty
             tcv_set' = tyCoVarsOfTypes pat_tys'
             (tv_set', cv_set') = partitionVarSet isTyVar tcv_set'
             tvs'     = varSetElemsWellScoped tv_set'
             cvs'     = varSetElemsWellScoped cv_set'
       ; rep_tc_name <- newFamInstTyConName (L loc (tyConName fam_tc)) pat_tys'
       ; let axiom = mkSingleCoAxiom Nominal rep_tc_name tvs' cvs'
                                     fam_tc pat_tys' rhs'
           -- NB: no validity check. We check validity of default instances
           -- in the class definition. Because type instance arguments cannot
           -- be type family applications and cannot be polytypes, the
           -- validity check is redundant.

       ; traceTc "mk_deflt_at_instance" (vcat [ ppr fam_tc, ppr rhs_ty
                                              , pprCoAxiom axiom ])
       ; fam_inst <- ASSERT( tyCoVarsOfType rhs' `subVarSet` tv_set' )
                     newFamInst SynFamilyInst axiom
       ; return [fam_inst] }

   -- No defaults ==> generate a warning
  | otherwise  -- defs = Nothing
  = do { when emit_warn $ warnMissingAT (tyConName fam_tc)
       ; return [] }
  where
    subst_tv subst tc_tv
      | Just ty <- lookupVarEnv (getTvSubstEnv subst) tc_tv
      = (subst, ty)
      | otherwise
      = (extendTCvSubst subst tc_tv ty', ty')
      where
        ty' = mkTyVarTy (updateTyVarKind (substTyUnchecked subst) tc_tv)

warnMissingAT :: Name -> TcM ()
warnMissingAT name
  = do { warn <- woptM Opt_WarnMissingMethods
       ; traceTc "warn" (ppr name <+> ppr warn)
       ; warnTc warn  -- Warn only if -Wmissing-methods
                (text "No explicit" <+> text "associated type"
                    <+> text "or default declaration for     "
                    <+> quotes (ppr name)) }
