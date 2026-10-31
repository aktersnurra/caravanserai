# Shared lifecycle checker. Per-app wrappers source config before this file.
# Required config: JAIL, JAIL_IP, PORT, and PUBLIC_HOST or PHX_HOST.

check_required_config() {
  HOST=${PUBLIC_HOST:-${PHX_HOST:-}}
  SERVICE=${SERVICE:-${APP:-${JAIL:-}}}

  [ -n "${JAIL:-}" ] || {
    echo 'check: missing JAIL' >&2
    return 1
  }
  [ -n "${JAIL_IP:-}" ] || {
    echo 'check: missing JAIL_IP' >&2
    return 1
  }
  [ -n "${PORT:-}" ] || {
    echo 'check: missing PORT' >&2
    return 1
  }
  [ -n "$HOST" ] || {
    echo 'check: missing PUBLIC_HOST or PHX_HOST' >&2
    return 1
  }
  [ -n "$SERVICE" ] || {
    echo 'check: missing SERVICE, APP, or JAIL' >&2
    return 1
  }
}

reachable_status() {
  status=$("$@" 2>/dev/null) || return 1
  case "$status" in
  [1-4][0-9][0-9]) return 0 ;;
  *) return 1 ;;
  esac
}

check_app() {
  check_required_config
  check_path=${CHECK_PATH:-/}
  : "${COMPUTE_TARGET:?check: missing COMPUTE_TARGET}"
  : "${EDGE_TARGET:?check: missing EDGE_TARGET}"
  SSH_BIN=${SSH_BIN:-ssh}
  CURL_BIN=${CURL_BIN:-curl}

  "$SSH_BIN" "$COMPUTE_TARGET" "doas jexec ${JAIL} service ${SERVICE} status"
  reachable_status "$SSH_BIN" "$EDGE_TARGET" \
    "curl -o /dev/null -sS -w '%{http_code}' --max-time 10 http://${JAIL_IP}:${PORT}${check_path}" || {
    echo 'check: edge host-direct HTTP endpoint is unreachable' >&2
    return 1
  }
  reachable_status "$CURL_BIN" -o /dev/null -sS -w '%{http_code}' --max-time 10 \
    "https://${HOST}${check_path}" || {
    echo 'check: public HTTP endpoint is unreachable' >&2
    return 1
  }
}
