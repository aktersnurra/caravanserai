open Infra

let check label condition =
  if condition then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)

let write path text =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel text)

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let () =
  let binary = Filename.concat (Sys.getcwd ()) "../bin/main.exe" in
  let fixture = Filename.temp_dir "source-cli" "fixture" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let source = Filename.concat fixture "source" in
    Proc.live (fun () -> Proc.run_checked "jj" ["git"; "init"; source]);
    write (Filename.concat source "release.txt") "committed\n";
    Proc.live (fun () -> Proc.run_checked "jj" ["-R"; source; "describe"; "-m"; "fixture"]);
    Proc.live (fun () -> Proc.run_checked "jj" ["-R"; source; "new"]);
    let _, commit = Proc.live (fun () -> Proc.capture "jj" ["--ignore-working-copy"; "-R"; source;
      "log"; "-r"; "@-"; "--no-graph"; "-T"; "commit_id ++ \"\\n\""]) in
    let commit = String.trim commit in
    let root = Filename.concat fixture "project" in
    List.iter (fun path -> Unix.mkdir path 0o700)
      [root; Filename.concat root "apps"; Filename.concat root "apps/example";
       Filename.concat root "apps/package"; Filename.concat root "compute";
       Filename.concat root "compute/apps"; Filename.concat root "compute/apps/_lib";
       Filename.concat root "guests"; Filename.concat root "edge"];
    write (Filename.concat root "pipelines.sexp") "()\n";
    write (Filename.concat root "serai.sexp")
      "((hosts ((compute (os freebsd)(ssh compute)(network (subnet 10.40.0.0/24) (gateway 10.40.0.1) (guest_bridge 10.40.0.254)))(edge (os linux)(ssh edge))))(jails ((example compute)(package compute)))(guests ())(edge edge)(proxy (example package)))\n";
    write (Filename.concat root "edge/edge.sexp") "((base_domain example.org) (operator ops))\n";
    write (Filename.concat root "apps/example/app.sexp")
      (Printf.sprintf "((name example)(ip 10.40.0.42)(hostname example.org)(tailnet_ports ((http 4000)))(operator_ports ())(strategy freebsd_native_elixir)(hooks (bootstrap deploy check))(extra_steps ())(strategy_config ((packages (sqlite3))(repo_path %s)(release_name example)(check_path /))))\n" source);
    write (Filename.concat root "apps/package/app.sexp")
      "((name package)(ip 10.40.0.43)(hostname package.example.org)(tailnet_ports ((http 4001)))(operator_ports ())(strategy freebsd_package)(hooks (bootstrap check))(extra_steps ())(strategy_config ((packages (garage))(check_path /))))\n";
    let run args =
      let original = Sys.getcwd () in
      Fun.protect ~finally:(fun () -> Sys.chdir original) (fun () ->
        Sys.chdir root;
        Proc.live (fun () -> Proc.capture binary args)) in
    let out = Filename.concat fixture "result" in
    let code, output = run ["artifact"; "source-stage"; "example"; "--revision"; commit; "--out"; out] in
    check "CLI stages a declared source commit" (code = 0 && Sys.file_exists (Filename.concat out "release.txt"));
    check "CLI reports full commit and destination" (String.contains output '\n' && String.contains output '/');
    let code, _ = run ["artifact"; "source-stage"; "example"; "--revision"; commit; "--out"; out] in
    check "CLI refuses existing destination" (code <> 0);
    let code, _ = run ["artifact"; "source-stage"; "absent"; "--revision"; commit; "--out"; (out ^ "-other")] in
    check "CLI refuses unknown workload" (code <> 0);
    let code, _ = run ["artifact"; "source-stage"; "package"; "--revision"; commit; "--out"; (out ^ "-package")] in
    check "CLI refuses package workloads" (code <> 0 && not (Sys.file_exists (out ^ "-package")));
    let code, _ = run ["artifact"; "source-stage"; "example"; "--out"; (out ^ "-other")] in
    check "CLI requires revision" (code <> 0))
