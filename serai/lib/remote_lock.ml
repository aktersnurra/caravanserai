(* A per-host lock around one serai run's use of the remote stage, so two
   concurrent runs cannot overwrite each other's staged files between a
   diff and its install. The lock is a directory: mkdir is atomic, so
   exactly one run creates it. It holds [holder] (who, for the message a
   blocked run prints) and [token] (which run, so a release never removes
   another run's lock). A run that finds the lock held waits for it. Nothing
   removes a lock automatically -- a lock left by a killed run is reported
   as stale after [stale_after_seconds], and cleared with `serai unlock`. *)

let held_exit = 3
let stale_exit = 4
let stale_after_seconds = 30 * 60

let lock_dir ~stage = stage ^ "/locks/infra"

(* Printed instead of the record when the host has none, so "never
   applied" is told apart from an empty or unreadable record. *)
let no_record_marker = "--no-record--"

(* How often a waiting run retries a held lock. *)
let poll_seconds = 2

(* On success the script prints [record]'s contents (or the marker) to
   stdout, so the caller learns what the host was last applied from over
   the same connection that took the lock. A held lock is waited for on
   the host, in that one connection: reconnecting to retry could cost the
   operator a hardware-key touch each time. *)
let acquire_script ~stage ~token ~holder ~record ~wait_seconds =
  String.concat "\n"
    [
      "set -eu";
      "lock=" ^ Shell.quote (lock_dir ~stage);
      "record=" ^ Shell.quote record;
      (* The ssh session that runs this script. If the serai run is
         interrupted, sshd goes and this script must not take the lock
         afterwards for a run that no longer exists. *)
      "caller=$PPID";
      "waited=0";
      "waiting_for=";
      {|until mkdir "$lock" 2>/dev/null; do|};
      (* Staleness is the lock dir's mtime, last changed when holder and
         token were created in it -- nothing may touch files inside the
         lock afterwards, or a stale lock would look fresh. If the holder
         released between the mkdir and this stat, the next try takes it. *)
      {|  if stat --version >/dev/null 2>&1; then since=$(stat -c %Y "$lock" 2>/dev/null) || since=; else since=$(stat -f %m "$lock" 2>/dev/null) || since=; fi|};
      {|  if [ -n "$since" ]; then|};
      {|    age=$(( $(date +%s) - since ))|};
      {|    holder=$(cat "$lock/holder" 2>/dev/null || echo 'unknown holder')|};
      Printf.sprintf {|    [ "$age" -lt %d ] || { echo "locked by $holder for ${age}s" >&2; exit %d; }|}
        stale_after_seconds stale_exit;
      {|    if [ "$holder" != "$waiting_for" ]; then|};
      {|      echo "waiting for the lock, held by $holder for ${age}s" >&2|};
      {|      waiting_for=$holder|};
      "    fi";
      "  fi";
      Printf.sprintf {|  [ "$waited" -lt %d ] || { echo "still locked after waiting ${waited}s" >&2; exit %d; }|}
        wait_seconds held_exit;
      Printf.sprintf "  sleep %d" poll_seconds;
      Printf.sprintf "  waited=$((waited + %d))" poll_seconds;
      Printf.sprintf {|  kill -0 "$caller" 2>/dev/null || exit %d|} held_exit;
      "done";
      "printf '%s\\n' " ^ Shell.quote holder ^ {| >"$lock/holder"|};
      "printf '%s\\n' " ^ Shell.quote token ^ {| >"$lock/token"|};
      {|if [ -e "$record" ]; then cat "$record" 2>/dev/null || true; else printf '%s\n' |}
      ^ Shell.quote no_record_marker ^ "; fi";
    ]

let release_script ~stage ~token =
  String.concat "\n"
    [
      "lock=" ^ Shell.quote (lock_dir ~stage);
      {|if [ "$(cat "$lock/token" 2>/dev/null || true)" = |} ^ Shell.quote token ^ " ]; then";
      {|  rm -rf "$lock"|};
      "else";
      {|  echo "lock at $lock is not this run's; left in place" >&2|};
      "fi";
    ]

let unlock_script ~stage =
  String.concat "\n"
    [
      "lock=" ^ Shell.quote (lock_dir ~stage);
      {|if [ -d "$lock" ]; then|};
      {|  echo "removing lock held by $(cat "$lock/holder" 2>/dev/null || echo 'unknown holder')" >&2|};
      {|  rm -rf "$lock"|};
      "else";
      {|  echo "no lock at $lock" >&2|};
      "fi";
    ]
