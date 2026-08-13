#!/usr/bin/env bash
# tt-server.sh — TrustTunnel endpoint manager (run ON the VPS as root).
# Sibling: tt-client-openwrt.sh (router client; uses clients/<name>.toml from add-user).
# Data lifecycle and copy-paste flows: $0 help
set -euo pipefail

VERSION_SCRIPT="0.1.28"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATES_SERVER="${SCRIPT_DIR}/templates/server"

# Fixed layout — no per-site knobs (robustness > flexibility).
INSTALL_DIR="/opt/moreprivate/tt-server"
SERVICE_USER="moreprivate"
SERVICE_NAME="moreprivate-tt-server"
CUSTOM_SNI=""
HTTP_CONNECTIONS_NUM=0
# Tolerate last-mile bufferbloat under load (library default health check is 7s).
HEALTH_CHECK_TIMEOUT_MS=15000
UPSTREAM_PROTOCOL="http2"
CERT_LIVE_NAME="ocserv-ip"
# Release source; override only for an intentional mirror.
GITHUB_REPO="${TT_GITHUB_REPO:-moreprivate/tt-server}"

BIN_NAME="tt-server"
RELEASE_ASSET_PREFIX="tt-server"
UNIT_PATH="/etc/systemd/system/${SERVICE_NAME}.service"
CREDS="${INSTALL_DIR}/credentials.toml"
VPN_TOML="${INSTALL_DIR}/vpn.toml"
HOSTS_TOML="${INSTALL_DIR}/hosts.toml"
CERT_DIR="${INSTALL_DIR}/certs"
CERT_FC="${CERT_DIR}/fullchain.pem"
CERT_PK="${CERT_DIR}/privkey.pem"
CLIENTS_DIR="${INSTALL_DIR}/clients"
CLIENT_PROTOCOL_FILE="${INSTALL_DIR}/client-protocol"
ENDPOINT_IP_FILE="${INSTALL_DIR}/endpoint.ip"
RELEASE_META="${INSTALL_DIR}/release.env"
LE_LIVE="/etc/letsencrypt/live/${CERT_LIVE_NAME}"
LE_HOOK="/etc/letsencrypt/renewal-hooks/deploy/moreprivate-tt-server-reload"

_APT_UPDATED=0
_ST_FAILS=0
_ST_WARNS=0
_BIN_TX_ACTIVE=0
_BIN_TX_OLD=""
_BIN_TX_NEW=""
_BIN_TX_CREATED=0
_BIN_TX_SERVICE_WAS_ACTIVE=0

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
need_root() { [[ "$(id -u)" -eq 0 ]] || die "run as root"; }

# --- small utils ---
need_cmds() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null || die "need command: $c"; done
}

validate_custom_sni() {
  local value="$1"
  [[ -n "$value" ]] || die "install requires --custom-sni HOST"
  [[ "${#value}" -le 253 ]] || die "custom SNI is too long"
  [[ ! "$value" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "custom SNI must be a DNS hostname, not an IP address"
  [[ "$value" =~ ^[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?)+$ ]] \
    || die "invalid custom SNI hostname: ${value}"
}

validate_upstream_protocol() {
  [[ "$1" == "auto" || "$1" == "http2" || "$1" == "http3" ]] \
    || die "upstream protocol must be auto, http2, or http3"
}

# Install packages only if missing (skip apt-get update when everything is present —
# offline --binary/--skip-certbot re-runs must not die on "apt-get update" with no net).
apt_install() {
  local p need_apt=0
  export DEBIAN_FRONTEND=noninteractive
  for p in "$@"; do
    if ! dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
      need_apt=1
      break
    fi
  done
  if [[ "$need_apt" -eq 0 ]]; then
    return 0
  fi
  command -v apt-get >/dev/null || die "need apt-get to install: $*"
  if [[ "${_APT_UPDATED}" -ne 1 ]]; then
    apt-get update -y -qq \
      || die "apt-get update failed (network required to install: $*)"
    _APT_UPDATED=1
  fi
  apt-get install -y -qq "$@" || die "apt-get install failed: $*"
}

is_installed() { [[ -x "${INSTALL_DIR}/${BIN_NAME}" ]]; }

# root:service 0640 (config / secrets readable by daemon)
own_conf() {
  chown "root:${SERVICE_USER}" "$@"
  chmod 0640 "$@"
}

# root:service 0755 binary
own_bin() {
  chown "root:${SERVICE_USER}" "$1"
  chmod 0755 "$1"
}

binary_link_path() {
  printf '%s/%s' "${INSTALL_DIR}" "${BIN_NAME}"
}

binary_resolve_link() {
  local link target
  link="$(binary_link_path)"
  [[ -L "$link" ]] || return 1
  target="$(readlink "$link")"
  [[ "$target" == /* ]] || target="${INSTALL_DIR}/${target}"
  case "$target" in
    "${INSTALL_DIR}/${RELEASE_ASSET_PREFIX}-"*-linux-*) ;;
    *) return 1 ;;
  esac
  [[ -x "$target" ]] || return 1
  printf '%s' "$target"
}

binary_switch_link() {
  local target="$1" link tmp
  link="$(binary_link_path)"
  tmp="${link}.link.$$"
  rm -f "$tmp"
  ln -s "$(basename "$target")" "$tmp"
  mv -f "$tmp" "$link"
}

binary_tx_begin() {
  local link
  link="$(binary_link_path)"
  _BIN_TX_ACTIVE=1
  _BIN_TX_OLD=""
  _BIN_TX_NEW=""
  _BIN_TX_CREATED=0
  _BIN_TX_SERVICE_WAS_ACTIVE=0
  if [[ -e "$link" || -L "$link" ]]; then
    [[ -L "$link" ]] \
      || die "binary path is not a managed symlink: ${link} (purge, then install cleanly)"
    _BIN_TX_OLD="$(binary_resolve_link)" \
      || die "binary symlink target missing or not executable: ${link}"
  fi
  # Do not prune here. A failed candidate must leave every pre-transaction
  # binary intact; successful commit is the only place that removes old files.
  if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    _BIN_TX_SERVICE_WAS_ACTIVE=1
  fi
  # The service may legitimately be absent, stopped, or disabled before an
  # install/upgrade. Record prior state without leaking the probe status.
  return 0
}

binary_tx_install() {
  local src="$1" tag="$2" target src_sum target_sum
  [[ "$tag" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid binary version: ${tag}"
  target="${INSTALL_DIR}/$(basename "$src")"
  [[ "$(basename "$src")" == "${RELEASE_ASSET_PREFIX}-${tag}-linux-"* ]] \
    || die "binary filename does not match its release tag: $(basename "$src")"
  if [[ -e "$target" ]]; then
    [[ -f "$target" && -x "$target" ]] || die "invalid versioned binary: ${target}"
    src_sum="$(sha256sum "$src" | awk '{print $1}')"
    target_sum="$(sha256sum "$target" | awk '{print $1}')"
    [[ "$src_sum" == "$target_sum" ]] \
      || die "versioned binary collision with different content: ${target}"
  else
    install -m 0755 -o root -g "${SERVICE_USER}" "$src" "$target"
    _BIN_TX_CREATED=1
  fi
  "$target" --version >/dev/null 2>&1 \
    || die "binary not runnable (wrong arch or corrupt?): ${target}"
  _BIN_TX_NEW="$target"
  binary_switch_link "$target"
  "$target" --version 2>/dev/null | head -1 | sed 's/^/  /' || true
}

binary_tx_rollback() {
  [[ "$_BIN_TX_ACTIVE" -eq 1 ]] || return 0
  if [[ -n "$_BIN_TX_OLD" && -x "$_BIN_TX_OLD" ]]; then
    binary_switch_link "$_BIN_TX_OLD"
    echo "NOTICE: restored working binary $(basename "$_BIN_TX_OLD")" >&2
  else
    rm -f "$(binary_link_path)"
  fi
  if [[ "$_BIN_TX_CREATED" -eq 1 && -n "$_BIN_TX_NEW" && "$_BIN_TX_NEW" != "$_BIN_TX_OLD" ]]; then
    rm -f "$_BIN_TX_NEW"
  fi
  _BIN_TX_ACTIVE=0
  if [[ "$_BIN_TX_SERVICE_WAS_ACTIVE" -eq 1 && -n "$_BIN_TX_OLD" && -f "$UNIT_PATH" ]]; then
    systemctl restart "${SERVICE_NAME}.service" >/dev/null 2>&1 \
      || echo "WARNING: old binary restored but service restart failed" >&2
  fi
}

binary_tx_commit() {
  local keep="$1" previous="${2:-}" f
  [[ "$_BIN_TX_ACTIVE" -eq 1 ]] || return 0
  for f in "${INSTALL_DIR}/${RELEASE_ASSET_PREFIX}-"*-linux-*; do
    [[ -e "$f" ]] || continue
    [[ "$f" == "$keep" || "$f" == "$previous" ]] || rm -f "$f"
  done
  _BIN_TX_ACTIVE=0
  _BIN_TX_OLD=""
  _BIN_TX_NEW=""
  _BIN_TX_CREATED=0
}

binary_tx_on_exit() {
  local rc="$1"
  [[ "$rc" -eq 0 ]] || binary_tx_rollback
}

binary_previous() {
  local current="$1" f found=""
  for f in "${INSTALL_DIR}/${RELEASE_ASSET_PREFIX}-"*-linux-*; do
    [[ -f "$f" && -x "$f" && "$f" != "$current" ]] || continue
    [[ -z "$found" ]] || die "multiple rollback binaries found; run upgrade to prune them"
    found="$f"
  done
  [[ -n "$found" ]] || return 1
  printf '%s' "$found"
}

# Create dir 0750 root:service
ensure_dir() {
  install -d -m 0750 -o root -g "${SERVICE_USER}" "$1"
}

# TOML basic-string: key = "value"  → print value or empty
toml_get_str() {
  local key="$1" file="$2"
  [[ -f "$file" ]] || return 0
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -1
}

openssl_date_epoch() {
  date -u -d "$1" +%s 2>/dev/null \
    || date -u -j -f '%b %e %H:%M:%S %Y %Z' "$1" +%s 2>/dev/null \
    || echo 0
}

file_meta() {
  local p="$1"
  if [[ -e "$p" ]]; then
    stat -c '%a %U:%G %s' "$p" 2>/dev/null || stat -f '%OLp %Su:%Sg %z' "$p" 2>/dev/null || echo "?"
  else
    echo "missing"
  fi
}

# status lines
_st_ok() { echo "  ok    $*"; }
_st_warn() { echo "  warn  $*"; _ST_WARNS=$((_ST_WARNS + 1)); }
_st_fail() { echo "  FAIL  $*"; _ST_FAILS=$((_ST_FAILS + 1)); }
_st_info() { echo "  info  $*"; }

# ok+meta if file exists, else fail (full path)
_st_file() {
  local p="$1"
  if [[ -f "$p" ]]; then
    _st_ok "${p}  meta=$(file_meta "$p")"
  else
    _st_fail "${p} missing"
  fi
}

usage() {
  cat <<EOF
NAME
    tt-server.sh ${VERSION_SCRIPT} — TrustTunnel endpoint (root on this VPS)

SYNOPSIS
    $0 install --custom-sni HOST [--upstream-protocol auto|http2|http3] [--icmp-interface IFACE] [--binary PATH | --version TAG]
    $0 install --custom-sni HOST --skip-certbot [--upstream-protocol auto|http2|http3] [--icmp-interface IFACE] [--binary PATH | --version TAG]
    $0 upgrade [--binary PATH | --version TAG]
    $0 add-user <name>
    $0 del-user <name>
    $0 list-users | status
    $0 disable | enable
    $0 rollback
    $0 purge
    $0 help

DESCRIPTION
    Fixed layout: ${INSTALL_DIR}  user=${SERVICE_USER}

    install
        --upstream-protocol auto|http2|http3 selects the transport written to
        generated client files (default: http2). The endpoint always enables H2+H3.
        --custom-sni HOST is mandatory. It is written to hosts.toml and every
        generated client configuration. HOST must be an ASCII DNS hostname,
        not an IP address.
        Binary: latest published ${GITHUB_REPO} release (default),
                or --version TAG, or --binary PATH.
        Release downloads require a matching SHA-256 sidecar; there is no
        fallback to upstream or to GitHub Actions artifacts.
        Public IP: https://1.1.1.1|1.0.0.1/cdn-cgi/trace → ${ENDPOINT_IP_FILE}.
        TLS: LE shortlived IP cert (~6d) via certbot --preferred-profile shortlived
             --ip-address (not -d; LE rejects bare IP as DNS name). Auto-renew + hook → ${CERT_DIR}/.
             --skip-certbot: use existing ${CERT_FC} + ${CERT_PK}; YOU renew.
        Firewall: ufw allow 22, 80, 443 BEFORE certbot (HTTP-01 needs :80).
        ICMP: enables tunneled ICMP in [icmp]. The VPS egress interface is
              auto-detected; override it with --icmp-interface IFACE.
              The systemd service receives CAP_NET_RAW for its raw ICMP socket.
              This is unrelated to ping_enable, which remains false because it
              controls the endpoint's public HTTP /ping handler.
        Full reconciliation: dir, service user, binary, unit, configs, certs,
        ufw, then enable/start/verify the endpoint. The same behavior applies
        to a first install and to an existing installation.
        Does NOT create VPN users. With zero users the endpoint still starts,
        but its empty authenticator rejects every client until add-user.
        Keeps credentials.toml, clients/*.toml, and existing certs unless LE
        replaces them.

    upgrade
        Binary only: latest published release by default, or --version TAG,
        or --binary PATH. Does not touch configs, credentials, clients, certs,
        firewall, unit contents, or enablement. If the endpoint is active,
        restart and verify it; if inactive, leave it inactive.

    add-user <name>
        Required before a client can authenticate (and for each new device).
        Autogen strong password (never printed).
        Writes credentials.toml [[client]] + ${CLIENTS_DIR}/<name>.toml (0600).
        Generated clients use the install-time protocol (default http2;
        http_connections_num=${HTTP_CONNECTIONS_NUM}; 0 = client default of 8).
        Starts/restarts the endpoint. Copy the .toml to clients.

    del-user <name>
        Remove credentials entry and ${CLIENTS_DIR}/<name>.toml.

    disable / enable
        stop+disable / enable+start systemd unit; keep all files.

    rollback
        Switch to the one immediately previous versioned binary. If the service
        is active, restart and verify it; an inactive service remains inactive.
        The stable ${INSTALL_DIR}/${BIN_NAME} path is a symlink. A successful
        install/upgrade keeps current + one previous binary and deletes older ones;
        a failed upgrade deletes only its new candidate and preserves every
        binary that existed before the attempt.

    purge
        Reverse of install (service → unit → hook → ${INSTALL_DIR} → user).
        Keep by design (reported): LE store, ufw rules/package, apt/snap tools.

EXAMPLES
    # First install (latest GH release + LE shortlived IP cert + ufw)
    bash $0 install --custom-sni camouflage.example
    bash $0 status
    # then add-user (see below) — zero users means deny-all

    # Pin release or use a local build
    bash $0 install --custom-sni camouflage.example --version 20260725T064943Z-c6767f5d5015
    bash $0 install --custom-sni camouflage.example --binary /root/tt-server-RELEASE_TAG-linux-ARCH
    bash $0 install --custom-sni camouflage.example --icmp-interface eth0

    # Own PEMs (no certbot)
    install -d -m 0750 ${CERT_DIR}
    # place fullchain.pem + privkey.pem, then:
    bash $0 install --custom-sni camouflage.example --skip-certbot --binary /root/tt-server-RELEASE_TAG-linux-ARCH

    # Create OpenWrt (or phone) client; password only in the file
    bash $0 add-user openwrt
    ls -l ${CLIENTS_DIR}/openwrt.toml
    # copy to router (from your laptop):
    #   scp -O root@VPS:${CLIENTS_DIR}/openwrt.toml /tmp/openwrt.toml
    #   scp -O root@router:/tmp/openwrt.toml …
    # then on OpenWrt (self-contained direct; see tt-client-openwrt.sh help):
    #   sh tt-client-openwrt.sh install --config /tmp/openwrt.toml --binary /tmp/tt-client-RELEASE_TAG-linux-ARCH

    # Rotate one client (new password; old file invalid after del+add)
    bash $0 del-user openwrt
    bash $0 add-user openwrt
    # scp new openwrt.toml → router → tt-client-openwrt.sh update-creds --config …

    # Upgrade binary only; preserve all state
    bash $0 upgrade
    bash $0 upgrade --version 20260725T064943Z-c6767f5d5015
    bash $0 rollback

    # Temporary outage / bring back
    bash $0 disable
    bash $0 enable

    # Full wipe of this install (LE store + ufw kept)
    bash $0 purge

    # Health check
    bash $0 status
    bash $0 list-users

SEE ALSO
    tt-client-openwrt.sh — OpenWrt client (install, upgrade, update-creds,
                    update-direct, direct-enable/disable, disable/enable,
                    rollback, status, purge)

EOF
}

# --- preconditions ---
check_os() {
  [[ "$(uname -s)" == "Linux" ]] || die "Linux only"
  [[ -d /run/systemd/system ]] || die "systemd required"
  command -v systemctl >/dev/null || die "systemctl required"
  if [[ -f /etc/os-release ]]; then
    # shellcheck source=/dev/null
    . /etc/os-release
    case "${ID:-}:${ID_LIKE:-}" in
      debian:*|ubuntu:*|*debian*|*ubuntu*) ;;
      *) log "warning: untested distro ID=${ID:-?} (Debian/Ubuntu expected)" ;;
    esac
  fi
}

machine_tag() {
  case "$(uname -m)" in
    x86_64|amd64) echo "x86_64" ;;
    *) die "unsupported arch: $(uname -m) (GitHub endpoint releases are x86_64 only)" ;;
  esac
}

# Extract the release tag from the published server asset name. A supplied
# binary must retain that original identity; it is never relabelled as local.
binary_tag_from_file() {
  local base="$(basename "$1")" tag=""
  case "$base" in
    "${RELEASE_ASSET_PREFIX}-"*-linux-*)
      tag="${base#${RELEASE_ASSET_PREFIX}-}"
      tag="${tag%-linux-*}"
      ;;
  esac
  [[ -n "$tag" && "$tag" != *-linux-* ]] || \
    die "binary filename must be a release asset (expected ${RELEASE_ASSET_PREFIX}-<tag>-linux-<arch>): ${base}"
  printf '%s' "$tag"
}

# --- download ---
resolve_latest_version() {
  need_cmds curl
  local json tag
  json="$(curl -fsSL "https://api.github.com/repos/${GITHUB_REPO}/releases/latest")" \
    || die "failed to query GitHub releases for ${GITHUB_REPO}"
  if command -v python3 >/dev/null 2>&1; then
    tag="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])' <<<"$json")" \
      || die "failed to parse latest tag_name"
  else
    tag="$(printf '%s' "$json" | sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
  fi
  [[ -n "$tag" ]] || die "no tag_name in latest release (API rate limit?)"
  printf '%s' "$tag"
}

# Print the verified downloaded binary path; caller removes its parent directory.
download_release() {
  local ver="$1" cpu asset asset_url tmp expect got actual
  [[ -n "$ver" ]] || die "empty version"
  [[ "$ver" =~ ^[A-Za-z0-9._-]+$ ]] || die "invalid release tag: ${ver}"
  cpu="$(machine_tag)"
  tmp="$(mktemp -d)"
  asset="${RELEASE_ASSET_PREFIX}-${ver}-linux-${cpu}"
  asset_url="https://github.com/${GITHUB_REPO}/releases/download/${ver}/${asset}"
  log "download ${asset_url}" >&2
  curl -fsSL -o "${tmp}/${asset}" "${asset_url}" \
    || { rm -rf "$tmp"; die "download failed for ${GITHUB_REPO} tag '${ver}' asset '${asset}'"; }
  curl -fsSL -o "${tmp}/${asset}.sha256" "${asset_url}.sha256" \
    || { rm -rf "$tmp"; die "missing mandatory checksum: ${asset}.sha256"; }
  expect="$(awk '{print $1; exit}' "${tmp}/${asset}.sha256")"
  [[ "$expect" =~ ^[0-9a-fA-F]{64}$ ]] \
    || { rm -rf "$tmp"; die "invalid checksum file for ${asset}"; }
  got="$(sha256sum "${tmp}/${asset}" | awk '{print $1}')"
  [[ "${expect,,}" == "${got,,}" ]] \
    || { rm -rf "$tmp"; die "sha256 mismatch for ${asset}"; }
  chmod 0755 "${tmp}/${asset}"
  actual="$("${tmp}/${asset}" --version 2>/dev/null)" \
    || { rm -rf "$tmp"; die "downloaded endpoint binary is not runnable"; }
  [[ "$actual" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$ ]] \
    || { rm -rf "$tmp"; die "downloaded endpoint reported invalid embedded version '${actual}'"; }
  [[ "$ver" =~ ^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$ ]] \
    || { rm -rf "$tmp"; die "invalid release tag format: '${ver}'"; }
  [[ "$actual" == "$ver" ]] \
    || { rm -rf "$tmp"; die "embedded version '${actual}' does not match release tag '${ver}'"; }
  log "embedded endpoint version: ${actual}" >&2
  echo "${tmp}/${asset}"
}

write_release_meta() {
  local source="$1" tag="$2" binary="$3" digest
  digest="$(sha256sum "$binary" | awk '{print $1}')"
  cat >"${RELEASE_META}" <<EOF
RELEASE_SOURCE=${source}
RELEASE_TAG=${tag}
BINARY_SHA256=${digest}
EOF
  own_conf "${RELEASE_META}"
}

ensure_service_user() {
  if ! id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    log "create system user ${SERVICE_USER}"
    useradd --system --home "${INSTALL_DIR}" --shell /usr/sbin/nologin \
      --user-group "${SERVICE_USER}"
  fi
}

# --- configs ---
detect_icmp_interface() {
  local iface=""
  iface="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | sed -n 's/.* dev \([^[:space:]]*\).*/\1/p' | head -1)"
  if [[ -z "$iface" ]]; then
    iface="$(ip -4 route show default 2>/dev/null \
      | sed -n 's/.* dev \([^[:space:]]*\).*/\1/p' | head -1)"
  fi
  [[ -n "$iface" ]] || die "cannot detect ICMP egress interface; use --icmp-interface IFACE"
  printf '%s' "$iface"
}

validate_icmp_interface() {
  local iface="$1"
  [[ "$iface" =~ ^[[:alnum:]_.-]+$ ]] \
    || die "invalid --icmp-interface: ${iface}"
  ip link show dev "$iface" >/dev/null 2>&1 \
    || die "ICMP interface does not exist: ${iface}"
}

emit_vpn_toml() {
  local icmp_iface="$1"
  if [[ -f "${TEMPLATES_SERVER}/vpn.toml" ]]; then
    log "vpn.toml from ${TEMPLATES_SERVER}/vpn.toml"
    sed "s|@ICMP_INTERFACE@|${icmp_iface}|g" \
      "${TEMPLATES_SERVER}/vpn.toml" >"${VPN_TOML}"
    own_conf "${VPN_TOML}"
    return 0
  fi
  cat >"${VPN_TOML}" <<EOF
listen_address = "0.0.0.0:443"
ipv6_available = false
allow_private_network_connections = false

tls_handshake_timeout_secs = 10
client_listener_timeout_secs = 600
connection_establishment_timeout_secs = 30
tcp_connections_timeout_secs = 604800
udp_connections_timeout_secs = 300

credentials_file = "credentials.toml"

ping_enable = false
speedtest_enable = false
auth_failure_status_code = 404
non_connect_auth_failure_status_code = 404

[listen_protocols]

[listen_protocols.http1]
upload_buffer_size = 32768

[listen_protocols.http2]
initial_connection_window_size = 8388608
initial_stream_window_size = 131072
max_concurrent_streams = 1000
max_frame_size = 16384
header_table_size = 65536

[listen_protocols.quic]
recv_udp_payload_size = 1350
send_udp_payload_size = 1350
initial_max_data = 104857600
initial_max_stream_data_bidi_local = 1048576
initial_max_stream_data_bidi_remote = 1048576
initial_max_stream_data_uni = 1048576
initial_max_streams_bidi = 4096
initial_max_streams_uni = 4096
max_connection_window = 25165824
max_stream_window = 16777216
disable_active_migration = true
enable_early_data = true
message_queue_capacity = 4096

[icmp]
interface_name = "${icmp_iface}"
request_timeout_secs = 3
recv_message_queue_capacity = 256

[forward_protocol]
direct = {}
EOF
  own_conf "${VPN_TOML}"
}

emit_hosts_toml() {
  if [[ -f "${TEMPLATES_SERVER}/hosts.toml.in" ]]; then
    log "hosts.toml from ${TEMPLATES_SERVER}/hosts.toml.in"
    sed -e "s|@CUSTOM_SNI@|${CUSTOM_SNI}|g" \
        -e "s|@INSTALL_DIR@|${INSTALL_DIR}|g" \
      "${TEMPLATES_SERVER}/hosts.toml.in" >"${HOSTS_TOML}"
  else
    cat >"${HOSTS_TOML}" <<EOF
[[main_hosts]]
hostname = "${CUSTOM_SNI}"
cert_chain_path = "${CERT_FC}"
private_key_path = "${CERT_PK}"
EOF
  fi
  own_conf "${HOSTS_TOML}"
}

ensure_creds_file() {
  # Empty registry for trusttunnel_endpoint (see parse_clients in tt-server):
  #   OK:   empty file, or comments/whitespace only  → deny-all, zero users
  #   BAD:  client = []   (plain array — rejected)
  #   BAD:  [client]      (single table — rejected)
  #   OK:   [[client]] …  (array-of-tables entries from add-user)
  if [[ ! -f "${CREDS}" ]]; then
    umask 077
    # Prefer a true empty file (matches endpoint unit tests). Comments also work.
    : >"${CREDS}"
  fi
  own_conf "${CREDS}"
}

# Number of [[client]] users in credentials.toml
creds_count() {
  local n
  n="$(creds_usernames 2>/dev/null | wc -l | tr -d ' ')"
  [[ -n "$n" ]] || n=0
  printf '%s' "$n"
}

emit_unit() {
  cat >"${UNIT_PATH}" <<EOF
[Unit]
Description=TrustTunnel endpoint
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=${SERVICE_USER}
Group=${SERVICE_USER}
WorkingDirectory=${INSTALL_DIR}
ExecStart=${INSTALL_DIR}/${BIN_NAME} vpn.toml hosts.toml
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_RAW
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ReadWritePaths=${INSTALL_DIR}
ProtectHome=true

[Install]
WantedBy=multi-user.target
EOF
  chmod 0644 "${UNIT_PATH}"
}

# Copy LE live PEMs into install tree (shared by setup_certs + hook)
install_certs_from_live() {
  local live="${1:-$LE_LIVE}"
  ensure_dir "${CERT_DIR}"
  install -m 0640 -o root -g "${SERVICE_USER}" \
    "${live}/fullchain.pem" "${CERT_FC}"
  install -m 0640 -o root -g "${SERVICE_USER}" \
    "${live}/privkey.pem" "${CERT_PK}"
}

write_certbot_hook() {
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat >"${LE_HOOK}" <<EOF
#!/bin/sh
set -e
LIVE="${LE_LIVE}"
DEST="${CERT_DIR}"
install -d -m 0750 -o root -g ${SERVICE_USER} "\$DEST"
install -m 0640 -o root -g ${SERVICE_USER} "\$LIVE/fullchain.pem" "\$DEST/fullchain.pem"
install -m 0640 -o root -g ${SERVICE_USER} "\$LIVE/privkey.pem" "\$DEST/privkey.pem"
systemctl restart ${SERVICE_NAME}.service
EOF
  chmod 0755 "${LE_HOOK}"
}

# Resolve certbot binary (snap often not on PATH until new login).
certbot_bin() {
  if [[ -x /snap/bin/certbot ]]; then
    printf '%s' /snap/bin/certbot
    return 0
  fi
  if command -v certbot >/dev/null 2>&1; then
    command -v certbot
    return 0
  fi
  return 1
}

# $1 = public IPv4 (required when issuing new LE cert)
# $2 = 1 if --skip-certbot
#
# LE still issues bare-IP certs (GA 2026) but ONLY with the shortlived profile (~6d).
# Certbot 5.3+: use --ip-address IP + --preferred-profile shortlived
# (plain -d IP is rejected client-side: "IP address. LE will not issue for bare IP" as DNS name).
setup_certs() {
  local vps_ip="$1" skip="${2:-0}" cb
  if [[ "$skip" == "1" ]]; then
    [[ -f "${CERT_FC}" && -f "${CERT_PK}" ]] \
      || die "--skip-certbot requires both ${CERT_FC} and ${CERT_PK}"
    own_conf "${CERT_FC}" "${CERT_PK}"
    log "skip-certbot: using existing PEMs; no certbot, no deploy hook, no auto-renew"
    log "  renew yourself, then: systemctl restart ${SERVICE_NAME}"
    return 0
  fi

  LE_LIVE="/etc/letsencrypt/live/${CERT_LIVE_NAME}"
  log "certbot: LE shortlived IP cert (~6d) + auto-renew + deploy hook"
  apt_install curl openssl ca-certificates snapd
  systemctl enable --now snapd.socket 2>/dev/null || true
  snap wait system seed.loaded 2>/dev/null || true
  # snap PATH
  export PATH="/snap/bin:${PATH:-/usr/bin}"
  if ! certbot_bin >/dev/null 2>&1; then
    command -v snap >/dev/null || die "snap missing after snapd install (cannot get certbot)"
    snap install --classic certbot \
      || die "snap install certbot failed"
    ln -sfn /snap/bin/certbot /usr/local/bin/certbot
  fi
  hash -r 2>/dev/null || true
  export PATH="/snap/bin:/usr/local/bin:${PATH}"
  cb="$(certbot_bin)" || die "certbot not found (expected /snap/bin/certbot after snap install)"
  log "using certbot: ${cb} ($("${cb}" --version 2>&1 | head -1))"

  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true

  if [[ ! -f "${LE_LIVE}/fullchain.pem" ]]; then
    [[ -n "${vps_ip}" ]] || die "cannot issue LE cert: public IP unknown (cdn-cgi/trace failed)"
    [[ "${vps_ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
      || die "endpoint is not IPv4 (domain LE not handled here): ${vps_ip}"
    log "certbot standalone --preferred-profile shortlived --ip-address ${vps_ip}"
    # Do NOT use -d for IPs (Certbot treats that as DNS SAN and rejects).
    "${cb}" certonly --standalone --preferred-challenges http \
      --preferred-profile shortlived \
      --ip-address "${vps_ip}" \
      --cert-name "${CERT_LIVE_NAME}" \
      --agree-tos \
      --register-unsafely-without-email \
      --non-interactive \
      || die "certbot failed for IP ${vps_ip}
  Need: ufw allow 80/tcp (script runs setup_ufw first); cloud SG/security group allow 80;
        nothing else bound to :80 during standalone; --preferred-profile shortlived"
  else
    log "LE cert already present: ${LE_LIVE}"
  fi
  install_certs_from_live "${LE_LIVE}"
  write_certbot_hook
  # Ensure renew path keeps shortlived + IP (reconfigure if supported)
  if "${cb}" reconfigure --help >/dev/null 2>&1; then
    "${cb}" reconfigure --cert-name "${CERT_LIVE_NAME}" \
      --preferred-profile shortlived 2>/dev/null \
      || log "warning: certbot reconfigure profile skipped (renew may still work if lineage ok)"
  fi
}

# Always open 22/80/443 and enable ufw (this host is the TT VPS).
setup_ufw() {
  apt_install ufw
  need_cmds ufw
  ufw allow OpenSSH 2>/dev/null || true
  ufw allow 22/tcp   # SSH
  ufw allow 80/tcp   # LE HTTP-01
  ufw allow 443/tcp  # TrustTunnel HTTP/2
  ufw allow 443/udp  # TrustTunnel HTTP/3 / QUIC
  if ! ufw status 2>/dev/null | grep -qi 'Status: active'; then
    log "enabling ufw"
    echo "y" | ufw --force enable || echo "y" | ufw enable \
      || die "ufw enable failed"
  else
    log "ufw already active; rules ensured"
  fi
  ufw status verbose || ufw status || true
}

# --- credentials ---
toml_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  printf '%s' "$s"
}

validate_username() {
  [[ "$1" =~ ^[A-Za-z0-9_@.-]+$ ]] \
    || die "invalid username '$1' (use letters, digits, _ @ . -)"
}

# Print all usernames in credentials.toml (one per line).
creds_usernames() {
  [[ -f "${CREDS}" ]] || return 0
  local line
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^username[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
      echo "${BASH_REMATCH[1]}"
    fi
  done <"${CREDS}"
}

creds_has_user() {
  # grep exit 1 when missing must not trip set -e
  creds_usernames | grep -qxF "$1" || return 1
  return 0
}

creds_add() {
  local name="$1" pass="$2"
  ensure_creds_file
  validate_username "$name"
  creds_has_user "$name" && die "user already exists: ${name}"
  {
    echo ""
    echo "[[client]]"
    echo "username = \"$(toml_escape "$name")\""
    echo "password = \"$(toml_escape "$pass")\""
  } >>"${CREDS}"
  own_conf "${CREDS}"
}

creds_del() {
  local name="$1" tmp line buf="" drop=0 in_client=0
  [[ -f "${CREDS}" ]] || die "no ${CREDS}"
  validate_username "$name"
  creds_has_user "$name" || die "user not found: ${name}"
  tmp="$(mktemp)"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^\[\[client\]\] ]]; then
      if [[ "$in_client" -eq 1 && "$drop" -eq 0 && -n "$buf" ]]; then
        printf '%s' "$buf" >>"$tmp"
      fi
      buf="${line}"$'\n'
      in_client=1
      drop=0
      continue
    fi
    if [[ "$in_client" -eq 1 ]]; then
      buf+="${line}"$'\n'
      if [[ "$line" =~ ^username[[:space:]]*=[[:space:]]*\"([^\"]+)\" ]]; then
        [[ "${BASH_REMATCH[1]}" == "$name" ]] && drop=1
      fi
      continue
    fi
    printf '%s\n' "$line" >>"$tmp"
  done <"${CREDS}"
  if [[ "$in_client" -eq 1 && "$drop" -eq 0 && -n "$buf" ]]; then
    printf '%s' "$buf" >>"$tmp"
  fi
  install -m 0640 -o root -g "${SERVICE_USER}" "$tmp" "${CREDS}"
  rm -f "$tmp"
}

# Strong password for clients (never printed; only in credentials.toml + clients/*.toml).
gen_password() {
  # 32 hex chars. Avoid openssl|tr|head under pipefail (SIGPIPE / non-zero exit).
  need_cmds openssl
  openssl rand -hex 16
}

# Public IPv4 of this host (what clients dial + LE -d).
# 1) Cloudflare trace 1.1.1.1 / 1.0.0.1  →  line ip=
# 2) cached ${ENDPOINT_IP_FILE}
# 3) IP SAN on install-tree cert
detect_endpoint_ip() {
  local ip="" line url
  if command -v curl >/dev/null 2>&1; then
    for url in "https://1.1.1.1/cdn-cgi/trace" "https://1.0.0.1/cdn-cgi/trace"; do
      line="$(curl -4fsS --max-time 8 "$url" 2>/dev/null | sed -n 's/^ip=//p' | head -1 || true)"
      ip="$(printf '%s' "$line" | tr -d '[:space:]')"
      [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
    done
  fi
  if [[ -f "${ENDPOINT_IP_FILE}" ]]; then
    ip="$(tr -d '[:space:]' <"${ENDPOINT_IP_FILE}")"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  fi
  if [[ -f "${CERT_FC}" ]] && command -v openssl >/dev/null 2>&1; then
    ip="$(openssl x509 -in "${CERT_FC}" -noout -text 2>/dev/null \
      | sed -n 's/.*IP Address:\([0-9.]*\).*/\1/p' | head -1)"
    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && { printf '%s' "$ip"; return 0; }
  fi
  return 1
}

save_endpoint_ip() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "bad endpoint IP: ${ip}"
  ensure_dir "${INSTALL_DIR}"
  printf '%s\n' "$ip" >"${ENDPOINT_IP_FILE}"
  chmod 0644 "${ENDPOINT_IP_FILE}"
}

save_upstream_protocol() {
  validate_upstream_protocol "$1"
  printf '%s\n' "$1" >"${CLIENT_PROTOCOL_FILE}"
  chmod 0644 "${CLIENT_PROTOCOL_FILE}"
}

load_upstream_protocol() {
  if [[ -f "${CLIENT_PROTOCOL_FILE}" ]]; then
    local value
    value="$(tr -d '[:space:]' <"${CLIENT_PROTOCOL_FILE}")"
    validate_upstream_protocol "$value"
    UPSTREAM_PROTOCOL="$value"
  fi
}

# Client SNI must exactly match the hostname persisted by install.
server_sni() {
  local s
  s="$(toml_get_str hostname "${HOSTS_TOML}" || true)"
  [[ -n "$s" ]] && { printf '%s' "$s"; return 0; }
  return 1
}

# Write portable client setup file (password only here + credentials.toml — not printed).
write_client_config() {
  local name="$1" pass="$2" endpoint="$3" sni="$4" path
  install -d -m 0700 -o root -g root "${CLIENTS_DIR}"
  path="${CLIENTS_DIR}/${name}.toml"
  cat >"${path}" <<EOF
# TrustTunnel client setup — generated by tt-server.sh add-user
# username=${name}
# created_utc=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
# endpoint=${endpoint}:443  custom_sni=${sni}
#
# Secret file (mode 0600). Password is not printed by add-user.
# Copy to the device and import into the client.

loglevel = "info"

vpn_mode = "general"
killswitch_enabled = true
killswitch_allow_ports = []
post_quantum_group_enabled = true

exclusions_tcp_early_ack_enabled = false
exclusions_preresolve_enabled = false
exclusions_preresolve_max_queries = 50
exclusions = []

[endpoint]
hostname = "${endpoint}"
addresses = ["${endpoint}:443"]
custom_sni = "${sni}"
has_ipv6 = false
username = "$(toml_escape "$name")"
password = "$(toml_escape "$pass")"
client_random = ""
skip_verification = false
certificate = ""
upstream_protocol = "${UPSTREAM_PROTOCOL}"
http_connections_num = ${HTTP_CONNECTIONS_NUM}
health_check_timeout_ms = ${HEALTH_CHECK_TIMEOUT_MS}
anti_dpi = false
dns_upstreams = ["1.1.1.1", "1.0.0.1"]

# OpenWrt: set bound_if to your WAN device (e.g. "wan").
# Apps that own the tunnel can ignore [listener].

[listener]

[listener.tun]
# bound_if = "wan"
included_routes = ["0.0.0.0/0"]
excluded_routes = [
    "0.0.0.0/8",
    "169.254.0.0/16",
    "192.168.0.0/16",
    "224.0.0.0/3",
]
mtu_size = 1280
change_system_dns = false
EOF
  chown root:root "${path}"
  chmod 0600 "${path}"
  printf '%s' "$path"
}

service_owns_443() {
  local pid
  pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}.service" 2>/dev/null || echo 0)"
  [[ -n "$pid" && "$pid" != "0" ]] || return 1
  ss -lntp 2>/dev/null | grep -E ':443\b' | grep -q "pid=${pid},"
}

service_restart_verify() {
  systemctl restart "${SERVICE_NAME}.service" \
    || die "systemctl restart ${SERVICE_NAME} failed"
  sleep 1
  systemctl is-active --quiet "${SERVICE_NAME}.service" \
    || {
      systemctl --no-pager -l status "${SERVICE_NAME}.service" || true
      journalctl -u "${SERVICE_NAME}.service" -n 30 --no-pager 2>/dev/null || true
      die "service not active after restart"
    }
  service_owns_443 \
    || {
      systemctl --no-pager -l status "${SERVICE_NAME}.service" || true
      ss -lntp 2>/dev/null | grep -E ':443\b' || true
      die "service is active but its MainPID does not listen on tcp/443"
    }
}

service_restart_check() {
  systemctl enable "${SERVICE_NAME}.service" 2>/dev/null || true
  service_restart_verify
}

reload_service() {
  systemctl cat "${SERVICE_NAME}.service" >/dev/null 2>&1 \
    || die "systemd service ${SERVICE_NAME}.service missing (install first?)"
  service_restart_check
}

# --- list clients (shared by list-users + status) ---
print_client_names() {
  local list indent="${1:-  }"
  list="$(creds_usernames || true)"
  if [[ -z "$list" ]]; then
    echo "${indent}(none)"
    return 1
  fi
  printf '%s\n' "$list" | sed "s/^/${indent}/"
  return 0
}

# --- status helpers ---
status_cert_expiry() {
  local fc="$1" end start not_after_epoch not_before_epoch now
  local left_s left_d life_s life_d warn_after_s
  end="$(openssl x509 -in "$fc" -noout -enddate 2>/dev/null | cut -d= -f2- || true)"
  start="$(openssl x509 -in "$fc" -noout -startdate 2>/dev/null | cut -d= -f2- || true)"
  local subj cn san san_clean
  subj="$(openssl x509 -in "$fc" -noout -subject -nameopt RFC2253 2>/dev/null | sed 's/^subject=//' || true)"
  [[ -z "$subj" || "$subj" == "subject=" ]] && \
    subj="$(openssl x509 -in "$fc" -noout -subject 2>/dev/null | sed 's/^subject=//' || true)"
  cn="$(openssl x509 -in "$fc" -noout -subject -nameopt RFC2253 2>/dev/null \
    | sed -n 's/.*CN=\([^,]*\).*/\1/p' || true)"
  san="$(openssl x509 -in "$fc" -noout -text 2>/dev/null \
    | awk '/X509v3 Subject Alternative Name/{getline; gsub(/^ +/,"",$0); print; exit}' || true)"
  [[ -z "$san" ]] && san="$(openssl x509 -in "$fc" -noout -ext subjectAltName 2>/dev/null \
    | tr '\n' ' ' | sed 's/.*Subject Alternative Name://;s/critical//g;s/^ *//' || true)"
  san_clean="$(printf '%s' "$san" | tr -s ' \t' ' ' | sed 's/^ //;s/ $//')"

  if [[ -z "$subj" || "$subj" =~ ^[[:space:]]*$ ]]; then
    _st_info "subject: (empty — common for IP-only LE certs)"
  else
    _st_info "subject: ${subj}"
  fi
  [[ -n "$san_clean" ]] && _st_info "san: ${san_clean}" || _st_warn "san: (none parsed)"
  if [[ -n "$cn" ]]; then
    _st_info "identity: CN=${cn}"
  elif [[ -n "$san_clean" ]]; then
    _st_info "identity: SAN ${san_clean}"
  else
    _st_info "identity: (no CN/SAN)"
  fi
  _st_info "notBefore: ${start:-?}  notAfter: ${end:-?}"

  [[ -n "$end" ]] || return 0
  not_after_epoch="$(openssl_date_epoch "$end")"
  not_before_epoch=0
  [[ -n "$start" ]] && not_before_epoch="$(openssl_date_epoch "$start")"
  now="$(date -u +%s)"
  [[ "$not_after_epoch" -gt 0 ]] || return 0

  left_s=$(( not_after_epoch - now ))
  left_d=$(( left_s / 86400 ))
  if [[ "$not_before_epoch" -gt 0 && "$not_after_epoch" -gt "$not_before_epoch" ]]; then
    life_s=$(( not_after_epoch - not_before_epoch ))
    life_d=$(( (life_s + 86399) / 86400 ))
    warn_after_s=$(( life_s * 15 / 100 ))
    [[ "$warn_after_s" -lt 86400 ]] && warn_after_s=86400
    [[ "$warn_after_s" -gt $((14 * 86400)) ]] && warn_after_s=$((14 * 86400))
    _st_info "lifetime ~${life_d}d  remaining ~${left_d}d  warn_below ~$((warn_after_s / 86400))d"
  else
    warn_after_s=$((2 * 86400))
    _st_info "remaining ~${left_d}d (lifetime unknown; warn if <2d)"
  fi
  if [[ "$left_s" -lt 0 ]]; then
    _st_fail "certificate EXPIRED (${left_d}d)"
  elif [[ "$left_s" -lt "$warn_after_s" ]]; then
    _st_warn "certificate expires soon (~${left_d}d left) — renew (certbot renew)"
  else
    _st_ok "certificate valid ~${left_d}d remaining"
  fi
}

status_journal_sni() {
  command -v journalctl >/dev/null 2>&1 || return 0
  echo "  --- recent journal (last 8) ---"
  journalctl -u "${SERVICE_NAME}.service" -n 8 --no-pager 2>/dev/null | sed 's/^/  | /' || true
  local j24 hits hex_sample ip_guess configured_sni=""
  configured_sni="$(server_sni 2>/dev/null || true)"
  j24="$(journalctl -u "${SERVICE_NAME}.service" --since '24 hours ago' --no-pager 2>/dev/null || true)"
  hits="$(printf '%s\n' "$j24" | grep -c 'Illegal SNI extension: ignoring IP address' || true)"
  hits="$(printf '%s' "$hits" | tr -d '[:space:]')"
  [[ -z "$hits" ]] && hits=0
  if [[ "$hits" -eq 0 ]]; then
    _st_ok "journal (24h): no Illegal SNI / IP-as-hostname noise"
    return 0
  fi
  _st_warn "journal (24h): ${hits}× Illegal SNI (client sent IP as hostname)"
  _st_info "hint: client custom_sni must match ${configured_sni:-hosts.toml hostname}, not the VPS IP"
  hex_sample="$(printf '%s\n' "$j24" \
    | sed -n 's/.*ignoring IP address presented as hostname (\([0-9a-fA-F]*\)).*/\1/p' | tail -1)"
  [[ -z "$hex_sample" ]] && return 0
  if command -v xxd >/dev/null 2>&1; then
    ip_guess="$(printf '%s' "$hex_sample" | xxd -r -p 2>/dev/null || true)"
  else
    ip_guess="$(python3 -c "print(bytes.fromhex('${hex_sample}').decode('ascii','replace'))" 2>/dev/null || true)"
  fi
  [[ -n "$ip_guess" ]] && _st_info "last decoded SNI-as-IP ≈ ${ip_guess}"
}

# --- actions ---
cmd_install() {
  local ver="" local_bin="" skip_certbot=0 release_bin="" pub_ip="" icmp_iface="" \
    binary_tag="" release_source="" custom_sni=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="${2:?}"; shift 2 ;;
      --binary) local_bin="${2:?}"; shift 2 ;;
      --custom-sni) custom_sni="${2:?}"; shift 2 ;;
      --upstream-protocol) UPSTREAM_PROTOCOL="${2:?}"; shift 2 ;;
      --icmp-interface) icmp_iface="${2:?}"; shift 2 ;;
      --skip-certbot) skip_certbot=1; shift ;;
      -h|--help) usage; exit 0 ;;
      *) die "install: unknown option $1 (see help)" ;;
    esac
  done
  if [[ -n "$local_bin" && -n "$ver" ]]; then
    die "use only one of --binary or --version"
  fi
  validate_custom_sni "$custom_sni"
  validate_upstream_protocol "$UPSTREAM_PROTOCOL"
  CUSTOM_SNI="${custom_sni,,}"
  check_os

  log "preconditions"
  # apt first (need_cmds would die before we can install curl/ss on a minimal image),
  # then assert every command we actually invoke is on PATH.
  apt_install curl ca-certificates openssl iproute2
  need_cmds curl tar install sha256sum find openssl ss useradd id readlink ln mv basename

  [[ -n "$icmp_iface" ]] || icmp_iface="$(detect_icmp_interface)"
  validate_icmp_interface "$icmp_iface"
  log "ICMP egress interface=${icmp_iface}"

  ensure_service_user
  ensure_dir "${INSTALL_DIR}"
  ensure_dir "${CERT_DIR}"

  if [[ -n "$local_bin" ]]; then
    [[ -f "$local_bin" ]] || die "binary file not found: $local_bin"
    log "install binary from --binary"
    binary_tag="$(binary_tag_from_file "$local_bin")"
    ver="$binary_tag"
    release_source=file
  else
    [[ -n "$ver" ]] || ver="$(resolve_latest_version)"
    log "release tag: ${ver}"
    release_bin="$(download_release "$ver")"
    local_bin="$release_bin"
    binary_tag="$ver"
    release_source="github:${GITHUB_REPO}"
  fi
  binary_tx_begin
  trap 'binary_tx_on_exit "$?"' EXIT
  binary_tx_install "$local_bin" "$binary_tag"
  [[ -z "$release_bin" ]] || rm -rf "$(dirname "$release_bin")"

  log "configs"
  [[ -f "${VPN_TOML}" ]] && log "rewrite ${VPN_TOML}"
  emit_vpn_toml "$icmp_iface"
  save_upstream_protocol "$UPSTREAM_PROTOCOL"
  [[ -f "${HOSTS_TOML}" ]] && log "rewrite ${HOSTS_TOML}"
  emit_hosts_toml
  [[ -f "${CREDS}" ]] && log "keep existing ${CREDS}"
  ensure_creds_file

  log "public IP (Cloudflare cdn-cgi/trace)"
  pub_ip="$(detect_endpoint_ip)" \
    || die "cannot detect public IPv4 (need outbound HTTPS to 1.1.1.1 / 1.0.0.1)"
  save_endpoint_ip "${pub_ip}"
  log "endpoint.ip=${pub_ip}"

  # UFW BEFORE certbot: HTTP-01 needs inbound TCP/80 from the internet.
  # (Previously ufw ran after LE → active ufw with only 22 caused ACME timeout.)
  log "firewall (22 SSH, 80 LE HTTP-01, 443 TT) + enable ufw — before TLS"
  setup_ufw

  log "tls"
  setup_certs "${pub_ip}" "${skip_certbot}"

  log "systemd"
  [[ -f "${UNIT_PATH}" ]] && log "rewrite ${UNIT_PATH}"
  emit_unit
  systemctl daemon-reload
  service_restart_check

  log "verify"
  "${INSTALL_DIR}/${BIN_NAME}" --version 2>/dev/null || true
  write_release_meta "$release_source" "${ver:-local}" "${INSTALL_DIR}/${BIN_NAME}"
  binary_tx_commit "$_BIN_TX_NEW" "$_BIN_TX_OLD"
  trap - EXIT
  echo "OK install → ${INSTALL_DIR}  endpoint=${pub_ip}  sni=${CUSTOM_SNI}"
  if [[ "$(creds_count)" -lt 1 ]]; then
    echo "  endpoint active in deny-all mode; NEXT: $0 add-user <name>"
  else
    echo "  clients: $0 add-user <name> | status"
  fi
}

cmd_upgrade() {
  check_os
  local ver="" local_bin="" release_bin="" binary_tag="" release_source=""
  local current target src_sum current_sum new previous was_active=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --version) ver="${2:?}"; shift 2 ;;
      --binary) local_bin="${2:?}"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "upgrade: unknown option $1 (see help)" ;;
    esac
  done
  [[ -z "$local_bin" || -z "$ver" ]] || die "use only one of --binary or --version"
  is_installed || die "not installed (run install first)"
  need_cmds install sha256sum readlink ln mv basename dirname systemctl

  if [[ -n "$local_bin" ]]; then
    [[ -f "$local_bin" ]] || die "binary file not found: $local_bin"
    binary_tag="$(binary_tag_from_file "$local_bin")"
    ver="$binary_tag"
    release_source=file
  else
    need_cmds curl
    [[ -n "$ver" ]] || ver="$(resolve_latest_version)"
    log "release tag: ${ver}"
    release_bin="$(download_release "$ver")"
    local_bin="$release_bin"
    binary_tag="$ver"
    release_source="github:${GITHUB_REPO}"
  fi

  current="$(binary_resolve_link)" \
    || die "managed binary symlink missing or invalid — run install"
  target="${INSTALL_DIR}/$(basename "$local_bin")"
  if [[ "$current" == "$target" ]]; then
    src_sum="$(sha256sum "$local_bin" | awk '{print $1}')"
    current_sum="$(sha256sum "$current" | awk '{print $1}')"
    [[ "$src_sum" == "$current_sum" ]] \
      || die "current version name collides with different binary content: ${target}"
    [[ -z "$release_bin" ]] || rm -rf "$(dirname "$release_bin")"
    write_release_meta "$release_source" "${ver:-local}" "$current"
    echo "OK upgrade — already current: $(basename "$current")"
    return 0
  fi

  log "upgrade binary only"
  binary_tx_begin
  trap 'binary_tx_on_exit "$?"' EXIT
  binary_tx_install "$local_bin" "$binary_tag"
  [[ -z "$release_bin" ]] || rm -rf "$(dirname "$release_bin")"

  if [[ "$_BIN_TX_SERVICE_WAS_ACTIVE" -eq 1 ]]; then
    was_active=1
    log "restart active endpoint"
    service_restart_verify
  else
    log "endpoint inactive — leave inactive"
  fi

  write_release_meta "$release_source" "${ver:-local}" "$(binary_link_path)"
  new="$_BIN_TX_NEW"
  previous="$_BIN_TX_OLD"
  binary_tx_commit "$new" "$previous"
  trap - EXIT
  echo "OK upgrade — current=$(basename "$new")  rollback=$(basename "$previous")"
  [[ "$was_active" -eq 1 ]] \
    || echo "  service was inactive and remains inactive"
}

cmd_add_user() {
  local name="${1:-}" pass endpoint sni client_path
  [[ -n "$name" && -z "${2:-}" ]] || die "usage: $0 add-user <name>"
  is_installed || die "not installed (run install first)"
  load_upstream_protocol
  need_cmds openssl install
  validate_username "$name"
  ensure_creds_file
  creds_has_user "$name" && die "user already exists: ${name}"
  endpoint="$(detect_endpoint_ip)" \
    || die "cannot detect server public IP from cert/network (is TLS cert an IP cert?)"
  sni="$(server_sni)" \
    || die "server SNI missing from ${HOSTS_TOML}; reinstall with --custom-sni HOST"
  pass="$(gen_password)"
  [[ -n "$pass" && ${#pass} -ge 24 ]] || die "password generation failed"

  client_path="${CLIENTS_DIR}/${name}.toml"
  if ! client_path="$(write_client_config "$name" "$pass" "$endpoint" "$sni")"; then
    rm -f "${CLIENTS_DIR}/${name}.toml"
    die "failed to write client config for ${name}"
  fi
  if ! (creds_add "$name" "$pass"); then
    rm -f "$client_path"
    die "failed to add credentials for ${name}"
  fi
  if ! (reload_service); then
    log "add-user failed; rolling back ${name}"
    creds_del "$name"
    rm -f "$client_path"
    (reload_service) \
      || log "warning: service did not recover after rolling back ${name}"
    die "service failed after adding ${name}; user and client config rolled back"
  fi

  echo "OK user=${name}"
  echo "client_config=${client_path}"
  echo "  endpoint=${endpoint}:443  sni=${sni}"
  echo "  password not printed — only in client_config and ${CREDS}"
}

cmd_del_user() {
  local name="${1:-}" cfile
  [[ -n "$name" && -z "${2:-}" ]] || die "usage: $0 del-user <name>"
  is_installed || die "not installed"
  validate_username "$name"
  creds_del "$name"
  cfile="${CLIENTS_DIR}/${name}.toml"
  rm -f "$cfile"
  log "deleted ${cfile} (if it existed)"
  reload_service
  echo "OK deleted user=${name}"
}

cmd_list_users() {
  is_installed || die "not installed"
  echo "server credentials: ${CREDS}"
  echo "users:"
  print_client_names "  " || true
  echo "client setup files (${CLIENTS_DIR}/):"
  if [[ -d "${CLIENTS_DIR}" ]]; then
    local f
    local any=0
    for f in "${CLIENTS_DIR}"/*.toml; do
      [[ -f "$f" ]] || continue
      any=1
      echo "  $f  meta=$(file_meta "$f")"
    done
    [[ "$any" -eq 1 ]] || echo "  (none)"
  else
    echo "  (no ${CLIENTS_DIR} yet)"
  fi
}

cmd_status() {
  _ST_FAILS=0
  _ST_WARNS=0
  local client_count current="" previous=""
  client_count="$(creds_count)"
  echo "=== TrustTunnel server status ==="
  echo "host=$(hostname -f 2>/dev/null || hostname)"
  echo

  echo "[install]"
  _st_info "dir=${INSTALL_DIR}  sni=$(server_sni 2>/dev/null || echo missing)"
  if [[ -f "${ENDPOINT_IP_FILE}" ]]; then
    _st_info "endpoint.ip=$(tr -d '[:space:]' <"${ENDPOINT_IP_FILE}")"
  fi
  [[ -d "${INSTALL_DIR}" ]] && _st_ok "install dir exists" || _st_fail "install dir missing"
  if [[ -x "${INSTALL_DIR}/${BIN_NAME}" ]]; then
    _st_ok "binary ${INSTALL_DIR}/${BIN_NAME}  meta=$(file_meta "${INSTALL_DIR}/${BIN_NAME}")"
    if [[ -L "${INSTALL_DIR}/${BIN_NAME}" ]]; then
      current="$(binary_resolve_link)"
      _st_info "binary [*] ${current}"
      if previous="$(binary_previous "$current" 2>/dev/null)"; then
        _st_info "binary [ ] ${previous}"
      else
        _st_info "binary [ ] unavailable (no previous successful install)"
      fi
    else
      _st_fail "binary path is not a managed symlink"
    fi
    _st_info "product: $("${INSTALL_DIR}/${BIN_NAME}" --version 2>/dev/null | head -1 || echo unknown)"
    if [[ -f "${RELEASE_META}" ]]; then
      _st_info "release: $(tr '\n' ' ' <"${RELEASE_META}")"
    else
      _st_warn "release metadata missing"
    fi
  else
    _st_fail "binary missing or not executable: ${INSTALL_DIR}/${BIN_NAME}"
  fi
  if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    _st_ok "service user ${SERVICE_USER} (uid=$(id -u "${SERVICE_USER}"))"
  else
    _st_fail "service user ${SERVICE_USER} missing"
  fi
  echo

  echo "[config]"
  local f
  for f in "${VPN_TOML}" "${HOSTS_TOML}" "${CREDS}"; do
    _st_file "$f"
  done
  _st_info "sni/hostname=$(toml_get_str hostname "${HOSTS_TOML}" || echo '?')"
  _st_info "listen_address=$(toml_get_str listen_address "${VPN_TOML}" || echo '?')"
  if [[ -f "${CLIENT_PROTOCOL_FILE}" ]]; then
    _st_info "new clients: upstream_protocol=$(tr -d '[:space:]' <"${CLIENT_PROTOCOL_FILE}")"
  else
    _st_info "new clients: upstream_protocol=${UPSTREAM_PROTOCOL} (default; not yet saved by install)"
  fi
  [[ -f "${TEMPLATES_SERVER}/vpn.toml" ]] && _st_info "ops templates at ${TEMPLATES_SERVER}"
  echo

  echo "[icmp]"
  local icmp_iface route_iface="" main_pid="" cap_eff=""
  icmp_iface="$(toml_get_str interface_name "${VPN_TOML}")"
  if [[ -f "${VPN_TOML}" ]] && grep -q '^\[icmp\]$' "${VPN_TOML}"; then
    _st_ok "[icmp] enabled"
  else
    _st_fail "[icmp] missing from ${VPN_TOML}"
  fi
  if [[ -n "$icmp_iface" ]] && ip link show dev "$icmp_iface" >/dev/null 2>&1; then
    _st_ok "interface_name=${icmp_iface}"
  else
    _st_fail "ICMP interface missing or invalid: ${icmp_iface:-unset}"
  fi
  route_iface="$(ip -4 route get 1.1.1.1 2>/dev/null \
    | sed -n 's/.* dev \([^[:space:]]*\).*/\1/p' | head -1)"
  if [[ -n "$icmp_iface" && "$icmp_iface" == "$route_iface" ]]; then
    _st_ok "ICMP interface matches current egress route"
  else
    _st_fail "ICMP interface=${icmp_iface:-unset}, current egress=${route_iface:-unknown}; reinstall with --icmp-interface"
  fi
  if [[ -f "${UNIT_PATH}" ]] \
    && grep -qE '^AmbientCapabilities=.*(^|[[:space:]])CAP_NET_RAW([[:space:]]|$)' "${UNIT_PATH}"; then
    _st_ok "systemd grants CAP_NET_RAW"
  else
    _st_fail "systemd AmbientCapabilities lacks CAP_NET_RAW"
  fi
  main_pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}.service" 2>/dev/null || true)"
  if [[ "$main_pid" =~ ^[1-9][0-9]*$ && -r "/proc/${main_pid}/status" ]]; then
    cap_eff="$(awk '/^CapEff:/ { print $2 }' "/proc/${main_pid}/status")"
    if [[ -n "$cap_eff" ]] && (( (16#$cap_eff & 16#2000) != 0 )); then
      _st_ok "running process has effective CAP_NET_RAW"
    else
      _st_fail "running process lacks effective CAP_NET_RAW (CapEff=${cap_eff:-unknown})"
    fi
  else
    _st_info "effective CAP_NET_RAW not tested while service is inactive"
  fi
  if [[ -n "$icmp_iface" ]] && command -v ping >/dev/null 2>&1; then
    if ping -c 1 -W 3 -I "$icmp_iface" 1.1.1.1 >/dev/null 2>&1; then
      _st_ok "VPS ICMP egress works via ${icmp_iface}"
    else
      _st_fail "VPS cannot ping 1.1.1.1 via ${icmp_iface}"
    fi
  else
    _st_info "VPS ICMP egress probe unavailable (ping command or interface missing)"
  fi
  echo

  echo "[certs]"
  if [[ -f "${CERT_FC}" ]]; then
    _st_ok "${CERT_FC}  meta=$(file_meta "${CERT_FC}")"
    if command -v openssl >/dev/null 2>&1; then
      status_cert_expiry "${CERT_FC}"
    else
      _st_warn "openssl not installed; cannot show cert expiry"
    fi
  else
    _st_fail "${CERT_FC} missing"
  fi
  _st_file "${CERT_PK}"
  if [[ -d "${LE_LIVE}" ]]; then
    _st_ok "letsencrypt live=${LE_LIVE}"
  else
    _st_info "letsencrypt live=${LE_LIVE} (absent — OK if --skip-certbot / manual PEMs)"
  fi
  [[ -x "${LE_HOOK}" ]] && _st_ok "certbot deploy hook ${LE_HOOK}" \
    || _st_warn "certbot deploy hook missing (renewals may not copy into ${CERT_DIR})"
  if command -v certbot >/dev/null 2>&1; then
    _st_info "certbot=$(certbot --version 2>/dev/null | head -1)"
  else
    _st_info "certbot not installed"
  fi
  echo

  echo "[systemd]"
  [[ -f "${UNIT_PATH}" ]] && _st_ok "service file ${UNIT_PATH}" || _st_fail "service file missing"
  local en act main_pid
  en="$(systemctl is-enabled "${SERVICE_NAME}.service" 2>/dev/null || true)"
  act="$(systemctl is-active "${SERVICE_NAME}.service" 2>/dev/null || true)"
  [[ -n "$en" ]] || en=unknown
  [[ -n "$act" ]] || act=unknown
  if [[ "$act" == "active" ]]; then
    _st_ok "active=${act}  enabled=${en}"
  elif [[ "$en" == "disabled" && "$act" == "inactive" ]]; then
    _st_warn "service inactive and disabled (run: $0 enable)"
  else
    _st_fail "active=${act}  enabled=${en}"
  fi
  main_pid="$(systemctl show -p MainPID --value "${SERVICE_NAME}.service" 2>/dev/null || echo 0)"
  [[ -n "$main_pid" && "$main_pid" != "0" ]] && _st_info "MainPID=${main_pid}"
  status_journal_sni
  echo

  echo "[listen]"
  if command -v ss >/dev/null 2>&1; then
    local l443 u443 l80
    l443="$(ss -lntp 2>/dev/null | grep -E ':443\b' || true)"
    u443="$(ss -lnup 2>/dev/null | grep -E ':443\b' || true)"
    l80="$(ss -lntp 2>/dev/null | grep -E ':80\b' || true)"
    if [[ -n "$l443" ]] && service_owns_443; then
      _st_ok "tcp/443:"; printf '%s\n' "$l443" | sed 's/^/        /'
    elif [[ -n "$l443" ]]; then
      _st_fail "tcp/443 listener does not belong to service MainPID:"
      printf '%s\n' "$l443" | sed 's/^/        /'
    else
      _st_fail "nothing listening on tcp/443"
    fi
    if [[ -n "$u443" ]]; then
      _st_ok "udp/443 (HTTP/3):"; printf '%s\n' "$u443" | sed 's/^/        /'
    else
      _st_fail "nothing listening on udp/443 (HTTP/3)"
    fi
    if [[ -n "$l80" ]]; then
      _st_info "tcp/80:"; printf '%s\n' "$l80" | sed 's/^/        /'
    else
      _st_info "tcp/80 not listening"
    fi
  else
    _st_warn "ss not available"
  fi
  echo

  echo "[ufw]"
  if ! command -v ufw >/dev/null 2>&1; then
    _st_info "ufw not installed"
  else
    local ust rules
    ust="$(ufw status 2>/dev/null | head -1 || true)"
    if echo "$ust" | grep -qi 'Status: active'; then
      _st_ok "${ust}"
    elif echo "$ust" | grep -qi 'inactive'; then
      _st_warn "ufw inactive (provider/cloud FW may still apply)"
    else
      _st_info "${ust:-ufw status unknown}"
    fi
    rules="$(ufw status numbered 2>/dev/null | grep -iE '443|80|22|OpenSSH' || true)"
    if [[ -n "$rules" ]]; then
      echo "  --- relevant rules ---"
      printf '%s\n' "$rules" | sed 's/^/  | /'
    else
      _st_warn "no ufw rules matched 22/80/443/OpenSSH"
    fi
  fi
  echo

  echo "[clients]"
  if [[ -f "${CREDS}" ]]; then
    if [[ "$client_count" -eq 0 ]]; then
      _st_ok "0 users — endpoint authenticator is deny-all"
    else
      _st_ok "${client_count} user(s) in ${CREDS}"
      print_client_names "        - " || true
    fi
  else
    _st_fail "${CREDS} missing"
  fi
  if [[ -d "${CLIENTS_DIR}" ]]; then
    local cf cn
    cn=0
    for cf in "${CLIENTS_DIR}"/*.toml; do
      [[ -f "$cf" ]] || continue
      cn=$((cn + 1))
      _st_info "client_config ${cf}  meta=$(file_meta "$cf")"
    done
    [[ "$cn" -eq 0 ]] && _st_info "no files in ${CLIENTS_DIR}/"
  else
    _st_info "no ${CLIENTS_DIR}/ yet"
  fi
  echo

  echo "[summary]"
  _st_info "FAIL=${_ST_FAILS}  warn=${_ST_WARNS}"
  if [[ "${_ST_FAILS}" -eq 0 ]]; then
    [[ "${_ST_WARNS}" -eq 0 ]] && echo "OK status" || echo "OK status (with warnings)"
    return 0
  fi
  echo "status: failed (${_ST_FAILS} FAIL)"
  return 1
}

cmd_disable() {
  [[ -f "${UNIT_PATH}" ]] || die "systemd service file missing (${UNIT_PATH}) — not installed?"
  log "disable ${SERVICE_NAME}"
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true
  echo "OK disable"
  echo "  stopped + disabled systemd service (will not start on boot)"
  echo "  kept: ${UNIT_PATH}, ${INSTALL_DIR}/ (binary, configs, credentials, certs/)"
  echo "  re-enable: $0 enable"
}

cmd_enable() {
  [[ -f "${UNIT_PATH}" ]] || die "systemd service file missing (${UNIT_PATH}) — run install first"
  [[ -x "${INSTALL_DIR}/${BIN_NAME}" ]] || die "binary missing — run install first"
  log "enable ${SERVICE_NAME}"
  systemctl daemon-reload
  systemctl enable "${SERVICE_NAME}.service"
  service_restart_check
  echo "OK enable"
  echo "  systemd service enabled + started"
  [[ "$(creds_count)" -gt 0 ]] \
    || echo "  zero users: endpoint is active in deny-all mode"
}

cmd_rollback() {
  local current previous was_active=0
  current="$(binary_resolve_link)" \
    || die "managed binary symlink missing or invalid — run install first"
  previous="$(binary_previous "$current")" \
    || die "no previous successful binary is available"
  systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null && was_active=1

  log "rollback $(basename "$current") → $(basename "$previous")"
  binary_switch_link "$previous"
  if [[ "$was_active" -eq 1 ]]; then
    if ! (
      service_restart_check
    ); then
      binary_switch_link "$current"
      (service_restart_check) >/dev/null 2>&1 || true
      die "rollback binary failed; restored $(basename "$current")"
    fi
  fi
  write_release_meta rollback "$(basename "$previous")" "$(binary_link_path)"
  echo "OK rollback — current=$(basename "$previous")  rollback=$(basename "$current")"
  [[ "$was_active" -eq 1 ]] || echo "  service was inactive and remains inactive"
}

cmd_purge() {
  # Reverse of install (last step first):
  #   install: user+dirs → binary+configs → certs/hook → unit+start → ufw
  #   purge:   stop unit → unit → hook → install dir → user
  # Intentionally NOT reversed (reported under KEPT): apt pkgs, snap/certbot, LE live, ufw.
  local left=0 ufw_line certbot_path

  log "purge ${SERVICE_NAME} (reverse install)"

  log "1/5 stop+disable systemd service"
  systemctl stop "${SERVICE_NAME}.service" 2>/dev/null || true
  systemctl disable "${SERVICE_NAME}.service" 2>/dev/null || true

  log "2/5 remove unit ${UNIT_PATH}"
  rm -f "${UNIT_PATH}"
  systemctl daemon-reload 2>/dev/null || true
  systemctl reset-failed "${SERVICE_NAME}.service" 2>/dev/null || true

  log "3/5 remove certbot deploy hook"
  rm -f "${LE_HOOK}"

  log "4/5 remove ${INSTALL_DIR} (binary, vpn/hosts/creds, clients/, certs/ PEMs, endpoint.ip)"
  rm -rf "${INSTALL_DIR}"

  log "5/5 remove service user ${SERVICE_USER}"
  if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    userdel "${SERVICE_USER}" 2>/dev/null \
      || log "warning: userdel ${SERVICE_USER} failed (process still running?)"
  fi

  echo
  echo "=== purge report ==="
  echo "REMOVED (TT install artifacts):"
  echo "  - systemd unit ${UNIT_PATH}"
  echo "  - certbot hook ${LE_HOOK}"
  echo "  - tree ${INSTALL_DIR}/  (binary, configs, credentials, clients, service PEMs)"
  echo "  - system user ${SERVICE_USER} (if present)"
  echo
  echo "KEPT by design (not part of a clean reverse of host packages/firewall):"
  echo "  - /etc/letsencrypt/  (LE account + live/${CERT_LIVE_NAME} if issued)"
  if [[ -d "${LE_LIVE}" ]]; then
    echo "      present: ${LE_LIVE}"
  else
    echo "      (no live cert dir ${LE_LIVE} — OK if --skip-certbot was used)"
  fi
  echo "  - ufw package, enable state, and allow rules (22/80/443) if install added them"
  if command -v ufw >/dev/null 2>&1; then
    ufw_line="$(ufw status 2>/dev/null | head -1 || true)"
    echo "      status: ${ufw_line:-unknown}"
    ufw status numbered 2>/dev/null | grep -iE '443|80|22|OpenSSH' | sed 's/^/      | /' || true
  else
    echo "      (ufw not installed)"
  fi
  echo "  - apt packages install may have pulled (curl, ca-certificates, openssl, iproute2, snapd, ufw)"
  certbot_path="$(command -v certbot 2>/dev/null || true)"
  if [[ -n "$certbot_path" ]]; then
    echo "  - certbot still on PATH: ${certbot_path} (snap/apt — not removed)"
  fi
  if command -v snap >/dev/null 2>&1 && snap list certbot >/dev/null 2>&1; then
    echo "  - snap package certbot still installed"
  fi
  echo
  echo "LEFTOVER scan (should be empty for TT-managed paths):"
  if [[ -e "${UNIT_PATH}" ]]; then
    echo "  FAIL  still exists: ${UNIT_PATH}"; left=$((left + 1))
  else
    echo "  ok    unit gone"
  fi
  if [[ -e "${LE_HOOK}" ]]; then
    echo "  FAIL  still exists: ${LE_HOOK}"; left=$((left + 1))
  else
    echo "  ok    certbot hook gone"
  fi
  if [[ -e "${INSTALL_DIR}" ]]; then
    echo "  FAIL  still exists: ${INSTALL_DIR}"; left=$((left + 1))
  else
    echo "  ok    ${INSTALL_DIR} gone"
  fi
  if id -u "${SERVICE_USER}" >/dev/null 2>&1; then
    echo "  FAIL  user still exists: ${SERVICE_USER}"; left=$((left + 1))
  else
    echo "  ok    user ${SERVICE_USER} gone"
  fi
  if systemctl is-active --quiet "${SERVICE_NAME}.service" 2>/dev/null; then
    echo "  FAIL  service still active"; left=$((left + 1))
  else
    echo "  ok    service not active"
  fi
  if command -v pgrep >/dev/null 2>&1 && pgrep -f "${BIN_NAME}" >/dev/null 2>&1; then
    echo "  FAIL  process still running: ${BIN_NAME}"; left=$((left + 1))
  elif command -v pgrep >/dev/null 2>&1; then
    echo "  ok    no ${BIN_NAME} process"
  else
    echo "  info  pgrep not available — skip process check"
  fi
  echo
  if [[ "$left" -ne 0 ]]; then
    echo "status: purge incomplete (${left} leftover FAIL) — fix manually then re-run purge"
    return 1
  fi
  echo "OK purge — TT endpoint artifacts removed; KEPT items listed above"
}

# One line at process start for every command: name, script version, UTC time.
announce_start() {
  echo "${0##*/} ${VERSION_SCRIPT}  $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
}

main() {
  local cmd="${1:-help}"
  shift || true
  announce_start
  case "$cmd" in
    help|-h|--help) usage; return 0 ;;
  esac
  need_root
  case "$cmd" in
    install)    cmd_install "$@" ;;
    upgrade)    cmd_upgrade "$@" ;;
    add-user)   cmd_add_user "$@" ;;
    del-user)   cmd_del_user "$@" ;;
    list-users) cmd_list_users "$@" ;;
    status)     cmd_status "$@" ;;
    disable)    cmd_disable "$@" ;;
    enable)     cmd_enable "$@" ;;
    rollback)   cmd_rollback "$@" ;;
    purge)      cmd_purge "$@" ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
