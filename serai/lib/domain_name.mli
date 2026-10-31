type t

type error = Invalid_domain_name of string

(** ASCII DNS names, at most 253 bytes, with 1..63-byte labels. Labels
    contain letters, digits and internal hyphens. No wildcard or trailing dot. *)
val parse : string -> (t, error) result
val to_string : t -> string
val error_message : error -> string
