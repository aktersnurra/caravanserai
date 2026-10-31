(** Read-only, versioned agent interface. Reads declarations/templates only;
    never dispatches host, build, source-export, or mutation operations.
    Plans are design previews, not approvals or verified artifact identities. *)
type response

(** Accepts exactly one [--json] and optionally [--progress=jsonl]. Unsupported
    commands/options are refused before resolving the repository or reading it. *)
val run : layout:(unit -> Layout.t) -> string list -> response
val to_json : response -> string
val exit_code : response -> int

(** The same envelope for the commands that do act (infra new, infra up),
    which the CLI runs itself, so this module still cannot. *)
type json = Null | Bool of bool | Int of int | Text of string
          | Array of json list | Object of (string * json) list

(** [Ok data] as succeeded; [Error (data, message)] as failed with code
    [step_failed], keeping the data (what ran before the failing step). A
    [Failure] raised by [f] is refused with code [not_applied]: these commands
    raise only before they change anything. Ctrl-C is interrupted and
    anything else failed. *)
val respond : operation:string -> (unit -> (json, json * string) result) -> response
