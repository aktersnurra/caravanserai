open Serai

let contains text part =
  let rec loop n = n + String.length part <= String.length text &&
    (String.sub text n (String.length part) = part || loop (n + 1)) in
  loop 0

let rec scratch directory =
  let path = Filename.concat directory "serai/_build" in
  if Sys.file_exists path then path else
    let parent = Filename.dirname directory in
    if parent = directory then failwith "serai/_build prerequisite missing" else scratch parent

let capture f =
  let path = Filename.temp_file ~temp_dir:(scratch (Sys.getcwd ())) "progress-" ".jsonl" in
  let fd = Unix.openfile path [Unix.O_WRONLY; Unix.O_TRUNC] 0o600 in
  let saved = Unix.dup Unix.stderr in
  Fun.protect ~finally:(fun () -> Unix.dup2 saved Unix.stderr; Unix.close saved; Unix.close fd)
    (fun () -> Unix.dup2 fd Unix.stderr; f ());
  let channel = open_in path in
  let text = Fun.protect ~finally:(fun () -> close_in channel; Sys.remove path)
    (fun () -> really_input_string channel (in_channel_length channel)) in
  String.split_on_char '\n' text |> List.filter (fun line -> contains line "serai.phase_duration")

exception Primary

let () =
  Printexc.record_backtrace true;
  let events = capture (fun () ->
    Progress.start ~enabled:true ~operation:"artifact.build" ~workload:(Some "quoted\"\n");
    assert (Progress.is_enabled ());
    assert (Progress.with_duration ~phase:"first" ~parent:None (fun () -> 17) = 17);
    Progress.with_duration ~phase:"parent" ~parent:None (fun () ->
      Progress.with_duration ~phase:"child" ~parent:(Some "parent") (fun () -> ()));
    (try Progress.with_duration ~phase:"failure" ~parent:None (fun () -> raise Primary)
     with Primary -> assert (contains (Printexc.get_backtrace ()) "test_progress.ml"));
    Progress.skipped ~phase:"base-extraction" ~parent:(Some "remote-total") ~reason:"prepared clone";
    Progress.finish Progress.Succeeded) in
  assert (List.length events = 5);
  List.iter (fun line ->
    assert (contains line "\"operation\":\"artifact.build\",\"workload\":\"quoted\\\"\\u000a\"");
    assert (contains line "\"reason\":")) events;
  List.iter (fun line ->
    let key = "\"duration_seconds\":" in
    let rec find n = if String.sub line n (String.length key) = key then n + String.length key else find (n+1) in
    let start = find 0 in
    let stop = String.index_from line start ',' in
    let seconds = float_of_string (String.sub line start (stop-start)) in
    assert (Float.is_finite seconds && seconds >= 0.)) (List.filter (fun line -> not (contains line "\"status\":\"skipped\"")) events);
  List.iter2 (fun line phase -> assert (contains line ("\"phase\":\"" ^ phase ^ "\""))) events
    ["first"; "child"; "parent"; "failure"; "base-extraction"];
  assert (contains (List.nth events 1) "\"parent\":\"parent\"");
  assert (contains (List.nth events 3) "\"status\":\"failed\"");
  assert (contains (List.nth events 4) "\"duration_seconds\":null,\"reason\":\"prepared clone\"");
  assert (capture (fun () ->
    Progress.start ~enabled:false ~operation:"disabled" ~workload:None;
    Progress.with_duration ~phase:"hidden" ~parent:None (fun () -> ());
    Progress.skipped ~phase:"hidden" ~parent:None ~reason:"disabled") = []);
  let child = Unix.fork () in
  if child = 0 then begin
    let fd = Unix.openfile "/dev/full" [Unix.O_WRONLY] 0 in
    Unix.dup2 fd Unix.stderr; Unix.close fd;
    Progress.start ~enabled:true ~operation:"broken" ~workload:None;
    assert (Progress.with_duration ~phase:"success" ~parent:None (fun () -> 23) = 23);
    assert (try Progress.with_duration ~phase:"primary" ~parent:None (fun () -> if Sys.file_exists "/dev/full" then raise Primary); false
     with Primary -> true);
    exit 0
  end;
  assert (snd (Unix.waitpid [] child) = Unix.WEXITED 0);
  let prior = Sys.signal Sys.sigpipe Sys.Signal_default in
  ignore (capture (fun () ->
    Progress.start ~enabled:true ~operation:"signal-disposition" ~workload:None;
    Progress.with_duration ~phase:"success" ~parent:None (fun () -> ())));
  assert (match Sys.signal Sys.sigpipe Sys.Signal_default with Sys.Signal_default -> true | _ -> false);
  ignore (capture (fun () ->
    Progress.start ~enabled:true ~operation:"signal-disposition" ~workload:None;
    (try Progress.with_duration ~phase:"failure" ~parent:None (fun () -> raise Primary)
     with Primary -> ())));
  assert (match Sys.signal Sys.sigpipe Sys.Signal_default with Sys.Signal_default -> true | _ -> false);
  Sys.set_signal Sys.sigpipe prior;
  let read_end, write_end = Unix.pipe () in
  Unix.close read_end;
  let child = Unix.fork () in
  if child = 0 then begin
    Unix.dup2 write_end Unix.stderr; Unix.close write_end;
    Progress.start ~enabled:true ~operation:"closed-pipe" ~workload:None;
    assert (Progress.with_duration ~phase:"success" ~parent:None (fun () -> 23) = 23);
    exit 0
  end;
  Unix.close write_end;
  assert (snd (Unix.waitpid [] child) = Unix.WEXITED 0);
  print_endline "ok - monotonic duration order, nesting, failure, skip, disabled and broken stderr"
