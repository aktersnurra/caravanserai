(** [render ()]'s result as the file at [path], or an Error naming [path].
    Sys.Break propagates. *)
val catch_render : string -> (unit -> string) -> (string * string, string) result
val render_all : Declaration.t -> ((string * string) list, string) result
val summary : Declaration.t -> (string * string) list -> string
