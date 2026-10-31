(** infra up's read-only look at an app's own jail before anything changes:
    whether /jails/<app> exists, which jails hold which addresses (running,
    or configured in /etc/jail.conf, declared or not), and the owner of its
    env file. The script reports facts; [check] decides. *)

(** Run as root on the compute host. Never reads the env file. *)
val script : app:string -> string

type state =
  | Absent  (** no jail yet, and its address is free *)
  | Present of (unit, string) result
      (** at its declared address; [Error] says how to put its env in place *)

(** Refuses an address another jail holds, a jail at another address, and
    any answer the probe did not give clearly. *)
val check : app:string -> ip:string -> string -> (state, string) result
