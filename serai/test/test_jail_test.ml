(* Jail_test: the test-jail name and ip rules, the namespace audit of every
   app's retargeted script against its real host-side names, and the
   destroy script -- refused in OCaml, refused again inside the sh, and run
   locally with sh against a temp jail.conf and jails dir, with fake
   service, jls, sysrc, zfs, chflags, mount and rm first on PATH. Nothing here
   touches a real host. *)
open Serai

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let example_app name =
  App_config.load (Filename.concat (Layout.app_dir (Repo_root.example ()) name) "app.sexp")

let declared text = App_config.of_sexp (Sexplib.Sexp.of_string text)

(* One app per strategy jail-test retargets: the example's Phoenix and OCaml
   apps, and inline the package and binary strategies it does not use. *)
let real_apps =
  [ example_app "hello"; example_app "counter";
    declared {|((name store) (ip 10.20.0.4) (hostname store.example.org) (tailnet_ports ((s3 3900)))
                (operator_ports ()) (strategy freebsd_package) (hooks (bootstrap check)) (extra_steps ())
                (strategy_config ((packages (garage)) (check_path /))))|};
    declared {|((name idp) (ip 10.20.0.5) (hostname id.example.org) (tailnet_ports ((http 1411)))
                (operator_ports ()) (strategy fetch_binary) (hooks (bootstrap check)) (extra_steps ())
                (strategy_config ((version v2.16.0)
                  (binary_sha256 942e6ceff2a87f12011a776551758245889250ffa5039034f130347921d9940b)
                  (binary_url_template https://example.org/releases/${VERSION}/idp_freebsd_amd64)
                  (binary_name idp) (port 1411)
                  (env_values ((APP_URL https://id.example.org))) (data_dir /var/db/idp)
                  (packages (sqlite3)) (env_template_path env.template)
                  (rc_template_path idp.rc.template) (check_path /))))|} ]
let declared_names = List.map (fun (a : App_config.t) -> a.endpoint.name) real_apps
let declared_ips = List.map (fun (a : App_config.t) -> a.endpoint.ip) real_apps

(* ---------------------------------------------------------------------- *)
(* Name and ip rules                                                       *)
(* ---------------------------------------------------------------------- *)

let () =
  check "name: <app>test" (Jail_test.name (example_app "counter") = "countertest");
  List.iter
    (fun (a : App_config.t) ->
      let name = Jail_test.name a in
      check (Printf.sprintf "name: %s passes the name rules" name)
        (Jail_test.validate_name ~declared:declared_names name = Ok ()
        && Network_endpoint.is_placeholder_safe name
        && (try Dispatcher.validate_app_name name; true with Failure _ -> false)))
    real_apps;
  check "name: a declared endpoint's name is refused"
    (Result.is_error (Jail_test.validate_name ~declared:("mealstest" :: declared_names) "mealstest"));
  check "name: a name with a hyphen is refused (not placeholder-safe)"
    (Result.is_error (Jail_test.validate_name ~declared:[] "my-apptest"));
  check "name: a name not ending in test is refused"
    (Result.is_error (Jail_test.validate_name ~declared:[] "meals"));
  check "name: test alone is refused" (Result.is_error (Jail_test.validate_name ~declared:[] "test"))

(* The example's worker host, and one on another network: the rules come
   from the host's declared network, not from a built-in subnet. *)
let compute =
  let d = Result.get_ok (Declaration.load ~layout:(Repo_root.example ())) in
  Topology.host (Option.get d.topology) "worker"
let other = Topology.host (Topology.of_sexp (Sexplib.Sexp.of_string
  {|((hosts ((west (os freebsd) (ssh west) (network (subnet 10.8.0.0/16) (gateway 10.8.0.1)))
             (edge (os linux) (ssh edge))))
     (jails ((web west))) (guests ()) (edge edge) (proxy ()))|})) "west"

let () =
  let ok ip = Jail_test.validate_ip ~host:compute ~declared:declared_ips ip = Ok () in
  check "ip: 10.20.0.250 is accepted" (ok "10.20.0.250");
  check "ip: 10.20.0.2 is accepted when undeclared"
    (Jail_test.validate_ip ~host:compute ~declared:[] "10.20.0.2" = Ok ());
  check "ip: another host's network decides"
    (Jail_test.validate_ip ~host:other ~declared:[] "10.8.3.4" = Ok ()
     && Result.is_error (Jail_test.validate_ip ~host:other ~declared:[] "10.20.0.250")
     && Result.is_error (Jail_test.validate_ip ~host:other ~declared:[] "10.8.0.1"));
  List.iter
    (fun ip -> check ("ip: refused " ^ ip) (not (ok ip)))
    [
      "10.20.0.1"; "10.20.0.254"; "10.20.0.0"; "10.20.0.255"; "10.20.0.256";
      "10.20.1.20"; "10.0.0.20"; "10.20.0."; "10.20.0.020"; "10.20.0.2x";
      "10.20.0.-5"; "10.20.0.1000"; "x10.20.0.20"; "";
    ];
  List.iter (fun ip -> check ("ip: a declared endpoint's ip is refused: " ^ ip) (not (ok ip))) declared_ips

(* ---------------------------------------------------------------------- *)
(* Namespace audit: the retargeted script names no real host resource     *)
(* ---------------------------------------------------------------------- *)

let replace_all ~sub ~by s =
  let sl = String.length sub in
  let b = Buffer.create (String.length s) in
  let rec go i =
    if i > String.length s - sl then Buffer.add_string b (String.sub s i (String.length s - i))
    else if String.sub s i sl = sub then (Buffer.add_string b by; go (i + sl))
    else (Buffer.add_char b s.[i]; go (i + 1))
  in
  go 0;
  Buffer.contents b

(* The script's JAIL, APP and JROOT spelled out, so each host-side name
   appears literally. *)
let expand ~jail ~app script =
  script
  |> replace_all ~sub:{|JROOT="/jails/${JAIL}"|} ~by:("JROOT=/jails/" ^ jail)
  |> replace_all ~sub:"${JROOT}" ~by:("/jails/" ^ jail)
  |> replace_all ~sub:"\"$JROOT\"" ~by:("\"/jails/" ^ jail ^ "\"")
  |> replace_all ~sub:"${JAIL}" ~by:jail
  |> replace_all ~sub:"\"$JAIL\"" ~by:("\"" ^ jail ^ "\"")
  |> replace_all ~sub:"${APP}" ~by:app
  |> replace_all ~sub:"\"$APP\"" ~by:("\"" ^ app ^ "\"")

let is_name_char c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '.' || c = '_' || c = '-'

(* [needle] as a whole token: the character after it cannot extend it, so
   /jails/meals does not match /jails/mealstest, nor 10.40.0.2 10.40.0.200. *)
let names ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    i + nl <= hl
    && ((String.sub haystack i nl = needle && (i + nl = hl || not (is_name_char haystack.[i + nl])))
       || go (i + 1))
  in
  go 0

let test_ip = "10.40.0.200"

let () =
  List.iter
    (fun (app : App_config.t) ->
      let real = app.endpoint.name in
      let test = Jail_test.name app in
      let script =
        match Jail_test.render app ~ip:test_ip with
        | Ok script -> script
        | Error errors -> failwith (Network_endpoint.errors_message errors)
      in
      let expanded = expand ~jail:test ~app:real script in
      let label s = Printf.sprintf "audit %s as %s: %s" real test s in
      check (label "the test jail's root, block and jail_list entry are named")
        (names ~needle:("/jails/" ^ test) expanded
        && List.mem (test ^ " {") (String.split_on_char '\n' expanded)
        && contains ~needle:(Printf.sprintf {|jail_list+=" %s"|} test) expanded);
      check (label "the test ip is the jail's ip")
        (List.mem ("JAIL_IP=" ^ test_ip) (String.split_on_char '\n' script));
      List.iter
        (fun (what, needle) -> check (label ("never names " ^ what)) (not (names ~needle expanded)))
        [
          ("the real jail root", "/jails/" ^ real);
          ("the real jail.conf block", "\n" ^ real ^ " {");
          ("the real jail_list entry", {|jail_list+=" |} ^ real);
          ("the real jail as a jexec target", Printf.sprintf {|jexec "%s"|} real);
          ("the real jail as a service jail target", Printf.sprintf {|service jail start "%s"|} real);
          ("the real jail's ip", app.endpoint.ip);
        ];
      check (label "never names the real jail in a jail.conf path")
        (not (contains ~needle:(Printf.sprintf "path          = /jails/%s;" real) expanded));
      match app.strategy with
      | Strategy_config.Freebsd_native_ocaml s ->
          check (label "the dataset is the test one") (Jail_test.dataset app = Some (s.zfs_dataset ^ "test"));
          check (label "never names the real dataset") (not (names ~needle:s.zfs_dataset script));
          check (label "names the test dataset") (names ~needle:(s.zfs_dataset ^ "test") script)
      | Strategy_config.Freebsd_package_service _ ->
          check (label "package service refuses unsafe test retargeting") false
      | Strategy_config.(Freebsd_native_elixir _ | Freebsd_package _ | Fetch_binary _) ->
          check (label "no dataset") (Jail_test.dataset app = None))
    real_apps

let () =
  let logs = example_app "logs" in
  check "logs: test jail refuses service args containing live listener IPs"
    (match Jail_test.render logs ~ip:test_ip with
    | Error errors -> contains ~needle:"live listener addresses" (Network_endpoint.errors_message errors)
    | Ok _ -> false);
  check "logs: namespaced dataset is only the test dataset"
    (Jail_test.dataset logs = Some "zroot/logstest")

(* The only change retarget makes to the app is its ip: retargeting back
   to the real ip gives the real app. *)
let () =
  let counter = example_app "counter" in
  check "retarget: only the ip changes"
    (match Jail_test.retarget counter ~ip:test_ip with
    | Error _ -> false
    | Ok retargeted -> (
        retargeted.endpoint.ip = test_ip
        &&
        match Jail_test.retarget retargeted ~ip:counter.endpoint.ip with
        | Ok back -> back = counter
        | Error _ -> false))

(* retarget goes through Network_endpoint.create: an ip that is not a
   canonical IPv4 host address never reaches a script. *)
let () =
  let counter = example_app "counter" in
  List.iter
    (fun ip ->
      check ("retarget: refuses " ^ String.escaped ip)
        (match Jail_test.render counter ~ip with
        | Error [ Network_endpoint.Invalid_ip (name, bad) ] -> name = "counter" && bad = ip
        | Error _ | Ok _ -> false))
    [ ""; "10.40.0"; "10.40.0.020"; "10.40.0.2x"; "10.40.0.200/32"; "10.40.0.200\nset -x" ]

(* ---------------------------------------------------------------------- *)
(* Destroy: refusals in OCaml                                             *)
(* ---------------------------------------------------------------------- *)

let refused f = match f () with _ -> false | exception Invalid_argument _ -> true

(* Jail_test.destroy_script takes only a target validate_destroy_target
   built; a refused target is Invalid_argument here, as it was when
   destroy_script validated its own arguments. *)
let destroy_script ~name ?dataset () =
  match Jail_test.validate_destroy_target ~name ?dataset () with
  | Ok target -> Jail_test.destroy_script target
  | Error msg -> invalid_arg msg

let () =
  check "destroy: a real jail name is refused" (refused (fun () -> destroy_script ~name:"meals" ()));
  check "destroy: a name with a hyphen is refused"
    (refused (fun () -> destroy_script ~name:"my-apptest" ()));
  check "destroy: test alone is refused" (refused (fun () -> destroy_script ~name:"test" ()));
  check "destroy: a quote in the name is refused"
    (refused (fun () -> destroy_script ~name:"x'test" ()));
  check "destroy: a real dataset is refused"
    (refused (fun () -> destroy_script ~name:"mealstest" ~dataset:"zroot/meals" ()));
  check "destroy: a test name and a test dataset render"
    (not (refused (fun () -> destroy_script ~name:"mealstest" ~dataset:"zroot/mealstest" ())))

(* ---------------------------------------------------------------------- *)
(* Destroy: the script, run locally                                        *)
(* ---------------------------------------------------------------------- *)

let read_file path = In_channel.with_open_bin path In_channel.input_all
let write_file path contents = Out_channel.with_open_bin path (fun oc -> output_string oc contents)

let rec remove_tree path =
  if Sys.is_directory path then begin
    Array.iter (fun e -> remove_tree (Filename.concat path e)) (Sys.readdir path);
    Sys.rmdir path
  end
  else Sys.remove path

let fake name body ~bin =
  let path = Filename.concat bin name in
  write_file path ("#!/bin/sh\n" ^ body ^ "\n");
  Unix.chmod path 0o755

let block name ip =
  Printf.sprintf
    "\n%s {\n    path          = /jails/%s;\n    ip4.addr      = lo1|%s/32;\n    mount.devfs;\n}\n" name name ip

let jail_conf = "# host jails\n" ^ block "meals" "10.40.0.6" ^ block "mealstest" "10.40.0.200" ^ block "drill" "10.40.0.2"

type run = {
  status : int;
  log : string;
  conf : string;
  conf_mode : int;
  dir : string;
  backups : string list;
  strays : string list; (* jail.conf.* left beside it, other than backups *)
  output : string;
}

(* Runs [script] under sh with the fakes first on PATH, JAIL_CONF and
   JAILS_DIR in a fresh temp dir holding [jail_conf] and the jail roots
   /jails/meals and /jails/mealstest. zfs list succeeds for every dataset;
   jls -j fails (the jail is stopped) unless [running]; mount -p prints
   [mounts], with @JAILS@ standing for the temp jails dir, as the log does,
   and @REAL@ for its resolved path. With [symlinked], the jails dir is a
   symlink to real-jails. rm runs the real rm, with -x dropped (GNU rm has
   no -x). Every fake appends its argv to the log. *)
let run_destroy ?(mounts = "") ?(running = false) ?(symlinked = false) ?(conf_text = jail_conf) script =
  let dir = Filename.temp_dir "serai-jail-test" "" in
  let bin = Filename.concat dir "bin" and jails = Filename.concat dir "jails" in
  Sys.mkdir bin 0o755;
  if symlinked then begin
    Sys.mkdir (Filename.concat dir "real-jails") 0o755;
    Unix.symlink "real-jails" jails
  end
  else Sys.mkdir jails 0o755;
  List.iter
    (fun j ->
      Sys.mkdir (Filename.concat jails j) 0o755;
      Sys.mkdir (Filename.concat jails (j ^ "/etc")) 0o755;
      write_file (Filename.concat jails (j ^ "/etc/resolv.conf")) "nameserver 1.1.1.1\n")
    [ "meals"; "mealstest" ];
  let log = Filename.concat dir "calls.log" in
  write_file log "";
  let logging name = Printf.sprintf {|echo "%s $*" >>"$FAKE_LOG"|} name in
  List.iter (fun n -> fake n (logging n) ~bin) [ "service"; "sysrc"; "zfs"; "chflags" ];
  fake "jls" (logging "jls" ^ if running then "\nexit 0" else "\nexit 1") ~bin;
  fake "mount" (logging "mount" ^ {|
printf '%s' "$FAKE_MOUNTS" | sed -e "s#@JAILS@#${JAILS_DIR}#g" -e "s#@REAL@#$(realpath "$JAILS_DIR")#g"|}) ~bin;
  fake "rm" (logging "rm" ^ {|
if [ "$1" = -rfx ]; then shift; exec /bin/rm -rf "$@"; fi
exec /bin/rm "$@"|}) ~bin;
  let conf = Filename.concat dir "jail.conf" in
  write_file conf conf_text;
  Unix.chmod conf 0o644;
  let script_path = Filename.concat dir "destroy.sh" and out = Filename.concat dir "out" in
  write_file script_path script;
  let command =
    Printf.sprintf "env PATH=%s:\"$PATH\" FAKE_LOG=%s FAKE_MOUNTS=%s JAIL_CONF=%s JAILS_DIR=%s sh %s >%s 2>&1"
      (Filename.quote bin) (Filename.quote log) (Filename.quote mounts) (Filename.quote conf)
      (Filename.quote jails) (Filename.quote script_path) (Filename.quote out)
  in
  let status = Sys.command command in
  let siblings =
    Sys.readdir dir |> Array.to_list |> List.filter (fun f -> String.starts_with ~prefix:"jail.conf." f)
  in
  let is_backup f = String.starts_with ~prefix:"jail.conf.before-" f in
  let backups = siblings |> List.filter is_backup |> List.map (fun f -> read_file (Filename.concat dir f)) in
  let result =
    {
      status;
      log = replace_all ~sub:jails ~by:"@JAILS@" (read_file log);
      conf = read_file conf;
      conf_mode = (Unix.stat conf).st_perm;
      dir = String.concat "," (List.sort compare (Array.to_list (Sys.readdir jails)));
      backups;
      strays = List.filter (fun f -> not (is_backup f)) siblings;
      output = read_file out;
    }
  in
  if symlinked then Sys.remove jails;
  remove_tree dir;
  result

let () =
  let r = run_destroy (destroy_script ~name:"mealstest" ~dataset:"zroot/mealstest" ()) in
  check "destroy run: succeeds" (r.status = 0);
  if r.status <> 0 then print_string r.output;
  check "destroy run: only the mealstest block is removed from jail.conf"
    (r.conf = "# host jails\n" ^ block "meals" "10.40.0.6" ^ "\n" ^ block "drill" "10.40.0.2");
  check "destroy run: the backup is the jail.conf before" (r.backups = [ jail_conf ]);
  check "destroy run: jail.conf is replaced atomically, keeping its mode, with no temp file left"
    (r.conf_mode = 0o644 && r.strays = []);
  check "destroy run: only /jails/mealstest is removed" (r.dir = "meals");
  check "destroy run: stop, running check, jail_list, dataset, mount check, chflags -- in that order, on test names only"
    (String.split_on_char '\n' (String.trim r.log)
    = [
        "service jail stop mealstest";
        "jls -j mealstest";
        "sysrc jail_list-=mealstest";
        "zfs list -H -o name zroot/mealstest";
        "zfs destroy -r zroot/mealstest";
        "mount -p";
        "chflags -R noschg @JAILS@/mealstest";
        "rm -rfx @JAILS@/mealstest";
      ])

let () =
  let r = run_destroy (destroy_script ~name:"drilltest" ()) in
  check "destroy run: no dataset -> zfs never called" (r.status = 0 && not (contains ~needle:"zfs" r.log));
  check "destroy run: a jail with no block leaves jail.conf untouched and makes no backup"
    (r.conf = jail_conf && r.backups = [])

(* A jail still running after the stop is refused before anything is
   changed: jail.conf, jail_list, the dataset and the root are all kept. *)
let () =
  let r = run_destroy ~running:true (destroy_script ~name:"mealstest" ~dataset:"zroot/mealstest" ()) in
  check "destroy run: a jail still running -> refuses and changes nothing"
    (r.status <> 0 && r.conf = jail_conf && r.backups = [] && r.dir = "meals,mealstest"
    && contains ~needle:"jail mealstest is still running" r.output
    && String.split_on_char '\n' (String.trim r.log) = [ "service jail stop mealstest"; "jls -j mealstest" ])

(* A jail that failed to stop still has its devfs mounted under the root:
   the root is then left alone rather than removed across the mount. *)
let () =
  let r =
    run_destroy ~mounts:"devfs\t@JAILS@/mealstest/dev\tdevfs\trw\t0 0\n"
      (destroy_script ~name:"mealstest" ())
  in
  check "destroy run: a mount under the root -> refuses, root kept, chflags never run"
    (r.status <> 0 && r.dir = "meals,mealstest" && contains ~needle:"still mounted" r.output
    && not (contains ~needle:"chflags" r.log));
  let r =
    run_destroy ~mounts:"devfs\t@JAILS@/meals/dev\tdevfs\trw\t0 0\n"
      (destroy_script ~name:"mealstest" ())
  in
  check "destroy run: a mount under the real jail's root does not count" (r.status = 0 && r.dir = "meals")

(* The mount guard compares against the resolved root: a jails dir reached
   through a symlink still sees the mount under the real path. *)
let () =
  let r =
    run_destroy ~symlinked:true ~mounts:"devfs\t@REAL@/mealstest/dev\tdevfs\trw\t0 0\n"
      (destroy_script ~name:"mealstest" ())
  in
  check "destroy run: a mount under the resolved root -> refuses, root kept"
    (r.status <> 0 && r.dir = "meals,mealstest" && contains ~needle:"still mounted" r.output
    && not (contains ~needle:"chflags" r.log))

(* A block closed by an indented } is removed up to that line, and no
   further: the blocks after it are kept. *)
let () =
  let indented =
    "\nmealstest {\n    path          = /jails/mealstest;\n    ip4.addr      = lo1|10.40.0.200/32;\n    }\n"
  in
  let before = "# host jails\n" ^ block "meals" "10.40.0.6" ^ indented ^ block "drill" "10.40.0.2" in
  let r = run_destroy ~conf_text:before (destroy_script ~name:"mealstest" ()) in
  check "destroy run: a block closed by an indented } is removed, the next block kept"
    (r.status = 0 && r.conf = "# host jails\n" ^ block "meals" "10.40.0.6" ^ "\n" ^ block "drill" "10.40.0.2")

(* A one-line block cannot be removed line by line: refused before
   anything is touched. *)
let () =
  let one_line =
    "# host jails\n" ^ block "meals" "10.40.0.6"
    ^ "\nmealstest { path = /jails/mealstest; ip4.addr = lo1|10.40.0.200/32; }\n" ^ block "drill" "10.40.0.2"
  in
  let r = run_destroy ~conf_text:one_line (destroy_script ~name:"mealstest" ()) in
  check "destroy run: a one-line block -> refuses, jail.conf untouched, nothing run"
    (r.status <> 0 && r.conf = one_line && r.backups = [] && r.strays = [] && r.log = ""
    && r.dir = "meals,mealstest" && contains ~needle:"one line" r.output)

(* The existing-jail probe jail-test runs over its stage-guard ssh, run
   locally against a temp jail.conf and jails dir. *)
let probe ?(conf_text = jail_conf) ~roots name =
  let dir = Filename.temp_dir "serai-jail-probe" "" in
  let jails = Filename.concat dir "jails" and conf = Filename.concat dir "jail.conf" in
  Sys.mkdir jails 0o755;
  List.iter (fun j -> Sys.mkdir (Filename.concat jails j) 0o755) roots;
  write_file conf conf_text;
  let script = Filename.concat dir "probe.sh" and out = Filename.concat dir "out" in
  write_file script (Jail_test.existing_ip_script ~jail_conf:conf ~jails_dir:jails ~name ());
  let status = Sys.command (Printf.sprintf "sh %s >%s 2>&1" (Filename.quote script) (Filename.quote out)) in
  let output = read_file out in
  remove_tree dir;
  (status, output)

let () =
  check "probe: no root -> absent" (probe ~roots:[] "mealstest" = (0, "jail-test-existing: absent\n"));
  check "probe: a root and its block -> the block's ip"
    (probe ~roots:[ "mealstest" ] "mealstest" = (0, "jail-test-existing: ip 10.40.0.200\n"));
  check "probe: a root with no block of its own -> no ip (meals's block is not mealstest's)"
    (probe ~conf_text:(block "meals" "10.40.0.6") ~roots:[ "mealstest" ] "mealstest"
    = (0, "jail-test-existing: ip \n"));
  check "probe: a root and no jail.conf -> no ip"
    (probe ~conf_text:"" ~roots:[ "mealstest" ] "mealstest" = (0, "jail-test-existing: ip \n"))

let () =
  let check_existing output = Jail_test.check_existing ~app:"meals" ~name:"mealstest" ~ip:"10.40.0.200" output in
  check "existing: absent -> ok" (check_existing "jail-test-existing: absent\n" = Ok Jail_test.Absent);
  check "existing: the same ip -> ok (a re-run)"
    (check_existing "jail-test-existing: ip 10.40.0.200\n" = Ok Jail_test.Same_ip);
  let refused_because needle output =
    match check_existing output with Error msg -> contains ~needle msg | Ok _ -> false
  in
  check "existing: another ip -> refused, naming it and the destroy"
    (refused_because "already exists at 10.40.0.201" "jail-test-existing: ip 10.40.0.201\n"
    && refused_because "serai jail-test meals --destroy" "jail-test-existing: ip 10.40.0.201\n");
  check "existing: a root with no ip -> refused" (refused_because "already exists" "jail-test-existing: ip \n");
  check "existing: no answer -> refused" (refused_because "could not tell" "");
  check "existing: a garbled answer -> refused" (refused_because "could not tell" "jail-test-existing: maybe\n")

(* The sh refuses on its own: a script whose name or dataset was forged past
   the OCaml check touches nothing. *)
let () =
  let forge ~sub ~by = replace_all ~sub ~by (destroy_script ~name:"mealstest" ~dataset:"zroot/mealstest" ()) in
  List.iter
    (fun (what, script) ->
      let r = run_destroy script in
      check ("destroy sh: refuses " ^ what)
        (r.status <> 0 && r.log = "" && r.conf = jail_conf && r.dir = "meals,mealstest"
        && contains ~needle:"refusing" r.output))
    [
      ("the real jail name", forge ~sub:"name='mealstest'" ~by:"name='meals'");
      ("the real dataset", forge ~sub:"dataset='zroot/mealstest'" ~by:"dataset='zroot/meals'");
      ("a name with a slash", forge ~sub:"name='mealstest'" ~by:"name='../etctest'");
      ("an empty name", forge ~sub:"name='mealstest'" ~by:"name=''");
      ("test alone", forge ~sub:"name='mealstest'" ~by:"name='test'");
    ]

(* The env-file probe, run against a fake jexec that answers stat for
   mealstest's /etc/meals/env (or fails, as for a missing file or jail), then
   parsed: only root:meals 0640 passes, and every refusal says how to fix it. *)
let () =
  let dir = Filename.temp_dir "env-probe" "" in
  let jexec = Filename.concat dir "jexec" in
  let probe owner =
    Out_channel.with_open_bin jexec (fun oc ->
        output_string oc
          (match owner with
           | Some owner ->
               "#!/bin/sh\n[ \"$1 $2 $5\" = 'mealstest stat /etc/meals/env' ] && echo '" ^ owner ^ "'\n"
           | None -> "#!/bin/sh\nexit 1\n"));
    Unix.chmod jexec 0o755;
    let input = Unix.open_process_in
        ("PATH=" ^ Filename.quote dir ^ ":$PATH sh -c "
         ^ Filename.quote (Jail_test.env_file_script ~name:"mealstest" ~app:"meals")) in
    let output = In_channel.input_all input in
    ignore (Unix.close_process_in input);
    Jail_test.check_env_file ~app:"meals" ~name:"mealstest" output in
  let refused_with needles = function
    | Error message -> List.for_all (fun needle -> contains ~needle message) needles
    | Ok () -> false in
  check "env probe: root:meals 0640 is in place" (probe (Some "root:meals:640") = Ok ());
  check "env probe: wrong owner or mode is refused with the fix"
    (refused_with [ "root:wheel:600"; "doas jexec mealstest chown root:meals /etc/meals/env";
                    "doas jexec mealstest chmod 0640 /etc/meals/env" ] (probe (Some "root:wheel:600")));
  check "env probe: a missing env says where and from what to write it"
    (refused_with [ "/jails/mealstest/etc/meals/env"; " apps/meals/env.template" ] (probe None));
  check "env probe: an unclear answer is refused"
    (refused_with [ "could not tell" ] (Jail_test.check_env_file ~app:"meals" ~name:"mealstest" ""));
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

let () =
  if !failures > 0 then begin
    Printf.printf "%d assertion(s) failed\n" !failures;
    exit 1
  end
  else print_endline "all assertions passed"
