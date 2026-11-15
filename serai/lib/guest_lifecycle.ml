(* A bhyve guest: provision, build, deploy, artifacts and logging. Part of
   Dispatcher. Every connection goes through the compute host by ProxyJump
   and shares the control socket; the steps that run a guest script ask for
   a TTY, because su must prompt for the guest's root password. *)
open Remote_host
open Artifact_lifecycle
open Logging_install

let find_guest env name =
  if not (name <> "" && String.for_all is_app_char name) then failwith "invalid guest name";
  match List.find_opt (fun guest -> Guest_config.name guest = name) env.guests with
  | Some guest -> guest
  | None -> failwith "unknown guest"

type guest_step =
  | Stage_guard (* the staging check, over the same hop the rsync uses *)
  | Stage_guest_dir (* guests/<guest> to <stage>/compute/guests/ on the guest *)
  | Push_source of string (* the resolved source checkout, to ~<login>/<guest>/ *)
  | Build (* unprivileged, as the login user *)
  | Install (* as root, through su *)
  | Provision (* as root, through su *)
  | Logging of logging_action (* the guest's log sender, as root, without rebuilding the app *)
  | Autostart (* on the compute host: vm-bhyve starts the guest at boot *)

(* The program and arguments of each step, in one place. *)
let guest_command env (guest : Guest_config.t) step =
  let name = Guest_config.name guest and target = guest_target guest in
  let script hook = Printf.sprintf "%s/compute/guests/%s/%s" env.remote_stage name hook in
  (* rsync splits -e on whitespace itself; no shell sees it *)
  let remote_shell = String.concat " " ((env.ssh_bin :: guest_ssh_options env) @ guest_jump_options env guest) in
  let tty_ssh command = (env.ssh_bin, ("-t" :: guest_connection env guest) @ [ command ]) in
  (* su rather than doas or sudo: the guest deliberately has neither *)
  let as_root hook = "su -c " ^ Shell.quote ("sh " ^ script hook) in
  match step with
  | Stage_guard ->
      ( env.ssh_bin,
        guest_connection env guest
        @ [ secure_remote_stage_script ~stage:env.remote_stage ~subtree:"compute/guests" ] )
  | Stage_guest_dir ->
      ( env.rsync_bin,
        [
          "-az"; "--delete"; "-e"; remote_shell;
          "--exclude"; ".env"; "--exclude"; ".env.*";
          Filename.concat (Layout.guests_dir env.layout) name;
          Printf.sprintf "%s:%s/compute/guests/" target env.remote_stage;
        ] )
  | Push_source source_dir ->
      (* _build and the VCS metadata stay behind: the guest compiles for its
         own glibc, and a build tree from another machine would be stale at
         best. The destination is the guest's name under the login user's
         home, where the guest's build and install scripts look. *)
      ( env.rsync_bin,
        [
          "-az"; "--delete"; "-e"; remote_shell;
          "--exclude"; "_build/"; "--exclude"; ".git/"; "--exclude"; ".jj/";
          "--exclude"; ".env"; "--exclude"; ".env.*";
          source_dir ^ "/";
          Printf.sprintf "%s:%s/" target name;
        ] )
  | Build -> tty_ssh ("sh " ^ script "build")
  | Install -> tty_ssh (as_root "install")
  | Provision -> tty_ssh (as_root "provision")
  | Logging action -> tty_ssh ("su -c " ^ Shell.quote ("sh " ^ script "logging" ^ logging_action_arg action))
  | Autostart ->
      (* On the guest's own host. Only after provision: a guest that is not
         installed yet would boot to an empty UEFI menu. sysrc's += adds the
         name once. *)
      let host = match env.topology with
        | Some topology -> (Topology.guest_host topology name).ssh
        | None -> env.compute_target in
      (env.ssh_bin,
       guest_ssh_options env @ ssh_args env [ host; "doas sysrc vm_list+=" ^ Shell.quote name ])

let run_guest_step env guest step =
  let prog, args = guest_command env guest step in
  Proc.run_checked prog args

(* Staged through the guest's own /tmp, not the compute host's: the scripts run
   inside the guest, so that is where the tree has to land. *)
let stage_guest env guest =
  run_guest_step env guest Stage_guard;
  run_guest_step env guest Stage_guest_dir

(* SOURCE_CHECKOUT wins over the declared source_checkout; a relative path
   is taken against the repository root. Refused before any command when
   the directory is missing. Returns the checkout as given (for the
   message) and the resolved directory. *)
let resolve_source_checkout env (guest : Guest_config.t) =
  let checkout = Option.value env.source_checkout_override ~default:guest.source_checkout in
  let source_dir = Layout.config_path env.layout checkout in
  if not (Sys.file_exists source_dir && Sys.is_directory source_dir) then
    failwith ("source checkout not found: " ^ source_dir);
  (checkout, source_dir)

(* The source is pushed, not cloned: a guest's source may be private, and the
   alternative is a deploy key on a machine whose whole purpose is to be
   exposed to the internet. The build runs as the login user, deliberately
   unprivileged: the opam switch belongs to that user. *)
let artifact_guest_abi value =
  let number value = value <> "" && String.for_all (function '0'..'9' -> true | _ -> false) value in
  match String.split_on_char ':' value with
  | ["Linux"; ("x86_64" | "aarch64"); libc] ->
      (match String.split_on_char '_' libc with
       | ["glibc"; version] ->
           (match String.split_on_char '.' version with
            | [major; minor] when number major && number minor -> ()
            | _ -> failwith "artifact build: invalid Linux/glibc ABI")
       | _ -> failwith "artifact build: invalid Linux/glibc ABI")
  | _ -> failwith "artifact build: requires native Linux/glibc ABI"

let guest_workload action (guest : Guest_config.t) =
  match guest.workload with
  | Some workload -> workload
  | None -> failwith (Printf.sprintf "%s: guest %s declares no workload" action (Guest_config.name guest))

let artifact_build_guest_store ?reuse env name ~revision ~opam_repository:(repository_checkout, repository_revision)
    ~compiler ~store =
  let guest = find_guest env name in
  let workload = guest_workload "artifact build" guest in
  validate_stage env.remote_stage;
  validate_app_name env.lock_token;
  ok_or_fail (Artifact_store.validate_root store);
  let selected = Option.map (fun identity ->
    match Artifact_store.load ~root:store ~identity with
    | Ok (manifest, _) -> manifest | Error message -> failwith message) reuse in
  let _, checkout = resolve_source_checkout env guest in
  let local = Filename.temp_dir "serai-guest-artifact" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    Progress.phase "source";
    let snapshot checkout revision label =
      let path = Filename.concat local label in
      let commit = ok_or_fail (Source_snapshot.stage ~jj_bin:env.jj_bin ~checkout ~revision ~out:path) in
      let receipt = Filename.concat local (label ^ "-inventory") in
      path, receipt, commit, write_inventory ~root:path ~commit ~receipt in
    let source, source_receipt, source_commit, source_sha = snapshot checkout revision "source" in
    let repository, repo_receipt, repo_commit, repo_sha = snapshot repository_checkout repository_revision "repository" in
    require_opam_repository repository;
    Progress.phase "recipe";
    let recipe_dir = Filename.concat local "recipe" in
    let recipe = ok_or_fail (Artifact_recipe.stage_guest ~lib_dir:(Layout.lib_dir env.layout) ~out:recipe_dir
      ~project:workload.project ~target:workload.target ~release_name:workload.release
      ~compiler ~repository_commit:repo_commit ~repository_sha256:repo_sha) in
    match selected with
    | Some manifest ->
        Progress.phase "reuse";
        artifact_guest_abi manifest.target_abi;
        let source_matches = match manifest.input with
          | Artifact_manifest.Source_commit value -> String.equal value source_commit | _ -> false in
        if manifest.name <> name || manifest.release_name <> workload.release
           || not source_matches || manifest.recipe_sha256 <> recipe.sha256
        then failwith "artifact reuse: requested inputs do not match stored artifact";
        Artifact_manifest.identity manifest
    | None ->
    if not (env.confirm (Printf.sprintf "Build verified %s artifact in the Linux guest?" name)) then
      failwith "artifact build: cancelled";
    let subtree = "artifact-build/" ^ name ^ "/" ^ env.lock_token in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let output = Filename.concat local "output" in
    Unix.mkdir output 0o700;
    let shell = String.concat " " ((env.ssh_bin :: guest_ssh_options env) @ guest_jump_options env guest) in
    let remote path = guest_target guest ^ ":" ^ stage ^ "/" ^ path in
    let ssh command = ssh_checked env (guest_connection env guest @ [command]) in
    with_retained_stage env ~command:("artifact build " ^ name) ~host:(Guest guest)
      ~retained:(Printf.sprintf
        "artifact build: %s stage %s and guest lock retained; inspect before serai unlock %s." name stage name)
      ~prepare:(fun retention ->
        uncertain_while retention (fun () -> ssh (secure_remote_stage_script ~stage:env.remote_stage ~subtree)))
      ~cleanup:(fun () -> ssh (remove_stage_script ~marker:"artifact-guest-cleanup" stage))
      (fun retention ->
        let transfer src dst =
          uncertain_while retention (fun () ->
            rsync_checked env ["-az"; "--no-owner"; "--no-group"; "-e"; shell; "--"; src; dst]) in
        Progress.phase "transfer";
        transfer (source ^ "/") (remote "source/");
        transfer source_receipt (remote "source-inventory");
        transfer (repository ^ "/") (remote "repository/");
        transfer repo_receipt (remote "repository-inventory");
        List.iter (fun (file, _) -> transfer (Filename.concat recipe_dir file) (remote file)) recipe.scripts;
        let checks = List.map (fun (file, digest) -> String.concat "\n"
          ["file=" ^ Shell.quote (stage ^ "/" ^ file);
           {|[ -f "$file" ] && [ ! -L "$file" ] || exit 1|};
           {|value=$(sha256sum "$file") || exit 1|};
           {|value=${value%% *}|}; "[ \"$value\" = " ^ Shell.quote digest ^ " ] || exit 1"])
          recipe.scripts in
        let args = [stage ^ "/artifact_build_guest.sh"; stage ^ "/source";
          stage ^ "/source-inventory"; source_sha; stage ^ "/repository";
          stage ^ "/repository-inventory"; repo_sha; compiler; stage ^ "/output";
          workload.project; workload.target; workload.release] in
        Progress.phase "build";
        uncertain_while retention (fun () ->
          ssh (String.concat "\n" (["set -eu"] @ checks @
            ["exec sh " ^ String.concat " " (List.map Shell.quote args)])));
        Progress.phase "transfer";
        List.iter (fun file -> transfer (remote ("output/" ^ file)) (Filename.concat output file))
          ["release.tar"; "release.sha256"; "target-abi"; "dependencies"]);
    Progress.phase "verify";
    let archive = Filename.concat output "release.tar" in
    if (Unix.lstat archive).Unix.st_kind <> Unix.S_REG then failwith "artifact build: unsafe guest archive";
    let archive_sha256 = artifact_file_sha256 archive in
    if read_evidence ~dir:output "release.sha256" 65 <> archive_sha256 ^ "\n" then failwith "artifact build: guest archive checksum mismatch";
    let target_abi = abi_evidence ~dir:output in
    artifact_guest_abi target_abi;
    let dependencies = dependency_evidence ~dir:output in
    (match dependencies with
     | [{Artifact_manifest.name="opam-repository"; version; sha256}]
       when String.equal version repo_commit && String.equal sha256 repo_sha -> ()
     | _ -> failwith "artifact build: guest repository receipt mismatch");
    let manifest = ok_or_fail (Artifact_manifest.create ~name ~source_commit ~target_abi ~dependencies
      ~recipe_sha256:recipe.sha256 ~release_name:workload.release ~archive_sha256) in
    Progress.phase "publish";
    match Artifact_store.publish ~root:store ~manifest ~archive with
    | Ok _ -> Artifact_manifest.identity manifest | Error message -> failwith message)

let artifact_apply_guest ?(convert=false) env name ~store ~identity ~rollback =
  Progress.phase "verify";
  if convert && rollback then failwith "artifact apply: invalid guest operation";
  let guest = find_guest env name in
  let workload = guest_workload "artifact apply" guest in
  let manifest, archive = ok_or_fail (Artifact_store.load ~root:store ~identity) in
  (match manifest.input with Artifact_manifest.Source_commit _ -> ()
   | _ -> failwith "artifact apply: a guest workload requires immutable source input");
  if manifest.name <> name || manifest.release_name <> workload.release then
    failwith "artifact apply: guest workload mismatch";
  artifact_guest_abi manifest.target_abi;
  let port = match List.find_opt (fun (p : Network_endpoint.named_port) -> p.port_name="http") guest.endpoint.tailnet_ports with
    | Some p -> p.port | None -> failwith "artifact apply: missing guest HTTP readiness port" in
  let url = Printf.sprintf "http://%s:%d/health" guest.endpoint.ip port in
  validate_stage env.remote_stage;
  if not (env.confirm (Printf.sprintf "Apply %s artifact %s (files only; no database rollback)?" name identity)) then
    failwith "artifact apply: cancelled";
  let local = Filename.temp_dir "serai-guest-apply" "" in
  Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
    let scripts = snapshot_helpers env ~context:"artifact apply" ~local
      (["artifact_install_guest.sh"; "artifact_activate_guest.sh"; "artifact_check_health.sh"]
       @ if convert then ["artifact_convert_binary.sh"; "artifact_service_guest.sh"] else []) in
    let subtree = "artifact-apply/" ^ name ^ "/" ^ identity in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let shell = String.concat " " ((env.ssh_bin :: guest_ssh_options env) @ guest_jump_options env guest) in
    let ssh command = ssh_checked env (guest_connection env guest @ [command]) in
    with_retained_stage env ~command:("artifact apply " ^ name) ~host:(Guest guest)
      ~retained:(Printf.sprintf
        "artifact apply: %s stage %s and guest lock retained; inspect before serai unlock %s." name stage name)
      ~prepare:(fun retention ->
        uncertain_while retention (fun () -> ssh (secure_remote_stage_script ~stage:env.remote_stage ~subtree)))
      ~cleanup:(fun () -> ssh (remove_stage_script stage))
      (fun retention ->
        Progress.phase "transfer";
        let transfer source name =
          uncertain_while retention (fun () ->
            rsync_checked env ["-az"; "--no-owner"; "--no-group"; "-e"; shell; "--"; source;
              guest_target guest ^ ":" ^ stage ^ "/" ^ name]) in
        transfer archive "release.tar";
        List.iter (fun (name, path, _) -> transfer path name) scripts;
        let copy name digest = String.concat "\n"
          ["cp -P -- " ^ Shell.quote (stage ^ "/" ^ name) ^ " \"$private/" ^ name ^ "\"";
           "[ -f \"$private/" ^ name ^ "\" ] && [ ! -L \"$private/" ^ name ^ "\" ]";
           "value=$(sha256sum \"$private/" ^ name ^ "\")";
           "[ \"${value%% *}\" = " ^ Shell.quote digest ^ " ]"] in
        let mode = if rollback then "rollback" else "upgrade" in
        let activate = if convert then
          "env -i PATH=/usr/bin:/bin SERAI_LOCK_HELD=1 JAIL_ROOT=/ JEXEC_BIN=\"$private/artifact_service_guest.sh\" sh \"$private/artifact_convert_binary.sh\" "
          ^ String.concat " " (List.map Shell.quote [workload.release; identity; manifest.archive_sha256;
              workload.release; url; "/usr/local/bin/" ^ workload.release])
          else "env -i PATH=/usr/bin:/bin SERAI_LOCK_HELD=1 sh \"$private/artifact_activate_guest.sh\" "
          ^ String.concat " " (List.map Shell.quote [mode; workload.release; identity; manifest.archive_sha256; url]) in
        let command = String.concat "\n" (["set -eu"; "PATH=/usr/bin:/bin; export PATH"; "umask 077";
          "actual=Linux:$(uname -m):glibc_$(getconf GNU_LIBC_VERSION | cut -d ' ' -f 2)";
          "[ \"$actual\" = " ^ Shell.quote manifest.target_abi ^ " ]";
          "private=$(mktemp -d /var/tmp/infra-guest-apply.XXXXXXXX)";
          "trap 'rm -rf -- \"$private\"' EXIT HUP INT TERM"]
          @ List.map (fun (name, _, digest) -> copy name digest) scripts
          @ ["chmod 700 \"$private\"/*.sh"; copy "release.tar" manifest.archive_sha256;
             "env -i PATH=/usr/bin:/bin sh \"$private/artifact_install_guest.sh\" "
               ^ String.concat " " [Shell.quote workload.release; Shell.quote workload.service_group;
                   Shell.quote identity; "\"$private/release.tar\""; Shell.quote manifest.archive_sha256]; activate]) in
        Progress.phase "apply";
        retention.uncertain <- true;
        let code = ssh_run env (("-t" :: guest_connection env guest) @ ["su -c " ^ Shell.quote command]) in
        retention.uncertain <- code >= 128;
        if code <> 0 then failwith (Printf.sprintf "artifact apply %s: remote exited %d" name code)))

let build_steps env guest (checkout, source_dir) =
  announce "build %s" (Guest_config.name guest);
  stage_guest env guest;
  announce "pushing source from %s" checkout;
  run_guest_step env guest (Push_source source_dir);
  run_guest_step env guest Build

let install_guest_logging ?(action = Normal_logging) env name =
  let guest = find_guest env name in
  validate_stage env.remote_stage;
  with_locks env ~command:("install " ^ name ^ " logging" ^ logging_action_arg action) [ Guest guest ] (fun _records ->
      announce "install %s logging" name;
      stage_guest env guest;
      run_guest_step env guest (Logging action))

let provision_guest env name =
  let guest = find_guest env name in
  validate_stage env.remote_stage;
  with_locks env ~command:("provision " ^ name) [ Guest guest ] (fun _records ->
      announce "provision %s" name;
      stage_guest env guest;
      run_guest_step env guest Provision;
      run_guest_step env guest Autostart)

let build_guest env name =
  let guest = find_guest env name in
  let source = resolve_source_checkout env guest in
  validate_stage env.remote_stage;
  with_locks env ~command:("build " ^ name) [ Guest guest ] (fun _records -> build_steps env guest source)

(* Build, then install, then provision, under one lock, stopping at the
   first failure. Install restarts the service on the new binary with the
   config it already has; provision then rewrites the config and restarts
   only if it changed. The other order could hand a new config section to
   the old binary, whose parser rejects unknown fields. Provision reuses
   the tree build staged in this run rather than staging it again. *)
let deploy_guest env name =
  let guest = find_guest env name in
  let source = resolve_source_checkout env guest in
  validate_stage env.remote_stage;
  with_locks env ~command:("deploy " ^ name) [ Guest guest ] (fun _records ->
      build_steps env guest source;
      (* Only install escalates: build is never given root, so the build
         account cannot replace the service binary. *)
      announce "install %s" name;
      run_guest_step env guest Install;
      announce "provision %s" name;
      run_guest_step env guest Provision;
      run_guest_step env guest Autostart)
