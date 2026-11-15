(** Quotes one argument for a POSIX shell. *)
val quote : string -> string

(** The answers a remote probe printed: the rest of each line of the output
    that starts with [marker], in order. *)
val answers : marker:string -> string -> string list
