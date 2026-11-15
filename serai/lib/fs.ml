type privacy = Private | Unsafe | Missing

let private_directory path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ }
    when st_uid = Unix.geteuid () && st_perm land 0o077 = 0 -> Private
  | _ -> Unsafe
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Missing

let rec ensure_private_directory path =
  match private_directory path with
  | Private -> true
  | Unsafe -> false
  | Missing ->
      let parent = Filename.dirname path in
      (parent = path || Sys.file_exists parent || ensure_private_directory parent)
      && (Unix.mkdir path 0o700; true)

let file_sha256 ~not_regular path =
  In_channel.with_open_bin path (fun channel ->
    if (Unix.fstat (Unix.descr_of_in_channel channel)).Unix.st_kind <> Unix.S_REG then failwith not_regular;
    let buffer = Bytes.create 65536 in
    let rec consume state =
      match In_channel.input channel buffer 0 (Bytes.length buffer) with
      | 0 -> state
      | count -> consume (Digestif.SHA256.feed_bytes state ~off:0 ~len:count buffer) in
    Digestif.SHA256.(to_hex (get (consume empty))))

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()
