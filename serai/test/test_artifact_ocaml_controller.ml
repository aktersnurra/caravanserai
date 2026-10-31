open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name
  else (Printf.eprintf "FAIL - %s\n%!" name; exit 1)
let write path value = Out_channel.with_open_bin path (fun channel -> output_string channel value)
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let contains value needle =
  let rec loop i = i + String.length needle <= String.length value
    && (String.sub value i (String.length needle) = needle || loop (i + 1)) in
  loop 0
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Unix.unlink path
let jj args = Proc.live (fun () -> Proc.run_checked "jj" args)
let commit checkout description =
  jj ["-R"; checkout; "describe"; "-m"; description];
  jj ["-R"; checkout; "new"];
  let code, value = Proc.live (fun () -> Proc.capture "jj"
    ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-"; "--no-graph"; "-T"; "commit_id"]) in
  if code <> 0 then failwith "fixture commit failed" else String.trim value

let () =
  let fixture = Filename.temp_dir "artifact-ocaml-controller" "" in
  Fun.protect ~finally:(fun () -> remove fixture) (fun () ->
    let source = Filename.concat fixture "source" in
    let repository = Filename.concat fixture "repository" in
    List.iter (fun path -> jj ["git"; "init"; path]) [source; repository];
    write (Filename.concat source "dune-project") "(lang dune 3.24)\n";
    let revision = commit source "public OCaml source" in
    write (Filename.concat repository "repo") "opam-version: \"2.0\"\n";
    let repository_revision = commit repository "immutable opam fixture" in
    let base = Filename.concat fixture "base.txz" in
    write base "base fixture";
    let store = Filename.concat fixture "store" in
    Unix.mkdir store 0o700;
    let layout = Repo_root.example () in
    let loaded = match Declaration.load ~layout with Ok value -> value | Error _ -> failwith "declaration fixture" in
    let declaration = Filename.concat fixture "meals.sexp" in
    write declaration (Printf.sprintf
      "((name meals)(ip 10.40.0.6)(hostname meals.example.org)(tailnet_ports ((http 4020)))(operator_ports ())(strategy freebsd_native_ocaml)(hooks (bootstrap deploy check))(extra_steps ())(strategy_config ((ocaml_switch 5.5.1)(repo_path %s)(zfs_dataset zroot/meals)(data_dir /var/db/meals)(packages (ocaml-opam sqlite3 gmp))(serve_args (serve))(migrate (command migrate))(check_path /health))))\n" source);
    let env : Dispatcher.env = {
      layout; topology = Some (Test_declaration.topology
        ~jails:[ "meals" ] ~guests:[] ()); compute_target="compute-test"; edge_target="edge-test";
      remote_stage="/tmp/serai-stage-test"; ssh_bin="ssh"; rsync_bin="rsync"; curl_bin="curl";
      config=[App_config.load declaration]; endpoints=loaded.endpoints; edge=loaded.edge;
      edge_ts_ip=None; edge_peer_match=None; caddy_force_build=false; confirm=(fun _ -> true);
      operator="test@test"; lock_token="ocaml-test"; jj_bin="jj"; now_utc=(fun () -> "2026-10-14T00:00:00Z");
      guests=[]; ops_control_path="/tmp/ops-ssh-%C"; ssh_multiplex=false; source_checkout_override=None;
    } in
    let archive = "verified OCaml archive fixture" in
    let output (call : Proc.request) =
      match call.prog, List.rev call.args with
      | "rsync", destination :: remote :: _ when contains remote "/output/" ->
          let value = match Filename.basename remote with
            | "release.tar" -> archive
            | "release.sha256" -> sha256 archive ^ "\n"
            | "target-abi" -> "FreeBSD:15:amd64\n"
            | "dependencies" -> "sqlite3\t3.50.2\t" ^ sha256 "package archive" ^ "\n"
            | _ -> failwith "unexpected output" in
          write destination value; 0
      | _ -> 0 in
    let build ?reuse ?opam_snapshots ?(repository_revision=repository_revision) env =
      Dispatcher.artifact_build_store ?reuse ?opam_snapshots ~opam_repository:(repository, repository_revision)
        env "meals" ~revision ~ip:"10.40.0.200" ~base_archive:base ~base_sha256:(sha256 "base fixture") ~store in
    let mock = Proc.Mock.create ~exit_codes:output () in
    let identity = Proc.Mock.run mock (fun () -> build env) in
    let manifest = match Artifact_store.load ~root:store ~identity with
      | Ok (manifest, _) -> manifest | Error message -> failwith message in
    check "OCaml source build publishes the verified source-v1 manifest"
      (manifest.input = Artifact_manifest.Source_commit revision && manifest.release_name = "meals"
       && manifest.archive_sha256 = sha256 archive && manifest.target_abi = "FreeBSD:15:amd64");
    let calls = Proc.Mock.calls mock in
    check "OCaml build binds declared compiler and both verified snapshots"
      (List.exists (fun (call : Proc.request) -> call.prog = "ssh"
        && List.for_all (contains (String.concat " " call.args))
          ["SERAI_ARTIFACT_KIND=ocaml"; "ocaml-base-compiler.5.5.1";
           "SERAI_OPAM_INVENTORY_SHA256="; "/repository-inventory"] ) calls);
    check "OCaml helpers transfer from the private recipe snapshot, not mutable originals"
      (List.for_all (fun name -> List.exists (fun (call : Proc.request) ->
        call.prog = "rsync" && contains (String.concat " " call.args) ("/recipe/" ^ name)) calls)
        ["artifact_build_ocaml.sh"; "artifact_build_jail.sh"; "artifact_verify_source.sh"; "artifact_resolve_packages.sh"]);
    let reuse_mock = Proc.Mock.create () in
    check "explicit OCaml reuse is verified locally with zero host calls"
      (Proc.Mock.run reuse_mock (fun () -> build ~reuse:identity env) = identity
       && Proc.Mock.calls reuse_mock = []);
    let opam_snapshots = Filename.concat fixture "opam-snapshots" in
    check "reuse with a snapshot cache exports the opam tree once, under its commit, and matches"
      (Proc.Mock.run (Proc.Mock.create ()) (fun () -> build ~reuse:identity ~opam_snapshots env) = identity
       && Sys.file_exists (Filename.concat opam_snapshots (repository_revision ^ "/repo"))
       && Proc.Mock.run (Proc.Mock.create ()) (fun () -> build ~reuse:identity ~opam_snapshots env) = identity);
    let refuses label action =
      let mock = Proc.Mock.create () in
      let rejected = try ignore (Proc.Mock.run mock action); false with Failure _ -> true in
      check label (rejected && Proc.Mock.calls mock = []) in
    write (Filename.concat repository "repo") "opam-version: \"2.0\"\n# different immutable input\n";
    let changed_revision = commit repository "different opam input" in
    refuses "changed opam snapshot refuses reuse without fallback or host work"
      (fun () -> build ~reuse:identity ~repository_revision:changed_revision env);
    refuses "missing explicit selection refuses without fallback or host work"
      (fun () -> build ~reuse:(String.make 64 'f') env);
    List.iter (fun code ->
      let failed = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
        if call.prog = "ssh" && contains (String.concat " " call.args) "artifact_build_jail.sh"
        then code else output call) () in
      let rejected = try ignore (Proc.Mock.run failed (fun () -> build env)); false
        with Failure _ -> true in
      let destructive = List.exists (fun (call : Proc.request) ->
        call.prog = "ssh" && (contains (String.concat " " call.args) "artifact-build-cleanup:"
          || contains (String.concat " " call.args) {|rm -rf "$lock"|})) (Proc.Mock.calls failed) in
      check (Printf.sprintf "OCaml build failure %d retains remote stage/lock without publication" code)
        (rejected && not destructive)) [1; 143; 255];
    let cleaned = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      if call.prog = "ssh" && contains (String.concat " " call.args) "artifact_build_jail.sh"
      then 3 else output call) () in
    let rejected = try ignore (Proc.Mock.run cleaned (fun () -> build env)); false
      with Failure _ -> true in
    let ran needle = List.exists (fun (call : Proc.request) ->
      call.prog = "ssh" && contains (String.concat " " call.args) needle) (Proc.Mock.calls cleaned) in
    check "a build that failed and board its jail down removes the stage and releases the lock"
      (rejected && ran "artifact-build-cleanup:" && ran {|rm -rf "$lock"|});
    let ran_bundle (call : Proc.request) = Filename.basename call.prog = "build-bundle.sh" in
    let names_bundle (call : Proc.request) =
      call.prog = "ssh" && contains (String.concat " " call.args) "SERAI_WEB_BUNDLE=" in
    check "an app without a web bundle builds none and names none to the build jail"
      (not (List.exists ran_bundle calls) && not (List.exists names_bundle calls));
    let bundled = Filename.concat fixture "meals-web.sexp" in
    write bundled (Printf.sprintf
      "((name meals)(ip 10.40.0.6)(hostname meals.example.org)(tailnet_ports ((http 4020)))(operator_ports ())(strategy freebsd_native_ocaml)(hooks (bootstrap deploy check))(extra_steps ())(strategy_config ((ocaml_switch 5.5.1)(repo_path %s)(zfs_dataset zroot/meals)(data_dir /var/db/meals)(packages (ocaml-opam sqlite3 gmp))(serve_args (serve))(migrate (command migrate))(check_path /health)(web_bundle web/build-bundle.sh))))\n" source);
    let web_env = { env with config = [App_config.load bundled] } in
    (* The mocked script writes [entries] into its output directory. *)
    let bundle entries (call : Proc.request) =
      if ran_bundle call then begin
        let out = List.hd call.args in
        Unix.mkdir out 0o700;
        List.iter (fun (name, directory) ->
          if directory then Unix.mkdir (Filename.concat out name) 0o700
          else write (Filename.concat out name) name) entries;
        0
      end else output call in
    let web_mock = Proc.Mock.create
      ~exit_codes:(bundle [ "index.html", false; "main.bc.js", false ]) () in
    let web_identity = Proc.Mock.run web_mock (fun () -> build web_env) in
    let web_calls = Proc.Mock.calls web_mock in
    check "a declared web bundle is built on the controller in a copy of the staged source"
      (List.exists (fun (call : Proc.request) -> ran_bundle call
         && contains call.prog "/web-source/web/") web_calls);
    check "the web bundle travels to the stage and is named to the build jail"
      (List.exists (fun (call : Proc.request) -> call.prog = "rsync"
         && List.exists (fun arg -> contains arg "compute-test:" && String.ends_with ~suffix:"/web/" arg) call.args)
         web_calls
       && List.exists names_bundle web_calls);
    check "the web bundle gives the artifact its own recipe" (web_identity <> identity);
    List.iter (fun (label, entries) ->
      let mock = Proc.Mock.create ~exit_codes:(bundle entries) () in
      let rejected = try ignore (Proc.Mock.run mock (fun () -> build web_env)); false
        with Failure _ -> true in
      check ("a web bundle with " ^ label ^ " is refused before any host work")
        (rejected && not (List.exists (fun (call : Proc.request) ->
          call.prog = "ssh" || call.prog = "rsync") (Proc.Mock.calls mock))))
      [ "no files", [];
        "a subdirectory", [ "index.html", false; "assets", true ];
        "a hidden file", [ "index.html", false; ".env", false ] ];
    let apply = Proc.Mock.create () in
    let applied = try Proc.Mock.run apply (fun () ->
      Dispatcher.artifact_apply env "meals" ~identity ~store ~rollback:false); true
      with Failure _ -> false in
    check "meals source artifact activates through its binary anchor, declared migrate, app name and HTTP readiness"
      (* Each argument is quoted, then the command again for doas sh -c. *)
      (applied && List.exists (fun (call : Proc.request) -> call.prog="ssh"
        && contains (String.concat " " call.args) {|/usr/local/bin/meals'\'' '\''migrate'\'' '\''meals'\''|}
        && contains (String.concat " " call.args) "http://10.40.0.6:4020/health") (Proc.Mock.calls apply)))
