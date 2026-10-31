type request = {
  prog : string;
  args : string list;
  extra_env : (string * string) list;
}

(** The original operation failed, and cleanup also failed unexpectedly.
    Both causes are retained; ordinary interrupts during reaping are retried. *)
exception Cleanup_failed of exn * exn

(** Explicit overrides replace inherited values; later overrides win. *)
val run : ?extra_env:(string * string) list -> string -> string list -> int
val capture : ?extra_env:(string * string) list -> string -> string list -> int * string
val run_checked : ?extra_env:(string * string) list -> string -> string list -> unit
val live : (unit -> 'result) -> 'result

module Mock : sig
  type t
  val create : ?exit_codes:(request -> int) -> ?outputs:(request -> string) -> unit -> t
  val calls : t -> request list
  val run : t -> (unit -> 'result) -> 'result
end
