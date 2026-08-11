# TrustTunnel local build chain — same model as GitHub self-hosted runner.
#
# Public API (this is all you need):
#
#   make build          full product (server + client + signed APKs)
#   make build-router   server + OpenWrt/linux client only
#   make clean          refresh build junk; keep finished products
#   make distclean      delete everything under .tt-build/ (products too)
#   make help           this list
#
# Host: Docker only (+ $HOME/.config/tt-mobile for APK signing).
# Image: adguard/core-libs:2.12. Tools live under .tt-build/ (not ~/flutter).

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ROOT := $(abspath $(CURDIR)/..)
SERVER_DIR := $(ROOT)/tt-server
CLIENT_DIR := $(ROOT)/tt-client
MOBILE_DIR := $(ROOT)/tt-mobile
OUT_DIR ?= $(ROOT)/.tt-build
DOCKER ?= docker
BUILD_IMAGE ?= adguard/core-libs:2.12

# Pinned the same way as tt-mobile CI (build-mobile-targets.yml).
FLUTTER_VERSION ?= 3.44.8
FLUTTER_GIT ?= https://github.com/flutter/flutter.git

# All caches under OUT_DIR (user-owned). Paths are host paths; Docker bind-mounts them.
DOCKER_HOME := $(OUT_DIR)/docker-home
DOCKER_GRADLE_HOME := $(OUT_DIR)/docker-gradle
DOCKER_CARGO_HOME := $(OUT_DIR)/docker-cargo
DOCKER_RUSTUP_HOME := $(OUT_DIR)/docker-rustup
DOCKER_CONAN_HOME := $(OUT_DIR)/docker-conan
DOCKER_PUB_CACHE := $(OUT_DIR)/docker-pub-cache
# Tooling bootstrapped inside the container (same idea as CI RUNNER_TEMP/*).
TOOL_FLUTTER := $(OUT_DIR)/flutter
TOOL_ANDROID_SDK := $(OUT_DIR)/android-sdk

# Inside container absolute paths (workspace = monorepo root).
C_OUT := /workspace/.tt-build
C_FLUTTER := $(C_OUT)/flutter
C_ANDROID_SDK := $(C_OUT)/android-sdk
C_HOME := /tmp/tt-home
C_CARGO := /tmp/tt-cargo
C_RUSTUP := /tmp/tt-rustup
C_CONAN := /tmp/tt-conan
C_GRADLE := /tmp/tt-gradle
C_PUB := /tmp/tt-pub

CLIENT_ENV := $(CLIENT_DIR)/env
CLIENT_PYTHON := $(CLIENT_ENV)/bin/python
CLIENT_CONAN := $(CLIENT_ENV)/bin/conan

# Match the component workflows: release identity is the newest source commit
# (excluding workflow-only edits), formatted as UTC timestamp plus short SHA.
RELEASE_TAG_SCRIPT := $(CURDIR)/scripts/release-tag.sh
SERVER_VERSION ?= $(shell '$(RELEASE_TAG_SCRIPT)' '$(SERVER_DIR)')
CLIENT_VERSION ?= $(shell '$(RELEASE_TAG_SCRIPT)' '$(CLIENT_DIR)')
MOBILE_VERSION ?= $(shell '$(RELEASE_TAG_SCRIPT)' '$(MOBILE_DIR)')
MOBILE_VERSION_CODE ?= $(shell cd '$(MOBILE_DIR)' && epoch=$$(git show -s --format=%ct HEAD) && code=$$((epoch - 1577836800)) && test "$$code" -gt 0 && test "$$code" -le 2100000000 && printf '%s' "$$code")
SERVER_ARCHES ?= x86_64 aarch64
CLIENT_ARCHES ?= x86_64 aarch64 mipsel

# Image layout (adguard/core-libs:2.12)
IMAGE_ANDROID_SDK := /storage/android-sdk
IMAGE_SDKMANAGER := $(IMAGE_ANDROID_SDK)/cmdline-tools/latest/bin/sdkmanager
IMAGE_NDK := $(IMAGE_ANDROID_SDK)/ndk/29.0.14206865
ANDROID_PLATFORM := platforms;android-36
ANDROID_BUILD_TOOLS := build-tools;35.0.0
ANDROID_NDK_PKG := ndk;29.0.14206865
ANDROID_CMAKE_PKG := cmake;3.31.6
ANDROID_CMAKE_DIR = $(ANDROID_SDK_ROOT)/cmake/3.31.6

# Always the invoking host user (never root-in-docker).
HOST_UID := $(shell id -u)
HOST_GID := $(shell id -g)
ifeq ($(HOST_UID),0)
  $(error Do not run this Makefile as root. Use your normal login user so Docker files stay owned by you.)
endif

# Signing only (secret). Not a toolchain. Never in git.
# Freeze host path at outer make parse time. Inside Docker HOME is /tmp/tt-home, so
# docker-run MUST pass HOST_TT_SIGN_DIR=… on the nested make command line (override)
# and bind-mount that host path (and under container $HOME/.config/tt-mobile).
HOST_TT_SIGN_DIR ?= $(abspath $(HOME)/.config/tt-mobile)
HOST_TT_KEYSTORE ?= $(HOST_TT_SIGN_DIR)/trusttunnel.keystore

# When NATIVE_BUILD=1 we are inside the container (or host-dev).
# Always use workspace .tt-build tooling — never host ~/flutter or host SDK.
ifeq ($(NATIVE_BUILD),1)
  ANDROID_SDK_ROOT ?= $(C_ANDROID_SDK)
  ANDROID_HOME ?= $(C_ANDROID_SDK)
  FLUTTER ?= $(C_FLUTTER)/bin/flutter
  FLUTTER_BIN := $(C_FLUTTER)/bin
else
  ANDROID_SDK_ROOT := $(TOOL_ANDROID_SDK)
  ANDROID_HOME := $(TOOL_ANDROID_SDK)
  FLUTTER := $(TOOL_FLUTTER)/bin/flutter
  FLUTTER_BIN := $(TOOL_FLUTTER)/bin
endif

.PHONY: help build build-router clean distclean \
	build-chain build-chain-native build-router-native \
	check check-repos check-docker check-cross check-mobile \
	setup-cross setup-client setup-android setup-flutter setup-android-sdk \
	build-server build-client build-android build-mobile \
	docker-prep docker-run

.NOTPARALLEL: build build-router build-chain build-chain-native build-router-native \
	clean distclean

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

help:
	@printf '%s\n' \
	  'TrustTunnel build (Docker, same idea as the self-hosted GH runner)' \
	  '' \
	  '  make build          Server + client + signed release APKs' \
	  '  make build-router   Server + client only (OpenWrt / protocol work)' \
	  '  make clean          Clear caches & intermediate trees; keep products' \
	  '  make distclean      Delete all of $(OUT_DIR)/ (products + caches)' \
	  '  make help           This message' \
	  '' \
	  'Products (kept by clean):  $(OUT_DIR)/server/  client/  mobile/' \
	  'Needs: Docker + image $(BUILD_IMAGE)' \
	  'APK signing once:  cd ../tt-mobile && make aux-setup-android-signing' \
	  '                   → $$HOME/.config/tt-mobile/' \
	  '' \
	  'Typical loops:' \
	  '  make build-router              # after client/server code changes' \
	  '  make clean && make build       # full product refresh' \
	  '  make distclean && make build   # only if tooling is corrupted'

# ---------------------------------------------------------------------------
# Docker entry (host) — only Docker + image + workspace + .tt-build + keystore
# ---------------------------------------------------------------------------

docker-prep:
	@mkdir -p '$(OUT_DIR)' '$(DOCKER_HOME)' '$(DOCKER_HOME)/.config' '$(DOCKER_HOME)/.android' \
	  '$(DOCKER_HOME)/.dart-tool' \
	  '$(DOCKER_GRADLE_HOME)' '$(DOCKER_CARGO_HOME)' '$(DOCKER_PUB_CACHE)' \
	  '$(DOCKER_RUSTUP_HOME)' '$(DOCKER_CONAN_HOME)' \
	  '$(TOOL_FLUTTER)' '$(TOOL_ANDROID_SDK)' \
	  '$(OUT_DIR)/server' '$(OUT_DIR)/client' '$(OUT_DIR)/mobile' '$(OUT_DIR)/host-cc' \
	  '$(OUT_DIR)/zig/x86_64' '$(OUT_DIR)/zig/aarch64' \
	  '$(HOST_TT_SIGN_DIR)'
	@printf '%s\n' 'reporting=0' 'flutter-tool=1970-01-01,1' 'dart-tool=1970-01-01,1' \
	  > '$(DOCKER_HOME)/.dart-tool/dart-flutter-telemetry.config'

check-docker: check-repos
	@command -v '$(DOCKER)' >/dev/null 2>&1 || { echo 'missing Docker' >&2; exit 1; }
	@'$(DOCKER)' image inspect '$(BUILD_IMAGE)' >/dev/null 2>&1 \
	  || { echo "pulling $(BUILD_IMAGE)"; '$(DOCKER)' pull '$(BUILD_IMAGE)'; }

# GOAL = make target inside container (build-router-native | build-chain-native)
# Always --user $(id -u):$(id -g). Never omit --user (default container user can be root).
docker-run: check-docker docker-prep
	@test -n '$(GOAL)' || { echo 'docker-run requires GOAL=...' >&2; exit 1; }
	@test '$(HOST_UID)' != '0' || { echo 'error: refuse Docker as root; run make as your local user' >&2; exit 1; }
	@echo "==> $(GOAL) in $(BUILD_IMAGE) as uid=$(HOST_UID) gid=$(HOST_GID) (local user only; no root docker)"
	'$(DOCKER)' run --rm --init \
	  --user '$(HOST_UID):$(HOST_GID)' \
	  -e HOME=$(C_HOME) \
	  -e USER=ttbuild \
	  -e ANDROID_USER_HOME=$(C_HOME)/.android \
	  -e CARGO_HOME=$(C_CARGO) \
	  -e RUSTUP_HOME=$(C_RUSTUP) \
	  -e CONAN_HOME=$(C_CONAN) \
	  -e GRADLE_USER_HOME=$(C_GRADLE) \
	  -e PUB_CACHE=$(C_PUB) \
	  -e PATH=$(C_CARGO)/bin:/opt/cargo/bin:/opt/zig:/usr/lib/llvm-21/bin:/opt/cmake/bin:$(C_FLUTTER)/bin:$(C_ANDROID_SDK)/cmdline-tools/latest/bin:$(C_ANDROID_SDK)/platform-tools:/usr/local/bin:/usr/bin:/bin \
	  -e ANDROID_HOME=$(C_ANDROID_SDK) \
	  -e ANDROID_SDK_ROOT=$(C_ANDROID_SDK) \
	  -e ANDROID_NDK_HOME=$(C_ANDROID_SDK)/ndk/29.0.14206865 \
	  -e ANDROID_NDK_ROOT=$(C_ANDROID_SDK)/ndk/29.0.14206865 \
	  -e FLUTTER=$(C_FLUTTER)/bin/flutter \
	  -e FLUTTER_ROOT=$(C_FLUTTER) \
	  -e FLUTTER_SUPPRESS_ANALYTICS=true \
	  -e CI=true \
	  -e PUB_ENVIRONMENT=flutter_bot \
	  -e NATIVE_BUILD=1 \
	  -e SERVER_ARCHES='$(SERVER_ARCHES)' \
	  -e CLIENT_ARCHES='$(CLIENT_ARCHES)' \
	  -e SERVER_VERSION='$(SERVER_VERSION)' \
	  -e CLIENT_VERSION='$(CLIENT_VERSION)' \
	  -e MOBILE_VERSION='$(MOBILE_VERSION)' \
	  -e MOBILE_VERSION_CODE='$(MOBILE_VERSION_CODE)' \
	  -e FLUTTER_VERSION='$(FLUTTER_VERSION)' \
	  -e HOST_TT_SIGN_DIR='$(HOST_TT_SIGN_DIR)' \
	  -v '$(ROOT)':/workspace \
	  -v '$(DOCKER_HOME)':$(C_HOME) \
	  -v '$(DOCKER_GRADLE_HOME)':$(C_GRADLE) \
	  -v '$(DOCKER_CARGO_HOME)':$(C_CARGO) \
	  -v '$(DOCKER_RUSTUP_HOME)':$(C_RUSTUP) \
	  -v '$(DOCKER_CONAN_HOME)':$(C_CONAN) \
	  -v '$(DOCKER_PUB_CACHE)':$(C_PUB) \
	  -v '$(HOST_TT_SIGN_DIR)':'$(HOST_TT_SIGN_DIR)':ro \
	  -v '$(HOST_TT_SIGN_DIR)':$(C_HOME)/.config/tt-mobile:ro \
	  -w /workspace/tt-manage \
	  '$(BUILD_IMAGE)' \
	  bash -euo pipefail -c '\
	    mkdir -p "$$HOME" "$$HOME/.config" "$$HOME/.android" "$$HOME/.dart-tool" \
	      "$$CARGO_HOME" "$$GRADLE_USER_HOME" "$$PUB_CACHE" "$$CONAN_HOME" \
	      "$(C_OUT)/server" "$(C_OUT)/client" "$(C_FLUTTER)" "$(C_ANDROID_SDK)" "$$RUSTUP_HOME"; \
	    echo "==> resetting isolated Conan state"; \
	    find "$$CONAN_HOME" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +; \
	    mkdir -p "$$CONAN_HOME"; \
	    if ! compgen -G "$$RUSTUP_HOME/toolchains/*/bin/rustc" >/dev/null 2>&1 \
	       && compgen -G "/opt/rustup/toolchains/*/bin/rustc" >/dev/null 2>&1; then \
	      echo "==> copying image Rust toolchain metadata to writable cache"; \
	      cp -a /opt/rustup/. "$$RUSTUP_HOME/"; \
	    fi; \
	    printf "%s\n" "reporting=0" "flutter-tool=1970-01-01,1" "dart-tool=1970-01-01,1" \
	      > "$$HOME/.dart-tool/dart-flutter-telemetry.config"; \
	    git config --global --add safe.directory /workspace/tt-server; \
	    git config --global --add safe.directory /workspace/tt-client; \
	    git config --global --add safe.directory /workspace/tt-mobile; \
	    git config --global --add safe.directory /workspace/tt-manage; \
	    git config --global --add safe.directory $(C_FLUTTER); \
	    make $(GOAL) \
	      NATIVE_BUILD=1 \
	      SERVER_ARCHES="$$SERVER_ARCHES" CLIENT_ARCHES="$$CLIENT_ARCHES" \
	      SERVER_VERSION="$$SERVER_VERSION" CLIENT_VERSION="$$CLIENT_VERSION" \
	      MOBILE_VERSION="$$MOBILE_VERSION" MOBILE_VERSION_CODE="$$MOBILE_VERSION_CODE" \
	      FLUTTER_VERSION="$$FLUTTER_VERSION" \
	      ANDROID_HOME=$(C_ANDROID_SDK) ANDROID_SDK_ROOT=$(C_ANDROID_SDK) \
	      FLUTTER=$(C_FLUTTER)/bin/flutter \
	      HOST_TT_SIGN_DIR="$$HOST_TT_SIGN_DIR" \
	      HOST_TT_KEYSTORE="$$HOST_TT_SIGN_DIR/trusttunnel.keystore" \
	  '

build build-chain:
	@$(MAKE) docker-run GOAL=build-chain-native
	@echo "==> Full build complete:"
	@ls -lah '$(OUT_DIR)/mobile' 2>/dev/null || true
	@ls -lah '$(OUT_DIR)/server' '$(OUT_DIR)/client' 2>/dev/null || true

build-router:
	@$(MAKE) docker-run GOAL=build-router-native
	@echo "==> Router build complete:"
	@ls -lah '$(OUT_DIR)/server' '$(OUT_DIR)/client' 2>/dev/null || true

# ---------------------------------------------------------------------------
# Checks (inside container when NATIVE_BUILD=1)
# ---------------------------------------------------------------------------

check-repos:
	@for repo in '$(SERVER_DIR)' '$(CLIENT_DIR)' '$(MOBILE_DIR)'; do \
	  test -d "$$repo" || { echo "missing repository: $$repo" >&2; exit 1; }; \
	  git -C "$$repo" rev-parse --show-toplevel >/dev/null 2>&1 \
	    || { echo "not a Git worktree: $$repo" >&2; exit 1; }; \
	  echo "repo OK: $$repo"; \
	done

check-cross: check-repos
	@command -v cargo >/dev/null || { echo 'missing cargo' >&2; exit 1; }
	@command -v cmake >/dev/null || { echo 'missing cmake' >&2; exit 1; }
	@command -v zig >/dev/null || { echo 'missing zig' >&2; exit 1; }
	@command -v llvm-strip >/dev/null || { echo 'missing llvm-strip' >&2; exit 1; }
	@command -v rustup >/dev/null || { echo 'missing rustup' >&2; exit 1; }

check-mobile: check-repos
	@test -x '$(FLUTTER)' || { echo "missing Flutter at $(FLUTTER) — run setup-flutter" >&2; exit 1; }
	@test -d '$(ANDROID_SDK_ROOT)/platforms' \
	  || { echo "missing Android platforms under $(ANDROID_SDK_ROOT) — run setup-android-sdk" >&2; exit 1; }
	@test -x '$(ANDROID_SDK_ROOT)/cmake/3.31.6/bin/cmake' \
	  || { echo "missing Android CMake 3.31.6 under $(ANDROID_SDK_ROOT)" >&2; exit 1; }
	@test -d '$(ANDROID_SDK_ROOT)/ndk/29.0.14206865' \
	  || { echo "missing NDK 29.0.14206865 under $(ANDROID_SDK_ROOT)" >&2; exit 1; }

ifeq ($(NATIVE_BUILD),1)
check: check-cross check-mobile
else
check: check-docker
endif

# ---------------------------------------------------------------------------
# Tooling bootstrap (inside container — mirrors CI "Install native build tools")
# ---------------------------------------------------------------------------

# Flutter: git clone pinned tag into .tt-build/flutter (CI: RUNNER_TEMP/flutter @ 3.44.8)
setup-flutter:
	@set -euo pipefail; \
	fl='$(if $(filter 1,$(NATIVE_BUILD)),$(C_FLUTTER),$(TOOL_FLUTTER))'; \
	ver='$(FLUTTER_VERSION)'; \
	if [ -x "$$fl/bin/flutter" ] && [ -d "$$fl/.git" ]; then \
	  cur=$$(git -C "$$fl" describe --tags --exact-match 2>/dev/null || true); \
	  if [ "$$cur" = "$$ver" ]; then echo "Flutter $$ver already at $$fl"; exit 0; fi; \
	fi; \
	echo "==> Bootstrapping Flutter $$ver → $$fl"; \
	rm -rf "$$fl"; \
	git clone --depth 1 --branch "$$ver" '$(FLUTTER_GIT)' "$$fl"; \
	git config --global --add safe.directory "$$fl"; \
	export FLUTTER_SUPPRESS_ANALYTICS=true CI=true; \
	export HOME="$${HOME:-$(C_HOME)}"; \
	mkdir -p "$$HOME/.dart-tool"; \
	printf '%s\n' 'reporting=0' > "$$HOME/.dart-tool/dart-flutter-telemetry.config"; \
	"$$fl/bin/flutter" --disable-analytics >/dev/null 2>&1 || true; \
	"$$fl/bin/dart" --disable-analytics >/dev/null 2>&1 || true; \
	"$$fl/bin/flutter" --suppress-analytics precache --android; \
	echo "Flutter ready: $$("$$fl/bin/flutter" --suppress-analytics --version | head -1)"

# Android SDK packages into .tt-build/android-sdk (writable); use image sdkmanager.
setup-android-sdk:
	@set -euo pipefail; \
	sdk='$(if $(filter 1,$(NATIVE_BUILD)),$(C_ANDROID_SDK),$(TOOL_ANDROID_SDK))'; \
	sm='$(IMAGE_SDKMANAGER)'; \
	if [ ! -x "$$sm" ]; then \
	  sm=$$(command -v sdkmanager || true); \
	fi; \
	if [ ! -x "$$sm" ]; then \
	  echo "error: no sdkmanager (expected $(IMAGE_SDKMANAGER))" >&2; exit 1; \
	fi; \
	export HOME="$${HOME:-$(C_HOME)}"; \
	export ANDROID_USER_HOME="$$HOME/.android"; \
	mkdir -p "$$HOME/.android" "$$sdk"; \
	if [ -d "$$sdk/platforms/android-36" ] \
	   && [ -x "$$sdk/cmake/3.31.6/bin/cmake" ] \
	   && [ -d "$$sdk/ndk/29.0.14206865" ]; then \
	  echo "Android SDK packages already at $$sdk"; exit 0; \
	fi; \
	echo "==> Installing Android packages into $$sdk (same set as CI)"; \
	yes | "$$sm" --sdk_root="$$sdk" --licenses >/dev/null || true; \
	"$$sm" --sdk_root="$$sdk" \
	  '$(ANDROID_PLATFORM)' '$(ANDROID_BUILD_TOOLS)' \
	  '$(ANDROID_NDK_PKG)' '$(ANDROID_CMAKE_PKG)'; \
	test -d "$$sdk/platforms/android-36"; \
	test -x "$$sdk/cmake/3.31.6/bin/cmake"; \
	test -d "$$sdk/ndk/29.0.14206865"; \
	echo "Android SDK ready at $$sdk"

setup-cross:
	@command -v rustup >/dev/null || { echo 'missing rustup' >&2; exit 1; }
	@toolchain=$$(sed -n 's/^[[:space:]]*channel[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' '$(SERVER_DIR)/rust-toolchain.toml' | head -1); \
	  test -n "$$toolchain" || { echo 'error: cannot read server Rust toolchain' >&2; exit 1; }; \
	  rustup toolchain install "$$toolchain" --profile minimal; \
	  for target in x86_64-unknown-linux-musl aarch64-unknown-linux-musl; do \
	    rustup target add --toolchain "$$toolchain" "$$target"; \
	    rustup target list --installed --toolchain "$$toolchain" | grep -qx "$$target" \
	      || { echo "error: Rust target $$target missing from toolchain $$toolchain" >&2; exit 1; }; \
	  done
	@command -v cargo-zigbuild >/dev/null || cargo install --locked --version 0.22.3 cargo-zigbuild

# Client Conan: prefer image/system `conan` (adguard/core-libs ships it). Fall back
# to tt-client/env only when needed. That env is on a host↔Docker bind-mount, so a
# venv created on the host has absolute shebangs under /home/... which ENOENT inside
# /workspace — never leave a broken env/bin on PATH ahead of system conan.
setup-client:
	@set -e; \
	use_system=0; \
	if command -v conan >/dev/null 2>&1 && conan --version >/dev/null 2>&1; then \
	  use_system=1; \
	fi; \
	if [ "$$use_system" = 1 ]; then \
	  if [ -d '$(CLIENT_ENV)' ]; then \
	    env_ok=1; \
	    if [ -f '$(CLIENT_ENV)/pyvenv.cfg' ] && ! grep -qF '$(CLIENT_ENV)' '$(CLIENT_ENV)/pyvenv.cfg'; then env_ok=0; fi; \
	    if [ -e '$(CLIENT_CONAN)' ] && ! '$(CLIENT_CONAN)' --version >/dev/null 2>&1; then env_ok=0; fi; \
	    if [ "$$env_ok" = 0 ]; then \
	      echo "Removing unusable bind-mounted client venv at $(CLIENT_ENV) (host path / stale shebang; using system Conan)"; \
	      rm -rf '$(CLIENT_ENV)'; \
	    fi; \
	  fi; \
	  echo "Using system Conan: $$(conan --version)"; \
	  conan profile detect --force; \
	  if (cd '$(CLIENT_DIR)' && conan graph info . --profile:host=default >/dev/null 2>&1); then \
	    echo "Conan dependencies already bootstrapped, skipping clone/export."; \
	  else \
	    cd '$(CLIENT_DIR)' && python3 scripts/bootstrap_conan_deps.py; \
	  fi; \
	  exit 0; \
	fi; \
	need_venv=0; \
	if [ ! -e '$(CLIENT_ENV)/bin/python3' ] || [ ! -x '$(CLIENT_ENV)/bin/python3' ]; then need_venv=1; \
	elif ! '$(CLIENT_ENV)/bin/python3' -c 'import sys' >/dev/null 2>&1; then need_venv=1; \
	elif ! '$(CLIENT_ENV)/bin/python3' -c 'import pip' >/dev/null 2>&1; then need_venv=1; \
	elif [ -f '$(CLIENT_ENV)/pyvenv.cfg' ] && ! grep -qF '$(CLIENT_ENV)' '$(CLIENT_ENV)/pyvenv.cfg'; then need_venv=1; \
	elif [ -x '$(CLIENT_CONAN)' ] && ! '$(CLIENT_CONAN)' --version >/dev/null 2>&1; then need_venv=1; \
	fi; \
	if [ "$$need_venv" = 1 ]; then \
	  echo "Creating client venv at $(CLIENT_ENV) (system Conan unavailable)"; \
	  rm -rf '$(CLIENT_ENV)'; \
	  if ! python3 -m venv --without-pip '$(CLIENT_ENV)' 2>/dev/null \
	     && ! python3 -m venv '$(CLIENT_ENV)'; then \
	    echo "error: python3 -m venv failed for $(CLIENT_ENV)" >&2; exit 1; \
	  fi; \
	  if ! '$(CLIENT_ENV)/bin/python3' -c 'import pip' >/dev/null 2>&1; then \
	    '$(CLIENT_ENV)/bin/python3' -c 'import ensurepip; ensurepip.bootstrap()' >/dev/null 2>&1 || true; \
	  fi; \
	  if ! '$(CLIENT_ENV)/bin/python3' -c 'import pip' >/dev/null 2>&1; then \
	    echo "Bootstrapping pip into venv via get-pip.py"; \
	    python3 -c 'import urllib.request; urllib.request.urlretrieve("https://bootstrap.pypa.io/get-pip.py","/tmp/tt-get-pip.py")'; \
	    '$(CLIENT_ENV)/bin/python3' /tmp/tt-get-pip.py --disable-pip-version-check; \
	  fi; \
	  '$(CLIENT_ENV)/bin/python3' -c 'import pip' \
	    || { echo "error: venv still has no pip after recreate" >&2; exit 1; }; \
	fi; \
	'$(CLIENT_PYTHON)' -m pip install --disable-pip-version-check --upgrade pip conan; \
	if [ -f '$(CLIENT_DIR)/requirements.txt' ]; then \
	  '$(CLIENT_PYTHON)' -m pip install --disable-pip-version-check -r '$(CLIENT_DIR)/requirements.txt'; \
	fi; \
	if [ ! -x '$(CLIENT_CONAN)' ] || ! '$(CLIENT_CONAN)' --version >/dev/null 2>&1; then \
	  '$(CLIENT_PYTHON)' -m pip install --disable-pip-version-check --force-reinstall 'conan>=2.0.5'; \
	fi; \
	'$(CLIENT_CONAN)' --version >/dev/null \
	  || { echo "error: conan still not runnable in $(CLIENT_ENV)" >&2; exit 1; }; \
	PATH="$(CLIENT_ENV)/bin:$$PATH" '$(CLIENT_CONAN)' profile detect --force; \
	if (cd '$(CLIENT_DIR)' && PATH="$(CLIENT_ENV)/bin:$$PATH" conan graph info . --profile:host=default >/dev/null 2>&1); then \
	  echo "Conan dependencies already bootstrapped, skipping clone/export."; \
	else \
	  cd '$(CLIENT_DIR)' && PATH="$(CLIENT_ENV)/bin:$$PATH" '$(CLIENT_PYTHON)' scripts/bootstrap_conan_deps.py; \
	fi

setup-android: setup-android-sdk setup-client
	@rustup target add aarch64-linux-android armv7-linux-androideabi \
	  x86_64-linux-android i686-linux-android 2>/dev/null || true
	@command -v cargo-ndk >/dev/null || cargo install --locked cargo-ndk

# ---------------------------------------------------------------------------
# Build graph (inside container)
# ---------------------------------------------------------------------------

build-server: check-cross setup-cross
	@mkdir -p '$(OUT_DIR)/server'
	@set -e; for arch in $(SERVER_ARCHES); do \
	  case "$$arch" in \
	    x86_64) target=x86_64-unknown-linux-musl; zig_target=x86_64-linux-musl;; \
	    aarch64) target=aarch64-unknown-linux-musl; zig_target=aarch64-linux-musl;; \
	    *) echo "unsupported server arch: $$arch" >&2; exit 1;; \
	  esac; \
	  zig_dir='$(OUT_DIR)/zig/'"$$arch"; mkdir -p "$$zig_dir"; \
	  ln -sf '$(CURDIR)/scripts/zig-compiler' "$$zig_dir/zig-cc"; \
	  ln -sf '$(CURDIR)/scripts/zig-compiler' "$$zig_dir/zig-cxx"; \
	  output="$(OUT_DIR)/server/tt-server-$(SERVER_VERSION)-linux-$$arch"; \
	  (cd '$(SERVER_DIR)' && env CC="$$zig_dir/zig-cc" CXX="$$zig_dir/zig-cxx" \
	    scripts/ci/build-musl-target.sh "$$arch" '$(SERVER_VERSION)' "$$output"); \
	done

build-client: check-cross setup-cross setup-client
	@mkdir -p '$(OUT_DIR)/client' '$(OUT_DIR)/host-cc'
	@set -e; \
	wrap='$(OUT_DIR)/host-cc'; \
	ln -sf '$(CURDIR)/scripts/zig-compiler' "$$wrap/cc"; \
	ln -sf '$(CURDIR)/scripts/zig-compiler' "$$wrap/c++"; \
	real_cc="$$(command -v cc || command -v gcc)"; \
	real_cxx="$$(command -v c++ || command -v g++)"; \
	ln -sf "$$real_cc" "$$wrap/tt-host-cc"; \
	ln -sf "$$real_cxx" "$$wrap/tt-host-cxx"; \
	client_path="$$wrap:$(CLIENT_ENV)/bin:$$PATH"; \
	for arch in $(CLIENT_ARCHES); do \
	  build_dir="cmake-build-musl-cross-$$arch-relwithdebinfo"; \
	  rm -f '$(CLIENT_DIR)/'"$$build_dir"/.tt-configured \
	    '$(CLIENT_DIR)/'"$$build_dir"/CMakeCache.txt; \
	  (cd '$(CLIENT_DIR)' && PATH="$$client_path" TT_CLIENT_VERSION='$(CLIENT_VERSION)' SKIP_BOOTSTRAP=1 \
	    $(MAKE) PRESET="musl-cross-""$$arch""-relwithdebinfo" BUILD_DIR="$$build_dir" build_trusttunnel_client); \
	  input="$(CLIENT_DIR)/$$build_dir/trusttunnel/trusttunnel_client"; \
	  output="$(OUT_DIR)/client/tt-client-$(CLIENT_VERSION)-linux-$$arch"; \
	  llvm-strip -o "$$output" "$$input"; chmod 755 "$$output"; \
	done

build-android: setup-android
	@mkdir -p '$(MOBILE_DIR)/third_party/tt-client-maven'
	@rm -f '$(CLIENT_DIR)/platform/android/local.properties'
	@printf 'sdk.dir=%s\ncmake.dir=%s\n' '$(ANDROID_SDK_ROOT)' '$(ANDROID_SDK_ROOT)/cmake/3.31.6' \
	  > '$(CLIENT_DIR)/platform/android/local.properties'
	cd '$(CLIENT_DIR)/platform/android' && PATH="$(CLIENT_ENV)/bin:$$PATH" \
	  TT_CLIENT_VERSION='$(CLIENT_VERSION)' \
	  ./gradlew :lib:publishReleasePublicationToTtClientMavenRepository --no-daemon
	rm -rf '$(MOBILE_DIR)/third_party/tt-client-maven'/*
	cp -a '$(CLIENT_DIR)/platform/android/lib/build/maven-repo/.' \
	  '$(MOBILE_DIR)/third_party/tt-client-maven/'

# Signing comes only from $HOME/.config/tt-mobile (HOST_TT_SIGN_DIR), never from
# repo-tree android/local.properties (that file is for sdk.dir only and is cleaned).
build-mobile: setup-flutter build-android
	@set -euo pipefail; \
	if [ -z "$${ORG_GRADLE_PROJECT_signingConfigKeyStorePath:-}" ]; then \
	  props=''; \
	  for cand in \
	    '$(HOST_TT_SIGN_DIR)/local.properties' \
	    "$${HOME}/.config/tt-mobile/local.properties"; do \
	    if [ -f "$$cand" ] && grep -q '^signingConfigKeyStorePath=' "$$cand"; then \
	      props="$$cand"; break; \
	    fi; \
	  done; \
	  ks=''; alias='trusttunnel'; kpass=''; spass=''; \
	  if [ -n "$$props" ]; then \
	    ks=$$(grep -E '^signingConfigKeyStorePath=' "$$props" | head -1 | cut -d= -f2- || true); \
	    alias=$$(grep -E '^signingConfigKeyAlias=' "$$props" | head -1 | cut -d= -f2- || true); \
	    kpass=$$(grep -E '^signingConfigKeyPassword=' "$$props" | head -1 | cut -d= -f2- || true); \
	    spass=$$(grep -E '^signingConfigKeyStorePassword=' "$$props" | head -1 | cut -d= -f2- || true); \
	  fi; \
	  if [ ! -f "$$ks" ]; then \
	    for cand in '$(HOST_TT_KEYSTORE)' \
	      '$(HOST_TT_SIGN_DIR)/trusttunnel.keystore' \
	      "$${HOME}/.config/tt-mobile/trusttunnel.keystore"; do \
	      if [ -f "$$cand" ]; then ks="$$cand"; break; fi; \
	    done; \
	  fi; \
	  if [ ! -f "$$ks" ] || [ -z "$$kpass" ] || [ -z "$$spass" ]; then \
	    echo "error: release signing not configured for replaceable APKs." >&2; \
	    echo "  Once:  cd $(MOBILE_DIR) && make aux-setup-android-signing" >&2; \
	    echo "         → \$$HOME/.config/tt-mobile/trusttunnel.keystore" >&2; \
	    echo "  (Docker resolves via HOST_TT_SIGN_DIR=$(HOST_TT_SIGN_DIR))" >&2; \
	    exit 1; \
	  fi; \
	  export ORG_GRADLE_PROJECT_signingConfigKeyStorePath="$$ks"; \
	  export ORG_GRADLE_PROJECT_signingConfigKeyAlias="$${alias:-trusttunnel}"; \
	  export ORG_GRADLE_PROJECT_signingConfigKeyPassword="$$kpass"; \
	  export ORG_GRADLE_PROJECT_signingConfigKeyStorePassword="$$spass"; \
	fi; \
	export PATH="$(FLUTTER_BIN):$(CLIENT_ENV)/bin:$$PATH"; \
	export FLUTTER_SUPPRESS_ANALYTICS=true CI=true; \
	export ANDROID_HOME='$(ANDROID_SDK_ROOT)' ANDROID_SDK_ROOT='$(ANDROID_SDK_ROOT)'; \
	mkdir -p "$${HOME}/.dart-tool"; \
	printf '%s\n' 'reporting=0' > "$${HOME}/.dart-tool/dart-flutter-telemetry.config"; \
	'$(FLUTTER)' --disable-analytics >/dev/null 2>&1 || true; \
	"$$(dirname '$(FLUTTER)')/dart" --disable-analytics >/dev/null 2>&1 || true; \
	rm -f '$(MOBILE_DIR)/.flutter-plugins-dependencies' || true; \
	# sdk.dir only — never persist signing secrets in the repo tree \
	mkdir -p '$(MOBILE_DIR)/android'; \
	printf 'sdk.dir=%s\n' '$(ANDROID_SDK_ROOT)' > '$(MOBILE_DIR)/android/local.properties'; \
	cd '$(MOBILE_DIR)'; \
	'$(FLUTTER)' --suppress-analytics pub get; \
	test -f .dart_tool/package_config.json; \
	$(MAKE) gen; \
	$(MAKE) ln; \
	test -f .dart_tool/package_config.json; \
	ORG_GRADLE_PROJECT_ttClientVersion='$(CLIENT_VERSION)' \
	ORG_GRADLE_PROJECT_signingConfigKeyStorePath="$$ORG_GRADLE_PROJECT_signingConfigKeyStorePath" \
	ORG_GRADLE_PROJECT_signingConfigKeyAlias="$$ORG_GRADLE_PROJECT_signingConfigKeyAlias" \
	ORG_GRADLE_PROJECT_signingConfigKeyPassword="$$ORG_GRADLE_PROJECT_signingConfigKeyPassword" \
	ORG_GRADLE_PROJECT_signingConfigKeyStorePassword="$$ORG_GRADLE_PROJECT_signingConfigKeyStorePassword" \
	'$(FLUTTER)' --suppress-analytics build apk --release --split-per-abi \
	  --build-name='$(MOBILE_VERSION)' --build-number='$(MOBILE_VERSION_CODE)' \
	  --dart-define="TT_CLIENT_VERSION=$(CLIENT_VERSION)"; \
	mkdir -p '$(OUT_DIR)/mobile'; \
	out='$(MOBILE_DIR)/build/app/outputs/flutter-apk'; \
	for abi in arm64-v8a armeabi-v7a x86_64; do \
	  src="$$out/app-$$abi-release.apk"; \
	  if [ -f "$$src" ]; then cp "$$src" '$(OUT_DIR)/mobile'/tt-mobile-$(MOBILE_VERSION)-$$abi-release.apk; fi; \
	done; \
	test -f '$(OUT_DIR)/mobile/tt-mobile-$(MOBILE_VERSION)-arm64-v8a-release.apk'; \
	ls -lah '$(OUT_DIR)/mobile'/tt-mobile-*-release.apk

build-router-native: check-cross
	$(MAKE) build-server
	$(MAKE) build-client
	@echo "Router build complete: $(OUT_DIR)/server $(OUT_DIR)/client"

build-chain-native: check-cross
	$(MAKE) build-server
	$(MAKE) build-client
	$(MAKE) setup-flutter
	$(MAKE) setup-android-sdk
	$(MAKE) build-mobile
	@echo "Build chain complete: $(OUT_DIR)"

# ---------------------------------------------------------------------------
# Clean — only two public targets: clean | distclean
# ---------------------------------------------------------------------------

# Safe default: clear junk so the next build is fresh, but keep deploy outputs.
clean:
	@# Tooling / Docker caches under OUT_DIR (not the finished binaries/APKs)
	@rm -rf '$(OUT_DIR)/flutter' '$(OUT_DIR)/android-sdk' \
	  '$(OUT_DIR)/docker-home' '$(OUT_DIR)/docker-gradle' \
	  '$(OUT_DIR)/docker-cargo' '$(OUT_DIR)/docker-pub-cache' \
	  '$(OUT_DIR)/flutter-tools-dart' '$(OUT_DIR)/flutter-bin-cache' \
	  '$(OUT_DIR)/host-cc' '$(OUT_DIR)/zig' \
	  '$(OUT_DIR)/test-sdk' 2>/dev/null || true
	@# Sibling intermediate trees
	@rm -rf '$(SERVER_DIR)/target' \
	  '$(CLIENT_DIR)'/cmake-build-* '$(CLIENT_DIR)'/.conan2 \
	  '$(CLIENT_DIR)'/.venv '$(CLIENT_DIR)'/env \
	  '$(CLIENT_DIR)'/platform/android/.gradle \
	  '$(CLIENT_DIR)'/platform/android/lib/build \
	  '$(CLIENT_DIR)'/platform/android/lib/.cxx \
	  '$(CLIENT_DIR)'/platform/android/build \
	  '$(CLIENT_DIR)'/build_* \
	  '$(MOBILE_DIR)/third_party/tt-client-maven' \
	  '$(MOBILE_DIR)/build' '$(MOBILE_DIR)/.dart_tool' 2>/dev/null || true
	@rm -f '$(CLIENT_DIR)/platform/android/local.properties' \
	  '$(MOBILE_DIR)/android/local.properties' \
	  '$(MOBILE_DIR)/.flutter-plugins-dependencies' 2>/dev/null || true
	@mkdir -p '$(OUT_DIR)/server' '$(OUT_DIR)/client' '$(OUT_DIR)/mobile'
	@echo "==> clean: caches cleared; products kept in $(OUT_DIR)/{server,client,mobile}"

# Full wipe when you really want a cold start (products + tool caches).
distclean: clean
	@rm -rf '$(OUT_DIR)'
	@echo "==> distclean: removed $(OUT_DIR)"
