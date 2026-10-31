(* Declaration.load and Validation.render_all: the offline render of the
   whole declaration behind `infra validate`, against the example and
   against small temp roots built per case. *)
open Infra

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

let write_file path contents =
  Out_channel.with_open_bin path (fun oc -> output_string oc contents)

let demo : Network_endpoint.t =
  Test_declaration.endpoint ~name:"demo" ~ip:"10.0.0.7" ~hostname:"demo.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4000 } ] ~operator_ports:[]

(* A root whose edge/caddy is the given fixture template tree. *)
let root_with_caddy fixture =
  let root = Filename.temp_dir "infra-validation" "" in
  Sys.mkdir (Filename.concat root "edge") 0o700;
  Unix.symlink
    (Filename.concat (Sys.getcwd ()) fixture)
    (Filename.concat root "edge/caddy");
  root

let declaration_of ~root endpoints : Declaration.t =
  match Declaration.create ~layout:(Layout.v ~engine:root ~config:root) ~apps:[] ~guests:(List.map Test_declaration.guest endpoints) ~edge:(Test_declaration.edge "example.org") with
  | Ok declaration -> declaration
  | Error error -> failwith (Declaration.error_message error)

(* (a) the example configuration renders, one jail script per app *)
let () =
  let layout = Repo_root.example () in
  match Declaration.load ~layout with
  | Error error -> check ("example: loads: " ^ Declaration.error_message error) false
  | Ok declaration -> (
      match Validation.render_all declaration with
      | Error msg -> check ("example: renders: " ^ msg) false
      | Ok files ->
          let paths = List.map fst files in
          check "example: ACL, pf rules and root Caddyfile rendered"
            (List.for_all
               (fun path -> List.mem path paths)
               [ "acls.hujson"; "service-rules.conf"; "caddy/Caddyfile" ]);
          check "example: every Caddy template rendered under caddy/conf.d"
            (List.for_all
               (fun template ->
                 List.mem ("caddy/conf.d/" ^ Filename.chop_suffix template ".template") paths)
               (Caddy_render.template_names (Layout.caddy_sites layout)));
          check "example: one jail script per app"
            (declaration.apps <> []
            && List.for_all
                 (fun (app : App_config.t) ->
                   List.mem ("jails/" ^ app.endpoint.name ^ ".sh") paths)
                 declaration.apps);
          check "example: guests are not apps, so get no jail script"
            (declaration.guests <> []
            && List.for_all
                 (fun guest ->
                   not (List.mem ("jails/" ^ Guest_config.name guest ^ ".sh") paths))
                 declaration.guests))

(* (b) an unknown Caddy placeholder names its file *)
let () =
  let root = root_with_caddy "fixtures/caddy_unknown" in
  match Validation.render_all (declaration_of ~root [ demo ]) with
  | Ok _ -> check "unknown placeholder: refused" false
  | Error msg ->
      check "unknown placeholder: refused, naming the file"
        (contains ~needle:"conf.d/40-demo.caddy" msg && contains ~needle:"__DEMO_JAIL_IP__" msg)

(* (c) nothing reachable is an error, not an empty policy *)
let () =
  let root = root_with_caddy "fixtures/edge_root/edge/caddy" in
  match Validation.render_all (declaration_of ~root [ Test_declaration.endpoint ~name:demo.name ~ip:demo.ip ~hostname:demo.hostname
          ~tailnet_ports:[] ~operator_ports:[] ]) with
  | Ok _ -> check "no tailnet ports: refused" false
  | Error msg -> check "no tailnet ports: refused" (contains ~needle:"tailnet_ports" msg)

(* (d) a broken app.sexp is an Error naming its path, not an exception *)
let () =
  let root = Filename.temp_dir "infra-validation" "" in
  List.iter
    (fun dir -> Sys.mkdir (Filename.concat root dir) 0o700)
    [ "apps"; "apps/broken"; "guests"; "edge" ];
  write_file (Filename.concat root "edge/edge.sexp") "((base_domain example.org) (operator ops))\n";
  let app_sexp = Filename.concat root "apps/broken/app.sexp" in
  write_file app_sexp "((name broken) (bogus field))\n";
  (match Declaration.load ~layout:(Layout.v ~engine:root ~config:root) with
  | Ok _ -> check "broken app.sexp: refused" false
  | Error msg -> check "broken app.sexp: refused, naming its path" (contains ~needle:app_sexp (Declaration.error_message msg)));
  write_file app_sexp "((name broken\n";
  match Declaration.load ~layout:(Layout.v ~engine:root ~config:root) with
  | Ok _ -> check "unparseable app.sexp: refused" false
  | Error msg ->
      check "unparseable app.sexp: refused, naming its path" (contains ~needle:app_sexp (Declaration.error_message msg))

(* (e) the summary line *)
let () =
  let root = root_with_caddy "fixtures/edge_root/edge/caddy" in
  let declaration = declaration_of ~root [ demo ] in
  let files =
    [
      ("acls.hujson", "");
      ("service-rules.conf", "");
      ("caddy/Caddyfile", "");
      ("caddy/conf.d/40-demo.caddy", "");
      ("jails/a.sh", "");
      ("jails/b.sh", "");
    ]
  in
  check "summary: counts apps, guests, caddy files and jail scripts"
    (Validation.summary declaration files = "ok: 0 apps, 1 guest, 2 caddy files, 2 jail scripts");
  check "summary: plural guests"
    (Validation.summary (declaration_of ~root [ demo;
        Test_declaration.endpoint ~name:"other" ~ip:"10.0.0.8" ~hostname:"other.example.org"
          ~tailnet_ports:[] ~operator_ports:[] ]) files
    = "ok: 0 apps, 2 guests, 2 caddy files, 2 jail scripts")

(* (f) a render error names its file, but Ctrl-C is not a render error: it
   propagates so main exits 130 as it does elsewhere *)
let () =
  check "catch_render: a failure is an Error naming the file"
    (Validation.catch_render "jails/demo.sh" (fun () -> failwith "boom")
    = Error "jails/demo.sh: boom");
  check "catch_render: Sys.Break is re-raised, not an Error"
    (match Validation.catch_render "jails/demo.sh" (fun () -> raise Sys.Break) with
    | _ -> false
    | exception Sys.Break -> true)

let () = if !failures > 0 then exit 1
