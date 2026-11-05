(** An app's drift: what its compute host runs against what its repository
    says should run. Pure; the host's and the mirror's answers come in. *)

type state =
  | Current  (** the live commit is the target *)
  | Behind  (** the target descends from the live commit *)
  | Diverged  (** it doesn't: a local deploy, or a rewritten branch *)
  | Not_deployed  (** no active release *)
  | Unknown  (** an active release with no source record *)

(** [current], [behind], [diverged], [not_deployed], [unknown]. *)
val state_to_string : state -> string

(** Whether serai up would change what runs: [Behind], [Diverged],
    [Not_deployed]. Only these get a plan. *)
val drifted : state -> bool

(** The commit an app should run, and the revision named it: ["deploy"]
    (CI-approved, as serai update deploys) or the default branch's name. *)
type target = { revision : string; commit : string }

(** The [deploy] bookmark's commit when the repository has one; otherwise
    the default branch (name, commit), forced only then. *)
val target :
  deploy:string option -> default_branch:(string * string, string) result Lazy.t -> (target, string) result

(** The state from the release probe's answer and the target commit.
    [descends] answers whether the target descends from the live commit;
    it is asked only when the two differ. *)
val decide :
  Release_probe.t -> target:string -> descends:(unit -> (bool, string) result) -> (state, string) result
