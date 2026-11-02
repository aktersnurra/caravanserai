type claim = { key : string; value : string }
type group = { name : string; friendly_name : string; claims : claim list }

type user = {
  username : string;
  email : string option;
  first_name : string;
  last_name : string;
  display_name : string;
  admin : bool;
  disabled : bool;
  locale : string option;
  groups : string list;
  claims : claim list;
}

type client = {
  id : string;
  name : string;
  description : string;
  callback_urls : string list;
  logout_callback_urls : string list;
  backchannel_logout_url : string option;
  launch_url : string option;
  public : bool;
  pkce : bool;
  skip_consent : bool;
  allowed_groups : string list;
  access_token_minutes : int option;
  refresh_token_minutes : int option;
}

type permission = { key : string; name : string; description : string option }

type grant = {
  client : string;
  user_delegated : string list option;
  client_credentials : string list option;
}

type api = {
  resource : string;
  name : string;
  permissions : permission list;
  cimd : string list option;
  grants : grant list;
}

type t = { url : string; groups : group list; users : user list; clients : client list; apis : api list }

exception Invalid of string

let invalid fmt = Printf.ksprintf (fun message -> raise (Invalid message)) fmt

(* Pocket ID refuses these as custom claims (isReservedClaim, v2.19.1). *)
let reserved_claims =
  [ "given_name"; "family_name"; "name"; "email"; "email_verified"; "preferred_username";
    "display_name"; "groups"; "type"; "sub"; "iss"; "aud"; "exp"; "iat"; "auth_time"; "nonce";
    "acr"; "amr"; "azp"; "client_id"; "nbf"; "jti" ]

(* Token lifetimes Pocket ID accepts: a minute to a year. *)
let max_token_minutes = 365 * 24 * 60

let is_alnum = function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true | _ -> false

(* ^[a-zA-Z0-9]([a-zA-Z0-9_.@-]*[a-zA-Z0-9])?$ *)
let valid_username s =
  let n = String.length s in
  n >= 1 && is_alnum s.[0] && is_alnum s.[n - 1]
  && String.for_all (fun c -> is_alnum c || String.contains "_.@-" c) s

(* ^[a-zA-Z0-9._-]+$ *)
let valid_client_id s = String.for_all (fun c -> is_alnum c || String.contains "._-" c) s

let valid_email s =
  match String.index_opt s '@' with
  | Some i -> i > 0 && i < String.length s - 1 && not (String.exists (fun c -> c = ' ') s)
  | None -> false

let has_prefix ~prefix s =
  String.length s >= String.length prefix && String.sub s 0 (String.length prefix) = prefix

let has_space s = String.exists (function ' ' | '\t' | '\n' | '\r' -> true | _ -> false) s

(* An absolute URI with no fragment (fosite's resource indicator rule), not
   an active-content scheme (Pocket ID's), and no trailing slash, which
   Pocket ID strips before comparing. *)
let valid_audience s =
  match String.index_opt s ':' with
  | Some i when i > 0 ->
      let scheme = String.sub s 0 i in
      let scheme_ok =
        (match scheme.[0] with 'a' .. 'z' | 'A' .. 'Z' -> true | _ -> false)
        && String.for_all (fun c -> is_alnum c || String.contains "+.-" c) scheme in
      scheme_ok
      && i < String.length s - 1
      && (not (List.mem (String.lowercase_ascii scheme) [ "javascript"; "data" ]))
      && (not (String.contains s '#'))
      && (not (has_space s))
      && s.[String.length s - 1] <> '/'
  | _ -> false

let length_within what ~min ~max s =
  let n = String.length s in
  if n < min || n > max then invalid "%s must be %d to %d characters, not %d" what min max n

let check_unique what keys =
  let rec go seen = function
    | [] -> ()
    | key :: rest -> if List.mem key seen then invalid "duplicate %s %s" what key else go (key :: seen) rest in
  go [] keys

(* Sexp reading. *)

let context = "idp.sexp"
let fields ~known sexp = Sexp_fields.fields_of_sexp ~context ~known sexp
let atom sexp = Sexp_fields.atom ~context sexp
let atoms sexp = Sexp_fields.list ~context atom sexp
let opt name fields f = Option.map f (List.assoc_opt name fields)
let string_or_empty name fields = Option.value ~default:"" (opt name fields atom)
let list_or_empty name fields f = Option.value ~default:[] (opt name fields f)

let flag name fields =
  match List.assoc_opt name fields with
  | None -> false
  | Some (Sexplib.Sexp.List []) -> true
  | Some _ -> invalid "%s is a flag and takes no value" name

(* (key field ...) entries of a named list. *)
let entries sexp =
  Sexp_fields.list ~context
    (function
      | Sexplib.Sexp.List (Atom key :: rest) -> (key, Sexplib.Sexp.List rest)
      | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected (name field ...)") sexp)
    sexp

let within what name f =
  try f () with
  | Invalid message -> invalid "%s %s: %s" what name message
  | Sexplib.Conv.Of_sexp_error _ as exn ->
      (* Sexp_fields prefixes the file; the outer error adds it once. *)
      let message = Declaration.describe exn and prefix = context ^ ": " in
      let message =
        if has_prefix ~prefix message then
          String.sub message (String.length prefix) (String.length message - String.length prefix)
        else message in
      invalid "%s %s: %s" what name message

let claims_of sexp =
  let claims =
    Sexp_fields.list ~context
      (function
        | Sexplib.Sexp.List [ Atom key; Atom value ] -> { key; value }
        | sexp -> Sexplib.Conv.of_sexp_error (context ^ ": expected (claim value)") sexp)
      sexp in
  check_unique "claim" (List.map (fun (c : claim) -> c.key) claims);
  List.iter (fun (c : claim) ->
      if List.mem c.key reserved_claims then invalid "claim %s is reserved by Pocket ID" c.key;
      if c.key = "" then invalid "a claim needs a name";
      if c.value = "" then invalid "claim %s needs a value" c.key) claims;
  claims

let minutes name fields =
  opt name fields (fun sexp ->
      let text = atom sexp in
      match int_of_string_opt text with
      | Some n when n >= 1 && n <= max_token_minutes
                    && String.for_all (function '0' .. '9' -> true | _ -> false) text -> n
      | _ -> invalid "%s must be whole minutes from 1 to %d" name max_token_minutes)

let group_of (name, sexp) =
  within "group" name (fun () ->
      let f = fields ~known:[ "friendly_name"; "claims" ] sexp in
      length_within "the name" ~min:2 ~max:255 name;
      let friendly_name = atom (Sexp_fields.field ~context "friendly_name" f) in
      length_within "friendly_name" ~min:2 ~max:50 friendly_name;
      { name; friendly_name; claims = list_or_empty "claims" f claims_of })

let user_of (username, sexp) =
  within "user" username (fun () ->
      let f = fields ~known:[ "email"; "first_name"; "last_name"; "display_name"; "admin";
                              "disabled"; "locale"; "groups"; "claims" ] sexp in
      if not (valid_username username) || String.length username > 50 then
        invalid "a username is 1 to 50 letters or digits, with . _ @ - inside";
      let email = opt "email" f atom in
      Option.iter (fun e -> if not (valid_email e) then invalid "email %s is not an address" e) email;
      let first_name = string_or_empty "first_name" f in
      let last_name = string_or_empty "last_name" f in
      let display_name = string_or_empty "display_name" f in
      length_within "first_name" ~min:0 ~max:50 first_name;
      length_within "last_name" ~min:0 ~max:50 last_name;
      length_within "display_name" ~min:0 ~max:100 display_name;
      let groups = list_or_empty "groups" f atoms in
      check_unique "group" groups;
      { username; email; first_name; last_name; display_name;
        admin = flag "admin" f; disabled = flag "disabled" f; locale = opt "locale" f atom;
        groups; claims = list_or_empty "claims" f claims_of })

let client_of (id, sexp) =
  within "client" id (fun () ->
      let f = fields ~known:[ "name"; "description"; "callback_urls"; "logout_callback_urls";
                              "backchannel_logout_url"; "launch_url"; "public"; "pkce";
                              "skip_consent"; "allowed_groups"; "access_token_minutes";
                              "refresh_token_minutes" ] sexp in
      if not (valid_client_id id) then invalid "a client ID is letters, digits, . _ and -";
      length_within "the client ID" ~min:2 ~max:128 id;
      let name = atom (Sexp_fields.field ~context "name" f) in
      length_within "name" ~min:1 ~max:50 name;
      let description = string_or_empty "description" f in
      length_within "description" ~min:0 ~max:150 description;
      let allowed_groups = list_or_empty "allowed_groups" f atoms in
      check_unique "allowed group" allowed_groups;
      if flag "public" f && not (flag "pkce" f) then
        invalid "a public client always uses PKCE in Pocket ID: add (pkce)";
      let callback_urls = list_or_empty "callback_urls" f atoms in
      let logout_callback_urls = list_or_empty "logout_callback_urls" f atoms in
      check_unique "callback URL" callback_urls;
      check_unique "logout callback URL" logout_callback_urls;
      { id; name; description; callback_urls; logout_callback_urls;
        backchannel_logout_url = opt "backchannel_logout_url" f atom;
        launch_url = opt "launch_url" f atom;
        public = flag "public" f; pkce = flag "pkce" f; skip_consent = flag "skip_consent" f;
        allowed_groups;
        access_token_minutes = minutes "access_token_minutes" f;
        refresh_token_minutes = minutes "refresh_token_minutes" f })

let permission_of (key, sexp) =
  within "permission" key (fun () ->
      let f = fields ~known:[ "name"; "description" ] sexp in
      length_within "the key" ~min:1 ~max:128 key;
      let name = atom (Sexp_fields.field ~context "name" f) in
      length_within "name" ~min:1 ~max:50 name;
      let description = opt "description" f atom in
      Option.iter (length_within "description" ~min:0 ~max:200) description;
      { key; name; description })

let grant_of (client, sexp) =
  within "grant to" client (fun () ->
      let f = fields ~known:[ "user_delegated"; "client_credentials" ] sexp in
      { client; user_delegated = opt "user_delegated" f atoms;
        client_credentials = opt "client_credentials" f atoms })

let api_of (resource, sexp) =
  within "api" resource (fun () ->
      let f = fields ~known:[ "name"; "permissions"; "cimd"; "grants" ] sexp in
      if not (valid_audience resource) then
        invalid "the audience must be an absolute URI with no fragment or trailing slash";
      length_within "the audience" ~min:1 ~max:350 resource;
      let name = atom (Sexp_fields.field ~context "name" f) in
      length_within "name" ~min:1 ~max:50 name;
      let permissions = List.map permission_of (list_or_empty "permissions" f entries) in
      check_unique "permission" (List.map (fun (p : permission) -> p.key) permissions);
      let grants = List.map grant_of (list_or_empty "grants" f entries) in
      check_unique "grant to" (List.map (fun g -> g.client) grants);
      { resource; name; permissions; cimd = opt "cimd" f atoms; grants })

let check_url url =
  let prefix = "https://" in
  if not (has_prefix ~prefix url) || String.length url = String.length prefix then
    invalid "url must be https://<host>, not %s" url;
  if url.[String.length url - 1] = '/' then invalid "url must not end with /";
  if has_space url then invalid "url must not contain spaces"

let check_references t =
  let groups = List.map (fun (g : group) -> g.name) t.groups in
  let clients = List.map (fun (c : client) -> c.id) t.clients in
  let declared what known owner name =
    if not (List.mem name known) then invalid "%s names undeclared %s %s" owner what name in
  List.iter (fun (u : user) -> List.iter (declared "group" groups ("user " ^ u.username)) u.groups) t.users;
  List.iter (fun (c : client) ->
      List.iter (declared "group" groups ("client " ^ c.id)) c.allowed_groups) t.clients;
  List.iter (fun (a : api) ->
      let permissions = List.map (fun (p : permission) -> p.key) a.permissions in
      let owner = "api " ^ a.resource in
      Option.iter (List.iter (declared "permission" permissions owner)) a.cimd;
      List.iter (fun g ->
          declared "client" clients owner g.client;
          let grant_owner = owner ^ " grant to " ^ g.client in
          Option.iter (List.iter (declared "permission" permissions grant_owner)) g.user_delegated;
          Option.iter (List.iter (declared "permission" permissions grant_owner)) g.client_credentials)
        a.grants) t.apis

let parse sexp =
  try
    let f = fields ~known:[ "url"; "groups"; "users"; "clients"; "apis" ] sexp in
    let url = atom (Sexp_fields.field ~context "url" f) in
    check_url url;
    let groups = List.map group_of (list_or_empty "groups" f entries) in
    let users = List.map user_of (list_or_empty "users" f entries) in
    let clients = List.map client_of (list_or_empty "clients" f entries) in
    let apis = List.map api_of (list_or_empty "apis" f entries) in
    check_unique "group" (List.map (fun (g : group) -> g.name) groups);
    check_unique "user" (List.map (fun (u : user) -> u.username) users);
    check_unique "client" (List.map (fun (c : client) -> c.id) clients);
    check_unique "api" (List.map (fun (a : api) -> a.resource) apis);
    let t = { url; groups; users; clients; apis } in
    check_references t;
    Ok t
  with
  | Invalid message -> Error (context ^ ": " ^ message)
  | Sexplib.Conv.Of_sexp_error _ as exn -> Error (Declaration.describe exn)

let load ~layout =
  let path = Layout.idp layout in
  if not (Sys.file_exists path) then Ok None
  else
    match Sexplib.Sexp.load_sexp path with
    | sexp -> Result.map Option.some (parse sexp)
    | exception ((Sexplib.Sexp.Parse_error _ | Failure _ | Sys_error _) as exn) ->
        Error (path ^ ": " ^ Declaration.describe exn)

(* Printing, leaving out defaults so an export reads like a hand-written file. *)

let to_sexp t =
  let open Sexplib.Sexp in
  let field name value = List [ Atom name; value ] in
  let atoms xs = List (Stdlib.List.map (fun x -> Atom x) xs) in
  let text name s = if s = "" then [] else [ field name (Atom s) ] in
  let some name f = function None -> [] | Some v -> [ field name (f v) ] in
  let flag name b = if b then [ List [ Atom name ] ] else [] in
  let nonempty name f xs = if xs = [] then [] else [ field name (f xs) ] in
  let entry key fields = List (Atom key :: fields) in
  let claims = nonempty "claims"
      (fun cs -> List (Stdlib.List.map (fun (c : claim) -> List [ Atom c.key; Atom c.value ]) cs)) in
  let group (g : group) = entry g.name (field "friendly_name" (Atom g.friendly_name) :: claims g.claims) in
  let user (u : user) =
    entry u.username
      (some "email" (fun e -> Atom e) u.email
       @ text "first_name" u.first_name @ text "last_name" u.last_name
       @ text "display_name" u.display_name @ flag "admin" u.admin @ flag "disabled" u.disabled
       @ some "locale" (fun l -> Atom l) u.locale @ nonempty "groups" atoms u.groups
       @ claims u.claims) in
  let minutes name = some name (fun n -> Atom (string_of_int n)) in
  let client (c : client) =
    entry c.id
      (field "name" (Atom c.name) :: text "description" c.description
       @ nonempty "callback_urls" atoms c.callback_urls
       @ nonempty "logout_callback_urls" atoms c.logout_callback_urls
       @ some "backchannel_logout_url" (fun u -> Atom u) c.backchannel_logout_url
       @ some "launch_url" (fun u -> Atom u) c.launch_url
       @ flag "public" c.public @ flag "pkce" c.pkce @ flag "skip_consent" c.skip_consent
       @ nonempty "allowed_groups" atoms c.allowed_groups
       @ minutes "access_token_minutes" c.access_token_minutes
       @ minutes "refresh_token_minutes" c.refresh_token_minutes) in
  let permission (p : permission) =
    entry p.key (field "name" (Atom p.name) :: some "description" (fun d -> Atom d) p.description) in
  let grant g =
    entry g.client (some "user_delegated" atoms g.user_delegated
                    @ some "client_credentials" atoms g.client_credentials) in
  let api (a : api) =
    entry a.resource
      (field "name" (Atom a.name)
       :: nonempty "permissions" (fun ps -> List (Stdlib.List.map permission ps)) a.permissions
       @ some "cimd" atoms a.cimd
       @ nonempty "grants" (fun gs -> List (Stdlib.List.map grant gs)) a.grants) in
  let section name f xs = nonempty name (fun xs -> List (Stdlib.List.map f xs)) xs in
  List
    (field "url" (Atom t.url)
     :: section "groups" group t.groups @ section "users" user t.users
     @ section "clients" client t.clients @ section "apis" api t.apis)

let make ~url ~groups ~users ~clients ~apis = parse (to_sexp { url; groups; users; clients; apis })

(* Sexplib escapes every byte above 127 as a three-digit decimal escape
   inside a quoted atom; its reader takes those bytes raw, so they are
   written back raw. Escapes of bytes 0-127 (backslash, quote, control
   characters) are kept. *)
let to_string t =
  let text = Sexplib.Sexp.to_string_hum (to_sexp t) in
  let buffer = Buffer.create (String.length text) in
  let n = String.length text in
  let digit c = c >= '0' && c <= '9' in
  let rec go i =
    if i >= n then ()
    else if text.[i] = '\\' && i + 1 < n && text.[i + 1] = '\\' then begin
      Buffer.add_string buffer "\\\\"; go (i + 2)
    end
    else if text.[i] = '\\' && i + 3 < n && digit text.[i + 1] && digit text.[i + 2] && digit text.[i + 3]
            && (let code = int_of_string (String.sub text (i + 1) 3) in code >= 128 && code <= 255) then begin
      Buffer.add_char buffer (Char.chr (int_of_string (String.sub text (i + 1) 3))); go (i + 4)
    end
    else begin Buffer.add_char buffer text.[i]; go (i + 1) end in
  go 0;
  Buffer.contents buffer
