let ( let* ) result f = Result.bind result f

let protect_root root =
  if Filename.is_relative root then Error "artifact store: root must be absolute"
  else
    match Unix.lstat root with
    | metadata when metadata.Unix.st_kind = Unix.S_DIR
        && metadata.Unix.st_uid = Unix.geteuid ()
        && metadata.Unix.st_perm land 0o077 = 0 -> Ok ()
    | _ -> Error "artifact store: root must be a private owned directory"
    | exception Unix.Unix_error _ -> Error "artifact store: root not found"

let validate_root = protect_root

let entry_path root manifest =
  Filename.concat root (Artifact_manifest.identity manifest)

let regular path =
  match Unix.lstat path with
  | metadata -> metadata.Unix.st_kind = Unix.S_REG
  | exception Unix.Unix_error _ -> false

let canonical_matches path expected =
  if not (regular path) then false
  else
    let channel = open_in_bin path in
    Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
      if (Unix.fstat (Unix.descr_of_in_channel channel)).Unix.st_kind <> Unix.S_REG then false
      else
        let contents = really_input_string channel (String.length expected) in
        contents = expected && (try ignore (input_char channel); false with End_of_file -> true))

let reuse ~root ~manifest =
  try
    let* () = protect_root root in
    let entry = entry_path root manifest in
    let* () = match Unix.lstat entry with
      | metadata when metadata.Unix.st_kind = Unix.S_DIR
          && metadata.Unix.st_uid = Unix.geteuid ()
          && metadata.Unix.st_perm land 0o077 = 0 -> Ok ()
      | _ -> Error "artifact store: unsafe entry"
      | exception Unix.Unix_error _ -> Error "artifact store: missing entry" in
    if not (canonical_matches (Filename.concat entry "manifest")
      (Artifact_manifest.canonical manifest)) then
      Error "artifact store: manifest mismatch"
    else
      let archive = Filename.concat entry "release.tar" in
      let* () = Artifact_manifest.verify_archive manifest ~archive in
      Ok archive
  with Sys_error _ | Unix.Unix_error _ | End_of_file ->
    Error "artifact store: cannot read entry"

let load ~root ~identity =
  try
    let* () = protect_root root in
    let* () = if String.length identity = 64
      && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) identity
      then Ok () else Error "artifact store: invalid identity" in
    let entry = Filename.concat root identity in
    let* () = match Unix.lstat entry with
      | metadata when metadata.Unix.st_kind = Unix.S_DIR
          && metadata.Unix.st_uid = Unix.geteuid ()
          && metadata.Unix.st_perm land 0o077 = 0 -> Ok ()
      | _ -> Error "artifact store: unsafe entry" in
    let path = Filename.concat entry "manifest" in
    let* () = if regular path then Ok () else Error "artifact store: unsafe manifest" in
    let* manifest = In_channel.with_open_bin path (fun channel ->
      let metadata = Unix.fstat (Unix.descr_of_in_channel channel) in
      if metadata.Unix.st_kind <> Unix.S_REG || metadata.Unix.st_size > 1048576
      then Error "artifact store: unsafe manifest"
      else Artifact_manifest.of_canonical (really_input_string channel metadata.Unix.st_size)) in
    let* () = if Artifact_manifest.identity manifest = identity then Ok ()
      else Error "artifact store: identity mismatch" in
    let* archive = reuse ~root ~manifest in
    Ok (manifest, archive)
  with Sys_error _ | Unix.Unix_error _ | End_of_file ->
    Error "artifact store: cannot load entry"

let is_identity name =
  String.length name = 64 && String.for_all (function '0'..'9' | 'a'..'f' -> true | _ -> false) name

let stored_manifest root identity =
  let path = Filename.concat (Filename.concat root identity) "manifest" in
  match In_channel.with_open_bin path (fun channel ->
      if in_channel_length channel > 1048576 then Error "oversized"
      else Artifact_manifest.of_canonical (In_channel.input_all channel)) with
  | Ok manifest when Artifact_manifest.identity manifest = identity -> Some manifest
  | Ok _ | Error _ -> None
  | exception Sys_error _ -> None

let find ~root ~f =
  let* () = protect_root root in
  let identities = Sys.readdir root |> Array.to_list |> List.filter is_identity |> List.sort String.compare in
  match List.find_opt (fun identity ->
      match stored_manifest root identity with Some m -> f m | None -> false) identities with
  | None -> Ok None
  | Some identity ->
      let* _ = load ~root ~identity in
      Ok (Some identity)

let rec remove_tree path =
  match Unix.lstat path with
  | { Unix.st_kind = Unix.S_DIR; _ } ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path
  | exception Unix.Unix_error (Unix.ENOENT, _, _) -> ()

let write_file path write =
  let descriptor = Unix.openfile path [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
  let channel = Unix.out_channel_of_descr descriptor in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () ->
    write channel;
    flush channel;
    Unix.fsync descriptor)

let copy_file source destination =
  let input = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    if (Unix.fstat (Unix.descr_of_in_channel input)).Unix.st_kind <> Unix.S_REG then
      failwith "artifact store: source is not regular";
    write_file destination (fun output ->
      let buffer = Bytes.create 65536 in
      let rec copy () =
        let count = Stdlib.input input buffer 0 (Bytes.length buffer) in
        if count > 0 then (Stdlib.output output buffer 0 count; copy ()) in
      copy ()))

let sync_directory path =
  let descriptor = Unix.openfile path [ Unix.O_RDONLY ] 0 in
  Fun.protect ~finally:(fun () -> Unix.close descriptor) (fun () -> Unix.fsync descriptor)

let publish ~root ~manifest ~archive =
  try
    let* () = protect_root root in
    let* () = Artifact_manifest.verify_archive manifest ~archive in
    let entry = entry_path root manifest in
    match Unix.lstat entry with
    | _ -> reuse ~root ~manifest
    | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
        let stage = Filename.temp_dir ~temp_dir:root ".infra-artifact-" "" in
        Fun.protect ~finally:(fun () -> remove_tree stage) (fun () ->
          let stored = Filename.concat stage "release.tar" in
          copy_file archive stored;
          let* () = Artifact_manifest.verify_archive manifest ~archive:stored in
          write_file (Filename.concat stage "manifest") (fun channel ->
            output_string channel (Artifact_manifest.canonical manifest));
          sync_directory stage;
          (match Unix.lstat entry with
           | _ -> ()
           | exception Unix.Unix_error (Unix.ENOENT, _, _) ->
               (try Unix.rename stage entry with
                | Unix.Unix_error ((Unix.EEXIST | Unix.ENOTEMPTY), _, _) -> ()));
          sync_directory root;
          reuse ~root ~manifest)
  with Sys_error _ | Unix.Unix_error _ | Failure _ ->
    Error "artifact store: cannot publish archive"
