(*
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

(** {1 Reduction to CNF and simplifications} *)

module T = Term
module S = Symbol
module F = Formula

(* check whether the formula is already in CNF *)
let rec is_cnf f = match f.F.form with
  | F.Or l -> List.for_all is_lit l
  | F.Not f' -> is_lit f'
  | F.True
  | F.False
  | F.Atom _
  | F.Equal _ -> true
  | F.And _ 
  | F.Equiv _
  | F.Imply _
  | F.Forall _
  | F.Exists _ -> false

and is_lit f = match f.F.form with
  | F.Not f' -> F.is_atomic f'
  | F.Equal _
  | F.Atom _
  | F.True
  | F.False -> true
  | F.Or _
  | F.And _
  | F.Equiv _
  | F.Imply _
  | F.Forall _
  | F.Exists _ -> false

(* miniscoping (push quantifiers as deep as possible in the formula) *)
let rec miniscope f =
  let f = F.simplify f in
  (* recursive miniscoping *)
  match f.F.form with
  | F.Forall {F.form=F.And l} ->
    (* forall x (and l) -> and (forall x f' \ f' in l) *)
    let l = List.map miniscope l in
    let with_v, without_v = List.partition (fun f -> F.db_contains f 0) l in
    F.mk_and (List.map F.mk_forall with_v @ List.map F.db_unlift without_v)
  | F.Forall {F.form=F.Or l} ->
    let l = List.map miniscope l in
    let with_v, without_v = List.partition (fun f -> F.db_contains f 0) l in
    F.mk_or (F.mk_forall (F.mk_or with_v) :: List.map F.db_unlift without_v)
  | F.Forall f' -> F.mk_forall (miniscope f')
  | F.Exists {F.form=F.And l} ->
    let l = List.map miniscope l in
    let with_v, without_v = List.partition (fun f -> F.db_contains f 0) l in
    F.mk_and (F.mk_exists (F.mk_and with_v) :: List.map F.db_unlift without_v)
  | F.Exists {F.form=F.Or l} ->
    let l = List.map miniscope l in
    let with_v, without_v = List.partition (fun f -> F.db_contains f 0) l in
    F.mk_or (List.map F.mk_exists with_v @ List.map F.db_unlift without_v)
  | F.Exists f' -> F.mk_exists (miniscope f')
  | F.And l -> F.mk_and (List.map miniscope l)
  | F.Or l -> F.mk_or (List.map miniscope l)
  | F.Imply (f1, f2) -> F.mk_imply (miniscope f1) (miniscope f2)
  | F.Equiv (f1, f2) -> F.mk_equiv (miniscope f1) (miniscope f2)
  | F.Not f' -> F.mk_not (miniscope f')
  | F.True
  | F.False
  | F.Equal _
  | F.Atom _ -> f

(* negation normal form (also remove equivalence and implications).
    [polarity] is the polarity of the formula, ie the parity of the number
    of negations on the path from the root formula to this formula. *) 
let rec nnf polarity f = match f.F.form with
  | F.Atom _
  | F.Equal _ -> f
  | F.Not {F.form=F.And l} ->
    nnf polarity (F.mk_or (List.map F.mk_not l))
  | F.And l -> F.mk_and (List.map (nnf polarity) l)
  | F.Not {F.form=F.Or l} ->
    nnf polarity (F.mk_and (List.map F.mk_not l))
  | F.Or l -> F.mk_or (List.map (nnf polarity) l)
  | F.Not ({F.form=(F.Imply _ | F.Equiv _)} as f') ->
    nnf polarity (F.mk_not (nnf (not polarity) f'))
  | F.Imply (f1, f2) ->
    nnf polarity (F.mk_or [ (F.mk_not f1); f2 ])
  | F.Equiv(f1,f2) ->
    if polarity
      then
        nnf polarity (F.mk_and [ F.mk_imply f1 f2; F.mk_imply f2 f1 ])
      else
        nnf polarity (F.mk_or [ F.mk_and [f1; f2]; F.mk_and [F.mk_not f1; F.mk_not f2] ])
  | F.Not {F.form=F.Forall f'} -> F.mk_exists (nnf polarity (F.mk_not f'))
  | F.Forall f' -> F.mk_forall (nnf polarity f')
  | F.Not {F.form=F.Exists f'} -> F.mk_forall (nnf polarity (F.mk_not f'))
  | F.Exists f' -> F.mk_exists (nnf polarity f')
  | F.Not f' when F.is_atomic f' -> f
  | F.Not _ -> failwith "NNF failure!"
  | F.True
  | F.False -> f

let skolemize ~ctx f =
  let rec skolemize f = match f.F.form with
  | F.And l -> F.mk_and (List.map skolemize l)
  | F.Or l -> F.mk_or (List.map skolemize l)
  | F.Not f' -> F.mk_not (skolemize f')
  | F.Imply _
  | F.Equiv _ -> failwith "can only skolemize a NNF formula"
  | F.Atom _
  | F.Equal _
  | F.True
  | F.False -> f
  | F.Exists f' ->
    (* replace [v] by a fresh skolem term *)
    let new_f' = Skolem.skolem_form ~ctx f' in
    skolemize new_f'
  | F.Forall f' ->
    (* remove quantifier, replace by fresh variable *)
    F.iter (Skolem.update_var ~ctx) f';
    let ty = F.db_type f' 0 in
    let v = T.mk_var ?ty (Skolem.fresh_var ~ctx) in
    let new_f' = F.db_replace f' v in
    skolemize new_f'
  in
  skolemize f

(* helper: reduction to cnf using De Morgan laws. Returns a list of list of
  atomic formulas *)
let rec to_cnf f = match f.F.form with
  | F.Equal _
  | F.Atom _
  | F.True
  | F.False -> [[f]]
  | F.Not f' ->
    if F.is_atomic f'
      then [[f]]
      else failwith (Util.sprintf "should be atomic: %a" F.pp f')
  | F.And l ->
    (* simply concat sub-CNF *)
    Util.list_flatmap to_cnf l
  | F.Or (f'::l) ->
    (* cartesian products of sub-CNF *)
    List.fold_left
      (fun cnf f' -> product (to_cnf f') cnf)
      (to_cnf f')
      l
  | F.Forall _
  | F.Exists _ -> failwith "Cnf.to_cnf: can only clausify a skolemized formula"
  | F.Imply _
  | F.Equiv _ -> failwith "Cnf.to_cnf: can only clausify a NNF formula"
  | F.Or [] -> assert false
(* cartesian product of lists of lists *)
and product a b =
  List.fold_left
    (fun acc litsa -> List.fold_left
      (fun acc' litsb -> (litsa @ litsb) :: acc')
      acc b)
    [] a

type clause = Formula.t list
  (** Basic clause representation, as list of literals *)

(* Transform the clause into proper CNF; returns a list of clauses *)
let cnf_of ?(ctx=Skolem.create ()) f =
  let f = F.flatten f in
  if is_cnf f
    then
      match f.F.form with
      | F.Or l -> [l]
      | F.False -> []
      | F.True 
      | F.Equal _
      | F.Atom _ -> [[f]]
      | F.Not f' when F.is_atomic f' -> [[f]]
      | F.Not _
      | F.Equiv _
      | F.Imply _
      | F.And _
      | F.Forall _
      | F.Exists _ -> assert false
    else begin
      Util.debug 4 "reduce %a to CNF..." F.pp f;
      let f = F.simplify f in
      Util.debug 4 "... simplified: %a" F.pp f;
      let f = nnf true f in
      Util.debug 4 "... NNF: %a" F.pp f;
      let f = miniscope f in
      Util.debug 4 "... miniscoped: %a" F.pp f;
      F.iter (Skolem.update_var ~ctx) f;
      let f = skolemize ~ctx f in
      Util.debug 4 "... skolemized: %a" F.pp f;
      let clauses = to_cnf f in
      clauses
    end

let cnf_of_list ?(ctx=Skolem.create ()) l =
  Util.list_flatmap (fun f -> cnf_of ~ctx f) l
