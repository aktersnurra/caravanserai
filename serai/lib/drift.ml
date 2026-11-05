type app_drift =
  | App_checked of {
      app : string;
      state : Drift_app.state;
      live : string option;
      target : Drift_app.target;
      plan : Dispatcher.up_plan option;
    }
  | App_unavailable of { app : string; message : string }
  | App_not_covered of string

let app (env : Dispatcher.env) name ~cache ~store =
  let source_built (app : App_config.t) =
    match app.strategy with
    | Strategy_config.Freebsd_native_elixir _ | Freebsd_native_ocaml _ -> true
    | Freebsd_package _ | Fetch_binary _ | Freebsd_package_service _ -> false in
  if not (source_built (Dispatcher.find_app env name)) then App_not_covered name
  else
    let ok = function Ok value -> value | Error message -> failwith message in
    let jj_bin = env.jj_bin in
    match
      let topology = match env.topology with
        | Some topology -> topology | None -> failwith "drift: configured topology required" in
      let inputs = ok (Up_inputs.of_app ~topology (Dispatcher.find_app env name)) in
      let releases = Dispatcher.probe_releases env name in
      let mirror = ok (Source_mirror.sync ~jj_bin ~cache ~name ~url:inputs.source_url) in
      let deploy = ok (Source_mirror.remote_bookmark ~jj_bin mirror Update.deploy_bookmark) in
      let default_branch = lazy (Result.bind (Source_mirror.default_branch ~jj_bin mirror) (fun revision ->
          Result.map (fun commit -> (revision, commit)) (Source_mirror.resolve ~jj_bin mirror ~revision))) in
      let target = ok (Drift_app.target ~deploy ~default_branch) in
      let descends () =
        let live = Option.get releases.source in
        Result.bind (Source_mirror.has_commit ~jj_bin mirror live) (function
          | false -> Ok false
          | true -> Source_mirror.is_ancestor ~jj_bin mirror ~ancestor:live ~descendant:target.commit) in
      let state = ok (Drift_app.decide releases ~target:target.commit ~descends) in
      let plan =
        if Drift_app.drifted state then Some (Dispatcher.up_plan env name ~revision:target.commit ~cache ~store)
        else None in
      App_checked { app = name; state; live = releases.source; target; plan }
    with
    | checked -> checked
    | exception Failure message -> App_unavailable { app = name; message }

type 'a section = Checked of 'a | Unavailable of string | Not_declared

type t = { edge : Dispatcher.edge_plan section; idp : Idp_plan.t section; apps : app_drift list }

let idp (env : Dispatcher.env) =
  match Idp_declaration.load ~layout:env.layout with
  | Error message -> Unavailable message
  | Ok None -> Not_declared
  | Ok (Some declaration) -> (
      match Pocket_id.session ~url:declaration.url with
      | Error message -> Unavailable message
      | Ok session -> (
          match Pocket_id.fetch ~curl_bin:env.curl_bin session with
          | Error error -> Unavailable (Pocket_id.error_message error)
          | Ok live -> Checked (Idp_plan.plan declaration live)))

let run (env : Dispatcher.env) ~cache ~store =
  let edge = match Dispatcher.plan_edge env with
    | plan -> Checked plan
    | exception Failure message -> Unavailable message in
  let idp = idp env in
  let apps =
    List.map (fun (a : App_config.t) -> app env a.endpoint.name ~cache ~store) env.config
    @ List.map (fun guest -> App_not_covered guest) (Dispatcher.list_guests env) in
  { edge; idp; apps }

let drifted t =
  let edge = match t.edge with Checked plan -> plan.plan_id <> None | Unavailable _ | Not_declared -> false in
  let idp = match t.idp with Checked plan -> plan.plan_id <> None | Unavailable _ | Not_declared -> false in
  edge || idp
  || List.exists (function App_checked { state; _ } -> Drift_app.drifted state | App_unavailable _ | App_not_covered _ -> false) t.apps

let complete t =
  let available = function Unavailable _ -> false | Checked _ | Not_declared -> true in
  available t.edge && available t.idp
  && List.for_all (function App_unavailable _ -> false | App_checked _ | App_not_covered _ -> true) t.apps

let exit_code t = if drifted t then 2 else if complete t then 0 else 1
