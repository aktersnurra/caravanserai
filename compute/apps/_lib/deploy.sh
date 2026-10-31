# compute/apps/_lib/deploy.sh
# Deploy library sourced by per-app deploy scripts.
#
# Expected to be sourced after the per-app `config` has been loaded. Required
# variables: JAIL, APP, MODULE, PORT, REPO_PATH, HOST_DEPLOY_DIR, JAIL_DEPLOY_DIR.
#
# Per-app deploy script:
#   #!/usr/bin/env bash
#   set -euo pipefail
#   SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
#   . "${SCRIPT_DIR}/config"
#   . "${SERAI_LIB:?run through infra deploy <app>}/deploy.sh"
#   run_deploy "$@"
#
# Optional hooks (per-app, executable files next to `config`):
#   post-copy.sh    runs after release copied, before migrations

log() { echo "==> $*"; }

run_deploy() {
  TARGET="${1:?usage: $0 user@compute}"
  SRC_DIR="/jails/${JAIL}/opt/${JAIL}_src"
  case "$REPO_PATH" in
    /*) APP_DIR="$REPO_PATH" ;;
    *)  APP_DIR="${SCRIPT_DIR}/${REPO_PATH}" ;;
  esac

  [ -d "$APP_DIR" ] || { echo "REPO_PATH not found: $APP_DIR" >&2; exit 1; }

  JAIL_UID="$(ssh "$TARGET" "doas jexec ${JAIL} id -u ${JAIL}")"
  export TARGET SRC_DIR APP_DIR JAIL_UID
  export JAIL APP MODULE PORT HOST_DEPLOY_DIR JAIL_DEPLOY_DIR PHX_HOST
  # Optional vars some apps define:
  [ -n "${VIDEO_PORT-}" ] && export VIDEO_PORT
  [ -n "${JAIL_IP-}" ] && export JAIL_IP

  _build_assets
  _sync_source
  _build_release
  _stop_and_wait_port_release
  _copy_release
  _run_hook post-copy.sh
  _run_migrations
  _start_and_wait_ready
  _print_status_and_logs
}

_build_assets() {
  log "Building assets locally"
  (cd "$APP_DIR" && MIX_ENV=prod mix assets.deploy)
}

_sync_source() {
  log "Syncing source to ${TARGET}:${SRC_DIR}"
  ssh "$TARGET" "doas mkdir -p ${SRC_DIR}"
  rsync -az --delete \
    --rsync-path="doas rsync" \
    --include="lib/***" \
    --include="priv/***" \
    --include="config/***" \
    --include="assets/***" \
    --include="mix.exs" \
    --include="mix.lock" \
    --exclude="*" \
    "${APP_DIR}/" \
    "${TARGET}:${SRC_DIR}/"
  ssh "$TARGET" "doas chown -R ${JAIL_UID}:${JAIL_UID} ${SRC_DIR}"
}

_build_release() {
  log "Building release inside jail"
  ssh "$TARGET" "
    doas jexec -U ${JAIL} ${JAIL} sh -c '
      set -e
      cd ${JAIL_DEPLOY_DIR}_src
      mix local.hex --force --if-missing
      mix local.rebar --force --if-missing
      MIX_ENV=prod mix deps.get --only prod
      MIX_ENV=prod mix release --overwrite
    '
  "
}

_stop_and_wait_port_release() {
  log "Stopping service"
  ssh "$TARGET" "
    doas jexec ${JAIL} service ${APP} stop || true
    doas jexec ${JAIL} sh -c '
      release_still_running() {
        sockstat -l4 2>/dev/null | grep -q \":${PORT}\\b\" && return 0
        pgrep -f beam.smp >/dev/null 2>&1 && return 0
        pgrep -f run_erl >/dev/null 2>&1 && return 0
        return 1
      }

      # The HTTP port can close before BEAM/run_erl fully exits. Wait for both
      # the listener and release processes before replacing live executables.
      for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
        if ! release_still_running; then
          pkill -9 epmd || true
          sleep 1
          exit 0
        fi
        sleep 1
      done

      # Force-kill if graceful shutdown is stale or the release cookie changed.
      echo \"release still running after 15s — force-killing\" >&2
      pkill -9 -f beam.smp || true
      pkill -9 -f run_erl || true
      pkill -9 epmd || true
      sleep 2

      release_still_running && {
        echo \"release STILL running after SIGKILL\" >&2
        exit 1
      }
      pgrep -x epmd >/dev/null 2>&1 && {
        echo \"epmd STILL running after SIGKILL\" >&2
        exit 1
      }
      exit 0
    '
  "
}

_copy_release() {
  log "Copying release into place"
  ssh "$TARGET" "
    set -e
    doas jexec ${JAIL} sh -c '
      set -e
      cp -a ${JAIL_DEPLOY_DIR}_src/_build/prod/rel/${APP}/. ${JAIL_DEPLOY_DIR}/
    '
    doas chown -R ${JAIL_UID}:${JAIL_UID} ${HOST_DEPLOY_DIR}
  "
}

_run_hook() {
  hook="${SCRIPT_DIR}/$1"
  if [ -x "$hook" ]; then
    log "Running hook: $1"
    "$hook"
  fi
}

_run_migrations() {
  log "Running migrations"
  ssh "$TARGET" "
    doas jexec ${JAIL} sh -c '
      set -a && . /etc/${JAIL}/env && set +a
      ${JAIL_DEPLOY_DIR}/bin/${APP} eval \"${MODULE}.Release.migrate()\"
    '
  "
}

_start_and_wait_ready() {
  log "Starting service"
  ssh "$TARGET" "doas jexec ${JAIL} service ${APP} start"

  log "Waiting for app readiness on :${PORT}"
  ssh "$TARGET" "
    doas jexec ${JAIL} sh -c '
      for i in \$(jot 30); do
        fetch -qo- http://127.0.0.1:${PORT}/ >/dev/null 2>&1 && exit 0
        sleep 1
      done
      echo \"app did not respond on :${PORT} after 30s — last 100 log lines:\" >&2
      tail -100 /var/log/${JAIL}/${APP}.log >&2
      exit 1
    '
  "
}

_print_status_and_logs() {
  log "Status:"
  ssh "$TARGET" "doas jexec ${JAIL} service ${APP} status"
  log ""
  log "Logs: ssh ${TARGET} 'tail -f /jails/${JAIL}/var/log/${JAIL}/${APP}.log'"
}
