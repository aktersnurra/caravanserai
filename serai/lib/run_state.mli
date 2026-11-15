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

(** A fresh run, for tests. *)
val reset : unit -> unit
