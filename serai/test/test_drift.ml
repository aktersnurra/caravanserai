(* Drift's summary: whether anything drifted, whether every section was
   checked, and the exit code an agent or cron reads. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let id = Result.get_ok (Plan_id.parse "0123456789abcdef")
let edge pending : Dispatcher.edge_plan =
  { components = (if pending then [ ("pf", "compute") ] else []); plan_id = (if pending then Some id else None) }
let idp pending : Idp_plan.t =
  { actions = []; undeclared = []; secrets_needed = []; lockout = None; plan_id = (if pending then Some id else None) }
let target : Drift_app.target = { revision = "deploy"; commit = String.make 40 'b' }
let app state : Drift.app_drift =
  App_checked { app = "hello"; state; live = Some (String.make 40 'a'); target; plan = None }

let t ?(edge = Drift.Checked (edge false)) ?(idp = Drift.Checked (idp false)) ?(apps = []) () : Drift.t =
  { edge; idp; apps }

let () =
  let clean = t ~apps:[ app Current; app Unknown; App_not_covered "logs" ] ~idp:Not_declared () in
  check "nothing pending, everything checked: not drifted, complete, exit 0"
    (not (Drift.drifted clean) && Drift.complete clean && Drift.exit_code clean = 0);
  List.iter (fun (what, drifted) ->
      check ("drifted: " ^ what) (Drift.drifted drifted && Drift.complete drifted && Drift.exit_code drifted = 2))
    [ ("an edge plan", t ~edge:(Checked (edge true)) ());
      ("an idp plan", t ~idp:(Checked (idp true)) ());
      ("an app behind", t ~apps:[ app Behind ] ());
      ("an app diverged", t ~apps:[ app Diverged ] ());
      ("an app not deployed", t ~apps:[ app Not_deployed ] ()) ];
  List.iter (fun (what, partial) ->
      check ("incomplete: " ^ what) ((not (Drift.drifted partial)) && (not (Drift.complete partial)) && Drift.exit_code partial = 1))
    [ ("the edge", t ~edge:(Unavailable "lock held") ());
      ("the idp", t ~idp:(Unavailable "no key") ());
      ("an app", t ~apps:[ App_unavailable { app = "hello"; message = "probe failed" } ] ()) ];
  let both = t ~edge:(Unavailable "lock held") ~apps:[ app Behind ] () in
  check "drifted and incomplete: exit 2, still incomplete"
    (Drift.drifted both && (not (Drift.complete both)) && Drift.exit_code both = 2)
