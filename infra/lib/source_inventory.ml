type file = { path : string; mode : string; sha256 : string }
type t = { commit : string; files : file list }

let is_hex value =
  (String.length value = 40 || String.length value = 64)
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let is_path path =
  path <> "" && String.length path <= 4096
  && List.for_all (fun component ->
       component <> "" && component <> "." && component <> ".."
       && component <> ".env"
       && not (String.length component >= 5 && String.sub component 0 5 = ".env.")
       && not (String.starts_with ~prefix:".env~" component)
       && String.for_all (function
            | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '~' | '-' -> true
            | _ -> false) component)
       (String.split_on_char '/' path)

let sha256_file path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
    if (Unix.fstat (Unix.descr_of_in_channel channel)).Unix.st_kind <> Unix.S_REG then
      failwith "source inventory: file changed type during hashing";
    let bytes = Bytes.create 65536 in
    let rec consume state =
      let length = input channel bytes 0 (Bytes.length bytes) in
      if length = 0 then state
      else consume (Digestif.SHA256.feed_string state (Bytes.sub_string bytes 0 length))
    in
    Digestif.SHA256.(to_hex (get (consume empty))))

let create ~root ~commit =
  try
    if not (is_hex commit) then Error "source inventory: invalid full commit ID"
    else
      let rec visit directory relative =
        let info = Unix.lstat directory in
        if info.Unix.st_kind <> Unix.S_DIR || info.Unix.st_perm land 0o7777 <> 0o700 then
          failwith "source inventory: non-private or non-directory source path";
        Sys.readdir directory |> Array.to_list |> List.sort String.compare
        |> List.concat_map (fun basename ->
             let path = if relative = "" then basename else relative ^ "/" ^ basename in
             if not (is_path path) then failwith "source inventory: unsafe or secret-bearing path";
             let absolute = Filename.concat directory basename in
             let info = Unix.lstat absolute in
             match info.Unix.st_kind with
             | Unix.S_DIR -> visit absolute path
             | Unix.S_REG ->
                 let mode = match info.Unix.st_perm land 0o7777 with
                   | 0o600 -> "600" | 0o700 -> "700"
                   | _ -> failwith "source inventory: file mode must be 0600 or 0700" in
                 [ { path; mode; sha256 = sha256_file absolute } ]
             | _ -> failwith "source inventory: non-regular source entry")
      in
      let files = List.sort (fun left right -> String.compare left.path right.path) (visit root "") in
      if files = [] then Error "source inventory: empty source tree"
      else Ok { commit; files }
  with
  | Failure message -> Error message
  | Unix.Unix_error _ | Sys_error _ -> Error "source inventory: cannot read source tree"

let canonical inventory =
  let buffer = Buffer.create 1024 in
  Buffer.add_string buffer ("infra-source-v1\t" ^ inventory.commit ^ "\n");
  List.iter (fun file ->
    Buffer.add_string buffer (file.mode ^ "\t" ^ file.sha256 ^ "\t" ^ file.path ^ "\n")) inventory.files;
  Buffer.contents buffer

let identity inventory = Digestif.SHA256.(to_hex (digest_string (canonical inventory)))
