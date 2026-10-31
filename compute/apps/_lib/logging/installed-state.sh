#!/bin/sh
# Sourced by bootstrap.sh. ready: running, every managed file matches.
# install: stopped, every file matches or none exists. differs: a consistent
# state with every file present and some different, which only a deliberate
# replace may overwrite. Anything else (a partial install, a link, an
# inconsistent service state) fails, for an operator to inspect.
installed_logging_state() {
  active=$1 enabled=$2
  shift 2
  [ "$#" -ge 2 ] && [ $(( $# % 2 )) -eq 0 ] || return 1
  case "$active:$enabled" in
    yes:YES) result=ready ;;
    no:NO|no:) result=install ;;
    *) return 1 ;;
  esac
  present=0
  absent=0
  differ=0
  while [ "$#" -gt 0 ]; do
    expected=$1 current=$2
    shift 2
    [ -f "$expected" ] && [ ! -L "$expected" ] || return 1
    if [ -e "$current" ] || [ -L "$current" ]; then
      [ -f "$current" ] && [ ! -L "$current" ] || return 1
      cmp -s "$expected" "$current" || differ=$((differ + 1))
      present=$((present + 1))
    else
      absent=$((absent + 1))
    fi
  done
  [ "$present" -eq 0 ] || [ "$absent" -eq 0 ] || return 1
  [ "$result" != ready ] || [ "$absent" -eq 0 ] || return 1
  [ "$differ" -eq 0 ] || result=differs
  printf '%s\n' "$result"
}
