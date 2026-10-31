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
