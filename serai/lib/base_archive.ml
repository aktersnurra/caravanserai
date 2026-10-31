let ( let* ) = Result.bind

let is_sha256 value =
  String.length value = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let file_sha256 path =
  In_channel.with_open_bin path (fun channel ->
    let buffer = Bytes.create 65536 in
    let rec consume state =
      match In_channel.input channel buffer 0 (Bytes.length buffer) with
      | 0 -> state
      | count -> consume (Digestif.SHA256.feed_bytes state ~off:0 ~len:count buffer)
    in
    Digestif.SHA256.(to_hex (get (consume empty))))

let private_directory path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; st_uid; st_perm; _ }
    when st_uid = Unix.geteuid () && st_perm land 0o077 = 0 -> Ok ()
  | _ -> Error ("base archive: " ^ path ^ " must be a private directory")
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> Unix.mkdir path 0o700; Ok ()

let ensure ~curl_bin ~cache ~url ~sha256 =
  let* () = if is_sha256 sha256 then Ok () else Error "base archive: invalid SHA-256" in
  let* () = private_directory cache in
  let directory = Filename.concat cache "base" in
  let* () = private_directory directory in
  let archive = Filename.concat directory (sha256 ^ ".txz") in
  if Sys.file_exists archive then
    if file_sha256 archive = sha256 then Ok archive
    else Error ("base archive: cached " ^ archive ^ " does not match its digest; remove it")
  else begin
    let partial = Filename.temp_file ~temp_dir:directory "download-" ".partial" in
    let discard () = if Sys.file_exists partial then Sys.remove partial in
    match Proc.run curl_bin [ "-fsSL"; "--max-time"; "1800"; "-o"; partial; "--"; url ] with
    | 0 when file_sha256 partial = sha256 ->
        Unix.chmod partial 0o600;
        Unix.rename partial archive;
        Ok archive
    | 0 -> discard (); Error ("base archive: " ^ url ^ " does not match the declared SHA-256")
    | code -> discard (); Error (Printf.sprintf "base archive: downloading %s failed (exit %d)" url code)
  end
