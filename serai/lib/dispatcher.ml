(* Everything serai does to a host, as one interface. The parts live in
   the modules included here, in dependency order; what is left below is
   the small glue that spans them. *)

include Remote_host
include App_hooks
include Artifact_lifecycle

(* What _lib/check.sh's check_app needs, from the declaration: the rc
   service (a Phoenix release's name, a package service's own, otherwise the
   app's), the port named
   http or the only tailnet port, the public hostname and the check path. *)
let check_environment (app : App_config.t) =
  let endpoint = app.endpoint in
  let service, check_path = match app.strategy with
    | Strategy_config.Freebsd_native_elixir s -> s.release_name, s.check_path
    | Freebsd_native_ocaml s -> endpoint.name, s.check_path
    | Freebsd_package s -> endpoint.name, s.check_path
    | Fetch_binary s -> endpoint.name, s.check_path
    | Freebsd_package_service s -> s.service, s.check_path in
  [ ("JAIL", endpoint.name); ("JAIL_IP", endpoint.ip); ("PORT", string_of_int (check_port endpoint));
    ("PUBLIC_HOST", endpoint.hostname); ("SERVICE", service); ("CHECK_PATH", check_path) ]

let check env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  require_direct_hook env;
  if not (App_config.supports app Check) then
    Run_state.fail ~cause:"unsupported_for_workload" "check is not supported for this app";
  announce "check %s" app.endpoint.name;
  Proc.run_checked "sh"
    [ "-c"; {|set -eu; . "$1"; check_app|}; "sh"; Layout.lib_file env.layout "check.sh" ]
    ~extra_env:
      (check_environment app
       @ [
           ("COMPUTE_TARGET", env.compute_target);
           ("EDGE_TARGET", env.edge_target);
           ("CURL_BIN", env.curl_bin);
         ])

let update_version env app_name version =
  let app = find_app env app_name in
  let env = app_env env app_name in
  if not (App_config.supports app Update_version) then
    Run_state.fail ~cause:"unsupported_for_workload" "update-version is not supported for this app";
  announce "update-version %s" app.endpoint.name;
  Run_state.changing ();
  Proc.run_checked (hook_path env app "update-version") [ version ]
    ~extra_env:[ ("CURL_BIN", env.curl_bin) ]

include Edge_apply
include Logging_install
include Test_jail

(* serai new: the declaration a new app starts from, and nothing else: no
   host is touched. The files are written only if none exists, and the
   whole declaration must load and render afterwards, or they are removed
   and serai.sexp is put back. *)
type new_kind = New_phoenix | New_ocaml

let new_app env name ~kind ~repo ~hostname =
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let repo = if Filename.is_relative repo then Filename.concat (Sys.getcwd ()) repo else repo in
  if not (Sys.file_exists repo && Sys.is_directory repo) then Run_state.fail ~cause:"invalid_argument" ("new: " ^ repo ^ " is not a directory");
  let source = match Source_mirror.origin_url ~jj_bin:env.jj_bin repo with
    | Ok url -> url
    | Error message -> Run_state.fail ~cause:"source_unavailable" (Printf.sprintf "new: %s: %s (builds fetch the origin)" repo message) in
  let kind = match kind with
    | New_ocaml -> App_scaffold.Ocaml
    | New_phoenix ->
        let mix_exs = Filename.concat repo "mix.exs" in
        if not (Sys.file_exists mix_exs) then Run_state.fail ~cause:"invalid_argument" ("new: no mix.exs in " ^ repo);
        let release_ex release =
          let path = Filename.concat repo (Printf.sprintf "lib/%s/release.ex" release) in
          if Sys.file_exists path then Some (read path) else None in
        match App_scaffold.phoenix ~mix_exs:(read mix_exs) ~release_ex with
        | Ok kind -> kind
        | Error message -> Run_state.fail ~cause:"invalid_argument" ("new: " ^ message) in
  let declaration = match Declaration.load ~layout:env.layout with
    | Ok declaration -> declaration
    | Error error -> Run_state.fail ~cause:"invalid_declaration" ("new: " ^ Declaration.error_message error) in
  let topology_path = Layout.topology env.layout in
  let topology = read topology_path in
  let templates = Caddy_render.template_names (Layout.caddy_sites env.layout) in
  let plan = ok_or_fail ~cause:"invalid_declaration" (App_scaffold.plan declaration ~topology ~templates
                     { name; kind; repo_path = repo; source; hostname }) in
  let app_dir = Layout.app_dir env.layout name in
  List.iter (fun path ->
      if Sys.file_exists path then Run_state.fail ~cause:"already_exists" ("new: " ^ path ^ " already exists"))
    (app_dir :: List.map (fun (f : App_scaffold.file) -> Layout.config_path env.layout f.path) plan.files);
  let write path contents = Out_channel.with_open_bin path (fun out -> output_string out contents) in
  let undo () =
    List.iter (fun (f : App_scaffold.file) ->
        let path = Layout.config_path env.layout f.path in
        if Sys.file_exists path then Sys.remove path) plan.files;
    if Sys.file_exists app_dir then Sys.rmdir app_dir;
    write topology_path topology in
  (try
     Sys.mkdir app_dir 0o755;
     List.iter (fun (f : App_scaffold.file) -> write (Layout.config_path env.layout f.path) f.contents) plan.files;
     write topology_path plan.topology;
     match Result.bind
             (Result.map_error Declaration.error_message (Declaration.load ~layout:env.layout))
             Validation.render_all with
     | Ok _ -> ()
     | Error message -> Run_state.fail ~cause:"invalid_declaration" ("new: the declaration does not render with " ^ name ^ ": " ^ message)
   with exn -> undo (); raise exn);
  plan

include Up
include Guest_lifecycle

let is_guest env name = List.exists (fun guest -> Guest_config.name guest = name) env.guests

(* serai deploy <name>: a guest's lifecycle, or an app's deploy hook. A
   loaded declaration already refuses a name used twice; checked again here
   so the choice never depends on lookup order. *)
let deploy_app_or_guest env name =
  match (App_config.find env.config name, is_guest env name) with
  | Some _, true -> Run_state.fail ~cause:"invalid_declaration" (Printf.sprintf "deploy: %s is both an app and a guest" name)
  | None, true -> deploy_guest env name
  | _, false -> deploy env name

(* rollout itself now lives as data in pipelines.sexp -- see Pipeline.run --
   rather than as hardcoded OCaml, so "deploy-or-bootstrap, optionally edge,
   then check" is expressed the same way an app-specific extra step would
   be, instead of being a special case only the compiler can extend. *)
