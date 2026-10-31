(* Renders everything the declaration produces, offline: the Headscale ACL,
   the pf rules, the Caddy tree and every app's jail script. No Proc call,
   no lock, no jj -- the only I/O is Caddy_render reading its templates.
   Behind `serai validate`, which lint runs first. *)

let prefix_error label = Result.map_error (fun message -> label ^ ": " ^ message)

(* [render ()]'s result as the file at [path], or an Error naming [path].
   Sys.Break is Ctrl-C, not a render error: it propagates so main exits 130. *)
let catch_render path render =
  match render () with
  | contents -> Ok (path, contents)
  | exception Sys.Break -> raise Sys.Break
  | exception exn -> Error (Printf.sprintf "%s: %s" path (Declaration.describe exn))

let render_jail (app : App_config.t) =
  catch_render
    (Printf.sprintf "jails/%s.sh" app.endpoint.name)
    (fun () -> Strategy.render_jail_script app)

let render_jails apps =
  List.fold_left
    (fun rendered app ->
      Result.bind rendered (fun scripts ->
          Result.map (fun script -> script :: scripts) (render_jail app)))
    (Ok []) apps
  |> Result.map List.rev

let render_all (declaration : Declaration.t) =
  let ( let* ) = Result.bind in
  let proxy = Option.map Topology.proxy_workloads declaration.topology in
  let* acl = Headscale_acl.render ?proxy ~edge:declaration.edge declaration.endpoints |> prefix_error "acls.hujson" in
  let* groups = match declaration.topology with
    | None -> Ok ["service-rules.conf", declaration.endpoints]
    | Some topology ->
        let hosts = Topology.compute_hosts topology in
        List.fold_left (fun acc (host : Topology.host) ->
          let* groups = acc in
          let names = Topology.workloads_on topology host.id in
          let* endpoints = Network_endpoint.to_list declaration.endpoints
            |> List.filter (fun (e : Network_endpoint.t) -> List.mem e.name names)
            |> Network_endpoint.validate_all |> Result.map_error Network_endpoint.errors_message in
          let path = if List.length hosts = 1 then "service-rules.conf"
            else "hosts/" ^ host.id ^ "/service-rules.conf" in
          Ok (groups @ [path,endpoints])) (Ok []) hosts in
  let* pf = List.fold_left (fun acc (path,endpoints) ->
    let* files = acc in
    let* rules = Pf_rules.render ?proxy endpoints |> prefix_error path in
    Ok (files @ [path,rules])) (Ok []) groups in
  let* caddy =
    Caddy_render.render ?proxy ~edge:declaration.edge
      ~root_template:(Layout.caddy_root_template declaration.layout)
      ~sites:(Layout.caddy_sites declaration.layout)
      declaration.endpoints
    |> prefix_error "caddy"
  in
  let* jails = render_jails declaration.apps in
  Ok
    (("acls.hujson", acl) :: pf
     @ List.map (fun (path, contents) -> ("caddy/" ^ path, contents)) caddy
     @ jails)

let count ~prefix files =
  List.length (List.filter (fun (path, _) -> String.starts_with ~prefix path) files)

let plural count noun = Printf.sprintf "%d %s%s" count noun (if count = 1 then "" else "s")

let summary (declaration : Declaration.t) files =
  Printf.sprintf "ok: %s, %s, %s, %s"
    (plural (List.length declaration.apps) "app")
    (plural (List.length declaration.guests) "guest")
    (plural (count ~prefix:"caddy/" files) "caddy file")
    (plural (count ~prefix:"jails/" files) "jail script")
