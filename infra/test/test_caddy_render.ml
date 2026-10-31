(* Caddy_render: placeholder derivation, substitution, the unknown-
   placeholder refusal, and file naming, against fixture template trees. *)
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

let demo : Network_endpoint.t =
  Test_declaration.endpoint ~name:"demo" ~ip:"10.0.0.7" ~hostname:"demo.example.org"
    ~tailnet_ports:[ { port_name = "http"; port = 4000 }; { port_name = "video"; port = 4002 } ]
    ~operator_ports:[ { port_name = "ssh"; port = 22 } ]

let render ?proxy ~base_domain ~template_dir endpoints =
  Caddy_render.render ?proxy ~edge:(Test_declaration.edge base_domain)
    ~root_template:(Filename.concat template_dir "Caddyfile") ~sites:(Filename.concat template_dir "sites")
    (Test_declaration.endpoints endpoints)

let () =
  let map = Caddy_render.placeholders ~edge:(Test_declaration.edge "example.org") (Test_declaration.endpoints [ demo ]) in
  check "placeholders: base domain"
    (List.assoc_opt "__BASE_DOMAIN__" map = Some "example.org");
  check "placeholders: ip and hostname"
    (List.assoc_opt "__DEMO_IP__" map = Some "10.0.0.7"
    && List.assoc_opt "__DEMO_HOSTNAME__" map = Some "demo.example.org");
  check "placeholders: one per named tailnet port"
    (List.assoc_opt "__DEMO_HTTP_PORT__" map = Some "4000"
    && List.assoc_opt "__DEMO_VIDEO_PORT__" map = Some "4002");
  check "placeholders: operator ports are not proxied, so not exposed"
    (List.assoc_opt "__DEMO_SSH_PORT__" map = None)

let () =
  check "substitute: every occurrence replaced"
    (Caddy_render.substitute ~placeholders:[ ("__A__", "x") ] "__A__ and __A__" = "x and x");
  check "find_unsubstituted: clean text" (Caddy_render.find_unsubstituted "a {$SECRET} b" = None);
  check "find_unsubstituted: names the leftover"
    (Caddy_render.find_unsubstituted "reverse_proxy __DEMO_JAIL_IP__:1" = Some "__DEMO_JAIL_IP__");
  check "find_unsubstituted: leftover followed by capitals or digits still caught"
    (Caddy_render.find_unsubstituted "__FOO__X" = Some "__FOO__"
    && Caddy_render.find_unsubstituted "x__A__1" = Some "__A__"
    && Caddy_render.find_unsubstituted "__DEMO_IP__A:1" = Some "__DEMO_IP__");
  check "find_unsubstituted: real Caddy syntax and bare underscores are not placeholders"
    (Caddy_render.find_unsubstituted "rewrite * {rp.header.X-Accel-Redirect}" = None
    && Caddy_render.find_unsubstituted "_____" = None);
  check "substitute: match at the very end, left-to-right like sed"
    (Caddy_render.substitute ~placeholders:[ ("__A__", "x") ] "y__A__" = "yx"
    && Caddy_render.substitute ~placeholders:[ ("aa", "b") ] "aaa" = "ba");
  check "substitute: an empty pattern is a caller bug, not a hang"
    (match Caddy_render.substitute ~placeholders:[ ("", "x") ] "abc" with
    | _ -> false
    | exception Invalid_argument _ -> true);
  check "find_unsubstituted: digit-bearing placeholder caught"
    (Caddy_render.find_unsubstituted "x:__GARAGE_S3_PORT__" = Some "__GARAGE_S3_PORT__")

let () =
  match
    render ~base_domain:"example.org"
      ~template_dir:"fixtures/edge_root/edge/caddy" [ demo ]
  with
  | Error msg -> check ("render: fixture tree renders: " ^ msg) false
  | Ok files ->
      check "render: Caddyfile first, then conf.d in sorted order, .template dropped"
        (List.map fst files = [ "Caddyfile"; "conf.d/10-main.caddy"; "conf.d/40-demo.caddy" ]);
      check "render: root Caddyfile substituted"
        (List.assoc "Caddyfile" files = "{\n    email ops@example.org\n}\n\nimport conf.d/*.caddy\n");
      check "render: vhost substituted"
        (List.assoc "conf.d/40-demo.caddy" files
        = "demo.example.org {\n\
          \    reverse_proxy 10.0.0.7:4000 {\n\
          \        header_up Host {host}\n\
          \    }\n\
          \    reverse_proxy /video/* 10.0.0.7:4002\n\
           }\n")

let () =
  match
    render ~base_domain:"example.org" ~template_dir:"fixtures/caddy_unknown"
      [ demo ]
  with
  | Ok _ -> check "render: unknown placeholder refused" false
  | Error msg ->
      check "render: unknown placeholder refused, naming file and placeholder"
        (contains ~needle:"conf.d/40-demo.caddy" msg && contains ~needle:"__DEMO_JAIL_IP__" msg)

let () =
  match render ~base_domain:"example.org" ~template_dir:"fixtures/absent" [ demo ] with
  | Ok _ -> check "render: missing template tree is an Error, not an exception" false
  | Error msg ->
      check "render: missing template tree is an Error, not an exception"
        (contains ~needle:"missing Caddy template tree" msg)

(* Every proxied workload has exactly one site. *)
let () =
  let other : Network_endpoint.t =
    Test_declaration.endpoint ~name:"other" ~ip:"10.0.0.8" ~hostname:"other.example.org"
      ~tailnet_ports:[ { port_name = "http"; port = 4010 } ] ~operator_ports:[] in
  let render_proxy proxy =
    render ~proxy ~base_domain:"example.org" ~template_dir:"fixtures/edge_root/edge/caddy" [ demo; other ] in
  check "render: a proxied workload with its template renders"
    (Result.is_ok (render_proxy [ "demo" ]));
  (match render_proxy [ "demo"; "other" ] with
   | Ok _ -> check "render: a proxied workload without a template is refused" false
   | Error msg ->
       check "render: a proxied workload without a template is refused, by name"
         (contains ~needle:"other is proxied but no template" msg));
  let tree = Filename.temp_dir "infra-caddy-two-sites" "" in
  let write path contents =
    Out_channel.with_open_bin (Filename.concat tree path) (fun out -> output_string out contents) in
  Sys.mkdir (Filename.concat tree "sites") 0o700;
  write "Caddyfile" "import conf.d/*.caddy\n";
  write "sites/40-demo.caddy.template" "__DEMO_HOSTNAME__ {\n}\n";
  write "sites/41-demo.caddy.template" "__DEMO_HOSTNAME__ {\n}\n";
  match render ~proxy:[ "demo" ] ~base_domain:"example.org" ~template_dir:tree [ demo ] with
  | Ok _ -> check "render: a workload in two templates is refused" false
  | Error msg ->
      check "render: a workload in two templates is refused, naming both"
        (contains ~needle:"40-demo.caddy.template" msg && contains ~needle:"41-demo.caddy.template" msg)

let () = if !failures > 0 then exit 1
