(* Central logging's senders on the compute and edge hosts. Part of
   Dispatcher. *)
open Remote_host
open Edge_apply

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
  Run_state.changing ();
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
      Run_state.changing ();
      ssh_checked env
        [ env.edge_target; Printf.sprintf "sudo bash %s/edge/%s%s" env.remote_stage script (logging_action_arg action) ])
