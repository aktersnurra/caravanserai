(* Building, storing, applying and reverting artifacts in jails. Part of
   Dispatcher. *)
open Remote_host

(* Prepare one verified Phoenix release in its jail without changing the
   active symlink or service. This is a building block for the artifact
   lifecycle, deliberately separate from today's deploy hook. The archive
   comes from a trusted build; artifact_install.sh verifies its SHA-256 again
   on the compute host. *)
let artifact_install env app_name ~identity ~archive ~sha256 =
  let app = find_app env app_name in
  let env = app_env env app_name in
  (match app.strategy with
  | Strategy_config.Freebsd_native_elixir _ -> ()
  | _ -> Run_state.fail ~cause:"unsupported_for_workload" "artifact install currently supports Phoenix releases only");
  let safe c = is_stage_char c || c = '.' in
  if identity = "" || identity = "." || identity = ".."
     || String.length identity > 128 || not (String.for_all safe identity) then
    Run_state.fail ~cause:"invalid_argument" "invalid artifact identity";
  if String.length sha256 <> 64 || not (String.for_all (function
      | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false) sha256) then
    Run_state.fail ~cause:"invalid_argument" "invalid artifact SHA-256";
  (match Unix.lstat archive with
  | { Unix.st_kind = Unix.S_REG; _ } -> ()
  | _ -> Run_state.fail ~cause:"invalid_argument" "artifact archive must be a regular file"
  | exception Unix.Unix_error _ -> Run_state.fail ~cause:"input_unavailable" "artifact archive does not exist");
  validate_stage env.remote_stage;
  let stage = Printf.sprintf "%s/artifacts/%s/%s" env.remote_stage app.endpoint.name identity in
  let installer = Layout.lib_file env.layout "artifact_install.sh" in
  announce "install artifact %s %s (prepare only)" app.endpoint.name identity;
  Run_state.changing ();
  with_locks env ~command:("artifact install " ^ app.endpoint.name) [ Compute_host ] (fun _records ->
      secure_remote_stage env ~target:env.compute_target
        ~subtree:("artifacts/" ^ app.endpoint.name ^ "/" ^ identity);
      rsync_checked env
        [ "-az"; "--no-owner"; "--no-group"; "--"; archive;
          Printf.sprintf "%s:%s/release.tar" env.compute_target stage ];
      rsync_checked env
        [ "-az"; "--no-owner"; "--no-group"; "--"; installer;
          Printf.sprintf "%s:%s/artifact_install.sh" env.compute_target stage ];
      let command =
        String.concat " "
          ("doas sh" :: List.map Shell.quote
            [ stage ^ "/artifact_install.sh"; app.endpoint.name; identity;
              stage ^ "/release.tar"; sha256; app.endpoint.name; "-" ])
      in
      ssh_checked env [ env.compute_target; command ])

(* artifact_build_jail.sh exit status: the build failed or was refused and
   its jail, address, devfs and root are gone, so stage and lock can go too. *)
let build_torn_down_exit = 3

(* Run the remote build-jail command. Only success and a torn-down failure
   leave nothing to inspect; anything else stays uncertain. *)
let run_build_jail env retention command =
  retention.uncertain <- true;
  match ssh_run env [ env.compute_target; command ] with
  | 0 -> retention.uncertain <- false
  | code when code = build_torn_down_exit ->
      retention.uncertain <- false;
      Run_state.fail ~cause:"build_failed" "artifact build: the build failed (output above); its build jail was removed"
  | code ->
      Run_state.fail ~cause:"command_failed" (Printf.sprintf
        "artifact build: remote exited %d; the build jail may remain, inspect before unlocking" code)

type artifact_build_candidate = {
  source_commit : string;
  source_inventory_sha256 : string;
  target_abi : string;
  recipe_sha256 : string;
  archive_sha256 : string;
  manifest : Artifact_manifest.t;
}

let artifact_file_sha256 path =
  let not_regular = "artifact build: input must be a regular file" in
  try Fs.file_sha256 ~not_regular path
  with Failure message when message = not_regular -> Run_state.fail ~cause:"invalid_argument" message

(* The inventory of the tree staged at [root], written as [receipt] to
   travel with it: its identity. *)
let write_inventory ~root ~commit ~receipt =
  let inventory = ok_or_fail ~cause:"invalid_source" (Source_inventory.create ~root ~commit) in
  write_private receipt (Source_inventory.canonical inventory);
  Source_inventory.identity inventory

(* A staged opam repository carries its [repo] marker file. *)
let require_opam_repository path =
  match Unix.lstat (Filename.concat path "repo") with
  | { Unix.st_kind = Unix.S_REG; _ } -> ()
  | _ -> Run_state.fail ~cause:"invalid_source" "artifact build: invalid opam repository marker"
  | exception Unix.Unix_error _ -> Run_state.fail ~cause:"invalid_source" "artifact build: missing opam repository marker"

(* The engine's helpers [names] copied privately into [local], so what is
   sent is what was hashed: each as (name, copy, digest). *)
let snapshot_helpers env ~context ~local names =
  List.map (fun name ->
    let snapshot = Filename.concat local name in
    let source = Layout.lib_file env.layout name in
    In_channel.with_open_bin source (fun input ->
      if (Unix.lstat source).Unix.st_kind <> Unix.S_REG
         || (Unix.fstat (Unix.descr_of_in_channel input)).Unix.st_kind <> Unix.S_REG
      then Run_state.fail ~cause:"input_unavailable" (context ^ ": unsafe helper");
      write_private snapshot (In_channel.input_all input));
    name, snapshot, artifact_file_sha256 snapshot) names

(* What a build sent back, read no further than [limit]. *)
let read_evidence ~dir name limit =
  let file = Filename.concat dir name in
  match Unix.lstat file with
  | { Unix.st_kind = Unix.S_REG; _ } ->
      In_channel.with_open_bin file (fun channel ->
        if In_channel.length channel > Int64.of_int limit then
          Run_state.fail ~cause:"invalid_build_output" ("artifact build: oversized evidence: " ^ name);
        In_channel.input_all channel)
  | _ -> Run_state.fail ~cause:"invalid_build_output" ("artifact build: unsafe evidence: " ^ name)
  | exception Unix.Unix_error _ -> Run_state.fail ~cause:"invalid_build_output" ("artifact build: missing evidence: " ^ name)

(* The target-abi file's one line. *)
let abi_evidence ~dir =
  match String.split_on_char '\n' (read_evidence ~dir "target-abi" 129) with
  | [ value; "" ] -> value
  | _ -> Run_state.fail ~cause:"invalid_build_output" "artifact build: invalid target ABI"

let dependency_evidence ~dir =
  ok_or_fail ~cause:"invalid_build_output" (Artifact_manifest.dependencies_of_inventory (read_evidence ~dir "dependencies" 1048576))

(* The base archive a build starts from: a regular file with the declared
   digest. [context] prefixes the refusal. *)
let require_base_archive ~context ~base_archive ~base_sha256 =
  if not (is_sha256 base_sha256) then Run_state.fail ~cause:"invalid_argument" (context ^ ": invalid base SHA-256");
  (match Unix.lstat base_archive with
   | { Unix.st_kind = Unix.S_REG; _ } -> ()
   | _ -> Run_state.fail ~cause:"invalid_argument" (context ^ ": base archive must be regular")
   | exception Unix.Unix_error _ -> Run_state.fail ~cause:"input_unavailable" (context ^ ": base archive not found"));
  if artifact_file_sha256 base_archive <> base_sha256 then
    Run_state.fail ~cause:"input_mismatch" (context ^ ": base archive SHA-256 mismatch")

(* The lib32 archive extracted over the base: checked like the base. *)
let require_lib32_archive ~context (archive, sha256) =
  if not (is_sha256 sha256) then Run_state.fail ~cause:"invalid_argument" (context ^ ": invalid lib32 SHA-256");
  (match Unix.lstat archive with
   | { Unix.st_kind = Unix.S_REG; _ } -> ()
   | _ -> Run_state.fail ~cause:"invalid_argument" (context ^ ": lib32 archive must be regular")
   | exception Unix.Unix_error _ -> Run_state.fail ~cause:"input_unavailable" (context ^ ": lib32 archive not found"));
  if artifact_file_sha256 archive <> sha256 then
    Run_state.fail ~cause:"input_mismatch" (context ^ ": lib32 archive SHA-256 mismatch")

(* The lock token names the build jail and its stage directory. *)
let require_build_token env ~refusal =
  if env.lock_token = "" || String.length env.lock_token > 32
     || not (String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) env.lock_token)
  then Run_state.fail ~cause:"invalid_environment" refusal

(* A pinned binary's URL: its template with ${VERSION} replaced. *)
let binary_url ~context ~template ~version =
  match String.split_on_char '$' template with
  | [ before; after ] when String.starts_with ~prefix:"{VERSION}" after ->
      before ^ version ^ String.sub after 9 (String.length after - 9)
  | _ -> Run_state.fail ~cause:"invalid_declaration" (context ^ ": invalid binary URL template")

let artifact_source_configuration env app_name opam_repository =
  match (find_app env app_name).strategy, opam_repository with
  | Strategy_config.Freebsd_native_elixir value, None ->
      value.repo_path, value.release_name, value.packages, None
  | Strategy_config.Freebsd_native_ocaml value, Some _ ->
      value.repo_path, app_name, value.packages, Some ("ocaml-base-compiler." ^ value.ocaml_switch)
  | Strategy_config.Freebsd_native_ocaml _, None ->
      Run_state.fail ~cause:"invalid_argument" "artifact build: OCaml requires immutable opam repository checkout and revision"
  | Strategy_config.Freebsd_native_elixir _, Some _ ->
      Run_state.fail ~cause:"invalid_argument" "artifact build: Phoenix does not accept opam repository inputs"
  | _ -> Run_state.fail ~cause:"unsupported_for_workload" "artifact build: expected declared source strategy"

let artifact_web_bundle env app_name =
  match (find_app env app_name).strategy with
  | Strategy_config.Freebsd_native_ocaml value -> value.web_bundle
  | _ -> None

(* Built on the controller: the bundle needs tools the FreeBSD build jail
   lacks. It runs in a copy of the staged source, so the snapshot the build
   jail verifies stays as committed, and must leave a flat set of regular
   files with plain names. *)
let artifact_build_web_bundle ~source ~script ~local =
  let work = Filename.concat local "web-source" in
  let out = Filename.concat local "web" in
  Proc.run_checked "cp" [ "-R"; "-p"; "--"; source; work ];
  Proc.run_checked (Filename.concat work script) [ out ];
  (match Unix.lstat out with
   | { Unix.st_kind = Unix.S_DIR; _ } -> ()
   | _ -> Run_state.fail ~cause:"build_failed" "web bundle: output must be a directory"
   | exception Unix.Unix_error _ -> Run_state.fail ~cause:"build_failed" "web bundle: no output");
  let names = Sys.readdir out in
  if names = [||] then Run_state.fail ~cause:"build_failed" "web bundle: empty output";
  Array.iter (fun name ->
    if name.[0] = '.' || not (String.for_all (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true | _ -> false) name)
    then Run_state.fail ~cause:"build_failed" ("web bundle: unsafe file name " ^ String.escaped name);
    match Unix.lstat (Filename.concat out name) with
    | { Unix.st_kind = Unix.S_REG; _ } -> ()
    | _ -> Run_state.fail ~cause:"build_failed" ("web bundle: not a regular file: " ^ name)) names;
  out

let artifact_source_recipe ?opam_snapshots env ~local ~base_sha256 ~lib32_sha256 ~release_name ~packages ~compiler ~opam_repository ~web_bundle =
  Progress.phase "recipe";
  let out = Filename.concat local "recipe" in
  let staged, repository = match compiler, opam_repository with
    | None, None when Option.is_none web_bundle -> Artifact_recipe.stage ~lib_dir:(Layout.lib_dir env.layout) ~out
        ~base_sha256 ~lib32_sha256 ~release_name ~packages, None
    | Some compiler, Some (checkout, revision) ->
        let staged = match opam_snapshots with
          | Some cache -> Source_snapshot.stage_cached ~jj_bin:env.jj_bin ~checkout ~revision ~cache
          | None ->
              let path = Filename.concat local "repository" in
              Source_snapshot.stage ~jj_bin:env.jj_bin ~checkout ~revision ~out:path
              |> Result.map (fun commit -> commit, path) in
        let commit, path = ok_or_fail ~cause:"source_unavailable" (staged) in
        let receipt = Filename.concat local "repository-inventory" in
        let sha256 = write_inventory ~root:path ~commit ~receipt in
        require_opam_repository path;
        Artifact_recipe.stage_ocaml ~lib_dir:(Layout.lib_dir env.layout) ~out ~base_sha256 ~lib32_sha256 ~release_name ~packages
          ~compiler ~repository_commit:commit ~repository_sha256:sha256 ~web_bundle, Some (path, receipt, sha256)
    | _ -> Run_state.fail ~cause:"invalid_declaration" "artifact build: inconsistent source recipe inputs" in
  let recipe = ok_or_fail ~cause:"source_unavailable" (staged) in
  recipe, repository

let artifact_build_candidate ?checkout ?opam_repository ?opam_snapshots ?lib32 env app_name ~revision ~ip ~base_archive ~base_sha256 ~out =
  let app = find_app env app_name in
  let env = app_env env app_name in
  let repo_path, release_name, packages, compiler = artifact_source_configuration env app_name opam_repository in
  let repo_path = Option.value checkout ~default:repo_path in
  validate_stage env.remote_stage;
  let declared = Network_endpoint.to_list env.endpoints |> List.map (fun endpoint -> endpoint.Network_endpoint.ip) in
  ok_or_fail ~cause:"invalid_argument" (Jail_test.validate_ip ~host:(jail_host env app_name) ~declared ip);
  require_base_archive ~context:"artifact build" ~base_archive ~base_sha256;
  Option.iter (require_lib32_archive ~context:"artifact build") lib32;
  let lib32_sha256 = Option.map snd lib32 in
  if out = "" || out = "." || out = ".." then Run_state.fail ~cause:"invalid_argument" "artifact build: invalid output";
  (match Unix.lstat out with
   | _ -> Run_state.fail ~cause:"already_exists" "artifact build: output already exists"
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  (match Unix.lstat (Filename.dirname out) with
   | { Unix.st_kind = Unix.S_DIR; _ } -> ()
   | _ -> Run_state.fail ~cause:"invalid_argument" "artifact build: output parent must be a directory"
   | exception Unix.Unix_error _ -> Run_state.fail ~cause:"invalid_argument" "artifact build: output parent not found");
  require_build_token env ~refusal:"artifact build: invalid lock token for build jail";
  let local = Filename.temp_dir "serai-artifact-build" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    Progress.phase "source";
    let source = Filename.concat local "source" in
    let source_commit, source_inventory_sha256, inventory_path =
      Progress.with_duration ~phase:"source" ~parent:None (fun () ->
      let source_commit = ok_or_fail ~cause:"source_unavailable" (Source_snapshot.stage ~jj_bin:env.jj_bin
        ~checkout:repo_path ~revision ~out:source) in
      let inventory_path = Filename.concat local "inventory" in
      source_commit, write_inventory ~root:source ~commit:source_commit ~receipt:inventory_path, inventory_path) in
    let web_bundle = artifact_web_bundle env app_name in
    let recipe_dir = Filename.concat local "recipe" in
    let recipe, repository = artifact_source_recipe ?opam_snapshots env ~local ~base_sha256 ~lib32_sha256
      ~release_name ~packages ~compiler ~opam_repository ~web_bundle in
    let web = Option.map (fun script ->
      Progress.phase "web-bundle";
      Progress.with_duration ~phase:"web-bundle" ~parent:None (fun () ->
        artifact_build_web_bundle ~source ~script ~local)) web_bundle in
    let recipe_sha256 = recipe.sha256 in
    let output_temp = Filename.temp_dir ~temp_dir:(Filename.dirname out) "serai-candidate-" "" in
    Fun.protect
      ~finally:(fun () -> if Sys.file_exists output_temp then remove_tree output_temp)
      (fun () ->
        let subtree = "artifact-build/" ^ app.endpoint.name ^ "/" ^ env.lock_token in
        let stage = env.remote_stage ^ "/" ^ subtree in
        let remote path = Printf.sprintf "%s:%s/%s" env.compute_target stage path in
        let cleanup_script = String.concat "\n"
          [ "set -eu";
            "# artifact-build-cleanup:";
            "parent=" ^ Shell.quote (env.remote_stage ^ "/artifact-build/" ^ app.endpoint.name);
            "stage=" ^ Shell.quote stage;
            {|[ -d "$parent" ] && [ ! -L "$parent" ] || exit 1|};
            {|[ -d "$stage" ] && [ ! -L "$stage" ] || exit 1|};
            {|rm -rf -- "$stage"|};
            {|[ ! -e "$stage" ] && [ ! -L "$stage" ]|} ] in
        if not (approved env ~operation:"artifact.build"
                  ~facts:[ "app", app_name; "host", host_label env Compute_host; "builder_ip", ip;
                           "base_sha256", base_sha256; "source_commit", source_commit;
                           "recipe_sha256", recipe_sha256 ]
                  (Printf.sprintf "Build %s at %s in a build jail on %s?"
                     app_name (Hex.short source_commit) (host_label env Compute_host)))
        then Run_state.fail ~cause:"declined" "artifact build: cancelled";
        with_retained_stage env ~command:("artifact build " ^ app.endpoint.name) ~host:Compute_host ~stage
          ~retained:(Printf.sprintf
            "artifact build: stage %s and host lock retained; inspect failed/uncertain build before serai unlock %s."
            stage (host_label env Compute_host))
          ~prepare:(fun retention ->
            uncertain_while retention (fun () -> secure_remote_stage env ~target:env.compute_target ~subtree))
          ~cleanup:(fun () ->
            Progress.with_duration ~phase:"controller-cleanup" ~parent:None (fun () ->
              ssh_checked env [env.compute_target; "doas sh -c " ^ Shell.quote cleanup_script]))
          (fun retention ->
            let rsync phase source destination =
              uncertain_while retention (fun () ->
                Progress.with_duration ~phase ~parent:None (fun () -> rsync_checked env
                  [ "-az"; "--no-owner"; "--no-group"; "--"; source; destination ])) in
            Progress.phase "transfer";
            rsync "outbound-transfer" (source ^ "/") (remote "source/");
            rsync "outbound-transfer" inventory_path (remote "inventory");
            rsync "outbound-transfer" base_archive (remote "base.txz");
            Option.iter (fun (archive, _) -> rsync "outbound-transfer" archive (remote "lib32.txz")) lib32;
            let script name = Filename.concat recipe_dir name in
            List.iter (fun (name, _) -> rsync "outbound-transfer" (script name) (remote name)) recipe.scripts;
            Option.iter (fun (path, receipt, _) ->
              rsync "outbound-transfer" (path ^ "/") (remote "repository/");
              rsync "outbound-transfer" receipt (remote "repository-inventory")) repository;
            Option.iter (fun web -> rsync "outbound-transfer" (web ^ "/") (remote "web/")) web;
            let build_args =
              [ stage ^ "/artifact_build_jail.sh";
                "infra-build-" ^ app.endpoint.name ^ "-" ^ env.lock_token; ip;
                stage ^ "/base.txz"; base_sha256; stage ^ "/source";
                stage ^ "/inventory"; source_inventory_sha256;
                release_name; stage ^ "/output" ] @ packages in
            let script_checks = List.map (fun (name, digest) ->
              String.concat "\n"
                [ "file=" ^ Shell.quote (stage ^ "/" ^ name);
                  {|[ -f "$file" ] && [ ! -L "$file" ] || exit 1|};
                  Printf.sprintf {|[ "$(sha256 -q "$file")" = %s ] || exit 1|}
                    (Shell.quote digest) ]) recipe.scripts in
            let command = "doas sh -c " ^ Shell.quote
              (String.concat "\n" ([ "set -eu" ] @ script_checks @
                [ "SERAI_LOCK_HELD=1 SERAI_PROGRESS_JSONL=" ^ (if Progress.is_enabled () then "1 " else "0 ")
                  ^ (match lib32 with
                    | None -> ""
                    | Some (_, sha256) -> "SERAI_LIB32_ARCHIVE=" ^ Shell.quote (stage ^ "/lib32.txz")
                        ^ " SERAI_LIB32_SHA256=" ^ Shell.quote sha256 ^ " ")
                  ^ (match compiler, repository with
                    | Some compiler, Some (_, _, digest) ->
                        String.concat " " ["SERAI_ARTIFACT_KIND=ocaml";
                          "SERAI_OCAML_COMPILER=" ^ Shell.quote compiler;
                          "SERAI_OPAM_REPOSITORY=" ^ Shell.quote (stage ^ "/repository");
                          "SERAI_OPAM_INVENTORY=" ^ Shell.quote (stage ^ "/repository-inventory");
                          "SERAI_OPAM_INVENTORY_SHA256=" ^ Shell.quote digest]
                        ^ (if Option.is_none web then "" else " SERAI_WEB_BUNDLE=" ^ Shell.quote (stage ^ "/web")) ^ " "
                    | _ -> "") ^ "exec sh "
                  ^ String.concat " " (List.map Shell.quote build_args) ])) in
            Progress.phase "build";
            Progress.with_duration ~phase:"remote-total" ~parent:None (fun () ->
              run_build_jail env retention command);
            Progress.phase "transfer";
            rsync "return-transfer" (remote "output/release.tar") (Filename.concat output_temp "release.tar");
            rsync "return-transfer" (remote "output/release.sha256") (Filename.concat output_temp "release.sha256");
            rsync "return-transfer" (remote "output/target-abi") (Filename.concat output_temp "target-abi");
            rsync "return-transfer" (remote "output/dependencies") (Filename.concat output_temp "dependencies"));
        Progress.phase "verify";
        let archive_sha256, target_abi, dependencies =
          Progress.with_duration ~phase:"verification" ~parent:None (fun () ->
          let dir = output_temp in
          let archive = Filename.concat dir "release.tar" in
          let archive_sha256 = String.trim (read_evidence ~dir "release.sha256" 65) in
          if not (is_sha256 archive_sha256)
             || (Unix.lstat archive).Unix.st_kind <> Unix.S_REG
             || artifact_file_sha256 archive <> archive_sha256 then
            Run_state.fail ~cause:"invalid_build_output" "artifact build: candidate archive SHA-256 mismatch";
          let target_abi = abi_evidence ~dir in
          (match String.split_on_char ':' target_abi with
           | [ "FreeBSD"; major; arch ] when major <> "" && arch <> ""
               && String.for_all (function '0' .. '9' -> true | _ -> false) major
               && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false) arch -> ()
           | _ -> Run_state.fail ~cause:"invalid_build_output" "artifact build: invalid target ABI");
          let dependencies = dependency_evidence ~dir in
          archive_sha256, target_abi, dependencies) in
        let manifest = ok_or_fail ~cause:"invalid_build_output" (Artifact_manifest.create ~name:app_name ~source_commit ~target_abi
          ~dependencies ~recipe_sha256 ~release_name ~archive_sha256) in
        Out_channel.with_open_bin (Filename.concat output_temp "manifest") (fun channel ->
          output_string channel (Artifact_manifest.canonical manifest));
        (match Unix.lstat out with
         | _ -> Run_state.fail ~cause:"already_exists" "artifact build: output already exists"
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
        Unix.rename output_temp out;
        { source_commit; source_inventory_sha256; target_abi; recipe_sha256; archive_sha256; manifest }))

let artifact_build_store ?reuse ?checkout ?opam_repository ?opam_snapshots ?lib32 env app_name ~revision ~ip ~base_archive ~base_sha256 ~store =
  ok_or_fail ~cause:"store_failed" (Artifact_store.validate_root store);
  let local = Filename.temp_dir "serai-artifact-publish" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    match reuse with
    | None ->
        let out = Filename.concat local "candidate" in
        let candidate = artifact_build_candidate ?checkout ?opam_repository ?opam_snapshots ?lib32 env app_name ~revision ~ip
          ~base_archive ~base_sha256 ~out in
        Progress.phase "publish";
        Progress.with_duration ~phase:"publication" ~parent:None (fun () ->
        match Artifact_store.publish ~root:store ~manifest:candidate.manifest
          ~archive:(Filename.concat out "release.tar") with
         | Ok _ -> Artifact_manifest.identity candidate.manifest
         | Error message -> Run_state.fail ~cause:"store_failed" message)
    | Some identity ->
        Progress.phase "reuse";
        let manifest, _ = ok_or_fail ~cause:"store_failed" (Artifact_store.load ~root:store ~identity) in
        let repo_path, release_name, packages, compiler =
          artifact_source_configuration env app_name opam_repository in
        let repo_path = Option.value checkout ~default:repo_path in
        require_base_archive ~context:"artifact reuse" ~base_archive ~base_sha256;
        Option.iter (require_lib32_archive ~context:"artifact reuse") lib32;
        let source_commit = ok_or_fail ~cause:"source_unavailable" (Source_snapshot.stage ~jj_bin:env.jj_bin
          ~checkout:repo_path ~revision ~out:(Filename.concat local "source")) in
        let recipe, _ = artifact_source_recipe ?opam_snapshots env ~local ~base_sha256
          ~lib32_sha256:(Option.map snd lib32) ~release_name
          ~packages ~compiler ~opam_repository ~web_bundle:(artifact_web_bundle env app_name) in
        let same_source = match manifest.input with
          | Artifact_manifest.Source_commit commit -> commit = source_commit
          | _ -> false in
        if manifest.name <> app_name || not same_source
           || manifest.recipe_sha256 <> recipe.sha256
           || manifest.release_name <> release_name
        then Run_state.fail ~cause:"input_mismatch" "artifact reuse: requested inputs do not match stored artifact";
        identity)

let artifact_build_executable_store ?reuse env app_name ~ip ~base_archive ~base_sha256 ~store =
  let app = find_app env app_name in
  let env = app_env env app_name in
  let release, packages, input, worker_env = match app.strategy with
    | Strategy_config.Freebsd_package s ->
        let principal = match s.packages with [package] -> package | _ -> app_name in
        principal, s.packages, Artifact_manifest.Package_archives principal,
        ["SERAI_ARTIFACT_KIND=package"]
    | Strategy_config.Fetch_binary s ->
        let url = binary_url ~context:"artifact build" ~template:s.binary_url_template ~version:s.version in
        s.binary_name, s.packages,
        Artifact_manifest.Upstream_binary {version=s.version; url; sha256=s.binary_sha256},
        ["SERAI_ARTIFACT_KIND=binary"; "SERAI_EXECUTABLE_SOURCE=" ^ Shell.quote url;
         "SERAI_EXECUTABLE_SHA256=" ^ Shell.quote s.binary_sha256]
    | _ -> Run_state.fail ~cause:"unsupported_for_workload" "artifact build: expected package or pinned executable strategy" in
  ok_or_fail ~cause:"store_failed" (Artifact_store.validate_root store);
  validate_stage env.remote_stage;
  let declared = Network_endpoint.to_list env.endpoints |> List.map (fun e -> e.Network_endpoint.ip) in
  ok_or_fail ~cause:"invalid_argument" (Jail_test.validate_ip ~host:(jail_host env app_name) ~declared ip);
  require_base_archive ~context:"artifact build" ~base_archive ~base_sha256;
  require_build_token env ~refusal:"artifact build: invalid lock token";
  let local = Filename.temp_dir "serai-executable-build" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    Progress.phase "recipe";
    let recipe_dir = Filename.concat local "recipe" in
    let recipe = ok_or_fail ~cause:"input_unavailable" (Artifact_recipe.stage_executable ~lib_dir:(Layout.lib_dir env.layout) ~out:recipe_dir
      ~base_sha256 ~release_name:release ~packages ~input) in
    match reuse with
    | Some identity ->
        Progress.phase "reuse";
        let manifest, _ = ok_or_fail ~cause:"store_failed" (Artifact_store.load ~root:store ~identity) in
        if manifest.name <> app_name || manifest.input <> input
           || manifest.recipe_sha256 <> recipe.sha256 || manifest.release_name <> release
        then Run_state.fail ~cause:"input_mismatch" "artifact reuse: requested inputs do not match stored artifact";
        identity
    | None ->
    if not (approved env ~operation:"artifact.build"
              ~facts:[ "app", app_name; "host", host_label env Compute_host; "builder_ip", ip;
                       "base_sha256", base_sha256; "recipe_sha256", recipe.sha256 ]
              ("Build verified executable artifact for " ^ app_name ^ "?"))
    then Run_state.fail ~cause:"declined" "artifact build: cancelled";
    let subtree = "artifact-executable/" ^ app_name ^ "/" ^ env.lock_token in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let remote name = env.compute_target ^ ":" ^ stage ^ "/" ^ name in
    (* A remote exit below 128 is the command's own answer; a signal's
       128+n or ssh's failure leaves the outcome unknown. *)
    let remote_exit retention command =
      retention.uncertain <- true;
      let code = ssh_run env [env.compute_target; command] in
      retention.uncertain <- code >= 128;
      code in
    let refuse_exit code =
      if code <> 0 then Run_state.fail ~cause:"command_failed" (Printf.sprintf "artifact build: remote exited %d" code) in
    with_retained_stage env ~command:("artifact build " ^ app_name) ~host:Compute_host ~stage
      ~retained:(Printf.sprintf
        "artifact build: stage %s and host lock retained; inspect failed/uncertain build before serai unlock %s."
        stage (host_label env Compute_host))
      ~prepare:(fun retention ->
        refuse_exit (remote_exit retention ("sh -c " ^ Shell.quote
          (secure_remote_stage_script ~stage:env.remote_stage ~subtree))))
      ~cleanup:(fun () ->
        refuse_exit (ssh_run env [env.compute_target;
          "doas sh -c " ^ Shell.quote (remove_stage_script ~marker:"artifact-executable-cleanup" stage)]))
      (fun retention ->
        let transfer source destination =
          uncertain_while retention (fun () ->
            rsync_checked env ["-az"; "--no-owner"; "--no-group"; "--"; source; destination]) in
        Progress.phase "transfer";
        transfer base_archive (remote "base.txz");
        List.iter (fun (name, _) -> transfer (Filename.concat recipe_dir name) (remote name)) recipe.scripts;
        let checks = List.map (fun (name, sha) ->
          "file=" ^ Shell.quote (stage ^ "/" ^ name)
          ^ "\n[ -f \"$file\" ] && [ ! -L \"$file\" ]\n[ \"$(sha256 -q \"$file\")\" = " ^ Shell.quote sha ^ " ]") recipe.scripts in
        let args = [stage ^ "/artifact_build_jail.sh"; "infra-build-" ^ app_name ^ "-" ^ env.lock_token;
          ip; stage ^ "/base.txz"; base_sha256; "-"; "-"; "-"; release; stage ^ "/output"] @ packages in
        Progress.phase "build";
        run_build_jail env retention ("doas sh -c " ^ Shell.quote
          (String.concat "\n" (["set -eu"] @ checks @ [String.concat " "
            (["SERAI_LOCK_HELD=1"] @ worker_env @ ["exec sh"] @ List.map Shell.quote args)])));
        Progress.phase "transfer";
        List.iter (fun name -> transfer (remote ("output/" ^ name)) (Filename.concat local name))
          ["release.tar"; "release.sha256"; "target-abi"; "dependencies"]);
    Progress.phase "verify";
    let archive_sha256 = String.trim (read_evidence ~dir:local "release.sha256" 65) in
    let target_abi = abi_evidence ~dir:local in
    (match String.split_on_char ':' target_abi with
     | ["FreeBSD"; major; "amd64"] when major <> ""
         && String.for_all (function '0'..'9' -> true | _ -> false) major -> ()
     | _ -> Run_state.fail ~cause:"invalid_build_output" "artifact build: incompatible executable ABI");
    let dependencies = dependency_evidence ~dir:local in
    let manifest = ok_or_fail ~cause:"invalid_build_output" (Artifact_manifest.create_input ~name:app_name ~input ~target_abi ~dependencies
      ~recipe_sha256:recipe.sha256 ~release_name:release ~archive_sha256) in
    Progress.phase "publish";
    match Artifact_store.publish ~root:store ~manifest ~archive:(Filename.concat local "release.tar") with
    | Ok _ -> Artifact_manifest.identity manifest | Error message -> Run_state.fail ~cause:"store_failed" message)

(* The port a check or an activation probes: the one named http, or the
   only one declared. *)
let check_port (endpoint : Network_endpoint.t) =
  match
    List.find_opt (fun (p : Network_endpoint.named_port) -> p.port_name = "http") endpoint.tailnet_ports,
    endpoint.tailnet_ports with
  | Some p, _ | None, [ p ] -> p.port
  | None, _ -> Run_state.fail ~cause:"invalid_declaration" (endpoint.name ^ ": no http tailnet port to check")

(* How a release activates: its release (the launcher under bin/), health
   path, executable anchor (- for none), the health status activation
   expects, whether the rc script's migrate command runs, and how activation
   tells the old service has stopped. *)
type release_settings = {
  release : string;
  check_path : string;
  anchor : string;
  health_status : string;
  migrate : bool;
  service_status : string;
}

(* A source-built app's settings come from its strategy alone. *)
let source_release_settings app_name (strategy : Strategy_config.t) =
  match strategy with
  | Freebsd_native_elixir s ->
      Some { release = s.release_name; check_path = s.check_path; anchor = "-";
             health_status = "success"; migrate = Option.is_some s.migrate; service_status = "rc" }
  | Freebsd_native_ocaml s ->
      Some { release = app_name; check_path = s.check_path; anchor = "/usr/local/bin/" ^ app_name;
             health_status = "success"; migrate = Option.is_some s.migrate; service_status = "rc" }
  | Freebsd_package _ | Fetch_binary _ | Freebsd_package_service _ -> None

(* Snapshots [helpers] from the engine, stages them and [files] (local path,
   staged name) under [subtree] on the compute host, checks each helper's
   digest there and runs the first one with [args stage] and [assignments],
   holding the compute host lock as [label]. A transfer or run whose outcome
   is unknown keeps the stage and the lock for inspection; otherwise the
   stage is removed. [context] prefixes its errors. *)
let run_artifact_helper env ~context ~label ~subtree ~files ~helpers ~assignments ~args =
  let local = Filename.temp_dir "serai-artifact-apply" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    let scripts = snapshot_helpers env ~context ~local helpers in
    let stage = env.remote_stage ^ "/" ^ subtree in
    with_retained_stage env ~command:label ~host:Compute_host ~stage
      ~retained:(Printf.sprintf
        "%s: remote outcome uncertain; stage %s and host lock retained. Inspect before serai unlock %s."
        context stage (host_label env Compute_host))
      ~prepare:(fun _ -> secure_remote_stage env ~target:env.compute_target ~subtree)
      ~cleanup:(fun () ->
        ssh_checked env [env.compute_target; "sh -c " ^ Shell.quote (remove_stage_script stage)])
      (fun retention ->
        Progress.phase "transfer";
        (* A failed/interrupted transfer may leave a remote writer. *)
        let transfer source name =
          uncertain_while retention (fun () ->
            rsync_checked env
              ["-az"; "--no-owner"; "--no-group"; "--"; source;
               env.compute_target ^ ":" ^ stage ^ "/" ^ name]) in
        List.iter (fun (source, name) -> transfer source name) files;
        List.iter (fun (name, snapshot, _) -> transfer snapshot name) scripts;
        let checks = List.map (fun (name, _, sha) ->
          "file=" ^ Shell.quote (stage ^ "/" ^ name)
          ^ "\n[ -f \"$file\" ] && [ ! -L \"$file\" ]\n[ \"$(sha256 -q \"$file\")\" = " ^ Shell.quote sha ^ " ]") scripts in
        Progress.phase "apply";
        (* Proc folds locally signalled exits into 128+signal. Those, SSH
           transport failure and local exceptions leave the remote outcome unknown. *)
        retention.uncertain <- true;
        let command = String.concat " "
          (("SERAI_LOCK_HELD=1" :: List.map (fun (name, value) -> name ^ "=" ^ value) assignments)
           @ [ "exec sh" ] @ List.map Shell.quote (args stage)) in
        let code = ssh_run env [env.compute_target; "doas sh -c " ^ Shell.quote
          (String.concat "\n" (["set -eu"] @ checks @ [command]))] in
        retention.uncertain <- code >= 128;
        if code <> 0 then Run_state.fail ~cause:"command_failed" (Printf.sprintf "%s: remote exited %d" label code)))

let artifact_apply ?(convert=false) ?rehearse_ip env app_name ~store ~identity ~rollback =
  let env = app_env env app_name in
  Progress.phase "verify";
  if (convert && rollback) || (Option.is_some rehearse_ip && (convert || rollback))
  then Run_state.fail ~cause:"invalid_argument" "artifact apply: invalid operation";
  (* A rehearsal applies to the test jail <app>test at the test ip; every
     in-jail name stays the app's. *)
  let app, jail = match rehearse_ip with
    | None -> find_app env app_name, app_name
    | Some ip ->
        let app = find_app env app_name in
        (match Jail_test.retarget app ~ip with
         | Ok retargeted -> retargeted, Jail_test.name app
         | Error errors -> Run_state.fail ~cause:"invalid_argument" ("artifact apply: " ^ Network_endpoint.errors_message errors)) in
  let manifest, archive = ok_or_fail ~cause:"store_failed" (Artifact_store.load ~root:store ~identity) in
  if manifest.name <> app_name || not (String.starts_with ~prefix:"FreeBSD:" manifest.target_abi)
  then Run_state.fail ~cause:"input_mismatch" "artifact apply: workload or operating system mismatch";
  let settings = match source_release_settings app_name app.strategy, app.strategy, manifest.input with
    | Some settings, _, Artifact_manifest.Source_commit _ -> settings
    | None, Strategy_config.Freebsd_package s, Artifact_manifest.Package_archives package
        when List.mem package s.packages ->
        let status = match s.check_status with None -> "success" | Some status -> string_of_int status in
        let service_status = match s.service_status with Rc -> "rc" | Process -> "process" in
        { release = package; check_path = s.check_path; anchor = "/usr/local/bin/" ^ package;
          health_status = status; migrate = false; service_status }
    | None, Strategy_config.Fetch_binary s, Artifact_manifest.Upstream_binary input ->
        let url = binary_url ~context:"artifact apply" ~template:s.binary_url_template ~version:input.version in
        if input.url <> url || (not rollback && (input.version <> s.version || input.sha256 <> s.binary_sha256))
        then Run_state.fail ~cause:"input_mismatch" "artifact apply: immutable input does not match the declaration";
        { release = s.binary_name; check_path = s.check_path; anchor = "/usr/local/bin/" ^ s.binary_name;
          health_status = "success"; migrate = false; service_status = "rc" }
    | _ -> Run_state.fail ~cause:"input_mismatch" "artifact apply: immutable input does not match the declaration" in
  if manifest.release_name <> settings.release then Run_state.fail ~cause:"input_mismatch" "artifact apply: release name mismatch";
  (* Conversion moves a legacy executable (package or pinned binary) under
     the release layout; Phoenix apps were adopted by a one-off since
     removed. *)
  if convert && settings.anchor = "-" then Run_state.fail ~cause:"unsupported_for_workload" "artifact apply: conversion is for executables only";
  let port = check_port app.endpoint in
  let url = Printf.sprintf "http://%s:%d%s" app.endpoint.ip port settings.check_path in
  let mode = if convert then "convert" else if rollback then "rollback" else "upgrade" in
  validate_stage env.remote_stage;
  if not (approved env ~operation:("artifact." ^ mode)
            ~facts:[ "jail", jail; "host", host_label env Compute_host; "identity", identity;
                     "archive_sha256", manifest.archive_sha256; "check", url ]
            (Printf.sprintf "%s %s to %s (files only; no database rollback)?" mode jail identity))
  then Run_state.fail ~cause:"declined" "artifact apply: cancelled";
  run_artifact_helper env ~context:"artifact apply" ~label:("artifact " ^ mode ^ " " ^ jail)
    ~subtree:("artifact-apply/" ^ jail ^ "/" ^ identity)
    ~files:[ archive, "release.tar" ]
    ~helpers:(["artifact_apply.sh"; "artifact_install.sh"; "artifact_activate.sh"; "artifact_check_health.sh"]
              @ if convert then ["artifact_convert_binary.sh"] else [])
    ~assignments:[ ("SERAI_ARTIFACT_HTTP_STATUS", settings.health_status);
                   ("SERAI_ARTIFACT_SERVICE_STATUS", settings.service_status) ]
    ~args:(fun stage ->
      [stage ^ "/artifact_apply.sh"; mode; jail; identity;
       manifest.archive_sha256; stage ^ "/release.tar"; settings.release; url; manifest.target_abi;
       settings.anchor; if settings.migrate then "migrate" else "-"; app_name;
       (* The manifest's identity covers its commit, so the host can
          record it as what this release was built from. *)
       (match manifest.input with Artifact_manifest.Source_commit commit -> commit | _ -> "-")])

(* The app's release pointers and source record, read as root. *)
let probe_releases env app_name =
  let env = app_env env app_name in
  match ssh_capture env [ env.compute_target; "doas sh -c " ^ Shell.quote (Release_probe.script ~app:app_name) ] with
  | 0, output -> (
      ok_or_fail ~cause:"host_state" (Release_probe.check ~app:app_name output))
  | code, _ ->
      Run_state.fail ~cause:"command_failed" (Printf.sprintf "probing %s's releases on %s failed (exit %d)"
        app_name (host_label env Compute_host) code)

(* The release kept in .previous, reactivated where it is installed: no
   archive, so the store that built it is not needed. Only an app that
   never migrates: its releases are files, and a migrated database may not
   be readable by the previous release. *)
let revert env app_name =
  let env = app_env env app_name in
  Progress.phase "verify";
  let app = find_app env app_name in
  let settings = match source_release_settings app_name app.strategy with
    | Some settings -> settings
    | None -> Run_state.fail ~cause:"unsupported_for_workload" "revert: only source-built apps revert" in
  if settings.migrate then
    Run_state.fail ~cause:"unsupported_for_workload" (Printf.sprintf "revert: %s declares migrate; roll it back with serai artifact rollback" app_name);
  validate_stage env.remote_stage;
  let previous =
    match probe_releases env app_name with
    | { previous = Some identity; _ } -> identity
    | { previous = None; _ } -> Run_state.fail ~cause:"host_state" (Printf.sprintf "revert: %s has no previous release on the host" app_name)
    | exception Failure message -> Run_state.refail ~prefix:"revert: " ~otherwise:"command_failed" message in
  let url = Printf.sprintf "http://%s:%d%s" app.endpoint.ip (check_port app.endpoint) settings.check_path in
  if not (approved env ~operation:"revert"
            ~facts:[ "app", app_name; "host", host_label env Compute_host; "identity", previous; "check", url ]
            (Printf.sprintf "revert %s to %s (files only)?" app_name previous)) then
    Run_state.fail ~cause:"declined" "revert: cancelled";
  (* The script checks .previous again under the lock. *)
  run_artifact_helper env ~context:"revert" ~label:("artifact revert " ^ app_name)
    ~subtree:("artifact-revert/" ^ app_name ^ "/" ^ previous)
    ~files:[]
    ~helpers:[ "artifact_apply.sh"; "artifact_activate.sh"; "artifact_check_health.sh" ]
    ~assignments:[ ("SERAI_ARTIFACT_HTTP_STATUS", settings.health_status);
                   ("SERAI_ARTIFACT_SERVICE_STATUS", settings.service_status) ]
    ~args:(fun stage ->
      [ stage ^ "/artifact_apply.sh"; "revert"; app_name; previous; "-"; "-"; settings.release; url;
        "-"; settings.anchor; "-"; app_name; "-" ])
