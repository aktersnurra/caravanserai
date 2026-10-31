(** Renders [root_template] as Caddyfile and each template in [sites] as
    conf.d/<name>, without the .template suffix. *)
val render : ?proxy:string list -> edge:Edge_config.t -> root_template:string -> sites:string ->
  Network_endpoint.validated ->
  ((string * string) list, string) result

val placeholders : edge:Edge_config.t -> Network_endpoint.validated -> (string * string) list
val substitute : placeholders:(string * string) list -> string -> string
val find_unsubstituted : string -> string option
val template_names : string -> string list
