(* What each host last had its edge config applied from -- provenance, not
   state: the live files remain the truth that --plan diffs against, and
   this only says which commit put them there. Written by edge after a
   successful apply, read back and shown by edge and edge --plan. *)

type revision = {
  commit : string;
  change : string;
  is_published : bool; (* reachable from a remote bookmark, i.e. pushed *)
}

type t = {
  revision : revision;
  applied_at : string; (* UTC, ISO 8601 *)
  applied_by : string; (* user@machine *)
  components : string list; (* what this apply installed on the host *)
}

let path = "/var/lib/infra/applied"

(* With jj there is always a commit: the working-copy commit when it holds
   changes, its parent when it is empty. *)
let jj_revision_args ~root =
  [
    "-R"; root; "log"; "-r"; "coalesce(@ ~ empty(), @-)"; "--no-graph"; "-T";
    {|commit_id ++ " " ++ change_id ++ " " ++ if(self.contained_in("::remote_bookmarks()"), "published", "local") ++ "\n"|};
  ]

let revision_of_jj_output output =
  match String.split_on_char ' ' (String.trim output) with
  | [ commit; change; ("published" | "local") as publication ]
    when commit <> "" && change <> "" ->
      Ok { commit; change; is_published = publication = "published" }
  | _ -> Error (Printf.sprintf "unexpected jj output: %S" (String.trim output))

let context = "Applied_record"

let to_string t =
  let atom s = Sexplib.Sexp.Atom s in
  let field name value = Sexplib.Sexp.List [ atom name; value ] in
  Sexplib.Sexp.to_string_hum
    (Sexplib.Sexp.List
       [
         field "commit" (atom t.revision.commit);
         field "change" (atom t.revision.change);
         field "published" (atom (string_of_bool t.revision.is_published));
         field "applied_at" (atom t.applied_at);
         field "applied_by" (atom t.applied_by);
         field "components" (Sexplib.Sexp.List (List.map atom t.components));
       ])

let of_sexp sexp =
  let fields =
    Sexp_fields.fields_of_sexp ~context
      ~known:[ "commit"; "change"; "published"; "applied_at"; "applied_by"; "components" ]
      sexp
  in
  let atom name = Sexp_fields.atom ~context (Sexp_fields.field ~context name fields) in
  let is_published =
    match atom "published" with
    | "true" -> true
    | "false" -> false
    | _ -> Sexplib.Conv.of_sexp_error (context ^ ": published must be true or false") sexp
  in
  {
    revision = { commit = atom "commit"; change = atom "change"; is_published };
    applied_at = atom "applied_at";
    applied_by = atom "applied_by";
    components =
      Sexp_fields.list ~context (Sexp_fields.atom ~context)
        (Sexp_fields.field ~context "components" fields);
  }

let of_string s = of_sexp (Sexplib.Sexp.of_string s)

let short_commit commit = if String.length commit > 12 then String.sub commit 0 12 else commit

let summary t =
  Printf.sprintf "last applied %s (%s) %s by %s" (short_commit t.revision.commit)
    (if t.revision.is_published then "published" else "local only, not pushed")
    t.applied_at t.applied_by

(* Through a temp file and mv, so a reader never sees a half-written
   record; mode 644 so the unprivileged ssh user can read it back. *)
let write_script ?(path = path) t =
  let dir = Filename.dirname path in
  String.concat " && "
    [
      "install -d -m 755 " ^ Shell.quote dir;
      "printf '%s\\n' " ^ Shell.quote (to_string t) ^ " > " ^ Shell.quote (path ^ ".tmp");
      "chmod 644 " ^ Shell.quote (path ^ ".tmp");
      "mv " ^ Shell.quote (path ^ ".tmp") ^ " " ^ Shell.quote path;
    ]
