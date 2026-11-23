type staged = { sha256 : string; scripts : (string * string) list }

let scripts =
  [ "artifact_build_jail.sh"; "artifact_build_phoenix.sh"; "artifact_verify_source.sh";
    "artifact_resolve_packages.sh"; "artifact_build_assets.exs" ]

let valid_sha256 = Hex.is_sha256

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

let valid_commit = Hex.is_object_id

(* Copies the builder scripts [names] into a new private [out] and hashes
   the recipe: [header], then each of [fields scripts] length-prefixed, in
   order. The encoding is part of every stored artifact's identity: a
   change to it orphans the store. A failure removes what was staged. *)
let stage_scripts ~lib_dir ~out ~names ~header ~failure fields =
  let created = ref false in
  let remove_partial () =
    if !created then
      try
        Array.iter (fun name -> Unix.unlink (Filename.concat out name)) (Sys.readdir out);
        Unix.rmdir out
      with Unix.Unix_error _ | Sys_error _ -> () in
  try
    Unix.mkdir out 0o700;
    created := true;
    let scripts = List.map (fun name ->
      name, copy_and_hash (Filename.concat lib_dir name) (Filename.concat out name)) names in
    let buffer = Buffer.create 512 in
    Buffer.add_string buffer (header ^ "\n");
    List.iter (fun value ->
      Buffer.add_string buffer (Printf.sprintf "%d:%s\n" (String.length value) value)) (fields scripts);
    Ok { sha256 = Digestif.SHA256.(to_hex (digest_string (Buffer.contents buffer))); scripts }
  with Unix.Unix_error _ | Sys_error _ | Failure _ ->
    remove_partial ();
    Error failure

let script_fields scripts = List.concat_map (fun (name, digest) -> [ name; digest ]) scripts
let counted values = string_of_int (List.length values) :: values

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
  let valid_name = release_name <> "" && String.length release_name <= 128
    && String.for_all (function 'a'..'z'|'0'..'9'|'_'|'-' -> true | _ -> false) release_name in
  match origins with
  | Some origins when valid_sha256 base_sha256 && valid_name && packages <> []
                      && List.for_all valid_package packages ->
      stage_scripts ~lib_dir ~out ~header:"infra-executable-recipe-v1"
        ~names:["artifact_build_jail.sh"; "artifact_resolve_packages.sh"; "artifact_build_executable.sh"]
        ~failure:"artifact recipe: cannot stage executable scripts"
        (fun scripts -> [ base_sha256; release_name ] @ counted packages @ origins @ script_fields scripts)
  | _ -> Error "artifact recipe: invalid executable inputs"

let stage_ocaml ~lib_dir ~out ~base_sha256 ~lib32_sha256 ~release_name ~packages ~compiler
    ~repository_commit ~repository_sha256 ~web_bundle =
  if not (valid_sha256 base_sha256 && Option.for_all valid_sha256 lib32_sha256
          && valid_sha256 repository_sha256
          && valid_commit repository_commit && valid_release release_name
          && valid_package compiler && String.starts_with ~prefix:"ocaml-base-compiler." compiler)
     || packages = [] || not (List.for_all valid_package packages)
  then Error "artifact recipe: invalid OCaml inputs"
  else
    stage_scripts ~lib_dir ~out ~header:"infra-ocaml-recipe-v1"
      ~names:["artifact_build_jail.sh"; "artifact_build_ocaml.sh";
              "artifact_verify_source.sh"; "artifact_resolve_packages.sh"]
      ~failure:"artifact recipe: cannot stage OCaml scripts"
      (fun scripts ->
        [ base_sha256; release_name; compiler; repository_commit; repository_sha256 ] @ counted packages
        @ script_fields scripts
        @ (match web_bundle with Some script -> [ "web_bundle"; script ] | None -> [])
        @ (match lib32_sha256 with Some digest -> [ "lib32"; digest ] | None -> []))

let stage_guest ~lib_dir ~out ~project ~target ~release_name ~compiler ~repository_commit
    ~repository_sha256 =
  if not (valid_release release_name && project <> "" && target <> "" && valid_package compiler
          && String.starts_with ~prefix:"ocaml-variants." compiler
          && valid_sha256 repository_sha256 && valid_commit repository_commit)
  then Error "artifact recipe: invalid guest inputs"
  else
    stage_scripts ~lib_dir ~out ~header:"infra-linux-guest-recipe-v1"
      ~names:["artifact_build_guest.sh"; "artifact_build_ocaml.sh"; "artifact_verify_source.sh"]
      ~failure:"artifact recipe: cannot stage guest scripts"
      (fun scripts ->
        [ project; target; release_name; compiler; repository_commit; repository_sha256 ] @ script_fields scripts)

let stage ~lib_dir ~out ~base_sha256 ~lib32_sha256 ~release_name ~packages =
  if not (valid_sha256 base_sha256) then Error "artifact recipe: invalid base SHA-256"
  else if not (Option.for_all valid_sha256 lib32_sha256) then Error "artifact recipe: invalid lib32 SHA-256"
  else if not (valid_release release_name) then Error "artifact recipe: invalid release name"
  else if packages = [] || not (List.for_all valid_package packages) then
    Error "artifact recipe: invalid package declaration"
  else
    stage_scripts ~lib_dir ~out ~header:"infra-phoenix-recipe-v1" ~names:scripts
      ~failure:"artifact recipe: cannot stage builder scripts"
      (fun staged ->
        [ base_sha256; release_name ] @ counted packages
        @ [ string_of_int (List.length staged) ] @ script_fields staged
        @ (match lib32_sha256 with Some digest -> [ "lib32"; digest ] | None -> []))
