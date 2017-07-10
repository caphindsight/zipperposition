
(* This file is free software, part of Logtk. See file "license" for more details. *)

(** {1 Hashconsed Variable} *)

type +'a t = {
  id: int;
  ty: 'a;
}
type 'a hvar = 'a t

let id t = t.id
let ty t = t.ty

let make ~ty i =
  if i < 0 then invalid_arg "HVar.make";
  { id=i; ty; }

let cast v ~ty = {v with ty; }
let update_ty v ~f = {v with ty=f v.ty; }

let compare cmp a b =
  let c = CCOrd.int a.id b.id  in
  if c<>0 then c else cmp a.ty b.ty
let equal eq a b = a.id = b.id && eq a.ty b.ty
let hash a = Hash.int a.id

let max a b = if a.id < b.id then b else a
let min a b = if a.id < b.id then a else b

let pp out v = Format.fprintf out "X%d" v.id
let pp_tstp = pp
let to_string v = CCFormat.to_string pp v
let to_string_tstp = to_string

let make_unsafe ~ty id = {ty; id; }

let fresh_ = ref ~-1
let fresh ~ty () =
  if !fresh_ > 0 then failwith "HVar.fresh_var: underflow";
  let v = make_unsafe ~ty !fresh_ in
  decr fresh_;
  v

let is_fresh v = id v < 0
