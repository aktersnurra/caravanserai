open Infra

let () =
  if Array.length Sys.argv <> 3 then failwith "usage: host_artifact_store_candidate CANDIDATE PRIVATE_STORE";
  let candidate = Sys.argv.(1) in
  let root = Sys.argv.(2) in
  let valid = function Ok value -> value | Error message -> failwith message in
  let manifest = valid (Artifact_manifest.of_canonical
    (In_channel.with_open_bin (Filename.concat candidate "manifest") In_channel.input_all)) in
  let archive = Filename.concat candidate "release.tar" in
  let published = valid (Artifact_store.publish ~root ~manifest ~archive) in
  let reused = valid (Artifact_store.reuse ~root ~manifest) in
  if published <> reused then failwith "publication/reuse disagree";
  ignore (valid (Artifact_manifest.verify_archive manifest ~archive:reused));
  Printf.printf "verified actual candidate store roundtrip: %s\nidentity=%s\n%!"
    reused (Artifact_manifest.identity manifest)
