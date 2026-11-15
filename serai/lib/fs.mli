(** The local filesystem, as the store, the caches and the stagers use it. *)

type privacy =
  | Private  (** a directory, this user's, closed to everyone else *)
  | Unsafe  (** anything else that exists, a symlink included *)
  | Missing

val private_directory : string -> privacy

(** Creates a missing directory, and its missing parents, private. False
    when it exists and is not {!Private}. *)
val ensure_private_directory : string -> bool

(** A regular file's SHA-256 in hex; [Failure not_regular] for anything else. *)
val file_sha256 : not_regular:string -> string -> string

(** Removes a tree without following a symlink; a missing path is nothing
    to remove. *)
val remove_tree : string -> unit
