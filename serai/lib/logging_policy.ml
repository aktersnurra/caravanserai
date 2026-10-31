(* A jail either keeps its syslog local, or forwards through a reviewed
   sender its app ships: a syslog-ng snippet, the files it runs and an
   optional preflight, all under the app's logging/<source>/. Every sender
   forwards to the receiver, an app the policy names. The engine knows no
   app's logs. *)
type source = Local_only | Reviewed of string
type jail = { name : string; source : source }
type t = { receiver : string; jails : jail list }

let context = "Logging_policy"

let source_of_atom ~reviewed ~jail = function
  | "local_only" -> Ok Local_only
  | name
    when String.length name > 0
         && (match name.[0] with 'a' .. 'z' -> true | _ -> false)
         && String.for_all (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) name ->
      if reviewed ~jail ~source:name then Ok (Reviewed name)
      else Error (Printf.sprintf "logging source %s is not a reviewed sender %s ships" name jail)
  | value -> Error ("unapproved logging source: " ^ value)

let parse ~apps ~reviewed (sexp : Sexplib.Sexp.t) =
  try
    let fields = Sexp_fields.fields_of_sexp ~context ~known:[ "receiver"; "jails" ] sexp in
    let entry = function
      | Sexplib.Sexp.List [ Atom name; Atom source ] -> Ok (name, source)
      | _ -> Error "expected (jail_name source_type)"
    in
    let entries =
      match Sexp_fields.field ~context "jails" fields with
      | List entries -> entries
      | _ -> []
    in
    let receiver =
      match Sexp_fields.field ~context "receiver" fields with
      | Atom name -> name
      | sexp -> Sexplib.Conv.of_sexp_error "Logging_policy: receiver must be an app name" sexp
    in
    if App_config.find apps receiver = None then Error ("undeclared logging receiver: " ^ receiver)
    else if entries = [] then Error "logging policy requires at least one jail"
    else
      let rec collect seen jails = function
        | [] -> Ok { receiver; jails = List.rev jails }
        | sexp :: rest ->
            (match entry sexp with
             | Error _ as error -> error
             | Ok (name, source_name) ->
                 if not (Network_endpoint.is_placeholder_safe name) then
                   Error ("invalid jail name: " ^ name)
                 else if name = receiver then
                   Error (Printf.sprintf "the receiver %s cannot forward itself" name)
                 else if List.mem name seen then Error ("duplicate logging jail: " ^ name)
                 else if App_config.find apps name = None then Error ("undeclared logging jail: " ^ name)
                 else
                   match source_of_atom ~reviewed ~jail:name source_name with
                   | Error _ as error -> error
                   | Ok source -> collect (name :: seen) ({ name; source } :: jails) rest)
      in
      collect [] [] entries
  with Sexplib.Conv.Of_sexp_error (exn, _) -> Error (Printexc.to_string exn)

let sender_dir layout ~jail ~source =
  Filename.concat (Filename.concat (Layout.app_dir layout jail) "logging") source

let load ~layout ~apps =
  let reviewed ~jail ~source =
    let conf = Filename.concat (sender_dir layout ~jail ~source) "sender.conf" in
    Sys.file_exists conf && not (Sys.is_directory conf) in
  match parse ~apps ~reviewed (Sexplib.Sexp.load_sexp (Layout.logging layout)) with
  | Ok policy -> policy
  | Error error -> failwith ("logging policy: " ^ error)

let render_targets policy =
  let source_name = function
    | Local_only -> "local_only"
    | Reviewed name -> name
  in
  policy.jails
  |> List.map (fun jail -> jail.name ^ " " ^ source_name jail.source)
  |> String.concat "\n" |> fun text -> text ^ "\n"

let receiver policy = policy.receiver

let reviewed policy =
  List.filter_map (fun jail -> match jail.source with
    | Reviewed source -> Some (jail.name, source) | Local_only -> None) policy.jails
