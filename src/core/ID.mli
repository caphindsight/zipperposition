
(* This file is free software, part of Logtk. See file "license" for more details. *)

(** {1 Unique Identifiers}

    An {!ID.t} is a unique identifier (an integer) with a human-readable name.
    We use those to give names to variables that are not hashconsed (the hashconsing
    does not play nice with names)

    @since NEXT_RELEASE *)

type t = private {
  id: int;
  name: string;
  mutable payload: exn; (** Use [exn] as an open type for user-defined payload *)
}

val make : string -> t
(** Makes a fresh ID *)

val makef : ('a, Format.formatter, unit, t) format4 -> 'a

val copy : t -> t
(** Copy with a new ID *)

val id : t -> int
val name : t -> string
val payload : t -> exn

exception No_payload

val set_payload : ?can_erase:(exn -> bool) -> t -> exn -> unit
(** Set given exception as payload.
    @param can_erase if provided, checks whether the current value
      can be safely erased.
    @raise Invalid_argument if there already is a payload. *)

val set_payload_erase : t -> exn -> unit
(** Set given exception as payload. Erases any previous value. *)

include Interfaces.HASH with type t := t
include Interfaces.ORD with type t := t
include Interfaces.PRINT with type t := t

(** NOTE: default printer does not display the {!id} field *)

val pp_full : t CCFormat.printer
(** Prints the ID with its internal number *)

val pp_fullc : t CCFormat.printer
(** Prints the ID with its internal number colored in gray (better for
    readability). Only use for debugging. *)

val gensym : unit -> t
(** Generate a new ID with a new, unique name *)

module Map : CCMap.S with type key = t
module Set : CCSet.S with type elt = t
module Tbl : CCHashtbl.S with type key = t


