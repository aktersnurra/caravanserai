(* infra jail-test: the pure parts. An app's generated jail script is tried
   on a throwaway jail, <app>test, at an operator-chosen ip, without
   touching the real one. Strategy.render_jail_script ~jail_name already moves
   every host-side resource -- the jail.conf block, /jails/<name>,
   jail_list, every jexec and service jail target, an app's ZFS dataset -- to
   the jail name, and keeps every in-jail name the real app's. Retargeting
   is therefore only the ip; everything else here is the rules a test jail
   must satisfy and the script that destroys one.

   Strategy's string fields audited for host-side names: repo_path and
   check_path are not in the jail script; data_dir, upload_dir, db_path,
   geolite_db and the template paths are inside the jail root or beside the
   staged script; zfs_dataset is namespaced by zfs_dataset_for. The only
   host paths left are transient /tmp downloads, which the compute host lock keeps
   from racing a real bootstrap. *)

let suffix = "test"

let name (app : App_config.t) = app.endpoint.name ^ suffix

let is_test_name name =
  Network_endpoint.is_placeholder_safe name
  && String.length name > String.length suffix
  && String.ends_with ~suffix name

(* The test name must be a valid app and endpoint name, and must not be a
   declared endpoint's: the test jail would take over that jail's block,
   root and jail_list entry. *)
let validate_name ~declared name =
  if not (is_test_name name) then
    Error (Printf.sprintf "jail-test: %s is not a valid test jail name ([a-z0-9]+test)" name)
  else if List.mem name declared then
    Error (Printf.sprintf "jail-test: %s is already a declared endpoint" name)
  else Ok ()

(* Free on the host's network, and no declared endpoint's ip. The network
   check takes canonical dotted decimal only, so the string compares equal
   to how an endpoint would spell it. *)
let validate_ip ~host ~declared ip =
  match Topology.check_workload_ip host ip with
  | Error reason -> Error (Printf.sprintf "jail-test: --ip %s: %s" ip reason)
  | Ok () when List.mem ip declared -> Error (Printf.sprintf "jail-test: --ip %s is a declared endpoint's ip" ip)
  | Ok () -> Ok ()

(* The app at [ip], rebuilt through Network_endpoint.create, so the test
   ip passes the same canonical IPv4 check as a declared one; nothing but
   the ip changes. *)
let retarget (app : App_config.t) ~ip =
  match app.strategy with
  | Strategy_config.Freebsd_package_service _ ->
      Error [ Network_endpoint.Invalid_ip (ip, "package service args contain live listener addresses; refusing to retarget") ]
  | _ ->
      let endpoint = app.endpoint in
      Network_endpoint.create ~name:endpoint.name ~ip ~hostname:endpoint.hostname
        ~tailnet_ports:endpoint.tailnet_ports ~operator_ports:endpoint.operator_ports
      |> Result.map (App_config.with_endpoint app)

let render app ~ip =
  retarget app ~ip |> Result.map (Strategy.render_jail_script ~jail_name:(name app))

(* Run on the compute host over the stage-guard ssh, before anything is staged:
   prints whether /jails/<name> exists and, if so, the ip4.addr of its
   jail.conf block (empty when there is none). Read-only, and unprivileged:
   jail.conf and /jails are world-readable. The paths are parameters only
   so the test can run it against temp files. *)
let existing_marker = "jail-test-existing: "

let existing_ip_script ?(jail_conf = "/etc/jail.conf") ?(jails_dir = "/jails") ~name () =
  String.concat "\n"
    [
      "name=" ^ Shell.quote name;
      "jail_conf=" ^ Shell.quote jail_conf;
      "root=" ^ Shell.quote (jails_dir ^ "/" ^ name);
      {|if [ ! -e "$root" ] && [ ! -L "$root" ]; then|};
      "  echo '" ^ existing_marker ^ "absent'";
      "else";
      {|  ip=$(awk -v name="$name" '|};
      {|    !inb && $0 ~ ("^" name "[[:space:]]*[{]") { inb = 1; next }|};
      {|    inb && /^[[:space:]]*}/ { exit }|};
      {|    inb && /^[[:space:]]*ip4\.addr[[:space:]]*=/ {|};
      {|      sub(/^[^=]*=[[:space:]]*/, ""); sub(/^[^|]*[|]/, ""); sub(/[\/;].*$/, ""); print; exit|};
      "    }";
      {|  ' "$jail_conf" 2>/dev/null || true)|};
      "  echo \"" ^ existing_marker ^ "ip ${ip}\"";
      "fi";
    ]

(* An existing test jail is only re-run at the ip it already has: its
   jail.conf block is written once, so another --ip would leave the jail
   at the old address while infra reported the new one. Anything the probe
   did not clearly answer is refused. *)
type existing = Absent | Same_ip

(* The probe lines after [marker], in order. *)
let answers ~marker output =
  String.split_on_char '\n' output
  |> List.filter_map (fun line ->
         if String.starts_with ~prefix:marker line then
           Some (String.sub line (String.length marker) (String.length line - String.length marker))
         else None)

let check_existing ~app ~name ~ip output =
  let answers = answers ~marker:existing_marker output in
  let destroy_first = Printf.sprintf "destroy it first: infra jail-test %s --destroy" app in
  match answers with
  | [ "absent" ] -> Ok Absent
  | [ answer ] when String.starts_with ~prefix:"ip " answer -> (
      match String.sub answer 3 (String.length answer - 3) with
      | existing when existing = ip -> Ok Same_ip
      | "" ->
          Error
            (Printf.sprintf "jail-test: /jails/%s already exists with no ip4.addr in jail.conf; %s" name destroy_first)
      | existing ->
          Error
            (Printf.sprintf "jail-test: /jails/%s already exists at %s, not %s; re-run with --ip %s or %s" name existing
               ip existing destroy_first))
  | _ -> Error (Printf.sprintf "jail-test: could not tell whether /jails/%s already exists" name)

let env_marker = "jail-test-env: "

(* stat through jexec, so the group resolves inside the jail. *)
let env_file_script ~name ~app =
  String.concat "\n"
    [
      "name=" ^ Shell.quote name;
      "file=" ^ Shell.quote ("/etc/" ^ app ^ "/env");
      {|if owner=$(jexec "$name" stat -f '%Su:%Sg:%Lp' "$file" 2>/dev/null); then|};
      "  echo \"" ^ env_marker ^ "${owner}\"";
      "else";
      "  echo '" ^ env_marker ^ "absent'";
      "fi";
    ]

(* The test instance's own env: infra never writes or copies one. *)
let check_env_file ~app ~name output =
  let file = Printf.sprintf "/jails/%s/etc/%s/env" name app in
  let fix = Printf.sprintf "doas jexec %s chown root:%s /etc/%s/env && doas jexec %s chmod 0640 /etc/%s/env"
      name app app name app in
  match answers ~marker:env_marker output with
  | [ owner ] when owner = Printf.sprintf "root:%s:640" app -> Ok ()
  | [ "absent" ] ->
      Error
        (Printf.sprintf
           "%s has no env yet: write %s from %s, with this jail's own ip in any \
            listen address and its own database, then run %s, and run the same command again"
           name file (Layout.Relative.app_file ~app "env.template") fix)
  | [ owner ] -> Error (Printf.sprintf "%s is %s, not root:%s:640: run %s" file owner app fix)
  | _ -> Error (Printf.sprintf "could not tell whether %s is in place" file)

(* The test jail's own ZFS dataset, when its strategy has one. *)
let dataset (app : App_config.t) =
  match app.strategy with
  | Strategy_config.Freebsd_native_ocaml s ->
      Some (Strategy.zfs_dataset_for ~jail:(name app) ~app:app.endpoint.name s.zfs_dataset)
  | Strategy_config.Freebsd_package_service s ->
      Some (Strategy.zfs_dataset_for ~jail:(name app) ~app:app.endpoint.name s.zfs_dataset)
  | Strategy_config.(Freebsd_native_elixir _ | Freebsd_package _ | Fetch_binary _) -> None

(* Destroy only ever touches a name and a dataset ending in test. Checked
   here -- the only way to build a destroy_target -- and again inside the
   script, so neither alone can be bypassed. *)
type destroy_target = { name : string; dataset : string option }

let check_destroy_target ~name ?dataset () =
  if not (is_test_name name) then
    Error (Printf.sprintf "jail-test --destroy: refusing jail name %s: it does not end in test" name)
  else
    match dataset with
    | Some d when not (String.length d > String.length suffix && String.ends_with ~suffix d) ->
        Error (Printf.sprintf "jail-test --destroy: refusing dataset %s: it does not end in test" d)
    | Some _ | None -> Ok ()

let validate_destroy_target ~name ?dataset () =
  check_destroy_target ~name ?dataset () |> Result.map (fun () -> { name; dataset })

(* Run as root on the compute host. JAIL_CONF and JAILS_DIR are overridable so the
   script can be run locally against a temp copy; doas clears the
   environment, so on the compute host they are always the real paths. A one-line
   jail.conf block, which the line-wise removal cannot handle, and a jail
   still running after the stop are refused before anything is changed.
   jail.conf is rewritten through a temp file beside it (cp -p keeps its
   mode and owner) and mv, so it is never half-written. The dataset is
   destroyed before the root is removed, because it is mounted inside it;
   the root is removed only once nothing is mounted under its resolved
   path (a jail that failed to stop still has its devfs there), and rm -x
   never crosses a mount point regardless. *)
let destroy_script { name; dataset } =
  (match check_destroy_target ~name ?dataset () with
  | Ok () -> ()
  | Error msg -> invalid_arg msg);
  String.concat "\n"
    [
      "set -eu";
      "name=" ^ Shell.quote name;
      "dataset=" ^ Shell.quote (Option.value dataset ~default:"");
      {|JAIL_CONF="${JAIL_CONF:-/etc/jail.conf}"|};
      {|JAILS_DIR="${JAILS_DIR:-/jails}"|};
      {|refuse() { echo "jail-test destroy: refusing: $*" >&2; exit 1; }|};
      {|case "$name" in|};
      {|  '' | *[!a-z0-9]*) refuse "jail name $name is not [a-z0-9]+" ;;|};
      {|  test) refuse "jail name $name is only the suffix" ;;|};
      {|  *test) ;;|};
      {|  *) refuse "jail name $name does not end in test" ;;|};
      "esac";
      {|case "$dataset" in|};
      {|  '' | ?*test) ;;|};
      {|  *) refuse "dataset $dataset does not end in test" ;;|};
      "esac";
      {|root="${JAILS_DIR}/${name}"|};
      {|log() { echo "==> [${name}] $*"; }|};
      {|if grep -q "^${name}[[:space:]]*[{].*[}]" "$JAIL_CONF" 2>/dev/null; then|};
      {|  refuse "the jail.conf block for $name is on one line; remove it by hand"|};
      "fi";
      {|log "stopping the jail"|};
      {|service jail stop "$name" 2>/dev/null || true|};
      {|if jls -j "$name" >/dev/null 2>&1; then|};
      {|  refuse "jail $name is still running; stop it (jail -r $name) and re-run"|};
      "fi";
      {|if grep -q "^${name}[[:space:]]*[{]" "$JAIL_CONF" 2>/dev/null; then|};
      {|  backup="${JAIL_CONF}.before-${name}-destroy.$(date +%Y%m%d%H%M%S)"|};
      {|  cp -p "$JAIL_CONF" "$backup"|};
      {|  log "removing its jail.conf block (backup: ${backup})"|};
      {|  new=$(mktemp "${JAIL_CONF}.XXXXXX")|};
      {|  trap 'rm -f "$new"' EXIT|};
      {|  cp -p "$JAIL_CONF" "$new"|};
      {|  awk -v name="$name" '|};
      {|    !skip && $0 ~ ("^" name "[[:space:]]*[{]") { skip = 1; next }|};
      {|    skip { if ($0 ~ /^[[:space:]]*}/) skip = 0; next }|};
      "    { print }";
      {|  ' "$backup" >"$new"|};
      {|  mv "$new" "$JAIL_CONF"|};
      "  trap - EXIT";
      "fi";
      {|log "removing it from jail_list"|};
      {|sysrc jail_list-="$name"|};
      {|if [ -n "$dataset" ] && zfs list -H -o name "$dataset" >/dev/null 2>&1; then|};
      {|  log "destroying dataset ${dataset}"|};
      {|  zfs destroy -r "$dataset"|};
      "fi";
      {|if [ -e "$root" ]; then|};
      {|  real_root=$(realpath "$root")|};
      {|  if mount -p | awk -v root="$real_root" '$2 == root || index($2, root "/") == 1 { found = 1 } END { exit !found }'; then|};
      {|    refuse "something is still mounted under ${real_root}"|};
      "  fi";
      {|  log "removing ${root}"|};
      {|  chflags -R noschg "$root"|};
      {|  rm -rfx "$root"|};
      "fi";
      {|log "destroyed"|};
    ]
