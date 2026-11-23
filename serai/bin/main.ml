open Serai

exception Cli_exit of int

let usage_and_exit () =
  prerr_string (Cli_spec.usage ());
  raise (Cli_exit 1)

let getenv_default name default =
  match Sys.getenv_opt name with Some v -> v | None -> default

(* An XDG base directory: the variable, or [fallback] under HOME. *)
let xdg name fallback =
  match Sys.getenv_opt name with
  | Some dir when dir <> "" -> dir
  | _ ->
      (match Sys.getenv_opt "HOME" with
       | Some home when home <> "" -> Filename.concat home fallback
       | _ -> Run_state.fail ~cause:"invalid_environment" (Printf.sprintf "neither %s nor HOME is set" name))

(* A yes/no question on the terminal; anything but y or yes is no. *)
let ask question =
  Printf.printf "%s [y/N] %!" question;
  match In_channel.input_line stdin with
  | Some answer -> List.mem (String.lowercase_ascii (String.trim answer)) [ "y"; "yes" ]
  | None -> false

(* Runs [f] with stdout pointed at stderr, so that --json's stdout carries
   exactly the one result: what the run prints, its subprocesses included,
   goes to stderr. *)
let with_stdout_on_stderr f =
  let saved = Unix.dup Unix.stdout in
  Unix.dup2 Unix.stderr Unix.stdout;
  Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved) f

(* The engine installed beside this binary, as install.sh lays it
   out: <prefix>/bin/serai and <prefix>/share/caravanserai. *)
let installed_engine () =
  Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "share/caravanserai"

(* The configuration is the nearest serai.sexp; the engine, an
   engine checkout above it, else the installed one. In this repository
   they are the same directory; from inside example/ the example is
   configured on this engine. *)
let locate_layout () =
  match Layout.discover ~from:(Sys.getcwd ()) ~installed:(installed_engine ()) with
  | Ok layout -> layout
  | Error message -> Run_state.fail ~cause:"input_unavailable" message

let load_declaration layout =
  match Declaration.load ~layout with
  | Ok declaration -> declaration
  | Error error -> Run_state.fail ~cause:"invalid_declaration" (Declaration.error_message error)

let env_of_layout ~assume_yes layout : Dispatcher.env =
  let declaration = load_declaration layout in
  List.iter (fun key -> match Sys.getenv_opt key with
    | Some value when value <> "" -> Run_state.fail ~cause:"invalid_environment" (key ^ ": configure hosts in serai.sexp instead")
    | _ -> ()) ["COMPUTE_TARGET"; "EDGE_TARGET"];
  let topology = match declaration.topology with Some value -> value | None -> Run_state.fail ~cause:"invalid_declaration" "missing topology" in
  let compute_target = match Topology.compute_hosts topology with
    | host :: _ -> host.ssh | [] -> "" in
  let getenv_nonempty name =
    match Sys.getenv_opt name with Some "" | None -> None | Some value -> Some value
  in
  let env =
    {
      Dispatcher.layout;
      topology = Some topology;
      compute_target = compute_target;
      edge_target = (Topology.edge topology).ssh;
      (* The hosts keep each run's lock here, so two serais configured with
         different stages do not see each other's runs. *)
      remote_stage = getenv_default "OPS_REMOTE_STAGE" "/tmp/serai-stage";
      ssh_bin = getenv_default "SSH_BIN" "ssh";
      rsync_bin = getenv_default "RSYNC_BIN" "rsync";
      curl_bin = getenv_default "CURL_BIN" "curl";
      config = declaration.apps;
      endpoints = declaration.endpoints;
      edge = declaration.edge;
      edge_ts_ip = getenv_nonempty "EDGE_TS_IP";
      edge_peer_match = getenv_nonempty "EDGE_PEER_MATCH";
      caddy_force_build = Sys.getenv_opt "CADDY_FORCE_BUILD" = Some "1";
      confirm =
        (fun question ->
          if assume_yes then true
          else if not (Unix.isatty Unix.stdin) then
            Run_state.fail ~cause:"approval_needed"
              (question ^ ": needs confirmation but stdin is not a terminal; re-run with --yes")
          else ask question);
      operator =
        Printf.sprintf "%s@%s"
          (Option.value (Sys.getenv_opt "USER") ~default:"unknown")
          (Unix.gethostname ());
      lock_token =
        (Random.self_init ();
         Printf.sprintf "%d-%08x%08x" (Unix.getpid ()) (Random.bits ()) (Random.bits ()));
      jj_bin = getenv_default "JJ_BIN" "jj";
      now_utc =
        (fun () ->
          let t = Unix.gmtime (Unix.time ()) in
          Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.tm_year + 1900) (t.tm_mon + 1) t.tm_mday
            t.tm_hour t.tm_min t.tm_sec);
      guests = declaration.guests;
      (* The defaults the bash ./ops used for the guest's shared ssh
         control socket. *)
      ops_control_path =
        (match getenv_nonempty "OPS_CONTROL_PATH" with
        | Some path -> path
        | None -> Option.value (getenv_nonempty "TMPDIR") ~default:"/tmp" ^ "/ops-ssh-%C");
      ssh_multiplex =
        (match Sys.getenv_opt "OPS_SSH_MULTIPLEX" with None | Some "" | Some "1" -> true | Some _ -> false);
      source_checkout_override = getenv_nonempty "SOURCE_CHECKOUT";
    }
  in
  env

let build_env ~assume_yes () : Dispatcher.env * Pipeline.t =
  let layout = locate_layout () in
  (env_of_layout ~assume_yes layout, Pipeline.load (Layout.pipelines layout))

let write_files dir files =
  match Rendered_output.write ~dir files with
  | Ok () -> ()
  | Error error -> Run_state.fail ~cause:"invalid_argument" (Rendered_output.error_message error)

(* Runs without build_env: validate needs no jj, operator, lock token or
   network, only the declaration, the shell configs that repeat it, the
   pipelines and the Caddy templates. *)
let validate ~out =
  Progress.phase "validate";
  let layout = locate_layout () in
  let declaration = load_declaration layout in
  ignore (Logging_policy.load ~layout ~apps:declaration.apps);
  ignore (Pipeline.load (Layout.pipelines layout));
  (match Idp_declaration.load ~layout with
   | Ok _ -> () | Error message -> Run_state.fail ~cause:"invalid_declaration" message);
  (match Config_drift.check declaration with
   | [] -> ()
   | drift -> Run_state.fail ~cause:"invalid_declaration" (String.concat "\n" (List.map Config_drift.message drift)));
  match Validation.render_all declaration with
  | Error msg -> Run_state.fail ~cause:"render_failed" msg
  | Ok files ->
      Option.iter (fun dir -> write_files dir files) out;
      print_endline (Validation.summary declaration files)

let artifact_plan ?revision name =
  Progress.phase "plan";
  let declaration = load_declaration (locate_layout ()) in
  let app = App_config.find declaration.apps name in
  let guest = List.find_opt (fun guest -> Guest_config.name guest = name) declaration.guests in
  let plan = match app, guest with
    | Some app, None -> Artifact_plan.of_app ?revision app
    | None, Some guest -> Artifact_plan.of_guest ?revision guest
    | None, None -> Run_state.fail ~cause:"unknown_workload" ("unknown workload: " ^ name)
    | Some _, Some _ -> Run_state.fail ~cause:"invalid_declaration" ("ambiguous workload: " ^ name)
  in
  match plan with
  | Ok plan -> print_endline (Artifact_plan.render plan)
  | Error message -> Run_state.fail ~cause:"invalid_declaration" message

let artifact_source_stage name ~revision ~out =
  Progress.phase "source";
  let layout = locate_layout () in
  let declaration = load_declaration layout in
  let app = App_config.find declaration.apps name in
  let guest = List.find_opt (fun guest -> Guest_config.name guest = name) declaration.guests in
  let checkout = match app, guest with
    | Some app, None ->
        (match app.strategy with
         | Strategy_config.Freebsd_native_elixir strategy -> strategy.repo_path
         | Strategy_config.Freebsd_native_ocaml strategy -> strategy.repo_path
         | _ -> Run_state.fail ~cause:"unsupported_for_workload" (name ^ ": source staging requires a source-built workload"))
    | None, Some guest -> guest.source_checkout
    | None, None -> Run_state.fail ~cause:"unknown_workload" ("unknown workload: " ^ name)
    | Some _, Some _ -> Run_state.fail ~cause:"invalid_declaration" ("ambiguous workload: " ^ name)
  in
  let checkout = Layout.config_path layout checkout in
  match Source_snapshot.stage ~jj_bin:(getenv_default "JJ_BIN" "jj") ~checkout ~revision ~out with
  | Ok commit -> Printf.printf "source commit: %s\nstaged at: %s\n%!" commit out
  | Error message -> Run_state.fail ~cause:"source_unavailable" message

(* Mirrors and base archives are reproducible downloads; the store holds
   verified artifacts worth keeping. Both are private to this user. *)
let up_dirs () =
  let cache = getenv_default "SERAI_CACHE" (Filename.concat (xdg "XDG_CACHE_HOME" ".cache") "serai") in
  let store = getenv_default "SERAI_STORE"
    (Filename.concat (Filename.concat (xdg "XDG_DATA_HOME" ".local/share") "serai") "store") in
  let rec make_private dir =
    if not (Sys.file_exists dir) then (make_private (Filename.dirname dir); Sys.mkdir dir 0o700) in
  List.iter make_private [ cache; store ];
  cache, store

let up ?local_source ?target ?expect_plan env app ~revision =
  let cache, store = up_dirs () in
  Dispatcher.up ?local_source ?target ?expect_plan env app ~revision ~cache ~store

let up_run ?local_source ?expect_plan env app ~revision =
  let cache, store = up_dirs () in
  Dispatcher.up_run ?local_source ?expect_plan env app ~revision ~cache ~store

(* A plan id from the command line; a malformed one is refused before
   anything else happens. *)
let expected_plan text =
  match Plan_id.parse text with Ok id -> id | Error message -> raise (Agent_cli.Bad_request message)

let up_plan ?local_source env app ~revision =
  let cache, store = up_dirs () in
  Dispatcher.up_plan ?local_source env app ~revision ~cache ~store

(* serai up <app> and its flags, through the command table: the app, the
   revision and a lookup that also answers the global and plan flags. *)
let parse_up argv =
  match Cli_spec.parse argv with
  | Ok ({ command = { path = [ "up" ]; _ }; arguments = [ app ]; _ } as inv) ->
      let switch on = if on then Some "" else None in
      Option.map (fun revision ->
          app, revision, (function
            | "--plan" -> switch inv.plan | "--yes" -> switch inv.yes
            | "--expect-plan" -> inv.expect_plan
            | flag -> Cli_spec.flag inv flag))
        (Cli_spec.flag inv "--revision")
  | _ -> None

let new_kind = function
  | "phoenix" -> Dispatcher.New_phoenix
  | "ocaml" -> Dispatcher.New_ocaml
  | kind -> Run_state.fail ~cause:"invalid_argument" ("new: --kind is phoenix or ocaml, not " ^ kind)

let new_app ?hostname env app ~kind ~repo =
  Dispatcher.new_app env app ~kind:(new_kind kind) ~repo ~hostname

let print_new (plan : App_scaffold.t) app =
  Printf.printf "declared %s at %s, http port %d, https://%s\n" app plan.ip plan.port plan.hostname;
  List.iter (fun (f : App_scaffold.file) -> Printf.printf "  wrote  %s\n" f.path) plan.files;
  Printf.printf "  placed and proxied in serai.sexp\n\
                 next: review and commit the declaration, then serai up %s --revision <rev>\n%!" app

(* The commands that act, answered in the agent envelope. *)
let new_json (plan : App_scaffold.t) app =
  Agent_cli.(Object [ "app", String app; "ip", String plan.ip; "port", Json.of_int plan.port;
    "hostname", String plan.hostname;
    "files", Array (List.map (fun (f : App_scaffold.file) -> String f.path) plan.files @ [ String Layout.Relative.topology ]);
    "host_inspected", Bool false ])

let up_plan_json (plan : Dispatcher.up_plan) =
  Agent_cli.(Object [ "app", String plan.app; "host", String plan.host; "source", String plan.source;
    "commit", String plan.commit; "local_source", Bool plan.local;
    "jail", (match plan.jail with
      | Dispatcher.Jail_ready -> Object [ "action", String "none" ]
      | Jail_create -> Object [ "action", String "create" ]
      | Jail_needs_env message -> Object [ "action", String "refused"; "message", String message ]);
    "release", (match plan.release with
      | Dispatcher.Reuse identity -> Object [ "action", String "reuse"; "identity", String identity ]
      | Build { ip; base_sha256; lib32_sha256 } ->
          Object [ "action", String "build"; "builder_ip", String ip; "base_sha256", String base_sha256;
                   "lib32_sha256", (match lib32_sha256 with Some sha256 -> String sha256 | None -> Null) ]);
    "public_url", String plan.public_url; "plan_id", String (Plan_id.to_string (Dispatcher.up_plan_id plan));
    "host_inspected", Bool true; "applied", Bool false ])

let component_json (name, host) = Agent_cli.(Object [ "component", String name; "host", String host ])

let edge_plan_json (plan : Dispatcher.edge_plan) =
  Agent_cli.(Object [
    "pending", Bool (plan.plan_id <> None);
    "plan_id", (match plan.plan_id with Some id -> String (Plan_id.to_string id) | None -> Null);
    "components", Array (List.map component_json plan.components) ])

let edge_outcome_json (outcome : Dispatcher.edge_outcome) =
  Agent_cli.(Object [
    "applied", Array (List.map component_json outcome.applied);
    "failed", (match outcome.failed with
      | None -> Null
      | Some (name, host, message) ->
          Object [ "component", String name; "host", String host; "message", String message ]) ])

let short = Hex.short

let drift_apply_command app (plan : Dispatcher.up_plan) =
  Printf.sprintf "serai up %s --revision %s --yes --json --expect-plan %s"
    app plan.commit (Plan_id.to_string (Dispatcher.up_plan_id plan))

let drift_json (t : Drift.t) =
  let open Agent_cli in
  let section to_fields = function
    | Drift.Checked value -> Object (("state", String "checked") :: to_fields value)
    | Unavailable message -> Object [ "state", String "unavailable"; "message", String message ]
    | Not_declared -> Object [ "state", String "not_declared" ] in
  let fields = function Object fields -> fields | json -> [ "plan", json ] in
  let app = function
    | Drift.App_checked { app; state; live; target; plan } ->
        Object ([ "app", String app; "state", String (Drift_app.state_to_string state);
                  "live", (match live with Some commit -> String commit | None -> Null);
                  "target", String target.commit; "target_revision", String target.revision ]
                @ match plan with
                  | Some plan -> [ "plan", up_plan_json plan; "apply", String (drift_apply_command app plan) ]
                  | None -> [])
    | App_unavailable { app; message } -> Object [ "app", String app; "state", String "unavailable"; "message", String message ]
    | App_not_covered app -> Object [ "app", String app; "state", String "not_covered" ] in
  Object [
    "drifted", Bool (Drift.drifted t); "complete", Bool (Drift.complete t);
    "edge", section (fun plan -> fields (edge_plan_json plan)) t.edge;
    "idp", section (fun (plan : Idp_plan.t) ->
        fields (Idp_plan.to_json plan)
        @ [ "lockout", (match plan.lockout with Some message -> String message | None -> Null) ]) t.idp;
    "apps", Array (List.map app t.apps) ]

(* One line per section and app, after the edge's diffs. *)
let print_drift (t : Drift.t) =
  let unavailable what message = Printf.printf "%s: unavailable: %s\n" what message in
  let plan_suffix = function Some id -> "; plan " ^ Plan_id.to_string id | None -> "" in
  (match t.edge with
   | Drift.Checked { components = []; _ } -> print_endline "edge: current"
   | Checked { components; plan_id } ->
       Printf.printf "edge: pending %s%s\n"
         (String.concat ", " (List.map (fun (name, host) -> Printf.sprintf "%s [%s]" name host) components))
         (plan_suffix plan_id)
   | Unavailable message -> unavailable "edge" message
   | Not_declared -> print_endline "edge: not declared");
  (match t.idp with
   | Drift.Checked plan when plan.plan_id = None -> print_endline "idp: current"
   | Checked plan ->
       Printf.printf "idp: pending %d action%s%s%s\n" (List.length plan.actions)
         (if List.length plan.actions = 1 then "" else "s") (plan_suffix plan.plan_id)
         (match plan.lockout with Some message -> "; refused: " ^ message | None -> "")
   | Unavailable message -> unavailable "idp" message
   | Not_declared -> print_endline "idp: not declared");
  List.iter (function
      | Drift.App_checked { app; state; live; target; plan } ->
          let from = match live with Some commit -> short commit ^ " -> " | None -> "" in
          Printf.printf "app %s: %s %s%s (%s)%s\n" app (Drift_app.state_to_string state) from (short target.commit)
            target.revision (plan_suffix (Option.map Dispatcher.up_plan_id plan))
      | App_unavailable { app; message } -> unavailable ("app " ^ app) message
      | App_not_covered app -> Printf.printf "app %s: not covered\n" app)
    t.apps;
  flush stdout

let drift env =
  let cache, store = up_dirs () in
  Drift.run env ~cache ~store

let step_status (status : Dispatcher.step_status) =
  Agent_cli.(match status with
    | Done -> [ "status", String "done" ]
    | Skipped -> [ "status", String "skipped" ]
    | Not_run -> [ "status", String "not_run" ]
    | Failed message -> [ "status", String "failed"; "message", String message ]
    | Pending message -> [ "status", String "pending"; "message", String message ])

(* What the operator or agent does after a failed step: a sentence, and
   the command when there is one. Nothing is undone automatically: a
   release may already have migrated. *)
let next_after app ~revision (step : Dispatcher.up_step) =
  match step with
  | Jail -> Printf.sprintf "inspect jail %s on the compute host before running serai up again" app,
            [ "serai"; "status"; app; "--json" ]
  | Build -> Printf.sprintf "fix the build, then serai up %s --revision %s" app revision,
             [ "serai"; "up"; app; "--revision"; revision; "--plan"; "--json" ]
  | Release -> Printf.sprintf "serai status %s says which release is active" app, [ "serai"; "status"; app; "--json" ]
  | Edge -> "serai edge --plan", [ "serai"; "edge"; "--plan"; "--json" ]
  | Check -> Printf.sprintf "serai check %s" app, [ "serai"; "check"; app; "--json" ]

let up_json app ~revision ((plan : Dispatcher.up_plan), (outcome : Dispatcher.up_outcome)) =
  let open Agent_cli in
  let data result next =
    Object ([ "app", String app; "commit", String plan.commit; "local_source", Bool plan.local ] @ result
      @ [ "steps", Array (List.map (fun (step, status) ->
            Object (("name", String (Dispatcher.step_name step)) :: step_status status)) outcome.steps);
          "next", (match next with Some (text, _) -> String text | None -> Null);
          "next_command", (match next with
            | Some (_, (_ :: _ as command)) -> Array (List.map (fun word -> String word) command)
            | _ -> Null) ]) in
  match outcome.result with
  | Deployed identity -> Ok (data [ "outcome", String "deployed"; "identity", String identity ] None)
  | Stopped_for_env message -> Ok (data [ "outcome", String "stopped_for_operator" ] (Some (message, [])))
  | Stopped_for_edge id ->
      let id = Plan_id.to_string id in
      Ok (data [ "outcome", String "stopped_for_operator"; "edge_plan_id", String id ]
            (Some (Printf.sprintf "have the edge plan %s approved and apply it, then serai check %s" id app,
                   [ "serai"; "edge"; "--yes"; "--json"; "--expect-plan"; id ])))
  | Step_failed (step, message) ->
      Error (data [ "outcome", String "failed" ] (Some (next_after app ~revision step)), message)

(* serai update: its settings and state live with the user running it, the
   configuration comes from a verified commit, not the working directory. *)
let update_paths () =
  let settings = Filename.concat (Filename.concat (xdg "XDG_CONFIG_HOME" ".config") "serai") "update.sexp" in
  let state_dir = Filename.concat (Filename.concat (xdg "XDG_STATE_HOME" ".local/state") "serai") "update" in
  let cache, store = up_dirs () in
  settings, { Update.state_dir; cache; store; engine = installed_engine () }

let update_settings path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text -> (match Update.config_of_string text with
    | Ok config -> config | Error message -> Run_state.fail ~cause:"invalid_environment" message)
  | exception Sys_error message -> Run_state.fail ~cause:"invalid_environment" ("update: " ^ message)

let update_deps () =
  { Update.jj_bin = getenv_default "JJ_BIN" "jj"; env_of_layout = env_of_layout ~assume_yes:true }

(* Everything a run prints, its subprocesses included, kept aside: cron
   mails any output, and a run with nothing new must print nothing. *)
let captured f =
  let log = Filename.temp_file "serai-update" ".log" in
  flush_all ();
  let saved_out = Unix.dup Unix.stdout and saved_err = Unix.dup Unix.stderr in
  let fd = Unix.openfile log [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 fd Unix.stdout; Unix.dup2 fd Unix.stderr; Unix.close fd;
  let result = try Ok (f ()) with error -> Error error in
  flush_all ();
  Unix.dup2 saved_out Unix.stdout; Unix.dup2 saved_err Unix.stderr;
  Unix.close saved_out; Unix.close saved_err;
  let text = In_channel.with_open_bin log In_channel.input_all in
  Sys.remove log;
  result, text

let revert_json = function
  | Update.Not_attempted why -> Agent_cli.(Object [ "outcome", String "not_attempted"; "message", String why ])
  | Reverted -> Agent_cli.(Object [ "outcome", String "reverted" ])
  | Revert_failed message -> Agent_cli.(Object [ "outcome", String "failed"; "message", String message ])

let update_outcome_json (name, outcome) =
  let open Agent_cli in
  let fields = match outcome with
    | Update.Not_enrolled -> [ "outcome", String "not_enrolled" ]
    | Built_on_controller -> [ "outcome", String "built_on_controller" ]
    | Already_handled commit -> [ "outcome", String "already_handled"; "commit", String commit ]
    | Current commit -> [ "outcome", String "current"; "commit", String commit ]
    | Would_deploy commit -> [ "outcome", String "would_deploy"; "commit", String commit ]
    | Deployed { commit; identity } ->
        [ "outcome", String "deployed"; "commit", String commit; "identity", String identity ]
    | Refused { commit; refusal } ->
        [ "outcome", String "refused"; "commit", String commit;
          "message", String (Update_decision.refusal_message refusal) ]
    | Failed { commit; step; message; revert } ->
        [ "outcome", String "failed"; "commit", String commit; "step", String (Dispatcher.step_name step);
          "message", String message; "revert", revert_json revert ]
    | Not_applied { commit; message } ->
        [ "outcome", String "not_applied";
          "commit", (match commit with Some commit -> String commit | None -> Null);
          "message", String message ] in
  Object (("app", String name) :: fields)

let update_report_json (report : Update.report) =
  let open Agent_cli in
  [ "configuration", (match report.configuration with
      | Update.Configuration commit -> Object [ "status", String "verified"; "commit", String commit ]
      | Configuration_refused { commit; refusal } ->
          Object [ "status", String "refused"; "commit", String commit;
                   "message", String (Update_decision.refusal_message refusal) ]
      | Configuration_unavailable message -> Object [ "status", String "unavailable"; "message", String message ]);
    "apps", Array (List.map update_outcome_json report.apps);
    "host_inspected", Bool (match report.configuration with Update.Configuration _ -> true | _ -> false) ]

let update argv =
  let flags = List.filter (fun arg -> arg <> "update") argv in
  if List.exists (fun flag -> not (List.mem flag [ "--plan"; "--json" ])) flags then begin
    prerr_string (Cli_spec.usage ());
    exit 1
  end;
  let plan = List.mem "--plan" flags and json = List.mem "--json" flags in
  let settings_path, paths = update_paths () in
  let act () =
    let config = update_settings settings_path in
    if plan then `Plan (Update.plan (update_deps ()) config paths)
    else `Run (Update.run (update_deps ()) config paths) in
  if json then begin
    let operation = if plan then "update.plan" else "update" in
    let response = with_stdout_on_stderr
      (fun () -> Agent_cli.respond ~operation (fun () ->
         match Proc.live act with
         | `Plan report ->
             let data = Agent_cli.Object (update_report_json report @ [ "applied", Agent_cli.Bool false ]) in
             (match report.configuration with
              | Update.Configuration _ -> Ok data
              | _ -> Error (data, String.concat "; " (Update.plan_lines report)))
         | `Run None -> Ok (Agent_cli.Object [ "ran", Agent_cli.Bool false ])
         | `Run (Some run) ->
             let data = Agent_cli.Object (update_report_json run.report
               @ [ "ran", Agent_cli.Bool true;
                   "reported", Agent_cli.Array (List.map (fun line -> Agent_cli.String line) run.lines) ]) in
             if run.failed then Error (data, String.concat "; " run.lines) else Ok data)) in
    print_endline (Agent_cli.to_json response);
    exit (Agent_cli.exit_code response)
  end;
  match captured (fun () -> Proc.live act) with
  | Ok (`Plan report), _ ->
      List.iter print_endline (Update.plan_lines report);
      exit (match report.configuration with Update.Configuration _ -> 0 | _ -> 1)
  | Ok (`Run None), _ -> exit 0
  | Ok (`Run (Some { lines = []; _ })), _ -> exit 0
  | Ok (`Run (Some run)), log ->
      List.iter print_endline run.lines;
      if log <> "" then (print_string "\n--- log ---\n"; print_string log);
      exit (if run.failed then 1 else 0)
  | Error error, log ->
      Printf.printf "update: %s\n" (match error with Failure message -> message | error -> Printexc.to_string error);
      if log <> "" then (print_string "\n--- log ---\n"; print_string log);
      exit 1

(* serai idp: Pocket ID's users, groups, clients and APIs against idp.sexp.
   Runs on the controller over HTTPS only: no ssh, lock or host. *)
let idp argv =
  let usage () = prerr_string (Cli_spec.usage ()); exit 1 in
  let rec parse ~plan ~json ~yes ~export ~url ~expect = function
    | [] -> (plan, json, yes, export, url, expect)
    | "--plan" :: rest when not plan -> parse ~plan:true ~json ~yes ~export ~url ~expect rest
    | "--json" :: rest when not json -> parse ~plan ~json:true ~yes ~export ~url ~expect rest
    | "--yes" :: rest when not yes -> parse ~plan ~json ~yes:true ~export ~url ~expect rest
    | "--export" :: rest when not export -> parse ~plan ~json ~yes ~export:true ~url ~expect rest
    | "--url" :: value :: rest when url = None -> parse ~plan ~json ~yes ~export ~url:(Some value) ~expect rest
    | "--expect-plan" :: value :: rest when expect = None ->
        parse ~plan ~json ~yes ~export ~url ~expect:(Some value) rest
    | _ -> usage () in
  let plan, json, yes, export, url, expect =
    parse ~plan:false ~json:false ~yes:false ~export:false ~url:None ~expect:None (List.tl argv) in
  (match () with
   | () when export && (plan || json || yes || expect <> None) -> usage ()
   | () when (not export) && url <> None -> usage ()
   | () when json && not (plan || yes) -> usage ()
   | () when plan && (yes || expect <> None) -> usage ()
   | () -> ());
  let fail message = Printf.eprintf "idp: %s\n%!" message; exit 1 in
  let curl_bin = getenv_default "CURL_BIN" "curl" in
  let fetch_result url =
    match Pocket_id.session ~url with
    | Error message -> Error message
    | Ok session ->
        Result.map (fun live -> (session, live))
          (Result.map_error Pocket_id.error_message (Proc.live (fun () -> Pocket_id.fetch ~curl_bin session))) in
  let no_declaration layout =
    Printf.sprintf "no %s: nothing is declared (start from the live state with serai idp --export --url https://<host> > idp.sexp)"
      (Layout.idp layout) in
  let stale expected (current : Plan_id.t option) =
    Printf.sprintf "idp: stale plan: approved %s, now %s; run serai idp --plan again"
      (Plan_id.to_string expected)
      (match current with Some id -> Plan_id.to_string id | None -> "nothing to do") in
  (* For --json: the declaration, the live state and the plan between them,
     or a Failure before anything changes. *)
  let planned () =
    let layout = locate_layout () in
    let declaration = match Idp_declaration.load ~layout with
      | Ok (Some d) -> d
      | Ok None -> Run_state.fail ~cause:"invalid_declaration" (no_declaration layout)
      | Error message -> Run_state.fail ~cause:"invalid_declaration" message in
    match fetch_result declaration.url with
    | Error message -> Run_state.fail ~cause:"service_unavailable" message
    | Ok (session, live) ->
        let t = Idp_plan.plan declaration live in
        Option.iter (Run_state.fail ~cause:"would_lock_out") t.lockout;
        session, live, t in
  if json && yes then begin
    let response = with_stdout_on_stderr
      (fun () -> Agent_cli.respond ~operation:"idp.apply" (fun () ->
         let expected = match expect with
           | None -> raise (Agent_cli.Bad_request "serai idp --yes --json requires --expect-plan <id>, the plan_id of the approved serai idp --plan --json")
           | Some text -> (match Plan_id.parse text with Ok id -> id | Error m -> raise (Agent_cli.Bad_request m)) in
         match planned () with
         | session, live, t ->
             if t.plan_id <> Some expected then raise (Plan_id.Stale (stale expected t.plan_id));
             let applied = Proc.live (fun () -> Pocket_id.apply ~curl_bin session live t) in
             let open Agent_cli in
             let optional_int = function Some n -> Json.of_int n | None -> Null in
             let optional_text = function Some s -> String s | None -> Null in
             let failed = match applied.failed with
               | None -> Null
               | Some (action, (error : Pocket_id.error)) ->
                   Object [ ("action", Idp_plan.action_to_json action); ("request", String error.request);
                            ("status", optional_int error.status); ("code", optional_text error.code);
                            ("message", String error.message) ] in
             let data = Object [
                 ("completed", Array (List.map Idp_plan.action_to_json applied.completed));
                 ("failed", failed);
                 ("secrets_needed", Array (List.map (fun c -> String c) t.secrets_needed)) ] in
             match applied.failed with
             | None -> Ok data
             | Some (_, error) -> Error (data, Pocket_id.error_message error))) in
    print_endline (Agent_cli.to_json response);
    exit (Agent_cli.exit_code response)
  end;
  if json then begin
    let pending = ref false in
    let response = with_stdout_on_stderr
      (fun () -> Agent_cli.respond ~operation:"idp.plan" (fun () ->
         let _, _, t = planned () in
         pending := Idp_plan.pending t;
         Ok (Idp_plan.to_json t))) in
    print_endline (Agent_cli.to_json response);
    let code = Agent_cli.exit_code response in
    exit (if code = 0 && !pending then 2 else code)
  end;
  let layout = locate_layout () in
  let load () = match Idp_declaration.load ~layout with Ok d -> d | Error message -> fail message in
  let fetch url = match fetch_result url with Ok x -> x | Error message -> fail message in
  if export then begin
    (* --url never reads idp.sexp: [serai idp --export --url ... > idp.sexp]
       has the shell create it, empty, before serai starts. *)
    let url = match url with
      | Some url -> url
      | None -> (match load () with
          | Some d -> d.url
          | None -> fail "no idp.sexp: give the server with --export --url https://<host>") in
    let _, live = fetch url in
    match Idp_plan.export ~url live with
    | Error message -> fail message
    | Ok declaration ->
        Printf.printf "; Exported from %s by serai idp --export. Review it before committing.\n%s\n"
          url (Idp_declaration.to_string declaration);
        exit 0
  end;
  let expected = Option.map (fun text ->
      match Plan_id.parse text with Ok id -> id | Error message -> fail message) expect in
  let declaration = match load () with Some d -> d | None -> fail (no_declaration layout) in
  let session, live = fetch declaration.url in
  let t = Idp_plan.plan declaration live in
  List.iter print_endline (Idp_plan.lines t);
  if plan then Option.iter (fun id -> Printf.printf "plan %s\n" (Plan_id.to_string id)) t.plan_id;
  Option.iter (fun reason -> fail ("refused: " ^ reason)) t.lockout;
  if plan then exit (if Idp_plan.pending t then 2 else 0);
  Option.iter (fun expected ->
      if t.plan_id <> Some expected then begin
        Printf.eprintf "%s\n%!" (stale expected t.plan_id); exit 1
      end) expected;
  if not (Idp_plan.pending t) then exit 0;
  let count = List.length t.actions in
  let confirmed =
    yes
    || (Unix.isatty Unix.stdin
        && ask (Printf.sprintf "Apply %d change%s to %s?" count (if count = 1 then "" else "s") declaration.url)) in
  if not confirmed then
    fail (if Unix.isatty Unix.stdin then "not applied" else "needs confirmation but stdin is not a terminal; re-run with --yes");
  let applied = Proc.live (fun () -> Pocket_id.apply ~curl_bin session live t) in
  let done_count = List.length applied.completed in
  match applied.failed with
  | Some (_, error) ->
      Printf.printf "applied %d of %d; stopped: %s\nRun serai idp --plan to see what remains.\n"
        done_count count (Pocket_id.error_message error);
      exit 1
  | None ->
      Printf.printf "applied %d change%s\n" done_count (if done_count = 1 then "" else "s");
      List.iter (fun client ->
          Printf.printf "client %s: create a secret for it in the UI and put it in the app's env file\n" client)
        t.secrets_needed;
      exit 0

let acting_json argv =
  let run ?(assume_yes = false) ?(pending = ref false) ?(incomplete = ref false) operation workload f =
    Progress.start ~enabled:(List.mem "--progress=jsonl" argv) ~operation ~workload:(Some workload);
    Sys.catch_break true;
    let response = with_stdout_on_stderr
      (fun () -> Agent_cli.respond ~operation (fun () ->
         Proc.live (fun () -> f (fst (build_env ~assume_yes ()))))) in
    print_endline (Agent_cli.to_json response);
    let code = Agent_cli.exit_code response in
    let code = if code = 0 && !pending then 2 else if code = 0 && !incomplete then 1 else code in
    Progress.finish (if code = 0 then Progress.Succeeded else if code = 2 then Progress.Changes_pending
                     else if code = 130 then Progress.Interrupted else Progress.Failed);
    exit code in
  (* Refused before the repository is loaded or anything is contacted. *)
  let refuse operation message =
    let response = Agent_cli.respond ~operation (fun () -> raise (Agent_cli.Bad_request message)) in
    print_endline (Agent_cli.to_json response);
    exit (Agent_cli.exit_code response) in
  let checked operation text =
    match Plan_id.parse text with Ok id -> id | Error message -> refuse operation message in
  match List.filter (fun arg -> arg <> "--json" && arg <> "--progress=jsonl") argv with
  | [ "new"; app; "--kind"; kind; "--repo"; repo ] ->
      run "new" app (fun env -> Ok (new_json (new_app env app ~kind ~repo) app))
  | [ "new"; app; "--kind"; kind; "--repo"; repo; "--hostname"; hostname ] ->
      run "new" app (fun env -> Ok (new_json (new_app ~hostname env app ~kind ~repo) app))
  | "up" :: _ as up_argv ->
      (match parse_up up_argv with
       | None -> ()
       | Some (app, revision, flag) ->
           let local_source = flag "--source" in
           (match flag "--plan", flag "--yes", flag "--expect-plan", flag "--rehearse", flag "--ip" with
            | Some _, None, None, None, None ->
                run "up.plan" app (fun env -> Ok (up_plan_json (up_plan ?local_source env app ~revision)))
            (* Applies only with --yes, there being no terminal to ask in,
               and only the plan the operator approved. *)
            | None, Some _, Some id, None, None ->
                let expect_plan = checked "up" id in
                run ~assume_yes:true "up" app (fun env ->
                  up_json app ~revision (up_run ?local_source ~expect_plan env app ~revision))
            | None, Some _, None, None, None ->
                refuse "up" "serai up --yes --json requires --expect-plan <id>, the plan_id of the approved serai up --plan --json"
            | _ -> ()))
  | [ "edge"; "--plan" ] ->
      let pending = ref false in
      run ~pending "edge.plan" "edge" (fun env ->
        let plan = Dispatcher.plan_edge env in
        pending := plan.plan_id <> None;
        Ok (edge_plan_json plan))
  | [ "edge"; "--yes"; "--expect-plan"; id ] ->
      let expect_plan = checked "edge" id in
      run ~assume_yes:true "edge" "edge" (fun env ->
        let outcome = Dispatcher.edge_run ~expect_plan env in
        let data = edge_outcome_json outcome in
        match outcome.failed with None -> Ok data | Some (_, _, message) -> Error (data, message))
  | [ "edge"; "--yes" ] ->
      refuse "edge" "serai edge --yes --json requires --expect-plan <id>, the plan_id of the approved serai edge --plan --json"
  | "edge" :: _ ->
      refuse "edge" "serai edge --json takes --plan, or --yes --expect-plan <id>"
  | [ "drift" ] ->
      let pending = ref false and incomplete = ref false in
      run ~pending ~incomplete "drift" "drift" (fun env ->
        let t = drift env in
        pending := Drift.drifted t;
        incomplete := not (Drift.complete t);
        Ok (drift_json t))
  | "drift" :: _ -> refuse "drift" "serai drift --json takes no other argument"

  | _ -> ()

(* What approving a command as requested approves: the request itself. *)
let request_facts (inv : Cli_spec.invocation) =
  [ "command", Cli_spec.name inv.command ]
  @ List.mapi (fun i argument -> Printf.sprintf "argument%d" i, argument) inv.arguments
  @ inv.flags

(* Every command but update and idp. Prints for a person and returns the
   same result as data; under --json stdout is the envelope's alone, and
   what is printed here goes to stderr. *)
let dispatch (context : (Dispatcher.env * Pipeline.t) Lazy.t) (inv : Cli_spec.invocation) : Json.t =
  let open Json in
  let env () = fst (Lazy.force context) in
  let flag = Cli_spec.flag inv and has = Cli_spec.has inv in
  let need name = match flag name with Some value -> value | None -> usage_and_exit () in
  (* A command with nothing more to say names what it acted on; the
     envelope adds the hosts and the steps that ran. *)
  let none = match inv.arguments with
    | workload :: _ -> Object [ "workload", String workload ]
    | [] -> Object [] in
  let names list = List.iter print_endline list; Array (List.map (fun name -> String name) list) in
  (* A command that asks nothing itself is approved as requested, when a
     plan is asked for or expected. *)
  if inv.command.approval = Cli_spec.Bound_by_request && !Run_state.approval <> Run_state.Ask then begin
    (* No plan for a workload that is not declared. *)
    let env = env () in
    let known list name = List.mem name list in
    (match inv.command.arguments, inv.arguments with
     | (kind, _) :: _, name :: _ when List.mem kind [ "app"; "guest"; "app|guest" ] ->
         let apps = Dispatcher.list_apps env and guests = Dispatcher.list_guests env in
         if not ((kind <> "guest" && known apps name) || (kind <> "app" && known guests name)) then
           Run_state.fail ~cause:"unknown_workload" (Printf.sprintf "unknown %s: %s" kind name)
     | ("host-id|guest", _) :: _, name :: _ when Remote_host.host_of_label env name = None ->
         Run_state.fail ~cause:"invalid_argument" ("expected a configured host ID or guest name, not " ^ name)
     | _ -> ());
    ignore (Remote_host.approved env ~operation:(String.concat "." inv.command.path)
              ~facts:(request_facts inv) (Cli_spec.name inv.command))
  end;
  match inv.command.path, inv.arguments with
  | [ "apps" ], [] -> names (Dispatcher.list_apps (env ()))
  | [ "guests" ], [] -> names (Dispatcher.list_guests (env ()))
  | [ "commands" ], [] -> print_string (Cli_spec.usage ()); Cli_spec.to_json ()
  | [ "render-logging-targets" ], [] ->
      let layout = locate_layout () in
      let targets = Logging_policy.load ~layout ~apps:(load_declaration layout).apps |> Logging_policy.render_targets in
      print_string targets; Object [ "targets", String targets ]
  | [ "validate" ], [] -> validate ~out:(flag "--out"); none
  | [ "artifact"; "plan" ], [ name ] -> artifact_plan ?revision:(flag "--revision") name; none
  | [ "artifact"; "source-stage" ], [ name ] ->
      artifact_source_stage name ~revision:(need "--revision") ~out:(need "--out"); none
  | [ "artifact"; "build" ], [ name ] ->
      let env = env () and reuse = flag "--reuse" and store = need "--store" in
      let opam_repository = match flag "--opam-repository", flag "--opam-revision" with
        | Some checkout, Some revision -> Some (checkout, revision)
        | None, None -> None
        | _ -> usage_and_exit () in
      let identity =
        match flag "--revision", flag "--ip", flag "--base", flag "--sha256", opam_repository, flag "--compiler" with
        | Some revision, None, None, None, Some opam_repository, Some compiler ->
            Dispatcher.artifact_build_guest_store ?reuse env name ~revision ~opam_repository ~compiler ~store
        | Some revision, Some ip, Some base_archive, Some base_sha256, opam_repository, None ->
            Dispatcher.artifact_build_store ?reuse ?opam_repository env name ~revision ~ip
              ~base_archive ~base_sha256 ~store
        | None, Some ip, Some base_archive, Some base_sha256, None, None ->
            Dispatcher.artifact_build_executable_store ?reuse env name ~ip ~base_archive ~base_sha256 ~store
        | _ -> usage_and_exit () in
      Printf.printf "%s verified artifact: %s\n%!" (if reuse = None then "stored" else "reused") identity;
      Object [ "identity", String identity; "reused", Bool (reuse <> None) ]
  | [ "artifact"; "install" ], [ app ] ->
      Dispatcher.artifact_install (env ()) app ~identity:(need "--identity") ~archive:(need "--archive")
        ~sha256:(need "--sha256"); none
  | [ "artifact"; ("upgrade" | "rollback" | "convert" as mode) ], [ name ] ->
      let env = env () and identity = need "--identity" and store = need "--store" in
      let convert = mode = "convert" and rollback = mode = "rollback" in
      if List.mem name (Dispatcher.list_guests env)
      then Dispatcher.artifact_apply_guest ~convert env name ~store ~identity ~rollback
      else Dispatcher.artifact_apply ~convert env name ~store ~identity ~rollback;
      Object [ "identity", String identity; "mode", String mode ]
  | [ "revert" ], [ app ] -> Dispatcher.revert (env ()) app; none
  | [ "new" ], [ app ] ->
      let plan = new_app ?hostname:(flag "--hostname") (env ()) app ~kind:(need "--kind") ~repo:(need "--repo") in
      print_new plan app; new_json plan app
  | [ "bootstrap" ], [ app ] -> Dispatcher.bootstrap (env ()) app; none
  | [ "deploy" ], [ name ] -> Dispatcher.deploy_app_or_guest (env ()) name; none
  | [ "provision" ], [ guest ] -> Dispatcher.provision_guest (env ()) guest; none
  | [ "build" ], [ guest ] -> Dispatcher.build_guest (env ()) guest; none
  | [ "check" ], [ app ] ->
      let env = env () in
      Dispatcher.check env app;
      let fact = Dispatcher.check_environment (Dispatcher.find_app env app) in
      let get name = List.assoc name fact in
      Object [ "workload", String app; "service", String (get "SERVICE");
               "checked", Array [
                 String (Printf.sprintf "http://%s:%s%s" (get "JAIL_IP") (get "PORT") (get "CHECK_PATH"));
                 String (Printf.sprintf "https://%s%s" (get "PUBLIC_HOST") (get "CHECK_PATH")) ] ]
  | [ "up" ], [ app ] ->
      let env = env () and revision = need "--revision" and local_source = flag "--source" in
      (match inv.plan, has "--rehearse", flag "--ip" with
       | true, false, None when inv.expect_plan = None ->
           let plan = up_plan ?local_source env app ~revision in
           Dispatcher.print_up_plan plan; up_plan_json plan
       | false, true, Some ip when inv.expect_plan = None ->
           up ?local_source ~target:(Dispatcher.Rehearse ip) env app ~revision; none
       | false, false, None ->
           up ?local_source ?expect_plan:(Option.map expected_plan inv.expect_plan) env app ~revision; none
       | _ -> usage_and_exit ())
  | [ "edge" ], [] when inv.plan ->
      let plan = Dispatcher.plan_edge (env ()) in
      (match plan.plan_id with
       | Some id -> Printf.printf "plan %s\n%!" (Plan_id.to_string id); raise (Cli_exit 2)
       | None -> edge_plan_json plan)
  | [ "edge" ], [] -> Dispatcher.edge ?expect_plan:(Option.map expected_plan inv.expect_plan) (env ()); none
  | [ "drift" ], [] ->
      let t = drift (env ()) in
      print_drift t;
      (match Drift.exit_code t with 0 -> drift_json t | code -> raise (Cli_exit code))
  | [ "status" ], ([] | [ _ ] as only) ->
      let apps = Status.apps ?only:(List.nth_opt only 0) (env ()) in
      List.iter (fun app -> print_endline (Status.app_line app)) apps;
      Object [ "apps", Array (List.map Status.app_json apps); "host_inspected", Bool true ]
  | [ "locks" ], ([] | [ _ ] as only) ->
      let locks = Status.locks ?only:(List.nth_opt only 0) (env ()) in
      List.iter (fun lock -> print_endline (Status.lock_line lock)) locks;
      Object [ "locks", Array (List.map Status.lock_json locks); "host_inspected", Bool true ]
  | [ "unlock" ], [ host ] -> Dispatcher.unlock (env ()) host; none
  | [ "caddy-install" ], [] -> Dispatcher.caddy_install (env ()); none
  | [ "jail-test" ], [ app ] ->
      (match flag "--ip", has "--destroy" with
       | Some ip, false -> Dispatcher.jail_test (env ()) app ~ip
       | None, true -> Dispatcher.jail_test_destroy (env ()) app
       | _ -> usage_and_exit ());
      none
  | [ "rollout" ], [ app ] ->
      let env, registry = Lazy.force context in
      Pipeline.run env registry app (if has "--edge" then "rollout-edge" else "rollout"); none
  | [ "run" ], [ app; pipeline ] ->
      let env, registry = Lazy.force context in
      Pipeline.run env registry app pipeline; none
  | [ "update-version" ], (app :: version) ->
      Dispatcher.update_version (env ()) app (match version with [ version ] -> version | _ -> ""); none
  | _ -> usage_and_exit ()

(* How this invocation's approvals are answered. *)
let approval_of (inv : Cli_spec.invocation) =
  match inv.plan, inv.expect_plan with
  | true, _ -> Run_state.Plan_only
  | false, Some id -> Run_state.Expect (expected_plan id)
  | false, None -> Run_state.Ask

let operation_of (inv : Cli_spec.invocation) =
  String.concat "." inv.command.path, List.nth_opt inv.arguments 0

(* --json for every command the bespoke handlers above do not answer. A
   command that changes a host applies only an approved plan: there is no
   terminal to ask in, and --yes alone is nobody's approval of anything
   in particular. *)
let generic_json (inv : Cli_spec.invocation) =
  let operation, workload = operation_of inv in
  Progress.start ~enabled:inv.progress ~operation ~workload;
  Sys.catch_break true;
  let finish response =
    print_endline (Agent_cli.to_json response);
    let code = if Agent_cli.is_plan response then 2 else Agent_cli.exit_code response in
    Progress.finish (match code with
      | 0 -> Progress.Succeeded | 2 -> Progress.Changes_pending | 130 -> Progress.Interrupted | _ -> Progress.Failed);
    exit code in
  let refuse message = finish (Agent_cli.respond ~operation (fun () -> raise (Agent_cli.Bad_request message))) in
  let changes = inv.command.impact = Cli_spec.Changes_hosts in
  (match changes, inv.plan, inv.yes, inv.expect_plan with
   | false, _, _, _ | true, true, false, None | true, false, true, Some _ -> ()
   | true, _, _, _ ->
       refuse (Printf.sprintf
         "serai %s --json changes a host: it takes --plan, or --yes --expect-plan <id> with the plan_id the operator approved"
         (Cli_spec.name inv.command)));
  finish (with_stdout_on_stderr (fun () ->
    Agent_cli.respond ~operation (fun () ->
      Run_state.approval := approval_of inv;
      Proc.live (fun () -> Ok (dispatch (lazy (build_env ~assume_yes:true ())) inv)))))

let () =
  let argv = List.tl (Array.to_list Sys.argv) in
  (match argv with "update" :: _ -> update argv | "idp" :: _ -> idp argv | _ -> ());
  let json = List.mem "--json" argv in
  if json then acting_json argv;
  let parsed = Cli_spec.parse argv in
  (match parsed with
   | Error error when json ->
       let operation = match List.filter (fun arg -> not (String.starts_with ~prefix:"--" arg)) argv with
         | "artifact" :: action :: _ -> "artifact." ^ action | action :: _ -> action | [] -> "usage" in
       let response = match error with
         | Cli_spec.Unknown_command ->
             Agent_cli.refused ~operation ~known:false "unknown command; serai commands --json lists them"
         | Bad_arguments (command, message) ->
             Agent_cli.refused ~operation ~known:true (Printf.sprintf "%s; usage: %s" message (Cli_spec.synopsis command)) in
       print_endline (Agent_cli.to_json response);
       exit (Agent_cli.exit_code response)
   | Ok ({ command = { path = [ "validate" ] | [ "inspect" ] | [ "artifact"; "plan" ]; _ }; _ }) when json ->
       let args = List.filter (fun arg -> not (String.starts_with ~prefix:"--" arg)) argv in
       let operation, workload = match args with
         | "artifact" :: action :: name :: _ -> "artifact." ^ action, Some name
         | action :: _ -> action, None | [] -> "usage", None in
       Progress.start ~enabled:(List.mem "--progress=jsonl" argv) ~operation ~workload;
       Sys.catch_break true;
       let response = Agent_cli.run ~layout:locate_layout argv in
       print_endline (Agent_cli.to_json response);
       let code = Agent_cli.exit_code response in
       Progress.finish (if code = 0 then Progress.Succeeded else if code = 130 then Progress.Interrupted else Progress.Failed);
       exit code
   | Ok inv when json -> generic_json inv
   | _ -> ());
  let inv = match parsed with
    | Ok inv -> inv
    | Error _ ->
        Progress.start ~enabled:(List.mem "--progress=jsonl" argv) ~operation:"usage" ~workload:None;
        prerr_string (Cli_spec.usage ());
        Progress.finish Progress.Failed;
        exit 1 in
  let operation, workload = operation_of inv in
  Progress.start ~enabled:inv.progress ~operation ~workload;
  (* Ctrl-C would otherwise kill the process outright, skipping
     Dispatcher.with_locks' Fun.protect ~finally and leaving a stale remote
     lock. As Sys.Break it unwinds like any exception, releasing the locks
     on the way out. *)
  Sys.catch_break true;
  let failed message =
    Printf.eprintf "%s\n%!" message;
    Progress.finish Progress.Failed;
    (* 3: a stage and lock were left; nothing may be retried blindly. *)
    exit (if Run_state.retained () = [] then 1 else 3) in
  try
    Run_state.approval := approval_of inv;
    ignore (Proc.live (fun () -> dispatch (lazy (build_env ~assume_yes:inv.yes ())) inv));
    Progress.finish Progress.Succeeded
  with
  | Cli_exit code ->
      Progress.finish (if code = 2 then Progress.Changes_pending else Progress.Failed);
      exit code
  | Run_state.Planned plan ->
      Printf.printf "%s\n" plan.question;
      List.iter (fun (name, value) -> Printf.printf "    %-16s %s\n" name value) plan.facts;
      Printf.printf "plan %s\n%!" (Plan_id.to_string plan.id);
      Progress.finish Progress.Changes_pending;
      exit 2
  | Sys.Break ->
      prerr_endline "interrupted";
      Progress.finish Progress.Interrupted;
      exit 130
  | Fun.Finally_raised _ ->
      (* a second Ctrl-C while with_locks was releasing *)
      prerr_endline "interrupted; a remote lock may remain: serai locks, then serai unlock <host-id|guest>";
      Progress.outcome_unknown ();
      Progress.finish Progress.Interrupted;
      exit 130
  | Failure msg | Plan_id.Stale msg | Agent_cli.Bad_request msg -> failed msg
  | e -> failed ("error: " ^ Printexc.to_string e)
