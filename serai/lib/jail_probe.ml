let root_marker = "jail-probe-root: "
let running_marker = "jail-probe-running: "
let configured_marker = "jail-probe-configured: "

(* jail.conf addresses are read from every ip4.addr line, whatever its form
   (lo1|ip/32, a bare ip, a list), so a jail serai does not declare counts. *)
let script ~app =
  String.concat "\n"
    [
      "app=" ^ Shell.quote app;
      {|if [ -e "/jails/$app" ] || [ -L "/jails/$app" ]; then|};
      "  echo '" ^ root_marker ^ "present'";
      "else";
      "  echo '" ^ root_marker ^ "absent'";
      "fi";
      {|jls -h name ip4.addr 2>/dev/null | awk 'NR > 1 { print "|} ^ running_marker ^ {|" $1 " " $2 }'|};
      {|awk '|};
      {|  /^[[:space:]]*[A-Za-z0-9_.-]+[[:space:]]*[{]/ { name = $1; sub(/[{].*$/, "", name) }|};
      {|  /^[[:space:]]*ip4\.addr/ {|};
      {|    line = $0; sub(/^[^=]*=/, "", line); gsub(/[|\/;,]/, " ", line)|};
      {|    n = split(line, f, " ")|};
      {|    for (i = 1; i <= n; i++) if (f[i] ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) print "|} ^ configured_marker ^ {|" name " " f[i]|};
      {|  }|};
      {|' /etc/jail.conf 2>/dev/null || true|};
      Jail_test.env_file_script ~name:app ~app;
    ]

type state = Absent | Present of (unit, string) result

let answers ~marker output =
  String.split_on_char '\n' output
  |> List.filter_map (fun line ->
         if String.starts_with ~prefix:marker line then
           Some (String.sub line (String.length marker) (String.length line - String.length marker))
         else None)

let pairs ~marker output =
  answers ~marker output
  |> List.filter_map (fun answer ->
         match String.split_on_char ' ' answer with [ name; ip ] -> Some (name, ip) | _ -> None)

let check ~app ~ip output =
  let held = pairs ~marker:running_marker output @ pairs ~marker:configured_marker output in
  let holders = List.sort_uniq String.compare
      (List.filter_map (fun (name, held_ip) -> if name <> app && held_ip = ip then Some name else None) held) in
  let own = List.sort_uniq String.compare
      (List.filter_map (fun (name, held_ip) -> if name = app then Some held_ip else None) held) in
  match holders, answers ~marker:root_marker output, own with
  | _ :: _, _, _ ->
      Error (Printf.sprintf "%s is already held by jail %s; give %s another ip in %s"
               ip (String.concat ", " holders) app (Layout.Relative.app_file ~app "app.sexp"))
  | [], [ "absent" ], [] -> Ok Absent
  | [], [ "absent" ], _ :: _ ->
      Error (Printf.sprintf "/etc/jail.conf has a %s jail but /jails/%s is missing; inspect the compute host" app app)
  | [], [ "present" ], [ own_ip ] when own_ip = ip ->
      Ok (Present (Jail_test.check_env_file ~app ~name:app output))
  | [], [ "present" ], [] ->
      Error (Printf.sprintf "/jails/%s exists but no jail %s is configured or running; inspect the compute host" app app)
  | [], [ "present" ], others ->
      Error (Printf.sprintf "jail %s is at %s, not the declared %s" app (String.concat ", " others) ip)
  | _ -> Error (Printf.sprintf "could not tell whether jail %s exists" app)
