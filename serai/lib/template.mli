(** Literal text substitution, for the templates serai fills. *)

(** Every occurrence, left to right. [Invalid_argument] on an empty pattern. *)
val replace_all : pattern:string -> with_:string -> string -> string

(** Each placeholder in turn, replaced by its value everywhere. *)
val substitute : placeholders:(string * string) list -> string -> string
