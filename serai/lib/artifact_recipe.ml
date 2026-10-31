type staged = { sha256 : string; scripts : (string * string) list }

let scripts =
  [ "artifact_build_jail.sh"; "artifact_build_phoenix.sh"; "artifact_verify_source.sh";
    "artifact_resolve_packages.sh"; "artifact_build_assets.exs" ]

let valid_sha256 value = String.length value = 64
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let valid_release value = value <> "" && String.length value <= 128
  && String.for_all (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false) value

let valid_package value = value <> "" && String.length value <= 128
  && String.for_all
       (function 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '+' | '-' -> true | _ -> false)
       value

let copy_and_hash source destination =
  if (Unix.lstat source).Unix.st_kind <> Unix.S_REG then
    failwith "artifact recipe: builder script must be regular";
  let input = open_in_bin source in
  Fun.protect ~finally:(fun () -> close_in input) (fun () ->
    if (Unix.fstat (Unix.descr_of_in_channel input)).Unix.st_kind <> Unix.S_REG then
      failwith "artifact recipe: builder script must be regular";
    let descriptor = Unix.openfile destination
      [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600 in
    let output = Unix.out_channel_of_descr descriptor in
    Fun.protect ~finally:(fun () -> close_out output) (fun () ->
      let buffer = Bytes.create 65536 in
      let rec copy hash =
        let count = Stdlib.input input buffer 0 (Bytes.length buffer) in
        if count = 0 then hash
        else begin
          Stdlib.output output buffer 0 count;
          copy (Digestif.SHA256.feed_string hash (Bytes.sub_string buffer 0 count))
        end in
      let hash = copy Digestif.SHA256.empty in
      flush output;
      Digestif.SHA256.(to_hex (get hash))))

let stage_executable ~lib_dir ~out ~base_sha256 ~release_name ~packages ~input =
  let origins = match input with
    | Artifact_manifest.Package_archives principal when valid_package principal && List.mem principal packages ->
        Some ["package"; principal]
    | Artifact_manifest.Upstream_binary binary
        when valid_package binary.version && valid_sha256 binary.sha256
          && String.starts_with ~prefix:"https://" binary.url
          && String.for_all (fun c -> Char.code c > 32 && Char.code c < 127) binary.url ->
        Some ["binary"; binary.version; binary.url; binary.sha256]
    | _ -> None in
  if not (valid_sha256 base_sha256) || release_name = "" || String.length release_name > 128
     || not (String.for_all (function 'a'..'z'|'0'..'9'|'_'|'-' -> true | _ -> false) release_name)
     || packages = [] || not (List.for_all valid_package packages) || origins = None
  then Error "artifact recipe: invalid executable inputs"
  else
    let created = ref false in
    try
      Unix.mkdir out 0o700; created := true;
      let names = ["artifact_build_jail.sh"; "artifact_resolve_packages.sh"; "artifact_build_executable.sh"] in
      let scripts = List.map (fun name -> name,
        copy_and_hash (Filename.concat lib_dir name) (Filename.concat out name)) names in
      let buffer = Buffer.create 512 in
      Buffer.add_string buffer "infra-executable-recipe-v1\n";
      let field value = Buffer.add_string buffer
        (Printf.sprintf "%d:%s\n" (String.length value) value) in
      List.iter field [base_sha256; release_name; string_of_int (List.length packages)];
      List.iter field packages;
      List.iter field (Option.get origins);
      List.iter (fun (name, sha) -> field name; field sha) scripts;
      Ok {sha256=Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer))); scripts}
    with Unix.Unix_error _ | Sys_error _ | Failure _ ->
      if !created then begin
        Array.iter (fun name -> Unix.unlink (Filename.concat out name)) (Sys.readdir out);
        Unix.rmdir out
      end;
      Error "artifact recipe: cannot stage executable scripts"

let stage_ocaml ~lib_dir ~out ~base_sha256 ~release_name ~packages ~compiler
    ~repository_commit ~repository_sha256 ~web_bundle =
  let valid_commit value = (String.length value = 40 || String.length value = 64)
    && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) value in
  if not (valid_sha256 base_sha256 && valid_sha256 repository_sha256
          && valid_commit repository_commit && valid_release release_name
          && valid_package compiler && String.starts_with ~prefix:"ocaml-base-compiler." compiler)
     || packages = [] || not (List.for_all valid_package packages)
  then Error "artifact recipe: invalid OCaml inputs"
  else
    let created = ref false in
    try
      Unix.mkdir out 0o700; created := true;
      let names = ["artifact_build_jail.sh"; "artifact_build_ocaml.sh";
                   "artifact_verify_source.sh"; "artifact_resolve_packages.sh"] in
      let scripts = List.map (fun name -> name,
        copy_and_hash (Filename.concat lib_dir name)
          (Filename.concat out name)) names in
      let buffer = Buffer.create 512 in
      Buffer.add_string buffer "infra-ocaml-recipe-v1\n";
      let field value = Buffer.add_string buffer (Printf.sprintf "%d:%s\n" (String.length value) value) in
      List.iter field [base_sha256; release_name; compiler; repository_commit; repository_sha256;
                       string_of_int (List.length packages)];
      List.iter field packages;
      List.iter (fun (name, digest) -> field name; field digest) scripts;
      Option.iter (fun script -> field "web_bundle"; field script) web_bundle;
      Ok {sha256=Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer))); scripts}
    with Unix.Unix_error _ | Sys_error _ | Failure _ ->
      if !created then begin
        Array.iter (fun name -> Unix.unlink (Filename.concat out name)) (Sys.readdir out);
        Unix.rmdir out
      end;
      Error "artifact recipe: cannot stage OCaml scripts"

let stage_guest ~lib_dir ~out ~project ~target ~release_name ~compiler ~repository_commit
    ~repository_sha256 =
  if not (valid_release release_name && project <> "" && target <> "" && valid_package compiler && String.starts_with ~prefix:"ocaml-variants." compiler
          && valid_sha256 repository_sha256)
     || not ((String.length repository_commit = 40 || String.length repository_commit = 64)
       && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) repository_commit)
  then Error "artifact recipe: invalid guest inputs"
  else
    let created = ref false in
    try
      Unix.mkdir out 0o700; created := true;
      let names = ["artifact_build_guest.sh"; "artifact_build_ocaml.sh"; "artifact_verify_source.sh"] in
      let scripts = List.map (fun name -> name,
        copy_and_hash (Filename.concat lib_dir name) (Filename.concat out name)) names in
      let buffer = Buffer.create 512 in
      Buffer.add_string buffer "infra-linux-guest-recipe-v1\n";
      let field value = Buffer.add_string buffer (Printf.sprintf "%d:%s\n" (String.length value) value) in
      List.iter field [project; target; release_name; compiler; repository_commit; repository_sha256];
      List.iter (fun (name, digest) -> field name; field digest) scripts;
      Ok {sha256=Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer))); scripts}
    with Unix.Unix_error _ | Sys_error _ | Failure _ ->
      if !created then begin
        Array.iter (fun name -> Unix.unlink (Filename.concat out name)) (Sys.readdir out);
        Unix.rmdir out
      end;
      Error "artifact recipe: cannot stage guest scripts"

let stage ~lib_dir ~out ~base_sha256 ~release_name ~packages =
  if not (valid_sha256 base_sha256) then Error "artifact recipe: invalid base SHA-256"
  else if not (valid_release release_name) then Error "artifact recipe: invalid release name"
  else if packages = [] || not (List.for_all valid_package packages) then
    Error "artifact recipe: invalid package declaration"
  else
    let staged = ref false in
    let remove_partial () =
      if !staged then begin
        Array.iter (fun name -> Unix.unlink (Filename.concat out name)) (Sys.readdir out);
        Unix.rmdir out
      end in
    try
      Unix.mkdir out 0o700;
      staged := true;
      let script_hashes = List.map (fun name ->
        let source = Filename.concat lib_dir name in
        name, copy_and_hash source (Filename.concat out name)) scripts in
      let buffer = Buffer.create 384 in
      Buffer.add_string buffer "infra-phoenix-recipe-v1\n";
      let field value =
        Buffer.add_string buffer (string_of_int (String.length value));
        Buffer.add_char buffer ':';
        Buffer.add_string buffer value;
        Buffer.add_char buffer '\n' in
      field base_sha256;
      field release_name;
      field (string_of_int (List.length packages));
      List.iter field packages;
      field (string_of_int (List.length script_hashes));
      List.iter (fun (name, digest) -> field name; field digest) script_hashes;
      Ok { sha256 = Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer)));
           scripts = script_hashes }
    with
    | Unix.Unix_error _ | Sys_error _ | Failure _ ->
        remove_partial ();
        Error "artifact recipe: cannot stage builder scripts"
