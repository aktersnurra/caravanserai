(** What one run of serai has done so far, for its report: whether it has
    begun to change a host, which stages and locks it left for inspection,
    and how its approvals are answered. One run, one state. *)

(** How a request for approval is answered. *)
type approval =
  | Ask  (** the operator, through the environment's [confirm] *)
  | Granted  (** an approval already given covers this one *)
  | Plan_only  (** nothing is approved: the request is reported as {!Planned} *)
  | Expect of Plan_id.t  (** only the plan with this id *)

(** What an approval would have allowed: [id] names the operation and
    every fact. *)
type planned = { operation : string; id : Plan_id.t; question : string; facts : (string * string) list }

(** Raised instead of asking, under [Plan_only], before anything changes. *)
exception Planned of planned

val approval : approval ref
val with_approval : approval -> (unit -> 'a) -> 'a

(** From here on a failure may have left a host changed. *)
val changing : unit -> unit
val has_changed : unit -> bool

(** A stage and its host's lock left in place because the outcome on that
    host is unknown. *)
type retained = { host : string; stage : string; context : string }

val retain : retained -> unit
val retained : unit -> retained list

(** Fails as [Failure message] does, and records why in a word a caller
    can branch on: the cause of that message, for the run's report. *)
val fail : cause:string -> string -> 'a

(** The cause recorded for exactly this message, if any. *)
val cause_of : string -> string option

(** Passes on a failure already raised with [message]: keeps its cause,
    or [otherwise] when it had none. *)
val refail : ?prefix:string -> otherwise:string -> string -> 'a

(** What the run did, in order: each step it announced, and each host
    whose lock it took. *)
val ran : string -> unit
val steps_ran : unit -> string list
val locked : string -> unit
val hosts_locked : unit -> string list

(** A fresh run, for tests. *)
val reset : unit -> unit
