(* Dispatcher logic tested in-process, no fake ssh/rsync binaries on $PATH:
   Proc.Mock records every command the dispatcher would have run and hands
   back a scripted exit code, so the same effectful functions that talk to
   real hosts in production run here against nothing but memory. *)

open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

(* Lock, record and revision calls wrap every edge/bootstrap run; the
   sequence tests below are about the real work, so they see calls with
   that bookkeeping filtered out. Lock and record tests read raw calls. *)
let is_bookkeeping (r : Proc.request) =
  let cmd = String.concat " " r.args in
  r.prog = "jj"
  || contains ~needle:"locks/infra" cmd
  || contains ~needle:"subtree='locks'" cmd
  || contains ~needle:"/var/lib/infra/applied" cmd

let without_bookkeeping calls = List.filter (fun r -> not (is_bookkeeping r)) calls

let is_acquire (r : Proc.request) = contains ~needle:{|mkdir "$lock"|} (String.concat " " r.args)

let is_existing_probe (r : Proc.request) = contains ~needle:"jail-test-existing" (String.concat " " r.args)

(* jj answers with a revision; each lock acquire with "no record yet";
   jail-test's existing-jail probe with "no such jail" *)
let fixture_outputs (r : Proc.request) =
  if r.prog = "jj" then "c0ffee00c0ffee00 changeid1 published\n"
  else if is_acquire r then Remote_lock.no_record_marker ^ "\n"
  else if is_existing_probe r then "jail-test-existing: absent\n"
  else ""

let make_app ?(tailnet_ports = []) ~name ~ip ~hooks () : App_config.t =
  let endpoint = Test_declaration.endpoint ~name ~ip ~hostname:(name ^ ".example.org")
      ~tailnet_ports:(List.map (fun port -> Network_endpoint.{ port_name = "http"; port }) tailnet_ports)
      ~operator_ports:[] in
  Test_declaration.app ~endpoint ~hooks

let config : App_config.t list =
  [
    make_app ~name:"drill" ~ip:"10.40.0.2" ~hooks:[ Bootstrap; Deploy; Check ]
      ~tailnet_ports:[ 4000 ] ();
    make_app ~name:"garage" ~ip:"10.40.0.4" ~hooks:[ Bootstrap; Check ] ();
    make_app ~name:"board" ~ip:"10.40.0.3" ~hooks:[ Bootstrap; Deploy; Check ] ();
    make_app ~name:"meals" ~ip:"10.40.0.5" ~hooks:[ Bootstrap; Deploy; Check ] ();
    make_app ~name:"idp" ~ip:"10.40.0.6"
      ~hooks:[ Bootstrap; Check; Update_version ] ();
  ]

(* The fixture template tree (fixtures/edge_root/edge/caddy) references
   __DEMO_*__, so edge tests render against a single "demo" endpoint. *)
let fixture_endpoint : Network_endpoint.t =
  Test_declaration.endpoint ~name:"demo" ~ip:"10.0.0.7" ~hostname:"demo.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4000 }; { port_name = "video"; port = 4002 } ]
    ~operator_ports:[ { port_name = "ssh"; port = 22 } ]

let make_env ?(endpoints = [ fixture_endpoint ]) () : Dispatcher.env =
  {
    layout = Layout.v ~engine:"/repo" ~config:"fixtures/edge_root";
    topology = None;
    compute_target = "compute-test";
    edge_target = "edge-test";
    remote_stage = "/tmp/serai-stage-test";
    ssh_bin = "ssh";
    rsync_bin = "rsync";
    curl_bin = "curl";
    config;
    endpoints = Test_declaration.endpoints endpoints;
    edge = Test_declaration.edge "example.org";
    edge_ts_ip = None;
    edge_peer_match = None;
    caddy_force_build = false;
    confirm = (fun _ -> true);
    operator = "tester@test";
    lock_token = "token-1";
    jj_bin = "jj";
    now_utc = (fun () -> "2026-09-24T22:41:03Z");
    guests = [];
    ops_control_path = "/tmp/ops-ssh-%C";
    ssh_multiplex = true;
    source_checkout_override = None;
  }

(* Runs [f] against a fresh mock; returns Ok/Error like the dispatcher's own
   failwith-on-rejection convention, plus the commands that were recorded. *)
let run f =
  let mock = Proc.Mock.create ~outputs:fixture_outputs () in
  let result = try Ok (Proc.Mock.run mock f) with Failure msg -> Error msg in
  (result, without_bookkeeping (Proc.Mock.calls mock))

let progs calls = List.map (fun (r : Proc.request) -> r.prog) calls

(* apps: sorted, total, and reads nothing but the config *)
let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.list_apps env) in
  check "apps: no commands run to list apps" (calls = []);
  check "apps: sorted, all five present"
    (result = Ok [ "board"; "drill"; "garage"; "idp"; "meals" ])

(* bootstrap: secure the stage, rsync _lib + the app dir, stage the rendered
   jail script, then run the remote bootstrap hook via doas *)
let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.bootstrap env "drill") in
  check "bootstrap: succeeds" (result = Ok ());
  check "bootstrap: ssh, rsync, rsync, ssh in order" (progs calls = [ "ssh"; "rsync"; "rsync"; "ssh" ]);
  match calls with
  | [ stage_ssh; rsync_call; _jail_rsync; hook_ssh ] ->
      check "bootstrap: stage guard targets the compute, and runs the safety script"
        (match stage_ssh.args with
        | [ target; script ] ->
            target = "compute-test" && contains ~needle:"unsafe remote staging path" script
        | _ -> false);
      let rsync_args = String.concat " " rsync_call.args in
      check "bootstrap: rsync ships _lib and the app dir to the staged path"
        (contains ~needle:"_lib" rsync_args
        && contains ~needle:"edge_root/apps/drill" rsync_args
        && contains ~needle:"compute-test:/tmp/serai-stage-test/compute/apps/" rsync_args);
      check "bootstrap: local dotenv files are never staged"
        (List.mem ".env" rsync_call.args && List.mem ".env.*" rsync_call.args);
      check "bootstrap: runs the staged jail script via doas"
        (match hook_ssh.args with
        | [ target; cmd ] ->
            target = "compute-test"
            && contains
                 ~needle:"doas sh /tmp/serai-stage-test/compute/apps/drill/jail"
                 cmd
        | _ -> false)
  | _ -> check "bootstrap: expected exactly 4 commands" false

(* deploy: validated against the sexp config before anything runs *)
let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.deploy env "garage") in
  check "deploy: rejected for an app without the deploy hook"
    (result = Error "deploy is not supported for this app");
  check "deploy: no process spawned for a rejected app" (calls = [])

let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.deploy env "drill") in
  check "deploy: succeeds for an app with the deploy hook" (result = Ok ());
  match calls with
  | [ call ] ->
      check "deploy: invokes the app-owned deploy hook"
        (contains ~needle:"edge_root/apps/drill/deploy" call.prog);
      check "deploy: passes COMPUTE_TARGET as the sole argument" (call.args = [ "compute-test" ]);
      check "deploy: extra env carries COMPUTE_TARGET, CURL_BIN and the engine's _lib"
        (call.extra_env
         = [ ("COMPUTE_TARGET", "compute-test"); ("CURL_BIN", "curl"); ("SERAI_LIB", "/repo/compute/apps/_lib") ])
  | _ -> check "deploy: expected exactly 1 command" false

(* check: no positional args, but three env vars threaded through *)
let () =
  let env = make_env () in
  let archive = Filename.temp_file "infra-release" ".tar" in
  Fun.protect
    ~finally:(fun () -> Sys.remove archive)
    (fun () ->
      let sha256 = String.make 64 'a' in
      let result, calls =
        run (fun () -> Dispatcher.artifact_install env "drill"
          ~identity:"abc123-recipe" ~archive ~sha256)
      in
      check "artifact install: accepts a Phoenix archive" (result = Ok ());
      check "artifact install: guards stage, transfers archive and installer, then prepares release"
        (progs calls = [ "ssh"; "rsync"; "rsync"; "ssh" ]);
      check "artifact install: remote command does not activate the release"
        (match List.rev calls with
        | last :: _ ->
            let command = String.concat " " last.args in
            contains ~needle:"doas sh" command
            && contains ~needle:"artifact_install.sh" command
            && not (contains ~needle:"service" command)
        | [] -> false);
      let result, calls =
        run (fun () -> Dispatcher.artifact_install env "drill"
          ~identity:"../other" ~archive ~sha256)
      in
      check "artifact install: path escape is rejected before SSH" (Result.is_error result && calls = []);
      let logs = App_config.load
        (Filename.concat (Layout.app_dir (Repo_root.example ()) "logs") "app.sexp") in
      let env = { env with config = [ logs ] } in
      let result, calls =
        run (fun () -> Dispatcher.artifact_install env "logs"
          ~identity:"abc123" ~archive ~sha256)
      in
      check "artifact install: non-Phoenix strategy is rejected before SSH"
        (Result.is_error result && calls = []))

(* check: _lib/check.sh's check_app, fed from the declaration and the targets *)
let () =
  let env = make_env () in
  let _, calls = run (fun () -> Dispatcher.check env "drill") in
  match calls with
  | [ call ] ->
      check "check: runs the shared check_app"
        (call.prog = "sh" && call.args = [ "-c"; {|set -eu; . "$1"; check_app|}; "sh"; "/repo/compute/apps/_lib/check.sh" ]);
      check "check: extra env carries the declared check inputs, then the targets"
        (call.extra_env
        = [ ("JAIL", "drill"); ("JAIL_IP", "10.40.0.2"); ("PORT", "4000");
            ("PUBLIC_HOST", "drill.example.org"); ("SERVICE", "example"); ("CHECK_PATH", "/");
            ("COMPUTE_TARGET", "compute-test"); ("EDGE_TARGET", "edge-test"); ("CURL_BIN", "curl") ])
  | _ -> check "check: expected exactly 1 command" false

(* update-version: only idp supports it in this config *)
let () =
  let env = make_env () in
  let result, _ = run (fun () -> Dispatcher.update_version env "drill" "1.2.3") in
  check "update-version: rejected for an app without the hook"
    (result = Error "update-version is not supported for this app")

let () =
  let env = make_env () in
  let _, calls = run (fun () -> Dispatcher.update_version env "idp" "1.2.3") in
  match calls with
  | [ call ] -> check "update-version: version is passed positionally" (call.args = [ "1.2.3" ])
  | _ -> check "update-version: expected exactly 1 command" false

(* rollout itself moved to pipelines.sexp / lib/pipeline.ml -- see
   test_pipeline.ml for that coverage. *)

(* app-name and stage validation happen before any command is spawned *)
let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.bootstrap env "does-not-exist") in
  check "bootstrap: rejects an unknown app" (result = Error "unknown app");
  check "bootstrap: no commands run for an unknown app" (calls = [])

let () =
  let env = make_env () in
  let result, calls = run (fun () -> Dispatcher.deploy env "Drill") in
  check "deploy: rejects uppercase app names before spawning anything"
    (result = Error "invalid app name" && calls = [])

let () =
  let env = { (make_env ()) with remote_stage = "/etc/passwd" } in
  let result, calls = run (fun () -> Dispatcher.bootstrap env "drill") in
  check "bootstrap: rejects a stage outside /tmp"
    (result = Error "OPS_REMOTE_STAGE must be a dedicated non-root directory beneath /tmp");
  check "bootstrap: rejects the bad stage before staging anything" (calls = [])

(* edge: render everything, stage it, have each script diff live against the
   staged file, then install only what changed, once confirmed -- pf, then
   the ACL before Caddy so a vhost never proxies to a port the policy still
   blocks. *)
let is_diff (r : Proc.request) = contains ~needle:"_DIFF_ONLY=1" (String.concat " " r.args)

(* answers 10 ("changes pending") for the diff commands whose text contains
   one of [pending], 0 for everything else *)
let run_edge ?(pending = []) ?(confirm = fun _ -> true) f =
  let exit_codes (r : Proc.request) =
    let cmd = String.concat " " r.args in
    if is_diff r && List.exists (fun needle -> contains ~needle cmd) pending then 10 else 0
  in
  let mock = Proc.Mock.create ~exit_codes ~outputs:fixture_outputs () in
  let env = { (make_env ()) with confirm } in
  let result = try Ok (Proc.Mock.run mock (fun () -> f env)) with Failure msg -> Error msg in
  (result, without_bookkeeping (Proc.Mock.calls mock))

let staging = [ "ssh"; "rsync"; "ssh"; "rsync"; "rsync"; "rsync" ]
let diffs = [ "ssh"; "ssh"; "ssh" ]

let () =
  let result, calls = run_edge (fun env -> Dispatcher.edge env) in
  check "edge: nothing pending -> stage, three diffs, no install, no prompt"
    (result = Ok () && progs calls = staging @ diffs);
  let args (r : Proc.request) = String.concat " " r.args in
  match List.filteri (fun i _ -> i >= 6) calls with
  | [ pf_diff; acl_diff; caddy_diff ] ->
      check "edge: diffs run in pf, acl, caddy order, each in diff-only mode"
        (contains ~needle:"PF_DIFF_ONLY=1" (args pf_diff)
        && contains ~needle:"PF_SOURCE=/tmp/serai-stage-test/compute/service-rules.conf" (args pf_diff)
        && contains ~needle:"POLICY_DIFF_ONLY=1" (args acl_diff)
        && contains ~needle:"CADDY_DIFF_ONLY=1" (args caddy_diff)
        && contains ~needle:"CADDY_SOURCE=/tmp/serai-stage-test/edge/caddy-rendered" (args caddy_diff))
  | _ -> check "edge: expected three diff commands after staging" false

let () =
  let prompted = ref false in
  let result, calls =
    run_edge ~pending:[ "POLICY" ] ~confirm:(fun _ -> prompted := true; true) (fun env ->
        Dispatcher.edge env)
  in
  let installs = List.filteri (fun i _ -> i >= 9) calls in
  check "edge: only the pending component is installed, after confirmation"
    (result = Ok () && !prompted
    && List.map (fun (r : Proc.request) -> String.concat " " r.args) installs
       = [ "edge-test sudo env POLICY_SOURCE=/tmp/serai-stage-test/edge/acls.hujson bash /tmp/serai-stage-test/edge/01-headscale-policy" ])

let () =
  let result, calls =
    run_edge ~pending:[ "PF"; "POLICY"; "CADDY" ] (fun env -> Dispatcher.edge env)
  in
  let installs = List.filteri (fun i _ -> i >= 9) calls in
  let args (r : Proc.request) = String.concat " " r.args in
  check "edge: all pending -> installs in pf, acl, caddy order, none in diff-only mode"
    (result = Ok ()
    && List.length installs = 3
    && (not (List.exists is_diff installs))
    && contains ~needle:"PF_SOURCE=" (args (List.nth installs 0))
    && contains ~needle:"POLICY_SOURCE=" (args (List.nth installs 1))
    && contains ~needle:"CADDY_SOURCE=" (args (List.nth installs 2)))

(* The exact commands: prefix, target, flags and paths all spelled out, so a
   dropped doas/sudo or a wrong host cannot hide behind a substring match. *)
let () =
  let result, calls =
    run_edge ~pending:[ "PF"; "POLICY"; "CADDY" ] (fun env -> Dispatcher.edge env)
  in
  let commands = List.map (fun (r : Proc.request) -> String.concat " " r.args) calls in
  let stage = "/tmp/serai-stage-test" in
  let pf ~diff =
    Printf.sprintf "compute-test doas env %sPF_SOURCE=%s/compute/service-rules.conf sh %s/compute/01-pf-rules"
      (if diff then "PF_DIFF_ONLY=1 " else "") stage stage
  in
  let acl ~diff =
    Printf.sprintf "edge-test sudo env %sPOLICY_SOURCE=%s/edge/acls.hujson bash %s/edge/01-headscale-policy"
      (if diff then "POLICY_DIFF_ONLY=1 " else "") stage stage
  in
  let caddy ~diff =
    Printf.sprintf "edge-test sudo env %sCADDY_SOURCE=%s/edge/caddy-rendered bash %s/edge/02-caddy"
      (if diff then "CADDY_DIFF_ONLY=1 " else "") stage stage
  in
  check "edge: exact diff commands for pf, acl and caddy"
    (result = Ok ()
    && List.filteri (fun i _ -> i >= 6 && i < 9) commands
       = [ pf ~diff:true; acl ~diff:true; caddy ~diff:true ]);
  check "edge: exact install commands for pf, acl and caddy"
    (List.filteri (fun i _ -> i >= 9) commands
    = [ pf ~diff:false; acl ~diff:false; caddy ~diff:false ])

let () =
  let result, calls =
    run_edge ~pending:[ "CADDY" ] ~confirm:(fun _ -> false) (fun env -> Dispatcher.edge env)
  in
  check "edge: declined -> fails, nothing installed"
    (result = Error "edge: not applied" && List.length calls = 9)

let () =
  let result, calls = run_edge ~pending:[ "PF" ] (fun env -> Dispatcher.plan_edge env) in
  check "plan_edge: reports pending, installs nothing, never prompts"
    (result = Ok true && List.length calls = 9);
  let result, _ = run_edge (fun env -> Dispatcher.plan_edge env) in
  check "plan_edge: nothing pending -> false" (result = Ok false)

let () =
  let mock = Proc.Mock.create ~exit_codes:(fun r -> if is_diff r then 1 else 0) ~outputs:fixture_outputs () in
  let result =
    try Ok (Proc.Mock.run mock (fun () -> Dispatcher.edge (make_env ())))
    with Failure msg -> Error msg
  in
  check "edge: a diff command failing (not 0/10) aborts before any install"
    (match result with Error _ -> List.length (without_bookkeeping (Proc.Mock.calls mock)) = 7 | Ok () -> false)

let () =
  let env = { (make_env ()) with edge_ts_ip = Some "100.64.0.1"; edge_peer_match = Some "^edge$" } in
  let mock = Proc.Mock.create ~exit_codes:(fun r -> if is_diff r then 10 else 0) ~outputs:fixture_outputs () in
  let _ = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.edge env)) with Failure m -> Error m in
  let pf_commands =
    without_bookkeeping (Proc.Mock.calls mock)
    |> List.filter (fun (r : Proc.request) -> contains ~needle:"PF_SOURCE=" (String.concat " " r.args))
  in
  check "edge: EDGE_TS_IP and EDGE_PEER_MATCH forwarded to both the pf diff and the pf install"
    (List.length pf_commands = 2
    && List.for_all
         (fun (r : Proc.request) ->
           let cmd = String.concat " " r.args in
           contains ~needle:"EDGE_TS_IP='100.64.0.1'" cmd && contains ~needle:"EDGE_PEER_MATCH='^edge$'" cmd)
         pf_commands)

let () =
  let env = { (make_env ()) with caddy_force_build = true } in
  let mock = Proc.Mock.create ~exit_codes:(fun r -> if is_diff r then 10 else 0) ~outputs:fixture_outputs () in
  let result = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.edge env)) with Failure m -> Error m in
  let caddy_commands =
    without_bookkeeping (Proc.Mock.calls mock)
    |> List.map (fun (r : Proc.request) -> String.concat " " r.args)
    |> List.filter (fun cmd -> contains ~needle:"CADDY_SOURCE=" cmd)
  in
  check "edge: CADDY_FORCE_BUILD=1 forwarded on the caddy apply only, never the diff"
    (result = Ok ()
    && caddy_commands
       = [
           "edge-test sudo env CADDY_DIFF_ONLY=1 CADDY_SOURCE=/tmp/serai-stage-test/edge/caddy-rendered bash /tmp/serai-stage-test/edge/02-caddy";
           "edge-test sudo env CADDY_FORCE_BUILD=1 CADDY_SOURCE=/tmp/serai-stage-test/edge/caddy-rendered bash /tmp/serai-stage-test/edge/02-caddy";
         ])

let () =
  let no_ports = Test_declaration.endpoint ~name:fixture_endpoint.name ~ip:fixture_endpoint.ip
      ~hostname:fixture_endpoint.hostname ~tailnet_ports:[] ~operator_ports:fixture_endpoint.operator_ports in
  let result, calls = run (fun () -> Dispatcher.edge (make_env ~endpoints:[ no_ports ] ())) in
  check "edge: a render error aborts before any command"
    (calls = [] && match result with Error _ -> true | Ok () -> false)

let () =
  match Dispatcher.render_edge (make_env ()) with
  | Error msg -> check ("render_edge: fixture renders: " ^ msg) false
  | Ok files ->
      check "render_edge: stages pf, acl and the caddy tree"
        (List.map fst files
        = [ "compute/service-rules.conf"; "edge/acls.hujson"; "edge/caddy-rendered/Caddyfile";
            "edge/caddy-rendered/conf.d/10-main.caddy"; "edge/caddy-rendered/conf.d/40-demo.caddy" ])

let acquires calls =
  List.filter_map
    (fun (r : Proc.request) ->
      match r.args with
      | [ target; script ] when contains ~needle:{|mkdir "$lock"|} script -> Some target
      | _ -> None)
    calls

let releases calls =
  List.filter_map
    (fun (r : Proc.request) ->
      match r.args with
      | [ "-o"; "ConnectTimeout=10"; target; script ] when contains ~needle:"is not this run's" script ->
          Some target
      | _ -> None)
    calls

let run_raw ?(exit_codes = fun _ -> 0) ?(outputs = fixture_outputs) f =
  let mock = Proc.Mock.create ~exit_codes ~outputs () in
  let result = try Ok (Proc.Mock.run mock f) with Failure msg -> Error msg in
  (result, Proc.Mock.calls mock)

let () =
  let _, calls = run_raw (fun () -> Dispatcher.edge (make_env ())) in
  check "lock: edge locks compute then edge" (acquires calls = [ "compute-test"; "edge-test" ]);
  check "lock: edge releases edge then compute" (releases calls = [ "edge-test"; "compute-test" ]);
  check "lock: acquired before any staging rsync"
    (match List.find_index (fun (r : Proc.request) -> r.prog = "rsync") calls with
    | None -> false
    | Some first_rsync ->
        List.length (List.filter (fun (r : Proc.request) -> contains ~needle:{|mkdir "$lock"|} (String.concat " " r.args))
          (List.filteri (fun i _ -> i < first_rsync) calls)) = 2)

let () =
  let _, calls = run_raw (fun () -> ignore (Dispatcher.plan_edge (make_env ()))) in
  check "lock: plan takes the same locks" (acquires calls = [ "compute-test"; "edge-test" ])

let () =
  let held (r : Proc.request) =
    match r.args with
    | [ "edge-test"; script ] when contains ~needle:{|mkdir "$lock"|} script -> Remote_lock.held_exit
    | _ -> 0
  in
  let result, calls = run_raw ~exit_codes:held (fun () -> Dispatcher.edge (make_env ())) in
  check "lock: a held edge lock stops the run, naming the host"
    (match result with Error msg -> contains ~needle:"edge is locked" msg | Ok () -> false);
  check "lock: nothing staged when a lock is held"
    (not (List.exists (fun (r : Proc.request) -> r.prog = "rsync") calls));
  check "lock: the compute lock already taken is released" (releases calls = [ "compute-test" ])

let () =
  let stale (r : Proc.request) =
    match r.args with
    | [ "compute-test"; script ] when contains ~needle:{|mkdir "$lock"|} script -> Remote_lock.stale_exit
    | _ -> 0
  in
  let result, _ = run_raw ~exit_codes:stale (fun () -> Dispatcher.edge (make_env ())) in
  check "lock: a stale lock says how to clear it"
    (match result with Error msg -> contains ~needle:"infra unlock compute" msg | Ok () -> false)

let () =
  let rsync_fails (r : Proc.request) = if r.prog = "rsync" then 1 else 0 in
  let result, calls = run_raw ~exit_codes:rsync_fails (fun () -> Dispatcher.edge (make_env ())) in
  check "lock: a failure mid-run still releases both locks"
    (Result.is_error result && releases calls = [ "edge-test"; "compute-test" ])

let () =
  let _, calls = run_raw (fun () -> Dispatcher.bootstrap (make_env ()) "drill") in
  check "lock: bootstrap locks only the compute"
    (acquires calls = [ "compute-test" ] && releases calls = [ "compute-test" ])

let () =
  let result, calls = run_raw (fun () -> Dispatcher.unlock (make_env ()) "edge") in
  check "unlock: runs the unlock script on the named host"
    (result = Ok ()
    && match calls with
       | [ { args = [ "edge-test"; script ]; _ } ] -> contains ~needle:"removing lock held by" script
       | _ -> false);
  let result, calls = run_raw (fun () -> Dispatcher.unlock (make_env ()) "gateway") in
  check "unlock: unknown host rejected before any command"
    (calls = [] && match result with Error _ -> true | Ok () -> false)

let record_writes calls =
  List.filter_map
    (fun (r : Proc.request) ->
      match r.args with
      | [ target; command ] when contains ~needle:"applied.tmp" command -> Some (target, command)
      | _ -> None)
    calls

let pending_on needles (r : Proc.request) =
  let cmd = String.concat " " r.args in
  if contains ~needle:"_DIFF_ONLY=1" cmd && List.exists (fun needle -> contains ~needle cmd) needles
  then 10
  else 0

let () =
  let _, calls = run_raw ~exit_codes:(pending_on [ "POLICY"; "CADDY" ]) (fun () -> Dispatcher.edge (make_env ())) in
  match record_writes calls with
  | [ (target, command) ] ->
      check "record: written once, only to the host that was installed on" (target = "edge-test");
      check "record: via sudo on the edge, with the commit, operator and components"
        (contains ~needle:"sudo sh -c" command
        && contains ~needle:"c0ffee00c0ffee00" command
        && contains ~needle:"tester@test" command
        && contains ~needle:"(components (acl caddy))" command)
  | writes -> check (Printf.sprintf "record: expected one write, got %d" (List.length writes)) false

let () =
  let _, calls = run_raw ~exit_codes:(pending_on [ "PF" ]) (fun () -> Dispatcher.edge (make_env ())) in
  check "record: pf applied -> written to the compute with doas"
    (match record_writes calls with
    | [ ("compute-test", command) ] -> contains ~needle:"doas sh -c" command && contains ~needle:"(components (pf))" command
    | _ -> false)

let () =
  let _, calls = run_raw ~exit_codes:(pending_on [ "PF"; "POLICY"; "CADDY" ]) (fun () -> ignore (Dispatcher.plan_edge (make_env ()))) in
  check "record: plan never writes one" (record_writes calls = [])

let () =
  let _, calls = run_raw (fun () -> Dispatcher.edge (make_env ())) in
  check "record: no changes -> no write" (record_writes calls = []);
  check "record: each host's last record is read by its lock acquire"
    (List.filter_map
       (fun (r : Proc.request) ->
         match r.args with
         | [ target; script ] when is_acquire r && contains ~needle:"cat \"$record\"" script
                                   && contains ~needle:"record='/var/lib/infra/applied'" script ->
             Some target
         | _ -> None)
       calls
    = [ "compute-test"; "edge-test" ])

(* Each ssh connection may cost the operator a hardware-key touch: the
   stage guard, lock and record read share one connection per host, and
   the release is the only other. *)
let lock_connections calls host =
  List.length
    (List.filter
       (fun (r : Proc.request) ->
         let cmd = String.concat " " r.args in
         r.prog = "ssh" && List.mem host r.args
         && (contains ~needle:"locks/infra" cmd || contains ~needle:"subtree='locks'" cmd
            || contains ~needle:"/var/lib/infra/applied" cmd))
       calls)

let () =
  let result, calls = run_raw (fun () -> Dispatcher.plan_edge (make_env ())) in
  check "lock: edge --plan makes exactly 2 lock connections per host (lock, release)"
    (result = Ok false && lock_connections calls "compute-test" = 2 && lock_connections calls "edge-test" = 2);
  check "lock: the acquire runs the locks/ stage guard in the same script"
    (List.for_all
       (fun (r : Proc.request) ->
         let script = String.concat " " r.args in
         contains ~needle:"subtree='locks'" script && contains ~needle:"unsafe remote staging path" script)
       (List.filter is_acquire calls))

let () =
  let unreachable (r : Proc.request) =
    match r.args with [ "edge-test"; _ ] when is_acquire r -> 255 | _ -> 0
  in
  let result, calls = run_raw ~exit_codes:unreachable (fun () -> Dispatcher.edge (make_env ())) in
  check "lock: ssh 255 on acquire -> could not reach the host"
    (match result with Error msg -> contains ~needle:"could not reach edge" msg | Ok () -> false);
  check "lock: unreachable edge still releases the compute" (releases calls = [ "compute-test" ])

(* stdout of [f], which announces through Printf.printf *)
let capture_stdout f =
  let file = Filename.temp_file "infra-dispatcher-test" ".out" in
  flush stdout;
  let saved = Unix.dup Unix.stdout in
  let fd = Unix.openfile file [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  Unix.dup2 fd Unix.stdout;
  Unix.close fd;
  let result =
    Fun.protect
      ~finally:(fun () ->
        flush stdout;
        Unix.dup2 saved Unix.stdout;
        Unix.close saved)
      f
  in
  let text = In_channel.with_open_bin file In_channel.input_all in
  Sys.remove file;
  (result, text)

let index_of ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = if i + nl > hl then None else if String.sub haystack i nl = needle then Some i else go (i + 1) in
  go 0

let () =
  let record : Applied_record.t =
    {
      revision = { commit = "0123456789abcdef"; change = "changeid9"; is_published = false };
      applied_at = "2026-09-20T10:00:00Z";
      applied_by = "someone@laptop";
      components = [ "acl"; "caddy" ];
    }
  in
  let outputs (r : Proc.request) =
    match r.args with
    | [ "compute-test"; _ ] when is_acquire r -> Remote_lock.no_record_marker ^ "\n"
    | [ "edge-test"; _ ] when is_acquire r -> Applied_record.to_string record ^ "\n"
    | _ -> fixture_outputs r
  in
  let mock = Proc.Mock.create ~outputs () in
  let result, text = capture_stdout (fun () -> Proc.Mock.run mock (fun () -> Dispatcher.plan_edge (make_env ()))) in
  check "record: no record on the host -> never applied" (contains ~needle:"==> compute: never applied by infra" text);
  check "record: a parsed record is summarised"
    (result = false
    && contains ~needle:"==> edge: last applied 0123456789ab (local only, not pushed) 2026-09-20T10:00:00Z by someone@laptop" text);
  check "record: shown before staging"
    (match (index_of ~needle:"==> edge: last applied" text, index_of ~needle:"==> stage compute" text) with
    | Some shown, Some staged -> shown < staged
    | _ -> false)

let () =
  let outputs (r : Proc.request) =
    match r.args with
    | [ "edge-test"; _ ] when is_acquire r -> "(commit"
    | [ "compute-test"; _ ] when is_acquire r -> ""
    | _ -> fixture_outputs r
  in
  let mock = Proc.Mock.create ~outputs () in
  let _, text = capture_stdout (fun () -> Proc.Mock.run mock (fun () -> Dispatcher.plan_edge (make_env ()))) in
  check "record: a malformed record is unreadable, not never applied"
    (contains ~needle:"==> edge: unreadable record at /var/lib/infra/applied" text);
  check "record: an empty record is unreadable, not never applied"
    (contains ~needle:"==> compute: unreadable record at /var/lib/infra/applied" text)

let () =
  let _, calls =
    run_raw ~exit_codes:(pending_on [ "CADDY" ]) (fun () ->
        Dispatcher.edge { (make_env ()) with confirm = (fun _ -> false) })
  in
  check "record: declined -> no write" (record_writes calls = [])

let () =
  let failing_install (r : Proc.request) =
    let cmd = String.concat " " r.args in
    if contains ~needle:"_DIFF_ONLY=1" cmd && contains ~needle:"CADDY" cmd then 10
    else if contains ~needle:"CADDY_SOURCE=" cmd then 1
    else 0
  in
  let _, calls = run_raw ~exit_codes:failing_install (fun () -> Dispatcher.edge (make_env ())) in
  check "record: a failed install -> no write" (record_writes calls = [])

let () =
  let compute_record_write_fails (r : Proc.request) =
    match r.args with
    | [ "compute-test"; command ] when contains ~needle:"applied.tmp" command -> 1
    | _ -> pending_on [ "PF"; "CADDY" ] r
  in
  let result, calls = run_raw ~exit_codes:compute_record_write_fails (fun () -> Dispatcher.edge (make_env ())) in
  check "record: a failed record write only warns; the edge still succeeds" (result = Ok ());
  check "record: a failed record write does not stop the next host's"
    (List.map fst (record_writes calls) = [ "compute-test"; "edge-test" ])

let () =
  let mock = Proc.Mock.create ~exit_codes:(fun r -> if r.prog = "jj" then 1 else 0) ~outputs:fixture_outputs () in
  let result = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.edge (make_env ()))) with Failure m -> Error m in
  check "record: no readable jj revision -> fails before any ssh"
    (Result.is_error result
    && not (List.exists (fun (r : Proc.request) -> r.prog = "ssh") (Proc.Mock.calls mock)))

(* caddy-install: edge lock only, stage edge/ and the rendered Caddy tree,
   confirm, then one unconditional 02-caddy run -- no diff, no record. *)
let caddy_install_command ~force_build =
  Printf.sprintf
    "edge-test sudo env %sCADDY_SOURCE=/tmp/serai-stage-test/edge/caddy-rendered bash /tmp/serai-stage-test/edge/02-caddy"
    (if force_build then "CADDY_FORCE_BUILD=1 " else "")

let () =
  let result, calls = run_raw (fun () -> Dispatcher.caddy_install (make_env ())) in
  check "caddy-install: succeeds" (result = Ok ());
  check "caddy-install: takes only the edge lock, and releases it"
    (acquires calls = [ "edge-test" ] && releases calls = [ "edge-test" ]);
  check "caddy-install: the lock is the first call" (match calls with first :: _ -> is_acquire first | [] -> false);
  let args (r : Proc.request) = String.concat " " r.args in
  match without_bookkeeping calls with
  | [ guard; tree; rendered; install ] ->
      check "caddy-install: stage guard on the edge's edge/ subtree"
        (guard.prog = "ssh" && contains ~needle:"subtree='edge'" (args guard)
        && List.hd guard.args = "edge-test");
      check "caddy-install: rsyncs the engine's edge/ and the configuration's edge/ in one --delete transfer"
        (tree.prog = "rsync" && List.mem "--delete" tree.args
        && List.mem "/repo/edge/" tree.args
        && List.mem "fixtures/edge_root/edge/" tree.args
        && List.mem "edge-test:/tmp/serai-stage-test/edge/" tree.args);
      check "caddy-install: then rsyncs the rendered Caddy tree"
        (rendered.prog = "rsync" && List.mem "--delete" rendered.args
        && List.mem "edge-test:/tmp/serai-stage-test/edge/caddy-rendered/" rendered.args);
      check "caddy-install: runs 02-caddy with CADDY_SOURCE, not in diff-only mode"
        (install.prog = "ssh" && args install = caddy_install_command ~force_build:false
        && not (is_diff install))
  | calls -> check (Printf.sprintf "caddy-install: expected 4 commands, got %d" (List.length calls)) false

let () =
  let _, calls = run_raw (fun () -> Dispatcher.caddy_install (make_env ())) in
  check "caddy-install: never writes an applied record" (record_writes calls = [])

let () =
  let _, calls = run_raw (fun () -> Dispatcher.caddy_install { (make_env ()) with caddy_force_build = true }) in
  check "caddy-install: CADDY_FORCE_BUILD=1 forwarded when set"
    (List.exists (fun (r : Proc.request) -> String.concat " " r.args = caddy_install_command ~force_build:true) calls)

let () =
  let question = ref "" in
  let env = { (make_env ()) with confirm = (fun q -> question := q; false) } in
  let result, calls = run_raw (fun () -> Dispatcher.caddy_install env) in
  check "caddy-install: declined -> fails, nothing installed"
    (result = Error "caddy-install: not applied"
    && not (List.exists (fun (r : Proc.request) -> contains ~needle:"02-caddy" (String.concat " " r.args) && r.prog = "ssh") calls));
  check "caddy-install: asks before running 02-caddy"
    (!question = "run edge/02-caddy (build if needed, unit, install, reload) on edge?");
  check "caddy-install: declined still releases the edge lock" (releases calls = [ "edge-test" ])

let () =
  let broken = Test_declaration.endpoint ~name:"nope" ~ip:fixture_endpoint.ip
      ~hostname:fixture_endpoint.hostname ~tailnet_ports:fixture_endpoint.tailnet_ports
      ~operator_ports:fixture_endpoint.operator_ports in
  let result, calls = run_raw (fun () -> Dispatcher.caddy_install (make_env ~endpoints:[ broken ] ())) in
  check "caddy-install: a render error aborts before any command"
    (calls = [] && match result with Error _ -> true | Ok () -> false)

(* jail-test: the example's apps, since the script is rendered from their
   strategy_config, on the example's network. Everything is validated and
   rendered before the compute host lock; staging, the confirm and the run happen
   under it. *)
let example_app name =
  App_config.load (Filename.concat (Layout.app_dir (Repo_root.example ()) name) "app.sexp")
let counter = example_app "counter"
let example_apps = [ example_app "hello"; counter ]

let jail_test_env ?(confirm = fun _ -> true) () =
  { (make_env ()) with config = example_apps; confirm;
    topology = Some (Test_declaration.topology ~guests:[]
      ~network:"(subnet 10.20.0.0/24) (gateway 10.20.0.1) (guest_bridge 10.20.0.254)"
      ~jails:(List.map (fun (a : App_config.t) -> a.endpoint.name) example_apps) ()) }

(* Declarations are only built through their smart constructors: these
   rebuild an app or endpoint with one field changed. *)
let endpoint_with ?name ?ip (endpoint : Network_endpoint.t) =
  Test_declaration.endpoint
    ~name:(Option.value name ~default:endpoint.name)
    ~ip:(Option.value ip ~default:endpoint.ip)
    ~hostname:endpoint.hostname ~tailnet_ports:endpoint.tailnet_ports
    ~operator_ports:endpoint.operator_ports

let app_with ?name ?ip (app : App_config.t) =
  App_config.with_endpoint app (endpoint_with ?name ?ip app.endpoint)

let destroy_script ~name ?dataset () =
  match Jail_test.validate_destroy_target ~name ?dataset () with
  | Ok target -> Jail_test.destroy_script target
  | Error msg -> failwith msg

let countertest_stage = "/tmp/serai-stage-test/jail-test/countertest"

let () =
  (* the staged jail is read while its rsync runs: the local copy is
     removed once staging is done *)
  let staged = ref None in
  let exit_codes (r : Proc.request) =
    (match r.args with
    | [ "-az"; "--no-perms"; "--no-owner"; "--no-group"; source; dest ] when dest = "compute-test:" ^ countertest_stage ^ "/jail" ->
        staged := Some (In_channel.with_open_bin source In_channel.input_all)
    | _ -> ());
    0
  in
  let question = ref "" in
  (* the confirm marks where it was asked in the captured output *)
  let env = jail_test_env ~confirm:(fun q -> question := q; print_string "<<asked>>\n"; true) () in
  let (result, calls), text =
    capture_stdout (fun () -> run_raw ~exit_codes (fun () -> Dispatcher.jail_test env "counter" ~ip:"10.20.0.200"))
  in
  check "jail-test: succeeds" (result = Ok ());
  check "jail-test: takes only the compute lock, first, and releases it"
    (acquires calls = [ "compute-test" ] && releases calls = [ "compute-test" ]
    && match calls with first :: _ -> is_acquire first | [] -> false);
  (match without_bookkeeping calls with
  | [ guard; app_dir; jail; run_script ] ->
      check "jail-test: stage guard on the compute's jail-test/<test name> subtree"
        (guard.prog = "ssh" && List.hd guard.args = "compute-test"
        && contains ~needle:"subtree='jail-test/countertest'" (String.concat " " guard.args));
      check "jail-test: the stage-guard ssh also probes for an existing countertest, no extra connection"
        (guard.args
        = [
            "compute-test";
            Dispatcher.secure_remote_stage_script ~stage:"/tmp/serai-stage-test" ~subtree:"jail-test/countertest"
            ^ "\n" ^ Jail_test.existing_ip_script ~name:"countertest" ();
          ]);
      (* --no-perms: without it -a copies the app dir's 0755 onto the
         guarded stage dir, and every later jail-test fails the 0700 guard. *)
      check "jail-test: rsyncs the app dir, without any jail or its mode, to the test stage"
        (app_dir.prog = "rsync"
        && app_dir.args
           = [
               "-az"; "--no-perms"; "--no-owner"; "--no-group"; "--delete"; "--exclude=/jail";
               "--exclude"; ".env"; "--exclude"; ".env.*"; "fixtures/edge_root/apps/counter/";
               "compute-test:" ^ countertest_stage ^ "/";
             ]);
      check "jail-test: then rsyncs the rendered script as its jail"
        (jail.prog = "rsync" && List.nth jail.args 5 = "compute-test:" ^ countertest_stage ^ "/jail");
      check "jail-test: the staged jail is the countertest render at the given ip"
        (match Jail_test.render (counter) ~ip:"10.20.0.200" with
        | Ok script -> !staged = Some script
        | Error _ -> false);
      check "jail-test: runs the staged jail with doas on the compute"
        (run_script.prog = "ssh"
        && run_script.args = [ "compute-test"; "doas sh '" ^ countertest_stage ^ "/jail'" ])
  | calls -> check (Printf.sprintf "jail-test: expected 4 commands, got %d" (List.length calls)) false);
  check "jail-test: asks before running"
    (!question = "create test jail countertest (10.20.0.200) on compute from counter's generated jail script?");
  check "jail-test: says what it will create, dataset included"
    (contains
       ~needle:
         "==> will create jail countertest at 10.20.0.200: root /jails/countertest, jail.conf block and jail_list entry \
          countertest, zfs dataset zroot/countertest"
       text);
  check "jail-test: warns the jail persists, autostarts, starts the app's service, and must be destroyed"
    (contains
       ~needle:
         "==> countertest joins jail_list and autostarts on reboot; the script starts the jail and, if it enables \
          one, counter's rc.d service counter; destroy it when done: infra jail-test counter --destroy"
       text);
  check "jail-test: warns before it asks"
    (match (index_of ~needle:"autostarts on reboot" text, index_of ~needle:"<<asked>>" text) with
    | Some a, Some b -> a < b
    | _ -> false);
  check "jail-test: says what it will create before it runs"
    (match (index_of ~needle:"==> will create" text, index_of ~needle:"==> run generated" text) with
    | Some a, Some b -> a < b
    | _ -> false)

let () =
  let result, calls = run_raw (fun () -> Dispatcher.jail_test (jail_test_env ~confirm:(fun _ -> false) ()) "counter" ~ip:"10.20.0.200") in
  check "jail-test: declined -> fails, the script never runs"
    (result = Error "jail-test: not run"
    && not (List.exists (fun (r : Proc.request) -> contains ~needle:"doas" (String.concat " " r.args)) calls));
  check "jail-test: declined still releases the compute lock" (releases calls = [ "compute-test" ])

let () =
  let refused what ?(env = jail_test_env ()) ~because app ip =
    let result, calls = run_raw (fun () -> Dispatcher.jail_test env app ~ip) in
    check ("jail-test: refused before any command: " ^ what)
      (calls = [] && match result with Error msg -> contains ~needle:because msg | Ok () -> false)
  in
  refused "an ip outside the host's network" ~because:"not a host address in compute's 10.20.0.0/24" "counter" "10.20.1.200";
  refused "the host's gateway" ~because:"compute's own address" "counter" "10.20.0.1";
  refused "the host's guest bridge" ~because:"compute's own address" "counter" "10.20.0.254";
  refused "the app's own ip" ~because:"declared endpoint's ip" "counter" "10.20.0.3";
  refused "another app's ip" ~because:"declared endpoint's ip" "counter" "10.20.0.2";
  refused "a guest's ip" ~because:"declared endpoint's ip"
    ~env:
      {
        (jail_test_env ()) with
        endpoints =
          Test_declaration.endpoints
            [ endpoint_with ~ip:"10.20.0.201" fixture_endpoint ];
      }
    "counter" "10.20.0.201";
  refused "an unknown app" ~because:"unknown app" "nope" "10.20.0.200";
  refused "a stage outside /tmp" ~because:"OPS_REMOTE_STAGE" ~env:{ (jail_test_env ()) with remote_stage = "/etc" }
    "counter" "10.20.0.200";
  let countertest = app_with ~name:"countertest" ~ip:"10.20.0.99" counter in
  refused "a test name that is a declared app" ~because:"already a declared endpoint"
    ~env:{ (jail_test_env ()) with config = example_apps @ [ countertest ] }
    "counter" "10.20.0.200";
  (* An app whose test name is not placeholder-safe, or whose script does
     not render, can no longer be declared: Network_endpoint.create refuses
     the name and App_config refuses the strategy at load. Jail_test's own
     refusals of such names stay covered by test_jail_test.ml. *)
  check "jail-test: an app named k-cal cannot be declared"
    (Result.is_error
       (Network_endpoint.create ~name:"k-cal" ~ip:"10.20.0.99" ~hostname:"k-cal.example.org"
          ~tailnet_ports:[] ~operator_ports:[]));
  check "jail-test: an app whose strategy does not parse cannot be declared"
    (match
       App_config.of_sexp
         (Sexplib.Sexp.of_string
            "((name hello) (ip 10.20.0.2) (hostname hello.example.org) (tailnet_ports ()) \
             (operator_ports ()) (strategy freebsd_native_elixir) (hooks ()) (extra_steps ()) \
             (strategy_config ()))")
     with
    | _ -> false
    | exception Sexplib.Conv.Of_sexp_error _ -> true)

(* An existing countertest at another ip, or one the probe cannot account
   for, is refused before anything is staged or run; the lock is released.
   The same ip is a re-run and goes ahead. *)
let () =
  let answering answer (r : Proc.request) = if is_existing_probe r then answer else fixture_outputs r in
  let staged_or_run calls =
    List.exists
      (fun (r : Proc.request) -> r.prog = "rsync" || contains ~needle:"doas" (String.concat " " r.args))
      calls
  in
  List.iter
    (fun (what, answer, because) ->
      let result, calls =
        run_raw ~outputs:(answering answer) (fun () -> Dispatcher.jail_test (jail_test_env ()) "counter" ~ip:"10.20.0.200")
      in
      check ("jail-test: refused before staging: " ^ what)
        ((match result with Error msg -> contains ~needle:because msg | Ok () -> false)
        && (not (staged_or_run calls))
        && releases calls = [ "compute-test" ]))
    [
      ("countertest exists at another ip", "jail-test-existing: ip 10.20.0.201\n", "already exists at 10.20.0.201");
      ("countertest exists with no ip", "jail-test-existing: ip \n", "already exists");
      ("the probe gave no answer", "", "could not tell");
    ];
  let result, calls =
    run_raw ~outputs:(answering "jail-test-existing: ip 10.20.0.200\n") (fun () ->
        Dispatcher.jail_test (jail_test_env ()) "counter" ~ip:"10.20.0.200")
  in
  check "jail-test: countertest existing at the same ip -> a re-run, it goes ahead"
    (result = Ok () && staged_or_run calls);
  let result, calls =
    run_raw
      ~exit_codes:(fun r -> if is_existing_probe r then 1 else 0)
      (fun () -> Dispatcher.jail_test (jail_test_env ()) "counter" ~ip:"10.20.0.200")
  in
  check "jail-test: a failed stage guard -> fails before staging"
    (Result.is_error result && (not (staged_or_run calls)) && releases calls = [ "compute-test" ])

(* --destroy: the compute lock, a confirm, then one doas sh -c of the destroy
   script for <app>test -- nothing staged. *)
let () =
  let question = ref "" in
  let env = jail_test_env ~confirm:(fun q -> question := q; true) () in
  let (result, calls), text = capture_stdout (fun () -> run_raw (fun () -> Dispatcher.jail_test_destroy env "counter")) in
  check "jail-test --destroy: succeeds" (result = Ok ());
  check "jail-test --destroy: takes and releases only the compute lock"
    (acquires calls = [ "compute-test" ] && releases calls = [ "compute-test" ]);
  (match without_bookkeeping calls with
  | [ destroy ] ->
      check "jail-test --destroy: one doas sh -c of the countertest destroy script, with its dataset"
        (destroy.prog = "ssh"
        && destroy.args
           = [
               "compute-test";
               "doas sh -c "
               ^ Shell.quote (destroy_script ~name:"countertest" ~dataset:"zroot/countertest" ());
             ])
  | calls -> check (Printf.sprintf "jail-test --destroy: expected 1 command, got %d" (List.length calls)) false);
  check "jail-test --destroy: asks first" (!question = "destroy test jail countertest on compute?");
  check "jail-test --destroy: says what it will destroy"
    (contains
       ~needle:
         "==> will destroy jail countertest: stop it, remove its jail.conf block and jail_list entry, zfs destroy -r \
          zroot/countertest, remove /jails/countertest"
       text)

let () =
  let _, calls = run_raw (fun () -> Dispatcher.jail_test_destroy (jail_test_env ()) "hello") in
  check "jail-test --destroy: no dataset for a strategy without one"
    (List.exists
       (fun (r : Proc.request) ->
         r.args = [ "compute-test"; "doas sh -c " ^ Shell.quote (destroy_script ~name:"hellotest" ()) ])
       calls)

let () =
  let result, calls = run_raw (fun () -> Dispatcher.jail_test_destroy (jail_test_env ~confirm:(fun _ -> false) ()) "counter") in
  check "jail-test --destroy: declined -> nothing destroyed, lock released"
    (result = Error "jail-test --destroy: not run"
    && not (List.exists (fun (r : Proc.request) -> contains ~needle:"doas sh -c" (String.concat " " r.args)) calls)
    && releases calls = [ "compute-test" ])

let () =
  let refused what ~env app =
    let result, calls = run_raw (fun () -> Dispatcher.jail_test_destroy env app) in
    check ("jail-test --destroy: refused before any command: " ^ what) (Result.is_error result && calls = [])
  in
  refused "an unknown app" ~env:(jail_test_env ()) "nope";
  let result, calls =
    run_raw (fun () ->
        Dispatcher.jail_test_destroy
          { (jail_test_env ()) with
            config = example_apps @ [ app_with ~name:"countertest" ~ip:"10.20.0.99" counter ] }
          "counter")
  in
  check "jail-test --destroy: refused before any command: a test name that is a declared app"
    (calls = [] && match result with Error msg -> contains ~needle:"already a declared endpoint" msg | Ok () -> false);
  let result, calls =
    run_raw (fun () ->
        Dispatcher.jail_test_destroy
          { (jail_test_env ()) with
            endpoints = Test_declaration.endpoints [ endpoint_with ~name:"countertest" fixture_endpoint ] }
          "counter")
  in
  check "jail-test --destroy: refused before any command: a test name that is a declared guest"
    (calls = [] && match result with Error msg -> contains ~needle:"already a declared endpoint" msg | Ok () -> false);
  (* No app named k-cal can be declared (Network_endpoint refuses the
     name), so its test name never reaches Jail_test from here. *)
  refused "an app named k-cal, which cannot be declared" ~env:(jail_test_env ()) "k-cal"

(* bootstrap stages the app directory, then counter's rendered jail script as
   compute/apps/counter/jail beside it, then runs the hook, all under the compute host lock. *)
let () =
  let staged = ref None in
  let exit_codes (r : Proc.request) =
    (match r.args with
    | [ _; _; _; source; "compute-test:/tmp/serai-stage-test/compute/apps/counter/jail" ] ->
        staged := Some (In_channel.with_open_bin source In_channel.input_all)
    | _ -> ());
    0
  in
  let result, calls = run_raw ~exit_codes (fun () -> Dispatcher.bootstrap (jail_test_env ()) "counter") in
  (match without_bookkeeping calls with
  | [ guard; app_dir; jail; hook ] ->
      (* The engine (/repo) supplies _lib, the configuration
         (fixtures/edge_root) the app: one transfer to the stage. *)
      check "bootstrap: stage guard, engine _lib and configured app rsync, rendered jail rsync, run it"
        (result = Ok ()
        && contains ~needle:"subtree='compute/apps'" (String.concat " " guard.args)
        && (app_dir.prog, app_dir.args)
           = ("rsync",
              [ "-az"; "--delete"; "--exclude"; ".env"; "--exclude"; ".env.*";
                "/repo/compute/apps/_lib"; "fixtures/edge_root/apps/counter"; "compute-test:/tmp/serai-stage-test/compute/apps/" ])
        && jail.prog = "rsync"
        && jail.args
           = [ "-az"; "--no-owner"; "--no-group"; List.nth jail.args 3; "compute-test:/tmp/serai-stage-test/compute/apps/counter/jail" ]
        && (hook.prog, hook.args)
           = ("ssh", [ "compute-test"; "doas sh /tmp/serai-stage-test/compute/apps/counter/jail" ]))
  | calls -> check (Printf.sprintf "bootstrap: expected 4 commands, got %d" (List.length calls)) false);
  check "bootstrap: the staged jail is counter's own render"
    (!staged = Some (Strategy.render_jail_script (counter)));
  check "bootstrap: under the compute lock"
    (acquires calls = [ "compute-test" ] && releases calls = [ "compute-test" ])

(* The stage guard, run for real: each check executes the guard script bootstrap
   sends over ssh locally, against a private stage under /tmp, and fails the
   ssh call when the script does. An unsafe stage stops bootstrap before any
   rsync or privileged hook. *)
let () =
  let fake_stat_dir = Filename.temp_dir "infra-fake-stat" "" in
  at_exit (fun () -> Test_declaration.remove_tree fake_stat_dir);
  (* Reports another owner for FOREIGN_STAGE, else defers to the real stat. *)
  Out_channel.with_open_bin (Filename.concat fake_stat_dir "stat") (fun oc ->
      output_string oc
        "#!/bin/sh\nif [ \"${FOREIGN_STAGE:-}\" = \"${3:-}\" ] && [ \"$1\" = -c ] && [ \"$2\" = %u ]; then echo 4242; else exec /usr/bin/stat \"$@\"; fi\n");
  Unix.chmod (Filename.concat fake_stat_dir "stat") 0o755;
  let bootstrap_at ?(foreign = false) stage =
    let exit_codes (r : Proc.request) =
      match r.args with
      | [ "compute-test"; script ] when contains ~needle:"unsafe remote staging path" script ->
          let env = if foreign then Printf.sprintf "FOREIGN_STAGE=%s PATH=%s:$PATH " (Filename.quote stage) fake_stat_dir else "" in
          Sys.command (env ^ "sh -c " ^ Filename.quote script ^ " 2>/dev/null")
      | _ -> 0
    in
    run_raw ~exit_codes (fun () -> Dispatcher.bootstrap { (jail_test_env ()) with remote_stage = stage } "counter")
  in
  let refused name ?foreign stage =
    let result, calls = bootstrap_at ?foreign stage in
    let reached prog = List.exists (fun (r : Proc.request) -> r.prog = prog) (without_bookkeeping calls) in
    check ("stage guard: " ^ name ^ " is refused before rsync and the hook")
      (Result.is_error result && (not (reached "rsync"))
      && not (List.exists (fun (r : Proc.request) -> contains ~needle:"doas sh" (String.concat " " r.args)) calls))
  in
  let stage = Printf.sprintf "/tmp/infra-stage-test-%d" (Unix.getpid ()) in
  let clean () = ignore (Sys.command ("rm -rf " ^ Filename.quote stage)) in
  at_exit clean;
  clean ();
  let result, _ = bootstrap_at stage in
  let mode path = (Unix.lstat path).st_perm in
  check "stage guard: a fresh stage is created private, component by component"
    (result = Ok () && mode stage = 0o700 && mode (stage ^ "/compute/apps") = 0o700);
  clean ();
  Unix.symlink fake_stat_dir stage;
  refused "a symlinked stage" stage;
  clean ();
  Unix.mkdir stage 0o700;
  Unix.chmod stage 0o777;
  refused "a permissive stage" stage;
  clean ();
  Unix.mkdir stage 0o700;
  refused "another user's stage" ~foreign:true stage;
  clean ()

(* An app whose strategy does not parse is refused at load, so
   bootstrap never sees one. *)
let () =
  check "bootstrap: an app whose strategy does not parse -> refused at load"
    (match
       App_config.of_sexp
         (Sexplib.Sexp.of_string
            "((name drill) (ip 10.40.0.2) (hostname drill.example.org) (tailnet_ports ()) \
             (operator_ports ()) (strategy freebsd_native_elixir) (hooks (bootstrap)) \
             (extra_steps ()) (strategy_config ()))")
     with
    | _ -> false
    | exception Sexplib.Conv.Of_sexp_error (Failure msg, _) ->
        contains ~needle:"missing strategy_config field" msg)

(* Guests: the bhyve lifecycle, reached by ProxyJump through the
   compute host over a shared control socket. A temporary tree stands in for the
   repository root and the operator's source checkout beside it. *)
let guest_tree =
  let dir = Filename.temp_dir "infra-guest" "" in
  List.iter (fun sub -> Sys.mkdir (Filename.concat dir sub) 0o700) [ "repo"; "src"; "src/vault"; "elsewhere" ];
  at_exit (fun () -> Test_declaration.remove_tree dir);
  dir

let guest_root = Filename.concat guest_tree "repo"

let vault_guest =
  Test_declaration.guest ~login_user:"vault" ~source_checkout:"../src/vault"
    (Test_declaration.endpoint ~name:"vault" ~ip:"10.40.0.10" ~hostname:"vault.example.org"
       ~tailnet_ports:[ { port_name = "http"; port = 4010 } ] ~operator_ports:[ { port_name = "ssh"; port = 22 } ])

let guest_env ?(multiplex = true) ?source () =
  { (make_env ()) with layout = Layout.v ~engine:"/repo" ~config:guest_root; guests = [ vault_guest ]; ssh_multiplex = multiplex;
                       source_checkout_override = source }

(* guests: sorted, and reads nothing but the declaration *)
let () =
  let second = Test_declaration.guest ~login_user:"ops" ~source_checkout:"../src/alpha"
      (Test_declaration.endpoint ~name:"alpha" ~ip:"10.40.0.11" ~hostname:"alpha.example.org"
         ~tailnet_ports:[] ~operator_ports:[])
  in
  let result, calls =
    run (fun () -> Dispatcher.list_guests { (guest_env ()) with guests = [ vault_guest; second ] })
  in
  check "guests: no commands run to list guests" (calls = []);
  check "guests: sorted" (result = Ok [ "alpha"; "vault" ])

let stage = "/tmp/serai-stage-test"
let mux = [ "-o"; "ControlMaster=auto"; "-o"; "ControlPath=/tmp/ops-ssh-%C"; "-o"; "ControlPersist=60" ]
let hop = [ "-J"; "compute-test"; "vault@10.40.0.10" ]
let guard_call ?(opts = mux) () =
  ("ssh", opts @ hop @ [ Dispatcher.secure_remote_stage_script ~stage ~subtree:"compute/guests" ])
let stage_call ?(shell = "ssh -o ControlMaster=auto -o ControlPath=/tmp/ops-ssh-%C -o ControlPersist=60 -J compute-test") () =
  ( "rsync",
    [ "-az"; "--delete"; "-e"; shell; "--exclude"; ".env"; "--exclude"; ".env.*";
      guest_root ^ "/guests/vault"; "vault@10.40.0.10:" ^ stage ^ "/compute/guests/" ] )
let push_call ?(shell = "ssh -o ControlMaster=auto -o ControlPath=/tmp/ops-ssh-%C -o ControlPersist=60 -J compute-test")
    ?(source = guest_root ^ "/../src/vault") () =
  ( "rsync",
    [ "-az"; "--delete"; "-e"; shell; "--exclude"; "_build/"; "--exclude"; ".git/"; "--exclude"; ".jj/";
      "--exclude"; ".env"; "--exclude"; ".env.*";
      source ^ "/"; "vault@10.40.0.10:vault/" ] )
let tty_call ?(opts = mux) command = ("ssh", ("-t" :: opts) @ hop @ [ command ])
let build_call ?opts () = tty_call ?opts ("sh " ^ stage ^ "/compute/guests/vault/build")
let install_call ?opts () = tty_call ?opts ("su -c 'sh " ^ stage ^ "/compute/guests/vault/install'")
let provision_call ?opts () = tty_call ?opts ("su -c 'sh " ^ stage ^ "/compute/guests/vault/provision'")
(* on the compute host itself, after provision: vm-bhyve starts the guest at boot *)
let autostart_call ?(opts = mux) () = ("ssh", opts @ [ "compute-test"; "doas sysrc vm_list+='vault'" ])

let argv calls = List.map (fun (r : Proc.request) -> (r.prog, r.args)) calls

let guest_acquires calls =
  List.filter_map
    (fun (r : Proc.request) ->
      if is_acquire r then Some (List.filteri (fun i _ -> i < List.length r.args - 1) r.args) else None)
    calls

let guest_releases calls =
  List.filter_map
    (fun (r : Proc.request) ->
      if contains ~needle:"is not this run's" (String.concat " " r.args) then
        Some (List.filteri (fun i _ -> i < List.length r.args - 1) r.args)
      else None)
    calls

let lock_connection = mux @ hop
let release_connection = [ "-o"; "ConnectTimeout=10" ] @ mux @ hop

(* exit [code] for the first call whose argv is [call] *)
let failing_at (prog, args) code (r : Proc.request) = if r.prog = prog && r.args = args then code else 0

let () =
  let result, calls = run_raw (fun () -> Dispatcher.provision_guest (guest_env ()) "vault") in
  check "guest provision: succeeds" (result = Ok ());
  check "guest provision: the exact argv of every call, in order"
    (argv (without_bookkeeping calls) = [ guard_call (); stage_call (); provision_call (); autostart_call () ]);
  check "guest provision: locks the guest through the compute host first, releases it last"
    (guest_acquires calls = [ lock_connection ] && guest_releases calls = [ release_connection ]
    && (match calls with first :: _ -> is_acquire first | [] -> false)
    && match List.rev calls with last :: _ -> guest_releases [ last ] <> [] | [] -> false)

let () =
  let result, calls = run_raw (fun () -> Dispatcher.build_guest (guest_env ()) "vault") in
  check "guest build: succeeds" (result = Ok ());
  check "guest build: the exact argv of every call, in order"
    (argv (without_bookkeeping calls) = [ guard_call (); stage_call (); push_call (); build_call () ]);
  check "guest build: under the guest's lock"
    (guest_acquires calls = [ lock_connection ] && guest_releases calls = [ release_connection ])

let () =
  let result, calls = run_raw (fun () -> Dispatcher.deploy_guest (guest_env ()) "vault") in
  check "guest deploy: succeeds" (result = Ok ());
  check "guest deploy: build, install, provision, then autostart -- exact argv, in order"
    (argv (without_bookkeeping calls)
    = [ guard_call (); stage_call (); push_call (); build_call (); install_call (); provision_call ();
        autostart_call () ]);
  check "guest deploy: one lock on the guest for the whole run"
    (guest_acquires calls = [ lock_connection ] && guest_releases calls = [ release_connection ]);
  check "guest deploy: -t exactly on the build, install and provision calls"
    (List.filter_map
       (fun (r : Proc.request) -> if List.mem "-t" r.args then Some (r.prog, r.args) else None)
       calls
    = [ build_call (); install_call (); provision_call () ])

let () =
  let _, calls = run_raw (fun () -> Dispatcher.deploy_guest (guest_env ~multiplex:false ()) "vault") in
  check "guest: OPS_SSH_MULTIPLEX=0 drops the control options everywhere"
    (argv (without_bookkeeping calls)
    = [ guard_call ~opts:[] (); stage_call ~shell:"ssh -J compute-test" (); push_call ~shell:"ssh -J compute-test" ();
        build_call ~opts:[] (); install_call ~opts:[] (); provision_call ~opts:[] (); autostart_call ~opts:[] () ]
    && guest_acquires calls = [ hop ])

let () =
  let _, calls = run_raw (fun () -> Dispatcher.deploy_guest { (guest_env ()) with ops_control_path = "/run/user/1/cm-%C" } "vault") in
  check "guest: OPS_CONTROL_PATH is the control path on every connection"
    (List.for_all
       (fun (r : Proc.request) ->
         List.mem "ControlPath=/run/user/1/cm-%C" r.args
         || List.exists (fun a -> contains ~needle:"ControlPath=/run/user/1/cm-%C " a) r.args)
       calls)

let () =
  let elsewhere = Filename.concat guest_tree "elsewhere" in
  let _, calls = run_raw (fun () -> Dispatcher.build_guest (guest_env ~source:elsewhere ()) "vault") in
  check "guest build: an absolute SOURCE_CHECKOUT replaces the declared checkout"
    (List.mem (push_call ~source:elsewhere ()) (argv calls));
  let _, calls = run_raw (fun () -> Dispatcher.build_guest (guest_env ~source:"../src/vault/" ()) "vault") in
  check "guest build: a relative SOURCE_CHECKOUT is taken against the repository root"
    (List.mem (push_call ~source:(guest_root ^ "/../src/vault/") ()) (argv calls))

let () =
  List.iter
    (fun (label, f) ->
      let result, calls = run_raw f in
      check ("guest: a missing checkout is refused before any call: " ^ label)
        (calls = []
        && result = Error ("source checkout not found: " ^ guest_root ^ "/../src/nosuch")))
    [
      ("build", fun () -> Dispatcher.build_guest (guest_env ~source:"../src/nosuch" ()) "vault");
      ("deploy", fun () -> Dispatcher.deploy_guest (guest_env ~source:"../src/nosuch" ()) "vault");
    ]

let () =
  List.iter
    (fun (name, expected) ->
      List.iter
        (fun (label, f) ->
          let result, calls = run_raw (fun () -> f (guest_env ()) name) in
          check (Printf.sprintf "guest %s: %S refused before any call" label name)
            (calls = [] && result = Error expected))
        [ ("provision", Dispatcher.provision_guest); ("build", Dispatcher.build_guest);
          ("deploy", Dispatcher.deploy_guest) ])
    [ ("nosuch", "unknown guest"); ("bad/name", "invalid guest name"); ("", "invalid guest name");
      ("drill", "unknown guest") ]

let () =
  let result, calls =
    run_raw ~exit_codes:(failing_at (build_call ()) 1) (fun () -> Dispatcher.deploy_guest (guest_env ()) "vault")
  in
  check "guest deploy: a failed build stops before install and provision"
    (Result.is_error result
    && not (List.exists (fun c -> c = install_call () || c = provision_call ()) (argv calls)));
  check "guest deploy: a failed build still releases the guest's lock"
    (guest_releases calls = [ release_connection ]);
  let result, calls =
    run_raw ~exit_codes:(failing_at (install_call ()) 1) (fun () -> Dispatcher.deploy_guest (guest_env ()) "vault")
  in
  check "guest deploy: a failed install stops before provision"
    (Result.is_error result && List.mem (install_call ()) (argv calls)
    && not (List.mem (provision_call ()) (argv calls)));
  check "guest deploy: a failed install still releases the guest's lock"
    (guest_releases calls = [ release_connection ]);
  let result, calls =
    run_raw ~exit_codes:(failing_at (stage_call ()) 1) (fun () -> Dispatcher.provision_guest (guest_env ()) "vault")
  in
  check "guest provision: a failed staging rsync stops before su, and releases the lock"
    (Result.is_error result && not (List.mem (provision_call ()) (argv calls))
    && guest_releases calls = [ release_connection ])

let () =
  let held (r : Proc.request) = if is_acquire r then Remote_lock.stale_exit else 0 in
  let result, calls = run_raw ~exit_codes:held (fun () -> Dispatcher.deploy_guest (guest_env ()) "vault") in
  check "guest lock: a stale lock stops the run before staging, naming infra unlock vault"
    ((match result with Error msg -> contains ~needle:"infra unlock vault" msg | Ok () -> false)
    && without_bookkeeping calls = []);
  let result, calls = run_raw (fun () -> Dispatcher.unlock (guest_env ()) "vault") in
  check "unlock: a guest is unlocked through the compute host"
    (result = Ok ()
    && match calls with
       | [ { prog = "ssh"; args; _ } ] ->
           List.filteri (fun i _ -> i < List.length args - 1) args = lock_connection
           && contains ~needle:"removing lock held by" (List.nth args (List.length args - 1))
       | _ -> false)

let () =
  let env = guest_env () in
  let _, calls = run_raw (fun () -> Dispatcher.deploy_app_or_guest env "vault") in
  check "deploy <name>: a declared guest runs the guest deploy"
    (List.mem (install_call ()) (argv calls));
  let _, calls = run_raw (fun () -> Dispatcher.deploy_app_or_guest env "drill") in
  check "deploy <name>: an app runs its deploy hook"
    (match calls with [ call ] -> contains ~needle:"/apps/drill/deploy" call.prog | _ -> false);
  let both = { env with config = make_app ~name:"vault" ~ip:"10.40.0.20" ~hooks:[ Deploy ] () :: env.config } in
  let result, calls = run_raw (fun () -> Dispatcher.deploy_app_or_guest both "vault") in
  check "deploy <name>: a name that is both an app and a guest is refused before any call"
    (calls = [] && result = Error "deploy: vault is both an app and a guest");
  let result, calls = run_raw (fun () -> Dispatcher.deploy_app_or_guest env "nosuch") in
  check "deploy <name>: neither is an unknown app" (calls = [] && result = Error "unknown app")

(* Execute the real generated guard locally, with only its /tmp anchor
   relocated behind a private test parent. No transport or native host runs. *)
let () =
  let parent = Filename.concat (Sys.getcwd ()) "../.." in
  (* dune runs tests from _build/default/test; use the existing private TMPDIR. *)
  let parent = match Sys.getenv_opt "TMPDIR" with Some p -> p | None -> parent in
  let scratch = Filename.temp_dir ~temp_dir:parent "stage-modes-" "" in
  let quote = Filename.quote in
  let write path text = Out_channel.with_open_bin path (fun c -> output_string c text) in
  let cleanup () = ignore (Sys.command ("rm -rf " ^ quote scratch)) in
  Fun.protect ~finally:cleanup (fun () ->
    let bin = Filename.concat scratch "bin" in Unix.mkdir bin 0o700;
    let stat = Filename.concat bin "stat" in
    write stat {|#!/bin/sh
if [ "$*" = --version ]; then [ "$FAKE_STAT_KIND" = linux ]; exit; fi
[ "$#" = 3 ] || exit 99
case "$1:$2" in
 -c:%u|-f:%u) exec /usr/bin/stat -c %u "$3" ;;
 -c:%a) exec /usr/bin/stat -c %a "$3" ;;
 -f:%p) printf '%o\n' "0x$(/usr/bin/stat -c %f "$3")" ;;
 -f:%Lp) printf '%o\n' "$((0x$(/usr/bin/stat -c %f "$3") & 0777))" ;;
 *) exit 99 ;;
esac
|};
    Unix.chmod stat 0o700;
    let script = Dispatcher.secure_remote_stage_script ~stage:"/tmp/permission-stage" ~subtree:"new-subtree" in
    let script = Caddy_render.substitute ~placeholders:["path=/tmp\n", "path=" ^ quote scratch ^ "\n"] script in
    let path = Filename.concat scratch "guard" in write path script;
    let stage = Filename.concat scratch "permission-stage" in
    let leaf = Filename.concat stage "new-subtree" in
    let run kind = Sys.command ("PATH=" ^ quote (bin ^ ":/usr/bin:/bin") ^ " FAKE_STAT_KIND=" ^ kind ^ " sh " ^ quote path ^ " >/dev/null 2>&1") in
    List.iter (fun kind ->
      check ("staging " ^ kind ^ ": private 0700 accepted") (run kind = 0);
      Unix.rmdir leaf;
      List.iter (fun mode ->
        Unix.chmod stage mode;
        check (Printf.sprintf "staging %s: special mode %o refused before mkdir" kind mode)
          (run kind <> 0 && not (Sys.file_exists leaf))) [0o1700;0o2700;0o4700];
      Unix.chmod stage 0o700;
      Unix.rmdir stage) ["linux";"freebsd"])

(* compute logging: each reviewed sender is staged from its app's directory,
   beside _lib, where bootstrap.sh looks for it. *)
let () =
  let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
  let env = { (make_env ()) with layout = d.layout; config = d.apps; topology = d.topology; guests = d.guests } in
  let result, calls = run_raw (fun () -> Dispatcher.install_compute_logging env) in
  let staged sender = List.exists (fun (r : Proc.request) ->
    r.prog = "rsync" && List.mem "--relative" r.args
    && List.mem (Filename.concat (Layout.apps_dir d.layout) sender) r.args
    && List.mem "compute-test:/tmp/serai-stage-test/compute/apps/" r.args) calls in
  check "compute logging: reviewed senders staged from their apps"
    (result = Ok () && staged "./counter/logging/counter_service")

(* compute logging: the relay and sender configs are rendered from the logs app
   and the guests placed on its host, and staged beside the targets. *)
let () =
  let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
  let env = { (make_env ()) with layout = d.layout; config = d.apps; topology = d.topology; guests = d.guests } in
  let staged = Hashtbl.create 3 in
  let read_stage (r : Proc.request) =
    (if r.prog = "rsync" then match List.find_opt (fun a -> Filename.basename a = "logs" && Sys.file_exists a) r.args with
      | Some dir -> List.iter (fun f -> Hashtbl.replace staged f
          (In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all)) (Array.to_list (Sys.readdir dir))
      | None -> ());
    0 in
  let result, _ = run_raw ~exit_codes:read_stage (fun () -> Dispatcher.install_compute_logging env) in
  let file name = Option.value ~default:"" (Hashtbl.find_opt staged name) in
  check "compute logging: configs rendered from the receiver and the host's guests"
    (result = Ok ()
     && contains ~needle:{|network("10.20.0.20"|} (file "syslog-ng-host.conf")
     && contains ~needle:"port(29514)" (file "syslog-ng-jail.conf")
     && contains ~needle:{|"${SOURCEIP}" eq "10.20.0.10"|} (file "syslog-ng-host.conf")
     && file "guest-bridge" = "10.20.0.254\n"
     && Hashtbl.mem staged "logging-targets")

(* edge logging: the sender's config and receiver are rendered from the logs
   app and staged beside 03-logging after the payload, before it runs. *)
let () =
  let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
  let env = { (make_env ()) with layout = d.layout; config = d.apps } in
  let staged = Hashtbl.create 2 and order = ref [] in
  let read_stage (r : Proc.request) =
    order := r :: !order;
    (* The rendered stage's edge, not the payload's edge/ *)
    let rendered a = Filename.basename a = "edge" && not (String.ends_with ~suffix:"/" a) in
    (if r.prog = "rsync" then match List.find_opt (fun a -> rendered a && Sys.file_exists a) r.args with
      | Some dir -> List.iter (fun f -> Hashtbl.replace staged f
          (In_channel.with_open_bin (Filename.concat dir f) In_channel.input_all)) (Array.to_list (Sys.readdir dir))
      | None -> ());
    0 in
  let result, calls = run_raw ~exit_codes:read_stage
    (fun () -> Dispatcher.install_edge_logging_component env Edge_sender) in
  let file name = Option.value ~default:"" (Hashtbl.find_opt staged name) in
  let index p = List.find_index p calls in
  let rendered_rsync = index (fun (r : Proc.request) -> r.prog = "rsync"
    && List.exists (fun a -> Filename.basename a = "edge" && not (String.ends_with ~suffix:"/" a)) r.args) in
  let installer = index (fun (r : Proc.request) ->
    r.prog = "ssh" && contains ~needle:"/edge/03-logging" (String.concat " " r.args)) in
  check "edge logging: the sender's config and receiver rendered from the logs app"
    (result = Ok ()
     && contains ~needle:{|"10.20.0.20"|} (file "syslog-ng-victoria.conf")
     && not (contains ~needle:"__LOGS" (file "syslog-ng-victoria.conf"))
     && file "logging-receiver" = "10.20.0.20 29514\n");
  check "edge logging: staged before 03-logging runs"
    (match rendered_rsync, installer with Some r, Some i -> r < i | _ -> false)

let () =
  if !failures > 0 then begin
    Printf.printf "%d assertion(s) failed\n" !failures;
    exit 1
  end
  else print_endline "all assertions passed"
