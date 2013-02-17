(************************************************************************)
(*  v      *   The Coq Proof Assistant  /  The Coq Development Team     *)
(* <O___,, *   INRIA - CNRS - LIX - LRI - PPS - Copyright 1999-2012     *)
(*   \VV/  **************************************************************)
(*    //   *      This file is distributed under the terms of the       *)
(*         *       GNU Lesser General Public License Version 2.1        *)
(************************************************************************)

open Errors
open Util
open Names
open Term
open Closure
open Reduction
open Reductionops
open Termops
open Environ
open Recordops
open Evarutil
open Evarsolve
open Globnames
open Evd
open Pretype_errors

type flex_kind_of_term =
  | Rigid
  | MaybeFlexible (* approx'ed as reducible but not necessarily so *)
  | Flexible of existential

let flex_kind_of_term c sk =
  match kind_of_term c with
    | Rel _ | Const _ | Var _ -> MaybeFlexible
    | Lambda _ when not (Option.is_empty (decomp_stack sk)) -> MaybeFlexible
    | LetIn _  -> MaybeFlexible
    | Evar ev -> Flexible ev
    | Lambda _ | Prod _ | Sort _ | Ind _ | Construct _ | CoFix _ -> Rigid
    | Meta _ -> Rigid
    | Fix _ -> Rigid (* happens when the fixpoint is partially applied *)
    | Cast _ | App _ | Case _ -> assert false

let not_purely_applicative_stack args =
  List.exists (function (Zfix _ | Zcase _) -> true | _ -> false) args

let eval_flexible_term ts env c =
  match kind_of_term c with
  | Const c ->
      if is_transparent_constant ts c
      then constant_opt_value env c
      else None
  | Rel n ->
      (try let (_,v,_) = lookup_rel n env in Option.map (lift n) v
      with Not_found -> None)
  | Var id ->
      (try
	 if is_transparent_variable ts id then
	   let (_,v,_) = lookup_named id env in v
	 else None
       with Not_found -> None)
  | LetIn (_,b,_,c) -> Some (subst1 b c)
  | Lambda _ -> Some c
  | _ -> assert false

let apprec_nohdbeta ts env evd c =
  match kind_of_term (fst (Reductionops.whd_nored_stack evd c)) with
    | (Case _ | Fix _) -> zip (whd_betaiota_deltazeta_for_iota_state ts env evd (c, []))
    | _ -> c

let position_problem l2r = function
  | CONV -> None
  | CUMUL -> Some l2r

(* [check_conv_record (t1,l1) (t2,l2)] tries to decompose the problem
   (t1 l1) = (t2 l2) into a problem

     l1 = params1@c1::extra_args1
     l2 = us2@extra_args2
     (t1 params1 c1) = (proji params (c xs))
     (t2 us2) = (cstr us)
     extra_args1 = extra_args2

   by finding a record R and an object c := [xs:bs](Build_R params v1..vn)
   with vi = (cstr us), for which we know that the i-th projection proji
   satisfies

      (proji params (c xs)) = (cstr us)

   Rem: such objects, usable for conversion, are defined in the objdef
   table; practically, it amounts to "canonically" equip t2 into a
   object c in structure R (since, if c1 were not an evar, the
   projection would have been reduced) *)

let check_conv_record (t1,sk1) (t2,sk2) =
  try
    let proji = global_of_constr t1 in
    let canon_s,sk2_effective =
      try
	match kind_of_term t2 with
	    Prod (_,a,b) -> (* assert (l2=[]); *)
      	      if dependent (mkRel 1) b then raise Not_found
	      else lookup_canonical_conversion (proji, Prod_cs),[Zapp [a;pop b]]
	  | Sort s ->
	      lookup_canonical_conversion
		(proji, Sort_cs (family_of_sort s)),[]
	  | _ ->
	      let c2 = global_of_constr t2 in
		lookup_canonical_conversion (proji, Const_cs c2),sk2
      with Not_found ->
	lookup_canonical_conversion (proji,Default_cs),[]
    in
    let { o_DEF = c; o_INJ=n; o_TABS = bs;
          o_TPARAMS = params; o_NPARAMS = nparams; o_TCOMPS = us } = canon_s in
    let params1, c1, extra_args1 =
      match strip_n_app nparams sk1 with
	| Some (params1, c1,extra_args1) -> params1, c1, extra_args1
	| _ -> raise Not_found in
    let us2,extra_args2 =
      let l',s' = strip_app sk2_effective in
      let bef,aft = List.chop (List.length us) l' in
      (bef, append_stack_app_list aft s') in
    c,bs,(params,params1),(us,us2),(extra_args1,extra_args2),c1,
    (n,zip(t2,sk2))
  with Failure _ | Not_found ->
    raise Not_found

(* Precondition: one of the terms of the pb is an uninstantiated evar,
 * possibly applied to arguments. *)

let rec ise_try evd = function
    [] -> assert false
  | [f] -> f evd
  | f1::l ->
      match f1 evd with
      | Success _ as x -> x
      | UnifFailure _ -> ise_try evd l

let ise_and evd l =
  let rec ise_and i = function
      [] -> assert false
    | [f] -> f i
    | f1::l ->
        match f1 i with
	| Success i' -> ise_and i' l
	| UnifFailure _ as x -> x in
  ise_and evd l

(* This function requires to get the outermost arguments first.  It is
   a fold_right for backward compatibility.

   It tries to unify the suffix of 2 lists element by element and if
   it reaches the end of a list, it returns the remaining elements in
   the other list if there are some.
*)
let generic_ise_list2 i f l1 l2 =
  let rec aux i l1 l2 =
    match l1,l2 with
    | [], [] -> (None, Success i)
    | l, [] -> (Some (Inl (List.rev l)), Success i)
    | [], l -> (Some (Inr (List.rev l)), Success i)
    | x::l1, y::l2 ->
        (match aux i l1 l2 with
        | aa, Success i' -> (aa, f i' x y)
        | _, (UnifFailure _ as x) -> None, x)
  in aux i (List.rev l1) (List.rev l2)

(* Same but the 2 lists must have the same length *)
let ise_list2 evd f l1 l2 =
  match generic_ise_list2 evd f l1 l2 with
  | None, out -> out
  | _, (UnifFailure _ as out) -> out
  | Some _, Success i -> UnifFailure (i,NotSameArgSize)

let ise_array2 evd f v1 v2 =
  let rec allrec i = function
    | -1 -> Success i
    | n ->
        match f i v1.(n) v2.(n) with
	| Success i' -> allrec i' (n-1)
	| UnifFailure _ as x -> x in
  let lv1 = Array.length v1 in
  if Int.equal lv1 (Array.length v2) then allrec evd (pred lv1)
  else UnifFailure (evd,NotSameArgSize)

(* This function tries to unify 2 stacks element by element. It works
   from the end to the beginning. If it unifies a non empty suffix of
   stacks but not the entire stacks, the first part of the answer is
   Some(the remaining prefixes to tackle)) *)
let ise_stack2 no_app env evd f sk1 sk2 =
  let rec ise_stack2 deep i sk1 sk2 =
    let fail x = if deep then Some (List.rev sk1, List.rev sk2), Success i
      else None, x in
    match sk1, sk2 with
    | [], [] -> None, Success i
    | Zcase (_,t1,c1,_)::q1, Zcase (_,t2,c2,_)::q2 ->
      (match f env i CONV t1 t2 with
      | Success i' ->
	(match ise_array2 i' (fun ii -> f env ii CONV) c1 c2 with
	| Success i'' -> ise_stack2 true i'' q1 q2
        | UnifFailure _ as x -> fail x)
      | UnifFailure _ as x -> fail x)
    | Zfix (((li1, i1),(_,tys1,bds1 as recdef1)),a1,_)::q1, Zfix (((li2, i2),(_,tys2,bds2)),a2,_)::q2 ->
      if Int.equal i1 i2 && Array.equal Int.equal li1 li2 then
        match ise_and i [
	  (fun i -> ise_array2 i (fun ii -> f env ii CONV) tys1 tys2);
	  (fun i -> ise_array2 i (fun ii -> f (push_rec_types recdef1 env) ii CONV) bds1 bds2);
	  (fun i -> ise_list2 i (fun ii -> f env ii CONV) a1 a2)] with
        | Success i' -> ise_stack2 true i' q1 q2
        | UnifFailure _ as x -> fail x
      else fail (UnifFailure (i,NotSameHead))
    | Zupdate _ :: _, _ | Zshift _ :: _, _
    | _, Zupdate _ :: _ | _, Zshift _ :: _ -> assert false
    | Zapp l1 :: q1, Zapp l2 :: q2 ->
      if no_app&&deep then fail ((*dummy*)UnifFailure(i,NotSameHead)) else begin
      (* Is requiring to match on all the shorter list a restriction
	 here ? we could imagine a generalization of
	 generic_ise_list2 that succeed when it matches only a strict
	 non empty suffix of both lists and returns in this case the 2
	 prefixes *)
      match generic_ise_list2 i (fun ii -> f env ii CONV) l1 l2 with
      |_,(UnifFailure _ as x) -> fail x
      |None,Success i' -> ise_stack2 true i' q1 q2
      |Some (Inl r),Success i' -> ise_stack2 true i' (Zapp r :: q1) q2
      |Some (Inr r),Success i' -> ise_stack2 true i' q1 (Zapp r :: q2)
    end
    |_, _ -> fail (UnifFailure (i,(* Maybe improve: *) NotSameHead))
  in ise_stack2 false evd (List.rev sk1) (List.rev sk2)

(* Make sure that the matching suffix is the all stack *)
let exact_ise_stack2 env evd f sk1 sk2 =
  match ise_stack2 false env evd f sk1 sk2 with | None, out -> out | _ -> UnifFailure (evd, NotSameArgSize)

let rec evar_conv_x ts env evd pbty term1 term2 =
  let term1 = whd_head_evar evd term1 in
  let term2 = whd_head_evar evd term2 in
  (* Maybe convertible but since reducing can erase evars which [evar_apprec]
     could have found, we do it only if the terms are free of evar.
     Note: incomplete heuristic... *)
  let ground_test =
    if is_ground_term evd term1 && is_ground_term evd term2 then
      if is_trans_fconv pbty ts env evd term1 term2 then
        Some true
      else if is_ground_env evd env then Some false
      else None
    else None in
  match ground_test with
    | Some true -> Success evd
    | Some false -> UnifFailure (evd,ConversionFailed (env,term1,term2))
    | None ->
	(* Until pattern-unification is used consistently, use nohdbeta to not
	   destroy beta-redexes that can be used for 1st-order unification *)
        let term1 = apprec_nohdbeta ts env evd term1 in
        let term2 = apprec_nohdbeta ts env evd term2 in
        if is_undefined_evar evd term1 then
          solve_simple_eqn (evar_conv_x ts) env evd
	    (position_problem true pbty,destEvar term1,term2)
        else if is_undefined_evar evd term2 then
          solve_simple_eqn (evar_conv_x ts) env evd
	    (position_problem false pbty,destEvar term2,term1)
        else
          evar_eqappr_x ts env evd pbty
            (whd_nored_state evd (term1,empty_stack)) (whd_nored_state evd (term2,empty_stack))

and evar_eqappr_x ?(rhs_is_already_stuck = false)
    ts env evd pbty (term1,sk1 as appr1) (term2,sk2 as appr2) =
  let default_fail i = (* costly *)
    UnifFailure (i,ConversionFailed (env, zip appr1, zip appr2)) in
  let miller_pfenning on_left fallback ev (_,skF) apprM evd =
    let tM = zip apprM in
    Option.cata
      (fun lF -> Option.cata
	(fun l1' ->
      (* Miller-Pfenning's patterns unification *)
      let t2 = nf_evar evd tM in
      let t2 = solve_pattern_eqn env l1' t2 in
      solve_simple_eqn (evar_conv_x ts) env evd
	(position_problem on_left pbty,ev,t2)
	) fallback
	(is_unification_pattern_evar env evd ev lF tM)
      ) (default_fail evd) (list_of_app_stack skF) in
  let flex_maybeflex on_left ev (termF,skF as apprF) (termM, skM as apprM) =
    let switch f a b = if on_left then f a b else f b a in
    let not_only_app = not_purely_applicative_stack skM in
    let f1 i = miller_pfenning on_left
      (if not_only_app then (* Postpone the use of an heuristic *)
	switch (fun x y -> Success (add_conv_pb (pbty,env,zip x,zip y) i)) apprF apprM
       else default_fail i)
      ev apprF apprM i
    and f2 i =
      match switch (ise_stack2 not_only_app env i (evar_conv_x ts)) skF skM with
      |Some (l,r), Success i' when on_left && (not_only_app || l = []) ->
	switch (evar_conv_x ts env i' pbty) (zip(termF,l)) (zip(termM,r))
      |Some (r,l), Success i' when not on_left && (not_only_app || l = []) ->
	switch (evar_conv_x ts env i' pbty) (zip(termF,l)) (zip(termM,r))
      |None, Success i' -> switch (evar_conv_x ts env i' pbty) termF termM
      |_, (UnifFailure _ as x) -> x
      |Some _, _ -> UnifFailure (i,NotSameArgSize)
    and f3 i =
      match eval_flexible_term ts env termM with
      | Some vM ->
	switch (evar_eqappr_x ts env i pbty) apprF
	  (whd_betaiota_deltazeta_for_iota_state ts env i (vM, skM))
      | None -> UnifFailure (i,NotSameHead)
    in
    ise_try evd [f1; f2; f3] in
  let eta env evd onleft sk term sk' term' =
    assert (match sk with [] -> true | _ -> false);
    let (na,c1,c'1) = destLambda term in
    let c = nf_evar evd c1 in
    let env' = push_rel (na,None,c) env in
    let appr1 = whd_betaiota_deltazeta_for_iota_state ts env' evd (c'1, empty_stack) in
    let appr2 = whd_nored_state evd (zip (term', sk' @ [Zshift 1]), [Zapp [mkRel 1]]) in
      if onleft then evar_eqappr_x ts env' evd CONV appr1 appr2
      else evar_eqappr_x ts env' evd CONV appr2 appr1
  in

  let app_empty = match sk1, sk2 with [], [] -> true | _ -> false in
  (* Evar must be undefined since we have flushed evars *)
  match (flex_kind_of_term term1 sk1, flex_kind_of_term term2 sk2) with
    | Flexible (sp1,al1 as ev1), Flexible (sp2,al2 as ev2) ->
	let f1 i =
	  match ise_stack2 false env i (evar_conv_x ts) sk1 sk2 with
	  |None, Success i' -> solve_simple_eqn (evar_conv_x ts) env i'
	    (position_problem true pbty,ev1,term2)
	  |Some (r,[]), Success i' -> solve_simple_eqn (evar_conv_x ts) env i'
	    (position_problem false pbty,ev2,zip(term1,r))
	  |Some ([],r), Success i' -> solve_simple_eqn (evar_conv_x ts) env i'
	          (position_problem true pbty,ev1,zip(term2,r))
	  |_, (UnifFailure _ as x) -> x
	  |Some _, _ -> UnifFailure (i,NotSameArgSize)
	and f2 i =
          if Int.equal sp1 sp2 then
	    match ise_stack2 false env i (evar_conv_x ts) sk1 sk2 with
	    |None, Success i' ->
              Success (solve_refl (fun env i pbty a1 a2 ->
                is_success (evar_conv_x ts env i pbty a1 a2))
                env i' sp1 al1 al2)
	    |_, (UnifFailure _ as x) -> x
            |Some _, _ -> UnifFailure (i,NotSameArgSize)
          else UnifFailure (i,NotSameHead)
	in
	ise_try evd [f1; f2]

    | Flexible ev1, MaybeFlexible -> flex_maybeflex true ev1 appr1 appr2

    | MaybeFlexible, Flexible ev2 -> flex_maybeflex false ev2 appr2 appr1

    | MaybeFlexible, MaybeFlexible -> begin
        match kind_of_term term1, kind_of_term term2 with
        | LetIn (na,b1,t1,c'1), LetIn (_,b2,_,c'2) ->
        let f1 i =
          ise_and i
	    [(fun i -> evar_conv_x ts env i CONV b1 b2);
	     (fun i ->
	       let b = nf_evar i b1 in
	       let t = nf_evar i t1 in
	       evar_conv_x ts (push_rel (na,Some b,t) env) i pbty c'1 c'2);
	     (fun i -> exact_ise_stack2 env i (evar_conv_x ts) sk1 sk2)]
	and f2 i =
          let appr1 = whd_betaiota_deltazeta_for_iota_state ts env i ((subst1 b1 c'1),sk1)
          and appr2 = whd_betaiota_deltazeta_for_iota_state ts env i ((subst1 b2 c'2),sk2)
	  in evar_eqappr_x ts env i pbty appr1 appr2
	in
	ise_try evd [f1; f2]

	| _, _ ->
	let f1 i =
	  if eq_constr term1 term2 then
	    exact_ise_stack2 env i (evar_conv_x ts) sk1 sk2
	  else
	     UnifFailure (i,NotSameHead)
	and f2 i =
	  (try conv_record ts env i
             (try check_conv_record appr1 appr2
	      with Not_found -> check_conv_record appr2 appr1)
           with Not_found -> UnifFailure (i,NoCanonicalStructure))
	and f3 i =
          (* heuristic: unfold second argument first, exception made
             if the first argument is a beta-redex (expand a constant
             only if necessary) or the second argument is potentially
             usable as a canonical projection or canonical value *)
          let rec is_unnamed (hd, args) = match kind_of_term hd with
            | (Var _|Construct _|Ind _|Const _|Prod _|Sort _) ->
	      not_purely_applicative_stack args
            | (CoFix _|Meta _|Rel _)-> true
            | Evar _ -> not_purely_applicative_stack args
	    (* false (* immediate solution without Canon Struct *)*)
            | Lambda _ -> assert (match args with [] -> true | _ -> false); true
            | LetIn (_,b,_,c) ->
                is_unnamed (whd_betaiota_deltazeta_for_iota_state ts env i (subst1 b c, args))
            | Case _| Fix _| App _| Cast _ -> assert false in
          let rhs_is_stuck_and_unnamed () =
            match eval_flexible_term ts env term2 with
            | None -> false
            | Some v2 ->
	      let applicative_stack = append_stack_app_list (fst (strip_app sk2)) empty_stack in
	      is_unnamed (whd_betaiota_deltazeta_for_iota_state ts env i (v2, applicative_stack)) in
          let rhs_is_already_stuck =
            rhs_is_already_stuck || rhs_is_stuck_and_unnamed () in
	  if (isLambda term1 || rhs_is_already_stuck) && (not (not_purely_applicative_stack sk1)) then
	    match eval_flexible_term ts env term1 with
	    | Some v1 ->
		evar_eqappr_x ~rhs_is_already_stuck
                  ts env i pbty (whd_betaiota_deltazeta_for_iota_state ts env i (v1,sk1)) appr2
	    | None ->
		match eval_flexible_term ts env term2 with
		| Some v2 ->
		    evar_eqappr_x ts env i pbty appr1 (whd_betaiota_deltazeta_for_iota_state ts env i (v2,sk2))
		| None -> UnifFailure (i,NotSameHead)
	  else
	    match eval_flexible_term ts env term2 with
	    | Some v2 ->
		evar_eqappr_x ts env i pbty appr1 (whd_betaiota_deltazeta_for_iota_state ts env i (v2,sk2))
	    | None ->
		match eval_flexible_term ts env term1 with
		| Some v1 ->
		    evar_eqappr_x ts env i pbty (whd_betaiota_deltazeta_for_iota_state ts env i (v1,sk1)) appr2
		| None -> UnifFailure (i,NotSameHead)
	in
	ise_try evd [f1; f2; f3]
      end

    | Rigid, Rigid when isLambda term1 & isLambda term2 ->
        let (na,c1,c'1) = destLambda term1 in
        let (_,c2,c'2) = destLambda term2 in
        assert app_empty;
        ise_and evd
          [(fun i -> evar_conv_x ts env i CONV c1 c2);
           (fun i ->
	     let c = nf_evar i c1 in
	     evar_conv_x ts (push_rel (na,None,c) env) i CONV c'1 c'2)]

    | Flexible ev1, Rigid ->
      let f1 evd = 
	miller_pfenning true
	(Success ((* Postpone the use of an heuristic *)
	  add_conv_pb (pbty,env,zip appr1,zip appr2) evd))
	ev1 appr1 appr2 evd
      and f2 evd =
	if isLambda term2 then
	  eta env evd false sk2 term2 sk1 term1
	else UnifFailure (evd,NotSameHead)
      in ise_try evd [f1;f2]

    | Rigid, Flexible ev2 ->
      let f1 evd =
	miller_pfenning false
	  (Success ((* Postpone the use of an heuristic *)
	     add_conv_pb (pbty,env,zip appr1,zip appr2) evd))
	ev2 appr2 appr1 evd
      and f2 evd =
	if isLambda term1 then
	  eta env evd true sk1 term1 sk2 term2
	else UnifFailure (evd,NotSameHead)
      in ise_try evd [f1;f2]

    | MaybeFlexible, Rigid ->
	let f3 i =
	  (try conv_record ts env i (check_conv_record appr1 appr2)
           with Not_found -> UnifFailure (i,NoCanonicalStructure))
	and f4 i =
	  match eval_flexible_term ts env term1 with
	    | Some v1 ->
		evar_eqappr_x ts env i pbty
		  (whd_betaiota_deltazeta_for_iota_state ts env i (v1,sk1)) appr2
	    | None -> 
	      if isLambda term2 then eta env evd false sk2 term2 sk1 term1
	      else UnifFailure (i,NotSameHead)
	in	 
	  ise_try evd [f3; f4]

    | Rigid, MaybeFlexible ->
	let f3 i =
	  (try conv_record ts env i (check_conv_record appr2 appr1)
           with Not_found -> UnifFailure (i,NoCanonicalStructure))
	and f4 i =
	  match eval_flexible_term ts env term2 with
	    | Some v2 ->
		evar_eqappr_x ts env i pbty
		  appr1 (whd_betaiota_deltazeta_for_iota_state ts env i (v2,sk2))
	    | None -> 
	      if isLambda term1 then eta env evd true sk1 term1 sk2 term2
	      else UnifFailure (i,NotSameHead)
	in
	  ise_try evd [f3; f4]

    (* Eta-expansion *)
    | Rigid, _ when isLambda term1 ->
        eta env evd true sk1 term1 sk2 term2

    | _, Rigid when isLambda term2 ->
        eta env evd false sk2 term2 sk1 term1

    | Rigid, Rigid -> begin
        match kind_of_term term1, kind_of_term term2 with

	| Sort s1, Sort s2 when app_empty ->
	    (try
	       let evd' =
		 if pbty == CONV
		 then Evd.set_eq_sort evd s1 s2
		 else Evd.set_leq_sort evd s1 s2
	       in Success evd'
	     with Univ.UniverseInconsistency _ ->
               UnifFailure (evd,UnifUnivInconsistency)
	     | _ -> UnifFailure (evd,NotSameHead))

	| Prod (n,c1,c'1), Prod (_,c2,c'2) when app_empty ->
            ise_and evd
              [(fun i -> evar_conv_x ts env i CONV c1 c2);
               (fun i ->
 	         let c = nf_evar i c1 in
	         evar_conv_x ts (push_rel (n,None,c) env) i pbty c'1 c'2)]

	| Ind sp1, Ind sp2 ->
	    if eq_ind sp1 sp2 then
              exact_ise_stack2 env evd (evar_conv_x ts) sk1 sk2
            else UnifFailure (evd,NotSameHead)

	| Construct sp1, Construct sp2 ->
	    if eq_constructor sp1 sp2 then
              exact_ise_stack2 env evd (evar_conv_x ts) sk1 sk2
            else UnifFailure (evd,NotSameHead)

	| Fix ((li1, i1),(_,tys1,bds1 as recdef1)), Fix ((li2, i2),(_,tys2,bds2)) -> (* Partially applied fixs *)
	  if Int.equal i1 i2 && Array.equal Int.equal li1 li2 then
            ise_and evd [
	      (fun i -> ise_array2 i (fun i' -> evar_conv_x ts env i' CONV) tys1 tys2);
	      (fun i -> ise_array2 i (fun i' -> evar_conv_x ts (push_rec_types recdef1 env) i' CONV) bds1 bds2);
	      (fun i -> exact_ise_stack2 env i (evar_conv_x ts) sk1 sk2)]
	  else UnifFailure (evd, NotSameHead)

	| CoFix (i1,(_,tys1,bds1 as recdef1)), CoFix (i2,(_,tys2,bds2)) ->
            if Int.equal i1 i2  then
              ise_and evd
                [(fun i -> ise_array2 i
                    (fun i -> evar_conv_x ts env i CONV) tys1 tys2);
                 (fun i -> ise_array2 i
		     (fun i -> evar_conv_x ts (push_rec_types recdef1 env) i CONV)
		     bds1 bds2);
                 (fun i -> exact_ise_stack2 env i
                     (evar_conv_x ts) sk1 sk2)]
            else UnifFailure (evd,NotSameHead)

	| (Meta _, _) | (_, Meta _) ->
	  begin match ise_stack2 true env evd (evar_conv_x ts) sk1 sk2 with
	  |_, (UnifFailure _ as x) -> x
	  |None, Success i' -> evar_conv_x ts env i' CONV term1 term2
	  |Some (sk1',sk2'), Success i' -> evar_conv_x ts env i' CONV (zip (term1,sk1')) (zip (term2,sk2'))
	  end

	| (Ind _ | Construct _ | Sort _ | Prod _ | CoFix _ | Fix _), _ -> UnifFailure (evd,NotSameHead)
	| _, (Ind _ | Construct _ | Sort _ | Prod _ | CoFix _ | Fix _) -> UnifFailure (evd,NotSameHead)

	| (App _ | Cast _ | Case _), _ -> assert false
	| (LetIn _ | Rel _ | Var _ | Const _ | Evar _), _ -> assert false
	| (Lambda _), _ -> assert false

      end

and conv_record trs env evd (c,bs,(params,params1),(us,us2),(ts,ts1),c1,(n,t2)) =
  let (evd',ks,_) =
    List.fold_left
      (fun (i,ks,m) b ->
	 if Int.equal m n then (i,t2::ks, m-1) else
	 let dloc = (Loc.ghost,Evar_kinds.InternalHole) in
         let (i',ev) = new_evar i env ~src:dloc (substl ks b) in
	 (i', ev :: ks, m - 1))
      (evd,[],List.length bs - 1) bs
  in
  ise_and evd'
    [(fun i ->
      ise_list2 i
        (fun i' x1 x -> evar_conv_x trs env i' CONV x1 (substl ks x))
        params1 params);
     (fun i ->
       ise_list2 i
         (fun i' u1 u -> evar_conv_x trs env i' CONV u1 (substl ks u))
         us2 us);
     (fun i -> exact_ise_stack2 env i (evar_conv_x trs) ts ts1);
     (fun i -> evar_conv_x trs env i CONV c1 (applist (c,(List.rev ks))))]

(* getting rid of the optional argument rhs_is_already_stuck *)
let evar_eqappr_x ts env evd pbty appr1 appr2 =
  evar_eqappr_x ts env evd pbty appr1 appr2

(* We assume here |l1| <= |l2| *)

let first_order_unification ts env evd (ev1,l1) (term2,l2) =
  let (deb2,rest2) = List.chop (List.length l2-List.length l1) l2 in
  ise_and evd
    (* First compare extra args for better failure message *)
    [(fun i -> ise_list2 i (fun i -> evar_conv_x ts env i CONV) rest2 l1);
    (fun i ->
      (* Then instantiate evar unless already done by unifying args *)
      let t2 = applist(term2,deb2) in
      if is_defined_evar i ev1 then
	evar_conv_x ts env i CONV t2 (mkEvar ev1)
      else
	solve_simple_eqn ~choose:true (evar_conv_x ts) env i (None,ev1,t2))]

let choose_less_dependent_instance evk evd term args =
  let evi = Evd.find_undefined evd evk in
  let subst = make_pure_subst evi args in
  let subst' = List.filter (fun (id,c) -> eq_constr c term) subst in
  match subst' with
  | [] -> None
  | (id, _) :: _ -> Some (Evd.define evk (mkVar id) evd)

let apply_on_subterm f c t =
  let rec applyrec (k,c as kc) t =
    (* By using eq_constr, we make an approximation, for instance, we *)
    (* could also be interested in finding a term u convertible to t *)
    (* such that c occurs in u *)
    if eq_constr c t then f k
    else
      map_constr_with_binders_left_to_right (fun d (k,c) -> (k+1,lift 1 c))
	applyrec kc t
  in
  applyrec (0,c) t

let filter_possible_projections c ty ctxt args =
  let fv1 = free_rels c in
  let fv2 = collect_vars c in
  let tyvars = collect_vars ty in
  List.map2 (fun (id,_,_) a ->
    a == c ||
    (* Here we make an approximation, for instance, we could also be *)
    (* interested in finding a term u convertible to c such that a occurs *)
    (* in u *)
    isRel a && Int.Set.mem (destRel a) fv1 ||
    isVar a && Id.Set.mem (destVar a) fv2 ||
    Id.Set.mem id tyvars)
    ctxt args

let solve_evars = ref (fun _ -> failwith "solve_evars not installed")
let set_solve_evars f = solve_evars := f

(* We solve the problem env_rhs |- ?e[u1..un] = rhs knowing
 * x1:T1 .. xn:Tn |- ev : ty
 * by looking for a maximal well-typed abtraction over u1..un in rhs
 *
 * We first build C[e11..e1p1,..,en1..enpn] obtained from rhs by replacing
 * all occurrences of u1..un by evars eij of type Ti' where itself Ti' has
 * been obtained from the type of ui by also replacing all occurrences of
 * u1..ui-1 by evars.
 *
 * Then, we use typing to infer the relations between the different
 * occurrences. If some occurrence is still unconstrained after typing,
 * we instantiate successively the unresolved occurrences of un by xn,
 * of un-1 by xn-1, etc [the idea comes from Chung-Kil Hur, that he
 * used for his Heq plugin; extensions to several arguments based on a
 * proposition from Dan Grayson]
 *)

let second_order_matching ts env_rhs evd (evk,args) argoccs rhs =
  try
  let args = Array.to_list args in
  let evi = Evd.find_undefined evd evk in
  let env_evar = evar_filtered_env evi in
  let sign = named_context_val env_evar in
  let ctxt = evar_filtered_context evi in
  let filter = evar_filter evi in
  let instance = List.map mkVar (List.map pi1 ctxt) in

  let rec make_subst = function
  | (id,_,t)::ctxt', c::l, occs::occsl when isVarId id c ->
      begin match occs with
      | Some _ ->
        error "Cannot force abstraction on identity instance."
      | None ->
        make_subst (ctxt',l,occsl)
      end
  | (id,_,t)::ctxt', c::l, occs::occsl ->
      let evs = ref [] in
      let ty = Retyping.get_type_of env_rhs evd c in
      let filter' = filter_possible_projections c ty ctxt args in
      let filter = List.map2 (&&) filter filter' in
      (id,t,c,ty,evs,filter,occs) :: make_subst (ctxt',l,occsl)
  | [], [], [] -> []
  | _ -> anomaly (Pp.str "Signature, instance and occurrences list do not match") in

  let rec set_holes evdref rhs = function
  | (id,_,c,cty,evsref,filter,occs)::subst ->
      let set_var k =
        match occs with
        | Some Locus.AllOccurrences -> mkVar id
        | Some _ -> error "Selection of specific occurrences not supported"
        | None ->
        let evty = set_holes evdref cty subst in
        let _, instance = List.filter2 (fun b c -> b) filter instance in
        let evd,ev = new_evar_instance sign !evdref evty ~filter instance in
        evdref := evd;
        evsref := (fst (destEvar ev),evty)::!evsref;
        ev in
      set_holes evdref (apply_on_subterm set_var c rhs) subst
  | [] -> rhs in

  let subst = make_subst (ctxt,args,argoccs) in

  let evdref = ref evd in
  let rhs = set_holes evdref rhs subst in
  let evd = !evdref in

  (* We instantiate the evars of which the value is forced by typing *)
  let evd,rhs =
    try !solve_evars env_evar evd rhs
    with e when Pretype_errors.precatchable_exception e ->
      (* Could not revert all subterms *)
      raise Exit in

  let rec abstract_free_holes evd = function
  | (id,idty,c,_,evsref,_,_)::l ->
      let rec force_instantiation evd = function
      | (evk,evty)::evs ->
          let evd =
            if is_undefined evd evk then
              (* We force abstraction over this unconstrained occurrence *)
              (* and we use typing to propagate this instantiation *)
              (* This is an arbitrary choice *)
              let evd = Evd.define evk (mkVar id) evd in
              match evar_conv_x ts env_evar evd CUMUL idty evty with
              | UnifFailure _ -> error "Cannot find an instance"
              | Success evd ->
              match reconsider_conv_pbs (evar_conv_x ts) evd with
              | UnifFailure _ -> error "Cannot find an instance"
              | Success evd ->
              evd
            else
              evd
          in
          force_instantiation evd evs
      | [] ->
          abstract_free_holes evd l
      in
      force_instantiation evd !evsref
  | [] ->
      Evd.define evk rhs evd in

  abstract_free_holes evd subst, true
  with Exit -> evd, false

let second_order_matching_with_args ts env evd ev l t =
(*
  let evd,ev = evar_absorb_arguments env evd ev l in
  let argoccs = Array.map_to_list (fun _ -> None) (snd ev) in
  let evd, b = second_order_matching ts env evd ev argoccs t in
  if b then Success evd else
*)
  UnifFailure (evd, ConversionFailed (env,applist(mkEvar ev,l),t))

let apply_conversion_problem_heuristic ts env evd pbty t1 t2 =
  let t1 = apprec_nohdbeta ts env evd (whd_head_evar evd t1) in
  let t2 = apprec_nohdbeta ts env evd (whd_head_evar evd t2) in
  let (term1,l1 as appr1) = decompose_app t1 in
  let (term2,l2 as appr2) = decompose_app t2 in
  let app_empty = match l1, l2 with [], [] -> true | _ -> false in
  match kind_of_term term1, kind_of_term term2 with
  | Evar (evk1,args1), (Rel _|Var _) when app_empty
      && Array.for_all (fun a -> eq_constr a term2 || isEvar a) args1 ->
      (* The typical kind of constraint coming from pattern-matching return
         type inference *)
      (match choose_less_dependent_instance evk1 evd term2 args1 with
      | Some evd -> Success evd
      | None -> UnifFailure (evd, ConversionFailed (env,term1,term2)))
  | (Rel _|Var _), Evar (evk2,args2) when app_empty
      & Array.for_all (fun a -> eq_constr a term1 or isEvar a) args2 ->
      (* The typical kind of constraint coming from pattern-matching return
         type inference *)
      (match choose_less_dependent_instance evk2 evd term1 args2 with
      | Some evd -> Success evd
      | None -> UnifFailure (evd, ConversionFailed (env,term1,term2)))
  | Evar (evk1,args1), Evar (evk2,args2) when Int.equal evk1 evk2 ->
      let f env evd pbty x y = is_trans_fconv pbty ts env evd x y in
      Success (solve_refl ~can_drop:true f env evd evk1 args1 args2)
  | Evar ev1, Evar ev2 ->
      Success (solve_evar_evar ~force:true
        (evar_define (evar_conv_x ts)) (evar_conv_x ts) env evd ev1 ev2)
  | Evar ev1,_ when List.length l1 <= List.length l2 ->
      (* On "?n t1 .. tn = u u1 .. u(n+p)", try first-order unification *)
      (* and otherwise second-order matching *)
      ise_try evd
        [(fun evd -> first_order_unification ts env evd (ev1,l1) appr2);
         (fun evd ->
           second_order_matching_with_args ts env evd ev1 l1 (applist appr2))]
  | _,Evar ev2 when List.length l2 <= List.length l1 ->
      (* On "u u1 .. u(n+p) = ?n t1 .. tn", try first-order unification *)
      (* and otherwise second-order matching *)
      ise_try evd
        [(fun evd -> first_order_unification ts env evd (ev2,l2) appr1);
         (fun evd ->
           second_order_matching_with_args ts env evd ev2 l2 (applist appr1))]
  | Evar ev1,_ ->
      (* Try second-order pattern-matching *)
      second_order_matching_with_args ts env evd ev1 l1 (applist appr2)
  | _,Evar ev2 ->
      (* Try second-order pattern-matching *)
      second_order_matching_with_args ts env evd ev2 l2 (applist appr1)
  | _ ->
      (* Some head evar have been instantiated, or unknown kind of problem *)
      evar_conv_x ts env evd pbty t1 t2

let check_problems_are_solved env evd =
  match snd (extract_all_conv_pbs evd) with
  | (pbty,env,t1,t2)::_ -> Pretype_errors.error_cannot_unify env evd (t1, t2)
  | _ -> ()

let max_undefined_with_candidates evd =
  (* If evar were ordered with highest index first, fold_undefined
     would be going decreasingly and we could use fold_undefined to
     find the undefined evar of maximum index (alternatively,
     max_bindings from ocaml 3.12 could be used); instead we traverse
     the whole map *)
  let l = Evd.fold_undefined
    (fun evk ev_info evars ->
        match ev_info.evar_candidates with
        | None -> evars
        | Some l -> (evk,ev_info,l)::evars) evd [] in
  match l with
  | [] -> None
  | a::l -> Some (List.last (a::l))

let rec solve_unconstrained_evars_with_canditates evd =
  (* max_undefined is supposed to return the most recent, hence
     possibly most dependent evar *)
  match max_undefined_with_candidates evd with
  | None -> evd
  | Some (evk,ev_info,l) ->
      let rec aux = function
      | [] -> error "Unsolvable existential variables."
      | a::l ->
          try
            let conv_algo = evar_conv_x full_transparent_state in
            let evd = check_evar_instance evd evk a conv_algo in
            let evd = Evd.define evk a evd in
            match reconsider_conv_pbs conv_algo evd with
            | Success evd -> solve_unconstrained_evars_with_canditates evd
            | UnifFailure _ -> aux l
          with e when Pretype_errors.precatchable_exception e ->
            aux l in
      (* List.rev is there to favor most dependent solutions *)
      (* and favor progress when used with the refine tactics *)
      let evd = aux (List.rev l) in
      solve_unconstrained_evars_with_canditates evd

let solve_unconstrained_impossible_cases evd =
  Evd.fold_undefined (fun evk ev_info evd' ->
    match ev_info.evar_source with
    | _,Evar_kinds.ImpossibleCase -> Evd.define evk (j_type (coq_unit_judge ())) evd'
    | _ -> evd') evd evd

let consider_remaining_unif_problems ?(ts=full_transparent_state) env evd =
  let evd = solve_unconstrained_evars_with_canditates evd in
  let rec aux evd pbs progress stuck =
    match pbs with
    | (pbty,env,t1,t2 as pb) :: pbs ->
        (match apply_conversion_problem_heuristic ts env evd pbty t1 t2 with
	| Success evd' ->
	    let (evd', rest) = extract_all_conv_pbs evd' in
            begin match rest with
            | [] -> aux evd' pbs true stuck
            | _ -> (* Unification got actually stuck, postpone *)
	      aux evd pbs progress (pb :: stuck)
            end
        | UnifFailure (evd,reason) ->
	    Pretype_errors.error_cannot_unify env evd ~reason (t1, t2))
    | _ -> 
	if progress then aux evd stuck false []
	else 
	  match stuck with
	  | [] -> (* We're finished *) evd
	  | (pbty,env,t1,t2) :: _ ->
	      (* There remains stuck problems *)
	      Pretype_errors.error_cannot_unify env evd (t1, t2)
  in
  let (evd,pbs) = extract_all_conv_pbs evd in
  let heuristic_solved_evd = aux evd pbs false [] in
  check_problems_are_solved env heuristic_solved_evd;
  solve_unconstrained_impossible_cases heuristic_solved_evd

(* Main entry points *)

exception UnableToUnify of evar_map * unification_error

let the_conv_x ?(ts=full_transparent_state) env t1 t2 evd =
  match evar_conv_x ts env evd CONV  t1 t2 with
  | Success evd' -> evd'
  | UnifFailure (evd',e) -> raise (UnableToUnify (evd',e))

let the_conv_x_leq ?(ts=full_transparent_state) env t1 t2 evd =
  match evar_conv_x ts env evd CUMUL t1 t2 with
  | Success evd' -> evd'
  | UnifFailure (evd',e) -> raise (UnableToUnify (evd',e))

let e_conv ?(ts=full_transparent_state) env evdref t1 t2 =
  match evar_conv_x ts env !evdref CONV t1 t2 with
  | Success evd' -> evdref := evd'; true
  | _ -> false

let e_cumul ?(ts=full_transparent_state) env evdref t1 t2 =
  match evar_conv_x ts env !evdref CUMUL t1 t2 with
  | Success evd' -> evdref := evd'; true
  | _ -> false
