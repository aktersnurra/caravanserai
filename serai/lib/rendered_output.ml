open Base

type error =
  | Destination_not_empty of string
  | Destination_not_directory of string
  | Io_error of string

let error_message = function
  | Destination_not_empty path -> "output directory is not empty: " ^ path
  | Destination_not_directory path -> "output destination must be a directory, not a file or symlink: " ^ path
  | Io_error message -> message

let rec make_directories path =
  if not (Stdlib.Sys.file_exists path) then begin
    make_directories (Stdlib.Filename.dirname path);
    Stdlib.Sys.mkdir path 0o700
  end

let write ~dir files =
  let dir = if String.equal dir "/" then dir else String.rstrip dir ~drop:(Char.equal '/') in
  try
    let existing =
      try Some (Unix.lstat dir) with Unix.Unix_error (Unix.ENOENT, _, _) -> None
    in
    let destination = match existing with
      | Some { Unix.st_kind = Unix.S_DIR; _ } ->
          if Array.is_empty (Stdlib.Sys.readdir dir) then Ok ()
          else Error (Destination_not_empty dir)
      | Some _ -> Error (Destination_not_directory dir)
      | None -> make_directories dir; Ok ()
    in
    Result.map destination ~f:(fun () ->
      List.iter files ~f:(fun (path, contents) ->
        assert (Stdlib.Filename.is_relative path
                && List.for_all (String.split path ~on:'/') ~f:(fun component ->
                    not (List.mem [ ""; "."; ".." ] component ~equal:String.equal)));
        let target = Stdlib.Filename.concat dir path in
        make_directories (Stdlib.Filename.dirname target);
        Stdlib.Out_channel.with_open_bin target (fun channel -> Stdlib.output_string channel contents)))
  with
  | Sys_error message -> Error (Io_error message)
  | Unix.Unix_error (error, operation, path) ->
      Error (Io_error (Printf.sprintf "%s %s: %s" operation path (Unix.error_message error)))
