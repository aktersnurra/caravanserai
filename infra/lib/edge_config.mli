(** Edge settings that belong to no single app or guest. [operator] is the
    Headscale user who owns the tags and may reach the hosts' and guests'
    operator ports. *)
type t = private { base_domain : string; operator : string }

type error =
  | Invalid_base_domain of Domain_name.error
  | Invalid_operator of string

val create : base_domain:string -> operator:string -> (t, error) result
val error_message : error -> string
val of_sexp : Sexplib.Sexp.t -> t
val load : string -> t
