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
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] --yes --json   (each step's outcome as JSON)\n\
  \  serai up <app> --revision <bookmark|commit> [--source <checkout>] --rehearse --ip <addr>   (the same into <app>test; no edge)\n\
  \  serai edge [--plan] [--yes]   (--plan exits 2 when changes are pending)\n\
  \  serai caddy-install [--yes]   (build if needed, unit, install, reload)\n\
  \  serai unlock <host-id|guest>\n\
  \  serai jail-test <app> --ip <addr> [--yes]   (generated script on jail <app>test)\n\
  \  serai jail-test <app> --destroy [--yes]\n\
  \  serai rollout <app> [--edge] [--yes]\n\
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

let build_env ~assume_yes () : Dispatcher.env * Pipeline.t =
  let layout = locate_layout () in
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
  (env, Pipeline.load (Layout.pipelines layout))

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

let up ?local_source ?target env app ~revision =
  let cache, store = up_dirs () in
  Dispatcher.up ?local_source ?target env app ~revision ~cache ~store

let up_run ?local_source env app ~revision =
  let cache, store = up_dirs () in
  Dispatcher.up_run ?local_source env app ~revision ~cache ~store

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
    "public_url", Text plan.public_url; "host_inspected", Bool true; "applied", Bool false ])

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
  match List.filter (fun arg -> arg <> "--json" && arg <> "--progress=jsonl") argv with
  | [ "new"; app; "--kind"; kind; "--repo"; repo ] ->
      run "new" app (fun env -> Ok (new_json (new_app env app ~kind ~repo) app))
  | [ "new"; app; "--kind"; kind; "--repo"; repo; "--hostname"; hostname ] ->
      run "new" app (fun env -> Ok (new_json (new_app ~hostname env app ~kind ~repo) app))
  | [ "up"; app; "--revision"; revision; "--plan" ] ->
      run "up.plan" app (fun env -> Ok (up_plan_json (up_plan env app ~revision)))
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--plan" ] ->
      run "up.plan" app (fun env -> Ok (up_plan_json (up_plan ~local_source:checkout env app ~revision)))
  (* Applies only with --yes: there is no terminal to ask in. *)
  | [ "up"; app; "--revision"; revision; "--yes" ] ->
      run ~assume_yes:true "up" app (fun env -> up_json app ~revision (up_run env app ~revision))
  | [ "up"; app; "--revision"; revision; "--source"; checkout; "--yes" ] ->
      run ~assume_yes:true "up" app (fun env ->
        up_json app ~revision (up_run ~local_source:checkout env app ~revision))
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
  | Failure msg ->
      Printf.eprintf "%s\n%!" msg;
      Progress.finish Progress.Failed;
      exit 1
  | e ->
      Printf.eprintf "error: %s\n%!" (Printexc.to_string e);
      Progress.finish Progress.Failed;
      exit 1
