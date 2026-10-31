open Base

type named_port = { port_name : string; port : int }
type t = {
  name : string;
  ip : string;
  hostname : string;
  tailnet_ports : named_port list;
  operator_ports : named_port list;
}
type port_access = Tailnet | Operator

type error =
  | Invalid_name of string
  | Invalid_ip of string * string
  | Invalid_hostname of string * Domain_name.error
  | Invalid_port_name of string * string
  | Invalid_port of string * port_access * named_port
  | Duplicate_port_name of string * port_access * string
  | Duplicate_port of string * port_access * int
  | Duplicate_name of string * string * string
  | Duplicate_ip of string * string * string
  | Duplicate_hostname of string * string * string

let access_name = function Tailnet -> "tailnet" | Operator -> "operator"
let error_message = function
  | Invalid_name name -> Printf.sprintf "name %s must be [a-z0-9]+" name
  | Invalid_ip (name, ip) -> Printf.sprintf "%s: invalid IPv4 host address %S" name ip
  | Invalid_hostname (name, error) -> name ^ ": invalid hostname: " ^ Domain_name.error_message error
  | Invalid_port_name (name, port_name) -> Printf.sprintf "%s: port name %s must be [a-z0-9]+" name port_name
  | Invalid_port (name, access, named) -> Printf.sprintf "%s: %s port %s %d out of range 1-65535" name (access_name access) named.port_name named.port
  | Duplicate_port_name (name, access, port_name) -> Printf.sprintf "%s: duplicate %s port name %s" name (access_name access) port_name
  | Duplicate_port (name, access, port) -> Printf.sprintf "%s: duplicate %s port %d" name (access_name access) port
  | Duplicate_name (name, left, right) -> Printf.sprintf "duplicate name %s: %s and %s" name left right
  | Duplicate_ip (ip, left, right) -> Printf.sprintf "duplicate ip %s: %s and %s" ip left right
  | Duplicate_hostname (hostname, left, right) ->
      Printf.sprintf "duplicate hostname %s: %s and %s" hostname left right

let errors_message errors = String.concat ~sep:"; " (List.map errors ~f:error_message)
let is_placeholder_safe value =
  not (String.is_empty value)
  && String.for_all value ~f:(fun c -> Char.is_digit c || (Char.(c >= 'a' && c <= 'z')))

(* Canonical dotted decimal prevents aliases such as 127.1 or octal-looking
   addresses bypassing duplicate-IP detection. The renderers are IPv4-only. *)
let is_ipv4_host value =
  let octets = String.split value ~on:'.' in
  List.length octets = 4
  && List.for_all octets ~f:(fun octet ->
    let length = String.length octet in
    length > 0 && length <= 3
    && (length = 1 || not (Char.equal octet.[0] '0'))
    && String.for_all octet ~f:Char.is_digit
    && Int.of_string octet <= 255)

let port_errors name access ports =
  let _, _, errors = List.fold ports
      ~init:(Set.empty (module String), Set.empty (module Int), [])
      ~f:(fun (names, numbers, errors) ({ port_name; port } as named) ->
        let current =
          (if is_placeholder_safe port_name then [] else [ Invalid_port_name (name, port_name) ])
          @ (if port >= 1 && port <= 65535 then [] else [ Invalid_port (name, access, named) ])
          @ (if Set.mem names port_name then [ Duplicate_port_name (name, access, port_name) ] else [])
          @ (if Set.mem numbers port then [ Duplicate_port (name, access, port) ] else [])
        in
        Set.add names port_name, Set.add numbers port, List.rev_append current errors)
  in List.rev errors

let create ~name ~ip ~hostname ~tailnet_ports ~operator_ports =
  let errors =
    (if is_placeholder_safe name then [] else [ Invalid_name name ])
    @ (if is_ipv4_host ip then [] else [ Invalid_ip (name, ip) ])
    @ (match Domain_name.parse hostname with Ok _ -> [] | Error error -> [ Invalid_hostname (name, error) ])
    @ port_errors name Tailnet tailnet_ports
    @ port_errors name Operator operator_ports
  in
  match errors with
  | [] -> Ok { name; ip; hostname; tailnet_ports; operator_ports }
  | _ -> Error errors

type validated = t list
let to_list endpoints = endpoints
let validate_all endpoints =
  let _, _, _, errors = List.fold endpoints
      ~init:(Map.empty (module String), Map.empty (module String), Map.empty (module String), [])
      ~f:(fun (names, ips, hostnames, errors) endpoint ->
        let current =
          (match Map.find names endpoint.name with
           | None -> [] | Some other -> [ Duplicate_name (endpoint.name, other, endpoint.ip) ])
          @ (match Map.find ips endpoint.ip with
             | None -> [] | Some other -> [ Duplicate_ip (endpoint.ip, other, endpoint.name) ])
          @ (match Map.find hostnames endpoint.hostname with
             | None -> []
             | Some other -> [ Duplicate_hostname (endpoint.hostname, other, endpoint.name) ])
        in
        Map.set names ~key:endpoint.name ~data:endpoint.ip,
        Map.set ips ~key:endpoint.ip ~data:endpoint.name,
        Map.set hostnames ~key:endpoint.hostname ~data:endpoint.name,
        List.rev_append current errors)
  in
  match errors with [] -> Ok endpoints | _ -> Error (List.rev errors)

let context = "Network_endpoint"
let field_names = [ "name"; "ip"; "hostname"; "tailnet_ports"; "operator_ports" ]
let named_port_of_sexp (sexp : Sexplib.Sexp.t) =
  match sexp with
  | List [ Atom port_name; Atom port ] -> (
      match Stdlib.int_of_string_opt port with
      | Some port -> { port_name; port }
      | None -> Sexplib.Conv.of_sexp_error (context ^ ": expected an integer port") sexp)
  | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected (port_name port)") sexp

let of_fields fields =
  let field name = Sexp_fields.field ~context name fields in
  let atom = Sexp_fields.atom ~context in
  let ports name = Sexp_fields.list ~context named_port_of_sexp (field name) in
  match create ~name:(atom (field "name")) ~ip:(atom (field "ip"))
          ~hostname:(atom (field "hostname"))
          ~tailnet_ports:(ports "tailnet_ports") ~operator_ports:(ports "operator_ports") with
  | Ok endpoint -> endpoint
  | Error errors -> Sexplib.Conv.of_sexp_error (errors_message errors)
      (Sexplib.Sexp.List (List.map fields ~f:(fun (key, value) -> Sexplib.Sexp.List [ Atom key; value ])))
