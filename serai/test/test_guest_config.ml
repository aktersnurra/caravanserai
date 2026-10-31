(* Guest_config and Edge_config parsing, plus the real guests and
   edge/edge.sexp files, in the style of test_app_config.ml. *)
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

let raises_with ~needle f =
  match f () with
  | _ -> false
  | exception Sexplib.Conv.Of_sexp_error (exn, _) ->
      contains ~needle (Printexc.to_string exn)

let guest_fields =
  {|(name vault) (ip 10.40.0.10) (hostname vault.example)
    (tailnet_ports ((http 4010))) (operator_ports ((ssh 22)))
    (login_user vault) (source_checkout ../src/vault)|}

let parse_guest str = Guest_config.of_sexp (Sexplib.Sexp.List (Sexplib.Sexp.of_string_many str))

let () =
  let guest = parse_guest guest_fields in
  let vault = Guest_config.endpoint guest in
  check "guest: endpoint fields parsed" (vault.name = "vault" && vault.ip = "10.40.0.10");
  check "guest: operator port named"
    (vault.operator_ports = [ { port_name = "ssh"; port = 22 } ]);
  check "guest: login_user and source_checkout parsed"
    (guest.login_user = "vault" && guest.source_checkout = "../src/vault");
  check "guest: jail-only fields are unknown here"
    (raises_with ~needle:"unknown field hooks" (fun () ->
         parse_guest (guest_fields ^ "(hooks (bootstrap))")))

(* The lifecycle fields: both required, login_user a user name, and
   source_checkout a non-empty single-line path. *)
let network_fields =
  {|(name vault) (ip 10.40.0.10) (hostname vault.example)
    (tailnet_ports ((http 4010))) (operator_ports ((ssh 22)))|}

let () =
  check "guest: a missing login_user is refused"
    (raises_with ~needle:"missing field login_user" (fun () ->
         parse_guest (network_fields ^ "(source_checkout ../src/vault)")));
  check "guest: a missing source_checkout is refused"
    (raises_with ~needle:"missing field source_checkout" (fun () ->
         parse_guest (network_fields ^ "(login_user vault)")));
  List.iter (fun user ->
    check ("guest: invalid login_user refused: " ^ String.escaped user)
      (raises_with ~needle:"login_user" (fun () ->
           parse_guest (Printf.sprintf "%s (login_user %S) (source_checkout ../src)" network_fields user))))
    [ ""; "Vault"; "1fund"; "-vault"; "vault user"; "vault;id"; "vault\n" ];
  List.iter (fun user ->
    check ("guest: valid login_user accepted: " ^ user)
      ((parse_guest (Printf.sprintf "%s (login_user %s) (source_checkout ../src)" network_fields user))
         .login_user = user))
    [ "vault"; "_build"; "vault-2"; "a_b" ];
  List.iter (fun path ->
    check ("guest: invalid source_checkout refused: " ^ String.escaped path)
      (raises_with ~needle:"source_checkout" (fun () ->
           parse_guest (Printf.sprintf "%s (login_user vault) (source_checkout %S)" network_fields path))))
    [ ""; "../src/vault\n/etc" ];
  let endpoint = Guest_config.endpoint (parse_guest guest_fields) in
  check "guest: create refuses an invalid login_user with its variant"
    (Guest_config.create ~endpoint ~login_user:"Root" ~source_checkout:"x" ()
     = Error (Invalid_login_user ("vault", "Root")));
  check "guest: create refuses an empty source_checkout with its variant"
    (Guest_config.create ~endpoint ~login_user:"vault" ~source_checkout:"" ()
     = Error (Invalid_source_checkout ("vault", "")))

(* The workload: optional, and every field checked, since each ends up in a
   path, a unit name or a chown on the guest. *)
let () =
  let workload = {|(workload ((project tools/ledger) (target bin/main.exe)
                     (release ledger) (service_group ledger-svc)))|} in
  check "guest: no workload is a guest serai builds nothing in"
    ((parse_guest guest_fields).workload = None);
  check "guest: a workload is parsed"
    (match (parse_guest (guest_fields ^ workload)).workload with
     | Some w -> w.project = "tools/ledger" && w.target = "bin/main.exe"
                 && w.release = "ledger" && w.service_group = "ledger-svc"
     | None -> false);
  let field name value =
    let fields = [ "project", "tools/ledger"; "target", "bin/main.exe";
                   "release", "ledger"; "service_group", "ledger-svc" ] in
    Printf.sprintf "(workload (%s))" (String.concat " " (List.map (fun (k, v) ->
      Printf.sprintf "(%s %S)" k (if k = name then value else v)) fields)) in
  List.iter (fun (name, value) ->
    check (Printf.sprintf "guest: invalid workload %s refused: %s" name (String.escaped value))
      (raises_with ~needle:name (fun () -> parse_guest (guest_fields ^ field name value))))
    [ "project", ""; "project", "/abs"; "project", "a/../b"; "project", "a//b"; "project", "a/";
      "project", "./a"; "project", "a b"; "target", "bin/$(id).exe"; "target", "..";
      "release", ""; "release", "Ledger"; "release", "1ledger"; "release", "led/ger";
      "release", String.make 64 'a'; "service_group", "Svc"; "service_group", "a b" ];
  check "guest: an unknown workload field is refused"
    (raises_with ~needle:"unknown field" (fun () ->
       parse_guest (guest_fields ^ {|(workload ((project p) (target t.exe) (release r)
                                              (service_group g) (unit x)))|})));
  check "guest: workload refuses an invalid release with its variant"
    (Guest_config.workload ~guest:"g" ~project:"p" ~target:"t.exe" ~release:"R" ~service_group:"g"
     = Error (Invalid_workload ("g", "release", "R")))

let () =
  let edge = Edge_config.of_sexp (Sexplib.Sexp.of_string "((base_domain example.org) (operator ops))") in
  check "edge: base_domain parsed" (edge.base_domain = "example.org");
  check "edge: operator parsed" (edge.operator = "ops");
  check "edge: a missing operator is rejected"
    (raises_with ~needle:"operator" (fun () ->
         Edge_config.of_sexp (Sexplib.Sexp.of_string "((base_domain example.org))")));
  List.iter (fun operator ->
    check ("edge: invalid operator rejected: " ^ operator)
      (raises_with ~needle:"operator" (fun () ->
         Edge_config.of_sexp (Sexplib.Sexp.List
           [ List [ Atom "base_domain"; Atom "example.org" ]; List [ Atom "operator"; Atom operator ] ]))))
    [ ""; "Ops"; "ops@"; "a b"; "-ops"; String.make 64 'a' ];
  check "edge: unknown field rejected"
    (raises_with ~needle:"unknown field domain" (fun () ->
         Edge_config.of_sexp (Sexplib.Sexp.of_string "((domain example.org))")))

(* The example's files: ledger is the one guest, edge.sexp its domain, and
   apps + guests together pass validation. *)
let () =
  let layout = Repo_root.example () in
  let guests = Guest_config.load_all (Layout.guests_dir layout) in
  check "example guests: ledger only" (List.map Guest_config.name guests = [ "ledger" ]);
  (match guests with
  | [ guest ] ->
      let ledger = Guest_config.endpoint guest in
      check "example guests: ledger as declared"
        (ledger.ip = "10.20.0.10"
        && ledger.hostname = "ledger.example.org"
        && ledger.tailnet_ports = [ { port_name = "http"; port = 4020 } ]
        && ledger.operator_ports = [ { port_name = "ssh"; port = 22 } ]
        && guest.login_user = "ledger"
        && guest.source_checkout = "../src/ledger"
        && (match guest.workload with
            | Some w -> w.project = "service" && w.target = "bin/main.exe"
                        && w.release = "ledger" && w.service_group = "ledger-svc"
            | None -> false))
  | _ -> check "example guests: one guest" false);
  let guests = List.map Guest_config.endpoint guests in
  let edge = Edge_config.load (Layout.edge layout) in
  check "example edge.sexp: base_domain" (edge.base_domain = "example.org");
  check "example edge.sexp: operator" (edge.operator = "ops");
  let apps = App_config.load_all (Layout.apps_dir layout) in
  check "example apps + guests validate together"
    (Result.is_ok (Network_endpoint.validate_all (List.map App_config.endpoint apps @ guests)))

let () =
  List.iter (fun domain ->
    check ("edge: invalid base_domain rejected: " ^ domain)
      (raises_with ~needle:"domain" (fun () ->
         Edge_config.of_sexp (Sexplib.Sexp.List
           [ List [ Atom "base_domain"; Atom domain ]; List [ Atom "operator"; Atom "ops" ] ]))))
    [ ""; "*.example.org"; "example.org {"; "a..example"; "-bad.example" ]

let () = if !failures > 0 then exit 1
