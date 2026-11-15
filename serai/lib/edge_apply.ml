(* The edge: rendering, staging, planning and installing pf rules, the
   Headscale policy and Caddy's tree. Part of Dispatcher. *)
open Remote_host

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
            raise (Plan_id.Stale (Printf.sprintf
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
