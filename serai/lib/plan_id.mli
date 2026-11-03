(** A plan's name: an apply given one refuses to apply any other plan.
    Pure. Binding guards against change between plan and apply, not against
    an adversary, so 64 bits are enough. *)

(** 16 lowercase hex characters. *)
type t = private string

(** The first 64 bits of BLAKE2b-256 over the operation, the format version
    and each part, every one length-prefixed: the same parts always give the
    same id, and no other operation's plan can. *)
val make : operation:string -> string list -> t

(** An id as a user or agent passed it, e.g. to [--expect-plan]. *)
val parse : string -> (t, string) result

val to_string : t -> string
