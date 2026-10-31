(** serai jail-test's pure parts: the rules a test jail <app>test must
    satisfy, its retargeted jail script, the existing-jail probe and the
    script that destroys one. *)

(** <app>test. *)
val name : App_config.t -> string

(** Refuses a name that is not [a-z0-9]+test or is a [declared] endpoint's. *)
val validate_name : declared:string list -> string -> (unit, string) result

(** [ip] is one [Topology.check_workload_ip] allows on [host], and no
    declared endpoint's. *)
val validate_ip : host:Topology.host -> declared:string list -> string -> (unit, string) result

(** The app at [ip], its endpoint rebuilt through [Network_endpoint.create];
    nothing but the ip changes. *)
val retarget : App_config.t -> ip:string -> (App_config.t, Network_endpoint.error list) result

(** The app's generated jail script on jail <app>test at [ip]. *)
val render : App_config.t -> ip:string -> (string, Network_endpoint.error list) result

(** Read-only probe for an existing /jails/<name> and its jail.conf ip. The
    paths are parameters only so tests can run it against temp files. *)
val existing_ip_script : ?jail_conf:string -> ?jails_dir:string -> name:string -> unit -> string

type existing = Absent | Same_ip

(** Accepts only a clear "absent" or the same ip from the probe's output. *)
val check_existing : app:string -> name:string -> ip:string -> string -> (existing, string) result

(** Run as root on the compute host: reports the owner, group and mode of the test
    jail [name]'s /etc/[app]/env, or that there is none (or no running jail).
    Never reads the file. *)
val env_file_script : name:string -> app:string -> string

(** [Ok] only for the probe's report of an env file [root:app 0640]; the
    error says exactly how the operator puts it in place or fixes it. *)
val check_env_file : app:string -> name:string -> string -> (unit, string) result

(** The test jail's own ZFS dataset, when its strategy has one. *)
val dataset : App_config.t -> string option

(** A jail name, and optional dataset, both ending in test: the only thing
    [destroy_script] accepts. *)
type destroy_target

val validate_destroy_target : name:string -> ?dataset:string -> unit -> (destroy_target, string) result

(** Run as root on the compute host; refuses a non-test name or dataset again inside
    the sh. *)
val destroy_script : destroy_target -> string
