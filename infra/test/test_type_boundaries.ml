let () =
  let includes = Filename.concat (Sys.getcwd ()) "../lib/.infra.objs/byte" in
  let directory = Filename.temp_dir "infra-type-boundaries" "" in
  let failures = ref 0 in
  let check name condition =
    Printf.printf "%s - %s\n%!" (if condition then "ok  " else "FAIL") name;
    if not condition then incr failures
  in
  Fun.protect ~finally:(fun () -> Test_declaration.remove_tree directory) (fun () ->
    let compile name source =
      let path = Filename.concat directory (name ^ ".ml") in
      Out_channel.with_open_bin path (fun channel -> output_string channel source);
      let log = Filename.concat directory (name ^ ".log") in
      let command = String.concat " " (List.map Filename.quote
        [ "ocamlfind"; "ocamlc"; "-package"; "base,sexplib,unix"; "-I"; includes; "-c"; path ])
        ^ " >" ^ Filename.quote log ^ " 2>&1" in
      let code = Sys.command command in
      code, In_channel.with_open_bin log In_channel.input_all
    in
    let code, log = compile "valid" {|let render () =
      match Infra.Network_endpoint.create ~name:"demo" ~ip:"10.0.0.1"
        ~hostname:"demo.example.org" ~tailnet_ports:[] ~operator_ports:[] with
      | Error _ -> ()
      | Ok endpoint -> match Infra.Network_endpoint.validate_all [endpoint] with
        | Error _ -> () | Ok endpoints -> ignore (Infra.Pf_rules.render endpoints)
    let app endpoint =
      match Infra.Strategy_config.parse ~strategy:(Sexplib.Sexp.Atom "freebsd_native_elixir")
        ~config:(Sexplib.Sexp.of_string "((packages (sqlite3)) (repo_path /r) (release_name example) (check_path /))") with
      | Error _ -> ()
      | Ok strategy ->
          match Infra.App_config.create ~endpoint ~strategy ~hooks:[] ~extra_steps:[ "step.sh" ] () with
          | Error _ -> ()
          | Ok app -> ignore (Infra.Strategy.render_jail_script app, Infra.Jail_test.render app ~ip:"10.40.0.200")
    let guest endpoint =
      match Infra.Guest_config.create ~endpoint ~login_user:"vault" ~source_checkout:"../src/vault" () with
      | Error _ -> () | Ok guest -> ignore (Infra.Guest_config.endpoint guest)
    let destroy () =
      match Infra.Jail_test.validate_destroy_target ~name:"mealstest" ~dataset:"zroot/mealstest" () with
      | Error _ -> () | Ok target -> ignore (Infra.Jail_test.destroy_script target)
    |} in
    check ("public construction compiles: " ^ log) (code = 0);
    List.iter (fun (name, source, expected) ->
      let code, log = compile name source in
      let contains =
        let rec scan i = i + String.length expected <= String.length log
          && (String.sub log i (String.length expected) = expected || scan (i + 1)) in scan 0 in
      check ("compiler rejects " ^ name) (code <> 0 && contains))
      [ "forged_endpoint", {|let value : Infra.Network_endpoint.t =
          { name="demo"; ip="invalid"; hostname="bad"; tailnet_ports=[]; operator_ports=[] }|}, "private";
        "forged_collection", {|let value : Infra.Network_endpoint.validated = []|}, "Network_endpoint.validated";
        "raw_renderer_input", {|let render (endpoints : Infra.Network_endpoint.t list) =
          Infra.Pf_rules.render endpoints|}, "Network_endpoint.validated";
        "forged_declaration", {|let make endpoints edge : Infra.Declaration.t =
          { layout=Infra.Layout.v ~engine:"." ~config:"."; apps=[]; guests=[]; endpoints; edge }|}, "private";
        "unparsed_strategy", {|let make endpoint = Infra.App_config.create ~endpoint
          ~strategy:(Sexplib.Sexp.Atom "typo") ~hooks:[] ~extra_steps:[] ()|}, "Strategy_config.t";
        "forged_app", {|let make endpoint strategy : Infra.App_config.t =
          { endpoint; strategy; hooks=[]; extra_steps=[ "../x.sh" ] }|}, "private";
        "app_record_update", {|let change (app : Infra.App_config.t) = { app with extra_steps = [ "../x.sh" ] }|},
          "private";
        "endpoint_record_update", {|let change (endpoint : Infra.Network_endpoint.t) =
          { endpoint with ip = "0.0.0.0/0" }|}, "private";
        "forged_strategy", {|let value = Infra.Strategy_config.Freebsd_native_elixir
          { packages=[]; repo_path="/r"; release_name="example"; check_path="/" }|}, "private";
        "unchecked_app", {|let make endpoint strategy : Infra.App_config.t =
          Infra.App_config.create ~endpoint ~strategy ~hooks:[] ~extra_steps:[ "../x.sh" ] ()|}, "result";
        "strategy_reparse", {|let parse app = Infra.Strategy.of_app_config app|}, "of_app_config";
        "forged_destroy_target", {|let script = Infra.Jail_test.destroy_script "meals"|},
          "Jail_test.destroy_target";
        "unchecked_destroy_target", {|let script =
          Infra.Jail_test.destroy_script ~name:"meals" ()|}, "Jail_test.destroy_target";
        "jail_test_internals", {|let ok = Infra.Jail_test.is_test_name "meals"|}, "is_test_name";
        "forged_domain", {|let value : Infra.Domain_name.t = "bad {"|}, "Domain_name.t";
        "forged_edge", {|let value : Infra.Edge_config.t = { base_domain="bad {"; operator="ops" }|}, "private";
        "forged_guest", {|let make endpoint : Infra.Guest_config.t =
          { endpoint; login_user="root; id"; source_checkout=""; workload=None }|}, "private";
        "guest_record_update", {|let change (guest : Infra.Guest_config.t) =
          { guest with login_user = "root; id" }|}, "private";
        "unchecked_guest", {|let make endpoint : Infra.Guest_config.t =
          Infra.Guest_config.create ~endpoint ~login_user:"Root" ~source_checkout:"" ()|}, "result" ]);
  if !failures > 0 then exit 1
