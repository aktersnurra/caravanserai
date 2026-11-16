type flag = { flag : string; value : string option; required : bool }
type effect = Offline | Reads_hosts | Changes_files | Changes_hosts
type approval = No_approval | Own_plan | Bound | Bound_by_request

type command = {
  path : string list;
  arguments : (string * bool) list;
  flags : flag list;
  summary : string;
  effect : effect;
  approval : approval;
}

type invocation = {
  command : command;
  arguments : string list;
  flags : (string * string) list;
  json : bool;
  yes : bool;
  progress : bool;
  plan : bool;
  expect_plan : string option;
}

type error = Unknown_command | Bad_arguments of command * string

let valued ?(required = false) flag value = { flag; value = Some value; required }
let switch flag = { flag; value = None; required = false }
let need = valued ~required:true

let command ?(arguments = []) ?(flags = []) ?(approval = No_approval) path effect summary =
  { path = String.split_on_char ' ' path; arguments; flags; summary; effect; approval }

let app = [ "app", true ] and guest = [ "guest", true ] and workload = [ "app|guest", true ]
let store_entry = [ need "--identity" "identity"; need "--store" "dir" ]

let commands = [
  command "apps" Offline "the declared apps";
  command "guests" Offline "the declared guests";
  command "commands" Offline "this table: every command, its arguments and what it may change";
  command "inspect" Offline "the declared topology, not live state";
  command "validate" Offline ~flags:[ valued "--out" "dir" ] "load and render the whole declaration";
  command "render-logging-targets" Offline "the jails central logging forwards from";
  command "artifact plan" Offline ~arguments:workload ~flags:[ valued "--revision" "rev" ]
    "a design preview of the workload's artifact; no approval";
  command "artifact source-stage" Changes_files ~arguments:workload
    ~flags:[ need "--revision" "rev"; need "--out" "dir" ] "export committed source locally";
  command "artifact build" Changes_hosts ~approval:Bound ~arguments:workload
    ~flags:[ valued "--revision" "rev"; valued "--ip" "builder-ip"; valued "--base" "txz"; valued "--sha256" "digest";
             need "--store" "dir"; valued "--opam-repository" "checkout"; valued "--opam-revision" "rev";
             valued "--compiler" "ocaml-variants.version"; valued "--reuse" "identity" ]
    "build and store a verified artifact, or verify a stored one with --reuse";
  command "artifact install" Changes_hosts ~approval:Bound_by_request ~arguments:app
    ~flags:[ need "--identity" "identity"; need "--archive" "tar"; need "--sha256" "digest" ]
    "stage and verify a release in its jail; no activation";
  command "artifact upgrade" Changes_hosts ~approval:Bound ~arguments:workload ~flags:store_entry
    "install, switch to and check a stored artifact";
  command "artifact rollback" Changes_hosts ~approval:Bound ~arguments:workload ~flags:store_entry
    "switch back to the retained previous artifact; files only";
  command "artifact convert" Changes_hosts ~approval:Bound ~arguments:workload ~flags:store_entry
    "move a byte-equivalent legacy executable under the release layout";
  command "revert" Changes_hosts ~approval:Bound ~arguments:app
    "reactivate the previous release where it is installed; apps without migrate";
  command "new" Changes_files ~arguments:app
    ~flags:[ need "--kind" "phoenix|ocaml"; need "--repo" "checkout"; valued "--hostname" "fqdn" ]
    "declare a new app; touches no host";
  command "bootstrap" Changes_hosts ~approval:Bound_by_request ~arguments:app "create or converge the app's jail";
  command "deploy" Changes_hosts ~approval:Bound_by_request ~arguments:workload
    "an app's deploy hook, or a guest's build, install and provision";
  command "provision" Changes_hosts ~approval:Bound_by_request ~arguments:guest "provision a guest";
  command "build" Changes_hosts ~approval:Bound_by_request ~arguments:guest "build a guest's workload on it";
  command "check" Reads_hosts ~arguments:app "the service's status and its direct and public endpoints";
  command "up" Changes_hosts ~approval:Own_plan ~arguments:app
    ~flags:[ need "--revision" "bookmark|commit"; valued "--source" "checkout"; switch "--rehearse";
             valued "--ip" "addr" ]
    "create a new app's jail, or build or reuse, release, check; edge changes need their own approval";
  command "edge" Changes_hosts ~approval:Own_plan "pf rules, the Headscale policy and Caddy's tree";
  command "drift" Reads_hosts "where the live system differs from the declaration, with the plan that fixes each part";
  command "status" Reads_hosts ~arguments:[ "app", false ] "each app's jail and releases, live";
  command "locks" Reads_hosts ~arguments:[ "host-id|guest", false ] "who holds each host's lock, and for how long";
  command "unlock" Changes_hosts ~approval:Bound_by_request ~arguments:[ "host-id|guest", true ]
    "remove a host's lock after inspecting it";
  command "caddy-install" Changes_hosts ~approval:Bound "build Caddy if needed, write its unit, install, reload";
  command "jail-test" Changes_hosts ~approval:Bound ~arguments:app
    ~flags:[ valued "--ip" "addr"; switch "--destroy" ] "run the generated jail script on <app>test, or destroy it";
  command "rollout" Changes_hosts ~approval:Bound_by_request ~arguments:app ~flags:[ switch "--edge" ]
    "the rollout pipeline";
  command "run" Changes_hosts ~approval:Bound_by_request ~arguments:[ "app", true; "pipeline", true ]
    "a named pipeline from pipelines.sexp";
  command "update-version" Changes_files ~arguments:[ "app", true; "version", false ] "the app's update-version hook";
  command "update" Changes_hosts ~approval:Own_plan "deploy what CI marked, if signed and newer";
  command "idp" Changes_hosts ~approval:Own_plan ~flags:[ switch "--export"; valued "--url" "url" ]
    "Pocket ID's users, groups, clients and APIs to match idp.sexp";
]

let rec is_prefix prefix list = match prefix, list with
  | [], _ -> true
  | p :: prefix, x :: list -> p = x && is_prefix prefix list
  | _ :: _, [] -> false

let find argv =
  List.filter (fun c -> is_prefix c.path argv) commands
  |> List.sort (fun a b -> compare (List.length b.path) (List.length a.path))
  |> function command :: _ -> Some command | [] -> None

let rec drop n list = if n = 0 then list else match list with [] -> [] | _ :: rest -> drop (n - 1) rest

let parse argv =
  match find argv with
  | None -> Error Unknown_command
  | Some command ->
      let bad message = Error (Bad_arguments (command, message)) in
      let takes_plan = command.approval <> No_approval in
      let rec go inv = function
        | [] -> Ok { inv with arguments = List.rev inv.arguments; flags = List.rev inv.flags }
        | "--json" :: rest when not inv.json -> go { inv with json = true } rest
        | "--yes" :: rest when not inv.yes -> go { inv with yes = true } rest
        | "--progress=jsonl" :: rest when not inv.progress -> go { inv with progress = true } rest
        | "--plan" :: rest when takes_plan && not inv.plan -> go { inv with plan = true } rest
        | "--expect-plan" :: id :: rest when takes_plan && inv.expect_plan = None ->
            go { inv with expect_plan = Some id } rest
        | token :: rest when String.starts_with ~prefix:"--" token ->
            (match List.find_opt (fun f -> f.flag = token) command.flags, rest with
             | None, _ -> bad ("unknown flag " ^ token)
             | Some _, _ when List.mem_assoc token inv.flags -> bad (token ^ " given twice")
             | Some { value = None; _ }, rest -> go { inv with flags = (token, "") :: inv.flags } rest
             | Some { value = Some _; _ }, value :: rest -> go { inv with flags = (token, value) :: inv.flags } rest
             | Some { value = Some name; _ }, [] -> bad (Printf.sprintf "%s needs <%s>" token name))
        | token :: rest -> go { inv with arguments = token :: inv.arguments } rest in
      Result.bind
        (go { command; arguments = []; flags = []; json = false; yes = false; progress = false; plan = false;
              expect_plan = None } (drop (List.length command.path) argv))
        (fun inv ->
          let required = List.length (List.filter snd command.arguments) in
          let given = List.length inv.arguments in
          match List.find_opt (fun f -> f.required && not (List.mem_assoc f.flag inv.flags)) command.flags with
          | _ when given < required || given > List.length command.arguments ->
              bad "wrong number of arguments"
          | Some missing -> bad (missing.flag ^ " is required")
          | None when inv.plan && inv.expect_plan <> None -> bad "--plan and --expect-plan exclude each other"
          | None -> Ok inv)

let flag inv name = List.assoc_opt name inv.flags
let has inv name = List.mem_assoc name inv.flags
let name command = String.concat " " command.path

let synopsis command =
  String.concat " "
    ([ "serai"; name command ]
     @ List.map (fun (argument, required) -> if required then "<" ^ argument ^ ">" else "[" ^ argument ^ "]")
         command.arguments
     @ List.map (fun f ->
           let text = match f.value with Some value -> Printf.sprintf "%s <%s>" f.flag value | None -> f.flag in
           if f.required then text else "[" ^ text ^ "]") command.flags
     @ (match command.approval with
        | No_approval -> []
        | Own_plan | Bound | Bound_by_request -> [ "[--plan | --expect-plan <id>]" ]))

let usage () =
  "usage:\n"
  ^ String.concat "" (List.map (fun c -> Printf.sprintf "  %s\n      %s\n" (synopsis c) c.summary) commands)
  ^ "  Every command takes --json (one result on stdout), --yes and --progress=jsonl.\n\
    \  With --json, a command that changes a host applies only an approved plan:\n\
    \  --plan to get its plan_id, then --yes --expect-plan <id>.\n"

let effect_name = function
  | Offline -> "offline" | Reads_hosts -> "reads_hosts"
  | Changes_files -> "changes_local_files" | Changes_hosts -> "changes_hosts"

let to_json () =
  let open Json in
  Object [
    "global_flags", Array (List.map (fun f -> String f) [ "--json"; "--yes"; "--progress=jsonl" ]);
    "commands", Array (List.map (fun c ->
      Object [
        "command", String (name c); "synopsis", String (synopsis c); "summary", String c.summary;
        "effect", String (effect_name c.effect);
        "plan", Bool (c.approval <> No_approval);
        "arguments", Array (List.map (fun (argument, required) ->
          Object [ "name", String argument; "required", Bool required ]) c.arguments);
        "flags", Array (List.map (fun f ->
          Object [ "flag", String f.flag;
                   "value", (match f.value with Some value -> String value | None -> Null);
                   "required", Bool f.required ]) c.flags) ]) commands) ]
