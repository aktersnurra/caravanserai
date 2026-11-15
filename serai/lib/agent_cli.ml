(* Deliberately no Proc/Dispatcher dependency: this surface cannot mutate hosts. *)
type json = Json.t = Null | Bool of bool | Number of string | String of string
          | Array of json list | Object of (string * json) list

type error_code = Invalid_request | Unsupported_operation | Input_unavailable
  | Invalid_declaration | Invalid_plan | Unknown_workload | Render_failed
  | Internal_error | Interrupted | Not_applied | Step_failed | Stale_plan
  | Apply_failed | Outcome_unknown

type status = Succeeded | Refused | Failed | Cancelled | Unknown
type response = { operation : string; status : status; data : json;
                  error : (error_code * string) option }
type request = Validate | Inspect | Plan of string * string option
exception Refusal of error_code * string
exception Bad_request of string

let code = function
  | Invalid_request -> "invalid_request" | Unsupported_operation -> "unsupported_operation"
  | Input_unavailable -> "input_unavailable" | Invalid_declaration -> "invalid_declaration"
  | Invalid_plan -> "invalid_plan" | Unknown_workload -> "unknown_workload"
  | Render_failed -> "render_failed" | Internal_error -> "internal_error"
  | Interrupted -> "interrupted" | Not_applied -> "not_applied" | Step_failed -> "step_failed"
  | Stale_plan -> "stale_plan" | Apply_failed -> "apply_failed" | Outcome_unknown -> "outcome_unknown"

let encode = Json.to_string

let to_json response =
  let status = match response.status with Succeeded -> "succeeded" | Refused -> "refused"
    | Failed -> "failed" | Cancelled -> "interrupted" | Unknown -> "unknown" in
  let error = match response.error with None -> Null | Some (kind,message) ->
    Object ["code",String (code kind); "message",String message] in
  encode (Object ["schema_version",Json.of_int 1; "operation",String response.operation;
    "status",String status; "data",response.data; "error",error])

let exit_code response = match response.status with
  | Succeeded -> 0 | Cancelled -> 130 | Refused | Failed -> 1 | Unknown -> 3
let is_plan response = match response.status, response.data with
  | Succeeded, Object fields -> List.assoc_opt "applied" fields = Some (Bool false) && List.mem_assoc "plan_id" fields
  | _ -> false
let refuse kind message = raise (Refusal (kind,message))
let strings values = Array (List.map (fun value -> String value) values)
let optional = function None -> Null | Some value -> String value

let topology (d : Declaration.t) = match d.topology with
  | Some value -> value | None -> refuse Invalid_declaration "missing topology"

let workload (d : Declaration.t) name =
  let t = topology d in
  let app = App_config.find d.apps name in
  let guest = List.find_opt (fun guest -> Guest_config.name guest = name) d.guests in
  let kind, host, endpoint, target, jumps, lock_kind, lock_id = match app,guest with
    | Some app, None ->
        let host = Topology.jail_host t name in
        "freebsd_jail",host,app.endpoint,host.ssh,Topology.host_jumps t host,"host",host.id
    | None, Some guest ->
        let host = Topology.guest_host t name in
        "linux_guest",host,guest.endpoint,guest.login_user ^ "@" ^ guest.endpoint.ip,
        Topology.guest_jumps t name,"guest",name
    | None, None -> refuse Unknown_workload ("unknown workload: " ^ name)
    | Some _, Some _ -> refuse Invalid_declaration ("ambiguous workload: " ^ name) in
  Object ["name",String name; "kind",String kind; "host_id",String host.id;
    "ssh_target",String target; "ssh_jumps",strings jumps;
    "ip",String endpoint.ip; "hostname",String endpoint.hostname;
    "proxied",Bool (List.mem name (Topology.proxy_workloads t));
    "mutation_lock",Object ["kind",String lock_kind; "id",String lock_id]]

let inventory (d : Declaration.t) =
  let t = topology d in
  let hosts = Topology.hosts t |> List.sort (fun (a : Topology.host) b -> String.compare a.id b.id)
    |> List.map (fun (h : Topology.host) -> Object ["id",String h.id;
        "os",String (match h.os with Topology.Freebsd -> "freebsd" | Topology.Linux -> "linux");
        "ssh_target",String h.ssh; "via",optional h.via;
        "ssh_jumps",strings (Topology.host_jumps t h)]) in
  let names = App_config.names d.apps @ List.map Guest_config.name d.guests |> List.sort String.compare in
  Object ["scope",String "declaration"; "host_inspected",Bool false;
    "hosts",Array hosts; "workloads",Array (List.map (workload d) names);
    "edge_host_id",String (Topology.edge t).id]

let plan (d : Declaration.t) name revision =
  let target = workload d name in
  let result = match App_config.find d.apps name with
    | Some app -> Artifact_plan.of_app ?revision app
    | None -> Artifact_plan.of_guest ?revision (List.find (fun g -> Guest_config.name g = name) d.guests) in
  let p = match result with Ok p -> p | Error message -> refuse Invalid_plan message in
  let origin = match p.origin with
    | Artifact_plan.Phoenix_source s -> Object ["kind",String "phoenix_source";
        "checkout",String s.checkout; "requested_revision",String s.revision; "release_name",String s.release_name]
    | Artifact_plan.Ocaml_source s -> Object ["kind",String "ocaml_source";
        "checkout",String s.checkout; "requested_revision",String s.revision]
    | Artifact_plan.Guest_source s -> Object ["kind",String "guest_source";
        "checkout",String s.checkout; "requested_revision",String s.revision]
    | Artifact_plan.Verified_binary s -> Object ["kind",String "pinned_binary";
        "version",String s.version; "sha256",String s.sha256]
    | Artifact_plan.Freebsd_packages names -> Object ["kind",String "freebsd_packages"; "package_names",strings names] in
  Object ["kind",String "design_preview"; "name",String name; "target",target; "origin",origin;
    "host_inspected",Bool false; "source_verified",Bool false; "artifact_identity",Null;
    "authorized_to_apply",Bool false; "database_rollback",Bool false]

let parse argv =
  if List.length (List.filter ((=) "--json") argv) <> 1 then refuse Invalid_request "expected exactly one --json";
  match List.filter (fun arg -> arg <> "--json" && arg <> "--progress=jsonl") argv with
  | ["validate"] -> Validate
  | ["inspect"] -> Inspect
  | ["artifact"; "plan"; name] -> Plan (name,None)
  | ["artifact"; "plan"; name; "--revision"; revision] -> Plan (name,Some revision)
  | ("validate" | "inspect") :: _ | "artifact" :: "plan" :: _ ->
      refuse Invalid_request "unsupported arguments for this read-only operation"
  | _ -> refuse Unsupported_operation "JSON currently supports inspect, validate and artifact plan only"

let run ~layout argv =
  let args = List.filter (fun arg -> not (String.starts_with ~prefix:"--" arg)) argv in
  let operation = match args with "artifact" :: action :: _ -> "artifact." ^ action
    | action :: _ -> action | [] -> "usage" in
  let error status kind message = {operation; status; data=Null; error=Some (kind,message)} in
  try
    let request = parse argv in
    let layout = try layout () with Failure message | Sys_error message -> refuse Input_unavailable message in
    Progress.phase "inputs";
    let d = match Declaration.load ~layout with
      | Ok d -> d | Error e -> refuse Invalid_declaration (Declaration.error_message e) in
    let data = match request with
      | Inspect -> Progress.phase "inspect"; inventory d
      | Plan (name,revision) -> Progress.phase "plan"; plan d name revision
      | Validate ->
          Progress.phase "validate";
          (match Config_drift.check d with
           | [] -> ()
           | drift -> refuse Invalid_declaration (String.concat "\n" (List.map Config_drift.message drift)));
          (match Idp_declaration.load ~layout with
           | Ok _ -> () | Error message -> refuse Invalid_declaration message);
          let files = match Validation.render_all d with
            | Ok files -> files | Error message -> refuse Render_failed message in
          Object ["apps",Json.of_int (List.length d.apps); "guests",Json.of_int (List.length d.guests);
            "rendered_files",strings (List.map fst files); "host_inspected",Bool false] in
    {operation; status=Succeeded; data; error=None}
  with
  | Refusal (kind,message) -> error Refused kind message
  | Sys.Break -> error Cancelled Interrupted "interrupted before any host operation"
  | _ -> error Failed Internal_error "unexpected local error; no host operation was performed"

(* A stage and lock the run left behind, and the command that clears the
   lock once the host has been inspected. *)
let retained_json () =
  Array (List.map (fun (r : Run_state.retained) ->
    Object [ "host", String r.host; "stage", String r.stage; "during", String r.context;
             "inspect", strings [ "serai"; "locks"; "--json" ];
             "unlock_after_inspection", strings [ "serai"; "unlock"; r.host ] ]) (Run_state.retained ()))

let plan_json (p : Run_state.planned) =
  Object [ "operation", String p.operation; "plan_id", String (Plan_id.to_string p.id);
           "question", String p.question;
           "facts", Object (List.map (fun (name, value) -> name, String value) p.facts);
           "applied", Bool false ]

(* Where the run stood when it ended decides what an error means: nothing
   had changed (refused), a host may have (failed), or a stage and lock
   were left because the outcome on a host is not known (unknown). *)
let respond ~operation f =
  let with_retained data = match Run_state.retained (), data with
    | [], data -> data
    | _, Object fields -> Object (fields @ [ "retained", retained_json () ])
    | _, _ -> Object [ "retained", retained_json () ] in
  let ended ?(data = Null) ~refused message =
    let status, kind = match Run_state.retained (), Run_state.has_changed () with
      | _ :: _, _ -> Unknown, Outcome_unknown
      | [], true -> Failed, Apply_failed
      | [], false -> refused in
    { operation; status; data = with_retained data; error = Some (kind, message) } in
  match f () with
  | Ok data when Run_state.retained () = [] -> { operation; status = Succeeded; data; error = None }
  | Ok data -> ended ~data ~refused:(Refused, Not_applied) "the run left a stage and lock for inspection"
  | Error (data, message) ->
      (match ended ~data ~refused:(Failed, Step_failed) message with
       | { status = Failed; _ } as response -> { response with error = Some (Step_failed, message) }
       | response -> response)
  | exception Run_state.Planned plan -> { operation; status = Succeeded; data = plan_json plan; error = None }
  | exception Failure message -> ended ~refused:(Refused, Not_applied) message
  | exception Plan_id.Stale message -> ended ~refused:(Refused, Stale_plan) message
  | exception Bad_request message -> ended ~refused:(Refused, Invalid_request) message
  | exception Sys.Break ->
      (match ended ~refused:(Cancelled, Interrupted) "interrupted" with
       | { status = Failed; _ } as response -> { response with status = Cancelled; error = Some (Interrupted, "interrupted") }
       | response -> response)
  | exception exn -> ended ~refused:(Failed, Internal_error) (Printexc.to_string exn)
