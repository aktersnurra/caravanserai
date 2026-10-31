(** The syslog-ng configs central logging installs on a FreeBSD host, from
    the declarations: every sender forwards to the receiver's address and
    syslog tailnet port, and the host relay also accepts the host's bhyve
    guests on its guest bridge, at that same port, from their addresses
    only. *)

type t

type error =
  | No_syslog_port of string  (** the receiver declares no [syslog] tailnet port *)
  | No_guest_bridge of string  (** guests on a host without a guest bridge *)

(** Where every sender forwards: an address and its syslog port. *)
type receiver

(** The logs app's endpoint, which must declare a [syslog] tailnet port. *)
val receiver : Network_endpoint.t -> (receiver, error) result

(** [host] is the host the receiver and the senders run on, [guests] the
    endpoints of the guests placed there. *)
val v : receiver:receiver -> host:Topology.host -> guests:Network_endpoint.t list -> (t, error) result

val error_message : error -> string

(** The host relay: copies of host syslogd's files, and the guests' TCP
    syslog when there are guests. *)
val render_host : t -> string

(** A jail sender's base, to which the installer appends the jail's reviewed
    sender: its local socket kept on local disk, and the receiver. *)
val render_jail : t -> string

(** The guest bridge address the host relay listens on, or "" with no guests. *)
val render_bridge : t -> string

(** The edge host sender's config: [template] with __LOGS_IP__ and
    __LOGS_SYSLOG_PORT__ filled from the receiver. *)
val render_edge_sender : receiver -> template:string -> string

(** "<ip> <port>\n", for the edge host installer's route and receiver checks. *)
val render_receiver : receiver -> string
