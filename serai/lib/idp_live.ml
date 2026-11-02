type 'a with_id = { id : string; value : 'a }

type client_extra = {
  has_logo : bool;
  has_dark_logo : bool;
  requires_reauthentication : bool;
  pushed_authorization_requests : bool;
  federated_identities : Json.t;
}

type user_extra = { email_verified : bool }
type api = { api : Idp_declaration.api; permission_ids : (string * string) list }

type t = {
  version : string;
  groups : Idp_declaration.group with_id list;
  users : (Idp_declaration.user * user_extra) with_id list;
  clients : (Idp_declaration.client * client_extra) with_id list;
  apis : api with_id list;
}

let static_api_key_user = "00000000-0000-0000-0000-000000000000"

let ( let* ) = Result.bind

let traverse f items =
  let rec go acc = function
    | [] -> Ok (List.rev acc)
    | item :: rest -> let* v = f item in go (v :: acc) rest in
  go [] items

(* A required field, its error naming the field. *)
let req name decode json =
  match Json.member name json with
  | Error message -> Error message
  | Ok None -> Error ("missing " ^ name)
  | Ok (Some value) -> Result.map_error (fun m -> name ^ ": " ^ m) (decode value)

(* An optional field: missing or null is None. *)
let opt name decode json =
  match Json.member name json with
  | Error message -> Error message
  | Ok (None | Some Json.Null) -> Ok None
  | Ok (Some value) -> Result.map (fun v -> Some v) (Result.map_error (fun m -> name ^ ": " ^ m) (decode value))

let strings = Json.list Json.string
let named what name result = Result.map_error (fun m -> Printf.sprintf "%s %s: %s" what name m) result

(* customClaims: absent or null for a resource with none. *)
let claims json =
  let claim c =
    let* key = req "key" Json.string c in
    let* value = req "value" Json.string c in
    Ok ({ key; value } : Idp_declaration.claim) in
  match opt "customClaims" (Json.list claim) json with
  | Ok None -> Ok []
  | Ok (Some claims) -> Ok claims
  | Error _ as error -> error

let page json =
  let* data = req "data" (Json.list Result.ok) json in
  let* pagination = req "pagination" Result.ok json in
  let* current = req "currentPage" Json.int pagination in
  let* total = req "totalPages" Json.int pagination in
  Ok (data, if current < total then `More else `Last)

let version json = req "currentVersion" Json.string json

let group json =
  let* id = req "id" Json.string json in
  let* name = req "name" Json.string json in
  named "group" name
    (let* friendly_name = req "friendlyName" Json.string json in
     let* claims = claims json in
     Ok { id; value = ({ name; friendly_name; claims } : Idp_declaration.group) })

let user json =
  let* id = req "id" Json.string json in
  let* username = req "username" Json.string json in
  named "user" username
    (let* email = opt "email" Json.string json in
     let* first_name = req "firstName" Json.string json in
     let* last_name = opt "lastName" Json.string json in
     let* display_name = req "displayName" Json.string json in
     let* admin = req "isAdmin" Json.bool json in
     let* disabled = req "disabled" Json.bool json in
     let* locale = opt "locale" Json.string json in
     let* email_verified = req "emailVerified" Json.bool json in
     let* groups = req "userGroups" (Json.list (req "name" Json.string)) json in
     let* claims = claims json in
     Ok { id;
          value = (({ username; email; first_name; last_name = Option.value ~default:"" last_name;
                      display_name; admin; disabled; locale; groups; claims } : Idp_declaration.user),
                   { email_verified }) })

let minutes name json =
  let* n = req name Json.int json in
  Ok (if n = 0 then None else Some n)

let client json =
  let* id = req "id" Json.string json in
  named "client" id
    (let* name = req "name" Json.string json in
     let* description = req "description" Json.string json in
     let* callback_urls = req "callbackURLs" strings json in
     let* logout_callback_urls = req "logoutCallbackURLs" strings json in
     let* backchannel = opt "backchannelLogoutURL" Json.string json in
     let* launch_url = opt "launchURL" Json.string json in
     let* public = req "isPublic" Json.bool json in
     let* pkce = req "pkceEnabled" Json.bool json in
     let* skip_consent = req "skipConsent" Json.bool json in
     let* restricted = req "isGroupRestricted" Json.bool json in
     let* groups = req "allowedUserGroups" (Json.list (req "name" Json.string)) json in
     let* allowed_groups =
       match restricted, groups with
       | false, _ -> Ok []
       | true, [] -> Error "restricted to no groups, which idp.sexp cannot declare; \
                            allow a group or lift the restriction in the UI"
       | true, groups -> Ok groups in
     let* access_token_minutes = minutes "accessTokenDurationMinutes" json in
     let* refresh_token_minutes = minutes "refreshTokenDurationMinutes" json in
     let* has_logo = req "hasLogo" Json.bool json in
     let* has_dark_logo = req "hasDarkLogo" Json.bool json in
     let* requires_reauthentication = req "requiresReauthentication" Json.bool json in
     let* pushed_authorization_requests = req "requiresPushedAuthorizationRequests" Json.bool json in
     let* credentials = req "credentials" Result.ok json in
     let* federated_identities =
       Result.map (Option.value ~default:Json.Null) (opt "federatedIdentities" Result.ok credentials) in
     let backchannel_logout_url = match backchannel with Some "" -> None | other -> other in
     Ok { id;
          value = (({ id; name; description; callback_urls; logout_callback_urls;
                      backchannel_logout_url; launch_url; public; pkce; skip_consent;
                      allowed_groups; access_token_minutes; refresh_token_minutes }
                    : Idp_declaration.client),
                   { has_logo; has_dark_logo; requires_reauthentication;
                     pushed_authorization_requests; federated_identities }) })

(* A grant names permissions by id; idp.sexp by key. *)
let grant ~permission_ids json =
  let* client = req "client" (req "id" Json.string) json in
  named "grant to" client
    (let key id =
       match List.find_opt (fun (_, pid) -> pid = id) permission_ids with
       | Some (key, _) -> Ok key
       | None -> Error ("unknown permission id " ^ id) in
     let access flag ids =
       let* on = req flag Json.bool json in
       if not on then Ok None
       else
         let* ids = Result.map (Option.value ~default:[]) (opt ids strings json) in
         Result.map Option.some (traverse key ids) in
     let* user_delegated = access "userDelegatedAccess" "userDelegatedPermissionIds" in
     let* client_credentials = access "clientAccess" "clientPermissionIds" in
     Ok ({ client; user_delegated; client_credentials } : Idp_declaration.grant))

let api (json, grant_items) =
  let* id = req "id" Json.string json in
  let* resource = req "resource" Json.string json in
  named "api" resource
    (let* name = req "name" Json.string json in
     let* permissions =
       req "permissions"
         (Json.list (fun p ->
              let* pid = req "id" Json.string p in
              let* key = req "key" Json.string p in
              let* pname = req "name" Json.string p in
              let* description = opt "description" Json.string p in
              let* cimd = req "allowedForCimdClients" Json.bool p in
              Ok ((({ key; name = pname; description } : Idp_declaration.permission), pid), cimd)))
         json in
     let* cimd_on = req "allowCimdClients" Json.bool json in
     let permission_ids = List.map (fun (((p : Idp_declaration.permission), pid), _) -> (p.key, pid)) permissions in
     let cimd =
       if cimd_on then
         Some (List.filter_map (fun (((p : Idp_declaration.permission), _), on) ->
                   if on then Some p.key else None) permissions)
       else None in
     (* An entry with neither access is a CIMD client's, not a grant. *)
     let* grants = traverse (grant ~permission_ids) grant_items in
     let grants = List.filter (fun (g : Idp_declaration.grant) ->
                      g.user_delegated <> None || g.client_credentials <> None) grants in
     Ok { id;
          value = { api = { resource; name; permissions = List.map (fun ((p, _), _) -> p) permissions;
                            cimd; grants };
                    permission_ids } })

let assemble ~version ~groups ~users ~clients ~apis =
  let* groups = traverse group groups in
  let* users = traverse user users in
  let users = List.filter (fun u -> u.id <> static_api_key_user) users in
  let* clients = traverse client clients in
  let* apis = traverse api apis in
  Ok { version; groups; users; clients; apis }
