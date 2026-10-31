type t = private {
  layout : Layout.t;
  apps : App_config.t list;
  guests : Guest_config.t list;
  endpoints : Network_endpoint.validated;
  edge : Edge_config.t;
  topology : Topology.t option; (** Always present after [load]; pure render fixtures may omit it. *)
}
type error =
  | Invalid_endpoints of Network_endpoint.error list
  | Invalid_file of string * string
  | Read_error of string

val create : layout:Layout.t -> apps:App_config.t list -> guests:Guest_config.t list ->
  edge:Edge_config.t -> (t, error) result
val load : layout:Layout.t -> (t, error) result
val error_message : error -> string

(** Printable form of an input-boundary exception (Sexplib conversion,
    Failure, Sys_error); used where rendering still reports by exception. *)
val describe : exn -> string
