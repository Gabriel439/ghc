-- (c) The University of Glasgow 2006

{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE CPP #-}
{-# LANGUAGE DeriveFunctor #-}

module Unify (
        tcMatchTy, tcMatchTys, tcMatchTyX, tcMatchTysX, tcUnifyTyWithTFs,
        ruleMatchTyX,

        -- * Rough matching
        roughMatchTcs, instanceCantMatch,
        typesCantMatch,

        -- Side-effect free unification
        tcUnifyTy, tcUnifyTys,
        tcUnifyTysFG,
        BindFlag(..),
        UnifyResult, UnifyResultM(..),

        -- Matching a type against a lifted type (coercion)
        liftCoMatch
   ) where

#include "HsVersions.h"

import Var
import VarEnv
import VarSet
import Kind
import Name( Name )
import Type hiding ( getTvSubstEnv )
import Coercion hiding ( getCvSubstEnv )
import TyCon
import TyCoRep hiding ( getTvSubstEnv, getCvSubstEnv )
import Util
import Pair
import Outputable

import Control.Monad
#if __GLASGOW_HASKELL__ > 710
import qualified Control.Monad.Fail as MonadFail
#endif
import Control.Applicative hiding ( empty )
import qualified Control.Applicative

{-

Unification is much tricker than you might think.

1. The substitution we generate binds the *template type variables*
   which are given to us explicitly.

2. We want to match in the presence of foralls;
        e.g     (forall a. t1) ~ (forall b. t2)

   That is what the RnEnv2 is for; it does the alpha-renaming
   that makes it as if a and b were the same variable.
   Initialising the RnEnv2, so that it can generate a fresh
   binder when necessary, entails knowing the free variables of
   both types.

3. We must be careful not to bind a template type variable to a
   locally bound variable.  E.g.
        (forall a. x) ~ (forall b. b)
   where x is the template type variable.  Then we do not want to
   bind x to a/b!  This is a kind of occurs check.
   The necessary locals accumulate in the RnEnv2.

Note [Kind coercions in Unify]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
We wish to match/unify while ignoring casts. But, we can't just ignore
them completely, or we'll end up with ill-kinded substitutions. For example,
say we're matching `a` with `ty |> co`. If we just drop the cast, we'll
return [a |-> ty], but `a` and `ty` might have different kinds. We can't
just match/unify their kinds, either, because this might gratuitously
fail. After all, `co` is the witness that the kinds are the same -- they
may look nothing alike.

So, we pass a kind coercion to the match/unify worker. This coercion witnesses
the equality between the substed kind of the left-hand type and the substed
kind of the right-hand type. To get this coercion, we first have to match/unify
the kinds before looking at the types. Happily, we need look only one level
up, as all kinds are guaranteed to have kind *.

We thought, at one point, that this was all unnecessary: why should casts
be in types in the first place? But they do. In
dependent/should_compile/KindEqualities2, we see, for example
the constraint Num (Int |> (blah ; sym blah)).
We naturally want to find a dictionary for that constraint, which
requires dealing with coercions in this manner.

-}

-- | @tcMatchTy t1 t2@ produces a substitution (over fvs(t1))
-- @s@ such that @s(t1)@ equals @t2@.
-- The returned substitution might bind coercion variables,
-- if the variable is an argument to a GADT constructor.
--
-- We don't pass in a set of "template variables" to be bound
-- by the match, because tcMatchTy (and similar functions) are
-- always used on top-level types, so we can bind any of the
-- free variables of the LHS.
tcMatchTy :: Type -> Type -> Maybe TCvSubst
tcMatchTy ty1 ty2 = tcMatchTys [ty1] [ty2]

-- | This is similar to 'tcMatchTy', but extends a substitution
tcMatchTyX :: TCvSubst            -- ^ Substitution to extend
           -> Type                -- ^ Template
           -> Type                -- ^ Target
           -> Maybe TCvSubst
tcMatchTyX subst ty1 ty2 = tcMatchTysX subst [ty1] [ty2]

-- | Like 'tcMatchTy' but over a list of types.
tcMatchTys :: [Type]         -- ^ Template
           -> [Type]         -- ^ Target
           -> Maybe TCvSubst -- ^ One-shot; in principle the template
                             -- variables could be free in the target
tcMatchTys tys1 tys2
  = tcMatchTysX (mkEmptyTCvSubst in_scope) tys1 tys2
  where
    in_scope = mkInScopeSet (tyCoVarsOfTypes tys1 `unionVarSet` tyCoVarsOfTypes tys2)

-- | Like 'tcMatchTys', but extending a substitution
tcMatchTysX :: TCvSubst       -- ^ Substitution to extend
            -> [Type]         -- ^ Template
            -> [Type]         -- ^ Target
            -> Maybe TCvSubst -- ^ One-shot substitution
tcMatchTysX (TCvSubst in_scope tv_env cv_env) tys1 tys2
-- See Note [Kind coercions in Unify]
  = case tc_unify_tys (const BindMe)
                      False  -- Matching, not unifying
                      False  -- Not an injectivity check
                      (mkRnEnv2 in_scope) tv_env cv_env tys1 tys2 of
      Unifiable (tv_env', cv_env')
        -> Just $ TCvSubst in_scope tv_env' cv_env'
      _ -> Nothing

-- | This one is called from the expression matcher,
-- which already has a MatchEnv in hand
ruleMatchTyX
  :: TyCoVarSet          -- ^ template variables
  -> RnEnv2
  -> TvSubstEnv          -- ^ type substitution to extend
  -> Type                -- ^ Template
  -> Type                -- ^ Target
  -> Maybe TvSubstEnv
ruleMatchTyX tmpl_tvs rn_env tenv tmpl target
-- See Note [Kind coercions in Unify]
  = case tc_unify_tys (matchBindFun tmpl_tvs) False False rn_env
                      tenv emptyCvSubstEnv [tmpl] [target] of
      Unifiable (tenv', _) -> Just tenv'
      _                    -> Nothing

matchBindFun :: TyCoVarSet -> TyVar -> BindFlag
matchBindFun tvs tv = if tv `elemVarSet` tvs then BindMe else Skolem


{- *********************************************************************
*                                                                      *
                Rough matching
*                                                                      *
********************************************************************* -}

-- See Note [Rough match] field in InstEnv

roughMatchTcs :: [Type] -> [Maybe Name]
roughMatchTcs tys = map rough tys
  where
    rough ty
      | Just (ty', _) <- splitCastTy_maybe ty   = rough ty'
      | Just (tc,_)   <- splitTyConApp_maybe ty = Just (tyConName tc)
      | otherwise                               = Nothing

instanceCantMatch :: [Maybe Name] -> [Maybe Name] -> Bool
-- (instanceCantMatch tcs1 tcs2) returns True if tcs1 cannot
-- possibly be instantiated to actual, nor vice versa;
-- False is non-committal
instanceCantMatch (mt : ts) (ma : as) = itemCantMatch mt ma || instanceCantMatch ts as
instanceCantMatch _         _         =  False  -- Safe

itemCantMatch :: Maybe Name -> Maybe Name -> Bool
itemCantMatch (Just t) (Just a) = t /= a
itemCantMatch _        _        = False


{-
************************************************************************
*                                                                      *
                GADTs
*                                                                      *
************************************************************************

Note [Pruning dead case alternatives]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider        data T a where
                   T1 :: T Int
                   T2 :: T a

                newtype X = MkX Int
                newtype Y = MkY Char

                type family F a
                type instance F Bool = Int

Now consider    case x of { T1 -> e1; T2 -> e2 }

The question before the house is this: if I know something about the type
of x, can I prune away the T1 alternative?

Suppose x::T Char.  It's impossible to construct a (T Char) using T1,
        Answer = YES we can prune the T1 branch (clearly)

Suppose x::T (F a), where 'a' is in scope.  Then 'a' might be instantiated
to 'Bool', in which case x::T Int, so
        ANSWER = NO (clearly)

We see here that we want precisely the apartness check implemented within
tcUnifyTysFG. So that's what we do! Two types cannot match if they are surely
apart. Note that since we are simply dropping dead code, a conservative test
suffices.
-}

-- | Given a list of pairs of types, are any two members of a pair surely
-- apart, even after arbitrary type function evaluation and substitution?
typesCantMatch :: [(Type,Type)] -> Bool
-- See Note [Pruning dead case alternatives]
typesCantMatch prs = any (uncurry cant_match) prs
  where
    cant_match :: Type -> Type -> Bool
    cant_match t1 t2 = case tcUnifyTysFG (const BindMe) [t1] [t2] of
      SurelyApart -> True
      _           -> False

{-
************************************************************************
*                                                                      *
             Unification
*                                                                      *
************************************************************************

Note [Fine-grained unification]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Do the types (x, x) and ([y], y) unify? The answer is seemingly "no" --
no substitution to finite types makes these match. But, a substitution to
*infinite* types can unify these two types: [x |-> [[[...]]], y |-> [[[...]]] ].
Why do we care? Consider these two type family instances:

type instance F x x   = Int
type instance F [y] y = Bool

If we also have

type instance Looper = [Looper]

then the instances potentially overlap. The solution is to use unification
over infinite terms. This is possible (see [1] for lots of gory details), but
a full algorithm is a little more power than we need. Instead, we make a
conservative approximation and just omit the occurs check.

[1]: http://research.microsoft.com/en-us/um/people/simonpj/papers/ext-f/axioms-extended.pdf

tcUnifyTys considers an occurs-check problem as the same as general unification
failure.

tcUnifyTysFG ("fine-grained") returns one of three results: success, occurs-check
failure ("MaybeApart"), or general failure ("SurelyApart").

See also Trac #8162.

It's worth noting that unification in the presence of infinite types is not
complete. This means that, sometimes, a closed type family does not reduce
when it should. See test case indexed-types/should_fail/Overlap15 for an
example.

Note [The substitution in MaybeApart]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The constructor MaybeApart carries data with it, typically a TvSubstEnv. Why?
Because consider unifying these:

(a, a, Int) ~ (b, [b], Bool)

If we go left-to-right, we start with [a |-> b]. Then, on the middle terms, we
apply the subst we have so far and discover that we need [b |-> [b]]. Because
this fails the occurs check, we say that the types are MaybeApart (see above
Note [Fine-grained unification]). But, we can't stop there! Because if we
continue, we discover that Int is SurelyApart from Bool, and therefore the
types are apart. This has practical consequences for the ability for closed
type family applications to reduce. See test case
indexed-types/should_compile/Overlap14.

Note [Unifying with skolems]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
If we discover that two types unify if and only if a skolem variable is
substituted, we can't properly unify the types. But, that skolem variable
may later be instantiated with a unifyable type. So, we return maybeApart
in these cases.

Note [Lists of different lengths are MaybeApart]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
It is unusual to call tcUnifyTys or tcUnifyTysFG with lists of different
lengths. The place where we know this can happen is from compatibleBranches in
FamInstEnv, when checking data family instances. Data family instances may be
eta-reduced; see Note [Eta reduction for data family axioms] in TcInstDcls.

We wish to say that

  D :: * -> * -> *
  axDF1 :: D Int ~ DFInst1
  axDF2 :: D Int Bool ~ DFInst2

overlap. If we conclude that lists of different lengths are SurelyApart, then
it will look like these do *not* overlap, causing disaster. See Trac #9371.

In usages of tcUnifyTys outside of family instances, we always use tcUnifyTys,
which can't tell the difference between MaybeApart and SurelyApart, so those
usages won't notice this design choice.
-}

tcUnifyTy :: Type -> Type       -- All tyvars are bindable
          -> Maybe TCvSubst
                       -- A regular one-shot (idempotent) substitution
-- Simple unification of two types; all type variables are bindable
tcUnifyTy t1 t2 = tcUnifyTys (const BindMe) [t1] [t2]

-- | Unify two types, treating type family applications as possibly unifying
-- with anything and looking through injective type family applications.
tcUnifyTyWithTFs :: Bool  -- ^ True <=> do two-way unification;
                          --   False <=> do one-way matching.
                          --   See end of sec 5.2 from the paper
                 -> Type -> Type -> Maybe TCvSubst
-- This algorithm is an implementation of the "Algorithm U" presented in
-- the paper "Injective type families for Haskell", Figures 2 and 3.
-- The code is incorporated with the standard unifier for convenience, but
-- its operation should match the specification in the paper.
tcUnifyTyWithTFs twoWay t1 t2
  = case tc_unify_tys (const BindMe) twoWay True
                       rn_env emptyTvSubstEnv emptyCvSubstEnv
                       [t1] [t2] of
      Unifiable  (subst, _) -> Just $ niFixTCvSubst subst
      MaybeApart (subst, _) -> Just $ niFixTCvSubst subst
      -- we want to *succeed* in questionable cases. This is a
      -- pre-unification algorithm.
      SurelyApart      -> Nothing
  where
    rn_env = mkRnEnv2 $ mkInScopeSet $ tyCoVarsOfTypes [t1, t2]

-----------------
tcUnifyTys :: (TyCoVar -> BindFlag)
           -> [Type] -> [Type]
           -> Maybe TCvSubst
                                -- ^ A regular one-shot (idempotent) substitution
                                -- that unifies the erased types. See comments
                                -- for 'tcUnifyTysFG'

-- The two types may have common type variables, and indeed do so in the
-- second call to tcUnifyTys in FunDeps.checkClsFD
tcUnifyTys bind_fn tys1 tys2
  = case tcUnifyTysFG bind_fn tys1 tys2 of
      Unifiable result -> Just result
      _                -> Nothing

-- This type does double-duty. It is used in the UM (unifier monad) and to
-- return the final result. See Note [Fine-grained unification]
type UnifyResult = UnifyResultM TCvSubst
data UnifyResultM a = Unifiable a        -- the subst that unifies the types
                    | MaybeApart a       -- the subst has as much as we know
                                         -- it must be part of an most general unifier
                                         -- See Note [The substitution in MaybeApart]
                    | SurelyApart
                    deriving Functor

instance Applicative UnifyResultM where
  pure  = Unifiable
  (<*>) = ap

instance Monad UnifyResultM where

  SurelyApart  >>= _ = SurelyApart
  MaybeApart x >>= f = case f x of
                         Unifiable y -> MaybeApart y
                         other       -> other
  Unifiable x  >>= f = f x

instance Alternative UnifyResultM where
  empty = SurelyApart

  a@(Unifiable {})  <|> _                 = a
  _                 <|> b@(Unifiable {})  = b
  a@(MaybeApart {}) <|> _                 = a
  _                 <|> b@(MaybeApart {}) = b
  SurelyApart       <|> SurelyApart       = SurelyApart

instance MonadPlus UnifyResultM

-- | @tcUnifyTysFG bind_tv tys1 tys2@ attepts to find a substitution @s@ (whose
-- domain elements all respond 'BindMe' to @bind_tv@) such that
-- @s(tys1)@ and that of @s(tys2)@ are equal, as witnessed by the returned
-- Coercions.
tcUnifyTysFG :: (TyVar -> BindFlag)
             -> [Type] -> [Type]
             -> UnifyResult
tcUnifyTysFG bind_fn tys1 tys2
  = do { (env, _) <- tc_unify_tys bind_fn True False env
                                  emptyTvSubstEnv emptyCvSubstEnv
                                  tys1 tys2
       ; return $ niFixTCvSubst env }
  where
    vars = tyCoVarsOfTypes tys1 `unionVarSet` tyCoVarsOfTypes tys2
    env  = mkRnEnv2 $ mkInScopeSet vars

-- | This function is actually the one to call the unifier -- a little
-- too general for outside clients, though.
tc_unify_tys :: (TyVar -> BindFlag)
             -> Bool        -- ^ True <=> unify; False <=> match
             -> Bool        -- ^ True <=> doing an injectivity check
             -> RnEnv2
             -> TvSubstEnv  -- ^ substitution to extend
             -> CvSubstEnv
             -> [Type] -> [Type]
             -> UnifyResultM (TvSubstEnv, CvSubstEnv)
tc_unify_tys bind_fn unif inj_check rn_env tv_env cv_env tys1 tys2
  = initUM bind_fn unif inj_check rn_env tv_env cv_env $
    do { unify_tys kis1 kis2
       ; unify_tys tys1 tys2
       ; (,) <$> getTvSubstEnv <*> getCvSubstEnv }
  where
    kis1 = map typeKind tys1
    kis2 = map typeKind tys2

instance Outputable a => Outputable (UnifyResultM a) where
  ppr SurelyApart    = text "SurelyApart"
  ppr (Unifiable x)  = text "Unifiable" <+> ppr x
  ppr (MaybeApart x) = text "MaybeApart" <+> ppr x

{-
************************************************************************
*                                                                      *
                Non-idempotent substitution
*                                                                      *
************************************************************************

Note [Non-idempotent substitution]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
During unification we use a TvSubstEnv/CvSubstEnv pair that is
  (a) non-idempotent
  (b) loop-free; ie repeatedly applying it yields a fixed point

Note [Finding the substitution fixpoint]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Finding the fixpoint of a non-idempotent substitution arising from a
unification is harder than it looks, because of kinds.  Consider
   T k (H k (f:k)) ~ T * (g:*)
If we unify, we get the substitution
   [ k -> *
   , g -> H k (f:k) ]
To make it idempotent we don't want to get just
   [ k -> *
   , g -> H * (f:k) ]
We also want to substitute inside f's kind, to get
   [ k -> *
   , g -> H k (f:*) ]
If we don't do this, we may apply the substitition to something,
and get an ill-formed type, i.e. one where typeKind will fail.
This happened, for example, in Trac #9106.

This is the reason for extending env with [f:k -> f:*], in the
definition of env' in niFixTvSubst
-}

niFixTCvSubst :: TvSubstEnv -> TCvSubst
-- Find the idempotent fixed point of the non-idempotent substitution
-- See Note [Finding the substitution fixpoint]
-- ToDo: use laziness instead of iteration?
niFixTCvSubst tenv = f tenv
  where
    f tenv
        | not_fixpoint = f (mapVarEnv (substTy subst') tenv)
        | otherwise    = subst
        where
          not_fixpoint  = foldVarSet ((||) . in_domain) False range_tvs
          in_domain tv  = tv `elemVarEnv` tenv

          range_tvs     = foldVarEnv (unionVarSet . tyCoVarsOfType) emptyVarSet tenv
          subst         = mkTvSubst (mkInScopeSet range_tvs) tenv

             -- env' extends env by replacing any free type with
             -- that same tyvar with a substituted kind
             -- See note [Finding the substitution fixpoint]
          tenv'  = extendVarEnvList tenv [ (rtv, mkTyVarTy $
                                                 setTyVarKind rtv $
                                                 substTy subst $
                                                 tyVarKind rtv)
                                         | rtv <- varSetElems range_tvs
                                         , not (in_domain rtv) ]
          subst' = mkTvSubst (mkInScopeSet range_tvs) tenv'

niSubstTvSet :: TvSubstEnv -> TyCoVarSet -> TyCoVarSet
-- Apply the non-idempotent substitution to a set of type variables,
-- remembering that the substitution isn't necessarily idempotent
-- This is used in the occurs check, before extending the substitution
niSubstTvSet tsubst tvs
  = foldVarSet (unionVarSet . get) emptyVarSet tvs
  where
    get tv
      | Just ty <- lookupVarEnv tsubst tv
      = niSubstTvSet tsubst (tyCoVarsOfType ty)

      | otherwise
      = unitVarSet tv

{-
************************************************************************
*                                                                      *
                The workhorse
*                                                                      *
************************************************************************

Note [Specification of unification]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
The algorithm implemented here is rather delicate, and we depend on it
to uphold certain properties. This is a summary of these required
properties. Any reference to "flattening" refers to the flattening
algorithm in FamInstEnv (See Note [Flattening] in FamInstEnv), not
the flattening algorithm in the solver.

Notation:
 θ,φ    substitutions
 ξ    type-function-free types
 τ,σ  other types
 τ♭   type τ, flattened

 ≡    eqType

(U1) Soundness.
If (unify τ₁ τ₂) = Unifiable θ, then θ(τ₁) ≡ θ(τ₂). θ is a most general
unifier for τ₁ and τ₂.

(U2) Completeness.
If (unify ξ₁ ξ₂) = SurelyApart,
then there exists no substitution θ such that θ(ξ₁) ≡ θ(ξ₂).

These two properties are stated as Property 11 in the "Closed Type Families"
paper (POPL'14). Below, this paper is called [CTF].

(U3) Apartness under substitution.
If (unify ξ τ♭) = SurelyApart, then (unify ξ θ(τ)♭) = SurelyApart, for
any θ. (Property 12 from [CTF])

(U4) Apart types do not unify.
If (unify ξ τ♭) = SurelyApart, then there exists no θ such that
θ(ξ) = θ(τ). (Property 13 from [CTF])

THEOREM. Completeness w.r.t ~
If (unify τ₁♭ τ₂♭) = SurelyApart, then there exists no proof that (τ₁ ~ τ₂).

PROOF. See appendix of [CTF].


The unification algorithm is used for type family injectivity, as described
in the "Injective Type Families" paper (Haskell'15), called [ITF]. When run
in this mode, it has the following properties.

(I1) If (unify σ τ) = SurelyApart, then σ and τ are not unifiable, even
after arbitrary type family reductions. Note that σ and τ are not flattened
here.

(I2) If (unify σ τ) = MaybeApart θ, and if some
φ exists such that φ(σ) ~ φ(τ), then φ extends θ.


Furthermore, the RULES matching algorithm requires this property,
but only when using this algorithm for matching:

(M1) If (match σ τ) succeeds with θ, then all matchable tyvars in σ
are bound in θ.

Property M1 means that we must extend the substitution with, say
(a ↦ a) when appropriate during matching.
See also Note [Self-substitution when matching].

(M2) Completeness of matching.
If θ(σ) = τ, then (match σ τ) = Unifiable φ, where θ is an extension of φ.

Sadly, property M2 and I2 conflict. Consider

type family F1 a b where
  F1 Int    Bool   = Char
  F1 Double String = Char

Consider now two matching problems:

P1. match (F1 a Bool) (F1 Int Bool)
P2. match (F1 a Bool) (F1 Double String)

In case P1, we must find (a ↦ Int) to satisfy M2.
In case P2, we must /not/ find (a ↦ Double), in order to satisfy I2. (Note
that the correct mapping for I2 is (a ↦ Int). There is no way to discover
this, but we musn't map a to anything else!)

We thus must parameterize the algorithm over whether it's being used
for an injectivity check (refrain from looking at non-injective arguments
to type families) or not (do indeed look at those arguments).

(It's all a question of whether or not to include equation (7) from Fig. 2
of [ITF].)

This extra parameter is a bit fiddly, perhaps, but seemingly less so than
having two separate, almost-identical algorithms.

Note [Self-substitution when matching]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
What should happen when we're *matching* (not unifying) a1 with a1? We
should get a substitution [a1 |-> a1]. A successful match should map all
the template variables (except ones that disappear when expanding synonyms).
But when unifying, we don't want to do this, because we'll then fall into
a loop.

This arrangement affects the code in three places:
 - If we're matching a refined template variable, don't recur. Instead, just
   check for equality. That is, if we know [a |-> Maybe a] and are matching
   (a ~? Maybe Int), we want to just fail.

 - Skip the occurs check when matching. This comes up in two places, because
   matching against variables is handled separately from matching against
   full-on types.

Note that this arrangement was provoked by a real failure, where the same
unique ended up in the template as in the target. (It was a rule firing when
compiling Data.List.NonEmpty.)

Note [Matching coercion variables]
~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~
Consider this:

   type family F a

   data G a where
     MkG :: F a ~ Bool => G a

   type family Foo (x :: G a) :: F a
   type instance Foo MkG = False

We would like that to be accepted. For that to work, we need to introduce
a coercion variable on the left an then use it on the right. Accordingly,
at use sites of Foo, we need to be able to use matching to figure out the
value for the coercion. (See the desugared version:

   axFoo :: [a :: *, c :: F a ~ Bool]. Foo (MkG c) = False |> (sym c)

) We never want this action to happen during *unification* though, when
all bets are off.

-}

-- See Note [Specification of unification]
unify_ty :: Type -> Type -> Coercion   -- Types to be unified and a co
                                       -- between their kinds
                                       -- See Note [Kind coercions in Unify]
         -> UM ()
-- Respects newtypes, PredTypes

unify_ty ty1 ty2 kco
  | Just ty1' <- coreView ty1 = unify_ty ty1' ty2 kco
  | Just ty2' <- coreView ty2 = unify_ty ty1 ty2' kco
  | CastTy ty1' co <- ty1     = unify_ty ty1' ty2 (co `mkTransCo` kco)
  | CastTy ty2' co <- ty2     = unify_ty ty1 ty2' (kco `mkTransCo` mkSymCo co)

unify_ty (TyVarTy tv1) ty2 kco = uVar tv1 ty2 kco
unify_ty ty1 (TyVarTy tv2) kco
  = do { unif <- amIUnifying
       ; if unif
         then umSwapRn $ uVar tv2 ty1 (mkSymCo kco)
         else surelyApart }  -- non-tv on left; tv on right: can't match.

unify_ty ty1 ty2 _kco
  | Just (tc1, tys1) <- splitTyConApp_maybe ty1
  , Just (tc2, tys2) <- splitTyConApp_maybe ty2
  = if tc1 == tc2 || (isStarKind ty1 && isStarKind ty2)
    then if isInjectiveTyCon tc1 Nominal
         then unify_tys tys1 tys2
         else do { let inj | isTypeFamilyTyCon tc1
                           = case familyTyConInjectivityInfo tc1 of
                               NotInjective -> repeat False
                               Injective bs -> bs
                           | otherwise
                           = repeat False

                       (inj_tys1, noninj_tys1) = partitionByList inj tys1
                       (inj_tys2, noninj_tys2) = partitionByList inj tys2

                 ; unify_tys inj_tys1 inj_tys2
                 ; inj_tf <- checkingInjectivity
                 ; unless inj_tf $ -- See (end of) Note [Specification of unification]
                   don'tBeSoSure $ unify_tys noninj_tys1 noninj_tys2 }
    else -- tc1 /= tc2
         if isGenerativeTyCon tc1 Nominal && isGenerativeTyCon tc2 Nominal
         then surelyApart
         else maybeApart

        -- Applications need a bit of care!
        -- They can match FunTy and TyConApp, so use splitAppTy_maybe
        -- NB: we've already dealt with type variables,
        -- so if one type is an App the other one jolly well better be too
unify_ty (AppTy ty1a ty1b) ty2 _kco
  | Just (ty2a, ty2b) <- tcRepSplitAppTy_maybe ty2
  = unify_ty_app ty1a ty1b ty2a ty2b

unify_ty ty1 (AppTy ty2a ty2b) _kco
  | Just (ty1a, ty1b) <- tcRepSplitAppTy_maybe ty1
  = unify_ty_app ty1a ty1b ty2a ty2b

unify_ty (LitTy x) (LitTy y) _kco | x == y = return ()

unify_ty (ForAllTy (Named tv1 _) ty1) (ForAllTy (Named tv2 _) ty2) kco
  = do { unify_ty (tyVarKind tv1) (tyVarKind tv2) (mkNomReflCo liftedTypeKind)
       ; umRnBndr2 tv1 tv2 $ unify_ty ty1 ty2 kco }

-- See Note [Matching coercion variables]
unify_ty (CoercionTy co1) (CoercionTy co2) kco
  = do { unif <- amIUnifying
       ; c_subst <- getCvSubstEnv
       ; case co1 of
           CoVarCo cv
             |  not unif
             ,  not (cv `elemVarEnv` c_subst)
             -> do { b <- tvBindFlagL cv
                   ; if b == BindMe
                       then do { checkRnEnvRCo co2
                               ; let [_, _, co_l, co_r] = decomposeCo 4 kco
                                  -- cv :: t1 ~ t2
                                  -- co2 :: s1 ~ s2
                                  -- co_l :: t1 ~ s1
                                  -- co_r :: t2 ~ s2
                               ; extendCvEnv cv (co_l `mkTransCo`
                                                 co2 `mkTransCo`
                                                 mkSymCo co_r) }
                       else return () }
           _ -> return () }

unify_ty ty1 _ _
  | Just (tc1, _) <- splitTyConApp_maybe ty1
  , not (isGenerativeTyCon tc1 Nominal)
  = maybeApart

unify_ty _ ty2 _
  | Just (tc2, _) <- splitTyConApp_maybe ty2
  , not (isGenerativeTyCon tc2 Nominal)
  = do { unif <- amIUnifying
       ; if unif then maybeApart else surelyApart }

unify_ty _ _ _ = surelyApart

unify_ty_app :: Type -> Type -> Type -> Type -> UM ()
unify_ty_app ty1a ty1b ty2a ty2b
  = do { -- TODO (RAE): Remove this exponential behavior.
         let ki1a = typeKind ty1a
             ki2a = typeKind ty2a
       ; unify_ty ki1a ki2a (mkNomReflCo liftedTypeKind)
       ; let kind_co = mkNomReflCo ki1a
       ; unify_ty ty1a ty2a kind_co
       ; unify_ty ty1b ty2b (mkNthCo 0 kind_co) }

unify_tys :: [Type] -> [Type] -> UM ()
unify_tys orig_xs orig_ys
  = go orig_xs orig_ys
  where
    go []     []     = return ()
    go (x:xs) (y:ys)
      = do { unify_ty x y (mkNomReflCo $ typeKind x)
           ; go xs ys }
    go _ _ = maybeApart  -- See Note [Lists of different lengths are MaybeApart]

---------------------------------
uVar :: TyVar           -- Variable to be unified
     -> Type            -- with this Type
     -> Coercion        -- :: kind tv ~N kind ty
     -> UM ()

uVar tv1 ty kco
 = do { -- Check to see whether tv1 is refined by the substitution
        subst <- getTvSubstEnv
      ; case (lookupVarEnv subst tv1) of
          Just ty' -> do { unif <- amIUnifying
                         ; if unif
                           then unify_ty ty' ty kco   -- Yes, call back into unify
                           else -- when *matching*, we don't want to just recur here.
                                -- this is because the range of the subst is the target
                                -- type, not the template type. So, just check for
                                -- normal type equality.
                                guard (ty' `eqType` ty) }
          Nothing  -> uUnrefined tv1 ty ty kco } -- No, continue

uUnrefined :: TyVar             -- variable to be unified
           -> Type              -- with this Type
           -> Type              -- (version w/ expanded synonyms)
           -> Coercion          -- :: kind tv ~N kind ty
           -> UM ()

-- We know that tv1 isn't refined

uUnrefined tv1 ty2 ty2' kco
  | Just ty2'' <- coreView ty2'
  = uUnrefined tv1 ty2 ty2'' kco    -- Unwrap synonyms
                -- This is essential, in case we have
                --      type Foo a = a
                -- and then unify a ~ Foo a

  | TyVarTy tv2 <- ty2'
  = do { tv1' <- umRnOccL tv1
       ; tv2' <- umRnOccR tv2
       ; unif <- amIUnifying
           -- See Note [Self-substitution when matching]
       ; when (tv1' /= tv2' || not unif) $ do
       { subst <- getTvSubstEnv
          -- Check to see whether tv2 is refined
       ; case lookupVarEnv subst tv2 of
         {  Just ty' | unif -> uUnrefined tv1 ty' ty' kco
         ;  _               -> do
       {   -- So both are unrefined

           -- And then bind one or the other,
           -- depending on which is bindable
       ; b1 <- tvBindFlagL tv1
       ; b2 <- tvBindFlagR tv2
       ; let ty1 = mkTyVarTy tv1
       ; case (b1, b2) of
           (BindMe, _)        -> do { checkRnEnvR ty2 -- make sure ty2 is not a local
                                    ; extendTvEnv tv1 (ty2 `mkCastTy` mkSymCo kco) }
           (_, BindMe) | unif -> do { checkRnEnvL ty1 -- ditto for ty1
                                    ; extendTvEnv tv2 (ty1 `mkCastTy` kco) }

           _ | tv1' == tv2' -> return ()
             -- How could this happen? If we're only matching and if
             -- we're comparing forall-bound variables.

           _ -> maybeApart -- See Note [Unification with skolems]
  }}}}

uUnrefined tv1 ty2 ty2' kco -- ty2 is not a type variable
  = do { occurs <- elemNiSubstSet tv1 (tyCoVarsOfType ty2')
       ; unif   <- amIUnifying
       ; if unif && occurs  -- See Note [Self-substitution when matching]
         then maybeApart       -- Occurs check, see Note [Fine-grained unification]
         else do bindTv tv1 (ty2 `mkCastTy` mkSymCo kco) }
            -- Bind tyvar to the synonym if poss

elemNiSubstSet :: TyVar -> TyCoVarSet -> UM Bool
elemNiSubstSet v set
  = do { tsubst <- getTvSubstEnv
       ; return $ v `elemVarSet` niSubstTvSet tsubst set }

bindTv :: TyVar -> Type -> UM ()
bindTv tv ty    -- ty is not a variable
  = do  { checkRnEnvR ty -- make sure ty mentions no local variables
        ; b <- tvBindFlagL tv
        ; case b of
            Skolem -> maybeApart  -- See Note [Unification with skolems]
            BindMe -> extendTvEnv tv ty
        }

{-
%************************************************************************
%*                                                                      *
                Binding decisions
*                                                                      *
************************************************************************
-}

data BindFlag
  = BindMe      -- A regular type variable

  | Skolem      -- This type variable is a skolem constant
                -- Don't bind it; it only matches itself
  deriving Eq

{-
************************************************************************
*                                                                      *
                Unification monad
*                                                                      *
************************************************************************
-}

data UMEnv = UMEnv { um_bind_fun :: TyVar -> BindFlag
                       -- the user-supplied BindFlag function
                   , um_unif     :: Bool   -- unification (True) or matching?
                   , um_inj_tf   :: Bool   -- checking for injectivity?
                             -- See (end of) Note [Specification of unification]
                   , um_rn_env   :: RnEnv2 }

data UMState = UMState
                   { um_tv_env   :: TvSubstEnv
                   , um_cv_env   :: CvSubstEnv }

newtype UM a = UM { unUM :: UMEnv -> UMState
                         -> UnifyResultM (UMState, a) }

instance Functor UM where
      fmap = liftM

instance Applicative UM where
      pure a = UM (\_ s -> pure (s, a))
      (<*>)  = ap

instance Monad UM where
  fail _   = UM (\_ _ -> SurelyApart) -- failed pattern match
  m >>= k  = UM (\env state ->
                  do { (state', v) <- unUM m env state
                     ; unUM (k v) env state' })

-- need this instance because of a use of 'guard' above
instance Alternative UM where
  empty     = UM (\_ _ -> Control.Applicative.empty)
  m1 <|> m2 = UM (\env state ->
                  unUM m1 env state <|>
                  unUM m2 env state)

instance MonadPlus UM

#if __GLASGOW_HASKELL__ > 710
instance MonadFail.MonadFail UM where
    fail _   = UM (\_tvs _subst -> SurelyApart) -- failed pattern match
#endif

initUM :: (TyVar -> BindFlag)
       -> Bool        -- True <=> unify; False <=> match
       -> Bool        -- True <=> doing an injectivity check
       -> RnEnv2
       -> TvSubstEnv  -- subst to extend
       -> CvSubstEnv
       -> UM a -> UnifyResultM a
initUM badtvs unif inj_tf rn_env subst_env cv_subst_env um
  = case unUM um env state of
      Unifiable (_, subst)  -> Unifiable subst
      MaybeApart (_, subst) -> MaybeApart subst
      SurelyApart           -> SurelyApart
  where
    env = UMEnv { um_bind_fun = badtvs
                , um_unif     = unif
                , um_inj_tf   = inj_tf
                , um_rn_env   = rn_env }
    state = UMState { um_tv_env = subst_env
                    , um_cv_env = cv_subst_env }

tvBindFlagL :: TyVar -> UM BindFlag
tvBindFlagL tv = UM $ \env state ->
  Unifiable (state, if inRnEnvL (um_rn_env env) tv
                    then Skolem
                    else um_bind_fun env tv)

tvBindFlagR :: TyVar -> UM BindFlag
tvBindFlagR tv = UM $ \env state ->
  Unifiable (state, if inRnEnvR (um_rn_env env) tv
                    then Skolem
                    else um_bind_fun env tv)

getTvSubstEnv :: UM TvSubstEnv
getTvSubstEnv = UM $ \_ state -> Unifiable (state, um_tv_env state)

getCvSubstEnv :: UM CvSubstEnv
getCvSubstEnv = UM $ \_ state -> Unifiable (state, um_cv_env state)

extendTvEnv :: TyVar -> Type -> UM ()
extendTvEnv tv ty = UM $ \_ state ->
  Unifiable (state { um_tv_env = extendVarEnv (um_tv_env state) tv ty }, ())

extendCvEnv :: CoVar -> Coercion -> UM ()
extendCvEnv cv co = UM $ \_ state ->
  Unifiable (state { um_cv_env = extendVarEnv (um_cv_env state) cv co }, ())

umRnBndr2 :: TyCoVar -> TyCoVar -> UM a -> UM a
umRnBndr2 v1 v2 thing = UM $ \env state ->
  let rn_env' = rnBndr2 (um_rn_env env) v1 v2 in
  unUM thing (env { um_rn_env = rn_env' }) state

checkRnEnv :: (RnEnv2 -> Var -> Bool) -> VarSet -> UM ()
checkRnEnv inRnEnv varset = UM $ \env state ->
  if any (inRnEnv (um_rn_env env)) (varSetElems varset)
  then MaybeApart (state, ())
  else Unifiable (state, ())

-- | Converts any SurelyApart to a MaybeApart
don'tBeSoSure :: UM () -> UM ()
don'tBeSoSure um = UM $ \env state ->
  case unUM um env state of
    SurelyApart -> MaybeApart (state, ())
    other       -> other

checkRnEnvR :: Type -> UM ()
checkRnEnvR ty = checkRnEnv inRnEnvR (tyCoVarsOfType ty)

checkRnEnvL :: Type -> UM ()
checkRnEnvL ty = checkRnEnv inRnEnvL (tyCoVarsOfType ty)

checkRnEnvRCo :: Coercion -> UM ()
checkRnEnvRCo co = checkRnEnv inRnEnvR (tyCoVarsOfCo co)

umRnOccL :: TyVar -> UM TyVar
umRnOccL v = UM $ \env state ->
  Unifiable (state, rnOccL (um_rn_env env) v)

umRnOccR :: TyVar -> UM TyVar
umRnOccR v = UM $ \env state ->
  Unifiable (state, rnOccR (um_rn_env env) v)

umSwapRn :: UM a -> UM a
umSwapRn thing = UM $ \env state ->
  let rn_env' = rnSwap (um_rn_env env) in
  unUM thing (env { um_rn_env = rn_env' }) state

amIUnifying :: UM Bool
amIUnifying = UM $ \env state -> Unifiable (state, um_unif env)

checkingInjectivity :: UM Bool
checkingInjectivity = UM $ \env state -> Unifiable (state, um_inj_tf env)

maybeApart :: UM ()
maybeApart = UM (\_ state -> MaybeApart (state, ()))

surelyApart :: UM a
surelyApart = UM (\_ _ -> SurelyApart)

{-
%************************************************************************
%*                                                                      *
            Matching a (lifted) type against a coercion
%*                                                                      *
%************************************************************************

This section defines essentially an inverse to liftCoSubst. It is defined
here to avoid a dependency from Coercion on this module.

-}

data MatchEnv = ME { me_tmpls :: TyVarSet
                   , me_env   :: RnEnv2 }

-- | 'liftCoMatch' is sort of inverse to 'liftCoSubst'.  In particular, if
--   @liftCoMatch vars ty co == Just s@, then @tyCoSubst s ty == co@,
--   where @==@ there means that the result of tyCoSubst has the same
--   type as the original co; but may be different under the hood.
--   That is, it matches a type against a coercion of the same
--   "shape", and returns a lifting substitution which could have been
--   used to produce the given coercion from the given type.
--   Note that this function is incomplete -- it might return Nothing
--   when there does indeed exist a possible lifting context.
--
-- This function is incomplete in that it doesn't respect the equality
-- in `eqType`. That is, it's possible that this will succeed for t1 and
-- fail for t2, even when t1 `eqType` t2. That's because it depends on
-- there being a very similar structure between the type and the coercion.
-- This incompleteness shouldn't be all that surprising, especially because
-- it depends on the structure of the coercion, which is a silly thing to do.
--
-- The lifting context produced doesn't have to be exacting in the roles
-- of the mappings. This is because any use of the lifting context will
-- also require a desired role. Thus, this algorithm prefers mapping to
-- nominal coercions where it can do so.
liftCoMatch :: TyCoVarSet -> Type -> Coercion -> Maybe LiftingContext
liftCoMatch tmpls ty co
  = do { cenv1 <- ty_co_match menv emptyVarEnv ki ki_co ki_ki_co ki_ki_co
       ; cenv2 <- ty_co_match menv cenv1       ty co
                              (mkNomReflCo co_lkind) (mkNomReflCo co_rkind)
       ; return (LC (mkEmptyTCvSubst in_scope) cenv2) }
  where
    menv     = ME { me_tmpls = tmpls, me_env = mkRnEnv2 in_scope }
    in_scope = mkInScopeSet (tmpls `unionVarSet` tyCoVarsOfCo co)
    -- Like tcMatchTy, assume all the interesting variables
    -- in ty are in tmpls

    ki       = typeKind ty
    ki_co    = promoteCoercion co
    ki_ki_co = mkNomReflCo liftedTypeKind

    Pair co_lkind co_rkind = coercionKind ki_co

-- | 'ty_co_match' does all the actual work for 'liftCoMatch'.
ty_co_match :: MatchEnv   -- ^ ambient helpful info
            -> LiftCoEnv  -- ^ incoming subst
            -> Type       -- ^ ty, type to match
            -> Coercion   -- ^ co, coercion to match against
            -> Coercion   -- ^ :: kind of L type of substed ty ~N L kind of co
            -> Coercion   -- ^ :: kind of R type of substed ty ~N R kind of co
            -> Maybe LiftCoEnv
ty_co_match menv subst ty co lkco rkco
  | Just ty' <- coreViewOneStarKind ty = ty_co_match menv subst ty' co lkco rkco

  -- handle Refl case:
  | tyCoVarsOfType ty `isNotInDomainOf` subst
  , Just (ty', _) <- isReflCo_maybe co
  , ty `eqType` ty'
  = Just subst

  where
    isNotInDomainOf :: VarSet -> VarEnv a -> Bool
    isNotInDomainOf set env
      = noneSet (\v -> elemVarEnv v env) set

    noneSet :: (Var -> Bool) -> VarSet -> Bool
    noneSet f = foldVarSet (\v rest -> rest && (not $ f v)) True

ty_co_match menv subst ty co lkco rkco
  | CastTy ty' co' <- ty
  = ty_co_match menv subst ty' co (co' `mkTransCo` lkco) (co' `mkTransCo` rkco)

  | CoherenceCo co1 co2 <- co
  = ty_co_match menv subst ty co1 (lkco `mkTransCo` mkSymCo co2) rkco

  | SymCo co' <- co
  = swapLiftCoEnv <$> ty_co_match menv (swapLiftCoEnv subst) ty co' rkco lkco

  -- Match a type variable against a non-refl coercion
ty_co_match menv subst (TyVarTy tv1) co lkco rkco
  | Just co1' <- lookupVarEnv subst tv1' -- tv1' is already bound to co1
  = if eqCoercionX (nukeRnEnvL rn_env) co1' co
    then Just subst
    else Nothing       -- no match since tv1 matches two different coercions

  | tv1' `elemVarSet` me_tmpls menv           -- tv1' is a template var
  = if any (inRnEnvR rn_env) (tyCoVarsOfCoList co)
    then Nothing      -- occurs check failed
    else Just $ extendVarEnv subst tv1' $
                castCoercionKind co (mkSymCo lkco) (mkSymCo rkco)

  | otherwise
  = Nothing

  where
    rn_env = me_env menv
    tv1' = rnOccL rn_env tv1

  -- just look through SubCo's. We don't really care about roles here.
ty_co_match menv subst ty (SubCo co) lkco rkco
  = ty_co_match menv subst ty co lkco rkco

ty_co_match menv subst (AppTy ty1a ty1b) co _lkco _rkco
  | Just (co2, arg2) <- splitAppCo_maybe co     -- c.f. Unify.match on AppTy
  = ty_co_match_app menv subst ty1a ty1b co2 arg2
ty_co_match menv subst ty1 (AppCo co2 arg2) _lkco _rkco
  | Just (ty1a, ty1b) <- repSplitAppTy_maybe ty1
       -- yes, the one from Type, not TcType; this is for coercion optimization
  = ty_co_match_app menv subst ty1a ty1b co2 arg2

ty_co_match menv subst (TyConApp tc1 tys) (TyConAppCo _ tc2 cos) _lkco _rkco
  = ty_co_match_tc menv subst tc1 tys tc2 cos
ty_co_match menv subst (ForAllTy (Anon ty1) ty2) (TyConAppCo _ tc cos) _lkco _rkco
  = ty_co_match_tc menv subst funTyCon [ty1, ty2] tc cos

ty_co_match menv subst (ForAllTy (Named tv1 _) ty1)
                       (ForAllCo tv2 kind_co2 co2)
                       lkco rkco
  = do { subst1 <- ty_co_match menv subst (tyVarKind tv1) kind_co2
                               ki_ki_co ki_ki_co
       ; let rn_env0 = me_env menv
             rn_env1 = rnBndr2 rn_env0 tv1 tv2
             menv'   = menv { me_env = rn_env1 }
       ; ty_co_match menv' subst1 ty1 co2 lkco rkco }
  where
    ki_ki_co = mkNomReflCo liftedTypeKind

ty_co_match _ subst (CoercionTy {}) _ _ _
  = Just subst -- don't inspect coercions

ty_co_match menv subst ty co lkco rkco
  | Just co' <- pushRefl co = ty_co_match menv subst ty co' lkco rkco
  | otherwise               = Nothing

ty_co_match_tc :: MatchEnv -> LiftCoEnv
               -> TyCon -> [Type]
               -> TyCon -> [Coercion]
               -> Maybe LiftCoEnv
ty_co_match_tc menv subst tc1 tys1 tc2 cos2
  = do { guard (tc1 == tc2)
       ; ty_co_match_args menv subst tys1 cos2 lkcos rkcos }
  where
    Pair lkcos rkcos
      = traverse (fmap mkNomReflCo . coercionKind) cos2

ty_co_match_app :: MatchEnv -> LiftCoEnv
                -> Type -> Type -> Coercion -> Coercion
                -> Maybe LiftCoEnv
ty_co_match_app menv subst ty1a ty1b co2a co2b
  = do { -- TODO (RAE): Remove this exponential behavior.
         subst1 <- ty_co_match menv subst  ki1a ki2a ki_ki_co ki_ki_co
       ; let Pair lkco rkco = mkNomReflCo <$> coercionKind ki2a
       ; subst2 <- ty_co_match menv subst1 ty1a co2a lkco rkco
       ; ty_co_match menv subst2 ty1b co2b (mkNthCo 0 lkco) (mkNthCo 0 rkco) }
  where
    ki1a = typeKind ty1a
    ki2a = promoteCoercion co2a
    ki_ki_co = mkNomReflCo liftedTypeKind

ty_co_match_args :: MatchEnv -> LiftCoEnv -> [Type]
                 -> [Coercion] -> [Coercion] -> [Coercion]
                 -> Maybe LiftCoEnv
ty_co_match_args _    subst []       []         _ _ = Just subst
ty_co_match_args menv subst (ty:tys) (arg:args) (lkco:lkcos) (rkco:rkcos)
  = do { subst' <- ty_co_match menv subst ty arg lkco rkco
       ; ty_co_match_args menv subst' tys args lkcos rkcos }
ty_co_match_args _    _     _        _          _ _ = Nothing

pushRefl :: Coercion -> Maybe Coercion
pushRefl (Refl Nominal (AppTy ty1 ty2))
  = Just (AppCo (Refl Nominal ty1) (mkNomReflCo ty2))
pushRefl (Refl r (ForAllTy (Anon ty1) ty2))
  = Just (TyConAppCo r funTyCon [mkReflCo r ty1, mkReflCo r ty2])
pushRefl (Refl r (TyConApp tc tys))
  = Just (TyConAppCo r tc (zipWith mkReflCo (tyConRolesX r tc) tys))
pushRefl (Refl r (ForAllTy (Named tv _) ty))
  = Just (mkHomoForAllCos_NoRefl [tv] (Refl r ty))
    -- NB: NoRefl variant. Otherwise, we get a loop!
pushRefl (Refl r (CastTy ty co))  = Just (castCoercionKind (Refl r ty) co co)
pushRefl _                        = Nothing
