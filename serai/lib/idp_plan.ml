open Idp_declaration

type kind = Group | User | Client | Api
type change = Value of string | Set of { field : string; added : string list; removed : string list }

type action =
  | Create_group of group
  | Update_group of { group : group; changes : change list }
  | Create_user of user
  | Update_user of { user : user; changes : change list }
  | Create_client of client
  | Update_client of { client : client; changes : change list }
  | Create_api of api
  | Update_api of { api : api; changes : change list }
  | Set_cimd of { resource : string; permissions : string list option }
  | Set_grant of { resource : string; grant : grant }
  | Remove_grant of { resource : string; client : string }

type t = { actions : action list; undeclared : (kind * string) list; secrets_needed : string list }

let sorted xs = List.sort_uniq compare xs

(* Field comparisons, each giving the change if the field differs. *)
let value field live declared = if live = declared then [] else [ Value field ]

let set field live declared =
  let live = sorted live and declared = sorted declared in
  let added = List.filter (fun x -> not (List.mem x live)) declared in
  let removed = List.filter (fun x -> not (List.mem x declared)) live in
  if added = [] && removed = [] then [] else [ Set { field; added; removed } ]

let claim_strings claims = List.map (fun (c : claim) -> c.key ^ "=" ^ c.value) claims

(* A lifetime left out of the declaration is not managed. *)
let managed field live = function None -> [] | Some _ as declared -> value field live declared

let group_changes (live : group) (g : group) =
  value "friendly_name" live.friendly_name g.friendly_name
  @ set "claims" (claim_strings live.claims) (claim_strings g.claims)

let user_changes (live : user) (u : user) =
  value "email" live.email u.email
  @ value "first_name" live.first_name u.first_name
  @ value "last_name" live.last_name u.last_name
  @ value "display_name" live.display_name u.display_name
  @ value "admin" live.admin u.admin
  @ value "disabled" live.disabled u.disabled
  @ value "locale" live.locale u.locale
  @ set "groups" live.groups u.groups
  @ set "claims" (claim_strings live.claims) (claim_strings u.claims)

let client_changes (live : client) (c : client) =
  value "name" live.name c.name
  @ value "description" live.description c.description
  @ set "callback_urls" live.callback_urls c.callback_urls
  @ set "logout_callback_urls" live.logout_callback_urls c.logout_callback_urls
  @ value "backchannel_logout_url" live.backchannel_logout_url c.backchannel_logout_url
  @ value "launch_url" live.launch_url c.launch_url
  @ value "public" live.public c.public
  @ value "pkce" live.pkce c.pkce
  @ value "skip_consent" live.skip_consent c.skip_consent
  @ set "allowed_groups" live.allowed_groups c.allowed_groups
  @ managed "access_token_minutes" live.access_token_minutes c.access_token_minutes
  @ managed "refresh_token_minutes" live.refresh_token_minutes c.refresh_token_minutes

let api_changes (live : api) (a : api) =
  let keys ps = List.map (fun (p : permission) -> p.key) ps in
  let kept =
    List.filter_map (fun (p : permission) ->
        match List.find_opt (fun (l : permission) -> l.key = p.key) live.permissions with
        | Some l when l <> p -> Some (Value ("permission " ^ p.key))
        | _ -> None) a.permissions in
  value "name" live.name a.name @ set "permissions" (keys live.permissions) (keys a.permissions) @ kept

let normalize_grant (g : grant) =
  { g with user_delegated = Option.map sorted g.user_delegated;
           client_credentials = Option.map sorted g.client_credentials }

(* For each declared resource, a create or an update; [key] names both. *)
let reconcile ~key ~live ~create ~update declared =
  List.filter_map (fun d ->
      match List.find_opt (fun l -> key l = key d) live with
      | None -> Some (create d)
      | Some l -> update l d) declared

let undeclared kind ~key ~live declared =
  List.filter_map (fun l ->
      if List.exists (fun d -> key d = key l) declared then None else Some (kind, key l)) live

let plan (d : Idp_declaration.t) (live : Idp_live.t) =
  let values xs = List.map (fun (x : _ Idp_live.with_id) -> x.value) xs in
  let live_groups = values live.groups in
  let live_users = List.map fst (values live.users) in
  let live_clients = List.map fst (values live.clients) in
  let live_apis = List.map (fun (a : Idp_live.api) -> a.api) (values live.apis) in
  let update make changes = match changes with [] -> None | changes -> Some (make changes) in
  let groups =
    reconcile ~key:(fun (g : group) -> g.name) ~live:live_groups d.groups
      ~create:(fun g -> Create_group g)
      ~update:(fun l g -> update (fun changes -> Update_group { group = g; changes }) (group_changes l g)) in
  let users =
    reconcile ~key:(fun (u : user) -> u.username) ~live:live_users d.users
      ~create:(fun u -> Create_user u)
      ~update:(fun l u -> update (fun changes -> Update_user { user = u; changes }) (user_changes l u)) in
  let clients =
    reconcile ~key:(fun (c : client) -> c.id) ~live:live_clients d.clients
      ~create:(fun c -> Create_client c)
      ~update:(fun l c -> update (fun changes -> Update_client { client = c; changes }) (client_changes l c)) in
  let apis =
    reconcile ~key:(fun (a : api) -> a.resource) ~live:live_apis d.apis
      ~create:(fun a -> Create_api a)
      ~update:(fun l a -> update (fun changes -> Update_api { api = a; changes }) (api_changes l a)) in
  let live_api resource = List.find_opt (fun (a : api) -> a.resource = resource) live_apis in
  let cimd =
    List.filter_map (fun (a : api) ->
        let live_cimd = Option.bind (live_api a.resource) (fun l -> l.cimd) in
        let created = live_api a.resource = None in
        if (created && a.cimd = None) || ((not created) && Option.map sorted live_cimd = Option.map sorted a.cimd)
        then None
        else Some (Set_cimd { resource = a.resource; permissions = a.cimd })) d.apis in
  let grants =
    List.concat_map (fun (a : api) ->
        let live_grants = match live_api a.resource with Some l -> l.grants | None -> [] in
        let set =
          List.filter_map (fun (g : grant) ->
              match List.find_opt (fun (l : grant) -> l.client = g.client) live_grants with
              | Some l when normalize_grant l = normalize_grant g -> None
              | _ -> Some (Set_grant { resource = a.resource; grant = g })) a.grants in
        let removed =
          List.filter_map (fun (l : grant) ->
              if List.exists (fun (g : grant) -> g.client = l.client) a.grants then None
              else Some (Remove_grant { resource = a.resource; client = l.client })) live_grants in
        set @ removed) d.apis in
  let actions = groups @ users @ clients @ apis @ cimd @ grants in
  let undeclared =
    undeclared Group ~key:(fun (g : group) -> g.name) ~live:live_groups d.groups
    @ undeclared User ~key:(fun (u : user) -> u.username) ~live:live_users d.users
    @ undeclared Client ~key:(fun (c : client) -> c.id) ~live:live_clients d.clients
    @ undeclared Api ~key:(fun (a : api) -> a.resource) ~live:live_apis d.apis in
  let secrets_needed =
    List.filter_map (function Create_client c when not c.public -> Some c.id | _ -> None) actions in
  { actions; undeclared; secrets_needed }

let pending t = t.actions <> []

let kind_name = function Group -> "group" | User -> "user" | Client -> "client" | Api -> "api"

let change_text = function
  | Value field -> field
  | Set { field; added; removed } ->
      let marks = List.map (( ^ ) "+") added @ List.map (( ^ ) "-") removed in
      Printf.sprintf "%s (%s)" field (String.concat " " marks)

let update_line kind name changes =
  Printf.sprintf "%s %s: update %s" kind name (String.concat ", " (List.map change_text changes))

let action_line = function
  | Create_group g -> "group " ^ g.name ^ ": create"
  | Update_group { group; changes } -> update_line "group" group.name changes
  | Create_user u -> "user " ^ u.username ^ ": create"
  | Update_user { user; changes } -> update_line "user" user.username changes
  | Create_client c when c.public -> "client " ^ c.id ^ ": create"
  | Create_client c ->
      "client " ^ c.id ^ ": create; confidential: create a secret for it in the UI and put it in the app's env file"
  | Update_client { client; changes } -> update_line "client" client.id changes
  | Create_api a -> "api " ^ a.resource ^ ": create"
  | Update_api { api; changes } -> update_line "api" api.resource changes
  | Set_cimd { resource; permissions = None } -> "api " ^ resource ^ ": CIMD off"
  | Set_cimd { resource; permissions = Some keys } ->
      Printf.sprintf "api %s: CIMD on (%s)" resource (String.concat " " keys)
  | Set_grant { resource; grant } ->
      let access label = function
        | None -> []
        | Some keys -> [ Printf.sprintf "%s (%s)" label (String.concat " " keys) ] in
      Printf.sprintf "api %s: grant %s %s" resource grant.client
        (String.concat ", " (access "user_delegated" grant.user_delegated
                             @ access "client_credentials" grant.client_credentials))
  | Remove_grant { resource; client } -> Printf.sprintf "api %s: remove the grant to %s" resource client

let lines t =
  List.map action_line t.actions
  @ List.map (fun (kind, name) -> Printf.sprintf "undeclared: %s %s (left alone)" (kind_name kind) name)
      t.undeclared

let to_json t =
  let open Agent_cli in
  let strings xs = Array (List.map (fun x -> Text x) xs) in
  let change = function
    | Value field -> Object [ ("field", Text field) ]
    | Set { field; added; removed } ->
        Object [ ("field", Text field); ("added", strings added); ("removed", strings removed) ] in
  let entry action kind name extra =
    Object ([ ("action", Text action); ("kind", Text (kind_name kind)); ("name", Text name) ] @ extra) in
  let changes cs = [ ("changes", Array (List.map change cs)) ] in
  let keys = function None -> Null | Some ks -> strings ks in
  let action = function
    | Create_group g -> entry "create" Group g.name []
    | Update_group { group; changes = cs } -> entry "update" Group group.name (changes cs)
    | Create_user u -> entry "create" User u.username []
    | Update_user { user; changes = cs } -> entry "update" User user.username (changes cs)
    | Create_client c -> entry "create" Client c.id []
    | Update_client { client; changes = cs } -> entry "update" Client client.id (changes cs)
    | Create_api a -> entry "create" Api a.resource []
    | Update_api { api; changes = cs } -> entry "update" Api api.resource (changes cs)
    | Set_cimd { resource; permissions } -> entry "set_cimd" Api resource [ ("permissions", keys permissions) ]
    | Set_grant { resource; grant } ->
        entry "set_grant" Api resource
          [ ("client", Text grant.client); ("user_delegated", keys grant.user_delegated);
            ("client_credentials", keys grant.client_credentials) ]
    | Remove_grant { resource; client } -> entry "remove_grant" Api resource [ ("client", Text client) ] in
  Object
    [ ("pending", Bool (pending t));
      ("actions", Array (List.map action t.actions));
      ("undeclared", Array (List.map (fun (kind, name) ->
           Object [ ("kind", Text (kind_name kind)); ("name", Text name) ]) t.undeclared));
      ("secrets_needed", strings t.secrets_needed) ]

(* Pocket ID stores these when a client sets none (v2.19.1). *)
let default_access_token_minutes = 60
let default_refresh_token_minutes = 30 * 24 * 60

let export ~url (live : Idp_live.t) =
  let values xs = List.map (fun (x : _ Idp_live.with_id) -> x.value) xs in
  let unless_default default = function Some n when n = default -> None | other -> other in
  let client (c : client) =
    { c with access_token_minutes = unless_default default_access_token_minutes c.access_token_minutes;
             refresh_token_minutes = unless_default default_refresh_token_minutes c.refresh_token_minutes } in
  make ~url ~groups:(values live.groups) ~users:(List.map fst (values live.users))
    ~clients:(List.map (fun (c, _) -> client c) (values live.clients))
    ~apis:(List.map (fun (a : Idp_live.api) -> a.api) (values live.apis))
