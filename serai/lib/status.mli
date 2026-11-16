(** The live side, read-only: who holds each host's lock, and each app's
    jail and releases. Nothing here takes a lock or changes a host. *)

type lock_state =
  | Free
  | Held of {
      holder : string;
      age_seconds : int;
      stale : bool;  (** older than {!Remote_lock.stale_after_seconds} *)
      holder_alive : bool option;
          (** known only when the holder is a run on this machine *)
    }
  | Lock_unavailable of string

type lock = { host : string; lock : lock_state }

(** Every configured host's lock, or only [only]'s (a host id or guest). *)
val locks : ?only:string -> Remote_host.env -> lock list

type jail = Jail_absent | Jail_ready | Jail_needs_env of string

type app_state =
  | Live of { jail : jail; releases : Release_probe.t option }
  | App_unavailable of string

type app = { app : string; host : string; ip : string; state : app_state }

(** Every app's jail and releases, or only [only]'s: one connection each. *)
val apps : ?only:string -> Remote_host.env -> app list

val lock_json : lock -> Json.t
val app_json : app -> Json.t
val lock_line : lock -> string
val app_line : app -> string
