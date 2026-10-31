(* A bhyve guest's declaration (guests/<name>/guest.sexp): the network
   fields the edge renderers read, plus the login user, source checkout and
   workload serai's guest lifecycle (provision, build, deploy) needs. Everything
   else about a guest -- bhyve sizing, the ISO, its build toolchain -- stays
   in its shell config. A guest is not a jail, so App_config's strategy and
   hooks do not apply, and are unknown fields here. *)

type workload = { project : string; target : string; release : string; service_group : string }

type t = {
  endpoint : Network_endpoint.t;
  login_user : string;
  source_checkout : string;
  workload : workload option;
}

type error =
  | Invalid_login_user of string * string
  | Invalid_source_checkout of string * string
  | Invalid_workload of string * string * string

let error_message = function
  | Invalid_login_user (name, value) ->
      Printf.sprintf "%s: login_user %S must be [a-z_][a-z0-9_-]*" name value
  | Invalid_source_checkout (name, value) ->
      Printf.sprintf "%s: source_checkout %S must be a non-empty path with no newline" name value
  | Invalid_workload (name, field, value) ->
      Printf.sprintf "%s: workload %s %S is invalid" name field value

let is_user_start c = (c >= 'a' && c <= 'z') || c = '_'
let is_user_char c = is_user_start c || (c >= '0' && c <= '9') || c = '-'

let is_login_user value =
  value <> "" && is_user_start value.[0] && String.for_all is_user_char value

let is_source_checkout value = value <> "" && not (String.contains value '\n')

(* The worker's rule for a path within the source: relative, and each
   component a plain name. *)
let is_source_path value =
  value <> ""
  && String.for_all (function 'a'..'z' | 'A'..'Z' | '0'..'9' | '_' | '.' | '-' | '/' -> true | _ -> false) value
  && List.for_all (fun c -> c <> "" && c <> "." && c <> "..") (String.split_on_char '/' value)

let is_release value =
  value <> "" && String.length value <= 63
  && (match value.[0] with 'a'..'z' -> true | _ -> false)
  && String.for_all (function 'a'..'z' | '0'..'9' | '_' | '-' -> true | _ -> false) value

let workload ~guest ~project ~target ~release ~service_group =
  let invalid field value = Error (Invalid_workload (guest, field, value)) in
  if not (is_source_path project) then invalid "project" project
  else if not (is_source_path target) then invalid "target" target
  else if not (is_release release) then invalid "release" release
  else if not (is_login_user service_group) then invalid "service_group" service_group
  else Ok { project; target; release; service_group }

let create ?workload ~(endpoint : Network_endpoint.t) ~login_user ~source_checkout () =
  if not (is_login_user login_user) then Error (Invalid_login_user (endpoint.name, login_user))
  else if not (is_source_checkout source_checkout) then
    Error (Invalid_source_checkout (endpoint.name, source_checkout))
  else Ok { endpoint; login_user; source_checkout; workload }

let endpoint guest = guest.endpoint
let name guest = guest.endpoint.name

let context = "Guest_config"
let known_fields = Network_endpoint.field_names @ [ "login_user"; "source_checkout"; "workload" ]

let of_sexp sexp =
  let fields = Sexp_fields.fields_of_sexp ~context ~known:known_fields sexp in
  let atom name = Sexp_fields.atom ~context (Sexp_fields.field ~context name fields) in
  let endpoint = Network_endpoint.of_fields fields in
  let workload = Option.map (fun value ->
    let fields = Sexp_fields.fields_of_sexp ~context
      ~known:[ "project"; "target"; "release"; "service_group" ] value in
    let atom name = Sexp_fields.atom ~context (Sexp_fields.field ~context name fields) in
    match workload ~guest:endpoint.name ~project:(atom "project") ~target:(atom "target")
            ~release:(atom "release") ~service_group:(atom "service_group") with
    | Ok workload -> workload
    | Error error -> Sexplib.Conv.of_sexp_error (error_message error) value)
    (List.assoc_opt "workload" fields) in
  match create ?workload ~endpoint ~login_user:(atom "login_user")
          ~source_checkout:(atom "source_checkout") () with
  | Ok guest -> guest
  | Error error -> Sexplib.Conv.of_sexp_error (error_message error) sexp

let load path = of_sexp (Sexplib.Sexp.load_sexp path)

let load_all dir =
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.filter_map (fun entry ->
         let guest_sexp = Filename.concat (Filename.concat dir entry) "guest.sexp" in
         if Sys.file_exists guest_sexp then Some (load guest_sexp) else None)
