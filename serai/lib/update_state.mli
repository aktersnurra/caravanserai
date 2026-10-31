(** What serai update remembers between runs, per app: the deploy commit
    whose outcome was final ([handled], so it is not tried again until the
    ref moves) and the last line reported (so a result is reported once,
    until it changes). Also the run lock that keeps two runs apart. *)

type app = { handled : string option; reported : string option }
type t = { config_reported : string option; apps : (string * app) list }

val empty : t

(** An app never recorded has nothing handled or reported. *)
val find : t -> string -> app

val set : t -> string -> app -> t

(** Only the apps in [apps], so a removed app's record does not linger. *)
val retain : t -> apps:string list -> t

val to_string : t -> string

(** Refuses anything [to_string] would not write. *)
val of_string : string -> (t, string) result

(** [dir]/state.sexp; a missing file is [empty], an unreadable one an
    error, never [empty]. [dir] is created private, or must already be. *)
val load : dir:string -> (t, string) result

(** Replaces [dir]/state.sexp at once (temporary file and rename), 0600. *)
val save : dir:string -> t -> (unit, string) result

(** Runs [f] holding a lock on [dir]/lock, or returns [None] at once when
    another process holds it. The lock goes with the process, so a run
    that dies never wedges the next. Fails when [dir] is not private. *)
val with_run_lock : dir:string -> (unit -> 'a) -> 'a option
