(* The two effects this whole dispatcher performs: run an external command
   ([Run]), or run one and collect its stdout ([Capture]). Everything else
   (bootstrap/deploy/check/rollout) is plain, direct-style OCaml built on
   top of [run]/[run_checked]/[capture] below. Swapping what "running a
   command" means -- inherit the terminal for real ssh/rsync, or record it
   in memory for a test -- is a matter of installing a different handler
   around the call, not threading a fake binary through $PATH. *)

type request = {
  prog : string;
  args : string list;
  extra_env : (string * string) list;
      (* additional variables layered on top of the current environment,
         mirroring `env FOO=bar prog ...` in the bash dispatcher *)
}

type _ Effect.t += Run : request -> int Effect.t (* exit code *)

type _ Effect.t += Capture : request -> (int * string) Effect.t
  (* exit code, stdout *)

let request ?(extra_env = []) prog args = { prog; args; extra_env }

let run ?extra_env prog args = Effect.perform (Run (request ?extra_env prog args))
let capture ?extra_env prog args = Effect.perform (Capture (request ?extra_env prog args))

(* A multi-line argument is a remote script; echoing it whole buries the
   exit code under dozens of lines, so name it by its first line. *)
let describe_arg arg =
  match String.index_opt arg '\n' with
  | Some i -> String.sub arg 0 i ^ " ..."
  | None -> arg

let run_checked ?extra_env prog args =
  let req = request ?extra_env prog args in
  match Effect.perform (Run req) with
  | 0 -> ()
  | code ->
      failwith
        (Printf.sprintf "%s %s: exited %d" prog
           (String.concat " " (List.map describe_arg args)) code)

let spawn_environment extra_env =
  let inherited =
    Unix.environment () |> Array.to_list
    |> List.filter_map (fun entry ->
           match String.index_opt entry '=' with
           | None -> None
           | Some index ->
               Some (String.sub entry 0 index,
                     String.sub entry (index + 1) (String.length entry - index - 1)))
  in
  let entries = List.fold_left (fun entries (name, value) ->
      (name, value) :: List.remove_assoc name entries) [] (inherited @ extra_env) in
  entries |> List.map (fun (name, value) -> name ^ "=" ^ value) |> Array.of_list

exception Cleanup_failed of exn * exn

let () =
  Printexc.register_printer (function
    | Cleanup_failed (primary, cleanup) ->
        Some (Printf.sprintf "%s (cleanup also failed: %s)"
                (Printexc.to_string primary) (Printexc.to_string cleanup))
    | _ -> None)

let reraise_after_cleanup primary cleanup =
  let backtrace = Printexc.get_raw_backtrace () in
  match cleanup () with
  | () -> Printexc.raise_with_backtrace primary backtrace
  | exception secondary ->
      Printexc.raise_with_backtrace (Cleanup_failed (primary, secondary)) backtrace

(* Unlike Fun.protect, preserve both errors when cleanup also fails. *)
let protect ~finally f =
  match f () with
  | value -> finally (); value
  | exception primary -> reraise_after_cleanup primary finally

let rec waitpid pid =
  try Unix.waitpid [] pid with
  | Unix.Unix_error (Unix.EINTR, _, _) -> waitpid pid

let exit_code_of pid =
  let _, status = waitpid pid in
  match status with
  | Unix.WEXITED c -> c
  | Unix.WSIGNALED s | Unix.WSTOPPED s -> 128 + s

(* Once interrupted, finish reaping this child before propagating the original
   error. Further Ctrl-C must not abandon it; unexpected errors remain visible. *)
let rec reap pid =
  try ignore (waitpid pid) with Sys.Break -> reap pid

let wait_for pid =
  match exit_code_of pid with
  | code -> code
  | exception primary -> reraise_after_cleanup primary (fun () -> reap pid)

let run_live { prog; args; extra_env } =
  let pid =
    Unix.create_process_env prog
      (Array.of_list (prog :: args))
      (spawn_environment extra_env) Unix.stdin Unix.stdout Unix.stderr
  in
  wait_for pid

let capture_live { prog; args; extra_env } =
  let read_end, write_end = Unix.pipe ~cloexec:true () in
  let channel = Unix.in_channel_of_descr read_end in
  let writer = Unix.out_channel_of_descr write_end in
  (* Channel close is idempotent: retrying Sys.Break does not close a reused
     numeric descriptor. Other close errors are not retried. *)
  let rec finish_close close () =
    try close () with Sys.Break -> finish_close close ()
  in
  let finish_read = finish_close (fun () -> In_channel.close channel) in
  let finish_write = finish_close (fun () -> Out_channel.close writer) in
  let close_read () =
    match In_channel.close channel with
    | () -> ()
    | exception Sys.Break -> reraise_after_cleanup Sys.Break finish_read
  in
  protect ~finally:close_read (fun () ->
      let pid =
        match Unix.create_process_env prog
                (Array.of_list (prog :: args))
                (spawn_environment extra_env) Unix.stdin write_end Unix.stderr with
        | pid -> pid
        | exception primary ->
            reraise_after_cleanup primary finish_write
      in
      match
        Out_channel.close writer;
        let output = In_channel.input_all channel in
        (exit_code_of pid, output)
      with
      | result -> result
      | exception primary ->
          reraise_after_cleanup primary (fun () ->
              (* Stop a pipe writer before waiting for it. Further interrupts
                 cannot skip close or reap; unexpected errors preserve both causes. *)
              protect ~finally:(fun () -> reap pid) (fun () ->
                  protect ~finally:finish_write finish_read)))

(* Live handler: spawns the process with stdin and stderr inherited from
   us, exactly like bash invoking `"$SSH_BIN" ...` directly -- the user
   sees ssh/rsync progress live rather than it being buffered and replayed.
   [Run] inherits stdout too; [Capture] pipes it back as the result.
   Any exception while the child runs -- Sys.Break from Ctrl-C, a
   Unix_error from the spawn, wait or read -- is raised in the suspended
   computation via [discontinue], so its cleanup (with_locks' release)
   runs rather than being skipped. *)
let live f =
  let open Effect.Deep in
  let resume k perform request =
    match perform request with
    | result -> continue k result
    | exception e -> discontinue k e
  in
  match_with f ()
    {
      retc = (fun x -> x);
      exnc = raise;
      effc =
        (fun (type a) (eff : a Effect.t) ->
          match eff with
          | Run request -> Some (fun (k : (a, _) continuation) -> resume k run_live request)
          | Capture request -> Some (fun (k : (a, _) continuation) -> resume k capture_live request)
          | _ -> None);
    }

(* Test handler: records every command that would have run, in order, and
   answers with a scripted exit code instead of touching the network. *)
module Mock = struct
  type t = {
    mutable calls : request list;
    exit_codes : request -> int;
    outputs : request -> string;
  }

  let create ?(exit_codes = fun _ -> 0) ?(outputs = fun _ -> "") () =
    { calls = []; exit_codes; outputs }

  let calls t = List.rev t.calls

  let run t f =
    let open Effect.Deep in
    match_with f ()
      {
        retc = (fun x -> x);
        exnc = raise;
        effc =
          (fun (type a) (eff : a Effect.t) ->
            match eff with
            | Run req ->
                Some
                  (fun (k : (a, _) continuation) ->
                    t.calls <- req :: t.calls;
                    continue k (t.exit_codes req))
            | Capture req ->
                Some
                  (fun (k : (a, _) continuation) ->
                    t.calls <- req :: t.calls;
                    continue k (t.exit_codes req, t.outputs req))
            | _ -> None);
      }
end
