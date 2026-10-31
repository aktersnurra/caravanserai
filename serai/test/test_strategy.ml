(* Strategy sh generation tested against golden files, matching
   test_app_config.ml's style: no external test framework, just check
   helpers and a shared failure counter. *)
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

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let golden name = read_file (Filename.concat "golden/strategy" name)

(* Apps are built as App_config.of_sexp builds them: the endpoint through
   Network_endpoint.create, the strategy through Strategy_config.parse and
   the extra steps through App_config.create. *)
let parse_strategy strategy config =
  Strategy_config.parse ~strategy:(Sexplib.Sexp.Atom strategy) ~config:(Sexplib.Sexp.of_string config)

let make_app ?(extra_steps = []) ?env_names ~name ~ip ~hostname ~tailnet_ports ~strategy config =
  let endpoint =
    Test_declaration.endpoint ~name ~ip ~hostname
      ~tailnet_ports:(List.map (fun (port_name, port) -> Network_endpoint.{ port_name; port }) tailnet_ports)
      ~operator_ports:[]
  in
  let strategy =
    match parse_strategy strategy config with
    | Ok strategy -> strategy
    | Error error -> failwith (Strategy_config.error_message error)
  in
  match
    App_config.create ?env_names ~endpoint ~strategy ~hooks:[ Bootstrap; Deploy; Check ] ~extra_steps ()
  with
  | Ok app -> app
  | Error error -> failwith (Strategy_config.error_message error)

(* The same app with other extra steps, validated as at load. *)
let with_extra_steps (app : App_config.t) extra_steps =
  App_config.create ~env_names:app.env_names ~endpoint:app.endpoint ~strategy:app.strategy
    ~hooks:app.hooks ~extra_steps ()

(* The example configuration's apps, as App_config.load reads them: one per
   native kind. Their jail scripts are checked against golden/example/ by
   test_example_render. *)
let example_app name =
  App_config.load (Filename.concat (Layout.app_dir (Repo_root.example ()) name) "app.sexp")

let hello_app = example_app "hello"
let counter_app = example_app "counter"

(* Strategy_config.parse is what App_config.of_sexp calls at load: every
   rejection below happens before anything renders. *)
let rejected ~strategy ~needle config =
  match parse_strategy strategy config with
  | Ok _ -> false
  | Error error -> contains ~needle (Strategy_config.error_message error)

let () =
  match parse_strategy "not_a_real_strategy" "()" with
  | Ok _ -> check "unknown strategy atom should be rejected" false
  | Error error ->
      check "unknown strategy error attaches the bogus atom"
        (Strategy_config.offending_sexp error = Sexplib.Sexp.Atom "not_a_real_strategy"
        && match error with Strategy_config.Unknown_strategy _ -> true | _ -> false)

(* A pinned binary: an identity provider with a database path, its public
   URL and a key it must never lose. *)
let pinned_config ?(env_values = "(env_values ((APP_URL https://id.example.org) (DB_PATH /var/db/idp/idp.db)))")
    ?(generated_secrets = "(generated_secrets (SESSION_KEY))") () =
  Printf.sprintf
    "((version v1.2.0) \
     (binary_sha256 %s) \
     (binary_url_template https://downloads.example.org/idp/${VERSION}/idp_freebsd_amd64) \
     (binary_name idp) \
     (port 1411) \
     %s %s \
     (data_dir /var/db/idp) \
     (packages (sqlite3)) \
     (env_template_path env.template) \
     (rc_template_path idp.rc.template) \
     (check_path /))"
    (String.make 64 'a') env_values generated_secrets

let pinned_app ?env_values ?generated_secrets () =
  make_app ~name:"idp" ~ip:"10.20.0.5" ~hostname:"id.example.org"
    ~tailnet_ports:[ ("http", 1411) ] ~strategy:"fetch_binary"
    (pinned_config ?env_values ?generated_secrets ())

let () =
  let generated = Strategy.render_jail_script (pinned_app ()) in
  check "fetch_binary matches golden output" (generated = golden "fetch_binary.sh")

let () =
  check "fetch_binary missing field error names the missing field"
    (rejected ~strategy:"fetch_binary" ~needle:"missing strategy_config field" "((version v1))");
  check "fetch_binary: an app-specific field is not a strategy field"
    (rejected ~strategy:"fetch_binary" ~needle:"unknown strategy_config field app_url"
       (pinned_config ~generated_secrets:"(app_url https://id.example.org)" ()));
  check "fetch_binary: env and secrets are optional"
    (Result.is_ok (parse_strategy "fetch_binary" (pinned_config ~env_values:"" ~generated_secrets:"" ())));
  List.iter
    (fun (name, env_values, generated_secrets, needle) ->
      check ("fetch_binary rejects " ^ name)
        (rejected ~strategy:"fetch_binary" ~needle (pinned_config ~env_values ~generated_secrets ())))
    [
      ("a lowercase env name", "(env_values ((app_url x)))", "", "env name");
      ("a reserved env name", "(env_values ((PORT 80)))", "", "filled by the engine");
      ("a reserved secret name", "", "(generated_secrets (JAIL_IP))", "filled by the engine");
      ("a name declared twice", "(env_values ((KEY a)))", "(generated_secrets (KEY))", "declared twice");
      ("a repeated env name", "(env_values ((A x) (A y)))", "", "declared twice");
      ("a quote in a value", {|(env_values ((A "x\"y")))|}, "", "unsafe env value");
      ("a dollar in a value", "(env_values ((A x$y)))", "", "unsafe env value");
      ("a backtick in a value", "(env_values ((A x`y)))", "", "unsafe env value");
      ("a backslash in a value", {|(env_values ((A "x\\y")))|}, "", "unsafe env value");
      ("an ampersand in a value", "(env_values ((A x&y)))", "", "unsafe env value");
      ("a space in a value", {|(env_values ((A "x y")))|}, "", "unsafe env value");
      ("an empty value", {|(env_values ((A "")))|}, "", "unsafe env value");
    ]

(* The env section of the rendered script, run as the script runs it:
   from ENVFILE= to its closing fi, with a stub openssl that hands out
   numbered secrets. *)
let env_section script =
  let lines = String.split_on_char '\n' script in
  let rec drop = function
    | [] -> []
    | line :: rest when String.starts_with ~prefix:"ENVFILE=" line -> line :: rest
    | _ :: rest -> drop rest
  in
  let rec take = function
    | [] -> []
    | "fi" :: _ -> [ "fi" ]
    | line :: rest -> line :: take rest
  in
  String.concat "\n" (take (drop lines))

let write_file path contents =
  let oc = open_out_bin path in
  output_string oc contents;
  close_out oc

let run_env_section ?existing ~template app =
  let dir = Filename.temp_dir "fetch-binary-env" "" in
  List.iter (fun sub -> Unix.mkdir (Filename.concat dir sub) 0o700)
    [ "root"; "root/etc"; "root/etc/idp"; "app"; "bin"; "tmp" ];
  write_file (Filename.concat dir "app/env.template") template;
  Option.iter (write_file (Filename.concat dir "root/etc/idp/env")) existing;
  write_file (Filename.concat dir "bin/openssl")
    "#!/bin/sh\nn=$(($(cat \"$STUB_COUNT\" 2>/dev/null || echo 0) + 1))\necho \"$n\" >\"$STUB_COUNT\"\necho \"secret-$n\"\n";
  Unix.chmod (Filename.concat dir "bin/openssl") 0o755;
  let script = Filename.concat dir "env.sh" in
  write_file script
    (String.concat "\n"
       [ "set -eu"; {|log() { echo "==> $*" >&2; }|};
         Printf.sprintf "JROOT=%s/root SCRIPT_DIR=%s/app APP=idp JAIL_IP=10.20.0.5" dir dir;
         Printf.sprintf "export TMPDIR=%s/tmp STUB_COUNT=%s/count PATH=%s/bin:$PATH" dir dir dir;
         env_section (Strategy.render_jail_script app); "" ]);
  let status = Sys.command (Printf.sprintf "sh %s 2>/dev/null" (Filename.quote script)) in
  let env = Filename.concat dir "root/etc/idp/env" in
  let contents = if Sys.file_exists env then Some (read_file env) else None in
  let leftovers = Sys.readdir (Filename.concat dir "tmp") |> Array.length in
  let secrets_made = Sys.file_exists (Filename.concat dir "count") in
  ignore (Sys.command (Printf.sprintf "rm -r %s" (Filename.quote dir)));
  (status, contents, leftovers, secrets_made)

let () =
  let template = "URL=__APP_URL__\nLISTEN=__JAIL_IP__:__PORT__\nDB=__DB_PATH__\nKEY=__SESSION_KEY__\nOTHER=__SIGNING_KEY__\n" in
  let app = pinned_app ~generated_secrets:"(generated_secrets (SESSION_KEY SIGNING_KEY))" () in
  let status, env, leftovers, _ = run_env_section ~template app in
  check "fetch_binary env: every placeholder filled, each secret its own"
    (status = 0
    && env = Some "URL=https://id.example.org\nLISTEN=10.20.0.5:1411\nDB=/var/db/idp/idp.db\nKEY=secret-1\nOTHER=secret-2\n");
  check "fetch_binary env: no secret left in TMPDIR" (leftovers = 0);
  let status, env, _, secrets_made = run_env_section ~existing:"KEY=kept\n" ~template app in
  check "fetch_binary env: an existing env file is kept and no secret is made"
    (status = 0 && env = Some "KEY=kept\n" && not secrets_made);
  let status, env, leftovers, _ = run_env_section ~template:"A=__UNDECLARED__\n" app in
  check "fetch_binary env: an undeclared placeholder fails and writes no env"
    (status <> 0 && env = None && leftovers = 0)

(* A package the example does not declare: no build, no rc script of its own. *)
let package_app =
  make_app ~name:"store" ~ip:"10.20.0.4" ~hostname:"store.example.org"
    ~tailnet_ports:[ ("s3", 3900) ] ~strategy:"freebsd_package"
    "((packages (garage)) (check_path /))"

(* An OCaml jail: the dataset must be verified mounted before
   the jail starts, so SQLite never falls back to the jail's own filesystem. *)
let index_of ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i =
    if i + nl > hl then None
    else if String.sub haystack i nl = needle then Some i
    else go (i + 1)
  in
  go 0

let () =
  let generated = Strategy.render_jail_script counter_app in
  check "freebsd_native_ocaml verifies the ZFS mount before starting the jail"
    (match
       ( index_of ~needle:"refusing to start jail" generated,
         index_of ~needle:"service jail start" generated )
     with
    | Some verify, Some start -> verify < start
    | _ -> false)

(* ... and registers the jail (jail.conf block, jail_list entry) only once
   the mount is verified, so a failed verify leaves nothing to autostart. *)
let () =
  let generated = Strategy.render_jail_script counter_app in
  check "freebsd_native_ocaml: ZFS verify, then jail.conf, then jail_list, then start"
    (match
       ( index_of ~needle:"refusing to start jail" generated,
         index_of ~needle:"cat >>/etc/jail.conf" generated,
         index_of ~needle:{|sysrc jail_list+=|} generated,
         index_of ~needle:"service jail start" generated )
     with
    | Some verify, Some conf, Some list, Some start -> verify < conf && conf < list && list < start
    | _ -> false)

let () =
  check "freebsd_native_ocaml missing field error names the missing field"
    (rejected ~strategy:"freebsd_native_ocaml" ~needle:"missing strategy_config field"
       "((ocaml_switch 5.5.1))");
  check "freebsd_native_elixir missing field error names the missing field"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"missing strategy_config field" "()");
  check "freebsd_native_elixir requires a release name"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"release_name"
       "((packages (sqlite3)) (repo_path /r) (check_path /))");
  check "freebsd_native_elixir rejects release names unsafe for a build worker"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"invalid release_name"
       "((packages (sqlite3)) (repo_path /r) (release_name ../escape) (check_path /))")

(* strategy_config is checked against the field set of the strategy being
   parsed: a field that belongs to another strategy is still unknown here. *)
let () =
  check "unknown strategy_config field error names the key"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"version"
       "((packages (sqlite3)) (repo_path /r) (check_path /) (version v1))");
  check "duplicate strategy_config field error names the key"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"repo_path"
       "((packages (sqlite3)) (repo_path /r) (check_path /) (repo_path /s))")

(* An empty package list would render `pkg install -y` with no arguments,
   which fails under set -e -- reject it at parse time instead. *)
let () =
  check "freebsd_native_elixir rejects an empty packages list"
    (rejected ~strategy:"freebsd_native_elixir" ~needle:"packages"
       "((packages ()) (repo_path /r) (release_name example) (check_path /))");
  check "freebsd_native_ocaml rejects an empty packages list"
    (rejected ~strategy:"freebsd_native_ocaml" ~needle:"packages"
       "((ocaml_switch 5.5.1) (repo_path /r) (zfs_dataset zroot/meals) \
        (data_dir /var/db/meals) (packages ()) (serve_args (serve)) (check_path /health))")

(* extra_steps run from the directory the script lives in, in declared
   order, after the service user is created -- so a step can chown to it, as
   a backup job's install does -- and before any service is enabled. *)
let () =
  List.iter
    (fun (label, (app : App_config.t)) ->
      let script =
        match with_extra_steps app [ "first.sh"; "second.sh" ] with
        | Ok app -> Strategy.render_jail_script app
        | Error error -> failwith (Strategy_config.error_message error)
      in
      (* Passed on each step's command line, never exported: the script's
         own later jexec calls would inherit an exported JAIL, which
         service(8) reads as its -j option. *)
      check (label ^ ": each extra step is handed the jail's facts")
        (List.for_all
           (fun step ->
             contains
               ~needle:
                 (Printf.sprintf
                    {|JAIL="$JAIL" JAIL_IP="$JAIL_IP" JROOT="$JROOT" APP="$APP" sh "${SCRIPT_DIR}/%s"|}
                    step)
               script)
           [ "first.sh"; "second.sh" ]);
      check (label ^ ": the jail's facts are never exported")
        (not (contains ~needle:"export" script));
      check (label ^ ": extra_steps run in order after the service user")
        (match
           ( index_of ~needle:"pkg install -y" script,
             index_of ~needle:"pw useradd" script,
             index_of ~needle:{|sh "${SCRIPT_DIR}/first.sh"|} script,
             index_of ~needle:{|sh "${SCRIPT_DIR}/second.sh"|} script )
         with
        | Some install, Some user, Some first, Some second ->
            install < user && user < first && first < second
        | _ -> false);
      check (label ^ ": extra_steps run before any service is enabled")
        (match
           ( index_of ~needle:{|sh "${SCRIPT_DIR}/second.sh"|} script,
             index_of ~needle:{|jexec "$JAIL" sysrc |} script )
         with
        | Some second, Some enable -> second < enable
        | Some _, None -> true
        | None, _ -> false);
      check (label ^ ": no extra_steps, no export")
        (not (contains ~needle:"export" (Strategy.render_jail_script app))))
    [ ("freebsd_native_elixir", hello_app); ("fetch_binary", (pinned_app ()));
      ("freebsd_native_ocaml", counter_app) ]

(* A step name is spliced into the script, so it must be a plain file name
   beside the script: no path, no quoting. Refused when the app is built,
   so no such app ever reaches rendering. *)
let () =
  List.iter
    (fun step ->
      check
        (Printf.sprintf "extra_steps entry %S is rejected" step)
        (match with_extra_steps hello_app [ step ] with
        | Ok _ -> false
        | Error (Strategy_config.Invalid_extra_step rejected as error) ->
            rejected = step && contains ~needle:"extra_steps" (Strategy_config.error_message error)
        | Error _ -> false))
    [ "../x.sh"; "sub/x.sh"; "a b.sh"; {|x".sh|}; "$(x).sh"; ".hidden.sh"; "" ]

(* Erlang links only belong to the Elixir strategy when an Erlang runtime is installed. *)
let () =
  check "freebsd_native_elixir links erlang28 into /usr/local/bin"
    (contains ~needle:"/usr/local/lib/erlang28/bin/*" (Strategy.render_jail_script hello_app));
  check "freebsd_native_elixir links whichever erlang-runtimeNN is installed"
    (let script =
       Strategy.render_jail_script
         (make_app ~name:"drill" ~ip:"10.40.0.2" ~hostname:"drill.example.org"
            ~tailnet_ports:[ ("http", 4000) ] ~strategy:"freebsd_native_elixir"
            "((packages (erlang-runtime29 elixir-devel)) (repo_path /x) (release_name drill_trainer) (check_path /))")
     in
     contains ~needle:"/usr/local/lib/erlang29/bin/*" script
     && not (contains ~needle:"erlang28" script));
  check "freebsd_package installs the package without Erlang setup"
    (let script =
       Strategy.render_jail_script
         (make_app ~name:"garage" ~ip:"10.40.0.4" ~hostname:"s3.example.org"
            ~tailnet_ports:[ ("s3", 3900) ] ~strategy:"freebsd_package"
            "((packages (garage)) (check_path /))")
     in
     contains ~needle:{|jexec "$JAIL" pkg install -y garage|} script
     && not (contains ~needle:"/usr/local/lib/erlang" script));
  check "freebsd_package: a declared check_status is parsed"
    (match parse_strategy "freebsd_package" "((packages (minio)) (check_path /) (check_status 403))" with
     | Ok (Strategy_config.Freebsd_package s) -> s.check_status = Some 403
     | _ -> false);
  check "freebsd_package: without check_status, any success is ready"
    (match parse_strategy "freebsd_package" "((packages (minio)) (check_path /))" with
     | Ok (Strategy_config.Freebsd_package s) -> Option.is_none s.check_status
     | _ -> false);
  List.iter (fun bad ->
    check ("freebsd_package: check_status " ^ bad ^ " is refused")
      (rejected ~strategy:"freebsd_package" ~needle:"check_status"
         (Printf.sprintf "((packages (minio)) (check_path /) (check_status %s))" bad)))
    [ "99"; "600"; "abc"; "(403)" ];
  check "freebsd_package: service_status process is parsed"
    (match parse_strategy "freebsd_package" "((packages (minio)) (check_path /) (service_status process))" with
     | Ok (Strategy_config.Freebsd_package s) -> s.service_status = Process
     | _ -> false);
  check "freebsd_package: without service_status, rc status is trusted"
    (match parse_strategy "freebsd_package" "((packages (minio)) (check_path /))" with
     | Ok (Strategy_config.Freebsd_package s) -> s.service_status = Rc
     | _ -> false);
  List.iter (fun bad ->
    check ("freebsd_package: service_status " ^ bad ^ " is refused")
      (rejected ~strategy:"freebsd_package" ~needle:"service_status"
         (Printf.sprintf "((packages (minio)) (check_path /) (service_status %s))" bad)))
    [ "garage"; "(process)"; "Process" ];
  check "freebsd_package refuses source-build fields"
    (rejected ~strategy:"freebsd_package" ~needle:"repo_path"
       "((packages (garage)) (repo_path /unused) (check_path /))")

(* Templates are read from beside the script, never from cwd. *)
let () =
  let script = Strategy.render_jail_script (pinned_app ()) in
  check "fetch_binary reads the env template beside the script"
    (contains ~needle:{|"${SCRIPT_DIR}/env.template"|} script);
  check "fetch_binary reads the rc.d template beside the script"
    (contains ~needle:{|"${SCRIPT_DIR}/idp.rc.template"|} script)

let () =
  check "fetch_binary rejects an empty packages list"
    (rejected ~strategy:"fetch_binary" ~needle:"packages"
       "((version v1) (binary_sha256 x) (binary_url_template u) (binary_name b) \
        (port 1) (data_dir /d) \
        (packages ()) (env_template_path e) (rc_template_path r) (check_path /))")

(* A script rendered under another jail name (serai jail-test's <app>test)
   keeps every in-jail name -- service user, /opt, /var/db, /etc, rc.d and
   service name -- equal to the real app's, and moves every host-side one --
   jail.conf block, /jails/<name>, jail_list, jexec and service jail targets,
   an OCaml app's ZFS dataset -- to the jail name. The check expands the script's own
   JAIL and APP variables, then looks at what each line would name. *)
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

let expand ~jail ~app script =
  script
  |> replace_all ~sub:"${JAIL}" ~by:jail
  |> replace_all ~sub:"\"$JAIL\"" ~by:(Printf.sprintf "%S" jail)
  |> replace_all ~sub:"${APP}" ~by:app
  |> replace_all ~sub:"\"$APP\"" ~by:(Printf.sprintf "%S" app)

let every_jexec_targets ~jail script =
  let prefix = "jexec \"" in
  let pl = String.length prefix in
  let rec go i =
    match index_of ~needle:prefix (String.sub script i (String.length script - i)) with
    | None -> true
    | Some j ->
        let at = i + j + pl in
        let target = jail ^ "\"" in
        String.length script >= at + String.length target
        && String.sub script at (String.length target) = target
        && go at
  in
  go 0

(* One app per strategy that builds a jail of its own. *)
let rendered_apps =
  [ ("hello", hello_app); ("counter", counter_app); ("idp", (pinned_app ())); ("store", package_app) ]

let () =
  List.iter
    (fun (name, app) ->
      let test = name ^ "test" in
      let script = Strategy.render_jail_script ~jail_name:test app in
      let lines = String.split_on_char '\n' script in
      let expanded = expand ~jail:test ~app:name script in
      let has needle = contains ~needle expanded in
      let label s = Printf.sprintf "%s under jail name %s: %s" name test s in
      check (label "JAIL is the jail name") (List.mem ("JAIL=" ^ test) lines);
      check (label "APP is the app name") (List.mem ("APP=" ^ name) lines);
      check (label "jail root is /jails/<jail name>")
        (List.mem {|JROOT="/jails/${JAIL}"|} lines);
      check (label "jail.conf block and path use the jail name")
        (List.mem (test ^ " {") (String.split_on_char '\n' expanded)
        && has (Printf.sprintf "path          = /jails/%s;" test));
      check (label "jail_list and service jail use the jail name")
        (has (Printf.sprintf {|sysrc jail_list+=" %s"|} test)
        && has (Printf.sprintf {|service jail start "%s"|} test));
      check (label "every jexec targets the jail name") (every_jexec_targets ~jail:test expanded);
      check (label "no host-side name is the real app's")
        (not (has (Printf.sprintf "/jails/%s;" name) || has (Printf.sprintf "\n%s {" name)
             || has (Printf.sprintf {|jail_list+=" %s"|} name)));
      check (label "in-jail dirs use the app name")
        (List.for_all
           (fun dir -> has (Printf.sprintf {|"${JROOT}%s/%s"|} dir name))
           [ "/opt"; "/var/db"; "/etc"; "/var/log"; "/var/run" ]);
      check (label "service user is the app name")
        (has (Printf.sprintf {|pw useradd -n "%s"|} name)
        && has (Printf.sprintf {|-c "%s service user"|} name)
        && has (Printf.sprintf {|chown -R "%s:%s"|} name name));
      check (label "no in-jail name is the jail name")
        (not
           (List.exists has
              [
                "/opt/" ^ test; "/var/db/" ^ test; "/etc/" ^ test; "/var/log/" ^ test;
                "/var/run/" ^ test; Printf.sprintf {|-n "%s"|} test; test ^ "_enable";
                "service " ^ test; "rc.d/" ^ test;
              ])))
    rendered_apps

let () =
  let expanded =
    expand ~jail:"idptest" ~app:"idp"
      (Strategy.render_jail_script ~jail_name:"idptest" (pinned_app ()))
  in
  List.iter
    (fun needle -> check ("idp under idptest: " ^ needle) (contains ~needle expanded))
    [
      {|sysrc idp_enable="YES"|}; "service idp restart"; "service idp start";
      {|"${JROOT}/usr/local/etc/rc.d/idp"|}; {|ENVFILE="${JROOT}/etc/idp/env"|};
      {|chown "root:idp" "/etc/idp/env"|};
    ]

(* An OCaml app's dataset lives on the host, so a test jail gets its own: the
   jail name's suffix beyond the app name is appended to the dataset. A jail
   name that does not extend the app name has no safe dataset and is refused. *)
let () =
  let counter = counter_app in
  let lines = String.split_on_char '\n' (Strategy.render_jail_script ~jail_name:"countertest" counter) in
  check "counter under countertest: the dataset is namespaced"
    (List.mem "ZFS_DATASET=zroot/countertest" lines);
  check "counter under countertest: the real dataset is never named"
    (not (List.mem "ZFS_DATASET=zroot/counter" lines));
  check "counter under its own name: the dataset is unchanged"
    (List.mem "ZFS_DATASET=zroot/counter" (String.split_on_char '\n' (Strategy.render_jail_script counter)));
  check "counter under a jail name that does not extend counter is refused"
    (match Strategy.render_jail_script ~jail_name:"other" counter with
    | _ -> false
    | exception Invalid_argument msg -> contains ~needle:"zfs_dataset" msg)

(* The default jail name is the endpoint name. *)
let () =
  List.iter
    (fun (name, app) ->
      check (name ^ ": the default jail name is the endpoint name")
        (Strategy.render_jail_script app = Strategy.render_jail_script ~jail_name:name app))
    rendered_apps

(* Build inputs are declared: the app source and, for OCaml, the pinned
   opam repository. A missing source is allowed (legacy hook apps). *)
let () =
  let elixir extra =
    parse_strategy "freebsd_native_elixir"
      ("((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /) " ^ extra ^ ")") in
  let ocaml extra =
    parse_strategy "freebsd_native_ocaml"
      ("((ocaml_switch 5.5.1) (repo_path /r) (zfs_dataset zroot/meals) (data_dir /var/db/meals) \
        (packages (ocaml-opam)) (check_path /health) (serve_args (serve)) " ^ extra ^ ")") in
  check "elixir source is optional"
    (match elixir "" with Ok (Strategy_config.Freebsd_native_elixir { source = None; _ }) -> true | _ -> false);
  check "elixir declares an ssh git source"
    (match elixir "(source (git git@github.com:ops/drill_trainer.git))" with
     | Ok (Strategy_config.Freebsd_native_elixir { source = Some url; _ }) ->
         url = "git@github.com:ops/drill_trainer.git"
     | _ -> false);
  check "https git source accepted"
    (Result.is_ok (elixir "(source (git https://github.com/ops/meals.git))"));
  List.iter (fun (label, source) ->
      check ("unsafe git source rejected: " ^ label)
        (match elixir source with Error _ -> true | Ok _ -> false))
    [ ("option-like", "(source (git -oProxyCommand=x))");
      ("local path", "(source (git /home/user/repo))");
      ("shell metacharacter", "(source (git \"https://x/$(id)\"))");
      ("not git", "(source (path /r))") ];
  check "ocaml declares source and pinned opam repository"
    (match ocaml "(source (git git@github.com:ops/meals.git)) \
                  (opam_repository (git https://github.com/ocaml/opam-repository.git) \
                   (commit 4b3c9153f191701aa5da18d2f5ab5da796ce2133))" with
     | Ok (Strategy_config.Freebsd_native_ocaml
             { source = Some _; opam_repository = Some { url; commit }; _ }) ->
         url = "https://github.com/ocaml/opam-repository.git"
         && commit = "4b3c9153f191701aa5da18d2f5ab5da796ce2133"
     | _ -> false);
  check "opam repository commit must be a full commit id"
    (Result.is_error (ocaml "(opam_repository (git https://github.com/ocaml/opam-repository.git) (commit main))"))

(* The rc.d script of each native kind, against golden output: both example
   apps declare a migrate, which adds the migrate command; without one there
   is none, and other strategies have no rc script. *)
let () =
  let hello_without_migrate =
    make_app ~name:"hello" ~ip:"10.20.0.2" ~hostname:"hello.example.org"
      ~tailnet_ports:[ ("http", 4000) ] ~strategy:"freebsd_native_elixir"
      "((packages (sqlite3)) (repo_path /r) (release_name hello) (check_path /))" in
  List.iter
    (fun (label, app, service, file) ->
      match Rc_script.render app with
      | Some rc ->
          check (label ^ ": rc service name") (rc.service = service);
          check (label ^ ": rc matches golden output") (rc.script = golden file)
      | None -> check (label ^ ": renders an rc script") false)
    [ ("hello", hello_app, "hello", "rc_hello.sh");
      ("counter", counter_app, "counter", "rc_counter.sh") ];
  check "rc: hello without migrate has no migrate command"
    (match Rc_script.render hello_without_migrate with
     | Some rc -> not (contains ~needle:"migrate" rc.script)
     | None -> false);
  check "rc: package and binary strategies have none"
    (Rc_script.render (pinned_app ()) = None)

(* The rc's env check, run: counter's script with rc.subr stubbed out, the env
   file moved to a scratch path and the env function called directly. *)
let () =
  let replace ~needle ~by text =
    match index_of ~needle text with
    | Some i ->
        String.sub text 0 i ^ by
        ^ String.sub text (i + String.length needle) (String.length text - i - String.length needle)
    | None -> failwith ("rc env check: no " ^ needle) in
  let dir = Filename.temp_dir "rc-env" "" in
  let envfile = Filename.concat dir "env" and errors = Filename.concat dir "errors" in
  let script =
    (match Rc_script.render counter_app with Some rc -> rc.script | None -> "")
    |> replace ~needle:". /etc/rc.subr" ~by:"load_rc_config() { :; }"
    |> replace ~needle:{|envfile="/etc/counter/env"|} ~by:("envfile=" ^ Filename.quote envfile)
    |> replace ~needle:{|run_rc_command "$1"|} ~by:"counter_env" in
  let accepts env =
    Out_channel.with_open_bin envfile (fun oc -> output_string oc env);
    Sys.command ("sh -c " ^ Filename.quote script ^ " >/dev/null 2>" ^ Filename.quote errors) = 0 in
  let refused_naming name env =
    not (accepts env)
    && contains ~needle:(name ^ " is not set") (In_channel.with_open_bin errors In_channel.input_all) in
  check "rc env: every declared name filled in is accepted"
    (accepts "COUNTER_DATABASE_PATH=/var/db/counter/c.db\nCOUNTER_LISTEN_ADDRESS=10.20.0.3:4010\n");
  check "rc env: a missing name is refused, naming it"
    (refused_naming "COUNTER_LISTEN_ADDRESS" "COUNTER_DATABASE_PATH=/var/db/counter/c.db\n");
  check "rc env: an empty value is refused"
    (refused_naming "COUNTER_DATABASE_PATH" "COUNTER_DATABASE_PATH=\nCOUNTER_LISTEN_ADDRESS=10.20.0.3:4010\n");
  check "rc env: a REPLACE_ME value is refused"
    (refused_naming "COUNTER_LISTEN_ADDRESS"
       "COUNTER_DATABASE_PATH=/var/db/counter/c.db\nCOUNTER_LISTEN_ADDRESS=REPLACE_ME\n");
  check "rc env: an unreadable env file is refused"
    (Sys.remove envfile;
     Sys.command ("sh -c " ^ Filename.quote script ^ " >/dev/null 2>&1") <> 0);
  ignore (Sys.command ("rm -rf " ^ Filename.quote dir))

(* Migrate is per kind: a release eval for phoenix, a binary subcommand for
   ocaml, so neither can declare the other's form. Omitted means none. *)
let () =
  let elixir extra =
    parse_strategy "freebsd_native_elixir"
      ("((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /) " ^ extra ^ ")") in
  let ocaml ?(serve = "(serve_args (serve))") extra =
    parse_strategy "freebsd_native_ocaml"
      ("((ocaml_switch 5.5.1) (repo_path /r) (zfs_dataset zroot/meals) (data_dir /var/db/meals) \
        (packages (ocaml-opam)) (check_path /health) " ^ serve ^ " " ^ extra ^ ")") in
  let elixir_migrate = function
    | Ok (Strategy_config.Freebsd_native_elixir { migrate; _ }) -> Ok migrate
    | Ok _ -> Error "other strategy" | Error e -> Error (Strategy_config.error_message e) in
  let ocaml_migrate = function
    | Ok (Strategy_config.Freebsd_native_ocaml { migrate; _ }) -> Ok migrate
    | Ok _ -> Error "other strategy" | Error e -> Error (Strategy_config.error_message e) in
  check "elixir migrate omitted is none" (elixir_migrate (elixir "") = Ok None);
  check "elixir migrate none" (elixir_migrate (elixir "(migrate none)") = Ok None);
  check "elixir migrate release_eval"
    (elixir_migrate (elixir "(migrate (release_eval Hello.Release.migrate))")
     = Ok (Some "Hello.Release.migrate"));
  List.iter (fun (label, migrate) ->
      check ("elixir migrate refused: " ^ label) (Result.is_error (elixir migrate)))
    [ ("a command", "(migrate (command migrate))");
      ("no module", "(migrate (release_eval migrate))");
      ("lowercase module", "(migrate (release_eval hello.migrate))");
      ("code injection", "(migrate (release_eval \"Hello.m(); System.halt\"))");
      ("unknown form", "(migrate yes)") ];
  check "ocaml migrate omitted is none" (ocaml_migrate (ocaml "") = Ok None);
  check "ocaml migrate command"
    (ocaml_migrate (ocaml "(migrate (command migrate --verbose))") = Ok (Some [ "migrate"; "--verbose" ]));
  List.iter (fun (label, migrate) ->
      check ("ocaml migrate refused: " ^ label) (Result.is_error (ocaml migrate)))
    [ ("a release eval", "(migrate (release_eval Meals.migrate))");
      ("empty command", "(migrate (command))");
      ("shell word", "(migrate (command \"migrate;id\"))") ];
  check "ocaml serve_args parsed"
    (match ocaml "" with
     | Ok (Strategy_config.Freebsd_native_ocaml { serve_args; _ }) -> serve_args = [ "serve" ]
     | _ -> false);
  check "ocaml serve_args required" (Result.is_error (ocaml ~serve:"" ""));
  check "ocaml serve_args must not be empty" (Result.is_error (ocaml ~serve:"(serve_args ())" ""));
  check "ocaml serve_args are plain words"
    (Result.is_error (ocaml ~serve:"(serve_args (\"serve &\"))" ""));
  let web_bundle = function
    | Ok (Strategy_config.Freebsd_native_ocaml { web_bundle; _ }) -> Ok web_bundle
    | Ok _ -> Error "other strategy" | Error e -> Error (Strategy_config.error_message e) in
  check "ocaml web_bundle omitted is none" (web_bundle (ocaml "") = Ok None);
  check "ocaml web_bundle is a path in the source"
    (web_bundle (ocaml "(web_bundle web/build-bundle.sh)") = Ok (Some "web/build-bundle.sh"));
  List.iter (fun (label, value) ->
      check ("ocaml web_bundle refused: " ^ label)
        (Result.is_error (ocaml ("(web_bundle " ^ value ^ ")"))))
    [ ("absolute", "/usr/bin/true"); ("parent", "../build.sh"); ("dot segment", "web/./b.sh");
      ("option", "-x"); ("trailing slash", "web/"); ("shell word", "\"b.sh;id\"") ]

let () =
  if !failures > 0 then exit 1
