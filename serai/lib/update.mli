(** serai update: deploys a newer version of each source-built app that is
    already running, once CI has moved its repository's deploy bookmark to
    a commit signed by an allowed key, and never anything else. The
    configuration is read from a signed commit of its own remote, staged
    locally. Judgements live in {!Update_decision}; this module gathers the
    facts and acts. *)

(** The updater's own settings, from ~/.config/serai/update.sexp:
    {v
    ((config (git <configuration remote>) (bookmark <its branch>))
     (signers (<key id as jj reports it> ...))
     (gnupghome <directory holding only the signers' public keys>))
    v} *)
type config = {
  config_url : string;
  config_bookmark : string;
  signers : string list;
  gnupghome : string;
}

val config_of_string : string -> (config, string) result

(** The bookmark CI moves in each app's repository. *)
val deploy_bookmark : string

(** The configuration's mirror under [cache]/sources; not an app name,
    which never holds a dot. *)
val configuration_mirror : string

type paths = {
  state_dir : string;  (** {!Update_state}'s directory and run lock *)
  cache : string;  (** source mirrors, base archives, configuration snapshots *)
  store : string;  (** verified artifacts *)
  engine : string;  (** the installed engine the snapshot is run on *)
}

type revert = Not_attempted of string | Reverted | Revert_failed of string

type outcome =
  | Not_enrolled  (** no deploy bookmark, or no declared source *)
  | Already_handled of string
  | Current of string
  | Would_deploy of string  (** --plan only *)
  | Deployed of { commit : string; identity : string }
  | Refused of { commit : string; refusal : Update_decision.refusal }
  | Failed of { commit : string; step : Dispatcher.up_step; message : string; revert : revert }
  | Not_applied of { commit : string option; message : string }
      (** nothing changed on the host; tried again next run *)

type configuration =
  | Configuration of string  (** the verified commit the run used *)
  | Configuration_refused of { commit : string; refusal : Update_decision.refusal }
  | Configuration_unavailable of string

type report = { configuration : configuration; apps : (string * outcome) list }

(** [env_of_layout] builds the dispatcher's env for the staged
    configuration; it must never ask for confirmation. *)
type deps = { jj_bin : string; env_of_layout : Layout.t -> Dispatcher.env }

(** Every app's status, changing nothing: no lock, no state written, no
    deploy. *)
val plan : deps -> config -> paths -> report

type run = { report : report; lines : string list; failed : bool }

(** One run under the run lock: [None] when another run holds it. [lines]
    are only those not already reported; [failed] is whether one of them
    is a refusal or failure. *)
val run : deps -> config -> paths -> run option

(** One line per status, for --plan. *)
val plan_lines : report -> string list
