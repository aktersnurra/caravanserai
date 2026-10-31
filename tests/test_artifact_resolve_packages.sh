#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/serai/_build"
TMP="$(mktemp -d "$ROOT/serai/_build/resolver-test.XXXXXXXX")"
trap 'rm -rf "$TMP"' EXIT
export TMPDIR="$TMP/tmp"
mkdir -m 700 "$TMPDIR"
mkdir "$TMP/bin"
cp "$ROOT/tests/stat-field" "$TMP/bin/"
cat >"$TMP/bin/pkg" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
    fetch)
        [ "$2" = -y ] && [ "$3" = -d ] && [ "$4" = -o ] || exit 1
        layout=${PKG_LAYOUT:-Hashed}
        mkdir -p "$5/$layout"
        printf 'resolved pkg bytes\n' >"$5/$layout/pkg.pkg"
        printf 'resolved compiler bytes\n' >"$5/$layout/compiler.pkg"
        printf 'resolved transitive bytes\n' >"$5/$layout/library.pkg"
        [ "${DUPLICATE_ARCHIVE:-0}" = 0 ] || cp "$5/$layout/compiler.pkg" "$5/$layout/duplicate.pkg"
        # Native pkg fetch sets public modes even under a private umask.
        chmod 755 "$5/$layout"
        chmod 644 "$5/$layout/"*.pkg
        ;;
    query)
        if [ "$2" = -F ]; then
            case "$3" in
                */pkg.pkg) printf 'pkg\t2.5.1\n' ;;
                */compiler.pkg|*/duplicate.pkg) printf 'compiler\t1.0_1,1\n' ;;
                */library.pkg) printf 'library\t2.0\n' ;;
                *) exit 1 ;;
            esac
        else
            case "$3" in
                pkg) printf 'pkg\t2.5.1\n' ;;
                compiler) printf 'compiler\t1.0_1,1\n' ;;
                library) [ "${BAD_INSTALLED:-0}" != 1 ] || { printf 'library\t3.0\n'; exit 0; }; printf 'library\t2.0\n' ;;
                *) exit 1 ;;
            esac
        fi
        ;;
    add)
        [ "$2" = -f ] && [ "$#" = 5 ] || exit 1
        [ "${FAIL_ADD:-0}" != 1 ] || exit 1
        # Model public directories created by a package under the inherited mask.
        public="$(dirname "$COMMAND_LOG")/public"
        mkdir -p "$public"
        [ "$("${0%/*}/stat-field" perm "$public")" = 755 ] || {
            echo 'public package directory must be searchable by the builder' >&2; exit 1;
        }
        if [ "${TAMPER_ARCHIVE:-0}" = 1 ]; then printf 'changed\n' >>"$3"; fi
        ;;
    *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
chmod +x "$TMP/bin/"*
run() {
    PKG_BIN="$TMP/bin/pkg" SHA256_BIN="$TMP/bin/sha256" COMMAND_LOG="$TMP/$1/commands" \
    PKG_LAYOUT="${PKG_LAYOUT:-Hashed}" BAD_INSTALLED="${BAD_INSTALLED:-0}" FAIL_ADD="${FAIL_ADD:-0}" TAMPER_ARCHIVE="${TAMPER_ARCHIVE:-0}" DUPLICATE_ARCHIVE="${DUPLICATE_ARCHIVE:-0}" \
    sh "$ROOT/compute/apps/_lib/artifact_resolve_packages.sh" "$TMP/$1/cache" "$TMP/$1/dependencies" compiler
}
mkdir "$TMP/good"
run good
printf 'library\t2.0\t%s\n' "$(sha256sum "$TMP/good/cache/Hashed/library.pkg" | awk '{print $1}')" >"$TMP/expected"
grep -Fxq "$(<"$TMP/expected")" "$TMP/good/dependencies"
test "$(wc -l <"$TMP/good/dependencies")" -eq 3
grep -q '^fetch -y -d -o .* pkg compiler$' "$TMP/good/commands"
grep -q '^add -f /' "$TMP/good/commands"
test "$("$ROOT/tests/stat-field" perm "$TMP/good/cache")" = 700
test "$("$ROOT/tests/stat-field" perm "$TMP/good/cache/Hashed")" = 700
test "$("$ROOT/tests/stat-field" perm "$TMP/good/dependencies")" = 600
test "$("$ROOT/tests/stat-field" perm "$TMP/good/cache/Hashed/library.pkg")" = 600
test "$("$ROOT/tests/stat-field" perm "$TMP/good/public")" = 755
# Full tuples are the original resolver output; no synthetic package checksum.
for tuple in 'compiler 1.0_1,1' 'library 2.0' 'pkg 2.5.1'; do
    read -r name version <<<"$tuple"
    printf '%s\t%s\t%s\n' "$name" "$version" "$(sha256sum "$TMP/good/cache/Hashed/$name.pkg" | cut -d ' ' -f1)"
done >"$TMP/full-expected"
cmp "$TMP/full-expected" "$TMP/good/dependencies"
mkdir "$TMP/all-layout"
PKG_LAYOUT=All run all-layout
test "$(wc -l <"$TMP/all-layout/dependencies")" -eq 3
test "$("$ROOT/tests/stat-field" perm "$TMP/all-layout/cache/All")" = 700
test "$("$ROOT/tests/stat-field" perm "$TMP/all-layout/cache/All/library.pkg")" = 600
for failure in BAD_INSTALLED FAIL_ADD TAMPER_ARCHIVE DUPLICATE_ARCHIVE; do
    mkdir "$TMP/$failure"
    if ( export "$failure=1"; run "$failure" ) >"$TMP/result" 2>&1; then
        echo "unexpected success: $failure" >&2; exit 1
    fi
    test ! -e "$TMP/$failure/dependencies"
    if [[ $failure == DUPLICATE_ARCHIVE ]]; then ! grep -q '^add ' "$TMP/$failure/commands"; fi
done
if run good >"$TMP/result" 2>&1; then echo 'existing inventory overwritten' >&2; exit 1; fi
echo 'ok - archive hashes attest the installed resolved package closure'
