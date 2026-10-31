type revision = { commit : string; change : string; is_published : bool }
type t = {
  revision : revision;
  applied_at : string;
  applied_by : string;
  components : string list;
}
val path : string
val jj_revision_args : root:string -> string list
val revision_of_jj_output : string -> (revision, string) result
val to_string : t -> string
val of_string : string -> t
val short_commit : string -> string
val summary : t -> string
val write_script : ?path:string -> t -> string
