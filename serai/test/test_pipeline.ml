(* The DSL's own tests: parsing sexp into steps, registry fallback from
   per-app pipelines to the shared defaults, evaluation order, and that a
   failing step still short-circuits a sequence the way bash's `set -e`
   does -- for free, since Sequence is just List.iter over calls that raise. *)

open Serai

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

(* jj answers with a revision; each lock acquire with "no record yet" *)
let fixture_outputs (r : Proc.request) =
  if r.prog = "jj" then "c0ffee00c0ffee00 changeid1 published\n"
  else if contains ~needle:{|mkdir "$lock"|} (String.concat " " r.args) then Remote_lock.no_record_marker ^ "\n"
  else ""

let sexp_of_string s = Sexplib.Sexp.of_string s

let make_app ~name ~ip ~hooks : App_config.t =
  let endpoint = Test_declaration.endpoint ~name ~ip ~hostname:(name ^ ".example.org")
      ~tailnet_ports:[ { Network_endpoint.port_name = "http"; port = 4000 } ] ~operator_ports:[] in
  Test_declaration.app ~endpoint ~hooks

let config : App_config.t list =
  [
    make_app ~name:"drill" ~ip:"10.40.0.2" ~hooks:[ Bootstrap; Deploy; Check ];
    make_app ~name:"garage" ~ip:"10.40.0.4" ~hooks:[ Bootstrap; Check ];
  ]

let registry : Pipeline.t =
  {
    default =
      [
        ("rollout", Pipeline.(Sequence [ Prefer (Deploy, Hook Bootstrap); Hook Check ]));
        ( "rollout-edge",
          Pipeline.(Sequence [ Prefer (Deploy, Hook Bootstrap); Edge; Hook Check ]) );
      ];
    apps =
      [
        ( "drill",
          [
            ( "rollout-with-videos",
              Pipeline.(
                Sequence
                  [
                    Prefer (Deploy, Hook Bootstrap);
                    Hook Check;
                    Script ("seed-videos", [ Compute_target ]);
                  ]) );
          ] );
      ];
  }

(* The fixture template tree (fixtures/edge_root/edge/caddy) references
   __DEMO_*__, so edge tests render against a single "demo" endpoint. *)
let fixture_endpoint : Network_endpoint.t =
  Test_declaration.endpoint ~name:"demo" ~ip:"10.0.0.7" ~hostname:"demo.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4000 }; { port_name = "video"; port = 4002 } ]
    ~operator_ports:[ { port_name = "ssh"; port = 22 } ]

let make_env () : Dispatcher.env =
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
    endpoints = Test_declaration.endpoints [ fixture_endpoint ];
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

let run ?exit_codes f =
  let mock = Proc.Mock.create ?exit_codes ~outputs:fixture_outputs () in
  let result = try Ok (Proc.Mock.run mock f) with Failure msg -> Error msg in
  (result, without_bookkeeping (Proc.Mock.calls mock))

let progs calls = List.map (fun (r : Proc.request) -> r.prog) calls

(* --- parsing --- *)

let () =
  check "parse: a bare hook name is a Hook step"
    (Pipeline.step_of_sexp (sexp_of_string "check") = Pipeline.Hook App_config.Check);
  check "parse: edge is its own step, not an App_config.hook"
    (Pipeline.step_of_sexp (sexp_of_string "edge") = Pipeline.Edge);
  check "parse: sequence collects steps in order"
    (Pipeline.step_of_sexp (sexp_of_string "(sequence bootstrap check)")
    = Pipeline.Sequence [ Hook Bootstrap; Hook Check ]);
  check "parse: prefer carries its hook and the fallback step"
    (Pipeline.step_of_sexp (sexp_of_string "(prefer deploy bootstrap)")
    = Pipeline.Prefer (Deploy, Hook Bootstrap));
  check "parse: script carries its name and resolves $COMPUTE_TARGET/$EDGE_TARGET"
    (Pipeline.step_of_sexp (sexp_of_string "(script seed-videos $COMPUTE_TARGET literal-arg)")
    = Pipeline.Script ("seed-videos", [ Compute_target; Literal "literal-arg" ]));
  check "parse: an unknown hook name is a load-time error, not a silent no-op"
    (match Pipeline.step_of_sexp (sexp_of_string "bogus-hook") with
    | exception Sexplib.Conv.Of_sexp_error _ -> true
    | _ -> false)

(* --- registry lookup: per-app overrides fall back to shared defaults --- *)

let () =
  check "registry: an app with no override still sees the default pipeline"
    (Pipeline.find registry ~app:"garage" ~name:"rollout" <> None);
  check "registry: an app-specific pipeline is found by name"
    (Pipeline.find registry ~app:"drill" ~name:"rollout-with-videos" <> None);
  check "registry: an app-specific pipeline isn't visible to other apps"
    (Pipeline.find registry ~app:"garage" ~name:"rollout-with-videos" = None);
  check "registry: an unknown pipeline name resolves to nothing"
    (Pipeline.find registry ~app:"drill" ~name:"no-such-pipeline" = None)

(* check runs _lib/check.sh's check_app, not a per-app hook file. *)
let is_check (r : Proc.request) =
  r.prog = "sh" && List.exists (contains ~needle:"_lib/check.sh") r.args

(* --- evaluation: default rollout picks deploy vs bootstrap per app config --- *)

let () =
  let env = make_env () in
  let _, calls = run (fun () -> Pipeline.run env registry "drill" "rollout") in
  check "eval: deploy-capable app runs deploy then check"
    (match calls with
    | [ deploy_call; check_call ] ->
        contains ~needle:"deploy" deploy_call.prog && is_check check_call
    | _ -> false)

let () =
  let env = make_env () in
  let _, calls = run (fun () -> Pipeline.run env registry "garage" "rollout") in
  check "eval: bootstrap-only app bootstraps (ssh, rsync, rsync, ssh) then checks"
    (match calls with
    | [ a; b; j; c; check_call ] ->
        progs [ a; b; j; c ] = [ "ssh"; "rsync"; "rsync"; "ssh" ] && is_check check_call
    | _ -> false)

let () =
  let env = make_env () in
  let _, calls = run (fun () -> Pipeline.run env registry "garage" "rollout-edge") in
  check "eval: rollout-edge runs edge between bootstrap and check, not after"
    (match calls with
    | [ a; b; j; c; e1; e2; e3; e4; e5; e6; e7; e8; e9; check_call ] ->
        progs [ a; b; j; c ] = [ "ssh"; "rsync"; "rsync"; "ssh" ]
        && progs [ e1; e2; e3; e4; e5; e6; e7; e8; e9 ]
           = [ "ssh"; "rsync"; "ssh"; "rsync"; "rsync"; "rsync"; "ssh"; "ssh"; "ssh" ]
        && is_check check_call
    | _ -> false)

let () =
  let env = make_env () in
  let _, calls = run (fun () -> Pipeline.run env registry "drill" "rollout-with-videos") in
  check "eval: drill's extra pipeline runs deploy, check, then seed-videos with the target"
    (match calls with
    | [ deploy_call; check_call; script_call ] ->
        contains ~needle:"deploy" deploy_call.prog
        && is_check check_call
        && contains ~needle:"edge_root/apps/drill/seed-videos" script_call.prog
        && script_call.args = [ "compute-test" ]
    | _ -> false)

(* --- failure inside a sequence stops it early, same as bash's set -e --- *)

let () =
  let env = make_env () in
  let exit_codes (r : Proc.request) = if contains ~needle:"deploy" r.prog then 1 else 0 in
  let result, calls = run ~exit_codes (fun () -> Pipeline.run env registry "drill" "rollout") in
  check "eval: a failing deploy step stops the sequence before check runs"
    (match result, calls with Error _, [ _deploy_only ] -> true | _ -> false)

let () =
  let env = make_env () in
  let result, calls = run (fun () -> Pipeline.run env registry "drill" "no-such-pipeline") in
  check "eval: running an unknown pipeline fails without spawning anything"
    (result = Error "unknown pipeline" && calls = [])

(* The example's logs rollout must not leave the guest, edge host or VMUI
   installation to operator-run shell commands. Follow the requests, not
   just the sexp shape. *)
let logging_registry = Pipeline.load (Layout.pipelines (Repo_root.example ()))
let logging_env () =
  let env = make_env () in
  let logs_endpoint = Test_declaration.endpoint ~name:"logs" ~ip:"10.40.0.20"
      ~hostname:"logs.example.org"
      ~tailnet_ports:[ { port_name = "http"; port = 9428 }; { port_name = "syslog"; port = 29514 } ]
      ~operator_ports:[] in
  let ledger = Test_declaration.guest ~login_user:"ledger"
      (Test_declaration.endpoint ~name:"ledger" ~ip:"10.40.0.10"
         ~hostname:"ledger.example.org" ~tailnet_ports:[] ~operator_ports:[]) in
  let config = Test_declaration.app ~endpoint:logs_endpoint ~hooks:[ Bootstrap; Check ] :: env.config in
  (* The real engine, for the edge host sender's template; the edge fixture,
     plus a template for the proxied logs jail. *)
  { env with layout = Layout.v ~engine:(Repo_root.find ()) ~config:"fixtures/logging_root"; config;
             (* The edge's workloads are placed and proxied; the logs jail's
                host runs the relay, beside the guest. *)
             topology = Some (Test_declaration.topology ~proxy:[ "demo"; "logs" ]
               ~jails:("demo" :: App_config.names config) ~guests:[ "ledger" ] ());
             guests = [ ledger ];
             endpoints = Test_declaration.endpoints [ fixture_endpoint; logs_endpoint ] }

let () =
  check "the edge renders the logs jail's private ACL/PF routes"
    (match Dispatcher.render_edge (logging_env ()) with
    | Error _ -> false
    | Ok files ->
        List.exists (fun (_, body) -> contains ~needle:"10.40.0.20:29514" body) files)

let call_contains needle (r : Proc.request) =
  contains ~needle r.prog || contains ~needle (String.concat " " r.args)

let first_index needle calls =
  List.find_map
    (fun (index, call) -> if call_contains needle call then Some index else None)
    (List.mapi (fun index call -> (index, call)) calls)

let ordered calls needles =
  match List.map (fun needle -> first_index needle calls) needles with
  | [] -> true
  | positions ->
      List.for_all Option.is_some positions
      && let indices = List.map Option.get positions in
         List.sort compare indices = indices
         && List.length (List.sort_uniq compare indices) = List.length indices

let () =
  let env = logging_env () in
  let result, calls = run (fun () -> Pipeline.run env logging_registry "logs" "rollout-edge") in
  let stages_targets (r : Proc.request) =
    r.prog = "rsync"
    && List.exists (String.ends_with ~suffix:"/logs") r.args
    && List.exists (String.ends_with ~suffix:":/tmp/serai-stage-test/compute/apps/") r.args in
  let targets_staged =
    List.find_map (fun (i, r) -> if stages_targets r then Some i else None)
      (List.mapi (fun i r -> (i, r)) calls) in
  check "logging install stages the typed target manifest before invoking the compute host installer"
    (match targets_staged,
           first_index "/compute/apps/_lib/logging/bootstrap.sh" calls with
     | Some staged, Some installed -> staged < installed
     | _ -> false);
  check "logs rollout-edge: receiver, compute host senders, edge, guest, edge host sender, VMUI auth, then checks"
    (result = Ok ()
     && ordered calls [ "/compute/apps/logs/jail"; "/compute/apps/_lib/logging/bootstrap.sh";
                         "PF_DIFF_ONLY=1"; "/compute/guests/ledger/logging"; "/edge/03-logging";
                         "/edge/04-vmui-auth"; "_lib/check.sh"; "logging_root/apps/logs/check-forwarding" ]);
  check "logs rollout-edge: the guest stages its own files and runs as root through the compute host"
    (List.exists (fun (r : Proc.request) -> r.prog = "rsync"
      && call_contains "logging_root/guests/ledger" r && call_contains "-J compute-test" r) calls
     && List.exists (fun (r : Proc.request) -> r.prog = "ssh"
      && call_contains "su -c" r && call_contains "/compute/guests/ledger/logging" r) calls);
  check "logs rollout-edge: edge host installers are staged and executed under sudo"
    (List.exists (fun (r : Proc.request) -> r.prog = "rsync"
      && call_contains "/edge/" r && call_contains "edge-test:" r) calls
     && List.for_all (fun script -> List.exists (fun (r : Proc.request) ->
        r.prog = "ssh" && call_contains ("sudo bash /tmp/serai-stage-test/edge/" ^ script) r) calls)
        [ "03-logging"; "04-vmui-auth" ])

let () =
  let result, calls = run (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "forwarding") in
  check "logs forwarding: the compute host installer then the forwarding check, nothing else"
    (result = Ok ()
     && ordered calls [ "/compute/apps/_lib/logging/bootstrap.sh"; "logging_root/apps/logs/check-forwarding" ]
     && first_index "/compute/apps/logs/jail" calls = None
     && first_index "PF_DIFF_ONLY=1" calls = None
     && first_index "/compute/guests/ledger/logging" calls = None
     && first_index "/edge/" calls = None)

let () =
  let result, calls = run (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "recover") in
  let recover_index script calls =
    List.find_map (fun (i, request) ->
      if call_contains (script ^ " --recover") request &&
         not (call_contains (script ^ " --recover-check") request) then Some i else None)
      (List.mapi (fun i request -> (i, request)) calls) in
  let positions =
    [ first_index "/compute/guests/ledger/logging --recover-check" calls;
      first_index "/edge/03-logging --recover-check" calls;
      first_index "/edge/04-vmui-auth --recover-check" calls;
      recover_index "/compute/guests/ledger/logging" calls;
      recover_index "/edge/03-logging" calls;
      recover_index "/edge/04-vmui-auth" calls;
      first_index "_lib/check.sh" calls;
      first_index "/compute/guests/ledger/logging --recover-health" calls;
      first_index "/edge/03-logging --recover-health" calls;
      first_index "/edge/04-vmui-auth --recover-health" calls ] in
  check "logs recover: all three exact-match preflights precede any repair"
    (result = Ok () && List.for_all Option.is_some positions
     && let indices = List.map Option.get positions in
        List.sort compare indices = indices
        && List.length (List.sort_uniq compare indices) = List.length indices
     && first_index "/compute/apps/logs/jail" calls = None
     && first_index "PF_DIFF_ONLY=1" calls = None);
  let failed (r : Proc.request) =
    if call_contains "/edge/04-vmui-auth --recover-check" r then 1 else 0 in
  let result, calls = run ~exit_codes:failed
    (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "recover") in
  check "logs recover: failed preflight prevents all repairs"
    (Result.is_error result && first_index "/edge/04-vmui-auth --recover-check" calls <> None
     && recover_index "/compute/guests/ledger/logging" calls = None);
  let failed (r : Proc.request) =
    if call_contains "/compute/guests/ledger/logging --recover-health" r then 1 else 0 in
  let result, calls = run ~exit_codes:failed
    (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "recover") in
  check "logs recover: failed final sender check aborts the remaining checks"
    (Result.is_error result
     && first_index "/edge/03-logging --recover-health" calls = None);
  let result, calls = run
    (fun () -> Pipeline.run (logging_env ()) logging_registry "garage" "recover") in
  check "logs recover: not available to unrelated apps"
    (Result.is_error result && calls = [])

let () =
  let stop_at needle (r : Proc.request) = if call_contains needle r then 1 else 0 in
  List.iter (fun (failed, forbidden) ->
    let result, calls = run ~exit_codes:(stop_at failed)
      (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "rollout-edge") in
    check ("logs rollout-edge: failure at " ^ failed ^ " prevents " ^ forbidden)
      (Result.is_error result && first_index failed calls <> None
       && first_index forbidden calls = None))
    [ ("/compute/apps/logs/jail", "/compute/apps/_lib/logging/bootstrap.sh");
      ("/compute/apps/_lib/logging/bootstrap.sh", "PF_DIFF_ONLY=1");
      ("PF_DIFF_ONLY=1", "/compute/guests/ledger/logging");
      ("/compute/guests/ledger/logging", "/edge/03-logging");
      ("/edge/03-logging", "/edge/04-vmui-auth");
      ("/edge/04-vmui-auth", "_lib/check.sh");
      ("_lib/check.sh", "logging_root/apps/logs/check-forwarding") ]

(* The compute host's senders converge by default; only compute-logging-replace passes
   the installer --replace, and the logs app names it in its own pipeline. *)
let () =
  let step text = Pipeline.step_of_sexp (sexp_of_string text) in
  check "parse: compute-logging converges, compute-logging-replace replaces"
    (step "compute-logging" = Pipeline.Logging (Compute_sender Converge, Normal_logging)
     && step "compute-logging-replace" = Pipeline.Logging (Compute_sender Replace, Normal_logging));
  let installer replace calls = List.exists (fun (r : Proc.request) -> r.prog = "ssh"
    && call_contains "/compute/apps/_lib/logging/bootstrap.sh" r
    && call_contains "--replace" r = replace) calls in
  let result, calls = run (fun () -> Pipeline.run (logging_env ()) logging_registry "logs" "forwarding") in
  check "eval: forwarding runs the installer without --replace" (result = Ok () && installer false calls);
  let result, calls = run (fun () ->
    Pipeline.run (logging_env ()) logging_registry "logs" "replace-forwarding") in
  check "eval: replace-forwarding runs the installer with --replace, then the forwarding check"
    (result = Ok () && installer true calls
     && ordered calls [ "/compute/apps/_lib/logging/bootstrap.sh logs --replace"; "logging_root/apps/logs/check-forwarding" ])

(* A guest's log sender is named by the step, not built in: any declared
   guest's own logging hook, and an undeclared one refused before anything runs. *)
let () =
  let step text = Pipeline.step_of_sexp (sexp_of_string text) in
  check "parse: (guest-logging g) installs that guest's sender"
    (step "(guest-logging ledger)" = Pipeline.Logging (Guest_sender "ledger", Normal_logging));
  check "parse: the guest recovery steps name their guest"
    (step "(recover-guest-check ledger)" = Pipeline.Logging (Guest_sender "ledger", Recovery_check)
     && step "(recover-guest ledger)" = Pipeline.Logging (Guest_sender "ledger", Recovery_apply)
     && step "(recover-guest-health ledger)" = Pipeline.Logging (Guest_sender "ledger", Recovery_health));
  check "parse: no step is named after a particular guest"
    (List.for_all (fun text -> match step text with
       | exception Sexplib.Conv.Of_sexp_error _ -> true | _ -> false)
      [ "vault-logging"; "recover-vault"; "(guest-logging)"; "(guest-logging a b)" ]);
  let ledger = Test_declaration.guest ~login_user:"builder"
      (Test_declaration.endpoint ~name:"ledger" ~ip:"10.40.0.12"
         ~hostname:"ledger.example" ~tailnet_ports:[] ~operator_ports:[]) in
  let env = logging_env () in
  let env = { env with guests = [ ledger ];
                       topology = Some (Test_declaration.topology ~proxy:[ "demo"; "logs" ]
                         ~jails:("demo" :: App_config.names env.config) ~guests:[ "ledger" ] ()) } in
  let registry text = Pipeline.of_sexp (sexp_of_string
    (Printf.sprintf "((default ()) (apps ((logs ((p %s))))))" text)) in
  let result, calls = run (fun () -> Pipeline.run env (registry "(guest-logging ledger)") "logs" "p") in
  check "eval: guest-logging runs the named guest's own logging hook as root"
    (result = Ok () && List.exists (fun (r : Proc.request) -> r.prog = "ssh"
       && call_contains "su -c" r && call_contains "/compute/guests/ledger/logging" r) calls);
  let result, calls = run (fun () ->
    Pipeline.run env (registry "(sequence compute-logging (guest-logging nosuch))") "logs" "p") in
  check "eval: a pipeline naming an undeclared guest fails before spawning anything"
    (Result.is_error result && calls = [])

let () =
  if !failures > 0 then begin
    Printf.printf "%d assertion(s) failed\n" !failures;
    exit 1
  end
  else print_endline "all assertions passed"
