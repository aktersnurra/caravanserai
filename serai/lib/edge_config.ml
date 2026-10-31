(* edge host edge settings that belong to no single endpoint (edge/edge.sexp).
   base_domain fills __BASE_DOMAIN__ in the non-app Caddy vhosts (main,
   git, mail, ...); operator is the Headscale user the ACL grants operator
   access to. *)

type t = { base_domain : string; operator : string }

type error =
  | Invalid_base_domain of Domain_name.error
  | Invalid_operator of string

let error_message = function
  | Invalid_base_domain error -> Domain_name.error_message error
  | Invalid_operator operator ->
      Printf.sprintf "invalid operator %S: a Headscale user name, [a-z0-9][a-z0-9._-]*, at most 63 characters"
        operator

let context = "Edge_config"

(* Rendered as "<operator>@" in the policy, so the name itself must not
   carry the @ or anything that would break out of the JSON string. *)
let valid_operator operator =
  let length = String.length operator in
  length > 0 && length <= 63
  && (match operator.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true | _ -> false) operator

let create ~base_domain ~operator =
  match Domain_name.parse base_domain with
  | Error error -> Error (Invalid_base_domain error)
  | Ok _ when not (valid_operator operator) -> Error (Invalid_operator operator)
  | Ok domain -> Ok { base_domain = Domain_name.to_string domain; operator }

let of_sexp sexp =
  let fields = Sexp_fields.fields_of_sexp ~context ~known:[ "base_domain"; "operator" ] sexp in
  let atom name = Sexp_fields.atom ~context (Sexp_fields.field ~context name fields) in
  match create ~base_domain:(atom "base_domain") ~operator:(atom "operator") with
  | Ok edge -> edge
  | Error error -> Sexplib.Conv.of_sexp_error (error_message error) sexp

let load path = of_sexp (Sexplib.Sexp.load_sexp path)
