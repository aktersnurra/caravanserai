(* Strategy parsing is independent of App_config, so declarations can store
   its result rather than raw S-expressions that need reparsing. *)

(* A pinned git input: [url] as declared, [commit] a full commit id. *)
type pinned_git = { url : string; commit : string }

type freebsd_native_elixir = {
  packages : string list;
  repo_path : string;
  source : string option;  (* git URL the build fetches; None: legacy hooks only *)
  release_name : string;
  migrate : string option;
  check_path : string;
}

type service_status = Rc | Process

type freebsd_package = {
  packages : string list;
  check_path : string;
  check_status : int option;
  service_status : service_status;
}

(* binary_url_template carries a literal "${VERSION}" placeholder that the
   generated sh substitutes at runtime via its own VERSION shell variable --
   the same idiom render_jail_base already uses for ${JAIL}/${JAIL_IP}, so
   OCaml never needs to know the app's actual pinned version at render time. *)
type fetch_binary = {
  version : string;
  packages : string list;
  data_dir : string;
  binary_sha256 : string;
  binary_url_template : string;
  binary_name : string;
  port : string;
  env_values : (string * string) list;
  generated_secrets : string list;
  env_template_path : string;
  rc_template_path : string;
  check_path : string;
}

type freebsd_native_ocaml = {
  ocaml_switch : string;
  repo_path : string;
  source : string option;
  opam_repository : pinned_git option;
  zfs_dataset : string;
  data_dir : string;
  packages : string list;
  serve_args : string list;
  migrate : string list option;
  check_path : string;
  web_bundle : string option;
}

type freebsd_package_service = {
  packages : string list;
  zfs_dataset : string;
  data_dir : string;
  data_owner : string;
  service : string;
  service_args : string list;
  check_path : string;
}

type t =
  | Freebsd_native_elixir of freebsd_native_elixir
  | Freebsd_package of freebsd_package
  | Fetch_binary of fetch_binary
  | Freebsd_native_ocaml of freebsd_native_ocaml
  | Freebsd_package_service of freebsd_package_service

let field_of_sexp name fields =
  match List.assoc_opt name fields with
  | Some v -> v
  | None ->
      let sexp =
        Sexplib.Sexp.List
          (List.map (fun (k, v) -> Sexplib.Sexp.List [ Atom k; v ]) fields)
      in
      Sexplib.Conv.of_sexp_error
        (Printf.sprintf "Strategy: missing strategy_config field %s" name)
        sexp

let atom_of_sexp = function
  | Sexplib.Sexp.Atom a -> a
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected an atom" sexp

(* The name is passed to the Phoenix build worker and used as a release
   directory component. Match its restricted shell-side syntax here. *)
let release_name_of_sexp sexp =
  let name = atom_of_sexp sexp in
  if name = "" || String.length name > 128
     || not (String.for_all
               (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
               name)
  then Sexplib.Conv.of_sexp_error "Strategy: invalid release_name" sexp
  else name

(* A declared git remote is passed to jj as an argument and stored in the
   mirror's config: accept only scp-style ssh, ssh:// and https:// URLs over
   a conservative character set, never a local path or an option. *)
let git_url_of_sexp sexp =
  let url = atom_of_sexp sexp in
  let safe = String.for_all (function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '@' | ':' | '/' | '.' | '_' | '~' | '-' -> true
    | _ -> false) url in
  let scheme = List.exists (fun prefix -> String.starts_with ~prefix url)
    [ "https://"; "ssh://"; "git@" ] in
  if url = "" || String.length url > 512 || not safe || not scheme
  then Sexplib.Conv.of_sexp_error "Strategy: source must be an https://, ssh:// or git@ URL" sexp
  else url

let git_source_of_sexp = function
  | Sexplib.Sexp.List [ Atom "git"; url ] -> git_url_of_sexp url
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected (git <url>)" sexp

let commit_of_sexp sexp =
  let commit = atom_of_sexp sexp in
  if String.length commit = 40
     && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) commit
  then commit
  else Sexplib.Conv.of_sexp_error "Strategy: commit must be a full 40-hex commit id" sexp

let pinned_git_of_sexp = function
  | Sexplib.Sexp.List [ source; Sexplib.Sexp.List [ Atom "commit"; commit ] ] ->
      { url = git_source_of_sexp source; commit = commit_of_sexp commit }
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected (git <url>) (commit <id>)" sexp

(* A word spliced into a generated rc script or a service command line:
   letters, digits and - _ . = only, never quoting or expansion. *)
let word_of_sexp sexp =
  let word = atom_of_sexp sexp in
  if word = "" || String.length word > 64
     || not (String.for_all (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' | '=' -> true
         | _ -> false) word)
  then Sexplib.Conv.of_sexp_error "Strategy: expected a plain word" sexp
  else word

let check_status_of_sexp sexp =
  let invalid () = Sexplib.Conv.of_sexp_error "Strategy: check_status must be an HTTP status, 100-599" sexp in
  match sexp with
  | Sexplib.Sexp.Atom text
    when String.length text = 3 && String.for_all (function '0' .. '9' -> true | _ -> false) text ->
      let status = int_of_string text in
      if status >= 100 && status <= 599 then status else invalid ()
  | _ -> invalid ()

let service_status_of_sexp = function
  | Sexplib.Sexp.Atom "rc" -> Rc
  | Sexplib.Sexp.Atom "process" -> Process
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: service_status must be rc or process" sexp

(* A relative path inside the app's source, run on the controller: plain
   segments only, never absolute, an option or a way out of the source. *)
let source_path_of_sexp sexp =
  let path = atom_of_sexp sexp in
  let segment_ok = function
    | "" | "." | ".." -> false
    | segment -> String.for_all (function
        | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' | '.' -> true
        | _ -> false) segment in
  if path = "" || String.length path > 256 || path.[0] = '-'
     || not (List.for_all segment_ok (String.split_on_char '/' path))
  then Sexplib.Conv.of_sexp_error "Strategy: expected a relative path in the source" sexp
  else path

let words_of_sexp ~field = function
  | Sexplib.Sexp.List (_ :: _ as items) -> List.map word_of_sexp items
  | sexp -> Sexplib.Conv.of_sexp_error (Printf.sprintf "Strategy: %s must be a non-empty list" field) sexp

(* An Elixir remote function, Module.Path.fun, called with no arguments by
   [bin/<release> eval]. Nothing else can reach the eval. *)
let release_eval_of_sexp sexp =
  let expression = atom_of_sexp sexp in
  let segment_ok ~first segment =
    segment <> ""
    && (match segment.[0] with
        | 'A' .. 'Z' -> first
        | 'a' .. 'z' | '_' -> not first
        | _ -> false)
    && String.for_all (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '!' | '?' -> true | _ -> false) segment in
  match List.rev (String.split_on_char '.' expression) with
  | fn :: (_ :: _ as modules)
    when segment_ok ~first:false fn && List.for_all (segment_ok ~first:true) modules
         && String.length expression <= 128 -> expression
  | _ -> Sexplib.Conv.of_sexp_error "Strategy: release_eval must be Module.function" sexp

let elixir_migrate_of_sexp = function
  | Sexplib.Sexp.Atom "none" -> None
  | Sexplib.Sexp.List [ Atom "release_eval"; expression ] -> Some (release_eval_of_sexp expression)
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: migrate must be none or (release_eval Module.function)" sexp

let ocaml_migrate_of_sexp = function
  | Sexplib.Sexp.Atom "none" -> None
  | Sexplib.Sexp.List (Atom "command" :: (_ :: _ as args)) -> Some (List.map word_of_sexp args)
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: migrate must be none or (command <word>...)" sexp

let string_list_of_sexp = function
  | Sexplib.Sexp.List items -> List.map atom_of_sexp items
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected a list" sexp

(* An empty list would render `pkg install -y` with no arguments, which
   fails under set -e. *)
let packages_of_sexp sexp =
  match string_list_of_sexp sexp with
  | [] -> Sexplib.Conv.of_sexp_error "Strategy: packages must not be empty" sexp
  | packages -> packages

(* [known] is the field set of the strategy being parsed: an unknown or
   repeated key is an error, not silently ignored or first-wins. *)
let fields_of_sexp ~known (sexp : Sexplib.Sexp.t) =
  match sexp with
  | List items ->
      List.fold_left
        (fun fields item ->
          let key, value =
            match item with
            | Sexplib.Sexp.List [ Atom key; value ] -> (key, value)
            | Sexplib.Sexp.List (Atom key :: rest) -> (key, Sexplib.Sexp.List rest)
            | sexp ->
                Sexplib.Conv.of_sexp_error
                  "Strategy: expected (field value ...)" sexp
          in
          if not (List.mem key known) then
            Sexplib.Conv.of_sexp_error
              (Printf.sprintf "Strategy: unknown strategy_config field %s" key)
              item
          else if List.mem_assoc key fields then
            Sexplib.Conv.of_sexp_error
              (Printf.sprintf "Strategy: duplicate strategy_config field %s" key)
              item
          else (key, value) :: fields)
        [] items
      |> List.rev
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected a list" sexp

let is_service_char = function
  | 'a' .. 'z' | '0' .. '9' | '_' | '-' -> true
  | _ -> false

let is_argument_char = function
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' | '/' | ':' | '=' -> true
  | _ -> false

let safe_token ~field ~allowed sexp =
  let value = atom_of_sexp sexp in
  if value = "" || not (String.for_all allowed value) then
    Sexplib.Conv.of_sexp_error ("Strategy: unsafe " ^ field) sexp;
  value

(* An env file placeholder's name: __NAME__ in the template. JAIL_IP and
   PORT are filled from the app itself. *)
let env_name_of_sexp sexp =
  let name = atom_of_sexp sexp in
  let is_name_char = function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false in
  if name = "" || not (match name.[0] with 'A' .. 'Z' -> true | _ -> false)
     || not (String.for_all is_name_char name)
  then Sexplib.Conv.of_sexp_error "Strategy: env name must be [A-Z][A-Z0-9_]*" sexp;
  if List.mem name [ "JAIL_IP"; "PORT" ] then
    Sexplib.Conv.of_sexp_error (Printf.sprintf "Strategy: %s is filled by the engine" name) sexp;
  name

(* A value is rendered as a double-quoted awk -v assignment and used as a
   gsub replacement: a quote, $, backtick or backslash would be read by the
   shell or awk, and & by gsub. One printable word, so it also fits on the
   single line FreeBSD's awk accepts in -v. *)
let env_value_of_sexp sexp =
  let value = atom_of_sexp sexp in
  let is_value_char c = c > ' ' && c <= '~' && not (String.contains "\"$`\\&" c) in
  if value = "" || not (String.for_all is_value_char value) then
    Sexplib.Conv.of_sexp_error "Strategy: unsafe env value" sexp;
  value

let env_values_of_sexp = function
  | Sexplib.Sexp.List items ->
      List.map
        (function
          | Sexplib.Sexp.List [ name; value ] -> (env_name_of_sexp name, env_value_of_sexp value)
          | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected (NAME value)" sexp)
        items
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected a list" sexp

let generated_secrets_of_sexp = function
  | Sexplib.Sexp.List items -> List.map env_name_of_sexp items
  | sexp -> Sexplib.Conv.of_sexp_error "Strategy: expected a list" sexp

(* One placeholder, one source: a name in both lists, or twice in one,
   would leave which value wins to the order of the gsubs. *)
let check_env_names ~config names =
  let rec go seen = function
    | [] -> ()
    | name :: rest ->
        if List.mem name seen then
          Sexplib.Conv.of_sexp_error (Printf.sprintf "Strategy: env name %s declared twice" name) config;
        go (name :: seen) rest
  in
  go [] names

let of_sexp ~(strategy : Sexplib.Sexp.t) ~config =
  match strategy with
  | Atom "freebsd_native_elixir" ->
      let fields =
        fields_of_sexp config
          ~known:[ "packages"; "repo_path"; "source"; "release_name"; "migrate"; "check_path" ]
      in
      Freebsd_native_elixir
        {
          packages = packages_of_sexp (field_of_sexp "packages" fields);
          repo_path = atom_of_sexp (field_of_sexp "repo_path" fields);
          source = Option.map git_source_of_sexp (List.assoc_opt "source" fields);
          release_name = release_name_of_sexp (field_of_sexp "release_name" fields);
          migrate = Option.bind (List.assoc_opt "migrate" fields) elixir_migrate_of_sexp;
          check_path = atom_of_sexp (field_of_sexp "check_path" fields);
        }
  | Atom "freebsd_package" ->
      let fields = fields_of_sexp config ~known:[ "packages"; "check_path"; "check_status"; "service_status" ] in
      Freebsd_package
        {
          packages = packages_of_sexp (field_of_sexp "packages" fields);
          check_path = atom_of_sexp (field_of_sexp "check_path" fields);
          check_status = Option.map check_status_of_sexp (List.assoc_opt "check_status" fields);
          service_status =
            Option.fold ~none:Rc ~some:service_status_of_sexp (List.assoc_opt "service_status" fields);
        }
  | Atom "fetch_binary" ->
      let fields =
        fields_of_sexp config
          ~known:
            [
              "version"; "packages"; "data_dir"; "binary_sha256";
              "binary_url_template"; "binary_name"; "port"; "env_values";
              "generated_secrets"; "env_template_path"; "rc_template_path";
              "check_path";
            ]
      in
      let env_values =
        Option.fold ~none:[] ~some:env_values_of_sexp (List.assoc_opt "env_values" fields) in
      let generated_secrets =
        Option.fold ~none:[] ~some:generated_secrets_of_sexp
          (List.assoc_opt "generated_secrets" fields) in
      check_env_names ~config (List.map fst env_values @ generated_secrets);
      Fetch_binary
        {
          version = atom_of_sexp (field_of_sexp "version" fields);
          packages = packages_of_sexp (field_of_sexp "packages" fields);
          data_dir = atom_of_sexp (field_of_sexp "data_dir" fields);
          binary_sha256 = atom_of_sexp (field_of_sexp "binary_sha256" fields);
          binary_url_template =
            atom_of_sexp (field_of_sexp "binary_url_template" fields);
          binary_name = atom_of_sexp (field_of_sexp "binary_name" fields);
          port = atom_of_sexp (field_of_sexp "port" fields);
          env_values;
          generated_secrets;
          env_template_path =
            atom_of_sexp (field_of_sexp "env_template_path" fields);
          rc_template_path =
            atom_of_sexp (field_of_sexp "rc_template_path" fields);
          check_path = atom_of_sexp (field_of_sexp "check_path" fields);
        }
  | Atom "freebsd_native_ocaml" ->
      let fields =
        fields_of_sexp config
          ~known:
            [
              "ocaml_switch"; "repo_path"; "source"; "opam_repository"; "zfs_dataset";
              "data_dir"; "packages"; "serve_args"; "migrate"; "check_path"; "web_bundle";
            ]
      in
      Freebsd_native_ocaml
        {
          ocaml_switch = atom_of_sexp (field_of_sexp "ocaml_switch" fields);
          repo_path = atom_of_sexp (field_of_sexp "repo_path" fields);
          source = Option.map git_source_of_sexp (List.assoc_opt "source" fields);
          opam_repository =
            Option.map pinned_git_of_sexp (List.assoc_opt "opam_repository" fields);
          zfs_dataset = atom_of_sexp (field_of_sexp "zfs_dataset" fields);
          data_dir = atom_of_sexp (field_of_sexp "data_dir" fields);
          packages = packages_of_sexp (field_of_sexp "packages" fields);
          serve_args = words_of_sexp ~field:"serve_args" (field_of_sexp "serve_args" fields);
          migrate = Option.bind (List.assoc_opt "migrate" fields) ocaml_migrate_of_sexp;
          check_path = atom_of_sexp (field_of_sexp "check_path" fields);
          web_bundle = Option.map source_path_of_sexp (List.assoc_opt "web_bundle" fields);
        }
  | Atom "freebsd_package_service" ->
      let fields =
        fields_of_sexp config
          ~known:[ "packages"; "zfs_dataset"; "data_dir"; "data_owner"; "service"; "service_args";
                   "check_path" ]
      in
      let args_sexp = field_of_sexp "service_args" fields in
      let service_args = string_list_of_sexp args_sexp in
      if service_args = [] then
        Sexplib.Conv.of_sexp_error "Strategy: service_args must not be empty" args_sexp;
      let packages_sexp = field_of_sexp "packages" fields in
      let packages = packages_of_sexp packages_sexp in
      List.iter
        (fun package ->
          if package = "" || not (String.for_all is_service_char package) then
            Sexplib.Conv.of_sexp_error "Strategy: unsafe package name" packages_sexp)
        packages;
      List.iter
        (fun arg ->
          if arg = "" || not (String.for_all is_argument_char arg) then
            Sexplib.Conv.of_sexp_error "Strategy: unsafe service argument" args_sexp)
        service_args;
      let zfs_dataset = safe_token ~field:"zfs_dataset" ~allowed:is_argument_char
          (field_of_sexp "zfs_dataset" fields) in
      let data_dir_sexp = field_of_sexp "data_dir" fields in
      let data_dir = safe_token ~field:"data_dir" ~allowed:is_argument_char data_dir_sexp in
      if not (String.starts_with ~prefix:"/" data_dir)
         || List.exists (fun part -> part = "." || part = "..")
              (String.split_on_char '/' data_dir)
      then
        Sexplib.Conv.of_sexp_error
          "Strategy: data_dir must be absolute and stay inside the jail" data_dir_sexp;
      Freebsd_package_service
        {
          packages;
          zfs_dataset;
          data_dir;
          data_owner = safe_token ~field:"data_owner" ~allowed:is_service_char
            (field_of_sexp "data_owner" fields);
          service = safe_token ~field:"service" ~allowed:is_service_char
            (field_of_sexp "service" fields);
          service_args;
          check_path = atom_of_sexp (field_of_sexp "check_path" fields);
        }
  | sexp ->
      Sexplib.Conv.of_sexp_error
        "Strategy_config: unknown strategy, expected one of \
         freebsd_native_elixir|freebsd_package|fetch_binary|freebsd_native_ocaml|freebsd_package_service"
        sexp

type error =
  | Unknown_strategy of Sexplib.Sexp.t
  | Invalid_fields of string * Sexplib.Sexp.t
  | Invalid_extra_step of string

let error_message = function
  | Unknown_strategy sexp -> "unknown strategy: " ^ Sexplib.Sexp.to_string sexp
  | Invalid_fields (message, _) -> message
  | Invalid_extra_step _ ->
      "Strategy: extra_steps entry must be a plain file name beside the script"

let offending_sexp = function
  | Unknown_strategy sexp | Invalid_fields (_, sexp) -> sexp
  | Invalid_extra_step step -> Sexplib.Sexp.Atom step

(* A step name is spliced into the generated script inside double quotes,
   so it must be a plain file name beside the script: no path, no quoting,
   no expansion, not hidden. *)
let is_plain_file_name step =
  step <> ""
  && step.[0] <> '.'
  && String.for_all
       (fun c ->
         (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')
         || c = '.' || c = '_' || c = '-')
       step

let parse_extra_steps steps =
  match List.find_opt (fun step -> not (is_plain_file_name step)) steps with
  | Some step -> Error (Invalid_extra_step step)
  | None -> Ok steps

let parse ~strategy ~config =
  match strategy with
  | Sexplib.Sexp.Atom ("freebsd_native_elixir" | "freebsd_package" | "fetch_binary" | "freebsd_native_ocaml"
                     | "freebsd_package_service") ->
      (try Ok (of_sexp ~strategy ~config) with
       | Sexplib.Conv.Of_sexp_error (Failure message, sexp) -> Error (Invalid_fields (message, sexp)))
  | sexp -> Error (Unknown_strategy sexp)
