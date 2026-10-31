(* A tiny DSL for sequencing dispatcher-level steps, read from pipelines.sexp.
   Deliberately scoped to steps that already run from the operator's machine
   today (the four hooks, edge, central logging's sender installers, and
   app-owned "extra" scripts beside app.sexp) -- it does not reach into
   cron/jail-internal hooks such as an app's in-jail sync or backup job,
   which are app-private, not dispatcher commands, on purpose.

   Grammar:

     step  := hook-name              ; bootstrap | deploy | check | update-version
            | edge
            | compute-logging | compute-logging-replace | edge-logging | vmui-auth
            | recover-(edge|auth)[-check|-health]
            | (guest-logging guest)  ; a declared guest's own logging hook
            | (recover-guest[-check|-health] guest)
            | (sequence step ...)
            | (prefer hook-name step) ; run hook-name if the app supports it,
                                       ; else fall back to the given step
            | (script name arg ...)   ; run apps/<app>/<name> with args
     arg   := $COMPUTE_TARGET | $EDGE_TARGET | <literal>

   Evaluating a step performs exactly the Proc.Run effects the equivalent
   hand-written OCaml would have -- Sequence is just List.iter, and a failed
   step's exception propagates and stops the rest, the same short-circuit
   `set -e` already gives the bash dispatcher, for free. *)

type arg = Literal of string | Compute_target | Edge_target

type logging_sender = Compute_sender of Dispatcher.compute_logging_mode | Guest_sender of string | Edge_sender | Vmui_auth

type step =
  | Hook of App_config.hook
  | Edge
  | Logging of logging_sender * Dispatcher.logging_action
  | Sequence of step list
  | Prefer of App_config.hook * step
  | Script of string * arg list

let arg_of_sexp (sexp : Sexplib.Sexp.t) =
  match sexp with
  | Atom "$COMPUTE_TARGET" -> Compute_target
  | Atom "$EDGE_TARGET" -> Edge_target
  | Atom s -> Literal s
  | sexp -> Sexplib.Conv.of_sexp_error "Pipeline.arg_of_sexp: expected an atom" sexp

(* The compute host's relay has no recovery mode: rerunning its installer repairs it. *)
let logging_step = function
  | "compute-logging" -> Some (Compute_sender Converge, Dispatcher.Normal_logging)
  | "compute-logging-replace" -> Some (Compute_sender Replace, Normal_logging)
  | "edge-logging" -> Some (Edge_sender, Normal_logging)
  | "vmui-auth" -> Some (Vmui_auth, Normal_logging)
  | "recover-edge-check" -> Some (Edge_sender, Recovery_check)
  | "recover-auth-check" -> Some (Vmui_auth, Recovery_check)
  | "recover-edge" -> Some (Edge_sender, Recovery_apply)
  | "recover-auth" -> Some (Vmui_auth, Recovery_apply)
  | "recover-edge-health" -> Some (Edge_sender, Recovery_health)
  | "recover-auth-health" -> Some (Vmui_auth, Recovery_health)
  | _ -> None

let guest_logging_step = function
  | "guest-logging" -> Some Dispatcher.Normal_logging
  | "recover-guest-check" -> Some Recovery_check
  | "recover-guest" -> Some Recovery_apply
  | "recover-guest-health" -> Some Recovery_health
  | _ -> None

let rec step_of_sexp (sexp : Sexplib.Sexp.t) : step =
  match sexp with
  | Atom "edge" -> Edge
  | Atom name -> (
      match logging_step name with
      | Some (sender, action) -> Logging (sender, action)
      | None -> Hook (App_config.hook_of_sexp sexp))
  | List (Atom "sequence" :: steps) -> Sequence (List.map step_of_sexp steps)
  | List [ Atom step; Atom guest ] when Option.is_some (guest_logging_step step) ->
      Logging (Guest_sender guest, Option.get (guest_logging_step step))
  | List [ Atom "prefer"; hook_sexp; fallback ] ->
      Prefer (App_config.hook_of_sexp hook_sexp, step_of_sexp fallback)
  | List (Atom "script" :: Atom name :: args) -> Script (name, List.map arg_of_sexp args)
  | sexp -> Sexplib.Conv.of_sexp_error "Pipeline.step_of_sexp: malformed step" sexp

(* pipelines.sexp: a set of named default pipelines available to every app,
   plus optional per-app pipelines (looked up first, falling back to
   default). Keeps every app on the same rollout logic unless it actually
   needs something extra. *)
type t = { default : (string * step) list; apps : (string * (string * step) list) list }

let named_steps_of_sexp (sexp : Sexplib.Sexp.t) =
  match sexp with
  | List entries ->
      List.map
        (function
          | Sexplib.Sexp.List [ Atom name; step_sexp ] -> (name, step_of_sexp step_sexp)
          | sexp -> Sexplib.Conv.of_sexp_error "Pipeline: expected (name step)" sexp)
        entries
  | sexp -> Sexplib.Conv.of_sexp_error "Pipeline: expected a list of (name step)" sexp

let of_sexp (sexp : Sexplib.Sexp.t) =
  match sexp with
  | List [ List [ Atom "default"; default_sexp ]; List [ Atom "apps"; apps_sexp ] ] ->
      let default = named_steps_of_sexp default_sexp in
      let apps =
        match apps_sexp with
        | List entries ->
            List.map
              (function
                | Sexplib.Sexp.List [ Atom app; steps_sexp ] -> (app, named_steps_of_sexp steps_sexp)
                | sexp -> Sexplib.Conv.of_sexp_error "Pipeline: expected (app steps)" sexp)
              entries
        | sexp -> Sexplib.Conv.of_sexp_error "Pipeline: expected a list of (app steps)" sexp
      in
      { default; apps }
  | sexp ->
      Sexplib.Conv.of_sexp_error "Pipeline.of_sexp: expected ((default ...) (apps ...))" sexp

let load path = of_sexp (Sexplib.Sexp.load_sexp path)

let find t ~app ~name =
  let app_steps = Option.value (List.assoc_opt app t.apps) ~default:[] in
  match List.assoc_opt name app_steps with
  | Some _ as found -> found
  | None -> List.assoc_opt name t.default

let resolve_arg (env : Dispatcher.env) = function
  | Literal s -> s
  | Compute_target -> env.compute_target
  | Edge_target -> env.edge_target

let rec eval env app_name step =
  match step with
  | Hook App_config.Bootstrap -> Dispatcher.bootstrap env app_name
  | Hook App_config.Deploy -> Dispatcher.deploy env app_name
  | Hook App_config.Check -> Dispatcher.check env app_name
  | Hook App_config.Update_version -> Dispatcher.update_version env app_name ""
  | Edge -> Dispatcher.edge env
  | Logging (Compute_sender mode, _) -> Dispatcher.install_compute_logging ~mode env
  | Logging (Guest_sender guest, action) -> Dispatcher.install_guest_logging ~action env guest
  | Logging (Edge_sender, action) -> Dispatcher.install_edge_logging_component ~action env Dispatcher.Edge_sender
  | Logging (Vmui_auth, action) -> Dispatcher.install_edge_logging_component ~action env Dispatcher.Vmui_auth
  | Sequence steps -> List.iter (eval env app_name) steps
  | Prefer (hook, fallback) ->
      let app = Dispatcher.find_app env app_name in
      if App_config.supports app hook then eval env app_name (Hook hook)
      else eval env app_name fallback
  | Script (name, args) ->
      let app = Dispatcher.find_app env app_name in
      let env = Dispatcher.app_env env app_name in
      Dispatcher.require_direct_hook env;
      Proc.run_checked
        (Filename.concat (Layout.app_dir env.layout app.endpoint.name) name)
        (List.map (resolve_arg env) args)

let rec guests = function
  | Logging (Guest_sender guest, _) -> [ guest ]
  | Sequence steps -> List.concat_map guests steps
  | Prefer (_, fallback) -> guests fallback
  | Hook _ | Edge | Logging _ | Script _ -> []

let run env registry app_name pipeline_name =
  let app = Dispatcher.find_app env app_name in
  match find registry ~app:app.endpoint.name ~name:pipeline_name with
  | None -> failwith "unknown pipeline"
  | Some step ->
      (* Every guest the pipeline names is declared, before any step runs. *)
      let declared = Dispatcher.list_guests env in
      List.iter (fun guest ->
        if not (List.mem guest declared) then failwith ("pipeline names an undeclared guest: " ^ guest))
        (guests step);
      eval env app_name step
