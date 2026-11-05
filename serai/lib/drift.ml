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
