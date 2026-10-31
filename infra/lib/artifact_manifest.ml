type dependency = { name : string; version : string; sha256 : string }

type input =
  | Source_commit of string
  | Package_archives of string
  | Upstream_binary of { version : string; url : string; sha256 : string }

type t = {
  name : string;
  input : input;
  target_abi : string;
  dependencies : dependency list;
  recipe_sha256 : string;
  release_name : string;
  archive_sha256 : string;
}

let is_lower_hex value =
  String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let is_sha256 value = String.length value = 64 && is_lower_hex value

let is_component ?(extra = "") value =
  value <> "" && value <> "." && value <> ".." && String.length value <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | character -> String.contains extra character)
       value

let ( let* ) result f = Result.bind result f
let require label condition = if condition then Ok () else Error ("invalid " ^ label)

let validate_dependencies (dependencies : dependency list) =
  let dependencies = List.sort (fun (left : dependency) right -> String.compare left.name right.name) dependencies in
  let* () = require "resolved dependencies" (dependencies <> []) in
  let rec check_dependencies (items : dependency list) = match items with
    | [] -> Ok dependencies
    | dependency :: rest ->
        let* () = require "dependency name" (is_component ~extra:"+" dependency.name) in
        let* () = require "dependency version" (is_component ~extra:"+:," dependency.version) in
        let* () = require "dependency SHA-256" (is_sha256 dependency.sha256) in
        let* () = require "duplicate dependency"
            (match rest with next :: _ -> next.name <> dependency.name | [] -> true) in
        check_dependencies rest
  in
  check_dependencies dependencies

let dependencies_of_inventory text =
  match List.rev (String.split_on_char '\n' text) with
  | "" :: reversed ->
      let rec parse acc = function
        | [] -> validate_dependencies (List.rev acc)
        | line :: rest ->
            (match String.split_on_char '\t' line with
             | [ name; version; sha256 ] -> parse ({ name; version; sha256 } :: acc) rest
             | _ -> Error "invalid dependency inventory record") in
      parse [] (List.rev reversed)
  | _ -> Error "incomplete dependency inventory"

let valid_url url =
  let prefix = "https://" in
  String.starts_with ~prefix url && String.length url <= 2048
  && String.length url > String.length prefix
  && String.for_all (function
       | 'a'..'z' | 'A'..'Z' | '0'..'9' | '/' | '.' | '-' | '_' | ':' | '+' -> true
       | _ -> false) url
  && (match String.split_on_char '/' (String.sub url 8 (String.length url - 8)) with
      | host :: _ -> host <> "" && not (String.starts_with ~prefix:"." host)
      | [] -> false)

let create_input ~name ~input ~target_abi ~(dependencies : dependency list) ~recipe_sha256
    ~release_name ~archive_sha256 =
  let* () = require "workload name" (is_component name) in
  let* () = match input with
    | Source_commit commit -> require "source commit"
        ((String.length commit = 40 || String.length commit = 64) && is_lower_hex commit)
    | Package_archives package -> require "resolved package origin"
        (is_component ~extra:"+" package && List.exists (fun (d : dependency) -> d.name = package) dependencies)
    | Upstream_binary {version; url; sha256} ->
        let* () = require "upstream version" (is_component ~extra:"+" version) in
        let* () = require "upstream URL" (valid_url url) in
        require "upstream SHA-256" (is_sha256 sha256) in
  let* () = require "target ABI" (is_component ~extra:":" target_abi) in
  let* () = require "build recipe SHA-256" (is_sha256 recipe_sha256) in
  let* () = require "release name"
      (release_name <> "" && String.length release_name <= 128
       && String.for_all (function
            | 'a' .. 'z' | '0' .. '9' | '_' -> true
            | '-' -> (match input with Source_commit _ -> false | _ -> true)
            | _ -> false) release_name) in
  let* () = require "archive SHA-256" (is_sha256 archive_sha256) in
  let* dependencies = validate_dependencies dependencies in
  Ok { name; input; target_abi; dependencies; recipe_sha256;
       release_name; archive_sha256 }

let create ~name ~source_commit ~target_abi ~dependencies ~recipe_sha256
    ~release_name ~archive_sha256 =
  create_input ~name ~input:(Source_commit source_commit) ~target_abi ~dependencies
    ~recipe_sha256 ~release_name ~archive_sha256

let canonical manifest =
  let buffer = Buffer.create 256 in
  Buffer.add_string buffer (match manifest.input with
    | Source_commit _ -> "infra-artifact-manifest-v1\n"
    | Package_archives _ | Upstream_binary _ -> "infra-artifact-manifest-v2\n");
  let field value =
    Buffer.add_string buffer (string_of_int (String.length value));
    Buffer.add_char buffer ':';
    Buffer.add_string buffer value;
    Buffer.add_char buffer '\n'
  in
  field manifest.name;
  (match manifest.input with
   | Source_commit commit -> field commit
   | Package_archives package -> field "package-archives"; field package
   | Upstream_binary {version; url; sha256} ->
       field "upstream-binary"; field version; field url; field sha256);
  field manifest.target_abi;
  field (string_of_int (List.length manifest.dependencies));
  List.iter (fun (dependency : dependency) ->
    field dependency.name;
    field dependency.version;
    field dependency.sha256) manifest.dependencies;
  field manifest.recipe_sha256;
  field manifest.release_name;
  field manifest.archive_sha256;
  Buffer.contents buffer

let of_canonical text =
  let exception Invalid_manifest in
  try
    let header =
      if String.starts_with ~prefix:"infra-artifact-manifest-v1\n" text then "infra-artifact-manifest-v1\n"
      else if String.starts_with ~prefix:"infra-artifact-manifest-v2\n" text then "infra-artifact-manifest-v2\n"
      else raise Invalid_manifest in
    let offset = ref (String.length header) in
    let decimal value =
      let number = int_of_string value in
      if number < 0 || string_of_int number <> value then raise Invalid_manifest;
      number in
    let field ?(max_size=128) () =
      let colon = String.index_from text !offset ':' in
      let size = decimal (String.sub text !offset (colon - !offset)) in
      let start = colon + 1 in
      if size > max_size || size >= String.length text - start then raise Invalid_manifest;
      if text.[start + size] <> '\n' then raise Invalid_manifest;
      offset := start + size + 1;
      String.sub text start size in
    let name = field () in
    let input =
      if header = "infra-artifact-manifest-v1\n" then Source_commit (field ())
      else match field () with
        | "package-archives" -> Package_archives (field ())
        | "upstream-binary" ->
            let version = field () in
            let url = field ~max_size:2048 () in
            let sha256 = field () in
            Upstream_binary {version; url; sha256}
        | _ -> raise Invalid_manifest in
    let target_abi = field () in
    let count = decimal (field ()) in
    (* Every valid dependency needs at least 76 encoded bytes. Bound allocation
       by actual input size before creating its list. *)
    if count < 1 || count > (String.length text - !offset) / 76 then raise Invalid_manifest;
    let dependencies = List.init count (fun _ ->
      let name = field () in
      let version = field () in
      let sha256 = field () in
      { name; version; sha256 }) in
    let recipe_sha256 = field () in
    let release_name = field () in
    let archive_sha256 = field () in
    if !offset <> String.length text then raise Invalid_manifest;
    let* manifest = create_input ~name ~input ~target_abi ~dependencies
      ~recipe_sha256 ~release_name ~archive_sha256 in
    if canonical manifest <> text then Error "noncanonical artifact manifest"
    else Ok manifest
  with
  | Invalid_manifest | Not_found | Invalid_argument _ | Failure _ ->
      Error "invalid artifact manifest encoding"

let identity manifest =
  Digestif.SHA256.(to_hex (digest_string (canonical manifest)))

let verify_archive manifest ~archive =
  try
    let metadata = Unix.lstat archive in
    if metadata.Unix.st_kind <> Unix.S_REG then Error ("not a regular archive: " ^ archive)
    else
      let channel = open_in_bin archive in
      Fun.protect ~finally:(fun () -> close_in channel) (fun () ->
        if (Unix.fstat (Unix.descr_of_in_channel channel)).Unix.st_kind <> Unix.S_REG then
          Error ("not a regular archive: " ^ archive)
        else
          let bytes = Bytes.create 65536 in
          let rec hash context =
            let count = input channel bytes 0 (Bytes.length bytes) in
            if count = 0 then context
            else hash (Digestif.SHA256.feed_string context (Bytes.sub_string bytes 0 count))
          in
          let observed = Digestif.SHA256.(to_hex (get (hash empty))) in
          if String.equal observed manifest.archive_sha256 then Ok ()
          else Error ("archive SHA-256 mismatch: " ^ archive))
  with
  | Unix.Unix_error _ | Sys_error _ -> Error ("cannot read archive: " ^ archive)
