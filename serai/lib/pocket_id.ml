open Idp_declaration

type session = { url : string; key : string }
type error = { request : string; status : int option; code : string option; message : string }

let key_variable = "SERAI_IDP_API_KEY"
let supported = "2.19"

let error_message e =
  let status = match e.status with Some s -> Printf.sprintf " (HTTP %d)" s | None -> "" in
  let code = match e.code with Some c -> Printf.sprintf " [%s]" c | None -> "" in
  Printf.sprintf "%s%s: %s%s" e.request status e.message code

(* The key goes into curl's config syntax, inside quotes: printable ASCII
   with no quote, backslash or space cannot break out of it. *)
let session ~url =
  match Sys.getenv_opt key_variable with
  | None | Some "" ->
      Error (Printf.sprintf "set %s (an admin API key from %s/settings/admin/api-keys) for this command"
               key_variable url)
  | Some key ->
      if String.for_all (fun c -> c > ' ' && c < '\127' && c <> '"' && c <> '\\') key then Ok { url; key }
      else Error (key_variable ^ " must be printable ASCII with no quote, backslash or whitespace")

let ( let* ) = Result.bind

(* $0 is curl; the key comes from the child's environment. *)
let script = {|printf 'header = "X-API-Key: %s"\n' "$SERAI_IDP_API_KEY" | "$0" --config - "$@"|}

let request ~curl_bin session meth path ?body () =
  let name = meth ^ " " ^ (match String.index_opt path '?' with Some i -> String.sub path 0 i | None -> path) in
  let fail ?status ?code message = Error { request = name; status; code; message } in
  let body_args = match body with
    | None -> []
    | Some json -> [ "-H"; "Content-Type: application/json"; "--data-binary"; Json.to_string json ] in
  let args =
    [ "-c"; script; curl_bin; "-sS"; "--max-time"; "30"; "-g"; "-X"; meth;
      "-H"; "Accept: application/json" ] @ body_args @ [ "-w"; "\n%{http_code}"; session.url ^ path ] in
  let code, output = Proc.capture ~extra_env:[ (key_variable, session.key) ] "sh" args in
  if code <> 0 then fail (Printf.sprintf "curl exited %d" code)
  else
    match String.rindex_opt output '\n' with
    | None -> fail "no HTTP status from curl"
    | Some i ->
        let text = String.sub output 0 i in
        let status_text = String.trim (String.sub output (i + 1) (String.length output - i - 1)) in
        (match int_of_string_opt status_text with
         | None -> fail "no HTTP status from curl"
         | Some status when status >= 200 && status < 300 ->
             if String.trim text = "" then Ok Json.Null
             else (match Json.parse text with
                 | Ok json -> Ok json
                 | Error _ -> fail ~status "the response is not JSON")
         | Some status ->
             (* Pocket ID's error and code fields only: never the body. *)
             let field name = match Json.parse text with
               | Ok json -> (match Json.member name json with Ok (Some (Json.String s)) -> Some s | _ -> None)
               | Error _ -> None in
             fail ~status ?code:(field "code")
               (Option.value ~default:"request failed" (field "error")))

let decode_error request message = { request; status = None; code = None; message }

let all_pages ~curl_bin session path =
  let rec go page acc =
    let sep = if String.contains path '?' then "&" else "?" in
    let* json = request ~curl_bin session "GET"
        (Printf.sprintf "%s%spagination[page]=%d&pagination[limit]=100" path sep page) () in
    match Idp_live.page json with
    | Error message -> Error (decode_error ("GET " ^ path) message)
    | Ok (items, `More) -> go (page + 1) (List.rev_append items acc)
    | Ok (items, `Last) -> Ok (List.rev (List.rev_append items acc)) in
  go 1 []

let rec traverse f = function
  | [] -> Ok []
  | x :: rest -> let* y = f x in let* ys = traverse f rest in Ok (y :: ys)

let supported_version version =
  let version = if String.length version > 0 && version.[0] = 'v' then
      String.sub version 1 (String.length version - 1) else version in
  String.starts_with ~prefix:(supported ^ ".") version

let fetch ?(curl_bin = "curl") session =
  let* json = request ~curl_bin session "GET" "/api/version/current" () in
  let* version = Result.map_error (decode_error "GET /api/version/current") (Idp_live.version json) in
  if not (supported_version version) then
    Error { request = "GET /api/version/current"; status = None; code = None;
            message = Printf.sprintf "Pocket ID %s: serai idp is tested against %s.x only" version supported }
  else
    let* groups = all_pages ~curl_bin session "/api/user-groups" in
    let* users = all_pages ~curl_bin session "/api/users" in
    let* clients = all_pages ~curl_bin session "/api/oidc/clients" in
    let* apis = all_pages ~curl_bin session "/api/apis" in
    let* apis = traverse (fun api ->
        let* id = Result.map_error (decode_error "GET /api/apis")
            (match Json.member "id" api with Ok (Some (Json.String id)) -> Ok id | _ -> Error "an API without an id") in
        let* grants = all_pages ~curl_bin session ("/api/apis/" ^ id ^ "/clients") in
        Ok (api, grants)) apis in
    Result.map_error (decode_error "decode")
      (Idp_live.assemble ~version ~groups ~users ~clients ~apis)

(* Request bodies. *)

let text s = Json.String s
let texts xs = Json.Array (List.map text xs)
let opt_text = function None -> Json.Null | Some s -> Json.String s
let claims_body claims = Json.Array (List.map (fun (c : claim) ->
    Json.Object [ ("key", text c.key); ("value", text c.value) ]) claims)

let user_body (u : user) ~email_verified =
  Json.Object [
    ("username", text u.username); ("email", opt_text u.email); ("emailVerified", Json.Bool email_verified);
    ("firstName", text u.first_name); ("lastName", text u.last_name); ("displayName", text u.display_name);
    ("isAdmin", Json.Bool u.admin); ("locale", opt_text u.locale); ("disabled", Json.Bool u.disabled) ]

let new_client_extra : Idp_live.client_extra =
  { has_logo = false; has_dark_logo = false; requires_reauthentication = false;
    pushed_authorization_requests = false; federated_identities = Json.Null }

let client_body ?id (c : client) (extra : Idp_live.client_extra) ~access ~refresh =
  let minutes = function None -> Json.Number "0" | Some n -> Json.Number (string_of_int n) in
  Json.Object (
    (match id with Some id -> [ ("id", text id) ] | None -> [])
    @ [ ("name", text c.name); ("description", text c.description);
        ("callbackURLs", texts c.callback_urls); ("logoutCallbackURLs", texts c.logout_callback_urls);
        ("backchannelLogoutURL", text (Option.value ~default:"" c.backchannel_logout_url));
        ("isPublic", Json.Bool c.public); ("pkceEnabled", Json.Bool c.pkce);
        ("requiresReauthentication", Json.Bool extra.requires_reauthentication);
        ("requiresPushedAuthorizationRequests", Json.Bool extra.pushed_authorization_requests);
        ("skipConsent", Json.Bool c.skip_consent);
        ("credentials", Json.Object [ ("federatedIdentities",
            (match extra.federated_identities with Json.Null -> Json.Array [] | fi -> fi)) ]);
        ("launchURL", opt_text c.launch_url);
        ("hasLogo", Json.Bool extra.has_logo); ("hasDarkLogo", Json.Bool extra.has_dark_logo);
        ("isGroupRestricted", Json.Bool (c.allowed_groups <> []));
        ("accessTokenDurationMinutes", minutes access); ("refreshTokenDurationMinutes", minutes refresh) ])

let permissions_body (a : api) =
  Json.Object [ ("permissions", Json.Array (List.map (fun (p : permission) ->
      Json.Object [ ("key", text p.key); ("name", text p.name); ("description", opt_text p.description) ])
      a.permissions)) ]

(* Apply. *)

type applied = { completed : Idp_plan.action list; failed : (Idp_plan.action * error) option }

type ids = {
  mutable groups : (string * string) list;  (* name -> id *)
  mutable users : (string * string) list;  (* username -> id *)
  mutable apis : (string * string) list;  (* audience -> id *)
  mutable permissions : (string * (string * string) list) list;  (* audience -> key -> id *)
}

let id_field request json =
  match Json.member "id" json with
  | Ok (Some (Json.String id)) -> Ok id
  | _ -> Error (decode_error request "the response has no id")

let decode_permission_ids request json =
  let decode p = match Json.member "key" p, Json.member "id" p with
    | Ok (Some (Json.String key)), Ok (Some (Json.String id)) -> Ok (key, id)
    | _ -> Error "a permission without a key or id" in
  match Json.member "permissions" json with
  | Ok (Some ps) -> Result.map_error (decode_error request) (Json.list decode ps)
  | _ -> Error (decode_error request "the response has no permissions")

let lookup what table key =
  match List.assoc_opt key table with
  | Some id -> Ok id
  | None -> Error (decode_error "apply" (Printf.sprintf "no id for %s %s" what key))

let apply ?(curl_bin = "curl") session (live : Idp_live.t) (plan : Idp_plan.t) =
  let call meth path ?body () = request ~curl_bin session meth path ?body () in
  let ids = {
    groups = List.map (fun (g : group Idp_live.with_id) -> (g.value.name, g.id)) live.groups;
    users = List.map (fun (u : _ Idp_live.with_id) -> ((fst u.value).username, u.id)) live.users;
    apis = List.map (fun (a : Idp_live.api Idp_live.with_id) -> (a.value.api.resource, a.id)) live.apis;
    permissions = List.map (fun (a : Idp_live.api Idp_live.with_id) ->
        (a.value.api.resource, a.value.permission_ids)) live.apis } in
  let live_client id = List.find_opt (fun (c : _ Idp_live.with_id) -> c.id = id) live.clients in
  let live_user name = List.find_opt (fun (u : _ Idp_live.with_id) -> (fst u.value).username = name) live.users in
  let group_ids names = traverse (lookup "group" ids.groups) names in
  let permission_ids resource keys =
    let table = Option.value ~default:[] (List.assoc_opt resource ids.permissions) in
    traverse (lookup ("permission of " ^ resource) table) keys in
  let set_memberships user_id groups =
    let* group_ids = group_ids groups in
    let* _ = call "PUT" ("/api/users/" ^ user_id ^ "/user-groups")
        ~body:(Json.Object [ ("userGroupIds", texts group_ids) ]) () in
    Ok () in
  let set_claims kind id claims =
    let* _ = call "PUT" ("/api/custom-claims/" ^ kind ^ "/" ^ id) ~body:(claims_body claims) () in
    Ok () in
  let set_allowed_groups (c : client) =
    if c.allowed_groups = [] then Ok ()
    else
      let* group_ids = group_ids c.allowed_groups in
      let* _ = call "PUT" ("/api/oidc/clients/" ^ c.id ^ "/allowed-user-groups")
          ~body:(Json.Object [ ("userGroupIds", texts group_ids) ]) () in
      Ok () in
  let set_permissions api_id (a : api) =
    let* response = call "PUT" ("/api/apis/" ^ api_id ^ "/permissions") ~body:(permissions_body a) () in
    let* table = decode_permission_ids "PUT /api/apis/:id/permissions" response in
    ids.permissions <- (a.resource, table) :: List.remove_assoc a.resource ids.permissions;
    Ok () in
  let run = function
    | Idp_plan.Create_group g ->
        let* response = call "POST" "/api/user-groups"
            ~body:(Json.Object [ ("friendlyName", text g.friendly_name); ("name", text g.name) ]) () in
        let* id = id_field "POST /api/user-groups" response in
        ids.groups <- (g.name, id) :: ids.groups;
        if g.claims = [] then Ok () else set_claims "user-group" id g.claims
    | Update_group { group = g; _ } ->
        let* id = lookup "group" ids.groups g.name in
        let* _ = call "PUT" ("/api/user-groups/" ^ id)
            ~body:(Json.Object [ ("friendlyName", text g.friendly_name); ("name", text g.name) ]) () in
        set_claims "user-group" id g.claims
    | Create_user u ->
        let* group_ids = group_ids u.groups in
        let body = match user_body u ~email_verified:false with
          | Json.Object fields -> Json.Object (fields @ [ ("userGroupIds", texts group_ids) ])
          | other -> other in
        let* response = call "POST" "/api/users" ~body () in
        let* id = id_field "POST /api/users" response in
        ids.users <- (u.username, id) :: ids.users;
        (* Explicitly, so Pocket ID's defaults for new users do not stay. *)
        let* () = set_memberships id u.groups in
        set_claims "user" id u.claims
    | Update_user { user = u; _ } ->
        let* id = lookup "user" ids.users u.username in
        let email_verified = match live_user u.username with
          | Some l -> (snd l.value).Idp_live.email_verified | None -> false in
        let* _ = call "PUT" ("/api/users/" ^ id) ~body:(user_body u ~email_verified) () in
        let* () = set_memberships id u.groups in
        set_claims "user" id u.claims
    | Create_client c ->
        let* response = call "POST" "/api/oidc/clients"
            ~body:(client_body ~id:c.id c new_client_extra ~access:c.access_token_minutes
                     ~refresh:c.refresh_token_minutes) () in
        (* Pocket ID may create a first secret and return it once: delete
           it unread, so no credential exists that nobody holds. *)
        let* () = match Json.member "createdSecret" response with
          | Ok (Some (Json.Object _ as secret)) ->
              let* secret_id = id_field "POST /api/oidc/clients" secret in
              let* _ = call "DELETE" ("/api/oidc/clients/" ^ c.id ^ "/secrets/" ^ secret_id) () in
              Ok ()
          | _ -> Ok () in
        set_allowed_groups c
    | Update_client { client = c; _ } ->
        let extra, live_access, live_refresh = match live_client c.id with
          | Some l -> let lc, extra = l.value in (extra, lc.access_token_minutes, lc.refresh_token_minutes)
          | None -> (new_client_extra, None, None) in
        let keep declared live = match declared with Some _ -> declared | None -> live in
        let* _ = call "PUT" ("/api/oidc/clients/" ^ c.id)
            ~body:(client_body c extra ~access:(keep c.access_token_minutes live_access)
                     ~refresh:(keep c.refresh_token_minutes live_refresh)) () in
        set_allowed_groups c
    | Create_api a ->
        let* response = call "POST" "/api/apis"
            ~body:(Json.Object [ ("name", text a.name); ("resource", text a.resource) ]) () in
        let* id = id_field "POST /api/apis" response in
        ids.apis <- (a.resource, id) :: ids.apis;
        set_permissions id a
    | Update_api { api = a; _ } ->
        let* id = lookup "api" ids.apis a.resource in
        let* _ = call "PUT" ("/api/apis/" ^ id) ~body:(Json.Object [ ("name", text a.name) ]) () in
        set_permissions id a
    | Set_cimd { resource; permissions } ->
        let* id = lookup "api" ids.apis resource in
        let* permission_ids = permission_ids resource (Option.value ~default:[] permissions) in
        let* _ = call "PUT" ("/api/apis/" ^ id ^ "/cimd-access")
            ~body:(Json.Object [ ("enabled", Json.Bool (permissions <> None));
                                 ("permissionIds", texts permission_ids) ]) () in
        Ok ()
    | Set_grant { resource; grant } ->
        let* id = lookup "api" ids.apis resource in
        let* delegated = permission_ids resource (Option.value ~default:[] grant.user_delegated) in
        let* credentials = permission_ids resource (Option.value ~default:[] grant.client_credentials) in
        let* _ = call "PUT" ("/api/apis/" ^ id ^ "/clients/" ^ grant.client)
            ~body:(Json.Object [
                ("userDelegatedAccess", Json.Bool (grant.user_delegated <> None));
                ("clientAccess", Json.Bool (grant.client_credentials <> None));
                ("userDelegatedPermissionIds", texts delegated);
                ("clientPermissionIds", texts credentials) ]) () in
        Ok ()
    | Remove_grant { resource; client } ->
        let* id = lookup "api" ids.apis resource in
        let* _ = call "DELETE" ("/api/apis/" ^ id ^ "/clients/" ^ client) () in
        Ok () in
  let rec go completed = function
    | [] -> { completed = List.rev completed; failed = None }
    | action :: rest ->
        (match run action with
         | Ok () -> go (action :: completed) rest
         | Error error -> { completed = List.rev completed; failed = Some (action, error) }) in
  go [] plan.actions
