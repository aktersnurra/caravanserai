(* serai up orchestration against the process mock: what runs, in which
   order, and what never runs before the operator confirms. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let write path value = Out_channel.with_open_bin path (fun c -> output_string c value)
let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
let mentions needle (r : Proc.request) = List.exists (contains needle) (r.prog :: r.args)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let commit = String.make 40 'c'
let current = String.make 64 'e'

let () =
  let fixture = Filename.temp_dir "serai-up" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
    let base_bytes = "synthetic base archive" in
    let topology = Topology.of_sexp (Sexplib.Sexp.of_string (Printf.sprintf
      {|((hosts ((compute (os freebsd) (ssh compute) (network (subnet 10.20.0.0/24) (gateway 10.20.0.1) (guest_bridge 10.20.0.254))
          (build (ip 10.20.0.11) (base (url https://example.invalid/base.txz) (sha256 %s))))
         (edge (os linux) (ssh edge))))
        (jails ((hello compute) (counter compute) (logs compute)))
        (guests ((ledger (host compute) (via compute)))) (edge edge)
        (proxy (hello counter logs ledger)))|} (sha256 base_bytes))) in
    let cache = Filename.concat fixture "cache" and store = Filename.concat fixture "store" in
    List.iter (fun dir -> Unix.mkdir dir 0o700) [ cache; store; Filename.concat cache "base" ];
    write (Filename.concat cache ("base/" ^ sha256 base_bytes ^ ".txz")) base_bytes;
    let env ~confirm : Dispatcher.env = {
      layout = d.layout; topology = Some topology;
      compute_target = "compute"; edge_target = "edge"; remote_stage = "/tmp/serai-up-test";
      ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl"; config = d.apps;
      endpoints = d.endpoints; edge = d.edge; edge_ts_ip = None; edge_peer_match = None;
      caddy_force_build = false; confirm; operator = "test"; lock_token = "up-test";
      jj_bin = "jj"; now_utc = (fun () -> "2026-10-23T00:00:00Z"); guests = d.guests;
      ops_control_path = "/tmp/test-%C"; ssh_multiplex = false; source_checkout_override = None } in
    (* What the compute host answers to a test-jail probe, and to the live jail's. *)
    let probe = ref "" in
    let live_ready = "jail-probe-root: present\njail-probe-running: hello 10.20.0.2\n\
                      jail-probe-configured: hello 10.20.0.2\njail-test-env: root:hello:640\n" in
    let live_probe = ref live_ready in
    let outputs (r : Proc.request) =
      if mentions "jail-test-existing" r then !probe
      else if mentions "jail-probe-root" r then !live_probe
      else if r.prog = "jj" && mentions "/sources/" r then commit ^ "\n"
      else if r.prog = "jj" then String.make 40 'a' ^ " zzzz published\n"
      else if mentions "release_bin=" r then current ^ "\n"
      else "" in
    let run ?rehearse_ip ~confirm app =
      let target = Option.map (fun ip -> Dispatcher.Rehearse ip) rehearse_ip in
      let mock = Proc.Mock.create ~outputs () in
      let result =
        try Ok (Proc.Mock.run mock (fun () ->
          Dispatcher.up ?target (env ~confirm) app ~revision:"main" ~cache ~store))
        with Failure message -> Error message in
      result, Proc.Mock.calls mock in

    let result, calls = run ~confirm:(fun _ -> true) "logs" in
    check "an app without declared inputs is refused before any process runs"
      (Result.is_error result && calls = []);

    let asked = ref [] in
    let result, calls = run ~confirm:(fun q -> asked := q :: !asked; false) "hello" in
    check "declining the plan stops with nothing applied" (result = Error "up: not applied");
    check "exactly one question is asked" (List.length !asked = 1);
    check "the source mirror is fetched before the plan"
      (List.exists (fun r -> r.Proc.prog = "jj" && List.mem "clone" r.args) calls);
    check "nothing but the read-only jail probe reaches a host before confirmation"
      (List.for_all (fun (r : Proc.request) ->
           (r.prog <> "ssh" || mentions "jail-probe-root" r) && r.prog <> "rsync") calls);

    (* Store an artifact for exactly this commit and recipe: up must reuse it. *)
    let hello = Option.get (App_config.find d.apps "hello") in
    let packages, release_name = match hello.strategy with
      | Strategy_config.Freebsd_native_elixir s -> s.packages, s.release_name
      | _ -> assert false in
    let recipe = Result.get_ok (Artifact_recipe.stage ~lib_dir:(Layout.lib_dir d.layout)
      ~out:(Filename.concat fixture "recipe") ~base_sha256:(sha256 base_bytes) ~release_name ~packages) in
    let archive = Filename.concat fixture "release.tar" in
    write archive "release bytes";
    let manifest = Result.get_ok (Artifact_manifest.create ~name:"hello" ~source_commit:commit
      ~target_abi:"FreeBSD:15:amd64"
      ~dependencies:[ Artifact_manifest.{ name = "pkg"; version = "2.7.5"; sha256 = sha256 "pkg" } ]
      ~recipe_sha256:recipe.sha256 ~release_name
      ~archive_sha256:(sha256 "release bytes")) in
    let identity = Result.get_ok (Artifact_store.publish ~root:store ~manifest ~archive) |> ignore;
      Artifact_manifest.identity manifest in
    let result, calls = run ~confirm:(fun _ -> true) "hello" in
    if Result.is_error result then print_endline (match result with Error m -> m | Ok () -> "");
    check "a confirmed run with a stored artifact succeeds" (result = Ok ());
    check "the stored artifact is reused, not rebuilt"
      (not (List.exists (mentions "artifact_build_jail.sh") calls));
    let index predicate =
      let rec go i = function [] -> None | r :: rest -> if predicate r then Some i else go (i + 1) rest in
      go 0 calls in
    (match index (mentions identity), index (mentions "01-pf-rules"), index (fun r -> r.prog = "curl") with
     | Some apply, Some edge, Some public ->
         check "the release is applied, then the edge, then the public check" (apply < edge && edge < public)
     | _ -> check "every step ran" false);
    check "hello upgrades through the generic activation, not a pointer upgrade"
      (List.exists (fun r -> mentions "artifact_apply.sh" r && mentions identity r) calls
       && not (List.exists (mentions "release_bin=") calls));
    check "the release is applied with the source commit it was built from"
      (List.exists (fun r -> mentions "artifact_apply.sh" r && mentions identity r && mentions commit r) calls);
    check "the public check uses the app's hostname"
      (List.exists (fun (r : Proc.request) -> r.prog = "curl"
         && List.mem "https://hello.example.org/" r.args) calls);

    (* up_run: every step's outcome, as up --json reports it. *)
    let up_run ?exit_codes () =
      let mock = Proc.Mock.create ?exit_codes ~outputs () in
      Proc.Mock.run mock (fun () ->
        Dispatcher.up_run (env ~confirm:(fun _ -> true)) "hello" ~revision:"main" ~cache ~store) in
    let statuses (outcome : Dispatcher.up_outcome) =
      List.map (fun (step, status) -> Dispatcher.step_name step, (match status with
        | Dispatcher.Done -> "done" | Skipped -> "skipped" | Not_run -> "not_run" | Failed _ -> "failed"))
        outcome.steps in
    let _, outcome = up_run () in
    check "a reused release: jail and build skipped, then release, edge and check done"
      (outcome.result = Dispatcher.Deployed identity
       && statuses outcome = [ "jail", "skipped"; "build", "skipped"; "release", "done"; "edge", "done"; "check", "done" ]);
    let _, outcome = up_run ~exit_codes:(fun r -> if r.Proc.prog = "curl" then 22 else 0) () in
    check "a failed public check is the check step's, after the release and edge are done"
      ((match outcome.result with Dispatcher.Step_failed (Dispatcher.Check, m) -> contains "curl exit 22" m | _ -> false)
       && statuses outcome = [ "jail", "skipped"; "build", "skipped"; "release", "done"; "edge", "done"; "check", "failed" ]);

    (* Update: the existing jail only, never the edge. *)
    let touches_edge (r : Proc.request) =
      List.exists (fun a -> a = "edge" || String.starts_with ~prefix:"edge:" a) r.args
      || mentions "01-pf-rules" r || mentions "01-headscale-policy" r || mentions "02-caddy" r in
    let update ?(local_source : string option) () =
      let mock = Proc.Mock.create ~outputs () in
      let result =
        try Ok (Proc.Mock.run mock (fun () ->
          Dispatcher.up_run ?local_source ~target:Dispatcher.Update (env ~confirm:(fun _ -> true))
            "hello" ~revision:"main" ~cache ~store))
        with Failure message -> Error message in
      result, Proc.Mock.calls mock in
    (match update () with
     | Ok (_, outcome), calls ->
         check "an update releases into the ready jail, skips the edge and checks the public URL"
           (outcome.result = Dispatcher.Deployed identity
            && statuses outcome = [ "jail", "skipped"; "build", "skipped"; "release", "done"; "edge", "skipped"; "check", "done" ]);
         check "an update sends nothing to the edge host and runs no edge script"
           (not (List.exists touches_edge calls));
         check "an update still checks the public URL"
           (List.exists (fun (r : Proc.request) -> r.prog = "curl"
              && List.mem "https://hello.example.org/" r.args) calls)
     | Error message, _ -> check ("an update of a ready jail succeeds: " ^ message) false);
    let changes_host calls =
      List.exists (fun (r : Proc.request) ->
          r.prog = "rsync" || (r.prog = "ssh" && not (mentions "jail-probe-root" r))) calls in
    live_probe := "jail-probe-root: absent\njail-probe-running: counter 10.20.0.3\njail-test-env: absent\n";
    (match update () with
     | Error message, calls ->
         check "an update never creates a jail" (contains "update: hello has no jail" message);
         check "and changes nothing on the host" (not (changes_host calls))
     | Ok _, _ -> check "an update of an absent jail is refused" false);
    live_probe := "jail-probe-root: present\njail-probe-configured: hello 10.20.0.2\njail-test-env: absent\n";
    (match update () with
     | Error message, calls ->
         check "an update refuses a jail without its env, naming the file"
           (String.starts_with ~prefix:"update: " message && contains "/jails/hello/etc/hello/env" message);
         check "and changes nothing on the host" (not (changes_host calls))
     | Ok _, _ -> check "an update of a jail without its env is refused" false);
    live_probe := live_ready;
    (match update ~local_source:fixture () with
     | Error _, calls -> check "an update builds only pushed commits, never a local checkout" (calls = [])
     | Ok _, _ -> check "an update from a local checkout is refused" false);

    (* --plan: the same decisions, nothing asked or applied. *)
    let mock = Proc.Mock.create ~outputs () in
    let plan = Proc.Mock.run mock (fun () ->
      Dispatcher.up_plan (env ~confirm:(fun _ -> failwith "asked")) "hello" ~revision:"main" ~cache ~store) in
    check "--plan reuses the stored release for a ready jail"
      (plan.release = Dispatcher.Reuse identity && plan.jail = Dispatcher.Jail_ready && plan.commit = commit);
    check "--plan changes no host"
      (List.for_all (fun (r : Proc.request) ->
           (r.prog <> "ssh" || mentions "jail-probe-root" r) && r.prog <> "rsync" && r.prog <> "curl")
         (Proc.Mock.calls mock));

    (* A jail without its env is refused before anything is asked. *)
    live_probe := "jail-probe-root: present\njail-probe-configured: hello 10.20.0.2\njail-test-env: absent\n";
    let asked = ref 0 in
    let result, calls = run ~confirm:(fun _ -> incr asked; true) "hello" in
    check "a jail without its env is refused before the question, naming the file"
      (match result with Error m -> contains "/jails/hello/etc/hello/env" m | Ok () -> false);
    check "and nothing is asked or changed" (!asked = 0 && not (List.exists (fun r -> r.Proc.prog = "rsync") calls));

    (* An address another jail holds, declared or not, is refused. *)
    live_probe := "jail-probe-root: absent\njail-probe-running: logs 10.20.0.2\njail-test-env: absent\n";
    let result, calls = run ~confirm:(fun _ -> true) "hello" in
    check "an address another jail holds is refused, naming the jail"
      (match result with Error m -> contains "held by jail logs" m | Ok () -> false);
    check "and nothing is changed" (not (List.exists (fun r -> r.Proc.prog = "rsync") calls));

    (* A new app's jail: created on confirmation, then up stops for its env. *)
    live_probe := "jail-probe-root: absent\njail-probe-running: counter 10.20.0.3\njail-test-env: absent\n";
    let asked = ref [] in
    let result, calls = run ~confirm:(fun q -> asked := q :: !asked; true) "hello" in
    check "a missing jail is the question" (!asked = [ "create jail hello at 10.20.0.2?" ]);
    check "a missing jail is created by running its rendered jail script"
      (List.exists (mentions "compute/apps/hello/jail") calls
       && List.exists (fun r -> r.Proc.prog = "ssh" && mentions "doas sh /tmp/serai-up-test/compute/apps/hello/jail" r) calls);
    check "then up stops for the env, with nothing built or applied"
      ((match result with Error m -> contains "created jail hello" m && contains "env.template" m | Ok () -> false)
       && not (List.exists (mentions "artifact_apply.sh") calls));
    let _, outcome = up_run () in
    check "a created jail stops for the operator; nothing after it runs"
      ((match outcome.result with Dispatcher.Stopped_for_env m -> contains "env.template" m | _ -> false)
       && statuses outcome = [ "jail", "done"; "build", "not_run"; "release", "not_run"; "edge", "not_run"; "check", "not_run" ]);
    live_probe := live_ready;

    (* Rehearsal: the same release into hellotest at a test ip. *)
    let rehearse = run ~rehearse_ip:"10.20.0.250" in
    let result, calls = run ~rehearse_ip:"10.20.0.2" ~confirm:(fun _ -> true) "hello" in
    check "rehearsal at a declared ip is refused before any process runs"
      (Result.is_error result && calls = []);

    probe := "jail-test-existing: ip 10.20.0.250\njail-test-env: absent\n";
    let asked = ref 0 in
    let result, calls = rehearse ~confirm:(fun _ -> incr asked; true) "hello" in
    check "a test jail without its env is refused before the plan, saying how to write it"
      (match result with
       | Error message -> contains "/jails/hellotest/etc/hello/env" message
                          && contains "apps/hello/env.template" message && not (contains "compute/apps/hello/env.template" message)
       | Ok () -> false);
    check "nothing is asked or applied without the env"
      (!asked = 0 && not (List.exists (mentions "artifact_apply.sh") calls));

    probe := "jail-test-existing: absent\njail-test-env: absent\n";
    let asked = ref [] in
    let result, calls = rehearse ~confirm:(fun q -> asked := q :: !asked; true) "hello" in
    check "a missing test jail is created from the generated script, then the run stops for its env"
      (match result with
       | Error message -> contains "up: created hellotest" message && contains "env.template" message
       | Ok () -> false);
    check "creating the test jail is confirmed on its own"
      (List.exists (contains "create test jail hellotest") !asked);
    check "nothing is applied in the run that creates the test jail"
      (List.exists (mentions "/jail-test/hellotest/jail") calls
       && not (List.exists (mentions "artifact_apply.sh") calls));

    probe := "jail-test-existing: ip 10.20.0.250\njail-test-env: root:hello:640\n";
    let result, calls = rehearse ~confirm:(fun _ -> true) "hello" in
    if Result.is_error result then print_endline (match result with Error m -> m | Ok () -> "");
    check "a rehearsal with its jail and env in place succeeds" (result = Ok ());
    check "the rehearsal applies into hellotest, checking the test ip, migrating, with the app's in-jail name"
      (List.exists (fun r -> mentions identity r && mentions "'\\''hellotest'\\''" r
                             && mentions "http://10.20.0.250:4000/" r
                             && mentions "'\\''migrate'\\'' '\\''hello'\\''" r) calls);
    check "a rehearsal never reads the live release, touches the edge or checks the public URL"
      (not (List.exists (fun r -> mentions "release_bin=" r || mentions "01-pf-rules" r
                                  || r.Proc.prog = "curl") calls)))
