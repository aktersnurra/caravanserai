open Remote_host

type lock_state =
  | Free
  | Held of { holder : string; age_seconds : int; stale : bool; holder_alive : bool option }
  | Lock_unavailable of string

type lock = { host : string; lock : lock_state }

(* A holder is "user@machine: serai <command> (pid N)". When that machine
   is this one, the pid says whether its run is still going. *)
let holder_alive ~operator holder =
  if not (String.starts_with ~prefix:(operator ^ ": ") holder) then None
  else
    match String.rindex_opt holder '(' with
    | None -> None
    | Some start ->
        (match Scanf.sscanf_opt (String.sub holder start (String.length holder - start)) "(pid %d)" Fun.id with
         | None -> None
         | Some pid ->
             (match Unix.kill pid 0 with
              | () -> Some true
              | exception Unix.Unix_error (Unix.ESRCH, _, _) -> Some false
              | exception Unix.Unix_error _ -> Some true))

let lock_hosts env = match env.topology with
  | Some topology -> List.map (fun host -> Host host) (Topology.hosts topology)
  | None -> [ Compute_host; Edge_host ]

let lock_of env host =
  let state =
    match ssh_capture env ([ "-o"; "ConnectTimeout=10" ] @ host_connection env host
                           @ [ Remote_lock.inspect_script ~stage:env.remote_stage ]) with
    | 0, output ->
        (match Remote_lock.inspect output with
         | Ok None -> Free
         | Ok (Some { holder; age_seconds; stale }) ->
             Held { holder; age_seconds; stale; holder_alive = holder_alive ~operator:env.operator holder }
         | Error message -> Lock_unavailable message)
    | code, _ -> Lock_unavailable (Printf.sprintf "could not read the lock (ssh exit %d)" code) in
  { host = host_label env host; lock = state }

let locks ?only env =
  Progress.phase "inspect";
  match only with
  | None -> List.map (lock_of env) (lock_hosts env)
  | Some label ->
      (match host_of_label env label with
       | Some host -> [ lock_of env host ]
       | None -> Run_state.fail ~cause:"invalid_argument" "locks: expected a configured host ID or guest name")

type jail = Jail_absent | Jail_ready | Jail_needs_env of string

type app_state =
  | Live of { jail : jail; releases : Release_probe.t option }
  | App_unavailable of string

type app = { app : string; host : string; ip : string; state : app_state }

(* One connection per app: the jail probe and the release probe together,
   both read-only. *)
let app_status env (app : App_config.t) =
  let name = app.endpoint.name in
  let env = app_env env name in
  let script = Printf.sprintf "( %s\n) || true\n( %s\n) || true"
      (Jail_probe.script ~app:name) (Release_probe.script ~app:name) in
  let state =
    match ssh_capture env [ "-o"; "ConnectTimeout=10"; env.compute_target; "doas sh -c " ^ Shell.quote script ] with
    | 0, output ->
        (match Jail_probe.check ~app:name ~ip:app.endpoint.ip output with
         | Error message -> App_unavailable message
         | Ok Jail_probe.Absent -> Live { jail = Jail_absent; releases = None }
         | Ok (Jail_probe.Present env_file) ->
             let jail = match env_file with Ok () -> Jail_ready | Error message -> Jail_needs_env message in
             Live { jail; releases = Result.to_option (Release_probe.check ~app:name output) })
    | code, _ -> App_unavailable (Printf.sprintf "could not probe the host (ssh exit %d)" code) in
  { app = name; host = host_label env Compute_host; ip = app.endpoint.ip; state }

let apps ?only env =
  Progress.phase "inspect";
  match only with
  | Some name -> [ app_status env (find_app env name) ]
  | None -> List.map (app_status env) env.config

let optional = function Some value -> Json.String value | None -> Json.Null

let lock_json { host; lock } =
  Json.Object (("host", Json.String host) :: (match lock with
    | Free -> [ "state", Json.String "free" ]
    | Held { holder; age_seconds; stale; holder_alive } ->
        [ "state", Json.String "held"; "holder", Json.String holder; "age_seconds", Json.of_int age_seconds;
          "stale", Json.Bool stale;
          "holder_alive", (match holder_alive with Some alive -> Json.Bool alive | None -> Json.Null) ]
    | Lock_unavailable message -> [ "state", Json.String "unavailable"; "message", Json.String message ]))

let app_json { app; host; ip; state } =
  Json.Object ([ "app", Json.String app; "host", Json.String host; "ip", Json.String ip ] @ (match state with
    | App_unavailable message -> [ "state", Json.String "unavailable"; "message", Json.String message ]
    | Live { jail; releases } ->
        [ "state", Json.String "checked";
          "jail", Json.Object (match jail with
            | Jail_absent -> [ "state", Json.String "absent" ]
            | Jail_ready -> [ "state", Json.String "ready" ]
            | Jail_needs_env message -> [ "state", Json.String "needs_env"; "message", Json.String message ]);
          "release", (match releases with
            | None -> Json.Null
            | Some { active; source; previous } ->
                Json.Object [ "active", optional active; "source_commit", optional source;
                              "previous", optional previous ]) ]))

let lock_line { host; lock } = match lock with
  | Free -> Printf.sprintf "%s: free" host
  | Held { holder; age_seconds; stale; holder_alive } ->
      Printf.sprintf "%s: held for %ds by %s%s%s" host age_seconds holder
        (match holder_alive with
         | Some true -> " (that run is alive on this machine)"
         | Some false -> " (that run has ended on this machine)"
         | None -> "")
        (if stale then "; older than the stale threshold" else "")
  | Lock_unavailable message -> Printf.sprintf "%s: unavailable: %s" host message

let app_line { app; host; state; _ } = match state with
  | App_unavailable message -> Printf.sprintf "%s on %s: unavailable: %s" app host message
  | Live { jail = Jail_absent; _ } -> Printf.sprintf "%s on %s: no jail" app host
  | Live { jail; releases } ->
      let field name = function Some value -> Printf.sprintf " %s %s" name (Hex.short value) | None -> "" in
      Printf.sprintf "%s on %s:%s%s" app host
        (match jail with Jail_needs_env message -> " needs its env (" ^ message ^ ");" | _ -> "")
        (match releases with
         | None -> " no release record"
         | Some { active = None; _ } -> " no active release"
         | Some { active; source; previous } ->
             field "active" active ^ field "from" source ^ field "previous" previous)
