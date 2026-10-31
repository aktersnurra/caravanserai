(** Validated placement and transport, not an operation scheduler. *)
type os = Freebsd | Linux
(** Where a FreeBSD host builds artifacts: a disposable jail address and the
    pinned base archive extracted into it. *)
type build = private { ip : string; base_url : string; base_sha256 : string }

(** A FreeBSD host's workload network: the subnet its jails and guests
    share, the host's own address on it, and the guest bridge's address
    when it runs bhyve guests. Addresses are canonical dotted decimal. *)
type network = private { subnet : Ipv4.subnet; gateway : string; guest_bridge : string option }

(** [network] is [Some] exactly for a FreeBSD host. *)
type host = private {
  id : string; os : os; ssh : string; via : string option; build : build option;
  network : network option;
}
type guest = private { name : string; host : string; via : string option }
type t
val of_sexp : Sexplib.Sexp.t -> t
val load : string -> t
val validate_workloads : t -> apps:string list -> guests:string list -> (unit, string) result

(** [ip] may be given to a jail or guest on [host]: a host address on its
    network other than the gateway and guest bridge. *)
val check_workload_ip : host -> string -> (unit, string) result

(** [ips] pairs each jail and guest with its declared address. Each must be
    one [check_workload_ip] allows on the host it is placed on, and not that
    host's build address. *)
val validate_addresses : t -> ips:(string * string) list -> (unit, string) result

(** [exposed] names the workloads that declare tailnet ports; it must equal [proxy]. *)
val validate_proxy : t -> exposed:string list -> (unit, string) result
val hosts : t -> host list
val host : t -> string -> host
val edge : t -> host
val jail_host : t -> string -> host
val guest : t -> string -> guest
val guest_host : t -> string -> host
val compute_hosts : t -> host list
val host_jumps : t -> host -> string list
val guest_jumps : t -> string -> string list
val proxy_workloads : t -> string list
val workloads_on : t -> string -> string list
