(** Every judgement serai update makes, as pure functions over the facts
    its driver gathers: whether a deploy ref is worth a look, whether a
    commit may be deployed, whether a failed release is reverted, and
    whether a result is worth reporting again. No effects. *)

(** The look before the host is touched: [desired] is the deploy ref's
    commit, [handled] the last commit whose outcome was final. *)
type triage = Not_enrolled | Already_handled | Examine of string

val triage : desired:string option -> handled:string option -> triage

type refusal =
  | Unsigned
  | Bad_signature of Source_mirror.signature_status
  | Key_not_allowed of string
  | No_deployed_record  (** the host has no source record: deploy once by hand *)
  | Not_newer of { deployed : string }

type verdict = Current | Deploy | Refuse of refusal

(** Good, and by a non-empty key on [allowed]; otherwise why not. *)
val check_signature : allowed:string list -> Source_mirror.signature -> (unit, refusal) result

(** In order: already deployed is [Current]; then the signature must pass
    [check_signature]; then the host must have a record; then [desired]
    must descend from it ([descends]). *)
val examine :
  desired:string -> deployed:string option -> signature:Source_mirror.signature ->
  allowed:string list -> descends:bool -> verdict

(** A failed release step, on an app without migrate, whose new release is
    active (the switch happened): the only failure an update reverts. *)
val should_revert : step:Dispatcher.up_step -> migrate:bool -> active_is_desired:bool -> bool

(** A line is reported when it differs from the last one reported. *)
val should_report : last:string option -> current:string -> bool

val refusal_message : refusal -> string
