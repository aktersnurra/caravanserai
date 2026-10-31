#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP"; rm -rf "$TMP"' EXIT
mkdir "$TMP/bin"
python3 - "$TMP/freebsd" "$TMP/linux" <<'PY'
import sys
from pathlib import Path
for path,abi in zip(sys.argv[1:], [9,0]):
 h=bytearray(64); h[:8]=bytes([127,69,76,70,2,1,1,abi]); h[16:20]=bytes([2,0,62,0]); Path(path).write_bytes(h)
PY
cat >"$TMP/bin/fetch" <<'EOF'
#!/bin/sh
[ "$1" = -o ] && [ "$3" = https://example.org/idp ] || exit 1
cp "$FIXTURE_BINARY" "$2"
EOF
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
chmod +x "$TMP/bin/"*
checksum="$(sha256sum "$TMP/freebsd" | awk '{print $1}')"
run() {
 PATH="$TMP/bin:$PATH" FIXTURE_BINARY="${FIXTURE_BINARY:-$TMP/freebsd}" \
 sh "$ROOT/compute/apps/_lib/artifact_build_executable.sh" "$1" "$2" "$3" "$4" "$TMP/$5"
}
run download https://example.org/idp "$checksum" idp pocket-output
run verified-file "$TMP/freebsd" "$checksum" garage garage-output
for output in pocket-output garage-output; do
 test -f "$TMP/$output/release.tar"
 test "$(sha256sum "$TMP/$output/release.tar" | awk '{print $1}')" = "$(cat "$TMP/$output/release.sha256")"
done
tar -tf "$TMP/pocket-output/release.tar" | grep -Fxq './bin/idp'
tar -tf "$TMP/garage-output/release.tar" | grep -Fxq './bin/garage'
if run download https://example.org/idp "$(printf '%064d' 0)" idp wrong-sha >"$TMP/error" 2>&1; then exit 1; fi
test ! -e "$TMP/wrong-sha"
linux_sha="$(sha256sum "$TMP/linux" | awk '{print $1}')"
if FIXTURE_BINARY="$TMP/linux" run download https://example.org/idp "$linux_sha" idp wrong-os >"$TMP/error" 2>&1; then exit 1; fi
test ! -e "$TMP/wrong-os"
ln -s "$TMP/freebsd" "$TMP/link"
if run verified-file "$TMP/link" "$checksum" garage linked-input >"$TMP/error" 2>&1; then exit 1; fi
for bad in 'http://example.org/idp' 'https://user:password@example.org/idp'; do
 if run download "$bad" "$checksum" idp unsafe-url >"$TMP/error" 2>&1; then exit 1; fi
done
if run download https://example.org/idp "$checksum" '../escape' unsafe-name >"$TMP/error" 2>&1; then exit 1; fi
if run verified-file "$TMP/freebsd" "$checksum" garage garage-output >"$TMP/error" 2>&1; then exit 1; fi
test -f "$TMP/garage-output/release.tar"
if find "$TMP" -maxdepth 1 -name '*.tmp.*' | grep -q .; then echo 'executable worker partial stage leaked' >&2; exit 1; fi
echo 'ok - pinned FreeBSD executable payloads reject checksum, OS, link and input-boundary failures'
