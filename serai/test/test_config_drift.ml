(* Config_drift on a fixture declaration: every checked field named when
   its config disagrees, nothing when they agree. *)
open Serai

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let declaration_drift root =
  match Declaration.load ~layout:(Layout.v ~engine:root ~config:root) with
  | Error error -> failwith (Declaration.error_message error)
  | Ok declaration -> List.map Config_drift.message (Config_drift.check declaration)

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)

(* A fixture declaration whose configs disagree in each checked field. *)
let fixture_root () =
  let root = Filename.temp_dir "serai-config-drift" "" in
  List.iter
    (fun dir -> Sys.mkdir (Filename.concat root dir) 0o700)
    [ "apps"; "apps/web"; "apps/store"; "guests"; "guests/vm"; "edge" ];
  write_file (Filename.concat root "serai.sexp")
    "((hosts ((compute (os freebsd)(ssh compute)(network (subnet 10.0.0.0/24) (gateway 10.0.0.1) (guest_bridge 10.0.0.254)))(edge (os linux)(ssh edge))))(jails ((web compute)(store compute)))(guests ((vm (host compute)(via compute))))(edge edge)(proxy (web store vm)))\n";
  write_file (Filename.concat root "edge/edge.sexp") "((base_domain example.org) (operator ops))\n";
  let app name ~ip ~host ~ports =
    write_file
      (Filename.concat root ("apps/" ^ name ^ "/app.sexp"))
      (Printf.sprintf
         "((name %s) (ip %s) (hostname %s) (tailnet_ports (%s)) (operator_ports ())\n\
         \ (strategy freebsd_native_elixir) (hooks (bootstrap)) (extra_steps ())\n\
         \ (strategy_config ((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /))))\n"
         name ip host ports)
  in
  app "web" ~ip:"10.0.0.2" ~host:"web.example.org" ~ports:"(http 4000) (video 4002)";
  app "store" ~ip:"10.0.0.3" ~host:"s3.example.org" ~ports:"(s3 3900)";
  write_file
    (Filename.concat root "guests/vm/guest.sexp")
    "((name vm) (ip 10.0.0.10) (hostname vm.example.org) (tailnet_ports ((http 4010)))\n\
    \ (operator_ports ((ssh 22))) (login_user vm) (source_checkout ../src/vm))\n";
  root

let config root path contents = write_file (Filename.concat root path) contents

let () =
  let root = fixture_root () in
  config root "apps/web/config"
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"web.example.org\"\n";
  config root "apps/store/config"
    "JAIL_IP=\"10.0.0.3\"\nPUBLIC_HOST=\"s3.example.org\"\nS3_PORT=\"3900\"\nPORT=\"${S3_PORT}\"\n";
  config root "guests/vm/config"
    ("GUEST_IP=\"10.0.0.10\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.org\"\n"
    ^ "GUEST_USER=\"vm\"\nSOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../src/vm}\"\n");
  check "fixture: agreeing configs report no drift" (declaration_drift root = []);
  let expect_drift name path contents needle =
    config root path contents;
    let errors = declaration_drift root in
    let found =
      List.exists
        (fun e ->
          let nl = String.length needle and el = String.length e in
          let rec go i = i + nl <= el && (String.sub e i nl = needle || go (i + 1)) in
          go 0)
        errors
    in
    if not found then List.iter prerr_endline errors;
    check ("fixture: " ^ name) (found && List.length errors = 1)
  in
  let web = "apps/web/config" and store = "apps/store/config" in
  let vm = "guests/vm/config" in
  expect_drift "JAIL_IP drift is named" web
    "JAIL_IP=\"10.0.0.9\"\nPORT=\"4000\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"web.example.org\"\n"
    "web/config: JAIL_IP is 10.0.0.9 but";
  expect_drift "PORT drift is named" web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4001\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"web.example.org\"\n"
    "PORT is 4001 but";
  expect_drift "VIDEO_PORT drift is named" web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nVIDEO_PORT=\"4003\"\nPHX_HOST=\"web.example.org\"\n"
    "VIDEO_PORT is 4003 but";
  expect_drift "a missing VIDEO_PORT is named" web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nPHX_HOST=\"web.example.org\"\n" "VIDEO_PORT is unset";
  expect_drift "PHX_HOST drift is named" web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"www.example.org\"\n"
    "PHX_HOST is www.example.org but";
  expect_drift "Phoenix release name drift is named" web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"web.example.org\"\nAPP=\"wrong\"\n"
    "APP is wrong but";
  config root web
    "JAIL_IP=\"10.0.0.2\"\nPORT=\"4000\"\nVIDEO_PORT=\"4002\"\nPHX_HOST=\"web.example.org\"\n";
  expect_drift "an s3-only endpoint's PORT follows S3_PORT" store
    "JAIL_IP=\"10.0.0.3\"\nPUBLIC_HOST=\"s3.example.org\"\nS3_PORT=\"3901\"\nPORT=\"3900\"\n"
    "S3_PORT is 3901 but";
  config root store
    "JAIL_IP=\"10.0.0.3\"\nPUBLIC_HOST=\"s3.example.org\"\nS3_PORT=\"3900\"\nPORT=\"${S3_PORT}\"\n";
  expect_drift "GUEST_IP drift is named" vm
    ("GUEST_IP=\"10.0.0.11\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.org\"\n"
    ^ "GUEST_USER=\"vm\"\nSOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../src/vm}\"\n")
    "GUEST_IP is 10.0.0.11 but";
  expect_drift "PUBLIC_HOST drift is named" vm
    ("GUEST_IP=\"10.0.0.10\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.net\"\n"
    ^ "GUEST_USER=\"vm\"\nSOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../src/vm}\"\n")
    "PUBLIC_HOST is vm.example.net but";
  expect_drift "GUEST_USER drift is named" vm
    "GUEST_IP=\"10.0.0.10\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.org\"\n\
     GUEST_USER=\"builder\"\nSOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../src/vm}\"\n"
    "GUEST_USER is builder but";
  expect_drift "a missing GUEST_USER is named" vm
    "GUEST_IP=\"10.0.0.10\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.org\"\n\
     SOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../src/vm}\"\n"
    "GUEST_USER is unset";
  expect_drift "SOURCE_CHECKOUT default drift is named" vm
    "GUEST_IP=\"10.0.0.10\"\nPORT=\"4010\"\nPUBLIC_HOST=\"vm.example.org\"\n\
     GUEST_USER=\"vm\"\nSOURCE_CHECKOUT=\"${SOURCE_CHECKOUT:-../other/vm}\"\n"
    "SOURCE_CHECKOUT is ../other/vm but";
  config root web "echo broken >&2; exit 3\n";
  check "fixture: a config /bin/sh cannot source is named, with what it said"
    (List.mem (Filename.concat root web ^ ": cannot be sourced: broken") (declaration_drift root));
  Sys.remove (Filename.concat root web);
  check "fixture: an app without a config of its own has nothing to drift"
    (not (List.exists (fun error -> String.starts_with ~prefix:(Filename.concat root web) error)
            (declaration_drift root)));
  Sys.remove (Filename.concat root vm);
  check "fixture: a guest's missing config is named"
    (match declaration_drift root with
    | [ error ] -> String.starts_with ~prefix:(Filename.concat root vm ^ ": missing") error
    | _ -> false)

let () = if !failures > 0 then exit 1
