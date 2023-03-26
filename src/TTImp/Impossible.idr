module TTImp.Impossible

import Core.Context
import Core.Env
import Core.Evaluate
import Core.TT

import TTImp.TTImp

import Data.List

%default covering

-- This file contains support for building a guess at the term on the LHS of an
-- 'impossible' case, in order to help build a tree of covered cases for
-- coverage checking. Since the LHS by definition won't be well typed, we are
-- only guessing! But we can still do some type-directed disambiguation of
-- names.
-- Constants (fromInteger/fromString etc) won't be supported, because in general
-- they involve resoling interfaces - they'll just become unmatchable patterns.

match : {auto c : Ref Ctxt Defs} ->
        NF [<] -> (Name, Int, ClosedTerm) -> Core Bool
match nty (n, i, rty)
    = do defs <- get Ctxt
         rtynf <- expand !(nf [<] rty)
         sameRet nty rtynf
  where
    sameRet : NF [<] -> NF [<] -> Core Bool
    sameRet _ (VApp{}) = pure True
    sameRet _ (VErased{}) = pure True
    sameRet (VApp{}) _ = pure True
    sameRet (VErased{}) _ = pure True
    sameRet (VTCon _ n _ _) (VTCon _ n' _ _) = pure (n == n')
    sameRet (VPrimVal _ c) (VPrimVal _ c') = pure (c == c')
    sameRet (VType{}) (VType{}) = pure True
    sameRet nf (VBind fc _ (Pi _ _ _ _) sc)
        = do defs <- get Ctxt
             sc' <- expand !(sc (pure (VErased fc Placeholder)))
             sameRet nf sc'
    sameRet _ _ = pure False

dropNoMatch : {auto c : Ref Ctxt Defs} ->
              Maybe (NF [<]) -> List (Name, Int, GlobalDef) ->
              Core (List (Name, Int, GlobalDef))
dropNoMatch _ [t] = pure [t]
dropNoMatch Nothing ts = pure ts
dropNoMatch (Just nty) ts
    = -- if the return type of a thing in ts doesn't match nty, drop it
      filterM (match nty . map (map type)) ts

data QVar : Type where

nextVar : {auto q : Ref QVar Int} ->
          FC -> Core ClosedTerm
nextVar fc
    = do i <- get QVar
         put QVar (i + 1)
         pure (Ref fc Bound (MN "imp" i))

badClause : ClosedTerm -> List RawImp -> List RawImp -> List (Name, RawImp) -> Core a
badClause fn exps autos named
   = throw (GenericMsg (getLoc fn)
            ("Badly formed impossible clause "
               ++ show (fn, exps, autos, named)))

findNamed : Name -> List (Name, RawImp) -> Maybe ((Name, RawImp), List (Name, RawImp))
findNamed n l = case partition ((== n) . fst) l of
                     (x :: xs, ys) => Just (x, (xs ++ ys))
                     _ => Nothing

mutual
  processArgs : {auto c : Ref Ctxt Defs} ->
                {auto q : Ref QVar Int} ->
                Term [<] -> NF [<] ->
                (expargs : List RawImp) ->
                (autoargs : List RawImp) ->
                (namedargs : List (Name, RawImp)) ->
                Core ClosedTerm
  -- unnamed takes priority
  processArgs fn (VBind fc x (Pi _ c Explicit ty) sc) (e :: exps) autos named
     = do e' <- mkTerm e (Just ty) [] [] []
          defs <- get Ctxt
          processArgs (App fc fn c e') !(expand !(sc (nf [<] e')))
                      exps autos named
  processArgs fn (VBind fc x (Pi _ c Explicit ty) sc) [] autos named
     = do defs <- get Ctxt
          case findNamed x named of
            Just ((_, e), named') =>
               do e' <- mkTerm e (Just ty) [] [] []
                  processArgs (App fc fn c e') !(expand !(sc (nf [<] e')))
                              [] autos named'
            Nothing => badClause fn [] autos named
  processArgs fn (VBind fc x (Pi _ c Implicit ty) sc) exps autos named
     = do defs <- get Ctxt
          case findNamed x named of
            Nothing => do e' <- nextVar fc
                          processArgs (App fc fn c e')
                                      !(expand !(sc (nf [<] e')))
                                      exps autos named
            Just ((_, e), named') =>
               do e' <- mkTerm e (Just ty) [] [] []
                  processArgs (App fc fn c e') !(expand !(sc (nf [<] e')))
                              exps autos named'
  processArgs fn (VBind fc x (Pi _ c AutoImplicit ty) sc) exps autos named
     = do defs <- get Ctxt
          case autos of
               (e :: autos') => -- unnamed takes priority
                   do e' <- mkTerm e (Just ty) [] [] []
                      processArgs (App fc fn c e') !(expand !(sc (nf [<] e')))
                                  exps autos' named
               [] =>
                  case findNamed x named of
                     Nothing =>
                        do e' <- nextVar fc
                           processArgs (App fc fn c e')
                                       !(expand !(sc (nf [<] e')))
                                       exps [] named
                     Just ((_, e), named') =>
                        do e' <- mkTerm e (Just ty) [] [] []
                           processArgs (App fc fn c e')
                                       !(expand !(sc (nf [<] e')))
                                       exps [] named'
  processArgs fn ty [] [] [] = pure fn
  processArgs fn ty exps autos named
     = badClause fn exps autos named

  buildApp : {auto c : Ref Ctxt Defs} ->
             {auto q : Ref QVar Int} ->
             FC -> Name -> Maybe (Glued [<]) ->
             (expargs : List RawImp) ->
             (autoargs : List RawImp) ->
             (namedargs : List (Name, RawImp)) ->
             Core ClosedTerm
  buildApp fc n mty exps autos named
      = do defs <- get Ctxt
           prims <- getPrimitiveNames
           when (n `elem` prims) $
               throw (InternalError "Can't deal with constants here yet")
           gdefs <- lookupNameBy id n (gamma defs)
           [(n', i, gdef)] <- dropNoMatch !(traverseOpt expand mty) gdefs
              | ts => ambiguousName fc n (map fst ts)
           tynf <- nf [<] (type gdef)
           -- #899 we need to make sure that type & data constructors are marked
           -- as such so that the coverage checker actually uses the matches in
           -- `impossible` branches to generate parts of the case tree.
           -- When `head` is `Func`, the pattern will be marked as forced and
           -- the coverage checker will considers that all the cases have been
           -- covered!
           let head = case definition gdef of
                        DCon _ t a => DataCon t a
                        TCon _ a => TyCon a
                        _ => Func
           processArgs (Ref fc head (Resolved i)) !(expand tynf) exps autos named

  mkTerm : {auto c : Ref Ctxt Defs} ->
           {auto q : Ref QVar Int} ->
           RawImp -> Maybe (Glued [<]) ->
           (expargs : List RawImp) ->
           (autoargs : List RawImp) ->
           (namedargs : List (Name, RawImp)) ->
           Core ClosedTerm
  mkTerm (IVar fc n) mty exps autos named
     = buildApp fc n mty exps autos named
  mkTerm (IApp fc fn arg) mty exps autos named
     = mkTerm fn mty (arg :: exps) autos named
  mkTerm (IAutoApp fc fn arg) mty exps autos named
     = mkTerm fn mty exps (arg :: autos) named
  mkTerm (INamedApp fc fn nm arg) mty exps autos named
     = mkTerm fn mty exps autos ((nm, arg) :: named)
  mkTerm (IPrimVal fc c) _ _ _ _ = pure (PrimVal fc c)
  mkTerm tm _ _ _ _ = nextVar (getFC tm)

-- Given an LHS that is declared 'impossible', build a term to match from,
-- so that when we build the case tree for checking coverage, we take into
-- account the impossible clauses
export
getImpossibleTerm : {vars : _} ->
                    {auto c : Ref Ctxt Defs} ->
                    Env Term vars -> NestedNames vars -> RawImp -> Core ClosedTerm
getImpossibleTerm env nest tm
    = do q <- newRef QVar (the Int 0)
         mkTerm (applyEnv tm) Nothing [] [] []
  where
    addEnv : {vars : _} ->
             FC -> Env Term vars -> List RawImp
    addEnv fc [<] = []
    addEnv fc (env :< b) =
       if isLet b
          then addEnv fc env
          else Implicit fc False :: addEnv fc env

    expandNest : RawImp -> RawImp
    expandNest (IVar fc n)
        = case lookup n (names nest) of
               Just (Just n', _, _) => IVar fc n'
               _ => IVar fc n
    expandNest tm = tm

    -- Need to apply the function to the surrounding environment, and update
    -- the name to the proper one from the nested names map
    applyEnv : RawImp -> RawImp
    applyEnv (IApp fc fn arg) = IApp fc (applyEnv fn) arg
    applyEnv (IAutoApp fc fn arg) = IAutoApp fc (applyEnv fn) arg
    applyEnv (INamedApp fc fn n arg)
        = INamedApp fc (applyEnv fn) n arg
    applyEnv tm = apply (expandNest tm) (addEnv (getFC tm) env)
