open Serai

(* Deliberately not a serai CLI command or a dune test. Only an operator at a
   real terminal can opt in to a single disposable declared Phoenix build test. *)
let run () =
  if Sys.getenv_opt "SERAI_ARTIFACT_HOST_TEST" <> Some "1" then
    failwith "host test: explicit opt-in required (SERAI_ARTIFACT_HOST_TEST=1)";
  if not (Unix.isatty Unix.stdin) then
    failwith "host test: real terminal required for SSH/security-key or doas prompts";
  let usage =
    "usage: host_artifact_build_candidate.exe --app NAME --revision COMMIT --ip IP --base LOCAL_BASE_TXZ --sha256 BASE_SHA256 --out NEW_DIR" in
  let app_name, arguments = match Array.to_list Sys.argv with
    | _ :: "--app" :: name :: rest -> name, rest
    | _ -> failwith usage in
  let revision, ip, base_archive, base_sha256, out =
    match arguments with
    | [ "--revision"; revision; "--ip"; ip; "--base"; base_archive;
        "--sha256"; base_sha256; "--out"; out ] ->
        revision, ip, base_archive, base_sha256, out
    | _ -> failwith usage in
  (* The configuration it is run in, on the engine above it, as serai finds them. *)
  let installed = Filename.concat (Filename.dirname (Filename.dirname Sys.executable_name)) "share/caravanserai" in
  let layout = match Layout.discover ~from:(Sys.getcwd ()) ~installed with
    | Ok layout -> layout | Error message -> failwith message in
  let declaration = match Declaration.load ~layout with
    | Ok value -> value | Error error -> failwith (Declaration.error_message error) in
  Printf.printf
    "Disposable %s build ONLY (no install/activation).\nCommit: %s\nBuilder IP: %s\nBase archive: %s\nCandidate output: %s\nType 'build candidate' to continue: %!"
    app_name revision ip base_archive out;
  (match In_channel.input_line stdin with
   | Some "build candidate" -> ()
   | _ -> failwith "host test: operator did not confirm");
  Random.self_init ();
  let now_utc () =
    let t = Unix.gmtime (Unix.time ()) in
    Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ" (t.tm_year + 1900) (t.tm_mon + 1)
      t.tm_mday t.tm_hour t.tm_min t.tm_sec in
  let env : Dispatcher.env = {
    layout; topology = declaration.topology;
    compute_target = "compute"; edge_target = "edge";
    remote_stage = "/tmp/serai-stage";
    ssh_bin = "ssh"; rsync_bin = "rsync"; curl_bin = "curl";
    config = declaration.apps; endpoints = declaration.endpoints; edge = declaration.edge;
    edge_ts_ip = None; edge_peer_match = None; caddy_force_build = false;
    confirm = (fun _ -> failwith "host test: unexpected confirmation request");
    operator = Printf.sprintf "%s@%s"
      (Option.value (Sys.getenv_opt "USER") ~default:"unknown") (Unix.gethostname ());
    lock_token = Printf.sprintf "host-%d-%08x" (Unix.getpid ()) (Random.bits ());
    jj_bin = "jj"; now_utc; guests = declaration.guests;
    ops_control_path = "/tmp/ops-ssh-%C"; ssh_multiplex = false;
    source_checkout_override = None;
  } in
  let candidate = Proc.live (fun () -> Dispatcher.artifact_build_candidate env app_name
    ~revision ~ip ~base_archive ~base_sha256 ~out) in
  Printf.printf "Candidate only: %s\nsource_commit=%s\nsource_inventory_sha256=%s\ntarget_abi=%s\nrecipe_sha256=%s\narchive_sha256=%s\n%!"
    out candidate.source_commit candidate.source_inventory_sha256 candidate.target_abi
    candidate.recipe_sha256 candidate.archive_sha256

let () =
  Sys.catch_break true;
  try run () with
  | Sys.Break ->
      Printf.eprintf "host test: interrupted; check the disposable jail and lock\n%!";
      exit 130
  | Fun.Finally_raised _ ->
      Printf.eprintf "host test: interrupted during cleanup; check the disposable jail and lock\n%!";
      exit 130
  | Failure message ->
      Printf.eprintf "%s\n%!" message;
      exit 1
