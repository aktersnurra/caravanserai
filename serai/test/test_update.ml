(* serai update against the process mock: the example configuration as the
   staged snapshot, jj's answers faked per question, and a stored artifact
   so a deploy reuses it instead of building. *)
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

let desired = String.make 40 'd'
let older = String.make 40 'a'
let key = "2921DF701EE03394"
let config_url = "file:///configuration"
let active = String.make 64 'e'
let retained = String.make 64 '9'

let () =
  let fixture = Filename.temp_dir "serai-update" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let example = Repo_root.example () in
    let base_bytes = "synthetic base archive" in
    let topology = Topology.of_sexp (Sexplib.Sexp.of_string (Printf.sprintf
      {|((hosts ((compute (os freebsd) (ssh compute) (network (subnet 10.20.0.0/24) (gateway 10.20.0.1) (guest_bridge 10.20.0.254))
          (build (ip 10.20.0.11) (base (url https://example.invalid/base.txz) (sha256 %s))))
         (edge (os linux) (ssh edge))))
        (jails ((hello compute) (counter compute) (logs compute)))
        (guests ((ledger (host compute) (via compute)))) (edge edge)
        (proxy (hello counter logs ledger)))|} (sha256 base_bytes))) in
    let cache = Filename.concat fixture "cache" and store = Filename.concat fixture "store" in
    let state_dir = Filename.concat fixture "state" in
    List.iter (fun dir -> Unix.mkdir dir 0o700) [ cache; store; Filename.concat cache "base" ];
    write (Filename.concat cache ("base/" ^ sha256 base_bytes ^ ".txz")) base_bytes;

    (* The configuration's mirror is a real repository: the snapshot reads
       it with jj directly, not through Proc. Its staged tree is cached, a
       copy of the example, so nothing is exported. *)
    let sources = Filename.concat cache "sources" in
    Unix.mkdir sources 0o700;
    let mirror = Filename.concat sources Update.configuration_mirror in
    let jj args = Proc.live (fun () -> Proc.run_checked "jj" args) in
    jj [ "git"; "init"; mirror ];
    jj [ "-R"; mirror; "--config"; "signing.behavior=drop"; "commit"; "-m"; "configuration" ];
    let config_commit = match Proc.live (fun () ->
        Proc.capture "jj" [ "-R"; mirror; "log"; "--no-graph"; "-r"; "@-"; "-T"; "commit_id" ]) with
      | 0, id -> String.trim id | _ -> failwith "configuration fixture" in
    let snapshots = Filename.concat cache "configuration-snapshots" in
    Unix.mkdir snapshots 0o700;
    let tree = Filename.concat snapshots config_commit in
    Proc.live (fun () -> Proc.run_checked "cp" [ "-R"; Layout.config example; tree ]);
    let hello_sexp = Filename.concat tree "apps/hello/app.sexp" in
    let with_migrate = In_channel.with_open_bin hello_sexp In_channel.input_all in
    let without_migrate =
      String.split_on_char '\n' with_migrate
      |> List.filter (fun line -> not (contains "(migrate" line)) |> String.concat "\n" in

    (* A stored artifact for each commit the runs deploy, so up reuses it. *)
    let d = Result.get_ok (Declaration.load ~layout:example) in
    let hello = Option.get (App_config.find d.apps "hello") in
    let packages, release_name = match hello.strategy with
      | Strategy_config.Freebsd_native_elixir s -> s.packages, s.release_name
      | _ -> assert false in
    let recipe = Result.get_ok (Artifact_recipe.stage ~lib_dir:(Layout.lib_dir example)
      ~out:(Filename.concat fixture "recipe") ~base_sha256:(sha256 base_bytes) ~release_name ~packages) in
    let archive = Filename.concat fixture "release.tar" in
    write archive "release bytes";
    let stored commit =
      let manifest = Result.get_ok (Artifact_manifest.create ~name:"hello" ~source_commit:commit
        ~target_abi:"FreeBSD:15:amd64"
        ~dependencies:[ Artifact_manifest.{ name = "pkg"; version = "2.7.5"; sha256 = sha256 "pkg" } ]
        ~recipe_sha256:recipe.sha256 ~release_name ~archive_sha256:(sha256 "release bytes")) in
      ignore (Result.get_ok (Artifact_store.publish ~root:store ~manifest ~archive));
      Artifact_manifest.identity manifest in
    let identity = stored desired in
    let failing = String.make 40 'c' and retried = String.make 40 '7' in
    ignore (stored failing); ignore (stored retried);

    let env_of_layout layout : Dispatcher.env =
      let d = Result.get_ok (Declaration.load ~layout) in
      { layout; topology = Some topology;
        compute_target = "compute"; edge_target = "edge"; remote_stage = "/tmp/serai-update-test";
        ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl"; config = d.apps;
        endpoints = d.endpoints; edge = d.edge; edge_ts_ip = None; edge_peer_match = None;
        caddy_force_build = false; confirm = (fun _ -> true); operator = "test"; lock_token = "update-test";
        jj_bin = "jj"; now_utc = (fun () -> "2026-10-31T00:00:00Z"); guests = d.guests;
        ops_control_path = "/tmp/test-%C"; ssh_multiplex = false; source_checkout_override = None } in
    let deps = { Update.jj_bin = "jj"; env_of_layout } in
    let paths = { Update.state_dir; cache; store; engine = Layout.engine example } in
    let config = { Update.config_url; config_bookmark = "master"; signers = [ key ];
                   gnupghome = Filename.concat fixture "gnupg" } in

    (* What jj, the jail probe and the release probe answer. *)
    let hello_deploy = ref (Some desired) in
    let signature_of = ref (fun _ -> "good " ^ key) in
    let descends = ref true in
    let deployed = ref older in
    let fail_release = ref false and switch_on_failure = ref false in
    let origins = Hashtbl.create 4 in
    Hashtbl.replace origins mirror config_url;
    let probe_answer () =
      Printf.sprintf "release-probe-active: .infra-releases/hello/%s\nrelease-probe-source: %s\n\
                      release-probe-previous: %s\n" active !deployed retained in
    let live_ready = "jail-probe-root: present\njail-probe-running: hello 10.20.0.2\n\
                      jail-probe-configured: hello 10.20.0.2\njail-test-env: root:hello:640\n" in
    let repository (r : Proc.request) =
      let rec after = function "-R" :: path :: _ -> Some path | _ :: rest -> after rest | [] -> None in
      after r.args in
    let outputs (r : Proc.request) =
      if r.prog = "jj" && List.mem "clone" r.args then begin
        (* A fake clone leaves a repository behind, as the real one does. *)
        let mirror = List.nth r.args (List.length r.args - 1) in
        Unix.mkdir mirror 0o700; Unix.mkdir (Filename.concat mirror ".jj") 0o700;
        Hashtbl.replace origins mirror (List.nth r.args (List.length r.args - 2));
        "" end
      else if r.prog = "jj" && List.mem "remote" r.args then
        (match repository r with
         | Some mirror -> "origin " ^ Option.value (Hashtbl.find_opt origins mirror) ~default:"" ^ "\n"
         | None -> "")
      else if r.prog = "jj" && mentions "remote_bookmarks(exact:\"master\"" r then config_commit ^ "\n"
      else if r.prog = "jj" && mentions "remote_bookmarks(exact:\"deploy\"" r then
        (match repository r with
         | Some mirror when Filename.basename mirror = "hello" ->
             Option.fold ~none:"" ~some:(fun c -> c ^ "\n") !hello_deploy
         | _ -> "")
      else if r.prog = "jj" && mentions "signature.status()" r then
        !signature_of (List.find (fun a -> String.length a = 40) r.args)
      else if r.prog = "jj" && mentions (older ^ " & ::") r then (if !descends then older ^ "\n" else "")
      else if r.prog = "jj" && mentions "/sources/" r then
        (* Source_mirror.resolve: the commit it was asked about, on the remote. *)
        (match List.find_opt (fun a -> String.length a > 40 && String.starts_with ~prefix:"(" a) r.args with
         | Some revset -> String.sub revset 1 40 ^ "\n"
         | None -> "")
      else if mentions "release-probe-active" r then probe_answer ()
      else if mentions "jail-probe-root" r then live_ready
      else "" in
    let exit_codes (r : Proc.request) =
      if !fail_release && r.prog = "ssh" && mentions "artifact_apply.sh" r && mentions "upgrade" r then begin
        if !switch_on_failure then deployed := Option.get !hello_deploy;
        1 end
      else 0 in
    let go f =
      let mock = Proc.Mock.create ~exit_codes ~outputs () in
      let result = Proc.Mock.run mock f in
      result, Proc.Mock.calls mock in
    let run () = go (fun () -> Update.run deps config paths) in
    let state () = Result.get_ok (Update_state.load ~dir:state_dir) in
    let ssh calls = List.filter (fun (r : Proc.request) -> r.prog = "ssh") calls in
    let locks calls = List.exists (mentions "locks/infra") calls in
    let applied calls = List.exists (fun r -> r.Proc.prog = "ssh" && mentions "artifact_apply.sh" r) calls in
    let reverted calls = List.exists (fun r -> r.Proc.prog = "ssh" && mentions "revert" r && mentions "artifact_apply.sh" r) calls in

    (* A moved ref, signed by an allowed key, newer than the deployed release. *)
    (match run () with
     | Some outcome, calls ->
         check "a newer signed commit is deployed"
           (List.assoc_opt "hello" outcome.report.apps = Some (Update.Deployed { commit = desired; identity }));
         check "the deploy goes through the update target: release, no edge"
           (applied calls && not (List.exists (fun (r : Proc.request) ->
              List.exists (fun a -> a = "edge" || String.starts_with ~prefix:"edge:" a) r.args) calls));
         check "the configuration used is the verified commit"
           (outcome.report.configuration = Update.Configuration config_commit);
         check "one line reports the deploy" (List.length outcome.lines = 1
           && contains "hello: deployed" (List.hd outcome.lines) && not outcome.failed);
         check "an app without a deploy bookmark is not enrolled"
           (List.assoc_opt "counter" outcome.report.apps = Some Update.Not_enrolled);
         check "the deployed commit is handled" ((Update_state.find (state ()) "hello").handled = Some desired)
     | None, _ -> check "the first run takes the run lock" false);

    (* The next run sees the same ref: nothing to do, nothing printed. *)
    deployed := desired;
    (match run () with
     | Some outcome, calls ->
         check "a handled commit is skipped without touching the host" (ssh calls = []);
         check "and prints nothing" (outcome.lines = [] && not outcome.failed)
     | None, _ -> check "the second run takes the run lock" false);

    (* An unsigned commit: refused before any host lock, reported once. *)
    let unsigned = String.make 40 'b' in
    hello_deploy := Some unsigned;
    deployed := older;
    signature_of := (fun commit -> if commit = config_commit then "good " ^ key else "unsigned");
    (match run () with
     | Some outcome, calls ->
         check "an unsigned commit is refused"
           (List.assoc_opt "hello" outcome.report.apps
            = Some (Update.Refused { commit = unsigned; refusal = Update_decision.Unsigned }));
         check "without taking a host lock or deploying" (not (locks calls) && not (applied calls));
         check "the refusal is reported as a failure" (outcome.failed && List.length outcome.lines = 1)
     | None, _ -> check "the unsigned run takes the run lock" false);
    (match run () with
     | Some outcome, _ -> check "a refusal is reported once" (outcome.lines = [] && not outcome.failed)
     | None, _ -> check "the repeat run takes the run lock" false);

    (* An unsigned configuration: nothing is examined. *)
    signature_of := (fun commit -> if commit = config_commit then "unsigned" else "good " ^ key);
    hello_deploy := Some desired;
    (match run () with
     | Some outcome, calls ->
         check "an unsigned configuration stops the run"
           ((match outcome.report.configuration with Update.Configuration_refused _ -> true | _ -> false)
            && outcome.report.apps = []);
         check "before any app is examined or any host reached" (ssh calls = []);
         check "and is reported" (outcome.failed && List.length outcome.lines = 1)
     | None, _ -> check "the configuration run takes the run lock" false);
    signature_of := (fun _ -> "good " ^ key);

    (* A release that fails after its switch, on an app that migrates: no revert. *)
    let reset commit =
      hello_deploy := Some commit; deployed := older; fail_release := true; switch_on_failure := true in
    reset desired;
    let state_before = state () in
    Update_state.save ~dir:state_dir (Update_state.set state_before "hello" { handled = None; reported = None })
    |> Result.get_ok;
    (match run () with
     | Some outcome, calls ->
         check "a switched release that fails is a failure of the release step"
           (match List.assoc_opt "hello" outcome.report.apps with
            | Some (Update.Failed { step = Dispatcher.Release; revert = Update.Not_attempted why; _ }) ->
                contains "migrate" why
            | _ -> false);
         check "an app that migrates is never reverted" (not (reverted calls));
         check "the failed commit is handled" ((Update_state.find (state ()) "hello").handled = Some desired);
         check "and the failure is reported" (outcome.failed && List.length outcome.lines = 1)
     | None, _ -> check "the failing run takes the run lock" false);

    (* The same failure on an app without migrate is reverted. *)
    write hello_sexp without_migrate;
    reset failing;
    (match run () with
     | Some outcome, calls ->
         check "a switched release that fails on an app without migrate is reverted"
           (match List.assoc_opt "hello" outcome.report.apps with
            | Some (Update.Failed { step = Dispatcher.Release; revert = Update.Reverted; _ }) -> true
            | _ -> false);
         check "through the in-place revert" (reverted calls)
     | None, _ -> check "the reverting run takes the run lock" false);
    write hello_sexp with_migrate;

    (* A release that fails before its switch changed nothing: tried again. *)
    reset retried;
    switch_on_failure := false;
    (match run () with
     | Some outcome, _ ->
         check "a release that fails before its switch is not applied"
           (match List.assoc_opt "hello" outcome.report.apps with
            | Some (Update.Not_applied { commit = Some c; _ }) -> c = retried
            | _ -> false);
         check "and is not handled" ((Update_state.find (state ()) "hello").handled <> Some retried);
         check "and is reported" (outcome.failed && List.length outcome.lines = 1)
     | None, _ -> check "the retried run takes the run lock" false);
    (match run () with
     | Some outcome, calls ->
         check "the next run tries it again" (applied calls);
         check "without reporting the same failure twice" (outcome.lines = [])
     | None, _ -> check "the retry takes the run lock" false);
    fail_release := false;

    (* --plan: every app's status, nothing changed. *)
    hello_deploy := Some desired; deployed := older;
    let saved = state () in
    let report, calls = go (fun () -> Update.plan deps config paths) in
    check "--plan says what would be deployed"
      (List.assoc_opt "hello" report.apps = Some (Update.Would_deploy desired));
    check "--plan deploys nothing and takes no host lock" (not (applied calls) && not (locks calls));
    check "--plan writes no state" (state () = saved);
    check "--plan lists every app"
      (let lines = Update.plan_lines report in
       List.exists (contains "hello") lines && List.exists (contains "counter") lines);

    (* Only one run at a time. *)
    (match Update_state.with_run_lock ~dir:state_dir (fun () ->
       match Unix.fork () with
       | 0 -> Unix._exit (match Update.run deps config paths with None -> 0 | Some _ -> 1)
       | child -> snd (Unix.waitpid [] child)) with
     | Some (Unix.WEXITED 0) -> check "a run while another holds the lock does nothing" true
     | _ -> check "a run while another holds the lock does nothing" false);

    (* The updater's own settings. *)
    let parse = Update.config_of_string in
    check "settings parse"
      (parse "((config (git file:///c) (bookmark main)) (signers (ABCD)) (gnupghome /g))"
       = Ok { config_url = "file:///c"; config_bookmark = "main"; signers = [ "ABCD" ]; gnupghome = "/g" });
    List.iter (fun (name, text) -> check ("settings refused: " ^ name) (Result.is_error (parse text)))
      [ "no signers", "((config (git u) (bookmark main)) (signers ()) (gnupghome /g))";
        "a relative gnupghome", "((config (git u) (bookmark main)) (signers (A)) (gnupghome g))";
        "a missing bookmark", "((config (git u)) (signers (A)) (gnupghome /g))";
        "an unknown field", "((config (git u) (bookmark main)) (signers (A)) (gnupghome /g) (extra x))";
        "not a sexp", "((config" ])
