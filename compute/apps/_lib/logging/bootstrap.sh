#!/bin/sh
# Run on the FreeBSD compute host, after the receiver's jail. Never replaces
# host syslogd.
# bootstrap.sh <receiver> [--replace]: <receiver> is the app every sender
# forwards to, whose stage directory holds what serai rendered. A sender
# whose managed files differ is refused unless --replace, which stops it,
# installs the new files and starts it, and on any failure restores every
# file and restarts the previous senders.
set -eu
usage() { echo 'logging: usage: bootstrap.sh <receiver> [--replace]' >&2; exit 1; }
RECEIVER=${1-}
case "$RECEIVER" in ''|*[!a-z0-9]*) usage ;; esac
REPLACE=no
case "$#:${2-}" in
  1:) ;;
  2:--replace) REPLACE=yes ;;
  *) usage ;;
esac
# A root for every host path, and the syslog-ng binary: both only for tests.
ROOT=${CENTRAL_LOGGING_ROOT:-}
SYSLOG_NG=${SYSLOG_NG_BIN:-/usr/local/sbin/syslog-ng}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
. "$SCRIPT_DIR/installed-state.sh"
. "$SCRIPT_DIR/target-manifest.sh"
APPS_DIR="$SCRIPT_DIR/../.."
TARGETS="$APPS_DIR/$RECEIVER/logging-targets"
validate_logging_targets "$TARGETS" "$RECEIVER" || {
  echo 'logging: generated target manifest missing or invalid' >&2; exit 1;
}
JAILS=$(cut -d ' ' -f 1 "$TARGETS")
# Rendered by serai from the declarations, staged beside the targets: the
# host relay, the jail senders' base, and the guest bridge the relay listens
# on (empty when the host runs no guests).
HOST_CONFIG="$APPS_DIR/$RECEIVER/syslog-ng-host.conf"
JAIL_CONFIG="$APPS_DIR/$RECEIVER/syslog-ng-jail.conf"
for file in "$HOST_CONFIG" "$JAIL_CONFIG" "$APPS_DIR/$RECEIVER/guest-bridge"; do
  [ -f "$file" ] && [ ! -L "$file" ] || { echo "logging: generated $file missing" >&2; exit 1; }
done
TARGETS_PATH=/usr/local/etc/central-logging/targets
CONFIG_PATH=/usr/local/etc/central-logging/syslog-ng.conf
RC_PATH=/usr/local/etc/rc.d/central_logging

# A jail's source is local_only, or a reviewed sender its app ships at
# <app>/logging/<source>/: sender.conf (appended to the jail's syslog-ng
# config), files under etc/ and libexec/ (installed into the jail's
# central-logging dirs), and an optional preflight run against the jail root.
instance_root() {
  if [ "$1" = host ]; then printf '%s\n' "$ROOT"; else printf '%s/jails/%s\n' "$ROOT" "$1"; fi
}
listed() { case " $2 " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
jail_source() { awk -v name="$1" '$1 == name { print $2; exit }' "$TARGETS"; }
sender_dir() { printf '%s/%s/logging/%s\n' "$APPS_DIR" "$1" "$(jail_source "$1")"; }
# "<shipped file> <installed path>" for each file a jail's sender installs.
sender_files() {
  [ "$(jail_source "$1")" != local_only ] || return 0
  sender=$(sender_dir "$1")
  for file in "$sender"/etc/* "$sender"/libexec/*; do
    [ -f "$file" ] || continue
    case "$file" in
      "$sender"/etc/*) printf '%s /usr/local/etc/central-logging/%s\n' "$file" "${file##*/}" ;;
      *) printf '%s /usr/local/libexec/central-logging/%s\n' "$file" "${file##*/}" ;;
    esac
  done
}

[ "$(id -u)" -eq 0 ] || { echo 'logging: run as root' >&2; exit 1; }
for jail in $JAILS; do
  [ "$(jail_source "$jail")" != local_only ] || continue
  sender=$(sender_dir "$jail")
  [ -f "$sender/sender.conf" ] && [ ! -L "$sender/sender.conf" ] || {
    echo "logging: $jail's reviewed sender is missing; refusing partial forwarding" >&2
    exit 1
  }
  for file in "$sender"/etc/* "$sender"/libexec/*; do
    [ -e "$file" ] || [ -L "$file" ] || continue
    case "${file##*/}" in
      .*|*[!a-zA-Z0-9._-]*) echo "logging: unsafe sender file name for $jail" >&2; exit 1 ;;
    esac
    [ -f "$file" ] && [ ! -L "$file" ] || {
      echo "logging: $jail's sender file is not a plain file" >&2; exit 1
    }
  done
done
bridge=$(cat "$APPS_DIR/$RECEIVER/guest-bridge")
case "$bridge" in
  '') ;;
  *[!0-9.]*) echo 'logging: generated guest bridge invalid' >&2; exit 1 ;;
  *) ifconfig vm-guests | grep -Fq "inet $bridge " || {
       echo 'logging: guest bridge address missing; refusing partial forwarding' >&2
       exit 1
     } ;;
esac
for jail in "$RECEIVER" $JAILS; do
  jls -j "$jail" >/dev/null || {
    echo "logging: jail $jail is not running" >&2
    exit 1
  }
done
for jail in $JAILS; do
  [ "$(jail_source "$jail")" != local_only ] || continue
  sender=$(sender_dir "$jail")
  if [ -f "$sender/preflight" ]; then sh "$sender/preflight" "$ROOT/jails/$jail"; fi
done
tmp=$(mktemp -d)
installed=''
activated=''
# Running senders a replace stopped: on failure they get their files back
# and are started again, still enabled.
stopped=''
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$status" -ne 0 ]; then
    for instance in $activated; do
      if [ "$instance" = host ]; then
        service central_logging onestop >/dev/null 2>&1 || true
        listed "$instance" "$stopped" || sysrc central_logging_enable=NO >/dev/null 2>&1 || true
      else
        jexec "$instance" service central_logging onestop >/dev/null 2>&1 || true
        listed "$instance" "$stopped" ||
          jexec "$instance" sysrc central_logging_enable=NO >/dev/null 2>&1 || true
      fi
    done
    for instance in $installed; do
      root=$(instance_root "$instance")
      set -- "$CONFIG_PATH" "$RC_PATH"
      if [ "$instance" = host ]; then set -- "$@" "$TARGETS_PATH"; else
        while read -r _ installed_path; do
          [ -n "$installed_path" ] || continue
          set -- "$@" "$installed_path"
        done <<SENDER
$(sender_files "$instance")
SENDER
      fi
      for target in "$@"; do
        backup="$tmp/$instance$(printf '%s' "$target" | tr / _)"
        if [ -f "$backup" ]; then
          cp -p "$backup" "$root$target"
        else
          rm -f "$root$target"
        fi
      done
    done
    for instance in $stopped; do
      if [ "$instance" = host ]; then
        service central_logging onestart >/dev/null 2>&1
      else
        jexec "$instance" service central_logging onestart >/dev/null 2>&1
      fi || echo "logging: $instance's previous sender did not restart; start it by hand" >&2
    done
  fi
  rm -f "$ROOT/usr/local/etc/central-logging/syslog-ng.candidate.conf"
  for jail in $JAILS; do
    rm -f "$ROOT/jails/$jail/usr/local/etc/central-logging/syslog-ng.candidate.conf"
  done
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Each instance's rc script, ordered for its boot. A jail's logger owns the
# jail's syslog socket, so it starts before every service there, all of which
# require NETWORKING; it forwards through its disk queue once the network is
# up. The host relay serves no host service, and listens on the guest bridge
# that vm creates, so it waits for that when the host runs guests.
# The order is one line; awk expands a \n escape in it. FreeBSD's awk refuses
# a literal newline in a -v value.
render_rc() {
  awk -v order="$1" '$0 == "# __RCORDER__" { print order; next } { print }' \
    "$SCRIPT_DIR/central-logging.rc.template" >"$2"
}
render_rc "# REQUIRE: NETWORKING${bridge:+ vm}" "$tmp/central-logging-host.rc"
render_rc '# REQUIRE: FILESYSTEMS\n# BEFORE: NETWORKING' "$tmp/central-logging-jail.rc"
rc_script() {
  if [ "$1" = host ]; then printf '%s\n' "$tmp/central-logging-host.rc"
  else printf '%s\n' "$tmp/central-logging-jail.rc"; fi
}

# Prepare every candidate and validate with the actual FreeBSD package before
# installing any rc.d script or enabling any service.
install -d -m 0700 "$ROOT/usr/local/etc/central-logging" "$ROOT/var/db/central-logging"
install -m 0600 "$HOST_CONFIG" \
  "$ROOT/usr/local/etc/central-logging/syslog-ng.candidate.conf"

for jail in $JAILS; do
  root=$(instance_root "$jail")
  install -d -m 0700 "$root/usr/local/etc/central-logging" \
    "$root/var/db/central-logging"
  candidate="$root/usr/local/etc/central-logging/syslog-ng.candidate.conf"
  install -m 0600 "$JAIL_CONFIG" "$candidate"
  # local_only keeps the local syslog socket, with no remote file source.
  if [ "$(jail_source "$jail")" != local_only ]; then
    cat "$(sender_dir "$jail")/sender.conf" >>"$candidate"
  fi
done

# Compare all active managed files before installing packages or touching any
# live config. A matching sender is left running; inconsistent state, or drift
# without --replace, aborts the entire run rather than overwriting an
# operator's changes.
ready_instances=''
to_install=''
to_stop=''
for instance in host $JAILS; do
  root=$(instance_root "$instance")
  if [ "$instance" = host ]; then
    if service central_logging onestatus >/dev/null 2>&1; then active=yes; else active=no; fi
    enabled=$(sysrc -n central_logging_enable 2>/dev/null || true)
  else
    if jexec "$instance" service central_logging onestatus >/dev/null 2>&1; then active=yes; else active=no; fi
    enabled=$(jexec "$instance" sysrc -n central_logging_enable 2>/dev/null || true)
  fi
  set -- "$root/usr/local/etc/central-logging/syslog-ng.candidate.conf" "$root$CONFIG_PATH" \
    "$(rc_script "$instance")" "$root$RC_PATH"
  if [ "$instance" = host ]; then set -- "$@" "$TARGETS" "$root$TARGETS_PATH"; else
    while read -r shipped installed_path; do
      [ -n "$shipped" ] || continue
      set -- "$@" "$shipped" "$root$installed_path"
    done <<SENDER
$(sender_files "$instance")
SENDER
  fi
  state=$(installed_logging_state "$active" "$enabled" "$@") || {
    echo "logging: $instance is partly installed or in an inconsistent state; refusing overwrite" >&2
    exit 1
  }
  case "$state" in
    ready) ready_instances="$ready_instances $instance" ;;
    install) to_install="$to_install $instance" ;;
    differs)
      [ "$REPLACE" = yes ] || {
        echo "logging: $instance's managed files differ; refusing overwrite (replace them deliberately with --replace)" >&2
        exit 1
      }
      to_install="$to_install $instance"
      if [ "$active" = yes ]; then to_stop="$to_stop $instance"; fi ;;
  esac
done
if [ -n "$ready_instances" ]; then
  echo "logging: preserving matching active senders:$ready_instances"
fi

for instance in $to_install; do
  if [ "$instance" = host ]; then
    pkg install -y syslog-ng
  else
    jexec "$instance" pkg install -y syslog-ng
  fi
done
"$SYSLOG_NG" --syntax-only \
  --cfgfile="$ROOT/usr/local/etc/central-logging/syslog-ng.candidate.conf"
for jail in $JAILS; do
  jexec "$jail" /usr/local/sbin/syslog-ng --syntax-only \
    --cfgfile=/usr/local/etc/central-logging/syslog-ng.candidate.conf
done

# All candidates parsed. Save pre-existing files so a failed start restores
# them, stop a sender being replaced, then start the host relay before any
# jail sender.
for instance in $to_install; do
  root=$(instance_root "$instance")
  set -- "$CONFIG_PATH" "$RC_PATH"
  if [ "$instance" = host ]; then set -- "$@" "$TARGETS_PATH"; else
    while read -r _ installed_path; do
      [ -n "$installed_path" ] || continue
      set -- "$@" "$installed_path"
    done <<SENDER
$(sender_files "$instance")
SENDER
  fi
  for target in "$@"; do
    if [ -f "$root$target" ]; then
      cp -p "$root$target" "$tmp/$instance$(printf '%s' "$target" | tr / _)"
    fi
  done
  if listed "$instance" "$to_stop"; then
    stopped="$stopped $instance"
    if [ "$instance" = host ]; then
      service central_logging onestop
    else
      jexec "$instance" service central_logging onestop
    fi
  fi
  installed="$installed $instance"
  if [ "$instance" = host ]; then
    install -m 0600 "$TARGETS" "$root$TARGETS_PATH"
  fi
  if [ "$instance" != host ]; then
    while read -r shipped installed_path; do
      [ -n "$shipped" ] || continue
      case "$installed_path" in
        /usr/local/libexec/*)
          install -d -m 0700 "$root/usr/local/libexec/central-logging"
          install -m 0755 "$shipped" "$root$installed_path" ;;
        *) install -m 0600 "$shipped" "$root$installed_path" ;;
      esac
    done <<SENDER
$(sender_files "$instance")
SENDER
  fi
  install -m 0600 "$root/usr/local/etc/central-logging/syslog-ng.candidate.conf" \
    "$root$CONFIG_PATH"
  install -m 0755 "$(rc_script "$instance")" "$root$RC_PATH"
done
for instance in $to_install; do
  activated="$activated $instance"
  if [ "$instance" = host ]; then
    service central_logging onestart
    sysrc central_logging_enable=YES >/dev/null
  else
    jexec "$instance" service central_logging onestart
    jexec "$instance" sysrc central_logging_enable=YES >/dev/null
  fi
done
