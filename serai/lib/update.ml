type config = {
  config_url : string;
  config_bookmark : string;
  signers : string list;
  gnupghome : string;
}

let context = "update.sexp"

let config_of_string text =
  let open Sexplib in
  let atom = Sexp_fields.atom ~context in
  match
    let fields = Sexp_fields.fields_of_sexp ~context ~known:[ "config"; "signers"; "gnupghome" ]
        (Sexp.of_string text) in
    let source = Sexp_fields.fields_of_sexp ~context:(context ^ " config") ~known:[ "git"; "bookmark" ]
        (Sexp_fields.field ~context "config" fields) in
    let config_url = atom (Sexp_fields.field ~context "git" source) in
    let config_bookmark = atom (Sexp_fields.field ~context "bookmark" source) in
    let signers = Sexp_fields.list ~context atom (Sexp_fields.field ~context "signers" fields) in
    let gnupghome = atom (Sexp_fields.field ~context "gnupghome" fields) in
    if config_url = "" || config_bookmark = "" then failwith "config needs a git remote and a bookmark";
    if signers = [] || List.mem "" signers then failwith "signers must name at least one key";
    if Filename.is_relative gnupghome then failwith "gnupghome must be an absolute path";
    { config_url; config_bookmark; signers; gnupghome }
  with
  | config -> Ok config
  | exception Conv.Of_sexp_error (Failure message, _) -> Error message
  | exception Conv.Of_sexp_error (exn, _) -> Error (Printexc.to_string exn)
  | exception Failure message -> Error (context ^ ": " ^ message)
  | exception Parsing.Parse_error -> Error (context ^ ": unreadable")

let deploy_bookmark = "deploy"
let configuration_mirror = "configuration.serai"

type paths = { state_dir : string; cache : string; store : string; engine : string }

type revert = Not_attempted of string | Reverted | Revert_failed of string

type outcome =
  | Not_enrolled
  | Built_on_controller
  | Already_handled of string
  | Current of string
  | Would_deploy of string
  | Deployed of { commit : string; identity : string }
  | Refused of { commit : string; refusal : Update_decision.refusal }
  | Failed of { commit : string; step : Dispatcher.up_step; message : string; revert : revert }
  | Not_applied of { commit : string option; message : string }

type configuration =
  | Configuration of string
  | Configuration_refused of { commit : string; refusal : Update_decision.refusal }
  | Configuration_unavailable of string

type report = { configuration : configuration; apps : (string * outcome) list }
type deps = { jj_bin : string; env_of_layout : Layout.t -> Dispatcher.env }

let ( let* ) = Result.bind
let verification config = [ ("GNUPGHOME", config.gnupghome) ]

(* The configuration's commit the run works from: its bookmark on the
   remote, signed by an allowed key, staged locally and located on the
   installed engine. *)
let verified_configuration deps config paths =
  let unavailable result = Result.map_error (fun message -> Configuration_unavailable message) result in
  let* mirror = unavailable (Source_mirror.sync ~jj_bin:deps.jj_bin ~cache:paths.cache
      ~name:configuration_mirror ~url:config.config_url) in
  let* commit = unavailable (Source_mirror.remote_bookmark ~jj_bin:deps.jj_bin mirror config.config_bookmark) in
  let* commit = match commit with
    | Some commit -> Ok commit
    | None -> Error (Configuration_unavailable (config.config_bookmark ^ " is not on the configuration's remote")) in
  let* signature = unavailable (Source_mirror.signature ~jj_bin:deps.jj_bin
      ~extra_env:(verification config) mirror ~commit) in
  let* () = Result.map_error (fun refusal -> Configuration_refused { commit; refusal })
      (Update_decision.check_signature ~allowed:config.signers signature) in
  let* _, tree = unavailable (Source_snapshot.stage_cached ~jj_bin:deps.jj_bin
      ~checkout:(Source_mirror.path mirror) ~revision:commit
      ~cache:(Filename.concat paths.cache "configuration-snapshots")) in
  let* layout = unavailable (Layout.discover ~from:tree ~installed:paths.engine) in
  Ok (commit, layout)

(* The apps an update may deploy: source-built, with a declared source,
   and whether each migrates. *)
type source_app = { name : string; url : string option; migrate : bool; controller_built : bool }

(* A web bundle is built on the controller, which the compute host is not. *)
let source_apps (env : Dispatcher.env) =
  List.filter_map (fun (app : App_config.t) ->
      let kind = match app.strategy with
        | Strategy_config.Freebsd_native_elixir s -> Some (Option.is_some s.migrate, false)
        | Freebsd_native_ocaml s -> Some (Option.is_some s.migrate, Option.is_some s.web_bundle)
        | Freebsd_package _ | Fetch_binary _ | Freebsd_package_service _ -> None in
      let url = match env.topology with
        | Some topology -> Result.to_option (Result.map (fun (i : Up_inputs.t) -> i.source_url)
            (Up_inputs.of_app ~topology app))
        | None -> None in
      match kind with
      | Some (migrate, controller_built) -> Some { name = app.endpoint.name; url; migrate; controller_built }
      | None -> None)
    env.config

let deploy paths env ~name ~commit ~migrate =
  match Dispatcher.up_run ~target:Dispatcher.Update env name ~revision:commit ~cache:paths.cache ~store:paths.store with
  | exception Failure message -> Not_applied { commit = Some commit; message }
  | _, { result = Deployed identity; _ } -> Deployed { commit; identity }
  | _, { result = Stopped_for_env _; _ } -> invalid_arg "update: up stopped for an env it never creates"
  | _, { result = Step_failed (Release, message); _ } -> (
      (* Whether the switch happened decides between retrying and a final
         failure, and whether there is anything to revert. *)
      match Dispatcher.probe_releases env name with
      | exception Failure probe ->
          Failed { commit; step = Release; message;
                   revert = Not_attempted ("could not tell whether the new release is active: " ^ probe) }
      | { source; _ } when source <> Some commit -> Not_applied { commit = Some commit; message }
      | _ when Update_decision.should_revert ~step:Release ~migrate ~active_is_desired:true ->
          let revert = match Dispatcher.revert env name with
            | () -> Reverted
            | exception Failure failure -> Revert_failed failure in
          Failed { commit; step = Release; message; revert }
      | _ ->
          Failed { commit; step = Release; message;
                   revert = Not_attempted "it declares migrate; roll back with serai artifact rollback" })
  | _, { result = Step_failed (step, message); _ } ->
      let why = match step with
        | Check -> "the release is healthy in its jail"
        | Jail | Build | Release | Edge -> "nothing was switched" in
      Failed { commit; step; message; revert = Not_attempted why }

let app_outcome ~plan deps config paths env ~handled { name; url; migrate; controller_built } =
  let not_applied ?commit message = Not_applied { commit; message } in
  match url with
  | _ when controller_built -> Built_on_controller
  | None -> Not_enrolled
  | Some url ->
  match Source_mirror.sync ~jj_bin:deps.jj_bin ~cache:paths.cache ~name ~url with
  | Error message -> not_applied message
  | Ok mirror ->
  match Source_mirror.remote_bookmark ~jj_bin:deps.jj_bin mirror deploy_bookmark with
  | Error message -> not_applied message
  | Ok desired ->
  match Update_decision.triage ~desired ~handled with
  | Not_enrolled -> Not_enrolled
  | Already_handled -> Already_handled (Option.value desired ~default:"")
  | Examine commit ->
  match Source_mirror.signature ~jj_bin:deps.jj_bin ~extra_env:(verification config) mirror ~commit with
  | Error message -> not_applied ~commit message
  | Ok signature ->
  match Dispatcher.probe_releases env name with
  | exception Failure message -> not_applied ~commit message
  | { source = deployed; _ } ->
  let descends = match deployed with
    | None -> Ok false
    | Some deployed -> Source_mirror.is_ancestor ~jj_bin:deps.jj_bin mirror ~ancestor:deployed ~descendant:commit in
  match descends with
  | Error message -> not_applied ~commit message
  | Ok descends ->
  match Update_decision.examine ~desired:commit ~deployed ~signature ~allowed:config.signers ~descends with
  | Current -> Current commit
  | Refuse refusal -> Refused { commit; refusal }
  | Deploy when plan -> Would_deploy commit
  | Deploy -> deploy paths env ~name ~commit ~migrate

(* One app's error is that app's; the loop goes on. *)
let examine ~plan deps config paths ~handled =
  match verified_configuration deps config paths with
  | Error configuration -> { configuration; apps = [] }
  | Ok (commit, layout) ->
      let env = deps.env_of_layout layout in
      let apps = List.map (fun ({ name; _ } as app) ->
          let outcome =
            try app_outcome ~plan deps config paths env ~handled:(handled name) app
            with Failure message -> Not_applied { commit = None; message } in
          name, outcome) (source_apps env) in
      { configuration = Configuration commit; apps }

let plan deps config paths = examine ~plan:true deps config paths ~handled:(fun _ -> None)

let short commit = if String.length commit > 12 then String.sub commit 0 12 else commit

let configuration_line = function
  | Configuration _ -> None
  | Configuration_refused { commit; refusal } ->
      Some (Printf.sprintf "configuration: refused %s: %s" (short commit) (Update_decision.refusal_message refusal))
  | Configuration_unavailable message -> Some ("configuration: unavailable: " ^ message)

let revert_text = function
  | Reverted -> "reverted to the previous release"
  | Revert_failed message -> "revert failed: " ^ message
  | Not_attempted why -> "not reverted: " ^ why

(* The line a run reports for an app, if any; and whether it is a failure. *)
let line name = function
  | Not_enrolled | Built_on_controller | Already_handled _ | Current _ -> None
  | Would_deploy commit -> Some (Printf.sprintf "%s: would deploy %s" name (short commit), false)
  | Deployed { commit; identity } ->
      Some (Printf.sprintf "%s: deployed %s as %s" name (short commit) (short identity), false)
  | Refused { commit; refusal } ->
      Some (Printf.sprintf "%s: refused %s: %s" name (short commit) (Update_decision.refusal_message refusal), true)
  | Failed { commit; step; message; revert } ->
      Some (Printf.sprintf "%s: %s failed at %s: %s; %s" name (short commit) (Dispatcher.step_name step)
              message (revert_text revert), true)
  | Not_applied { commit; message } ->
      Some (Printf.sprintf "%s: not applied%s: %s; tried again next run" name
              (match commit with Some commit -> " " ^ short commit | None -> "") message, true)

let plan_lines report =
  Option.to_list (configuration_line report.configuration)
  @ List.map (fun (name, outcome) ->
      match line name outcome, outcome with
      | Some (text, _), _ -> text
      | None, Not_enrolled -> name ^ ": not enrolled (no deploy bookmark)"
      | None, Built_on_controller -> name ^ ": built on the controller (web bundle); deploy it with serai up"
      | None, Already_handled commit -> Printf.sprintf "%s: %s already handled" name (short commit)
      | None, Current commit -> Printf.sprintf "%s: current at %s" name (short commit)
      | None, _ -> name) report.apps

type run = { report : report; lines : string list; failed : bool }

(* A final outcome marks its commit handled; a silent one forgets the last
   report, so the same words for a later commit are reported again. *)
let record (state : Update_state.t) report =
  match report.configuration with
  | Configuration_refused _ | Configuration_unavailable _ ->
      { state with config_reported = configuration_line report.configuration }
  | Configuration _ ->
      let state = { state with config_reported = None } in
      let state = Update_state.retain state ~apps:(List.map fst report.apps) in
      List.fold_left (fun state (name, outcome) ->
          let last = Update_state.find state name in
          let handled = match outcome with
            | Current commit | Already_handled commit -> Some commit
            | Deployed { commit; _ } | Refused { commit; _ } | Failed { commit; _ } -> Some commit
            | Not_enrolled | Built_on_controller -> None
            | Would_deploy _ | Not_applied _ -> last.handled in
          let reported = match line name outcome, outcome with
            | Some (text, _), _ -> Some text
            | None, Already_handled _ -> last.reported
            | None, _ -> None in
          Update_state.set state name { handled; reported })
        state report.apps

let run deps config paths =
  Update_state.with_run_lock ~dir:paths.state_dir (fun () ->
    let state = match Update_state.load ~dir:paths.state_dir with
      | Ok state -> state | Error message -> failwith message in
    let report =
      examine ~plan:false deps config paths ~handled:(fun name -> (Update_state.find state name).handled) in
    let candidates =
      (match configuration_line report.configuration with
       | Some text -> [ state.config_reported, text, true ]
       | None -> [])
      @ List.filter_map (fun (name, outcome) ->
          Option.map (fun (text, failure) -> (Update_state.find state name).reported, text, failure)
            (line name outcome)) report.apps in
    let reported = List.filter (fun (last, text, _) -> Update_decision.should_report ~last ~current:text) candidates in
    (match Update_state.save ~dir:paths.state_dir (record state report) with
     | Ok () -> () | Error message -> failwith message);
    { report;
      lines = List.map (fun (_, text, _) -> text) reported;
      failed = List.exists (fun (_, _, failure) -> failure) reported })
