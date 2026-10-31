open Infra

let check label condition =
  if condition then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)

let digest text = Digestif.SHA256.(to_hex (digest_string text))
let source_commit = String.make 40 'a'
let checksum = digest "package bytes"
let dependency name = Artifact_manifest.{ name; version = "1.2.3"; sha256 = checksum }

let manifest ?(name="sprint") ?(source_commit=source_commit) ?(target_abi="FreeBSD:14:amd64")
    ?(dependencies=[dependency "elixir"; dependency "erlang"])
    ?(recipe_sha256=digest "builder script") ?(release_name="sprint_trainer")
    ?(archive_sha256=digest "release bytes") () =
  Artifact_manifest.create ~name ~source_commit ~target_abi ~dependencies
    ~recipe_sha256 ~release_name ~archive_sha256

let valid = function Ok value -> value | Error message -> failwith message
let rejected result = match result with Error _ -> true | Ok _ -> false

let () =
  let first = valid (manifest ()) in
  let identity = Artifact_manifest.identity first in
  check "legacy cold source-v1 identity is frozen"
    (identity = "394eba3ceddf4b7a938ed7854273933280b5c110e247a22ffd7403902807ab10");
  check "manifest identity is lowercase SHA-256"
    (String.length identity = 64 && String.for_all (function '0'..'9'|'a'..'f' -> true | _ -> false) identity);
  let reversed = valid (manifest ~dependencies:[dependency "erlang"; dependency "elixir"] ()) in
  check "dependency input order does not alter canonical bytes"
    (Artifact_manifest.canonical first = Artifact_manifest.canonical reversed);
  check "identity is the digest of canonical bytes"
    (identity = digest (Artifact_manifest.canonical first));
  let encoded = Artifact_manifest.canonical first in
  let decoded = valid (Artifact_manifest.of_canonical encoded) in
  check "stored manifest roundtrips canonical bytes and identity"
    (Artifact_manifest.canonical decoded = encoded && Artifact_manifest.identity decoded = identity);
  check "every truncated manifest is refused"
    (List.init (String.length encoded) Fun.id |> List.for_all (fun length ->
       rejected (Artifact_manifest.of_canonical (String.sub encoded 0 length))));
  List.iter (fun text -> check "malformed stored manifest is refused"
    (rejected (Artifact_manifest.of_canonical text)))
    [encoded ^ "trailing"; "infra-artifact-manifest-v2\n";
     "infra-artifact-manifest-v1\n999999999999999999999999:x\n";
     "infra-artifact-manifest-v1\n-1:x\n";
     "infra-artifact-manifest-v1\n06:sprint\n" ^ String.sub encoded 35 (String.length encoded - 35)];
  List.iter (fun (label, changed) ->
    check (label ^ " changes identity") (Artifact_manifest.identity (valid changed) <> identity))
    [ "workload", manifest ~name:"board" ();
      "commit", manifest ~source_commit:(String.make 40 'b') ();
      "ABI", manifest ~target_abi:"FreeBSD:15:amd64" ();
      "dependencies", manifest ~dependencies:[dependency "elixir"] ();
      "recipe", manifest ~recipe_sha256:(digest "new builder") ();
      "release", manifest ~release_name:"other" ();
      "archive", manifest ~archive_sha256:(digest "other bytes") () ];
  List.iter (fun (label, result) -> check (label ^ " is rejected") (rejected result))
    [ "short commit", manifest ~source_commit:"abc123" ();
      "uppercase commit", manifest ~source_commit:(String.make 40 'A') ();
      "invalid recipe digest", manifest ~recipe_sha256:"abcd" ();
      "uppercase archive digest", manifest ~archive_sha256:(String.make 64 'A') ();
      "invalid workload", manifest ~name:"../escape" ();
      "invalid ABI", manifest ~target_abi:"FreeBSD 14" ();
      "invalid release", manifest ~release_name:"../release" ();
      "empty dependencies", manifest ~dependencies:[] ();
      "duplicate dependencies", manifest ~dependencies:[dependency "erlang"; dependency "erlang"] ();
      "missing dependency version", manifest ~dependencies:[Artifact_manifest.{name="erlang";version="";sha256=checksum}] ();
      "invalid dependency checksum", manifest ~dependencies:[Artifact_manifest.{name="erlang";version="1";sha256="?"}] () ];
  check "FreeBSD epoch versions and plus package names are accepted"
    (Result.is_ok (manifest ~dependencies:[Artifact_manifest.{
      name="compiler+runtime"; version="1.0_1,1"; sha256=checksum }] ()));
  let inventory = "compiler\t1.0_1,1\t" ^ checksum ^ "\n" in
  check "package inventory parses actual archive digest records"
    (Artifact_manifest.dependencies_of_inventory inventory = Ok [Artifact_manifest.{
      name="compiler"; version="1.0_1,1"; sha256=checksum }]);
  List.iter (fun (label, text) ->
    check (label ^ " inventory is refused")
      (Result.is_error (Artifact_manifest.dependencies_of_inventory text)))
    ["empty", ""; "incomplete", String.trim inventory;
     "duplicate", inventory ^ inventory; "checksum", "pkg\t1\tinternal-checksum\n";
     "extra field", "pkg\t1\t" ^ checksum ^ "\textra\n"];
  let app = App_config.load (Filename.concat (Layout.app_dir (Repo_root.example ()) "hello") "app.sexp") in
  let preview = match Artifact_plan.of_app ~revision:"abc123" app with
    | Ok value -> value | Error message -> failwith message in
  check "offline preview namespace is not a verified identity"
    (preview.artifact_dir <> Some identity
     && not (String.equal (Artifact_plan.render preview) (Artifact_manifest.canonical first)))

let () =
  let make input = Artifact_manifest.create_input ~name:"idp" ~input
    ~target_abi:"FreeBSD:15:amd64" ~dependencies:[dependency "idp"; dependency "garage"]
    ~recipe_sha256:(digest "binary adapter") ~release_name:"idp"
    ~archive_sha256:(digest "payload tar") in
  let binary = Artifact_manifest.Upstream_binary {
    version = "2.16.0"; url = "https://github.com/idp/idp/releases/download/v2.16.0/idp-freebsd-amd64";
    sha256 = checksum } in
  let binary_manifest = valid (make binary) in
  let bytes = Artifact_manifest.canonical binary_manifest in
  check "upstream input roundtrips without fabricating a source commit"
    (String.starts_with ~prefix:"infra-artifact-manifest-v2\n" bytes
     && Artifact_manifest.of_canonical bytes = Ok binary_manifest);
  let packages = valid (make (Artifact_manifest.Package_archives "garage")) in
  check "package origin is distinct from upstream input"
    (Artifact_manifest.identity packages <> Artifact_manifest.identity binary_manifest
     && Artifact_manifest.of_canonical (Artifact_manifest.canonical packages) = Ok packages);
  List.iter (fun input -> check "unsafe or unresolved input is rejected" (rejected (make input)))
    [Artifact_manifest.Package_archives "missing";
     Artifact_manifest.Upstream_binary {version="2"; url="http://example.org/file"; sha256=checksum};
     Artifact_manifest.Upstream_binary {version="2"; url="https://user:password@example.org/file"; sha256=checksum};
     Artifact_manifest.Upstream_binary {version="2"; url="https://example.org/file\n"; sha256=checksum};
     Artifact_manifest.Upstream_binary {version="2"; url="https://example.org/file"; sha256="invalid"}];
  let changed = valid (make (Artifact_manifest.Upstream_binary {
    version="2.16.0"; url="https://example.org/other"; sha256=checksum })) in
  check "upstream URL participates in identity"
    (Artifact_manifest.identity changed <> Artifact_manifest.identity binary_manifest);
  check "source constructor retains the existing v1 identity"
    (Artifact_manifest.create_input ~name:"sprint" ~input:(Artifact_manifest.Source_commit source_commit)
      ~target_abi:"FreeBSD:14:amd64" ~dependencies:[dependency "elixir"; dependency "erlang"]
      ~recipe_sha256:(digest "builder script") ~release_name:"sprint_trainer"
      ~archive_sha256:(digest "release bytes") = manifest ());
  check "every truncated upstream manifest is refused"
    (List.init (String.length bytes) Fun.id |> List.for_all (fun n ->
      rejected (Artifact_manifest.of_canonical (String.sub bytes 0 n))))

let () =
  let directory = Filename.temp_dir "artifact-manifest" "test" in
  let archive = Filename.concat directory "release.tar" in
  let alias = Filename.concat directory "release-link.tar" in
  Fun.protect ~finally:(fun () ->
    (try Sys.remove alias with Sys_error _ -> ());
    (try Sys.remove archive with Sys_error _ -> ());
    Unix.rmdir directory)
    (fun () ->
      let write contents =
        let output = open_out_bin archive in
        Fun.protect ~finally:(fun () -> close_out output)
          (fun () -> output_string output contents) in
      write "release bytes";
      let expected = valid (manifest ()) in
      check "matching archive bytes are verified"
        (Artifact_manifest.verify_archive expected ~archive = Ok ());
      Unix.symlink archive alias;
      check "archive symlink is refused"
        (rejected (Artifact_manifest.verify_archive expected ~archive:alias));
      check "archive directory is refused"
        (rejected (Artifact_manifest.verify_archive expected ~archive:directory));
      check "different manifest rejects archive"
        (rejected (Artifact_manifest.verify_archive
          (valid (manifest ~archive_sha256:(digest "other") ())) ~archive));
      write "changed bytes";
      check "changed archive bytes are refused"
        (rejected (Artifact_manifest.verify_archive expected ~archive));
      Sys.remove archive;
      check "missing archive is refused"
        (rejected (Artifact_manifest.verify_archive expected ~archive)))
