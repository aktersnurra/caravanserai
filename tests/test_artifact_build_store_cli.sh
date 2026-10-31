#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/serai/_build/prepared-builder/tmp"
TMP="$(mktemp -d "$ROOT/serai/_build/prepared-builder/tmp/task8-cli.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
cat >"$TMP/ssh" <<'EOF'
#!/bin/sh
printf 'unexpected remote call\n' >>"$REMOTE_LOG"
exit 1
EOF
chmod +x "$TMP/ssh"
export SSH_BIN="$TMP/ssh" RSYNC_BIN="$TMP/ssh" REMOTE_LOG="$TMP/remote"
mkdir "$TMP/store"
chmod 777 "$TMP/store"
(cd "$ROOT/serai" && dune build bin/main.exe)
CLI="$ROOT/serai/_build/default/bin/main.exe"
# A copy of the example configuration plus a package and a pinned binary,
# inside this repository so that its engine is the one above it.
cp -R "$ROOT/example" "$TMP/config"
for app in garage idp; do
 mkdir "$TMP/config/apps/$app"
 cp "$ROOT/serai/test/fixtures/executable_apps/$app/app.sexp" "$TMP/config/apps/$app/app.sexp"
done
sed -e 's/(logs worker)/(logs worker) (garage worker) (idp worker)/' \
 -e 's/(proxy (hello counter logs ledger))/(proxy (hello counter logs ledger garage idp))/' \
 "$ROOT/example/serai.sexp" >"$TMP/config/serai.sexp"
cd "$TMP/config"
if REMOTE_LOG="$TMP/remote" SSH_BIN="$TMP/ssh" "$CLI" \
 artifact build hello --revision invalid --ip 10.20.0.11 --base "$TMP/no-base" \
 --sha256 "$(printf '%064d' 0)" --store "$TMP/store" --yes >"$TMP/error" 2>&1; then
 echo 'build CLI accepted unsafe store' >&2; exit 1
fi
grep -Fq 'artifact store: root must be a private owned directory' "$TMP/error"
test ! -e "$TMP/remote"
chmod 700 "$TMP/store"
if REMOTE_LOG="$TMP/remote" SSH_BIN="$TMP/ssh" "$CLI" \
 artifact build hello --revision invalid --ip 10.20.0.11 --base "$TMP/no-base" \
 --sha256 "$(printf '%064d' 0)" --store "$TMP/store" --yes >"$TMP/error" 2>&1; then
 echo 'build CLI accepted absent trusted base' >&2; exit 1
fi
grep -Fq 'artifact build: base archive not found' "$TMP/error"
test ! -e "$TMP/remote"
if REMOTE_LOG="$TMP/remote" SSH_BIN="$TMP/ssh" "$CLI" \
 artifact build hello --revision invalid --ip 10.20.0.11 --base "$TMP/no-base" \
 --sha256 "$(printf '%064d' 0)" --store "$TMP/store" --reuse invalid-identity --yes >"$TMP/error" 2>&1; then
 echo 'reuse CLI accepted invalid artifact identity' >&2; exit 1
fi
grep -Fq 'artifact store: invalid identity' "$TMP/error"
test ! -e "$TMP/remote"
chmod 777 "$TMP/store"
for app in garage idp; do
 if REMOTE_LOG="$TMP/remote" SSH_BIN="$TMP/ssh" "$CLI" \
  artifact build "$app" --ip 10.20.0.11 --base "$TMP/no-base" \
  --sha256 "$(printf '%064d' 0)" --store "$TMP/store" --yes >"$TMP/error" 2>&1; then
  echo "FAIL - $app accepted unsafe store" >&2; exit 1
 fi
 if ! grep -Fq 'artifact store: root must be a private owned directory' "$TMP/error"; then
  echo "FAIL - $app no-revision build must select its executable strategy and guard the store" >&2
  exit 1
 fi
 test ! -e "$TMP/remote"
done
chmod 700 "$TMP/store"
for app in garage idp; do
 if REMOTE_LOG="$TMP/remote" SSH_BIN="$TMP/ssh" "$CLI" \
  artifact build "$app" --ip 10.20.0.11 --base "$TMP/no-base" \
  --sha256 "$(printf '%064d' 0)" --store "$TMP/store" --yes >"$TMP/error" 2>&1; then exit 1; fi
 grep -Fq 'artifact build: base archive not found' "$TMP/error"
 test ! -e "$TMP/remote"
done
printf 'fixture base\n' >"$TMP/base.txz"
printf 'fixture executable archive\n' >"$TMP/release.tar"
BASE_SHA=$(sha256sum "$TMP/base.txz" | cut -d ' ' -f 1)
export FIXTURE_ARCHIVE="$TMP/release.tar" REMOTE_LOG="$TMP/remote"
cat >"$TMP/ssh-success" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$REMOTE_LOG"
EOF
cat >"$TMP/rsync" <<'EOF'
#!/bin/sh
previous=''
source=''
for arg do source=$previous; previous=$arg; done
destination=$previous
case "$source" in
 */output/release.tar) cp "$FIXTURE_ARCHIVE" "$destination" ;;
 */output/release.sha256) sha256sum "$FIXTURE_ARCHIVE" | cut -d ' ' -f 1 >"$destination" ;;
 */output/target-abi) printf 'FreeBSD:15:amd64\n' >"$destination" ;;
 */output/dependencies)
  digest=$(printf 'public fixture package\n' | sha256sum | cut -d ' ' -f 1)
  for package in garage sqlite3 s5cmd; do printf '%s\t1.0\t%s\n' "$package" "$digest"; done >"$destination" ;;
 *) : ;;
esac
EOF
chmod +x "$TMP/ssh-success" "$TMP/rsync"
for app in garage idp; do
 rm -f "$TMP/remote"
 if ! SSH_BIN="$TMP/ssh-success" RSYNC_BIN="$TMP/rsync" "$CLI" \
  artifact build "$app" --ip 10.20.0.11 --base "$TMP/base.txz" --sha256 "$BASE_SHA" \
  --store "$TMP/store" --yes >"$TMP/result" 2>&1; then
  echo "FAIL - $app executable CLI must publish a verified typed-origin candidate" >&2; exit 1
 fi
 identity=$(awk '/^stored verified artifact:/ {print $4}' "$TMP/result")
 [[ "$identity" =~ ^[0-9a-f]{64}$ ]]
 cmp "$TMP/release.tar" "$TMP/store/$identity/release.tar"
 test -f "$TMP/store/$identity/manifest"
 kind=package; test "$app" != idp || kind=binary
 grep -Fq "SERAI_ARTIFACT_KIND=$kind" "$TMP/remote"
 grep -Fq 'artifact-executable-cleanup:' "$TMP/remote"
 rm -f "$TMP/remote"
 if ! SSH_BIN="$TMP/ssh" RSYNC_BIN="$TMP/rsync" "$CLI" \
  artifact build "$app" --ip 10.20.0.11 --base "$TMP/base.txz" --sha256 "$BASE_SHA" \
  --store "$TMP/store" --reuse "$identity" --yes >"$TMP/result" 2>&1; then
  echo "FAIL - $app explicit identity reuse must verify the typed-origin recipe locally" >&2; exit 1
 fi
 grep -Fq "reused verified artifact: $identity" "$TMP/result"
 test ! -e "$TMP/remote"
 if SSH_BIN="$TMP/ssh" RSYNC_BIN="$TMP/rsync" "$CLI" \
  artifact build "$app" --ip 10.20.0.11 --base "$TMP/base.txz" --sha256 "$BASE_SHA" \
  --store "$TMP/store" --reuse "$(printf '%064d' 0)" --yes >"$TMP/error" 2>&1; then exit 1; fi
 grep -Fq 'artifact store: cannot load entry' "$TMP/error"
 test ! -e "$TMP/remote"
done
echo 'ok - public source/executable build/store CLI verifies guards and typed-origin publication'
