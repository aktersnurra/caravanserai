open Infra

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name
  else (Printf.eprintf "FAIL - %s\n%!" name; exit 1)
let write path value = Out_channel.with_open_bin path (fun channel -> output_string channel value)
let read path = In_channel.with_open_bin path In_channel.input_all
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let contains value needle =
  let rec loop i = i + String.length needle <= String.length value
    && (String.sub value i (String.length needle) = needle || loop (i + 1)) in loop 0
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  end else Unix.unlink path
let jj args = Proc.live (fun () -> Proc.run_checked "jj" args)
let commit checkout description =
  jj ["-R"; checkout; "describe"; "-m"; description]; jj ["-R"; checkout; "new"];
  let code, value = Proc.live (fun () -> Proc.capture "jj"
    ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-"; "--no-graph"; "-T"; "commit_id"]) in
  if code <> 0 then failwith "fixture commit failed" else String.trim value

let () =
  let fixture = Filename.temp_dir "artifact-guest-controller" "" in
  Fun.protect ~finally:(fun () -> remove fixture) (fun () ->
    let source = Filename.concat fixture "source" and repository = Filename.concat fixture "repository" in
    List.iter (fun path -> jj ["git"; "init"; path]) [source; repository];
    write (Filename.concat source "public-source") "public ledger fixture\n";
    let revision = commit source "public ledger source" in
    write (Filename.concat repository "repo") "opam-version: \"2.0\"\n";
    let repository_revision = commit repository "immutable opam input" in
    let store = Filename.concat fixture "store" in Unix.mkdir store 0o700;
    let layout = Repo_root.example () in
    let loaded = match Declaration.load ~layout with Ok value -> value | Error _ -> failwith "declaration fixture" in
    let env : Dispatcher.env = {
      layout; topology = Some (Test_declaration.topology
        ~jails:(List.map (fun (a : App_config.t) -> a.endpoint.name) loaded.apps)
        ~guests:(List.map Guest_config.name loaded.guests) ()); compute_target="compute-test"; edge_target="edge-test";
      remote_stage="/tmp/serai-stage-test"; ssh_bin="ssh"; rsync_bin="rsync"; curl_bin="curl";
      config=loaded.apps; endpoints=loaded.endpoints; edge=loaded.edge;
      edge_ts_ip=None; edge_peer_match=None; caddy_force_build=false; confirm=(fun _ -> true);
      operator="test@test"; lock_token="guest-test"; jj_bin="jj"; now_utc=(fun () -> "2026-10-14T00:00:00Z");
      guests=loaded.guests; ops_control_path="/tmp/ops-ssh-%C"; ssh_multiplex=false; source_checkout_override=Some source;
    } in
    let archive = "verified Linux archive fixture" in
    let repo_receipt = ref "" in
    let output (call : Proc.request) = match call.prog, List.rev call.args with
      | "rsync", destination :: source :: _ when Filename.basename destination = "repository-inventory" ->
          repo_receipt := read source; 0
      | "rsync", destination :: remote :: _ when contains remote "/output/" ->
          let value = match Filename.basename remote with
            | "release.tar" -> archive
            | "release.sha256" -> sha256 archive ^ "\n"
            | "target-abi" -> "Linux:x86_64:glibc_2.36\n"
            | "dependencies" -> "opam-repository\t" ^ repository_revision ^ "\t" ^ sha256 !repo_receipt ^ "\n"
            | _ -> failwith "unexpected output" in write destination value; 0
      | _ -> 0 in
    let build ?reuse ?(compiler="ocaml-variants.5.2.0+ox") ?(repository_revision=repository_revision) ?(store=store) env =
      Dispatcher.artifact_build_guest_store ?reuse env "ledger" ~revision
        ~opam_repository:(repository, repository_revision) ~compiler ~store in
    let mock = Proc.Mock.create ~exit_codes:output () in
    let identity = Proc.Mock.run mock (fun () -> build env) in
    let manifest, public_archive = match Artifact_store.load ~root:store ~identity with
      | Ok value -> value | Error message -> failwith message in
    let source_matches = match manifest.input with
      | Artifact_manifest.Source_commit value -> value = revision | _ -> false in
    check "ledger publishes verified source-v1 with native Linux ABI and exact archive"
      (source_matches && manifest.release_name="ledger" && manifest.target_abi="Linux:x86_64:glibc_2.36"
       && manifest.archive_sha256=sha256 archive);
    let calls = Proc.Mock.calls mock in
    check "ledger builds unprivileged through declared guest and compute host with bound compiler/snapshots"
      (List.exists (fun (call : Proc.request) -> call.prog="ssh" && List.mem "-J" call.args
        && List.mem "compute-test" call.args && List.mem "ledger@10.20.0.10" call.args
        && List.for_all (contains (String.concat " " call.args))
          ["exec sh"; "artifact_build_guest.sh"; "ocaml-variants.5.2.0+ox"; "/source-inventory"; "/repository-inventory"]
        && not (contains (String.concat " " call.args) "su -c")) calls);
    let cleaned = ref false in
    let ordered = List.for_all (fun (call : Proc.request) ->
      let command = String.concat " " call.args in
      if contains command "artifact-guest-cleanup:" then cleaned := true;
      not (contains command {|rm -rf "$lock"|}) || !cleaned) calls in
    check "ledger cleanup is confirmed before guest lock release and publication" (!cleaned && ordered);
    let reused = Proc.Mock.create () in
    check "ledger explicit store selection rehashes and verifies inputs without host work"
      (Proc.Mock.run reused (fun () -> build ~reuse:identity env)=identity && Proc.Mock.calls reused=[]);
    let refuses label action =
      let mock = Proc.Mock.create () in
      let rejected = try ignore (Proc.Mock.run mock action); false with Failure _ -> true in
      check label (rejected && Proc.Mock.calls mock=[]) in
    refuses "ledger compiler changes refuse reuse before host work"
      (fun () -> build ~reuse:identity ~compiler:"ocaml-variants.5.2.0+different" env);
    write (Filename.concat repository "repo") "opam-version: \"2.0\"\n# changed\n";
    let changed = commit repository "changed repository input" in
    refuses "ledger repository changes refuse reuse without a fallback build"
      (fun () -> build ~reuse:identity ~repository_revision:changed env);
    refuses "ledger missing explicit selection refuses before source export or host work"
      (fun () -> build ~reuse:(String.make 64 'f') env);
    List.iter (fun code ->
      let failed_store = Filename.concat fixture ("failed-" ^ string_of_int code) in Unix.mkdir failed_store 0o700;
      let failed = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
        if call.prog="ssh" && contains (String.concat " " call.args) "artifact_build_guest.sh"
        then code else output call) () in
      let rejected = try ignore (Proc.Mock.run failed (fun () -> build ~store:failed_store env)); false with Failure _ -> true in
      let destructive = List.exists (fun (call : Proc.request) -> call.prog="ssh" &&
        (contains (String.concat " " call.args) "artifact-guest-cleanup:"
         || contains (String.concat " " call.args) {|rm -rf "$lock"|})) (Proc.Mock.calls failed) in
      check (Printf.sprintf "ledger worker failure %d retains stage/lock and publishes nothing" code)
        (rejected && not destructive && Array.length (Sys.readdir failed_store)=0)) [1;143;255];
    let apply = Proc.Mock.create () in
    Proc.Mock.run apply (fun () -> Dispatcher.artifact_apply_guest env "ledger" ~identity ~store ~rollback:false);
    check "ledger apply requests terminal root, checks live ABI and preserves external unit/config/state"
      (List.exists (fun (call : Proc.request) -> call.prog="ssh" && List.mem "-t" call.args
        && List.for_all (contains (String.concat " " call.args))
          ["su -c"; "getconf GNU_LIBC_VERSION"; "Linux:x86_64:glibc_2.36"; "artifact_install_guest.sh";
           "artifact_activate_guest.sh"; "http://10.20.0.10:4020/health"]
        && not (List.exists (contains (String.concat " " call.args)) ["daemon-reload"; "provision"; "migrate"]))
        (Proc.Mock.calls apply));
    let unknown = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      if call.prog="ssh" && List.mem "-t" call.args then 255 else 0) () in
    let rejected = try Proc.Mock.run unknown (fun () -> Dispatcher.artifact_apply_guest env "ledger" ~identity ~store ~rollback:false); false with Failure _ -> true in
    let destructive = List.exists (fun (call : Proc.request) -> call.prog="ssh" &&
      (contains (String.concat " " call.args) "rm -rf --" || contains (String.concat " " call.args) {|rm -rf "$lock"|}))
      (List.filter (fun (call : Proc.request) -> not (List.mem "-t" call.args)) (Proc.Mock.calls unknown)) in
    check "ledger uncertain root transport retains stage/lock without cleanup or retry" (rejected && not destructive);
    let convert = Proc.Mock.create () in
    Proc.Mock.run convert (fun () -> Dispatcher.artifact_apply_guest ~convert:true env "ledger" ~identity ~store ~rollback:false);
    check "ledger conversion uses the shared strict binary converter and guest service adapter"
      (List.exists (fun (call : Proc.request) -> call.prog="ssh" && List.mem "-t" call.args
        && List.for_all (contains (String.concat " " call.args))
          ["artifact_convert_binary.sh"; "artifact_service_guest.sh"; "JAIL_ROOT=/"; "/usr/local/bin/ledger"])
        (Proc.Mock.calls convert));
    let other_abi = match Artifact_manifest.create ~name:"ledger" ~source_commit:revision
      ~target_abi:"FreeBSD:15:amd64" ~dependencies:manifest.dependencies ~recipe_sha256:manifest.recipe_sha256
      ~release_name:"ledger" ~archive_sha256:manifest.archive_sha256 with
      | Ok value -> value | Error message -> failwith message in
    (match Artifact_store.publish ~root:store ~manifest:other_abi ~archive:public_archive with
     | Ok _ -> () | Error message -> failwith message);
    refuses "ledger rejects cross-OS artifacts before host work"
      (fun () -> Dispatcher.artifact_apply_guest env "ledger" ~store ~identity:(Artifact_manifest.identity other_abi)
        ~rollback:false; "unreachable");
    (* Nothing about archive is the engine's: another guest builds and installs
       exactly what its own guest.sexp declares. *)
    let archive = Guest_config.of_sexp (Sexplib.Sexp.of_string
      {|((name archive) (ip 10.40.0.12) (hostname archive.example) (tailnet_ports ((http 4012)))
         (operator_ports ()) (login_user builder) (source_checkout ../archive)
         (workload ((project services/archive) (target cmd/archive.exe) (release archive)
                    (service_group archive-svc))))|}) in
    let archive_env = { env with guests = [ archive ];
      topology = Some (Test_declaration.topology ~jails:[] ~guests:[ "archive" ] ()) } in
    let archive_store = Filename.concat fixture "archive" in Unix.mkdir archive_store 0o700;
    let built = Proc.Mock.create ~exit_codes:output () in
    let archive_identity = Proc.Mock.run built (fun () ->
      Dispatcher.artifact_build_guest_store archive_env "archive" ~revision
        ~opam_repository:(repository, repository_revision) ~compiler:"ocaml-variants.5.2.0+ox"
        ~store:archive_store) in
    let commands mock = List.filter_map (fun (call : Proc.request) ->
      if call.prog = "ssh" then Some (String.concat " " call.args) else None) (Proc.Mock.calls mock) in
    let no_ledger mock = not (List.exists (fun c -> contains c "ledger") (commands mock)) in
    check "a declared workload is built from its own project, target and release"
      (List.exists (fun c -> contains c "artifact_build_guest.sh"
         && List.for_all (contains c) ["'services/archive'"; "'cmd/archive.exe'"; "'archive'"]) (commands built)
       && no_ledger built);
    (match Artifact_store.load ~root:archive_store ~identity:archive_identity with
     | Ok (m, _) -> check "a declared workload's artifact is its release"
                      (m.name = "archive" && m.release_name = "archive")
     | Error message -> failwith message);
    let applied = Proc.Mock.create () in
    Proc.Mock.run applied (fun () ->
      Dispatcher.artifact_apply_guest archive_env "archive" ~identity:archive_identity ~store:archive_store
        ~rollback:false);
    check "a declared workload is installed as its release, for its service group"
      (List.exists (fun c -> List.for_all (contains c)
         ["artifact_install_guest.sh"; "archive-svc"; "artifact_activate_guest.sh"; "upgrade";
          "http://10.40.0.12:4012/health"]) (commands applied)
       && no_ledger applied);
    let converted = Proc.Mock.create () in
    Proc.Mock.run converted (fun () ->
      Dispatcher.artifact_apply_guest ~convert:true archive_env "archive" ~identity:archive_identity
        ~store:archive_store ~rollback:false);
    check "a declared workload converts its own legacy executable"
      (List.exists (fun c -> contains c "/usr/local/bin/archive") (commands converted) && no_ledger converted);
    let bare = Guest_config.of_sexp (Sexplib.Sexp.of_string
      {|((name bare) (ip 10.40.0.13) (hostname bare.example) (tailnet_ports ((http 4013)))
         (operator_ports ()) (login_user builder) (source_checkout ../bare))|}) in
    let bare_env = { env with guests = [ bare ];
      topology = Some (Test_declaration.topology ~jails:[] ~guests:[ "bare" ] ()) } in
    refuses "a guest with no workload is refused before any build work"
      (fun () -> Dispatcher.artifact_build_guest_store bare_env "bare" ~revision
        ~opam_repository:(repository, repository_revision) ~compiler:"ocaml-variants.5.2.0+ox"
        ~store:archive_store);
    refuses "a guest with no workload is refused before any apply work"
      (fun () -> Dispatcher.artifact_apply_guest bare_env "bare" ~identity:archive_identity
        ~store:archive_store ~rollback:false; "unreachable");
    let failed_store = Filename.concat fixture "cleanup-failed" in Unix.mkdir failed_store 0o700;
    let cleanup = Proc.Mock.create ~exit_codes:(fun (call : Proc.request) ->
      if call.prog="ssh" && contains (String.concat " " call.args) "artifact-guest-cleanup:" then 1 else output call) () in
    let rejected = try ignore (Proc.Mock.run cleanup (fun () -> build ~store:failed_store env)); false with Failure _ -> true in
    check "ledger cleanup failure retains guest lock and refuses publication"
      (rejected && Array.length (Sys.readdir failed_store)=0 && not (List.exists (fun (call : Proc.request) ->
        call.prog="ssh" && contains (String.concat " " call.args) {|rm -rf "$lock"|}) (Proc.Mock.calls cleanup))))
