(* Idp_plan: the declaration against the live state. *)
open Serai
open Idp_declaration

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let example =
  match Idp_declaration.load ~layout:(Repo_root.example ()) with
  | Ok (Some t) -> t | _ -> failwith "example/idp.sexp"

let live = Pocket_id_fixtures.live ()

let declare ?(groups = example.groups) ?(users = example.users) ?(clients = example.clients)
    ?(apis = example.apis) () =
  match make ~url:example.url ~groups ~users ~clients ~apis with
  | Ok t -> t | Error message -> failwith message

let map_named key name f xs = List.map (fun x -> if key x = name then f x else x) xs
let with_group name f = declare ~groups:(map_named (fun (g : group) -> g.name) name f example.groups) ()
let with_user name f = declare ~users:(map_named (fun (u : user) -> u.username) name f example.users) ()
let with_client id f = declare ~clients:(map_named (fun (c : client) -> c.id) id f example.clients) ()
let with_api f = declare ~apis:(List.map f example.apis) ()

let field_of = function Idp_plan.Value field -> field | Idp_plan.Set { field; _ } -> field

let changes_of = function
  | Idp_plan.Update_group { changes; _ } | Update_user { changes; _ }
  | Update_client { changes; _ } | Update_api { changes; _ } -> List.map field_of changes
  | _ -> []

let lines_of t = String.concat "\n" (Idp_plan.lines t)

let () =
  (* In sync. *)
  let in_sync = Idp_plan.plan example live in
  check "a live state equal to the declaration plans nothing"
    (in_sync.actions = [] && in_sync.undeclared = [] && in_sync.secrets_needed = []
     && not (Idp_plan.pending in_sync) && Idp_plan.lines in_sync = []);

  (* The API key's owner: demoting or disabling it would revoke the key. *)
  let lockout_mentions declaration live fragments =
    match (Idp_plan.plan declaration live).lockout with
    | Some reason -> List.for_all (fun f ->
        let n = String.length f in
        let rec at i = i + n <= String.length reason && (String.sub reason i n = f || at (i + 1)) in
        at 0) fragments
    | None -> false in
  check "in sync, no lockout" (in_sync.lockout = None);
  check "removing the key owner's admin is a lockout"
    (lockout_mentions (with_user "alice" (fun u -> { u with admin = false })) live [ "alice"; "admin"; "API key" ]);
  check "disabling the key owner is a lockout"
    (lockout_mentions (with_user "alice" (fun u -> { u with disabled = true })) live [ "alice"; "disabl" ]);
  check "the plan still lists the change it refuses"
    ((Idp_plan.plan (with_user "alice" (fun u -> { u with admin = false })) live).actions <> []);
  check "other changes to the key owner are not"
    ((Idp_plan.plan (with_user "alice" (fun u -> { u with groups = [ "admins" ]; display_name = "A" })) live).lockout = None);
  check "demoting or disabling another user is not"
    ((Idp_plan.plan (with_user "bob" (fun u -> { u with admin = true; disabled = true })) live).lockout = None);
  check "a key owner left undeclared is never touched, so no lockout"
    ((Idp_plan.plan (declare ~users:(List.filter (fun (u : user) -> u.username <> "alice") example.users)
                       ~clients:example.clients ()) live).lockout = None);
  check "the static key's user owns no declared user, so no lockout"
    ((Idp_plan.plan (with_user "alice" (fun u -> { u with admin = false }))
        { live with key_owner = Idp_live.static_api_key_user }).lockout = None);

  (* One changed field, one action naming it: every declared field. *)
  let one_change_ids = ref [] in
  let one_change name declaration ~expect =
    let t = Idp_plan.plan declaration live in
    one_change_ids := (name, t.plan_id) :: !one_change_ids;
    match t.actions with
    | [ action ] when expect action -> Printf.printf "ok - one change: %s\n%!" name
    | actions ->
        failwith (Printf.sprintf "one change: %s gave %d actions:\n%s" name (List.length actions)
                    (lines_of t)) in
  let update_naming field action = changes_of action = [ field ] in
  let group_field field f = one_change ("group " ^ field) (with_group "family" f) ~expect:(update_naming field) in
  group_field "friendly_name" (fun g -> { g with friendly_name = "Kin" });
  group_field "claims" (fun g -> { g with claims = [ { key = "household"; value = "south" } ] });
  let user_field field f = one_change ("user " ^ field) (with_user "bob" f) ~expect:(update_naming field) in
  user_field "email" (fun u -> { u with email = Some "robert@example.org" });
  user_field "first_name" (fun u -> { u with first_name = "Robert" });
  user_field "last_name" (fun u -> { u with last_name = "Builder" });
  user_field "display_name" (fun u -> { u with display_name = "Bob B" });
  user_field "admin" (fun u -> { u with admin = true });
  user_field "disabled" (fun u -> { u with disabled = true });
  user_field "locale" (fun u -> { u with locale = Some "sv" });
  user_field "groups" (fun u -> { u with groups = [ "family"; "admins" ] });
  user_field "claims" (fun u -> { u with claims = [ { key = "ledger_account"; value = "b-002" } ] });
  let client_field field f = one_change ("client " ^ field) (with_client "logs" f) ~expect:(update_naming field) in
  client_field "name" (fun c -> { c with name = "Logbook" });
  client_field "description" (fun c -> { c with description = "" });
  client_field "callback_urls" (fun c -> { c with callback_urls = c.callback_urls @ [ "https://logs.example.org/cb2" ] });
  client_field "logout_callback_urls" (fun c -> { c with logout_callback_urls = [ "https://logs.example.org/bye" ] });
  client_field "backchannel_logout_url" (fun c -> { c with backchannel_logout_url = Some "https://logs.example.org/bc" });
  client_field "launch_url" (fun c -> { c with launch_url = Some "https://logs.example.org/" });
  one_change "client public" (with_client "hello" (fun c -> { c with public = false }))
    ~expect:(update_naming "public");
  client_field "pkce" (fun c -> { c with pkce = true });
  client_field "skip_consent" (fun c -> { c with skip_consent = true });
  client_field "allowed_groups" (fun c -> { c with allowed_groups = [ "admins"; "family" ] });
  client_field "access_token_minutes" (fun c -> { c with access_token_minutes = Some 30 });
  client_field "refresh_token_minutes" (fun c -> { c with refresh_token_minutes = Some 1440 });
  one_change "api name" (with_api (fun a -> { a with name = "Books" })) ~expect:(update_naming "name");
  one_change "api permissions: one added"
    (with_api (fun a -> { a with permissions = a.permissions @ [ { key = "ledger:admin"; name = "Admin"; description = None } ] }))
    ~expect:(update_naming "permissions");
  one_change "api permissions: a kept key renamed"
    (with_api (fun a -> { a with permissions = List.map (fun (p : permission) ->
         if p.key = "ledger:write" then { p with name = "Edit the ledger" } else p) a.permissions }))
    ~expect:(update_naming "permission ledger:write");
  one_change "api cimd"
    (with_api (fun a -> { a with cimd = Some [ "ledger:read"; "ledger:write" ] }))
    ~expect:(function Idp_plan.Set_cimd { permissions = Some [ "ledger:read"; "ledger:write" ]; _ } -> true | _ -> false);
  one_change "api cimd off" (with_api (fun a -> { a with cimd = None }))
    ~expect:(function Idp_plan.Set_cimd { permissions = None; _ } -> true | _ -> false);
  one_change "api grant changed"
    (with_api (fun a -> { a with grants = [ { client = "hello"; user_delegated = Some [ "ledger:read"; "ledger:write" ];
                                             client_credentials = None } ] }))
    ~expect:(function Idp_plan.Set_grant { grant = { client = "hello"; _ }; _ } -> true | _ -> false);
  one_change "api grant added"
    (with_api (fun a -> { a with grants = a.grants @ [ { client = "logs"; user_delegated = None;
                                                         client_credentials = Some [ "ledger:read" ] } ] }))
    ~expect:(function Idp_plan.Set_grant { grant = { client = "logs"; _ }; _ } -> true | _ -> false);
  one_change "api grant removed" (with_api (fun a -> { a with grants = [] }))
    ~expect:(function Idp_plan.Remove_grant { client = "hello"; _ } -> true | _ -> false);

  (* Plan ids: one per distinct plan. *)
  let ids = List.map snd !one_change_ids in
  check "every one-field change has a plan id" (List.for_all Option.is_some ids);
  check "and no two of them are the same"
    (List.length (List.sort_uniq compare ids) = List.length ids
     || (List.iter (fun (n, id) -> Printf.printf "%s %s\n" n (Option.fold ~none:"-" ~some:Plan_id.to_string id))
           !one_change_ids; false));
  check "in sync, no plan id" (in_sync.plan_id = None);
  check "undeclared resources alone give no plan id"
    ((Idp_plan.plan (declare ~users:(List.filter (fun (u : user) -> u.username <> "bob") example.users) ()) live).plan_id = None);
  let bob_email e = Idp_plan.plan (with_user "bob" (fun u -> { u with email = Some e })) live in
  check "the same plan twice has the same id"
    ((bob_email "robert@example.org").plan_id = (bob_email "robert@example.org").plan_id);
  check "the same field changed to another value is another plan"
    ((bob_email "robert@example.org").plan_id <> (bob_email "rob@example.org").plan_id);
  let live_bob_reborn =
    { live with users = List.map (fun (u : _ Idp_live.with_id) ->
          if (fst u.value).username = "bob" then { u with id = "2c5e7a10-0000-4000-8000-0000000000ff" } else u) live.users } in
  check "the same update to another live record is another plan"
    ((bob_email "robert@example.org").plan_id <> (Idp_plan.plan (with_user "bob" (fun u -> { u with email = Some "robert@example.org" })) live_bob_reborn).plan_id);
  check "another server is another plan"
    ((bob_email "robert@example.org").plan_id
     <> (Idp_plan.plan (match make ~url:"https://id.example.net" ~groups:example.groups
                               ~users:(map_named (fun (u : user) -> u.username) "bob" (fun u -> { u with email = Some "robert@example.org" }) example.users)
                               ~clients:example.clients ~apis:example.apis with Ok t -> t | Error m -> failwith m) live).plan_id);

  (* What is not a change. *)
  let no_change name declaration =
    check ("no change: " ^ name) ((Idp_plan.plan declaration live).actions = []) in
  no_change "set-like lists in another order"
    (declare
       ~users:(map_named (fun (u : user) -> u.username) "alice" (fun u -> { u with groups = [ "family"; "admins" ] }) example.users)
       ~clients:(map_named (fun (c : client) -> c.id) "logs" (fun c -> { c with callback_urls = List.rev c.callback_urls }) example.clients)
       ());
  let two_permissions = Some [ "ledger:write"; "ledger:read" ] in
  let live_two =
    { live with apis = List.map (fun (a : Idp_live.api Idp_live.with_id) ->
          { a with value = { a.value with api = { a.value.api with
              cimd = Some [ "ledger:read"; "ledger:write" ];
              grants = [ { client = "hello"; user_delegated = Some [ "ledger:read"; "ledger:write" ];
                           client_credentials = None } ] } } }) live.apis } in
  check "no change: CIMD and grant permissions in another order"
    ((Idp_plan.plan (with_api (fun a -> { a with cimd = two_permissions;
        grants = [ { client = "hello"; user_delegated = two_permissions; client_credentials = None } ] }))
        live_two).actions = []);
  let live_with_lifetime =
    { live with clients = List.map (fun (c : _ Idp_live.with_id) ->
          if c.id = "logs" then { c with value = ({ (fst c.value) with access_token_minutes = Some 60 }, snd c.value) }
          else c) live.clients } in
  check "no change: an omitted token lifetime leaves the live one"
    ((Idp_plan.plan example live_with_lifetime).actions = []);
  check "a declared token lifetime that differs is a change"
    (match (Idp_plan.plan (with_client "logs" (fun c -> { c with access_token_minutes = Some 30 })) live_with_lifetime).actions with
     | [ action ] -> changes_of action = [ "access_token_minutes" ] | _ -> false);

  (* Removals inside a declared resource are shown as removals. *)
  let t = Idp_plan.plan (with_user "alice" (fun u -> { u with groups = [ "admins" ] })) live in
  check "a group left out of a user's list is a removal"
    (match t.actions with
     | [ Update_user { changes = [ Set { field = "groups"; added = []; removed = [ "family" ] } ]; _ } ] -> true
     | _ -> false);
  check "and its line says so" (Idp_plan.lines t = [ "user alice: update groups (-family)" ]);
  let t = Idp_plan.plan (with_api (fun a -> { a with permissions = [ List.hd a.permissions ] })) live in
  check "a permission left out is a removal"
    (match t.actions with
     | [ Update_api { changes = [ Set { field = "permissions"; added = []; removed = [ "ledger:write" ] } ]; _ } ] -> true
     | _ -> false);
  let live_with_stray_grant =
    { live with apis = List.map (fun (a : Idp_live.api Idp_live.with_id) ->
          { a with value = { a.value with api = { a.value.api with grants = a.value.api.grants @ [
              { client = "logs"; user_delegated = Some []; client_credentials = None } ] } } }) live.apis } in
  check "a live grant the declaration leaves out is removed"
    (match (Idp_plan.plan example live_with_stray_grant).actions with
     | [ Remove_grant { client = "logs"; resource = "https://ledger.example.org/mcp" } ] -> true
     | _ -> false);

  (* Undeclared resources are reported, not acted on. *)
  let carol = { (fst (List.nth live.users 1).value) with username = "carol"; groups = []; claims = [] } in
  let live_with_extras =
    { live with
      users = live.users @ [ { id = "u-carol"; value = (carol, { email_verified = false }) } ];
      groups = live.groups @ [ { id = "g-old"; value = { name = "old"; friendly_name = "Old"; claims = [] } } ] } in
  let t = Idp_plan.plan example live_with_extras in
  check "undeclared resources are reported"
    (t.actions = [] && t.undeclared = [ (Idp_plan.Group, "old"); (Idp_plan.User, "carol") ]);
  check "undeclared alone is not pending" (not (Idp_plan.pending t));
  check "undeclared lines"
    (Idp_plan.lines t = [ "undeclared: group old (left alone)"; "undeclared: user carol (left alone)" ]);
  let only_example_minus_logs = declare ~clients:[ List.hd example.clients ] () in
  check "an undeclared client is reported"
    ((Idp_plan.plan only_example_minus_logs live).undeclared = [ (Idp_plan.Client, "logs") ]);

  (* Creating everything, in an order where each step refers only to what exists. *)
  let empty = { live with groups = []; users = []; clients = []; apis = [] } in
  let t = Idp_plan.plan example empty in
  let order = List.map (function
      | Idp_plan.Create_group g -> "group " ^ g.name
      | Create_user u -> "user " ^ u.username
      | Create_client c -> "client " ^ c.id
      | Create_api a -> "api " ^ a.resource
      | Set_cimd { resource; _ } -> "cimd " ^ resource
      | Set_grant { grant; _ } -> "grant " ^ grant.client
      | _ -> "other") t.actions in
  check "creates in dependency order"
    (order = [ "group admins"; "group family"; "user alice"; "user bob"; "client hello"; "client logs";
               "api https://ledger.example.org/mcp"; "cimd https://ledger.example.org/mcp"; "grant hello" ]);
  check "every reference is to something created earlier"
    (let rec go groups clients = function
       | [] -> true
       | Idp_plan.Create_group g :: rest -> go (g.name :: groups) clients rest
       | Create_user u :: rest -> List.for_all (fun g -> List.mem g groups) u.groups && go groups clients rest
       | Create_client c :: rest ->
           List.for_all (fun g -> List.mem g groups) c.allowed_groups && go groups (c.id :: clients) rest
       | Set_grant { grant; _ } :: rest -> List.mem grant.client clients && go groups clients rest
       | _ :: rest -> go groups clients rest in
     go [] [] t.actions);
  check "a new confidential client needs a secret, a public one does not" (t.secrets_needed = [ "logs" ]);
  check "creating is pending" (Idp_plan.pending t);

  (* Export. *)
  check "export of the live state is the declaration" (Idp_plan.export ~url:example.url live = Ok example);
  let live_with_long_lifetime =
    { live with clients = List.map (fun (c : _ Idp_live.with_id) ->
          if c.id = "logs" then { c with value = ({ (fst c.value) with access_token_minutes = Some 120 }, snd c.value) }
          else c) live.clients } in
  check "export carries a lifetime that is not the default"
    (match Idp_plan.export ~url:example.url live_with_long_lifetime with
     | Ok t -> (List.find (fun (c : client) -> c.id = "logs") t.clients).access_token_minutes = Some 120
     | Error _ -> false);
  check "export validates the url" (Result.is_error (Idp_plan.export ~url:"http://id.example.org" live));

  (* Output. *)
  let drift =
    declare
      ~groups:(example.groups @ [ { name = "guests"; friendly_name = "Guests"; claims = [] } ])
      ~users:(map_named (fun (u : user) -> u.username) "bob"
                (fun u -> { u with email = Some "robert@example.org"; groups = [ "family"; "guests" ] }) example.users)
      ~clients:(example.clients @ [ { (List.nth example.clients 1) with id = "wiki"; name = "Wiki";
                                      callback_urls = [ "https://wiki.example.org/callback" ] } ])
      ~apis:(List.map (fun a -> { a with
          permissions = a.permissions @ [ { key = "ledger:admin"; name = "Administer"; description = None } ];
          grants = [] }) example.apis)
      () in
  let t = Idp_plan.plan drift live_with_extras in
  let expected_lines = [
    "group guests: create";
    "user bob: update email, groups (+guests)";
    "client wiki: create; confidential: create a secret for it in the UI and put it in the app's env file";
    "api https://ledger.example.org/mcp: update permissions (+ledger:admin)";
    "api https://ledger.example.org/mcp: remove the grant to hello";
    "undeclared: group old (left alone)";
    "undeclared: user carol (left alone)" ] in
  check "plan lines" (Idp_plan.lines t = expected_lines
                      || (List.iter print_endline (Idp_plan.lines t); false));
  let json = Agent_cli.to_json (Agent_cli.respond ~operation:"idp" (fun () -> Ok (Idp_plan.to_json t))) in
  let contains needle =
    let n = String.length needle in
    let rec at i = i + n <= String.length json && (String.sub json i n = needle || at (i + 1)) in
    at 0 in
  check "plan JSON"
    ((contains {|"pending":true|} && contains {|"action":"create","kind":"group","name":"guests"|}
      && contains {|{"field":"groups","added":["guests"],"removed":[]}|}
      && contains {|"secrets_needed":["wiki"]|}
      && contains {|"undeclared":[{"kind":"group","name":"old"},{"kind":"user","name":"carol"}]|}
      && contains {|"action":"remove_grant","kind":"api","name":"https://ledger.example.org/mcp","client":"hello"|})
     || (print_endline json; false))
