(* Applied_record: jj output parsing, sexp round trip, the summary line,
   and the write script, run locally against a temp path. *)
open Infra

let failures = ref 0

let check name cond =
  if cond then Printf.printf "ok   - %s\n%!" name
  else begin
    incr failures;
    Printf.printf "FAIL - %s\n%!" name
  end

let contains ~needle haystack =
  let nl = String.length needle and hl = String.length haystack in
  let rec go i = i + nl <= hl && (String.sub haystack i nl = needle || go (i + 1)) in
  nl = 0 || go 0

let revision : Applied_record.revision =
  { commit = "0659e49d74d2a2353fcbd5038b93d337bffbe3eb"; change = "mxmqtpxqoulv"; is_published = true }

let record : Applied_record.t =
  {
    revision;
    applied_at = "2026-09-24T22:41:03Z";
    applied_by = "ops@laptop";
    components = [ "acl"; "caddy" ];
  }

let () =
  check "jj output: published revision"
    (Applied_record.revision_of_jj_output
       "0659e49d74d2a2353fcbd5038b93d337bffbe3eb mxmqtpxqoulv published\n"
    = Ok revision);
  check "jj output: local revision"
    (match Applied_record.revision_of_jj_output "abc def local\n" with
    | Ok r -> not r.is_published
    | Error _ -> false);
  check "jj output: garbage is an Error"
    (Result.is_error (Applied_record.revision_of_jj_output "Error: not a jj repo\n"));
  check "jj args: queries the non-empty working-copy commit"
    (List.mem "coalesce(@ ~ empty(), @-)" (Applied_record.jj_revision_args ~root:"/repo")
    && List.mem "/repo" (Applied_record.jj_revision_args ~root:"/repo"))

let () =
  check "sexp: round trip" (Applied_record.of_string (Applied_record.to_string record) = record);
  check "sexp: unknown field rejected"
    (match Applied_record.of_string "((commit a) (change b) (published true) (applied_at t) (applied_by u) (components ()) (extra x))" with
    | _ -> false
    | exception Sexplib.Conv.Of_sexp_error _ -> true);
  check "summary: short commit, publication, when and who"
    (Applied_record.summary record
    = "last applied 0659e49d74d2 (published) 2026-09-24T22:41:03Z by ops@laptop");
  check "summary: unpublished commits are flagged"
    (contains ~needle:"(local only"
       (Applied_record.summary { record with revision = { revision with is_published = false } }))

let () =
  let dir = Printf.sprintf "/tmp/infra-record-test-%d" (Unix.getpid ()) in
  let path = dir ^ "/nested/applied" in
  let code = Sys.command (Printf.sprintf "sh -c %s" (Filename.quote (Applied_record.write_script ~path record))) in
  let written = try In_channel.with_open_bin path In_channel.input_all with Sys_error _ -> "" in
  ignore (Sys.command ("rm -rf " ^ dir));
  check "write_script: creates the directory and writes the record"
    (code = 0 && Applied_record.of_string written = record)

let () = if !failures > 0 then exit 1
