val fields_of_sexp : context:string -> known:string list -> Sexplib.Sexp.t ->
  (string * Sexplib.Sexp.t) list
val field : context:string -> string -> (string * Sexplib.Sexp.t) list -> Sexplib.Sexp.t
val atom : context:string -> Sexplib.Sexp.t -> string
val list : context:string -> (Sexplib.Sexp.t -> 'item) -> Sexplib.Sexp.t -> 'item list
