(* Source_mirror against a real local git origin: clone, fetch, and the
   rule that only commits reachable from the remote can be built. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let write path value = Out_channel.with_open_bin path (fun c -> output_string c value)
let jj arguments = Proc.live (fun () -> Proc.run_checked "jj" arguments)
let jj_output arguments =
  match Proc.live (fun () -> Proc.capture "jj" arguments) with
  | 0, output -> String.trim output
  | _ -> failwith "jj fixture error"

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let commit_on_main origin text =
  write (Filename.concat origin "file.txt") text;
  jj [ "-R"; origin; "commit"; "-m"; text ];
  jj [ "-R"; origin; "bookmark"; "set"; "main"; "-r"; "@-"; "--allow-backwards" ];
  jj_output [ "-R"; origin; "log"; "--no-graph"; "-r"; "@-"; "-T"; "commit_id" ]

let () = Proc.live @@ fun () ->
  let fixture = Filename.temp_dir "source-mirror" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let origin = Filename.concat fixture "origin" in
    jj [ "git"; "init"; "--colocate"; origin ];
    let first = commit_on_main origin "first" in
    let cache = Filename.concat fixture "cache" in
    let url = "file://" ^ origin in
    let sync () = Source_mirror.sync ~jj_bin:"jj" ~cache ~name:"app" ~url in
    let mirror = match sync () with Ok m -> m | Error e -> failwith e in
    check "mirror lives under the cache, named after the workload"
      (Source_mirror.path mirror = Filename.concat (Filename.concat cache "sources") "app");
    check "cache directories are private"
      ((Unix.stat cache).Unix.st_perm land 0o077 = 0);
    check "bookmark resolves to the remote commit"
      (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:"main" = Ok first);
    check "full commit id resolves to itself"
      (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:first = Ok first);
    let local_only = jj_output [ "-R"; Source_mirror.path mirror; "log"; "--no-graph"; "-r"; "@"; "-T"; "commit_id" ] in
    check "a commit that is not on the remote is refused"
      (Result.is_error (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:local_only));
    check "an unknown revision is refused"
      (Result.is_error (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:"nope"));
    check "a revset expression is refused"
      (Result.is_error (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:"main | root()"));
    let second = commit_on_main origin "second" in
    check "before sync the mirror still sees the old commit"
      (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:"main" = Ok first);
    let mirror = match sync () with Ok m -> m | Error e -> failwith e in
    check "sync fetches new remote commits"
      (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:"main" = Ok second);
    check "older pushed commits stay buildable"
      (Source_mirror.resolve ~jj_bin:"jj" mirror ~revision:first = Ok first);
    check "a mirror of a different URL is refused"
      (Result.is_error (Source_mirror.sync ~jj_bin:"jj" ~cache ~name:"app"
         ~url:("file://" ^ Filename.concat fixture "elsewhere")));
    check "an unreachable remote fails"
      (Result.is_error (Source_mirror.sync ~jj_bin:"jj" ~cache ~name:"other"
         ~url:("file://" ^ Filename.concat fixture "missing")));
    (* A git insteadOf rule (the operator's rewrites https://github.com/ to
       ssh) changes the URL jj reports, not the one the mirror recorded. The
       rule maps the declared URL to the same origin by plain path. Last,
       since it changes this process's git config. *)
    let rules = Filename.concat fixture "gitconfig" in
    write rules (Printf.sprintf "[url \"%s\"]\n\tinsteadOf = %s\n" origin url);
    Unix.putenv "GIT_CONFIG_GLOBAL" rules;
    check "an insteadOf rewrite of the declared URL is the same mirror"
      (match sync () with Ok _ -> true | Error e -> prerr_endline e; false))
