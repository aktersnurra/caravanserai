(* Pocket_id: the admin API client, against Proc.Mock standing in for curl. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let contains text needle =
  let n = String.length needle in
  let rec at i = i + n <= String.length text && (String.sub text i n = needle || at (i + 1)) in
  at 0

let key = "pid_TESTKEY123"
let url = "https://id.example.org"

let session () =
  Unix.putenv "SERAI_IDP_API_KEY" key;
  match Pocket_id.session ~url with Ok s -> s | Error m -> failwith m

(* What a mocked curl call asked for. *)
type call = { meth : string; path : string; body : string option; request : Proc.request }

let rec after flag = function
  | x :: y :: _ when x = flag -> Some y
  | _ :: rest -> after flag rest
  | [] -> None

let call_of (request : Proc.request) =
  let args = request.args in
  let target = List.nth args (List.length args - 1) in
  let path = String.sub target (String.length url) (String.length target - String.length url) in
  { meth = Option.get (after "-X" args); path; body = after "--data-binary" args; request }

let strip_query path = match String.index_opt path '?' with Some i -> String.sub path 0 i | None -> path

(* A route answers (status, body) for a call, or None to fall through. *)
let mock routes =
  let respond (request : Proc.request) =
    let c = call_of request in
    let rec go = function
      | [] -> failwith ("no route for " ^ c.meth ^ " " ^ c.path)
      | route :: rest -> (match route c with Some (status, body) -> body ^ "\n" ^ string_of_int status | None -> go rest) in
    go routes in
  Proc.Mock.create ~outputs:respond ()

let get path file c =
  if c.meth = "GET" && strip_query c.path = path then Some (200, Pocket_id_fixtures.text file) else None

let fixture_routes = [
  get "/api/version/current" "version.json";
  get "/api/users/me" "users-me.json";
  get "/api/user-groups" "user-groups.json";
  get "/api/users" "users.json";
  get "/api/oidc/clients" "oidc-clients.json";
  get "/api/apis" "apis.json";
  get "/api/apis/5b3a9f20-0000-4000-8000-000000000001/clients" "api-clients.json" ]

let calls mock = List.map call_of (Proc.Mock.calls mock)
let lines calls = List.map (fun c -> c.meth ^ " " ^ strip_query c.path) calls

let () =
  (* The key. *)
  Unix.putenv "SERAI_IDP_API_KEY" "";
  check "no key: the error says how to set it"
    (match Pocket_id.session ~url with
     | Error m -> contains m "SERAI_IDP_API_KEY" && contains m (url ^ "/settings/admin/api-keys")
     | Ok _ -> false);
  List.iter (fun (name, bad) ->
      Unix.putenv "SERAI_IDP_API_KEY" bad;
      check ("a key with " ^ name ^ " is refused") (Result.is_error (Pocket_id.session ~url)))
    [ ("a quote", "abc\"def"); ("a backslash", "abc\\def"); ("a space", "abc def"); ("a newline", "abc\ndef") ];

  (* Fetching. *)
  let s = session () in
  let m = mock fixture_routes in
  let result = Proc.Mock.run m (fun () -> Pocket_id.fetch s) in
  check "fetch gives the fixtures' live state" (result = Ok (Pocket_id_fixtures.live ()));
  check "the version is checked first, then the key's owner"
    (match lines (calls m) with
     | "GET /api/version/current" :: "GET /api/users/me" :: _ -> true | _ -> false);
  check "the key is in no request's arguments"
    (List.for_all (fun (r : Proc.request) -> not (List.exists (fun a -> contains a key) r.args)) (Proc.Mock.calls m));
  check "the key reaches each request only through its environment"
    (List.for_all (fun (r : Proc.request) ->
         r.prog = "sh" && List.assoc_opt "SERAI_IDP_API_KEY" r.extra_env = Some key) (Proc.Mock.calls m));
  check "lists are paged with globbing off"
    (List.exists (fun c -> contains c.path "pagination[page]=1&pagination[limit]=100"
                           && List.mem "-g" c.request.args) (calls m));

  let m = mock [ (fun c -> if c.path = "/api/version/current" then Some (200, {|{"currentVersion":"2.20.0"}|}) else None) ] in
  check "another minor version is refused after one request"
    (match Proc.Mock.run m (fun () -> Pocket_id.fetch s) with
     | Error e -> contains e.message "2.20.0" && contains e.message "2.19.x" && List.length (Proc.Mock.calls m) = 1
     | Ok _ -> false);

  let users_page n =
    let all = match Json.parse (Pocket_id_fixtures.text "users.json") with
      | Ok j -> (match Json.member "data" j with Ok (Some (Json.Array xs)) -> xs | _ -> []) | Error _ -> [] in
    let items = if n = 1 then [ List.nth all 1 ] else [ List.nth all 2 ] in
    Json.to_string (Json.Object [ ("data", Json.Array items); ("pagination", Json.Object [
        ("totalPages", Json.Number "2"); ("totalItems", Json.Number "2");
        ("currentPage", Json.Number (string_of_int n)); ("itemsPerPage", Json.Number "1") ]) ]) in
  let m = mock ((fun c ->
      if strip_query c.path = "/api/users" then
        Some (200, users_page (if contains c.path "pagination[page]=2" then 2 else 1))
      else None) :: fixture_routes) in
  check "every page is fetched"
    (match Proc.Mock.run m (fun () -> Pocket_id.fetch s) with
     | Ok live -> List.map (fun (u : _ Idp_live.with_id) -> (fst u.value).Idp_declaration.username) live.users = [ "alice"; "bob" ]
                  && List.length (List.filter (fun c -> strip_query c.path = "/api/users") (calls m)) = 2
     | Error e -> failwith (Pocket_id.error_message e));

  (* Errors. *)
  let m = mock [ (fun _ -> Some (400, {|{"error":"Invalid input","code":"validation_error","detail":"MARKER-in-body"}|})) ] in
  check "an error carries Pocket ID's code and message, never the body"
    (match Proc.Mock.run m (fun () -> Pocket_id.fetch s) with
     | Error e ->
         let text = Pocket_id.error_message e in
         e.status = Some 400 && e.code = Some "validation_error" && contains text "Invalid input"
         && contains text "GET /api/version/current" && not (contains text "MARKER")
     | Ok _ -> false);
  let m = Proc.Mock.create ~exit_codes:(fun _ -> 6) () in
  check "curl failing is an error"
    (match Proc.Mock.run m (fun () -> Pocket_id.fetch s) with
     | Error e -> contains e.message "curl exited 6" | Ok _ -> false);

  (* Applying: creating everything. *)
  let example = match Idp_declaration.load ~layout:(Repo_root.example ()) with
    | Ok (Some t) -> t | _ -> failwith "example/idp.sexp" in
  let live = Pocket_id_fixtures.live () in
  let empty = { live with groups = []; users = []; clients = []; apis = [] } in
  let plan = Idp_plan.plan example empty in
  let created = ref 0 in
  let fresh prefix = incr created; Printf.sprintf "%s-%d" prefix !created in
  let m = mock [ (fun c ->
      match c.meth, strip_query c.path with
      | "POST", "/api/user-groups" -> Some (201, Printf.sprintf {|{"id":"%s"}|} (fresh "g"))
      | "POST", "/api/users" -> Some (201, Printf.sprintf {|{"id":"%s"}|} (fresh "u"))
      | "POST", "/api/oidc/clients" ->
          let confidential = match c.body with Some b -> contains b {|"isPublic":false|} | None -> false in
          Some (201, if confidential then {|{"id":"logs","createdSecret":{"id":"secret-1","secret":"MARKER-SECRET"}}|}
                     else {|{"id":"hello"}|})
      | "POST", "/api/apis" -> Some (201, {|{"id":"api-1"}|})
      | "PUT", "/api/apis/api-1/permissions" ->
          Some (200, {|{"id":"api-1","permissions":[{"id":"p-read","key":"ledger:read"},{"id":"p-write","key":"ledger:write"}]}|})
      | _ -> Some (200, "{}")) ] in
  let applied = Proc.Mock.run m (fun () -> Pocket_id.apply s empty plan) in
  check "every action completes" (applied.failed = None && applied.completed = plan.actions);
  check "the requests, in order, with ids resolved"
    (lines (calls m) = [
        "POST /api/user-groups"; "POST /api/user-groups"; "PUT /api/custom-claims/user-group/g-2";
        "POST /api/users"; "PUT /api/users/u-3/user-groups"; "PUT /api/custom-claims/user/u-3";
        "POST /api/users"; "PUT /api/users/u-4/user-groups"; "PUT /api/custom-claims/user/u-4";
        "POST /api/oidc/clients"; "PUT /api/oidc/clients/hello/allowed-user-groups";
        "POST /api/oidc/clients"; "DELETE /api/oidc/clients/logs/secrets/secret-1";
        "PUT /api/oidc/clients/logs/allowed-user-groups";
        "POST /api/apis"; "PUT /api/apis/api-1/permissions";
        "PUT /api/apis/api-1/cimd-access"; "PUT /api/apis/api-1/clients/hello" ]
     || (List.iter print_endline (lines (calls m)); false));
  let body_in m meth path = match List.find_opt (fun c -> c.meth = meth && c.path = path) (calls m) with
    | Some { body = Some b; _ } -> b | _ -> "" in
  let body_of = body_in m in
  check "a new user's groups use the ids just created"
    (contains (body_of "PUT" "/api/users/u-3/user-groups") {|{"userGroupIds":["g-1","g-2"]}|});
  check "a new user with no claims still gets an empty set, overriding defaults"
    (body_of "PUT" "/api/custom-claims/user/u-4" = "[]");
  check "the returned secret is sent nowhere"
    (List.for_all (fun (r : Proc.request) -> not (List.exists (fun a -> contains a "MARKER-SECRET") r.args))
       (Proc.Mock.calls m));
  check "a new client carries its declared id" (contains (body_of "POST" "/api/oidc/clients") {|"id":"hello"|});
  check "CIMD and grants use the permission ids the update returned"
    (contains (body_of "PUT" "/api/apis/api-1/cimd-access") {|{"enabled":true,"permissionIds":["p-read"]}|}
     && contains (body_of "PUT" "/api/apis/api-1/clients/hello") {|"userDelegatedPermissionIds":["p-read"]|});

  (* Applying: updates send back what is not declared. *)
  let renamed = match Idp_declaration.make ~url ~groups:example.groups ~users:(List.map (fun (u : Idp_declaration.user) ->
      if u.username = "alice" then { u with display_name = "Alice A" } else u) example.users)
      ~clients:(List.map (fun (c : Idp_declaration.client) ->
          if c.id = "logs" then { c with name = "Logbook" } else c) example.clients) ~apis:example.apis with
    | Ok t -> t | Error m -> failwith m in
  let m = mock [ (fun _ -> Some (200, "{}")) ] in
  let applied = Proc.Mock.run m (fun () -> Pocket_id.apply s live (Idp_plan.plan renamed live)) in
  check "the updates complete" (applied.failed = None && List.length applied.completed = 2);
  let body_of = body_in m in
  let body = body_of "PUT" "/api/oidc/clients/logs" in
  check "a client update carries its logo flags and federated identities"
    (contains body {|"hasLogo":true|} && contains body {|"issuer":"https://ci.example.org"|}
     && contains body {|"name":"Logbook"|});
  check "an omitted lifetime is sent as it is live"
    (contains body {|"accessTokenDurationMinutes":60|} && contains body {|"refreshTokenDurationMinutes":43200|});
  check "a user update keeps the verified email"
    (contains (body_of "PUT" "/api/users/2c5e7a10-0000-4000-8000-000000000001") {|"emailVerified":true|});

  (* Applying: stopping at the first failure. *)
  let m = mock [ (fun _ -> Some (400, {|{"error":"Group already exists","code":"already_in_use"}|})) ] in
  let applied = Proc.Mock.run m (fun () -> Pocket_id.apply s empty plan) in
  check "a failure stops the run and says what completed"
    (applied.completed = [] && List.length (Proc.Mock.calls m) = 1
     && (match applied.failed with
         | Some (Idp_plan.Create_group { name = "admins"; _ }, e) -> e.code = Some "already_in_use"
         | _ -> false))
