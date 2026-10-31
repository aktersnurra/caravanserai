#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP"; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/source" "$TMP/bin"
cp "$ROOT/tests/stat-field" "$TMP/bin/"
chmod 700 "$TMP/source"
printf 'source fixture\n' >"$TMP/source/a.txt"
printf '#!/bin/sh\n' >"$TMP/source/z.sh"
printf 'opam definition\n' >"$TMP/source/compiler.5.6.0~alpha1.opam"
chmod 600 "$TMP/source/compiler.5.6.0~alpha1.opam"
chmod 600 "$TMP/source/a.txt"
chmod 700 "$TMP/source/z.sh"
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
[ "$1" = -f ] && [ "$#" = 3 ] || exit 99
if [ "${MODE_FAULT:-}" = fail ]; then exit 1; fi
if [ "${MODE_FAULT+x}" = x ]; then printf '%s\n' "$MODE_FAULT"; exit 0; fi
case $2 in
 %Lp) printf '%o\n' "$((0$("${0%/*}/stat-field" perm "$3") & 0777))" ;;
 %p) "${0%/*}/stat-field" mode "$3" ;;
 *) exit 99 ;;
esac
EOF
chmod +x "$TMP/bin/sha256" "$TMP/bin/stat"
commit="$(printf '%040d' 0)"
{
    printf 'infra-source-v1\t%s\n' "$commit"
    printf '600\t%s\ta.txt\n' "$(sha256sum "$TMP/source/a.txt" | awk '{print $1}')"
    printf '600\t%s\tcompiler.5.6.0~alpha1.opam\n' "$(sha256sum "$TMP/source/compiler.5.6.0~alpha1.opam" | awk '{print $1}')"
    printf '700\t%s\tz.sh\n' "$(sha256sum "$TMP/source/z.sh" | awk '{print $1}')"
} >"$TMP/inventory"
inventory_sha="$(sha256sum "$TMP/inventory" | awk '{print $1}')"
verify() {
    SHA256_BIN="$TMP/bin/sha256" STAT_BIN="$TMP/bin/stat" \
      sh "$ROOT/compute/apps/_lib/artifact_verify_source.sh" \
      "$TMP/source" "$TMP/inventory" "$inventory_sha"
}
fail() {
    if verify >"$TMP/log" 2>&1; then
        printf 'expected refusal: %s\n' "$1" >&2; exit 1
    fi
    if grep -q 'source fixture' "$TMP/log"; then
        echo 'source bytes leaked in error' >&2; exit 1
    fi
}
if ! verify; then
 echo 'FAIL - source verification must authenticate literal opam prerelease paths' >&2; exit 1
fi
# The same inventory verifies with this system's own sha256 and stat.
if [ "$(uname -s)" = Linux ]; then native="SHA256_KIND=linux SHA256_BIN=sha256sum STAT_KIND=linux"
else native="SHA256_KIND=freebsd SHA256_BIN=sha256 STAT_KIND=freebsd"; fi
if ! env $native STAT_BIN=stat \
 sh "$ROOT/compute/apps/_lib/artifact_verify_source.sh" \
 "$TMP/source" "$TMP/inventory" "$inventory_sha" >"$TMP/native-result" 2>&1; then
 echo "FAIL - native $(uname -s) source verification must accept the same verified inventory" >&2; exit 1
fi
for malformed in '' 8 41778 -1 000000040700 '1+1' fail; do
    MODE_FAULT="$malformed" fail "malformed/failed metadata $malformed"
done
# BSD gives new files their directory's group (wheel under /tmp) and refuses
# setgid on a file whose group the user is not in: give them the user's own.
chgrp "$(id -g)" "$TMP/source" "$TMP/source/a.txt" "$TMP/source/z.sh"
for entry in "$TMP/source" "$TMP/source/a.txt" "$TMP/source/z.sh"; do
    original=$("$ROOT/tests/stat-field" perm "$entry")
    for special in 1 2 4; do
        if ! chmod "0$special$original" "$entry" 2>/dev/null; then
            # Only root may set the sticky bit on a file on FreeBSD.
            [ "$special" = 1 ] && [ ! -d "$entry" ] && continue
            echo "FAIL - could not set special permission $special on $entry" >&2; exit 1
        fi
        fail "special permission $special$original $entry"
    done
    chmod "00$original" "$entry"
    verify
done
printf 'modified\n' >"$TMP/source/a.txt"
fail 'changed bytes'
printf 'source fixture\n' >"$TMP/source/a.txt"
rm "$TMP/source/a.txt"
fail 'missing file'
printf 'source fixture\n' >"$TMP/source/a.txt"
chmod 600 "$TMP/source/a.txt"
printf 'extra\n' >"$TMP/source/extra.txt"
chmod 600 "$TMP/source/extra.txt"
fail 'extra file'
rm "$TMP/source/extra.txt"
chmod 700 "$TMP/source/a.txt"
fail 'wrong mode'
chmod 600 "$TMP/source/a.txt"
ln -s a.txt "$TMP/source/link"
fail 'symlink'
rm "$TMP/source/link"
cp "$TMP/inventory" "$TMP/public-inventory"
printf 'synthetic environment backup\n' >"$TMP/source/.env~"
chmod 600 "$TMP/source/.env~"
{
    head -n 1 "$TMP/public-inventory"
    printf '600\t%s\t.env~\n' "$(sha256sum "$TMP/source/.env~" | awk '{print $1}')"
    tail -n +2 "$TMP/public-inventory"
} >"$TMP/inventory"
inventory_sha="$(sha256sum "$TMP/inventory" | awk '{print $1}')"
fail 'environment editor backup'
rm "$TMP/source/.env~"
cp "$TMP/public-inventory" "$TMP/inventory"
inventory_sha="$(sha256sum "$TMP/inventory" | awk '{print $1}')"
printf 'tamper\n' >>"$TMP/inventory"
fail 'changed inventory'
echo 'ok - source inventory verifier rejects changed, missing, extra and unsafe transferred entries'
