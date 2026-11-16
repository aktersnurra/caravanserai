let ( let* ) = Result.bind

let is_sha256 = Hex.is_sha256
let file_sha256 = Fs.file_sha256 ~not_regular:"not a regular file"

let private_directory path =
  if Fs.ensure_private_directory path then Ok ()
  else Error ("base archive: " ^ path ^ " must be a private directory")

let ensure ~curl_bin ~cache ~url ~sha256 =
  let* () = if is_sha256 sha256 then Ok () else Error "base archive: invalid SHA-256" in
  let* () = private_directory cache in
  let directory = Filename.concat cache "base" in
  let* () = private_directory directory in
  let archive = Filename.concat directory (sha256 ^ ".txz") in
  if Sys.file_exists archive then
    match file_sha256 archive with
    | digest when digest = sha256 -> Ok archive
    | _ -> Error ("base archive: cached " ^ archive ^ " does not match its digest; remove it")
    | exception (Sys_error message | Failure message) -> Error ("base archive: " ^ message)
  else begin
    let partial = Filename.temp_file ~temp_dir:directory "download-" ".partial" in
    let discard () = if Sys.file_exists partial then Sys.remove partial in
    (* Whatever ends the download -- an interrupt included -- the partial
       file goes; only a verified one is renamed into place. *)
    Fun.protect ~finally:discard (fun () ->
      match Proc.run curl_bin [ "-fsSL"; "--max-time"; "1800"; "-o"; partial; "--"; url ] with
      | 0 ->
          (match file_sha256 partial with
           | digest when digest = sha256 ->
               Unix.chmod partial 0o600;
               Unix.rename partial archive;
               Ok archive
           | _ -> Error ("base archive: " ^ url ^ " does not match the declared SHA-256")
           | exception (Sys_error message | Failure message) -> Error ("base archive: " ^ message))
      | code -> Error (Printf.sprintf "base archive: downloading %s failed (exit %d)" url code))
  end
