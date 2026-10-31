(* Per-app declaration, replacing apps.sexp's flat hook registry and each
   app's hand-written `config` shell file with one typed, parsed source of
   truth. Unknown hook or strategy names are parse errors, not silently
   ignored typos. *)

type hook = Bootstrap | Deploy | Check | Update_version

let hook_of_sexp (sexp : Sexplib.Sexp.t) =
  match sexp with
  | Atom "bootstrap" -> Bootstrap
  | Atom "deploy" -> Deploy
  | Atom "check" -> Check
  | Atom "update-version" -> Update_version
  | sexp ->
      Sexplib.Conv.of_sexp_error
        "App_config.hook_of_sexp: expected one of \
         bootstrap|deploy|check|update-version"
        sexp

type t = {
  endpoint : Network_endpoint.t;
      (* name/ip/hostname/ports: the facts Headscale_acl, Pf_rules and
         Caddy_render read, shared with guest.sexp. Parsed from the same
         flat field list as everything else here, not nested. *)
  strategy : Strategy_config.t;
  hooks : hook list;
  extra_steps : string list; (* plain file names, Strategy_config.parse_extra_steps *)
  env_names : string list; (* what env.template declares, Env_template.names *)
}

let create ?(env_names = []) ~endpoint ~strategy ~hooks ~extra_steps () =
  Strategy_config.parse_extra_steps extra_steps
  |> Result.map (fun extra_steps -> { endpoint; strategy; hooks; extra_steps; env_names })

let with_endpoint app endpoint = { app with endpoint }

let context = "App_config"

let known_fields =
  Network_endpoint.field_names @ [ "strategy"; "hooks"; "extra_steps"; "strategy_config" ]

let of_sexp (sexp : Sexplib.Sexp.t) =
  let fields = Sexp_fields.fields_of_sexp ~context ~known:known_fields sexp in
  let field name = Sexp_fields.field ~context name fields in
  let or_raise = function
    | Ok value -> value
    | Error error ->
        Sexplib.Conv.of_sexp_error (Strategy_config.error_message error)
          (Strategy_config.offending_sexp error)
  in
  let strategy =
    or_raise (Strategy_config.parse ~strategy:(field "strategy") ~config:(field "strategy_config"))
  in
  let extra_steps =
    Sexp_fields.list ~context (Sexp_fields.atom ~context) (field "extra_steps")
    |> Strategy_config.parse_extra_steps |> or_raise
  in
  {
    endpoint = Network_endpoint.of_fields fields;
    strategy;
    hooks = Sexp_fields.list ~context hook_of_sexp (field "hooks");
    extra_steps;
    env_names = [];
  }

(* The env.template beside app.sexp, read here and parsed once. *)
let load path =
  let app = of_sexp (Sexplib.Sexp.load_sexp path) in
  let template = Filename.concat (Filename.dirname path) "env.template" in
  if not (Sys.file_exists template) then app
  else
    (* Only fetch_binary's jail script renders its template. *)
    let filled_by = match app.strategy with
      | Strategy_config.Fetch_binary _ -> Env_template.Jail_script
      | Strategy_config.(Freebsd_native_elixir _ | Freebsd_native_ocaml _ | Freebsd_package _
                         | Freebsd_package_service _) ->
          Env_template.Operator in
    match Env_template.names ~filled_by (In_channel.with_open_bin template In_channel.input_all) with
    | Ok env_names -> { app with env_names }
    | Error error -> failwith (Env_template.error_message error)

let endpoint app = app.endpoint

let supports app hook = List.mem hook app.hooks

let find (t : t list) name = List.find_opt (fun a -> a.endpoint.name = name) t
let names (t : t list) = List.map (fun a -> a.endpoint.name) t |> List.sort compare

let load_all dir =
  Sys.readdir dir |> Array.to_list |> List.sort compare
  |> List.filter_map (fun entry ->
         let app_sexp = Filename.concat (Filename.concat dir entry) "app.sexp" in
         if Sys.file_exists app_sexp then Some (load app_sexp) else None)
