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
if command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    gh release download "$TAG" --repo "$REPO" --pattern '*.tar.gz*'
else
    # public repo: no auth needed, and shockwave has no gh installed
    echo "   (no gh; using curl)"
    API="https://api.github.com/repos/$REPO/releases/tags/$TAG"
    curl -fsSL "$API" -o rel.json
    python3 - <<'EOF' > urls.txt
import json
for a in json.load(open("rel.json"))["assets"]:
    print(a["browser_download_url"])
EOF
    [ -s urls.txt ] || { echo "   no assets found for $TAG" >&2; exit 1; }
    while read -r u; do curl -fsSL -O "$u"; done < urls.txt
fi
ASSET=$(ls ./*.tar.gz)
sha256sum -c "$ASSET.sha256"
echo "   checksum ok: $ASSET"

say "Checking the binary actually runs on this CPU"
# Don't grep for opcodes -- llama-server is a 17KB shim, the code is in
# libggml-cpu.so, and any hand-written opcode list will miss something. It missed
# BMI2 (shlx), which SIGILL'd here. Just run the thing: this IS the target CPU.
tar xzf "$ASSET" -C "$WORK"
if ! LD_LIBRARY_PATH="$WORK/usr/local/lib" \
     timeout 60 "$WORK/usr/local/bin/llama-server" --version >"$WORK/ver.txt" 2>&1; then
    echo "   REFUSING: the binary does not run on this CPU:" >&2
    tail -3 "$WORK/ver.txt" >&2
    dmesg -T 2>/dev/null | grep -i 'trap.*llama-server' | tail -1 >&2 || true
    exit 1
fi
echo "   ok: $(grep -m1 version "$WORK/ver.txt" || echo 'runs clean')"

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
