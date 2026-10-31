#!/bin/sh
# The binary converter's service boundary in a Linux guest: it stands in for
# jexec, called as RELEASE service RELEASE ACTION, and drives that unit.
set -eu
[ "$#" = 4 ] && [ "$2" = service ] && [ "$1" = "$3" ] || exit 1
release=$1
case "$release" in [a-z]*) ;; *) exit 1 ;; esac
case "$release" in *[!a-z0-9_-]*) exit 1 ;; esac
systemctl_bin=${SYSTEMCTL_BIN:-systemctl}
case "$4" in
 stop|start) exec "$systemctl_bin" "$4" "$release" ;;
 status)
  rc=0; state=$("$systemctl_bin" is-active "$release" 2>/dev/null) || rc=$?
  case "$rc:$state" in
   0:active) exit 0 ;;
   3:inactive) exit 1 ;;
   *) exit 2 ;;
  esac
  ;;
 *) exit 1 ;;
esac
