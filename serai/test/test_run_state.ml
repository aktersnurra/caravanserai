(* What an error means depends on where the run stood when it ended. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let contains needle haystack =
  let n = String.length needle and h = String.length haystack in
  let rec go i = i + n <= h && (String.sub haystack i n = needle || go (i + 1)) in
  go 0

let respond f = Agent_cli.respond ~operation:"demo" f
let says response text = contains text (Agent_cli.to_json response)

let () =
  Run_state.reset ();
  let r = respond (fun () -> failwith "no") in
  check "nothing changed: refused, not_applied, exit 1"
    (says r {|"status":"refused"|} && says r {|"code":"not_applied"|} && Agent_cli.exit_code r = 1);
  Run_state.changing ();
  let r = respond (fun () -> failwith "broke") in
  check "a host may have changed: failed, apply_failed"
    (says r {|"status":"failed"|} && says r {|"code":"apply_failed"|} && says r {|"message":"broke"|});
  let r = respond (fun () -> Error (Json.Object [ "steps", Json.Array [] ], "step")) in
  check "a failed step keeps its data and its code" (says r {|"code":"step_failed"|} && says r {|"steps":[]|});
  Run_state.retain { host = "compute"; stage = "/tmp/s/x"; context = "artifact build demo" };
  let r = respond (fun () -> failwith "lost") in
  check "a retained stage and lock: unknown, outcome_unknown, exit 3"
    (says r {|"status":"unknown"|} && says r {|"code":"outcome_unknown"|} && Agent_cli.exit_code r = 3);
  check "the retained host and stage are named, with how to inspect and unlock"
    (says r {|"host":"compute"|} && says r {|"stage":"/tmp/s/x"|}
     && says r {|"unlock_after_inspection":["serai","unlock","compute"]|});
  let r = respond (fun () -> Ok Json.Null) in
  check "a retained stage is never a success" (says r {|"status":"unknown"|});

  Run_state.reset ();
  let r = respond (fun () -> Run_state.fail ~cause:"lock_held" "compute is locked") in
  check "a failure names its cause beside the outcome code"
    (says r {|"code":"not_applied"|} && says r {|"cause":"lock_held"|});
  let r = respond (fun () -> ignore (try Run_state.fail ~cause:"declined" "first" with Failure _ -> ()); failwith "second") in
  check "a cause belongs to its own message, not to a later failure" (says r {|"cause":null|});
  Run_state.locked "compute"; Run_state.ran "bootstrap hello"; Run_state.changing ();
  let r = respond (fun () -> Ok (Json.Object [ "workload", Json.String "hello" ])) in
  check "a result says what ran and on which hosts"
    (says r {|"changed":true|} && says r {|"hosts":["compute"]|} && says r {|"ran":["bootstrap hello"]|});
  let r = respond (fun () -> Run_state.fail ~cause:"command_failed" "ssh: exited 1") in
  check "an error after a change still says what ran"
    (says r {|"status":"failed"|} && says r {|"ran":["bootstrap hello"]|} && says r {|"cause":"command_failed"|});

  Run_state.reset ();
  let plan : Run_state.planned =
    { operation = "demo"; id = Plan_id.make ~operation:"demo" [ "a" ]; question = "do it?"; facts = [ "app", "a" ] } in
  let r = respond (fun () -> raise (Run_state.Planned plan)) in
  check "a plan is a result: succeeded, applied false, with its id and facts"
    (Agent_cli.is_plan r && says r {|"applied":false|} && says r {|"facts":{"app":"a"}|}
     && says r (Plan_id.to_string plan.id));
  let r = respond (fun () -> raise (Plan_id.Stale "moved")) in
  check "another plan than the approved one: refused, stale_plan" (says r {|"code":"stale_plan"|});
  check "an ordinary result is not a plan" (not (Agent_cli.is_plan (respond (fun () -> Ok (Json.Object [])))))
