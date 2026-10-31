(** An app's [env.template]: the variables its [/etc/<app>/env] must set.

    Each line is blank, a comment ([#] after optional blanks) or
    [NAME=value] with [NAME] matching [[A-Z_][A-Z0-9_]*]. Values are never
    kept or reported. *)

(** Who turns the template into /etc/<app>/env: the operator, copying it by
    hand, so a value is a literal or [REPLACE_ME] and a [${NAME}] or
    [__NAME__] placeholder would reach the service unfilled; or the app's
    generated jail script, which fills its placeholders in. *)
type filled_by = Operator | Jail_script

type error =
  | Invalid_line of int  (** 1-based; neither blank, a comment nor an assignment *)
  | Placeholder of int  (** 1-based; a value holding [${...}] or [__NAME__] *)
  | Duplicate of string

val error_message : error -> string

(** The declared names, in template order. *)
val names : filled_by:filled_by -> string -> (string list, error) result
