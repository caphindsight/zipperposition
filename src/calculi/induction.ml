
(*
Zipperposition: a functional superposition prover for prototyping
Copyright (c) 2013, Simon Cruanes
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

Redistributions of source code must retain the above copyright notice, this
list of conditions and the following disclaimer.  Redistributions in binary
form must reproduce the above copyright notice, this list of conditions and the
following disclaimer in the documentation and/or other materials provided with
the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE
FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER
CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,
OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
*)

(** {1 Induction Through QBF} *)

module Sym = Logtk.Symbol
module T = Logtk.FOTerm
module Ty = Logtk.Type
module Util = Logtk.Util
module Lits = Literals

module type S = sig
  module Env : Env.S
  module Ctx : module type of Env.Ctx

  val scan : Env.C.t Sequence.t -> unit
  val register : unit -> unit
end

let ind_types_ = ref []
let cover_set_depth_ = ref 1

let section = Util.Section.make ~parent:Const.section "ind"
let section_qbf = Util.Section.make
  ~parent:section ~inheriting:[BoolSolver.section; BBox.section] "qbf"

(* is [s] a constructor symbol for some inductive type? *)
let is_constructor_ s = match s with
  | Sym.Cst info ->
      let name = info.Sym.cs_name in
      List.exists (fun (_, cstors) -> List.mem name cstors) !ind_types_
  | _ -> false

module Make(E : Env.S)(Sup : Superposition.S)(Solver : BoolSolver.QBF) = struct
  module Env = E
  module Ctx = Env.Ctx

  module C = Env.C
  module CI = Ctx.Induction
  module CCtx = ClauseContext
  module BoolLit = Ctx.BoolLit
  module Avatar = Avatar.Make(E)(Solver)  (* will use some inferences *)

  (** Map that is subsumption-aware *)
  module FVMap(X : sig type t end) = struct
    module FV = Logtk.FeatureVector.Make(struct
      type t = Lits.t * X.t
      let cmp (l1,_)(l2,_) = Lits.compare l1 l2
      let to_lits (l,_) = Lits.Seq.abstract l
    end)

    type t = FV.t

    let empty () = FV.empty ()

    let add fv lits x = FV.add fv (lits,x)

    (*
    let remove fv lits = FV.remove fv lits
    *)

    let find fv lits =
      FV.retrieve_alpha_equiv fv (Lits.Seq.abstract lits) ()
        |> Sequence.map2 (fun _ x -> x)
        |> Sequence.filter_map
          (fun (lits', x) ->
            if Lits.are_variant lits lits'
              then Some x else None
          )
        |> Sequence.head

    (* find clauses in [fv] that are subsumed by [lits] *)
    let find_subsumed_by fv lits =
      FV.retrieve_subsumed fv (Lits.Seq.abstract lits) ()
        |> Sequence.map2 (fun _ x -> x)
        |> Sequence.filter
          (fun (lits', x) -> Sup.subsumes lits lits')

    let to_seq = FV.iter

    (*
    (* find clauses in [fv] that subsume [lits] *)
    let find_subsuming fv lits =
      FV.retrieve_subsuming fv (Lits.Seq.abstract lits) ()
        |> Sequence.map2 (fun _ x -> x)
        |> Sequence.filter
          (fun (lits', x) -> Sup.subsumes lits' lits)
    *)
  end

  let level1_ = Solver.push Qbf.Forall []
  let level2_ = Solver.push Qbf.Exists []

  (* a candidate clause context *)
  type candidate_context = {
    cand_ctx : CCtx.t; (* the ctx itself *)
    cand_cst : T.t;    (* the inductive constant *)
    cand_lits : Lits.t; (* literals of [ctx[t]] *)
    mutable cand_initialized : bool; (* is [ctx[i]] proved yet? *)
  }

  (* if true, ignore clause when it comes to extracting contexts *)
  let flag_no_ctx = C.new_flag ()

  (** {6 Proof Relation} *)

  module CompactClauseSet = Sequence.Set.Make(CompactClause)

  (* one way to prove a clause: set of parent clauses
  type proof = CompactClauseSet.t
  *)

  (* given a proof (a set of parent clauses) extract the corresponding trail *)
  let trail_of_proof set =
    CompactClauseSet.fold
      (fun cc acc ->
        let trail = CompactClause.trail cc in
        List.fold_left
          (fun acc (sign, `Box_clause lits) ->
            BoolLit.set_sign sign (BoolLit.inject_lits lits) :: acc
          ) acc trail
      ) set []

  module ProofSet = Sequence.Set.Make(CompactClauseSet)

  (* a set of proofs *)
  type proof_set = {
    mutable proofs : ProofSet.t;
  }

  module FV_proofs = FVMap(struct
    type t = proof_set  (* lits -> set of proofs of those literals *)
  end)

  module FV_watch = FVMap(struct
    type t = [ `Inductive_cst of candidate_context | `Sub_cst ] list ref
    (* watched literals (as [lits]) ->
        set of either:
          - `Inductive ctx, a candidate_ctx
              such that [ctx.cand_lits[ctx.cand_cst] = lits]
          - `Sub_cst, we watch for proofs but have nothing else to do *)
  end)

  (* maps clauses to a list of their known proofs *)
  let proofs_ = ref (FV_proofs.empty ())

  (* find all known proofs of the given lits *)
  let find_proofs_ lits = FV_proofs.find !proofs_ lits

  (* clauses that we check for subsumption. If they are subsumed by
    some clause, we add an explicit proof *)
  let to_watch_ = ref (FV_watch.empty())

  (* clauses that were just added to {!to_watch_} *)
  let to_watch_new_ = ref (FV_watch.empty())

  (* signal to trigger whenever a new clause should be watched *)
  let on_new_to_watch = Signal.create ()

  (* from now on, we are interested in proofs of this clause *)
  let watch_proofs_of_clause lits elt =
    match FV_watch.find !to_watch_ lits with
    | Some l -> CCList.Ref.push l elt
    | None ->
        to_watch_new_ := FV_watch.add !to_watch_new_ lits (ref [elt]);
        Signal.send on_new_to_watch lits

  exception NonClausalProof
  (* raised when a proof doesn't use only clauses (also formulas...) *)

  (* add a proof to the set of proofs for [lits] *)
  let add_proof_ lits p =
    try
      let parents = Array.to_list p.Proof.parents in
      let parents = List.map
        (fun p -> match p.Proof.result with
          | Proof.Form _ -> raise NonClausalProof
          | Proof.Clause lits -> lits
        ) parents
      in
      let parents = CompactClauseSet.of_list parents in
      (* all proofs of [lits] *)
      let set = match find_proofs_ lits with
        | None ->
            let set = {proofs=ProofSet.empty} in
            proofs_ := FV_proofs.add !proofs_ lits set;
            set
        | Some set -> set
      in
      set.proofs <- ProofSet.add parents set.proofs;
      Util.debug ~section 4 "add proof: %a" Proof.pp_notrec p;
    with NonClausalProof ->
      ()  (* ignore the proof *)

  let () =
    Signal.on C.on_proof
      (fun (lits, p) ->
        add_proof_ lits p;
        Signal.ContinueListening
      );
    ()

  (** {6 Split on Inductive Constants} *)

  (* true if [t = c] where [c] is some inductive constructor *)
  let is_a_constructor_ t = match T.Classic.view t with
    | T.Classic.App (s, _, _) ->
        Sequence.exists (Sym.eq s) CI.Seq.constructors
    | _ -> false

  (* scan clauses for ground terms of an inductive type, and declare those terms *)
  let scan seq =
    Sequence.iter
      (fun c ->
        Lits.Seq.terms (Env.C.lits c)
        |> Sequence.flat_map T.Seq.subterms
        |> Sequence.filter
          (fun t ->
            T.is_ground t
            && T.is_const t  (* TODO: terms such as allow nil(alpha) *)
            && not (CI.is_blocked t)
            && CI.is_inductive_type (T.ty t)
            && not (is_a_constructor_ t)   (* 0 and nil: not inductive const *)
          )
        |> Sequence.iter (fun t -> CI.declare t)
      ) seq

  (* boolean xor *)
  let mk_xor_ l =
    let at_least_one = l in
    let at_most_one =
      CCList.diagonal l
        |> List.map (fun (l1,l2) -> [BoolLit.neg l1; BoolLit.neg l2])
    in
    at_least_one :: at_most_one

  (* TODO: observe new cover sets, to split clauses again *)

  (* detect ground terms of an inductive type, and perform a special
      case split with Xor on them. *)
  let case_split_ind c =
    let res = ref [] in
    (* first scan for new inductive consts *)
    scan (Sequence.singleton c);
    Lits.Seq.terms (Env.C.lits c)
      |> Sequence.flat_map T.Seq.subterms
      |> Sequence.filter CI.is_inductive
      |> Sequence.iter
        (fun t ->
          match CI.cover_set ~depth:!cover_set_depth_ t with
          | _, `Old -> ()
          | set, `New ->
              (* Make a case split on the cover set (one clause per literal) *)
              Util.debug ~section 2 "make a case split on inductive %a" T.pp t;
              let clauses_and_lits = List.map
                (fun t' ->
                  assert (T.is_ground t');
                  let lits = [| Literal.mk_eq t t' |] in
                  let bool_lit = BoolLit.inject_lits lits in
                  let proof cc = Proof.mk_c_trivial ~theories:["induction"] cc in
                  let trail = C.Trail.of_list [bool_lit] in
                  let clause = C.create_a ~trail lits proof in
                  C.set_flag flag_no_ctx clause true; (* no context from split *)
                  clause, bool_lit
                ) set.CI.cases
              in
              let clauses, bool_lits = List.split clauses_and_lits in
              (* add a boolean constraint: Xor of boolean lits *)
              Solver.add_clauses (mk_xor_ bool_lits);
              (* return clauses *)
              Util.debug ~section 4 "split inference for %a: %a"
                T.pp t (CCList.pp C.pp) clauses;
              res := List.rev_append clauses !res
        );
    !res

  (** {6 Clause Contexts}

  at any point, we have a set of clause contexts "of interest", that is,
  that might be used for induction. For any context [c], inductive [i]
  with subcases [t_1,...,t_n], we watch proofs of [c[i]], [c[t_1]], ... [c[t_n]].
  If [c[i]] has a proof, then [c] will be candidate for induction in
  the QBF formula.
  *)

  module FV_cand = FVMap(struct
    type t = candidate_context
  end)

  type candidate_context_set = FV_cand.t ref

  (* maps each inductive constant to
      set(clause contexts that are candidate for induction on this constant) *)
  let candidates_ : candidate_context_set T.Tbl.t = T.Tbl.create 255

  (* candidates for a term *)
  let find_candidates_ t =
    try T.Tbl.find candidates_ t
    with Not_found ->
      let set = ref (FV_cand.empty ()) in
      T.Tbl.add candidates_ t set;
      set

  let on_new_context =
    let s = Signal.create () in
    Signal.on s (fun ctx ->
      (* new context: watch proofs of ctx[i]
        and ctx[t] for all [t] that is a sub-constant of [i] *)
      watch_proofs_of_clause ctx.cand_lits (`Inductive_cst ctx);
      Util.debug ~section 2 "watch %a (initialization, %a)"
        Lits.pp ctx.cand_lits T.pp ctx.cand_cst;
      CI.cover_sets ctx.cand_cst
        |> Sequence.flat_map (fun set -> T.Set.to_seq set.CI.sub_constants)
        |> Sequence.iter
          (fun t ->
            let c = CCtx.apply ctx.cand_ctx t in
            Util.debug ~section 2 "watch %a (sub-cst %a)" Lits.pp c T.pp t;
            watch_proofs_of_clause c `Sub_cst
          );
      Signal.ContinueListening
    );
    s

  (* set of subterms of [lits] that could be extruded to form a context.
   TODO: stronger restrictions? for instance:
     - if clause contains several distinct terms of same inductive type, ignore
     - if [t] is a sub_cst and its constant also occurs in [lits] (similar),
        should we extrude context?
        e.g.  in [n = s(n')] no need to extract n' nor n *)
  let subterms_candidates_for_context_ lits =
    Lits.Seq.terms lits
      |> Sequence.flat_map T.Seq.subterms
      |> Sequence.filter
        (fun t -> CI.is_inductive t || CI.is_sub_constant t)
      |> T.Seq.add_set T.Set.empty

  (* ctx [c] is now initialized. Return [true] if it wasn't initialized before *)
  let cand_ctx_initialized_ c =
    let is_new = not c.cand_initialized in
    if is_new then (
      c.cand_initialized <- true;
      Util.debug ~section 2 "clause context %a[%a] now initialized"
        CCtx.pp c.cand_ctx T.pp c.cand_cst;
    );
    is_new

  (* see whether (ctx,t) is of interest. *)
  let process_ctx_ c ctx t =
    (* if [t] is an inductive constant, ctx is enabled! *)
    if CI.is_inductive t
      then (
        let set = find_candidates_ t in
        match FV_cand.find !set (C.lits c) with
          | None ->
              let ctx = {
                cand_initialized=true;
                cand_ctx=ctx;
                cand_cst=t;
                cand_lits=C.lits c;
              } in
              Util.debug ~section 2 "new (initialized) context for %a: %a"
                T.pp t CCtx.pp ctx.cand_ctx;
              set := FV_cand.add !set (C.lits c) ctx;
              Signal.send on_new_context ctx;
              None
          | Some ctx ->
              let is_new = cand_ctx_initialized_ ctx in (* we just proved ctx[t] *)
              if is_new
                then Some c (* context initialized; we can assume it *)
                else None
              (* TODO: is this necessary? we should just watch for proofs anyway *)
      ) else
        (* [t] is a subterm of the case [t'] of an inductive [cst] *)
        let cst, t' = CI.inductive_cst_of_sub_cst t in
        let set = find_candidates_ cst in
        let lits' = CCtx.apply ctx cst in
        match FV_cand.find !set lits' with
          | None ->
              let cand_ctx = {
                cand_initialized=false;
                cand_ctx=ctx;
                cand_cst=cst;
                cand_lits=lits'; (* ctx[cst] *)
              } in
              (* need to watch ctx[cst] until it is proved *)
              Util.debug ~section 2 "new context %a" CCtx.pp ctx;
              Signal.send on_new_context cand_ctx;
              set := FV_cand.add !set lits' cand_ctx;
              None
          | Some _ ->
              None  (* no new context *)

  (* search whether given clause [c] contains some "interesting" occurrences
     of an inductive  term. This is pretty much the main heuristic. *)
  let scan_given_for_context c =
    if C.get_flag flag_no_ctx c then [] else (
    let terms = subterms_candidates_for_context_ (C.lits c) in
    T.Set.fold
      (fun t acc ->
        (* extract a context [c = ctx[t]] *)
        let lits = C.lits c in
        let ctx = CCtx.extract_exn lits t in
        match process_ctx_ c ctx t with
          | None -> acc
          | Some c -> c :: acc
      ) terms []
    )

  (* [c] (same as [lits] subsumes [lits'] which is watched with list
    of contexts [l] *)
  let _process_clause_match_watched acc c lits lits' l =
    (* remember proof *)
    let proof cc = Proof.mk_c_inference ~rule:"subsumes" cc [C.proof c] in
    let proof' = proof (CompactClause.make lits' (C.get_trail c |> C.compact_trail)) in
    add_proof_ lits' proof';
    Util.debug ~section 2 "add proof of watched %a because of %a" Lits.pp lits' C.pp c;
    (* check whether that makes some cand_ctx initialized *)
    List.fold_left
      (fun acc elt -> match elt with
        | `Sub_cst -> acc  (* sub-constant, no initialization *)
        | `Inductive_cst cand_ctx ->
            (* [c] proves the initialization of [cand_ctx], i.e. the
              clause context applied to the corresponding
              inductive constant (rather than a sub-case) *)
            assert (CI.is_inductive cand_ctx.cand_cst);
            let is_new = cand_ctx_initialized_ cand_ctx in
            if is_new then (
              (* ctx[t] is now proved, deduce ctx[t] and add it to set of clauses *)
              let clause = C.create_a ~parents:[c]
                ~trail:(C.get_trail c) lits proof in
              (* disable subsumption for [clause] *)
              C.set_flag C.flag_persistent clause true;
              Util.debug ~section 2 "initialized %a by subsumption from %a"
                C.pp clause C.pp c;
              clause :: acc
            ) else acc
      ) acc !l

  (* search whether [c] subsumes some watched clause
     if [C[i]] subsumed, where [i] is an inductive constant:
      - "infer" the clause [C[i]]
      - monitor for [C[i']] for every [i'] sub-case of [i]
        - if such [C[i']] is detected, add its proof relation to QBF. Will
          be checked by avatar.check_satisfiability. Watch for proofs
          of [C[i']], they could evolve!! *)
  let scan_given_for_proof c =
    let lits = C.lits c in
    if Array.length lits = 0
    then [] (* proofs from [false] aren't interesting *)
    else FV_watch.find_subsumed_by !to_watch_ lits
      |> Sequence.fold
        (fun acc (lits', l) ->
          _process_clause_match_watched acc c lits lits' l
        ) []

  (* scan the set of active clauses, to see whether it proves some
      of the lits in [to_watch_new_] *)
  let scan_backward () =
    let w = !to_watch_new_ in
    to_watch_new_ := FV_watch.empty ();
    Env.ProofState.ActiveSet.clauses ()
      |> C.CSet.to_seq
      |> Sequence.filter (fun c -> Array.length (C.lits c) > 0)
      |> Sequence.fold
        (fun acc c ->
          let lits = C.lits c in
          FV_watch.find_subsumed_by w lits
            |> Sequence.fold
              (fun acc (lits',l) ->
                _process_clause_match_watched acc c lits lits' l
              ) acc
        ) []

  (** {6 Encoding to QBF} *)

  let neg_ = BoolLit.neg
  let valid_ x = BoolLit.inject_name' "valid(%a)" T.pp x
  let cases_ x = BoolLit.inject_name' "cases(%a)" T.pp x
  let pgraph_ x = BoolLit.inject_name' "proofgraph(%a)" T.pp x
  let empty_ x = BoolLit.inject_name' "empty(%a)" T.pp x
  let loop_ x = BoolLit.inject_name' "loop(%a)" T.pp x
  let base_ x = BoolLit.inject_name' "base(%a)" T.pp x
  let recf_ x = BoolLit.inject_name' "recf(%a)" T.pp x
  let init_ x = BoolLit.inject_name' "init(%a)" T.pp x
  let recf_term_ t = BoolLit.inject_name' "recf_term(%a)" T.pp t
  let recf_sub_term_ t = BoolLit.inject_name' "recf_subterm(%a)" T.pp t

  let is_true_ lits = BoolLit.inject_lits lits
  let trail_ok_ lits = BoolLit.inject_lits_pred lits BoolLit.TrailOk
  let provable_ lits cst = BoolLit.inject_lits_pred lits (BoolLit.Provable cst)
  let provable_sub_ lits t = BoolLit.inject_lits_pred lits (BoolLit.ProvableForSubConstant t)
  let in_loop_ ctx i = BoolLit.inject_ctx ctx i BoolLit.InLoop

  (* encode proof relation into QBF, starting from the set of "roots"
      that are (applications of) clause contexts + false.

      Plan:
        incremental:
          case splits
          bigAnd i:inductive_cst:
            def of [cases(i)]
            (path_constraint(i) => valid(i))
            valid(i) = [cases(i)] & (not [proofgraph] | [empty(i)] | not [loop(i)])
        backtrackable:
          (bigAnd_coversets(i) (bigXOr_{t in coverset(i)} i=t)) => [valid(i)]
          constraints of proofgraph => [proofgraph]
          bigAnd i:inductive_cst:
            def of loop(i) => [loop(i)]
            empty(i) => def of empty(i)
        *)

  (* current save level *)
  let save_level_ = ref Solver.root_save_level

  (* add
    - pathconditions(i) => [valid(i)]
    - valid(i) => [cases(i)] &
    - (not [proofgraph] | [empty(i)] | not [loop(i)]) *)
  let qbf_encode_valid_ cst =
    let pc = CI.pc cst in
    Solver.add_clauses
      [ valid_ cst :: List.map (fun pc -> neg_ pc.CI.pc_lit) pc (* pc -> valid *)
      ; [ neg_ (valid_ cst); cases_ cst ]
      ; [ neg_ (valid_ cst); neg_ (pgraph_ cst); empty_ cst; neg_ (loop_ cst) ]
      ];
    ()

  (* encode (init(i) & base(i) & recf(i)) => loop(i) *)
  let qbf_encode_loop_ cst =
    Solver.quantify_lits level2_ [init_ cst; base_ cst; recf_ cst; loop_ cst];
    Solver.add_clause
      [ neg_ (init_ cst); neg_ (base_ cst); neg_ (recf_ cst); loop_ (cst) ]

  (* - for each candidate ctx C,
        for each proof p in proofs(C[cst]), add:
        "trail(p) & candidate(ctx) => trail_ok_(C[cst])"
     - add "(bigand_{candidate ctx C} trail_ok(C[cst])) => init(cst)"
  *)
  let qbf_encode_init_ cst =
    let candidates = !(find_candidates_ cst)
      |> FV_cand.to_seq |> Sequence.map snd in
    let trail_ok_clauses =
      candidates
      |> Sequence.flat_map
        (fun ctx ->
          (* proof of [ctx[cst]] *)
          let proofs = match find_proofs_ ctx.cand_lits with
            | None -> Sequence.empty
            | Some {proofs} -> ProofSet.to_seq proofs
          in
          let trails = Sequence.map trail_of_proof proofs in
          Sequence.map
            (fun lits -> trail_ok_ ctx.cand_lits :: List.map neg_ lits)
            trails
        )
      |> Sequence.to_rev_list
    and init_clause =
      let guard = Sequence.map
        (fun ctx -> neg_ (trail_ok_ ctx.cand_lits)
        ) candidates
      in
      init_ cst :: Sequence.to_rev_list guard
    in
    Solver.add_clauses (init_clause :: trail_ok_clauses)

  (* definition of base(cst) *)
  let qbf_encode_base_ cst =
    let base_cases = CI.cover_sets cst
      |> Sequence.map (fun set -> set.CI.base_cases)
    in
    match find_proofs_ [| |] with
    | None -> ()
    | Some proofs_of_empty ->
        (* for each proof "p" of false:
           for each coverset "set" of cst:
            (bigand_{"t" a base case in "set"} not (t=cst)) => base(cst)
        *)
        let clauses = base_cases
          |> Sequence.map
            (fun base_cases ->
              let guard = List.map
                (fun t -> is_true_ [| Literal.mk_eq t cst |])
                base_cases
              in
              base_ cst :: guard
            )
          |> Sequence.to_rev_list
        in
        Solver.add_clauses clauses

  (* encode recf(cst), that is:
      for each coverset "set" of cst:
      ( bigand_{"t" a recursive case of "set"}
        (t=cst) =>
          bigor_{"t'" strict subterm of "t" of same type}
            bigand_{C in candidates(cst)} ([C in loop(cst)] => provable(C,cst))
      ) => recf(cst)
  *)
  let qbf_encode_recf_ cst =
    let candidates = !(find_candidates_ cst) |> FV_cand.to_seq |> Sequence.map snd in
    (* (bigand_{t recursive case} recf_term(t)) => recf(cst)  *)
    let clauses_per_set = CI.cover_sets cst
      |> Sequence.map (fun set -> set.CI.rec_cases)
      |> Sequence.map
        (fun rec_cases ->
          recf_ cst ::
          List.map
            (fun t ->
              Solver.quantify_lits level2_ [recf_term_ t];
              neg_ (recf_term_ t)
            ) rec_cases
        )
    and clauses_per_term = CI.cover_sets cst
      |> Sequence.flat_map (fun set -> set.CI.sub_constants |> T.Set.to_seq)
      |> Sequence.map
        (fun t' ->
          let _cst', t = CI.inductive_cst_of_sub_cst t' in
          assert (T.eq cst _cst');
          (* for every t' subterm of t:
             recf_subterm(t') => recf_term(t) *)
          Solver.quantify_lits level2_ [recf_sub_term_ t'];
          [neg_ (recf_sub_term_ t'); recf_term_ t]
        )
    and clauses_per_subterm = CI.cover_sets cst
      |> Sequence.flat_map (fun set -> T.Set.to_seq set.CI.sub_constants)
      |> Sequence.flat_map
        (fun t' ->
          let _, t = CI.inductive_cst_of_sub_cst t' in
          (* for every subterm t' of an inductive case of cst:
                (t=cst &
                  bigand_{C in candidates(cst)} provable_aux(C[t'], cst)
                ) => recf_sub_term(t')
          *)
          let guard_big_and =
            candidates
            |> Sequence.map
              (fun ctx ->
                let ctx_at_t' = ClauseContext.apply ctx.cand_ctx t' in
                neg_ (provable_ ctx_at_t' cst)
              )
            |> Sequence.to_rev_list
          in
          let clause1 =
            recf_sub_term_ t' ::
            neg_ (is_true_ [| Literal.mk_eq t cst |]) ::
            guard_big_and
          in
          (* for every C in candidates(Cst):
               ([C in loop(cst)] => provable(C[t'],cst)]) => provable_aux(C[t'],cst)
          *)
          let per_clause =
            candidates
            |> Sequence.flat_map
              (fun ctx ->
                let ctx_at_t' = ClauseContext.apply ctx.cand_ctx t' in
                let provable_aux = provable_sub_ ctx_at_t' t' in
                [ [ in_loop_ ctx.cand_ctx cst; provable_aux ]
                ; [ neg_ (provable_ ctx_at_t' cst); provable_aux ]
                ] |> Sequence.of_list
              )
          in
          Sequence.cons clause1 per_clause
        )
    in
    let all_clauses = Sequence.of_list
      [ clauses_per_set
      ; clauses_per_term
      ; clauses_per_subterm
      ]
    in
    Solver.add_clause_seq (Sequence.concat all_clauses);
    ()

  (* definition of empty(cst):
    not (empty loop(cst)) => bigor_{C in candidates(cst)} [C in loop(cst)] *)
  let qbf_encode_empty_ cst =
    let clause = !(find_candidates_ cst)
      |> FV_cand.to_seq
      |> Sequence.map snd
      |> Sequence.map
        (fun ctx ->
          let inloop = in_loop_ ctx.cand_ctx cst in
          Solver.quantify_lits level1_ [inloop];
          inloop
        )
      |> Sequence.to_rev_list
    in
    let clause = neg_ (empty_ cst) :: clause in
    Solver.add_clause clause;
    ()

  module LitsTbl = Hashtbl.Make(struct
    type t = Lits.t
    let equal = Lits.eq
    let hash = Lits.hash
  end)

  (* [lits] is pure iff it contains no inductive type. Its provability
      status w.r.t some inductive constant is [true] (trail notwithstanding) *)
  let pure_lits_ lits =
    let impure = Lits.Seq.terms lits
      |> Sequence.exists CI.contains_inductive_types
    in
    not impure

  (* table from sets of compact clauses to 'a *)
  module CompactClauseSetTbl = Hashtbl.Make(struct
    type t = CompactClauseSet.t
    let equal = CompactClauseSet.equal
    let hash_fun set h =
      let seq = CompactClauseSet.to_seq set in
      CCHash.seq CompactClause.hash_fun seq h
    let hash set = CCHash.apply hash_fun set
  end)

  (* encode the proofgraph of this constant, with literals [loop(cst) |- C]
      and [C[<>] in loop(cst)] *)
  let qbf_encode_proofgraph_of_ cst =
    let sets = CI.cover_sets cst in
    (* already encoded proofs *)
    let tbl = LitsTbl.create 128 in
    (* bool lit that encode the fact that a proof is true *)
    let proof_is_true_ =
      let blit_of_proof_tbl = CompactClauseSetTbl.create 128 in
      let count = ref 0 in
      fun proof ->
        try CompactClauseSetTbl.find blit_of_proof_tbl proof
        with Not_found ->
          let blit = BoolLit.inject_name' "is_true(%d,%a)" !count T.pp cst in
          Solver.quantify_lits level2_ [blit];
          CompactClauseSetTbl.add blit_of_proof_tbl proof blit;
          incr count;
          blit
    in
    (* queue of nodes of the proof graph (1 node = array of lits) to explore *)
    let q = Queue.create () in
    !(find_candidates_ cst)
      |> FV_cand.to_seq
      |> Sequence.map snd
      |> Sequence.iter
        (fun cand ->
          (* encode proof of [ctx[cst]]: It's
              provable(ctx[cst]) => [ctx in loop(cst)]
          *)
          assert (not (LitsTbl.mem tbl cand.cand_lits));
          LitsTbl.add tbl cand.cand_lits ();
          Solver.quantify_lits level2_
            [provable_ cand.cand_lits cst; in_loop_ cand.cand_ctx cst];
          Solver.add_clause [ neg_ (provable_ cand.cand_lits cst)
                            ; in_loop_ cand.cand_ctx cst];
          (* explore all sub-cases of this candidate context *)
          sets
          |> Sequence.flat_map
            (fun set ->
              set.CI.sub_constants
              |> T.Set.to_seq
            )
          |> Sequence.iter
            (fun t' ->
              (* we encode the proof graph "above" [ctx[t']] *)
              let lits = ClauseContext.apply cand.cand_ctx t' in
              Queue.push lits q;
            )
        );
    (* breadth first traversal, from leaves [ctx[t']] where ctx is a
      candidate context and t' an inductive sub-constant of
      a recursive case of  [cst] *)
    while not (Queue.is_empty q) do
      let lits = Queue.pop q in
      if not (LitsTbl.mem tbl lits) then (
        LitsTbl.add tbl lits ();
        Solver.quantify_lits level2_ [provable_ lits cst];
        match find_proofs_ lits  with
        | None ->
            (* not provable *)
            Solver.add_clause [neg_ (provable_ lits cst)]
        | Some {proofs;_} ->
            (* add provable(lits) => bigor_{p proof of lits} true_proof(p) *)
            let c1 = ProofSet.fold
              (fun proof l -> proof_is_true_ proof :: l)
              proofs [neg_ (provable_ lits cst)]
            in
            Solver.add_clause c1;
            (* define proofs:
                  for p proof with premises [lits_1, lits_2, ..., lits_n]
                  and trail [Gamma] add:
                    true_proof(p) => bigand_i provable(lits_i) & Gamma
                or: true_proof(p) => Gamma if pure(lits) *)
            ProofSet.iter
              (fun proof ->
                let trail = trail_of_proof proof |> Sequence.of_list in
                let sub_obligations =
                  if pure_lits_ lits
                    then Sequence.empty
                    else CompactClauseSet.to_seq proof
                      |> Sequence.map
                        (fun cc -> provable_ (CompactClause.lits cc) cst)
                in
                let goals = Sequence.append sub_obligations trail in
                (* "proof is true" implies "lit" is true *)
                let clauses = Sequence.map
                  (fun lit -> [neg_ (proof_is_true_ proof); lit])
                  goals
                in
                Solver.add_clause_seq clauses
              ) proofs
      )
    done;
    ()

  (* encode the whole proofgraph for every inductive constant. *)
  let qbf_encode_proofgraph_ () =
    CI.Seq.cst
      |> Sequence.iter qbf_encode_proofgraph_of_

  (* encode: cases(i) => bigAnd_{s in coversets(i) (xor_{t in s} i=t} *)
  let qbf_encode_cover_set cst set =
    let big_xor =
      mk_xor_
        (List.map
          (fun t -> is_true_ [|Literal.mk_eq cst t|])
          set.CI.cases
        )
    in
    (* guard every clause with "cases(i) => clause" *)
    let clauses = List.map (fun c -> neg_ (cases_ cst) :: c) big_xor in
    Solver.add_clauses clauses;
    ()

  (* the whole process of:
      - adding non-backtracking constraints
      - save state
      - adding backtrackable constraints *)
  let qbf_encode_enter_ () =
    (* normal constraints should be added already *)
    Util.debug ~section:section_qbf 4 "save QBF solver...";
    save_level_ := Solver.save ();
    CI.Seq.cst |> Sequence.iter qbf_encode_init_;
    CI.Seq.cst |> Sequence.iter qbf_encode_recf_;
    CI.Seq.cst |> Sequence.iter qbf_encode_base_;
    CI.Seq.cst |> Sequence.iter qbf_encode_empty_;
    qbf_encode_proofgraph_ ();
    ()

  (* restoring state *)
  let qbf_encode_exit_ () =
    Util.debug ~section:section_qbf 4 "...restore QBF solver";
    Solver.restore !save_level_;
    ()

  (* add/remove constraints before/after satisfiability checking *)
  let () =
    Signal.on Avatar.before_check_sat
      (fun () -> qbf_encode_enter_ (); Signal.ContinueListening);
    Signal.on Avatar.after_check_sat
      (fun () -> qbf_encode_exit_ (); Signal.ContinueListening);
    Signal.on CI.on_new_inductive
      (fun cst ->
        qbf_encode_valid_ cst;
        qbf_encode_loop_ cst;
        Signal.ContinueListening
      );
    Signal.on CI.on_new_cover_set
      (fun (cst, set) ->
        qbf_encode_cover_set cst set;
        Signal.ContinueListening
      );
    ()

  (** {6 Registration} *)

  (* declare a list of inductive types *)
  let declare_types_ l =
    List.iter
      (fun (ty,cstors) ->
        (* TODO: support polymorphic types? *)
        let pattern = Ty.const (Sym.of_string ty) in
        let constructors = List.map
          (fun str ->
            let s = Sym.of_string str in
            match Ctx.find_signature s with
              | None ->
                  let msg = Util.sprintf
                    "cannot find the type of inductive constructor %s" str
                  in failwith msg
              | Some ty ->
                  s, ty
          ) cstors
        in
        (* declare type. *)
        ignore (CI.declare_ty pattern constructors);
        Util.debug ~section 1 "declare inductive type %a" Ty.pp pattern;
        ()
      ) l

  (* ensure s1 > s2 if s1 is an inductive constant and s2 is a sub-case of s1 *)
  let constr_sub_cst_ s1 s2 =
    let module C = Logtk.Comparison in
    let res =
      if CI.is_inductive_symbol s1 && CI.dominates s1 s2
        then C.Gt
      else if CI.is_inductive_symbol s2 && CI.dominates s2 s1
        then C.Lt
      else C.Incomparable
    in res

  let register() =
    Util.debug ~section 1 "register induction calculus";
    declare_types_ !ind_types_;
    Solver.set_printer BoolLit.print;
    Ctx.add_constr 20 constr_sub_cst_;  (* enforce new constraint *)
    (* avatar rules *)
    Env.add_multi_simpl_rule Avatar.split;
    Env.add_unary_inf "avatar.check_empty" Avatar.check_empty;
    Env.add_generate "avatar.check_sat" Avatar.check_satisfiability;
    (* induction rules *)
    Env.add_generate "induction.scan_backward" scan_backward;
    Env.add_unary_inf "induction.scan_extrude" scan_given_for_context;
    Env.add_unary_inf "induction.scan_proof" scan_given_for_proof;
    (* XXX: ugly, but we must do case_split before scan_extrude/proof.
      Currently we depend on Env.generate_unary applying inferences in
      the reverse order of their addition *)
    Env.add_unary_inf "induction.case_split" case_split_ind;
    ()
end

let extension =
  let action env =
    let module E = (val env : Env.S) in
    let sup = Mixtbl.find ~inj:Superposition.key E.mixtbl "superposition" in
    let module Sup = (val sup : Superposition.S) in
    let module Solver = (val BoolSolver.get_qbf() : BoolSolver.QBF) in
    Util.debug ~section:section_qbf 2 "created QBF solver \"%s\"" Solver.name;
    let module A = Make(E)(Sup)(Solver) in
    A.register()
  (* add an ordering constraint: ensure that constructors are smaller
    than other terms *)
  and add_constr penv =
    let module C = Logtk.Comparison in
    let constr_cstor s1 s2 = match is_constructor_ s1, is_constructor_ s2 with
      | true, true
      | false, false -> if Sym.eq s1 s2 then C.Eq else C.Incomparable
      | true, false -> C.Lt
      | false, true -> C.Gt
    in
    PEnv.add_constr ~penv 15 constr_cstor
  in
  Extensions.({default with
    name="induction";
    actions=[Do action];
    penv_actions=[Penv_do add_constr];
  })

let enabled_ = ref false
let enable_ () =
  if not !enabled_ then (
    enabled_ := true;
    Util.debug ~section 1 "Induction: requires ord=rpo6; select=NoSelection";
    Params.ord := "rpo6";   (* new default! RPO is necessary*)
    Params.select := "NoSelection";
    Extensions.register extension
  )

(* [str] describes an inductive type, under the form "foo:c1|c2|c3" where
    "foo" is the type name and "c1", "c2", "c3" are the type constructors. *)
let add_ind_type_ str =
  enable_();
  let _fail() =
    failwith "expected \"type:c1|c2|c3\" where c1,... are constructors"
  in
  match Util.str_split ~by:":" str with
  | [ty; cstors] ->
      let cstors = Util.str_split ~by:"|" cstors in
      if List.length cstors < 2 then _fail();
      (* remember to declare this type as inductive *)
      Util.debug ~section 2 "user declares inductive type %s = %a"
        ty (CCList.pp CCString.pp) cstors;
      ind_types_ := (ty, cstors) :: !ind_types_
  | _ -> _fail()

let () =
  Params.add_opts
    [ "-induction", Arg.String add_ind_type_, " enable Induction on the given type"
    ; "-induction-depth", Arg.Set_int cover_set_depth_, " set default induction depth"
    ]
