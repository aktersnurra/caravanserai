#!/usr/bin/env bash
# scripts/install-infra.sh
# Builds and tests infra/, then installs the binary as serai (and infra, an
# alias) on PATH, and the engine files it runs on the hosts under
# $PREFIX/share/caravanserai, where serai finds them when no engine checkout
# is above the configuration it runs in. Re-run after pulling changes: the
# installed copy does not rebuild itself.
#   ./scripts/install-infra.sh
#   PREFIX=/usr/local ./scripts/install-infra.sh   # installs to $PREFIX/bin
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
cd "$root/infra"

PREFIX="${PREFIX:-$HOME/.local}"
share="$PREFIX/share/caravanserai"

dune build
# Tests before install, so a broken build never replaces a working infra.
dune runtest

# The engine's runtime files, staged beside the old ones and swapped in, so
# a failed copy never leaves a partial engine.
install -d "$PREFIX/share"
rm -rf "$share.new"
install -d "$share.new/compute/apps" "$share.new/edge"
cp -R "$root/compute/apps/_lib" "$share.new/compute/apps/"
cp "$root/compute/01-pf-rules" "$share.new/compute/"
cp "$root"/edge/00-headscale "$root"/edge/01-headscale-policy "$root"/edge/01-tailscale \
   "$root"/edge/02-caddy "$root"/edge/03-logging "$root"/edge/04-vmui-auth \
   "$root"/edge/syslog-ng-victoria.conf.template "$root"/edge/syslog-ng-victoria.service \
   "$share.new/edge/"
rm -rf "$share.old"
if [ -e "$share" ]; then mv "$share" "$share.old"; fi
mv "$share.new" "$share"
rm -rf "$share.old"
echo "==> installed $share"

install -d "$PREFIX/bin"
install -m 755 _build/default/bin/main.exe "$PREFIX/bin/serai"
ln -sf serai "$PREFIX/bin/infra"
echo "==> installed $PREFIX/bin/serai (and infra)"

case ":$PATH:" in
  *":$PREFIX/bin:"*) ;;
  *) echo "==> note: $PREFIX/bin is not on PATH" >&2 ;;
esac
