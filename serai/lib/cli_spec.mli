(** serai's commands as data: one table gives the parser, the usage text
    and [serai commands --json], so none of them can disagree. Pure. *)

type flag = { flag : string; value : string option  (** its placeholder; [None] for a switch *); required : bool }

type effect =
  | Offline  (** the declaration only: no host, no lock *)
  | Reads_hosts
  | Changes_files  (** local files only *)
  | Changes_hosts

(** How a change is approved. Any but [No_approval] takes [--plan] and
    [--expect-plan <id>]. *)
type approval =
  | No_approval
  | Own_plan  (** the command computes and checks its own plan *)
  | Bound  (** it asks through {!Remote_host.approved}, at the point of change *)
  | Bound_by_request
      (** it asks nothing itself; under [--json] the request as given is the
          plan, approved before the command starts *)

type command = {
  path : string list;
  arguments : (string * bool) list;  (** name, required; in order *)
  flags : flag list;
  summary : string;
  effect : effect;
  approval : approval;
}

val commands : command list

type invocation = {
  command : command;
  arguments : string list;
  flags : (string * string) list;  (** a switch's value is [""] *)
  json : bool;
  yes : bool;
  progress : bool;
  plan : bool;
  expect_plan : string option;
}

type error = Unknown_command | Bad_arguments of command * string

(** Flags in any order, each at most once; required arguments and flags
    present. *)
val parse : string list -> (invocation, error) result

val flag : invocation -> string -> string option
val has : invocation -> string -> bool
val name : command -> string
val synopsis : command -> string
val usage : unit -> string
val to_json : unit -> Json.t
