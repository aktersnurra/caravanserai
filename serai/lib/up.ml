(* serai up: plan, then jail, build, release, edge and check. Part of
   Dispatcher. *)
open Remote_host
open App_hooks
open Artifact_lifecycle
open Edge_apply
open Test_jail

type up_target = Live | Rehearse of string | Update

type up_jail = Jail_ready | Jail_create | Jail_needs_env of string
type up_release = Reuse of string | Build of { ip : string; base_sha256 : string }

type up_plan = {
  app : string;
  host : string;
  source : string;
  commit : string;
  local : bool;
  release : up_release;
  jail : up_jail;
  rehearsal : (string * string) option;
  public_url : string;
}

let short = Hex.short

type up_step = Jail | Build | Release | Edge | Check
type step_status = Done | Skipped | Failed of string | Pending of string | Not_run
type up_result =
  | Deployed of string
  | Stopped_for_env of string
  | Stopped_for_edge of Plan_id.t
  | Step_failed of up_step * string
type up_outcome = { steps : (up_step * step_status) list; result : up_result }

let up_steps = [ Jail; Build; Release; Edge; Check ]
let step_index = function Jail -> 0 | Build -> 1 | Release -> 2 | Edge -> 3 | Check -> 4
let step_name = function
  | Jail -> "jail" | Build -> "build" | Release -> "release" | Edge -> "edge" | Check -> "check"

(* Everything the apply acts on, in a fixed order. *)
let up_plan_id_of ~app ~host ~source ~commit ~local ~release ~jail ~rehearsal ~public_url =
  Plan_id.make ~operation:"up"
    ([ app; host; source; commit; string_of_bool local ]
     @ (match release with Reuse identity -> [ "reuse"; identity ] | Build { ip; base_sha256 } -> [ "build"; ip; base_sha256 ])
     @ (match jail with Jail_ready -> [ "ready" ] | Jail_create -> [ "create" ] | Jail_needs_env m -> [ "needs_env"; m ])
     @ (match rehearsal with None -> [ "live" ] | Some (jail, ip) -> [ "rehearsal"; jail; ip ])
     @ [ public_url ])

let up_plan_id (p : up_plan) =
  up_plan_id_of ~app:p.app ~host:p.host ~source:p.source ~commit:p.commit ~local:p.local ~release:p.release
    ~jail:p.jail ~rehearsal:p.rehearsal ~public_url:p.public_url

let print_up_plan ?(target = Live) plan =
  (match plan.rehearsal with
   | None -> announce "up %s on %s" plan.app plan.host
   | Some (jail, ip) -> announce "up %s on %s, rehearsed in %s at %s" plan.app plan.host jail ip);
  Printf.printf "    source   %s @ %s%s\n" plan.source plan.commit
    (if plan.local then "  (local checkout, not verified as pushed)" else "");
  (match plan.jail with
   | Jail_ready -> ()
   | Jail_create -> Printf.printf "    jail     create %s, then stop for its env\n" plan.app
   | Jail_needs_env message -> Printf.printf "    jail     refused until its env is in place: %s\n" message);
  (match plan.release with
   | Reuse identity -> Printf.printf "    release  reuse %s\n" identity
   | Build { ip; base_sha256 } -> Printf.printf "    release  build in jail %s from base %s\n" ip (short base_sha256));
  (match plan.rehearsal with
   | None when target = Update ->
       Printf.printf "    then     install and restart %s, check %s (no edge)\n%!" plan.app plan.public_url
   | None ->
       Printf.printf "    then     install and restart %s, update the edge if needed, check %s\n%!"
         plan.app plan.public_url
   | Some (jail, ip) ->
       Printf.printf "    then     install and start %s in %s and check it at %s (no edge, no public URL)\n%!"
         plan.app jail ip);
  if target = Live && plan.rehearsal = None then
    Printf.printf "plan %s\n%!" (Plan_id.to_string (up_plan_id plan))

(* Everything up decides before asking: the jail's state, the source
   commit and whether the release is reused or built. [apply] does the rest
   and is only called after confirmation, with an env that no longer asks;
   [plan_only] changes no host (a missing test jail is refused, not created). *)
let prepare_up ?local_source ?(target = Live) ~plan_only env app_name ~revision ~cache ~store =
  (* An update builds only what the remote has: never a local checkout. *)
  if target = Update && Option.is_some local_source then
    failwith "update: builds pushed commits only, not a local checkout";
  let app = find_app env app_name in
  let rehearse_ip = match target with Rehearse ip -> Some ip | Live | Update -> None in
  let topology = match env.topology with
    | Some topology -> topology | None -> failwith "up: configured topology required" in
  let inputs = ok_or_fail (Up_inputs.of_app ~topology app) in
  let env = app_env env app_name in
  let ok = ok_or_fail in
  ok_or_fail (Artifact_store.validate_root store);
  (* A rehearsal deploys into the test jail <app>test at [ip], probed
     read-only first: does it exist, and is its env in place. A missing jail
     is created, and the run stops for the operator to write its env. *)
  let rehearsal = Option.map (fun ip ->
      let jail = validate_test_jail env app ~ip in
      let probe = Jail_test.existing_ip_script ~name:jail () ^ "\n"
                  ^ Jail_test.env_file_script ~name:jail ~app:app_name in
      match ssh_capture env [ env.compute_target; "doas sh -c " ^ Shell.quote probe ] with
      | 0, output ->
          let env_file = Jail_test.check_env_file ~app:app_name ~name:jail output in
          (match ok (Jail_test.check_existing ~app:app_name ~name:jail ~ip output), env_file with
           | Jail_test.Same_ip, Ok () -> jail, ip
           | Jail_test.Same_ip, Error message -> failwith ("up: " ^ message)
           | Jail_test.Absent, _ when plan_only ->
               failwith (Printf.sprintf "up: %s does not exist yet; run without --plan to create it" jail)
           | Jail_test.Absent, _ ->
               jail_test env app_name ~ip;
               failwith (Printf.sprintf "up: created %s; %s" jail
                 (match env_file with Error message -> message | Ok () -> "run the same command again")))
      | code, _ -> failwith (Printf.sprintf "up: probing %s on %s failed (exit %d)" jail (host_label env Compute_host) code))
      rehearse_ip in
  (* The app's own jail, unless rehearsing: a new app's is created here, at
     an address no other jail holds, declared or not. *)
  let jail = match rehearsal with
    | Some _ -> Jail_ready
    | None -> (
        match ssh_capture env [ env.compute_target; "doas sh -c " ^ Shell.quote (Jail_probe.script ~app:app_name) ] with
        | 0, output -> (
            match ok (Jail_probe.check ~app:app_name ~ip:app.endpoint.ip output) with
            | Jail_probe.Absent -> Jail_create
            | Jail_probe.Present (Ok ()) -> Jail_ready
            | Jail_probe.Present (Error message) -> Jail_needs_env message)
        | code, _ -> failwith (Printf.sprintf "up: probing jail %s on %s failed (exit %d)" app_name (host_label env Compute_host) code)) in
  Progress.phase "source";
  let checkout, commit = match local_source with
    | Some path -> path, revision
    | None ->
        let mirror = ok (Source_mirror.sync ~jj_bin:env.jj_bin ~cache ~name:app_name ~url:inputs.source_url) in
        Source_mirror.path mirror, ok (Source_mirror.resolve ~jj_bin:env.jj_bin mirror ~revision) in
  let opam_repository = Option.map (fun (pinned : Strategy_config.pinned_git) ->
      let mirror = ok (Source_mirror.sync ~jj_bin:env.jj_bin ~cache ~name:"opam-repository" ~url:pinned.url) in
      Source_mirror.path mirror, ok (Source_mirror.resolve ~jj_bin:env.jj_bin mirror ~revision:pinned.commit))
    inputs.opam_repository in
  let base_sha256 = inputs.build.base_sha256 in
  let base_archive = ok (Base_archive.ensure ~curl_bin:env.curl_bin ~cache ~url:inputs.build.base_url ~sha256:base_sha256) in
  Progress.phase "recipe";
  (* The pinned opam tree is exported once per commit, not on every run. *)
  let opam_snapshots = Filename.concat cache "opam-snapshots" in
  let _, release_name, packages, compiler = artifact_source_configuration env app_name opam_repository in
  let recipe_sha256 =
    let local = Filename.temp_dir "serai-up-recipe" "" in
    Fun.protect ~finally:(fun () -> remove_tree local) (fun () ->
      (fst (artifact_source_recipe ~opam_snapshots env ~local ~base_sha256 ~release_name ~packages ~compiler
              ~opam_repository ~web_bundle:(artifact_web_bundle env app_name))).sha256) in
  let existing = ok (Artifact_store.find ~root:store ~f:(fun (m : Artifact_manifest.t) ->
      m.name = app_name && m.input = Artifact_manifest.Source_commit commit
      && m.recipe_sha256 = recipe_sha256 && m.release_name = release_name)) in
  let plan = {
    app = app_name; host = inputs.host.id;
    source = (if local_source = None then inputs.source_url else checkout);
    commit; local = local_source <> None;
    release = (match existing with
      | Some identity -> Reuse identity
      | None -> Build { ip = inputs.build.ip; base_sha256 });
    jail; rehearsal; public_url = inputs.public_url;
  } in
  (* Each step's outcome is data, so up and up --json report the same run.
     A step that fails stops the run; the steps after it did not run. *)
  let apply ~bound env =
    let statuses = Array.make (List.length up_steps) Not_run in
    let set step status = statuses.(step_index step) <- status in
    (* Any error a step raises is that step's outcome -- a retained lock's
       Cleanup_failed or a Unix_error as much as a Failure -- so the report
       still says which steps ran. Only an interrupt passes through. *)
    let run step f = match f () with
      | value -> set step Done; Ok value
      | exception ((Sys.Break | Out_of_memory | Stack_overflow) as fatal) -> raise fatal
      | exception error ->
          let message = match error with Failure message -> message | error -> Printexc.to_string error in
          set step (Failed message); Error (Step_failed (step, message)) in
    let ( let* ) = Result.bind in
    let result =
      let* () = match jail with
        | Jail_ready -> Ok (set Jail Skipped)
        | Jail_needs_env message -> set Jail (Failed message); Error (Step_failed (Jail, message))
        | Jail_create ->
            let* () = run Jail (fun () -> bootstrap env app_name) in
            Error (Stopped_for_env (Printf.sprintf
              "created jail %s; write /jails/%s/etc/%s/env from %s, root:%s 0640, \
               then run the same command again" app_name app_name app_name
              (Layout.Relative.app_file ~app:app_name "env.template") app_name)) in
      let* identity = match existing with
        | Some identity -> set Build Skipped; Ok identity
        | None -> run Build (fun () ->
            artifact_build_store ~checkout ?opam_repository ~opam_snapshots env app_name ~revision:commit
              ~ip:inputs.build.ip ~base_archive ~base_sha256 ~store) in
      match rehearsal with
      | Some (_, ip) ->
          (* Activation checks its health at the jail address. *)
          let* () = run Release (fun () -> artifact_apply ~rehearse_ip:ip env app_name ~store ~identity ~rollback:false) in
          set Edge Skipped; set Check Skipped;
          Ok (Deployed identity)
      | None ->
          let* () = run Release (fun () -> artifact_apply env app_name ~store ~identity ~rollback:false) in
          (* The edge renders from the declaration, never from app source,
             so moving an app's revision cannot change it. *)
          let* () = match target with
            | Update -> Ok (set Edge Skipped)
            (* An approved plan named no edge change, so it approves none:
               pending ones are planned and left for their own approval. *)
            | Live | Rehearse _ when bound ->
                let* pending = run Edge (fun () -> (plan_edge env).plan_id) in
                (match pending with
                 | None -> Ok ()
                 | Some id ->
                     set Edge (Pending ("edge changes are pending; they need their own approval: plan "
                                        ^ Plan_id.to_string id));
                     Error (Stopped_for_edge id))
            | Live | Rehearse _ -> run Edge (fun () -> edge env) in
          let* () = run Check (fun () ->
              Progress.phase "check";
              announce "check %s" inputs.public_url;
              match Proc.run env.curl_bin [ "-fsS"; "--max-time"; "15"; "-o"; "/dev/null"; "--"; inputs.public_url ] with
              | 0 -> ()
              | code -> failwith (Printf.sprintf "up: %s answered with an error (curl exit %d)" inputs.public_url code)) in
          Ok (Deployed identity) in
    { steps = List.map (fun step -> step, statuses.(step_index step)) up_steps;
      result = (match result with Ok result | Error result -> result) } in
  plan, apply

let up_plan ?local_source env app_name ~revision ~cache ~store =
  fst (prepare_up ?local_source ~plan_only:true env app_name ~revision ~cache ~store)

let up_run ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store =
  let plan, apply = prepare_up ?local_source ?target ~plan_only:false env app_name ~revision ~cache ~store in
  print_up_plan ?target plan;
  Option.iter (fun expected ->
      let current = up_plan_id plan in
      if current <> expected then
        raise (Plan_id.Stale (Printf.sprintf
                 "up: stale plan: approved %s, now %s; run serai up %s --revision %s --plan again"
                 (Plan_id.to_string expected) (Plan_id.to_string current) app_name revision))) expect_plan;
  let question = match plan.jail, target with
    | Jail_needs_env message, Some Update -> failwith ("update: " ^ message)
    | Jail_create, Some Update ->
        failwith (Printf.sprintf "update: %s has no jail; create it with serai up" app_name)
    | Jail_needs_env message, _ -> failwith ("up: " ^ message)
    | Jail_create, _ -> Printf.sprintf "create jail %s at %s?" app_name (find_app env app_name).endpoint.ip
    | Jail_ready, _ -> Printf.sprintf "deploy %s at %s?" app_name (short plan.commit) in
  if not (env.confirm question) then Run_state.fail ~cause:"declined" "up: not applied";
  Run_state.changing ();
  (* One confirmation covers the whole sequence -- but under an approved
     plan, not an edge change that plan never showed. *)
  plan, Run_state.with_approval Granted (fun () ->
    apply ~bound:(expect_plan <> None) { (app_env env app_name) with confirm = (fun _ -> true) })

let up ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store =
  let plan, outcome = up_run ?local_source ?target ?expect_plan env app_name ~revision ~cache ~store in
  match outcome.result, plan.rehearsal with
  | Deployed identity, Some (jail, ip) ->
      announce "%s is up in %s at %s (%s); destroy it when done: serai jail-test %s --destroy"
        app_name jail ip identity app_name
  | Deployed identity, None -> announce "%s is up at %s (%s)" app_name (short plan.commit) identity
  | Stopped_for_env message, _ -> failwith ("up: " ^ message)
  | Stopped_for_edge id, _ ->
      failwith (Printf.sprintf
        "up: %s is released, but edge changes are pending and this plan did not cover them; \
         approve them with serai edge --expect-plan %s, then serai check %s"
        app_name (Plan_id.to_string id) app_name)
  | Step_failed (_, message), _ -> failwith message
