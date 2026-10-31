(** A bhyve guest's declaration (guests/<name>/guest.sexp): its network
    endpoint, which the edge renderers read, and the facts serai's guest
    lifecycle needs -- who it logs in as, where the source it builds lives
    on the operator's machine, and the OCaml workload it builds. *)

(** The OCaml executable serai builds in a Linux guest and installs as a
    release. *)
type workload = private {
  project : string;
      (** The dune project directory within the source: relative, components of
          [A-Za-z0-9_.-], none of them [.] or [..]. *)
  target : string;  (** The dune executable target within it, by the same rule. *)
  release : string;
      (** [a-z][a-z0-9_-]*, at most 63: the installed executable, its systemd
          unit and /opt/<release>. *)
  service_group : string;  (** [a-z_][a-z0-9_-]*: the group that may read the release. *)
}

type t = private {
  endpoint : Network_endpoint.t;
  login_user : string;  (** [a-z_][a-z0-9_-]*: the account ssh reaches the guest as *)
  source_checkout : string;
      (** Non-empty, no newline. Relative paths are taken against the
          repository root when used. *)
  workload : workload option;  (** None: serai provisions the guest but builds nothing in it. *)
}

type error =
  | Invalid_login_user of string * string  (** guest name, value *)
  | Invalid_source_checkout of string * string  (** guest name, value *)
  | Invalid_workload of string * string * string  (** guest name, field, value *)

val workload : guest:string -> project:string -> target:string -> release:string ->
  service_group:string -> (workload, error) result

val create : ?workload:workload -> endpoint:Network_endpoint.t -> login_user:string ->
  source_checkout:string -> unit -> (t, error) result
val error_message : error -> string
val endpoint : t -> Network_endpoint.t
val name : t -> string

(** Sexplib adapter: malformed or invalid fields raise Of_sexp_error. *)
val of_sexp : Sexplib.Sexp.t -> t
val load : string -> t
val load_all : string -> t list
