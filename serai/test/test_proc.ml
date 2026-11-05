(* Proc.capture under the live handler (a real sh) and under the mock. *)
open Serai

(* A bounded writer with its own watchdog: the old read-error path blocks on
   waitpid while this child is blocked on a full pipe. No extra descendants. *)
let () =
  match Sys.argv with
  | [| _; "--pipe-writer"; result_file |] ->
      let finish result =
        Out_channel.with_open_text result_file (fun channel ->
            Out_channel.output_string channel result);
        exit 0
      in
      Sys.set_signal Sys.sigalrm (Sys.Signal_handle (fun _ -> finish "watchdog"));
      Sys.set_signal Sys.sigpipe Sys.Signal_ignore;
      ignore (Unix.alarm 2);
      Unix.sleepf 0.05;
      Unix.kill (Unix.getppid ()) Sys.sigint;
      let chunk = Bytes.make 65536 'x' in
      (try
         for _ = 1 to 128 do ignore (Unix.write Unix.stdout chunk 0 (Bytes.length chunk)) done;
         finish "finished"
       with Unix.Unix_error (Unix.EPIPE, _, _) -> finish "pipe-closed")
  | _ -> ()

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let () =
  let result = Proc.live (fun () -> Proc.capture "sh" [ "-c"; "printf 'a\\nb'; exit 3" ]) in
  check "capture (live): stdout and exit code" (result = (3, "a\nb"));
  let result =
    Proc.live (fun () ->
        Proc.capture ~extra_env:[ ("SERAI_TEST_VALUE", "x1") ] "sh" [ "-c"; "printf %s \"$SERAI_TEST_VALUE\"" ])
  in
  check "capture (live): extra_env reaches the command" (result = (0, "x1"))

let () =
  let result =
    Proc.live (fun () -> Proc.capture "sh" [ "-c"; "head -c 200000 /dev/zero | tr '\\0' a" ])
  in
  check "capture (live): output larger than a pipe buffer is read whole"
    (match result with 0, output -> String.length output = 200000 | _ -> false)

(* Ctrl-C while a child runs: Sys.Break is raised inside the live handler
   (waitpid or the read is interrupted), and must be passed on to the
   suspended computation so its cleanup -- with_locks' release -- runs.
   The child waits before signalling: a signal that lands before the parent
   blocks in waitpid is handled only after the child exits. *)
let interrupted_while_running name perform =
  let finally_ran = ref false in
  Sys.catch_break true;
  let outcome =
    Fun.protect
      ~finally:(fun () -> Sys.catch_break false)
      (fun () ->
        try
          Proc.live (fun () ->
              Fun.protect
                ~finally:(fun () -> finally_ran := true)
                (fun () -> perform "sh" [ "-c"; "sleep 0.05; kill -INT $PPID; sleep 1" ]));
          `Returned
        with Sys.Break -> `Break)
  in
  check (name ^ ": Sys.Break reaches the caller") (outcome = `Break);
  check (name ^ ": the computation's finally ran") !finally_ran

let () = interrupted_while_running "run (live) interrupted" (fun prog args -> ignore (Proc.run prog args))
let () =
  interrupted_while_running "capture (live) interrupted" (fun prog args -> ignore (Proc.capture prog args))

let () =
  let finally_ran = ref false in
  let result =
    try
      Ok
        (Proc.live (fun () ->
             Fun.protect
               ~finally:(fun () -> finally_ran := true)
               (fun () -> Proc.run "/nonexistent/serai-test-binary" [])))
    with Unix.Unix_error (Unix.ENOENT, _, _) -> Error `Enoent
  in
  check "run (live): a missing program raises ENOENT to the caller" (result = Error `Enoent);
  check "run (live): a missing program still runs the computation's finally" !finally_ran

let () =
  let mock =
    Proc.Mock.create
      ~exit_codes:(fun r -> if r.prog = "jj" then 0 else 7)
      ~outputs:(fun r -> if r.prog = "jj" then "c0ffee\n" else "")
      ()
  in
  let captured, ran =
    Proc.Mock.run mock (fun () ->
        let captured = Proc.capture "jj" [ "log" ] in
        let ran = Proc.run "ssh" [ "host"; "true" ] in
        (captured, ran))
  in
  check "capture (mock): scripted output and exit code" (captured = (0, "c0ffee\n"));
  check "capture (mock): run still answers exit codes" (ran = 7);
  check "capture (mock): both calls recorded in order"
    (List.map (fun (r : Proc.request) -> r.prog) (Proc.Mock.calls mock) = [ "jj"; "ssh" ])

let () =
  Unix.putenv "SERAI_TEST_OVERRIDE" "inherited";
  Unix.putenv "SERAI_TEST_KEEP" "unchanged";
  let code, output = Proc.live (fun () ->
      Proc.capture ~extra_env:[ "SERAI_TEST_OVERRIDE", "first";
                               "SERAI_TEST_OVERRIDE", "last=with=equals" ] "env" []) in
  let entries = String.split_on_char '\n' output in
  check "environment: one entry per overridden name, last override wins"
    (code = 0 && List.filter (String.starts_with ~prefix:"SERAI_TEST_OVERRIDE=") entries
                 = [ "SERAI_TEST_OVERRIDE=last=with=equals" ]);
  check "environment: unrelated inherited entries preserved"
    (List.mem "SERAI_TEST_KEEP=unchanged" entries)

(* The child signals only this test process and finishes on its own. Keep its
   PID so even a failed regression test waits for it before restoring signals. *)
let with_signalling_child name signal_number handler perform =
  let pid_file = Filename.temp_file "serai-proc-child-" ".pid" in
  let previous = Sys.signal signal_number (Sys.Signal_handle handler) in
  let rec wait pid =
    try ignore (Unix.waitpid [] pid) with
    | Sys.Break | Unix.Unix_error (Unix.EINTR, _, _) -> wait pid
    | Unix.Unix_error (Unix.ECHILD, _, _) -> ()
  in
  Fun.protect
    ~finally:(fun () ->
      Sys.set_signal signal_number previous;
      Sys.remove pid_file)
    (fun () ->
      let script = Printf.sprintf
          "printf '%%s' $$ > %s; sleep 0.05; kill -%s $PPID; sleep 0.05; kill -%s $PPID; sleep 0.3; exit 7"
          (Filename.quote pid_file) name name in
      let outcome = try Ok (perform script) with exn -> Error exn in
      let pid = In_channel.with_open_text pid_file (fun channel ->
          int_of_string (In_channel.input_all channel)) in
      let reaped =
        try
          let waited, _ = Unix.waitpid [Unix.WNOHANG] pid in
          if waited = 0 then (wait pid; false) else false
        with Unix.Unix_error (Unix.ECHILD, _, _) -> true
      in
      outcome, reaped)

let repeated_interrupt name perform =
  let signals = ref 0 in
  let outcome, reaped = with_signalling_child "INT" Sys.sigint
      (fun _ -> incr signals; raise Sys.Break) perform in
  check (name ^ ": repeated Ctrl-C preserves Sys.Break")
    (match outcome with Error Sys.Break -> true | _ -> false);
  check (name ^ ": repeated Ctrl-C does not abandon the child") reaped;
  check (name ^ ": both interrupts were delivered") (!signals = 2)

let () = repeated_interrupt "run cleanup" (fun script ->
    Proc.live (fun () -> Proc.run "sh" ["-c"; script]))
let () = repeated_interrupt "capture cleanup" (fun script ->
    Proc.live (fun () -> fst (Proc.capture "sh" ["-c"; script])))

let () =
  let signals = ref 0 in
  let outcome, reaped = with_signalling_child "USR1" Sys.sigusr1
      (fun _ -> incr signals) (fun script ->
        Proc.live (fun () -> Proc.run "sh" ["-c"; script])) in
  check "run wait: EINTR retries and returns the child's exit code"
    (match outcome with Ok 7 -> true | _ -> false);
  check "run wait: EINTR leaves no child to reap" reaped;
  check "run wait: both nonraising signals were delivered" (!signals = 2)

let () =
  let outcome, reaped = with_signalling_child "USR1" Sys.sigusr1
      (fun _ -> ()) (fun script ->
        Proc.live (fun () -> fst (Proc.capture "sh" ["-c"; "exec 1>&-; " ^ script]))) in
  check "capture wait: EINTR retries after output EOF"
    (match outcome with Ok 7 -> true | _ -> false);
  check "capture wait: EINTR leaves no child to reap" reaped

let () =
  let result_file = Filename.temp_file "serai-proc-writer-" ".result" in
  let previous = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ -> raise Sys.Break)) in
  let outcome, result = Fun.protect
      ~finally:(fun () -> Sys.set_signal Sys.sigint previous; Sys.remove result_file)
      (fun () ->
        let outcome =
          try ignore (Proc.live (fun () ->
              Proc.capture Sys.executable_name ["--pipe-writer"; result_file])); `Returned
          with Sys.Break -> `Break
        in
        let result = In_channel.with_open_text result_file In_channel.input_all in
        outcome, result) in
  check "capture read failure: preserves the interrupt" (outcome = `Break);
  check "capture read failure: closes the pipe before reaping, not after watchdog"
    (result = "pipe-closed")

(* Simulate a competing reaper: the original interrupt must not hide the
   unexpected ECHILD from cleanup. This is not a supported production caller.
   The child lives until the handler kills it: a child that exits right after
   the signal can be reaped by Proc's waitpid before the handler runs. *)
let () =
  let pid_file = Filename.temp_file "serai-proc-reaped-" ".pid" in
  let previous = Sys.signal Sys.sigint (Sys.Signal_handle (fun _ ->
      let pid = In_channel.with_open_text pid_file (fun channel ->
          int_of_string (In_channel.input_all channel)) in
      Unix.kill pid Sys.sigkill;
      ignore (Unix.waitpid [] pid);
      raise Sys.Break)) in
  let outcome = Fun.protect
      ~finally:(fun () -> Sys.set_signal Sys.sigint previous; Sys.remove pid_file)
      (fun () ->
        let script = Printf.sprintf "printf '%%s' $$ > %s; sleep 0.05; kill -INT $PPID; exec sleep 30"
            (Filename.quote pid_file) in
        try ignore (Proc.live (fun () -> Proc.run "sh" ["-c"; script])); None
        with exn -> Some exn) in
  check "cleanup failure: original interrupt and cleanup error are both retained"
    (match outcome with
     | Some (Proc.Cleanup_failed (Sys.Break, Unix.Unix_error (Unix.ECHILD, _, _))) -> true
     | _ -> false)

let () = if !failures > 0 then exit 1
