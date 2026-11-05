(* edge host edge settings that belong to no single endpoint (edge/edge.sexp).
   base_domain fills __BASE_DOMAIN__ in the non-app Caddy vhosts (main,
   git, mail, ...); operator is the Headscale user the ACL grants operator
   access to; operator_edge_ports are the edge host's own ports the
   operator's devices may reach over the tailnet (e.g. its mail server). *)

type t = {
  base_domain : string;
  operator : string;
  operator_edge_ports : Network_endpoint.named_port list;
}

type error =
  | Invalid_base_domain of Domain_name.error
  | Invalid_operator of string
  | Invalid_operator_edge_port of Network_endpoint.named_port
  | Duplicate_operator_edge_port of int
  | Duplicate_operator_edge_port_name of string

let error_message = function
  | Invalid_base_domain error -> Domain_name.error_message error
  | Invalid_operator operator ->
      Printf.sprintf "invalid operator %S: a Headscale user name, [a-z0-9][a-z0-9._-]*, at most 63 characters"
        operator
  | Invalid_operator_edge_port { port_name; port } ->
      Printf.sprintf "operator_edge_ports: %s %d needs a [a-z0-9]+ name and a port in 1-65535" port_name port
  | Duplicate_operator_edge_port port -> Printf.sprintf "operator_edge_ports: duplicate port %d" port
  | Duplicate_operator_edge_port_name name -> Printf.sprintf "operator_edge_ports: duplicate port name %s" name

let context = "Edge_config"

(* Rendered as "<operator>@" in the policy, so the name itself must not
   carry the @ or anything that would break out of the JSON string. *)
let valid_operator operator =
  let length = String.length operator in
  length > 0 && length <= 63
  && (match operator.[0] with 'a' .. 'z' | '0' .. '9' -> true | _ -> false)
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '.' | '_' | '-' -> true | _ -> false) operator

(* The first error in declared order, so the message names the port to fix. *)
let edge_port_error ports =
  let rec scan seen = function
    | [] -> None
    | ({ Network_endpoint.port_name; port } as named) :: rest ->
        if not (Network_endpoint.is_placeholder_safe port_name && port >= 1 && port <= 65535) then
          Some (Invalid_operator_edge_port named)
        else if List.exists (fun (seen : Network_endpoint.named_port) -> seen.port = port) seen then
          Some (Duplicate_operator_edge_port port)
        else if List.exists (fun (seen : Network_endpoint.named_port) -> seen.port_name = port_name) seen then
          Some (Duplicate_operator_edge_port_name port_name)
        else scan (named :: seen) rest
  in
  scan [] ports

let create ?(operator_edge_ports = []) ~base_domain ~operator () =
  match Domain_name.parse base_domain with
  | Error error -> Error (Invalid_base_domain error)
  | Ok _ when not (valid_operator operator) -> Error (Invalid_operator operator)
  | Ok domain -> (
      match edge_port_error operator_edge_ports with
      | Some error -> Error error
      | None -> Ok { base_domain = Domain_name.to_string domain; operator; operator_edge_ports })

let of_sexp sexp =
  let fields =
    Sexp_fields.fields_of_sexp ~context ~known:[ "base_domain"; "operator"; "operator_edge_ports" ] sexp in
  let atom name = Sexp_fields.atom ~context (Sexp_fields.field ~context name fields) in
  let operator_edge_ports =
    List.assoc_opt "operator_edge_ports" fields
    |> Option.map (Sexp_fields.list ~context Network_endpoint.named_port_of_sexp) in
  match create ?operator_edge_ports ~base_domain:(atom "base_domain") ~operator:(atom "operator") () with
  | Ok edge -> edge
  | Error error -> Sexplib.Conv.of_sexp_error (error_message error) sexp

let load path = of_sexp (Sexplib.Sexp.load_sexp path)
