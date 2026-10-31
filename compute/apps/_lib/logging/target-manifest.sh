#!/bin/sh
# Source from FreeBSD logging scripts. Never execute content as shell code.
# validate_logging_targets <file> <receiver>: the receiver forwards nothing.
validate_logging_targets() (
  file=$1
  receiver=$2
  [ -f "$file" ] && [ ! -L "$file" ] || return 1
  names=' '
  count=0
  while IFS=' ' read -r jail source extra || [ -n "$jail$source$extra" ]; do
    case "$jail" in
      ''|*[!a-z0-9]*) return 1 ;;
    esac
    [ "$jail" != "$receiver" ] && [ -z "$extra" ] || return 1
    case "$source" in
      # local_only, or a reviewed sender the jail's app ships; serai's typed
      # policy decides which, this checks only the shape.
      ''|[!a-z]*|*[!a-z0-9_]*) return 1 ;;
    esac
    case "$names" in *" $jail "*) return 1 ;; esac
    names="$names$jail "
    count=$((count + 1))
  done <"$file"
  [ "$count" -gt 0 ]
)
