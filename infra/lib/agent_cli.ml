(* Deliberately no Proc/Dispatcher dependency: this surface cannot mutate hosts. *)
type json = Null | Bool of bool | Int of int | Text of string
          | Array of json list | Object of (string * json) list

type error_code = Invalid_request | Unsupported_operation | Input_unavailable
  | Invalid_declaration | Invalid_plan | Unknown_workload | Render_failed
  | Internal_error | Interrupted | Not_applied | Step_failed

type status = Succeeded | Refused | Failed | Cancelled
type response = { operation : string; status : status; data : json;
                  error : (error_code * string) option }
type request = Validate | Inspect | Plan of string * string option
exception Refusal of error_code * string

let code = function
  | Invalid_request -> "invalid_request" | Unsupported_operation -> "unsupported_operation"
  | Input_unavailable -> "input_unavailable" | Invalid_declaration -> "invalid_declaration"
  | Invalid_plan -> "invalid_plan" | Unknown_workload -> "unknown_workload"
  | Render_failed -> "render_failed" | Internal_error -> "internal_error"
  | Interrupted -> "interrupted" | Not_applied -> "not_applied" | Step_failed -> "step_failed"

let quote text =
  let b = Buffer.create (String.length text + 2) in
  Buffer.add_char b '"';
  String.iter (function
    | '"' -> Buffer.add_string b "\\\"" | '\\' -> Buffer.add_string b "\\\\"
    | c when Char.code c < 32 -> Buffer.add_string b (Printf.sprintf "\\u%04x" (Char.code c))
    | c -> Buffer.add_char b c) text;
  Buffer.add_char b '"'; Buffer.contents b

let rec encode = function
  | Null -> "null" | Bool value -> string_of_bool value | Int value -> string_of_int value
  | Text value -> quote value
  | Array values -> "[" ^ String.concat "," (List.map encode values) ^ "]"
  | Object fields -> "{" ^ String.concat "," (List.map (fun (k,v) -> quote k ^ ":" ^ encode v) fields) ^ "}"

let to_json response =
  let status = match response.status with Succeeded -> "succeeded" | Refused -> "refused"
    | Failed -> "failed" | Cancelled -> "interrupted" in
  let error = match response.error with None -> Null | Some (kind,message) ->
    Object ["code",Text (code kind); "message",Text message] in
  encode (Object ["schema_version",Int 1; "operation",Text response.operation;
    "status",Text status; "data",response.data; "error",error])

let exit_code response = match response.status with Succeeded -> 0 | Cancelled -> 130 | Refused | Failed -> 1
let refuse kind message = raise (Refusal (kind,message))
let strings values = Array (List.map (fun value -> Text value) values)
let optional = function None -> Null | Some value -> Text value

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
  Object ["name",Text name; "kind",Text kind; "host_id",Text host.id;
    "ssh_target",Text target; "ssh_jumps",strings jumps;
    "ip",Text endpoint.ip; "hostname",Text endpoint.hostname;
    "proxied",Bool (List.mem name (Topology.proxy_workloads t));
    "mutation_lock",Object ["kind",Text lock_kind; "id",Text lock_id]]

let inventory (d : Declaration.t) =
  let t = topology d in
  let hosts = Topology.hosts t |> List.sort (fun (a : Topology.host) b -> String.compare a.id b.id)
    |> List.map (fun (h : Topology.host) -> Object ["id",Text h.id;
        "os",Text (match h.os with Topology.Freebsd -> "freebsd" | Topology.Linux -> "linux");
        "ssh_target",Text h.ssh; "via",optional h.via;
        "ssh_jumps",strings (Topology.host_jumps t h)]) in
  let names = App_config.names d.apps @ List.map Guest_config.name d.guests |> List.sort String.compare in
  Object ["scope",Text "declaration"; "host_inspected",Bool false;
    "hosts",Array hosts; "workloads",Array (List.map (workload d) names);
    "edge_host_id",Text (Topology.edge t).id]

let plan (d : Declaration.t) name revision =
  let target = workload d name in
  let result = match App_config.find d.apps name with
    | Some app -> Artifact_plan.of_app ?revision app
    | None -> Artifact_plan.of_guest ?revision (List.find (fun g -> Guest_config.name g = name) d.guests) in
  let p = match result with Ok p -> p | Error message -> refuse Invalid_plan message in
  let origin = match p.origin with
    | Artifact_plan.Phoenix_source s -> Object ["kind",Text "phoenix_source";
        "checkout",Text s.checkout; "requested_revision",Text s.revision; "release_name",Text s.release_name]
    | Artifact_plan.Ocaml_source s -> Object ["kind",Text "ocaml_source";
        "checkout",Text s.checkout; "requested_revision",Text s.revision]
    | Artifact_plan.Guest_source s -> Object ["kind",Text "guest_source";
        "checkout",Text s.checkout; "requested_revision",Text s.revision]
    | Artifact_plan.Verified_binary s -> Object ["kind",Text "pinned_binary";
        "version",Text s.version; "sha256",Text s.sha256]
    | Artifact_plan.Freebsd_packages names -> Object ["kind",Text "freebsd_packages"; "package_names",strings names] in
  Object ["kind",Text "design_preview"; "name",Text name; "target",target; "origin",origin;
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
          let files = match Validation.render_all d with
            | Ok files -> files | Error message -> refuse Render_failed message in
          Object ["apps",Int (List.length d.apps); "guests",Int (List.length d.guests);
            "rendered_files",strings (List.map fst files); "host_inspected",Bool false] in
    {operation; status=Succeeded; data; error=None}
  with
  | Refusal (kind,message) -> error Refused kind message
  | Sys.Break -> error Cancelled Interrupted "interrupted before any host operation"
  | _ -> error Failed Internal_error "unexpected local error; no host operation was performed"

let respond ~operation f =
  let error status kind message = {operation; status; data=Null; error=Some (kind,message)} in
  match f () with
  | Ok data -> {operation; status=Succeeded; data; error=None}
  | Error (data, message) -> {operation; status=Failed; data; error=Some (Step_failed, message)}
  | exception Failure message -> error Refused Not_applied message
  | exception Sys.Break -> error Cancelled Interrupted "interrupted"
  | exception exn -> error Failed Internal_error (Printexc.to_string exn)
