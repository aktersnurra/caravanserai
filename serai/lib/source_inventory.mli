(** Digest inventory of a private, commit-derived local source snapshot.
    The inventory is not proof that a remote builder received these bytes. *)
type t

val create : root:string -> commit:string -> (t, string) result
val canonical : t -> string
val identity : t -> string
