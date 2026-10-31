#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/root/opt" "$TMP/payload/bin" "$TMP/bin"
printf '#!/bin/sh\nexit 0\n' >"$TMP/payload/bin/ledger"
chmod 755 "$TMP/payload/bin/ledger"
mkdir "$TMP/payload/.infra-build"
printf 'verified build inventory\n' >"$TMP/payload/.infra-build/opam-packages"
# Use the real OCaml worker's archive shape, including the ./ directory entry.
tar -cf "$TMP/release.tar" -C "$TMP/payload" .
sha="$(sha256sum "$TMP/release.tar")"; sha=${sha%% *}
id="$(printf 'a%.0s' {1..64})"
cat >"$TMP/bin/chown" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"$CHOWN_LOG"
EOF
chmod +x "$TMP/bin/chown"
export CHOWN_LOG="$TMP/chown"
run() { GUEST_ROOT="$TMP/root" CHOWN_BIN="$TMP/bin/chown" sh "$ROOT/compute/apps/_lib/artifact_install_guest.sh" ledger ledger-svc "$id" "$TMP/release.tar" "$sha"; }
run
[ -x "$TMP/root/opt/.infra-releases/ledger/$id/bin/ledger" ]
[ "$(cat "$TMP/root/opt/.infra-releases/ledger/$id/.infra-sha256")" = "$sha" ]
[ ! -e "$TMP/root/opt/ledger" ]
grep -Fq root:ledger-svc "$CHOWN_LOG"
run
# A link in an otherwise hash-verified archive must be refused before extraction.
ln -s /etc/ledger/ledger.sexp "$TMP/payload/bin/config-link"
tar -cf "$TMP/release.tar" -C "$TMP/payload" bin
sha="$(sha256sum "$TMP/release.tar")"; sha=${sha%% *}
id="$(printf 'b%.0s' {1..64})"
if run >"$TMP/error" 2>&1; then exit 1; fi
[ ! -e "$TMP/root/opt/.infra-releases/ledger/$id" ]
echo 'ok - guest installer verifies archive metadata before extraction and never switches active code'
