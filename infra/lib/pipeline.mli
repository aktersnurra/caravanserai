type arg = Literal of string | Compute_target | Edge_target

(* Central logging's senders: the compute host's host relay and jail senders
   (converged, or deliberately replaced), a named guest's, the edge host's, and the
   VMUI auth proxy on the edge host. *)
type logging_sender =
  | Compute_sender of Dispatcher.compute_logging_mode
  | Guest_sender of string
  | Edge_sender
  | Vmui_auth

type step =
  | Hook of App_config.hook
  | Edge
  | Logging of logging_sender * Dispatcher.logging_action
  | Sequence of step list
  | Prefer of App_config.hook * step
  | Script of string * arg list

type t = { default : (string * step) list; apps : (string * (string * step) list) list }
val step_of_sexp : Sexplib.Sexp.t -> step
val of_sexp : Sexplib.Sexp.t -> t
val load : string -> t
val find : t -> app:string -> name:string -> step option
val run : Dispatcher.env -> t -> string -> string -> unit
