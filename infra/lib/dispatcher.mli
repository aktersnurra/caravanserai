type env = {
  layout : Layout.t;
  topology : Topology.t option;
  compute_target : string;
  edge_target : string;
  remote_stage : string;
  ssh_bin : string;
  rsync_bin : string;
  curl_bin : string;
  config : App_config.t list;
  endpoints : Network_endpoint.validated;
  edge : Edge_config.t;
  edge_ts_ip : string option;
  edge_peer_match : string option;
  caddy_force_build : bool;
  confirm : string -> bool;
  operator : string;
  lock_token : string;
  jj_bin : string;
  now_utc : unit -> string;
  guests : Guest_config.t list;
  ops_control_path : string;
  ssh_multiplex : bool;
  source_checkout_override : string option;
}

(** Refuses (Failure) anything but [a-z0-9-]+. *)
val validate_app_name : string -> unit

(** Remote shell boundary: creates and checks each stage component. *)
val secure_remote_stage_script : stage:string -> subtree:string -> string

val app_env : env -> string -> env
val require_direct_hook : env -> unit
val find_app : env -> string -> App_config.t
val list_apps : env -> string list
val list_guests : env -> string list
val bootstrap : env -> string -> unit
val deploy : env -> string -> unit

(** Stages a trusted Phoenix archive under the compute host lock and verifies/install
    it into a versioned jail directory. Does not activate or restart it. *)
val artifact_install : env -> string -> identity:string -> archive:string -> sha256:string -> unit

(** Internal candidate build only; no installation or activation. *)
type artifact_build_candidate = {
  source_commit : string;
  source_inventory_sha256 : string;
  target_abi : string;
  recipe_sha256 : string;
  archive_sha256 : string;
  manifest : Artifact_manifest.t;
}
val artifact_build_candidate : ?checkout:string -> ?opam_repository:(string * string) -> ?opam_snapshots:string ->
  env -> string -> revision:string -> ip:string ->
  base_archive:string -> base_sha256:string -> out:string -> artifact_build_candidate

(** Build and publish a verified source candidate. OCaml requires
    [opam_repository=(checkout, revision)], snapshotted and bound to its declared
    compiler recipe; Phoenix refuses this input. [reuse] explicitly pins an
    existing identity and its recorded dependencies: verify the archive and match
    committed source, base/helper recipe and release without remote work.
    Mismatches refuse; there is no automatic selection or fallback build.
    Reuse does not attest compatibility with a live target or activate it.
    [checkout] replaces the declared repo_path, e.g. with a source mirror.
    [opam_snapshots] keeps the exported opam repository by commit
    ({!Source_snapshot.stage_cached}); without it each call exports it anew. *)
val artifact_build_store : ?reuse:string -> ?checkout:string -> ?opam_repository:(string * string) -> ?opam_snapshots:string ->
  env -> string -> revision:string -> ip:string ->
  base_archive:string -> base_sha256:string -> store:string -> string

(** Build and store a declared package or checksum-pinned executable, without
    inventing a source commit. Publication requires verified output and cleanup.
    Interrupted/uncertain transport or worker failure retains stage and compute host lock.
    [reuse] verifies the selected store identity and exact declared origin/recipe
    locally, pinning its recorded dependencies without any build fallback. *)
val artifact_build_executable_store : ?reuse:string -> env -> string -> ip:string ->
  base_archive:string -> base_sha256:string -> store:string -> string

(** Select a verified Phoenix/package/pinned-binary store entry, probe the jail
    ABI and install, switch, restart and check under one compute host lock. An s3-only
    package requires running rc plus its exact unsigned S3 403; admin/token
    access is excluded.
    Binary rc/anchor names are separate from release launcher names.
    Rollback requires the retained previous identity; conversion requires
    byte-equivalent legacy code and retains a root-private backup/receipt.
    Neither operation rewrites external configuration or rolls back databases.
    Uncertain transport/interruption or cleanup retains the stage and compute host lock
    for inspection; it does not authorize blind retry or automatic unlock.
    [rehearse_ip] upgrades the test jail <app>test at that ip instead, with
    every in-jail name the app's; it excludes conversion and rollback. *)
val artifact_apply : ?convert:bool -> ?rehearse_ip:string -> env -> string ->
  store:string -> identity:string -> rollback:bool -> unit

(** Which kind of app [new_app] declares. *)
type new_kind = New_phoenix | New_ocaml

(** infra new: writes apps/<name>/app.sexp and env.template and the
    app's Caddy site, and places and proxies it in serai.sexp (see
    {!App_scaffold}). [repo] is the app's local jj checkout: its origin is the
    source builds fetch, and a Phoenix release is read from its mix.exs.
    Touches no host. Refuses to overwrite anything, and removes what it wrote
    unless the whole declaration loads and renders with the app. *)
val new_app : env -> string -> kind:new_kind -> repo:string -> hostname:string option -> App_scaffold.t

(** Deploy [app] at [revision] from its declared inputs: fetch the source
    mirror (or use [local_source], a checkout, for unpushed work), fetch the
    base archive into [cache], reuse or build the artifact in [store], apply
    it, update the edge and check the public URL. One confirmation up front.
    [target] is [Live] by default. [Rehearse ip] deploys into the test jail
    <app>test at that ip instead, with no edge step and health checked at the
    jail address. A missing test
    jail is created (its own confirmation) and the run stops for the operator
    to write its env; a test jail without its env, root:<app> 0640, is
    refused before anything changes. *)
type up_target =
  | Live  (** the app's jail, then the edge and the public check *)
  | Rehearse of string  (** the test jail <app>test at this ip *)

val up : ?local_source:string -> ?target:up_target -> env -> string -> revision:string ->
  cache:string -> store:string -> unit

(** What [up] decides before it asks. *)
type up_jail =
  | Jail_ready
  | Jail_create  (** a new app's: created on confirmation, then up stops for its env *)
  | Jail_needs_env of string  (** refused until the operator does this *)

type up_release =
  | Reuse of string  (** this stored identity *)
  | Build of { ip : string; base_sha256 : string }  (** in the build jail at [ip], from this base *)

type up_plan = private {
  app : string;
  host : string;
  source : string;  (** the declared git URL, or the local checkout *)
  commit : string;
  local : bool;  (** built from a local checkout, not a pushed commit *)
  release : up_release;
  jail : up_jail;
  rehearsal : (string * string) option;  (** the test jail and its ip *)
  public_url : string;
}

(** [up]'s plan, live target only, without changing any host: the jail is
    probed, the source mirror fetched and the store searched. *)
val up_plan : ?local_source:string -> env -> string -> revision:string -> cache:string -> store:string -> up_plan

val print_up_plan : up_plan -> unit

type up_step = Jail | Build | Release | Edge | Check
type step_status = Done | Skipped | Failed of string | Not_run

type up_result =
  | Deployed of string  (** this identity is active and healthy *)
  | Stopped_for_env of string  (** the jail was created; what the operator does next *)
  | Step_failed of up_step * string

(** Every step in order, with what happened to it. *)
type up_outcome = { steps : (up_step * step_status) list; result : up_result }

val step_name : up_step -> string

(** [up] without its reporting: the plan and the outcome of each step. A
    [Failure] means nothing changed: the plan was refused or not confirmed. *)
val up_run : ?local_source:string -> ?target:up_target -> env -> string -> revision:string ->
  cache:string -> store:string -> up_plan * up_outcome

(** The variables _lib/check.sh's check_app reads, from the declaration:
    JAIL, JAIL_IP, PORT (http, or the only tailnet port), PUBLIC_HOST,
    SERVICE (a Phoenix release's name, otherwise the app's) and CHECK_PATH. *)
val check_environment : App_config.t -> (string * string) list

(** Runs _lib/check.sh's check_app with [check_environment]: the service's
    status on the compute host, then its direct and public HTTP endpoints. *)
val check : env -> string -> unit
val update_version : env -> string -> string -> unit
val unlock : env -> string -> unit
val plan_edge : env -> bool
val edge : env -> unit
val caddy_install : env -> unit

(** Central logging's senders, each under its host's lock. [Recovery_check]
    inspects matching enabled units without starting them; [Recovery_apply]
    updates only known failed units and checks they stay active. *)
type logging_action = Normal_logging | Recovery_check | Recovery_apply | Recovery_health
type edge_logging_component = Edge_sender | Vmui_auth

(** Converge leaves matching senders running and refuses any whose managed
    files differ; Replace stops those, installs the new files and starts
    them, restoring the previous senders if anything fails. *)
type compute_logging_mode = Converge | Replace

(** The compute host relay and the jail senders logging.sexp names. *)
val install_compute_logging : ?mode:compute_logging_mode -> env -> unit
val install_edge_logging_component : ?action:logging_action -> env -> edge_logging_component -> unit
val install_guest_logging : ?action:logging_action -> env -> string -> unit

(** Build a guest's declared workload unprivileged through the compute host using immutable source/repository
    snapshots and an exact variant compiler. Selected [reuse] verifies an owned
    store entry and source/recipe locally; it does not attest live runtime or
    strict offline materials closure. Failed/uncertain work retains stage/lock. *)
val artifact_build_guest_store : ?reuse:string -> env -> string -> revision:string ->
  opam_repository:(string * string) -> compiler:string -> store:string -> string

(** Store-backed Linux/glibc ABI-gated install/activate/health or strict binary
    conversion. Root execution needs a real terminal for su. External unit,
    configuration and state are preserved. Unknown outcomes retain stage/lock. *)
val artifact_apply_guest : ?convert:bool -> env -> string -> store:string ->
  identity:string -> rollback:bool -> unit

(** A bhyve guest's lifecycle, each under a lock on the guest reached by
    ProxyJump through the compute host. [provision_guest] stages guests/<guest>
    and runs its provision as root, then adds the guest to the compute host's vm_list
    so it starts at boot; [build_guest] stages, pushes the source checkout
    and runs its build unprivileged; [deploy_guest] builds, then installs as
    root, then provisions, stopping at the first failure. *)
val provision_guest : env -> string -> unit
val build_guest : env -> string -> unit
val deploy_guest : env -> string -> unit

(** [deploy_guest] for a declared guest, [deploy] otherwise; refuses a name
    that is both. *)
val deploy_app_or_guest : env -> string -> unit

(** Runs [app]'s generated jail script on the throwaway jail <app>test at
    [ip], after Jail_test's name, ip and existing-jail checks. *)
val jail_test : env -> string -> ip:string -> unit

(** Destroys <app>test (and its test dataset), refusing any non-test name. *)
val jail_test_destroy : env -> string -> unit

(** Locally rendered files keyed by their relative remote staging paths. *)
val render_edge : env -> ((string * string) list, string) result

(** Remote shell boundary: stage guard and atomic acquire in one connection. *)
val acquire_lock_script : stage:string -> token:string -> holder:string -> string
