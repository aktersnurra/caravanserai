(* Release_probe: its script run by /bin/sh against a jail tree on disk, and
   check against the answers it gives and ones it must refuse. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let write path value = Out_channel.with_open_bin path (fun c -> output_string c value)
let rec mkdir_p path =
  if not (Sys.file_exists path) then begin
    mkdir_p (Filename.dirname path);
    Unix.mkdir path 0o755
  end

let active = String.make 64 'a'
let previous = String.make 64 'b'
let commit = String.make 40 'c'

(* The script as the compute host runs it, with JAIL_ROOT standing in for
   /jails/<app> the way the artifact scripts allow. *)
let probe ~root =
  let script = Filename.concat root "probe.sh" in
  write script (Release_probe.script ~app:"demo");
  match
    Proc.live (fun () ->
        Proc.capture ~extra_env:[ ("JAIL_ROOT", Filename.concat root "jail") ] "sh" [ script ])
  with
  | 0, output -> output
  | code, _ -> failwith (Printf.sprintf "probe script exited %d" code)

let () =
  let root = Filename.temp_dir "release-probe" "test" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let jail = Filename.concat root "jail" in
    let releases = Filename.concat jail "opt/.infra-releases/demo" in
    let get output = Release_probe.check ~app:"demo" output in

    check "a jail without a release has nothing active"
      (get (probe ~root) = Ok { Release_probe.active = None; source = None; previous = None });

    mkdir_p (Filename.concat releases active);
    Unix.symlink (".infra-releases/demo/" ^ active) (Filename.concat jail "opt/demo");
    check "an active release without a record has no source"
      (get (probe ~root) = Ok { Release_probe.active = Some active; source = None; previous = None });

    write (Filename.concat releases (active ^ "/.infra-source")) (commit ^ "\n");
    mkdir_p (Filename.concat releases previous);
    Unix.symlink previous (Filename.concat releases ".previous");
    check "the active release, its source commit and the retained previous"
      (get (probe ~root)
       = Ok { Release_probe.active = Some active; source = Some commit; previous = Some previous });

    (* A pointer outside the app's releases is never followed. *)
    Unix.unlink (Filename.concat jail "opt/demo");
    Unix.symlink "/etc" (Filename.concat jail "opt/demo");
    check "an unmanaged active pointer is refused" (Result.is_error (get (probe ~root)));
    Unix.unlink (Filename.concat jail "opt/demo");
    mkdir_p (Filename.concat jail "opt/demo");
    check "a legacy /opt/<app> directory is refused" (Result.is_error (get (probe ~root))));

  let answer ~active ~source ~previous =
    Printf.sprintf "release-probe-active: %s\nrelease-probe-source: %s\nrelease-probe-previous: %s\n"
      active source previous in
  let get output = Release_probe.check ~app:"demo" output in
  let link id = ".infra-releases/demo/" ^ id in
  check "another app's release is refused"
    (Result.is_error (get (answer ~active:(".infra-releases/other/" ^ active) ~source:commit ~previous)));
  check "a short identity is refused"
    (Result.is_error (get (answer ~active:(link "abc") ~source:commit ~previous)));
  check "a malformed source commit is refused"
    (Result.is_error (get (answer ~active:(link active) ~source:"HEAD" ~previous)));
  check "a malformed previous identity is refused"
    (Result.is_error (get (answer ~active:(link active) ~source:commit ~previous:"../x")));
  check "a source without an active release is refused"
    (Result.is_error (get (answer ~active:"none" ~source:commit ~previous:"none")));
  check "a missing answer is refused"
    (Result.is_error (get "release-probe-active: none\nrelease-probe-source: none\n"));
  check "a repeated answer is refused"
    (Result.is_error (get (answer ~active:"none" ~source:"none" ~previous:"none"
                           ^ "release-probe-active: none\n")))
