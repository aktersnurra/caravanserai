(* Idp_live: Pocket ID's responses decoded into the declaration's records. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let contains text needle =
  let n = String.length needle in
  let rec at i = i + n <= String.length text && (String.sub text i n = needle || at (i + 1)) in
  at 0

let json text = match Json.parse text with Ok j -> j | Error m -> failwith m

(* assemble with one resource kind replaced. *)
let assemble ?(key_owner = Pocket_id_fixtures.json "users-me.json") ?(groups = []) ?(users = [])
    ?(clients = []) ?(apis = []) () =
  Idp_live.assemble ~version:"2.19.1" ~key_owner ~groups ~users ~clients ~apis

let error_mentions result fragments =
  match result with
  | Ok _ -> false
  | Error message -> List.for_all (contains message) fragments

let () =
  let example =
    match Idp_declaration.load ~layout:(Repo_root.example ()) with
    | Ok (Some t) -> t | _ -> failwith "example/idp.sexp" in
  let live = Pocket_id_fixtures.live () in
  let values xs = List.map (fun (x : _ Idp_live.with_id) -> x.value) xs in
  check "the version" (live.version = "2.19.1");
  check "the key's owner is /users/me's id" (live.key_owner = "2c5e7a10-0000-4000-8000-000000000001");
  check "a /users/me without an id is an error"
    (error_mentions (assemble ~key_owner:(json {|{"username":"alice"}|}) ()) [ "users/me"; "id" ]);
  check "groups decode to the example's" (values live.groups = example.groups);
  check "users decode to the example's, without the static API key user"
    (List.map fst (values live.users) = example.users);
  let without_lifetimes (c : Idp_declaration.client) =
    { c with access_token_minutes = None; refresh_token_minutes = None } in
  check "clients decode to the example's, without the CIMD client"
    (List.map (fun (c, _) -> without_lifetimes c) (values live.clients) = example.clients);
  check "stored lifetimes decode as they are"
    (List.for_all (fun ((c : Idp_declaration.client), _) ->
         c.access_token_minutes = Some 60 && c.refresh_token_minutes = Some 43200) (values live.clients));
  check "APIs decode to the example's, CIMD-only entries not grants"
    (List.map (fun (a : Idp_live.api) -> a.api) (values live.apis) = example.apis);
  check "ids are kept"
    ((List.hd live.groups).id = "6f1d0c3e-0000-4000-8000-000000000001"
     && (List.hd live.clients).id = "hello");
  check "permission ids by key"
    ((List.hd live.apis).value.permission_ids
     = [ ("ledger:read", "7c4d2e10-0000-4000-8000-000000000001");
         ("ledger:write", "7c4d2e10-0000-4000-8000-000000000002") ]);
  let logs_extra = snd (List.nth live.clients 1).value in
  check "a client's logo and federated identities are kept"
    (logs_extra.has_logo && not logs_extra.has_dark_logo
     && (match logs_extra.federated_identities with Json.Array [ _ ] -> true | _ -> false));
  check "a client with no federated identities keeps Null"
    ((snd (List.hd live.clients).value).federated_identities = Json.Null);
  check "a user's verified email is kept"
    (List.map (fun (u : _ Idp_live.with_id) -> (snd u.value).Idp_live.email_verified) live.users = [ true; false ]);

  (* Pages. *)
  check "a page with more after it"
    (match Idp_live.page (json {|{"data":[1],"pagination":{"totalPages":3,"totalItems":250,"currentPage":2,"itemsPerPage":100}}|}) with
     | Ok ([ Json.Number "1" ], `More) -> true | _ -> false);
  check "the last page"
    (match Idp_live.page (json {|{"data":[],"pagination":{"totalPages":0,"totalItems":0,"currentPage":1,"itemsPerPage":100}}|}) with
     | Ok ([], `Last) -> true | _ -> false);
  check "a page without data is an error" (Result.is_error (Idp_live.page (json {|{"pagination":{}}|})));
  check "a version response without currentVersion is an error"
    (Result.is_error (Idp_live.version (json {|{"latestVersion":"2.19.1"}|})));

  (* Values idp.sexp reads differently. *)
  let client_json = List.hd (Pocket_id_fixtures.items "oidc-clients.json") in
  let with_field name value = match client_json with
    | Json.Object fields -> Json.Object (List.map (fun (k, v) -> if k = name then (k, value) else (k, v)) fields)
    | _ -> assert false in
  check "a token lifetime is Some when set"
    (match assemble ~clients:[ with_field "accessTokenDurationMinutes" (Json.Number "60") ] () with
     | Ok live -> (fst (List.hd live.clients).value).access_token_minutes = Some 60 | Error _ -> false);
  check "a backchannel URL is Some when set"
    (match assemble ~clients:[ with_field "backchannelLogoutURL" (Json.String "https://hello.example.org/bc") ] () with
     | Ok live -> (fst (List.hd live.clients).value).backchannel_logout_url = Some "https://hello.example.org/bc"
     | Error _ -> false);
  check "an unrestricted client allows no groups, whatever it lists"
    (match assemble ~clients:[ with_field "isGroupRestricted" (Json.Bool false) ] () with
     | Ok live -> (fst (List.hd live.clients).value).allowed_groups = [] | Error _ -> false);
  check "a client restricted to no groups is an error naming it"
    (error_mentions (assemble ~clients:[ with_field "allowedUserGroups" (Json.Array []) ] ())
       [ "client hello"; "restricted to no groups" ]);
  check "a mistyped field is an error naming the resource and field"
    (error_mentions (assemble ~clients:[ with_field "isPublic" (Json.String "yes") ] ())
       [ "client hello"; "isPublic"; "boolean" ]);
  check "a missing field is an error naming it"
    (error_mentions
       (assemble ~clients:[ (match client_json with
                              | Json.Object fields -> Json.Object (List.remove_assoc "pkceEnabled" fields)
                              | _ -> assert false) ] ())
       [ "client hello"; "missing pkceEnabled" ]);
  let api_json = List.hd (Pocket_id_fixtures.items "apis.json") in
  check "a grant of an unknown permission id is an error"
    (error_mentions
       (assemble ~apis:[ (api_json, [ json {|{"client":{"id":"hello"},"userDelegatedAccess":true,
           "clientAccess":false,"userDelegatedPermissionIds":["nope"],"clientPermissionIds":[]}|} ]) ] ())
       [ "api https://ledger.example.org/mcp"; "grant to hello"; "unknown permission id nope" ]);
  check "client-credentials access decodes"
    (match assemble ~apis:[ (api_json, [ json {|{"client":{"id":"hello"},"userDelegatedAccess":false,
              "clientAccess":true,"userDelegatedPermissionIds":[],
              "clientPermissionIds":["7c4d2e10-0000-4000-8000-000000000002"]}|} ]) ] () with
     | Ok live ->
         (List.hd live.apis).value.api.grants
         = [ { client = "hello"; user_delegated = None; client_credentials = Some [ "ledger:write" ] } ]
     | Error _ -> false);
  check "CIMD off is None"
    (match api_json with
     | Json.Object fields ->
         (match assemble ~apis:[ (Json.Object (List.map (fun (k, v) ->
              if k = "allowCimdClients" then (k, Json.Bool false) else (k, v)) fields), []) ] () with
          | Ok live -> (List.hd live.apis).value.api.cimd = None | Error _ -> false)
     | _ -> false)
