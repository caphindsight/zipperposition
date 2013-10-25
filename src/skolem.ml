
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

(** {1 Skolem symbols} *)

module T = FOTerm
module F = FOFormula
module S = Substs.FO

type ctx = {
  sc_gensym : Symbol.Gensym.t;                  (* new symbols *)
  mutable sc_var_index : int;                   (* fresh universal vars *)
  mutable sc_cache : (T.t * T.t) list;  (* term -> skolemized term *)
  mutable sc_fcache : (F.t * F.t) list; 
  mutable sc_signature : Signature.t;
}

(* TODO: use a term index for the cache? *)

let create ?(prefix="logtk_sk__") () =
  let ctx = {
    sc_gensym = Symbol.Gensym.create ~prefix ();
    sc_var_index = 0;
    sc_cache = [];
    sc_fcache = [];
    sc_signature = Signature.empty;
  } in
  ctx

let to_signature ctx = ctx.sc_signature

let fresh_sym ~ctx =
  Symbol.Gensym.new_ ctx.sc_gensym

(* update varindex in [ctx] so that it won't get captured in [t] *)
let update_var ~ctx t =
  ctx.sc_var_index <- max ctx.sc_var_index (T.max_var (T.vars t) + 1)

let fresh_var ~ctx =
  let n = ctx.sc_var_index in
  ctx.sc_var_index <- n + 1;
  n

exception FoundVariant of T.t * T.t * S.t

let skolem_term ~ctx ~ty t =
  let vars = T.vars_prefix_order t in
  (* find the skolemized normalized term *)
  try
    List.iter
      (fun (t', new_t') ->
        try
          let subst = FOUnif.variant t' 1 t 0  in
          raise (FoundVariant (t', new_t', subst))
        with FOUnif.Fail ->
          ())
      ctx.sc_cache;
    (* not found, use a fresh symbol *)
    let symb = fresh_sym ~ctx in
    (* replace the existential variable by [skolem_term] in [t] *)
    let skolem_term = T.mk_node symb vars in
    let new_t = T.db_unlift (T.db_replace t skolem_term) in
    (* update cache with new symbol *)
    ctx.sc_cache <- (t, new_t) :: ctx.sc_cache;
    (* update signature *)
    ctx.sc_signature <- Signature.declare ctx.sc_signature symb ty;
    Util.debug 5 "new skolem symbol %a with type %a" Symbol.pp symb Type.pp ty;
    new_t
  with FoundVariant (t',new_t',subst) ->
    let renaming = S.Renaming.create 5 in
    let new_t = S.apply ~renaming subst new_t' 1 in
    new_t

exception FoundFormVariant of F.t * F.t * S.t

let skolem_form ~ctx ~ty f =
  let vars = F.free_variables f in
  (* find a variant of [f] *)
  try
    List.iter
      (fun (f', new_f') ->
        Util.debug 5 "check variant %a and %a" F.pp f F.pp f';
        Sequence.iter
          (fun subst -> raise (FoundFormVariant (f', new_f', subst)))
          (FOUnif.form_variant f' 1 f 0))
      ctx.sc_fcache;
    (* fresh symbol *)
    let symb = fresh_sym ~ctx in
    let skolem_term = T.mk_node symb vars in
    (* replace variable by skolem t*)
    let new_f = F.db_unlift (F.db_replace f skolem_term) in
    ctx.sc_fcache <- (f, new_f) :: ctx.sc_fcache;
    (* update signature *)
    ctx.sc_signature <- Signature.declare ctx.sc_signature symb ty;
    Util.debug 5 "new skolem symbol %a with type %a" Symbol.pp symb Type.pp ty;
    new_f
  with FoundFormVariant(f',new_f',subst) ->
    Util.debug 5 "form %a is variant of %a under %a" F.pp f' F.pp f S.pp subst;
    let renaming = S.Renaming.create 5 in
    let new_f = S.apply_f ~renaming subst new_f' 1 in
    new_f

let skolem_ho ~ctx ~ty f = failwith "Skolem_ho: not implemented"
