(* Remote_lock's scripts, run with the local sh against a throwaway stage:
   the same POSIX sh that runs on the compute host (FreeBSD) and edge host (Arch). *)
open Serai

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let stage = Printf.sprintf "/tmp/serai-lock-test-%d" (Unix.getpid ())
let lock = Remote_lock.lock_dir ~stage

let sh script =
  Sys.command (Printf.sprintf "sh -c %s 2>/dev/null" (Filename.quote script))

(* exit code and stdout *)
let sh_output script =
  let out = Filename.temp_file "serai-lock-test" ".out" in
  Fun.protect
    ~finally:(fun () -> Sys.remove out)
    (fun () ->
      let code =
        Sys.command (Printf.sprintf "sh -c %s >%s 2>/dev/null" (Filename.quote script) (Filename.quote out))
      in
      (code, In_channel.with_open_bin out In_channel.input_all))

let record = stage ^ "/applied"

let () =
  ignore (Sys.command (Printf.sprintf "rm -rf %s && mkdir -p %s/locks" stage stage));
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ stage)))
    (fun () ->
      let acquire_output token =
        sh_output (Remote_lock.acquire_script ~stage ~token ~holder:("run " ^ token) ~record ~wait_seconds:0)
      in
      let acquire token = fst (acquire_output token) in
      let acquire_waiting ~wait_seconds token =
        Remote_lock.acquire_script ~stage ~token ~holder:("run " ^ token) ~record ~wait_seconds in
      let release token = Remote_lock.release_script ~stage ~token in
      check "acquire: free lock is taken, no record -> the marker"
        (acquire_output "t1" = (0, Remote_lock.no_record_marker ^ "\n"));
      check "acquire: holder recorded"
        (In_channel.with_open_bin (Filename.concat lock "holder") In_channel.input_all = "run t1\n");
      check "acquire: a second run sees it held" (acquire "t2" = Remote_lock.held_exit);
      check "release: someone else's token leaves the lock"
        (sh (Remote_lock.release_script ~stage ~token:"t2") = 0 && Sys.file_exists lock);
      check "release: own token removes it"
        (sh (Remote_lock.release_script ~stage ~token:"t1") = 0 && not (Sys.file_exists lock));
      Out_channel.with_open_bin record (fun oc -> output_string oc "(commit c0ffee)\n");
      check "acquire: taken again once released, printing the record"
        (acquire_output "t3" = (0, "(commit c0ffee)\n"));
      check "acquire: a held lock prints no record" (acquire_output "t3b" = (Remote_lock.held_exit, ""));
      check "acquire: a held lock is waited for, then taken"
        (Sys.command
           (Printf.sprintf "(sleep 1; sh -c %s) & sh -c %s >/dev/null 2>&1"
              (Filename.quote (release "t3")) (Filename.quote (acquire_waiting ~wait_seconds:10 "t3c"))) = 0
        && In_channel.with_open_bin (Filename.concat lock "token") In_channel.input_all = "t3c\n");
      check "acquire: waiting gives up after wait_seconds"
        (sh (acquire_waiting ~wait_seconds:2 "t3d") = Remote_lock.held_exit);
      (* The waiter's caller (the serai run's ssh session) dies while it
         waits: the lock released afterwards must stay free. *)
      ignore
        (Sys.command
           (Printf.sprintf "(sh -c %s >/dev/null 2>&1; :) & caller=$!; sleep 1; kill -9 $caller; sh -c %s; sleep 3"
              (Filename.quote (acquire_waiting ~wait_seconds:10 "t3e")) (Filename.quote (release "t3c"))));
      check "acquire: a waiter whose caller is gone never takes the lock" (not (Sys.file_exists lock));
      ignore (acquire "t3f");
      let old = int_of_float (Unix.time ()) - Remote_lock.stale_after_seconds - 60 in
      ignore (Sys.command (Printf.sprintf "touch -d @%d %s" old lock));
      check "acquire: an old lock is reported stale" (acquire "t4" = Remote_lock.stale_exit);
      check "unlock: removes any lock" (sh (Remote_lock.unlock_script ~stage) = 0 && not (Sys.file_exists lock));
      check "unlock: no lock is not an error" (sh (Remote_lock.unlock_script ~stage) = 0);
      (* mkdir fails yet there is no lock to stat -- as when the holder
         releases between the two. Without locks/ the mkdir fails the same
         way, so the race is reproduced deterministically. *)
      Sys.rmdir (Filename.dirname lock);
      check "acquire: lock gone between mkdir and stat -> reported held"
        (acquire "t5" = Remote_lock.held_exit))

(* The script the dispatcher actually sends: the stage guard for locks/
   and the acquire in one connection, run against a fresh stage. *)
let () =
  let stage = Printf.sprintf "/tmp/serai-lock-guard-test-%d" (Unix.getpid ()) in
  let lock = Remote_lock.lock_dir ~stage in
  let script = Dispatcher.acquire_lock_script ~stage ~token:"g1" ~holder:"guarded run" in
  Fun.protect
    ~finally:(fun () -> ignore (Sys.command ("rm -rf " ^ stage)))
    (fun () ->
      let code, output = sh_output script in
      check "guarded acquire: creates the stage and takes the lock"
        (code = 0 && Sys.file_exists lock
        && (output = Remote_lock.no_record_marker ^ "\n" || Sys.file_exists Applied_record.path));
      Unix.chmod stage 0o755;
      ignore (Sys.command ("rm -rf " ^ lock));
      check "guarded acquire: an unsafe stage is refused before locking"
        (sh script = 1 && not (Sys.file_exists lock)))

let () = if !failures > 0 then exit 1
