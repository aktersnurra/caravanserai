#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$ROOT/serai/_build/prepared-builder"
TMP="$(mktemp -d "$ROOT/serai/_build/prepared-builder/cold-jail-XXXXXXXX")"
trap 'chmod -R u+rwx "$TMP"; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/jails" "$TMP/source"
printf 'cache fixture\n' >"$TMP/cache-fixture"
cat >"$TMP/bin/time" <<'EOF'
#!/bin/sh
[ "$1" = -p ] || exit 99
shift
status=0
"$@" || status=$?
printf 'real 162.606
user 0.1
sys 0.2
' >&2
exit "$status"
EOF
chmod +x "$TMP/bin/time"
export TIME_BIN="$TMP/bin/time"

chmod 700 "$TMP/jails" "$TMP/source"
mkdir -p "$TMP/base/bin" "$TMP/base/rescue" "$TMP/base/libexec" "$TMP/base/var/db/pkg"
chmod 755 "$TMP/base/var/db/pkg"
printf '#!/bin/sh\n' >"$TMP/base/bin/sh"
printf '#!/bin/sh\n' >"$TMP/base/rescue/sh"
printf 'loader fixture\n' >"$TMP/base/libexec/ld-elf.so.1"
chmod 755 "$TMP/base/bin/sh" "$TMP/base/rescue/sh" "$TMP/base/libexec/ld-elf.so.1"
tar -cf "$TMP/base.tar" -C "$TMP/base" .
printf 'committed source\n' >"$TMP/source/main.txt"
chmod 600 "$TMP/source/main.txt"
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
cat >"$TMP/bin/stat" <<'EOF'
#!/bin/sh
[ "$1" = -f ] || exit 1
case "$2" in
    %Lp) printf '%o\n' "$((0x$(/usr/bin/stat -c %f "$3") & 0777))" ;;
    %p) printf '%o\n' "0x$(/usr/bin/stat -c %f "$3")" ;;
    %u) printf '12345\n' ;;
    *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/chown" <<'EOF'
#!/bin/sh
printf 'chown %s\n' "$*" >>"$COMMAND_LOG"
[ "$1" = -R ] && [ "$2" = 12345 ] || exit 1
[ "$(/usr/bin/stat -c %a "$3")" = 700 ] || exit 1
[ "${FAIL_PUBLISH_OWNER:-0}" != 1 ] || exit 1
EOF
cat >"$TMP/bin/ifconfig" <<'EOF'
#!/bin/sh
[ "$1" = lo1 ] || exit 2
if [ "$#" -eq 1 ]; then
    if [ "${IP_IN_USE:-0}" = 1 ] || [ -f "$ALIAS_STATE" ]; then
        printf '    inet %s netmask 0xffffffff\n' "$FIXTURE_IP"
    fi
elif [ "$#" -eq 4 ] && [ "$2" = inet ] && [ "$3" = "$FIXTURE_IP" ] && [ "$4" = -alias ]; then
    printf 'ifconfig %s\n' "$*" >>"$COMMAND_LOG"
    [ "${FAIL_ALIAS:-0}" != 1 ] || exit 1
    rm -f "$ALIAS_STATE"
else
    exit 2
fi
EOF
cat >"$TMP/bin/jls" <<'EOF'
#!/bin/sh
if [ "$1" = -j ]; then
    [ "$2" = "$FIXTURE_JAIL" ] && [ "$3" = jid ] && [ "$4" = path ] || exit 2
    [ -f "$JAIL_STATE" ] || exit 1
    printf '42 %s/%s\n' "$JAILS_DIR" "$FIXTURE_JAIL"
    exit 0
fi
[ "$1" = name ] || exit 2
[ "${JLS_EXISTS:-0}" = 1 ] && printf 'infra-build-drill-test\n'
[ -f "$JAIL_STATE" ] && cat "$JAIL_STATE"
exit 0
EOF
cat >"$TMP/bin/jail" <<'EOF'
#!/bin/sh
printf 'jail %s\n' "$*" >>"$COMMAND_LOG"
if [ "$1" = -c ]; then
    name=${2#name=}
    [ -s "$JAILS_DIR/$name/etc/resolv.conf" ] && [ -d "$JAILS_DIR/$name/dev" ] || exit 1
    if ! grep -Fxq 'nameserver 1.1.1.1' "$JAILS_DIR/$name/etc/resolv.conf"; then
        echo 'disposable jail did not receive approved test-only DNS' >&2; exit 1
    fi
    [ "$("$STAT_BIN" -f %Lp "$JAILS_DIR/$name/etc/resolv.conf")" = 644 ] || exit 1
fi
if [ "$1" = -c ]; then
    [ "${FAIL_CREATE:-0}" != 1 ] || exit 1
    printf '%s\n' "${2#name=}" >"$JAIL_STATE"
    : >"$MOUNT_STATE"
    : >"$ALIAS_STATE"
fi
if [ "$1" = -r ]; then
    [ "${FAIL_REMOVE:-0}" != 1 ] || exit 1
    [ "${REMOVE_STUCK:-0}" = 1 ] || rm -f "$JAIL_STATE"
fi
EOF
cat >"$TMP/bin/jexec" <<'EOF'
#!/bin/sh
printf 'jexec %s\n' "$*" >>"$COMMAND_LOG"
if [ "${2:-}" = sh ] || [ "${2:-}" = pw ] || [ "${2:-}" = chown ] ||
   [ "${2:-}" = /bin/sh ] ||
   { [ "${1:-}" = -U ] && { [ "${4:-}" = sh ] || [ "${4:-}" = /bin/sh ]; }; }; then
    echo 'jexec fixture: direct shell launch unavailable' >&2; exit 1
fi
if [ "${2:-}" = /rescue/sh ] && [ "${FAIL_SHELL_PROBE:-0}" = 1 ]; then
    echo 'jexec fixture: jail shell unavailable' >&2; exit 1
fi
if [ "$2" = pkg ] && [ "$3" = bootstrap ]; then
    root="$JAILS_DIR/$1"
    mkdir -p "$root/usr/local"
    chmod 755 "$root/usr" "$root/usr/local"
    # pkg bootstrap creates sbin under its inherited umask, not an explicit 0755.
    mkdir "$root/usr/local/sbin"
    if [ "$(/usr/bin/stat -c %a "$root/usr/local/sbin")" != 755 ]; then
        echo 'pkg bootstrap left public sbin inaccessible to builder' >&2; exit 1
    fi
fi
if { [ "$2" = pkg ] && [ "$3" = install ]; } || [ "$3" = /var/infra-build/artifact_resolve_packages.sh ]; then
    [ "${FAIL_PKG:-0}" != 1 ] || exit 1
    if [ "${DROP_RESCUE_AFTER_PKG:-0}" = 1 ]; then rm -f "$JAILS_DIR/$1/rescue/sh"; fi
fi
if [ "$3" = /var/infra-build/artifact_resolve_packages.sh ]; then
    printf 'compiler\t1.0\t%064d\n' 0 >"$JAILS_DIR/$1/var/infra-build/dependencies"
    [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$1/var/infra-build")" = 700 ] || exit 1
    [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$1/var/infra-build/dependencies")" = 600 ] || exit 1
    if [ "${BLOCK_PKG_SEARCH:-0}" = 1 ]; then chmod 700 "$JAILS_DIR/$1/usr/local/sbin"; fi
fi
if [ "${2:-}" = sha256 ]; then printf '%064d\n' 1; exit 0; fi
if [ "$2" = pkg ] && [ "$3" = config ] && [ "$4" = abi ]; then
    if [ "${BAD_ABI:-0}" = 1 ]; then printf 'untrusted ABI\n'; else printf 'FreeBSD:14:amd64\n'; fi
    exit 0
fi
if [ "${EXPECT_RUNTIME:-}" = 28 ] && [ "${2:-}" = /rescue/sh ] && [ "${3:-}" = -c ]; then
    case "${4:-}" in *'for binary'*)
        [ "${6:-}" = 28 ] || { echo 'runtime link command ignored declared OTP28' >&2; exit 1; } ;;
    esac
fi
if [ "$1" = -U ] && [ "${4:-}" = /rescue/sh ] && [ "${5:-}" = -c ]; then
    case "${6:-}" in
        *'tar -cf /work/cache.tar'*)
            [ "${FAIL_CACHE_SAVE:-0}" != 1 ] || exit 1
            printf 'cache fixture\n' >"$JAILS_DIR/$3/work/cache.tar"; exit 0 ;;
        *'tar -xf /work/cache.tar'*)
            [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$3")" = 755 ] || exit 1
            cmp -s "$JAILS_DIR/$3/work/cache.tar" "$CACHE_FIXTURE" || exit 1
            rm "$JAILS_DIR/$3/work/cache.tar"; exit 0 ;;
    esac
fi
if [ "$1" = -U ]; then
    [ "$2" = builder ] || exit 1
    [ "$("$STAT_BIN" -f %Lp "$JAILS_DIR")" = 700 ] || exit 1
    if [ "$("$STAT_BIN" -f %Lp "$JAILS_DIR/$3")" != 755 ]; then
        echo 'jexec fixture: builder cannot traverse jail root' >&2; exit 1
    fi
    [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$3/work")" = 700 ] || exit 1
    [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$3/work/source")" = 700 ] || exit 1
    if [ "${4:-}" = /usr/local/sbin/pkg ]; then
        [ "${5:-}" = query ] && [ "${6:-}" = -a ] || exit 1
        [ "$(/usr/bin/stat -c %a "$JAILS_DIR/$3/usr/local/sbin")" = 755 ] || {
            echo 'jexec fixture: builder cannot search pkg directory' >&2; exit 1;
        }
        printf 'compiler 1.0\n'
        exit 0
    fi
    if [ "${16:-}" = /work/web ] && [ ! -f "$JAILS_DIR/$3/work/web/index.html" ]; then
        echo 'jexec fixture: web bundle not in the jail' >&2; exit 1
    fi
    if [ "${SERAI_ARTIFACT_KIND:-}" = ocaml ] && [ "${SERAI_OPAM_ROOT:-}" != /work/opam ]; then
        echo 'jexec fixture: OCaml worker not given the kept opam root' >&2; exit 1
    fi
    if [ "${SERAI_ARTIFACT_KIND:-}" = ocaml ] && [ "${11:-}" != bin/meals.exe ]; then
        echo "jexec fixture: unknown application Dune target ${11:-missing}" >&2; exit 1
    fi
    [ "${FAIL_BUILD:-0}" != 1 ] || exit 1
    if [ "${INTERRUPT_BUILD:-0}" = 1 ]; then kill -INT "$PPID"; exit 130; fi
    mkdir -p "$JAILS_DIR/$3/work/output"
    printf 'archive fixture\n' >"$JAILS_DIR/$3/work/output/release.tar"
    sha256sum "$JAILS_DIR/$3/work/output/release.tar" | awk '{print $1}' >"$JAILS_DIR/$3/work/output/release.sha256"
    if [ "${BAD_CHECKSUM:-0}" = 1 ]; then printf '%064d\n' 0 >"$JAILS_DIR/$3/work/output/release.sha256"; fi
fi
EOF
cat >"$TMP/bin/mount" <<'EOF'
#!/bin/sh
if [ -f "$MOUNT_STATE" ]; then
    printf 'devfs on %s/dev (devfs)\n' "$JAILS_DIR/$FIXTURE_JAIL"
fi
EOF
cat >"$TMP/bin/umount" <<'EOF'
#!/bin/sh
printf 'umount %s\n' "$*" >>"$COMMAND_LOG"
[ "$1" = "$JAILS_DIR/$FIXTURE_JAIL/dev" ] || exit 1
[ "${FAIL_UMOUNT:-0}" != 1 ] || exit 1
rm -f "$MOUNT_STATE"
EOF
cat >"$TMP/bin/chflags" <<'EOF'
#!/bin/sh
printf 'chflags %s\n' "$*" >>"$COMMAND_LOG"
[ "$1" = -R ] && [ "$2" = noschg,nouchg ] || exit 1
[ ! -f "$MOUNT_STATE" ] && [ ! -f "$ALIAS_STATE" ] || exit 1
[ "${FAIL_CHFLAGS:-0}" != 1 ] || exit 1
EOF
chmod +x "$TMP/bin/"*
commit="$(printf '%040d' 0)"
printf 'infra-source-v1\t%s\n600\t%s\tmain.txt\n' \
    "$commit" "$(sha256sum "$TMP/source/main.txt" | awk '{print $1}')" >"$TMP/inventory"
base_sha="$(sha256sum "$TMP/base.tar" | awk '{print $1}')"
inv_sha="$(sha256sum "$TMP/inventory" | awk '{print $1}')"
cold_native_exec() {
    if [ "${TEST_CLOSED_STDERR:-0}" != 1 ]; then "$@"; return $?; fi
    python3 - "$@" <<'PYCLOSED'
import os,subprocess,sys
reader,writer=os.pipe();os.close(reader)
try:result=subprocess.run(sys.argv[1:],stderr=writer,timeout=30)
finally:os.close(writer)
sys.exit(result.returncode if result.returncode>=0 else 128-result.returncode)
PYCLOSED
}
run() {
    local source="${SOURCE_DIR:-$TMP/source}" inventory="${SOURCE_INVENTORY:-$TMP/inventory}" digest="${SOURCE_DIGEST:-$inv_sha}"
    local packages=("${ERLANG_PACKAGE:-erlang-runtime29}" elixir-devel sqlite3 gmake)
    case "${SERAI_ARTIFACT_KIND:-phoenix}" in
        ocaml) packages=(ocaml-opam bash gmake pkgconf sqlite3 gmp ca_root_nss git rsync) ;;
        package) source=-; inventory=-; digest=-; packages=(garage) ;;
        binary) source=-; inventory=-; digest=-; packages=(sqlite3 s5cmd) ;;
    esac
    SERAI_LOCK_HELD="${SERAI_LOCK_HELD:-1}" FAIL_BUILD="${FAIL_BUILD:-0}" FAIL_REMOVE="${FAIL_REMOVE:-0}" FAIL_CREATE="${FAIL_CREATE:-0}" REMOVE_STUCK="${REMOVE_STUCK:-0}" FAIL_PKG="${FAIL_PKG:-0}" FAIL_UMOUNT="${FAIL_UMOUNT:-0}" FAIL_ALIAS="${FAIL_ALIAS:-0}" FAIL_CHFLAGS="${FAIL_CHFLAGS:-0}" FAIL_PUBLISH_OWNER="${FAIL_PUBLISH_OWNER:-0}" FAIL_SHELL_PROBE="${FAIL_SHELL_PROBE:-0}" DROP_RESCUE_AFTER_PKG="${DROP_RESCUE_AFTER_PKG:-0}" BAD_CHECKSUM="${BAD_CHECKSUM:-0}" BAD_ABI="${BAD_ABI:-0}" \
    FIXTURE_JAIL="$1" FIXTURE_IP="$2" JAILS_DIR="$TMP/jails" BUILD_CACHE_DIR="${BUILD_CACHE_DIR:-$TMP/cache}" CACHE_FIXTURE="$TMP/cache-fixture" FAIL_CACHE_SAVE="${FAIL_CACHE_SAVE:-0}" SHA256_BIN="$TMP/bin/sha256" STAT_BIN="$TMP/bin/stat" \
    JAIL_BIN="$TMP/bin/jail" JEXEC_BIN="$TMP/bin/jexec" JLS_BIN="$TMP/bin/jls" IFCONFIG_BIN="$TMP/bin/ifconfig" MOUNT_BIN="$TMP/bin/mount" UMOUNT_BIN="$TMP/bin/umount" CHFLAGS_BIN="$TMP/bin/chflags" CHOWN_BIN="$TMP/bin/chown" JAIL_STATE="$TMP/jail-state" MOUNT_STATE="$TMP/mount-state" ALIAS_STATE="$TMP/alias-state" COMMAND_LOG="$TMP/commands" \
    cold_native_exec sh "$ROOT/compute/apps/_lib/artifact_build_jail.sh" \
      "$1" "$2" "$TMP/base.tar" "$3" "$source" "$inventory" \
      "$digest" "${RELEASE_NAME:-drill_trainer}" "$4" "${packages[@]}"
}
# Exit 3: the build failed or was refused and nothing it created remains, so
# the controller may release the lock. Exit 1: teardown incomplete, inspect.
expect_status() {
    local want=$1 label=$2; shift 2
    local status=0
    "$@" >"$TMP/result" 2>&1 || status=$?
    [ "$status" = "$want" ] || { echo "FAIL - $label exited $status, expected $want" >&2; tail -5 "$TMP/result" >&2; exit 1; }
}
refuse_before_jail() {
    : >"$TMP/commands"
    local status=0
    run "$1" "$2" "$3" "$4" >"$TMP/result" 2>&1 || status=$?
    if [ "$status" != 3 ]; then
        echo "refusal $5 exited $status, expected 3" >&2; exit 1
    fi
    if grep -q 'jail -c' "$TMP/commands"; then
        echo "jail was started before preflight: $5" >&2; exit 1
    fi
}
for special in 1 2 4; do
    chmod "0${special}700" "$TMP/jails"
    refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/special-mode" special-mode
    [ ! -e "$TMP/jails/infra-build-drill-test" ] && [ ! -e "$TMP/special-mode" ]
    [ ! -s "$TMP/commands" ] || { echo 'effects after permission refusal' >&2; exit 1; }
done
chmod 00700 "$TMP/jails"
SERAI_LOCK_HELD=0 refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/no-lock" lock
refuse_before_jail bad-name 10.40.0.200 "$base_sha" "$TMP/bad-name" name
refuse_before_jail infra-build-drill-test 'bad-ip' "$base_sha" "$TMP/bad-ip" ip
for ip in 10.40.0.256 10.20.0.01 10.20.0 10.20..2 .10.20.0.2 10.20.0.2.3 10.20.0.2a; do
    refuse_before_jail infra-build-drill-test "$ip" "$base_sha" "$TMP/bad-ip" "ip $ip"
done
refuse_before_jail infra-build-drill-test 10.40.0.200 "$(printf '%064d' 0)" "$TMP/bad-digest" checksum
mkdir "$TMP/occupied"
refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/occupied" output
JLS_EXISTS=1 refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/existing-jail" existing-jail
IP_IN_USE=1 refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/occupied-ip" occupied-ip
printf 'tampered\n' >"$TMP/source/main.txt"
refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/tampered" source-integrity
printf 'committed source\n' >"$TMP/source/main.txt"
: >"$TMP/commands"
if ! run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/dns-checked" >"$TMP/result" 2>&1; then
    grep 'disposable jail did not receive approved test-only DNS' "$TMP/result" || tail -5 "$TMP/result"
    exit 1
fi
test -f "$TMP/dns-checked/release.tar"
grep -F "chown -R 12345 $TMP/dns-checked.tmp." "$TMP/commands" >/dev/null || {
    echo 'private output was not handed to the staging owner' >&2; exit 1
}
test -f "$TMP/dns-checked/dependencies" || { echo 'missing resolved package archive inventory' >&2; exit 1; }
test "$(grep -c '^build jail: root rescue/sh mode=' "$TMP/result")" -eq 2
if [ "$(grep -c '^jexec infra-build-drill-test /rescue/sh -c[[:space:]]*$' "$TMP/commands")" -ne 2 ]; then
    echo 'missing pre/post-package shell probes' >&2; exit 1
fi
# The host's jail subnet is the declaration's: serai checks the address is on
# it, the script that it is one host address.
if ! run infra-build-drill-test 10.20.0.200 "$base_sha" "$TMP/other-subnet" >"$TMP/result" 2>&1; then
    echo 'build refused an address outside 10.40.0.0/24' >&2; tail -5 "$TMP/result" >&2; exit 1
fi
test -f "$TMP/other-subnet/release.tar"
if ! EXPECT_RUNTIME=28 ERLANG_PACKAGE=erlang-runtime28 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/otp28" >"$TMP/otp28-result" 2>&1; then
    echo 'FAIL - runtime links must use the declared OTP major' >&2; tail -5 "$TMP/otp28-result"; exit 1
fi
test -f "$TMP/otp28/release.tar"
mkdir -m 700 "$TMP/repository"
printf 'opam-version: "2.0"\n' >"$TMP/repository/repo"
chmod 600 "$TMP/repository/repo"
printf 'infra-source-v1\t%s\n600\t%s\trepo\n' "$commit" \
    "$(sha256sum "$TMP/repository/repo" | awk '{print $1}')" >"$TMP/repository-inventory"
repo_sha="$(sha256sum "$TMP/repository-inventory" | awk '{print $1}')"
: >"$TMP/commands"
if ! SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$repo_sha" \
 run infra-build-meals-test 10.40.0.200 "$base_sha" "$TMP/meals-candidate" >"$TMP/meals-result" 2>&1; then
    echo 'FAIL - OCaml build jail must verify source/repository and run the declared compiler without OTP' >&2
    tail -5 "$TMP/meals-result"; exit 1
fi
test -f "$TMP/meals-candidate/release.tar"
grep -Fq '/work/worker.sh /work/source . bin/meals.exe meals /work/output ocaml-base-compiler.5.5.1 /work/repository' "$TMP/commands"
if grep -Fq 'for binary' "$TMP/commands"; then echo 'FAIL - OCaml must not install OTP links' >&2; exit 1; fi
if grep -Fq '/work/web' "$TMP/commands"; then echo 'FAIL - no web bundle declared, none passed' >&2; exit 1; fi
# A controller-built web bundle is copied into the jail and named to the worker.
mkdir -m 700 "$TMP/web"
printf '<html>\n' >"$TMP/web/index.html"
: >"$TMP/commands"
if ! SERAI_WEB_BUNDLE="$TMP/web" SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$repo_sha" \
 run infra-build-meals-test 10.40.0.200 "$base_sha" "$TMP/meals-web" >"$TMP/meals-web-result" 2>&1; then
    echo 'FAIL - OCaml build jail must carry the web bundle to the worker' >&2
    tail -5 "$TMP/meals-web-result"; exit 1
fi
grep -Fq '/work/repository /work/web' "$TMP/commands"
ln -s "$TMP/web" "$TMP/web-link"
SERAI_WEB_BUNDLE="$TMP/web-link" SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$repo_sha" \
 refuse_before_jail infra-build-meals-test 10.40.0.200 "$base_sha" "$TMP/meals-web-link" web-bundle-link
SERAI_WEB_BUNDLE="$TMP/web" refuse_before_jail infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/phoenix-web" web-bundle-phoenix
: >"$TMP/commands"
if ! SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$repo_sha" \
 run infra-build-meals-isolated 10.40.0.200 "$base_sha" "$TMP/meals-isolated" >"$TMP/meals-isolated-result" 2>&1; then
    echo 'FAIL - isolated workload must compile the actual meals Dune target' >&2
    tail -5 "$TMP/meals-isolated-result"; exit 1
fi
test -f "$TMP/meals-isolated/release.tar"
grep -Fq '/work/worker.sh /work/source . bin/meals.exe meals /work/output' "$TMP/commands"
pkg_line=$(grep -n 'jexec -U builder infra-build-meals-isolated /usr/local/sbin/pkg query -a' "$TMP/commands" | cut -d: -f1)
worker_line=$(grep -n 'jexec -U builder infra-build-meals-isolated /rescue/sh.* /work/worker.sh' "$TMP/commands" | cut -d: -f1)
test -n "$pkg_line" && test "$pkg_line" -lt "$worker_line"
: >"$TMP/commands"
if BLOCK_PKG_SEARCH=1 SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$repo_sha" \
 run infra-build-meals-blocked 10.40.0.200 "$base_sha" "$TMP/meals-blocked" >"$TMP/meals-blocked-result" 2>&1; then
    echo 'FAIL - inaccessible pkg directory was accepted' >&2; exit 1
fi
grep -Fq 'builder cannot search pkg directory' "$TMP/meals-blocked-result"
if grep -Fq '/work/worker.sh' "$TMP/commands"; then
    echo 'FAIL - worker started after failed pkg preflight' >&2; exit 1
fi
test ! -e "$TMP/meals-blocked"
test ! -e "$TMP/jails/infra-build-meals-blocked"
test ! -e "$TMP/jail-state"
test ! -e "$TMP/mount-state"
test ! -e "$TMP/alias-state"
SERAI_ARTIFACT_KIND=ocaml SERAI_OCAML_COMPILER=ocaml-base-compiler.5.5.1 \
 SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
 SERAI_OPAM_INVENTORY_SHA256="$(printf '%064d' 0)" \
 refuse_before_jail infra-build-meals-test 10.40.0.200 "$base_sha" "$TMP/bad-repo" repository-integrity
: >"$TMP/commands"
if ! SERAI_ARTIFACT_KIND=package RELEASE_NAME=garage run infra-build-garage-test 10.40.0.200 "$base_sha" "$TMP/garage-candidate" >"$TMP/garage-result" 2>&1; then
    echo 'FAIL - package jail must use verified-file worker without a source checkout or OTP' >&2
    tail -5 "$TMP/garage-result"; exit 1
fi
grep -Fq '/work/worker.sh verified-file /usr/local/bin/garage' "$TMP/commands"
if grep -Fq 'for binary' "$TMP/commands"; then echo 'FAIL - package jail must not link Erlang' >&2; exit 1; fi
test -f "$TMP/garage-candidate/release.tar"
: >"$TMP/commands"
if ! SERAI_ARTIFACT_KIND=binary RELEASE_NAME=idp SERAI_EXECUTABLE_SOURCE=https://example.org/idp \
    SERAI_EXECUTABLE_SHA256="$(printf '%064d' 1)" run infra-build-idp-test 10.40.0.200 "$base_sha" "$TMP/idp-candidate" >"$TMP/idp-result" 2>&1; then
    echo 'FAIL - pinned binary jail must pass its URL/digest to the unprivileged worker' >&2
    tail -5 "$TMP/idp-result"; exit 1
fi
grep -Fq '/work/worker.sh download https://example.org/idp' "$TMP/commands"
test -f "$TMP/idp-candidate/release.tar"
if ! RELEASE_NAME=board run infra-build-board-test 10.40.0.200 "$base_sha" "$TMP/board-candidate" >"$TMP/board-result" 2>&1; then
    echo 'declared Board Phoenix adapter was refused' >&2; tail -5 "$TMP/board-result"; exit 1
fi
test -f "$TMP/board-candidate/release.tar"
test ! -e "$TMP/jails/infra-build-board-test"
if FAIL_PUBLISH_OWNER=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/owner-failed" >"$TMP/owner-result" 2>&1; then
    echo 'publication ignored failed owner handoff' >&2; exit 1
fi
test ! -e "$TMP/owner-failed"
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/jail-state" && test ! -e "$TMP/mount-state" && test ! -e "$TMP/alias-state"
: >"$TMP/commands"
if FAIL_SHELL_PROBE=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/probe-failed" >"$TMP/result" 2>&1; then
    echo 'unavailable jail shell was ignored' >&2; exit 1
fi
grep -q '^jexec infra-build-drill-test /rescue/sh -c' "$TMP/commands"
if grep -q '^jexec infra-build-drill-test pkg' "$TMP/commands"; then
    echo 'packages installed before validating the jail shell' >&2; exit 1
fi
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/probe-failed"
grep -q '^build jail: live before-packages$' "$TMP/result" || { echo 'missing live-jail diagnostics' >&2; exit 1; }
grep -Fq "42 $TMP/jails/infra-build-drill-test" "$TMP/result"
grep -q '^build jail: live shell-failed$' "$TMP/result"
grep -Fq "devfs on $TMP/jails/infra-build-drill-test/dev (devfs)" "$TMP/result"
: >"$TMP/commands"
if FAIL_CREATE=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/create-failed" >"$TMP/result" 2>&1; then
    echo 'jail creation failure was ignored' >&2; exit 1
fi
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/create-failed"
: >"$TMP/commands"
FAIL_BUILD=1 expect_status 3 'cleaned-up worker failure' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/failed"
grep -q 'jail -r infra-build-drill-test' "$TMP/commands"
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/failed"
: >"$TMP/commands"
FAIL_PKG=1 expect_status 3 'cleaned-up package failure' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/pkg-failed"
test ! -e "$TMP/jails/infra-build-drill-test"
if [ -e "$TMP/mount-state" ] || [ -e "$TMP/alias-state" ]; then
    echo 'jail cleanup left devfs or IP alias after package failure' >&2; exit 1
fi
test ! -e "$TMP/pkg-failed"
grep -q 'umount .*/dev' "$TMP/commands"
grep -q 'chflags -R noschg,nouchg' "$TMP/commands"
: >"$TMP/commands"
if DROP_RESCUE_AFTER_PKG=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/lost-rescue" >"$TMP/result" 2>&1; then
    echo 'missing rescue shell after pkg install was ignored' >&2; exit 1
fi
grep -q 'build jail: missing executable rescue/sh' "$TMP/result"
test ! -e "$TMP/lost-rescue"
test ! -e "$TMP/jails/infra-build-drill-test"
: >"$TMP/commands"
FAIL_UMOUNT=1 expect_status 1 'failed unmount' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/umount-failed"
test -d "$TMP/jails/infra-build-drill-test"
test -e "$TMP/mount-state"
test ! -e "$TMP/umount-failed"
rm -rf "$TMP/jails/infra-build-drill-test"
rm -f "$TMP/mount-state" "$TMP/alias-state" "$TMP/jail-state"
: >"$TMP/commands"
FAIL_ALIAS=1 expect_status 1 'failed alias removal' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/alias-failed"
test -d "$TMP/jails/infra-build-drill-test"
test -e "$TMP/alias-state"
test ! -e "$TMP/alias-failed"
rm -rf "$TMP/jails/infra-build-drill-test"
rm -f "$TMP/mount-state" "$TMP/alias-state" "$TMP/jail-state"
: >"$TMP/commands"
FAIL_CHFLAGS=1 expect_status 1 'failed flag clearing' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/chflags-failed"
test -d "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/mount-state"
test ! -e "$TMP/alias-state"
test ! -e "$TMP/chflags-failed"
rm -rf "$TMP/jails/infra-build-drill-test"
rm -f "$TMP/jail-state"
: >"$TMP/commands"
if BAD_ABI=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/abi-failed" >"$TMP/result" 2>&1; then
    echo 'invalid builder ABI was ignored' >&2; exit 1
fi
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/abi-failed"
: >"$TMP/commands"
if BAD_CHECKSUM=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/checksum-failed" >"$TMP/result" 2>&1; then
    echo 'archive checksum mismatch was ignored' >&2; exit 1
fi
test ! -e "$TMP/jails/infra-build-drill-test"
test ! -e "$TMP/checksum-failed"
: >"$TMP/commands"
FAIL_REMOVE=1 expect_status 1 'failed jail removal' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/cleanup-failed"
test -d "$TMP/jails/infra-build-drill-test"
test -e "$TMP/mount-state"
test -e "$TMP/alias-state"
test ! -e "$TMP/cleanup-failed"
# Fixture simulates a manual recovery of the stopped jail root.
rm -rf "$TMP/jails/infra-build-drill-test"
rm -f "$TMP/jail-state" "$TMP/mount-state" "$TMP/alias-state"
: >"$TMP/commands"
REMOVE_STUCK=1 expect_status 1 'still-running jail' run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/stuck"
test -d "$TMP/jails/infra-build-drill-test"
test -e "$TMP/mount-state"
test -e "$TMP/alias-state"
test ! -e "$TMP/stuck"
rm -rf "$TMP/jails/infra-build-drill-test"
rm -f "$TMP/jail-state" "$TMP/mount-state" "$TMP/alias-state"
: >"$TMP/commands"
run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/output"
test -f "$TMP/output/release.tar"
test "$(cat "$TMP/output/target-abi")" = FreeBSD:14:amd64
test "$(sha256sum "$TMP/output/release.tar" | awk '{print $1}')" = "$(cat "$TMP/output/release.sha256")"
test ! -e "$TMP/jails/infra-build-drill-test"
grep -Fq 'jexec -U builder infra-build-drill-test /rescue/sh -c exec /bin/sh "$@" sh /work/worker.sh' "$TMP/commands"
# Phoenix dependency cache: a cold build saves one archive per key, a warm
# build unpacks it as the builder before the worker, and a new key replaces it.
cache="$TMP/dependency-cache"
: >"$TMP/commands"
BUILD_CACHE_DIR="$cache" run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/cache-cold" >"$TMP/result" 2>&1
saved=$(find "$cache/drill_trainer" -name '*.tar')
[ "$(printf '%s\n' "$saved" | grep -c .)" = 1 ] || { echo 'cold build did not save one cache archive' >&2; exit 1; }
[ "$(/usr/bin/stat -c %a "$cache")" = 700 ] && [ "$(/usr/bin/stat -c %a "$cache/drill_trainer")" = 700 ] ||
    { echo 'cache directory is not root-only' >&2; exit 1; }
if grep -Fq 'tar -xf /work/cache.tar' "$TMP/commands"; then echo 'cold build restored a cache' >&2; exit 1; fi
: >"$TMP/commands"
BUILD_CACHE_DIR="$cache" run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/cache-warm" >"$TMP/result" 2>&1
restore_line=$(grep -n 'tar -xf /work/cache.tar' "$TMP/commands" | cut -d: -f1)
worker_line=$(grep -n '/work/worker.sh' "$TMP/commands" | cut -d: -f1)
[ -n "$restore_line" ] && [ "$restore_line" -lt "$worker_line" ] || { echo 'warm build did not restore before the worker' >&2; exit 1; }
if grep -Fq 'tar -cf /work/cache.tar' "$TMP/commands"; then echo 'warm build saved again' >&2; exit 1; fi
ERLANG_PACKAGE=erlang-runtime28 BUILD_CACHE_DIR="$cache" run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/cache-rekeyed" >"$TMP/result" 2>&1
rekeyed=$(find "$cache/drill_trainer" -name '*.tar')
[ "$(printf '%s\n' "$rekeyed" | grep -c .)" = 1 ] && [ "$rekeyed" != "$saved" ] ||
    { echo 'a new key did not replace the cache archive' >&2; exit 1; }
# A failed save is reported and leaves no partial archive; the build stands.
rm -rf "$cache"
FAIL_CACHE_SAVE=1 BUILD_CACHE_DIR="$cache" run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/cache-unsaved" >"$TMP/result" 2>&1
test -f "$TMP/cache-unsaved/release.tar"
grep -Fq 'build jail: dependency cache not saved' "$TMP/result" || { echo 'failed cache save not reported' >&2; exit 1; }
[ -z "$(find "$cache" -type f)" ] || { echo 'failed cache save left a file' >&2; exit 1; }
# Other kinds never touch the cache.
rm -rf "$cache"
SERAI_ARTIFACT_KIND=package RELEASE_NAME=garage BUILD_CACHE_DIR="$cache" run infra-build-garage-test 10.40.0.200 "$base_sha" "$TMP/cache-package" >"$TMP/result" 2>&1
[ ! -e "$cache" ] || { echo 'a package build touched the dependency cache' >&2; exit 1; }
# OCaml dependency cache: the build jail's opam root, keyed by the compiler,
# the opam repository, the build packages and the project's opam files.
ocaml_build() {
    SERAI_ARTIFACT_KIND=ocaml RELEASE_NAME=meals SERAI_OCAML_COMPILER="${COMPILER:-ocaml-base-compiler.5.5.1}" \
    SERAI_OPAM_REPOSITORY="$TMP/repository" SERAI_OPAM_INVENTORY="$TMP/repository-inventory" \
    SERAI_OPAM_INVENTORY_SHA256="$repo_sha" BUILD_CACHE_DIR="$cache" \
    run infra-build-meals-test 10.40.0.200 "$base_sha" "$TMP/$1" >"$TMP/result" 2>&1
}
: >"$TMP/commands"
ocaml_build ocaml-cache-cold
saved=$(find "$cache/meals" -name '*.tar')
[ "$(printf '%s\n' "$saved" | grep -c .)" = 1 ] || { echo 'cold OCaml build did not save one cache archive' >&2; exit 1; }
grep -Fq 'tar -cf /work/cache.tar opam' "$TMP/commands" || { echo 'OCaml cache does not hold the opam root' >&2; exit 1; }
if grep -Fq 'tar -xf /work/cache.tar' "$TMP/commands"; then echo 'cold OCaml build restored a cache' >&2; exit 1; fi
: >"$TMP/commands"
ocaml_build ocaml-cache-warm
restore_line=$(grep -n 'tar -xf /work/cache.tar' "$TMP/commands" | cut -d: -f1)
worker_line=$(grep -n '/work/worker.sh' "$TMP/commands" | cut -d: -f1)
[ -n "$restore_line" ] && [ "$restore_line" -lt "$worker_line" ] || { echo 'warm OCaml build did not restore before the worker' >&2; exit 1; }
if grep -Fq 'tar -cf /work/cache.tar' "$TMP/commands"; then echo 'warm OCaml build saved again' >&2; exit 1; fi
COMPILER=ocaml-base-compiler.5.5.0 ocaml_build ocaml-cache-compiler
by_compiler=$(find "$cache/meals" -name '*.tar')
[ "$(printf '%s\n' "$by_compiler" | grep -c .)" = 1 ] && [ "$by_compiler" != "$saved" ] ||
    { echo 'a new compiler did not rekey the OCaml cache' >&2; exit 1; }
mkdir -m 700 "$TMP/opam-source"
cp -p "$TMP/source/main.txt" "$TMP/opam-source/"
printf 'opam-version: "2.0"\ndepends: ["dream"]\n' >"$TMP/opam-source/meals.opam"
chmod 600 "$TMP/opam-source/meals.opam"
printf 'infra-source-v1\t%s\n600\t%s\tmain.txt\n600\t%s\tmeals.opam\n' "$commit" \
    "$(sha256sum "$TMP/opam-source/main.txt" | awk '{print $1}')" \
    "$(sha256sum "$TMP/opam-source/meals.opam" | awk '{print $1}')" >"$TMP/opam-inventory"
COMPILER=ocaml-base-compiler.5.5.0 SOURCE_DIR="$TMP/opam-source" SOURCE_INVENTORY="$TMP/opam-inventory" \
    SOURCE_DIGEST="$(sha256sum "$TMP/opam-inventory" | awk '{print $1}')" ocaml_build ocaml-cache-opam-file
by_opam_file=$(find "$cache/meals" -name '*.tar')
[ "$(printf '%s\n' "$by_opam_file" | grep -c .)" = 1 ] && [ "$by_opam_file" != "$by_compiler" ] ||
    { echo "a changed opam file did not rekey the OCaml cache" >&2; exit 1; }
: >"$TMP/commands"
if FAIL_BUILD=1 run infra-build-drill-test 10.40.0.200 "$base_sha" "$TMP/worker-boundary" >"$TMP/result" 2>&1; then
    echo 'worker failure was ignored' >&2; exit 1
fi
for step in shell-probe abi runtime-links builder-user work-owner; do
    grep -Fq "build jail: completed $step" "$TMP/result" || { echo "missing completed boundary $step" >&2; exit 1; }
done
grep -Fxq 'build jail: starting worker' "$TMP/result"
if grep -Fxq 'build jail: completed worker' "$TMP/result"; then
    echo 'failed worker marked complete' >&2; exit 1
fi
for closed_case in success worker-fail interrupt cleanup-fail; do
    status=0
    case $closed_case in
        success) TEST_CLOSED_STDERR=1 run infra-build-closed-test 10.40.0.200 "$base_sha" "$TMP/closed-success" >"$TMP/closed-result" || status=$? ;;
        worker-fail) TEST_CLOSED_STDERR=1 FAIL_BUILD=1 run infra-build-closed-test 10.40.0.200 "$base_sha" "$TMP/closed-worker-fail" >"$TMP/closed-result" || status=$? ;;
        interrupt) TEST_CLOSED_STDERR=1 INTERRUPT_BUILD=1 run infra-build-closed-test 10.40.0.200 "$base_sha" "$TMP/closed-interrupt" >"$TMP/closed-result" || status=$? ;;
        cleanup-fail) TEST_CLOSED_STDERR=1 FAIL_REMOVE=1 run infra-build-closed-test 10.40.0.200 "$base_sha" "$TMP/closed-cleanup-fail" >"$TMP/closed-result" || status=$? ;;
    esac
    if [ "$closed_case" = success ]; then
        test "$status" = 0 && test -f "$TMP/closed-success/release.tar"
    elif [ "$closed_case" = interrupt ]; then test "$status" = 130 && test ! -e "$TMP/closed-interrupt";
    elif [ "$closed_case" = worker-fail ]; then test "$status" = 3 && test ! -e "$TMP/closed-worker-fail";
    else test "$status" = 1 && test ! -e "$TMP/closed-$closed_case"; fi
    if [ "$closed_case" = cleanup-fail ]; then test -d "$TMP/jails/infra-build-closed-test"; else test ! -e "$TMP/jails/infra-build-closed-test"; fi
done
echo 'ok - disposable build jail validates inputs, runs unprivileged, verifies output and cleans up'
