(* App_scaffold against a fixture repository: the addresses, files and
   topology edit serai new writes, and what it refuses. *)
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

let write_file path contents =
  Out_channel.with_open_bin path (fun out -> output_string out contents)

let topology_text =
  "; Placement. A comment that must survive the edit.\n\
   ((hosts\n\
  \  ((compute (os freebsd) (ssh compute) (network (subnet 10.40.0.0/24) (gateway 10.40.0.1) (guest_bridge 10.40.0.254))\n\
  \    (build (ip 10.40.0.11)\n\
  \     (base (url https://example.org/base.txz)\n\
  \      (sha256 3768988b151c20f965679062b065c63a977d6bbb9f47fd83695ec2c40790c18f))))\n\
  \   (edge (os linux) (ssh edge))))\n\
  \ (jails\n\
  \  ((web compute)\n\
  \   (ledger compute)))\n\
  \ (guests ())\n\
  \ (edge edge)\n\
  \ (proxy (web ledger)))\n"

let fixture_root () =
  let root = Filename.temp_dir "serai-app-scaffold" "" in
  List.iter (fun dir -> Sys.mkdir (Filename.concat root dir) 0o700)
    [ "apps"; "apps/web"; "apps/ledger"; "guests"; "edge" ];
  write_file (Filename.concat root "serai.sexp") topology_text;
  write_file (Filename.concat root "edge/edge.sexp") "((base_domain example.org) (operator ops))\n";
  write_file (Filename.concat root "apps/web/app.sexp")
    "((name web) (ip 10.40.0.2) (hostname web.example.org) (tailnet_ports ((http 4000)))\n\
    \ (operator_ports ()) (strategy freebsd_native_elixir) (hooks (bootstrap check)) (extra_steps ())\n\
    \ (strategy_config ((packages (sqlite3)) (repo_path /r) (release_name web) (check_path /))))\n";
  write_file (Filename.concat root "apps/ledger/app.sexp")
    "((name ledger) (ip 10.40.0.3) (hostname ledger.example.org) (tailnet_ports ((http 4020)))\n\
    \ (operator_ports ()) (strategy freebsd_native_ocaml) (hooks (bootstrap check)) (extra_steps ())\n\
    \ (strategy_config ((ocaml_switch 5.5.1) (repo_path /l) (source (git git@example.org:ledger.git))\n\
    \  (opam_repository (git https://github.com/ocaml/opam-repository.git)\n\
    \   (commit 4b3c9153f191701aa5da18d2f5ab5da796ce2133))\n\
    \  (zfs_dataset zroot/ledger) (data_dir /var/db/ledger) (packages (ocaml-opam))\n\
    \  (serve_args (serve)) (migrate none) (check_path /health))))\n";
  root

let declaration root =
  match Declaration.load ~layout:(Layout.v ~engine:root ~config:root) with
  | Ok declaration -> declaration
  | Error error -> failwith (Declaration.error_message error)

let templates = [ "10-main.caddy.template"; "40-web.caddy.template"; "41-ledger.caddy.template" ]

let request ?hostname ?(name = "hello") kind =
  App_scaffold.{ name; kind; repo_path = "/src/hello"; source = "git@example.org:hello.git"; hostname }

let phoenix_kind = App_scaffold.Phoenix { release_name = "hello"; migrate = Some "Hello.Release.migrate" }

let file (plan : App_scaffold.t) path =
  List.find_map (fun (f : App_scaffold.file) -> if f.path = path then Some f.contents else None) plan.files

let () =
  let root = fixture_root () in
  let d = declaration root in
  match App_scaffold.plan d ~topology:topology_text ~templates (request phoenix_kind) with
  | Error message -> check ("phoenix: plans: " ^ message) false
  | Ok plan ->
      check "phoenix: the lowest free jail address" (plan.ip = "10.40.0.4");
      check "phoenix: the next http port in steps of 10" (plan.port = 4030);
      check "phoenix: the hostname defaults under the base domain" (plan.hostname = "hello.example.org");
      check "phoenix: app.sexp, env.template and the next Caddy site"
        (List.map (fun (f : App_scaffold.file) -> f.path) plan.files
         = [ "apps/hello/app.sexp"; "apps/hello/env.template"; "edge/caddy/sites/42-hello.caddy.template" ]);
      let app = Option.get (file plan "apps/hello/app.sexp") in
      check "phoenix: the release, its migrate and the source"
        (contains ~needle:"(release_name hello)" app
         && contains ~needle:"(migrate (release_eval Hello.Release.migrate))" app
         && contains ~needle:"(source (git git@example.org:hello.git))" app);
      let env = Option.get (file plan "apps/hello/env.template") in
      check "phoenix: env.template carries the port, host and secrets to fill"
        (contains ~needle:"PORT=4030" env && contains ~needle:"PHX_HOST=hello.example.org" env
         && contains ~needle:"SECRET_KEY_BASE=REPLACE_ME" env
         && contains ~needle:"DATABASE_PATH=/var/db/hello/hello.db" env);
      let site = Option.get (file plan "edge/caddy/sites/42-hello.caddy.template") in
      check "phoenix: the site proxies the app's placeholders"
        (contains ~needle:"__HELLO_HOSTNAME__ {\n    import access_log" site
         && contains ~needle:"reverse_proxy __HELLO_IP__:__HELLO_HTTP_PORT__" site);
      check "topology: placed beside the other jails and proxied, comments kept"
        (contains ~needle:"((web compute)\n   (ledger compute)\n   (hello compute)))" plan.topology
         && contains ~needle:"(proxy (web ledger hello)))" plan.topology
         && contains ~needle:"; Placement. A comment that must survive the edit." plan.topology)

let () =
  let root = fixture_root () in
  let d = declaration root in
  match App_scaffold.plan d ~topology:topology_text ~templates (request App_scaffold.Ocaml) with
  | Error message -> check ("ocaml: plans: " ^ message) false
  | Ok plan ->
      let app = Option.get (file plan "apps/hello/app.sexp") in
      check "ocaml: the other OCaml apps' switch and opam pin"
        (contains ~needle:"(ocaml_switch 5.5.1)" app
         && contains ~needle:"(commit 4b3c9153f191701aa5da18d2f5ab5da796ce2133)" app);
      check "ocaml: its own dataset and data dir, checked at /health"
        (contains ~needle:"(zfs_dataset zroot/hello)" app && contains ~needle:"(data_dir /var/db/hello)" app
         && contains ~needle:"(check_path /health)" app)

let () =
  let root = fixture_root () in
  let d = declaration root in
  let refused ?hostname ~name ~needle label =
    match App_scaffold.plan d ~topology:topology_text ~templates (request ?hostname ~name phoenix_kind) with
    | Ok _ -> check ("refused: " ^ label) false
    | Error message -> check ("refused: " ^ label) (contains ~needle message) in
  refused ~name:"web" ~needle:"already declared" "a declared name";
  refused ~name:"webtest" ~needle:"test jails" "a test jail's name";
  refused ~name:"Hello" ~needle:"[a-z0-9]+" "a name that is not [a-z0-9]+";
  refused ~name:"hello" ~hostname:"web.example.org" ~needle:"duplicate hostname" "another app's hostname";
  match App_scaffold.plan d ~topology:topology_text
          ~templates:(templates @ List.init 8 (fun i -> Printf.sprintf "%d-x.caddy.template" (42 + i)))
          (request phoenix_kind) with
  | Ok _ -> check "refused: no free Caddy site number" false
  | Error message -> check "refused: no free Caddy site number" (contains ~needle:"no free site number" message)

let () =
  let mix_exs = "defmodule Hello.MixProject do\n  def project do\n    [\n      app: :hello_web,\n      version: \"0.1.0\"]\n" in
  check "phoenix: mix.exs names the release; release.ex its migrate"
    (App_scaffold.phoenix ~mix_exs ~release_ex:(function
       | "hello_web" -> Some "defmodule HelloWeb.Release do\n  def migrate do\n"
       | _ -> None)
     = Ok (App_scaffold.Phoenix { release_name = "hello_web"; migrate = Some "HelloWeb.Release.migrate" }));
  check "phoenix: no release.ex means no migrate"
    (App_scaffold.phoenix ~mix_exs ~release_ex:(fun _ -> None)
     = Ok (App_scaffold.Phoenix { release_name = "hello_web"; migrate = None }));
  check "phoenix: a mix.exs without app: is refused"
    (Result.is_error (App_scaffold.phoenix ~mix_exs:"defmodule X do end" ~release_ex:(fun _ -> None)))

let () = if !failures > 0 then exit 1
