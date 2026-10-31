(** Opt-in, process-local CLI diagnostics. Reporting never grants authority,
    persists recovery state, or changes execution policy. *)
type outcome = Succeeded | Failed | Interrupted | Changes_pending

(** Start JSON-line events on stderr. Existing stdout and tool output remain
    unchanged. Disabled reporting is a no-op. *)
val start : enabled:bool -> operation:string -> workload:string option -> unit

(** Report entry into a phase, not a percentage or an inferred completion. *)
val phase : string -> unit

(** Existing execution policy could not confirm the remote outcome. *)
val outcome_unknown : unit -> unit

val finish : outcome -> unit

(** Monotonic interval events, separate from legacy phase-entry diagnostics.
    Parents identify containment, not additive costs. Exceptions retain their
    original raw backtrace; diagnostic failures never affect the operation. *)
type phase_status = Completed | Phase_failed | Skipped
val with_duration : phase:string -> parent:string option -> (unit -> 'value) -> 'value
val skipped : phase:string -> parent:string option -> reason:string -> unit

(** Diagnostic selection only; grants no execution authority. *)
val is_enabled : unit -> bool
