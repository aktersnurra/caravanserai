type entry = { path : string; executable : bool }

let ( let* ) value next = Result.bind value next
let error text = Error ("source snapshot: " ^ text)

let is_hex value =
  (String.length value = 40 || String.length value = 64)
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let is_revision value =
  value <> "" && String.length value <= 256
  && String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '/' | '@' | '.' | ':' | '-' -> true
       | _ -> false) value
  && value.[0] <> '-'

let is_environment_path path =
  List.exists (fun component -> component = ".env"
    || String.starts_with ~prefix:".env." component
    || String.starts_with ~prefix:".env~" component) (String.split_on_char '/' path)

let is_relative_path path =
  path <> "" && String.length path <= 4096
  && List.for_all (fun component ->
       component <> "" && component <> "." && component <> ".."
       && String.for_all (function
          | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '~' | '-' -> true
          | _ -> false) component)
       (String.split_on_char '/' path)

let status_ok = function Unix.WEXITED 0 -> true | _ -> false

let jj_args checkout arguments =
  [ "--ignore-working-copy"; "-R"; checkout ] @ arguments

(* Metadata only; stdout is bounded. Source bytes are streamed elsewhere. *)
let jj_capture jj_bin checkout arguments =
  let reader, writer = Unix.pipe ~cloexec:true () in
  let silent = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  let pid =
    try Unix.create_process jj_bin
          (Array.of_list (jj_bin :: jj_args checkout arguments)) silent writer silent
    with failure ->
      Unix.close reader; Unix.close writer; Unix.close silent; raise failure
  in
  Unix.close writer;
  Unix.close silent;
  let buffer = Buffer.create 1024 in
  let bytes = Bytes.create 8192 in
  let rec collect () =
    let count = Unix.read reader bytes 0 (Bytes.length bytes) in
    if count > 0 then begin
      if Buffer.length buffer + count > 8 * 1024 * 1024 then
        failwith "jj metadata exceeds 8 MiB";
      Buffer.add_subbytes buffer bytes 0 count;
      collect ()
    end
  in
  let output =
    try collect (); Unix.close reader; Buffer.contents buffer
    with failure -> Unix.close reader; ignore (Unix.waitpid [] pid); raise failure
  in
  let _, status = Unix.waitpid [] pid in
  if status_ok status then Ok output else error "jj could not resolve or enumerate the requested commit"

let entries_of_output output =
  let parts = String.split_on_char '\000' output in
  let rec parse seen entries = function
    | [ "" ] -> Ok (List.rev entries)
    | path :: kind :: mode :: rest ->
        if not (is_relative_path path) then error "unsafe tracked path"
        else if kind <> "file" || not (mode = "0" || mode = "1") then
          error "unsupported or conflicted tracked entry"
        else if List.mem path seen then error "duplicate tracked path"
        else if is_environment_path path then parse (path :: seen) entries rest
        else parse (path :: seen) ({ path; executable = mode = "1" } :: entries) rest
    | _ -> error "invalid jj file listing"
  in
  parse [] [] parts

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let rec ensure_parent root components =
  match components with
  | [] -> root
  | component :: rest ->
      let path = Filename.concat root component in
      (try Unix.mkdir path 0o700 with Unix.Unix_error (Unix.EEXIST, _, _) -> ());
      if (Unix.lstat path).Unix.st_kind <> Unix.S_DIR then failwith "invalid staging directory";
      Unix.chmod path 0o700;
      ensure_parent path rest

let export_entry jj_bin checkout commit root entry =
  let parts = String.split_on_char '/' entry.path in
  let filename = List.hd (List.rev parts) in
  let parent = ensure_parent root (List.rev (List.tl (List.rev parts))) in
  let destination = Filename.concat parent filename in
  let descriptor = Unix.openfile destination [Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL] 0o600 in
  let silent = Unix.openfile "/dev/null" [Unix.O_RDWR] 0 in
  let pid =
    try Unix.create_process jj_bin
          (Array.of_list (jj_bin :: jj_args checkout
             ["file"; "show"; "-r"; commit; "--"; Printf.sprintf "root:%S" entry.path]))
          silent descriptor silent
    with failure ->
      Unix.close descriptor; Unix.close silent; raise failure
  in
  Unix.close descriptor;
  Unix.close silent;
  let _, status = Unix.waitpid [] pid in
  if not (status_ok status) then failwith "jj could not export a tracked file";
  Unix.chmod destination (if entry.executable then 0o700 else 0o600)

let resolve jj_bin checkout revision =
  if not (is_revision revision) then error "invalid revision"
  else if not (Sys.file_exists (Filename.concat checkout ".jj")) then
    error "checkout is not a jj repository"
  else if not (Sys.is_directory checkout) then error "checkout is not a directory"
  else
    let* output = jj_capture jj_bin checkout
        ["log"; "-r"; revision; "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
    match String.split_on_char '\n' (String.trim output) with
    | [id] when is_hex id -> Ok id
    | _ -> error "revision must resolve to one full commit"

let stage ~jj_bin ~checkout ~revision ~out =
  try
    let* commit = resolve jj_bin checkout revision in
    let* listing = jj_capture jj_bin checkout
        ["file"; "list"; "-r"; commit; "-T";
         "path ++ \"\\0\" ++ file_type ++ \"\\0\" ++ if(executable, \"1\", \"0\") ++ \"\\0\""] in
    let* entries = entries_of_output listing in
    let parent = Filename.dirname out in
    if out = "" || out = "." || out = ".." || Filename.basename out = "." || Filename.basename out = ".." then
      error "invalid output directory"
    else if (Unix.lstat parent).Unix.st_kind <> Unix.S_DIR then
      error "output parent must be a directory"
    else if (try ignore (Unix.lstat out); true with Unix.Unix_error (Unix.ENOENT, _, _) -> false) then
      error "output already exists"
    else
      let temporary = Filename.temp_dir ~temp_dir:parent "source-snapshot-" "-tmp" in
      Fun.protect ~finally:(fun () ->
        if Sys.file_exists temporary then remove_tree temporary)
        (fun () ->
          Unix.chmod temporary 0o700;
          List.iter (export_entry jj_bin checkout commit temporary) entries;
          if (try ignore (Unix.lstat out); true with Unix.Unix_error (Unix.ENOENT, _, _) -> false)
          then failwith "output already exists";
          Unix.rename temporary out;
          Ok commit)
  with
  | Failure message -> error message
  | Unix.Unix_error _ | Sys_error _ -> error "filesystem or jj operation failed"

let stage_cached ~jj_bin ~checkout ~revision ~cache =
  try
    let* commit = resolve jj_bin checkout revision in
    let* () = match Unix.lstat cache with
      | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ }
        when st_uid = Unix.geteuid () && st_perm land 0o077 = 0 -> Ok ()
      | _ -> error "snapshot cache must be a private directory"
      | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.mkdir cache 0o700; Ok () in
    let tree = Filename.concat cache commit in
    match Unix.lstat tree with
    | { Unix.st_kind = Unix.S_DIR; _ } -> Ok (commit, tree)
    | _ -> error "cached snapshot is not a directory"
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        let* staged = stage ~jj_bin ~checkout ~revision:commit ~out:tree in
        Ok (staged, tree)
  with
  | Failure message -> error message
  | Unix.Unix_error _ | Sys_error _ -> error "filesystem or jj operation failed"
