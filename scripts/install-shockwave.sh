#!/usr/bin/env bash
# Install a GitHub-built llama.cpp tarball onto shockwave.
#
#   ./install-shockwave.sh <tag>            # download, back up, install, verify
#   ./install-shockwave.sh <tag> --dry-run  # show what would happen
#
# Deliberately NOT run automatically by CI. "It built" and "your models still
# work" are different claims; the second needs the live check at the end.
set -euo pipefail

REPO="${BUILDER_REPO:-guarismo/llama-cuda-builder}"
TAG="${1:-}"
DRY="${2:-}"
SERVICE="llama-server"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -n "$TAG" ] || { echo "usage: $0 <tag> [--dry-run]"; exit 1; }

say() { printf '\n== %s\n' "$*"; }
run() { if [ "$DRY" = "--dry-run" ]; then echo "   would: $*"; else "$@"; fi; }

say "Fetching $TAG from $REPO"
cd "$WORK"
gh release download "$TAG" --repo "$REPO" --pattern '*.tar.gz*'
ASSET=$(ls ./*.tar.gz)
sha256sum -c "$ASSET.sha256"
echo "   checksum ok: $ASSET"

say "Checking the binary matches this CPU"
# The FX-8350 has no AVX2/AVX-512. A binary built with -march=native on a CI
# runner would SIGILL here, so refuse it before touching /usr/local.
tar xzf "$ASSET" -C "$WORK" usr/local/bin/llama-server
if objdump -d "$WORK/usr/local/bin/llama-server" | grep -qE '%ymm|%zmm'; then
    echo "   REFUSING: binary uses AVX2/AVX-512 registers, this CPU cannot run it" >&2
    exit 1
fi
MISSING=$(for f in avx fma f16c; do grep -qw "$f" /proc/cpuinfo || echo "$f"; done)
[ -z "$MISSING" ] || { echo "   REFUSING: CPU lacks:$MISSING" >&2; exit 1; }
echo "   ok: no ymm/zmm, CPU has avx+fma+f16c"

say "Backing up the current install"
CUR=$(llama-server --version 2>&1 | grep -oE 'commit [0-9a-f]+' | awk '{print $2}' || echo unknown)
BACKUP="/home/igor/llama-PREV-${CUR}-usrlocal-backup.tar.gz"
run sudo systemctl stop "$SERVICE"
run sudo bash -c "cd / && tar czf '$BACKUP' usr/local/bin/llama-* usr/local/lib/libggml* usr/local/lib/libllama* usr/local/include/ggml* usr/local/include/llama* 2>/dev/null"
if [ "$DRY" != "--dry-run" ]; then
    N=$(tar tzf "$BACKUP" | wc -l)
    [ "$N" -gt 50 ] || { echo "   backup looks empty ($N entries) -- aborting" >&2; sudo systemctl start "$SERVICE"; exit 1; }
    echo "   backup: $BACKUP ($N entries)"
fi

say "Installing"
run sudo tar xzf "$WORK/$ASSET" -C /
run sudo ldconfig
run sudo systemctl start "$SERVICE"
[ "$DRY" = "--dry-run" ] || sleep 20
run llama-server --version

say "Verifying every preset live"
if [ "$DRY" != "--dry-run" ]; then
    python3 "$(dirname "$0")/verify-presets.py" || {
        echo
        echo "   VERIFICATION FAILED -- roll back with:"
        echo "     sudo systemctl stop $SERVICE && sudo tar xzf $BACKUP -C / && sudo ldconfig && sudo systemctl start $SERVICE"
        exit 1
    }
fi
say "Done. Rollback if needed: sudo tar xzf $BACKUP -C / && sudo ldconfig && sudo systemctl restart $SERVICE"
