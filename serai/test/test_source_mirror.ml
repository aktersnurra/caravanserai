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
    check "has_commit: a fetched commit is there"
      (Source_mirror.has_commit ~jj_bin:"jj" mirror first = Ok true);
    check "has_commit: an unknown commit is not, and that's no error"
      (Source_mirror.has_commit ~jj_bin:"jj" mirror (String.make 40 'f') = Ok false);
    check "has_commit: only a full commit id"
      (Result.is_error (Source_mirror.has_commit ~jj_bin:"jj" mirror "main"));
    (* The remote's default branch, as jj git clone recorded it. *)
    check "default branch: the origin's main"
      (Source_mirror.default_branch ~jj_bin:"jj" mirror = Ok "main");
    check "default branch: resolves to the origin's commit"
      (Result.bind (Source_mirror.default_branch ~jj_bin:"jj" mirror)
         (fun revision -> Source_mirror.resolve ~jj_bin:"jj" mirror ~revision) = Ok first);
    let other_origin = Filename.concat fixture "origin-master" in
    jj [ "git"; "init"; "--colocate"; other_origin ];
    write (Filename.concat other_origin "file.txt") "other";
    jj [ "-R"; other_origin; "commit"; "-m"; "other" ];
    jj [ "-R"; other_origin; "bookmark"; "set"; "master"; "-r"; "@-" ];
    let other = match Source_mirror.sync ~jj_bin:"jj" ~cache ~name:"other-app" ~url:("file://" ^ other_origin) with
      | Ok m -> m | Error e -> failwith e in
    check "default branch: the origin's master"
      (Source_mirror.default_branch ~jj_bin:"jj" other = Ok "master");
    jj [ "--ignore-working-copy"; "-R"; Source_mirror.path other; "config"; "unset"; "--repo"; {|revset-aliases."trunk()"|} ];
    check "default branch: none recorded is an error, not a guess"
      (match Source_mirror.default_branch ~jj_bin:"jj" other with
       | Error message -> String.length message > 0 | Ok _ -> false);
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
    (* Signatures: jj's verdict, with the verification setup the caller
       passes in its environment. The fixture signs with a throwaway ssh
       key; production verifies gpg the same way, through jj. *)
    let key = Filename.concat fixture "signing-key" in
    Proc.run_checked "ssh-keygen" [ "-q"; "-t"; "ed25519"; "-N"; ""; "-f"; key; "-C"; "fixture" ];
    let public_key = String.trim (In_channel.with_open_bin (key ^ ".pub") In_channel.input_all) in
    let fingerprint =
      match Proc.capture "ssh-keygen" [ "-lf"; key ^ ".pub" ] with
      | 0, output -> List.nth (String.split_on_char ' ' (String.trim output)) 1
      | _ -> failwith "ssh-keygen -l failed" in
    let allowed = Filename.concat fixture "allowed-signers" in
    write allowed (Printf.sprintf "fixture@example.org namespaces=\"git\" %s\n"
      (String.concat " " (List.filteri (fun i _ -> i < 2) (String.split_on_char ' ' public_key))));
    let trusting = Filename.concat fixture "trusting.toml" in
    write trusting (Printf.sprintf "[signing.backends.ssh]\nallowed-signers = %S\n" allowed);
    let trusting_nothing = Filename.concat fixture "trusting-nothing.toml" in
    write trusting_nothing "";
    let commit_signed ~signing text =
      write (Filename.concat origin "file.txt") text;
      jj ([ "-R"; origin ] @ signing @ [ "commit"; "-m"; text ]);
      jj [ "-R"; origin; "bookmark"; "set"; "main"; "-r"; "@-"; "--allow-backwards" ];
      jj_output [ "-R"; origin; "log"; "--no-graph"; "-r"; "@-"; "-T"; "commit_id" ] in
    let unsigned = commit_signed ~signing:[ "--config"; "signing.behavior=drop" ] "unsigned" in
    let signed = commit_signed "signed" ~signing:
      [ "--config"; "signing.behavior=force"; "--config"; "signing.backend=ssh";
        "--config"; "signing.key=" ^ key ] in
    let mirror = match sync () with Ok m -> m | Error e -> failwith e in
    let signature ~trust commit =
      Source_mirror.signature ~jj_bin:"jj" ~extra_env:[ ("JJ_CONFIG", trust) ] mirror ~commit in
    check "an unsigned commit is reported unsigned"
      (signature ~trust:trusting unsigned = Ok Source_mirror.Unsigned);
    check "a commit signed by a trusted key is good, by that key"
      (signature ~trust:trusting signed
       = Ok (Source_mirror.Signed { status = Good; key = fingerprint }));
    check "the same commit without its key trusted is not good"
      (match signature ~trust:trusting_nothing signed with
       | Ok (Source_mirror.Signed { status = Good; _ }) -> false
       | Ok (Source_mirror.Signed _) -> true
       | Ok Source_mirror.Unsigned | Error _ -> false);
    check "a signature is only looked up by full commit id"
      (Result.is_error (signature ~trust:trusting "main"));

    (* Ancestry, by full commit ids only. *)
    let ancestor a d = Source_mirror.is_ancestor ~jj_bin:"jj" mirror ~ancestor:a ~descendant:d in
    check "an older commit is an ancestor of a newer one" (ancestor first signed = Ok true);
    check "a newer commit is not an ancestor of an older one" (ancestor signed first = Ok false);
    check "a commit is its own ancestor" (ancestor signed signed = Ok true);
    check "ancestry refuses anything but full commit ids" (Result.is_error (ancestor "main" signed));

    (* Remote bookmarks: absent is an answer, not an error. *)
    let bookmark name = Source_mirror.remote_bookmark ~jj_bin:"jj" mirror name in
    check "a remote bookmark resolves to its commit" (bookmark "main" = Ok (Some signed));
    check "an absent remote bookmark is None" (bookmark "deploy" = Ok None);
    check "a bookmark expression is refused" (Result.is_error (bookmark "main | root()"));

    (* The verdict parser accepts exactly what the template prints. *)
    let parse = Source_mirror.parse_signature in
    check "parse: unsigned" (parse "unsigned" = Ok Source_mirror.Unsigned);
    check "parse: a gpg verdict"
      (parse "good 2921DF701EE03394" = Ok (Source_mirror.Signed { status = Good; key = "2921DF701EE03394" }));
    check "parse: an unknown key with no id"
      (parse "unknown" = Ok (Source_mirror.Signed { status = Unknown_key; key = "" }));
    check "parse: bad and invalid"
      (parse "bad K" = Ok (Source_mirror.Signed { status = Bad; key = "K" })
       && parse "invalid K" = Ok (Source_mirror.Signed { status = Invalid; key = "K" }));
    check "parse: an unknown status is refused" (Result.is_error (parse "trusted K"));
    check "parse: extra words are refused" (Result.is_error (parse "good K extra"));
    check "parse: several lines are refused" (Result.is_error (parse "good K\ngood L"));
    check "parse: empty output is refused" (Result.is_error (parse ""));

    (* A git insteadOf rule (the operator's rewrites https://github.com/ to
       ssh) changes the URL jj reports, not the one the mirror recorded. The
       rule maps the declared URL to the same origin by plain path. Last,
       since it changes this process's git config. *)
    let rules = Filename.concat fixture "gitconfig" in
    write rules (Printf.sprintf "[url \"%s\"]\n\tinsteadOf = %s\n" origin url);
    Unix.putenv "GIT_CONFIG_GLOBAL" rules;
    check "an insteadOf rewrite of the declared URL is the same mirror"
      (match sync () with Ok _ -> true | Error e -> prerr_endline e; false))
