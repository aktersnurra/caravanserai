open Base

type outcome = Succeeded | Failed | Interrupted | Changes_pending

type session = {
  operation : string;
  workload : string option;
  started_at : float;
  mutable phase : string;
  mutable uncertain : bool;
}

let current : session option ref = ref None

let quote value =
  let buffer = Buffer.create (String.length value + 2) in
  Buffer.add_char buffer '"';
  String.iter value ~f:(function
    | '"' -> Buffer.add_string buffer "\\\""
    | '\\' -> Buffer.add_string buffer "\\\\"
    | character when Char.to_int character < 32 ->
        Buffer.add_string buffer (Printf.sprintf "\\u%04x" (Char.to_int character))
    | character -> Buffer.add_char buffer character);
  Buffer.add_char buffer '"';
  Buffer.contents buffer

(* Use unbuffered stderr: a failed buffered write can be retried at exit. *)
let write_line line =
  try
    let text = "\n" ^ line ^ "\n" in
    let rec write offset =
      if offset < String.length text then
        let count = Unix.write_substring Unix.stderr text offset (String.length text - offset) in
        if count = 0 then current := None else write (offset + count)
    in
    (* EPIPE must be an exception, not a process-terminating SIGPIPE. Restore
       the caller's signal disposition immediately after the diagnostic write. *)
    let previous = Stdlib.Sys.signal Stdlib.Sys.sigpipe Stdlib.Sys.Signal_ignore in
    Stdlib.Fun.protect
      ~finally:(fun () -> Stdlib.Sys.set_signal Stdlib.Sys.sigpipe previous)
      (fun () -> write 0)
  with Stdlib.Sys_error _ | Unix.Unix_error _ -> current := None


let emit session status =
  let now = Unix.gettimeofday () in
  let time = Unix.gmtime now in
  let timestamp = Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02dZ"
    (time.tm_year + 1900) (time.tm_mon + 1) time.tm_mday time.tm_hour time.tm_min time.tm_sec in
  let line = Printf.sprintf
    {|{"event":"infra.progress","operation":%s,"workload":%s,"phase":%s,"status":%s,"timestamp":%s,"elapsed_seconds":%.3f}|}
    (quote session.operation) (Option.value_map session.workload ~default:"null" ~f:quote)
    (quote session.phase) (quote status) (quote timestamp)
    (Float.max 0. (now -. session.started_at)) in
  write_line line

let start ~enabled ~operation ~workload =
  current := if enabled then Some {
    operation; workload; started_at=Unix.gettimeofday (); phase="inputs"; uncertain=false;
  } else None;
  Option.iter !current ~f:(fun session -> emit session "running")

let phase value =
  Option.iter !current ~f:(fun session ->
    if not (String.equal session.phase value) then begin
      session.phase <- value;
      emit session "running"
    end)

let outcome_unknown () = Option.iter !current ~f:(fun session -> session.uncertain <- true)

let finish outcome =
  Option.iter !current ~f:(fun session ->
    let status = if session.uncertain then "unknown" else match outcome with
      | Succeeded -> "succeeded" | Failed -> "failed"
      | Interrupted -> "interrupted" | Changes_pending -> "changes_pending" in
    emit session status);
  current := None

let is_enabled () = Option.is_some !current

type phase_status = Completed | Phase_failed | Skipped

let duration_event session ~phase ~parent ~status ~duration ~reason =
  (* Reporting is best effort, including clock conversion/formatting. It must
     never replace the operation's result or its primary exception. *)
  try
    let status = match status with
      | Completed -> "completed" | Phase_failed -> "failed" | Skipped -> "skipped" in
    write_line (Printf.sprintf
      {|{"event":"infra.phase_duration","operation":%s,"workload":%s,"phase":%s,"parent":%s,"status":%s,"duration_seconds":%s,"reason":%s}|}
      (quote session.operation) (Option.value_map session.workload ~default:"null" ~f:quote)
      (quote phase) (Option.value_map parent ~default:"null" ~f:quote) (quote status)
      (Option.value_map duration ~default:"null" ~f:(fun seconds -> Printf.sprintf "%.9f" seconds))
      (Option.value_map reason ~default:"null" ~f:quote))
  with _ -> ()

let with_duration ~phase ~parent f =
  match !current with
  | None -> f ()
  | Some session ->
      let started = try Some (Mtime_clock.elapsed ()) with _ -> None in
      let report status =
        try
          Option.iter started ~f:(fun started ->
            let elapsed = Mtime.Span.abs_diff (Mtime_clock.elapsed ()) started in
            duration_event session ~phase ~parent ~status
              ~duration:(Some (Mtime.Span.to_float_ns elapsed /. 1e9)) ~reason:None)
        with _ -> () in
      match f () with
      | value -> report Completed; value
      | exception primary ->
          let backtrace = Stdlib.Printexc.get_raw_backtrace () in
          report Phase_failed;
          Stdlib.Printexc.raise_with_backtrace primary backtrace

let skipped ~phase ~parent ~reason =
  Option.iter !current ~f:(fun session ->
    duration_event session ~phase ~parent ~status:Skipped ~duration:None ~reason:(Some reason))
