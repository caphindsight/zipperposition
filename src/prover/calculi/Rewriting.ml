
(* This file is free software, part of Zipperposition. See file "license" for more details. *)

(** {1 Rewriting} *)

open Logtk

module T = FOTerm
module RW = Rewrite

let section = RW.section

let stat_narrowing_lit = Util.mk_stat "narrow.lit_steps"
let stat_narrowing_term = Util.mk_stat "narrow.term_steps"

let prof_narrowing_term = Util.mk_profiler "narrow.term"
let prof_narrowing_lit = Util.mk_profiler "narrow.lit"

module Make(E : Env_intf.S) = struct
  module Env = E
  module C = E.C

  (* simplification rule *)
  let simpl_term t =
    let t', rules = RW.Term.normalize_term t in
    if T.equal t t' then (
      assert (RW.Term.Set.is_empty rules);
      None
    ) else (
      Util.debugf ~section 2
        "@[<2>@{<green>rewrite@} `@[%a@]`@ into `@[%a@]`@ :using %a@]"
        (fun k->k T.pp t T.pp t' RW.Term.Set.pp rules);
      Some t'
    )

  (* perform term narrowing in [c] *)
  let narrow_term_passive_ c: C.t list =
    let eligible = C.Eligible.(res c) in
    let sc_rule = 1 in
    let sc_c = 0 in
    Literals.fold_terms ~vars:false ~subterms:true ~ord:(C.Ctx.ord())
      ~which:`All ~eligible (C.lits c)
    |> Sequence.flat_map
      (fun (u_p, passive_pos) ->
         RW.Term.narrow_term ~scope_rules:sc_rule (u_p,sc_c)
         |> Sequence.map
           (fun (rule,subst) ->
              let i, lit_pos = Literals.Pos.cut passive_pos in
              let renaming = C.Ctx.renaming_clear() in
              (* side literals *)
              let lits_passive = C.lits c in
              let lits_passive =
                Literals.apply_subst ~renaming subst (lits_passive,sc_c) in
              let lits' = CCArray.except_idx lits_passive i in
              (* literal in which narrowing took place *)
              let rhs =
                Subst.FO.apply ~renaming subst (RW.Term.Rule.rhs rule, sc_rule) in
              let new_lit =
                Literal.Pos.replace lits_passive.(i) ~at:lit_pos
                  ~by:rhs in
              (* make new clause *)
              Util.incr_stat stat_narrowing_term;
              let proof =
                Proof.Step.inference [C.proof_parent c]
                  ~rule:(Proof.Rule.mk "narrow") in
              let c' =
                C.create ~trail:(C.trail c) ~penalty:(C.penalty c) (new_lit :: lits') proof
              in
              Util.debugf ~section 3
                "@[<2>term narrowing:@ from `@[%a@]`@ to `@[%a@]`@ \
                 using rule `%a`@ and subst @[%a@]@]"
                (fun k->k C.pp c C.pp c' RW.Term.Rule.pp rule Subst.pp subst);
              c'
           )
      )
    |> Sequence.to_rev_list

  let narrow_term_passive = Util.with_prof prof_narrowing_term narrow_term_passive_

  (* TODO: contextual extended narrowing *)

  (* XXX: for now, we only do one step, and let Env.multi_simplify
     manage the fixpoint *)
  let simpl_clause c =
    let lits = C.lits c in
    match RW.Lit.normalize_clause lits with
      | None -> None
      | Some clauses ->
        let proof =
          Proof.Step.simp ~rule:(Proof.Rule.mk "rw_clause")
            [C.proof_parent c] in
        let clauses =
          List.map
            (fun c' -> C.create_a ~trail:(C.trail c) ~penalty:(C.penalty c) c' proof)
            clauses
        in
        Util.debugf ~section 2
          "@[<2>@{<green>rewrite@} `@[%a@]`@ into `@[<v>%a@]`@]"
          (fun k->k C.pp c (Util.pp_list C.pp) clauses);
        Some clauses

  (* narrowing on literals of given clause, using lits rewrite rules *)
  let narrow_lits_ c =
    let eligible = C.Eligible.res c in
    let lits = C.lits c in
    Literals.fold_lits ~eligible lits
    |> Sequence.fold
      (fun acc (lit,i) ->
         RW.Lit.narrow_lit ~scope_rules:1 (lit,0)
         |> Sequence.fold
           (fun acc (rule,subst) ->
              let proof =
                Proof.Step.inference [C.proof_parent c]
                  ~rule:(Proof.Rule.mk "narrow_clause") in
              let lits' = CCArray.except_idx lits i in
              (* create new clauses that correspond to replacing [lit]
                 by [rule.rhs] *)
              let clauses =
                List.map
                  (fun c' ->
                     let renaming = E.Ctx.renaming_clear () in
                     let new_lits =
                       (Literal.apply_subst_list ~renaming subst (lits',0)) @
                         (Literal.apply_subst_list ~renaming subst (c',1))
                     in
                     C.create ~trail:(C.trail c) ~penalty:(C.penalty c) new_lits proof)
                  (RW.Lit.Rule.rhs rule)
              in
              Util.debugf ~section 3
                "@[<2>narrowing of `@[%a@]`@ using `@[%a@]`@ with @[%a@]@ yields @[%a@]@]"
                (fun k->k C.pp c RW.Lit.Rule.pp rule Subst.pp subst
                    CCFormat.(list (hovbox C.pp)) clauses);
              Util.incr_stat stat_narrowing_lit;
              List.rev_append clauses acc)
           acc)
      []

  let narrow_lits lits =
    Util.with_prof prof_narrowing_lit narrow_lits_ lits

  let setup ~has_rw () =
    Util.debug ~section 1 "register Rewriting to Env...";
    E.add_rewrite_rule "rewrite_defs" simpl_term;
    E.add_binary_inf "narrow_term_defs" narrow_term_passive;
    if has_rw then  E.Ctx.lost_completeness ();
    E.add_multi_simpl_rule simpl_clause;
    E.add_unary_inf "narrow_lit_defs" narrow_lits;
    ()
end

module Key = struct
  let has_rw = Flex_state.create_key()
end

let post_cnf stmts st =
  CCVector.iter Statement.scan_stmt_for_defined_cst stmts;
  (* check if there are rewrite rules *)
  let has_rw =
    CCVector.to_seq stmts
    |> Sequence.exists
      (fun st -> match Statement.view st with
         | Statement.RewriteForm _
         | Statement.RewriteTerm _
         | Statement.Def _ -> true
         | _ -> false)
  in
  st
  |> Flex_state.add Key.has_rw has_rw

(* add a term simplification that normalizes terms w.r.t the set of rules *)
let normalize_simpl (module E : Env_intf.S) =
  let module M = Make(E) in
  let has_rw = E.flex_get Key.has_rw in
  M.setup ~has_rw ()

let extension =
  let open Extensions in
  { default with
      name = "rewriting";
      post_cnf_actions=[post_cnf];
      env_actions=[normalize_simpl];
  }

