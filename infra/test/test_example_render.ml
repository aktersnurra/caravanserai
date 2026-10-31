(* Everything the engine renders from the example configuration, checked
   against golden/example/: the Headscale ACL, the pf rules, the Caddy tree
   and each app's jail script. A deliberate change to a generator or to
   example/ changes these files. Regenerate with
     (cd example && infra validate --out <dir>)
   copy <dir>/ over golden/example/ and review the diff. *)
open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let golden_dir = "golden/example"

let rec golden_files dir prefix =
  Sys.readdir dir |> Array.to_list |> List.sort String.compare
  |> List.concat_map (fun name ->
         let path = Filename.concat dir name and relative = prefix ^ name in
         if Sys.is_directory path then golden_files path (relative ^ "/")
         else [ (relative, In_channel.with_open_bin path In_channel.input_all) ])

let () =
  match Declaration.load ~layout:(Repo_root.example ()) with
  | Error error -> check ("example loads: " ^ Declaration.error_message error) false
  | Ok declaration -> (
      match Validation.render_all declaration with
      | Error message -> check ("example renders: " ^ message) false
      | Ok rendered ->
          let rendered = List.sort (fun (a, _) (b, _) -> String.compare a b) rendered in
          let golden = if Sys.file_exists golden_dir then golden_files golden_dir "" else [] in
          check "the same files as golden/example"
            (List.map fst rendered = List.map fst golden);
          List.iter (fun (path, contents) ->
              check ("golden/example/" ^ path ^ " byte for byte")
                (List.assoc_opt path golden = Some contents))
            rendered)

let () = if !failures > 0 then exit 1
