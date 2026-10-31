(* App_config parsing tested against inline sexp strings and against the
   real apps tree, in the style of test_dispatcher.ml: no external test
   framework, just check/contains helpers and a shared failure counter. *)
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

(* The field blocks below are written as bare top-level forms (no wrapping
   parens), so parse them with of_string_many rather than of_string, which
   only accepts exactly one s-expression. *)
let parse_ok str =
  App_config.of_sexp (Sexplib.Sexp.List (Sexplib.Sexp.of_string_many str))

let endpoint_and_hooks =
  {|
  (name drill) (ip 10.40.0.2) (hostname drill.example)
  (tailnet_ports ((http 4000))) (operator_ports ())
  (strategy freebsd_native_elixir) (hooks (bootstrap deploy check))
  |}

let minimal_fields =
  endpoint_and_hooks
  ^ {|(extra_steps ()) (strategy_config ((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /)))|}

(* The strategy is parsed at load: an empty strategy_config is refused. *)
let incomplete_strategy_fields = endpoint_and_hooks ^ {|(extra_steps ()) (strategy_config ())|}

let () =
  let app =
    parse_ok
      {|
      (name garage)
      (ip 10.40.0.4)
      (hostname s3.example.org)
      (tailnet_ports ((s3 3900)))
      (operator_ports ())
      (strategy freebsd_package)
      (hooks (bootstrap check))
      (extra_steps ())
      (strategy_config (
        (packages (sqlite3))
        (check_path /)
      ))
      |}
  in
  check "endpoint name" (app.endpoint.name = "garage");
  check "endpoint ip" (app.endpoint.ip = "10.40.0.4");
  check "endpoint hostname" (app.endpoint.hostname = "s3.example.org");
  check "endpoint tailnet_ports"
    (app.endpoint.tailnet_ports = [ { port_name = "s3"; port = 3900 } ]);
  check "endpoint operator_ports" (app.endpoint.operator_ports = []);
  check "hooks" (App_config.supports app Bootstrap);
  check "hooks excludes deploy" (not (App_config.supports app Deploy))

let rejects_with ~needle str =
  match parse_ok str with
  | _ -> false
  | exception Sexplib.Conv.Of_sexp_error (exn, _) ->
      contains ~needle (Printexc.to_string exn)

let () =
  check "unknown field rejected, naming it"
    (rejects_with ~needle:"extra_proxy_directive"
       (minimal_fields ^ {|(extra_proxy_directive "header_up X-Foo bar")|}));
  check "the old jail_ip field is now unknown"
    (rejects_with ~needle:"unknown field jail_ip" (minimal_fields ^ "(jail_ip 10.40.0.9)"));
  check "the retired jail field is now unknown"
    (rejects_with ~needle:"unknown field jail" (minimal_fields ^ "(jail generated)"));
  check "duplicate field rejected, naming it"
    (rejects_with ~needle:"duplicate field ip" (minimal_fields ^ "(ip 10.40.0.9)"))

(* The example's apps tree loads, sorted, skipping the engine's _lib,
   and each app carries its declared endpoint. *)
let () =
  let apps = App_config.load_all (Layout.apps_dir (Repo_root.example ())) in
  check "example apps: all three load, sorted"
    (App_config.names apps = [ "counter"; "hello"; "logs" ]);
  match App_config.find apps "logs" with
  | None -> check "example apps: logs present" false
  | Some logs ->
      check "example apps: logs has named http and syslog ports"
        (logs.endpoint.tailnet_ports
        = [ { port_name = "http"; port = 9428 }; { port_name = "syslog"; port = 29514 } ])

let () =
  check "minimal fields load" (Result.is_ok (try Ok (parse_ok minimal_fields) with exn -> Error exn));
  check "app loading rejects incomplete strategy before rendering"
    (rejects_with ~needle:"missing strategy_config field" incomplete_strategy_fields);
  check "app loading rejects unknown strategy before rendering"
    (rejects_with ~needle:"unknown strategy"
      {|(name demo) (ip 1.2.3.4) (hostname demo.example)
        (tailnet_ports ()) (operator_ports ()) (strategy typo)
        (hooks ()) (extra_steps ()) (strategy_config ())|})

(* Extra step names are spliced into the generated script, so a name that
   is not a plain file name beside it is refused at load, naming it. *)
let () =
  List.iter
    (fun step ->
      check
        (Printf.sprintf "app loading rejects extra_steps entry %S" step)
        (match
           parse_ok
             (endpoint_and_hooks
             ^ Printf.sprintf {|(extra_steps (%S)) (strategy_config ((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /)))|}
                 step)
         with
        | _ -> false
        | exception Sexplib.Conv.Of_sexp_error (Failure msg, Sexplib.Sexp.Atom offending) ->
            contains ~needle:"extra_steps" msg && offending = step))
    [ "../x.sh"; "sub/x.sh"; "a b.sh"; {|x".sh|}; "$(x).sh"; ".hidden.sh"; "" ];
  check "app loading keeps plain extra_steps in order"
    ((parse_ok
        (endpoint_and_hooks
        ^ {|(extra_steps (first.sh second.sh)) (strategy_config ((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /)))|}))
       .extra_steps
    = [ "first.sh"; "second.sh" ])

let () = if !failures > 0 then exit 1
