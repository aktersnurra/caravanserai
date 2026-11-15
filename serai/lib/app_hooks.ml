(* An app's jail script and deploy hook. Part of Dispatcher. *)
open! Remote_host

(* bootstrap provisions the app's jail only. It deliberately does not push
   Headscale_acl/Pf_rules output: rollout falls through to bootstrap for
   apps without a deploy hook, so a push here would run on routine
   redeploys. The network edge converges through edge instead. *)
(* The app's generated jail script, rendered before any command; a render
   failure names the app. *)
let render_jail_script ~command (app : App_config.t) =
  try Strategy.render_jail_script app with
  | Sexplib.Conv.Of_sexp_error (exn, _) ->
      failwith
        (Printf.sprintf "%s: %s's jail script does not render: %s" command app.endpoint.name (Printexc.to_string exn))
  | Invalid_argument msg -> failwith (Printf.sprintf "%s: %s" command msg)

(* The app's jail script is rendered here and staged as compute/apps/<app>/jail
   in the staged app directory, beside the extra steps it runs, and run. *)
let bootstrap env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  validate_stage env.remote_stage;
  let jail_script = render_jail_script ~command:"bootstrap" app in
  announce "bootstrap %s" app.endpoint.name;
  with_locks env ~command:("bootstrap " ^ app.endpoint.name) [ Compute_host ] (fun _records ->
      secure_remote_stage env ~target:env.compute_target ~subtree:"compute/apps";
      rsync_checked env
        [
          "-az";
          "--delete";
          "--exclude"; ".env"; "--exclude"; ".env.*";
          Layout.lib_dir env.layout;
          Layout.app_dir env.layout app.endpoint.name;
          Printf.sprintf "%s:%s/compute/apps/" env.compute_target env.remote_stage;
        ];
      with_local_stage [ ("jail", jail_script) ] (fun local ->
          rsync_checked env
            [
              "-az"; "--no-owner"; "--no-group";
              Filename.concat local "jail";
              Printf.sprintf "%s:%s/compute/apps/%s/jail" env.compute_target env.remote_stage app.endpoint.name;
            ]);
      ssh_checked env
        [
          env.compute_target;
          Printf.sprintf "doas sh %s/compute/apps/%s/jail" env.remote_stage app.endpoint.name;
        ])

let deploy env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  require_direct_hook env;
  if not (App_config.supports app Deploy) then
    failwith "deploy is not supported for this app";
  announce "deploy %s" app.endpoint.name;
  (* The hook runs from the configuration, so the engine's deploy library
     is handed to it rather than found beside it. *)
  Proc.run_checked (hook_path env app "deploy") [ env.compute_target ]
    ~extra_env:[ ("COMPUTE_TARGET", env.compute_target); ("CURL_BIN", env.curl_bin);
                 ("SERAI_LIB", Layout.lib_dir env.layout) ]
