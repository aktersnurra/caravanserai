open Serai

let failures = ref 0
let check name condition =
  Printf.printf "%s - %s\n%!" (if condition then "ok  " else "FAIL") name;
  if not condition then incr failures

let () =
  let binary = Filename.concat (Sys.getcwd ()) "../bin/main.exe" in
  let root = Filename.concat (Repo_root.find ()) "example" in
  let directory = Filename.temp_dir "serai-validate-cli" "" in
  Fun.protect ~finally:(fun () ->
    let link = Filename.concat directory "link" in
    (try Unix.unlink link with Unix.Unix_error (Unix.ENOENT, _, _) -> ());
    Test_declaration.remove_tree directory) (fun () ->
    let run out =
      let cwd = Sys.getcwd () in
      Fun.protect ~finally:(fun () -> Sys.chdir cwd) (fun () ->
        Sys.chdir root;
        Proc.live (fun () -> Proc.capture binary [ "validate"; "--out"; out ]))
    in
    let sentinel = Filename.concat directory "sentinel" in
    Out_channel.with_open_bin sentinel (fun channel -> output_string channel "keep me");
    let code, _ = run directory in
    check "validate --out rejects nonempty destination" (code <> 0);
    check "validate --out preserves existing files without adding output"
      (Array.to_list (Sys.readdir directory) = [ "sentinel" ]
       && In_channel.with_open_bin sentinel In_channel.input_all = "keep me");
    let code, _ = run sentinel in
    check "validate --out rejects regular file destination" (code <> 0);
    let empty = Filename.concat directory "empty" in
    Sys.mkdir empty 0o700;
    let link = Filename.concat directory "link" in
    Unix.symlink empty link;
    let code, _ = run link in
    check "validate --out rejects symlink without writing its target"
      (code <> 0 && Array.length (Sys.readdir empty) = 0);
    let code, _ = run empty in
    check "validate --out accepts empty destination"
      (code = 0 && Sys.file_exists (Filename.concat empty "acls.hujson"));
    let missing = Filename.concat directory "new/nested" in
    let code, _ = run missing in
    check "validate --out creates missing destination"
      (code = 0 && Sys.file_exists (Filename.concat missing "caddy/Caddyfile")));
  (* Run inside a configuration, serai reads that configuration and finds its
     engine further up: example/ is checked against this repository's engine. *)
  let cwd = Sys.getcwd () in
  let out = Filename.temp_dir "serai-validate-example" "" in
  let code, output = Fun.protect ~finally:(fun () -> Sys.chdir cwd) (fun () ->
    Sys.chdir (Filename.concat (Repo_root.find ()) "example");
    Proc.live (fun () -> Proc.capture binary [ "validate"; "--out"; Filename.concat out "rendered" ])) in
  let rendered path = Filename.concat (Filename.concat out "rendered") path in
  let read path = In_channel.with_open_bin (rendered path) In_channel.input_all in
  check "validate inside example/ checks the example configuration"
    (code = 0
     && String.starts_with ~prefix:"ok: 3 apps, 1 guest" (String.trim output)
     && Sys.file_exists (rendered "jails/hello.sh") && Sys.file_exists (rendered "jails/counter.sh")
     && not (Sys.file_exists (rendered "jails/meals.sh")));
  check "the example's edge is its own"
    (code = 0 && (let text = read "caddy/conf.d/40-hello.caddy" and needle = "hello.example.org" in
       let n = String.length needle in
       let rec at i = i + n <= String.length text && (String.sub text i n = needle || at (i + 1)) in
       at 0));
  Test_declaration.remove_tree out;
  if !failures > 0 then exit 1
