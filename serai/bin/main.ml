open Serai

let usage_text =
  "usage:\n\
  \  serai apps\n\
  \  serai guests\n\
  \  serai inspect --json   (declared topology, not live state)\n\
  \  serai validate --json\n\
  \  serai artifact plan <app|guest> [--revision <rev>] --json   (design preview only)\n\
  \  serai validate [--out <dir>]   (offline: no ssh, lock or jj)\n\
  \  serai render-logging-targets   (offline: the jails central logging forwards from)\n\
  \  serai artifact plan <app|guest> [--revision <rev>]   (offline design preview)\n\
  \  serai artifact source-stage <app|guest> --revision <rev> --out <dir>   (local committed source only)\n\
  \  serai artifact build <app> --revision <rev> --ip <builder-ip> --base <txz> --sha256 <base-digest> --store <private-dir> [--reuse <identity>] [--yes]   (Phoenix build/store or explicit local reuse)\n\
  \  serai artifact build <app> --ip <builder-ip> --base <txz> --sha256 <base-digest> --store <private-dir> [--reuse <identity>] [--yes]   (package or pinned executable)\n\
  \  serai artifact build <ocaml-app> --revision <rev> --ip <builder-ip> --base <txz> --sha256 <digest> --store <dir> --opam-repository <checkout> --opam-revision <rev> [--reuse <identity>]\n\
  \  serai artifact build <guest> --revision <rev> --opam-repository <checkout> --opam-revision <rev> --compiler <ocaml-variants.version> --store <dir> [--reuse <identity>]\n\
  \  serai artifact install <app> --identity <identity> --archive <tar> --sha256 <digest>   (prepare only)\n\
  \  serai artifact upgrade <app> --identity <identity> --store <private-dir> [--yes]\n\
  \  serai artifact rollback <app> --identity <previous-identity> --store <private-dir> [--yes]\n\
  \  serai artifact convert <app> --identity <identity> --store <private-dir> [--yes]   (legacy executables, byte-equivalent only)\n\
  \  serai new <app> --kind phoenix|ocaml --repo <checkout> [--hostname <fqdn>] [--json]   (declaration only; no host)\n\
  \  serai bootstrap <app>\n\
  \  serai deploy <app|guest>   (a guest: build, install, then provision)\n\
  \  serai provision <guest>\n\
  \  serai build <guest>\n\
  \  serai check <app>\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] [--yes]   (create a new app's jail, or build or reuse, deploy, edge, check)\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] --plan [--json]   (what up would do; changes no host)\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] [--yes] --expect-plan <id>   (only the plan --plan named)\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] --yes --json --expect-plan <id>   (each step's outcome as JSON)\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] --rehearse --ip <addr>   (the same into <app>test; no edge)\n\
  \  serai edge [--plan] [--yes]   (--plan exits 2 when changes are pending)\n\
  \  serai caddy-install [--yes]   (build if needed, unit, install, reload)\n\
  \  serai unlock <host-id|guest>\n\
  \  serai jail-test <app> --ip <addr> [--yes]   (generated script on jail <app>test)\n\
  \  serai jail-test <app> --destroy [--yes]\n\
  \  serai rollout <app> [--edge] [--yes]\n\
  \  serai update [--plan] [--json]   (deploy what CI marked, if signed and newer; settings in ~/.config/serai/update.sexp)\n\
  \  serai idp [--yes] [--expect-plan <id>]   (Pocket ID's users, groups, clients and APIs to match idp.sexp; key in SERAI_IDP_API_KEY)\n\
  \  serai idp --yes --json --expect-plan <id>   (apply only the approved plan, as JSON)\n\
  \  serai idp --plan [--json]   (what idp would change; exits 2 when changes are pending)\n\
  \  serai idp --export [--url <url>]   (the live resources as idp.sexp; without --url, idp.sexp's url)\n\
  \  serai update-version <app> [version]\n\
  \  serai run <app> <pipeline>\n\
  \  Add --progress=jsonl to stream phase/outcome events on stderr.\n"

exception Cli_exit of int

let usage_and_exit () =
  prerr_string usage_text;
  raise (Cli_exit 1)

let getenv_default name default =
  match Sys.getenv_opt name with Some v -> v | None -> default

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
  | Error message -> failwith message

let load_declaration layout =
  match Declaration.load ~layout with
  | Ok declaration -> declaration
  | Error error -> failwith (Declaration.error_message error)

let env_of_layout ~assume_yes layout : Dispatcher.env =
  let declaration = load_declaration layout in
  List.iter (fun key -> match Sys.getenv_opt key with
    | Some value when value <> "" -> failwith (key ^ ": configure hosts in serai.sexp instead")
    | _ -> ()) ["COMPUTE_TARGET"; "EDGE_TARGET"];
  let topology = match declaration.topology with Some value -> value | None -> failwith "missing topology" in
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
            failwith (question ^ ": needs confirmation but stdin is not a terminal; re-run with --yes")
          else begin
            Printf.printf "%s [y/N] %!" question;
            match In_channel.input_line stdin with
            | Some answer -> List.mem (String.lowercase_ascii (String.trim answer)) [ "y"; "yes" ]
            | None -> false
          end);
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
  | Error error -> failwith (Rendered_output.error_message error)

(* Runs without build_env: validate needs no jj, operator, lock token or
   network, only the declaration, the shell configs that repeat it, the
   pipelines and the Caddy templates. *)
let validate ~out =
  Progress.phase "validate";
  let layout = locate_layout () in
  let declaration = load_declaration layout in
  ignore (Logging_policy.load ~layout ~apps:declaration.apps);
  ignore (Pipeline.load (Layout.pipelines layout));
  (match Idp_declaration.load ~layout with Ok _ -> () | Error message -> failwith message);
  (match Config_drift.check declaration with
   | [] -> ()
   | drift -> failwith (String.concat "\n" (List.map Config_drift.message drift)));
  match Validation.render_all declaration with
  | Error msg -> failwith msg
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
    | None, None -> Error ("unknown workload: " ^ name)
    | Some _, Some _ -> Error ("ambiguous workload: " ^ name)
  in
  match plan with
  | Ok plan -> print_endline (Artifact_plan.render plan)
  | Error message -> failwith message

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
         | _ -> failwith (name ^ ": source staging requires a source-built workload"))
    | None, Some guest -> guest.source_checkout
    | None, None -> failwith ("unknown workload: " ^ name)
    | Some _, Some _ -> failwith ("ambiguous workload: " ^ name)
  in
  let checkout = Layout.config_path layout checkout in
  match Source_snapshot.stage ~jj_bin:(getenv_default "JJ_BIN" "jj") ~checkout ~revision ~out with
  | Ok commit -> Printf.printf "source commit: %s\nstaged at: %s\n%!" commit out
  | Error message -> failwith message

(* Mirrors and base archives are reproducible downloads; the store holds
   verified artifacts worth keeping. Both are private to this user. *)
let up_dirs () =
  let home = Sys.getenv "HOME" in
  let xdg name fallback = match Sys.getenv_opt name with
    | Some dir when dir <> "" -> dir | _ -> Filename.concat home fallback in
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

let new_kind = function
  | "phoenix" -> Dispatcher.New_phoenix
  | "ocaml" -> Dispatcher.New_ocaml
  | kind -> failwith ("new: --kind is phoenix or ocaml, not " ^ kind)

let new_app ?hostname env app ~kind ~repo =
  Dispatcher.new_app env app ~kind:(new_kind kind) ~repo ~hostname

let print_new (plan : App_scaffold.t) app =
  Printf.printf "declared %s at %s, http port %d, https://%s\n" app plan.ip plan.port plan.hostname;
  List.iter (fun (f : App_scaffold.file) -> Printf.printf "  wrote  %s\n" f.path) plan.files;
  Printf.printf "  placed and proxied in serai.sexp\n\
                 next: review and commit the declaration, then serai up %s --revision <rev>\n%!" app

(* The commands that act, answered in the agent envelope. *)
let new_json (plan : App_scaffold.t) app =
  Agent_cli.(Object [ "app", Text app; "ip", Text plan.ip; "port", Int plan.port;
    "hostname", Text plan.hostname;
    "files", Array (List.map (fun (f : App_scaffold.file) -> Text f.path) plan.files @ [ Text Layout.Relative.topology ]);
    "host_inspected", Bool false ])

let up_plan_json (plan : Dispatcher.up_plan) =
  Agent_cli.(Object [ "app", Text plan.app; "host", Text plan.host; "source", Text plan.source;
    "commit", Text plan.commit; "local_source", Bool plan.local;
    "jail", (match plan.jail with
      | Dispatcher.Jail_ready -> Object [ "action", Text "none" ]
      | Jail_create -> Object [ "action", Text "create" ]
      | Jail_needs_env message -> Object [ "action", Text "refused"; "message", Text message ]);
    "release", (match plan.release with
      | Dispatcher.Reuse identity -> Object [ "action", Text "reuse"; "identity", Text identity ]
      | Build { ip; base_sha256 } ->
          Object [ "action", Text "build"; "builder_ip", Text ip; "base_sha256", Text base_sha256 ]);
    "public_url", Text plan.public_url; "plan_id", Text (Plan_id.to_string (Dispatcher.up_plan_id plan));
    "host_inspected", Bool true; "applied", Bool false ])

let step_status (status : Dispatcher.step_status) =
  Agent_cli.(match status with
    | Done -> [ "status", Text "done" ]
    | Skipped -> [ "status", Text "skipped" ]
    | Not_run -> [ "status", Text "not_run" ]
    | Failed message -> [ "status", Text "failed"; "message", Text message ])

(* What the operator or agent does after a failed step. Nothing is undone
   automatically: a release may already have migrated. *)
let next_after app ~revision (step : Dispatcher.up_step) =
  match step with
  | Jail -> Printf.sprintf "inspect jail %s on the compute host before running serai up again" app
  | Build -> Printf.sprintf "fix the build, then serai up %s --revision %s" app revision
  | Release -> Printf.sprintf "serai check %s; the message says whether the previous release is still active" app
  | Edge -> "serai edge --plan"
  | Check -> Printf.sprintf "serai check %s" app

let up_json app ~revision ((plan : Dispatcher.up_plan), (outcome : Dispatcher.up_outcome)) =
  let open Agent_cli in
  let data result next =
    Object ([ "app", Text app; "commit", Text plan.commit; "local_source", Bool plan.local ] @ result
      @ [ "steps", Array (List.map (fun (step, status) ->
            Object (("name", Text (Dispatcher.step_name step)) :: step_status status)) outcome.steps);
          "next", (match next with Some next -> Text next | None -> Null) ]) in
  match outcome.result with
  | Deployed identity -> Ok (data [ "outcome", Text "deployed"; "identity", Text identity ] None)
  | Stopped_for_env message -> Ok (data [ "outcome", Text "stopped_for_operator" ] (Some message))
  | Step_failed (step, message) ->
      Error (data [ "outcome", Text "failed" ] (Some (next_after app ~revision step)), message)

(* serai update: its settings and state live with the user running it, the
   configuration comes from a verified commit, not the working directory. *)
let update_paths () =
  let home = Sys.getenv "HOME" in
  let xdg name fallback = match Sys.getenv_opt name with
    | Some dir when dir <> "" -> dir | _ -> Filename.concat home fallback in
  let settings = Filename.concat (Filename.concat (xdg "XDG_CONFIG_HOME" ".config") "serai") "update.sexp" in
  let state_dir = Filename.concat (Filename.concat (xdg "XDG_STATE_HOME" ".local/state") "serai") "update" in
  let cache, store = up_dirs () in
  settings, { Update.state_dir; cache; store; engine = installed_engine () }

let update_settings path =
  match In_channel.with_open_bin path In_channel.input_all with
  | text -> (match Update.config_of_string text with Ok config -> config | Error message -> failwith message)
  | exception Sys_error message -> failwith ("update: " ^ message)

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
  | Update.Not_attempted why -> Agent_cli.(Object [ "outcome", Text "not_attempted"; "message", Text why ])
  | Reverted -> Agent_cli.(Object [ "outcome", Text "reverted" ])
  | Revert_failed message -> Agent_cli.(Object [ "outcome", Text "failed"; "message", Text message ])

let update_outcome_json (name, outcome) =
  let open Agent_cli in
  let fields = match outcome with
    | Update.Not_enrolled -> [ "outcome", Text "not_enrolled" ]
    | Built_on_controller -> [ "outcome", Text "built_on_controller" ]
    | Already_handled commit -> [ "outcome", Text "already_handled"; "commit", Text commit ]
    | Current commit -> [ "outcome", Text "current"; "commit", Text commit ]
    | Would_deploy commit -> [ "outcome", Text "would_deploy"; "commit", Text commit ]
    | Deployed { commit; identity } ->
        [ "outcome", Text "deployed"; "commit", Text commit; "identity", Text identity ]
    | Refused { commit; refusal } ->
        [ "outcome", Text "refused"; "commit", Text commit;
          "message", Text (Update_decision.refusal_message refusal) ]
    | Failed { commit; step; message; revert } ->
        [ "outcome", Text "failed"; "commit", Text commit; "step", Text (Dispatcher.step_name step);
          "message", Text message; "revert", revert_json revert ]
    | Not_applied { commit; message } ->
        [ "outcome", Text "not_applied";
          "commit", (match commit with Some commit -> Text commit | None -> Null);
          "message", Text message ] in
  Object (("app", Text name) :: fields)

let update_report_json (report : Update.report) =
  let open Agent_cli in
  [ "configuration", (match report.configuration with
      | Update.Configuration commit -> Object [ "status", Text "verified"; "commit", Text commit ]
      | Configuration_refused { commit; refusal } ->
          Object [ "status", Text "refused"; "commit", Text commit;
                   "message", Text (Update_decision.refusal_message refusal) ]
      | Configuration_unavailable message -> Object [ "status", Text "unavailable"; "message", Text message ]);
    "apps", Array (List.map update_outcome_json report.apps);
    "host_inspected", Bool (match report.configuration with Update.Configuration _ -> true | _ -> false) ]

let update argv =
  let flags = List.filter (fun arg -> arg <> "update") argv in
  if List.exists (fun flag -> not (List.mem flag [ "--plan"; "--json" ])) flags then begin
    prerr_string usage_text;
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
    (* stdout carries exactly the one result: what the run prints goes to stderr. *)
    let saved = Unix.dup Unix.stdout in
    Unix.dup2 Unix.stderr Unix.stdout;
    let response = Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved)
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
                   "reported", Agent_cli.Array (List.map (fun line -> Agent_cli.Text line) run.lines) ]) in
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
  let usage () = prerr_string usage_text; exit 1 in
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
  if json && yes then begin
    (* stdout carries exactly the one result, failures included. *)
    let saved = Unix.dup Unix.stdout in
    Unix.dup2 Unix.stderr Unix.stdout;
    let response = Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved)
      (fun () -> Agent_cli.respond ~operation:"idp.apply" (fun () ->
         let expected = match expect with
           | None -> raise (Agent_cli.Bad_request "serai idp --yes --json requires --expect-plan <id>, the plan_id of the approved serai idp --plan --json")
           | Some text -> (match Plan_id.parse text with Ok id -> id | Error m -> raise (Agent_cli.Bad_request m)) in
         let layout = locate_layout () in
         let declaration = match Idp_declaration.load ~layout with
           | Ok (Some d) -> d | Ok None -> failwith (no_declaration layout) | Error message -> failwith message in
         match fetch_result declaration.url with
         | Error message -> failwith message
         | Ok (session, live) ->
             let t = Idp_plan.plan declaration live in
             Option.iter failwith t.lockout;
             if t.plan_id <> Some expected then raise (Agent_cli.Stale_plan (stale expected t.plan_id));
             let applied = Proc.live (fun () -> Pocket_id.apply ~curl_bin session live t) in
             let open Agent_cli in
             let optional_int = function Some n -> Int n | None -> Null in
             let optional_text = function Some s -> Text s | None -> Null in
             let failed = match applied.failed with
               | None -> Null
               | Some (action, (error : Pocket_id.error)) ->
                   Object [ ("action", Idp_plan.action_to_json action); ("request", Text error.request);
                            ("status", optional_int error.status); ("code", optional_text error.code);
                            ("message", Text error.message) ] in
             let data = Object [
                 ("completed", Array (List.map Idp_plan.action_to_json applied.completed));
                 ("failed", failed);
                 ("secrets_needed", Array (List.map (fun c -> Text c) t.secrets_needed)) ] in
             match applied.failed with
             | None -> Ok data
             | Some (_, error) -> Error (data, Pocket_id.error_message error))) in
    print_endline (Agent_cli.to_json response);
    exit (Agent_cli.exit_code response)
  end;
  if json then begin
    (* stdout carries exactly the one result, failures included. *)
    let saved = Unix.dup Unix.stdout in
    Unix.dup2 Unix.stderr Unix.stdout;
    let pending = ref false in
    let response = Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved)
      (fun () -> Agent_cli.respond ~operation:"idp.plan" (fun () ->
         let layout = locate_layout () in
         let declaration = match Idp_declaration.load ~layout with
           | Ok (Some d) -> d | Ok None -> failwith (no_declaration layout) | Error message -> failwith message in
         match fetch_result declaration.url with
         | Error message -> failwith message
         | Ok (_, live) ->
             let t = Idp_plan.plan declaration live in
             Option.iter failwith t.lockout;
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
        && (Printf.printf "Apply %d change%s to %s? [y/N] %!" count (if count = 1 then "" else "s") declaration.url;
            match In_channel.input_line stdin with
            | Some answer -> List.mem (String.lowercase_ascii (String.trim answer)) [ "y"; "yes" ]
            | None -> false)) in
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
  let run ?(assume_yes = false) operation workload f =
    Progress.start ~enabled:(List.mem "--progress=jsonl" argv) ~operation ~workload:(Some workload);
    Sys.catch_break true;
    (* stdout carries exactly the one result: what the run prints, its
       subprocesses included, goes to stderr. *)
    let saved = Unix.dup Unix.stdout in
    Unix.dup2 Unix.stderr Unix.stdout;
    let response = Fun.protect ~finally:(fun () -> flush stdout; Unix.dup2 saved Unix.stdout; Unix.close saved)
      (fun () -> Agent_cli.respond ~operation (fun () ->
         Proc.live (fun () -> f (fst (build_env ~assume_yes ()))))) in
    print_endline (Agent_cli.to_json response);
    let code = Agent_cli.exit_code response in
    Progress.finish (if code = 0 then Progress.Succeeded else if code = 130 then Progress.Interrupted else Progress.Failed);
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
  | [ "up"; app; "--revision"; revision; "--plan" ] ->
      run "up.plan" app (fun env -> Ok (up_plan_json (up_plan env app ~revision)))
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--plan" ] ->
      run "up.plan" app (fun env -> Ok (up_plan_json (up_plan ~local_source:checkout env app ~revision)))
  (* Applies only with --yes, there being no terminal to ask in, and only
     the plan the operator approved. *)
  | [ "up"; app; "--revision"; revision; "--yes"; "--expect-plan"; id ] ->
      let expect_plan = checked "up" id in
      run ~assume_yes:true "up" app (fun env -> up_json app ~revision (up_run ~expect_plan env app ~revision))
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--yes"; "--expect-plan"; id ] ->
      let expect_plan = checked "up" id in
      run ~assume_yes:true "up" app (fun env ->
        up_json app ~revision (up_run ~local_source:checkout ~expect_plan env app ~revision))
  | [ "up"; _; "--revision"; _; "--yes" ] | [ "up"; _; "--revision"; _; "--source"; _; "--yes" ] ->
      refuse "up" "serai up --yes --json requires --expect-plan <id>, the plan_id of the approved serai up --plan --json"

  | _ -> ()

let dispatch (env, registry) argv =
  match argv with
  | [ "apps" ] -> List.iter print_endline (Dispatcher.list_apps env)
  | [ "guests" ] -> List.iter print_endline (Dispatcher.list_guests env)
  | [ "bootstrap"; app ] -> Dispatcher.bootstrap env app
  | [ "deploy"; name ] -> Dispatcher.deploy_app_or_guest env name
  | "artifact" :: "build" :: guest :: "--revision" :: revision ::
      "--opam-repository" :: checkout :: "--opam-revision" :: repository_revision ::
      "--compiler" :: compiler :: "--store" :: store :: tail ->
      let reuse = match tail with [] -> None | ["--reuse"; identity] -> Some identity
        | _ -> usage_and_exit () in
      let identity = Dispatcher.artifact_build_guest_store ?reuse env guest ~revision
        ~opam_repository:(checkout, repository_revision) ~compiler ~store in
      Printf.printf "%s verified artifact: %s\n%!"
        (if reuse = None then "stored" else "reused") identity
  | "artifact" :: "build" :: app :: "--revision" :: revision :: "--ip" :: ip ::
      "--base" :: base_archive :: "--sha256" :: base_sha256 :: "--store" :: store ::
      "--opam-repository" :: checkout :: "--opam-revision" :: repository_revision :: tail ->
      let reuse = match tail with [] -> None | ["--reuse"; identity] -> Some identity
        | _ -> usage_and_exit () in
      let identity = Dispatcher.artifact_build_store ?reuse
        ~opam_repository:(checkout, repository_revision) env app ~revision ~ip
        ~base_archive ~base_sha256 ~store in
      Printf.printf "%s verified artifact: %s\n%!"
        (if reuse = None then "stored" else "reused") identity
  | [ "artifact"; "build"; app; "--revision"; revision; "--ip"; ip;
      "--base"; base_archive; "--sha256"; base_sha256; "--store"; store ] ->
      let identity = Dispatcher.artifact_build_store env app ~revision ~ip
        ~base_archive ~base_sha256 ~store in
      Printf.printf "stored verified artifact: %s\n%!" identity
  | [ "artifact"; "build"; app; "--revision"; revision; "--ip"; ip;
      "--base"; base_archive; "--sha256"; base_sha256; "--store"; store; "--reuse"; reuse ] ->
      let identity = Dispatcher.artifact_build_store ~reuse env app ~revision ~ip
        ~base_archive ~base_sha256 ~store in
      Printf.printf "reused verified artifact: %s\n%!" identity
  | [ "artifact"; "build"; app; "--ip"; ip; "--base"; base_archive;
      "--sha256"; base_sha256; "--store"; store ] ->
      let identity = Dispatcher.artifact_build_executable_store env app ~ip
        ~base_archive ~base_sha256 ~store in
      Printf.printf "stored verified artifact: %s\n%!" identity
  | [ "artifact"; "build"; app; "--ip"; ip; "--base"; base_archive;
      "--sha256"; base_sha256; "--store"; store; "--reuse"; reuse ] ->
      let identity = Dispatcher.artifact_build_executable_store ~reuse env app ~ip
        ~base_archive ~base_sha256 ~store in
      Printf.printf "reused verified artifact: %s\n%!" identity
  | [ "artifact"; "install"; app; "--identity"; identity; "--archive"; archive; "--sha256"; sha256 ] ->
      Dispatcher.artifact_install env app ~identity ~archive ~sha256
  | [ "artifact"; ("upgrade" | "rollback" | "convert" as mode); app;
      "--identity"; identity; "--store"; store ] ->
      if List.mem app (Dispatcher.list_guests env) then
        Dispatcher.artifact_apply_guest ~convert:(mode = "convert") env app ~store ~identity ~rollback:(mode = "rollback")
      else Dispatcher.artifact_apply ~convert:(mode = "convert") env app ~store ~identity ~rollback:(mode = "rollback")
  | [ "provision"; guest ] -> Dispatcher.provision_guest env guest
  | [ "build"; guest ] -> Dispatcher.build_guest env guest
  | [ "check"; app ] -> Dispatcher.check env app
  | [ "edge" ] -> Dispatcher.edge env
  | [ "new"; app; "--kind"; kind; "--repo"; repo ] -> print_new (new_app env app ~kind ~repo) app
  | [ "new"; app; "--kind"; kind; "--repo"; repo; "--hostname"; hostname ] ->
      print_new (new_app ~hostname env app ~kind ~repo) app
  | [ "up"; app; "--revision"; revision; "--plan" ] -> Dispatcher.print_up_plan (up_plan env app ~revision)
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--plan" ] ->
      Dispatcher.print_up_plan (up_plan ~local_source:checkout env app ~revision)
  | [ "up"; app; "--revision"; revision ] -> up env app ~revision
  | [ "up"; app; "--revision"; revision; "--source"; checkout ] ->
      up ~local_source:checkout env app ~revision
  | [ "up"; app; "--revision"; revision; "--expect-plan"; id ] ->
      up ~expect_plan:(expected_plan id) env app ~revision
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--expect-plan"; id ] ->
      up ~local_source:checkout ~expect_plan:(expected_plan id) env app ~revision
  | [ "up"; app; "--revision"; revision; "--rehearse"; "--ip"; ip ] ->
      up ~target:(Dispatcher.Rehearse ip) env app ~revision
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--rehearse"; "--ip"; ip ] ->
      up ~local_source:checkout ~target:(Dispatcher.Rehearse ip) env app ~revision
  | [ "edge"; "--plan" ] -> if Dispatcher.plan_edge env then raise (Cli_exit 2)
  | [ "caddy-install" ] -> Dispatcher.caddy_install env
  | [ "unlock"; host ] -> Dispatcher.unlock env host
  | [ "jail-test"; app; "--ip"; ip ] -> Dispatcher.jail_test env app ~ip
  | [ "jail-test"; app; "--destroy" ] -> Dispatcher.jail_test_destroy env app
  | [ "rollout"; app ] -> Pipeline.run env registry app "rollout"
  | [ "rollout"; app; "--edge" ] -> Pipeline.run env registry app "rollout-edge"
  | [ "update-version"; app ] -> Dispatcher.update_version env app ""
  | [ "update-version"; app; version ] ->
      Dispatcher.update_version env app version
  | [ "run"; app; pipeline ] -> Pipeline.run env registry app pipeline
  | _ -> usage_and_exit ()

let () =
  let argv = List.tl (Array.to_list Sys.argv) in
  (match argv with "update" :: _ -> update argv | "idp" :: _ -> idp argv | _ -> ());
  if List.mem "--json" argv then acting_json argv;
  if List.mem "--json" argv then begin
    let args = List.filter (fun arg -> not (String.starts_with ~prefix:"--" arg)) argv in
    let operation, workload = match args with
      | "artifact" :: action :: name :: _ -> "artifact." ^ action, Some name
      | action :: _ -> action, None | [] -> "usage", None in
    Progress.start ~enabled:(List.mem "--progress=jsonl" argv) ~operation ~workload;
    Sys.catch_break true;
    let response = Agent_cli.run
      ~layout:locate_layout argv in
    print_endline (Agent_cli.to_json response);
    let code = Agent_cli.exit_code response in
    Progress.finish (if code = 0 then Progress.Succeeded else if code = 130 then Progress.Interrupted else Progress.Failed);
    exit code
  end;
  let assume_yes = List.mem "--yes" argv in
  let progress = List.mem "--progress=jsonl" argv in
  let argv = List.filter (fun arg -> arg <> "--yes" && arg <> "--progress=jsonl") argv in
  let operation, workload = match argv with
    | "artifact" :: action :: name :: _ -> "artifact." ^ action, Some name
    | ("bootstrap" | "deploy" | "provision" | "build" | "check" | "jail-test"
      | "rollout" | "update-version" | "run" | "up" | "new" as action) :: name :: _ -> action, Some name
    | action :: _ -> action, None
    | [] -> "usage", None in
  Progress.start ~enabled:progress ~operation ~workload;
  (* Ctrl-C would otherwise kill the process outright, skipping
     Dispatcher.with_locks' Fun.protect ~finally and leaving a stale remote
     lock. As Sys.Break it unwinds like any exception, releasing the locks
     on the way out. *)
  Sys.catch_break true;
  try
    if argv = [] then usage_and_exit ();
    (match argv with
    | [ "render-logging-targets" ] ->
        let layout = locate_layout () in
        Logging_policy.load ~layout ~apps:(load_declaration layout).apps
        |> Logging_policy.render_targets |> print_string
    | [ "validate" ] -> validate ~out:None
    | [ "validate"; "--out"; dir ] -> validate ~out:(Some dir)
    | "validate" :: _ -> usage_and_exit ()
    | [ "artifact"; "plan"; name ] -> artifact_plan name
    | [ "artifact"; "plan"; name; "--revision"; revision ] -> artifact_plan ~revision name
    | [ "artifact"; "source-stage"; name; "--revision"; revision; "--out"; out ] ->
        artifact_source_stage name ~revision ~out
    | "artifact" :: "build" :: _ ->
        Proc.live (fun () -> dispatch (build_env ~assume_yes ()) argv)
    | [ "artifact"; "install"; _; "--identity"; _; "--archive"; _; "--sha256"; _ ] ->
        Proc.live (fun () -> dispatch (build_env ~assume_yes ()) argv)
    | [ "artifact"; ("upgrade" | "rollback" | "convert"); _;
        "--identity"; _; "--store"; _ ] ->
        Proc.live (fun () -> dispatch (build_env ~assume_yes ()) argv)
    | "artifact" :: _ -> usage_and_exit ()
    | _ -> Proc.live (fun () -> dispatch (build_env ~assume_yes ()) argv));
    Progress.finish Progress.Succeeded
  with
  | Cli_exit code ->
      Progress.finish (if code = 2 then Progress.Changes_pending else Progress.Failed);
      exit code
  | Sys.Break ->
      prerr_endline "interrupted";
      Progress.finish Progress.Interrupted;
      exit 130
  | Fun.Finally_raised _ ->
      (* a second Ctrl-C while with_locks was releasing *)
      prerr_endline "interrupted; a remote lock may remain: serai unlock <host-id|guest>";
      Progress.outcome_unknown ();
      Progress.finish Progress.Interrupted;
      exit 130
  | Failure msg | Agent_cli.Stale_plan msg | Agent_cli.Bad_request msg ->
      Printf.eprintf "%s\n%!" msg;
      Progress.finish Progress.Failed;
      exit 1
  | e ->
      Printf.eprintf "error: %s\n%!" (Printexc.to_string e);
      Progress.finish Progress.Failed;
      exit 1
