(** Offline artifact model derived from the existing declarations. It does not
    inspect a host, build source, read secrets, or claim that deployment has
    happened. Source-built artifacts require an explicit source revision. *)

type target = Freebsd_jail of string | Linux_guest of string

type origin =
  | Phoenix_source of { checkout : string; revision : string; release_name : string }
  | Ocaml_source of { checkout : string; revision : string }
  | Guest_source of { checkout : string; revision : string }
  | Verified_binary of { version : string; sha256 : string }
  | Freebsd_packages of string list

type t = private {
  name : string;
  target : target;
  origin : origin;
  artifact_dir : string option;
}

val of_app : ?revision:string -> App_config.t -> (t, string) result
val of_guest : ?revision:string -> Guest_config.t -> (t, string) result
val render : t -> string
