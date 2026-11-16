(** Digests and commit ids as text: lowercase hex of a fixed length. *)

val is_lower : string -> bool

(** 64 lowercase hex digits. *)
val is_sha256 : string -> bool

(** A full git commit id: 40 lowercase hex digits. *)
val is_commit : string -> bool

(** A commit id of either object format: 40 or 64 digits. *)
val is_object_id : string -> bool

(** The first 12 characters, for messages. *)
val short : string -> string
