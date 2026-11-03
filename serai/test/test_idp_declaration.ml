(* Idp_declaration: reading and validating idp.sexp. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let parse_text text = Idp_declaration.parse (Sexplib.Sexp.of_string text)

let refused name text =
  match parse_text text with
  | Ok _ -> failwith ("accepted: " ^ name)
  | Error message -> Printf.printf "ok - refused: %s (%s)\n%!" name message

(* A valid declaration with one of each, for the refusals to vary. *)
let base ?(url = "https://id.example.org") ?(groups = "(g1 (friendly_name Group))")
    ?(users = "(u1 (groups (g1)))") ?(clients = "(c1 (name Client) (allowed_groups (g1)))")
    ?(apis = "(https://api.example.org/mcp (name Api) (permissions ((p:read (name Read)))) \
              (cimd (p:read)) (grants ((c1 (user_delegated (p:read))))))")
    ?(extra = "") () =
  Printf.sprintf "((url %s) (groups (%s)) (users (%s)) (clients (%s)) (apis (%s)) %s)"
    url groups users clients apis extra

let () =
  let open Idp_declaration in
  (* The example. *)
  let example =
    match load ~layout:(Repo_root.example ()) with
    | Ok (Some t) -> t
    | Ok None -> failwith "example/idp.sexp missing"
    | Error message -> failwith message in
  check "the example's url" (example.url = "https://id.example.org");
  let alice = List.find (fun (u : user) -> u.username = "alice") example.users in
  let bob = List.find (fun (u : user) -> u.username = "bob") example.users in
  check "a flag sets its field" (alice.admin && not alice.disabled);
  check "a user's groups and claims"
    (alice.groups = [ "admins"; "family" ]
     && alice.claims = [ { key = "ledger_account"; value = "a-001" } ]);
  check "omitted fields are Pocket ID's defaults"
    (not bob.admin && not bob.disabled && bob.locale = None && bob.display_name = ""
     && bob.last_name = "" && bob.first_name = "Bob" && bob.claims = []
     && bob.email = Some "bob@example.org");
  let family = List.find (fun (g : group) -> g.name = "family") example.groups in
  check "a group's claims" (family.claims = [ { key = "household"; value = "north" } ]);
  let hello = List.find (fun (c : client) -> c.id = "hello") example.clients in
  let logs = List.find (fun (c : client) -> c.id = "logs") example.clients in
  check "a public PKCE client" (hello.public && hello.pkce && hello.allowed_groups = [ "family" ]);
  check "a confidential client's defaults"
    (not logs.public && not logs.pkce && not logs.skip_consent
     && logs.access_token_minutes = None && logs.launch_url = None
     && logs.description = "Log viewer behind oauth2-proxy");
  let ledger = List.hd example.apis in
  check "an API's permissions, CIMD and grants"
    (ledger.resource = "https://ledger.example.org/mcp"
     && List.map (fun (p : permission) -> p.key) ledger.permissions = [ "ledger:read"; "ledger:write" ]
     && ledger.cimd = Some [ "ledger:read" ]
     && ledger.grants = [ { client = "hello"; user_delegated = Some [ "ledger:read" ];
                            client_credentials = None } ]);
  check "the example round-trips through to_sexp" (parse (to_sexp example) = Ok example);
  check "make builds the same declaration"
    (make ~url:example.url ~groups:example.groups ~users:example.users ~clients:example.clients
       ~apis:example.apis = Ok example);
  let accented = match make ~url:example.url
      ~groups:[ { name = "family"; friendly_name = "Famille \xc3\xa9t\xc3\xa9 \xe2\x80\x93 \\ \"q\""; claims = [] } ]
      ~users:[] ~clients:[] ~apis:[] with Ok t -> t | Error m -> failwith m in
  let printed = to_string accented in
  check "to_string writes UTF-8 as it is"
    (let needle = "Famille \xc3\xa9t\xc3\xa9 \xe2\x80\x93" in
     let n = String.length needle in
     let rec at i = i + n <= String.length printed && (String.sub printed i n = needle || at (i + 1)) in
     at 0);
  check "to_string reads back the same, backslashes and quotes included"
    (parse (Sexplib.Sexp.of_string printed) = Ok accented);
  check "to_string of the example reads back" (parse (Sexplib.Sexp.of_string (to_string example)) = Ok example);
  check "each resource prints as to_sexp prints it"
    (let section name xs = if xs = [] then [] else [ Sexplib.Sexp.List [ Sexplib.Sexp.Atom name; Sexplib.Sexp.List xs ] ] in
     to_sexp example
     = Sexplib.Sexp.List
         (Sexplib.Sexp.List [ Sexplib.Sexp.Atom "url"; Sexplib.Sexp.Atom example.url ]
          :: section "groups" (List.map group_to_sexp example.groups)
          @ section "users" (List.map user_to_sexp example.users)
          @ section "clients" (List.map client_to_sexp example.clients)
          @ section "apis" (List.map api_to_sexp example.apis)));
  check "make validates"
    (Result.is_error (make ~url:example.url ~groups:[] ~users:example.users ~clients:[] ~apis:[]));

  (* No file. *)
  let empty_config = Filename.temp_dir "idp-declaration" "test" in
  check "no idp.sexp is None"
    (load ~layout:(Layout.v ~engine:empty_config ~config:empty_config) = Ok None);
  Unix.rmdir empty_config;

  (* Minimal and optional. *)
  check "only a url is required"
    (match parse_text "((url https://id.example.org))" with
     | Ok t -> t.groups = [] && t.users = [] && t.clients = [] && t.apis = []
     | Error _ -> false);
  check "the base declaration is valid" (Result.is_ok (parse_text (base ())));
  check "CIMD on with no permissions"
    (match parse_text (base ~apis:"(https://api.example.org/mcp (name Api) (cimd ()))" ()) with
     | Ok t -> (List.hd t.apis).cimd = Some []
     | Error _ -> false);
  check "token durations"
    (match parse_text (base ~clients:"(c1 (name C) (access_token_minutes 60) (refresh_token_minutes 1440))"
                         ~apis:"" ()) with
     | Ok t -> let c = List.hd t.clients in
         c.access_token_minutes = Some 60 && c.refresh_token_minutes = Some 1440
     | Error _ -> false);
  check "a refused declaration names the resource"
    (match parse_text (base ~users:"(u1 (groups (nope)))" ()) with
     | Error message ->
         let contains s sub =
           let n = String.length sub in
           let rec at i = i + n <= String.length s && (String.sub s i n = sub || at (i + 1)) in
           at 0 in
         contains message "u1" && contains message "nope"
     | Ok _ -> false);

  (* Structure. *)
  refused "an unknown top-level field" (base ~extra:"(extra x)" ());
  refused "a missing url" "((groups ()))";
  refused "a repeated field" (base ~users:"(u1 (email a@example.org) (email b@example.org))" ());
  refused "an unknown user field" (base ~users:"(u1 (nickname x))" ());
  refused "a flag with a value" (base ~users:"(u1 (admin yes))" ());
  refused "a non-integer token duration" (base ~clients:"(c1 (name C) (access_token_minutes soon))" ~apis:"" ());
  refused "a zero token duration" (base ~clients:"(c1 (name C) (access_token_minutes 0))" ~apis:"" ());

  (* The url. *)
  refused "a plain http url" (base ~url:"http://id.example.org" ());
  refused "a url with a trailing slash" (base ~url:"https://id.example.org/" ());
  refused "a url with no host" (base ~url:"https://" ());

  (* Duplicates. *)
  refused "a duplicate group" (base ~groups:"(g1 (friendly_name Alpha)) (g1 (friendly_name Beta))" ());
  refused "a duplicate user" (base ~users:"(u1) (u1)" ());
  refused "a duplicate client" (base ~clients:"(c1 (name A)) (c1 (name B))" ());
  refused "a duplicate API"
    (base ~apis:"(https://api.example.org/mcp (name A)) (https://api.example.org/mcp (name B))" ());
  refused "a duplicate permission key"
    (base ~apis:"(https://api.example.org/mcp (name A) (permissions ((p (name A)) (p (name B)))))" ());
  refused "a duplicate claim key" (base ~users:"(u1 (claims ((k a) (k b))))" ());
  refused "a duplicate grant client"
    (base ~apis:"(https://api.example.org/mcp (name Api) (permissions ((p:read (name Read)))) \
                 (grants ((c1 (user_delegated ())) (c1 (client_credentials ())))))" ());

  (* References. *)
  refused "a user in an undeclared group" (base ~users:"(u1 (groups (nope)))" ());
  refused "a client allowing an undeclared group" (base ~clients:"(c1 (name C) (allowed_groups (nope)))" ());
  refused "a grant to an undeclared client"
    (base ~apis:"(https://api.example.org/mcp (name Api) (grants ((nope (user_delegated ())))))" ());
  refused "a grant of an undeclared permission"
    (base ~apis:"(https://api.example.org/mcp (name Api) (permissions ((p:read (name Read)))) \
                 (grants ((c1 (client_credentials (p:write))))))" ());
  refused "CIMD for an undeclared permission"
    (base ~apis:"(https://api.example.org/mcp (name Api) (permissions ((p:read (name Read)))) (cimd (p:write)))" ());

  (* Claims. *)
  List.iter (fun key -> refused ("the reserved claim " ^ key) (base ~users:(Printf.sprintf "(u1 (claims ((%s x))))" key) ()))
    [ "email"; "sub"; "groups"; "preferred_username"; "type" ];
  refused "an empty claim value" (base ~groups:{|(g1 (friendly_name Group) (claims ((k ""))))|} ());

  (* Pocket ID's limits. *)
  refused "a username starting with a dot" (base ~users:"(.alice)" ());
  refused "a username ending with a hyphen" (base ~users:"(alice-)" ());
  refused "a username with a space" (base ~users:{|("al ice")|} ());
  refused "a username over 50" (base ~users:(Printf.sprintf "(%s)" (String.make 51 'a')) ());
  check "a one-character username and one with @ . _ -"
    (Result.is_ok (parse_text (base ~users:"(a) (al.i_c-e@x)" ())));
  refused "an email without @" (base ~users:"(u1 (email alice))" ());
  refused "a client ID with a space" (base ~clients:{|("c 1" (name C))|} ~apis:"" ());
  refused "a client ID of one character" (base ~clients:"(c (name C))" ~apis:"" ());
  refused "a client ID over 128" (base ~clients:(Printf.sprintf "(%s (name C))" (String.make 129 'c')) ~apis:"" ());
  refused "a public client without pkce" (base ~clients:"(c1 (name C) (public))" ~apis:"" ());
  refused "a client without a name" (base ~clients:"(c1)" ~apis:"" ());
  refused "a client name over 50" (base ~clients:(Printf.sprintf "(c1 (name %s))" (String.make 51 'n')) ~apis:"" ());
  refused "a client description over 150"
    (base ~clients:(Printf.sprintf "(c1 (name C) (description %s))" (String.make 151 'd')) ~apis:"" ());
  refused "a group friendly name of one character" (base ~groups:"(g1 (friendly_name G))" ());
  refused "a group name of one character" (base ~groups:"(g (friendly_name Group))" ~users:"(u1)" ~clients:"(c1 (name C))" ());
  refused "a group without a friendly name" (base ~groups:"(g1)" ());
  refused "a first name over 50" (base ~users:(Printf.sprintf "(u1 (first_name %s))" (String.make 51 'f')) ());
  refused "a display name over 100" (base ~users:(Printf.sprintf "(u1 (display_name %s))" (String.make 101 'd')) ());
  refused "an API name over 50"
    (base ~apis:(Printf.sprintf "(https://api.example.org/mcp (name %s))" (String.make 51 'n')) ());
  refused "a permission key over 128"
    (base ~apis:(Printf.sprintf "(https://api.example.org/mcp (name A) (permissions ((%s (name P)))))"
                   (String.make 129 'k')) ());
  refused "a permission description over 200"
    (base ~apis:(Printf.sprintf "(https://api.example.org/mcp (name A) (permissions ((p (name P) (description %s)))))"
                   (String.make 201 'd')) ());

  (* Audiences. *)
  refused "an audience with a trailing slash" (base ~apis:"(https://api.example.org/mcp/ (name A))" ());
  refused "an audience that is not an absolute URI" (base ~apis:"(ledger (name A))" ());
  refused "an audience with an active-content scheme" (base ~apis:"(javascript:alert (name A))" ());
  check "a urn audience" (Result.is_ok (parse_text (base ~apis:"(urn:example:ledger (name A))" ())))
