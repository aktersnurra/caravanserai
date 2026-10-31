open Base

type t = {
  layout : Layout.t;
  apps : App_config.t list;
  guests : Guest_config.t list;
  endpoints : Network_endpoint.validated;
  edge : Edge_config.t;
  topology : Topology.t option;
}
type error =
  | Invalid_endpoints of Network_endpoint.error list
  | Invalid_file of string * string
  | Read_error of string

let error_message = function
  | Invalid_endpoints errors -> "app.sexp/guest.sexp validation failed: " ^ Network_endpoint.errors_message errors
  | Invalid_file (path, message) -> path ^ ": " ^ message
  | Read_error message -> message

let create ~layout ~apps ~guests ~edge =
  Network_endpoint.validate_all
    (List.map apps ~f:App_config.endpoint @ List.map guests ~f:Guest_config.endpoint)
  |> Result.map_error ~f:(fun errors -> Invalid_endpoints errors)
  |> Result.map ~f:(fun endpoints -> { layout; apps; guests; endpoints; edge; topology = None })

let describe = function
  | Sexplib.Conv.Of_sexp_error (Failure message, sexp) ->
      Printf.sprintf "%s in %s" message (Sexplib.Sexp.to_string sexp)
  | Sexplib.Conv.Of_sexp_error (exn, sexp) ->
      Printf.sprintf "%s in %s" (Exn.to_string exn) (Sexplib.Sexp.to_string sexp)
  | Failure message | Sys_error message -> message
  | exn -> Exn.to_string exn

let load_file load path =
  try Ok (load path) with
  | (Sexplib.Conv.Of_sexp_error _ | Failure _ | Sys_error _ | Sexplib.Sexp.Parse_error _) as exn ->
      Error (Invalid_file (path, describe exn))

let ( let* ) result f = Result.bind result ~f

let load_each dir filename load =
  let entries = Stdlib.Sys.readdir dir |> Array.to_list |> List.sort ~compare:String.compare in
  let rec collect = function
    | [] -> Ok []
    | entry :: rest ->
        let path = Stdlib.Filename.concat (Stdlib.Filename.concat dir entry) filename in
        if Stdlib.Sys.file_exists path then
          let* value = load_file load path in
          let* values = collect rest in
          Ok (value :: values)
        else collect rest
  in collect entries

let load ~layout =
  try
    let* apps = load_each (Layout.apps_dir layout) "app.sexp" App_config.load in
    let* guests = load_each (Layout.guests_dir layout) "guest.sexp" Guest_config.load in
    let* edge = load_file Edge_config.load (Layout.edge layout) in
    let path = Layout.topology layout in
    let* topology = load_file Topology.load path in
    let* () = Topology.validate_workloads topology
        ~apps:(List.map apps ~f:(fun app -> (App_config.endpoint app).name))
        ~guests:(List.map guests ~f:Guest_config.name)
      |> Result.map_error ~f:(fun message -> Invalid_file (path, message)) in
    let* () = Topology.validate_addresses topology
        ~ips:(List.map apps ~f:(fun app -> let e = App_config.endpoint app in (e.name, e.ip))
              @ List.map guests ~f:(fun guest -> let e = Guest_config.endpoint guest in (e.name, e.ip)))
      |> Result.map_error ~f:(fun message -> Invalid_file (path, message)) in
    let* declaration = create ~layout ~apps ~guests ~edge in
    let exposed = Network_endpoint.to_list declaration.endpoints
      |> List.filter_map ~f:(fun (e : Network_endpoint.t) ->
           if List.is_empty e.tailnet_ports then None else Some e.name) in
    let* () = Topology.validate_proxy topology ~exposed
      |> Result.map_error ~f:(fun message -> Invalid_file (path, message)) in
    Ok { declaration with topology = Some topology }
  with Sys_error message -> Error (Read_error message)
