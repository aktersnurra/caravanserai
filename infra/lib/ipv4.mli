(** IPv4 addresses and subnets in canonical dotted decimal, for placing
    workloads on a host's network. *)

type address = private int

(** Four decimal octets, each 0-255 with no leading zero, so one address has
    one spelling. *)
val address : string -> address option

val to_string : address -> string

type subnet = private { base : address; prefix : int }

(** [a.b.c.d/n] with [n] in 8-30 and no host bits set in [a.b.c.d]. *)
val subnet : string -> (subnet, string) result

val subnet_to_string : subnet -> string

(** In the subnet, and neither its network nor its broadcast address. *)
val is_host : subnet -> address -> bool

(** The subnet's host addresses, ascending. *)
val hosts : subnet -> address Seq.t
