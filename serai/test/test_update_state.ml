(* Update_state: the codec, the state file and the run lock. *)
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
let commit = String.make 40 'c'

let () =
  let open Update_state in
  (* The codec. *)
  let state =
    empty
    |> (fun t -> set t "meals" { handled = Some commit; reported = Some "meals: deployed cccccccccccc" })
    |> (fun t -> set t "board" { handled = None; reported = Some "board: refused (not signed)" })
    |> fun t -> { t with config_reported = Some "configuration: not signed" } in
  check "the state round-trips" (of_string (to_string state) = Ok state);
  check "empty round-trips" (of_string (to_string empty) = Ok empty);
  check "an app never seen has nothing recorded" (find state "other" = { handled = None; reported = None });
  check "set replaces an app's record"
    (find (set state "meals" { handled = None; reported = None }) "meals" = { handled = None; reported = None });
  check "retain drops apps no longer declared"
    (let kept = retain state ~apps:[ "meals" ] in
     find kept "board" = { handled = None; reported = None } && find kept "meals" = find state "meals");
  List.iter (fun (name, text) -> check ("refused: " ^ name) (Result.is_error (of_string text)))
    [ "not a sexp", "((apps";
      "an unknown field", "((apps ()) (extra x))";
      "a malformed commit", "((apps ((meals ((handled HEAD))))))";
      "a repeated app", "((apps ((meals ()) (meals ()))))";
      "an unknown app field", "((apps ((meals ((pending x))))))" ];

  let root = Filename.temp_dir "update-state" "test" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let dir = Filename.concat root "state/serai/update" in
    check "a missing state file loads as empty" (load ~dir = Ok empty);
    check "save writes the state" (save ~dir state = Ok () && load ~dir = Ok state);
    check "the state directory is private" ((Unix.stat dir).Unix.st_perm land 0o077 = 0);
    check "the state file is private"
      ((Unix.stat (Filename.concat dir "state.sexp")).Unix.st_perm land 0o077 = 0);
    check "save replaces the state and leaves no temporary file"
      (save ~dir empty = Ok () && load ~dir = Ok empty
       && Array.to_list (Sys.readdir dir) |> List.for_all (fun name -> name = "state.sexp" || name = "lock"));
    write (Filename.concat dir "state.sexp") "((apps";
    check "an unreadable state file is an error, never empty" (Result.is_error (load ~dir));
    let shared = Filename.concat root "shared" in
    Unix.mkdir shared 0o755;
    check "a state directory others can read is refused" (Result.is_error (load ~dir:shared));

    (* The run lock: one run at a time, released when its process ends. *)
    check "the run lock runs the body when free" (with_run_lock ~dir (fun () -> 42) = Some 42);
    let ready_read, ready_write = Unix.pipe () in
    let go_read, go_write = Unix.pipe () in
    (match Unix.fork () with
     | 0 ->
         Unix.close ready_read; Unix.close go_write;
         ignore (with_run_lock ~dir (fun () ->
           ignore (Unix.write_substring ready_write "x" 0 1);
           ignore (Unix.read go_read (Bytes.create 1) 0 1)));
         Unix._exit 0
     | child ->
         Unix.close ready_write; Unix.close go_read;
         ignore (Unix.read ready_read (Bytes.create 1) 0 1);
         check "while another process holds the run lock, the body does not run"
           (with_run_lock ~dir (fun () -> ()) = None);
         ignore (Unix.write_substring go_write "x" 0 1);
         ignore (Unix.waitpid [] child);
         check "once that process has ended, the run lock is free again"
           (with_run_lock ~dir (fun () -> ()) = Some ())))
