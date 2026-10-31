(* infra new's pure part. The generated files are parsed back through the
   same code that loads them (App_config, Env_template, Topology, the
   endpoint checks and the Caddy placeholders) before anything is returned,
   so a scaffold the rest of infra would refuse never reaches the disk. *)

type kind =
  | Phoenix of { release_name : string; migrate : string option }
  | Ocaml

type request = {
  name : string;
  kind : kind;
  repo_path : string;
  source : string;
  hostname : string option;
}

type file = { path : string; contents : string }

type t = {
  ip : string;
  port : int;
  hostname : string;
  files : file list;
  topology : string;
}

let ( let* ) = Result.bind

let find_from text ~from needle =
  let n = String.length needle and len = String.length text in
  let rec go i = if i + n > len then None else if String.sub text i n = needle then Some i else go (i + 1) in
  go from

let take_while text from ok =
  let len = String.length text in
  let rec go i = if i < len && ok text.[i] then go (i + 1) else i in
  let stop = go from in
  String.sub text from (stop - from)

let skip_blanks text from =
  let len = String.length text in
  let rec go i = if i < len && (text.[i] = ' ' || text.[i] = '\t') then go (i + 1) else i in
  go from

let is_ident c = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c = '_'
let is_module c = is_ident c || (c >= 'A' && c <= 'Z') || c = '.'

(* mix.exs's [app: :name]: the OTP application, which is the release name
   unless the project declares releases of its own. *)
let phoenix ~mix_exs ~release_ex =
  match find_from mix_exs ~from:0 "app:" with
  | None -> Error "mix.exs: no app: :name"
  | Some i ->
      let i = skip_blanks mix_exs (i + 4) in
      if i >= String.length mix_exs || mix_exs.[i] <> ':' then Error "mix.exs: no app: :name"
      else
        match take_while mix_exs (i + 1) is_ident with
        | "" -> Error "mix.exs: no app: :name"
        | release_name ->
            let migrate = Option.bind (release_ex release_name) (fun source ->
                match find_from source ~from:0 "defmodule ", find_from source ~from:0 "def migrate" with
                | Some i, Some _ ->
                    let name = take_while source (i + 10) is_module in
                    if String.ends_with ~suffix:".Release" name then Some (name ^ ".migrate") else None
                | _ -> None) in
            Ok (Phoenix { release_name; migrate })

(* --- serai.sexp, edited as text so its comments survive --- *)

type node = Atom of string * int | List of node list * int * int  (* start; '(' and ')' offsets *)

let parse_nodes text =
  let len = String.length text in
  let rec skip i =
    if i >= len then i
    else match text.[i] with
      | ' ' | '\t' | '\n' | '\r' -> skip (i + 1)
      | ';' -> (match String.index_from_opt text i '\n' with Some j -> skip (j + 1) | None -> len)
      | _ -> i in
  let rec node i =
    match text.[i] with
    | '(' -> let children, close = items (i + 1) in List (children, i, close), close + 1
    | ')' -> failwith "unbalanced )"
    | _ ->
        let atom = take_while text i (fun c -> not (List.mem c [ ' '; '\t'; '\n'; '\r'; '('; ')'; ';'; '"' ])) in
        if atom = "" then failwith "unsupported syntax" else Atom (atom, i), i + String.length atom
  and items i =
    let i = skip i in
    if i >= len then failwith "unbalanced ("
    else if text.[i] = ')' then [], i
    else let first, next = node i in let rest, close = items next in first :: rest, close in
  let rec top i acc =
    let i = skip i in
    if i >= len then List.rev acc else let first, next = node i in top next (first :: acc) in
  top 0 []

let field_list fields name =
  List.find_map (function
    | List (Atom (key, _) :: [ List (entries, opening, close) ], _, _) when key = name -> Some (entries, opening, close)
    | _ -> None) fields

(* The column [offset] starts at. *)
let column text offset =
  match String.rindex_from_opt text (offset - 1) '\n' with Some i -> offset - i - 1 | None -> offset

let place topology ~name ~host =
  let* fields = match parse_nodes topology with
    | [ List (fields, _, _) ] -> Ok fields
    | _ | exception Failure _ -> Error (Layout.Relative.topology ^ ": not one list") in
  let* jails = Option.to_result ~none:(Layout.Relative.topology ^ ": no (jails (...))") (field_list fields "jails") in
  let* proxy = Option.to_result ~none:(Layout.Relative.topology ^ ": no (proxy (...))") (field_list fields "proxy") in
  let insert_jail = match jails with
    | [], _, close -> close, Printf.sprintf "(%s %s)" name host
    | entries, _, close ->
        let start = match List.nth entries (List.length entries - 1) with Atom (_, s) | List (_, s, _) -> s in
        close, Printf.sprintf "\n%s(%s %s)" (String.make (column topology start) ' ') name host in
  let insert_proxy = match proxy with
    | [], _, close -> close, name
    | _, _, close -> close, " " ^ name in
  (* Later offset first, so the earlier one still holds. *)
  let edits = List.sort (fun (a, _) (b, _) -> compare b a) [ insert_jail; insert_proxy ] in
  Ok (List.fold_left (fun text (offset, insert) ->
      String.sub text 0 offset ^ insert ^ String.sub text offset (String.length text - offset)) topology edits)

(* --- addresses --- *)

(* The lowest address the host's network allows a jail that no endpoint
   or build jail uses. *)
let free_ip ~(host : Topology.host) ~used =
  let free ip = Topology.check_workload_ip host ip = Ok () && not (List.mem ip used) in
  match host.network with
  | None -> Error ("infra new: host " ^ host.id ^ " has no network")
  | Some network ->
      Ipv4.hosts network.subnet |> Seq.map Ipv4.to_string |> Seq.find free
      |> Option.to_result ~none:("infra new: no free jail address in " ^ Ipv4.subnet_to_string network.subnet)

let free_port (apps : App_config.t list) =
  let ports = List.concat_map (fun (app : App_config.t) ->
      List.filter_map (fun (p : Network_endpoint.named_port) ->
          if p.port >= 4000 && p.port < 5000 then Some p.port else None) app.endpoint.tailnet_ports) apps in
  match List.fold_left max 0 ports with
  | 0 -> Ok 4000
  | highest -> let next = (highest / 10 + 1) * 10 in
      if next < 5000 then Ok next else Error "no free http port in 4000-4999"

(* Caddy sites are numbered; apps' are 40-49. *)
let site_number templates =
  let numbers = List.filter_map (fun template ->
      match String.index_opt template '-' with
      | Some i -> int_of_string_opt (String.sub template 0 i)
      | None -> None) templates
    |> List.filter (fun n -> n >= 40 && n <= 49) in
  match List.fold_left max 39 numbers with
  | 49 -> Error (Layout.Relative.caddy_sites ^ ": no free site number in 40-49")
  | highest -> Ok (highest + 1)

(* --- the files --- *)

(* The kind with what it takes from elsewhere in the declaration. *)
type resolved =
  | Resolved_phoenix of { release_name : string; migrate : string option }
  | Resolved_ocaml of { switch : string; pin : Strategy_config.pinned_git }

let app_sexp (request : request) resolved ~ip ~port ~hostname =
  let header kind = String.concat "\n" [
      "(";
      "(name " ^ request.name ^ ")";
      "(ip " ^ ip ^ ")";
      "(hostname " ^ hostname ^ ")";
      Printf.sprintf "(tailnet_ports ((http %d)))" port;
      "(operator_ports ())";
      "(strategy " ^ kind ^ ")";
      "(hooks (bootstrap check))";
      "(extra_steps ())";
      "(strategy_config (" ] in
  match resolved with
  | Resolved_phoenix { release_name; migrate } ->
      String.concat "\n" [
        header "freebsd_native_elixir";
        "  (packages (erlang-runtime28 elixir-devel sqlite3 gmake git curl node24 npm-node24))";
        "  (repo_path " ^ request.repo_path ^ ")";
        "  (source (git " ^ request.source ^ "))";
        "  (release_name " ^ release_name ^ ")";
        (match migrate with
         | Some f -> "  (migrate (release_eval " ^ f ^ "))"
         | None -> "  ; No Release.migrate found; (release_eval M.f) runs one between stop and start.\n  (migrate none)");
        "  (check_path /)";
        "))";
        ")";
        "" ]
  | Resolved_ocaml { switch; pin } ->
      String.concat "\n" [
        header "freebsd_native_ocaml";
        "  (ocaml_switch " ^ switch ^ ")";
        "  (repo_path " ^ request.repo_path ^ ")";
        "  (source (git " ^ request.source ^ "))";
        "  ; The other OCaml apps' pin: one snapshot, already known to solve on FreeBSD.";
        "  (opam_repository (git " ^ pin.url ^ ")";
        "   (commit " ^ pin.commit ^ "))";
        "  (zfs_dataset zroot/" ^ request.name ^ ")";
        "  (data_dir /var/db/" ^ request.name ^ ")";
        "  (packages (ocaml-opam bash gmake pkgconf sqlite3 gmp ca_root_nss git))";
        "  ; The service runs bin/" ^ request.name ^ ".exe with these arguments.";
        "  (serve_args (serve))";
        "  ; (command a ...) runs the executable with a ... between stop and start.";
        "  (migrate none)";
        "  (check_path /health)";
        "))";
        ")";
        "" ]

let env_template (request : request) ~port ~hostname =
  match request.kind with
  | Phoenix { release_name; _ } ->
      String.concat "\n" [
        Printf.sprintf "# /etc/%s/env, root:%s 0640: replace every REPLACE_ME before the first activation." request.name request.name;
        "PHX_SERVER=true";
        "# The jail ip instead in a rehearsal jail.";
        "PHX_HOST=" ^ hostname;
        Printf.sprintf "PORT=%d" port;
        Printf.sprintf "DATABASE_PATH=/var/db/%s/%s.db" request.name release_name;
        "POOL_SIZE=5";
        "# The BEAM needs a UTF-8 locale, and nothing in the jail sets one.";
        "LANG=C.UTF-8";
        "# mix phx.gen.secret";
        "SECRET_KEY_BASE=REPLACE_ME";
        "RELEASE_COOKIE=REPLACE_ME";
        "RELEASE_TMP=/var/run/" ^ request.name;
        "" ]
  | Ocaml ->
      String.concat "\n" [
        Printf.sprintf "# /etc/%s/env, root:%s 0640: every variable the service reads, one per line." request.name request.name;
        "# The rc script refuses to start while one is empty or REPLACE_ME. The service";
        Printf.sprintf "# listens on the jail address, port %d; https://%s is its public URL." port hostname;
        "" ]

let caddy_site (request : request) ~kind_label =
  let upper = String.uppercase_ascii request.name in
  String.concat "\n" [
    "# ---------------------------------------------------------------------------";
    Printf.sprintf "# %s (%s, native FreeBSD jail)" request.name kind_label;
    "# ---------------------------------------------------------------------------";
    Printf.sprintf "__%s_HOSTNAME__ {" upper;
    "    import access_log";
    {|    header Strict-Transport-Security "max-age=31536000; includeSubDomains"|};
    Printf.sprintf "    reverse_proxy __%s_IP__:__%s_HTTP_PORT__ {" upper upper;
    "        # Wait out a restart rather than answer 502.";
    "        lb_try_duration 30s";
    "        header_up Host {host}";
    "        header_up X-Real-IP {remote_host}";
    "    }";
    "}";
    "" ]

(* --- the plan --- *)

let parse_back what parse = match parse () with
  | value -> Ok value
  | exception (Sexplib.Conv.Of_sexp_error _ | Failure _ | Not_found as exn) ->
      Error (Printf.sprintf "infra new: the generated %s does not load: %s" what (Declaration.describe exn))

let plan (declaration : Declaration.t) ~topology ~templates (request : request) =
  let name = request.name in
  let endpoints = Network_endpoint.to_list declaration.endpoints in
  let* () =
    if not (Network_endpoint.is_placeholder_safe name) then Error (name ^ ": an app name is [a-z0-9]+")
    else if String.ends_with ~suffix:"test" name then Error (name ^ ": names ending in test are test jails'")
    else if List.exists (fun (e : Network_endpoint.t) -> e.name = name) endpoints
    then Error (name ^ " is already declared")
    else Ok () in
  let* parsed_topology = Option.to_result ~none:"infra new: no topology" declaration.topology in
  let* host = match Topology.compute_hosts parsed_topology with
    | [ host ] -> Ok host
    | hosts -> Error (Printf.sprintf "infra new: %d compute hosts; place the app by hand" (List.length hosts)) in
  let used = List.map (fun (e : Network_endpoint.t) -> e.ip) endpoints
    @ List.filter_map (fun (h : Topology.host) -> Option.map (fun (b : Topology.build) -> b.ip) h.build)
        (Topology.hosts parsed_topology) in
  let* ip = free_ip ~host ~used in
  let* port = free_port declaration.apps in
  let hostname = Option.value request.hostname ~default:(name ^ "." ^ declaration.edge.base_domain) in
  let* resolved = match request.kind with
    | Phoenix { release_name; migrate } -> Ok (Resolved_phoenix { release_name; migrate })
    | Ocaml -> (
        match List.find_map (fun (app : App_config.t) -> match app.strategy with
            | Strategy_config.Freebsd_native_ocaml { ocaml_switch; opam_repository = Some pin; _ } ->
                Some (Resolved_ocaml { switch = ocaml_switch; pin })
            | _ -> None) declaration.apps with
        | Some resolved -> Ok resolved
        | None -> Error "infra new: no OCaml app declares an opam_repository pin to start from") in
  let* number = site_number templates in
  let app_text = app_sexp request resolved ~ip ~port ~hostname in
  let env_text = env_template request ~port ~hostname in
  let kind_label = match request.kind with Phoenix _ -> "Phoenix" | Ocaml -> "OCaml" in
  let site_text = caddy_site request ~kind_label in
  let* app = parse_back "app.sexp" (fun () -> App_config.of_sexp (Sexplib.Sexp.of_string app_text)) in
  let* _ = Env_template.names ~filled_by:Env_template.Operator env_text
    |> Result.map_error (fun e -> "infra new: the generated env.template: " ^ Env_template.error_message e) in
  let* validated = Network_endpoint.validate_all (endpoints @ [ app.endpoint ])
    |> Result.map_error (fun errors -> "infra new: " ^ Network_endpoint.errors_message errors) in
  let* () = match Caddy_render.find_unsubstituted
      (Caddy_render.substitute ~placeholders:(Caddy_render.placeholders ~edge:declaration.edge validated) site_text) with
    | None -> Ok ()
    | Some placeholder -> Error ("infra new: the generated Caddy site leaves " ^ placeholder) in
  let* topology = place topology ~name ~host:host.id in
  let* placed_on = parse_back "topology" (fun () ->
      let placed = Topology.of_sexp (Sexplib.Sexp.of_string topology) in
      (Topology.jail_host placed name).id, List.mem name (Topology.proxy_workloads placed)) in
  let* () = match placed_on with
    | id, true when id = host.id -> Ok ()
    | _ -> Error "infra new: the edited topology does not place and proxy the app" in
  Ok {
    ip; port; hostname; topology;
    files = [
      { path = Layout.Relative.app_file ~app:name "app.sexp"; contents = app_text };
      { path = Layout.Relative.app_file ~app:name "env.template"; contents = env_text };
      { path = Layout.Relative.caddy_site (Printf.sprintf "%d-%s.caddy.template" number name); contents = site_text };
    ];
  }
