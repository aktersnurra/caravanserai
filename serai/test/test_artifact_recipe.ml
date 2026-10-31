open Serai

let check label condition =
  if condition then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)

let sha256 value = Digestif.SHA256.(to_hex (digest_string value))
let write path value =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel value)
let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path
let valid = function Ok value -> value | Error message -> failwith message
let rejected = function Ok _ -> false | Error _ -> true

let () =
  let rec source_serai directory =
    if Filename.basename directory = "serai" && Sys.file_exists (Filename.concat directory "dune-project")
    then directory else let parent = Filename.dirname directory in
      if parent = directory then failwith "cannot locate serai" else source_serai parent in
  let temp_dir = Filename.concat (source_serai (Sys.getcwd ())) "_build" in
  check ("self-contained repository scratch parent: " ^ temp_dir)
    (String.equal temp_dir (Filename.concat (source_serai (Sys.getcwd ())) "_build")
     && not (Filename.is_relative temp_dir) && Sys.is_directory temp_dir);
  let fixture = Filename.temp_dir ~temp_dir "artifact-recipe" "" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let apps_dir = Filename.concat fixture "apps" in
    let scripts = Filename.concat apps_dir "_lib" in
    Unix.mkdir apps_dir 0o700;
    Unix.mkdir scripts 0o700;
    let names = ["artifact_build_jail.sh"; "artifact_build_phoenix.sh"; "artifact_verify_source.sh";
      "artifact_resolve_packages.sh"; "artifact_build_assets.exs"] in
    List.iter (fun name -> write (Filename.concat scripts name) ("script:" ^ name)) names;
    let base_sha256 = sha256 "trusted base bytes" in
    let packages = ["erlang-runtime29"; "elixir-devel"; "sqlite3"] in
    let stage label ?(base_sha256=base_sha256) ?(packages=packages)
        ?(release_name="sprint_trainer") () =
      Artifact_recipe.stage ~lib_dir:scripts ~out:(Filename.concat fixture label)
        ~base_sha256 ~packages ~release_name in
    let first = valid (stage "first" ()) in
    let cold_bytes = {|infra-phoenix-recipe-v1
64:0ec9db25d2cfc75724ffeb78cea59e29c00fe7653e7c0974122d50a47e41b2b7
14:sprint_trainer
1:3
16:erlang-runtime29
12:elixir-devel
7:sqlite3
1:5
22:artifact_build_jail.sh
64:d2fdd7ce74f02c018effac360f5c0cffef2acfc53ca151c5756cd834c1971f71
25:artifact_build_phoenix.sh
64:44e5c3f70d3b6524f2faa8b21711f0ff37b81a61c372eee034367f27f755607c
25:artifact_verify_source.sh
64:9bcb025f47f698858ea90969937ccbe9f6f0eec54bc7790d2de36ba7b010d2bd
28:artifact_resolve_packages.sh
64:82f7028a88ee8f730ec145cfb621ce393afeb0a36c161652190110fc7b558c9a
25:artifact_build_assets.exs
64:f694576a3fbb403ebaba564b9691e121ab3a8759eab2674ded184cf8060740b0
|} in
    check "frozen cold synthetic recipe bytes/hash remain unchanged"
      (sha256 cold_bytes = "754b6477cf2232d14a61fb9cce88db8eb19612baadae420dea398f8a1fce610c" && first.sha256 = sha256 cold_bytes);
    let second = valid (stage "second" ()) in
    check "same exact builder bytes and declared inputs yield deterministic SHA-256"
      (first = second && String.length first.sha256 = 64
       && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) first.sha256);
    check "script hashes match the staged bytes in fixed order"
      (first.scripts = List.map (fun name -> name, sha256 ("script:" ^ name)) names);
    check "staged scripts contain the exact hashed source bytes"
      (List.for_all (fun name ->
         read (Filename.concat (Filename.concat fixture "first") name) = "script:" ^ name) names);
    check "base archive checksum changes recipe"
      (valid (stage "changed-base" ~base_sha256:(sha256 "different base") ()) <> first);
    check "package declaration changes recipe"
      (valid (stage "changed-packages" ~packages:["erlang-runtime29"; "gmake"] ()) <> first);
    check "package order changes recipe"
      (valid (stage "reordered-packages" ~packages:(List.rev packages) ()) <> first);
    check "release name changes recipe"
      (valid (stage "changed-release" ~release_name:"other_release" ()) <> first);
    List.iteri (fun index name ->
      let script = Filename.concat scripts name in
      write script ("updated:" ^ name);
      check (name ^ " bytes change recipe without mutating previous stage")
        (valid (stage ("changed-script-" ^ string_of_int index) ()) <> first
         && read (Filename.concat (Filename.concat fixture "first") name) = "script:" ^ name);
      write script ("script:" ^ name)) names;
    let source = Filename.concat scripts "artifact_verify_source.sh" in
    write source "script:artifact_verify_source.sh";
    write (Filename.concat scripts "artifact_build_ocaml.sh") "OCaml worker";
    let ocaml label ?(compiler="ocaml-base-compiler.5.5.1")
        ?(repository_commit=String.make 40 'a') ?(repository_sha256=sha256 "repository")
        ?web_bundle () =
      Artifact_recipe.stage_ocaml ~lib_dir:scripts ~out:(Filename.concat fixture label)
        ~base_sha256 ~release_name:"meals" ~packages:["ocaml-opam"; "sqlite3"]
        ~compiler ~repository_commit ~repository_sha256 ~web_bundle in
    let ocaml_first = valid (ocaml "ocaml-first" ()) in
    (* Stored artifacts are reused by this digest: a recipe without a bundle
       keeps the bytes it had before bundles existed. *)
    check "an OCaml recipe without a web bundle keeps its bytes"
      (ocaml_first.sha256 = "13ac6abc4d88ae9ebd7bcfd405961cf3f927ee5834cc6fc1f868050aa1f34213");
    let web = valid (ocaml "ocaml-web" ~web_bundle:"web/build-bundle.sh" ()) in
    check "a declared web bundle script is bound into the OCaml recipe"
      (web <> ocaml_first
       && valid (ocaml "ocaml-web-again" ~web_bundle:"web/build-bundle.sh" ()) = web
       && valid (ocaml "ocaml-web-other" ~web_bundle:"web/other.sh" ()) <> web);
    check "OCaml recipe is deterministic and separate from Phoenix"
      (valid (ocaml "ocaml-second" ()) = ocaml_first && ocaml_first.sha256 <> first.sha256);
    check "OCaml recipe binds the declared compiler version"
      (valid (ocaml "ocaml-compiler" ~compiler:"ocaml-base-compiler.5.4.1" ()) <> ocaml_first);
    check "OCaml recipe binds both repository commit and inventory"
      (valid (ocaml "ocaml-repo-commit" ~repository_commit:(String.make 40 'b') ()) <> ocaml_first
       && valid (ocaml "ocaml-repo-inventory" ~repository_sha256:(sha256 "changed repository") ()) <> ocaml_first);
    check "OCaml recipe snapshots exactly its four required helpers"
      (List.map fst ocaml_first.scripts = ["artifact_build_jail.sh"; "artifact_build_ocaml.sh";
        "artifact_verify_source.sh"; "artifact_resolve_packages.sh"]);
    write (Filename.concat scripts "artifact_build_ocaml.sh") "changed OCaml worker";
    check "OCaml worker change alters recipe and leaves original snapshot unchanged"
      (valid (ocaml "ocaml-worker" ()) <> ocaml_first
       && read (Filename.concat fixture "ocaml-first/artifact_build_ocaml.sh") = "OCaml worker");
    check "OCaml recipe refuses unpinned compiler or repository inputs"
      (rejected (ocaml "ocaml-unpinned" ~compiler:"ocaml-base-compiler" ())
       && rejected (ocaml "ocaml-bad-commit" ~repository_commit:"latest" ()));
    let script = Filename.concat scripts "artifact_build_phoenix.sh" in
    Unix.unlink script;
    Unix.symlink (Filename.concat scripts "artifact_build_jail.sh") script;
    check "symlinked builder script is refused without partial stage"
      (rejected (stage "symlink" ())
       && not (Sys.file_exists (Filename.concat fixture "symlink")));
    Unix.unlink script;
    check "missing builder script is refused without partial stage"
      (rejected (stage "missing" ())
       && not (Sys.file_exists (Filename.concat fixture "missing")));
    check "malformed base checksum is refused"
      (rejected (stage "bad-base" ~base_sha256:"unknown" ()));
    check "empty package list is refused"
      (rejected (stage "no-packages" ~packages:[] ())))
