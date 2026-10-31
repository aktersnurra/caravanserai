(* Dispatcher.revert against the process mock: what reaches the compute
   host, in which order, and what is refused before anything does. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let write path value = Out_channel.with_open_bin path (fun c -> output_string c value)
let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0
let mentions needle (r : Proc.request) = List.exists (contains needle) (r.prog :: r.args)

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let active = String.make 64 'a'
let previous = String.make 64 'b'

let app_sexp ~name ~ip ~migrate =
  Printf.sprintf
    "((name %s)(ip %s)(hostname %s.example.org)(tailnet_ports ((http 4020)))(operator_ports ())\
     (strategy freebsd_native_ocaml)(hooks (bootstrap deploy check))(extra_steps ())\
     (strategy_config ((ocaml_switch 5.5.1)(repo_path /src/%s)(zfs_dataset zroot/%s)(data_dir /var/db/%s)\
     (packages (sqlite3))(serve_args (serve))%s(check_path /health))))\n"
    name ip name name name name (if migrate then "(migrate (command migrate))" else "")

let () =
  let fixture = Filename.temp_dir "revert" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let layout = Repo_root.example () in
    let loaded = match Declaration.load ~layout with Ok d -> d | Error _ -> failwith "declaration fixture" in
    let load ~name ~ip ~migrate =
      let path = Filename.concat fixture (name ^ ".sexp") in
      write path (app_sexp ~name ~ip ~migrate);
      App_config.load path in
    let env ~confirm : Dispatcher.env = {
      layout; topology = Some (Test_declaration.topology ~jails:[ "meals"; "ledger" ] ~guests:[] ());
      compute_target = "compute"; edge_target = "edge"; remote_stage = "/tmp/serai-revert-test";
      ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl";
      config = [ load ~name:"meals" ~ip:"10.40.0.6" ~migrate:false;
                 load ~name:"ledger" ~ip:"10.40.0.7" ~migrate:true ];
      endpoints = loaded.endpoints; edge = loaded.edge; edge_ts_ip = None; edge_peer_match = None;
      caddy_force_build = false; confirm; operator = "test"; lock_token = "revert-test";
      jj_bin = "jj"; now_utc = (fun () -> "2026-10-31T00:00:00Z"); guests = [];
      ops_control_path = "/tmp/test-%C"; ssh_multiplex = false; source_checkout_override = None } in
    let probe = ref "" in
    let outputs (r : Proc.request) = if mentions "release-probe-active" r then !probe else "" in
    let revert ?(confirm = fun _ -> true) app =
      let mock = Proc.Mock.create ~outputs () in
      let result =
        try Ok (Proc.Mock.run mock (fun () -> Dispatcher.revert (env ~confirm) app))
        with Failure message -> Error message in
      result, Proc.Mock.calls mock in
    let answer ~previous =
      Printf.sprintf "release-probe-active: .infra-releases/meals/%s\nrelease-probe-source: none\n\
                      release-probe-previous: %s\n" active previous in

    let result, calls = revert "ledger" in
    check "an app that migrates is refused before anything runs"
      ((match result with Error m -> contains "migrate" m | Ok () -> false) && calls = []);

    probe := answer ~previous:"none";
    let result, calls = revert "meals" in
    check "no previous release on the host is refused"
      (match result with Error m -> contains "no previous release" m | Ok () -> false);
    check "after only the read-only probe"
      (List.for_all (fun r -> mentions "release-probe-active" r) calls && List.length calls = 1);

    probe := answer ~previous;
    let asked = ref [] in
    let result, calls = revert ~confirm:(fun q -> asked := q :: !asked; false) "meals" in
    check "declining the revert changes nothing"
      (Result.is_error result && not (List.exists (mentions "locks/infra") calls)
       && List.exists (contains previous) !asked);

    let result, calls = revert "meals" in
    if Result.is_error result then print_endline (match result with Error m -> m | Ok () -> "");
    check "a retained previous release is reverted to" (result = Ok ());
    let index predicate =
      let rec go i = function [] -> None | r :: rest -> if predicate r then Some i else go (i + 1) rest in
      go 0 calls in
    let last predicate =
      List.fold_left (fun (i, found) r -> (i + 1, if predicate r then Some i else found)) (0, None) calls |> snd in
    (* Each argument is quoted again inside doas sh -c '...'. *)
    let q value = "'\\''" ^ value ^ "'\\''" in
    let applies r =
      mentions ("artifact_apply.sh'\\'' " ^ String.concat " " [ q "revert"; q "meals"; q previous ]) r in
    (match index (mentions "locks/infra"), index applies, last (mentions "locks/infra") with
     | Some lock, Some apply, Some unlock ->
         check "the revert runs under the compute host lock" (lock < apply && apply < unlock)
     | _ -> check "the lock is taken, the revert applied and the lock released" false);
    check "the revert never migrates, probes no ABI and installs nothing"
      (List.exists (fun r -> applies r && mentions (String.concat " "
         [ q "http://10.40.0.6:4020/health"; q "-"; q "/usr/local/bin/meals"; q "-"; q "meals"; q "-" ]) r) calls);
    check "no release archive is transferred"
      (not (List.exists (fun (r : Proc.request) -> r.prog = "rsync" && mentions "release.tar" r) calls));
    check "the activation helpers are staged and their digests checked"
      (List.exists (fun (r : Proc.request) -> r.prog = "rsync" && mentions "artifact_activate.sh" r) calls
       && List.exists (fun r -> applies r && mentions "sha256 -q" r) calls);
    check "the edge is never touched"
      (not (List.exists (fun (r : Proc.request) ->
         List.exists (fun a -> String.starts_with ~prefix:"edge" a) r.args) calls)))
