type t = string

let path mirror = mirror
let ( let* ) = Result.bind

let make_private_directory path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ }
    when st_uid = Unix.geteuid () && st_perm land 0o077 = 0 -> Ok ()
  | _ -> Error ("source mirror: " ^ path ^ " must be a private directory")
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.mkdir path 0o700; Ok ()

let jj ?extra_env jj_bin mirror arguments =
  match Proc.capture ?extra_env jj_bin ([ "--ignore-working-copy"; "-R"; mirror ] @ arguments) with
  | 0, output -> Ok (String.trim output)
  | code, _ -> Error (Printf.sprintf "source mirror: jj %s failed (exit %d)" (List.hd arguments) code)

(* The URL the mirror records, before any url.<base>.insteadOf rewrite in
   the user's or system git config: jj reports the rewritten one, which is
   not what was declared. Fetching still goes through the rewrite. *)
let remote_url jj_bin mirror =
  let* remotes =
    jj ~extra_env:[ ("GIT_CONFIG_GLOBAL", "/dev/null"); ("GIT_CONFIG_NOSYSTEM", "1") ]
      jj_bin mirror [ "git"; "remote"; "list" ] in
  match List.find_map (fun line ->
      match String.split_on_char ' ' line with
      | [ "origin"; url ] -> Some url
      | _ -> None) (String.split_on_char '\n' remotes) with
  | Some url -> Ok url
  | None -> Error "source mirror: no origin remote"

let origin_url ~jj_bin checkout = remote_url jj_bin checkout

let sync ~jj_bin ~cache ~name ~url =
  let sources = Filename.concat cache "sources" in
  let mirror = Filename.concat sources name in
  let* () = make_private_directory cache in
  let* () = make_private_directory sources in
  if Sys.file_exists mirror then
    let* origin = remote_url jj_bin mirror in
    if origin <> url then
      Error (Printf.sprintf "source mirror: %s fetches %s, not the declared %s" mirror origin url)
    else
      let* _ = jj jj_bin mirror [ "git"; "fetch" ] in
      Ok mirror
  else
    match Proc.run jj_bin [ "git"; "clone"; url; mirror ] with
    | 0 -> Ok mirror
    | code -> Error (Printf.sprintf "source mirror: cloning %s failed (exit %d)" url code)

(* No revset syntax reaches jj: a bookmark name or a full commit id only. *)
let is_full_commit revision =
  String.length revision = 40
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) revision

let is_bookmark revision =
  revision <> "" && String.length revision <= 128 && revision.[0] <> '-'
  && String.for_all (function
       | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '/' | '-' -> true
       | _ -> false) revision

let resolve ~jj_bin mirror ~revision =
  let* symbol =
    if is_full_commit revision then Ok revision
    else if is_bookmark revision then Ok (Printf.sprintf "\"%s\"@origin" revision)
    else Error ("source mirror: expected a bookmark name or full commit id, got " ^ revision) in
  let revset = Printf.sprintf "(%s) & ::remote_bookmarks()" symbol in
  match jj jj_bin mirror [ "log"; "--no-graph"; "-r"; revset; "-T"; "commit_id ++ \"\\n\"" ] with
  | Ok commit when is_full_commit commit -> Ok commit
  | Ok "" -> Error (Printf.sprintf "source mirror: %s is not on the remote; push it first" revision)
  | Ok _ | Error _ -> Error ("source mirror: cannot resolve " ^ revision ^ " on the remote")

type signature_status = Good | Bad | Unknown_key | Invalid
type signature = Unsigned | Signed of { status : signature_status; key : string }

let signature_template = {|if(signature, signature.status() ++ " " ++ signature.key(), "unsigned")|}

let parse_signature output =
  let status = function
    | "good" -> Ok Good | "bad" -> Ok Bad | "unknown" -> Ok Unknown_key | "invalid" -> Ok Invalid
    | other -> Error (Printf.sprintf "source mirror: unknown signature status %S" other) in
  let output = String.trim output in
  if String.contains output '\n' then Error "source mirror: expected one signature verdict"
  else
    match String.split_on_char ' ' output with
    | [ "unsigned" ] -> Ok Unsigned
    | [ word ] when word <> "" -> Result.map (fun status -> Signed { status; key = "" }) (status word)
    | [ word; key ] when key <> "" -> Result.map (fun status -> Signed { status; key }) (status word)
    | _ -> Error (Printf.sprintf "source mirror: unreadable signature verdict %S" output)

let full_commit ~what commit =
  if is_full_commit commit then Ok commit
  else Error (Printf.sprintf "source mirror: %s must be a full commit id, got %s" what commit)

let signature ~jj_bin ?extra_env mirror ~commit =
  let* commit = full_commit ~what:"a signed commit" commit in
  let* output = jj ?extra_env jj_bin mirror [ "log"; "--no-graph"; "-r"; commit; "-T"; signature_template ] in
  parse_signature output

let is_ancestor ~jj_bin mirror ~ancestor ~descendant =
  let* ancestor = full_commit ~what:"an ancestor" ancestor in
  let* descendant = full_commit ~what:"a descendant" descendant in
  let revset = Printf.sprintf "%s & ::%s" ancestor descendant in
  match jj jj_bin mirror [ "log"; "--no-graph"; "-r"; revset; "-T"; "commit_id ++ \"\\n\"" ] with
  | Ok "" -> Ok false
  | Ok commit when commit = ancestor -> Ok true
  | Ok _ -> Error "source mirror: unexpected ancestry answer"
  | Error _ as error -> error

(* present() is empty, not an error, for a commit the mirror lacks. *)
let has_commit ~jj_bin mirror commit =
  let* commit = full_commit ~what:"a commit" commit in
  match jj jj_bin mirror [ "log"; "--no-graph"; "-r"; Printf.sprintf "present(%s)" commit; "-T"; "commit_id ++ \"\\n\"" ] with
  | Ok "" -> Ok false
  | Ok found when found = commit -> Ok true
  | Ok _ -> Error "source mirror: unexpected answer for a commit"
  | Error _ as error -> error

(* jj git clone records the remote's HEAD as the mirror's own trunk()
   alias, "<name>@origin", TOML-quoted. Read at repo scope only, so a user's
   alias never stands in for the remote's. *)
let default_branch ~jj_bin mirror =
  let alias = {|revset-aliases."trunk()"|} in
  let* value = jj jj_bin (path mirror) [ "config"; "list"; "--repo"; alias; "-T"; {|value ++ "\n"|} ] in
  let suffix = "@origin\"" in
  let name =
    if String.length value > String.length suffix + 1 && value.[0] = '"' && String.ends_with ~suffix value
    then Some (String.sub value 1 (String.length value - String.length suffix - 1)) else None in
  match name with
  | Some name when is_bookmark name -> Ok name
  | Some _ | None when value = "" ->
      Error "source mirror: the remote's default branch was not recorded when the mirror was cloned"
  | Some _ | None -> Error (Printf.sprintf "source mirror: unexpected default branch %s" value)

(* remote_bookmarks() is empty, not an error, when the bookmark is absent. *)
let remote_bookmark ~jj_bin mirror name =
  if not (is_bookmark name) then Error ("source mirror: expected a bookmark name, got " ^ name)
  else
    let revset = Printf.sprintf {|remote_bookmarks(exact:"%s", exact:"origin")|} name in
    match jj jj_bin mirror [ "log"; "--no-graph"; "-r"; revset; "-T"; "commit_id ++ \"\\n\"" ] with
    | Ok "" -> Ok None
    | Ok commit when is_full_commit commit -> Ok (Some commit)
    | Ok _ -> Error (Printf.sprintf "source mirror: %s@origin does not name one commit" name)
    | Error _ as error -> error
