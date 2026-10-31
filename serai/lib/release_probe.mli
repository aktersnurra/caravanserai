(** The updater's read-only look at an app's releases on the compute host:
    which release /opt/<app> points at, the source commit recorded beside
    it, and the release kept in .previous for rollback. The script reports
    facts; [check] decides. *)

(** Run as root on the compute host. Reads release pointers and the
    .infra-source record only; never the env file. *)
val script : app:string -> string

type t = {
  active : string option;  (** identity behind /opt/<app> *)
  source : string option;  (** the commit recorded beside the active release *)
  previous : string option;  (** identity behind .previous *)
}

(** Refuses a pointer outside .infra-releases/<app>/, a malformed identity
    or commit, and any answer the script did not give exactly once. *)
val check : app:string -> string -> (t, string) result
