open Infra

let check label condition =
  if condition then Printf.printf "ok - %s\n%!" label
  else (Printf.eprintf "FAIL - %s\n%!" label; exit 1)

let write path contents mode =
  let channel = open_out_bin path in
  Fun.protect ~finally:(fun () -> close_out channel) (fun () -> output_string channel contents);
  Unix.chmod path mode

let rec remove_tree path =
  if (Unix.lstat path).Unix.st_kind = Unix.S_DIR then begin
    Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
    Unix.rmdir path
  end else Unix.unlink path

let rejected = function Error _ -> true | Ok _ -> false
let valid = function Ok value -> value | Error message -> failwith message
let digest text = Digestif.SHA256.(to_hex (digest_string text))
let commit = String.make 40 'a'

let () =
  let root = Filename.temp_dir "source-inventory" "fixture" in
  Fun.protect ~finally:(fun () -> remove_tree root) (fun () ->
    let first = Filename.concat root "z.txt" in
    let second = Filename.concat root "a.sh" in
    check "empty source is refused" (rejected (Source_inventory.create ~root ~commit));
    write first "first\n" 0o600;
    write second "#!/bin/sh\n" 0o700;
    let inventory = valid (Source_inventory.create ~root ~commit) in
    let canonical = Source_inventory.canonical inventory in
    let expected = Printf.sprintf "infra-source-v1\t%s\n700\t%s\ta.sh\n600\t%s\tz.txt\n"
      commit (digest "#!/bin/sh\n") (digest "first\n") in
    check "inventory lists sorted paths, modes and content digests" (canonical = expected);
    check "inventory identity hashes canonical bytes" (Source_inventory.identity inventory = digest expected);
    let nested = Filename.concat root "a" in
    Unix.mkdir nested 0o700;
    write (Filename.concat nested "nested.txt") "nested\n" 0o600;
    write (Filename.concat root "a.txt") "nearby\n" 0o600;
    let lines = String.split_on_char '\n' (Source_inventory.canonical
      (valid (Source_inventory.create ~root ~commit))) in
    let paths = List.filter_map (fun line ->
      match String.split_on_char '\t' line with [ _mode; _digest; path ] -> Some path | _ -> None) lines in
    check "inventory paths have global lexical order"
      (paths = ["a.sh"; "a.txt"; "a/nested.txt"; "z.txt"]);
    write (Filename.concat nested "compiler.5.6.0~alpha1.opam") "opam definition\n" 0o600;
    check "inventory authenticates literal opam prerelease paths"
      (match Source_inventory.create ~root ~commit with
       | Error _ -> false
       | Ok value -> List.mem
           ("600\t" ^ digest "opam definition\n" ^ "\ta/compiler.5.6.0~alpha1.opam")
           (String.split_on_char '\n' (Source_inventory.canonical value)));
    write first "changed\n" 0o600;
    check "changing source bytes changes inventory identity"
      (Source_inventory.identity (valid (Source_inventory.create ~root ~commit)) <> Source_inventory.identity inventory);
    check "short commit is refused" (rejected (Source_inventory.create ~root ~commit:"abc123"));
    Unix.chmod second 0o666;
    check "non-private file mode is refused" (rejected (Source_inventory.create ~root ~commit));
    Unix.chmod second 0o700;
    Unix.chmod second 0o4700;
    check "setuid source file is refused" (rejected (Source_inventory.create ~root ~commit));
    Unix.chmod second 0o700;
    let link = Filename.concat root "link" in
    Unix.symlink first link;
    check "symlink is refused" (rejected (Source_inventory.create ~root ~commit));
    Unix.unlink link;
    let pipe = Filename.concat root "pipe" in
    Unix.mkfifo pipe 0o600;
    check "FIFO is refused" (rejected (Source_inventory.create ~root ~commit));
    Unix.unlink pipe;
    let env = Filename.concat root ".env" in
    write env "synthetic fixture\n" 0o600;
    check "env-like paths are refused" (rejected (Source_inventory.create ~root ~commit));
    Unix.unlink env;
    let backup = Filename.concat root ".env~" in
    write backup "synthetic environment backup\n" 0o600;
    check "environment editor backups remain refused"
      (rejected (Source_inventory.create ~root ~commit));
    Unix.unlink backup;
    Unix.chmod root 0o755;
    check "non-private directory is refused" (rejected (Source_inventory.create ~root ~commit)))
