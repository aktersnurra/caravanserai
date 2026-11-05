(** Edge settings that belong to no single app or guest. [operator] is the
    Headscale user who owns the tags and may reach the hosts' and guests'
    operator ports. [operator_edge_ports] are the edge host's own ports the
    operator's devices may reach over the tailnet, e.g. its mail server;
    empty when edge.sexp omits them. *)
type t = private {
  base_domain : string;
  operator : string;
  operator_edge_ports : Network_endpoint.named_port list;
}

type error =
  | Invalid_base_domain of Domain_name.error
  | Invalid_operator of string
  | Invalid_operator_edge_port of Network_endpoint.named_port
  | Duplicate_operator_edge_port of int
  | Duplicate_operator_edge_port_name of string

val create : ?operator_edge_ports:Network_endpoint.named_port list ->
  base_domain:string -> operator:string -> unit -> (t, error) result
val error_message : error -> string
val of_sexp : Sexplib.Sexp.t -> t
val load : string -> t
