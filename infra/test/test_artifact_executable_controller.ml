open Infra

let check label value =
  if value then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)
let sha bytes = Digestif.SHA256.(to_hex (digest_string bytes))
let write path bytes = Out_channel.with_open_bin path (fun c -> output_string c bytes)
let rec remove path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path
let contains text part =
  let rec loop index = index + String.length part <= String.length text
    && (String.sub text index (String.length part) = part || loop (index + 1)) in
  loop 0

let () =
  let local = Filename.temp_dir "artifact-executable-controller" "" in
  Fun.protect ~finally:(fun () -> remove local) (fun () ->
    (* A package and an upstream binary: strategies the example does not use. *)
    let apps = List.map (fun name ->
      App_config.load (Printf.sprintf "fixtures/executable_apps/%s/app.sexp" name)) [ "garage"; "idp" ] in
    let env : Dispatcher.env = {
      layout = Repo_root.example (); topology = Some (Test_declaration.topology
        ~jails:(App_config.names apps) ~guests:[] ()); compute_target="compute-test"; edge_target="edge-test";
      remote_stage="/tmp/infra-executable-test"; ssh_bin="ssh"; rsync_bin="rsync"; curl_bin="curl";
      config=apps; endpoints=Test_declaration.endpoints (List.map App_config.endpoint apps);
      edge=Test_declaration.edge "example.org";
      edge_ts_ip=None; edge_peer_match=None; caddy_force_build=false; confirm=(fun _ -> true);
      operator="test@test"; lock_token="token-1"; jj_bin="jj";
      now_utc=(fun () -> "2026-10-13T00:00:00Z"); guests=[];
      ops_control_path="/tmp/ops-ssh-%C"; ssh_multiplex=false; source_checkout_override=None;
    } in
    let base = Filename.concat local "base.txz" in
    let bytes = "public executable fixture archive\n" in
    write base "base fixture\n";
    let base_sha256 = sha "base fixture\n" in
    let dependencies = String.concat "" (List.map (fun name ->
      name ^ "\t1.0\t" ^ sha ("archive " ^ name) ^ "\n") ["garage"; "sqlite3"; "s5cmd"]) in
    let observe ?(checksum=sha bytes) ?(abi="FreeBSD:15:amd64\n") call =
      match call.Proc.prog, List.rev call.args with
      | "rsync", destination :: source :: _ when contains source "/output/" ->
          (if contains source "/release.tar" then write destination bytes
           else if contains source "/release.sha256" then write destination (checksum ^ "\n")
           else if contains source "/target-abi" then write destination abi
           else if contains source "/dependencies" then write destination dependencies); 0
      | _ -> 0 in
    let store name =
      let path = Filename.concat local name in Unix.mkdir path 0o700; path in
    let build ?reuse env name store mock =
      try Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_build_executable_store ?reuse
        env name ~ip:"10.40.0.200" ~base_archive:base ~base_sha256 ~store))
      with Failure message -> Error message in
    List.iter (fun name ->
      let store = store name in
      let mock = Proc.Mock.create ~exit_codes:observe () in
      let identity = match build env name store mock with Ok x -> x | Error e -> failwith e in
      let manifest, archive = match Artifact_store.load ~root:store ~identity with
        | Ok x -> x | Error e -> failwith e in
      check (name ^ " store records a real typed origin, never a made-up source commit")
        (match name, manifest.input with
         | "garage", Artifact_manifest.Package_archives "garage" -> true
         | "idp", Artifact_manifest.Upstream_binary x ->
             x.version = "v2.16.0" && contains x.url "/v2.16.0/idp_freebsd_amd64"
         | _ -> false);
      let calls = Proc.Mock.calls mock in
      check (name ^ " cleanup precedes lock release and publication")
        (match List.rev calls with
         | release :: cleanup :: _ -> release.prog = "ssh" && cleanup.prog = "ssh"
           && contains (String.concat " " cleanup.args) "artifact-executable-cleanup:"
         | _ -> false);
      check (name ^ " never stages a source checkout or invokes jj")
        (not (List.exists (fun (c : Proc.request) -> c.prog = "jj"
          || contains (String.concat " " c.args) "/source/") calls));
      let mock = Proc.Mock.create () in
      check (name ^ " explicit reuse pins verified recipe and closure without remote calls")
        (build ~reuse:identity env name store mock = Ok identity && Proc.Mock.calls mock = []);
      let apply_mock = Proc.Mock.create () in
      let applied = try Ok (Proc.Mock.run apply_mock (fun () -> Dispatcher.artifact_apply env name
        ~store ~identity ~rollback:false)) with Failure message -> Error message in
      check (name ^ " typed store artifact reaches ABI/anchor-gated lifecycle") (applied = Ok ());
      let calls = Proc.Mock.calls apply_mock in
      let command = calls |> List.filter (fun (c : Proc.request) -> c.prog = "ssh")
        |> List.map (fun c -> String.concat " " c.Proc.args) |> String.concat "\n" in
      check (name ^ " routes declared health policy and legacy binary anchor")
        (if name = "garage" then contains command "http://10.20.0.4:3900/"
          && contains command "INFRA_ARTIFACT_HTTP_STATUS=403" && contains command "/usr/local/bin/garage"
          && contains command "INFRA_ARTIFACT_SERVICE_STATUS=process"
         else contains command "http://10.20.0.5:1411/" && contains command "/usr/local/bin/idp"
          && contains command "INFRA_ARTIFACT_SERVICE_STATUS=rc");
      (* The status is the declaration's, not the package's name. *)
      if name = "garage" then begin
        let garage = Option.get (App_config.find env.config "garage") in
        let strategy = match Strategy_config.parse ~strategy:(Sexplib.Sexp.Atom "freebsd_package")
            ~config:(Sexplib.Sexp.of_string "((packages (garage)) (check_path /))") with
          | Ok s -> s | Error _ -> failwith "strategy fixture" in
        let undeclared = match App_config.create ~env_names:garage.env_names ~endpoint:garage.endpoint
            ~strategy ~hooks:garage.hooks ~extra_steps:garage.extra_steps () with
          | Ok app -> app | Error _ -> failwith "app fixture" in
        let env = { env with config = List.map (fun (app : App_config.t) ->
          if app.endpoint.name = "garage" then undeclared else app) env.config } in
        let mock = Proc.Mock.create () in
        ignore (Proc.Mock.run mock (fun () -> Dispatcher.artifact_apply env name ~store ~identity ~rollback:false));
        let command = Proc.Mock.calls mock |> List.filter (fun (c : Proc.request) -> c.prog = "ssh")
          |> List.map (fun c -> String.concat " " c.Proc.args) |> String.concat "\n" in
        check "a package without a declared check_status waits for any success"
          (contains command "INFRA_ARTIFACT_HTTP_STATUS=success" && contains command "http://10.20.0.4:3900/");
        check "a package without a declared service_status trusts its rc status"
          (contains command "INFRA_ARTIFACT_SERVICE_STATUS=rc")
      end;
      check (name ^ " snapshots/transfers shared health helper")
        (List.exists (fun (c : Proc.request) -> c.prog = "rsync"
          && contains (String.concat " " c.args) "/artifact_check_health.sh") calls);
      let wrong_input = match manifest.input with
        | Artifact_manifest.Package_archives _ -> Artifact_manifest.Package_archives "sqlite3"
        | Artifact_manifest.Upstream_binary x ->
            Artifact_manifest.Upstream_binary {x with url="https://example.org/other-binary"}
        | _ -> assert false in
      let wrong = match Artifact_manifest.create_input ~name ~input:wrong_input
        ~target_abi:manifest.target_abi ~dependencies:manifest.dependencies
        ~recipe_sha256:manifest.recipe_sha256 ~release_name:manifest.release_name
        ~archive_sha256:manifest.archive_sha256 with Ok x -> x | Error e -> failwith e in
      (match Artifact_store.publish ~root:store ~manifest:wrong ~archive with Ok _ -> () | Error e -> failwith e);
      let mock = Proc.Mock.create () in
      let refused = try Ok (Proc.Mock.run mock (fun () -> Dispatcher.artifact_apply env name
        ~store ~identity:(Artifact_manifest.identity wrong) ~rollback:false)) with Failure e -> Error e in
      check (name ^ " rejects mismatched typed origin before host work")
        (Result.is_error refused && Proc.Mock.calls mock = []);
      let conversion = Proc.Mock.create () in
      let converted = try Ok (Proc.Mock.run conversion (fun () -> Dispatcher.artifact_apply ~convert:true env name
        ~store ~identity ~rollback:false)) with Failure e -> Error e in
      check (name ^ " conversion snapshots strict binary helper")
        (converted = Ok () && List.exists (fun (c : Proc.request) -> c.prog = "rsync"
          && contains (String.concat " " c.args) "/artifact_convert_binary.sh") (Proc.Mock.calls conversion));
      write archive "tampered\n";
      let mock = Proc.Mock.create () in
      check (name ^ " corrupt reuse refuses without fallback")
        (Result.is_error (build ~reuse:identity env name store mock) && Proc.Mock.calls mock = []);
      write archive bytes;
      let mock = Proc.Mock.create () in
      check (name ^ " missing identity refuses without remote work")
        (Result.is_error (build ~reuse:(String.make 64 '0') env name store mock) && Proc.Mock.calls mock = []);
      let helper_engine = Filename.concat local (name ^ "-helpers") in
      let helpers = Layout.v ~engine:helper_engine ~config:(Layout.config env.layout) in
      List.iter (fun dir -> Unix.mkdir dir 0o700)
        [ helper_engine; Filename.concat helper_engine "compute"; Filename.concat helper_engine "compute/apps"; Layout.lib_dir helpers ];
      List.iter (fun file -> write (Layout.lib_file helpers file)
        (In_channel.with_open_bin (Layout.lib_file env.layout file) In_channel.input_all))
        ["artifact_build_jail.sh"; "artifact_resolve_packages.sh"; "artifact_build_executable.sh"];
      write (Layout.lib_file helpers "artifact_build_executable.sh") "changed helper\n";
      let mock = Proc.Mock.create () in
      check (name ^ " changed helper recipe refuses selected reuse without rebuilding")
        (Result.is_error (build ~reuse:identity {env with layout = helpers} name store mock)
          && Proc.Mock.calls mock = [])) ["garage"; "idp"];
    let test_declaration = Filename.concat local "garagetest.sexp" in
    write test_declaration
      "((name garagetest)(ip 10.40.0.12)(hostname garagetest.invalid)(tailnet_ports ((s3 3900)))(operator_ports ())(strategy freebsd_package)(hooks (bootstrap check))(extra_steps ())(strategy_config ((packages (garage))(check_path /)(check_status 403))))\n";
    let test_app = App_config.load test_declaration in
    let test_env = {env with config=test_app :: env.config;
      topology = Some (Test_declaration.topology ~guests:[]
        ~jails:("garagetest" :: List.map (fun (a : App_config.t) -> a.endpoint.name) env.config) ())} in
    let test_store = store "isolated-garage" in
    let mock = Proc.Mock.create ~exit_codes:observe () in
    let result = build test_env "garagetest" test_store mock in
    check "isolated Garage workload builds its declared garage package, not a garagetest package"
      (Result.is_ok result);
    let identity = match result with Ok value -> value | Error message -> failwith message in
    let manifest = match Artifact_store.load ~root:test_store ~identity with
      | Ok (value, _) -> value | Error message -> failwith message in
    check "isolated Garage manifest separates workload identity from package/executable origin"
      (manifest.name="garagetest" && manifest.release_name="garage"
       && match manifest.input with Artifact_manifest.Package_archives "garage" -> true | _ -> false);
    let apply = Proc.Mock.create () in
    let applied = try Proc.Mock.run apply (fun () -> Dispatcher.artifact_apply test_env "garagetest"
      ~store:test_store ~identity ~rollback:false); true with Failure _ -> false in
    check "isolated Garage lifecycle accepts the package without selecting production garage"
      (applied && List.exists (fun (call : Proc.request) -> call.prog="ssh"
        && List.for_all (contains (String.concat " " call.args))
          ["garagetest"; "http://10.40.0.12:3900/"; "/usr/local/bin/garage"; "INFRA_ARTIFACT_HTTP_STATUS=403"]
        && not (contains (String.concat " " call.args) "http://10.20.0.4:3900/")) (Proc.Mock.calls apply));
    List.iter (fun (label, output) ->
      let store = store label in
      let mock = Proc.Mock.create ~exit_codes:output () in
      check (label ^ " refuses publication")
        (Result.is_error (build env "idp" store mock) && Sys.readdir store = [||]))
      ["bad-checksum", (fun call -> observe ~checksum:(String.make 64 'f') call);
       "malformed-abi", (fun call -> observe ~abi:"FreeBSD:15:amd64\nforged\n" call);
       "wrong-os", (fun call -> observe ~abi:"Linux:x86_64\n" call)];
    List.iter (fun (label, fails) ->
      let store = store label in
      let mock = Proc.Mock.create ~exit_codes:(fun call -> if fails call then 1 else observe call) () in
      check (label ^ " retains stage/lock and never publishes")
        (Result.is_error (build env "idp" store mock) && Sys.readdir store = [||]
          && not (List.exists (fun (call : Proc.request) ->
            contains (String.concat " " call.args) "artifact-executable-cleanup:") (Proc.Mock.calls mock))))
      ["worker-failure", (fun (c : Proc.request) -> c.prog = "ssh" && contains (String.concat " " c.args) "INFRA_ARTIFACT_KIND=binary");
       "transfer-failure", (fun c -> c.prog = "rsync")];
    let torn_down = store "torn-down-worker-failure" in
    let mock = Proc.Mock.create ~exit_codes:(fun (c : Proc.request) ->
      if c.prog = "ssh" && contains (String.concat " " c.args) "INFRA_ARTIFACT_KIND=binary" then 3
      else observe c) () in
    check "a torn-down worker failure cleans the stage and never publishes"
      (Result.is_error (build env "idp" torn_down mock) && Sys.readdir torn_down = [||]
        && List.exists (fun (call : Proc.request) ->
             contains (String.concat " " call.args) "artifact-executable-cleanup:") (Proc.Mock.calls mock));
    let store = store "cleanup-failure" in
    let mock = Proc.Mock.create ~exit_codes:(fun c ->
      if contains (String.concat " " c.args) "artifact-executable-cleanup:" then 1 else observe c) () in
    let result = build env "idp" store mock in
    let calls = Proc.Mock.calls mock in
    check "failed cleanup keeps the lock and refuses publication"
      (Result.is_error result && Sys.readdir store = [||]
        && (match List.rev calls with
            | last :: _ -> contains (String.concat " " last.args) "artifact-executable-cleanup:"
            | _ -> false)))
