#!/bin/sh
# One bounded, secret-free HTTP policy for artifact activation/conversion.
set -eu
url=${1:?health URL required}
case "$url" in http://?*) ;; *) exit 1 ;; esac
case "$url" in *[!a-zA-Z0-9./:_?=\&%+-]*) exit 1 ;; esac
curl_bin=${CURL_BIN:-curl}
sleep_bin=${SLEEP_BIN:-sleep}
case "${SERAI_ARTIFACT_HTTP_STATUS:-success}" in
    success)
        # curl reports every failed attempt, also those a later retry
        # recovers from; only the last one says why the check failed.
        if errors=$("$curl_bin" --disable -fsS --max-time 5 --retry 5 --retry-connrefused --retry-delay 1 \
            --retry-max-time 30 --output /dev/null "$url" 2>&1); then
            exit 0
        fi
        printf '%s\n' "$errors" | tail -n 1 >&2
        exit 1 ;;
    [1-5][0-9][0-9])
        # A declared exact status (S3's unsigned 403): the service must run
        # and answer exactly that.
        expected=$SERAI_ARTIFACT_HTTP_STATUS
        jail=${2:?jail required for status readiness}
        service_name=${3:?service required for status readiness}
        jexec_bin=${JEXEC_BIN:-jexec}
        remaining=6
        while [ "$remaining" -gt 0 ]; do
            if "$jexec_bin" "$jail" service "$service_name" status >/dev/null 2>&1 \
                && status=$("$curl_bin" --disable -sS --max-time 5 --output /dev/null --write-out '%{http_code}' "$url"); then
                [ "$status" != "$expected" ] || exit 0
            fi
            remaining=$((remaining - 1))
            [ "$remaining" -gt 0 ] || exit 1
            "$sleep_bin" 1 || exit 1
        done ;;
    *) exit 1 ;;
esac
