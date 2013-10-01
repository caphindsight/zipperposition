
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

(** {6 Arithmetic Manipulations} *)

open Logtk

module C = Clause
module S = Symbol
module PF = PFormula
module Literals = Literal.Arr

(** {2 Utils} *)

let is_arith_ty ty =
  Type.eq ty Type.int || Type.eq ty Type.rat || Type.eq ty Type.real

(** {2 Terms} *)

module T = struct
  include Term  (* for the rest of arith *)

  let rec is_arith t = match t.term with
    | Node ((S.Int _ | S.Rat _ | S.Real _), []) -> true
    | Node (s, _) when Symbol.Arith.is_arith s -> true
    | Var _
    | BoundVar _ ->
      begin match t.type_ with
      | Some ty -> is_arith_ty ty
      | None -> assert false
      end
    | _ -> false

  let rec sum_list l = match l with
    | [] -> failwith "Arith.sum_list: got empty list"
    | [x] -> x
    | x::l' -> mk_node S.Arith.sum [x; sum_list l']

  let mk_sum t1 t2 = mk_node S.Arith.sum [t1; t2]
  let mk_difference t1 t2 = mk_node S.Arith.difference [t1; t2]
  let mk_product t1 t2 = mk_node S.Arith.product [t1; t2]
  let mk_quotient t1 t2 = mk_node S.Arith.quotient [t1; t2]
  let mk_uminus t = mk_node S.Arith.uminus [t]
  
  let mk_less t1 t2 = mk_node S.Arith.less [t1; t2]
  let mk_lesseq t1 t2 = mk_node S.Arith.lesseq [t1; t2]

  let extract_subterms t =
    (* recursive function that gathers terms into set *)
    let rec gather set t = match t.term with
    | Bind _
    | At _
    | Var _
    | BoundVar _ -> THashSet.add set t
    | Node (s, []) when S.is_numeric s -> ()
    | Node (s, l) when S.Arith.is_arith s ->
      List.iter (gather set) l
    | Node _ -> THashSet.add set t
    in
    if is_arith t
      then
        let set = THashSet.create ~size:5 () in
        let () = gather set t in
        THashSet.to_list set
      else []

  let simplify ~signature t =
    (* recursive function with cache *)
    let rec simplify recurse t = match t.term with
    | Bind (s, t') -> mk_bind s (recurse t')
    | At (t1, t2) -> mk_at (recurse t1) (recurse t2)
    | Var _
    | BoundVar _ -> t
    | Node (s, [t']) ->
      let t' = recurse t' in
      try_reduce_unary recurse s t'
    | Node (s, [t1; t2]) ->
      let t1 = recurse t1 in
      let t2 = recurse t2 in
      try_reduce_binary recurse s t1 t2
    | Node (s, l) ->
      let t = mk_node s (List.map recurse l) in
      t
    (** unary builtins *)
    and try_reduce_unary recurse s a =
      match s, a.term with
      | S.Const ("$uminus", _), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.uminus n)
      | S.Const ("$uminus",_), Node (S.Const ("$uminus",_), [x]) -> x
      | S.Const ("$floor",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.floor n)
      | S.Const ("$ceiling",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.ceiling n)
      | S.Const ("$round",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.round n)
      | S.Const ("$truncate",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.truncate n)
      | S.Const ("$is_int",_), Node (n, []) when S.is_numeric n ->
        if S.is_int n then true_term else false_term
      | S.Const ("$is_rat",_), Node (n, []) when S.is_numeric n ->
        if S.is_rat n then true_term else false_term
      | S.Const ("$is_real",_), Node (n, []) when S.is_numeric n ->
        if S.is_real n then true_term else false_term
      | S.Const ("$to_rat",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.to_rat n)
      | S.Const ("$to_real",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.to_real n)
      | S.Const ("$to_int",_), Node (n, []) when S.is_numeric n ->
        mk_const (S.Arith.Op.to_int n)
      | _ -> mk_node s [a]  (* default case *)
    (** binary builtins *)
    and try_reduce_binary recurse s a b =
      try begin match s, a.term, b.term with
      | S.Const ("$sum",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.sum na nb)
      | S.Const ("$difference",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.difference na nb)
      | S.Const ("$product",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.product na nb)
      | S.Const ("$quotient",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.quotient na nb)
      | S.Const ("$quotient_e",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.quotient_e na nb)
      | S.Const ("$quotient_t",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.quotient_t na nb)
      | S.Const ("$quotient_f",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.quotient_f na nb)
      | S.Const ("$remainder_e",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.remainder_e na nb)
      | S.Const ("$remainder_t",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.remainder_t na nb)
      | S.Const ("$remainder_f",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        mk_const (S.Arith.Op.remainder_f na nb)
      | S.Const ("$less",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        if S.Arith.Op.less na nb then true_term else false_term
      | S.Const ("$lesseq",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        if S.Arith.Op.lesseq na nb then true_term else false_term
      | S.Const ("$greater",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        if S.Arith.Op.greater na nb then true_term else false_term
      | S.Const ("$greatereq",_), Node (na, []), Node (nb, [])
        when S.is_numeric na && S.is_numeric nb ->
        if S.Arith.Op.greatereq na nb then true_term else false_term
      | S.Const ("$sum",_), _, Node (nb,[]) when S.Arith.is_zero nb -> a
      | S.Const ("$sum",_), Node (na,[]), _ when S.Arith.is_zero na -> b
      | S.Const ("$difference",_), _, Node (nb,[]) when S.Arith.is_zero nb -> a
      | S.Const ("$difference",_), Node (na,[]), _ when S.Arith.is_zero na ->
        recurse (mk_uminus b)
      | S.Const ("$difference",_), _, _ when eq a b ->
        (* need to infer types so  that we know which zero to return *)
        let ty = TypeInference.infer_sig signature a in
        mk_const (S.Arith.zero_of_ty ty)
      | S.Const ("$product",_), _, Node (nb,[]) when S.Arith.is_one nb -> a
      | S.Const ("$product",_), Node (na,[]), _ when S.Arith.is_one na -> b
      | S.Const ("$product",_), Node (na,[]), _ when S.Arith.is_zero na -> a
      | S.Const ("$product",_), _, Node (nb,[]) when S.Arith.is_zero nb -> b
      | S.Const ("$quotient",_), _, Node (nb,[]) when S.Arith.is_one nb -> a
      | S.Const ("$quotient",_), Node (na,[]), _ when S.Arith.is_zero na -> a
      | _ -> mk_node s [a; b]  (* default case *)
      end with Division_by_zero ->
        mk_node s [a; b]
    in
    let __cache = TCache.create 9 in
    TCache.with_cache_rec __cache simplify t
end

(** {2 Formulas} *)

module F = struct
  include Formula

  let rec simplify ~signature f = match f.form with
  | True
  | False -> f
  | Not {form=Atom {T.term=T.Node(S.Const("$greater",_), [l;r])}} ->
    simplify ~signature (mk_atom (T.mk_lesseq l r))
  | Not {form=Atom {T.term=T.Node(S.Const("$greatereq",_), [l;r])}} ->
    simplify ~signature (mk_atom (T.mk_less l r))
  | Not {form=Atom {T.term=T.Node(S.Const("$less",_), [l;r])}} ->
    simplify ~signature (mk_atom (T.mk_lesseq r l))
  | Not {form=Atom {T.term=T.Node(S.Const("$lesseq",_), [l;r])}} ->
    simplify ~signature (mk_atom (T.mk_less r l))
  | Atom {T.term=T.Node(S.Const("$greater",_), [l;r])} ->
    simplify ~signature (mk_atom (T.mk_less r l))
  | Atom {T.term=T.Node(S.Const("$greatereq",_), [l;r])} ->
    simplify ~signature (mk_atom (T.mk_lesseq r l))
  | Or l -> mk_or (List.map (simplify ~signature) l)
  | And l -> mk_and (List.map (simplify ~signature) l)
  | Not f' -> mk_not (simplify ~signature f')
  | Equiv (f1, f2) -> mk_equiv (simplify ~signature f1) (simplify ~signature f2)
  | Imply (f1, f2) -> mk_imply (simplify ~signature f1) (simplify ~signature f2)
  | Atom p ->
    let p' = T.simplify ~signature p in
    mk_atom p'
  | Equal (l, r) ->
    let l' = T.simplify ~signature l in
    let r' = T.simplify ~signature r in
    mk_eq l' r'
  | Forall f' -> mk_forall (simplify ~signature f')
  | Exists f' -> mk_exists (simplify ~signature f')
end

(** {2 Polynomials of Order 1} *)

module Monome = struct
  type t = {
    coeffs : Symbol.t Term.TMap.t;
    constant : Symbol.t;
    divby : Symbol.t;  (* divide everything by this constant (cool for ints) *)
  }

  let const constant =
    assert (S.is_numeric constant);
    {
      coeffs = T.TMap.empty;
      constant;
      divby = S.Arith.one_of_ty (S.Arith.typeof constant);
    }
  
  let singleton ?divby coeff t =
    if S.Arith.is_zero coeff
      then const coeff  (* 0 *)
      else
        let coeffs = T.TMap.singleton t coeff in
        let constant = S.Arith.zero_of_ty (S.Arith.typeof coeff) in
        let divby = match divby with
        | Some d -> d
        | None -> S.Arith.one_of_ty (S.Arith.typeof coeff)
        in
        { coeffs; constant; divby; }

  let of_list constant l =
    let divby = S.Arith.one_of_ty (S.Arith.typeof constant) in
    let coeffs = List.fold_left
      (fun m (coeff, t) ->
        if S.Arith.is_zero coeff
          then m
          else T.TMap.add t coeff m)
      T.TMap.empty l
    in
    { constant; coeffs; divby; }

  let pp buf monome =
    Buffer.add_char buf '(';
    T.TMap.iter
      (fun t coeff -> Printf.bprintf buf "%a×%a +" S.pp coeff T.pp t)
      monome.coeffs;
    S.pp buf monome.constant;
    if S.Arith.is_one monome.divby
      then Buffer.add_char buf ')'
      else Printf.bprintf buf ")/%a" S.pp monome.divby

  let to_string monome = Util.on_buffer pp monome

  let fmt fmt m = Format.pp_print_string fmt (to_string m)

  let mem m t = T.TMap.mem t m.coeffs

  let find m t = T.TMap.find t m.coeffs

  let add m coeff t =
    (* compute sum of coeffs for [t], if need be *)
    let c =
      try
        let coeff' = T.TMap.find t m.coeffs in
        S.Arith.Op.sum coeff coeff'
      with Not_found -> coeff
    in
    if S.Arith.is_zero c
      then {m with coeffs=T.TMap.remove t m.coeffs;}
      else {m with coeffs=T.TMap.add t c m.coeffs;}
  
  let remove m t =
    { m with coeffs=T.TMap.remove t m.coeffs; }

  let terms m =
    T.TMap.fold (fun t coeff acc -> t :: acc) m.coeffs []

  let to_list m =
    T.TMap.fold (fun t coeff acc -> (coeff,t) :: acc) m.coeffs []

  let var_occurs v m =
    List.exists (fun t -> T.var_occurs v t) (terms m)

  (* scale: multiply all coeffs by constant, multiply divby by same constant.
    This yields the very same monome *)
  let _scale m c =
    assert (S.is_numeric c);
    assert (not (S.Arith.is_zero c));
    if S.Arith.is_one c
      then m  (* same monome *)
      else
        let constant = S.Arith.Op.product c m.constant in
        let coeffs = T.TMap.map (fun c' -> S.Arith.Op.product c c') m.coeffs in
        let divby = S.Arith.Op.product m.divby c in
        { constant; coeffs; divby; }

  (* reduce to same divby (same denominator) *)
  let reduce_same_divby m1 m2 =
    match m1.divby, m2.divby with
    | S.Int n1, S.Int n2 ->
      let gcd = Big_int.gcd_big_int n1 n2 in
      (* n1 × n2 = gcd × lcm, so we need to raise both n1 and n2 to lcm.
         to do that, let us introduce  n1 = gcd × d1, and n2 = gcd × d2.
         Then
            n1 × d2 = gcd × d1 × d2, and
            n2 × d1 = gcd × d2 × d1
         so we multiply m1 by d2, and m2 by d1.
      *)
      let d1 = S.mk_bigint (Big_int.div_big_int n1 gcd) in
      let d2 = S.mk_bigint (Big_int.div_big_int n2 gcd) in
      _scale m1 d2, _scale m2 d1
    | c1, c2 ->
      (* reduce m1 / c1 and m2 / c2 to same denominator. We choose c2
         arbitrarily, so we need to multiply m1/c1 by c1/c2. *)
      _scale m1 (S.Arith.Op.quotient c1 c2), m2

  let sum m1 m2 =
    let m1, m2 = reduce_same_divby m1 m2 in
    let constant = S.Arith.Op.sum m1.constant m2.constant in
    let coeffs = T.TMap.merge
      (fun t c1 c2 -> match c1, c2 with
      | None, Some c
      | Some c, None -> Some c
      | Some c1, Some c2 ->
        let c = S.Arith.Op.sum c1 c2 in
        if S.Arith.is_zero c
          then None
          else Some c
      | None, None -> assert false)
      m1.coeffs m2.coeffs
    in
    { m1 with constant; coeffs; }

  let difference m1 m2 =
    let m1, m2 = reduce_same_divby m1 m2 in
    let constant = S.Arith.Op.sum m1.constant m2.constant in
    let coeffs = T.TMap.merge
      (fun t c1 c2 -> match c1, c2 with
      | None, Some c -> Some (S.Arith.Op.uminus c)
      | Some c, None -> Some c
      | Some c1, Some c2 ->
        let c = S.Arith.Op.difference c1 c2 in
        if S.Arith.is_zero c
          then None
          else Some c
      | None, None -> assert false)
      m1.coeffs m2.coeffs
    in
    { m1 with constant; coeffs; }

  let uminus m =
    let constant = S.Arith.Op.uminus m.constant in
    let coeffs = T.TMap.map S.Arith.Op.uminus m.coeffs in
    { m with constant; coeffs; }

  (* product by constant *)
  let product m c =
    if S.Arith.is_zero c
      then const c  (* 0 *)
      else  (* itemwise product *)
        let constant = S.Arith.Op.product m.constant c in
        let coeffs = T.TMap.map (fun c' -> S.Arith.Op.product c c') m.coeffs in
        { m with constant; coeffs; }

  let divby m const =
    if S.Arith.is_zero const
      then raise Division_by_zero
      else
        let divby = S.Arith.Op.product const m.divby in
        { m with divby; }

  let succ m =
    let one = S.Arith.one_of_ty (S.Arith.typeof m.constant) in
    sum m (const one)

  let pred m =
    let one = S.Arith.one_of_ty (S.Arith.typeof m.constant) in
    difference m (const one)

  exception NotLinear
    (** Used by [of_term] *)

  let rec of_term ~signature t = match t.T.term with
  | T.Node (s, [t1; t2]) when S.eq s S.Arith.sum ->
    let m1 = of_term ~signature t1 in
    let m2 = of_term ~signature t2 in
    sum m1 m2
  | T.Node (s, [t1; t2]) when S.eq s S.Arith.difference ->
    let m1 = of_term ~signature t1 in
    let m2 = of_term ~signature t2 in
    difference m1 m2
  | T.Node (s, [t']) when S.eq s S.Arith.uminus ->
    let m = of_term ~signature t' in
    uminus m
  | T.Node (s, [{T.term=T.Node (s',[])}; t2])
    when S.eq s S.Arith.product && S.is_numeric s' ->
    let m = of_term ~signature t2 in
    product m s'
  | T.Node (S.Const("$succ",_), [t']) ->
    let m = of_term ~signature t' in
    succ m
  | T.Node (S.Const("$pred",_), [t']) ->
    let m = of_term ~signature t' in
    pred m
  | T.Node (s, [t2; {T.term=T.Node (s',[])}])
    when S.eq s S.Arith.product && S.is_numeric s' ->
    let m = of_term ~signature t2 in
    product m s'
  | T.Node (s, [t2; {T.term=T.Node (s',[])}])
    when S.eq s S.Arith.quotient && S.is_numeric s' && not (S.Arith.is_zero s') ->
    let m = of_term ~signature t2 in
    divby m s'
  | T.Node (s, []) when S.is_numeric s -> const s
  | T.Node (s, [_; _]) when S.Arith.is_arith s ->
    raise NotLinear  (* failure *)
  | T.Var _
  | T.BoundVar _ ->
    let ty = match t.T.type_ with Some ty -> ty | None -> assert false in
    let one = S.Arith.one_of_ty ty in
    singleton one t
  | T.Node _
  | T.At _
  | T.Bind _ ->
    let ty = TypeInference.infer_sig signature t in
    let one = S.Arith.one_of_ty ty in
    singleton one t

  let of_term_opt ~signature t =
    try Some (of_term ~signature t)
    with NotLinear -> None
      
  let to_term m =
    let sum = T.mk_const m.constant in
    let sum = T.TMap.fold
      (fun t' coeff sum -> T.mk_sum (T.mk_product (T.mk_const coeff) t') sum)
      m.coeffs sum
    in
    if S.Arith.is_one m.divby
      then sum
      else T.mk_quotient sum (T.mk_const m.divby)
end

(** {2 View a Literal as an arithmetic Literal}. *)

module Lit = struct
  type t =
  | Eq of Term.t * Monome.t
  | Neq of Term.t * Monome.t
  | L_less of Term.t * Monome.t   (* term < monome *)
  | L_lesseq of Term.t * Monome.t
  | R_less of Monome.t * Term.t
  | R_lesseq of Monome.t * Term.t

  let is_arith lit = match lit with
  | Literal.Equation (l, r, _, _) -> T.is_arith l || T.is_arith r
  | Literal.Prop (p, _) -> T.is_arith p
  | Literal.True
  | Literal.False -> false

  let extract ~signature lit =
    (* extract literal from (l=r | l!=r) *)
    let extract_eqn l r sign =
      try
        let m1 = Monome.of_term ~signature l in
        let m2 = Monome.of_term ~signature r in
        let m = Monome.difference m1 m2 in
        let terms = Monome.to_list m in
        (* for each term, pivot the monome so that we isolate the term
          on one side of the (dis)equation *)
        List.map
          (fun (coeff, t) ->
            assert (not (S.Arith.is_zero coeff));
            let m = Monome.divby (Monome.remove m t) coeff in
            if sign
              then Eq (t, m)
              else Neq (t, m))
          terms
      with Monome.NotLinear -> []
    (* extract lit from (l <= r | l < r) *)
    and extract_less ~strict l r =
      try
        let m1 = Monome.of_term ~signature l in
        let m2 = Monome.of_term ~signature r in
        let m = Monome.difference m1 m2 in
        let terms = Monome.to_list m in
        (* for each term, pivot the monome to isolate the term. Careful with
            the sign as it can change the comparison sign too! If the
            coeff is > 0 it means that the term [t] is on the {b left}
            side. *)
        List.map
          (fun (coeff, t) ->
            assert (not (S.Arith.is_zero coeff));
            (* do we have to change the sign of comparison? *)
            let swap = S.Arith.sign coeff < 0 in
            let m = Monome.divby (Monome.remove m t) (S.Arith.Op.abs coeff) in
            match strict, swap with
            | true, false -> L_less (t, m)
            | true, true -> R_less (m, t)
            | false, false -> L_lesseq (t, m)
            | false, true -> R_lesseq (m, t)
          )
          terms
      with Monome.NotLinear -> []
    in
    let extract_le a b = extract_less ~strict:false a b in
    let extract_lt a b = extract_less ~strict:true a b in
    match lit with
    | Literal.True
    | Literal.False -> []
    | Literal.Equation (l, r, sign, _) -> extract_eqn l r sign
    | Literal.Prop ({T.term=T.Node (S.Const ("$less",_), [a; b])}, true) ->
      extract_lt a b
    | Literal.Prop ({T.term=T.Node (S.Const ("$less",_), [a; b])}, false) ->
      extract_le b a
    | Literal.Prop ({T.term=T.Node (S.Const ("$lesseq",_), [a; b])}, true) ->
      extract_le a b
    | Literal.Prop ({T.term=T.Node (S.Const ("$lesseq",_), [a; b])}, false) ->
      extract_lt b a
    | Literal.Prop ({T.term=T.Node (S.Const ("$greater",_), [a; b])}, true) ->
      extract_lt b a
    | Literal.Prop ({T.term=T.Node (S.Const ("$greater",_), [a; b])}, false) ->
      extract_le a b
    | Literal.Prop ({T.term=T.Node (S.Const ("$greatereq",_), [a; b])}, true) ->
      extract_le b a
    | Literal.Prop ({T.term=T.Node (S.Const ("$greatereq",_), [a; b])}, false) ->
      extract_lt a b
    | Literal.Prop _ -> []

  let to_lit ~ord lit = match lit with
  | Eq (t, m) -> Literal.mk_eq ~ord t (Monome.to_term m)
  | Neq (t, m) -> Literal.mk_neq ~ord t (Monome.to_term m)
  | L_less (t, m) -> Literal.mk_true (T.mk_less t (Monome.to_term m))
  | L_lesseq (t, m) -> Literal.mk_true (T.mk_lesseq t (Monome.to_term m))
  | R_less (m, t) -> Literal.mk_true (T.mk_less (Monome.to_term m) t)
  | R_lesseq (m, t) -> Literal.mk_true (T.mk_lesseq (Monome.to_term m) t)

  let simplify ~ord ~signature lit = match lit with
  | Literal.Equation (l, r, sign, _) ->
    Literal.mk_lit ~ord (T.simplify ~signature l) (T.simplify ~signature r) sign
  | Literal.Prop (p, sign) ->
    Literal.mk_prop (T.simplify ~signature p) sign
  | Literal.True
  | Literal.False -> lit

  let get_term = function
  | Eq (t, _)
  | Neq (t, _)
  | L_less (t, _)
  | L_lesseq (t, _)
  | R_less (_, t)
  | R_lesseq (_, t) -> t

  let get_monome = function
  | Eq (_, m)
  | Neq (_, m)
  | L_less (_, m)
  | L_lesseq (_, m)
  | R_less (m, _)
  | R_lesseq (m, _) -> m

  let eliminate ?(elim_var=(fun v -> true)) ~signature lit =
    (* unify non-arith subterms pairwise *)
    let fact_subterms lit =
      let l = get_term lit :: Monome.terms (get_monome lit) in
      let l = Util.list_diagonal l in
      Util.list_fmap
        (fun (t1, t2) ->
          try Some (Unif.unification t1 0 t2 0)
          with Unif.Fail -> None)
        l
    (* find substitutions that solve the lit *)
    and solve_lit lit =
      begin match lit with
      | Eq _ -> []
      | Neq (x, m) when T.is_var x ->
        (* eliminate x, if not shielded *)
        if not (Monome.var_occurs x m) && elim_var x
          then
            let subst = Substs.(bind empty x 0 (Monome.to_term m) 0) in
            [subst]
          else []
      | L_less(x, m)
      | R_less(m, x)
        when T.is_var x && TypeInference.check_term_type_sig signature x Type.int ->
        (* x < m  is inconsistent with x = m *)
        begin try
          [ Unif.unification x 0 (Monome.to_term m) 0]
        with Unif.Fail -> []  (* occur check... *)
        end
      | L_lesseq(x, m)
        when T.is_var x && TypeInference.check_term_type_sig signature x Type.int ->
        (* x <= m inconsistent with x = m+1 *)
        begin try
          [ Unif.unification x 0 (Monome.to_term (Monome.succ m)) 0 ]
        with Unif.Fail -> []  (* occur check... *)
        end
      | R_lesseq(m, x)
        when T.is_var x && TypeInference.check_term_type_sig signature x Type.int ->
        (* x >= m inconsistent with x = m-1 *)
        begin try
          [ Unif.unification x 0 (Monome.to_term (Monome.pred m)) 0 ]
        with Unif.Fail -> []  (* occur check... *)
        end
      | _ -> []
      end
    in
    solve_lit lit @ fact_subterms lit

  module L = struct
    let get_terms l = List.map get_term l

    let filter l p =
      List.filter
        (fun lit ->
          let t = get_term lit in
          let m = get_monome lit in
          p t m)
        l
  end
end

(** {2 Arrays of literals} *)

module Lits = struct
  let purify ~ord ~signature ~eligible lits =
    let new_lits = ref [] in
    let _add_lit lit = new_lits := lit :: !new_lits in
    let varidx = ref (T.max_var (Literals.vars lits) + 1) in
    (* purify a term (adding constraints to the list). [root] is true only
        if the term occurs in the outermost arith expression *)
    let rec purify_term ~root t = match t.T.term with
    | T.Var _
    | T.BoundVar _ -> t
    | T.Bind (s, t') -> T.mk_bind s (purify_term ~root:false t')
    | T.At (t1, t2) ->
      T.mk_at (purify_term ~root:false t1) (purify_term ~root:false t2)
    | T.Node (s,[]) when S.is_numeric s -> t
    | T.Node (s, l) when S.Arith.is_arith s ->
      if root
        then (* recurse, still in root arith expression *)
          T.mk_node s (List.map (purify_term ~root) l)
        else begin
          (* purify this term out! *)
          let ty = TypeInference.infer_sig signature t in
          let v = T.mk_var ~ty !varidx in
          incr varidx;
          (* purify the term and add a constraint *)
          let t' = purify_term ~root:true t in
          let lit = Literal.mk_neq ~ord v t' in
          _add_lit lit;
          (* return variable instead of literal *)
          v
        end
    | T.Node (s, l) -> T.mk_node s (List.map (purify_term ~root:false) l)
    in
    (* purify each literal *)
    Array.iteri
      (fun i lit ->
        if eligible i lit
          then match lit with
          | Literal.Equation (l, r, sign, _) ->
            let l = purify_term ~root:true l in
            let r = purify_term r ~root:true in
            let lit = Literal.mk_lit ~ord l r sign in
            _add_lit lit
          | Literal.Prop (p, sign) ->
            let p = purify_term ~root:true p in
            let lit = Literal.mk_prop p sign in
            _add_lit lit
          | Literal.True -> _add_lit lit
          | Literal.False -> ()  (* useless *)
          else _add_lit lit (* keep *)
      )
      lits;
    Array.of_list (List.rev !new_lits)

  let pivot ~ord ~signature ~eligible lits =
    let results = ref [] in
    let add_res a = results := a :: !results in
    for i = 0 to Array.length lits - 1 do
      if eligible i lits.(i) then begin
        (* try to pivot the i-th literal *)
        let pivots = Lit.extract ~signature lits.(i) in
        (* only keep maximal terms *)
        let terms = Lit.L.get_terms pivots in
        let terms = Multiset.create terms in
        let bv = Multiset.max (Ordering.compare ord) terms in
        let terms = BV.select bv (Multiset.to_array terms) in
        List.iter
          (fun lit' ->
            (* build a new literal from lit', if the term is maximal *)
            let t = Lit.get_term lit' in
            if List.exists (fun (t',_) -> T.eq t t') terms then
              let lits = Util.array_except_idx lits i in
              let lits = Lit.to_lit ~ord lit' :: lits in
              let lits = Array.of_list lits in
              add_res lits
          )
          pivots
      end
    done;
    !results
end

(** {2 Inference Rules} *)

let rewrite_lit ~ctx lit =
  let signature = Ctx.signature ~ctx in
  match lit with
  | Literal.Prop (p, sign) ->
    let p' = T.simplify ~signature p in
    begin match p'.T.term, sign with
    | T.Node (S.Const("$less",_), [l;r]), false ->
      (* not (l < r) ---> r <= l *)
      Literal.mk_true (T.mk_lesseq r l)
    | T.Node (S.Const("$lesseq",_), [l;r]), false ->
      (* not (l <= r) ---> r < l *)
      Literal.mk_true (T.mk_less r l)
    | _ -> Literal.mk_prop p' sign
    end
  | Literal.Equation (l, r, sign, _) ->
    let l' = T.simplify ~signature l in
    let r' = T.simplify ~signature r in
    Literal.mk_lit ~ord:(Ctx.ord ctx) l' r' sign 
  | Literal.True
  | Literal.False -> lit

let factor_arith c =
  let ctx = c.C.hcctx in
  let signature = Ctx.signature ctx in
  let eligible = C.Eligible.param c in
  (* we can eliminate variables that are not shielded *)
  let elim_var x = not (Literals.shielded c.C.hclits x) in
  (* eliminate i-th literal with [subst] *)
  let eliminate_lit i subst =
    let lits' = Util.array_except_idx c.C.hclits i in
    let renaming = Ctx.renaming_clear ~ctx in
    let ord = Ctx.ord ctx in
    let lits' = Literal.apply_subst_list ~ord ~renaming subst lits' 0 in
    let proof cc = Proof.mk_c_step ~theories:["arith";"equality"]
      ~rule:"factor" cc [c.C.hcproof] in
    let new_c = C.create ~parents:[c] ~ctx lits' proof in
    new_c
  in
  (* try to factor arith literals *)
  Literals.fold_lits ~eligible c.C.hclits []
    (fun acc lit i ->
      let ord_lits = Lit.extract ~signature lit in
      let substs = Util.list_flatmap (Lit.eliminate ~elim_var ~signature) ord_lits in
      List.fold_left
        (fun acc subst -> eliminate_lit i subst :: acc)
        acc substs)

let pivot_arith c =
  let ctx = c.C.hcctx in
  let instance = Theories.TotalOrder.tstp_instance (Ctx.total_order ctx) in
  let eligible = C.Eligible.(combine [param c; ineq_of c instance]) in
  let lits'_list = Lits.pivot ~ord:(Ctx.ord ctx) ~signature:(Ctx.signature ctx)
    ~eligible c.C.hclits
  in
  Util.list_fmap
    (fun lits' ->
      if Literals.eq_com c.C.hclits lits'
        then None
        else begin
          (* build new clause *)
          let proof cc = Proof.mk_c_step ~theories:["equality";"arith"]
            ~rule:"arith_pivot" cc [c.C.hcproof] in
          let new_c = C.create_a ~parents:[c] ~ctx lits' proof in
          Util.debug 3 "arith_pivot of %a: %a" C.pp c C.pp new_c;
          Some new_c
        end)
    lits'_list

let purify_arith c =
  let ctx = c.C.hcctx in
  let eligible = C.Eligible.(combine [param c; ineq c]) in
  let lits' = Lits.purify ~ord:(Ctx.ord ctx) ~signature:(Ctx.signature ctx)
    ~eligible c.C.hclits
  in
  if Literals.eq_com c.C.hclits lits'
    then []
    else begin
      let proof cc = Proof.mk_c_step ~rule:"purify" cc [c.C.hcproof] in
      let new_c = C.create_a ~ctx ~parents:[c] lits' proof in
      [new_c]
    end

let axioms =
  (* parse a pformula *)
  let pform ~name s =
    let f = Parse_tptp.parse_formula Lex_tptp.token (Lexing.from_string s) in
    let proof = Proof.mk_f_axiom f ~file:"/dev/arith" ~name in
    let pf = PF.create f proof in
    pf
  in
  [ pform ~name:"sum_assoc" "$sum($sum(X,Y),Z) = $sum(X,$sum(Y,Z))"
  ; pform ~name:"sum_com" "$sum(X,Y) = $sum(Y,X)"
  ; pform ~name:"product_assoc" "$product($product(X,Y),Z) = $product(X,$product(Y,Z))"
  ; pform ~name:"product_com" "$product(X,Y) = $product(Y,X)"
  ]

(** {2 Setup} *)

let setup_penv ~penv =
  (* rule for formula simplification *)
  let simplify_rule set =
    let signature = PF.Set.signature set in
    fun set pf ->
      let f' = F.simplify ~signature pf.PF.form in
      if F.eq pf.PF.form f'
        then PEnv.DoNothing
        else
          let proof = Proof.mk_f_step f' ~rule:"arith_simplify" [pf.PF.proof] in
          let pf' = PF.create f' proof in
          PEnv.SimplifyInto pf'
  in
  (* signature of arith symbols *)
  PEnv.add_base_sig ~penv Signature.Arith.signature;
  PEnv.add_axioms ~penv (Sequence.of_list axioms);
  PEnv.add_operation_rule ~penv ~prio:2 simplify_rule;
  ()

let setup_env ~env =
  Env.add_lit_rule ~env "arith_rw" rewrite_lit;
  Env.add_unary_inf ~env "arith_factor" factor_arith;
  Env.add_unary_inf ~env "arith_pivot" pivot_arith;
  Env.add_unary_inf ~env "arith_purify" purify_arith;
  (* be sure that the ordering is present in the context *)
  Ctx.add_order ~ctx:(Env.ctx env) ~less:S.Arith.less ~lesseq:S.Arith.lesseq;
  ()