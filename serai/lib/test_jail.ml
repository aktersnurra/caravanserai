(* The throwaway jail <app>test. Part of Dispatcher. *)
open Remote_host

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
  ok_or_fail
    (Jail_test.validate_name ~declared:(List.map (fun (e : Network_endpoint.t) -> e.name) declared) test_name);
  ok_or_fail (Jail_test.validate_ip ~host:(jail_host env app.endpoint.name)
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
          (approved env ~operation:"jail-test"
             ~facts:[ "jail", test_name; "ip", ip; "host", host_label env Compute_host;
                      "script", Digest.to_hex (Digest.string script) ]
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
  ok_or_fail
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
    ok_or_fail (Jail_test.validate_destroy_target ~name:test_name ?dataset ())
  in
  let script = Jail_test.destroy_script target in
  announce "jail-test %s --destroy" app.endpoint.name;
  with_locks env ~command:("jail-test " ^ app.endpoint.name ^ " --destroy") [ Compute_host ] (fun _records ->
      announce "will destroy jail %s: stop it, remove its jail.conf block and jail_list entry%s, remove /jails/%s"
        test_name
        (match dataset with Some d -> ", zfs destroy -r " ^ d | None -> "")
        test_name;
      if not (approved env ~operation:"jail-test.destroy"
                ~facts:([ "jail", test_name; "host", host_label env Compute_host ]
                        @ match dataset with Some d -> [ "dataset", d ] | None -> [])
                (Printf.sprintf "destroy test jail %s on %s?" test_name (host_label env Compute_host))) then
        failwith "jail-test --destroy: not run";
      announce "destroy %s (compute)" test_name;
      ssh_checked env [ env.compute_target; "doas sh -c " ^ Shell.quote script ])
