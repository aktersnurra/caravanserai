open Infra

let check label condition =
  if condition then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)

let rejected = function Error _ -> true | Ok _ -> false
let sha256 text = Digestif.SHA256.(to_hex (digest_string text))
let write path contents =
  let output = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out output) (fun () -> output_string output contents)
let read path =
  let input = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in input)
    (fun () -> really_input_string input (in_channel_length input))
let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR -> Array.iter (fun child -> remove_tree (Filename.concat path child)) (Sys.readdir path); Unix.rmdir path
  | _ -> Unix.unlink path

let () =
  let fixture = Filename.temp_dir "artifact-store" "" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let root = Filename.concat fixture "store" in
    Unix.mkdir root 0o700;
    let archive = Filename.concat fixture "release.tar" in
    write archive "release bytes";
    let manifest = match Artifact_manifest.create ~name:"drill"
      ~source_commit:(String.make 40 'a') ~target_abi:"FreeBSD:14:amd64"
      ~dependencies:[Artifact_manifest.{name="elixir";version="1.2.3";sha256=sha256 "pkg archive"}]
      ~recipe_sha256:(sha256 "builder script") ~release_name:"drill_trainer"
      ~archive_sha256:(sha256 "release bytes") with
      | Ok value -> value | Error message -> failwith message in
    let identity = Artifact_manifest.identity manifest in
    let entry = Filename.concat root identity in
    let stored_archive = Filename.concat entry "release.tar" in
    let stored_manifest = Filename.concat entry "manifest" in
    check "absent artifact cannot be reused"
      (rejected (Artifact_store.reuse ~root ~manifest));
    let symlink = Filename.concat fixture "archive-link" in
    Unix.symlink archive symlink;
    check "symlink input refused before publication"
      (rejected (Artifact_store.publish ~root ~manifest ~archive:symlink)
       && not (Sys.file_exists entry));
    write archive "wrong bytes";
    check "mismatched archive leaves no partial entry"
      (rejected (Artifact_store.publish ~root ~manifest ~archive)
       && Sys.readdir root = [||]);
    write archive "release bytes";
    check "publish verifies archive and writes canonical manifest"
      (Artifact_store.publish ~root ~manifest ~archive = Ok stored_archive
       && read stored_archive = "release bytes"
       && read stored_manifest = Artifact_manifest.canonical manifest);
    check "identity selection loads and verifies its canonical entry"
      (Artifact_store.load ~root ~identity = Ok (manifest, stored_archive));
    check "identity selection rejects traversal before touching files"
      (rejected (Artifact_store.load ~root ~identity:"../release.tar"));
    check "reuse rehashes the archived bytes"
      (Artifact_store.reuse ~root ~manifest = Ok stored_archive);
    check "find selects the verified entry matching a predicate"
      (Artifact_store.find ~root ~f:(fun m -> m.Artifact_manifest.name = "drill") = Ok (Some identity));
    check "find reports no match without error"
      (Artifact_store.find ~root ~f:(fun m -> m.Artifact_manifest.name = "meals") = Ok None);
    write (Filename.concat root ".infra-artifact-partial") "";
    check "find ignores names that are not identities"
      (Artifact_store.find ~root ~f:(fun _ -> true) = Ok (Some identity));
    Sys.remove (Filename.concat root ".infra-artifact-partial");
    check "publishing identical bytes reuses verified entry"
      (Artifact_store.publish ~root ~manifest ~archive = Ok stored_archive);
    write stored_archive "tampered bytes";
    check "identity selection refuses corrupt archive"
      (rejected (Artifact_store.load ~root ~identity));
    check "tampered archive refuses reuse and overwrite"
      (rejected (Artifact_store.reuse ~root ~manifest)
       && rejected (Artifact_store.publish ~root ~manifest ~archive)
       && read stored_archive = "tampered bytes");
    write stored_archive "release bytes";
    write stored_manifest "invalid manifest";
    check "identity selection refuses corrupt canonical bytes"
      (rejected (Artifact_store.load ~root ~identity));
    check "tampered manifest refuses reuse even with matching archive"
      (rejected (Artifact_store.reuse ~root ~manifest)
       && rejected (Artifact_store.publish ~root ~manifest ~archive));
    write stored_manifest (Artifact_manifest.canonical manifest);
    let manifest_link = Filename.concat fixture "manifest-link" in
    Unix.rename stored_manifest manifest_link;
    Unix.symlink manifest_link stored_manifest;
    check "identity selection refuses a manifest symlink"
      (rejected (Artifact_store.load ~root ~identity));
    check "symlinked stored manifest is refused"
      (rejected (Artifact_store.reuse ~root ~manifest));
    Unix.unlink stored_manifest;
    Unix.rename manifest_link stored_manifest;
    write archive "changed source";
    check "changed source refuses publication even with valid stored entry"
      (rejected (Artifact_store.publish ~root ~manifest ~archive));
    write archive "release bytes";
    remove_tree entry;
    Unix.symlink fixture entry;
    check "identity symlink is refused"
      (rejected (Artifact_store.reuse ~root ~manifest)
       && rejected (Artifact_store.publish ~root ~manifest ~archive));
    Unix.unlink entry;
    Unix.mkdir entry 0o700;
    check "preexisting empty identity directory is not overwritten"
      (rejected (Artifact_store.publish ~root ~manifest ~archive)
       && Sys.readdir entry = [||]);
    Unix.rmdir entry;
    let root_link = Filename.concat fixture "store-link" in
    Unix.symlink root root_link;
    check "symlinked store root is refused"
      (rejected (Artifact_store.publish ~root:root_link ~manifest ~archive));
    Unix.chmod root 0o777;
    check "group-writable store root is refused"
      (rejected (Artifact_store.publish ~root ~manifest ~archive));
    check "no partial publication is left"
      (Sys.readdir root = [||]))
