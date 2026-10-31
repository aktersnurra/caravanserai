open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name
  else (Printf.eprintf "FAIL - %s\n%!" name; exit 1)

let write path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let jj args = Proc.live (fun () -> Proc.run_checked "jj" args)
let jj_output args =
  let code, output = Proc.live (fun () -> Proc.capture "jj" args) in
  if code <> 0 then failwith "jj fixture error" else String.trim output

let () =
  let fixture = Filename.temp_dir "artifact-build-candidate" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let checkout = Filename.concat fixture "source" in
    jj ["git"; "init"; checkout];
    write (Filename.concat checkout "release.txt") "synthetic committed source\n";
    jj ["-R"; checkout; "describe"; "-m"; "source fixture"];
    jj ["-R"; checkout; "new"];
    let revision = jj_output ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-";
      "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
    let base = Filename.concat fixture "base.txz" in
    write base "synthetic base archive\n";
    let declaration = Filename.concat fixture "app.sexp" in
    write declaration (Printf.sprintf
      "((name drill)(ip 10.40.0.2)(hostname drill.example.org)(tailnet_ports ((http 4000)))(operator_ports ())(strategy freebsd_native_elixir)(hooks (bootstrap deploy check))(extra_steps ())(strategy_config ((packages (erlang-runtime29 elixir-devel sqlite3 gmake))(repo_path %s)(release_name drill_trainer)(check_path /))))\n" checkout);
    let layout = Repo_root.example () in
    let loaded = match Declaration.load ~layout with Ok value -> value | Error _ -> failwith "repo fixture failed" in
    let env : Dispatcher.env = {
      layout; topology = Some (Test_declaration.topology
        ~jails:[ "drill"; "board" ] ~guests:[] ());
      compute_target = "compute-test"; edge_target = "edge-test";
      remote_stage = "/tmp/serai-stage-test";
      ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl";
      config = [App_config.load declaration]; endpoints = loaded.endpoints; edge = loaded.edge;
      edge_ts_ip = None; edge_peer_match = None; caddy_force_build = false;
      confirm = (fun _ -> true); operator = "test@test"; lock_token = "token-1";
      jj_bin = "jj"; now_utc = (fun () -> "2026-09-28T00:00:00Z");
      guests = []; ops_control_path = "/tmp/ops-ssh-%C"; ssh_multiplex = false;
      source_checkout_override = None;
    } in
    let run ?(base_archive=base) ?(base_sha256=sha256 "synthetic base archive\n")
        ?(revision=revision) ?(ip="10.40.0.200") name out =
      let mock = Proc.Mock.create () in
      let result = try
        Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_build_candidate env name
          ~revision ~ip ~base_archive ~base_sha256 ~out))
      with Failure message -> Error message in
      result, Proc.Mock.calls mock in
    let refused name ?base_archive ?base_sha256 ?revision ?ip label =
      let out = Filename.concat fixture label in
      let result, calls = run ?base_archive ?base_sha256 ?revision ?ip name out in
      check (label ^ " refused without remote calls")
        (Result.is_error result && calls = [] && not (Sys.file_exists out)) in
    refused "unknown" "unknown workload";
    refused "drill" ~revision:"no-such-commit" "missing source revision";
    refused "drill" ~ip:"bad-ip" "invalid build IP";
    refused "drill" ~base_sha256:"not-a-digest" "bad base digest";
    refused "drill" ~base_sha256:(String.make 64 'a') "mismatched base digest";
    refused "drill" ~base_archive:(Filename.concat fixture "missing-base") "missing base archive";
    let tracked_link = Filename.concat checkout "private-link" in
    Unix.symlink ".env" tracked_link;
    jj ["-R"; checkout; "describe"; "-m"; "tracked symlink fixture"];
    jj ["-R"; checkout; "new"];
    let bad_revision = jj_output ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-";
      "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
    refused "drill" ~revision:bad_revision "tracked symlink path";
    let no_scripts = { env with layout = Layout.v ~engine:fixture ~config:(Layout.config env.layout) } in
    let missing_script_out = Filename.concat fixture "missing-builder-script" in
    let mock = Proc.Mock.create () in
    let missing_result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate no_scripts "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n")
        ~out:missing_script_out))
      with Failure message -> Error message in
    check "missing recipe script refuses build before any remote call"
      (Result.is_error missing_result && Proc.Mock.calls mock = []
       && not (Sys.file_exists missing_script_out));
    let candidate_out = Filename.concat fixture "candidate" in
    let archive_bytes = "synthetic candidate archive\n" in
    let contains value needle =
      let rec find i = i + String.length needle <= String.length value
        && (String.sub value i (String.length needle) = needle || find (i + 1)) in
      find 0 in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      match call.prog, List.rev call.args with
      | "rsync", destination :: remote :: _ when contains remote "/output/release.tar" ->
          write destination archive_bytes; 0
      | "rsync", destination :: remote :: _ when contains remote "/output/release.sha256" ->
          write destination (sha256 archive_bytes ^ "\n"); 0
      | "rsync", destination :: remote :: _ when contains remote "/output/target-abi" ->
          write destination "FreeBSD:14:amd64\n"; 0
      | "rsync", destination :: remote :: _ when contains remote "/output/dependencies" ->
          write destination ("compiler\t1.0_1,1\t" ^ sha256 "compiler archive" ^ "\n"); 0
      | _ -> 0) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:candidate_out))
      with Failure message -> Error message in
    check "candidate build returns source commit and verified archive digest"
      (match result with
       | Ok candidate -> candidate.source_commit = revision
         && candidate.archive_sha256 = sha256 archive_bytes
         && candidate.target_abi = "FreeBSD:14:amd64"
         && String.length candidate.recipe_sha256 = 64
         && Sys.file_exists (Filename.concat candidate_out "release.tar")
       | Error _ -> false);
    check "complete candidate manifest is publishable and reverified by the store"
      (match result with
       | Error _ -> false
       | Ok candidate ->
           let store = Filename.concat fixture "store" in
           Unix.mkdir store 0o700;
           let archive = Filename.concat candidate_out "release.tar" in
           match Artifact_store.publish ~root:store ~manifest:candidate.manifest ~archive with
           | Error _ -> false
           | Ok published -> Artifact_store.reuse ~root:store ~manifest:candidate.manifest = Ok published);
    let calls = Proc.Mock.calls mock in
    check "builder scripts are transferred from private recipe snapshot"
      (List.for_all (fun name ->
         List.exists (fun (call : Proc.request) ->
           match call.prog, List.rev call.args with
           | "rsync", destination :: source :: _ ->
               contains destination ("/" ^ name)
               && contains source ("/recipe/" ^ name)
               && not (contains source (Layout.lib_dir env.layout))
           | _ -> false) calls)
        [ "artifact_build_jail.sh"; "artifact_build_phoenix.sh"; "artifact_verify_source.sh";
          "artifact_resolve_packages.sh"; "artifact_build_assets.exs" ]);
    check "candidate build cleanup is scoped and precedes lock release"
      (match List.rev calls with
       | release :: cleanup :: _ ->
           let command = String.concat " " cleanup.args in
           release.prog = "ssh" && cleanup.prog = "ssh"
           && contains command "artifact-build-cleanup:"
           && contains command "/artifact-build/drill/token-1"
           && contains command "rm -rf"
           && not (contains command "/jails/drill/")
       | _ -> false);
    check "candidate build acquires, stages, downloads, then releases the lock"
      (List.map (fun (call : Proc.request) -> call.prog) calls
       = ["ssh"; "ssh"; "rsync"; "rsync"; "rsync"; "rsync"; "rsync"; "rsync";
          "rsync"; "rsync"; "ssh"; "rsync"; "rsync"; "rsync"; "rsync"; "ssh"; "ssh"]);
    check "candidate build invokes the disposable adapter, never the service jail"
      (List.exists (fun (call : Proc.request) ->
         call.prog = "ssh" && contains (String.concat " " call.args) "artifact_build_jail.sh") calls
       && not (List.exists (fun (call : Proc.request) ->
         contains (String.concat " " call.args) "/jails/drill/") calls));
    check "remote builder checks all transferred script digests before execution"
      (List.exists (fun (call : Proc.request) ->
         let command = String.concat " " call.args in
         let contains_before first second =
           let rec find value needle i =
             if i + String.length needle > String.length value then None
             else if String.sub value i (String.length needle) = needle then Some i
             else find value needle (i + 1) in
           match find command first 0, find command second 0 with
           | Some before, Some after -> before < after | _ -> false in
         call.prog = "ssh" && contains_before "sha256 -q" "exec sh"
         && List.for_all (fun name ->
              let path = Layout.lib_file env.layout name in
              let channel = open_in_bin path in
              let expected = Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
                sha256 (really_input_string channel (in_channel_length channel))) in
              contains command ("/" ^ name) && contains command expected)
              [ "artifact_build_jail.sh"; "artifact_build_phoenix.sh"; "artifact_verify_source.sh";
                "artifact_resolve_packages.sh"; "artifact_build_assets.exs" ]) calls);
    check "adapter receives lock marker, inventory digest and declared packages"
      (match result with
       | Error _ -> false
       | Ok candidate -> List.exists (fun (call : Proc.request) ->
           let command = String.concat " " call.args in
           call.prog = "ssh" && contains command "artifact_build_jail.sh"
           && contains command "SERAI_LOCK_HELD=1"
           && contains command candidate.source_inventory_sha256
           && contains command "erlang-runtime29"
           && contains command "elixir-devel") calls);
    let board_sexp = Filename.concat fixture "board.sexp" in
    write board_sexp (Printf.sprintf
      "((name board)(ip 10.40.0.3)(hostname board.example.org)(tailnet_ports ((http 4001)))(operator_ports ())(strategy freebsd_native_elixir)(hooks (bootstrap deploy check))(extra_steps ())(strategy_config ((packages (erlang-runtime29 elixir-devel sqlite3 gmake git node24 npm-node24))(repo_path %s)(release_name board)(check_path /))))\n" checkout);
    let board = App_config.load board_sexp in
    let board_env = { env with config = [board] } in
    let board_out = Filename.concat fixture "board-candidate" in
    let board_result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate board_env "board" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:board_out))
      with Failure message -> Error message in
    check "Board candidate uses its own declared Phoenix release"
      (match board_result with Ok candidate -> candidate.source_commit = revision
        && Sys.file_exists (Filename.concat board_out "manifest") | Error _ -> false);
    check "Board stage and disposable jail names do not target Drill"
      (List.exists (fun (call : Proc.request) -> call.prog = "ssh"
        && contains (String.concat " " call.args) "infra-build-board-token-1"
        && contains (String.concat " " call.args) "/artifact-build/board/token-1")
        (Proc.Mock.calls mock));
    let store = Filename.concat fixture "build-store" in
    Unix.mkdir store 0o700;
    let built_identity = Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_store env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~store) in
    check "build-to-store publishes only its verified candidate"
      (match Artifact_store.load ~root:store ~identity:built_identity with
       | Ok (manifest, _) -> Artifact_manifest.identity manifest = built_identity
       | Error _ -> false);
    let apply_mock = Proc.Mock.create () in
    Proc.Mock.run apply_mock (fun () -> Dispatcher.artifact_apply env "drill"
      ~store ~identity:built_identity ~rollback:false);
    let apply_calls = Proc.Mock.calls apply_mock in
    let is_apply (call : Proc.request) =
      call.prog = "ssh" && contains (String.concat " " call.args) "SERAI_LOCK_HELD=1" in
    let is_cleanup (call : Proc.request) =
      call.prog = "ssh" && contains (String.concat " " call.args) {|rm -rf -- "$stage"|} in
    let is_release (call : Proc.request) =
      call.prog = "ssh" && contains (String.concat " " call.args) {|rm -rf "$lock"|} in
    check "store-backed upgrade uses one lock through ABI/install/switch/check"
      (List.length (List.filter (fun (call : Proc.request) -> contains (String.concat " " call.args) {|mkdir "$lock"|}) apply_calls) = 1
       && List.exists (fun call -> is_apply call
          && contains (String.concat " " call.args) "sha256 -q"
          && contains (String.concat " " call.args) "FreeBSD:14:amd64"
          && contains (String.concat " " call.args) "http://10.40.0.2:4000/"
          (* No anchor and no migrate declared; each argument is quoted,
             then the command again for doas sh -c. *)
          && contains (String.concat " " call.args) {|FreeBSD:14:amd64'\'' '\''-'\'' '\''-'\''|}) apply_calls
       && match List.rev apply_calls with
          | release :: cleanup :: apply :: _ -> is_release release && is_cleanup cleanup && is_apply apply
          | _ -> false);
    let convert_mock = Proc.Mock.create () in
    let refused = try Proc.Mock.run convert_mock (fun () -> Dispatcher.artifact_apply ~convert:true env "drill"
      ~store ~identity:built_identity ~rollback:false); false
      with Failure m -> m = "artifact apply: conversion is for executables only" in
    check "Phoenix conversion is refused before host work"
      (refused && Proc.Mock.calls convert_mock = []);
    let denied_mock = Proc.Mock.create () in
    let denied = try Ok (Proc.Mock.run denied_mock (fun () ->
      Dispatcher.artifact_apply {env with confirm=(fun _ -> false)} "drill"
        ~store ~identity:built_identity ~rollback:false)) with Failure message -> Error message in
    check "cancelled activation leaves hosts untouched"
      (Result.is_error denied && Proc.Mock.calls denied_mock = []);
    let wrong_mock = Proc.Mock.create () in
    let wrong = try Ok (Proc.Mock.run wrong_mock (fun () ->
      Dispatcher.artifact_apply board_env "board" ~store ~identity:built_identity ~rollback:false))
      with Failure message -> Error message in
    check "wrong workload refuses apply before host work"
      (Result.is_error wrong && Proc.Mock.calls wrong_mock = []);
    let apply_failure label code ~retain =
      let mock = Proc.Mock.create ~exit_codes:(fun call -> if is_apply call then code else 0) () in
      let result = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_apply env "drill"
          ~store ~identity:built_identity ~rollback:false)) with Failure message -> Error message in
      let calls = Proc.Mock.calls mock in
      check label (Result.is_error result
        && List.exists is_apply calls
        && List.exists is_cleanup calls = not retain
        && List.exists is_release calls = not retain) in
    apply_failure "known remote failure cleans stage and releases lock" 1 ~retain:false;
    let interrupted_ssh = Filename.concat fixture "interrupted-ssh" in
    let interrupted_rsync = Filename.concat fixture "interrupted-rsync" in
    let events = Filename.concat fixture "interrupt-events" in
    write interrupted_ssh ("#!/bin/sh\ncase \"$*\" in\n"
      ^ " *SERAI_LOCK_HELD=1*) printf 'apply\\n' >>" ^ Shell.quote events
      ^ "; kill -INT \"$PPID\"; sleep 0.1 ;;\n"
      ^ " *'rm -rf --'*) printf 'cleanup\\n' >>" ^ Shell.quote events ^ " ;;\n"
      ^ " *'rm -rf \"$lock\"'*) printf 'release\\n' >>" ^ Shell.quote events ^ " ;;\nesac\n");
    write interrupted_rsync "#!/bin/sh\nexit 0\n";
    Unix.chmod interrupted_ssh 0o700; Unix.chmod interrupted_rsync 0o700;
    let old_handler = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> raise Sys.Break)) in
    let interrupted = Fun.protect ~finally:(fun () -> Sys.set_signal Sys.sigint old_handler)
      (fun () -> try Proc.live (fun () -> Dispatcher.artifact_apply
        {env with ssh_bin=interrupted_ssh; rsync_bin=interrupted_rsync} "drill"
        ~store ~identity:built_identity ~rollback:false); false with Sys.Break -> true) in
    check "actual interrupted command retains remote stage and lock"
      (interrupted && In_channel.with_open_bin events In_channel.input_all = "apply\n");
    apply_failure "uncertain SSH outcome retains stage and lock" 255 ~retain:true;
    apply_failure "signal-style SSH exit retains stage and lock" 143 ~retain:true;
    let transfer_mock = Proc.Mock.create ~exit_codes:(fun call -> if call.prog = "rsync" then 12 else 0) () in
    let transfer_result = try Ok (Proc.Mock.run transfer_mock (fun () -> Dispatcher.artifact_apply env "drill"
      ~store ~identity:built_identity ~rollback:false)) with Failure message -> Error message in
    check "failed transfer retains stage/lock without running the lifecycle"
      (Result.is_error transfer_result && not (List.exists (fun call ->
        is_apply call || is_cleanup call || is_release call) (Proc.Mock.calls transfer_mock)));
    let cleanup_mock = Proc.Mock.create ~exit_codes:(fun call ->
      if is_apply call then 1 else if is_cleanup call then 2 else 0) () in
    let cleanup_result = try
      Proc.Mock.run cleanup_mock (fun () -> Dispatcher.artifact_apply env "drill"
        ~store ~identity:built_identity ~rollback:false); false
      with Proc.Cleanup_failed (Failure primary, Failure secondary) ->
        contains primary "remote exited 1" && contains secondary "exited 2" in
    check "cleanup failure preserves both causes and retains the lock"
      (cleanup_result && not (List.exists is_release (Proc.Mock.calls cleanup_mock)));
    Unix.chmod store 0o777;
    let unsafe_mock = Proc.Mock.create () in
    let unsafe_result = try Ok (Proc.Mock.run unsafe_mock (fun () ->
      Dispatcher.artifact_build_store env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~store))
      with Failure message -> Error message in
    check "unsafe store is rejected before native host operations"
      (Result.is_error unsafe_result && Proc.Mock.calls unsafe_mock = []);
    Unix.chmod store 0o700;
    let reuse ?(identity=built_identity) ?(source_revision=revision)
        ?(base_archive=base) ?(base_digest=sha256 "synthetic base archive\n") () =
      let calls = Proc.Mock.create () in
      let result = try Ok (Proc.Mock.run calls (fun () ->
          Dispatcher.artifact_build_store ~reuse:identity env "drill"
            ~revision:source_revision ~ip:"10.40.0.200"
            ~base_archive ~base_sha256:base_digest ~store))
        with Failure message -> Error message in
      result, Proc.Mock.calls calls in
    let reused, reuse_calls = reuse () in
    check "explicit reuse returns the verified identity without remote calls"
      (reused = Ok built_identity && reuse_calls = []);
    let refuse_reuse label result =
      let result, calls = result in
      check (label ^ " refuses without fallback build or remote calls")
        (Result.is_error result && calls = []) in
    refuse_reuse "missing identity" (reuse ~identity:(String.make 64 '0') ());
    refuse_reuse "invalid identity" (reuse ~identity:"../outside" ());
    refuse_reuse "invalid source revision" (reuse ~source_revision:"missing-revision" ());
    refuse_reuse "wrong base bytes" (reuse ~base_digest:(String.make 64 'f') ());
    let other_base = Filename.concat fixture "other-base.txz" in
    write other_base "different base\n";
    refuse_reuse "different verified base recipe"
      (reuse ~base_archive:other_base ~base_digest:(sha256 "different base\n") ());
    let recipe_sha256 = match result with Ok value -> value.recipe_sha256 | Error _ -> assert false in
    let stored ?(name="drill") ?(source_commit=revision) ?(target_abi="FreeBSD:14:amd64")
        ?(recipe_sha256=recipe_sha256) ?(release_name="drill_trainer") ?(version="1.0_1,1") () =
      let dependencies : Artifact_manifest.dependency list =
        [{ name="compiler"; version; sha256=sha256 ("compiler archive " ^ version) }] in
      let manifest = match Artifact_manifest.create ~name ~source_commit
          ~target_abi ~dependencies ~recipe_sha256 ~release_name
          ~archive_sha256:(sha256 archive_bytes) with Ok value -> value | Error error -> failwith error in
      (match Artifact_store.publish ~root:store ~manifest
          ~archive:(Filename.concat candidate_out "release.tar") with
       | Ok _ -> () | Error error -> failwith error);
      Artifact_manifest.identity manifest in
    refuse_reuse "wrong workload" (reuse ~identity:(stored ~name:"board" ()) ());
    refuse_reuse "wrong committed source" (reuse ~identity:(stored ~source_commit:(String.make 40 '1') ()) ());
    refuse_reuse "changed helpers or package recipe" (reuse ~identity:(stored ~recipe_sha256:(String.make 64 'f') ()) ());
    refuse_reuse "wrong release" (reuse ~identity:(stored ~release_name:"board" ()) ());
    let refuse_apply label identity =
      let mock = Proc.Mock.create () in
      let result = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_apply env "drill"
        ~store ~identity ~rollback:false)) with Failure message -> Error message in
      check label (Result.is_error result && Proc.Mock.calls mock = []) in
    refuse_apply "wrong release refuses apply before host work" (stored ~release_name:"board" ());
    refuse_apply "wrong OS refuses apply before host work" (stored ~target_abi:"Linux:x86_64" ());
    refuse_apply "missing store entry refuses apply before host work" (String.make 64 '0');
    let pinned = stored ~version:"2.0" () in
    let pinned_result, pinned_calls = reuse ~identity:pinned () in
    check "explicit identity pins recorded dependencies, never guesses latest"
      (pinned_result = Ok pinned && pinned_calls = []);
    let cached_archive = Filename.concat (Filename.concat store built_identity) "release.tar" in
    write cached_archive "corrupt cached archive\n";
    refuse_reuse "corrupt archive" (reuse ());
    refuse_apply "corrupt store archive refuses apply before host work" built_identity;
    write cached_archive archive_bytes;
    let failure_case label fail_when =
      let destination = Filename.concat fixture label in
      let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
        if fail_when call then 1 else 0) () in
      let result = try
        Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_build_candidate env "drill"
          ~revision ~ip:"10.40.0.200" ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
      let calls = Proc.Mock.calls mock in
      check (label ^ " refuses output and retains stage/lock for inspection")
        (Result.is_error result && not (Sys.file_exists destination)
         && not (List.exists (fun (call : Proc.request) -> call.prog = "ssh"
           && (contains (String.concat " " call.args) "artifact-build-cleanup:"
             || contains (String.concat " " call.args) {|rm -rf "$lock"|})) calls)) in
    let destination = Filename.concat fixture "guard-failed" in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      if call.prog = "ssh" && contains (String.concat " " call.args) "unsafe remote staging path"
      then 1 else 0) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
    check "failed stage guard never runs privileged cleanup"
      (Result.is_error result && not (Sys.file_exists destination)
       && not (List.exists (fun (call : Proc.request) ->
           contains (String.concat " " call.args) "artifact-build-cleanup:")
         (Proc.Mock.calls mock)));
    failure_case "stage failure" (fun call -> call.prog = "rsync");
    failure_case "script verification failure" (fun call ->
      call.prog = "ssh" && contains (String.concat " " call.args) "sha256 -q");
    failure_case "adapter failure" (fun call ->
      call.prog = "ssh" && contains (String.concat " " call.args) "artifact_build_jail.sh");
    let destination = Filename.concat fixture "tampered-candidate" in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      match call.prog, List.rev call.args with
      | "rsync", path :: remote :: _ when contains remote "/output/release.tar" ->
          write path archive_bytes; 0
      | "rsync", path :: remote :: _ when contains remote "/output/release.sha256" ->
          write path (String.make 64 'f' ^ "\n"); 0
      | "rsync", path :: remote :: _ when contains remote "/output/target-abi" ->
          write path "FreeBSD:14:amd64\n"; 0
      | "rsync", path :: remote :: _ when contains remote "/output/dependencies" ->
          write path ("compiler\t1\t" ^ sha256 "compiler archive" ^ "\n"); 0
      | _ -> 0) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
    check "tampered candidate digest never publishes output"
      (Result.is_error result && not (Sys.file_exists destination));
    let destination = Filename.concat fixture "invalid-abi" in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      match call.prog, List.rev call.args with
      | "rsync", path :: remote :: _ when contains remote "/output/release.tar" ->
          write path archive_bytes; 0
      | "rsync", path :: remote :: _ when contains remote "/output/release.sha256" ->
          write path (sha256 archive_bytes ^ "\n"); 0
      | "rsync", path :: remote :: _ when contains remote "/output/target-abi" ->
          write path "FreeBSD:14:amd64\nforged\n"; 0
      | "rsync", path :: remote :: _ when contains remote "/output/dependencies" ->
          write path ("compiler\t1\t" ^ sha256 "compiler archive" ^ "\n"); 0
      | _ -> 0) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
    check "malformed target ABI refuses candidate publication"
      (Result.is_error result && not (Sys.file_exists destination));
    let destination = Filename.concat fixture "invalid-dependencies" in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      match call.prog, List.rev call.args with
      | "rsync", path :: remote :: _ when contains remote "/output/release.tar" -> write path archive_bytes; 0
      | "rsync", path :: remote :: _ when contains remote "/output/release.sha256" -> write path (sha256 archive_bytes ^ "\n"); 0
      | "rsync", path :: remote :: _ when contains remote "/output/target-abi" -> write path "FreeBSD:14:amd64\n"; 0
      | "rsync", path :: remote :: _ when contains remote "/output/dependencies" -> write path "pkg\t1\tinternal-checksum\n"; 0
      | _ -> 0) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
    check "invalid dependency archive digest refuses candidate publication"
      (Result.is_error result && not (Sys.file_exists destination));
    let destination = Filename.concat fixture "cleanup-failed" in
    let mock = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      if call.prog = "ssh" && contains (String.concat " " call.args) "artifact-build-cleanup:"
      then 1
      else (match call.prog, List.rev call.args with
        | "rsync", path :: remote :: _ when contains remote "/output/release.tar" ->
            write path archive_bytes; 0
        | "rsync", path :: remote :: _ when contains remote "/output/release.sha256" ->
            write path (sha256 archive_bytes ^ "\n"); 0
        | _ -> 0)) () in
    let result = try Ok (Proc.Mock.run mock (fun () ->
      Dispatcher.artifact_build_candidate env "drill" ~revision ~ip:"10.40.0.200"
        ~base_archive:base ~base_sha256:(sha256 "synthetic base archive\n") ~out:destination))
      with Failure message -> Error message in
    check "failed stage cleanup refuses candidate publication and retains lock"
      (Result.is_error result && not (Sys.file_exists destination)
       && List.exists (fun (call : Proc.request) ->
         contains (String.concat " " call.args) "artifact-build-cleanup:") (Proc.Mock.calls mock)
       && not (List.exists (fun (call : Proc.request) ->
         contains (String.concat " " call.args) {|rm -rf "$lock"|}) (Proc.Mock.calls mock))))

