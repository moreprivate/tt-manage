#!/usr/bin/env bash
# Prove signing is discoverable inside the same Docker entry as make build,
# using only $HOME/.config/moreprivate/tt-mobile on the host (no repo-tree local.properties).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MANAGE="$ROOT/tt-manage"
SIGN_DIR="${HOST_TT_SIGN_DIR:-$HOME/.config/moreprivate/tt-mobile}"
MOBILE_LP="$ROOT/tt-mobile/android/local.properties"

KEYSTORE="$SIGN_DIR/tt-mobile.keystore"
test -f "$KEYSTORE" || {
  echo "FAIL: missing Android keystore under $SIGN_DIR/tt-mobile.keystore" >&2
  exit 1
}
test -f "$SIGN_DIR/local.properties" || {
  echo "FAIL: missing $SIGN_DIR/local.properties" >&2
  exit 1
}

# Simulate clean: no residual signing in the mobile tree
rm -f "$MOBILE_LP"

cd "$MANAGE"
# Resolve the same HOST_TT_SIGN_DIR make would use on the host
HOST_ABS="$(cd "$SIGN_DIR" && pwd)"

docker run --rm --user "$(id -u):$(id -g)" \
  -e HOME=/tmp/tt-home \
  -e HOST_TT_SIGN_DIR="$HOST_ABS" \
  -v "$ROOT":/workspace \
  -v "$HOST_ABS":"$HOST_ABS":ro \
  -v "$HOST_ABS":/tmp/tt-home/.config/moreprivate/tt-mobile:ro \
  -w /workspace/tt-manage \
  adguard/core-libs:2.12 \
  bash -euo pipefail -c '
    set -euo pipefail
    # Nested make re-evaluates Makefile; override must win (HOME is /tmp/tt-home).
    make -n build-mobile NATIVE_BUILD=1 \
      HOST_TT_SIGN_DIR="$HOST_TT_SIGN_DIR" \
      HOST_TT_KEYSTORE="$HOST_TT_SIGN_DIR/tt-mobile.keystore" \
      FLUTTER=/workspace/.tt-build/flutter/bin/flutter \
      ANDROID_SDK_ROOT=/workspace/.tt-build/android-sdk \
      2>/dev/null | head -1 >/dev/null || true

    # Real discovery logic (same candidates as build-mobile)
    props=""
    for cand in \
      "$HOST_TT_SIGN_DIR/local.properties" \
      "$HOME/.config/moreprivate/tt-mobile/local.properties"; do
      if [ -f "$cand" ] && grep -q "^signingConfigKeyStorePath=" "$cand"; then
        props="$cand"
        break
      fi
    done
    [ -n "$props" ] || { echo "FAIL: no signing props found"; exit 1; }
    ks=$(grep -E "^signingConfigKeyStorePath=" "$props" | head -1 | cut -d= -f2-)
    kpass=$(grep -E "^signingConfigKeyPassword=" "$props" | head -1 | cut -d= -f2-)
    spass=$(grep -E "^signingConfigKeyStorePassword=" "$props" | head -1 | cut -d= -f2-)
    [ -f "$ks" ] || { echo "FAIL: keystore not readable at $ks"; exit 1; }
    [ -n "$kpass" ] && [ -n "$spass" ] || { echo "FAIL: empty password in $props"; exit 1; }
    # Repo tree must not be the source
    [ ! -f /workspace/tt-mobile/android/local.properties ] \
      || ! grep -q signingConfigKeyStorePath /workspace/tt-mobile/android/local.properties 2>/dev/null \
      || { echo "FAIL: residual signing in repo local.properties"; exit 1; }
    echo "OK: signing via $props → keystore $ks"
  '
