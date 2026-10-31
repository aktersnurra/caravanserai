(* A pinned git input: [url] as declared, [commit] a full commit id. *)
type pinned_git = private { url : string; commit : string }

type freebsd_native_elixir = private {
  packages : string list;
  repo_path : string;
  source : string option;  (* git URL the build fetches; None: legacy hooks only *)
  release_name : string;
  migrate : string option;
      (* [(migrate (release_eval M.f))]: activation runs [bin/<release> eval "M.f()"]
         between stop and start. None: [(migrate none)] or omitted. *)
  check_path : string;
}

(** How activation tells whether a service is still running: its rc
    status, or, for a package whose rc status checks something else (a
    cluster RPC), a process named after its release. *)
type service_status = Rc | Process

type freebsd_package = private {
  packages : string list;
  check_path : string;
  check_status : int option;
      (** The exact HTTP status that means ready, for a service whose
          unauthenticated answer is not a success (S3's 403); otherwise
          any success. *)
  service_status : service_status;  (** [(service_status process)], or Rc *)
}
type fetch_binary = private {
  version : string;
  packages : string list;
  data_dir : string;
  binary_sha256 : string;
  binary_url_template : string;
  binary_name : string;
  port : string;
  env_values : (string * string) list;
      (** [(env_values ((NAME value) ...))]: each [__NAME__] in the env
          template becomes its value. [__JAIL_IP__] and [__PORT__] are always
          filled. Names are [A-Z][A-Z0-9_]*; values are single words free of
          the characters the rendered script would interpret. *)
  generated_secrets : string list;
      (** [(generated_secrets (NAME ...))]: each [__NAME__] becomes 32 random
          bytes, base64, made when the env file is first written. An existing
          env file is kept, so a secret is never regenerated. *)
  env_template_path : string;
  rc_template_path : string;
  check_path : string;
}
type freebsd_native_ocaml = private {
  ocaml_switch : string;
  repo_path : string;
  source : string option;
  opam_repository : pinned_git option;
  zfs_dataset : string;
  data_dir : string;
  packages : string list;
  serve_args : string list;  (* the service runs [<binary> <serve_args>] *)
  migrate : string list option;
      (* [(migrate (command a ...))]: activation runs [<binary> a ...] between
         stop and start. None: [(migrate none)] or omitted. *)
  check_path : string;
  web_bundle : string option;
      (* [(web_bundle <path>)]: a script in the source the controller runs as
         [<path> <out-dir>]; its flat output ships as the release's share/web. *)
}
(* A package that ships its own service account and rc.d script, with its
   data on a ZFS dataset (VictoriaLogs in the logs jail). *)
type freebsd_package_service = private {
  packages : string list;
  zfs_dataset : string;
  data_dir : string;
  data_owner : string;
  service : string;
  service_args : string list;
  check_path : string;
}
type t = private
  | Freebsd_native_elixir of freebsd_native_elixir
  | Freebsd_package of freebsd_package
  | Fetch_binary of fetch_binary
  | Freebsd_native_ocaml of freebsd_native_ocaml
  | Freebsd_package_service of freebsd_package_service

type error =
  | Unknown_strategy of Sexplib.Sexp.t
  | Invalid_fields of string * Sexplib.Sexp.t
  | Invalid_extra_step of string

val parse : strategy:Sexplib.Sexp.t -> config:Sexplib.Sexp.t -> (t, error) result

(** Extra steps are file names spliced into the generated jail script:
    each must be a plain, non-hidden file name beside it. *)
val parse_extra_steps : string list -> (string list, error) result
val error_message : error -> string
val offending_sexp : error -> Sexplib.Sexp.t
