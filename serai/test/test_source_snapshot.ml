open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name
  else (Printf.eprintf "FAIL - %s\n%!" name; exit 1)

let write path value =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel value)

let read path =
  let channel = open_in_bin path in
  Fun.protect ~finally:(fun () -> close_in channel) (fun () -> really_input_string channel (in_channel_length channel))

let jj arguments = Proc.live (fun () -> Proc.run_checked "jj" arguments)
let jj_output arguments =
  let code, output = Proc.live (fun () -> Proc.capture "jj" arguments) in
  if code <> 0 then failwith "jj fixture failed" else String.trim output

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let () =
  let fixture = Filename.temp_dir "source-snapshot" "fixture" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
  let checkout = Filename.concat fixture "checkout" in
  let out = Filename.concat fixture "snapshot" in
  jj ["git"; "init"; checkout];
  let tracked = Filename.concat checkout "release.txt" in
  write tracked "committed\n";
  let executable = Filename.concat checkout "run.sh" in
  write executable "#!/bin/sh\nexit 0\n";
  Unix.chmod executable 0o700;
  let subdir = Filename.concat checkout "nested" in
  Unix.mkdir subdir 0o700;
  write (Filename.concat subdir "config.txt") "tracked configuration\n";
  let prerelease = "ocaml-compiler.5.6.0~alpha1.opam" in
  write (Filename.concat subdir prerelease) "committed opam definition\n";
  jj ["-R"; checkout; "describe"; "-m"; "fixture source"];
  jj ["-R"; checkout; "new"];
  let commit = jj_output ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-";
    "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
  write tracked "dirty\n";
  write (Filename.concat checkout "private.txt") "not committed\n";
  let staged = Source_snapshot.stage ~jj_bin:"jj" ~checkout ~revision:commit ~out in
  check "stage reports the selected full commit for opam prerelease paths" (staged = Ok commit);
  check "opam prerelease paths export literal committed bytes"
    (read (Filename.concat (Filename.concat out "nested") prerelease) = "committed opam definition\n");
  check "staged bytes came from the commit, not the working tree"
    (read (Filename.concat out "release.txt") = "committed\n");
  check "untracked files are not staged"
    (not (Sys.file_exists (Filename.concat out "private.txt")));
  check "stage directories are private"
    ((Unix.stat out).Unix.st_perm = 0o700);
  check "stage files are private"
    ((Unix.stat (Filename.concat out "release.txt")).Unix.st_perm = 0o600);
  check "committed executable bit is retained"
    ((Unix.stat (Filename.concat out "run.sh")).Unix.st_perm = 0o700);
  let strict = Filename.concat fixture "strict-output" in
  let previous_umask = Unix.umask 0o777 in
  let strict_result = Fun.protect ~finally:(fun () -> ignore (Unix.umask previous_umask))
    (fun () -> Source_snapshot.stage ~jj_bin:"jj" ~checkout ~revision:commit ~out:strict) in
  check "strict umask still produces a usable private snapshot"
    (strict_result = Ok commit
     && (Unix.stat (Filename.concat strict "nested")).Unix.st_perm = 0o700
     && (Unix.stat (Filename.concat strict "nested/config.txt")).Unix.st_perm = 0o600);
  let refused revision out =
    match Source_snapshot.stage ~jj_bin:"jj" ~checkout ~revision ~out with
    | Error _ -> true | Ok _ -> false in
  check "existing destination is refused" (refused commit out);
  let destination_link = Filename.concat fixture "destination-link" in
  Unix.symlink out destination_link;
  check "destination symlink is refused without modifying its target"
    (refused commit destination_link && read (Filename.concat out "release.txt") = "committed\n");
  check "invalid revision is refused" (refused "--bad" (Filename.concat fixture "invalid"));
  check "missing revision is refused" (refused (String.make 40 'f') (Filename.concat fixture "missing"));
  check "failure leaves destination absent" (not (Sys.file_exists (Filename.concat fixture "missing")));
  let link = Filename.concat checkout "linked" in
  Unix.symlink "release.txt" link;
  jj ["-R"; checkout; "describe"; "-m"; "symlink fixture"];
  jj ["-R"; checkout; "new"];
  let link_commit = jj_output ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-";
    "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
  let link_out = Filename.concat fixture "link-output" in
  check "tracked symlink is refused" (refused link_commit link_out);
  check "failed export leaves no destination" (not (Sys.file_exists link_out));
  Unix.unlink link;
  let dotenv = Filename.concat checkout ".env" in
  write dotenv "synthetic fixture\n";
  write (Filename.concat checkout ".env~") "synthetic environment backup\n";
  jj ["-R"; checkout; "describe"; "-m"; "env fixture"];
  jj ["-R"; checkout; "new"];
  let example = Filename.concat subdir ".env.example" in
  write example "synthetic example fixture\n";
  jj ["-R"; checkout; "describe"; "-m"; "nested env example"];
  jj ["-R"; checkout; "new"];
  let env_commit = jj_output ["--ignore-working-copy"; "-R"; checkout; "log"; "-r"; "@-";
    "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
  let cache = Filename.concat fixture "snapshots" in
  let cached = Source_snapshot.stage_cached ~jj_bin:"jj" ~checkout ~revision:commit ~cache in
  check "a cached snapshot is staged under the commit in a private cache"
    (cached = Ok (commit, Filename.concat cache commit)
     && read (Filename.concat cache (commit ^ "/release.txt")) = "committed\n"
     && (Unix.stat cache).Unix.st_perm land 0o077 = 0);
  let no_export = Filename.concat fixture "jj-no-file-show" in
  write no_export "#!/bin/sh\nfor arg do\n [ \"$arg\" = show ] && exit 88\ndone\nexec jj \"$@\"\n";
  Unix.chmod no_export 0o700;
  check "a commit already in the cache is returned without exporting a file"
    (Source_snapshot.stage_cached ~jj_bin:no_export ~checkout ~revision:commit ~cache = cached);
  jj ["-R"; checkout; "bookmark"; "create"; "cached"; "-r"; commit];
  check "a revision is resolved to its commit before the cache is read"
    (Source_snapshot.stage_cached ~jj_bin:no_export ~checkout ~revision:"cached" ~cache = cached);
  Unix.chmod cache 0o755;
  check "a shared snapshot cache is refused"
    (Result.is_error (Source_snapshot.stage_cached ~jj_bin:"jj" ~checkout ~revision:commit ~cache));
  Unix.chmod cache 0o700;
  let wrapper = Filename.concat fixture "jj-no-env-read" in
  write wrapper "#!/bin/sh\nfor arg do\n case \"$arg\" in root:*'.env'*) exit 88 ;; esac\ndone\nexec jj \"$@\"\n";
  Unix.chmod wrapper 0o700;
  let env_out = Filename.concat fixture "env-output" in
  check "environment paths are omitted without requesting their bodies"
    (Source_snapshot.stage ~jj_bin:wrapper ~checkout ~revision:env_commit ~out:env_out = Ok env_commit);
  check "dotenv, editor backups and nested examples never enter the source tree"
    (not (Sys.file_exists (Filename.concat env_out ".env"))
     && not (Sys.file_exists (Filename.concat env_out ".env~"))
     && not (Sys.file_exists (Filename.concat env_out "nested/.env.example")));
  check "public tracked source is still exported"
    (read (Filename.concat env_out "release.txt") = "dirty\n");
  let unsafe = Filename.concat checkout "unsafe name.txt" in
  write unsafe "synthetic unsupported filename\n";
  jj ["-R"; checkout; "describe"; "-m"; "unsupported filename"];
  jj ["-R"; checkout; "new"];
  let unsafe_commit = jj_output ["--ignore-working-copy"; "-R"; checkout;
    "log"; "-r"; "@-"; "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
  check "space-bearing paths remain refused"
    (refused unsafe_commit (Filename.concat fixture "unsafe-output"));
  Unix.unlink unsafe;
  Unix.unlink dotenv;
  Unix.symlink "release.txt" dotenv;
  jj ["-R"; checkout; "describe"; "-m"; "excluded path symlink"];
  jj ["-R"; checkout; "new"];
  let excluded_link_commit = jj_output ["--ignore-working-copy"; "-R"; checkout;
    "log"; "-r"; "@-"; "--no-graph"; "-T"; "commit_id ++ \"\\n\""] in
  check "omission does not hide an unsupported environment entry"
    (refused excluded_link_commit (Filename.concat fixture "excluded-link-output")))
