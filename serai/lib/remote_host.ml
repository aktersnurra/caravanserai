(* Reaching a host: the run's environment, ssh routing, the host locks and
   the guarded remote stage. Dispatcher's interface is the public one; this
   and the modules it includes are its parts. *)

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

let ok_or_fail = function Ok value -> value | Error message -> failwith message

let is_sha256 = Hex.is_sha256
let remove_tree = Fs.remove_tree

let write_private path contents =
  Out_channel.with_open_bin path (fun channel -> output_string channel contents);
  Unix.chmod path 0o600

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
        (* Age is all the host knows: nothing refreshes a lock, and a build
           can outlast the threshold. So the holder is to be checked first. *)
        (Printf.sprintf
           "%s has been locked for over %d min (holder above). A long build can hold it that long: check on \
            the holder's machine that its serai (the pid named) has ended, and only then: serai unlock %s"
           label (Remote_lock.stale_after_seconds / 60) label)
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

(* A remote operation that may end with its outcome unknown: an interrupted
   transfer may leave a writer, a lost connection a running build. While
   [uncertain] is set, an error leaves the stage and the lock in place for
   inspection; otherwise the stage is removed and the lock released. *)
type retention = { mutable uncertain : bool }

(* [f]'s outcome is unknown until it returns: an exception leaves it so. *)
let uncertain_while retention f =
  retention.uncertain <- true;
  let value = f () in
  retention.uncertain <- false;
  value

(* Takes [host]'s lock, runs [prepare] (the staging guard: a failure there
   leaves no stage to remove), then [body], then [cleanup] whether [body]
   returned or raised -- unless the outcome is uncertain, when the stage and
   lock stay and [retained] says so. A cleanup that fails is uncertain too,
   and both errors are kept. *)
let with_retained_stage env ~command ~host ~retained ?(prepare = fun _ -> ()) ~cleanup body =
  let retention = { uncertain = false } in
  ignore (acquire_lock env ~command host);
  Fun.protect
    ~finally:(fun () ->
      if retention.uncertain then begin
        Progress.outcome_unknown ();
        Printf.eprintf "%s\n%!" retained
      end else release_lock env host)
    (fun () ->
      prepare retention;
      let cleanup () =
        if not retention.uncertain then begin
          Progress.phase "cleanup";
          uncertain_while retention cleanup
        end in
      match body retention with
      | value -> cleanup (); value
      | exception primary -> Proc.reraise_after_cleanup primary cleanup)

(* Removes a stage directory, refusing one that is missing or a symlink. *)
let remove_stage_script ?marker stage =
  String.concat "\n"
    ([ "set -eu" ] @ (match marker with Some marker -> [ "# " ^ marker ^ ":" ] | None -> [])
     @ [ "stage=" ^ Shell.quote stage;
         {|[ -d "$stage" ] && [ ! -L "$stage" ]|};
         {|rm -rf -- "$stage"|};
         {|[ ! -e "$stage" ] && [ ! -L "$stage" ]|} ])

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
