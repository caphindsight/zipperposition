(*
Zipperposition: a functional superposition prover for prototyping
Copyright (C) 2012 Simon Cruanes

This is free software; you can redistribute it and/or
modify it under the terms of the GNU General Public License
as published by the Free Software Foundation; either version 2
of the License, or (at your option) any later version.

This is distributed in the hope that it will be useful,
but WITHOUT ANY WARRANTY; without even the implied warranty of
MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
GNU General Public License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software
Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA
02110-1301 USA.
*)

(** {1 The state of a proof, contains a set of active clauses (processed),
    a set of passive clauses (to be processed), and an ordering
    that is used for redundancy elimination.} *)

open Basic
open Params

module I = Index
module S = FoSubst
module C = Clauses
module U = FoUtils
module BV = Bitvector
module FV = FeatureVector
module CQ = ClauseQueue

let stat_passive_cleanup = mk_stat "cleanup of passive set"

type index = Clauses.clause_pos Index.t
  (** An index for positions in clauses *)

let _indexes =
  let table = Hashtbl.create 2 in
  (* TODO write a Substitution Tree, with the new substitution representation? *)
  (* TODO rewrite a general purpose discrimination tree *)
  let mk_fingerprint fp = 
    Fingerprint.mk_index ~cmp:Clauses.compare_clause_pos fp in
  Hashtbl.add table "fp" (mk_fingerprint Fingerprint.fp6m);
  Hashtbl.add table "fp7m" (mk_fingerprint Fingerprint.fp7m);
  Hashtbl.add table "fp16" (mk_fingerprint Fingerprint.fp16);
  table

let choose_index name =
  try Hashtbl.find _indexes name
  with Not_found -> failwith ("no such index name: " ^ name)

let names_index () =
  let names = ref [] in
  Hashtbl.iter (fun n _ -> names := n :: !names) _indexes;
  !names

(* ----------------------------------------------------------------------
 * main type definitions
 * ---------------------------------------------------------------------- *)


(** set of active clauses *)
type active_set =
  < ctx : context;
    clauses : Clauses.CSet.t;           (** set of active clauses *)
    idx_sup_into : index;               (** index for superposition into the set *)
    idx_sup_from : index;               (** index for superposition from the set *)
    idx_back_demod : index;             (** index for backward demodulation/simplifications *)
    idx_fv : Index.subsumption_t;       (** index for subsumption *)

    add : hclause Sequence.t -> unit;   (** add clauses *)
    remove : hclause Sequence.t -> unit;(** remove clauses *)
  >

(** set of simplifying (unit) clauses *)
type simpl_set =
  < ctx : context;
    idx_simpl : Index.unit_t;           (** index for forward simplifications
                                            TODO split into pos-orientable/others *)

    add : hclause Sequence.t -> unit;
    remove : hclause Sequence.t -> unit;
  >

(** set of passive clauses *)
type passive_set =
  < ctx : context;
    clauses : Clauses.CSet.t;           (** set of clauses *)
    queues : (ClauseQueue.t * int) list;

    add : hclause Sequence.t -> unit;   (** add clauses *)
    remove : int -> unit;               (** remove clause by ID *)
    next : unit -> hclause option;      (** next passive clause, if any *)
    clean : unit -> unit;               (** cleanup internal queues *)
  >

(** state of a superposition calculus instance.
    It contains a set of active clauses, a set of passive clauses,
    and is parametrized by an ordering. *)
type state =
  < ctx : context;
    params : parameters;
    simpl_set : simpl_set;              (** index for forward demodulation *)
    active_set : active_set;            (** active clauses *)
    passive_set : passive_set;          (** passive clauses *)
    meta_prover : Meta.Prover.t option;
    experts : Experts.Set.t;            (** Set of current experts *)

    add_expert : Experts.t -> unit;     (** Add an expert *)
  >

(* ----------------------------------------------------------------------
 * utils for indexing part of a clause
 * ---------------------------------------------------------------------- *)

(** apply the operation to literals that verify (eligible hc i lit) where
    i is the index of the literal; if subterm is true then the operation is
    done on every subterm, otherwise on root *)
let update_with_clause op acc eligible ~subterms ~both_sides hc =
  let acc = ref acc in
  (* specialize eligible for the clause *)
  let eligible = eligible hc in
  (* process a lit *)
  let rec process_lit op acc i = function
    | Equation (l,r,_,_) when both_sides ->
      let acc = process_term op acc l [left_pos; i] in
      process_term op acc r [right_pos; i]
    | Equation (l,r,_,Gt) ->
      process_term op acc l [left_pos; i]
    | Equation (l,r,_,Lt) ->
      process_term op acc r [right_pos; i]
    | Equation (l,r,_,Incomparable)
    | Equation (l,r,_,Eq) ->
      let acc = process_term op acc l [left_pos; i] in
      process_term op acc r [right_pos; i]
  (* process a term (maybe recursively). We build positions in the wrong order,
     so we have to reverse them before giving them to [op acc]. *)
  and process_term op acc t pos =
    match t.term with
    | Var _ | BoundVar _ -> acc  (* variables are never indexed *)
    | Bind (s, _, t') ->
      (* apply the operation on the term itself *)
      let acc = op acc t (hc, List.rev pos, t) in
      if subterms then process_term op acc t' (0::pos) else acc
    | Node (_, []) -> op acc t (hc, List.rev pos, t)
    | Node (_, l) ->
      (* apply the operation on the term itself *)
      let acc = op acc t (hc, List.rev pos, t) in
      if subterms
        then (* recursively process (non-var) subterms *)
          let _, acc = List.fold_left
            (fun (i, acc) t -> i+1, process_term op acc t (i::pos))
            (0, acc) l
          in acc
        else acc (* stop after the root literal *)
  in
  (* process eligible literals *)
  Array.iteri
    (fun i lit -> if eligible i lit then acc := process_lit op !acc i lit)
    hc.hclits;
  !acc

(** update acc using op, on all given clauses *)
let update_with_clauses op acc eligible ~subterms ~both_sides hcs =
  let acc = ref acc in
  Sequence.iter
    (fun hc -> acc := update_with_clause op !acc eligible ~subterms ~both_sides hc)
    hcs;
  !acc

(** process literals that are potentially eligible for resolution *)
let eligible_res hc =
  let bv = C.eligible_res (hc,0) S.id_subst in
  fun i lit -> BV.get bv i

(** process literals that are potentially eligible for paramodulation *)
let eligible_param hc =
  let bv = C.eligible_param (hc,0) S.id_subst in
  fun i lit -> BV.get bv i

(** process all literals *)
let eligible_always hc i lit = true

(* ----------------------------------------------------------------------
 * active set
 * ---------------------------------------------------------------------- *)

(** Create an active set from the given ord, and indexing structures *)
let mk_active_set ~ctx (index : index) signature =
  (* create a FeatureVector index from the current signature *)
  let features = FV.mk_features signature in
  let fv_idx = FV.mk_index features in
  (object (self)
    val mutable m_clauses = C.CSet.empty
    val mutable m_sup_into = index
    val mutable m_sup_from = index
    val mutable m_back_demod = index
    val mutable m_fv = fv_idx
    method ctx = ctx
    method clauses = m_clauses
    method idx_sup_into = m_sup_into
    method idx_sup_from = m_sup_from
    method idx_back_demod = m_back_demod
    method idx_fv = m_fv

    (** update indexes by removing/adding clauses *)
    method update op hcs =
      (* sup into: subterms of literals that are eligible for res *)
      m_sup_into <-
        update_with_clauses op m_sup_into eligible_res ~subterms:true ~both_sides:false hcs;
      (* sup from : literals that are eligible for param *)
      m_sup_from <-
        update_with_clauses op m_sup_from eligible_param ~subterms:false ~both_sides:false hcs;
      (* back-demod : all subterms *)
      m_back_demod <-
        update_with_clauses op m_back_demod eligible_always ~subterms:true ~both_sides:true hcs

    (** add clauses (only process the ones not present in the set) *)
    method add hcs =
      let hcs = Sequence.filter (fun hc -> not (C.CSet.mem m_clauses hc)) hcs in
      let hcs = Sequence.persistent hcs in
      m_clauses <- C.CSet.of_seq m_clauses hcs;
      let op tree = tree#add in
      self#update op hcs;
      m_fv <- m_fv#add_clauses hcs

    (** remove clauses (only process the ones present in the set) *)
    method remove hcs =
      let hcs = Sequence.filter (C.CSet.mem m_clauses) hcs in
      let hcs = Sequence.persistent hcs in
      m_clauses <- C.CSet.remove_seq m_clauses hcs;
      let op tree = tree#remove in
      self#update op hcs;
      m_fv <- m_fv#remove_clauses hcs
  end :> active_set)

(* ----------------------------------------------------------------------
 * simplification set
 * ---------------------------------------------------------------------- *)

(** Create a simplification set *)
let mk_simpl_set ~ctx unit_idx =
  object
    val mutable m_simpl = unit_idx
    method ctx = ctx
    method idx_simpl = m_simpl

    method add hcs =
      m_simpl <- Sequence.fold (fun simpl hc -> simpl#add_clause hc) m_simpl hcs

    method remove hcs =
      m_simpl <- Sequence.fold (fun simpl hc -> simpl#remove_clause hc) m_simpl hcs
  end

(* ----------------------------------------------------------------------
 * passive set
 * ---------------------------------------------------------------------- *)

let mk_passive_set ~ctx queues =
  assert (queues != []);
  let length = List.length queues in
  object
    val mutable m_clauses = C.CSet.empty
    val m_queues = Array.of_list queues
    val mutable m_state = (0,0)
    method ctx = ctx
    method clauses = m_clauses
    method queues = Array.to_list m_queues

    (** add clauses (not already present in set) to the set *)
    method add hcs =
      let hcs = Sequence.filter (fun hc -> not (C.CSet.mem m_clauses hc)) hcs in
      let hcs = Sequence.persistent hcs in
      m_clauses <- C.CSet.of_seq m_clauses hcs;
      for i = 0 to length - 1 do
        (* add to i-th queue *)
        let (q, w) = m_queues.(i) in
        m_queues.(i) <- (CQ.adds q hcs, w)
      done

    (** remove clauses (not from the queues) *)
    method remove id = 
      m_clauses <- C.CSet.remove_id m_clauses id

    (** next clause *)
    method next () =
      let first_idx, w = m_state in
      (* search in the idx-th queue *)
      let rec search idx weight =
        let q, w = m_queues.(idx) in
        if weight >= w || CQ.is_empty q
        then next_idx (idx+1) (* empty queue, go to the next one *)
        else begin
          let new_q, hc = CQ.take_first q in (* pop from this queue *)
          m_queues.(idx) <- new_q, w;
          if C.CSet.mem m_clauses hc
            then begin (* done, found a still-valid clause *)
              U.debug 3 "taken clause from %s" (CQ.name q);
              m_clauses <- C.CSet.remove m_clauses hc;
              m_state <- (idx, weight+1);
              Some hc
            end else search idx weight
        end
      (* search the next non-empty queue *)
      and next_idx idx =
        if idx = first_idx then None (* all queues are empty *)
        else if idx = length then next_idx 0 (* cycle *)
        else search idx 0 (* search in this queue *)
      in
      search first_idx w

    (* cleanup the clause queues *)
    method clean () =
      incr_stat stat_passive_cleanup;
      for i = 0 to length - 1 do
        let q, w = m_queues.(i) in
        m_queues.(i) <- CQ.clean q m_clauses, w
      done
  end

(* ----------------------------------------------------------------------
 * global state
 * ---------------------------------------------------------------------- *)

let mk_state ~ctx ?meta params signature =
  let queues = ClauseQueue.default_queues
  and unit_idx = Dtree.unit_index
  and index = choose_index params.param_index
  and _experts = ref (Experts.Set.empty ~ctx) in
  object
    val m_active = (mk_active_set ~ctx index signature :> active_set)
    val m_passive = (mk_passive_set ~ctx queues :> passive_set)
    val m_simpl = (mk_simpl_set ~ctx unit_idx :> simpl_set)
    method ctx = ctx
    method params = params
    method active_set = m_active
    method passive_set = m_passive
    method simpl_set = m_simpl
    method meta_prover = meta
    method experts = !_experts
    method add_expert e =
      let es = Experts.update_ctx e ~ctx in
      _experts := Experts.Set.add_list !_experts es;
      (* add clauses of each expert to the set of passive clauses *)
      let clauses = Sequence.flatMap
        (fun e -> Sequence.of_list (Experts.clauses e))
        (Sequence.of_list es) in
      m_passive#add clauses
  end

(* ----------------------------------------------------------------------
 * utils
 * ---------------------------------------------------------------------- *)

(** statistics on the state (TODO stats on the simpl_set) *)
type state_stats = int * int * int (* num passive, num active, num simplification *)

let stats state =
  ( C.CSet.size state#active_set#clauses
  , C.CSet.size state#passive_set#clauses
  , state#simpl_set#idx_simpl#size)

let pp_state formatter state =
  let num_active, num_passive, num_simpl = stats state in
  Format.fprintf formatter
    "@[<h>state {%d active clauses; %d passive_clauses; %d simplification_rules;@;%a}@]"
    num_active num_passive num_simpl
    CQ.pp_queues (Sequence.of_list state#passive_set#queues)

let debug_state formatter state =
  let num_active, num_passive, num_simpl = stats state in
  Format.fprintf formatter
    ("@[<v 2>state {%d active clauses; %d passive_clauses; %d simplification_rules;" ^^
      "@;%a@;active:%a@;passive:%a@]@;")
    num_active num_passive num_simpl
    CQ.pp_queues (Sequence.of_list state#passive_set#queues)
    C.pp_set state#active_set#clauses
    C.pp_set state#passive_set#clauses
