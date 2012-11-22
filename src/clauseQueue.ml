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

(** Heuristic selection of clauses, using queues. Note that some
    queues do not need accept all clauses, as long as one of them does
    (for completeness). Anyway, a fifo queue should always be present,
    and presents this property. *)

open Types
open Hashcons

module C = Clauses
module O = Orderings
module Utils = FoUtils

(* a queue of clauses *)
class type queue =
  object
    method add : hclause -> queue
    method is_empty: bool
    method take_first : (queue * hclause)
    method remove : hclause list -> queue  (* slow *)
    method iter : (hclause -> unit) -> unit
    method name : string
  end

module LH = Leftistheap

type clause_ord = hclause LH.ordered

(** generic clause queue based on some ordering on clauses *)
let make_hq ~ord ?(accept=(fun _ -> true)) name =
  object
    val heap = new LH.leftistheap ord
    
    method is_empty = heap#is_empty

    method add hc =
      assert (hc.ctag <> (-1));
      if accept hc then
        let new_heap = heap#insert hc in
        ({< heap = new_heap >} :> queue)
      else
        ({<>} :> queue)

    method take_first =
      assert (not (heap#is_empty));
      let c,new_h = heap#extract_min in
      (({< heap = new_h >} :> queue), c)

    method remove hclauses =
      match hclauses with
      | [] -> ({< >} :> queue)
      | _ ->  ({< heap = heap#remove hclauses >} :> queue)

    method iter k = heap#iter k

    method name = name
  end

let fifo ~ord =
  let clause_ord =
    object
      method le hc1 hc2 =  hc1.ctag <= hc2.ctag
    end
  and name = "fifo_queue" in
  make_hq ~ord:clause_ord name

let clause_weight ~ord =
  let clause_ord =
    object
      method le hc1 hc2 =
        let w1 = ord#compute_clause_weight hc1
        and w2 = ord#compute_clause_weight hc2 in
        w1 <= w2
    end
  and name = "clause_weight" in
  make_hq ~ord:clause_ord name

(** compute a clause weight that makes maximal literals bigger *)
let compute_refined_clause_weight ~ord c =
  let weight = Array.fold_left
    (fun sum ({lit_eqn=Equation (l, r, _)} as lit) ->
      let lit_weight = ord#compute_term_weight l + ord#compute_term_weight r in
      sum + (if lit.lit_maximal then 4 * lit_weight else lit_weight))
    0 c.clits
  in (Array.length c.clits) * weight

let refined_clause_weight ~ord =
  let clause_ord =
    object
      method le hc1 hc2 =
        let w1 = compute_refined_clause_weight ~ord hc1
        and w2 = compute_refined_clause_weight ~ord hc2 in
        w1 <= w2
    end
  and name = "refined_clause_weight" in
  make_hq ~ord:clause_ord name
  
let goals ~ord =
  (* is the clause a goal clause? *)
  let is_goal_clause c =
    Array.fold_left (fun acc lit -> acc && C.neg_eqn lit.lit_eqn) true c.clits in
  let clause_ord =
    object
      method le hc1 hc2 =
        let w1 = compute_refined_clause_weight ~ord hc1
        and w2 = compute_refined_clause_weight ~ord hc2 in
        w1 <= w2
    end
  and name = "prefer_goals" in
  make_hq ~ord:clause_ord ~accept:is_goal_clause name

let non_goals ~ord =
  (* is the clause clause without goals? *)
  let is_non_goal_clause c =
    Array.fold_left (fun acc lit -> acc && C.pos_eqn lit.lit_eqn) true c.clits in
  let clause_ord =
    object
      method le hc1 hc2 =
        let w1 = compute_refined_clause_weight ~ord hc1
        and w2 = compute_refined_clause_weight ~ord hc2 in
        (* lexicographic comparison that favors clauses with less literals
           and then clauses with small weight *)
        w1 <= w2
    end
  and name = "prefer_non_goals" in
  make_hq ~ord:clause_ord ~accept:is_non_goal_clause name

let pos_unit_clauses ~ord =
  let is_unit_pos c = match c.clits with
  | [|{lit_eqn=Equation (_,_,true)}|] -> true
  | _ -> false
  in
  let clause_ord =
    object
      method le hc1 hc2 =
        assert (is_unit_pos hc1 && is_unit_pos hc2);
        let w1 = compute_refined_clause_weight ~ord hc1
        and w2 = compute_refined_clause_weight ~ord hc2 in
        (* lexicographic comparison that favors clauses with more goals,
           and then clauses with small weight *)
        w1 <= w2
    end
  and name = "prefer_pos_unit_clauses" in
  make_hq ~ord:clause_ord ~accept:is_unit_pos name

let default_queues ~ord =
  [ (clause_weight ~ord, 4);
    (pos_unit_clauses ~ord, 3);
    (non_goals ~ord, 1);
    (goals ~ord, 1);
    (fifo ~ord, 1);
  ]

let pp_queue formatter q =
  Format.fprintf formatter "@[<h>queue %s@]" q#name

let pp_queue_weight formatter (q, w) =
  Format.fprintf formatter "@[<h>queue %s (weight %d)@]" q#name w

let debug_queue_weight formatter (q, w) =
  let pp_heap formatter h =
    h#iter (Format.fprintf formatter "%a@;" !C.pp_clause#pp_h) in
  Format.fprintf formatter "@[<h>queue %s (weight %d) (contains @[<v>%a@])@]" q#name w pp_heap q

let pp_queues formatter qs =
  Format.fprintf formatter "@[<hov>%a@]" (Utils.pp_list ~sep:"; " pp_queue_weight) qs

let debug_queues formatter qs =
  Format.fprintf formatter "@[<hov>%a@]" (Utils.pp_list ~sep:"; " debug_queue_weight) qs
