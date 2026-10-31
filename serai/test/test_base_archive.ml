(* Base_archive: download once, verify the declared digest on every use. *)
open Serai

let check name condition =
  if condition then Printf.printf "ok - %s\n%!" name else failwith name

let write path value = Out_channel.with_open_bin path (fun c -> output_string c value)
let read path = In_channel.with_open_bin path In_channel.input_all
let sha256 value = Digestif.SHA256.(to_hex (digest_string value))

let rec remove_tree path =
  match (Unix.lstat path).Unix.st_kind with
  | Unix.S_DIR ->
      Array.iter (fun name -> remove_tree (Filename.concat path name)) (Sys.readdir path);
      Unix.rmdir path
  | _ -> Unix.unlink path

let () =
  let fixture = Filename.temp_dir "base-archive" "test" in
  Fun.protect ~finally:(fun () -> remove_tree fixture) (fun () ->
    let source = Filename.concat fixture "base.txz" in
    write source "synthetic base";
    let url = "file://" ^ source and cache = Filename.concat fixture "cache" in
    let ensure ?(sha256 = sha256 "synthetic base") () =
      Proc.live (fun () -> Base_archive.ensure ~curl_bin:"curl" ~cache ~url ~sha256) in
    let path = match ensure () with Ok path -> path | Error e -> failwith e in
    check "download lands in the cache with the declared bytes"
      (String.starts_with ~prefix:cache path && read path = "synthetic base");
    check "cached archive is private" ((Unix.stat path).Unix.st_perm = 0o600);
    Unix.unlink source;
    check "second use needs no download" (ensure () = Ok path);
    write path "tampered";
    check "a cached archive with other bytes is refused" (Result.is_error (ensure ()));
    remove_tree cache;
    write source "synthetic base";
    check "a download with other bytes is refused and not cached"
      (Result.is_error (ensure ~sha256:(String.make 64 'a') ())
       && Array.for_all (fun name -> not (String.ends_with ~suffix:".txz" name))
            (try Sys.readdir (Filename.concat cache "base") with Sys_error _ -> [||]));
    check "an invalid digest is refused before downloading"
      (Result.is_error (ensure ~sha256:"not-a-digest" ())))
