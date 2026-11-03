(* Direct-style port of the retired bash ./ops. Every function here reads like the bash
   version it replaces; the only thing that changed shape is how a command
   actually runs, and that lives entirely in Proc. *)

let is_app_char c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '-'

let validate_app_name name =
  if name <> "" && String.for_all is_app_char name then ()
  else failwith "invalid app name"

let is_stage_char c =
  (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
  || c = '_' || c = '-'

let validate_stage stage =
  match String.split_on_char '/' stage with
  | "" :: "tmp" :: (_ :: _ as rest)
    when List.for_all (fun p -> p <> "" && String.for_all is_stage_char p) rest
    -> ()
  | _ ->
      failwith "OPS_REMOTE_STAGE must be a dedicated non-root directory beneath /tmp"

(* Verbatim port of the POSIX sh staging guard the bash ./ops ran: stage components
   are created and checked remotely, before rsync or privilege escalation,
   so a pre-existing symlink or another user's directory can't redirect a
   staged hook. Kept as a remote shell script rather than reimplemented in
   OCaml, since it has to run on the FreeBSD box being staged, not here. *)
let secure_remote_stage_script ~stage ~subtree =
  String.concat "\n"
    [
      "set -eu";
      "stage=" ^ Shell.quote stage;
      "subtree=" ^ Shell.quote subtree;
      {|uid=$(id -u)|};
      "path=/tmp";
      {|rest=${stage#/tmp/}/$subtree|};
      {|while [ -n "$rest" ]; do|};
      {|  component=${rest%%/*}|};
      {|  rest=${rest#*/}|};
      {|  [ "$component" != "$rest" ] || rest=|};
      {|  path="$path/$component"|};
      {|  if [ -e "$path" ] || [ -L "$path" ]; then|};
      {|    [ -d "$path" ] && [ ! -L "$path" ] || {|};
      {|      echo "unsafe remote staging path: $path" >&2|};
      {|      exit 1|};
      {|    }|};
      {|  else|};
      {|    (umask 077 && mkdir "$path")|};
      {|  fi|};
      {|  if stat --version >/dev/null 2>&1; then|};
      {|    owner=$(stat -c '%u' "$path")|};
      {|    mode=$(stat -c '%a' "$path")|};
      {|  else|};
      {|    owner=$(stat -f '%u' "$path")|};
      {|    mode=$(stat -f '%p' "$path")|};
      {|  fi|};
      {|  case $mode in ''|*[!0-7]*) exit 1 ;; esac|};
      {|  [ "${#mode}" -le 6 ] || exit 1|};
      {|  mode=$((0$mode & 07777))|};
      {|  if [ "$owner" != "$uid" ] || [ "$mode" != "$((0700))" ]; then|};
      {|    echo "unsafe remote staging path: $path" >&2|};
      {|    exit 1|};
      {|  fi|};
      "done";
    ]

type env = {
  layout : Layout.t;
  topology : Topology.t option;
  compute_target : string;
  edge_target : string;
  remote_stage : string;
  ssh_bin : string;
  rsync_bin : string;
  curl_bin : string;
  config : App_config.t list;
  endpoints : Network_endpoint.validated; (* apps' and guests' endpoints, validated *)
  edge : Edge_config.t; (* edge/edge.sexp *)
  edge_ts_ip : string option;
  edge_peer_match : string option;
      (* forwarded to compute/01-pf-rules when set: rules are rendered here but
         the edge host address is resolved on the compute host, so an override has to
         travel with them *)
  caddy_force_build : bool;
      (* CADDY_FORCE_BUILD=1, forwarded to edge/02-caddy's install; never
         to its diff, which does not build *)
  confirm : string -> bool;
      (* asked once before edge installs anything; main answers from the
         terminal, or always yes under --yes *)
  operator : string; (* user@machine, named in lock holders and applied records *)
  lock_token : string; (* unique to this run: releases remove only our own lock *)
  jj_bin : string;
  now_utc : unit -> string; (* ISO 8601 UTC, for applied records *)
  guests : Guest_config.t list; (* guests/*/guest.sexp *)
  ops_control_path : string;
      (* OPS_CONTROL_PATH: the ssh control socket guest connections share,
         so a password is typed once per run rather than once per hop *)
  ssh_multiplex : bool; (* OPS_SSH_MULTIPLEX unset or 1 *)
  source_checkout_override : string option;
      (* SOURCE_CHECKOUT: replaces the guest's declared source_checkout *)
}

(* Legacy hook argument names are adapter details; placement selects their values. *)
let app_env env name = match env.topology with
  | None -> env
  | Some topology ->
      { env with compute_target = (Topology.jail_host topology name).ssh;
                 edge_target = (Topology.edge topology).ssh }

(* The host [name]'s jail runs on. An address is checked against its
   network, and without a topology there is no network to assume. *)
let jail_host env name = match env.topology with
  | Some topology -> Topology.jail_host topology name
  | None -> failwith ("no topology places " ^ name ^ " on a network")

let configured_host env target = match env.topology with
  | None -> None
  | Some topology -> List.find_opt (fun (h : Topology.host) -> h.ssh = target) (Topology.hosts topology)

let jump_options jumps = if jumps = [] then [] else ["-J"; String.concat "," jumps]
let target_connection env target =
  match env.topology, configured_host env target with
  | Some topology, Some host -> jump_options (Topology.host_jumps topology host) @ [target]
  | _ -> [target]

let ssh_args env args =
  if List.mem "-J" args then args else
  let rec insert = function
    | [] -> []
    | arg :: rest -> match configured_host env arg with
        | Some _ -> target_connection env arg @ rest
        | None -> arg :: insert rest
  in insert args
let require_direct_hook env =
  if List.exists (fun target -> target_connection env target <> [target])
      [env.compute_target; env.edge_target] then
    failwith "legacy hook cannot express this SSH route; use the artifact lifecycle"

let ssh_run env args = Proc.run env.ssh_bin (ssh_args env args)
let ssh_checked env args = Proc.run_checked env.ssh_bin (ssh_args env args)
let ssh_capture env args = Proc.capture env.ssh_bin (ssh_args env args)
let rsync_checked env args =
  let route = match env.topology with
    | None -> []
    | Some topology ->
        List.find_opt (fun (h : Topology.host) ->
          List.exists (String.starts_with ~prefix:(h.ssh ^ ":")) args) (Topology.hosts topology)
        |> Option.map (Topology.host_jumps topology) |> Option.value ~default:[] in
  let args = if route = [] || List.mem "-e" args then args else
    ["-e"; String.concat " " (env.ssh_bin :: jump_options route)] @ args in
  Proc.run_checked env.rsync_bin args

let announce fmt = Printf.ksprintf (fun message ->
  Progress.phase "execute";
  Printf.printf "==> %s\n%!" message) fmt

let find_app env name =
  validate_app_name name;
  match App_config.find env.config name with
  | Some app -> app
  | None -> failwith "unknown app"

let list_apps env = App_config.names env.config
let list_guests env = List.map (fun (g : Guest_config.t) -> g.endpoint.name) env.guests |> List.sort compare

let hook_path env app hook_file = Filename.concat (Layout.app_dir env.layout app.App_config.endpoint.name) hook_file

let secure_remote_stage env ~target ~subtree =
  ssh_checked env
    [ target; secure_remote_stage_script ~stage:env.remote_stage ~subtree ]

(* A guest is reached through the compute host rather than directly: it runs its own
   kernel on a private bridge, and the operator's machine has no route to
   it unless it is on the tailnet. ProxyJump makes that the same one-hop
   command either way. *)
let guest_target (guest : Guest_config.t) = guest.login_user ^ "@" ^ guest.endpoint.ip

(* Guest operations make several connections in a row -- the lock, the
   staging check, one or two rsyncs, the commands -- and each would
   authenticate on its own; with a password that means typing it at every
   hop. A shared control socket authenticates once and multiplexes the
   rest. Off with OPS_SSH_MULTIPLEX=0. *)
let guest_ssh_options env =
  if env.ssh_multiplex then
    [ "-o"; "ControlMaster=auto"; "-o"; "ControlPath=" ^ env.ops_control_path; "-o"; "ControlPersist=60" ]
  else []

(* Everything between ssh and the remote command for a guest connection. *)
let guest_jump_options env guest =
  match env.topology with
  | None -> ["-J"; env.compute_target]
  | Some topology -> jump_options (Topology.guest_jumps topology (Guest_config.name guest))
let guest_connection env guest = guest_ssh_options env @ guest_jump_options env guest @ [guest_target guest]

type host = Compute_host | Edge_host | Host of Topology.host | Guest of Guest_config.t

let host_target env = function
  | Compute_host -> env.compute_target
  | Edge_host -> env.edge_target
  | Host host -> host.ssh
  | Guest guest -> guest_target guest

let host_label env = function
  | Host host -> host.id
  | Guest guest -> Guest_config.name guest
  | (Compute_host | Edge_host) as role ->
      match configured_host env (host_target env role) with
      | Some host -> host.id
      | None -> if role = Compute_host then "compute" else "edge"

(* The ssh arguments before the remote command. *)
let host_connection env = function
  | (Compute_host | Edge_host | Host _) as host -> target_connection env (host_target env host)
  | Guest guest -> guest_connection env guest

let host_of_label env label =
  let guest () = List.find_opt (fun guest -> Guest_config.name guest = label) env.guests
    |> Option.map (fun guest -> Guest guest) in
  match env.topology with
  | Some topology ->
      (match List.find_opt (fun (h : Topology.host) -> h.id = label) (Topology.hosts topology) with
       | Some host -> Some (Host host) | None -> guest ())
  | None -> if label = "compute" then Some Compute_host else if label = "edge" then Some Edge_host else guest ()

(* One connection: the stage guard for locks/, then the acquire, which
   also prints the host's applied record -- each ssh connection may cost
   the operator a hardware-key touch. *)
let acquire_lock_script ~stage ~token ~holder =
  secure_remote_stage_script ~stage ~subtree:"locks"
  ^ "\n"
  ^ Remote_lock.acquire_script ~stage ~token ~holder ~record:Applied_record.path
      ~wait_seconds:Remote_lock.stale_after_seconds

let ssh_unreachable_exit = 255

(* Returns the acquire's stdout: the host's applied record, or
   Remote_lock.no_record_marker. stderr is inherited, so a "locked by ..."
   line reaches the terminal. *)
let acquire_lock env ~command host =
  Progress.phase "lock";
  let target = host_target env host and label = host_label env host in
  let holder = Printf.sprintf "%s: serai %s (pid %d)" env.operator command (Unix.getpid ()) in
  match
    ssh_capture env
      (host_connection env host
      @ [ acquire_lock_script ~stage:env.remote_stage ~token:env.lock_token ~holder ])
  with
  | 0, record_output -> record_output
  | code, _ when code = Remote_lock.held_exit ->
      failwith (Printf.sprintf "%s is locked by another serai run (holder above) that did not finish in %d min; retry once it does"
        label (Remote_lock.stale_after_seconds / 60))
  | code, _ when code = Remote_lock.stale_exit ->
      failwith
        (Printf.sprintf "%s has a stale lock (holder above); if that run is dead: serai unlock %s" label label)
  | code, _ when code = ssh_unreachable_exit -> failwith (Printf.sprintf "could not reach %s (%s)" label target)
  | code, _ -> failwith (Printf.sprintf "locking %s failed (exit %d)" label code)

(* Best effort: a failed release must not mask the error that ended the
   run, so it warns instead of raising. The connect timeout bounds how long
   an unreachable host can hold up the exit. *)
let release_lock env host =
  match
    ssh_run env
      ([ "-o"; "ConnectTimeout=10" ]
      @ host_connection env host
      @ [ Remote_lock.release_script ~stage:env.remote_stage ~token:env.lock_token ])
  with
  | 0 -> ()
  | code ->
      Printf.eprintf "warning: releasing the %s lock failed (exit %d); serai unlock %s clears it\n%!"
        (host_label env host) code (host_label env host)

(* Takes [hosts]' locks in order, runs [f] with each host's acquire
   output (its applied record), and releases them in reverse on every exit
   path. Every multi-host run passes the same order (compute, edge), so two runs
   cannot each hold one lock waiting on the other. *)
let with_locks env ~command hosts f =
  let hosts = match env.topology with None -> hosts | Some _ ->
    List.sort_uniq (fun a b -> String.compare (host_target env a) (host_target env b)) hosts in
  let rec take acquired = function
    | [] -> f (List.rev acquired)
    | host :: rest ->
        let record_output = acquire_lock env ~command host in
        Fun.protect
          ~finally:(fun () -> release_lock env host)
          (fun () -> take ((host, record_output) :: acquired) rest)
  in
  take [] hosts

let unlock env label =
  match host_of_label env label with
  | None -> failwith "unlock: expected a configured host ID or guest name"
  | Some host ->
      announce "unlock %s" label;
      ssh_checked env
        (host_connection env host @ [ Remote_lock.unlock_script ~stage:env.remote_stage ])

let current_revision env =
  match Proc.capture env.jj_bin (Applied_record.jj_revision_args ~root:(Layout.config env.layout)) with
  | 0, output -> (
      match Applied_record.revision_of_jj_output output with
      | Ok revision -> revision
      | Error msg -> failwith ("edge: " ^ msg))
  | code, _ -> failwith (Printf.sprintf "edge: could not read the jj revision of %s (exit %d)" (Layout.config env.layout) code)

(* [record_output] is what the host's lock acquire printed. *)
let show_applied_record env host record_output =
  if String.trim record_output = Remote_lock.no_record_marker then
    announce "%s: never applied by serai" (host_label env host)
  else
    match Applied_record.of_string record_output with
    | record -> announce "%s: %s" (host_label env host) (Applied_record.summary record)
    | exception _ -> announce "%s: unreadable record at %s" (host_label env host) Applied_record.path

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun entry -> remove_tree (Filename.concat path entry)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

let rec make_directories path =
  if not (Sys.file_exists path) then begin
    make_directories (Filename.dirname path);
    Sys.mkdir path 0o700
  end

(* The rendered files, written under a private local directory so rsync
   can ship them; removed afterwards whatever happens. *)
let with_local_stage files f =
  let local = Filename.temp_dir "serai-edge" "" in
  Fun.protect
    ~finally:(fun () -> remove_tree local)
    (fun () ->
      List.iter
        (fun (path, contents) ->
          let target = Filename.concat local path in
          make_directories (Filename.dirname target);
          Out_channel.with_open_bin target (fun oc -> output_string oc contents))
        files;
      f local)

(* bootstrap provisions the app's jail only. It deliberately does not push
   Headscale_acl/Pf_rules output: rollout falls through to bootstrap for
   apps without a deploy hook, so a push here would run on routine
   redeploys. The network edge converges through edge instead. *)
(* The app's generated jail script, rendered before any command; a render
   failure names the app. *)
let render_jail_script ~command (app : App_config.t) =
  try Strategy.render_jail_script app with
  | Sexplib.Conv.Of_sexp_error (exn, _) ->
      failwith
        (Printf.sprintf "%s: %s's jail script does not render: %s" command app.endpoint.name (Printexc.to_string exn))
  | Invalid_argument msg -> failwith (Printf.sprintf "%s: %s" command msg)

(* The app's jail script is rendered here and staged as compute/apps/<app>/jail
   in the staged app directory, beside the extra steps it runs, and run. *)
let bootstrap env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  validate_stage env.remote_stage;
  let jail_script = render_jail_script ~command:"bootstrap" app in
  announce "bootstrap %s" app.endpoint.name;
  with_locks env ~command:("bootstrap " ^ app.endpoint.name) [ Compute_host ] (fun _records ->
      secure_remote_stage env ~target:env.compute_target ~subtree:"compute/apps";
      rsync_checked env
        [
          "-az";
          "--delete";
          "--exclude"; ".env"; "--exclude"; ".env.*";
          Layout.lib_dir env.layout;
          Layout.app_dir env.layout app.endpoint.name;
          Printf.sprintf "%s:%s/compute/apps/" env.compute_target env.remote_stage;
        ];
      with_local_stage [ ("jail", jail_script) ] (fun local ->
          rsync_checked env
            [
              "-az"; "--no-owner"; "--no-group";
              Filename.concat local "jail";
              Printf.sprintf "%s:%s/compute/apps/%s/jail" env.compute_target env.remote_stage app.endpoint.name;
            ]);
      ssh_checked env
        [
          env.compute_target;
          Printf.sprintf "doas sh %s/compute/apps/%s/jail" env.remote_stage app.endpoint.name;
        ])

let deploy env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  require_direct_hook env;
  if not (App_config.supports app Deploy) then
    failwith "deploy is not supported for this app";
  announce "deploy %s" app.endpoint.name;
  (* The hook runs from the configuration, so the engine's deploy library
     is handed to it rather than found beside it. *)
  Proc.run_checked (hook_path env app "deploy") [ env.compute_target ]
    ~extra_env:[ ("COMPUTE_TARGET", env.compute_target); ("CURL_BIN", env.curl_bin);
                 ("SERAI_LIB", Layout.lib_dir env.layout) ]

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
  | _ -> failwith "artifact install currently supports Phoenix releases only");
  let safe c = is_stage_char c || c = '.' in
  if identity = "" || identity = "." || identity = ".."
     || String.length identity > 128 || not (String.for_all safe identity) then
    failwith "invalid artifact identity";
  if String.length sha256 <> 64 || not (String.for_all (function
      | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true | _ -> false) sha256) then
    failwith "invalid artifact SHA-256";
  (match Unix.lstat archive with
  | { Unix.st_kind = Unix.S_REG; _ } -> ()
  | _ -> failwith "artifact archive must be a regular file"
  | exception Unix.Unix_error _ -> failwith "artifact archive does not exist");
  validate_stage env.remote_stage;
  let stage = Printf.sprintf "%s/artifacts/%s/%s" env.remote_stage app.endpoint.name identity in
  let installer = Layout.lib_file env.layout "artifact_install.sh" in
  announce "install artifact %s %s (prepare only)" app.endpoint.name identity;
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
   leave nothing to inspect; anything else keeps [retain_remote] set. *)
let run_build_jail env ~retain_remote command =
  retain_remote := true;
  match ssh_run env [ env.compute_target; command ] with
  | 0 -> retain_remote := false
  | code when code = build_torn_down_exit ->
      retain_remote := false;
      failwith "artifact build: the build failed (output above); its build jail was removed"
  | code ->
      failwith (Printf.sprintf
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
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    if (Unix.fstat (Unix.descr_of_in_channel channel)).Unix.st_kind <> Unix.S_REG then
      failwith "artifact build: input must be a regular file";
    let bytes = Bytes.create 65536 in
    let rec consume state =
      let count = input channel bytes 0 (Bytes.length bytes) in
      if count = 0 then state
      else consume (Digestif.SHA256.feed_string state (Bytes.sub_string bytes 0 count))
    in
    Digestif.SHA256.(to_hex (get (consume empty))))

let rec artifact_remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> artifact_remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let artifact_source_configuration env app_name opam_repository =
  match (find_app env app_name).strategy, opam_repository with
  | Strategy_config.Freebsd_native_elixir value, None ->
      value.repo_path, value.release_name, value.packages, None
  | Strategy_config.Freebsd_native_ocaml value, Some _ ->
      value.repo_path, app_name, value.packages, Some ("ocaml-base-compiler." ^ value.ocaml_switch)
  | Strategy_config.Freebsd_native_ocaml _, None ->
      failwith "artifact build: OCaml requires immutable opam repository checkout and revision"
  | Strategy_config.Freebsd_native_elixir _, Some _ ->
      failwith "artifact build: Phoenix does not accept opam repository inputs"
  | _ -> failwith "artifact build: expected declared source strategy"

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
   | _ -> failwith "web bundle: output must be a directory"
   | exception Unix.Unix_error _ -> failwith "web bundle: no output");
  let names = Sys.readdir out in
  if names = [||] then failwith "web bundle: empty output";
  Array.iter (fun name ->
    if name.[0] = '.' || not (String.for_all (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true | _ -> false) name)
    then failwith ("web bundle: unsafe file name " ^ String.escaped name);
    match Unix.lstat (Filename.concat out name) with
    | { Unix.st_kind = Unix.S_REG; _ } -> ()
    | _ -> failwith ("web bundle: not a regular file: " ^ name)) names;
  out

let artifact_source_recipe ?opam_snapshots env ~local ~base_sha256 ~release_name ~packages ~compiler ~opam_repository ~web_bundle =
  Progress.phase "recipe";
  let out = Filename.concat local "recipe" in
  let staged, repository = match compiler, opam_repository with
    | None, None when Option.is_none web_bundle -> Artifact_recipe.stage ~lib_dir:(Layout.lib_dir env.layout) ~out
        ~base_sha256 ~release_name ~packages, None
    | Some compiler, Some (checkout, revision) ->
        let staged = match opam_snapshots with
          | Some cache -> Source_snapshot.stage_cached ~jj_bin:env.jj_bin ~checkout ~revision ~cache
          | None ->
              let path = Filename.concat local "repository" in
              Source_snapshot.stage ~jj_bin:env.jj_bin ~checkout ~revision ~out:path
              |> Result.map (fun commit -> commit, path) in
        let commit, path = match staged with Ok value -> value | Error message -> failwith message in
        let inventory = match Source_inventory.create ~root:path ~commit with
          | Ok value -> value | Error message -> failwith message in
        (match Unix.lstat (Filename.concat path "repo") with
         | {Unix.st_kind=Unix.S_REG; _} -> ()
         | _ -> failwith "artifact build: invalid opam repository marker"
         | exception Unix.Unix_error _ -> failwith "artifact build: missing opam repository marker");
        let receipt = Filename.concat local "repository-inventory" in
        Out_channel.with_open_bin receipt (fun channel -> output_string channel (Source_inventory.canonical inventory));
        Unix.chmod receipt 0o600;
        let sha256 = Source_inventory.identity inventory in
        Artifact_recipe.stage_ocaml ~lib_dir:(Layout.lib_dir env.layout) ~out ~base_sha256 ~release_name ~packages
          ~compiler ~repository_commit:commit ~repository_sha256:sha256 ~web_bundle, Some (path, receipt, sha256)
    | _ -> failwith "artifact build: inconsistent source recipe inputs" in
  let recipe = match staged with Ok value -> value | Error message -> failwith message in
  recipe, repository

let artifact_build_candidate ?checkout ?opam_repository ?opam_snapshots env app_name ~revision ~ip ~base_archive ~base_sha256 ~out =
  let app = find_app env app_name in
  let env = app_env env app_name in
  let repo_path, release_name, packages, compiler = artifact_source_configuration env app_name opam_repository in
  let repo_path = Option.value checkout ~default:repo_path in
  validate_stage env.remote_stage;
  let declared = Network_endpoint.to_list env.endpoints |> List.map (fun endpoint -> endpoint.Network_endpoint.ip) in
  (match Jail_test.validate_ip ~host:(jail_host env app_name) ~declared ip with
   | Ok () -> () | Error message -> failwith message);
  let is_sha256 value = String.length value = 64
    && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value in
  if not (is_sha256 base_sha256) then failwith "artifact build: invalid base SHA-256";
  (match Unix.lstat base_archive with
   | { Unix.st_kind = Unix.S_REG; _ } -> ()
   | _ -> failwith "artifact build: base archive must be regular"
   | exception Unix.Unix_error _ -> failwith "artifact build: base archive not found");
  if artifact_file_sha256 base_archive <> base_sha256 then
    failwith "artifact build: base archive SHA-256 mismatch";
  if out = "" || out = "." || out = ".." then failwith "artifact build: invalid output";
  (match Unix.lstat out with
   | _ -> failwith "artifact build: output already exists"
   | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
  (match Unix.lstat (Filename.dirname out) with
   | { Unix.st_kind = Unix.S_DIR; _ } -> ()
   | _ -> failwith "artifact build: output parent must be a directory"
   | exception Unix.Unix_error _ -> failwith "artifact build: output parent not found");
  if env.lock_token = "" || String.length env.lock_token > 32
     || not (String.for_all (function 'a' .. 'z' | '0' .. '9' | '-' -> true | _ -> false) env.lock_token)
  then failwith "artifact build: invalid lock token for build jail";
  let local = Filename.temp_dir "serai-artifact-build" "" in
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    Progress.phase "source";
    let source = Filename.concat local "source" in
    let source_commit, source_inventory_sha256, inventory_path =
      Progress.with_duration ~phase:"source" ~parent:None (fun () ->
      let source_commit = match Source_snapshot.stage ~jj_bin:env.jj_bin
        ~checkout:repo_path ~revision ~out:source with
        | Ok value -> value | Error message -> failwith message in
      let inventory = match Source_inventory.create ~root:source ~commit:source_commit with
        | Ok value -> value | Error message -> failwith message in
      let source_inventory_sha256 = Source_inventory.identity inventory in
      let inventory_path = Filename.concat local "inventory" in
      Out_channel.with_open_bin inventory_path
        (fun channel -> output_string channel (Source_inventory.canonical inventory));
      Unix.chmod inventory_path 0o600;
      source_commit, source_inventory_sha256, inventory_path) in
    let web_bundle = artifact_web_bundle env app_name in
    let recipe_dir = Filename.concat local "recipe" in
    let recipe, repository = artifact_source_recipe ?opam_snapshots env ~local ~base_sha256 ~release_name
      ~packages ~compiler ~opam_repository ~web_bundle in
    let web = Option.map (fun script ->
      Progress.phase "web-bundle";
      Progress.with_duration ~phase:"web-bundle" ~parent:None (fun () ->
        artifact_build_web_bundle ~source ~script ~local)) web_bundle in
    let recipe_sha256 = recipe.sha256 in
    let output_temp = Filename.temp_dir ~temp_dir:(Filename.dirname out) "serai-candidate-" "" in
    Fun.protect
      ~finally:(fun () -> if Sys.file_exists output_temp then artifact_remove_tree output_temp)
      (fun () ->
        let subtree = "artifact-build/" ^ app.endpoint.name ^ "/" ^ env.lock_token in
        let stage = env.remote_stage ^ "/" ^ subtree in
        let remote path = Printf.sprintf "%s:%s/%s" env.compute_target stage path in
        let retain_remote = ref false in
        let rsync phase source destination =
          retain_remote := true;
          Progress.with_duration ~phase ~parent:None (fun () -> rsync_checked env
            [ "-az"; "--no-owner"; "--no-group"; "--"; source; destination ]);
          retain_remote := false in
        ignore (acquire_lock env ~command:("artifact build " ^ app.endpoint.name) Compute_host);
        Fun.protect ~finally:(fun () ->
          if !retain_remote then begin
            Progress.outcome_unknown ();
            Printf.eprintf
"artifact build: stage %s and host lock retained; inspect failed/uncertain build before serai unlock %s.\n%!" stage (host_label env Compute_host)
          end else release_lock env Compute_host) (fun () ->
          retain_remote := true;
          secure_remote_stage env ~target:env.compute_target ~subtree;
          retain_remote := false;
          let cleanup_script = String.concat "\n"
            [ "set -eu";
              "# artifact-build-cleanup:";
              "parent=" ^ Shell.quote (env.remote_stage ^ "/artifact-build/" ^ app.endpoint.name);
              "stage=" ^ Shell.quote stage;
              {|[ -d "$parent" ] && [ ! -L "$parent" ] || exit 1|};
              {|[ -d "$stage" ] && [ ! -L "$stage" ] || exit 1|};
              {|rm -rf -- "$stage"|};
              {|[ ! -e "$stage" ] && [ ! -L "$stage" ]|} ] in
          let build_result = try
            Progress.phase "transfer";
            rsync "outbound-transfer" (source ^ "/") (remote "source/");
            rsync "outbound-transfer" inventory_path (remote "inventory");
            rsync "outbound-transfer" base_archive (remote "base.txz");
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
                [ "SERAI_LOCK_HELD=1 SERAI_PROGRESS_JSONL=" ^ (if Progress.is_enabled () then "1 " else "0 ") ^ (match compiler, repository with
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
              run_build_jail env ~retain_remote command);
            Progress.phase "transfer";
            rsync "return-transfer" (remote "output/release.tar") (Filename.concat output_temp "release.tar");
            rsync "return-transfer" (remote "output/release.sha256") (Filename.concat output_temp "release.sha256");
            rsync "return-transfer" (remote "output/target-abi") (Filename.concat output_temp "target-abi");
            rsync "return-transfer" (remote "output/dependencies") (Filename.concat output_temp "dependencies");
            Ok ()
          with error -> Error (error, Printexc.get_raw_backtrace ()) in
          let cleanup () =
            if not !retain_remote then begin
              Progress.phase "cleanup";
              retain_remote := true;
              Progress.with_duration ~phase:"controller-cleanup" ~parent:None (fun () ->
                ssh_checked env [env.compute_target; "doas sh -c " ^ Shell.quote cleanup_script]);
              retain_remote := false
            end in
          match build_result with
          | Ok () -> cleanup ()
          | Error (primary, backtrace) ->
              (match cleanup () with
               | () -> Printexc.raise_with_backtrace primary backtrace
               | exception secondary ->
                   Printexc.raise_with_backtrace (Proc.Cleanup_failed (primary, secondary)) backtrace));
        Progress.phase "verify";
        let archive_sha256, target_abi, dependencies =
          Progress.with_duration ~phase:"verification" ~parent:None (fun () ->
          let archive = Filename.concat output_temp "release.tar" in
          let checksum = Filename.concat output_temp "release.sha256" in
          let abi_file = Filename.concat output_temp "target-abi" in
          let dependencies_file = Filename.concat output_temp "dependencies" in
          (match Unix.lstat archive, Unix.lstat checksum, Unix.lstat abi_file,
                 Unix.lstat dependencies_file with
           | { Unix.st_kind = Unix.S_REG; _ }, { Unix.st_kind = Unix.S_REG; _ },
             { Unix.st_kind = Unix.S_REG; _ }, { Unix.st_kind = Unix.S_REG; _ } -> ()
           | _ -> failwith "artifact build: candidate output must be regular"
           | exception Unix.Unix_error _ -> failwith "artifact build: missing candidate output");
          let archive_sha256 =
            let channel = open_in_bin checksum in
            Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
              if in_channel_length channel > 65 then failwith "artifact build: invalid candidate checksum";
              String.trim (really_input_string channel (in_channel_length channel))) in
          if not (is_sha256 archive_sha256)
             || artifact_file_sha256 archive <> archive_sha256 then
            failwith "artifact build: candidate archive SHA-256 mismatch";
          let target_abi =
            let channel = open_in_bin abi_file in
            Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
              let length = in_channel_length channel in
              if length > 129 then failwith "artifact build: invalid target ABI";
              match String.split_on_char '\n' (really_input_string channel length) with
              | [ value; "" ] -> value
              | _ -> failwith "artifact build: invalid target ABI") in
          (match String.split_on_char ':' target_abi with
           | [ "FreeBSD"; major; arch ] when major <> "" && arch <> ""
               && String.for_all (function '0' .. '9' -> true | _ -> false) major
               && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' -> true | _ -> false) arch -> ()
           | _ -> failwith "artifact build: invalid target ABI");
          let dependencies = In_channel.with_open_bin dependencies_file (fun channel ->
            let size = in_channel_length channel in
            if size > 1048576 then failwith "artifact build: oversized dependency inventory";
            match Artifact_manifest.dependencies_of_inventory (really_input_string channel size) with
            | Ok value -> value | Error message -> failwith message) in
          archive_sha256, target_abi, dependencies) in
        let manifest = match Artifact_manifest.create ~name:app_name ~source_commit ~target_abi
          ~dependencies ~recipe_sha256 ~release_name ~archive_sha256 with
          | Ok value -> value | Error message -> failwith message in
        Out_channel.with_open_bin (Filename.concat output_temp "manifest") (fun channel ->
          output_string channel (Artifact_manifest.canonical manifest));
        (match Unix.lstat out with
         | _ -> failwith "artifact build: output already exists"
         | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ());
        Unix.rename output_temp out;
        { source_commit; source_inventory_sha256; target_abi; recipe_sha256; archive_sha256; manifest }))

let artifact_build_store ?reuse ?checkout ?opam_repository ?opam_snapshots env app_name ~revision ~ip ~base_archive ~base_sha256 ~store =
  (match Artifact_store.validate_root store with
   | Ok () -> () | Error message -> failwith message);
  let local = Filename.temp_dir "serai-artifact-publish" "" in
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    match reuse with
    | None ->
        let out = Filename.concat local "candidate" in
        let candidate = artifact_build_candidate ?checkout ?opam_repository ?opam_snapshots env app_name ~revision ~ip
          ~base_archive ~base_sha256 ~out in
        Progress.phase "publish";
        Progress.with_duration ~phase:"publication" ~parent:None (fun () ->
        match Artifact_store.publish ~root:store ~manifest:candidate.manifest
          ~archive:(Filename.concat out "release.tar") with
         | Ok _ -> Artifact_manifest.identity candidate.manifest
         | Error message -> failwith message)
    | Some identity ->
        Progress.phase "reuse";
        let manifest, _ = match Artifact_store.load ~root:store ~identity with
          | Ok value -> value | Error message -> failwith message in
        let repo_path, release_name, packages, compiler =
          artifact_source_configuration env app_name opam_repository in
        let repo_path = Option.value checkout ~default:repo_path in
        if String.length base_sha256 <> 64
           || not (String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) base_sha256)
        then failwith "artifact reuse: invalid base SHA-256";
        (match Unix.lstat base_archive with
         | { Unix.st_kind = Unix.S_REG; _ } -> ()
         | _ -> failwith "artifact reuse: base archive must be regular"
         | exception Unix.Unix_error _ -> failwith "artifact reuse: base archive not found");
        if artifact_file_sha256 base_archive <> base_sha256 then
          failwith "artifact reuse: base archive SHA-256 mismatch";
        let source_commit = match Source_snapshot.stage ~jj_bin:env.jj_bin
          ~checkout:repo_path ~revision ~out:(Filename.concat local "source") with
          | Ok value -> value | Error message -> failwith message in
        let recipe, _ = artifact_source_recipe ?opam_snapshots env ~local ~base_sha256 ~release_name
          ~packages ~compiler ~opam_repository ~web_bundle:(artifact_web_bundle env app_name) in
        let same_source = match manifest.input with
          | Artifact_manifest.Source_commit commit -> commit = source_commit
          | _ -> false in
        if manifest.name <> app_name || not same_source
           || manifest.recipe_sha256 <> recipe.sha256
           || manifest.release_name <> release_name
        then failwith "artifact reuse: requested inputs do not match stored artifact";
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
        let url = match String.split_on_char '$' s.binary_url_template with
          | [before; after] when String.starts_with ~prefix:"{VERSION}" after ->
              before ^ s.version ^ String.sub after 9 (String.length after - 9)
          | _ -> failwith "artifact build: invalid binary URL template" in
        s.binary_name, s.packages,
        Artifact_manifest.Upstream_binary {version=s.version; url; sha256=s.binary_sha256},
        ["SERAI_ARTIFACT_KIND=binary"; "SERAI_EXECUTABLE_SOURCE=" ^ Shell.quote url;
         "SERAI_EXECUTABLE_SHA256=" ^ Shell.quote s.binary_sha256]
    | _ -> failwith "artifact build: expected package or pinned executable strategy" in
  (match Artifact_store.validate_root store with Ok () -> () | Error message -> failwith message);
  validate_stage env.remote_stage;
  let declared = Network_endpoint.to_list env.endpoints |> List.map (fun e -> e.Network_endpoint.ip) in
  (match Jail_test.validate_ip ~host:(jail_host env app_name) ~declared ip with
   | Ok () -> () | Error message -> failwith message);
  if String.length base_sha256 <> 64
     || not (String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) base_sha256)
  then failwith "artifact build: invalid base SHA-256";
  (match Unix.lstat base_archive with
   | {Unix.st_kind=Unix.S_REG; _} -> ()
   | _ -> failwith "artifact build: base archive must be regular"
   | exception Unix.Unix_error _ -> failwith "artifact build: base archive not found");
  if artifact_file_sha256 base_archive <> base_sha256 then
    failwith "artifact build: base archive SHA-256 mismatch";
  if env.lock_token = "" || String.length env.lock_token > 32
     || not (String.for_all (function 'a'..'z'|'0'..'9'|'-' -> true | _ -> false) env.lock_token)
  then failwith "artifact build: invalid lock token";
  let local = Filename.temp_dir "serai-executable-build" "" in
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    Progress.phase "recipe";
    let recipe_dir = Filename.concat local "recipe" in
    let recipe = match Artifact_recipe.stage_executable ~lib_dir:(Layout.lib_dir env.layout) ~out:recipe_dir
      ~base_sha256 ~release_name:release ~packages ~input with
      | Ok value -> value | Error message -> failwith message in
    match reuse with
    | Some identity ->
        Progress.phase "reuse";
        let manifest, _ = match Artifact_store.load ~root:store ~identity with
          | Ok value -> value | Error message -> failwith message in
        if manifest.name <> app_name || manifest.input <> input
           || manifest.recipe_sha256 <> recipe.sha256 || manifest.release_name <> release
        then failwith "artifact reuse: requested inputs do not match stored artifact";
        identity
    | None ->
    if not (env.confirm ("Build verified executable artifact for " ^ app_name ^ "?"))
    then failwith "artifact build: cancelled";
    let subtree = "artifact-executable/" ^ app_name ^ "/" ^ env.lock_token in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let remote name = env.compute_target ^ ":" ^ stage ^ "/" ^ name in
    let retain_remote = ref false in
    ignore (acquire_lock env ~command:("artifact build " ^ app_name) Compute_host);
    Fun.protect ~finally:(fun () ->
      if !retain_remote then begin
        Progress.outcome_unknown ();
        Printf.eprintf
          "artifact build: stage %s and host lock retained; inspect failed/uncertain build before serai unlock %s.\n%!" stage (host_label env Compute_host)
      end else release_lock env Compute_host) (fun () ->
      let checked_remote command =
        retain_remote := true;
        let code = ssh_run env [env.compute_target; command] in
        retain_remote := code >= 128;
        if code <> 0 then failwith (Printf.sprintf "artifact build: remote exited %d" code) in
      checked_remote ("sh -c " ^ Shell.quote
        (secure_remote_stage_script ~stage:env.remote_stage ~subtree));
      let transfer source destination =
        retain_remote := true;
        rsync_checked env
          ["-az"; "--no-owner"; "--no-group"; "--"; source; destination];
        retain_remote := false in
      let cleanup () =
        if not !retain_remote then
          try
            Progress.phase "cleanup";
            checked_remote ("doas sh -c " ^ Shell.quote
            ("set -eu\n# artifact-executable-cleanup:\nstage=" ^ Shell.quote stage
             ^ "\n[ -d \"$stage\" ] && [ ! -L \"$stage\" ]\nrm -rf -- \"$stage\"\n[ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]"))
          with error -> retain_remote := true; raise error in
      let build () =
        Progress.phase "transfer";
        transfer base_archive (remote "base.txz");
        List.iter (fun (name, _) -> transfer (Filename.concat recipe_dir name) (remote name)) recipe.scripts;
        let checks = List.map (fun (name, sha) ->
          "file=" ^ Shell.quote (stage ^ "/" ^ name)
          ^ "\n[ -f \"$file\" ] && [ ! -L \"$file\" ]\n[ \"$(sha256 -q \"$file\")\" = " ^ Shell.quote sha ^ " ]") recipe.scripts in
        let args = [stage ^ "/artifact_build_jail.sh"; "infra-build-" ^ app_name ^ "-" ^ env.lock_token;
          ip; stage ^ "/base.txz"; base_sha256; "-"; "-"; "-"; release; stage ^ "/output"] @ packages in
        Progress.phase "build";
        run_build_jail env ~retain_remote ("doas sh -c " ^ Shell.quote
          (String.concat "\n" (["set -eu"] @ checks @ [String.concat " "
            (["SERAI_LOCK_HELD=1"] @ worker_env @ ["exec sh"] @ List.map Shell.quote args)])));
        Progress.phase "transfer";
        List.iter (fun name -> transfer (remote ("output/" ^ name)) (Filename.concat local name))
          ["release.tar"; "release.sha256"; "target-abi"; "dependencies"] in
      (match build () with
       | () -> cleanup ()
       | exception primary ->
           let backtrace = Printexc.get_raw_backtrace () in
           match cleanup () with
           | () -> Printexc.raise_with_backtrace primary backtrace
           | exception secondary ->
               Printexc.raise_with_backtrace (Proc.Cleanup_failed (primary, secondary)) backtrace));
    Progress.phase "verify";
    let read_evidence name limit =
      let file = Filename.concat local name in
      if (Unix.lstat file).Unix.st_kind <> Unix.S_REG then failwith "artifact build: unsafe evidence";
      In_channel.with_open_bin file (fun channel ->
        if in_channel_length channel > limit then failwith "artifact build: oversized evidence";
        In_channel.input_all channel) in
    let archive_sha256 = String.trim (read_evidence "release.sha256" 65) in
    let target_abi = match String.split_on_char '\n' (read_evidence "target-abi" 129) with
      | [value; ""] -> value
      | _ -> failwith "artifact build: invalid target ABI" in
    (match String.split_on_char ':' target_abi with
     | ["FreeBSD"; major; "amd64"] when major <> ""
         && String.for_all (function '0'..'9' -> true | _ -> false) major -> ()
     | _ -> failwith "artifact build: incompatible executable ABI");
    let dependencies = match Artifact_manifest.dependencies_of_inventory (read_evidence "dependencies" 1048576) with
      | Ok value -> value | Error message -> failwith message in
    let manifest = match Artifact_manifest.create_input ~name:app_name ~input ~target_abi ~dependencies
      ~recipe_sha256:recipe.sha256 ~release_name:release ~archive_sha256 with
      | Ok value -> value | Error message -> failwith message in
    Progress.phase "publish";
    match Artifact_store.publish ~root:store ~manifest ~archive:(Filename.concat local "release.tar") with
    | Ok _ -> Artifact_manifest.identity manifest | Error message -> failwith message)

(* The port a check or an activation probes: the one named http, or the
   only one declared. *)
let check_port (endpoint : Network_endpoint.t) =
  match
    List.find_opt (fun (p : Network_endpoint.named_port) -> p.port_name = "http") endpoint.tailnet_ports,
    endpoint.tailnet_ports with
  | Some p, _ | None, [ p ] -> p.port
  | None, _ -> failwith (endpoint.name ^ ": no http tailnet port to check")

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
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    let scripts = List.map (fun name ->
      let source = Layout.lib_file env.layout name in
      if (Unix.lstat source).Unix.st_kind <> Unix.S_REG then failwith (context ^ ": unsafe helper");
      let snapshot = Filename.concat local name in
      In_channel.with_open_bin source (fun input ->
        if (Unix.fstat (Unix.descr_of_in_channel input)).Unix.st_kind <> Unix.S_REG
        then failwith (context ^ ": unsafe helper");
        Out_channel.with_open_bin snapshot (fun output -> output_string output (In_channel.input_all input)));
      Unix.chmod snapshot 0o600;
      name, snapshot, artifact_file_sha256 snapshot) helpers in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let retain_remote = ref false in
    ignore (acquire_lock env ~command:label Compute_host);
    Fun.protect ~finally:(fun () ->
      if !retain_remote then begin
        Progress.outcome_unknown ();
        Printf.eprintf "%s: remote outcome uncertain; stage %s and host lock retained. Inspect before serai unlock %s.\n%!" context stage (host_label env Compute_host)
      end else release_lock env Compute_host) (fun () ->
        secure_remote_stage env ~target:env.compute_target ~subtree;
        let cleanup () =
          if not !retain_remote then
            try
              Progress.phase "cleanup";
              ssh_checked env [env.compute_target; "sh -c " ^ Shell.quote
              ("set -eu\nstage=" ^ Shell.quote stage ^ "\n[ -d \"$stage\" ] && [ ! -L \"$stage\" ]\nrm -rf -- \"$stage\"\n[ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]")]
            with e -> retain_remote := true; raise e in
        let apply () =
          Progress.phase "transfer";
          let transfer source name =
            (* A failed/interrupted transfer may leave a remote writer. *)
            retain_remote := true;
            rsync_checked env
              ["-az"; "--no-owner"; "--no-group"; "--"; source;
               env.compute_target ^ ":" ^ stage ^ "/" ^ name];
            retain_remote := false in
          List.iter (fun (source, name) -> transfer source name) files;
          List.iter (fun (name, snapshot, _) -> transfer snapshot name) scripts;
          let checks = List.map (fun (name, _, sha) ->
            "file=" ^ Shell.quote (stage ^ "/" ^ name)
            ^ "\n[ -f \"$file\" ] && [ ! -L \"$file\" ]\n[ \"$(sha256 -q \"$file\")\" = " ^ Shell.quote sha ^ " ]") scripts in
          Progress.phase "apply";
          (* Proc folds locally signalled exits into 128+signal. Those, SSH
             transport failure and local exceptions leave the remote outcome unknown. *)
          retain_remote := true;
          let command = String.concat " "
            (("SERAI_LOCK_HELD=1" :: List.map (fun (name, value) -> name ^ "=" ^ value) assignments)
             @ [ "exec sh" ] @ List.map Shell.quote (args stage)) in
          let code = ssh_run env [env.compute_target; "doas sh -c " ^ Shell.quote
            (String.concat "\n" (["set -eu"] @ checks @ [command]))] in
          retain_remote := code >= 128;
          if code <> 0 then failwith (Printf.sprintf "%s: remote exited %d" label code) in
        match apply () with
        | () -> cleanup ()
        | exception primary ->
            let backtrace = Printexc.get_raw_backtrace () in
            match cleanup () with
            | () -> Printexc.raise_with_backtrace primary backtrace
            | exception secondary ->
                Printexc.raise_with_backtrace (Proc.Cleanup_failed (primary, secondary)) backtrace))

let artifact_apply ?(convert=false) ?rehearse_ip env app_name ~store ~identity ~rollback =
  let env = app_env env app_name in
  Progress.phase "verify";
  if (convert && rollback) || (Option.is_some rehearse_ip && (convert || rollback))
  then failwith "artifact apply: invalid operation";
  (* A rehearsal applies to the test jail <app>test at the test ip; every
     in-jail name stays the app's. *)
  let app, jail = match rehearse_ip with
    | None -> find_app env app_name, app_name
    | Some ip ->
        let app = find_app env app_name in
        (match Jail_test.retarget app ~ip with
         | Ok retargeted -> retargeted, Jail_test.name app
         | Error errors -> failwith ("artifact apply: " ^ Network_endpoint.errors_message errors)) in
  let manifest, archive = match Artifact_store.load ~root:store ~identity with
    | Ok entry -> entry | Error message -> failwith message in
  if manifest.name <> app_name || not (String.starts_with ~prefix:"FreeBSD:" manifest.target_abi)
  then failwith "artifact apply: workload or operating system mismatch";
  let settings = match source_release_settings app_name app.strategy, app.strategy, manifest.input with
    | Some settings, _, Artifact_manifest.Source_commit _ -> settings
    | None, Strategy_config.Freebsd_package s, Artifact_manifest.Package_archives package
        when List.mem package s.packages ->
        let status = match s.check_status with None -> "success" | Some status -> string_of_int status in
        let service_status = match s.service_status with Rc -> "rc" | Process -> "process" in
        { release = package; check_path = s.check_path; anchor = "/usr/local/bin/" ^ package;
          health_status = status; migrate = false; service_status }
    | None, Strategy_config.Fetch_binary s, Artifact_manifest.Upstream_binary input ->
        let url = match String.split_on_char '$' s.binary_url_template with
          | [before; after] when String.starts_with ~prefix:"{VERSION}" after ->
              before ^ input.version ^ String.sub after 9 (String.length after - 9)
          | _ -> failwith "artifact apply: invalid binary URL template" in
        if input.url <> url || (not rollback && (input.version <> s.version || input.sha256 <> s.binary_sha256))
        then failwith "artifact apply: immutable input does not match the declaration";
        { release = s.binary_name; check_path = s.check_path; anchor = "/usr/local/bin/" ^ s.binary_name;
          health_status = "success"; migrate = false; service_status = "rc" }
    | _ -> failwith "artifact apply: immutable input does not match the declaration" in
  if manifest.release_name <> settings.release then failwith "artifact apply: release name mismatch";
  (* Conversion moves a legacy executable (package or pinned binary) under
     the release layout; Phoenix apps were adopted by a one-off since
     removed. *)
  if convert && settings.anchor = "-" then failwith "artifact apply: conversion is for executables only";
  let port = check_port app.endpoint in
  let url = Printf.sprintf "http://%s:%d%s" app.endpoint.ip port settings.check_path in
  let mode = if convert then "convert" else if rollback then "rollback" else "upgrade" in
  validate_stage env.remote_stage;
  if not (env.confirm (Printf.sprintf "%s %s to %s (files only; no database rollback)?" mode jail identity))
  then failwith "artifact apply: cancelled";
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
      match Release_probe.check ~app:app_name output with
      | Ok releases -> releases
      | Error message -> failwith message)
  | code, _ ->
      failwith (Printf.sprintf "probing %s's releases on %s failed (exit %d)"
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
    | None -> failwith "revert: only source-built apps revert" in
  if settings.migrate then
    failwith (Printf.sprintf "revert: %s declares migrate; roll it back with serai artifact rollback" app_name);
  validate_stage env.remote_stage;
  let previous =
    match probe_releases env app_name with
    | { previous = Some identity; _ } -> identity
    | { previous = None; _ } -> failwith (Printf.sprintf "revert: %s has no previous release on the host" app_name)
    | exception Failure message -> failwith ("revert: " ^ message) in
  let url = Printf.sprintf "http://%s:%d%s" app.endpoint.ip (check_port app.endpoint) settings.check_path in
  if not (env.confirm (Printf.sprintf "revert %s to %s (files only)?" app_name previous)) then
    failwith "revert: cancelled";
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

(* What _lib/check.sh's check_app needs, from the declaration: the rc
   service (a Phoenix release's name, a package service's own, otherwise the
   app's), the port named
   http or the only tailnet port, the public hostname and the check path. *)
let check_environment (app : App_config.t) =
  let endpoint = app.endpoint in
  let service, check_path = match app.strategy with
    | Strategy_config.Freebsd_native_elixir s -> s.release_name, s.check_path
    | Freebsd_native_ocaml s -> endpoint.name, s.check_path
    | Freebsd_package s -> endpoint.name, s.check_path
    | Fetch_binary s -> endpoint.name, s.check_path
    | Freebsd_package_service s -> s.service, s.check_path in
  [ ("JAIL", endpoint.name); ("JAIL_IP", endpoint.ip); ("PORT", string_of_int (check_port endpoint));
    ("PUBLIC_HOST", endpoint.hostname); ("SERVICE", service); ("CHECK_PATH", check_path) ]

let check env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  require_direct_hook env;
  if not (App_config.supports app Check) then
    failwith "check is not supported for this app";
  announce "check %s" app.endpoint.name;
  Proc.run_checked "sh"
    [ "-c"; {|set -eu; . "$1"; check_app|}; "sh"; Layout.lib_file env.layout "check.sh" ]
    ~extra_env:
      (check_environment app
       @ [
           ("COMPUTE_TARGET", env.compute_target);
           ("EDGE_TARGET", env.edge_target);
           ("CURL_BIN", env.curl_bin);
         ])

let update_version env app_name version =
  let app = find_app env app_name in
  let env = app_env env app_name in
  if not (App_config.supports app Update_version) then
    failwith "update-version is not supported for this app";
  announce "update-version %s" app.endpoint.name;
  Proc.run_checked (hook_path env app "update-version") [ version ]
    ~extra_env:[ ("CURL_BIN", env.curl_bin) ]

(* Every file edge stages, keyed by its path under the remote stage. All
   rendering happens here, on the operator's machine, before any command
   runs: a render error must not leave the compute host's pf updated and the edge host's
   ACL stale. *)
let proxy_workloads env = Option.map Topology.proxy_workloads env.topology

let compute_envs env = match env.topology with
  | None -> [env]
  | Some topology -> Topology.compute_hosts topology |> List.map (fun (host : Topology.host) ->
      let names = Topology.workloads_on topology host.id in
      let endpoints = Network_endpoint.to_list env.endpoints
        |> List.filter (fun (e : Network_endpoint.t) -> List.mem e.name names)
        |> Network_endpoint.validate_all in
      let endpoints = match endpoints with Ok x -> x | Error errors ->
        failwith (Network_endpoint.errors_message errors) in
      {env with compute_target=host.ssh; endpoints})

let pf_output_path env compute = match env.topology with
  | Some topology when List.length (Topology.compute_hosts topology) > 1 ->
      let host = Option.get (configured_host env compute.compute_target) in
      "hosts/" ^ host.id ^ "/service-rules.conf"
  | _ -> "compute/service-rules.conf"

let render_caddy env =
  Caddy_render.render ?proxy:(proxy_workloads env) ~edge:env.edge
    ~root_template:(Layout.caddy_root_template env.layout) ~sites:(Layout.caddy_sites env.layout)
    env.endpoints
  |> Result.map (List.map (fun (path, contents) -> ("edge/caddy-rendered/" ^ path, contents)))

let render_edge env =
  let ( let* ) = Result.bind in
  let* pf = List.fold_left (fun acc compute ->
    let* files = acc in
    let* rules = Pf_rules.render ?proxy:(proxy_workloads env) compute.endpoints in
    Ok (files @ [pf_output_path env compute, rules])) (Ok []) (compute_envs env) in
  let* acl = Headscale_acl.render ?proxy:(proxy_workloads env) ~edge:env.edge env.endpoints in
  let* caddy = render_caddy env in
  Ok (pf @ (("edge/acls.hujson", acl) :: caddy))

let optional_assignment name = function
  | Some value -> [ Printf.sprintf "%s=%s" name (Shell.quote value) ]
  | None -> []

type edge_component = Pf | Acl | Caddy

let edge_component_label = function
  | Pf -> "pf rules (compute)"
  | Acl -> "headscale policy (edge)"
  | Caddy -> "caddy config (edge)"

(* Exit code the three edge scripts use, under <X>_DIFF_ONLY=1, for
   "changes pending": distinct from 0 (already current) and from failure. *)
let changes_pending_exit = 10

(* The command that installs [component] from the staged file, or with
   [~diff_only:true] only validates it and prints the live-vs-staged diff. *)
let edge_command env ~diff_only component =
  let stage = env.remote_stage in
  let diff_flag name = if diff_only then [ name ^ "_DIFF_ONLY=1" ] else [] in
  match component with
  | Pf ->
      ( env.compute_target,
        String.concat " "
          ([ "doas"; "env" ] @ diff_flag "PF"
          @ [ Printf.sprintf "PF_SOURCE=%s/compute/service-rules.conf" stage ]
          @ optional_assignment "EDGE_TS_IP" env.edge_ts_ip
          @ optional_assignment "EDGE_PEER_MATCH" env.edge_peer_match
          @ [ "sh"; Printf.sprintf "%s/compute/01-pf-rules" stage ]) )
  | Acl ->
      ( env.edge_target,
        String.concat " "
          ([ "sudo"; "env" ] @ diff_flag "POLICY"
          @ [
              Printf.sprintf "POLICY_SOURCE=%s/edge/acls.hujson" stage;
              "bash";
              Printf.sprintf "%s/edge/01-headscale-policy" stage;
            ]) )
  | Caddy ->
      let force_build =
        if env.caddy_force_build && not diff_only then [ "CADDY_FORCE_BUILD=1" ] else []
      in
      ( env.edge_target,
        String.concat " "
          ([ "sudo"; "env" ] @ diff_flag "CADDY" @ force_build
          @ [
              Printf.sprintf "CADDY_SOURCE=%s/edge/caddy-rendered" stage;
              "bash";
              Printf.sprintf "%s/edge/02-caddy" stage;
            ]) )

(* --no-owner/--no-group: ssh edge logs in as root, and a root receiver
   under -a would keep the sender's uid, handing the stage to a user the
   next run's secure_remote_stage check then (rightly) refuses. *)
(* The repo's edge/ tree and the rendered Caddy tree from [local], staged
   on the edge. Shared by edge and caddy-install. *)
let stage_edge_payload env =
  let stage = env.remote_stage in
  announce "stage edge (%s)" env.edge_target;
  secure_remote_stage env ~target:env.edge_target ~subtree:"edge";
  (* --delete first: anything staged under edge/ before this would be
     removed. One transfer merges the engine's and the configuration's
     files, so neither's --delete removes the other's. *)
  rsync_checked env
    ([ "-az"; "--no-perms"; "--no-owner"; "--no-group"; "--delete";
       "--exclude"; ".env"; "--exclude"; ".env.*" ]
     @ List.map (fun dir -> dir ^ "/") (Layout.edge_sources env.layout)
     @ [ Printf.sprintf "%s:%s/edge/" env.edge_target stage ])

let stage_edge_host env local =
  let stage = env.remote_stage in
  stage_edge_payload env;
  rsync_checked env
    [
      "-az"; "--no-perms"; "--no-owner"; "--no-group"; "--delete";
      Filename.concat local "edge/caddy-rendered" ^ "/";
      Printf.sprintf "%s:%s/edge/caddy-rendered/" env.edge_target stage;
    ]

let stage_edge env local =
  let stage = env.remote_stage in
  let local_path path = Filename.concat local path in
  List.iter (fun compute ->
    announce "stage %s (%s)" (host_label compute Compute_host) compute.compute_target;
    secure_remote_stage compute ~target:compute.compute_target ~subtree:"compute";
    rsync_checked compute
      ["-az"; "--no-perms"; "--no-owner"; "--no-group";
       local_path (pf_output_path env compute);
       Layout.pf_rules env.layout;
       Printf.sprintf "%s:%s/compute/" compute.compute_target stage]) (compute_envs env);
  stage_edge_host env local;
  (* after stage_edge_host: its edge/ --delete would remove it *)
  rsync_checked env
    [ "-az"; "--no-perms"; "--no-owner"; "--no-group"; local_path "edge/acls.hujson"; Printf.sprintf "%s:%s/edge/" env.edge_target stage ]

(* Each diff prints straight to the terminal (ssh inherits stdout), so the
   operator reads the plan as it is computed. *)
let edge_jobs env = List.map (fun compute -> compute, Pf) (compute_envs env) @ [env, Acl; env, Caddy]

(* Each pending component with the diff it printed: captured, printed, and
   kept, since the plan id names exactly what the operator read. *)
let diff_components env =
  List.filter_map
    (fun (env, component) ->
      let target, command = edge_command env ~diff_only:true component in
      announce "plan %s" (edge_component_label component);
      let code, diff = ssh_capture env [ target; command ] in
      print_string diff;
      flush stdout;
      match code with
      | 0 -> None
      | code when code = changes_pending_exit -> Some (env, component, diff)
      | code ->
          failwith
            (Printf.sprintf "edge: diff for %s failed (exit %d)"
               (edge_component_label component) code))
    (edge_jobs env)

let component_host = function Pf -> Compute_host | Acl | Caddy -> Edge_host
let component_name = function Pf -> "pf" | Acl -> "acl" | Caddy -> "caddy"

type edge_plan = { components : (string * string) list; plan_id : Plan_id.t option }
type edge_outcome = { applied : (string * string) list; failed : (string * string * string) option }

let component_entry (env, component) = (component_name component, host_target env (component_host component))

let edge_plan_of pending =
  { components = List.map (fun (env, component, _) -> component_entry (env, component)) pending;
    plan_id =
      (match pending with
       | [] -> None
       | pending ->
           Some (Plan_id.make ~operation:"edge"
                   (List.concat_map (fun (env, component, diff) ->
                        let name, host = component_entry (env, component) in [ name; host; diff ]) pending))) }

(* Only edge hosts carry an applied record; component_host never names a
   guest. *)
let privilege = function
  | Compute_host -> "doas"
  | Edge_host -> "sudo"
  | Host host -> (match host.os with Topology.Freebsd -> "doas" | Topology.Linux -> "sudo")
  | Guest _ -> invalid_arg "privilege: no applied record on a guest"

let write_applied_record env ~revision host components =
  let record : Applied_record.t =
    {
      revision;
      applied_at = env.now_utc ();
      applied_by = env.operator;
      components = List.map component_name components;
    }
  in
  (* Provenance only: the install already succeeded, so a failed write
     warns rather than failing the edge. *)
  match
    ssh_run env
      (host_connection env host
      @ [ Printf.sprintf "%s sh -c %s" (privilege host) (Shell.quote (Applied_record.write_script record)) ])
  with
  | 0 -> ()
  | code -> Printf.eprintf "warning: applied record for %s not written (exit %d)\n%!" (host_label env host) code

let rendered_files env =
  match render_edge env with Ok files -> files | Error msg -> failwith ("edge render: " ^ msg)

(* One locked edge run: render locally and read the jj revision (failing
   before any remote command), take both hosts' locks, show what each host
   was last applied from, stage, then [f revision]. *)
let with_edge_session env ~command f =
  validate_stage env.remote_stage;
  let files = rendered_files env in
  let revision = current_revision env in
  announce "repo at %s (%s)" (Applied_record.short_commit revision.commit)
    (if revision.is_published then "published" else "local only, not pushed");
  let hosts = match env.topology with
    | None -> [Compute_host; Edge_host]
    | Some topology -> List.map (fun host -> Host host) (Topology.compute_hosts topology) @ [Host (Topology.edge topology)] in
  with_locks env ~command hosts (fun records ->
      List.iter (fun (host, record_output) -> show_applied_record env host record_output) records;
      with_local_stage files (fun local ->
          stage_edge env local;
          f revision))

(* Terraform-style plan: stage, diff, change nothing. *)
let edge_env env = match env.topology with
  | None -> env
  | Some topology -> {env with edge_target=(Topology.edge topology).ssh}

let plan_edge env =
  let env = edge_env env in
  announce "plan edge";
  with_edge_session env ~command:"edge --plan" (fun _revision ->
      match diff_components env with
      | [] ->
          announce "edge: no changes";
          edge_plan_of []
      | pending ->
          announce "edge: changes pending for %s"
            (String.concat ", " (List.map (fun (env,c,_) -> edge_component_label c ^ " [" ^ host_target env (component_host c) ^ "]") pending));
          edge_plan_of pending)

(* Keeps the order the bash ./ops edge used -- pf, then the ACL before
   Caddy so a vhost never proxies to a port the policy still blocks -- but
   installs only what the plan showed as changed, and only once confirmed. Each
   install goes through its script's validated <X>_SOURCE mode rather than
   writing live files from here. The staged files are still in place from
   the plan when installs run: nothing between the two re-stages them. *)
let edge_run ?expect_plan env =
  let env = edge_env env in
  announce "update edge";
  with_edge_session env ~command:"edge" (fun revision ->
      let pending = diff_components env in
      (* Under the locks, on what was just staged and diffed: the approved
         plan or nothing. *)
      Option.iter (fun expected ->
          let current = (edge_plan_of pending).plan_id in
          if current <> Some expected then
            raise (Agent_cli.Stale_plan (Printf.sprintf
                     "edge: stale plan: approved %s, now %s; run serai edge --plan again"
                     (Plan_id.to_string expected)
                     (match current with Some id -> Plan_id.to_string id | None -> "nothing to do"))))
        expect_plan;
      match pending with
      | [] -> announce "edge: already current"; { applied = []; failed = None }
      | pending ->
          let summary = String.concat ", " (List.map (fun (env,c,_) -> edge_component_label c ^ " [" ^ host_target env (component_host c) ^ "]") pending) in
          if not (env.confirm (Printf.sprintf "apply changes to %s?" summary)) then
            failwith "edge: not applied";
          let rec install applied = function
            | [] -> Ok (List.rev applied)
            | (env, component, _) :: rest ->
                let target, command = edge_command env ~diff_only:false component in
                announce "apply %s" (edge_component_label component);
                (match ssh_checked env [ target; command ] with
                 | () -> install ((env, component) :: applied) rest
                 | exception Failure message -> Error (List.rev applied, (env, component), message)) in
          match install [] pending with
          | Error (applied, failed, message) ->
              let name, host = component_entry failed in
              { applied = List.map component_entry applied; failed = Some (name, host, message) }
          | Ok installed ->
              List.iter
                (fun (context, host) ->
                  let target = host_target context host in
                  match List.filter (fun (e,c) -> host_target e (component_host c) = target) installed with
                  | [] -> ()
                  | installed -> write_applied_record context ~revision host (List.map snd installed))
                (List.map (fun compute -> compute, Compute_host) (compute_envs env) @ [env, Edge_host]);
              { applied = List.map component_entry installed; failed = None })

let edge ?expect_plan env =
  match (edge_run ?expect_plan env).failed with
  | None -> ()
  | Some (_, _, message) -> failwith message

(* What edge does not do: edge/02-caddy's unconditional run, which builds
   the binary if needed (or always, under CADDY_FORCE_BUILD=1), writes the
   unit, then installs and reloads the rendered tree. For a first install,
   a rebuild or a unit change; no diff and no applied record, since edge
   stays the way config converges. *)
let caddy_install env =
  let env = edge_env env in
  validate_stage env.remote_stage;
  let files =
    match render_caddy env with Ok files -> files | Error msg -> failwith ("caddy-install render: " ^ msg)
  in
  announce "caddy-install";
  with_locks env ~command:"caddy-install" [ Edge_host ] (fun _records ->
      with_local_stage files (fun local ->
          stage_edge_host env local;
          let target, command = edge_command env ~diff_only:false Caddy in
          announce "will run edge/02-caddy on %s: build if needed%s, unit, install, reload" target
            (if env.caddy_force_build then " (forced)" else "");
          let host = host_label env Edge_host in
          if not (env.confirm (Printf.sprintf "run edge/02-caddy (build if needed, unit, install, reload) on %s?" host)) then
            failwith "caddy-install: not applied";
          announce "apply caddy install (%s)" host;
          ssh_checked env [ target; command ]))

(* Central logging: the logs jail's VictoriaLogs and its senders. Each
   sender is installed by its own script on its own host, under that host's
   lock. The compute host's is not part of the logs jail's bootstrap: it installs a
   relay on the host and a sender in every jail logging.sexp names. *)
type logging_action = Normal_logging | Recovery_check | Recovery_apply | Recovery_health
type edge_logging_component = Edge_sender | Vmui_auth

let logging_action_arg = function
  | Normal_logging -> ""
  | Recovery_check -> " --recover-check"
  | Recovery_apply -> " --recover"
  | Recovery_health -> " --recover-health"

(* _lib/logging and the targets rendered from logging.sexp, staged as
   compute/apps/<receiver>/logging-targets, where the installer, told the
   receiver, looks. *)
type compute_logging_mode = Converge | Replace

(* The app logging.sexp names receives every sender's syslog; the policy
   has checked it is declared. *)
let logging_receiver env policy =
  match App_config.find env.config (Logging_policy.receiver policy) with
  | Some app -> Logging_relay.receiver (App_config.endpoint app)
  | None -> failwith ("logging: undeclared receiver " ^ Logging_policy.receiver policy)

let install_compute_logging ?(mode = Converge) env =
  validate_stage env.remote_stage;
  let policy = Logging_policy.load ~layout:env.layout ~apps:env.config in
  let targets = Logging_policy.render_targets policy in
  let receiver = Logging_policy.receiver policy in
  (* The receiver's host runs the relay; it accepts that host's guests. *)
  let host = jail_host env receiver in
  let guests = match env.topology with
    | None -> []
    | Some topology -> List.filter_map (fun (g : Guest_config.t) ->
        if (Topology.guest topology (Guest_config.name g)).host = host.id then Some (Guest_config.endpoint g)
        else None) env.guests in
  let relay = match Result.bind (logging_receiver env policy) (fun receiver -> Logging_relay.v ~receiver ~host ~guests) with
    | Ok relay -> relay | Error e -> failwith ("logging: " ^ Logging_relay.error_message e) in
  announce "install compute logging";
  with_locks env ~command:"install compute logging" [ Compute_host ] (fun _records ->
      secure_remote_stage env ~target:env.compute_target ~subtree:"compute/apps";
      rsync_checked env
        [
          "-az"; "--delete";
          Layout.lib_dir env.layout;
          Printf.sprintf "%s:%s/compute/apps/" env.compute_target env.remote_stage;
        ];
      (* Each reviewed sender from its app, at compute/apps/<app>/logging/<source>
         beside _lib, where bootstrap.sh looks; --relative creates the path. *)
      List.iter (fun (jail, source) ->
        rsync_checked env
          [
            "-az"; "--delete"; "--relative";
            Filename.concat (Layout.apps_dir env.layout)
              (String.concat "/" [ "."; jail; "logging"; source ]);
            Printf.sprintf "%s:%s/compute/apps/" env.compute_target env.remote_stage;
          ]) (Logging_policy.reviewed policy);
      with_local_stage
        [ (receiver ^ "/logging-targets", targets);
          (receiver ^ "/syslog-ng-host.conf", Logging_relay.render_host relay);
          (receiver ^ "/syslog-ng-jail.conf", Logging_relay.render_jail relay);
          (receiver ^ "/guest-bridge", Logging_relay.render_bridge relay) ] (fun local ->
          rsync_checked env
            [
              "-az"; "--no-owner"; "--no-group";
              Filename.concat local receiver;
              Printf.sprintf "%s:%s/compute/apps/" env.compute_target env.remote_stage;
            ]);
      ssh_checked env
        [ env.compute_target; Printf.sprintf "doas sh %s/compute/apps/_lib/logging/bootstrap.sh %s%s" env.remote_stage
            receiver (match mode with Converge -> "" | Replace -> " --replace") ])

let install_edge_logging_component ?(action = Normal_logging) env component =
  validate_stage env.remote_stage;
  let script = match component with Edge_sender -> "03-logging" | Vmui_auth -> "04-vmui-auth" in
  (* The sender's config, and the receiver its checks use, from the receiver app. *)
  let rendered = match component with
    | Vmui_auth -> []
    | Edge_sender ->
        let policy = Logging_policy.load ~layout:env.layout ~apps:env.config in
        let receiver = match logging_receiver env policy with
          | Ok receiver -> receiver | Error e -> failwith ("logging: " ^ Logging_relay.error_message e) in
        let template = In_channel.with_open_bin (Layout.edge_sender_template env.layout) In_channel.input_all in
        [ ("edge/syslog-ng-victoria.conf", Logging_relay.render_edge_sender receiver ~template);
          ("edge/logging-receiver", Logging_relay.render_receiver receiver) ] in
  with_locks env ~command:("install " ^ script ^ logging_action_arg action) [ Edge_host ] (fun _records ->
      stage_edge_payload env;
      (* after the payload: its edge/ --delete would remove them *)
      if rendered <> [] then
        with_local_stage rendered (fun local ->
            rsync_checked env
              [ "-az"; "--no-owner"; "--no-group"; Filename.concat local "edge";
                Printf.sprintf "%s:%s/" env.edge_target env.remote_stage ]);
      announce "install %s (edge)" script;
      ssh_checked env
        [ env.edge_target; Printf.sprintf "sudo bash %s/edge/%s%s" env.remote_stage script (logging_action_arg action) ])

let fail_on_error = function Ok () -> () | Error msg -> failwith msg

(* Every name and ip a test jail must not take: the apps' and guests'. *)
let declared_endpoints env =
  List.map App_config.endpoint env.config @ Network_endpoint.to_list env.endpoints

let jail_test_stage env test_name = Printf.sprintf "%s/jail-test/%s" env.remote_stage test_name

(* Tries [app_name]'s generated jail script on the throwaway jail
   <app>test at [ip]. Everything is validated and rendered before the first
   command; the compute host lock is held from staging to the end of the run. The
   stage-guard ssh also probes for an existing <app>test (no extra
   connection, so no extra key touch); one at another ip is refused before
   anything is staged. *)
(* <app>test, refused unless it and [ip] are free of every declared name and ip. *)
let validate_test_jail env (app : App_config.t) ~ip =
  let test_name = Jail_test.name app in
  validate_app_name test_name;
  let declared = declared_endpoints env in
  fail_on_error
    (Jail_test.validate_name ~declared:(List.map (fun (e : Network_endpoint.t) -> e.name) declared) test_name);
  fail_on_error (Jail_test.validate_ip ~host:(jail_host env app.endpoint.name)
    ~declared:(List.map (fun (e : Network_endpoint.t) -> e.ip) declared) ip);
  test_name

let jail_test env app_name ~ip =
  let app = find_app env app_name in
  let env = app_env env app_name in
  validate_stage env.remote_stage;
  let test_name = validate_test_jail env app ~ip in
  let script =
    match Jail_test.render app ~ip with
    | Ok script -> script
    | Error errors -> failwith ("jail-test: " ^ Network_endpoint.errors_message errors)
    | exception Sexplib.Conv.Of_sexp_error (exn, _) ->
        failwith (Printf.sprintf "jail-test: %s's jail script does not render: %s" app_name (Printexc.to_string exn))
    | exception Invalid_argument msg -> failwith ("jail-test: " ^ msg)
  in
  let dataset = Jail_test.dataset app in
  let stage = jail_test_stage env test_name in
  announce "jail-test %s as %s (%s)" app.endpoint.name test_name ip;
  with_locks env ~command:("jail-test " ^ app.endpoint.name) [ Compute_host ] (fun _records ->
      let guard_and_probe =
        secure_remote_stage_script ~stage:env.remote_stage ~subtree:("jail-test/" ^ test_name)
        ^ "\n" ^ Jail_test.existing_ip_script ~name:test_name ()
      in
      (match ssh_capture env [ env.compute_target; guard_and_probe ] with
      | 0, output ->
          (match Jail_test.check_existing ~app:app.endpoint.name ~name:test_name ~ip output with
           | Ok (Jail_test.Absent | Jail_test.Same_ip) -> ()
           | Error message -> failwith message)
      | code, _ -> failwith (Printf.sprintf "jail-test: staging guard on %s failed (exit %d)" (host_label env Compute_host) code));
      with_local_stage [ ("jail", script) ] (fun local ->
          (* jail is excluded from the app-dir rsync, so only the rendered
             script is ever at the path that runs as root. --no-perms keeps
             the app dir's 0755 off the guarded stage dir, which must stay
             0700 or the next jail-test's staging guard refuses it. *)
          rsync_checked env
            [
              "-az"; "--no-perms"; "--no-owner"; "--no-group"; "--delete"; "--exclude=/jail";
              "--exclude"; ".env"; "--exclude"; ".env.*";
              Layout.app_dir env.layout app.endpoint.name ^ "/";
              Printf.sprintf "%s:%s/" env.compute_target stage;
            ];
          rsync_checked env
            [
              "-az"; "--no-perms"; "--no-owner"; "--no-group";
              Filename.concat local "jail";
              Printf.sprintf "%s:%s/jail" env.compute_target stage;
            ]);
      announce "will create jail %s at %s: root /jails/%s, jail.conf block and jail_list entry %s%s"
        test_name ip test_name test_name
        (match dataset with Some d -> ", zfs dataset " ^ d | None -> "");
      (* The test jail is not throwaway by itself: it outlives this run
         and runs a real service until it is destroyed. *)
      announce
        "%s joins jail_list and autostarts on reboot; the script starts the jail and, if it enables one, %s's rc.d \
         service %s; destroy it when done: serai jail-test %s --destroy"
        test_name app.endpoint.name app.endpoint.name app.endpoint.name;
      if
        not
          (env.confirm
             (Printf.sprintf "create test jail %s (%s) on %s from %s's generated jail script?" test_name ip (host_label env Compute_host)
                app.endpoint.name))
      then failwith "jail-test: not run";
      announce "run generated jail script for %s (compute)" test_name;
      ssh_checked env
        [ env.compute_target; "doas sh " ^ Shell.quote (stage ^ "/jail") ];
      announce "inspect %s, then remove it: serai jail-test %s --destroy" test_name app.endpoint.name)

(* Destroys the test jail jail_test created: stop, jail.conf block,
   jail_list entry, the test dataset if any, the jail root. The name and
   dataset are refused unless they end in test, here and in the script. *)
let jail_test_destroy env app_name =
  let app = find_app env app_name in
  let env = app_env env app_name in
  let test_name = Jail_test.name app in
  validate_app_name test_name;
  fail_on_error
    (Jail_test.validate_name
       ~declared:(List.map (fun (e : Network_endpoint.t) -> e.name) (declared_endpoints env))
       test_name);
  let dataset =
    try Jail_test.dataset app with
    | Sexplib.Conv.Of_sexp_error (exn, _) ->
        failwith (Printf.sprintf "jail-test --destroy: %s: %s" app_name (Printexc.to_string exn))
    | Invalid_argument msg -> failwith ("jail-test --destroy: " ^ msg)
  in
  let target =
    match Jail_test.validate_destroy_target ~name:test_name ?dataset () with
    | Ok target -> target
    | Error msg -> failwith msg
  in
  let script = Jail_test.destroy_script target in
  announce "jail-test %s --destroy" app.endpoint.name;
  with_locks env ~command:("jail-test " ^ app.endpoint.name ^ " --destroy") [ Compute_host ] (fun _records ->
      announce "will destroy jail %s: stop it, remove its jail.conf block and jail_list entry%s, remove /jails/%s"
        test_name
        (match dataset with Some d -> ", zfs destroy -r " ^ d | None -> "")
        test_name;
      if not (env.confirm (Printf.sprintf "destroy test jail %s on %s?" test_name (host_label env Compute_host))) then
        failwith "jail-test --destroy: not run";
      announce "destroy %s (compute)" test_name;
      ssh_checked env [ env.compute_target; "doas sh -c " ^ Shell.quote script ])

(* The bhyve guest lifecycle: provision, build and deploy. Every connection goes through the compute host by ProxyJump and shares
   the control socket; the steps that run a guest script ask for a TTY,
   because su must prompt for the guest's root password (build too, as
   the bash ./ops always did). *)

(* serai new: the declaration a new app starts from, and nothing else: no
   host is touched. The files are written only if none exists, and the
   whole declaration must load and render afterwards, or they are removed
   and topology.sexp is put back. *)
type new_kind = New_phoenix | New_ocaml

let new_app env name ~kind ~repo ~hostname =
  let read path = In_channel.with_open_bin path In_channel.input_all in
  let repo = if Filename.is_relative repo then Filename.concat (Sys.getcwd ()) repo else repo in
  if not (Sys.file_exists repo && Sys.is_directory repo) then failwith ("new: " ^ repo ^ " is not a directory");
  let source = match Source_mirror.origin_url ~jj_bin:env.jj_bin repo with
    | Ok url -> url
    | Error message -> failwith (Printf.sprintf "new: %s: %s (builds fetch the origin)" repo message) in
  let kind = match kind with
    | New_ocaml -> App_scaffold.Ocaml
    | New_phoenix ->
        let mix_exs = Filename.concat repo "mix.exs" in
        if not (Sys.file_exists mix_exs) then failwith ("new: no mix.exs in " ^ repo);
        let release_ex release =
          let path = Filename.concat repo (Printf.sprintf "lib/%s/release.ex" release) in
          if Sys.file_exists path then Some (read path) else None in
        match App_scaffold.phoenix ~mix_exs:(read mix_exs) ~release_ex with
        | Ok kind -> kind
        | Error message -> failwith ("new: " ^ message) in
  let declaration = match Declaration.load ~layout:env.layout with
    | Ok declaration -> declaration
    | Error error -> failwith ("new: " ^ Declaration.error_message error) in
  let topology_path = Layout.topology env.layout in
  let topology = read topology_path in
  let templates = Caddy_render.template_names (Layout.caddy_sites env.layout) in
  let plan = match App_scaffold.plan declaration ~topology ~templates
                     { name; kind; repo_path = repo; source; hostname } with
    | Ok plan -> plan
    | Error message -> failwith message in
  let app_dir = Layout.app_dir env.layout name in
  List.iter (fun path ->
      if Sys.file_exists path then failwith ("new: " ^ path ^ " already exists"))
    (app_dir :: List.map (fun (f : App_scaffold.file) -> Layout.config_path env.layout f.path) plan.files);
  let write path contents = Out_channel.with_open_bin path (fun out -> output_string out contents) in
  let undo () =
    List.iter (fun (f : App_scaffold.file) ->
        let path = Layout.config_path env.layout f.path in
        if Sys.file_exists path then Sys.remove path) plan.files;
    if Sys.file_exists app_dir then Sys.rmdir app_dir;
    write topology_path topology in
  (try
     Sys.mkdir app_dir 0o755;
     List.iter (fun (f : App_scaffold.file) -> write (Layout.config_path env.layout f.path) f.contents) plan.files;
     write topology_path plan.topology;
     match Result.bind
             (Result.map_error Declaration.error_message (Declaration.load ~layout:env.layout))
             Validation.render_all with
     | Ok _ -> ()
     | Error message -> failwith ("new: the declaration does not render with " ^ name ^ ": " ^ message)
   with exn -> undo (); raise exn);
  plan

type up_target = Live | Rehearse of string | Update

type up_jail = Jail_ready | Jail_create | Jail_needs_env of string
type up_release = Reuse of string | Build of { ip : string; base_sha256 : string }

type up_plan = {
  app : string;
  host : string;
  source : string;
  commit : string;
  local : bool;
  release : up_release;
  jail : up_jail;
  rehearsal : (string * string) option;
  public_url : string;
}

let short value = if String.length value > 12 then String.sub value 0 12 else value

type up_step = Jail | Build | Release | Edge | Check
type step_status = Done | Skipped | Failed of string | Not_run
type up_result = Deployed of string | Stopped_for_env of string | Step_failed of up_step * string
type up_outcome = { steps : (up_step * step_status) list; result : up_result }

let up_steps = [ Jail; Build; Release; Edge; Check ]
let step_index = function Jail -> 0 | Build -> 1 | Release -> 2 | Edge -> 3 | Check -> 4
let step_name = function
  | Jail -> "jail" | Build -> "build" | Release -> "release" | Edge -> "edge" | Check -> "check"

(* Everything the apply acts on, in a fixed order. *)
let up_plan_id_of ~app ~host ~source ~commit ~local ~release ~jail ~rehearsal ~public_url =
  Plan_id.make ~operation:"up"
    ([ app; host; source; commit; string_of_bool local ]
     @ (match release with Reuse identity -> [ "reuse"; identity ] | Build { ip; base_sha256 } -> [ "build"; ip; base_sha256 ])
     @ (match jail with Jail_ready -> [ "ready" ] | Jail_create -> [ "create" ] | Jail_needs_env m -> [ "needs_env"; m ])
     @ (match rehearsal with None -> [ "live" ] | Some (jail, ip) -> [ "rehearsal"; jail; ip ])
     @ [ public_url ])

let up_plan_id (p : up_plan) =
  up_plan_id_of ~app:p.app ~host:p.host ~source:p.source ~commit:p.commit ~local:p.local ~release:p.release
    ~jail:p.jail ~rehearsal:p.rehearsal ~public_url:p.public_url

let print_up_plan ?(target = Live) plan =
  (match plan.rehearsal with
   | None -> announce "up %s on %s" plan.app plan.host
   | Some (jail, ip) -> announce "up %s on %s, rehearsed in %s at %s" plan.app plan.host jail ip);
  Printf.printf "    source   %s @ %s%s\n" plan.source plan.commit
    (if plan.local then "  (local checkout, not verified as pushed)" else "");
  (match plan.jail with
   | Jail_ready -> ()
   | Jail_create -> Printf.printf "    jail     create %s, then stop for its env\n" plan.app
   | Jail_needs_env message -> Printf.printf "    jail     refused until its env is in place: %s\n" message);
  (match plan.release with
   | Reuse identity -> Printf.printf "    release  reuse %s\n" identity
   | Build { ip; base_sha256 } -> Printf.printf "    release  build in jail %s from base %s\n" ip (short base_sha256));
  (match plan.rehearsal with
   | None when target = Update ->
       Printf.printf "    then     install and restart %s, check %s (no edge)\n%!" plan.app plan.public_url
   | None ->
       Printf.printf "    then     install and restart %s, update the edge if needed, check %s\n%!"
         plan.app plan.public_url
   | Some (jail, ip) ->
       Printf.printf "    then     install and start %s in %s and check it at %s (no edge, no public URL)\n%!"
         plan.app jail ip);
  if target = Live && plan.rehearsal = None then
    Printf.printf "plan %s\n%!" (Plan_id.to_string (up_plan_id plan))

(* Everything up decides before asking: the jail's state, the source
   commit and whether the release is reused or built. [apply] does the rest
   and is only called after confirmation, with an env that no longer asks;
   [plan_only] changes no host (a missing test jail is refused, not created). *)
let prepare_up ?local_source ?(target = Live) ~plan_only env app_name ~revision ~cache ~store =
  (* An update builds only what the remote has: never a local checkout. *)
  if target = Update && Option.is_some local_source then
    failwith "update: builds pushed commits only, not a local checkout";
  let app = find_app env app_name in
  let rehearse_ip = match target with Rehearse ip -> Some ip | Live | Update -> None in
  let topology = match env.topology with
    | Some topology -> topology | None -> failwith "up: configured topology required" in
  let inputs = match Up_inputs.of_app ~topology app with
    | Ok inputs -> inputs | Error message -> failwith message in
  let env = app_env env app_name in
  let ok = function Ok value -> value | Error message -> failwith message in
  (match Artifact_store.validate_root store with Ok () -> () | Error m -> failwith m);
  (* A rehearsal deploys into the test jail <app>test at [ip], probed
     read-only first: does it exist, and is its env in place. A missing jail
     is created, and the run stops for the operator to write its env. *)
  let rehearsal = Option.map (fun ip ->
      let jail = validate_test_jail env app ~ip in
      let probe = Jail_test.existing_ip_script ~name:jail () ^ "\n"
                  ^ Jail_test.env_file_script ~name:jail ~app:app_name in
      match ssh_capture env [ env.compute_target; "doas sh -c " ^ Shell.quote probe ] with
      | 0, output ->
          let env_file = Jail_test.check_env_file ~app:app_name ~name:jail output in
          (match ok (Jail_test.check_existing ~app:app_name ~name:jail ~ip output), env_file with
           | Jail_test.Same_ip, Ok () -> jail, ip
           | Jail_test.Same_ip, Error message -> failwith ("up: " ^ message)
           | Jail_test.Absent, _ when plan_only ->
               failwith (Printf.sprintf "up: %s does not exist yet; run without --plan to create it" jail)
           | Jail_test.Absent, _ ->
               jail_test env app_name ~ip;
               failwith (Printf.sprintf "up: created %s; %s" jail
                 (match env_file with Error message -> message | Ok () -> "run the same command again")))
      | code, _ -> failwith (Printf.sprintf "up: probing %s on %s failed (exit %d)" jail (host_label env Compute_host) code))
      rehearse_ip in
  (* The app's own jail, unless rehearsing: a new app's is created here, at
     an address no other jail holds, declared or not. *)
  let jail = match rehearsal with
    | Some _ -> Jail_ready
    | None -> (
        match ssh_capture env [ env.compute_target; "doas sh -c " ^ Shell.quote (Jail_probe.script ~app:app_name) ] with
        | 0, output -> (
            match ok (Jail_probe.check ~app:app_name ~ip:app.endpoint.ip output) with
            | Jail_probe.Absent -> Jail_create
            | Jail_probe.Present (Ok ()) -> Jail_ready
            | Jail_probe.Present (Error message) -> Jail_needs_env message)
        | code, _ -> failwith (Printf.sprintf "up: probing jail %s on %s failed (exit %d)" app_name (host_label env Compute_host) code)) in
  Progress.phase "source";
  let checkout, commit = match local_source with
    | Some path -> path, revision
    | None ->
        let mirror = ok (Source_mirror.sync ~jj_bin:env.jj_bin ~cache ~name:app_name ~url:inputs.source_url) in
        Source_mirror.path mirror, ok (Source_mirror.resolve ~jj_bin:env.jj_bin mirror ~revision) in
  let opam_repository = Option.map (fun (pinned : Strategy_config.pinned_git) ->
      let mirror = ok (Source_mirror.sync ~jj_bin:env.jj_bin ~cache ~name:"opam-repository" ~url:pinned.url) in
      Source_mirror.path mirror, ok (Source_mirror.resolve ~jj_bin:env.jj_bin mirror ~revision:pinned.commit))
    inputs.opam_repository in
  let base_sha256 = inputs.build.base_sha256 in
  let base_archive = ok (Base_archive.ensure ~curl_bin:env.curl_bin ~cache ~url:inputs.build.base_url ~sha256:base_sha256) in
  Progress.phase "recipe";
  (* The pinned opam tree is exported once per commit, not on every run. *)
  let opam_snapshots = Filename.concat cache "opam-snapshots" in
  let _, release_name, packages, compiler = artifact_source_configuration env app_name opam_repository in
  let recipe_sha256 =
    let local = Filename.temp_dir "serai-up-recipe" "" in
    Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
      (fst (artifact_source_recipe ~opam_snapshots env ~local ~base_sha256 ~release_name ~packages ~compiler
              ~opam_repository ~web_bundle:(artifact_web_bundle env app_name))).sha256) in
  let existing = ok (Artifact_store.find ~root:store ~f:(fun (m : Artifact_manifest.t) ->
      m.name = app_name && m.input = Artifact_manifest.Source_commit commit
      && m.recipe_sha256 = recipe_sha256 && m.release_name = release_name)) in
  let plan = {
    app = app_name; host = inputs.host.id;
    source = (if local_source = None then inputs.source_url else checkout);
    commit; local = local_source <> None;
    release = (match existing with
      | Some identity -> Reuse identity
      | None -> Build { ip = inputs.build.ip; base_sha256 });
    jail; rehearsal; public_url = inputs.public_url;
  } in
  (* Each step's outcome is data, so up and up --json report the same run.
     A step that fails stops the run; the steps after it did not run. *)
  let apply env =
    let statuses = Array.make (List.length up_steps) Not_run in
    let set step status = statuses.(step_index step) <- status in
    let run step f = match f () with
      | value -> set step Done; Ok value
      | exception Failure message -> set step (Failed message); Error (Step_failed (step, message)) in
    let ( let* ) = Result.bind in
    let result =
      let* () = match jail with
        | Jail_ready -> Ok (set Jail Skipped)
        | Jail_needs_env message -> set Jail (Failed message); Error (Step_failed (Jail, message))
        | Jail_create ->
            let* () = run Jail (fun () -> bootstrap env app_name) in
            Error (Stopped_for_env (Printf.sprintf
              "created jail %s; write /jails/%s/etc/%s/env from %s, root:%s 0640, \
               then run the same command again" app_name app_name app_name
              (Layout.Relative.app_file ~app:app_name "env.template") app_name)) in
      let* identity = match existing with
        | Some identity -> set Build Skipped; Ok identity
        | None -> run Build (fun () ->
            artifact_build_store ~checkout ?opam_repository ~opam_snapshots env app_name ~revision:commit
              ~ip:inputs.build.ip ~base_archive ~base_sha256 ~store) in
      match rehearsal with
      | Some (_, ip) ->
          (* Activation checks its health at the jail address. *)
          let* () = run Release (fun () -> artifact_apply ~rehearse_ip:ip env app_name ~store ~identity ~rollback:false) in
          set Edge Skipped; set Check Skipped;
          Ok (Deployed identity)
      | None ->
          let* () = run Release (fun () -> artifact_apply env app_name ~store ~identity ~rollback:false) in
          (* The edge renders from the declaration, never from app source,
             so moving an app's revision cannot change it. *)
          let* () = match target with
            | Update -> Ok (set Edge Skipped)
            | Live | Rehearse _ -> run Edge (fun () -> edge env) in
          let* () = run Check (fun () ->
              Progress.phase "check";
              announce "check %s" inputs.public_url;
              match Proc.run env.curl_bin [ "-fsS"; "--max-time"; "15"; "-o"; "/dev/null"; "--"; inputs.public_url ] with
              | 0 -> ()
              | code -> failwith (Printf.sprintf "up: %s answered with an error (curl exit %d)" inputs.public_url code)) in
          Ok (Deployed identity) in
    { steps = List.map (fun step -> step, statuses.(step_index step)) up_steps;
      result = (match result with Ok result | Error result -> result) } in
  plan, apply

let up_plan ?local_source env app_name ~revision ~cache ~store =
  fst (prepare_up ?local_source ~plan_only:true env app_name ~revision ~cache ~store)

let up_run ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store =
  let plan, apply = prepare_up ?local_source ?target ~plan_only:false env app_name ~revision ~cache ~store in
  print_up_plan ?target plan;
  Option.iter (fun expected ->
      let current = up_plan_id plan in
      if current <> expected then
        raise (Agent_cli.Stale_plan (Printf.sprintf
                 "up: stale plan: approved %s, now %s; run serai up %s --revision %s --plan again"
                 (Plan_id.to_string expected) (Plan_id.to_string current) app_name revision))) expect_plan;
  let question = match plan.jail, target with
    | Jail_needs_env message, Some Update -> failwith ("update: " ^ message)
    | Jail_create, Some Update ->
        failwith (Printf.sprintf "update: %s has no jail; create it with serai up" app_name)
    | Jail_needs_env message, _ -> failwith ("up: " ^ message)
    | Jail_create, _ -> Printf.sprintf "create jail %s at %s?" app_name (find_app env app_name).endpoint.ip
    | Jail_ready, _ -> Printf.sprintf "deploy %s at %s?" app_name (short plan.commit) in
  if not (env.confirm question) then failwith "up: not applied";
  (* One confirmation covers the whole sequence. *)
  plan, apply { (app_env env app_name) with confirm = (fun _ -> true) }

let up ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store =
  let plan, outcome = up_run ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store in
  match outcome.result, plan.rehearsal with
  | Deployed identity, Some (jail, ip) ->
      announce "%s is up in %s at %s (%s); destroy it when done: serai jail-test %s --destroy"
        app_name jail ip identity app_name
  | Deployed identity, None -> announce "%s is up at %s (%s)" app_name (short plan.commit) identity
  | Stopped_for_env message, _ -> failwith ("up: " ^ message)
  | Step_failed (_, message), _ -> failwith message

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
  (match Artifact_store.validate_root store with Ok () -> () | Error message -> failwith message);
  let selected = Option.map (fun identity ->
    match Artifact_store.load ~root:store ~identity with
    | Ok (manifest, _) -> manifest | Error message -> failwith message) reuse in
  let _, checkout = resolve_source_checkout env guest in
  let local = Filename.temp_dir "serai-guest-artifact" "" in
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    Progress.phase "source";
    let snapshot checkout revision label =
      let path = Filename.concat local label in
      let commit = match Source_snapshot.stage ~jj_bin:env.jj_bin ~checkout ~revision ~out:path with
        | Ok value -> value | Error message -> failwith message in
      let inventory = match Source_inventory.create ~root:path ~commit with
        | Ok value -> value | Error message -> failwith message in
      let receipt = Filename.concat local (label ^ "-inventory") in
      Out_channel.with_open_bin receipt (fun channel -> output_string channel (Source_inventory.canonical inventory));
      Unix.chmod receipt 0o600;
      path, receipt, commit, Source_inventory.identity inventory in
    let source, source_receipt, source_commit, source_sha = snapshot checkout revision "source" in
    let repository, repo_receipt, repo_commit, repo_sha = snapshot repository_checkout repository_revision "repository" in
    (match Unix.lstat (Filename.concat repository "repo") with
     | {Unix.st_kind=Unix.S_REG; _} -> ()
     | _ -> failwith "artifact build: invalid opam repository marker"
     | exception Unix.Unix_error _ -> failwith "artifact build: missing opam repository marker");
    Progress.phase "recipe";
    let recipe_dir = Filename.concat local "recipe" in
    let recipe = match Artifact_recipe.stage_guest ~lib_dir:(Layout.lib_dir env.layout) ~out:recipe_dir
      ~project:workload.project ~target:workload.target ~release_name:workload.release
      ~compiler ~repository_commit:repo_commit ~repository_sha256:repo_sha with
      | Ok value -> value | Error message -> failwith message in
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
    let retain_remote = ref false in
    let ssh command = ssh_checked env (guest_connection env guest @ [command]) in
    let transfer src dst =
      retain_remote := true;
      rsync_checked env ["-az"; "--no-owner"; "--no-group"; "-e"; shell; "--"; src; dst];
      retain_remote := false in
    ignore (acquire_lock env ~command:("artifact build " ^ name) (Guest guest));
    Fun.protect ~finally:(fun () ->
      if !retain_remote then begin
        Progress.outcome_unknown ();
        Printf.eprintf "artifact build: %s stage %s and guest lock retained; inspect before serai unlock %s.\n%!"
          name stage name
      end else release_lock env (Guest guest)) (fun () ->
      retain_remote := true;
      ssh (secure_remote_stage_script ~stage:env.remote_stage ~subtree);
      retain_remote := false;
      let cleanup () = if not !retain_remote then begin
        Progress.phase "cleanup";
        retain_remote := true;
        ssh ("set -eu\n# artifact-guest-cleanup:\nstage=" ^ Shell.quote stage
          ^ "\n[ -d \"$stage\" ] && [ ! -L \"$stage\" ]\nrm -rf -- \"$stage\"\n[ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]");
        retain_remote := false
      end in
      let build () =
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
        retain_remote := true;
        ssh (String.concat "\n" (["set -eu"] @ checks @
          ["exec sh " ^ String.concat " " (List.map Shell.quote args)]));
        retain_remote := false;
        Progress.phase "transfer";
        List.iter (fun file -> transfer (remote ("output/" ^ file)) (Filename.concat output file))
          ["release.tar"; "release.sha256"; "target-abi"; "dependencies"] in
      match build () with
      | () -> cleanup ()
      | exception primary ->
          let backtrace = Printexc.get_raw_backtrace () in
          (match cleanup () with
           | () -> Printexc.raise_with_backtrace primary backtrace
           | exception secondary -> Printexc.raise_with_backtrace (Proc.Cleanup_failed (primary, secondary)) backtrace));
    Progress.phase "verify";
    let read file limit =
      let path = Filename.concat output file in
      if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then failwith "artifact build: unsafe guest evidence";
      In_channel.with_open_bin path (fun channel ->
        if in_channel_length channel > limit then failwith "artifact build: oversized guest receipt";
        In_channel.input_all channel) in
    let archive = Filename.concat output "release.tar" in
    if (Unix.lstat archive).Unix.st_kind <> Unix.S_REG then failwith "artifact build: unsafe guest archive";
    let archive_sha256 = artifact_file_sha256 archive in
    if read "release.sha256" 65 <> archive_sha256 ^ "\n" then failwith "artifact build: guest archive checksum mismatch";
    let target_abi = match String.split_on_char '\n' (read "target-abi" 129) with
      | [value; ""] -> value | _ -> failwith "artifact build: invalid Linux ABI receipt" in
    artifact_guest_abi target_abi;
    let dependencies = match Artifact_manifest.dependencies_of_inventory (read "dependencies" 1048576) with
      | Ok value -> value | Error message -> failwith message in
    (match dependencies with
     | [{Artifact_manifest.name="opam-repository"; version; sha256}]
       when String.equal version repo_commit && String.equal sha256 repo_sha -> ()
     | _ -> failwith "artifact build: guest repository receipt mismatch");
    let manifest = match Artifact_manifest.create ~name ~source_commit ~target_abi ~dependencies
      ~recipe_sha256:recipe.sha256 ~release_name:workload.release ~archive_sha256 with
      | Ok value -> value | Error message -> failwith message in
    Progress.phase "publish";
    match Artifact_store.publish ~root:store ~manifest ~archive with
    | Ok _ -> Artifact_manifest.identity manifest | Error message -> failwith message)

let artifact_apply_guest ?(convert=false) env name ~store ~identity ~rollback =
  Progress.phase "verify";
  if convert && rollback then failwith "artifact apply: invalid guest operation";
  let guest = find_guest env name in
  let workload = guest_workload "artifact apply" guest in
  let manifest, archive = match Artifact_store.load ~root:store ~identity with
    | Ok value -> value | Error message -> failwith message in
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
  Fun.protect ~finally:(fun () -> artifact_remove_tree local) (fun () ->
    let scripts = List.map (fun name ->
      let path = Layout.lib_file env.layout name in
      if (Unix.lstat path).Unix.st_kind <> Unix.S_REG then failwith "artifact apply: unsafe guest helper";
      let snapshot = Filename.concat local name in
      In_channel.with_open_bin path (fun input ->
        if (Unix.fstat (Unix.descr_of_in_channel input)).Unix.st_kind <> Unix.S_REG then failwith "artifact apply: unsafe guest helper";
        Out_channel.with_open_bin snapshot (fun output -> output_string output (In_channel.input_all input)));
      Unix.chmod snapshot 0o600;
      name, snapshot, artifact_file_sha256 snapshot)
      (["artifact_install_guest.sh"; "artifact_activate_guest.sh"; "artifact_check_health.sh"]
       @ if convert then ["artifact_convert_binary.sh"; "artifact_service_guest.sh"] else []) in
    let subtree = "artifact-apply/" ^ name ^ "/" ^ identity in
    let stage = env.remote_stage ^ "/" ^ subtree in
    let shell = String.concat " " ((env.ssh_bin :: guest_ssh_options env) @ guest_jump_options env guest) in
    let ssh command = ssh_checked env (guest_connection env guest @ [command]) in
    let retain_remote = ref false in
    ignore (acquire_lock env ~command:("artifact apply " ^ name) (Guest guest));
    Fun.protect ~finally:(fun () ->
      if !retain_remote then begin
        Progress.outcome_unknown ();
        Printf.eprintf "artifact apply: %s stage %s and guest lock retained; inspect before serai unlock %s.\n%!"
          name stage name
      end else release_lock env (Guest guest)) (fun () ->
      retain_remote := true;
      ssh (secure_remote_stage_script ~stage:env.remote_stage ~subtree);
      retain_remote := false;
      let cleanup () = if not !retain_remote then begin
        Progress.phase "cleanup";
        retain_remote := true;
        ssh ("set -eu\nstage=" ^ Shell.quote stage
          ^ "\n[ -d \"$stage\" ] && [ ! -L \"$stage\" ]\nrm -rf -- \"$stage\"\n[ ! -e \"$stage\" ] && [ ! -L \"$stage\" ]");
        retain_remote := false
      end in
      let apply () =
        Progress.phase "transfer";
        let transfer source name =
          retain_remote := true;
          rsync_checked env ["-az"; "--no-owner"; "--no-group"; "-e"; shell; "--"; source;
            guest_target guest ^ ":" ^ stage ^ "/" ^ name];
          retain_remote := false in
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
        retain_remote := true;
        let code = ssh_run env (("-t" :: guest_connection env guest) @ ["su -c " ^ Shell.quote command]) in
        retain_remote := code >= 128;
        if code <> 0 then failwith (Printf.sprintf "artifact apply %s: remote exited %d" name code) in
      match apply () with
      | () -> cleanup ()
      | exception primary ->
          let backtrace = Printexc.get_raw_backtrace () in
          (match cleanup () with
           | () -> Printexc.raise_with_backtrace primary backtrace
           | exception secondary -> Printexc.raise_with_backtrace (Proc.Cleanup_failed (primary, secondary)) backtrace)))

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

let is_guest env name = List.exists (fun guest -> Guest_config.name guest = name) env.guests

(* serai deploy <name>: a guest's lifecycle, or an app's deploy hook. A
   loaded declaration already refuses a name used twice; checked again here
   so the choice never depends on lookup order. *)
let deploy_app_or_guest env name =
  match (App_config.find env.config name, is_guest env name) with
  | Some _, true -> failwith (Printf.sprintf "deploy: %s is both an app and a guest" name)
  | None, true -> deploy_guest env name
  | _, false -> deploy env name

(* rollout itself now lives as data in pipelines.sexp -- see Pipeline.run --
   rather than as hardcoded OCaml, so "deploy-or-bootstrap, optionally edge,
   then check" is expressed the same way an app-specific extra step would
   be, instead of being a special case only the compiler can extend. *)
