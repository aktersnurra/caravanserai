let active_marker = "release-probe-active: "
let source_marker = "release-probe-source: "
let previous_marker = "release-probe-previous: "

(* JAIL_ROOT stands in for /jails/<app> in tests, as in the artifact scripts.
   The active record is read only behind a well-formed identity, so a
   redirected pointer never makes root print another file. *)
let script ~app =
  String.concat "\n"
    [
      "set -eu";
      "app=" ^ Shell.quote app;
      {|root=${JAIL_ROOT:-/jails/$app}|};
      {|releases="$root/opt/.infra-releases/$app"|};
      "active=none";
      {|if [ -L "$root/opt/$app" ]; then active=$(readlink "$root/opt/$app")|};
      {|elif [ -e "$root/opt/$app" ]; then active=unmanaged; fi|};
      {|echo "|} ^ active_marker ^ {|$active"|};
      "source=none";
      {|id=${active#".infra-releases/$app/"}|};
      {|case "$id" in|};
      {|  "$active"|''|*[!0-9a-f]*) ;;|};
      {|  *) if [ "${#id}" -eq 64 ] && [ -f "$releases/$id/.infra-source" ] && [ ! -L "$releases/$id/.infra-source" ]; then|};
      {|       source=$(head -n 1 "$releases/$id/.infra-source")|};
      {|     fi ;;|};
      "esac";
      {|echo "|} ^ source_marker ^ {|$source"|};
      "previous=none";
      {|[ ! -L "$releases/.previous" ] || previous=$(readlink "$releases/.previous")|};
      {|echo "|} ^ previous_marker ^ {|$previous"|};
    ]

type t = { active : string option; source : string option; previous : string option }

let is_hex length value =
  String.length value = length
  && String.for_all (function '0' .. '9' | 'a' .. 'f' -> true | _ -> false) value

let ( let* ) = Result.bind

let answer ~marker output =
  match
    String.split_on_char '\n' output
    |> List.filter_map (fun line ->
           if String.starts_with ~prefix:marker line then
             Some (String.sub line (String.length marker) (String.length line - String.length marker))
           else None)
  with
  | [ value ] -> Ok value
  | _ -> Error (Printf.sprintf "release probe: expected one %S answer" (String.trim marker))

let optional ~what ~valid = function
  | "none" -> Ok None
  | value when valid value -> Ok (Some value)
  | value -> Error (Printf.sprintf "release probe: invalid %s %S" what value)

let check ~app output =
  let* active = answer ~marker:active_marker output in
  let* source = answer ~marker:source_marker output in
  let* previous = answer ~marker:previous_marker output in
  let prefix = ".infra-releases/" ^ app ^ "/" in
  let* active =
    optional ~what:"active pointer" active ~valid:(fun link ->
        String.starts_with ~prefix link
        && is_hex 64 (String.sub link (String.length prefix) (String.length link - String.length prefix))) in
  let active = Option.map (fun link -> String.sub link (String.length prefix) 64) active in
  let* source = optional ~what:"source commit" source ~valid:(is_hex 40) in
  let* previous = optional ~what:"previous identity" previous ~valid:(is_hex 64) in
  match active, source with
  | None, Some _ -> Error "release probe: a source commit without an active release"
  | _ -> Ok { active; source; previous }
