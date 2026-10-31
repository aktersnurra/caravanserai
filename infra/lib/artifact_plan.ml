(* The artifact and runtime are separate choices. This is intentionally an
   offline plan: a checkout revision must be checked against the actual source
   before a builder can run, and a FreeBSD package needs an exact resolved
   package version and checksum before it can be stored immutably. *)

type target = Freebsd_jail of string | Linux_guest of string

type origin =
  | Phoenix_source of { checkout : string; revision : string; release_name : string }
  | Ocaml_source of { checkout : string; revision : string }
  | Guest_source of { checkout : string; revision : string }
  | Verified_binary of { version : string; sha256 : string }
  | Freebsd_packages of string list

type t = {
  name : string;
  target : target;
  origin : origin;
  artifact_dir : string option;
}

let safe_component value =
  value <> "" && value <> "." && value <> ".." && String.length value <= 128
  && String.for_all
       (function
         | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
         | _ -> false)
       value

let is_sha256 value =
  String.length value = 64
  && String.for_all
       (function
         | 'a' .. 'f' | 'A' .. 'F' | '0' .. '9' -> true
         | _ -> false)
       value

let revision_for name = function
  | None -> Error (name ^ ": source revision required; pass --revision <revision>")
  | Some revision when safe_component revision && String.length revision <= 64 -> Ok revision
  | Some _ -> Error (name ^ ": revision must be a single safe path component")

(* A cache namespace, not a security checksum: a future artifact manifest must
   verify the complete build recipe and the artifact's SHA-256 before reuse. *)
let recipe_identity revision recipe =
  revision ^ "-" ^ Digest.to_hex (Digest.string recipe)

let artifact_dir name identity =
  if not (safe_component name && safe_component identity) then
    Error (name ^ ": invalid artifact path component")
  else Ok ("/var/db/infra/artifacts/" ^ name ^ "/" ^ identity)

let ( let* ) result f = Result.bind result f

let of_app ?revision (app : App_config.t) =
  let name = app.endpoint.name in
  let target = Freebsd_jail name in
  match app.strategy with
  | Strategy_config.Freebsd_native_elixir s ->
      let* revision = revision_for name revision in
      let recipe =
        String.concat "\000" ("phoenix" :: s.repo_path :: s.release_name :: s.packages)
      in
      let* artifact_dir = artifact_dir name (recipe_identity revision recipe) in
      Ok
        { name; target;
          origin = Phoenix_source { checkout = s.repo_path; revision; release_name = s.release_name };
          artifact_dir = Some artifact_dir }
  | Strategy_config.Freebsd_native_ocaml s ->
      let* revision = revision_for name revision in
      let recipe = String.concat "\000" ("ocaml" :: s.repo_path :: s.ocaml_switch :: s.packages) in
      let* artifact_dir = artifact_dir name (recipe_identity revision recipe) in
      Ok { name; target; origin = Ocaml_source { checkout = s.repo_path; revision }; artifact_dir = Some artifact_dir }
  | Strategy_config.Fetch_binary s ->
      let* () = match revision with None -> Ok () | Some _ -> Error (name ^ ": --revision applies only to source builds") in
      let* () = if is_sha256 s.binary_sha256 then Ok () else Error (name ^ ": invalid binary SHA-256") in
      let* artifact_dir = artifact_dir name (s.version ^ "-" ^ s.binary_sha256) in
      Ok { name; target; origin = Verified_binary { version = s.version; sha256 = s.binary_sha256 }; artifact_dir = Some artifact_dir }
  | Strategy_config.Freebsd_package s ->
      let* () = match revision with None -> Ok () | Some _ -> Error (name ^ ": --revision applies only to source builds") in
      Ok { name; target; origin = Freebsd_packages s.packages; artifact_dir = None }
  | Strategy_config.Freebsd_package_service s ->
      let* () = match revision with None -> Ok () | Some _ -> Error (name ^ ": --revision applies only to source builds") in
      Ok { name; target; origin = Freebsd_packages s.packages; artifact_dir = None }

let of_guest ?revision (guest : Guest_config.t) =
  let name = Guest_config.name guest in
  let* revision = revision_for name revision in
  let* artifact_dir = artifact_dir name (recipe_identity revision ("linux-guest\000" ^ guest.source_checkout)) in
  Ok
    { name; target = Linux_guest name;
      origin = Guest_source { checkout = guest.source_checkout; revision };
      artifact_dir = Some artifact_dir }

let render plan =
  let target = match plan.target with
    | Freebsd_jail name -> "FreeBSD jail " ^ name
    | Linux_guest name -> "Linux guest " ^ name
  in
  let input, build = match plan.origin with
    | Phoenix_source { checkout; revision; release_name } ->
        ( "source " ^ checkout ^ " at " ^ revision,
          "Phoenix release " ^ release_name ^ " in a disposable FreeBSD build jail" )
    | Ocaml_source { checkout; revision } ->
        ("source " ^ checkout ^ " at " ^ revision, "OCaml release in a disposable FreeBSD build jail")
    | Guest_source { checkout; revision } ->
        ("source " ^ checkout ^ " at " ^ revision, "Linux build in the guest build environment")
    | Verified_binary { version; sha256 } ->
        ("upstream binary " ^ version ^ " sha256 " ^ sha256, "fetch and verify")
    | Freebsd_packages packages ->
        ("FreeBSD packages " ^ String.concat ", " packages, "resolve exact package versions and checksums")
  in
  let store = match plan.artifact_dir with
    | Some path -> path
    | None -> "pending package resolution (no immutable artifact identity yet)"
  in
  String.concat "\n"
    [ "workload: " ^ plan.name;
      "runtime: " ^ target;
      "input: " ^ input;
      "prepare: " ^ build;
      "artifact store: " ^ store;
      "activation: stage versioned release, preserve data and secrets, switch active version, check health";
      "database migrations: explicit service step; binary rollback does not reverse a migration";
      "status: offline design preview; no build, host inspection or apply" ]
