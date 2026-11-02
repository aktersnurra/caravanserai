(* Pocket ID v2.19.1 responses for the example configuration
   (fixtures/pocket-id): decoded, they are exactly example/idp.sexp. *)
open Serai

let dir () = Filename.concat (Repo_root.find ()) "serai/test/fixtures/pocket-id"
let text name = In_channel.with_open_bin (Filename.concat (dir ()) name) In_channel.input_all

let json name =
  match Json.parse (text name) with
  | Ok json -> json
  | Error message -> failwith (name ^ ": " ^ message)

let items name =
  match Idp_live.page (json name) with
  | Ok (items, _) -> items
  | Error message -> failwith (name ^ ": " ^ message)

let live () =
  let version = match Idp_live.version (json "version.json") with
    | Ok v -> v | Error m -> failwith m in
  match Idp_live.assemble ~version ~key_owner:(json "users-me.json") ~groups:(items "user-groups.json") ~users:(items "users.json")
          ~clients:(items "oidc-clients.json")
          ~apis:(List.map (fun api -> (api, items "api-clients.json")) (items "apis.json")) with
  | Ok live -> live
  | Error message -> failwith message
