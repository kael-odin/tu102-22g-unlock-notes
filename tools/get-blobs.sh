#!/bin/bash
# get-blobs.sh - fetch the four TU102 firmware blobs the unlock build links in.
#
# These are NVIDIA firmware images. They are fetched from the pinned upstream
# commit and verified against known SHA-256 values. Do NOT redistribute them and
# do NOT commit them: blobs/ is gitignored and must stay that way.
#
# Usage:
#   ./get-blobs.sh [target-dir]
# target-dir defaults to ./efi-unlock-tu102 (a local checkout of the port).
set -euo pipefail

TARGET="${1:-./efi-unlock-tu102}"
if [ ! -d "$TARGET" ]; then
  echo "target dir not found: $TARGET" >&2
  echo "usage: $0 <path-to-efi-unlock-tu102>" >&2
  exit 2
fi
cd "$TARGET"
mkdir -p blobs

BASE="https://raw.githubusercontent.com/xrip/cmp50hx-unlock/df2fe11b370bb52cc314576d0f2f5ae47ce908f8/efi-unlock/blobs"
declare -A WANT=(
  [v67_payload.bin]=de7288bcfb80c2d4b259a59e823c926ba0a9adcab594219cc6802c94257ce271
  [booter_ucode_prod.bin]=e0f0fc93da097b5b68e5af3adb58b2235ed1fad5fce0b23592d3895af44cb743
  [gsp_rm_boot_dbg.bin]=fa43239bcee7b97ca62f007cc68487560a39e19f74f3dde7486db3f98df8e471
  [bl_gsp_tu102.bin]=f21f1cfbb8fffa8067685314367fc4c50f3f84dd99eda7c19db4292d9269b9d9
)

PROXY="${https_proxy:-${HTTPS_PROXY:-}}"

fetch() {
  local f="$1" want="$2" got
  if [ -f "blobs/$f" ] && [ "$(sha256sum "blobs/$f" | cut -d' ' -f1)" = "$want" ]; then
    echo "  blobs/$f already present (hash OK)"
    return 0
  fi
  echo "  fetching $f ..."
  if [ -n "$PROXY" ]; then
    curl -fsSL --retry 3 -x "$PROXY" -o "blobs/$f" "$BASE/$f" || true
  else
    curl -fsSL --retry 3 -o "blobs/$f" "$BASE/$f" \
      || curl -fsSL --retry 3 -x http://127.0.0.1:7890 -o "blobs/$f" "$BASE/$f" \
      || true
  fi
  got=$(sha256sum "blobs/$f" 2>/dev/null | cut -d' ' -f1 || true)
  if [ "${got:-}" != "$want" ]; then
    rm -f "blobs/$f"
    echo "  FAILED: $f (got '${got:-nothing}')" >&2
    echo "  fetch manually: $BASE/$f" >&2
    return 1
  fi
  echo "  blobs/$f OK"
}

FAIL=0
for f in "${!WANT[@]}"; do fetch "$f" "${WANT[$f]}" || FAIL=1; done
if [ "$FAIL" = 0 ]; then
  echo "all four TU102 blobs ready in $TARGET/blobs"
else
  echo "one or more blobs missing" >&2
  exit 1
fi
