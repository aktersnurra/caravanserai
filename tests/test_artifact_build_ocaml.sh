#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'chmod -R u+rwx "$TMP"; rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/source/tools/vault" "$TMP/repo"
printf 'opam-version: "2.0"\n' >"$TMP/repo/repo"
printf '(lang dune 3.24)\n' >"$TMP/source/dune-project"
printf 'opam-version: "2.0"\n' >"$TMP/source/meals.opam"
printf '(lang dune 3.17)\n' >"$TMP/source/tools/vault/dune-project"
printf 'opam-version: "2.0"\n' >"$TMP/source/tools/vault/vault.opam"
cat >"$TMP/bin/opam" <<'EOF'
#!/bin/sh
[ "${OPAMREQUIRECHECKSUMS:-}" = true ] || { echo 'missing required source checksums' >&2; exit 9; }
printf 'opam %s\n' "$*" >>"$COMMAND_LOG"
case "$1" in
 init) [ ! -e "$OPAMROOT" ] || exit 1; mkdir -p "$OPAMROOT" ;;
 switch) [ "$2" = create ] && [ "$3" = artifact ] || exit 1; mkdir "$OPAMROOT/artifact"; printf '%s\n' "$4" >"$OPAMROOT/compiler" ;;
 install) [ "$2" = . ] && [ "$3" = --deps-only ] || exit 1 ;;
 exec) shift; [ "$1" = --switch=artifact ] && [ "$2" = -- ] || exit 1; shift 2; exec "$@" ;;
 list)
   compiler=$(cat "$OPAMROOT/compiler")
   version=${compiler#*.}
   printf '%-28s\t%s\nocaml\t%s\ndune\t3.24.0\n' "${compiler%%.*}" "$version" "${version%%+*}" ;;
 *) exit 1 ;;
esac
EOF
cat >"$TMP/bin/dune" <<'EOF'
#!/bin/sh
printf 'dune %s\n' "$*" >>"$COMMAND_LOG"
[ "${FAIL_BUILD:-0}" != 1 ] || exit 7
[ "$1" = build ] && [ "$2" = --profile ] && [ "$3" = release ] || exit 1
mkdir -p "_build/default/$(dirname "$4")"
printf '#!/bin/sh\nexit 0\n' >"_build/default/$4"
chmod +x "_build/default/$4"
EOF
cat >"$TMP/bin/ldd" <<'EOF'
#!/bin/sh
[ "${FAIL_LINKAGE:-0}" != 1 ] || exit 8
if [ "${MISSING_LIBRARY:-0}" = 1 ]; then printf '\tlibsqlite3.so.0 => not found\n';
elif [ "${PRIVATE_LIBRARY:-0}" = 1 ]; then printf '\tlibprivate.so => %s/lib/libprivate.so\n' "$OPAMROOT";
else printf '\tlibsqlite3.so.0 => /usr/local/lib/libsqlite3.so.0\n'; fi
EOF
cat >"$TMP/bin/id" <<'EOF'
#!/bin/sh
[ "$1" = -u ] || exit 1
printf '%s\n' "${BUILD_UID:-1000}"
EOF
cat >"$TMP/bin/sha256" <<'EOF'
#!/bin/sh
[ "$1" = -q ] || exit 1
sha256sum "$2" | awk '{print $1}'
EOF
chmod +x "$TMP/bin/"*
run() {
 PATH="$TMP/bin:$PATH" COMMAND_LOG="$TMP/commands" \
 sh "$ROOT/compute/apps/_lib/artifact_build_ocaml.sh" "$TMP/source" "$1" "$2" "$3" "$TMP/$4" "$5" "$TMP/repo"
}
: >"$TMP/commands"
run . bin/meals.exe meals meals-output ocaml-base-compiler.5.5.1
[ -f "$TMP/meals-output/release.tar" ]
[ "$(sha256sum "$TMP/meals-output/release.tar" | awk '{print $1}')" = "$(cat "$TMP/meals-output/release.sha256")" ]
tar -tf "$TMP/meals-output/release.tar" | grep -Fxq './bin/meals'
tar -tf "$TMP/meals-output/release.tar" | grep -Fxq './.infra-build/opam-packages'
tar -xf "$TMP/meals-output/release.tar" -O ./.infra-build/opam-packages | grep -Fq 'ocaml-base-compiler' 
grep -Fq 'libsqlite3.so.0' "$TMP/meals-output/linkage"
grep -Fq 'opam switch create artifact ocaml-base-compiler.5.5.1' "$TMP/commands"
if tar -tf "$TMP/meals-output/release.tar" | grep -q '^\./share'; then echo 'a build without a web bundle shipped one' >&2; exit 1; fi
# A controller-built web bundle ships as share/web, each file's SHA-256 recorded.
web() {
 PATH="$TMP/bin:$PATH" COMMAND_LOG="$TMP/commands" sh "$ROOT/compute/apps/_lib/artifact_build_ocaml.sh" \
  "$TMP/source" . bin/meals.exe meals "$TMP/$1" ocaml-base-compiler.5.5.1 "$TMP/repo" "$TMP/$2"
}
mkdir "$TMP/web"
printf '<html>\n' >"$TMP/web/index.html"
printf 'js\n' >"$TMP/web/main.bc.js"
web web-output web
for file in index.html main.bc.js; do
 tar -tf "$TMP/web-output/release.tar" | grep -Fxq "./share/web/$file"
 tar -xf "$TMP/web-output/release.tar" -O ./.infra-build/web-bundle |
  grep -Fxq "$(sha256sum "$TMP/web/$file" | awk '{print $1}')$(printf '\t')$file"
done
for bad in subdirectory hidden link empty; do
 rm -rf "$TMP/bad-web"; mkdir "$TMP/bad-web"
 case $bad in
  subdirectory) mkdir "$TMP/bad-web/assets" ;;
  hidden) printf 'x\n' >"$TMP/bad-web/.env" ;;
  link) ln -s /etc/passwd "$TMP/bad-web/passwd" ;;
 esac
 [ "$bad" = empty ] || printf '<html>\n' >"$TMP/bad-web/index.html"
 if web "bad-web-$bad" bad-web >"$TMP/error" 2>&1; then echo "web bundle with $bad accepted" >&2; exit 1; fi
 [ ! -e "$TMP/bad-web-$bad" ]
done
# The build jail keeps its opam root for the dependency cache: the first build
# creates it, a later one reuses its switch; the app itself is always rebuilt.
: >"$TMP/commands"
SERAI_OPAM_ROOT="$TMP/kept-opam" run . bin/meals.exe meals kept-cold ocaml-base-compiler.5.5.1
[ -d "$TMP/kept-opam/artifact" ] || { echo 'kept opam root removed with the stage' >&2; exit 1; }
grep -Fq 'opam switch create artifact ocaml-base-compiler.5.5.1' "$TMP/commands"
: >"$TMP/commands"
SERAI_OPAM_ROOT="$TMP/kept-opam" run . bin/meals.exe meals kept-warm ocaml-base-compiler.5.5.1
if grep -Eq '^opam (init|switch create)' "$TMP/commands"; then echo 'a kept switch was rebuilt' >&2; exit 1; fi
grep -Fq 'opam install . --deps-only' "$TMP/commands"
grep -Fq 'dune build --profile release bin/meals.exe' "$TMP/commands"
tar -tf "$TMP/kept-warm/release.tar" | grep -Fxq './bin/meals'
if PRIVATE_LIBRARY=1 SERAI_OPAM_ROOT="$TMP/kept-opam" run . bin/meals.exe meals kept-private ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then
 echo 'a library inside the kept opam root was published' >&2; exit 1
fi
[ ! -e "$TMP/kept-private" ]
ln -s "$TMP/kept-opam" "$TMP/opam-link"
mkdir "$TMP/opam-empty"
for bad in relative link no-switch; do
 case $bad in
  relative) root=kept-opam ;;
  link) root=$TMP/opam-link ;;
  no-switch) root=$TMP/opam-empty ;;
 esac
 : >"$TMP/commands"
 if SERAI_OPAM_ROOT="$root" run . bin/meals.exe meals "kept-$bad" ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then
  echo "kept opam root ($bad) accepted" >&2; exit 1
 fi
 [ ! -s "$TMP/commands" ] && [ ! -e "$TMP/kept-$bad" ]
done
run tools/vault bin/main.exe vault vault-output ocaml-variants.5.2.0+ox
[ -f "$TMP/vault-output/release.tar" ]
tar -tf "$TMP/vault-output/release.tar" | grep -Fxq './bin/vault'
grep -Fq 'opam switch create artifact ocaml-variants.5.2.0+ox' "$TMP/commands"
if grep -Eq '^(service|systemctl)|migrate|switch set|opam env|^dune.*setup' "$TMP/commands"; then
 echo 'build invoked runtime or changed global switch' >&2; exit 1
fi
for bad in '../escape' '/absolute' 'tools/../vault' 'tools//vault'; do
 : >"$TMP/commands"
 if run "$bad" bin/main.exe vault refused ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then exit 1; fi
 [ ! -s "$TMP/commands" ]
done
: >"$TMP/commands"
if run . bin/meals.exe meals unpinned ocaml-base-compiler >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$TMP/commands" ]
: >"$TMP/commands"
if PATH="$TMP/bin:$PATH" COMMAND_LOG="$TMP/commands" sh "$ROOT/compute/apps/_lib/artifact_build_ocaml.sh" \
 "$TMP/source" . bin/meals.exe meals 'relative:/output' ocaml-base-compiler.5.5.1 "$TMP/repo" >"$TMP/error" 2>&1; then exit 1; fi
grep -Fq 'OCaml worker: invalid or unsafe input' "$TMP/error"
[ ! -s "$TMP/commands" ]
if BUILD_UID=0 run . bin/meals.exe meals root-refused ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then exit 1; fi
if FAIL_BUILD=1 run . bin/meals.exe meals failed ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then exit 1; fi
[ ! -e "$TMP/failed" ]
if FAIL_LINKAGE=1 run . bin/meals.exe meals bad-linkage ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then exit 1; fi
[ ! -e "$TMP/bad-linkage" ]
if MISSING_LIBRARY=1 run . bin/meals.exe meals missing-library ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then
 echo 'FAIL - unresolved runtime libraries must refuse publication even if ldd exits zero' >&2; exit 1
fi
[ ! -e "$TMP/missing-library" ]
if PRIVATE_LIBRARY=1 run . bin/meals.exe meals private-library ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then
 echo 'FAIL - libraries removed with the private build root must refuse publication' >&2; exit 1
fi
[ ! -e "$TMP/private-library" ]
if run . bin/meals.exe meals meals-output ocaml-base-compiler.5.5.1 >"$TMP/error" 2>&1; then exit 1; fi
[ -f "$TMP/meals-output/release.tar" ]
if find "$TMP" -maxdepth 1 -name '*.tmp.*' | grep -q .; then echo 'partial worker stage leaked' >&2; exit 1; fi
if [ "$(uname -s)" != Linux ]; then
 echo 'ok - isolated OCaml workers package meals without activation or global switch mutation'
 echo 'skip - the guest adapter and installer run only in the Linux guest'
 exit 0
fi
# Exercise the Linux adapter with actual source/repository inventory verification
# and the mock toolchain, then feed its real archive to the guest installer.
mkdir -p "$TMP/guest-source/tools/ledger" "$TMP/guest-repository" "$TMP/runtime/opt"
printf '(lang dune 3.17)\n' >"$TMP/guest-source/tools/ledger/dune-project"
printf 'opam-version: "2.0"\n' >"$TMP/guest-repository/repo"
find "$TMP/guest-source" "$TMP/guest-repository" -type d -exec chmod 700 {} +
find "$TMP/guest-source" "$TMP/guest-repository" -type f -exec chmod 600 {} +
for label in source repository; do
 if [ "$label" = source ]; then file=tools/ledger/dune-project; else file=repo; fi
 printf 'infra-source-v1\t%s\n600\t%s\t%s\n' "$(printf '1%.0s' {1..40})" \
  "$(sha256sum "$TMP/guest-$label/$file" | awk '{print $1}')" "$file" >"$TMP/guest-$label-inventory"
done
source_sha=$(sha256sum "$TMP/guest-source-inventory" | awk '{print $1}')
repo_sha=$(sha256sum "$TMP/guest-repository-inventory" | awk '{print $1}')
guest_build() {
 PATH="$TMP/bin:$PATH" COMMAND_LOG="$TMP/commands" sh "$ROOT/compute/apps/_lib/artifact_build_guest.sh" \
  "$TMP/guest-source" "$TMP/guest-source-inventory" "$source_sha" \
  "$TMP/guest-repository" "$TMP/guest-repository-inventory" "$repo_sha" \
  ocaml-variants.5.2.0+ox "$TMP/$1" tools/ledger bin/main.exe ledger
}
guest_build guest-output
grep -Fxq "Linux:$(uname -m):glibc_$(getconf GNU_LIBC_VERSION | awk '{print $2}')" "$TMP/guest-output/target-abi"
grep -Fxq "$(printf 'opam-repository\t%s\t%s' "$(printf '1%.0s' {1..40})" "$repo_sha")" "$TMP/guest-output/dependencies"
GUEST_ROOT="$TMP/runtime" CHOWN_BIN=true sh "$ROOT/compute/apps/_lib/artifact_install_guest.sh" ledger ledger-svc \
 "$(printf 'a%.0s' {1..64})" "$TMP/guest-output/release.tar" "$(cat "$TMP/guest-output/release.sha256")"
[ -x "$TMP/runtime/opt/.infra-releases/ledger/$(printf 'a%.0s' {1..64})/bin/ledger" ]
[ ! -e "$TMP/runtime/opt/ledger" ]
: >"$TMP/commands"
if BUILD_UID=0 guest_build guest-root-refused >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$TMP/commands" ]
printf 'changed source\n' >"$TMP/guest-source/tools/ledger/dune-project"
if guest_build guest-source-refused >"$TMP/error" 2>&1; then exit 1; fi
[ ! -s "$TMP/commands" ]
[ ! -e "$TMP/guest-source-refused" ]
echo 'ok - isolated OCaml workers and verified Linux adapter package/install meals and a guest workload without activation or global switch mutation'
