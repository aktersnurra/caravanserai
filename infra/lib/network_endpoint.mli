type named_port = { port_name : string; port : int }

type t = private {
  name : string;
  ip : string;
  hostname : string;
  tailnet_ports : named_port list;
  operator_ports : named_port list;
}

type port_access = Tailnet | Operator

type error =
  | Invalid_name of string
  | Invalid_ip of string * string
  | Invalid_hostname of string * Domain_name.error
  | Invalid_port_name of string * string
  | Invalid_port of string * port_access * named_port
  | Duplicate_port_name of string * port_access * string
  | Duplicate_port of string * port_access * int
  | Duplicate_name of string * string * string
  | Duplicate_ip of string * string * string
  | Duplicate_hostname of string * string * string  (** hostname, first and second workload *)

(** Validates a single endpoint, including ports within each access class. *)
val create : name:string -> ip:string -> hostname:string ->
  tailnet_ports:named_port list -> operator_ports:named_port list ->
  (t, error list) result

(** Evidence that every endpoint is valid and names, IPs and hostnames are unique. *)
type validated
val validate_all : t list -> (validated, error list) result
val to_list : validated -> t list
val errors_message : error list -> string

(** [a-z0-9]+: the grammar names and port names follow, so a derived Caddy
    placeholder or jail name cannot collide or carry syntax. *)
val is_placeholder_safe : string -> bool

val field_names : string list

(** Sexplib adapter: malformed fields raise Of_sexp_error at the input boundary. *)
val of_fields : (string * Sexplib.Sexp.t) list -> t
