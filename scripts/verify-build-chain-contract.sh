#!/usr/bin/env bash
# Static + structural contract: local make build matches self-hosted CI model,
# and signing is discovered from host $HOME/.config/tt-mobile inside Docker.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MF="$ROOT/Makefile"
fail() { echo "FAIL: $*" >&2; exit 1; }

grep -q 'BUILD_IMAGE ?= adguard/core-libs:2.12' "$MF" || fail "BUILD_IMAGE pin"
grep -q 'FLUTTER_VERSION ?= 3.44.8' "$MF" || fail "FLUTTER_VERSION pin"
grep -q 'platforms;android-36' "$MF" || fail "android-36"
grep -q 'build-tools;35.0.0' "$MF" || fail "build-tools"
grep -q 'ndk;29.0.14206865' "$MF" || fail "ndk"
grep -q 'cmake;3.31.6' "$MF" || fail "cmake"
grep -q 'TOOL_FLUTTER := \$(OUT_DIR)/flutter' "$MF" || fail "flutter under OUT_DIR"
grep -q 'TOOL_ANDROID_SDK := \$(OUT_DIR)/android-sdk' "$MF" || fail "android-sdk under OUT_DIR"

# No host personal toolchain bind-mounts (comments OK; env -e FLUTTER_ROOT=… OK)
if grep -nE -- '^\s+-v .*(/flutter|/Android/Sdk|FLUTTER_ROOT)' "$MF" \
  | grep -vE 'tt-mobile|C_FLUTTER|\.tt-build/flutter' >/dev/null 2>&1; then
  fail "host flutter/Android bind mount still present"
fi
# Explicitly forbid mounting host home flutter tree
if grep -nE -- '-v .*\(HOME\)/flutter|-v .*/flutter:ro' "$MF" >/dev/null 2>&1; then
  fail "host ~/flutter mount still present"
fi

# Nested make must pass host-absolute HOST_TT_SIGN_DIR (not re-expand HOME inside container)
grep -q 'HOST_TT_SIGN_DIR=' "$MF" || fail "HOST_TT_SIGN_DIR missing"
grep -q 'HOST_TT_SIGN_DIR="\$\$HOST_TT_SIGN_DIR"' "$MF" || fail "docker-run must pass HOST_TT_SIGN_DIR to nested make"
grep -q 'C_HOME)/.config/tt-mobile' "$MF" || fail "must bind-mount signing under container HOME/.config/tt-mobile"

# Public clean API is only clean + distclean; clean keeps products
grep -q '^clean:' "$MF" || fail "missing clean"
grep -q '^distclean:' "$MF" || fail "missing distclean"
grep -q "MOBILE_DIR)/android/local.properties" "$MF" || fail "clean must rm mobile android/local.properties"
# clean must not wipe entire OUT_DIR in its own recipe (distclean does)
if awk '/^clean:/{p=1;next} p&&/^[^#[:space:]]/{exit} p' "$MF" | grep -q "rm -rf '\\\$(OUT_DIR)'"; then
  fail "make clean must not rm -rf entire OUT_DIR (use distclean)"
fi

# Signing candidate loop must not list repo-tree android/local.properties
if grep -A80 '^build-mobile:' "$MF" | grep -B5 -A5 'signingConfigKeyStorePath' \
  | grep -q 'MOBILE_DIR)/android/local.properties'; then
  fail "build-mobile must not load signing from MOBILE_DIR/android/local.properties"
fi
# sdk.dir rewrite of that file is OK; secrets must only come from HOST_TT_SIGN_DIR / HOME
grep -A40 'for cand in' "$MF" | grep -q 'HOST_TT_SIGN_DIR)/local.properties' \
  || fail "signing candidates must include HOST_TT_SIGN_DIR/local.properties"

echo "OK: build-chain contract matches CI-like self-contained Docker model"
