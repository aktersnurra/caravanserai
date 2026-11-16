(* Status against the process mock: locks and apps read, nothing changed. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
let mentions needle (r : Proc.request) = List.exists (contains needle) (r.prog :: r.args)

let () =
  let layout = Repo_root.example () in
  let endpoint = Test_declaration.endpoint ~name:"drill" ~ip:"10.40.0.2" ~hostname:"drill.example.org"
      ~tailnet_ports:[ { Network_endpoint.port_name = "http"; port = 4000 } ] ~operator_ports:[] in
  let env : Dispatcher.env = {
    layout; topology = Some (Test_declaration.topology ~jails:[ "drill" ] ~guests:[] ());
    compute_target = "compute-test"; edge_target = "edge-test"; remote_stage = "/tmp/serai-status-test";
    ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl";
    config = [ Test_declaration.app ~endpoint ~hooks:[] ];
    endpoints = Test_declaration.endpoints [ endpoint ]; edge = Test_declaration.edge "example.org";
    edge_ts_ip = None; edge_peer_match = None; caddy_force_build = false; confirm = (fun _ -> false);
    operator = "ops@here"; lock_token = "status-test"; jj_bin = "jj";
    now_utc = (fun () -> "2026-11-15T00:00:00Z"); guests = [];
    ops_control_path = "/tmp/test-%C"; ssh_multiplex = false; source_checkout_override = None } in
  let run ?(exit_codes = fun _ -> 0) outputs f =
    let mock = Proc.Mock.create ~exit_codes ~outputs () in
    let result = Proc.Mock.run mock f in
    result, Proc.Mock.calls mock in

  check "lock probe: no answer is a free lock" (Remote_lock.inspect "" = Ok None);
  check "lock probe: holder and age, stale past the threshold"
    (Remote_lock.inspect "lock-holder: a@b: serai edge (pid 7)\nlock-age: 1900\n"
     = Ok (Some { holder = "a@b: serai edge (pid 7)"; age_seconds = 1900; stale = true }));
  check "lock probe: half an answer is refused" (Result.is_error (Remote_lock.inspect "lock-age: 3\n"));

  let own = Printf.sprintf "ops@here: serai edge (pid %d)" (Unix.getpid ()) in
  let locks, calls = run (fun r ->
      if mentions "compute-test" r then Printf.sprintf "lock-holder: %s\nlock-age: 12\n" own else "")
      (fun () -> Status.locks env) in
  check "locks: every configured host is read, one connection each"
    (List.map (fun (l : Status.lock) -> l.host) locks = [ "compute"; "edge" ] && List.length calls = 2);
  check "locks: a held lock names its holder, and a holder on this machine is known to be alive"
    (List.exists (fun (l : Status.lock) -> match l.lock with
       | Held { holder; age_seconds = 12; stale = false; holder_alive = Some true } -> holder = own
       | _ -> false) locks);
  check "locks: the other host's is free" (List.exists (fun (l : Status.lock) -> l.lock = Status.Free) locks);
  check "locks: nothing takes or removes a lock"
    (not (List.exists (fun r -> mentions "mkdir" r || mentions "rm -rf" r) calls));
  let locks, _ = run ~exit_codes:(fun _ -> 255) (fun _ -> "") (fun () -> Status.locks ~only:"edge" env) in
  check "locks: an unreachable host is unavailable, not free"
    (match locks with [ { host = "edge"; lock = Lock_unavailable _ } ] -> true | _ -> false);
  check "locks: another operator's holder has unknown liveness"
    ((fst (run (fun _ -> "lock-holder: eve@there: serai up (pid 1)\nlock-age: 5\n")
             (fun () -> Status.locks ~only:"compute" env)))
     |> List.for_all (fun (l : Status.lock) -> match l.lock with
          | Held { holder_alive = None; _ } -> true | _ -> false));

  let active = String.make 64 'a' and commit = String.make 40 'c' in
  let probe = Printf.sprintf
      "jail-probe-root: present\njail-probe-running: drill 10.40.0.2\njail-test-env: root:drill:640\n\
       release-probe-active: .infra-releases/drill/%s\nrelease-probe-source: %s\nrelease-probe-previous: none\n" active commit in
  let apps, calls = run (fun _ -> probe) (fun () -> Status.apps env) in
  check "status: one read-only connection per app" (List.length calls = 1);
  (match apps with
   | [ { app = "drill"; host = "compute"; state = Live { releases = Some r; _ }; _ } ] ->
       check "status: the active release and its source commit" (r.active = Some active && r.source = Some commit)
   | _ -> check "status: drill is read" false);
  let apps, _ = run (fun _ -> "jail-probe-root: absent\n") (fun () -> Status.apps ~only:"drill" env) in
  check "status: an app without a jail says so"
    (match apps with [ { state = Live { jail = Jail_absent; releases = None }; _ } ] -> true | _ -> false);
  let apps, _ = run ~exit_codes:(fun _ -> 255) (fun _ -> "") (fun () -> Status.apps env) in
  check "status: an unreachable host makes the app unavailable"
    (match apps with [ { state = App_unavailable _; _ } ] -> true | _ -> false)
