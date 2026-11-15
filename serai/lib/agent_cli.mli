(** Read-only, versioned agent interface. Reads declarations/templates only;
    never dispatches host, build, source-export, or mutation operations.
    Plans are design previews, not approvals or verified artifact identities. *)
type response

(** Accepts exactly one [--json] and optionally [--progress=jsonl]. Unsupported
    commands/options are refused before resolving the repository or reading it. *)
val run : layout:(unit -> Layout.t) -> string list -> response
val to_json : response -> string

(** A request refused before anything is read: [invalid_request] for a
    [known] command given wrongly, [unsupported_operation] for no command. *)
val refused : operation:string -> known:bool -> string -> response

(** 0 succeeded, 1 refused or failed, 3 unknown, 130 interrupted. *)
val exit_code : response -> int

(** The response is a plan awaiting approval ([applied] false, with a
    [plan_id]): the CLI exits 2 for it, as for any pending change. *)
val is_plan : response -> bool

(** The same envelope for the commands that do act (serai new, serai up),
    which the CLI runs itself, so this module still cannot. *)
type json = Json.t = Null | Bool of bool | Number of string | String of string
          | Array of json list | Object of (string * json) list

(** [Ok data] as succeeded; [Error (data, message)] as failed with code
    [step_failed], keeping the data (what ran before the failing step).
    What an exception means depends on where the run stood ({!Run_state}):
    - nothing had changed: [refused], code [not_applied] ([stale_plan],
      [invalid_request] for those exceptions);
    - a host may have changed: [failed], code [apply_failed];
    - a stage and lock were retained: [unknown], code [outcome_unknown],
      with [data.retained] naming each host and stage. No retry is safe
      until the host has been inspected.
    An object result gains [changed], [hosts] (each host whose lock the run
    took) and [ran] (each step it announced, in order); so does an error
    once a host may have changed. [error.cause] is the word recorded where
    the failure was raised ({!Run_state.fail}), or null.
    {!Run_state.Planned} is the plan itself: succeeded, [applied] false.
    Ctrl-C is interrupted. *)
val respond : operation:string -> (unit -> (json, json * string) result) -> response

(** The request itself is unusable (a missing or malformed argument):
    [respond] reports it refused with code [invalid_request]. *)
exception Bad_request of string
