(* Layout: every engine path is under the engine root and every
   configuration path under the configuration root. *)
open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let under root path = String.starts_with ~prefix:(root ^ "/") path

let () =
  let layout = Layout.v ~engine:"/engine" ~config:"/config" in
  check "roots are kept" (Layout.engine layout = "/engine" && Layout.config layout = "/config");
  List.iter (fun (name, path) -> check ("configuration: " ^ name) (under "/config" path))
    [ ("topology", Layout.topology layout);
      ("pipelines", Layout.pipelines layout);
      ("logging", Layout.logging layout);
      ("apps", Layout.apps_dir layout);
      ("app", Layout.app_dir layout "meals");
      ("guests", Layout.guests_dir layout);
      ("edge", Layout.edge layout);
      ("caddy root template", Layout.caddy_root_template layout);
      ("caddy sites", Layout.caddy_sites layout);
      ("relative checkout", Layout.config_path layout "../meals") ];
  List.iter (fun (name, path) -> check ("engine: " ^ name) (under "/engine" path))
    [ ("lib", Layout.lib_dir layout);
      ("lib file", Layout.lib_file layout "check.sh");
      ("pf rules", Layout.pf_rules layout) ];
  check "an app's directory is named for it"
    (Filename.basename (Layout.app_dir layout "meals") = "meals");
  check "an absolute checkout is unchanged" (Layout.config_path layout "/src/meals" = "/src/meals");
  check "the edge stage takes the engine's scripts and the configuration's edge"
    (match Layout.edge_sources layout with
     | [ engine; config ] -> under "/engine" engine && under "/config" config
     | _ -> false);
  check "the configuration's layout"
    (List.map (fun path -> String.sub path 8 (String.length path - 8))
       [ Layout.topology layout; Layout.pipelines layout; Layout.logging layout;
         Layout.app_dir layout "meals"; Layout.guests_dir layout; Layout.edge layout;
         Layout.caddy_root_template layout; Layout.caddy_sites layout ]
     = [ "serai.sexp"; "pipelines.sexp"; "logging.sexp"; "apps/meals"; "guests";
         "edge/edge.sexp"; "edge/caddy/Caddyfile"; "edge/caddy/sites" ]);
  check "relative paths name the same files"
    (Filename.concat (Layout.config layout) Layout.Relative.topology = Layout.topology layout
     && Filename.concat (Layout.config layout) (Layout.Relative.app_file ~app:"meals" "app.sexp")
        = Filename.concat (Layout.app_dir layout "meals") "app.sexp"
     && Filename.concat (Layout.config layout) (Layout.Relative.caddy_site "44-meals.caddy.template")
        = Filename.concat (Layout.caddy_sites layout) "44-meals.caddy.template");
  let same = Layout.v ~engine:"/repo" ~config:"/repo" in
  check "one repository: the engine's edge/ is the configuration's edge/"
    (Layout.edge_sources same = [ "/repo/edge"; "/repo/edge" ])

(* Discovery: the configuration is the nearest directory holding
   serai.sexp, the engine the nearest holding compute/apps/_lib, else
   the installed one. *)
let () =
  let root = Repo_root.find () in
  let nowhere = Filename.concat (Filename.get_temp_dir_name ()) "no-such-share" in
  let found from = Layout.discover ~from ~installed:nowhere in
  let example = Filename.concat root "example" in
  check "from inside example/, its configuration with this repository's engine"
    (match found (Filename.concat example "apps/hello") with
     | Ok layout -> Layout.engine layout = root && Layout.config layout = example
     | Error _ -> false);
  check "outside any configuration, an error"
    (match found "/" with Error _ -> true | Ok _ -> false);
  (* A configuration on its own, with no engine checkout above it. *)
  let scratch = Filename.temp_dir "layout-discover" "" in
  let mkdirs path = ignore (Sys.command ("mkdir -p " ^ Filename.quote (Filename.concat scratch path))) in
  List.iter mkdirs [ "config/apps/web"; "share/caravanserai/compute/apps/_lib" ];
  Out_channel.with_open_bin (Filename.concat scratch "config/serai.sexp") (fun oc -> output_string oc "()\n");
  let config = Filename.concat scratch "config" and share = Filename.concat scratch "share/caravanserai" in
  check "a configuration alone takes the installed engine"
    (match Layout.discover ~from:(Filename.concat config "apps/web") ~installed:share with
     | Ok layout -> Layout.engine layout = share && Layout.config layout = config
     | Error _ -> false);
  check "without an installed engine either, an error"
    (match Layout.discover ~from:config ~installed:nowhere with Error _ -> true | Ok _ -> false);
  mkdirs "config/compute/apps/_lib";
  check "a configuration that holds compute/apps/_lib is its own engine"
    (match Layout.discover ~from:config ~installed:share with
     | Ok layout -> Layout.engine layout = config && Layout.config layout = config
     | Error _ -> false);
  check "an engine checkout above the configuration wins over the installed one"
    (match Layout.discover ~from:(Filename.concat root "example") ~installed:share with
     | Ok layout -> Layout.engine layout = root
     | Error _ -> false);
  Test_declaration.remove_tree scratch

let () = if !failures > 0 then exit 1
