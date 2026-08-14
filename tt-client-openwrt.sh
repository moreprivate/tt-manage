#!/bin/sh
# tt-client-openwrt.sh — MorePrivate tt-client OpenWrt manager (run ON the router as root, busybox ash).
# Sibling: tt-server.sh (VPS endpoint; add-user → clients/<name>.toml).
# Data lifecycle and copy-paste flows: $0 help
set -e

VERSION_SCRIPT="0.6.8"

# Fixed layout — self-contained (only sibling: tt-server.sh on the VPS).
TT_DIR="/etc/moreprivate/tt-client"
CLIENT_TOML="${TT_DIR}/client.toml"
BIN="/usr/bin/tt-client"
INIT="/etc/init.d/tt-client"
GUARD_INIT="/etc/init.d/tt-client-guard"
PBR_NFT="${TT_DIR}/policy.nft"
FAILSAFE_NFT="${TT_DIR}/failsafe.nft"
DIRECT_EL="${TT_DIR}/direct-elements.nft"
DIRECT_DNS_EL="${TT_DIR}/direct-dns-elements.nft"
DIRECT_ZONE="${TT_DIR}/direct.zone"
DIRECT_CONF="${TT_DIR}/direct.conf"
WAN_DEV_FILE="${TT_DIR}/wan.dev"
HOTPLUG="/etc/hotplug.d/iface/95-moreprivate_tt_client-pbr"
DNS_ENV="${TT_DIR}/dns.env"
TT_DNS="${TT_DIR}/tt-dns.sh"
RELEASE_META="${TT_DIR}/release.env"
WAN_SHAPE_CONF="${TT_DIR}/wan-shape.conf"
GITHUB_REPO="${TT_GITHUB_REPO:-moreprivate/tt-client}"
# UCI logical interface (hotplug / ifstatus)
WAN_IF="wan"
# UCI section name for TT-managed SQM/CAKE (do not collide with manual sqm.*)
SQM_UCI_SECTION="moreprivate_tt_client"
MARK_PRIO="20000"
MARK="0x8802"
TUN_TABLE="880"
IPDENY_BASE="https://www.ipdeny.com/ipblocks/data/aggregated"
TUNNEL_DNS_SERVERS_DEFAULT="1.1.1.1 1.0.0.1"

_ST_FAILS=0
_ST_WARNS=0
_BIN_TX_ACTIVE=0
_BIN_TX_OLD=""
_BIN_TX_NEW=""
_BIN_TX_CREATED=0
_BIN_TX_SERVICE_WAS_RUNNING=0

# --- small utils ---
die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
# One line at process start for every command: name, script version, UTC time.
announce_start() {
  echo "${0##*/} ${VERSION_SCRIPT}  $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
}
need_root() { [ "$(id -u)" = "0" ] || die "run as root"; }

bak() {
  [ -f "$1" ] || return 0
  cp -p "$1" "$1.$(date +%Y%m%d%H%M%S).bak"
}

need_file() {
  [ -f "$1" ] || die "not found: $1"
}

need_arg() {
  # need_arg <flag> <value>
  [ -n "${2:-}" ] || die "$1 needs a value"
}

need_cmds() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "need command: $c"
  done
}

is_installed() {
  [ -x "$BIN" ] \
    && [ -f "$CLIENT_TOML" ] \
    && [ -x "$INIT" ] \
    && [ -x "$GUARD_INIT" ] \
    && [ -f "$PBR_NFT" ] \
    && [ -f "$FAILSAFE_NFT" ]
}

has_install_artifacts() {
  local f
  [ -e "$TT_DIR" ] && return 0
  if [ -e "$BIN" ] || [ -L "$BIN" ]; then
    return 0
  fi
  [ -e "$INIT" ] && return 0
  [ -e "$GUARD_INIT" ] && return 0
  [ -e "$HOTPLUG" ] && return 0
  [ -e /etc/sysctl.d/99-moreprivate_tt_client-ipv6.conf ] && return 0
  for f in /etc/rc.d/*moreprivate_tt_client*; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      return 0
    fi
  done
  for f in /usr/bin/tt-client-*-linux-*; do
    [ -e "$f" ] && return 0
  done
  client_running && return 0
  if command -v nft >/dev/null 2>&1 \
    && nft list table inet moreprivate_tt_client >/dev/null 2>&1; then
    return 0
  fi
  if command -v ip >/dev/null 2>&1 \
    && ip rule show 2>/dev/null | grep -q "${MARK_PRIO}:.*${MARK}"; then
    return 0
  fi
  if command -v uci >/dev/null 2>&1; then
    uci -q get network.moreprivate_tt_client >/dev/null 2>&1 && return 0
    uci -q get firewall.moreprivate_tt_client >/dev/null 2>&1 && return 0
    uci -q get firewall.moreprivate_tt_client_icmp_reply >/dev/null 2>&1 && return 0
    uci -q get firewall.lan_moreprivate_tt_client >/dev/null 2>&1 && return 0
    uci -q get firewall.moreprivate_tt_client_lan_wan >/dev/null 2>&1 && return 0
  fi
  return 1
}

need_installed() {
  is_installed || die "not installed (run install first)"
}

# busybox grep -c exits 1 when count is 0 — never use `grep -c || echo 0` (→ "0\n0")
count_cidr() {
  local f="$1" n
  n=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$f" 2>/dev/null) || n=0
  echo "${n:-0}"
}

toml_get_str() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\([^\"]*\\)\".*/\\1/p" "$file" | head -1
}

# status lines (same shape as tt-server.sh)
_st_ok() { echo "  ok    $*"; }
_st_warn() { echo "  warn  $*"; _ST_WARNS=$((_ST_WARNS + 1)); }
_st_fail() { echo "  FAIL  $*"; _ST_FAILS=$((_ST_FAILS + 1)); }
_st_info() { echo "  info  $*"; }

usage() {
  cat <<EOF
NAME
    tt-client-openwrt.sh ${VERSION_SCRIPT} — MorePrivate tt-client on OpenWrt (root on this router)

SYNOPSIS
    $0 install --config FILE [OPTIONS]
    $0 upgrade [--binary PATH | --version TAG]
    $0 update-creds --config FILE
    $0 update-direct [DIRECT-PROFILE OPTIONS]
    $0 direct-enable | direct-disable
    $0 tun-shape --download KBIT --upload KBIT
    $0 tun-shape-disable
    $0 disable | enable | restart
    $0 rollback
    $0 status
    $0 purge

DESCRIPTION
    LIST values accept commas or whitespace.

    --direct-countries LIST
        Automatic direct profile from two-letter country codes: IPdeny IPv4
        ranges, country DNS suffixes, and WAN-provided DNS.
        Example: "nl ch". GB maps to the delegated .uk suffix.
    --direct-ip-file PATH
        Use a custom direct IPv4 CIDR list instead of --direct-countries.
    --direct-dns-domains LIST
        Override automatically derived direct DNS suffixes.
    --direct-dns-servers LIST
        Override automatically discovered WAN DNS resolver IPv4 addresses.
        Router DNS traffic to these exact addresses bypasses the tunnel.
    --tunnel-dns-servers LIST
        Resolver IPv4 addresses for every other name.
        Default: ${TUNNEL_DNS_SERVERS_DEFAULT}
    Direct mode is fail-safe only as a complete profile. If either direct IP
    source is configured, direct DNS domains and direct DNS servers are
    required. Tunnel DNS server IPs may be inside or outside that list.
    DNS selection chooses only the resolver path. The returned IPv4 address is
    independently sent direct if it is in the direct list, otherwise through
    MorePrivate tt-client.

    If 1.1.1.1 is direct, automatic VPS-egress identity verification through
    it is skipped; test a known non-direct IP checker as instructed.

    install/upgrade binary source (same flags on server and clients):
        --version TAG   exact ${GITHUB_REPO} release
        --binary PATH   local file instead of a release
    install is clean-only and refuses complete or partial MorePrivate tt-client state.
    Use upgrade/update-* for an installed system, or purge before reinstalling.

    install tries a one-shot sync using the existing NTP configuration, then
    tries a plain-HTTP timestamp from 1.1.1.1. Clock failure only warns and
    continues; verify/set the clock manually if later HTTPS operations fail.
    The script never changes OpenWrt NTP settings.
    Stock OpenWrt can install every prerequisite from its matching feeds.
    Custom firmware must build in kmod-tun because kernel modules require an
    exact kernel ABI; all other prerequisites are ordinary userspace packages.

    With no direct-* options, all supported traffic uses MorePrivate tt-client; only the
    router's TCP connection to the configured endpoint IP and port uses WAN.
    That endpoint exception overrides the country list: every other flow to
    the endpoint IP, including SSH, uses MorePrivate tt-client. dnsmasq uses the tunnel
    DNS servers.

    upgrade changes only the binary. rollback switches current and previous
    successful binaries. disable/enable/restart control only the client service;
    routing policy remains fail-closed (disable leaves the kill switch on — net
    stays broken for non-direct traffic until enable). restart = stop+start,
    keep boot enablement, re-verify tunnel. direct-disable sends supported traffic
    except the router's configured server TCP connection through MorePrivate tt-client.
    purge removes MorePrivate tt-client routing and restores ordinary direct WAN.
    An independent nftables kill switch starts before OpenWrt networking and
    remains active across client and firewall4 stops/reloads.

    tun-shape installs optional SQM/CAKE on tun0 only (the tunnel), never on
    ISP WAN. WAN is typically far faster than the VPN; shaping WAN only caps
    tunnel throughput. Use tun-shape only if bufferbloat under load is proven;
    rates ≈ 85–95% of measured tunnel bulk (kbit/s). tun-shape-disable removes
    the TT-owned SQM section.

EXAMPLES
    # Full NL installation
    ./tt-client-openwrt.sh install \\
      --config ./openwrt.toml \\
      --direct-countries "nl"

    # Optional tuning overrides
    ./tt-client-openwrt.sh update-direct \\
      --direct-countries "nl ch" \\
      --direct-dns-servers "80.80.80.80 80.80.81.81"

    ./tt-client-openwrt.sh upgrade
    ./tt-client-openwrt.sh update-direct
    # Optional: shape tun0 only (never WAN), kbit/s ≈ tunnel bulk:
    ./tt-client-openwrt.sh tun-shape --download 100000 --upload 100000
    ./tt-client-openwrt.sh tun-shape-disable
    ./tt-client-openwrt.sh status
    ./tt-client-openwrt.sh rollback

EOF
}

# --- direct conf + fetch (self-contained; ipdeny on-router) ---
norm_ids() {
  normalize_list "$(echo "$1" | tr 'A-Z' 'a-z')"
}

country_network_name() {
  case "$1" in
    gb) echo uk ;;
    *) echo "$1" ;;
  esac
}

derive_country_domains() {
  local id name out=""
  for id in $(norm_ids "$1"); do
    echo "$id" | grep -qE '^[a-z][a-z]$' \
      || die "direct country must be a two-letter code: $id"
    name="$(country_network_name "$id")"
    out="${out} ${name}"
  done
  unique_list "$out"
}

get_wan_dns_servers() {
  local status="" found="" ip
  if [ -f /lib/functions/network.sh ]; then
    found="$(
      . /lib/functions/network.sh
      network_get_dnsserver _tt_wan_dns "$WAN_IF" 2>/dev/null || true
      printf '%s\n' "${_tt_wan_dns:-}"
    )"
  fi
  if [ -z "$found" ] && command -v ifstatus >/dev/null 2>&1; then
    status="$(ifstatus "$WAN_IF" 2>/dev/null || true)"
  elif [ -z "$found" ] && command -v ubus >/dev/null 2>&1; then
    status="$(ubus call "network.interface.${WAN_IF}" status 2>/dev/null || true)"
  fi
  if [ -z "$found" ] && [ -n "$status" ] && command -v jsonfilter >/dev/null 2>&1; then
    found="$(printf '%s\n' "$status" | jsonfilter -e '@["dns-server"][*]' 2>/dev/null || true)"
  fi
  # Explicit UCI DNS is a valid fallback when the live status has no peer DNS.
  found="${found} $(uci -q get "network.${WAN_IF}.dns" 2>/dev/null || true)"
  for ip in $(normalize_list "$found"); do
    is_ipv4 "$ip" && echo "$ip"
  done | awk '!seen[$0]++'
}

derive_country_profile() {
  local countries="$1" wan_dns
  [ -n "$countries" ] || die "cannot derive direct profile from an empty country list"
  [ "${DIRECT_DNS_DOMAINS_MODE:-auto}" != auto ] \
    || DIRECT_DNS_DOMAINS="$(derive_country_domains "$countries")"
  if [ "${DIRECT_DNS_SERVERS_MODE:-auto}" = auto ]; then
    wan_dns="$(get_wan_dns_servers)"
    [ -n "$wan_dns" ] || die "no WAN DNS discovered; set --direct-dns-servers explicitly"
    DIRECT_DNS_SERVERS="$(normalize_list "$wan_dns")"
  fi
}

normalize_list() {
  printf '%s\n' "$1" | tr ',\t\r\n' '    ' | tr -s ' ' | sed 's/^ //;s/ $//'
}

unique_list() {
  normalize_list "$1" | awk '{
    for (i = 1; i <= NF; i++)
      if (!seen[$i]++) out = out (out ? " " : "") $i
  } END { print out }'
}

is_ipv4() {
  echo "$1" | awk -F. 'NF != 4 { exit 1 }
    { for (i = 1; i <= 4; i++) if ($i !~ /^[0-9]+$/ || $i > 255) exit 1 }'
}

validate_direct_zone() {
  local zone="$1" bad
  need_file "$zone"
  bad="$(awk -F'[./]' '
    /^[[:space:]]*(#|$)/ { next }
    NF != 5 { print NR ": malformed IPv4 CIDR"; exit }
    {
      for (i = 1; i <= 4; i++)
        if ($i !~ /^[0-9]+$/ || $i > 255) {
          print NR ": invalid IPv4 octet"; exit
        }
      if ($5 !~ /^[0-9]+$/ || $5 < 1 || $5 > 32) {
        print NR ": prefix length must be 1..32"; exit
      }
      ip = ($1 * 16777216) + ($2 * 65536) + ($3 * 256) + $4
      size = 2 ^ (32 - $5)
      first = int(ip / size) * size
      last = first + size - 1
      # Never authorize broad/non-public destination space for direct WAN.
      split("0/8 10/8 100.64/10 127/8 169.254/16 172.16/12 192.0/24 192.0.2/24 192.168/16 198.18/15 198.51.100/24 203.0.113/24 224/4 240/4", r, " ")
      for (j in r) {
        split(r[j], p, "/")
        split(p[1], o, ".")
        base = (o[1] * 16777216) + ((o[2] + 0) * 65536) + ((o[3] + 0) * 256) + (o[4] + 0)
        span = 2 ^ (32 - p[2])
        if (first <= base + span - 1 && last >= base) {
          print NR ": private/reserved range overlaps " r[j]; exit
        }
      }
    }
  ' "$zone")"
  [ -z "$bad" ] || die "unsafe direct IP list ${zone}: ${bad}"
}

validate_direct_dependencies() {
  local zone="$1" domains_ascii
  validate_direct_zone "$zone"
  domains_ascii="$(domains_to_ascii_list "$DIRECT_DNS_DOMAINS")" \
    || need_idna_tool_hint "cannot convert DIRECT_DNS_DOMAINS to punycode: ${DIRECT_DNS_DOMAINS}"
  [ -n "$domains_ascii" ] || die "--direct-dns-domains produced an empty suffix list"
}

validate_dns_policy() {
  local ip
  if { [ -n "$DIRECT_DNS_DOMAINS" ] && [ -z "$DIRECT_DNS_SERVERS" ]; } \
    || { [ -z "$DIRECT_DNS_DOMAINS" ] && [ -n "$DIRECT_DNS_SERVERS" ]; }; then
    die "--direct-dns-domains and --direct-dns-servers must be set together"
  fi
  [ -n "$TUNNEL_DNS_SERVERS" ] || die "--tunnel-dns-servers cannot be empty"
  for ip in $DIRECT_DNS_SERVERS $TUNNEL_DNS_SERVERS; do
    is_ipv4 "$ip" || die "DNS server must be an IPv4 address: $ip"
  done
}

validate_direct_profile() {
  local zone="${1:-$DIRECT_ZONE}"
  validate_dns_policy
  if [ -z "${DIRECT_SOURCE:-}" ]; then
    [ -z "${DIRECT_COUNTRIES:-}" ] \
      && [ -z "${DIRECT_DNS_DOMAINS:-}" ] \
      && [ -z "${DIRECT_DNS_SERVERS:-}" ] \
      || die "incomplete direct profile: add --direct-countries or --direct-ip-file, or omit all direct options"
    return 0
  fi
  case "$DIRECT_SOURCE" in
    ipdeny)
      [ -n "${DIRECT_COUNTRIES:-}" ] \
        || die "incomplete direct profile: --direct-countries is empty"
      ;;
    file) ;;
    *) die "invalid direct IP source: ${DIRECT_SOURCE}" ;;
  esac
  [ -f "$zone" ] && [ "$(count_cidr "$zone")" -gt 0 ] \
    || die "incomplete direct profile: direct IP list is empty"
  [ -n "${DIRECT_DNS_DOMAINS:-}" ] \
    || die "incomplete direct profile: --direct-dns-domains is required"
  [ -n "${DIRECT_DNS_SERVERS:-}" ] \
    || die "incomplete direct profile: --direct-dns-servers is required"
  validate_direct_dependencies "$zone"
}

conf_get() {
  local key="$1" file="$2"
  [ -f "$file" ] || return 0
  sed -n "s/^${key}=//p" "$file" | head -1 | sed 's/^"//;s/"$//'
}

# True if string is pure DNS LDH (letters digits hyphen) + dots (already ASCII).
is_ascii_domain() {
  case "$1" in
    ''|*[!A-Za-z0-9.-]*) return 1 ;;
  esac
  # reject leading/trailing dot or empty labels
  case ".$1." in
    *..*) return 1 ;;
  esac
  return 0
}

# One domain/suffix → ASCII/punycode using IDNA 2008 / non-transitional UTS-46.
# Plain ASCII LDH/A-label input needs no tool. Unicode uses only an
# IDNA-2008-capable implementation so equivalent forms canonicalize equally.
domain_to_ascii() {
  local d="$1" out=""
  d="$(echo "$d" | sed 's/^\.//;s/\.$//')"
  [ -n "$d" ] || return 1
  if is_ascii_domain "$d"; then
    echo "$d" | tr 'A-Z' 'a-z'
    return 0
  fi
  if command -v idn2 >/dev/null 2>&1; then
    out="$(printf '%s' "$d" | idn2 --quiet 2>/dev/null)" \
      && [ -n "$out" ] && { echo "$out" | tr 'A-Z' 'a-z'; return 0; }
  fi
  if command -v python3 >/dev/null 2>&1; then
    out="$(DOMAIN="$d" python3 -c 'import os,sys
try:
  import idna
  d=os.environ["DOMAIN"].strip(".")
  print(idna.encode(d, uts46=True, transitional=False, std3_rules=True).decode("ascii"))
except Exception:
  sys.exit(1)
' 2>/dev/null)" && [ -n "$out" ] && { echo "$out"; return 0; }
  fi
  return 1
}

# Space-separated domain list → space-separated punycode list (unique, order kept).
domains_to_ascii_list() {
  local raw="$1" d a out="" seen=" "
  raw="$(normalize_list "$raw")"
  for d in $raw; do
    [ -n "$d" ] || continue
    a="$(domain_to_ascii "$d")" || return 1
    case "$seen" in
      *" $a "*) continue ;;
    esac
    seen="${seen}${a} "
    out="${out} ${a}"
  done
  normalize_list "$out"
  return 0
}

need_idna_tool_hint() {
  die "$*
  need idn2 or Python with the third-party idna module for IDNA 2008 / UTS-46
  apk add idn2"
}

load_direct_conf() {
  DIRECT_ENABLED=0
  DIRECT_COUNTRIES=""
  DIRECT_SOURCE="" # ipdeny | file
  DIRECT_DNS_DOMAINS=""
  DIRECT_DNS_SERVERS=""
  DIRECT_DNS_DOMAINS_MODE=""
  DIRECT_DNS_SERVERS_MODE=""
  TUNNEL_DNS_SERVERS="$TUNNEL_DNS_SERVERS_DEFAULT"
  if [ -f "$DIRECT_CONF" ]; then
    DIRECT_ENABLED="$(conf_get DIRECT_ENABLED "$DIRECT_CONF")"
    DIRECT_SOURCE="$(conf_get DIRECT_SOURCE "$DIRECT_CONF")"
    DIRECT_COUNTRIES="$(conf_get DIRECT_COUNTRIES "$DIRECT_CONF")"
    DIRECT_DNS_DOMAINS="$(conf_get DIRECT_DNS_DOMAINS "$DIRECT_CONF")"
    DIRECT_DNS_SERVERS="$(conf_get DIRECT_DNS_SERVERS "$DIRECT_CONF")"
    DIRECT_DNS_DOMAINS_MODE="$(conf_get DIRECT_DNS_DOMAINS_MODE "$DIRECT_CONF")"
    DIRECT_DNS_SERVERS_MODE="$(conf_get DIRECT_DNS_SERVERS_MODE "$DIRECT_CONF")"
    TUNNEL_DNS_SERVERS="$(conf_get TUNNEL_DNS_SERVERS "$DIRECT_CONF")"
  fi
  case "${DIRECT_ENABLED:-0}" in
    1|yes|true|on) DIRECT_ENABLED=1 ;;
    *) DIRECT_ENABLED=0 ;;
  esac
  case "${DIRECT_SOURCE:-}" in
    file) DIRECT_SOURCE=file ;;
    ipdeny) DIRECT_SOURCE=ipdeny ;;
    *) DIRECT_SOURCE="" ;;
  esac
  DIRECT_COUNTRIES="$(norm_ids "${DIRECT_COUNTRIES:-}")"
  DIRECT_DNS_DOMAINS="$(normalize_list "${DIRECT_DNS_DOMAINS:-}")"
  DIRECT_DNS_SERVERS="$(normalize_list "${DIRECT_DNS_SERVERS:-}")"
  case "$DIRECT_DNS_DOMAINS_MODE" in auto|manual) ;; *) DIRECT_DNS_DOMAINS_MODE=manual ;; esac
  case "$DIRECT_DNS_SERVERS_MODE" in auto|manual) ;; *) DIRECT_DNS_SERVERS_MODE=manual ;; esac
  TUNNEL_DNS_SERVERS="$(normalize_list "${TUNNEL_DNS_SERVERS:-$TUNNEL_DNS_SERVERS_DEFAULT}")"
  [ -n "$TUNNEL_DNS_SERVERS" ] || TUNNEL_DNS_SERVERS="$TUNNEL_DNS_SERVERS_DEFAULT"
}

save_direct_conf() {
  local tmp="${DIRECT_CONF}.new.$$"
  mkdir -p "$TT_DIR" || return 1
  {
    cat <<EOF
# managed by tt-client-openwrt.sh
# IP:  DIRECT_ZONE + DIRECT_ENABLED → nft tt_direct4 (DIRECT_COUNTRIES = ipdeny countries only)
# DNS: DIRECT_DNS_DOMAINS → DIRECT_DNS_SERVERS; else → TUNNEL_DNS_SERVERS
#      Country profiles derive defaults; explicit options override each field.
DIRECT_ENABLED=${DIRECT_ENABLED:-0}
DIRECT_SOURCE=${DIRECT_SOURCE:-}
DIRECT_COUNTRIES="${DIRECT_COUNTRIES:-}"
DIRECT_DNS_DOMAINS="${DIRECT_DNS_DOMAINS:-}"
DIRECT_DNS_SERVERS="${DIRECT_DNS_SERVERS:-}"
DIRECT_DNS_DOMAINS_MODE="${DIRECT_DNS_DOMAINS_MODE:-manual}"
DIRECT_DNS_SERVERS_MODE="${DIRECT_DNS_SERVERS_MODE:-manual}"
TUNNEL_DNS_SERVERS="${TUNNEL_DNS_SERVERS:-$TUNNEL_DNS_SERVERS_DEFAULT}"
EOF
  } >"$tmp" || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv -f "$tmp" "$DIRECT_CONF" || { rm -f "$tmp"; return 1; }
}

http_fetch() {
  local url="$1" out="$2"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" "$url" 2>/dev/null && return 0
  fi
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$out" "$url" 2>/dev/null && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL --max-time 120 -o "$out" "$url" 2>/dev/null && return 0
  fi
  return 1
}

http_fetch_host() {
  local url="$1" host="$2" out="$3"
  if command -v wget >/dev/null 2>&1; then
    wget -q -O "$out" --header="Host: ${host}" "$url" 2>/dev/null && return 0
  fi
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -O "$out" --header="Host: ${host}" "$url" 2>/dev/null \
      && return 0
  fi
  if command -v curl >/dev/null 2>&1; then
    curl -fsS --max-time 20 -H "Host: ${host}" -o "$out" "$url" 2>/dev/null \
      && return 0
  fi
  return 1
}

release_arch() {
  local arch=""
  if [ -f /etc/openwrt_release ]; then
    arch="$(sed -n "s/^DISTRIB_ARCH=['\"]\\([^'\"]*\\)['\"].*/\\1/p" /etc/openwrt_release | head -1)"
  fi
  if [ -z "$arch" ] && command -v apk >/dev/null 2>&1; then
    arch="$(apk --print-arch 2>/dev/null || true)"
  fi
  [ -n "$arch" ] || arch="$(uname -m)"
  case "$arch" in
    aarch64*|arm64*) echo aarch64 ;;
    mipsel*) echo mipsel ;;
    *) die "unsupported release architecture: ${arch} (use --binary PATH)" ;;
  esac
}

# Preserve the published asset's original release identity for both downloaded
# and user-supplied binaries. Never invent a "local-<hash>" filename.
binary_tag_from_file() {
  local base="$(basename "$1")" tag=""
  case "$base" in
    tt-client-*-linux-*)
      tag="${base#tt-client-}"
      tag="${tag%-linux-*}"
      ;;
  esac
  [ -n "$tag" ] || die "binary filename must be a release asset (expected tt-client-<tag>-linux-<arch>): $base"
  printf '%s' "$tag"
}

resolve_latest_version() {
  local stage json tag
  stage="${TT_DIR}/.release-latest.$$"
  mkdir -p "$stage"
  json="${stage}/latest.json"
  http_fetch "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" "$json" \
    || { rm -rf "$stage"; die "failed to query latest release for ${GITHUB_REPO}"; }
  tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$json" | head -1)"
  rm -rf "$stage"
  [ -n "$tag" ] || die "latest published release has no tag_name: ${GITHUB_REPO}"
  echo "$tag"
}

download_release_binary() {
  local tag="$1" arch asset url stage expect got actual
  echo "$tag" | grep -qE '^[A-Za-z0-9._-]+$' || die "invalid release tag: ${tag}"
  arch="$(release_arch)"
  asset="tt-client-${tag}-linux-${arch}"
  url="https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
  stage="${TT_DIR}/.release-download.$$"
  mkdir -p "$stage"
  log "download ${url}" >&2
  http_fetch "$url" "${stage}/${asset}" \
    || { rm -rf "$stage"; die "download failed for ${GITHUB_REPO} tag '${tag}' asset '${asset}'"; }
  http_fetch "${url}.sha256" "${stage}/${asset}.sha256" \
    || { rm -rf "$stage"; die "missing mandatory checksum: ${asset}.sha256"; }
  expect="$(awk '{print $1; exit}' "${stage}/${asset}.sha256")"
  echo "$expect" | grep -qE '^[0-9a-fA-F]{64}$' \
    || { rm -rf "$stage"; die "invalid checksum file for ${asset}"; }
  got="$(sha256sum "${stage}/${asset}" | awk '{print $1}')"
  [ "$(echo "$expect" | tr 'A-F' 'a-f')" = "$(echo "$got" | tr 'A-F' 'a-f')" ] \
    || { rm -rf "$stage"; die "sha256 mismatch for ${asset}"; }
  chmod 755 "${stage}/${asset}"
  actual="$("${stage}/${asset}" --version 2>/dev/null)" \
    || { rm -rf "$stage"; die "downloaded client binary is not runnable"; }
  embedded="${actual#tt-client }"
  echo "$embedded" | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$' \
    || { rm -rf "$stage"; die "downloaded client reported invalid embedded version '${actual}'"; }
  echo "$tag" | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$' \
    || { rm -rf "$stage"; die "invalid release tag format: '${tag}'"; }
  [ "$embedded" = "$tag" ] \
    || { rm -rf "$stage"; die "embedded version '${embedded}' does not match release tag '${tag}'"; }
  log "embedded client version: ${embedded}" >&2
  echo "${stage}/${asset}"
}

save_release_meta() {
  local source="$1" tag="$2" digest tmp="${RELEASE_META}.candidate.$$"
  digest="$(sha256sum "$BIN" | awk '{print $1}')" || return 1
  mkdir -p "$TT_DIR" || return 1
  cat >"$tmp" <<EOF
RELEASE_SOURCE=${source}
RELEASE_TAG=${tag}
BINARY_SHA256=${digest}
EOF
  [ "$?" -eq 0 ] || { rm -f "$tmp"; return 1; }
  chmod 644 "$tmp" || { rm -f "$tmp"; return 1; }
  mv "$tmp" "$RELEASE_META" || { rm -f "$tmp"; return 1; }
}

# Fetch ipdeny zones for DIRECT_COUNTRIES into DIRECT_ZONE (merged unique CIDRs).
fetch_direct_zone() {
  local ids="$1" target="${2:-$DIRECT_ZONE}" id url tmpdir f n
  ids="$(norm_ids "$ids")"
  [ -n "$ids" ] || die "DIRECT_COUNTRIES empty"
  need_cmds grep sort
  command -v wget >/dev/null 2>&1 \
    || command -v uclient-fetch >/dev/null 2>&1 \
    || command -v curl >/dev/null 2>&1 \
    || die "need wget, uclient-fetch, or curl to download the direct IP list (apk add wget-ssl)"

  tmpdir="/tmp/tt-direct.$$"
  mkdir -p "$tmpdir"
  : >"$tmpdir/merged"
  for id in $ids; do
    [ -n "$id" ] || continue
    echo "$id" | grep -qE '^[a-z][a-z]$' \
      || { rm -rf "$tmpdir"; die "direct country must be a two-letter code: $id"; }
    url="${IPDENY_BASE}/${id}-aggregated.zone"
    f="$tmpdir/${id}.zone"
    log "direct IP fetch $url"
    http_fetch "$url" "$f" || {
      rm -rf "$tmpdir"
      die "direct IP download failed for country=${id} (need WAN before fail-closed or use --direct-ip-file)"
    }
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$f" >>"$tmpdir/merged" \
      || {
        rm -rf "$tmpdir"
        die "no IPv4 CIDRs in feed for id=${id}"
      }
  done
  sort -u "$tmpdir/merged" >"$tmpdir/direct.zone"
  n=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$tmpdir/direct.zone" 2>/dev/null) || n=0
  [ "${n:-0}" -gt 0 ] || {
    rm -rf "$tmpdir"
    die "empty direct IP list after fetch"
  }
  validate_direct_zone "$tmpdir/direct.zone"
  mkdir -p "$TT_DIR"
  [ "$target" != "$DIRECT_ZONE" ] || bak "$DIRECT_ZONE"
  cp "$tmpdir/direct.zone" "$target"
  chmod 644 "$target"
  rm -rf "$tmpdir"
  DIRECT_SOURCE=ipdeny
  log "direct IP prefixes=${n} countries=${ids} (ipdeny)"
}

# Install zone from local file (one IPv4 CIDR per line). Comments/blank lines ignored.
install_direct_zone_file() {
  local src="$1" target="${2:-$DIRECT_ZONE}" n
  need_file "$src"
  validate_direct_zone "$src"
  n=$(grep -cE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$src" 2>/dev/null) || n=0
  [ "${n:-0}" -gt 0 ] || die "no IPv4 CIDRs in $src (one prefix per line, e.g. 1.2.3.0/24)"
  mkdir -p "$TT_DIR"
  [ "$target" != "$DIRECT_ZONE" ] || bak "$DIRECT_ZONE"
  grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$src" | sort -u >"$target"
  chmod 644 "$target"
  DIRECT_SOURCE=file
  DIRECT_COUNTRIES=""
  log "direct IP list from ${src} prefixes=$(count_cidr "$target")"
}

# IP technique: empty set (direct off) or full zone (direct on) → PBR reload
apply_direct_ip() {
  local vps_ip wan_dev
  vps_ip="$(parse_vps_ip "$CLIENT_TOML")" || die "cannot parse VPS_IP from client.toml"
  wan_dev="$(get_wan_dev)"
  mkdir -p "$TT_DIR" || return 1
  if [ "${DIRECT_ENABLED:-0}" = "1" ] && [ -f "$DIRECT_ZONE" ]; then
    direct_zone_to_elements "$DIRECT_ZONE" "$DIRECT_EL" || return 1
    direct_dns_to_elements "$DIRECT_DNS_EL" || return 1
  else
    write_empty_set_elements "$DIRECT_EL" || return 1
    write_empty_set_elements "$DIRECT_DNS_EL" || return 1
  fi
  chmod 644 "$DIRECT_EL" || return 1
  chmod 644 "$DIRECT_DNS_EL" || return 1
  apply_pbr "$vps_ip" "$wan_dev" || return 1
}

# DNS technique from the persisted derived/overridden profile.
# direct.conf keeps user form (UTF-8 ok); dns.env gets punycode for dnsmasq.
apply_direct_dns() {
  local domains_user="" domains_ascii="" direct_dns="" tunnel_dns
  mkdir -p "$TT_DIR" || return 1
  tunnel_dns="$(normalize_list "${TUNNEL_DNS_SERVERS:-$TUNNEL_DNS_SERVERS_DEFAULT}")"
  write_tt_dns
  if [ "${DIRECT_ENABLED:-0}" = "1" ]; then
    domains_user="$(normalize_list "${DIRECT_DNS_DOMAINS:-}")"
    direct_dns="$(normalize_list "${DIRECT_DNS_SERVERS:-}")"
    if [ -n "$domains_user" ] && [ -n "$direct_dns" ]; then
      domains_ascii="$(domains_to_ascii_list "$domains_user")" \
        || need_idna_tool_hint "cannot convert DIRECT_DNS_DOMAINS to punycode: ${domains_user}"
      [ -n "$domains_ascii" ] || die "DIRECT_DNS_DOMAINS produced empty punycode list"
    else
      domains_user=""
      domains_ascii=""
      direct_dns=""
    fi
  fi
  # dns.env: ASCII/punycode only (what dnsmasq matches)
  cat >"$DNS_ENV" <<EOF
TUNNEL_DNS_SERVERS="${tunnel_dns}"
DIRECT_DNS_SERVERS="${direct_dns}"
DIRECT_DNS_DOMAINS="${domains_ascii}"
EOF
  [ "$?" -eq 0 ] || return 1
  chmod 600 "$DNS_ENV" || return 1
  "$TT_DNS" apply || return 1
  if [ "${DIRECT_ENABLED:-0}" = "1" ]; then
    if [ -n "$domains_ascii" ] && [ -n "$direct_dns" ]; then
      log "direct DNS on: domains=[${domains_user}] ascii=[${domains_ascii}] servers=[${direct_dns}]"
    else
      log "direct DNS off (need both direct DNS options); direct IP routing remains active"
    fi
  fi
  return 0
}

# Apply both techniques from direct.conf + DIRECT_ZONE
apply_direct_stack() {
  validate_dns_policy || return 1
  if [ "${DIRECT_ENABLED:-0}" = "1" ]; then
    validate_direct_profile "$DIRECT_ZONE" || return 1
  fi
  apply_direct_ip || return 1
  apply_direct_dns || return 1
}

# --- WAN device ---
# Prefer live ifstatus l3_device; then UCI; then saved file; then logical name.
get_wan_dev() {
  local d=""
  if command -v ifstatus >/dev/null 2>&1 && command -v jsonfilter >/dev/null 2>&1; then
    d="$(ifstatus "$WAN_IF" 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
    [ -n "$d" ] && { echo "$d"; return 0; }
    d="$(ifstatus "$WAN_IF" 2>/dev/null | jsonfilter -e '@.device' 2>/dev/null || true)"
    [ -n "$d" ] && { echo "$d"; return 0; }
  fi
  d="$(uci -q get network.${WAN_IF}.device 2>/dev/null || true)"
  case "$d" in @*) d="" ;; esac
  [ -n "$d" ] && { echo "$d"; return 0; }
  if [ -f "$WAN_DEV_FILE" ]; then
    d="$(cat "$WAN_DEV_FILE" 2>/dev/null || true)"
    [ -n "$d" ] && { echo "$d"; return 0; }
  fi
  echo "$WAN_IF"
}

save_wan_dev() {
  mkdir -p "$TT_DIR" || return 1
  echo "$1" >"$WAN_DEV_FILE" || return 1
  chmod 644 "$WAN_DEV_FILE" || return 1
}

# --- TOML / config ---
parse_vps_ip() {
  local f="$1" ip
  [ -f "$f" ] || return 1
  ip="$(sed -n 's/.*addresses[[:space:]]*=[[:space:]]*\[.*"\([0-9][0-9.]*\):[0-9][0-9]*".*/\1/p' "$f" | head -1)"
  [ -n "$ip" ] || ip="$(sed -n 's/^hostname[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$f" | head -1)"
  echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  echo "$ip"
}

parse_vps_port() {
  local f="$1" port
  [ -f "$f" ] || return 1
  port="$(sed -n 's/.*addresses[[:space:]]*=[[:space:]]*\[.*"[0-9][0-9.]*:\([0-9][0-9]*\)".*/\1/p' "$f" | head -1)"
  echo "$port" | grep -qE '^[0-9]+$' || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  echo "$port"
}

parse_pbr_vps_ip() {
  local ip
  [ -f "$PBR_NFT" ] || return 1
  ip="$(sed -n 's/^# endpoint_ip=\([0-9][0-9.]*\)$/\1/p' "$PBR_NFT" | head -1)"
  echo "$ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  echo "$ip"
}

parse_pbr_vps_port() {
  local port
  [ -f "$PBR_NFT" ] || return 1
  port="$(sed -n 's/^# endpoint_port=\([0-9][0-9]*\)$/\1/p' "$PBR_NFT" | head -1)"
  echo "$port" | grep -qE '^[0-9]+$' || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  echo "$port"
}

# wan_dev recorded in PBR comment header (see write_pbr_nft)
parse_pbr_wan_dev() {
  local d
  [ -f "$PBR_NFT" ] || return 1
  d="$(sed -n 's/^# wan_dev=\(.*\)/\1/p' "$PBR_NFT" | head -1)"
  [ -n "$d" ] || return 1
  echo "$d"
}

# Install client.toml from server file; enforce OpenWrt requirements.
# $1=src  $2=wan_dev
install_client_toml() {
  local src="$1" wan_dev="$2" tmp protocol=""
  need_file "$src"
  [ -n "$wan_dev" ] || die "wan_dev empty"
  parse_vps_ip "$src" >/dev/null || die "config missing VPS IPv4 in addresses/hostname"
  parse_vps_port "$src" >/dev/null || die "config missing endpoint port in addresses"
  protocol="$(toml_get_str upstream_protocol "$src" 2>/dev/null || true)"
  [ "$protocol" = "auto" ] || [ "$protocol" = "http2" ] || [ "$protocol" = "http3" ] \
    || die "OpenWrt fail-closed policy supports upstream_protocol = \"auto\", \"http2\", or \"http3\""
  mkdir -p "$TT_DIR"
  chmod 700 "$TT_DIR"
  bak "$CLIENT_TOML"
  if [ ! "$src" -ef "$CLIENT_TOML" ]; then
    cp "$src" "$CLIENT_TOML"
  fi

  if grep -qE '^exclusions[[:space:]]*=' "$CLIENT_TOML"; then
    sed -i 's/^exclusions[[:space:]]*=.*/exclusions = []/' "$CLIENT_TOML"
  else
    printf '\nexclusions = []\n' >>"$CLIENT_TOML"
  fi

  if grep -qE '^bound_if[[:space:]]*=' "$CLIENT_TOML"; then
    sed -i "s|^bound_if[[:space:]]*=.*|bound_if = \"${wan_dev}\"|" "$CLIENT_TOML"
  elif grep -qE '^#[[:space:]]*bound_if[[:space:]]*=' "$CLIENT_TOML"; then
    sed -i "s|^#[[:space:]]*bound_if[[:space:]]*=.*|bound_if = \"${wan_dev}\"|" "$CLIENT_TOML"
  elif grep -q '\[listener\.tun\]' "$CLIENT_TOML"; then
    tmp="${CLIENT_TOML}.tmp.$$"
    awk -v bif="$wan_dev" '
      { print }
      $0 ~ /^\[listener\.tun\]/ { print "bound_if = \"" bif "\"" }
    ' "$CLIENT_TOML" >"$tmp"
    mv "$tmp" "$CLIENT_TOML"
  else
    printf '\n[listener.tun]\nbound_if = "%s"\n' "$wan_dev" >>"$CLIENT_TOML"
  fi
  grep -qE '^bound_if[[:space:]]*=' "$CLIENT_TOML" \
    || die "failed to set bound_if in ${CLIENT_TOML}"

  if grep -qE '^change_system_dns[[:space:]]*=' "$CLIENT_TOML"; then
    sed -i 's/^change_system_dns[[:space:]]*=.*/change_system_dns = false/' "$CLIENT_TOML"
  fi

  chmod 600 "$CLIENT_TOML"
  log "client.toml ← $src (exclusions=[], bound_if=${wan_dev})"
}

# --- writers ---
write_init() {
  cat >"$INIT" <<'EOF'
#!/bin/sh /etc/rc.common
START=95
STOP=10
USE_PROCD=1

start_service() {
	/etc/init.d/tt-client-guard check >/dev/null 2>&1 \
		|| {
			/etc/init.d/tt-client-guard start || return 1
			/etc/init.d/tt-client-guard check >/dev/null 2>&1 || return 1
		}
	procd_open_instance
	procd_set_param command /usr/bin/tt-client -c /etc/moreprivate/tt-client/client.toml
	procd_set_param respawn 3600 5 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_set_param limits nofile="65536 65536"
	procd_close_instance
}
EOF
  [ "$?" -eq 0 ] || return 1
  chmod 755 "$INIT" || return 1
}

write_guard_init() {
  cat >"$GUARD_INIT" <<EOF
#!/bin/sh /etc/rc.common
START=18
STOP=99
EXTRA_COMMANDS="check"
EXTRA_HELP="	check	Verify the complete fail-closed policy"

POLICY="${TT_DIR}/policy.nft"
FAILSAFE="${TT_DIR}/failsafe.nft"
WAN_DEV_FILE="${TT_DIR}/wan.dev"
FAILED="${TT_DIR}/policy.failed"
MARK="${MARK}"
MARK_PRIO="${MARK_PRIO}"

add_saved_wan() {
	wan_dev="\$(cat "\$WAN_DEV_FILE" 2>/dev/null)"
	case "\$wan_dev" in
		''|*[!A-Za-z0-9_.:-]*) return 1 ;;
	esac
	nft get element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }" \
		>/dev/null 2>&1 \
		|| nft add element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }"
}

add_live_default_wans() {
	for wan_dev in \$(ip -4 route show default 2>/dev/null \
		| sed -n 's/.* dev \([^ ]*\).*/\1/p'); do
		case "\$wan_dev" in
			''|*[!A-Za-z0-9_.:-]*) return 1 ;;
		esac
		nft get element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }" \
			>/dev/null 2>&1 \
			|| nft add element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }" \
			|| return 1
	done
}

install_mark_rule() {
	while ip rule del priority "\$MARK_PRIO" 2>/dev/null; do :; done
	ip rule add priority "\$MARK_PRIO" fwmark "\$MARK/0xffffffff" lookup main
}

disable_unguarded_wans() {
	{
		cat "\$WAN_DEV_FILE" 2>/dev/null || true
		ip -4 route show default 2>/dev/null \
			| sed -n 's/.* dev \([^ ]*\).*/\1/p'
	} | sort -u | while read -r wan_dev; do
		case "\$wan_dev" in
			''|*[!A-Za-z0-9_.:-]*) continue ;;
		esac
		logger -p daemon.crit -t moreprivate-tt-client-guard \
			"disabling unguarded WAN device \$wan_dev"
		ip link set "\$wan_dev" down 2>/dev/null || true
	done
}

populate_policy() {
	add_saved_wan \
		&& add_live_default_wans \
		&& install_mark_rule
}

load_policy() {
	if nft -f "\$POLICY" && populate_policy; then
		rm -f "\$FAILED" || {
			logger -p daemon.crit -t moreprivate-tt-client-guard \
				"cannot clear emergency-policy marker"
			disable_unguarded_wans
			return 1
		}
		return 0
	fi
	logger -p daemon.crit -t moreprivate-tt-client-guard \
		"full policy failed; loading endpoint-only emergency kill switch"
	touch "\$FAILED" || {
		logger -p daemon.crit -t moreprivate-tt-client-guard \
			"cannot record emergency-policy state; disabling WAN devices"
		disable_unguarded_wans
		return 1
	}
	if nft -f "\$FAILSAFE" && populate_policy; then
		return 0
	fi
	logger -p daemon.crit -t moreprivate-tt-client-guard \
		"emergency kill switch incomplete; disabling WAN devices"
	disable_unguarded_wans
	return 1
}

check() {
	[ ! -e "\$FAILED" ] || return 1
	nft list set inet moreprivate_tt_client tt_wan_devices >/dev/null 2>&1 || return 1
	nft get element inet moreprivate_tt_client tt_policy_mode "{ 0x1 }" \
		>/dev/null 2>&1 || return 1
	nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 || return 1
	nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1 || return 1
	nft list chain inet moreprivate_tt_client moreprivate_tt_client_output_mark >/dev/null 2>&1 \
		|| return 1
	nft list chain inet moreprivate_tt_client moreprivate_tt_client_output_guard 2>/dev/null \
		| grep -q reject || return 1
	nft list chain inet moreprivate_tt_client moreprivate_tt_client_forward_guard 2>/dev/null \
		| grep -q reject || return 1
	wan_dev="\$(cat "\$WAN_DEV_FILE" 2>/dev/null)"
	case "\$wan_dev" in
		''|*[!A-Za-z0-9_.:-]*) return 1 ;;
	esac
	nft get element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }" \
		>/dev/null 2>&1 || return 1
	for wan_dev in \$(ip -4 route show default 2>/dev/null \
		| sed -n 's/.* dev \([^ ]*\).*/\1/p'); do
		nft get element inet moreprivate_tt_client tt_wan_devices "{ \"\$wan_dev\" }" \
			>/dev/null 2>&1 || return 1
	done
	ip rule show | grep -q "\$MARK_PRIO:.*\$MARK" || return 1
}

start() {
	load_policy || {
		logger -p daemon.crit -t moreprivate-tt-client-guard \
			"policy startup failed"
		return 1
	}
}

reload() {
	load_policy
}

# Never remove the kill switch during ordinary shutdown or service control.
# The management script removes it explicitly only during purge.
stop() {
	return 0
}
EOF
  [ "$?" -eq 0 ] || return 1
  chmod 755 "$GUARD_INIT" || return 1
}

write_hotplug() {
  local vps_ip="$1" wan_dev="$2"
  is_ipv4 "$vps_ip" || return 1
  [ -n "$wan_dev" ] || return 1
  mkdir -p /etc/hotplug.d/iface || return 1
  cat >"$HOTPLUG" <<EOF
#!/bin/sh
# Endpoint TCP port is marked to main/WAN; every other endpoint flow uses tun0.
[ "\$ACTION" = ifup ] || [ "\$ACTION" = ifupdate ] || exit 0
is_wan=0
event_dev="\${DEVICE:-}"
if [ "\$INTERFACE" = moreprivate_tt_client ]; then
  :
else
  [ -n "\$event_dev" ] || event_dev="\$(
    ip -4 route show default 2>/dev/null \
      | sed -n 's/.* dev \\([^ ]*\\).*/\\1/p' | head -1
  )"
  if [ -n "\$event_dev" ] \
    && ip -4 route show default dev "\$event_dev" 2>/dev/null | grep -q .; then
    is_wan=1
  else
    exit 0
  fi
fi
if ! nft list chain inet moreprivate_tt_client moreprivate_tt_client_output_guard >/dev/null 2>&1 \
  || ! nft list chain inet moreprivate_tt_client moreprivate_tt_client_forward_guard >/dev/null 2>&1; then
  /etc/init.d/tt-client-guard start || {
    logger -p daemon.crit -t moreprivate-tt-client-guard \
      "policy unavailable on \${INTERFACE}; disabling \${event_dev:-${wan_dev}}"
    ip link set "\${event_dev:-${wan_dev}}" down 2>/dev/null || true
    exit 1
  }
fi
if [ "\$is_wan" = "1" ]; then
  case "\$event_dev" in
    *[!A-Za-z0-9_.:-]*)
      logger -p daemon.crit -t moreprivate-tt-client-guard "invalid WAN device name"
      exit 1
      ;;
  esac
  nft get element inet moreprivate_tt_client tt_wan_devices "{ \"\$event_dev\" }" \
    >/dev/null 2>&1 \
    || nft add element inet moreprivate_tt_client tt_wan_devices "{ \"\$event_dev\" }" || {
      logger -p daemon.crit -t moreprivate-tt-client-guard "cannot guard WAN device \$event_dev"
      ip link set "\$event_dev" down 2>/dev/null || true
      exit 1
    }
fi
while ip rule del priority ${MARK_PRIO} 2>/dev/null; do :; done
ip rule add priority ${MARK_PRIO} fwmark ${MARK}/0xffffffff lookup main || {
  logger -p daemon.crit -t moreprivate-tt-client-guard "cannot install endpoint/direct mark rule"
  exit 1
}
if ip link show tun0 >/dev/null 2>&1; then
  ip route replace table ${TUN_TABLE} ${vps_ip}/32 dev tun0 || {
    logger -p daemon.crit -t moreprivate-tt-client-guard "cannot install VPS tunnel route"
    exit 1
  }
fi
ip route flush cache 2>/dev/null || true
EOF
  [ "$?" -eq 0 ] || return 1
  chmod 755 "$HOTPLUG" || return 1
}

write_empty_set_elements() {
  printf '%s\n' '# intentionally empty set' >"$1"
}

direct_zone_to_elements() {
  local zone="$1" out="$2"
  if ! grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$zone" 2>/dev/null; then
    write_empty_set_elements "$out"
    return
  fi
  {
    echo "elements = {"
    grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$' "$zone" 2>/dev/null | sed 's/$/,/' || true
    echo "}"
  } >"$out"
}

direct_dns_to_elements() {
  local out="$1" ip values=""
  for ip in ${DIRECT_DNS_SERVERS:-}; do
    is_ipv4 "$ip" || return 1
    values="${values} ${ip}"
  done
  values="$(normalize_list "$values")"
  if [ -z "$values" ]; then
    write_empty_set_elements "$out"
    return
  fi
  {
    echo "elements = {"
    for ip in $values; do
      echo "${ip},"
    done
    echo "}"
  } >"$out"
}

replace_live_direct_dns_set() {
  local values ip
  values="$(normalize_list "$1")"
  nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1 || return 1
  nft flush set inet moreprivate_tt_client tt_direct_dns4 || return 1
  for ip in $values; do
    is_ipv4 "$ip" || return 1
    nft add element inet moreprivate_tt_client tt_direct_dns4 "{ $ip }" || return 1
  done
}

# $1=vps_ip  $2=endpoint_port  $3=wan_dev
write_pbr_nft() {
  local vps_ip="$1" endpoint_port="$2" wan_dev="$3" tmp="${PBR_NFT}.candidate.$$"
  # Soft-fail: transactional callers need return 1, not process exit.
  [ -n "$vps_ip" ] || return 1
  [ -n "$endpoint_port" ] || return 1
  [ -n "$wan_dev" ] || return 1
  [ -f "$DIRECT_EL" ] || write_empty_set_elements "$DIRECT_EL" || return 1
  [ -f "$DIRECT_DNS_EL" ] || write_empty_set_elements "$DIRECT_DNS_EL" || return 1
  cat >"$tmp" <<EOF
# MorePrivate tt-client PBR — managed by tt-client-openwrt.sh
# Independent from firewall4: loaded by ${GUARD_INIT} before network startup.
# Router endpoint TCP/UDP + direct-country traffic + selected WAN DNS → WAN.
# VPS precedence: only router TCP/UDP to the endpoint port is direct; every other
# router/forwarded flow to the VPS stays tunneled even when its IP is direct-country.
# endpoint_ip=${vps_ip}
# endpoint_port=${endpoint_port}
# wan_dev=${wan_dev}

destroy table inet moreprivate_tt_client
table inet moreprivate_tt_client {
set tt_wan_devices {
    type ifname
    elements = { "${wan_dev}" }
}

set tt_policy_mode {
    type mark
    elements = { 0x1 }
}

set tt_direct4 {
    type ipv4_addr
    flags interval
    include "${DIRECT_EL}"
}

set tt_direct_dns4 {
    type ipv4_addr
    include "${DIRECT_DNS_EL}"
}

chain moreprivate_tt_client_prerouting {
    type filter hook prerouting priority mangle; policy accept;
    ip daddr ${vps_ip} return
    meta l4proto { tcp, udp, icmp } ip daddr @tt_direct4 meta mark set ${MARK}
}

chain moreprivate_tt_client_output_mark {
    type route hook output priority mangle; policy accept;
    ip protocol tcp ip daddr ${vps_ip} tcp dport ${endpoint_port} meta mark set ${MARK}
    ip protocol udp ip daddr ${vps_ip} udp dport ${endpoint_port} meta mark set ${MARK}
    ip daddr ${vps_ip} return
    ip protocol tcp tcp dport 53 ip daddr @tt_direct_dns4 meta mark set ${MARK}
    ip protocol udp udp dport 53 ip daddr @tt_direct_dns4 meta mark set ${MARK}
    meta l4proto { tcp, udp, icmp } ip daddr @tt_direct4 meta mark set ${MARK}
}

chain moreprivate_tt_client_forward_guard {
    type filter hook forward priority filter - 1; policy accept;
    oifname @tt_wan_devices ip daddr ${vps_ip} counter reject
    oifname @tt_wan_devices meta l4proto { tcp, udp, icmp } ip daddr @tt_direct4 accept
    oifname @tt_wan_devices counter reject
}

chain moreprivate_tt_client_output_guard {
    type filter hook output priority filter - 1; policy accept;
    oifname @tt_wan_devices ip protocol tcp ip daddr ${vps_ip} tcp dport ${endpoint_port} accept
    oifname @tt_wan_devices ip protocol udp ip daddr ${vps_ip} udp dport ${endpoint_port} accept
    oifname @tt_wan_devices ip daddr ${vps_ip} counter reject
    oifname @tt_wan_devices udp sport 68 udp dport 67 accept
    oifname @tt_wan_devices ip protocol tcp tcp dport 53 ip daddr @tt_direct_dns4 accept
    oifname @tt_wan_devices ip protocol udp udp dport 53 ip daddr @tt_direct_dns4 accept
    oifname @tt_wan_devices meta l4proto { tcp, udp, icmp } ip daddr @tt_direct4 accept
    oifname @tt_wan_devices counter reject
}
}
EOF
  [ "$?" -eq 0 ] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  nft -c -f "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$PBR_NFT" || { rm -f "$tmp"; return 1; }
}

write_failsafe_nft() {
  local vps_ip="$1" endpoint_port="$2" wan_dev="$3" \
    tmp="${FAILSAFE_NFT}.candidate.$$"
  is_ipv4 "$vps_ip" || return 1
  [ -n "$endpoint_port" ] || return 1
  [ -n "$wan_dev" ] || return 1
  cat >"$tmp" <<EOF
# Endpoint-only emergency kill switch — managed by tt-client-openwrt.sh
destroy table inet moreprivate_tt_client
table inet moreprivate_tt_client {
set tt_wan_devices {
    type ifname
    elements = { "${wan_dev}" }
}

set tt_policy_mode {
    type mark
    elements = { 0x0 }
}

set tt_direct4 {
    type ipv4_addr
    flags interval
}

set tt_direct_dns4 {
    type ipv4_addr
}

chain moreprivate_tt_client_prerouting {
    type filter hook prerouting priority mangle; policy accept;
}

chain moreprivate_tt_client_output_mark {
    type route hook output priority mangle; policy accept;
    ip protocol tcp ip daddr ${vps_ip} tcp dport ${endpoint_port} meta mark set ${MARK}
    ip protocol udp ip daddr ${vps_ip} udp dport ${endpoint_port} meta mark set ${MARK}
}

chain moreprivate_tt_client_forward_guard {
    type filter hook forward priority filter - 1; policy accept;
    oifname @tt_wan_devices counter reject
}

chain moreprivate_tt_client_output_guard {
    type filter hook output priority filter - 1; policy accept;
    oifname @tt_wan_devices ip protocol tcp ip daddr ${vps_ip} tcp dport ${endpoint_port} accept
    oifname @tt_wan_devices ip protocol udp ip daddr ${vps_ip} udp dport ${endpoint_port} accept
    oifname @tt_wan_devices udp sport 68 udp dport 67 accept
    oifname @tt_wan_devices counter reject
}
}
EOF
  [ "$?" -eq 0 ] || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" || { rm -f "$tmp"; return 1; }
  nft -c -f "$tmp" || {
    rm -f "$tmp"
    return 1
  }
  mv "$tmp" "$FAILSAFE_NFT" || { rm -f "$tmp"; return 1; }
}

install_vps_tunnel_route() {
  local vps_ip="$1"
  is_ipv4 "$vps_ip" || return 1
  # While the client is stopped there is no tun0.  The hotplug handler installs
  # this route when the tunnel comes back.
  ip link show tun0 >/dev/null 2>&1 || return 0
  ip route replace table "$TUN_TABLE" "${vps_ip}/32" dev tun0 || return 1
  ip route flush cache 2>/dev/null || true
}

remove_vps_tunnel_route() {
  local vps_ip="$1"
  is_ipv4 "$vps_ip" || return 0
  ip route del table "$TUN_TABLE" "${vps_ip}/32" dev tun0 2>/dev/null || true
  ip route flush cache 2>/dev/null || true
}

reload_fw() {
  # Never reload network while MorePrivate tt-client is running: netifd removes the
  # client-owned tun routes. Network UCI is reloaded once before client start.
  # Soft-fail so callers in transaction paths can roll back (do not die here).
  /etc/init.d/firewall restart || return 1
}

firewall_lan_tunnel_jump_ready() {
  nft list chain inet fw4 forward_lan 2>/dev/null \
    | grep -q 'jump accept_to_moreprivate_tt_client'
}

firewall_tunnel_accept_ready() {
  nft list chain inet fw4 accept_to_moreprivate_tt_client 2>/dev/null \
    | grep -q 'oifname "tun0".*accept'
}

firewall_lan_tunnel_ready() {
  firewall_lan_tunnel_jump_ready \
    && firewall_tunnel_accept_ready
}

# Single path: write PBR + mark + firewall reload
apply_pbr() {
  local vps_ip="$1" wan_dev="$2" endpoint_port old_vps=""
  old_vps="$(parse_pbr_vps_ip 2>/dev/null || true)"
  endpoint_port="$(parse_vps_port "$CLIENT_TOML")" \
    || die "cannot parse endpoint port from client.toml"
  save_wan_dev "$wan_dev" || return 1
  [ -f "$DIRECT_EL" ] || write_empty_set_elements "$DIRECT_EL" || return 1
  [ -f "$DIRECT_DNS_EL" ] || write_empty_set_elements "$DIRECT_DNS_EL" || return 1
  write_pbr_nft "$vps_ip" "$endpoint_port" "$wan_dev" || return 1
  write_failsafe_nft "$vps_ip" "$endpoint_port" "$wan_dev" || return 1
  write_guard_init || return 1
  write_hotplug "$vps_ip" "$wan_dev" || return 1
  "$GUARD_INIT" enable >/dev/null 2>&1 || return 1
  # Use the same guarded loader as boot. If full activation or WAN-set
  # population fails, it installs the endpoint-only failsafe; if that cannot
  # cover every live WAN, it disables those devices.
  "$GUARD_INIT" start || return 1
  "$GUARD_INIT" check >/dev/null 2>&1 || return 1
  reload_fw || return 1
  install_vps_tunnel_route "$vps_ip" || return 1
  if [ -n "$old_vps" ] && [ "$old_vps" != "$vps_ip" ]; then
    remove_vps_tunnel_route "$old_vps"
  fi
  guard_policy_ready "$wan_dev" || return 1
}

# --- zones / system ---
install_zones() {
  local s has_lan_wan=0
  bak /etc/config/network
  bak /etc/config/firewall

  uci set network.moreprivate_tt_client='interface' || return 1
  uci set network.moreprivate_tt_client.proto='none' || return 1
  uci set network.moreprivate_tt_client.device='tun0' || return 1
  uci commit network || return 1

  uci set firewall.moreprivate_tt_client='zone' || return 1
  uci set firewall.moreprivate_tt_client.name='moreprivate_tt_client' || return 1
  uci add_list firewall.moreprivate_tt_client.network='moreprivate_tt_client' || return 1
  uci set firewall.moreprivate_tt_client.input='REJECT' || return 1
  uci set firewall.moreprivate_tt_client.output='ACCEPT' || return 1
  uci set firewall.moreprivate_tt_client.forward='REJECT' || return 1
  uci set firewall.moreprivate_tt_client.mtu_fix='1' || return 1

  # The tunnel zone remains closed to unsolicited router input.  Permit only
  # echo replies needed by router-originated ICMP requests sent through TT.
  # This is explicit because not every firewall/kernel combination classifies
  # the userspace-synthesized reply as conntrack ESTABLISHED.
  uci -q delete firewall.moreprivate_tt_client_icmp_reply 2>/dev/null || true
  uci set firewall.moreprivate_tt_client_icmp_reply='rule' || return 1
  uci set firewall.moreprivate_tt_client_icmp_reply.name='Allow-MorePrivate tt-client-ICMP-echo-reply' || return 1
  uci set firewall.moreprivate_tt_client_icmp_reply.src='moreprivate_tt_client' || return 1
  uci set firewall.moreprivate_tt_client_icmp_reply.family='ipv4' || return 1
  uci set firewall.moreprivate_tt_client_icmp_reply.proto='icmp' || return 1
  uci add_list firewall.moreprivate_tt_client_icmp_reply.icmp_type='echo-reply' || return 1
  uci set firewall.moreprivate_tt_client_icmp_reply.target='ACCEPT' || return 1

  uci set firewall.lan_moreprivate_tt_client='forwarding' || return 1
  uci set firewall.lan_moreprivate_tt_client.src='lan' || return 1
  uci set firewall.lan_moreprivate_tt_client.dest='moreprivate_tt_client' || return 1

  # Preserve every shared forwarding. The independent nft guard constrains any
  # existing path to WAN, so only create an owned LAN→WAN path when none exists.
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get "$s.src" 2>/dev/null)" = "lan" ] || continue
    [ "$(uci -q get "$s.dest" 2>/dev/null)" = "wan" ] || continue
    has_lan_wan=1
    break
  done
  if [ "$has_lan_wan" = 0 ]; then
    uci set firewall.moreprivate_tt_client_lan_wan='forwarding' || return 1
    uci set firewall.moreprivate_tt_client_lan_wan.src='lan' || return 1
    uci set firewall.moreprivate_tt_client_lan_wan.dest='wan' || return 1
  fi
  uci commit firewall || return 1
}

disable_ipv6() {
  bak /etc/config/network
  bak /etc/config/dhcp
  mkdir -p /etc/sysctl.d
  cat >/etc/sysctl.d/99-moreprivate_tt_client-ipv6.conf <<'EOF'
net.ipv6.conf.all.disable_ipv6=1
net.ipv6.conf.default.disable_ipv6=1
EOF
  sysctl -p /etc/sysctl.d/99-moreprivate_tt_client-ipv6.conf 2>/dev/null || true
  uci -q get network.wan6 >/dev/null 2>&1 && uci set network.wan6.disabled='1'
  for s in $(uci -q show network 2>/dev/null | sed -n "s/^\(network\.[^=]*\)=interface$/\1/p"); do
    [ "$(uci -q get "$s.proto" 2>/dev/null)" = "dhcpv6" ] && uci set "$s.disabled"='1'
  done
  uci commit network
  if uci -q get dhcp.lan >/dev/null 2>&1; then
    uci -q set dhcp.lan.dhcpv6='disabled' || true
    uci -q set dhcp.lan.ra='disabled' || true
    uci -q set dhcp.lan.ndp='disabled' || true
    uci commit dhcp
  fi
}

write_tt_dns() {
  cat >"$TT_DNS" <<'EOF'
#!/bin/sh
# Static dnsmasq split. Config: /etc/moreprivate/tt-client/dns.env
set -e
CONF="${TT_DNS_ENV:-/etc/moreprivate/tt-client/dns.env}"
normalize_list() {
  echo "$1" | tr ',\t' '  ' | tr -s ' ' | sed 's/^ //;s/ $//'
}
conf_get() {
  local key="$1"
  sed -n "s/^${key}=//p" "$CONF" | head -1 | sed 's/^"//;s/"$//'
}
load_conf() {
  [ -f "$CONF" ] || { echo "tt-dns: missing $CONF" >&2; return 1; }
  TUNNEL_DNS_SERVERS="$(conf_get TUNNEL_DNS_SERVERS)"
  DIRECT_DNS_SERVERS="$(conf_get DIRECT_DNS_SERVERS)"
  DIRECT_DNS_DOMAINS="$(conf_get DIRECT_DNS_DOMAINS)"
  TUNNEL_DNS_SERVERS="$(normalize_list "$TUNNEL_DNS_SERVERS")"
  [ -n "$TUNNEL_DNS_SERVERS" ] \
    || { echo "tt-dns: tunnel DNS servers are empty" >&2; return 1; }
  DIRECT_DNS_SERVERS="$(normalize_list "$DIRECT_DNS_SERVERS")"
  DIRECT_DNS_DOMAINS="$(normalize_list "$DIRECT_DNS_DOMAINS")"
}
clear_servers() {
  while uci -q delete dhcp.@dnsmasq[0].server 2>/dev/null; do :; done
}
ensure_rebind() {
  uci set dhcp.@dnsmasq[0].rebind_protection='1'
  for d in msftncsi.com www.msftconnecttest.com ipv6.msftconnecttest.com; do
    found=0
    for existing in $(uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null); do
      [ "$existing" = "$d" ] && found=1 && break
    done
    [ "$found" = 1 ] || uci add_list dhcp.@dnsmasq[0].rebind_domain="$d"
  done
}
apply() {
  load_conf
  if ! uci -q get dhcp.@dnsmasq[0] >/dev/null 2>&1; then
    uci add dhcp dnsmasq >/dev/null
  fi
  uci set dhcp.@dnsmasq[0].noresolv='1'
  uci -q delete dhcp.@dnsmasq[0].strictorder 2>/dev/null || true
  uci set dhcp.@dnsmasq[0].strictorder='1'
  ensure_rebind
  clear_servers
  if [ -n "$DIRECT_DNS_DOMAINS" ] && [ -n "$DIRECT_DNS_SERVERS" ]; then
    for dom in $DIRECT_DNS_DOMAINS; do
      dom="${dom#.}"
      [ -n "$dom" ] || continue
      for srv in $DIRECT_DNS_SERVERS; do
        [ -n "$srv" ] || continue
        uci add_list dhcp.@dnsmasq[0].server="/${dom}/${srv}"
      done
    done
  fi
  for srv in $TUNNEL_DNS_SERVERS; do
    [ -n "$srv" ] || continue
    uci add_list dhcp.@dnsmasq[0].server="$srv"
  done
  uci commit dhcp
  if ! /etc/init.d/dnsmasq reload; then
    /etc/init.d/dnsmasq restart || {
      echo "tt-dns: dnsmasq reload and restart failed" >&2
      return 1
    }
  fi
  echo "tt-dns: applied tunnel=[${TUNNEL_DNS_SERVERS}] direct=[${DIRECT_DNS_SERVERS}] domains=[${DIRECT_DNS_DOMAINS}]"
}
case "${1:-apply}" in
  apply|"") apply ;;
  status)
    load_conf || true
    echo "TUNNEL_DNS_SERVERS=${TUNNEL_DNS_SERVERS:-}"
    echo "DIRECT_DNS_SERVERS=${DIRECT_DNS_SERVERS:-}"
    echo "DIRECT_DNS_DOMAINS=${DIRECT_DNS_DOMAINS:-}"
    uci -q show dhcp.@dnsmasq[0].server 2>/dev/null || true
    ;;
  *) echo "usage: $0 [apply|status]" >&2; exit 1 ;;
esac
EOF
  [ "$?" -eq 0 ] || return 1
  chmod 755 "$TT_DNS" || return 1
}

# DNS via apply_direct_dns (direct on/off). force unused kept for call sites.
install_dns() {
  bak /etc/config/dhcp
  load_direct_conf
  apply_direct_dns
}

# --- binary / service ---
# procd stop sometimes prints this when the service instance is already gone
# (ubus NOT_FOUND). Harmless if the process actually exits — do not scare users.
PROCD_UBUS_NOT_FOUND_MSG='Command failed: Not found'

# Run /etc/init.d/moreprivate_tt_client <cmd>; drop known procd/ubus noise; keep real errors.
# stdout/stderr of the init script are filtered; return code is preserved.
service_init_cmd() {
  local cmd="$1" out rc=0
  [ -x "$INIT" ] || {
    echo "error: init script missing: $INIT" >&2
    return 1
  }
  out="$("$INIT" "$cmd" 2>&1)" || rc=$?
  if [ -n "$out" ]; then
    # Drop exact procd/ubus noise; keep any other init messages.
    printf '%s\n' "$out" | grep -vxF "$PROCD_UBUS_NOT_FOUND_MSG" | while IFS= read -r line || [ -n "$line" ]; do
      [ -n "$line" ] && echo "$line" >&2
    done
  fi
  return "$rc"
}

# Stop procd service and ensure no stray process remains (same end state as a
# successful /etc/init.d/moreprivate_tt_client stop). Success = process gone, not init rc.
service_stop() {
  local i=0
  if [ ! -x "$INIT" ]; then
    client_running || return 0
    echo "error: cannot stop running client: init script missing: $INIT" >&2
    return 1
  fi
  # Filter procd's intermittent "Command failed: Not found" (ubus instance already gone).
  service_init_cmd stop || true
  i=0
  while client_running && [ "$i" -lt 15 ]; do
    i=$((i + 1))
    sleep 1
  done
  if client_running; then
    log "client still running after stop — sending TERM"
    pids="$(pidof tt-client 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      # shellcheck disable=SC2086
      kill -TERM $pids 2>/dev/null || true
    fi
    sleep 2
  fi
  if client_running; then
    log "client still running after TERM — sending KILL"
    pids="$(pidof tt-client 2>/dev/null || true)"
    if [ -n "$pids" ]; then
      # shellcheck disable=SC2086
      kill -KILL $pids 2>/dev/null || true
    fi
    sleep 1
  fi
  if client_running; then
    echo "error: tt-client did not stop" >&2
    return 1
  fi
  return 0
}

service_start() {
  [ -x "$INIT" ] || {
    echo "error: init script missing: $INIT" >&2
    return 1
  }
  "$INIT" enable >/dev/null 2>&1 || return 1
  # Same filter as stop (rare on start, but keep restart output calm).
  if ! service_init_cmd start; then
    client_running || {
      echo "error: $INIT start failed" >&2
      return 1
    }
  fi
  # Wait until process is up (procd start can return before instance is ready).
  local i=0
  while ! client_running && [ "$i" -lt 15 ]; do
    i=$((i + 1))
    sleep 1
  done
  client_running || {
    echo "error: tt-client did not start" >&2
    return 1
  }
  return 0
}

service_restart() {
  service_stop || return 1
  service_start
}

# Stop+start without changing enablement (no re-enable).
service_restart_preserve_enablement() {
  [ -x "$INIT" ] || {
    echo "error: init script missing: $INIT" >&2
    return 1
  }
  service_stop || return 1
  if ! service_init_cmd start; then
    client_running || {
      echo "error: $INIT start failed" >&2
      return 1
    }
  fi
  local i=0
  while ! client_running && [ "$i" -lt 15 ]; do
    i=$((i + 1))
    sleep 1
  done
  if ! client_running; then
    echo "error: tt-client did not start after restart" >&2
    return 1
  fi
  return 0
}

# After process start: wait for CONNECTED + tun0 before live probes (avoids
# false FAIL while H3 is still handshaking).
service_wait_tunnel_ready() {
  local i=0 max="${1:-30}"
  while [ "$i" -lt "$max" ]; do
    i=$((i + 1))
    if client_running \
      && ip link show dev tun0 >/dev/null 2>&1 \
      && logread 2>/dev/null | tail -n 40 | grep -q 'VPN_SS_CONNECTED'; then
      return 0
    fi
    # CONNECTED line may have scrolled off; accept tun0 + process after a few secs
    if [ "$i" -ge 8 ] && client_running && ip link show dev tun0 >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  client_running && ip link show dev tun0 >/dev/null 2>&1
}

binary_resolve_link() {
  local target
  [ -L "$BIN" ] || return 1
  target="$(readlink "$BIN")"
  case "$target" in
    /*) ;;
    *) target="$(dirname "$BIN")/$target" ;;
  esac
  case "$target" in
    /usr/bin/tt-client-*-linux-*) ;;
    *) return 1 ;;
  esac
  [ -x "$target" ] || return 1
  echo "$target"
}

binary_switch_link() {
  local target="$1" tmp="${BIN}.link.$$"
  rm -f "$tmp"
  ln -s "$(basename "$target")" "$tmp"
  mv -f "$tmp" "$BIN"
}

binary_previous() {
  local current="$1" f found=""
  for f in /usr/bin/tt-client-*-linux-*; do
    [ -f "$f" ] && [ -x "$f" ] && [ "$f" != "$current" ] || continue
    [ -z "$found" ] || die "multiple rollback binaries found; run upgrade to prune them"
    found="$f"
  done
  [ -n "$found" ] || return 1
  echo "$found"
}

binary_tx_begin() {
  _BIN_TX_ACTIVE=1
  _BIN_TX_OLD=""
  _BIN_TX_NEW=""
  _BIN_TX_CREATED=0
  _BIN_TX_SERVICE_WAS_RUNNING=0
  if [ -e "$BIN" ] || [ -L "$BIN" ]; then
    [ -L "$BIN" ] \
      || die "binary path is not a managed symlink: $BIN (purge, then install cleanly)"
    _BIN_TX_OLD="$(binary_resolve_link)" \
      || die "binary symlink target missing or not executable: $BIN"
  fi
  # Do not prune here. A failed candidate must leave every pre-transaction
  # binary intact; successful commit is the only place that removes old files.
  if client_running; then
    _BIN_TX_SERVICE_WAS_RUNNING=1
  fi
  # The client may legitimately be absent, stopped, or disabled before an
  # install/upgrade. Record prior state without leaking the probe status.
  return 0
}

binary_tx_rollback() {
  [ "$_BIN_TX_ACTIVE" = 1 ] || return 0
  if [ -n "$_BIN_TX_OLD" ] && [ -x "$_BIN_TX_OLD" ]; then
    binary_switch_link "$_BIN_TX_OLD"
    echo "NOTICE: restored working binary $(basename "$_BIN_TX_OLD")" >&2
  else
    rm -f "$BIN"
  fi
  if [ "$_BIN_TX_CREATED" = 1 ] && [ -n "$_BIN_TX_NEW" ] \
    && [ "$_BIN_TX_NEW" != "$_BIN_TX_OLD" ]; then
    rm -f "$_BIN_TX_NEW"
  fi
  _BIN_TX_ACTIVE=0
  if [ "$_BIN_TX_SERVICE_WAS_RUNNING" = 1 ] && [ -n "$_BIN_TX_OLD" ] && [ -x "$INIT" ]; then
    service_restart_preserve_enablement >/dev/null 2>&1 \
      || echo "WARNING: old binary restored but service restart failed" >&2
  fi
}

binary_tx_commit() {
  local keep="$1" previous="${2:-}" f
  [ "$_BIN_TX_ACTIVE" = 1 ] || return 0
  for f in /usr/bin/tt-client-*-linux-*; do
    [ -e "$f" ] || continue
    [ "$f" = "$keep" ] || [ "$f" = "$previous" ] || rm -f "$f"
  done
  _BIN_TX_ACTIVE=0
  _BIN_TX_OLD=""
  _BIN_TX_NEW=""
  _BIN_TX_CREATED=0
}

binary_tx_on_exit() {
  local rc="$1"
  [ "$rc" = 0 ] || binary_tx_rollback
}

install_binary() {
  local src="$1" tag="$2" target src_sum target_sum
  need_file "$src"
  [ -s "$src" ] || die "binary empty: $src"
  service_stop
  echo "$tag" | grep -qE '^[A-Za-z0-9._-]+$' || die "invalid binary version: ${tag}"
  target="/usr/bin/$(basename "$src")"
  case "$(basename "$src")" in
    "tt-client-${tag}-linux-"*) ;;
    *) die "binary filename does not match its release tag: $(basename "$src")" ;;
  esac
  if [ -e "$target" ]; then
    [ -f "$target" ] && [ -x "$target" ] || die "invalid versioned binary: $target"
    src_sum="$(sha256sum "$src" | awk '{print $1}')"
    target_sum="$(sha256sum "$target" | awk '{print $1}')"
    [ "$src_sum" = "$target_sum" ] \
      || die "versioned binary collision with different content: $target"
  else
    cp "$src" "$target"
    chmod 755 "$target"
    _BIN_TX_CREATED=1
  fi
  # Wrong arch / corrupt binary → fail before rewriting firewall (fail-closed).
  "$target" --version >/dev/null 2>&1 \
    || die "binary not runnable (wrong arch or corrupt?): $target"
  _BIN_TX_NEW="$target"
  binary_switch_link "$target"
  "$target" --version 2>/dev/null | head -1 | sed 's/^/  /' || true
}

client_running() {
  [ -n "$(client_pids)" ]
}

# Count ESTAB sockets to VPS:port. $1=tcp|udp  $2=vps_ip  $3=port → stdout count
count_estab_to_endpoint() {
  local proto="$1" vps="$2" port="$3" flag
  command -v ss >/dev/null 2>&1 || return 1
  case "$proto" in
    tcp) flag="-tn" ;;
    udp) flag="-un" ;;
    *) return 1 ;;
  esac
  # shellcheck disable=SC2086
  ss $flag 2>/dev/null | awk -v needle="${vps}:${port}" '
    $1 ~ /ESTAB/ && index($0, needle) { c++ }
    END { print c+0 }
  '
}

# --- WAN CAKE / SQM (bufferbloat; independent of H2/H3) ---
is_positive_kbit() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    0) return 1 ;;
    *) return 0 ;;
  esac
}

wan_shape_save() {
  # $1=iface $2=download_kbit $3=upload_kbit
  cat >"$WAN_SHAPE_CONF" <<EOF
# Managed by tt-client-openwrt.sh tun-shape — CAKE on tunnel (tun0), rates in kbit/s
IFACE=$1
DOWNLOAD_KBIT=$2
UPLOAD_KBIT=$3
EOF
  chmod 0644 "$WAN_SHAPE_CONF" 2>/dev/null || true
}

wan_shape_load() {
  IFACE="" DOWNLOAD_KBIT="" UPLOAD_KBIT=""
  [ -f "$WAN_SHAPE_CONF" ] || return 1
  # shellcheck disable=SC1090
  . "$WAN_SHAPE_CONF"
  [ -n "$IFACE" ] && is_positive_kbit "$DOWNLOAD_KBIT" && is_positive_kbit "$UPLOAD_KBIT"
}

need_sqm_pkgs() {
  local miss=""
  [ -x /etc/init.d/sqm ] || miss="$miss sqm-scripts"
  command -v tc >/dev/null 2>&1 || miss="$miss ip-full"
  if command -v modprobe >/dev/null 2>&1; then
    modprobe sch_cake 2>/dev/null || true
    modprobe ifb 2>/dev/null || true
  fi
  # piece_of_cake needs sch_cake + ifb; install only if not loadable yet
  if ! lsmod 2>/dev/null | grep -qE '^sch_cake|^cake'; then
    miss="$miss kmod-sched-cake"
  fi
  if ! lsmod 2>/dev/null | grep -qE '^ifb'; then
    miss="$miss kmod-ifb"
  fi
  miss="$(unique_list "$miss")"
  if [ -n "$miss" ]; then
    command -v apk >/dev/null 2>&1 || die "need packages: ${miss}; apk unavailable"
    log "apk update (for SQM/CAKE)"
    apk update || die "apk update failed"
    log "apk add ${miss}"
    apk add $miss || die "apk add failed: ${miss}"
    if command -v modprobe >/dev/null 2>&1; then
      modprobe sch_cake 2>/dev/null || true
      modprobe ifb 2>/dev/null || true
    fi
  fi
  [ -x /etc/init.d/sqm ] || die "sqm-scripts missing after install"
  command -v tc >/dev/null 2>&1 || die "tc missing after install"
}

# List UCI section names of type sqm.*.=queue (busybox-safe).
sqm_queue_sections() {
  uci -q show sqm 2>/dev/null | sed -n 's/^sqm\.\([^=]*\)=queue$/\1/p'
}

# Ensure only sqm.${SQM_UCI_SECTION} is enabled on iface (script-only ownership).
# Other queues on the same iface are disabled so LuCI/default sqm.wan cannot win.
sqm_claim_iface() {
  local iface="$1" sec ifc en disabled=""
  for sec in $(sqm_queue_sections); do
    [ "$sec" = "$SQM_UCI_SECTION" ] && continue
    ifc="$(uci -q get "sqm.${sec}.interface" 2>/dev/null || true)"
    [ "$ifc" = "$iface" ] || continue
    en="$(uci -q get "sqm.${sec}.enabled" 2>/dev/null || true)"
    if [ "$en" != "0" ]; then
      uci set "sqm.${sec}.enabled=0"
      disabled="${disabled} ${sec}"
    fi
  done
  if [ -n "$disabled" ]; then
    log "disabled other sqm queue(s) on ${iface}:${disabled}"
  fi
}

# Fail if more than one enabled queue targets iface (reproducible sole owner).
sqm_assert_sole_enabled_on_iface() {
  local iface="$1" sec ifc en n=0 names=""
  for sec in $(sqm_queue_sections); do
    ifc="$(uci -q get "sqm.${sec}.interface" 2>/dev/null || true)"
    en="$(uci -q get "sqm.${sec}.enabled" 2>/dev/null || true)"
    [ "$ifc" = "$iface" ] || continue
    [ "$en" = "1" ] || continue
    n=$((n + 1))
    names="${names} ${sec}"
  done
  if [ "$n" -ne 1 ]; then
    die "sqm ownership broken on ${iface}: expected 1 enabled queue (sqm.${SQM_UCI_SECTION}), found ${n}:${names}"
  fi
  en="$(uci -q get "sqm.${SQM_UCI_SECTION}.enabled" 2>/dev/null || true)"
  [ "$en" = "1" ] || die "sqm.${SQM_UCI_SECTION} is not enabled after wan-shape"
}

# Parse CAKE bandwidth from "tc qdisc show" line → Mbit integer (e.g. 22 from 22Mbit).
sqm_cake_mbit_from_tc_line() {
  echo "$1" | sed -n 's/.*bandwidth \([0-9][0-9]*\)Mbit.*/\1/p' | head -1
}

# ifb device SQM uses for ingress (piece_of_cake: ifb4<iface>).
sqm_ifb_dev_for() {
  local iface="$1" d
  for d in "ifb4${iface}" "ifb-${iface}" "ifb0"; do
    ip link show dev "$d" >/dev/null 2>&1 && {
      echo "$d"
      return 0
    }
  done
  # Fallback: first ifb* with cake
  for d in $(ip -o link show 2>/dev/null | awk -F': ' '/ifb/{print $2}' | cut -d@ -f1); do
    tc qdisc show dev "$d" 2>/dev/null | grep -qi cake && {
      echo "$d"
      return 0
    }
  done
  return 1
}

# Verify live CAKE matches configured kbit (allow ±1 Mbit rounding). Returns 0 only if OK.
sqm_verify_live_rates() {
  local iface="$1" down_kbit="$2" up_kbit="$3"
  local want_down_m want_up_m live_up live_down ifb line
  want_down_m=$((down_kbit / 1000))
  want_up_m=$((up_kbit / 1000))
  [ "$want_down_m" -ge 1 ] || want_down_m=1
  [ "$want_up_m" -ge 1 ] || want_up_m=1

  line="$(tc qdisc show dev "$iface" 2>/dev/null | grep -i 'qdisc cake' | head -1 || true)"
  live_up="$(sqm_cake_mbit_from_tc_line "$line")"
  [ -n "$live_up" ] || {
    log "live verify failed: no cake on ${iface}"
    return 1
  }
  if [ "$live_up" -lt $((want_up_m - 1)) ] || [ "$live_up" -gt $((want_up_m + 1)) ]; then
    log "live verify failed: upload cake ${live_up}Mbit != ~${want_up_m}Mbit (${up_kbit}kbit) on ${iface}"
    return 1
  fi

  ifb="$(sqm_ifb_dev_for "$iface" 2>/dev/null || true)"
  [ -n "$ifb" ] || {
    log "live verify failed: no ifb ingress for ${iface}"
    return 1
  }
  line="$(tc qdisc show dev "$ifb" 2>/dev/null | grep -i 'qdisc cake' | head -1 || true)"
  live_down="$(sqm_cake_mbit_from_tc_line "$line")"
  [ -n "$live_down" ] || {
    log "live verify failed: no cake on ${ifb}"
    return 1
  }
  if [ "$live_down" -lt $((want_down_m - 1)) ] || [ "$live_down" -gt $((want_down_m + 1)) ]; then
    log "live verify failed: download cake ${live_down}Mbit != ~${want_down_m}Mbit (${down_kbit}kbit) on ${ifb}"
    return 1
  fi

  log "live CAKE matches: download~${want_down_m}Mbit upload~${want_up_m}Mbit on ${iface}"
  return 0
}

apply_wan_shape_uci() {
  local iface="$1" down="$2" up="$3"
  need_sqm_pkgs
  [ -d /etc/config ] || die "/etc/config missing"
  [ -f /etc/config/sqm ] || touch /etc/config/sqm

  # Stop first so we can reconfigure without fighting an already-bound qdisc.
  if [ -x /etc/init.d/sqm ]; then
    /etc/init.d/sqm stop 2>/dev/null || true
  fi

  # Script is sole owner of shaping on this iface (disable LuCI/default sqm.wan etc.).
  sqm_claim_iface "$iface"

  if ! uci -q get "sqm.${SQM_UCI_SECTION}" >/dev/null 2>&1; then
    uci set "sqm.${SQM_UCI_SECTION}=queue"
  fi
  uci set "sqm.${SQM_UCI_SECTION}.enabled=1"
  uci set "sqm.${SQM_UCI_SECTION}.interface=${iface}"
  uci set "sqm.${SQM_UCI_SECTION}.download=${down}"
  uci set "sqm.${SQM_UCI_SECTION}.upload=${up}"
  uci set "sqm.${SQM_UCI_SECTION}.qdisc=cake"
  uci set "sqm.${SQM_UCI_SECTION}.script=piece_of_cake.qos"
  uci set "sqm.${SQM_UCI_SECTION}.linklayer=none"
  uci set "sqm.${SQM_UCI_SECTION}.verbosity=5"
  uci set "sqm.${SQM_UCI_SECTION}.qdisc_advanced=0"
  uci commit sqm

  sqm_assert_sole_enabled_on_iface "$iface"

  /etc/init.d/sqm enable 2>/dev/null || true
  /etc/init.d/sqm start || die "sqm start failed — check iface ${iface} and rates"

  # Persist only after start so conf never claims rates that are not live.
  wan_shape_save "$iface" "$down" "$up"
  log "tunnel CAKE: iface=${iface} download=${down}kbit upload=${up}kbit (piece_of_cake, sqm.${SQM_UCI_SECTION})"

  sqm_verify_live_rates "$iface" "$down" "$up" \
    || die "tun-shape applied but live CAKE rates do not match — see uci show sqm / tc qdisc"
}

disable_wan_shape() {
  if uci -q get "sqm.${SQM_UCI_SECTION}" >/dev/null 2>&1; then
    uci set "sqm.${SQM_UCI_SECTION}.enabled=0" 2>/dev/null || true
    uci -q delete "sqm.${SQM_UCI_SECTION}" 2>/dev/null || true
    uci commit sqm 2>/dev/null || true
  fi
  if [ -x /etc/init.d/sqm ]; then
    /etc/init.d/sqm stop 2>/dev/null || true
    # Restart only if other sqm queues remain enabled
    if uci show sqm 2>/dev/null | grep -q "\.enabled='1'"; then
      /etc/init.d/sqm start 2>/dev/null || true
    fi
  fi
  rm -f "$WAN_SHAPE_CONF"
  log "tunnel CAKE disabled (TT sqm.${SQM_UCI_SECTION} removed)"
}

status_report_wan_shape() {
  local iface="" down="" up="" q="" en="" line live_up live_down ifb sec ifc oen others=""
  # Prefer live UCI TT section (script-owned) over conf file alone.
  en="$(uci -q get "sqm.${SQM_UCI_SECTION}.enabled" 2>/dev/null || true)"
  if [ "$en" = "1" ]; then
    iface="$(uci -q get "sqm.${SQM_UCI_SECTION}.interface" 2>/dev/null || true)"
    down="$(uci -q get "sqm.${SQM_UCI_SECTION}.download" 2>/dev/null || true)"
    up="$(uci -q get "sqm.${SQM_UCI_SECTION}.upload" 2>/dev/null || true)"
    _st_info "script-managed sqm.${SQM_UCI_SECTION}: iface=${iface:-?} download=${down:-?}kbit upload=${up:-?}kbit"
    # Heal conf drift so status/conf stay reproducible.
    if [ -n "$iface" ] && is_positive_kbit "$down" && is_positive_kbit "$up"; then
      if ! wan_shape_load 2>/dev/null \
        || [ "$IFACE" != "$iface" ] || [ "$DOWNLOAD_KBIT" != "$down" ] || [ "$UPLOAD_KBIT" != "$up" ]; then
        wan_shape_save "$iface" "$down" "$up"
      fi
    fi
  elif wan_shape_load; then
    iface="$IFACE"
    down="$DOWNLOAD_KBIT"
    up="$UPLOAD_KBIT"
    _st_warn "shape conf present but sqm.${SQM_UCI_SECTION} not enabled — re-run tun-shape or tun-shape-disable"
  else
    _st_info "not configured (optional: $0 tun-shape --download KBIT --upload KBIT on tun0)"
    return 0
  fi
  [ -n "$iface" ] || return 0

  # Legacy mistake: TT CAKE on ISP WAN caps the tunnel; flag it hard.
  case "$iface" in
    tun0|tun[0-9]*) ;;
    *)
      _st_fail "TT shape is on ${iface} (not tun0) — that caps ISP/WAN; run: $0 tun-shape-disable"
      return 0
      ;;
  esac

  for sec in $(sqm_queue_sections); do
    [ "$sec" = "$SQM_UCI_SECTION" ] && continue
    ifc="$(uci -q get "sqm.${sec}.interface" 2>/dev/null || true)"
    oen="$(uci -q get "sqm.${sec}.enabled" 2>/dev/null || true)"
    [ "$ifc" = "$iface" ] && [ "$oen" = "1" ] && others="${others} ${sec}"
  done
  if [ -n "$others" ]; then
    _st_fail "other enabled sqm on ${iface}:${others} — run: $0 tun-shape --download ${down} --upload ${up}"
  fi

  if command -v tc >/dev/null 2>&1; then
    q="$(tc qdisc show dev "$iface" 2>/dev/null | head -3 || true)"
    if echo "$q" | grep -qi cake; then
      line="$(echo "$q" | grep -i 'qdisc cake' | head -1)"
      live_up="$(sqm_cake_mbit_from_tc_line "$line")"
      _st_ok "live egress cake on ${iface}: ${live_up:-?}Mbit (want upload ~$((up / 1000))Mbit)"
      printf '%s\n' "$line" | sed 's/^/        /'
      ifb="$(sqm_ifb_dev_for "$iface" 2>/dev/null || true)"
      if [ -n "$ifb" ]; then
        line="$(tc qdisc show dev "$ifb" 2>/dev/null | grep -i 'qdisc cake' | head -1 || true)"
        live_down="$(sqm_cake_mbit_from_tc_line "$line")"
        if [ -n "$live_down" ]; then
          _st_ok "live ingress cake on ${ifb}: ${live_down}Mbit (want download ~$((down / 1000))Mbit)"
        else
          _st_fail "no cake on ingress ${ifb}"
        fi
      else
        _st_fail "no ifb ingress device for ${iface}"
      fi
      if [ -n "$live_up" ] && is_positive_kbit "$up"; then
        if [ "$live_up" -lt $((up / 1000 - 1)) ] || [ "$live_up" -gt $((up / 1000 + 1)) ]; then
          _st_fail "live upload ${live_up}Mbit != configured ${up}kbit — re-run tun-shape"
        fi
      fi
      if [ -n "$live_down" ] && is_positive_kbit "$down"; then
        if [ "$live_down" -lt $((down / 1000 - 1)) ] || [ "$live_down" -gt $((down / 1000 + 1)) ]; then
          _st_fail "live download ${live_down}Mbit != configured ${down}kbit — re-run tun-shape"
        fi
      fi
    elif [ -n "$q" ]; then
      _st_fail "live qdisc on ${iface} is not cake"
      printf '%s\n' "$q" | sed 's/^/        /'
    else
      _st_fail "no qdisc on ${iface} (sqm not active?) — re-run tun-shape"
    fi
  else
    _st_warn "tc missing; cannot show live qdisc"
  fi
}

# True if iface is the tunnel (only place TT may shape).
is_tunnel_shape_iface() {
  case "$1" in
    tun0|tun[0-9]*) return 0 ;;
    *) return 1 ;;
  esac
}

cmd_tun_shape() {
  local down="" up="" iface="tun0"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --download) down="${2:-}"; shift 2 ;;
      --upload) up="${2:-}"; shift 2 ;;
      --iface)
        iface="${2:-}"
        shift 2
        is_tunnel_shape_iface "$iface" \
          || die "tun-shape: only tunnel ifaces (tun0); never shape ISP WAN (got: ${iface})"
        ;;
      *) die "tun-shape: unknown option: $1 (want --download KBIT --upload KBIT)" ;;
    esac
  done
  is_positive_kbit "$down" || die "tun-shape: --download KBIT required (positive integer kbit/s)"
  is_positive_kbit "$up" || die "tun-shape: --upload KBIT required (positive integer kbit/s)"
  is_tunnel_shape_iface "$iface" || die "tun-shape: refuse non-tunnel iface: ${iface}"
  ip link show dev "$iface" >/dev/null 2>&1 \
    || die "tun-shape: ${iface} not present (start MorePrivate tt-client first)"
  apply_wan_shape_uci "$iface" "$down" "$up"
  log "OK tun-shape sqm.${SQM_UCI_SECTION} on ${iface} (${down}/${up} kbit)"
  log "tip: only if bufferbloat is proven; rates ≈ 85–95% of measured tunnel bulk — not ISP WAN rate"
}

cmd_tun_shape_disable() {
  [ "$#" -eq 0 ] || die "tun-shape-disable takes no arguments"
  disable_wan_shape
}

# Old name: refuse shaping WAN; point at tun-shape / disable for cleanup.
cmd_wan_shape() {
  die "wan-shape removed: never CAKE ISP WAN (it throttles the VPN). Run: $0 tun-shape-disable   then optionally: $0 tun-shape --download KBIT --upload KBIT (tun0 only)"
}

cmd_wan_shape_disable() {
  # Allow old name to clean up a mistaken WAN CAKE install.
  log "tun-shape-disable (was wan-shape-disable)"
  disable_wan_shape
}

# Report configured + live H2/H3 from ss (udp ESTAB=H3, tcp ESTAB=H2).
status_report_transport() {
  local conf="" vps="$1" port="$2" tcp_n="" udp_n="" live=""
  if [ -f "$CLIENT_TOML" ]; then
    conf="$(toml_get_str upstream_protocol "$CLIENT_TOML" 2>/dev/null || true)"
  fi
  [ -n "$conf" ] && _st_info "upstream_protocol=${conf} (configured)" \
    || _st_warn "upstream_protocol missing from client.toml"
  if [ -f "$CLIENT_TOML" ]; then
    local hc=""
    hc="$(sed -n 's/^health_check_timeout_ms[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$CLIENT_TOML" | head -1)"
    [ -n "$hc" ] && _st_info "health_check_timeout_ms=${hc}"
  fi

  if ! client_running; then
    _st_info "live transport: not tested (client stopped)"
    return 0
  fi
  if [ -z "$vps" ] || [ -z "$port" ]; then
    _st_warn "live transport: cannot probe (VPS/port unknown)"
    return 0
  fi
  if ! command -v ss >/dev/null 2>&1; then
    _st_warn "live transport: ss missing (install ip-full)"
    return 0
  fi
  tcp_n="$(count_estab_to_endpoint tcp "$vps" "$port" 2>/dev/null || echo 0)"
  udp_n="$(count_estab_to_endpoint udp "$vps" "$port" 2>/dev/null || echo 0)"
  case "$tcp_n" in ''|*[!0-9]*) tcp_n=0 ;; esac
  case "$udp_n" in ''|*[!0-9]*) udp_n=0 ;; esac

  if [ "$udp_n" -gt 0 ] && [ "$tcp_n" -gt 0 ]; then
    live="mixed H2+H3 (tcp ESTAB×${tcp_n}, udp ESTAB×${udp_n} → ${vps}:${port})"
    _st_ok "live transport: ${live}"
  elif [ "$udp_n" -gt 0 ]; then
    _st_ok "live transport: H3 (udp ESTAB×${udp_n} → ${vps}:${port})"
  elif [ "$tcp_n" -gt 0 ]; then
    _st_ok "live transport: H2 (tcp ESTAB×${tcp_n} → ${vps}:${port})"
  else
    _st_warn "live transport: none (no ESTAB to ${vps}:${port})"
  fi
}

client_pids() {
  if command -v pidof >/dev/null 2>&1; then
    pidof tt-client 2>/dev/null || true
  elif command -v pgrep >/dev/null 2>&1; then
    pgrep -f '^/usr/bin/tt-client([[:space:]]|$)' 2>/dev/null || true
  fi
}

client_single_pid() {
  local pids
  pids="$(client_pids)"
  set -- $pids
  [ "$#" -eq 1 ] || return 1
  echo "$1"
}

client_latest_vpn_state() {
  local pid="$1"
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  tt_log_tail 400 | awk -v tag="tt-client[${pid}]:" '
    index($0, tag) && /VPN_SS_/ {
      line = $0
      sub(/^.*VPN_SS_/, "VPN_SS_", line)
      sub(/[^A-Z_].*$/, "", line)
      state = line
    }
    END {
      if (state != "") print state
    }
  '
}

# Return the apk packages needed to provide missing installation capabilities.
ip_mark_route_supported() {
  command -v ip >/dev/null 2>&1 \
    && ip route get 127.0.0.1 mark "$MARK" >/dev/null 2>&1
}

missing_required_packages() {
  local require_fetch="${1:-0}" miss="" domain cert ca_ok=0
  [ -e /dev/net/tun ] || [ -e /dev/tun ] || miss="$miss kmod-tun"
  if ! ip_mark_route_supported; then
    miss="$miss ip-full"
  fi
  command -v nft >/dev/null 2>&1 || miss="$miss firewall4"
  command -v uci >/dev/null 2>&1 || miss="$miss uci"
  command -v awk >/dev/null 2>&1 || miss="$miss awk"
  command -v sed >/dev/null 2>&1 || miss="$miss sed"
  command -v grep >/dev/null 2>&1 || miss="$miss grep"
  [ -x /etc/init.d/dnsmasq ] || miss="$miss dnsmasq"
  [ -x /etc/init.d/firewall ] || miss="$miss firewall4"
  # TLS verify of LE endpoint certs + ipdeny HTTPS
  [ -s /etc/ssl/certs/ca-certificates.crt ] && ca_ok=1
  [ -s /etc/ssl/cert.pem ] && ca_ok=1
  for cert in /etc/ssl/certs/*.crt; do
    [ -s "$cert" ] && ca_ok=1 && break
  done
  if [ "$ca_ok" != "1" ]; then
    miss="$miss ca-certificates"
  fi
  if [ "$require_fetch" = "1" ]; then
    command -v wget >/dev/null 2>&1 \
      || command -v uclient-fetch >/dev/null 2>&1 \
      || command -v curl >/dev/null 2>&1 \
      || miss="$miss wget-ssl"
  fi
  if ! command -v idn2 >/dev/null 2>&1; then
    for domain in ${DIRECT_DNS_DOMAINS:-}; do
      is_ascii_domain "$domain" || {
        miss="$miss idn2"
        break
      }
    done
  fi
  unique_list "$miss"
}

try_clock_sync() {
  local configured server trace="/tmp/tt-clock.$$" timestamp now delta
  configured="$(normalize_list "$(uci -q get system.ntp.server 2>/dev/null || true)")"
  server="${configured%% *}"
  [ -n "$server" ] || server="0.openwrt.pool.ntp.org"
  log "best-effort clock check before HTTPS/package operations"
  if command -v ntpd >/dev/null 2>&1; then
    log "clock sync via ${server}"
    if command -v timeout >/dev/null 2>&1 \
      && timeout 20 ntpd -n -q -p "$server" >/dev/null 2>&1; then
      log "clock UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
      return 0
    elif ! command -v timeout >/dev/null 2>&1 \
      && ntpd -n -q -p "$server" >/dev/null 2>&1; then
      log "clock UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
      return 0
    fi
  fi

  log "NTP unavailable; try Cloudflare timestamp over HTTP to 1.1.1.1"
  if http_fetch_host \
    "http://1.1.1.1/cdn-cgi/trace" "cloudflare.com" "$trace"; then
    timestamp="$(
      sed -n 's/^ts=\([0-9][0-9]*\)\(\.[0-9][0-9]*\)\{0,1\}$/\1/p' "$trace" \
        | head -1
    )"
    rm -f "$trace"
    case "$timestamp" in
      ''|*[!0-9]*) timestamp="" ;;
    esac
    if [ -n "$timestamp" ] \
      && [ "$timestamp" -ge 1704067200 ] \
      && [ "$timestamp" -le 2147483647 ] \
      && date -u -s "@${timestamp}" >/dev/null 2>&1; then
      now="$(date -u '+%s' 2>/dev/null || true)"
      case "$now" in
        ''|*[!0-9]*) now=0 ;;
      esac
      delta=$((now - timestamp))
      [ "$delta" -lt 0 ] && delta=$((-delta))
      if [ "$delta" -le 10 ]; then
        log "clock UTC: $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
        return 0
      fi
    fi
  else
    rm -f "$trace"
  fi
  echo "WARNING: clock could not be synchronized; continuing without changing NTP settings" >&2
  echo "  verify 'date -u' and set the clock manually if HTTPS or apk fails" >&2
  return 0
}

# Install missing OpenWrt prerequisites, then verify actual capabilities.
need_pkgs() {
  local require_fetch="${1:-0}" miss remaining \
    apk_log="/tmp/tt-apk-add.$$"
  miss="$(missing_required_packages "$require_fetch")"
  [ -n "$miss" ] || return 0
  command -v apk >/dev/null 2>&1 \
    || die "missing required packages: ${miss}; apk is unavailable"
  log "missing OpenWrt packages: ${miss}"
  log "apk update"
  apk update \
    || die "apk update failed; installation stopped before MorePrivate tt-client changes"
  log "apk add ${miss}"
  if apk add $miss >"$apk_log" 2>&1; then
    cat "$apk_log"
    rm -f "$apk_log"
  else
    sed -n '1,12p' "$apk_log" >&2
    rm -f "$apk_log"
    case " $miss " in
      *" kmod-tun "*)
        die "cannot install kmod-tun: stock OpenWrt needs its matching kernel feed; custom firmware must include CONFIG_PACKAGE_kmod-tun=y"
        ;;
    esac
    die "apk add failed for: ${miss}; installation stopped"
  fi
  if command -v modprobe >/dev/null 2>&1; then
    modprobe tun 2>/dev/null || true
  fi
  remaining="$(missing_required_packages "$require_fetch")"
  [ -z "$remaining" ] \
    || die "packages installed but required capabilities are still missing: ${remaining}"
  log "OpenWrt package verification OK"
}

# --- verify ---
# Recent log lines mentioning moreprivate_tt_client / VPN (logread -e optional on old builds)
tt_log_tail() {
  local n="${1:-60}"
  # shellcheck disable=SC2015
  {
    logread -e moreprivate_tt_client 2>/dev/null \
      || logread 2>/dev/null | grep -i moreprivate_tt_client
  } | tail -n "$n" 2>/dev/null || true
}

tunnel_route_ready() {
  ip link show tun0 >/dev/null 2>&1 || return 1
  ip -4 route show table all 2>/dev/null \
    | grep -qE '(^|[[:space:]])dev tun0([[:space:]]|$)'
}

verify_tunnel() {
  local i=0 vps_ip="" pid="" state=""
  while [ "$i" -lt 8 ]; do
    pid="$(client_single_pid 2>/dev/null || true)"
    state=""
    [ -z "$pid" ] || state="$(client_latest_vpn_state "$pid" 2>/dev/null || true)"
    if [ "$state" = "VPN_SS_CONNECTED" ] && tunnel_route_ready; then
      # Restore the owned /32 after the client recreates table 880.
      if [ -f "$PBR_NFT" ]; then
        vps_ip="$(parse_vps_ip "$CLIENT_TOML")" || return 1
        install_vps_tunnel_route "$vps_ip" || return 1
      fi
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  echo "FAIL: tunnel not ready (pid=${pid:-none} latest_state=${state:-none} / tun route)"
  tt_log_tail 40 || true
  ip -4 route show table all 2>/dev/null | grep tun0 | sed 's/^/route: /' || true
  return 1
}

tunnel_probe_ip() {
  local ip
  for ip in 1.1.1.1 8.8.8.8 9.9.9.9; do
    if ! nft get element inet moreprivate_tt_client tt_direct4 "{ $ip }" >/dev/null 2>&1; then
      echo "$ip"
      return 0
    fi
  done
  return 1
}

guard_policy_ready() {
  local wan_dev="$1" dev
  [ -n "$wan_dev" ] || return 1
  [ -x "$GUARD_INIT" ] || return 1
  "$GUARD_INIT" check >/dev/null 2>&1 || return 1
  [ ! -e "${TT_DIR}/policy.failed" ] || return 1
  nft list table inet moreprivate_tt_client >/dev/null 2>&1 || return 1
  nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 || return 1
  nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1 || return 1
  nft get element inet moreprivate_tt_client tt_wan_devices "{ \"${wan_dev}\" }" \
    >/dev/null 2>&1 || return 1
  for dev in $(ip -4 route show default 2>/dev/null \
    | sed -n 's/.* dev \([^ ]*\).*/\1/p'); do
    nft get element inet moreprivate_tt_client tt_wan_devices "{ \"${dev}\" }" \
      >/dev/null 2>&1 || return 1
  done
  nft list chain inet moreprivate_tt_client moreprivate_tt_client_output_mark \
    >/dev/null 2>&1 || return 1
  nft list chain inet moreprivate_tt_client moreprivate_tt_client_output_guard 2>/dev/null \
    | grep -q reject || return 1
  nft list chain inet moreprivate_tt_client moreprivate_tt_client_forward_guard 2>/dev/null \
    | grep -q reject || return 1
}

verify_pbr() {
  local vps_ip="$1" wan_dev="$2" s wan_masq=0 has_lan_wan=0 marked_route=""
  [ -x "$GUARD_INIT" ] && "$GUARD_INIT" enabled 2>/dev/null \
    || die "independent kill-switch service is not enabled"
  guard_policy_ready "$wan_dev" \
    || die "independent kill switch is incomplete or emergency-only"
  ip rule show | grep -q "${MARK_PRIO}:.*${MARK}" \
    || die "missing ip rule priority ${MARK_PRIO}"
  [ -n "$vps_ip" ] || return 0
  ip_mark_route_supported \
    || die "cannot verify marked endpoint route: ip-full is required"
  marked_route="$(ip route get "$vps_ip" mark "$MARK" 2>/dev/null)" \
    || die "marked endpoint route query failed despite ip-full"
  echo "$marked_route" | grep -qE "dev ${wan_dev}|dev ${WAN_IF}|dev wan" \
    || die "VPS not via wan with mark: ${marked_route}"
  if client_running; then
    ip route get "$vps_ip" 2>/dev/null | grep -qE "dev tun0|table ${TUN_TABLE}" \
      || die "VPS non-endpoint traffic not via tun0: $(ip route get "$vps_ip" 2>/dev/null)"
  fi
  nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 \
    || die "tt_direct4 nft set missing (kill switch load failed?)"
  nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1 \
    || die "tt_direct_dns4 nft set missing (kill switch load failed?)"
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get "$s.src" 2>/dev/null)" = "lan" ] || continue
    [ "$(uci -q get "$s.dest" 2>/dev/null)" = "wan" ] || continue
    has_lan_wan=1
    break
  done
  [ "$has_lan_wan" = "1" ] || die "lan → wan forwarding missing for direct traffic"
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=zone$/\1/p'); do
    [ "$(uci -q get "$s.name" 2>/dev/null)" = "wan" ] || continue
    [ "$(uci -q get "$s.masq" 2>/dev/null)" = "1" ] && wan_masq=1
    break
  done
  [ "$wan_masq" = "1" ] || die "WAN zone masquerading disabled (direct traffic cannot reach internet)"
  nft list chain inet fw4 srcnat_wan 2>/dev/null | grep -q masquerade \
    || die "active WAN masquerade rule missing"
  firewall_lan_tunnel_ready \
    || die "active firewall4 LAN → moreprivate_tt_client forwarding missing"
}

cloudflare_trace() {
  local url="$1" timeout_secs="${2:-20}"
  if command -v curl >/dev/null 2>&1; then
    curl -4fsS --max-time "$timeout_secs" "$url" 2>/dev/null && return 0
  fi
  if command -v wget >/dev/null 2>&1; then
    wget -q -T "$timeout_secs" -O - "$url" 2>/dev/null && return 0
  fi
  if command -v uclient-fetch >/dev/null 2>&1; then
    uclient-fetch -q -T "$timeout_secs" -O - "$url" 2>/dev/null && return 0
  fi
  return 1
}

cloudflare_trace_ip() {
  local url="$1" timeout_secs="${2:-20}" trace exit_ip
  trace="$(cloudflare_trace "$url" "$timeout_secs")" || return 1
  exit_ip="$(printf '%s\n' "$trace" | sed -n 's/^ip=//p' | head -1 | tr -d '[:space:]')"
  echo "$exit_ip" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || return 1
  echo "$exit_ip"
}

verify_exit_ip() {
  local vps_ip="$1" direct_ip dns_ip hard_verified=0
  if nft get element inet moreprivate_tt_client tt_direct4 '{ 1.1.1.1 }' >/dev/null 2>&1; then
    echo "WARNING: 1.1.1.1 is in the direct IP list; automatic VPS-egress verification via 1.1.1.1 is skipped"
    echo "WARNING: test the public IP yourself with a known non-direct IP checker; expected ${vps_ip}"
  else
    direct_ip="$(cloudflare_trace_ip "https://1.1.1.1/cdn-cgi/trace")" || {
      echo "FAIL: cannot get public IPv4 from Cloudflare trace via 1.1.1.1"
      return 1
    }
    [ "$direct_ip" = "$vps_ip" ] || {
      echo "FAIL: tunnel egress via 1.1.1.1 IP=${direct_ip}, expected VPS_IP=${vps_ip}"
      return 1
    }
    hard_verified=1
  fi
  dns_lookup_once || {
    echo "FAIL: router DNS cannot resolve through 127.0.0.1:53"
    return 1
  }
  dns_ip="$(cloudflare_trace_ip "https://www.cloudflare.com/cdn-cgi/trace")" || {
    echo "WARNING: secondary Cloudflare DNS+HTTPS probe failed; it is non-fatal"
    if [ "$hard_verified" = "1" ]; then
      echo "OK tunnel egress IP=${vps_ip} verified via non-direct 1.1.1.1"
    else
      echo "WARNING: automatic VPS-egress identity is inconclusive; test a known non-direct IP checker and expect ${vps_ip}"
    fi
    return 0
  }
  if [ "$dns_ip" = "$vps_ip" ]; then
    if [ "$hard_verified" = "1" ]; then
      echo "OK tunnel egress IP=${vps_ip} (non-direct 1.1.1.1 + Cloudflare DNS trace)"
    else
      echo "WARNING: secondary Cloudflare DNS trace returned ${vps_ip}, but its destination was not proven non-direct"
      echo "WARNING: automatic VPS-egress identity remains inconclusive; test a known non-direct IP checker"
    fi
    return 0
  fi
  if [ "$hard_verified" = "1" ]; then
    echo "INFO: Cloudflare DNS trace egress=${dns_ip}; its selected destination may be intentionally direct"
    echo "OK tunnel egress IP=${vps_ip} verified via non-direct 1.1.1.1"
  else
    echo "WARNING: Cloudflare DNS trace egress=${dns_ip}; its selected destination may be intentionally direct"
    echo "WARNING: automatic VPS-egress identity is inconclusive; test a known non-direct IP checker and expect ${vps_ip}"
  fi
  return 0
}

icmp_echo_once() {
  local probe="${1:-1.1.1.1}"
  command -v ping >/dev/null 2>&1 || return 1
  ping -c 1 -W 3 "$probe" >/dev/null 2>&1
}

dns_lookup_once() {
  command -v nslookup >/dev/null 2>&1 || return 2
  if command -v timeout >/dev/null 2>&1; then
    timeout 8 nslookup google.com 127.0.0.1 >/dev/null 2>&1
    return $?
  fi
  nslookup google.com 127.0.0.1 >/dev/null 2>&1
}

verify_icmp() {
  local i=0 probe ping_output="" before="" after=""
  local rx_before=0 tx_before=0 rx_after=0 tx_after=0
  command -v ping >/dev/null 2>&1 || {
    echo "FAIL: router has no ping command for ICMP verification"
    return 1
  }
  probe="$(tunnel_probe_ip)" || {
    echo "INFO: ICMP verification skipped; configured direct list contains all built-in ping targets"
    return 0
  }
  ip route get "$probe" 2>/dev/null | grep -qE 'tun0|table 880' || {
    echo "FAIL: ICMP test target ${probe} is not routed through MorePrivate tt-client"
    return 1
  }
  before="$(ip -s link show dev tun0 2>/dev/null \
    | awk '/RX:/{getline; rx=$2} /TX:/{getline; tx=$2} END{print rx, tx}')"
  set -- $before
  rx_before="${1:-0}"
  tx_before="${2:-0}"
  while [ "$i" -lt 4 ]; do
    if ping_output="$(ping -c 1 -W 3 "$probe" 2>&1)"; then
      echo "OK tunneled ICMP echo via ${probe}"
      return 0
    fi
    i=$((i + 1))
    [ "$i" -lt 4 ] && sleep 2
  done
  after="$(ip -s link show dev tun0 2>/dev/null \
    | awk '/RX:/{getline; rx=$2} /TX:/{getline; tx=$2} END{print rx, tx}')"
  set -- $after
  rx_after="${1:-0}"
  tx_after="${2:-0}"
  echo "FAIL: tunneled ICMP echo failed"
  printf '%s\n' "$ping_output" | tail -n 6 | sed 's/^/  router ping: /'
  echo "  route: $(ip route get "$probe" 2>/dev/null | head -1)"
  echo "  tun0 packet delta during ping: RX=$((rx_after - rx_before)) TX=$((tx_after - tx_before))"
  if [ "$(uci -q get firewall.moreprivate_tt_client_icmp_reply.src 2>/dev/null)" != "moreprivate_tt_client" ] \
    || [ "$(uci -q get firewall.moreprivate_tt_client_icmp_reply.target 2>/dev/null)" != "ACCEPT" ]; then
    echo "  router firewall: managed tunnel echo-reply exception is missing"
  elif ! nft list chain inet fw4 input_moreprivate_tt_client 2>/dev/null \
    | grep -qE 'echo-reply.*accept|icmp type echo-reply.*accept'; then
    echo "  router firewall: managed echo-reply exception is not active in firewall4"
  fi
  tt_log_tail 40 | grep -iE 'icmp|drop|error' | tail -n 10 \
    | sed 's/^/  client log: /' || true
  echo "  VPS: vpn.toml needs [icmp] with the real egress interface"
  echo "  VPS: systemd service needs CAP_NET_RAW, then restart moreprivate_tt_client"
  return 1
}

# --- actions ---
rollback_failed_install() {
  local reason="$1"
  echo "FAIL install: ${reason}" >&2
  binary_tx_rollback
  log "rollback TT-owned state (restore direct WAN)"
  if ! cmd_purge; then
    echo "CRITICAL: TT cleanup is incomplete; direct WAN is not guaranteed" >&2
    echo "  run: $0 purge" >&2
    die "${reason}; rollback incomplete"
  fi
  echo "NOTICE: TT-owned fail-closed state was removed and direct WAN restored" >&2
  echo "NOTICE: shared DNS/IPv6 changes were not reverted; see purge report above" >&2
  die "$reason"
}

cmd_install() {
  local config="" binary="" version="" downloaded="" direct_countries="" direct_ip_file="" \
    direct_dns_domains="" direct_dns_servers="" \
    tunnel_dns_servers="$TUNNEL_DNS_SERVERS_DEFAULT" \
    vps_ip wan_dev binary_tag="" release_source="" \
    candidate="${TT_DIR}/direct.zone.candidate.$$" require_fetch=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) need_arg "$1" "${2:-}"; config="$2"; shift 2 ;;
      --binary) need_arg "$1" "${2:-}"; binary="$2"; shift 2 ;;
      --version|--release) need_arg "$1" "${2:-}"; version="$2"; shift 2 ;;
      --direct-countries) need_arg "$1" "${2:-}"; direct_countries="$2"; shift 2 ;;
      --direct-ip-file)
        need_arg "$1" "${2:-}"; direct_ip_file="$2"; shift 2 ;;
      --direct-dns-domains) need_arg "$1" "${2:-}"; direct_dns_domains="$2"; shift 2 ;;
      --direct-dns-servers) need_arg "$1" "${2:-}"; direct_dns_servers="$2"; shift 2 ;;
      --tunnel-dns-servers) need_arg "$1" "${2:-}"; tunnel_dns_servers="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "install: unknown option $1" ;;
    esac
  done
  [ -n "$config" ] || die "install needs --config FILE (from server clients/<name>.toml)"
  if [ -n "$binary" ] && [ -n "$version" ]; then
    die "install: use only one of --binary or --version"
  fi
  if [ -n "$direct_ip_file" ] && [ -n "$direct_countries" ]; then
    die "install: use either --direct-ip-file or --direct-countries (not both)"
  fi
  if [ -z "$direct_countries" ] && [ -z "$direct_ip_file" ]; then
    [ -z "$direct_dns_domains" ] && [ -z "$direct_dns_servers" ] \
      || die "install: direct options require --direct-countries or --direct-ip-file"
  elif [ -n "$direct_ip_file" ]; then
    [ -n "$direct_dns_domains" ] \
      || die "install: --direct-ip-file requires --direct-dns-domains"
    [ -n "$direct_dns_servers" ] \
      || die "install: --direct-ip-file requires --direct-dns-servers"
  fi
  DIRECT_DNS_DOMAINS_MODE=manual
  DIRECT_DNS_SERVERS_MODE=manual
  if [ -n "$direct_countries" ]; then
    [ -n "$direct_dns_domains" ] || DIRECT_DNS_DOMAINS_MODE=auto
    [ -n "$direct_dns_servers" ] || DIRECT_DNS_SERVERS_MODE=auto
  fi
  DIRECT_DNS_DOMAINS="$(normalize_list "$direct_dns_domains")"
  DIRECT_DNS_SERVERS="$(normalize_list "$direct_dns_servers")"
  TUNNEL_DNS_SERVERS="$(normalize_list "$tunnel_dns_servers")"
  DIRECT_COUNTRIES="$(norm_ids "$direct_countries")"

  need_file "$config"
  [ -z "$binary" ] || need_file "$binary"
  if has_install_artifacts; then
    die "install requires a clean router with no MorePrivate tt-client state; use upgrade/update-* for an installed system, or run purge first"
  fi
  try_clock_sync
  # An installed kmod may simply not have been loaded yet. Avoid a false
  # package miss and unnecessary network/package operation.
  if [ ! -e /dev/net/tun ] && [ ! -e /dev/tun ] \
    && command -v modprobe >/dev/null 2>&1; then
    modprobe tun 2>/dev/null || true
  fi
  [ -n "$binary" ] && [ -z "$DIRECT_COUNTRIES" ] || require_fetch=1
  need_pkgs "$require_fetch"
  need_cmds ip nft uci awk sed grep sha256sum readlink ln mv basename dirname
  [ -z "$DIRECT_COUNTRIES" ] || derive_country_profile "$DIRECT_COUNTRIES"
  validate_dns_policy

  if [ -z "$binary" ]; then
    command -v wget >/dev/null 2>&1 \
      || command -v uclient-fetch >/dev/null 2>&1 \
      || command -v curl >/dev/null 2>&1 \
      || die "need wget, uclient-fetch, or curl to download releases"
    [ -n "$version" ] || version="$(resolve_latest_version)"
    log "release tag: ${version}"
    downloaded="$(download_release_binary "$version")"
    binary="$downloaded"
    binary_tag="$version"
    release_source="github:${GITHUB_REPO}"
  else
    binary_tag="$(binary_tag_from_file "$binary")"
    version="$binary_tag"
    release_source=file
  fi

  vps_ip="$(parse_vps_ip "$config")" || die "bad config: no VPS IPv4"
  wan_dev="$(get_wan_dev)"
  log "VPS_IP=${vps_ip}  wan_dev=${wan_dev}"

  log "binary"
  binary_tx_begin
  trap 'binary_tx_on_exit "$?"' 0
  install_binary "$binary" "$binary_tag"
  [ -z "$downloaded" ] || rm -rf "$(dirname "$downloaded")"

  log "client.toml"
  install_client_toml "$config" "$wan_dev"
  save_wan_dev "$wan_dev"

  log "direct routing"
  mkdir -p "$TT_DIR"
  DIRECT_ENABLED=0
  DIRECT_SOURCE=""
  if [ -n "$direct_ip_file" ]; then
    DIRECT_COUNTRIES=""
    DIRECT_SOURCE=file
    if ! (install_direct_zone_file "$direct_ip_file" "$candidate"); then
      rollback_failed_install "failed to stage custom direct IP list"
    fi
    DIRECT_ENABLED=1
    if ! (validate_direct_profile "$candidate"); then
      rollback_failed_install "direct profile validation failed"
    fi
    mv "$candidate" "$DIRECT_ZONE" \
      || rollback_failed_install "failed to commit validated direct IP list"
  elif [ -n "$DIRECT_COUNTRIES" ]; then
    DIRECT_SOURCE=ipdeny
    if ! (fetch_direct_zone "$DIRECT_COUNTRIES" "$candidate"); then
      rollback_failed_install "failed to stage country direct IP list"
    fi
    DIRECT_ENABLED=1
    if ! (validate_direct_profile "$candidate"); then
      rollback_failed_install "direct profile validation failed"
    fi
    mv "$candidate" "$DIRECT_ZONE" \
      || rollback_failed_install "failed to commit validated direct IP list"
  else
    if ! (validate_direct_profile "$DIRECT_ZONE"); then
      rollback_failed_install "tunnel-only profile validation failed"
    fi
    rm -f "$DIRECT_ZONE"
    write_empty_set_elements "$DIRECT_EL"
    write_empty_set_elements "$DIRECT_DNS_EL"
    log "no direct IP list; supported traffic uses MorePrivate tt-client"
  fi
  log "ipv6 off"
  disable_ipv6
  save_direct_conf \
    || rollback_failed_install "failed to save routing profile"

  # Install and enable the independent kill switch before creating persistent
  # LAN→WAN forwarding or enabling the client service.  A power loss at any
  # later installation step therefore reboots fail-closed.
  log "independent PBR + kill switch (before network/service)"
  if ! (apply_direct_ip); then
    rollback_failed_install "failed to activate independent kill switch"
  fi

  log "zones"
  if ! install_zones; then
    rollback_failed_install "failed to install network/firewall zones"
  fi
  if ! /etc/init.d/network reload; then
    rollback_failed_install "network reload failed"
  fi

  log "procd"
  if ! write_init; then
    rollback_failed_install "failed to install MorePrivate tt-client service"
  fi
  service_start \
    || rollback_failed_install "MorePrivate tt-client service failed to start"

  log "verify tunnel"
  verify_tunnel \
    || rollback_failed_install "MorePrivate tt-client failed to connect"

  # apply_pbr restarted firewall before the MorePrivate tt-client zone existed.  Reload
  # once now, after tun0 exists, so firewall4 can bind the zone to the actual
  # device.  Never infer active forwarding merely from committed UCI.
  log "firewall LAN → tunnel"
  if ! /etc/init.d/firewall restart; then
    rollback_failed_install "firewall reload failed after tunnel startup"
  fi
  if ! firewall_lan_tunnel_ready; then
    rollback_failed_install "firewall4 did not activate LAN → moreprivate_tt_client forwarding"
  fi

  log "DNS"
  if ! (apply_direct_dns); then
    rollback_failed_install "failed to apply managed DNS"
  fi

  log "verify"
  if ! (verify_pbr "$vps_ip" "$wan_dev"); then
    rollback_failed_install "PBR verification failed"
  fi
  verify_tunnel \
    || rollback_failed_install "MorePrivate tt-client stopped after enabling DNS"
  verify_exit_ip "$vps_ip" \
    || rollback_failed_install "tunnel egress verification failed"
  verify_icmp \
    || rollback_failed_install "tunneled ICMP verification failed"
  save_release_meta "$release_source" "${version:-local}" \
    || rollback_failed_install "failed to save release metadata"
  binary_tx_commit "$_BIN_TX_NEW" "$_BIN_TX_OLD"
  trap - 0
  load_direct_conf
  echo "OK install openwrt  vps=${vps_ip}  wan_dev=${wan_dev}  direct_enabled=${DIRECT_ENABLED}"
  echo "  direct IP: source=${DIRECT_SOURCE} countries=[${DIRECT_COUNTRIES}] prefixes=$([ -f "$DIRECT_ZONE" ] && count_cidr "$DIRECT_ZONE" || echo 0)"
  echo "  DNS: direct_domains=[${DIRECT_DNS_DOMAINS}] direct_servers=[${DIRECT_DNS_SERVERS}] tunnel_servers=[${TUNNEL_DNS_SERVERS}]"
  echo "       modes: domains=${DIRECT_DNS_DOMAINS_MODE} servers=${DIRECT_DNS_SERVERS_MODE}"
  [ "$DIRECT_ENABLED" != "1" ] \
    || echo "  WAN exposure: TCP/UDP/ICMP to direct IP list; router DNS/53 to [${DIRECT_DNS_SERVERS}]"
  echo "  LAN acceptance required:"
  echo "    set the LAN client's nameserver to this router, then verify its public IP is ${vps_ip}"
  echo "    test both https://1.1.1.1/cdn-cgi/trace and https://www.cloudflare.com/cdn-cgi/trace"
}

cmd_upgrade() {
  local binary="" version="" downloaded="" binary_tag="" release_source=""
  local current target src_sum current_sum vps_ip new previous was_running=0 i=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --binary) need_arg "$1" "${2:-}"; binary="$2"; shift 2 ;;
      --version|--release) need_arg "$1" "${2:-}"; version="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "upgrade: unknown option $1" ;;
    esac
  done
  [ -z "$binary" ] || [ -z "$version" ] \
    || die "upgrade: use only one of --binary or --version"
  need_installed
  need_cmds sha256sum readlink ln mv basename dirname

  if [ -n "$binary" ]; then
    need_file "$binary"
    binary_tag="$(binary_tag_from_file "$binary")"
    version="$binary_tag"
    release_source=file
  else
    command -v wget >/dev/null 2>&1 \
      || command -v uclient-fetch >/dev/null 2>&1 \
      || command -v curl >/dev/null 2>&1 \
      || die "need wget, uclient-fetch, or curl to download releases"
    [ -n "$version" ] || version="$(resolve_latest_version)"
    log "release tag: ${version}"
    downloaded="$(download_release_binary "$version")"
    binary="$downloaded"
    binary_tag="$version"
    release_source="github:${GITHUB_REPO}"
  fi

  current="$(binary_resolve_link)" \
    || die "managed binary symlink missing or invalid — run install"
  target="/usr/bin/$(basename "$binary")"
  if [ "$current" = "$target" ]; then
    src_sum="$(sha256sum "$binary" | awk '{print $1}')"
    current_sum="$(sha256sum "$current" | awk '{print $1}')"
    [ "$src_sum" = "$current_sum" ] \
      || die "current version name collides with different binary content: $target"
    [ -z "$downloaded" ] || rm -rf "$(dirname "$downloaded")"
    save_release_meta "$release_source" "${version:-local}"
    echo "OK upgrade — already current: $(basename "$current")"
    return 0
  fi

  log "upgrade binary only"
  binary_tx_begin
  trap 'binary_tx_on_exit "$?"' 0
  install_binary "$binary" "$binary_tag"
  [ -z "$downloaded" ] || rm -rf "$(dirname "$downloaded")"

  if [ "$_BIN_TX_SERVICE_WAS_RUNNING" = 1 ]; then
    was_running=1
    vps_ip="$(parse_vps_ip "$CLIENT_TOML")" \
      || die "cannot read VPS IP from existing client.toml"
    log "restart running client"
    service_restart_preserve_enablement || die "upgraded client failed to restart"
    # H3 connect + first health check need a few seconds; one-shot DNS right after
    # start false-fails and rolls back a good binary.
    log "wait for tunnel to settle, then verify (retries)"
    i=0
    while [ "$i" -lt 5 ]; do
      i=$((i + 1))
      sleep 3
      if verify_tunnel \
        && verify_exit_ip "$vps_ip" \
        && verify_icmp; then
        break
      fi
      [ "$i" -lt 5 ] || die "upgraded client failed live verification after ${i} attempts"
      log "verify attempt ${i}/5 failed; retrying..."
    done
  else
    log "client stopped — leave stopped"
  fi

  save_release_meta "$release_source" "${version:-local}"
  new="$_BIN_TX_NEW"
  previous="$_BIN_TX_OLD"
  binary_tx_commit "$new" "$previous"
  trap - 0
  echo "OK upgrade — current=$(basename "$new")  rollback=$(basename "$previous")"
  [ "$was_running" = 1 ] || echo "  service was stopped and remains stopped"
}

cmd_update_creds() {
  local config="" vps_ip vps_port wan_dev old_ip="" old_port="" old_wan="" rewrite=0
  local previous="${TT_DIR}/client.toml.previous.$$" rollback_ok=1 was_running=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --config) need_arg "$1" "${2:-}"; config="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "update-creds: unknown option $1" ;;
    esac
  done
  [ -n "$config" ] || die "usage: $0 update-creds --config FILE"
  need_installed
  need_file "$config"

  wan_dev="$(get_wan_dev)"
  vps_ip="$(parse_vps_ip "$config")" || die "config missing VPS IPv4"
  vps_port="$(parse_vps_port "$config")" || die "config missing endpoint port"
  old_ip="$(parse_pbr_vps_ip 2>/dev/null || true)"
  old_port="$(parse_pbr_vps_port 2>/dev/null || true)"
  old_wan="$(parse_pbr_wan_dev 2>/dev/null || true)"
  [ -n "$old_ip" ] && [ -n "$old_port" ] && [ -n "$old_wan" ] \
    || die "cannot read active endpoint policy; run: $0 status"
  cp -p "$CLIENT_TOML" "$previous" \
    || die "cannot stage existing client.toml for rollback"
  client_running && was_running=1

  log "update client.toml from server file"
  if ! (install_client_toml "$config" "$wan_dev"); then
    cp -p "$previous" "$CLIENT_TOML" 2>/dev/null || true
    rm -f "$previous"
    die "cannot stage new client.toml; previous configuration retained"
  fi

  # Rewrite PBR if endpoint IP or WAN L3 device changed (else direct oifname can be stale)
  if [ -z "$old_ip" ] || [ "$old_ip" != "$vps_ip" ]; then
    log "PBR VPS IP ${old_ip:-none} → ${vps_ip}"
    rewrite=1
  fi
  if [ -z "$old_port" ] || [ "$old_port" != "$vps_port" ]; then
    log "PBR endpoint port ${old_port:-none} → ${vps_port}"
    rewrite=1
  fi
  if [ -z "$old_wan" ] || [ "$old_wan" != "$wan_dev" ]; then
    log "PBR wan_dev ${old_wan:-none} → ${wan_dev}"
    rewrite=1
  fi
  if ( { [ "$rewrite" != "1" ] || apply_pbr "$vps_ip" "$wan_dev"; } \
    && service_restart \
    && verify_tunnel \
    && verify_pbr "$vps_ip" "$wan_dev" ); then
    rm -f "$previous"
    echo "OK update-creds → ${CLIENT_TOML}  endpoint=${vps_ip}:${vps_port}"
    return 0
  fi

  echo "FAIL update-creds: candidate configuration/policy failed; restoring previous state" >&2
  if ! cp -p "$previous" "$CLIENT_TOML"; then
    rollback_ok=0
  elif [ "$rewrite" = "1" ] && ! (apply_pbr "$old_ip" "$old_wan"); then
      echo "CRITICAL: previous endpoint policy could not be reapplied" >&2
      rollback_ok=0
  fi
  if [ "$was_running" = "1" ]; then
    if ! (service_restart_preserve_enablement \
      && verify_tunnel \
      && verify_pbr "$old_ip" "$old_wan"); then
      echo "CRITICAL: previous client service could not be restored" >&2
      rollback_ok=0
    fi
  else
    if ! service_stop; then
      echo "CRITICAL: candidate client process could not be stopped" >&2
      rollback_ok=0
    fi
  fi
  rm -f "$previous"
  [ "$rollback_ok" = "1" ] \
    || die "update-creds failed; rollback incomplete; active state is unknown — run: $0 status"
  die "update-creds failed; previous configuration and policy restored"
}

cmd_update_direct() {
  local direct_countries="" direct_ip_file="" direct_dns_domains="" direct_dns_servers="" \
    tunnel_dns_servers="" n did_zone=0 \
    candidate="${TT_DIR}/direct.zone.candidate.$$" previous="${TT_DIR}/direct.zone.previous.$$" \
    had_previous=0 previous_direct_dns="" \
    staged_direct_dns=0 rollback_ok=1
  while [ $# -gt 0 ]; do
    case "$1" in
      --direct-countries) need_arg "$1" "${2:-}"; direct_countries="$2"; shift 2 ;;
      --direct-ip-file) need_arg "$1" "${2:-}"; direct_ip_file="$2"; shift 2 ;;
      --direct-dns-domains) need_arg "$1" "${2:-}"; direct_dns_domains="$2"; shift 2 ;;
      --direct-dns-servers) need_arg "$1" "${2:-}"; direct_dns_servers="$2"; shift 2 ;;
      --tunnel-dns-servers) need_arg "$1" "${2:-}"; tunnel_dns_servers="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      *) die "update-direct: unknown option $1" ;;
    esac
  done
  need_installed
  if [ -n "$direct_ip_file" ] && [ -n "$direct_countries" ]; then
    die "update-direct: use either --direct-ip-file or --direct-countries (not both)"
  fi
  load_direct_conf
  previous_direct_dns="$DIRECT_DNS_SERVERS"

  # DNS lists (independent of IP zone source)
  if [ -n "$direct_dns_domains" ]; then
    DIRECT_DNS_DOMAINS="$(normalize_list "$direct_dns_domains")"
    DIRECT_DNS_DOMAINS_MODE=manual
  fi
  if [ -n "$direct_dns_servers" ]; then
    DIRECT_DNS_SERVERS="$(normalize_list "$direct_dns_servers")"
    DIRECT_DNS_SERVERS_MODE=manual
  fi
  if [ -n "$tunnel_dns_servers" ]; then
    TUNNEL_DNS_SERVERS="$(normalize_list "$tunnel_dns_servers")"
  fi
  if [ -n "$direct_ip_file" ]; then
    install_direct_zone_file "$direct_ip_file" "$candidate"
    did_zone=1
  elif [ -n "$direct_countries" ]; then
    DIRECT_COUNTRIES="$(norm_ids "$direct_countries")"
    DIRECT_SOURCE=ipdeny
    [ -n "$DIRECT_DNS_DOMAINS" ] || DIRECT_DNS_DOMAINS_MODE=auto
    [ -n "$DIRECT_DNS_SERVERS" ] || DIRECT_DNS_SERVERS_MODE=auto
    derive_country_profile "$DIRECT_COUNTRIES"
    fetch_direct_zone "$DIRECT_COUNTRIES" "$candidate"
    did_zone=1
  elif [ -z "$direct_dns_domains" ] && [ -z "$direct_dns_servers" ] \
    && [ -z "$tunnel_dns_servers" ]; then
    # no args: re-fetch zone only
    if [ "$DIRECT_SOURCE" = "file" ]; then
      die "direct IP source is a custom file — use: $0 update-direct --direct-ip-file PATH
  or set DNS only: $0 update-direct --direct-dns-domains LIST --direct-dns-servers LIST"
    fi
    [ "$DIRECT_SOURCE" = "ipdeny" ] && [ -n "$DIRECT_COUNTRIES" ] \
      || die "no direct IP source configured; use --direct-countries or --direct-ip-file"
    derive_country_profile "$DIRECT_COUNTRIES"
    fetch_direct_zone "$DIRECT_COUNTRIES" "$candidate"
    did_zone=1
  fi
  # else: only DNS conf changed — no zone fetch
  validate_dns_policy
  if [ "$DIRECT_ENABLED" = "1" ] \
    && [ "$DIRECT_DNS_SERVERS" != "$previous_direct_dns" ]; then
    log "stage candidate router DNS/53 exception for validation"
    if ! replace_live_direct_dns_set "$DIRECT_DNS_SERVERS"; then
      if ! replace_live_direct_dns_set "$previous_direct_dns"; then
        die "cannot stage candidate DNS and rollback is incomplete; active DNS policy is unknown — run: $0 status"
      fi
      die "cannot stage candidate DNS for validation; previous active policy restored"
    fi
    staged_direct_dns=1
  fi

  if [ "$did_zone" = "1" ]; then
    if ! (validate_direct_profile "$candidate"); then
      if [ "$staged_direct_dns" = "1" ] \
        && ! replace_live_direct_dns_set "$previous_direct_dns"; then
        die "direct profile rejected and DNS-set rollback is incomplete — run: $0 status"
      fi
      rm -f "$candidate" "$previous" \
        || echo "WARNING: could not remove direct-profile staging files" >&2
      die "direct profile rejected; active policy is unchanged"
    fi
  else
    if ! (validate_direct_profile "$DIRECT_ZONE"); then
      if [ "$staged_direct_dns" = "1" ] \
        && ! replace_live_direct_dns_set "$previous_direct_dns"; then
        die "direct profile rejected and DNS-set rollback is incomplete — run: $0 status"
      fi
      die "direct profile rejected; active policy is unchanged"
    fi
  fi
  if [ "$staged_direct_dns" = "1" ]; then
    replace_live_direct_dns_set "$previous_direct_dns" \
      || die "candidate validated but DNS-set rollback is incomplete — run: $0 status"
    staged_direct_dns=0
  fi
  n=0
  if [ "$did_zone" = "1" ]; then
    n="$(count_cidr "$candidate")"
    if [ -f "$DIRECT_ZONE" ]; then
      cp -p "$DIRECT_ZONE" "$previous"
      had_previous=1
    fi
    bak "$DIRECT_ZONE"
    mv "$candidate" "$DIRECT_ZONE"
  elif [ -f "$DIRECT_ZONE" ]; then
    n="$(count_cidr "$DIRECT_ZONE")"
  fi
  if [ "$DIRECT_ENABLED" = "1" ]; then
    log "direct routing enabled — applying IP PBR + DNS"
    if ! (apply_direct_stack \
      && nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 \
      && save_direct_conf); then
      if [ "$did_zone" = "1" ]; then
        if [ "$had_previous" = "1" ]; then
          cp -p "$previous" "$DIRECT_ZONE"
        else
          rm -f "$DIRECT_ZONE"
        fi
      fi
      load_direct_conf
      rollback_ok=1
      if ! (apply_direct_stack); then
        echo "CRITICAL: previous direct profile could not be reapplied" >&2
        rollback_ok=0
      fi
      rm -f "$candidate" "$previous" \
        || echo "WARNING: could not remove direct-profile staging files" >&2
      [ "$rollback_ok" = "1" ] \
        || die "update-direct failed; rollback incomplete; active policy is unknown — run: $0 status"
      die "update-direct failed; previous active profile restored"
    fi
  else
    log "direct routing disabled — settings stored (direct-enable to apply)"
    if ! save_direct_conf; then
      if [ "$did_zone" = "1" ]; then
        if [ "$had_previous" = "1" ]; then
          cp -p "$previous" "$DIRECT_ZONE"
        else
          rm -f "$DIRECT_ZONE"
        fi
      fi
      rm -f "$candidate" "$previous" \
        || echo "WARNING: could not remove direct-profile staging files" >&2
      die "update-direct failed to save; active policy is unchanged"
    fi
  fi
  rm -f "$candidate" "$previous" \
    || echo "WARNING: could not remove direct-profile staging files" >&2
  echo "OK update-direct prefixes=${n}  source=${DIRECT_SOURCE}  countries=[${DIRECT_COUNTRIES}]  enabled=${DIRECT_ENABLED}"
  echo "  direct_dns_domains=[${DIRECT_DNS_DOMAINS}]"
  echo "  direct_dns_servers=[${DIRECT_DNS_SERVERS}] modes=${DIRECT_DNS_DOMAINS_MODE}/${DIRECT_DNS_SERVERS_MODE}"
  echo "  tunnel_dns_servers=[${TUNNEL_DNS_SERVERS}]"
  [ "$DIRECT_SOURCE" = "" ] \
    || echo "  WAN exposure: TCP/UDP/ICMP to direct IP list; router DNS/53 to [${DIRECT_DNS_SERVERS}]"
}

cmd_direct_enable() {
  local candidate="${TT_DIR}/direct.zone.candidate.$$" \
    previous="${TT_DIR}/direct.zone.previous.$$" had_previous=0 did_candidate=0 \
    rollback_ok=1
  need_installed
  load_direct_conf
  if [ ! -f "$DIRECT_ZONE" ] || [ "$(count_cidr "$DIRECT_ZONE")" = "0" ]; then
    if [ "$DIRECT_SOURCE" = "file" ]; then
      die "no direct IP list on disk — run: $0 update-direct --direct-ip-file PATH && $0 direct-enable"
    fi
    [ "$DIRECT_SOURCE" = "ipdeny" ] && [ -n "$DIRECT_COUNTRIES" ] \
      || die "no direct IP source configured; use update-direct first"
    log "no direct IP list yet — fetching countries=${DIRECT_COUNTRIES}"
    fetch_direct_zone "$DIRECT_COUNTRIES" "$candidate"
    if ! (validate_direct_profile "$candidate"); then
      rm -f "$candidate" "$previous" \
        || echo "WARNING: could not remove direct-profile staging files" >&2
      die "direct profile rejected; direct routing remains disabled and the candidate was discarded"
    fi
    if [ -f "$DIRECT_ZONE" ]; then
      cp -p "$DIRECT_ZONE" "$previous"
      had_previous=1
    fi
    bak "$DIRECT_ZONE"
    mv "$candidate" "$DIRECT_ZONE"
    did_candidate=1
  elif ! (validate_direct_profile "$DIRECT_ZONE"); then
    die "direct profile rejected; direct routing remains disabled"
  fi
  DIRECT_ENABLED=1
  if ! (apply_direct_stack \
    && nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 \
    && save_direct_conf); then
    if [ "$did_candidate" = "1" ]; then
      if [ "$had_previous" = "1" ]; then
        cp -p "$previous" "$DIRECT_ZONE"
      else
        rm -f "$DIRECT_ZONE"
      fi
    fi
    load_direct_conf
    rollback_ok=1
    if ! (apply_direct_stack); then
      echo "CRITICAL: previous direct policy could not be reapplied" >&2
      rollback_ok=0
    fi
    rm -f "$candidate" "$previous" \
      || echo "WARNING: could not remove direct-profile staging files" >&2
    [ "$rollback_ok" = "1" ] \
      || die "direct-enable failed; rollback incomplete; active policy is unknown — run: $0 status"
    die "direct-enable failed; previous active policy restored"
  fi
  rm -f "$candidate" "$previous" \
    || echo "WARNING: could not remove direct-profile staging files" >&2
  echo "OK direct-enable  source=${DIRECT_SOURCE}  countries=[${DIRECT_COUNTRIES}]  prefixes=$(count_cidr "$DIRECT_ZONE")"
  echo "  IP: direct list → WAN"
  echo "  DNS: direct_domains=[${DIRECT_DNS_DOMAINS}] direct_servers=[${DIRECT_DNS_SERVERS}] tunnel_servers=[${TUNNEL_DNS_SERVERS}]"
  echo "  WAN exposure: TCP/UDP/ICMP to direct IP list; router DNS/53 to [${DIRECT_DNS_SERVERS}]"
}

cmd_direct_disable() {
  local rollback_ok=1
  need_installed
  load_direct_conf
  DIRECT_ENABLED=0
  # Keep DIRECT_ZONE on disk for re-enable; empty nft set + DNS all via VPS path
  if ! (apply_direct_stack \
    && nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1 \
    && save_direct_conf); then
    load_direct_conf
    if ! (apply_direct_stack); then
      echo "CRITICAL: previous direct-enabled policy could not be reapplied" >&2
      rollback_ok=0
    fi
    [ "$rollback_ok" = "1" ] \
      || die "direct-disable failed; rollback incomplete; active policy is unknown — run: $0 status"
    die "direct-disable failed; previous active policy restored"
  fi
  echo "OK direct-disable  (direct IP list kept at ${DIRECT_ZONE} if present)"
  echo "  IP: only router TCP to the configured server IP:port uses WAN"
  if [ -n "$TUNNEL_DNS_SERVERS" ]; then
    echo "  DNS: all via ${TUNNEL_DNS_SERVERS}"
  else
    echo "  DNS: unchanged (not managed by this script)"
  fi
  echo "  re-enable: $0 direct-enable"
}

cmd_disable() {
  [ -x "$INIT" ] || die "not installed"
  log "disable MorePrivate tt-client service (direct routing policy stays)"
  service_stop || die "moreprivate_tt_client stop failed; service remains enabled"
  "$INIT" disable 2>/dev/null || true
  echo "OK disable"
  echo "  TT stopped; direct exceptions + fail-closed WAN rules still active"
  echo "  re-enable: $0 enable"
}

cmd_enable() {
  local vps_ip wan_dev
  need_installed
  vps_ip="$(parse_vps_ip "$CLIENT_TOML")" \
    || die "cannot parse VPS IP from client.toml"
  wan_dev="$(get_wan_dev)"
  log "enable MorePrivate tt-client service"
  service_start || die "moreprivate_tt_client start failed"
  verify_tunnel || exit 1
  verify_pbr "$vps_ip" "$wan_dev" || exit 1
  verify_icmp || exit 1
  echo "OK enable"
}

# Stop+start client; keep boot enablement; do not touch PBR/kill-switch.
# Must be as reliable as `/etc/init.d/moreprivate_tt_client restart` (hard stop + settle + verify).
cmd_restart() {
  local vps_ip wan_dev i=0
  need_installed
  vps_ip="$(parse_vps_ip "$CLIENT_TOML")" \
    || die "cannot parse VPS IP from client.toml"
  wan_dev="$(get_wan_dev)"
  log "restart MorePrivate tt-client service (PBR/kill-switch unchanged)"
  service_restart_preserve_enablement || die "moreprivate_tt_client restart failed"
  log "wait for tunnel to settle (process + tun0 + H3)"
  service_wait_tunnel_ready 30 || log "warn: settle timeout — still verifying"
  # Same budget as upgrade: H3 + ICMP mux often need >8s after a long-lived wedge.
  i=0
  while [ "$i" -lt 6 ]; do
    i=$((i + 1))
    sleep 3
    if verify_tunnel && verify_pbr "$vps_ip" "$wan_dev" && verify_icmp; then
      echo "OK restart"
      return 0
    fi
    [ "$i" -lt 6 ] && log "verify attempt ${i}/6 not ready yet..."
  done
  die "restart completed but live verification failed (tunnel/PBR/ICMP) — check logread -e moreprivate_tt_client and VPS [icmp]"
}

cmd_rollback() {
  local current previous was_running=0 vps_ip
  need_installed
  current="$(binary_resolve_link)" \
    || die "managed binary symlink missing or invalid — run install first"
  previous="$(binary_previous "$current")" \
    || die "no previous successful binary is available"
  client_running && was_running=1

  log "rollback $(basename "$current") → $(basename "$previous")"
  binary_switch_link "$previous"
  if [ "$was_running" = 1 ]; then
    vps_ip="$(parse_vps_ip "$CLIENT_TOML")" || {
      binary_switch_link "$current"
      die "cannot read VPS IP; restored $(basename "$current")"
    }
    if ! service_restart_preserve_enablement \
      || ! verify_tunnel \
      || ! verify_exit_ip "$vps_ip" \
      || ! verify_icmp; then
      binary_switch_link "$current"
      service_restart_preserve_enablement >/dev/null 2>&1 || true
      die "rollback binary failed verification; restored $(basename "$current")"
    fi
  fi
  save_release_meta rollback "$(basename "$previous")"
  echo "OK rollback — current=$(basename "$previous")  rollback=$(basename "$current")"
  [ "$was_running" = 1 ] || echo "  service was stopped and remains stopped"
}

cmd_status() {
  local vps_ip="" vps_port="" wan_dev s wan_masq=0 current="" previous=""
  local direct_ip="" dns_ip="" probe="" hard_verified=0 current_wan_dns=""
  local _vps_marked="" _vps_unmarked=""
  local dns_actual="" dns_expected="" dns_tunnel="" dns_direct="" dns_domains="" dom srv
  local tt_up="" tt_l3="" lan_cfg=0 lan_jump=0 lan_accept=0 ip_mark_ok=0
  _ST_FAILS=0
  _ST_WARNS=0
  echo "=== MorePrivate tt-client OpenWrt status ==="
  echo
  echo "[install]"
  if [ -x "$BIN" ]; then
    _st_ok "binary $BIN"
    if current="$(binary_resolve_link 2>/dev/null)"; then
      _st_info "binary [*] ${current}"
      if previous="$(binary_previous "$current" 2>/dev/null)"; then
        _st_info "binary [ ] ${previous}"
      else
        _st_info "binary [ ] unavailable (no previous successful install)"
      fi
    else
      _st_fail "binary path is not a managed symlink"
    fi
    _st_info "product: $("$BIN" --version 2>/dev/null | head -1 || echo unknown)"
    if [ -f "$RELEASE_META" ]; then
      _st_info "release: $(tr '\n' ' ' <"$RELEASE_META")"
    else
      _st_warn "release metadata missing"
    fi
  else
    _st_fail "binary missing"
  fi
  if [ -f "$CLIENT_TOML" ]; then
    _st_ok "$CLIENT_TOML"
    vps_ip="$(parse_vps_ip "$CLIENT_TOML" 2>/dev/null || true)"
    vps_port="$(parse_vps_port "$CLIENT_TOML" 2>/dev/null || true)"
    wan_dev="$(get_wan_dev)"
    _st_info "vps=${vps_ip:-?}:${vps_port:-?}"
    _st_info "user=$(toml_get_str username "$CLIENT_TOML")"
    _st_info "sni=$(toml_get_str custom_sni "$CLIENT_TOML")"
    _st_info "bound_if=$(toml_get_str bound_if "$CLIENT_TOML")"
    _st_info "wan_dev=${wan_dev}"
    if grep -qE '^exclusions[[:space:]]*=[[:space:]]*\[\]' "$CLIENT_TOML"; then
      _st_ok "exclusions = []"
    else
      _st_fail "exclusions must be []"
    fi
  else
    _st_fail "client.toml missing"
  fi
  echo
  echo "[service]"
  if [ -x "$INIT" ]; then
    if "$INIT" enabled 2>/dev/null; then
      _st_ok "enabled at boot"
    else
      _st_warn "disabled at boot (direct routing policy may still be active)"
    fi
  else
    _st_fail "init script missing"
  fi
  if client_running; then
    _st_ok "process running"
  else
    _st_warn "process not running"
  fi
  tt_log_tail 5 | sed 's/^/  | /' || true
  echo
  echo "[transport]"
  status_report_transport "$vps_ip" "$vps_port"
  echo
  echo "[tun-shape]"
  status_report_wan_shape
  echo
  echo "[icmp]"
  if ! command -v ping >/dev/null 2>&1; then
    _st_fail "router ping command missing"
  elif client_running; then
    probe="$(tunnel_probe_ip 2>/dev/null || true)"
    if [ -z "$probe" ]; then
      _st_info "ICMP test skipped: direct list contains all built-in ping targets"
    elif icmp_echo_once "$probe"; then
      _st_ok "tunneled echo via ${probe}"
    else
      _st_fail "tunneled echo via ${probe} failed (check server [icmp] + CAP_NET_RAW)"
    fi
  else
    _st_info "not tested while client is stopped"
  fi
  echo
  echo "[router connectivity]"
  if ! client_running; then
    _st_info "not tested while client is stopped"
  elif [ -z "$vps_ip" ]; then
    _st_fail "cannot test egress: VPS IP missing from client.toml"
  else
    if tunnel_route_ready; then
      _st_ok "tun0 has an active IPv4 route"
    else
      _st_fail "tun0 has no active IPv4 route"
    fi
    if nft get element inet moreprivate_tt_client tt_direct4 '{ 1.1.1.1 }' >/dev/null 2>&1; then
      _st_warn "1.1.1.1 is direct; manually test a known non-direct IP checker (expected ${vps_ip})"
    elif direct_ip="$(cloudflare_trace_ip "https://1.1.1.1/cdn-cgi/trace" 8 2>/dev/null)"; then
      if [ "$direct_ip" = "$vps_ip" ]; then
        _st_ok "direct-IP HTTPS egress=${direct_ip}"
        hard_verified=1
      else
        _st_fail "direct-IP HTTPS egress=${direct_ip}, expected VPS=${vps_ip}"
      fi
    else
      _st_fail "direct-IP HTTPS failed via 1.1.1.1"
    fi
    if dns_ip="$(cloudflare_trace_ip "https://www.cloudflare.com/cdn-cgi/trace" 8 2>/dev/null)"; then
      if [ "$dns_ip" = "$vps_ip" ] && [ "$hard_verified" = "1" ]; then
        _st_ok "DNS+HTTPS egress=${dns_ip}"
      elif [ "$dns_ip" = "$vps_ip" ]; then
        _st_warn "Cloudflare returned VPS IP, but destination was not proven non-direct; verify manually"
      elif [ "$hard_verified" = "1" ]; then
        _st_info "DNS+HTTPS egress=${dns_ip} (selected Cloudflare destination may be direct)"
      else
        _st_warn "DNS+HTTPS egress=${dns_ip}; manually test a known non-direct IP checker"
      fi
    else
      _st_warn "secondary DNS+HTTPS probe failed via www.cloudflare.com"
      [ "$hard_verified" = "1" ] \
        || _st_warn "manually test a known non-direct IP checker (expected ${vps_ip})"
    fi
  fi
  echo
  echo "[pbr]"
  if [ -f "$PBR_NFT" ]; then
    _st_ok "$PBR_NFT"
  else
    _st_fail "PBR nft missing"
  fi
  if [ -x "$GUARD_INIT" ] && "$GUARD_INIT" enabled 2>/dev/null; then
    _st_ok "independent kill switch enabled before network startup"
  else
    _st_fail "independent kill-switch service missing or disabled"
  fi
  if guard_policy_ready "$wan_dev"; then
    _st_ok "independent nft policy loaded for WAN device ${wan_dev}"
  elif [ -e "${TT_DIR}/policy.failed" ]; then
    _st_fail "full nft policy failed; endpoint-only emergency kill switch is active"
  else
    _st_fail "independent nft policy/chains/WAN-device guard incomplete"
  fi
  if ip rule show | grep -q "${MARK_PRIO}:.*${MARK}"; then
    _st_ok "ip rule prio ${MARK_PRIO} fwmark ${MARK}"
  else
    _st_fail "mark rule missing"
  fi
  if ip_mark_route_supported; then
    ip_mark_ok=1
    _st_ok "ip-full marked-route queries supported"
  else
    _st_fail "marked-route queries unsupported; install ip-full"
  fi
  if [ -n "$vps_ip" ] && client_running; then
    if [ "$ip_mark_ok" != "1" ]; then
      _st_fail "endpoint TCP/UDP marked route not tested because ip-full is unavailable"
    else
      _vps_marked="$(ip route get "$vps_ip" mark "$MARK" 2>/dev/null | head -1)"
      if echo "$_vps_marked" | grep -qE "dev ${wan_dev}|dev ${WAN_IF}|dev wan"; then
        _st_ok "endpoint TCP/UDP mark routes VPS via WAN: ${_vps_marked}"
      else
        _st_fail "endpoint TCP/UDP mark does not route VPS via WAN: ${_vps_marked:-no route}"
      fi
    fi
    _vps_unmarked="$(ip route get "$vps_ip" 2>/dev/null | head -1)"
    if echo "$_vps_unmarked" | grep -qE "dev tun0|table ${TUN_TABLE}"; then
      _st_ok "other VPS traffic routes via tunnel: ${_vps_unmarked}"
    else
      _st_fail "other VPS traffic does not route via tunnel: ${_vps_unmarked:-no route}"
    fi
  fi
  if nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1; then
    _st_ok "nft set tt_direct4"
  else
    _st_fail "tt_direct4 not loaded"
  fi
  if nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1; then
    _st_ok "nft set tt_direct_dns4 (router DNS only)"
  else
    _st_fail "tt_direct_dns4 not loaded"
  fi
  has_lan_wan=0
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get "$s.src" 2>/dev/null)" = "lan" ] || continue
    [ "$(uci -q get "$s.dest" 2>/dev/null)" = "wan" ] || continue
    has_lan_wan=1
    break
  done
  if [ "$has_lan_wan" = "1" ]; then
    _st_ok "lan → wan forwarding (direct list only; nft guarded)"
  else
    _st_fail "lan → wan forwarding missing"
  fi
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=zone$/\1/p'); do
    [ "$(uci -q get "$s.name" 2>/dev/null)" = "wan" ] || continue
    [ "$(uci -q get "$s.masq" 2>/dev/null)" = "1" ] && wan_masq=1
    break
  done
  if [ "$wan_masq" = "1" ]; then
    _st_ok "WAN zone masquerading"
  else
    _st_fail "WAN zone masquerading disabled"
  fi
  if nft list chain inet fw4 srcnat_wan 2>/dev/null | grep -q masquerade; then
    _st_ok "active WAN masquerade rule"
  else
    _st_fail "active WAN masquerade rule missing"
  fi
  echo
  echo "[lan tunnel path]"
  if [ "$(uci -q get network.moreprivate_tt_client.proto 2>/dev/null)" = "none" ] \
    && [ "$(uci -q get network.moreprivate_tt_client.device 2>/dev/null)" = "tun0" ]; then
    _st_ok "UCI interface moreprivate_tt_client → tun0"
  else
    _st_fail "UCI interface moreprivate_tt_client is not bound to tun0"
  fi
  if command -v ifstatus >/dev/null 2>&1 \
    && command -v jsonfilter >/dev/null 2>&1; then
    tt_up="$(ifstatus moreprivate_tt_client 2>/dev/null | jsonfilter -e '@.up' 2>/dev/null || true)"
    tt_l3="$(ifstatus moreprivate_tt_client 2>/dev/null | jsonfilter -e '@.l3_device' 2>/dev/null || true)"
  fi
  if [ "$tt_up" = "true" ] && [ "$tt_l3" = "tun0" ]; then
    _st_ok "netifd interface up, l3_device=tun0"
  else
    _st_fail "netifd interface not ready: up=${tt_up:-unknown} l3_device=${tt_l3:-unknown}"
  fi
  if [ "$(uci -q get firewall.lan_moreprivate_tt_client.src 2>/dev/null)" = "lan" ] \
    && [ "$(uci -q get firewall.lan_moreprivate_tt_client.dest 2>/dev/null)" = "moreprivate_tt_client" ]; then
    lan_cfg=1
    _st_ok "UCI forwarding lan → moreprivate_tt_client"
  else
    _st_fail "UCI forwarding lan → moreprivate_tt_client missing"
  fi
  if [ "$(uci -q get firewall.moreprivate_tt_client_icmp_reply.src 2>/dev/null)" = "moreprivate_tt_client" ] \
    && [ "$(uci -q get firewall.moreprivate_tt_client_icmp_reply.target 2>/dev/null)" = "ACCEPT" ] \
    && nft list chain inet fw4 input_moreprivate_tt_client 2>/dev/null \
      | grep -qE 'echo-reply.*accept|icmp type echo-reply.*accept'; then
    _st_ok "router-local tunneled ICMP echo replies allowed"
  else
    _st_fail "router-local tunnel echo-reply firewall rule missing or inactive"
  fi
  if firewall_lan_tunnel_jump_ready; then
    lan_jump=1
    _st_ok "active firewall4 forward_lan → accept_to_moreprivate_tt_client"
  else
    _st_fail "active firewall4 forward_lan has no moreprivate_tt_client jump"
  fi
  if firewall_tunnel_accept_ready; then
    lan_accept=1
    _st_ok "active firewall4 accepts LAN forwarding to tun0"
  else
    _st_fail "active firewall4 accept_to_moreprivate_tt_client does not accept tun0"
  fi
  if tunnel_route_ready; then
    _st_ok "kernel has an IPv4 route through tun0"
  else
    _st_fail "kernel has no active IPv4 route through tun0"
  fi
  if [ "$lan_cfg" = "1" ] && { [ "$lan_jump" != "1" ] || [ "$lan_accept" != "1" ]; }; then
    _st_info "diagnosis: UCI is configured but firewall4 active state is stale/incomplete"
    _st_info "action: /etc/init.d/firewall restart"
  elif [ "$tt_up" != "true" ] || [ "$tt_l3" != "tun0" ]; then
    _st_info "diagnosis: netifd has not attached the moreprivate_tt_client interface to tun0"
  fi
  load_direct_conf
  echo
  echo "[direct]"
  if [ "$DIRECT_ENABLED" = "1" ]; then
    _st_ok "enabled (IP PBR + DNS split)"
  else
    _st_info "disabled (direct-enable to turn on)"
  fi
  _st_info "source=${DIRECT_SOURCE}  direct_countries=[${DIRECT_COUNTRIES}]"
  _st_info "direct_dns_domains=[${DIRECT_DNS_DOMAINS}] mode=${DIRECT_DNS_DOMAINS_MODE}"
  if [ -n "$DIRECT_DNS_DOMAINS" ]; then
    _pc=""
    _pc="$(domains_to_ascii_list "$DIRECT_DNS_DOMAINS" 2>/dev/null)" || _pc="(install python3 or idn2 to show/convert)"
    _st_info "direct_dns_domains_ascii=[${_pc}]"
  fi
  _st_info "direct_dns_servers=[${DIRECT_DNS_SERVERS}] mode=${DIRECT_DNS_SERVERS_MODE}"
  if [ "$DIRECT_DNS_SERVERS_MODE" = auto ]; then
    current_wan_dns="$(normalize_list "$(get_wan_dns_servers)")"
    if [ -z "$current_wan_dns" ]; then
      _st_warn "WAN DNS is no longer discoverable; automatic resolver profile may be stale"
    elif [ "$current_wan_dns" != "$DIRECT_DNS_SERVERS" ]; then
      _st_warn "WAN DNS changed to [${current_wan_dns}]; run: $0 update-direct"
    fi
  fi
  _st_info "tunnel_dns_servers=[${TUNNEL_DNS_SERVERS}]"
  if [ -f "$DIRECT_ZONE" ]; then
    _st_ok "direct IP prefixes=$(count_cidr "$DIRECT_ZONE")"
  else
    _st_info "no direct IP list yet (update-direct --direct-ip-file PATH | --direct-countries LIST)"
  fi
  if [ -n "$vps_ip" ]; then
    _st_info "route 1.1.1.1: $(ip route get 1.1.1.1 2>/dev/null | head -1)"
  fi
  echo
  echo "[dns]"
  if [ "$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null)" = "1" ]; then
    _st_ok "dnsmasq noresolv=1"
  else
    _st_fail "dnsmasq noresolv must be 1 (WAN resolver leak risk)"
  fi
  if [ "$(uci -q get dhcp.@dnsmasq[0].strictorder 2>/dev/null)" = "1" ]; then
    _st_ok "dnsmasq strictorder=1"
  else
    _st_fail "dnsmasq strictorder must be 1"
  fi
  if [ -f "$DNS_ENV" ]; then
    _st_ok "$DNS_ENV"
    dns_tunnel="$(sed -n 's/^TUNNEL_DNS_SERVERS="\(.*\)"$/\1/p' "$DNS_ENV")"
    dns_direct="$(sed -n 's/^DIRECT_DNS_SERVERS="\(.*\)"$/\1/p' "$DNS_ENV")"
    dns_domains="$(sed -n 's/^DIRECT_DNS_DOMAINS="\(.*\)"$/\1/p' "$DNS_ENV")"
    dns_expected=""
    for dom in $dns_domains; do
      for srv in $dns_direct; do
        dns_expected="${dns_expected} /${dom}/${srv}"
      done
    done
    dns_expected="$(normalize_list "${dns_expected} ${dns_tunnel}")"
    dns_actual="$(normalize_list "$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null)")"
    if [ "$dns_actual" = "$dns_expected" ]; then
      _st_ok "dnsmasq server list exactly matches managed policy"
    else
      _st_fail "dnsmasq server list differs: actual=[${dns_actual}] expected=[${dns_expected}]"
    fi
  else
    _st_fail "no dns.env"
  fi
  if client_running; then
    if dns_lookup_once; then
      _st_ok "router DNS resolves via 127.0.0.1:53"
    else
      case "$?" in
        2) _st_warn "nslookup unavailable; DNS covered only by the DNS+HTTPS probe" ;;
        *) _st_fail "router DNS cannot resolve google.com via 127.0.0.1:53" ;;
      esac
    fi
  else
    _st_info "live DNS not tested while client is stopped"
  fi
  echo
  _st_info "FAIL=${_ST_FAILS}  warn=${_ST_WARNS}"
  if [ "$_ST_FAILS" -eq 0 ]; then
    if [ "$_ST_WARNS" -eq 0 ]; then
      echo "OK status"
    else
      echo "OK status (with warnings)"
    fi
    return 0
  fi
  echo "status: failed (${_ST_FAILS} FAIL)"
  return 1
}

cmd_purge() {
  # Goal: router usable with direct WAN after purge.
  # MUST remove TT product that would break or split traffic without TT:
  #   service, binary, PBR/fail-closed nft, direct, mark rule, hotplug, tun0,
  #   network.moreprivate_tt_client, firewall.moreprivate_tt_client, lan→moreprivate_tt_client.
  # MUST keep/ensure direct lan→wan (any shared LAN→WAN forwarding).
  # MUST NOT touch shared host policy (DNS, rebind, wan6/dhcpv6 UCI) —
  # even if install modified them — only REPORT for user review.
  local left=0 has_lan_wan s vps_ip=""

  log "purge TT product only (direct internet; shared state reported untouched)"
  vps_ip="$(parse_vps_ip "$CLIENT_TOML" 2>/dev/null || true)"

  # Drop TT-owned SQM/CAKE before removing state files (UCI lives outside TT_DIR).
  if [ -f "$WAN_SHAPE_CONF" ] || uci -q get "sqm.${SQM_UCI_SECTION}" >/dev/null 2>&1; then
    log "0/5 disable TT tun-shape (sqm.${SQM_UCI_SECTION})"
    disable_wan_shape 2>/dev/null || true
  fi

  log "1/5 stop+disable TT service"
  service_stop \
    || echo "WARNING: client did not stop; purge will continue and report it as leftover" >&2
  if [ -x "$INIT" ]; then
    "$INIT" disable 2>/dev/null || true
  fi
  if [ -x "$GUARD_INIT" ]; then
    "$GUARD_INIT" disable 2>/dev/null || true
  fi

  log "2/5 remove TT product files + direct policy/PBR/fail-closed + mark + tun"
  rm -f "$INIT" "$GUARD_INIT"
  rm -f /etc/rc.d/*moreprivate_tt_client* 2>/dev/null || true
  rm -f "$BIN" "${BIN}.link."*
  rm -f /usr/bin/tt-client-*-linux-*
  # Independent kill switch + hotplug must go before ordinary WAN is restored.
  nft destroy table inet moreprivate_tt_client 2>/dev/null || true
  rm -f "$PBR_NFT" "$HOTPLUG"
  rm -rf "$TT_DIR"
  while ip rule del priority "$MARK_PRIO" 2>/dev/null; do :; done
  remove_vps_tunnel_route "$vps_ip"
  ip route flush cache 2>/dev/null || true
  if ip link show tun0 >/dev/null 2>&1; then
    ip link set tun0 down 2>/dev/null || true
    ip link del tun0 2>/dev/null || true
  fi
  # owned sysctl drop-in only (not UCI ipv6 policy)
  rm -f /etc/sysctl.d/99-moreprivate_tt_client-ipv6.conf
  sysctl -w net.ipv6.conf.all.disable_ipv6=0 2>/dev/null || true
  sysctl -w net.ipv6.conf.default.disable_ipv6=0 2>/dev/null || true

  log "3/5 remove TT zones/forwards; ensure direct lan→wan remains"
  uci -q delete network.moreprivate_tt_client 2>/dev/null || true
  uci commit network 2>/dev/null || true
  uci -q delete firewall.moreprivate_tt_client 2>/dev/null || true
  uci -q delete firewall.moreprivate_tt_client_icmp_reply 2>/dev/null || true
  uci -q delete firewall.lan_moreprivate_tt_client 2>/dev/null || true
  uci -q delete firewall.moreprivate_tt_client_lan_wan 2>/dev/null || true
  has_lan_wan=0
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get "$s.src" 2>/dev/null)" = "lan" ] || continue
    [ "$(uci -q get "$s.dest" 2>/dev/null)" = "wan" ] || continue
    has_lan_wan=1
    break
  done
  if [ "$has_lan_wan" = 0 ]; then
    echo "  no lan→wan forward — adding one so internet works without TT"
    uci add firewall forwarding >/dev/null
    uci set firewall.@forwarding[-1].src='lan'
    uci set firewall.@forwarding[-1].dest='wan'
  else
    echo "  lan→wan forward already present (direct path OK)"
  fi
  uci commit firewall 2>/dev/null || true

  log "4/5 reload network + firewall (dnsmasq left alone — shared state)"
  /etc/init.d/network reload 2>/dev/null || true
  /etc/init.d/firewall restart 2>/dev/null || true

  log "5/5 report"
  echo
  echo "=== purge report ==="
  echo "REMOVED (TT product — required so traffic is not stuck/fail-closed):"
  echo "  - services ${INIT}, ${GUARD_INIT}; binary symlink ${BIN}, versioned client binaries"
  echo "  - independent PBR/kill switch, hotplug ${HOTPLUG}, direct policy/config ${TT_DIR}/"
  echo "  - ip rule prio ${MARK_PRIO}, tun0, sysctl 99-moreprivate_tt_client-ipv6.conf"
  echo "  - UCI network.moreprivate_tt_client, firewall.moreprivate_tt_client, moreprivate_tt_client_icmp_reply, lan_moreprivate_tt_client, moreprivate_tt_client_lan_wan"
  echo
  echo "DIRECT PATH:"
  if [ "$has_lan_wan" = 0 ]; then
    echo "  - added stock lan→wan forwarding (none was present)"
  else
    echo "  - left existing shared lan→wan forwarding"
  fi
  echo
  echo "UNTOUCHED shared state (install may have changed these — review/fix if you care):"
  echo "  - DNS dnsmasq:"
  echo "      server=$(uci -q get dhcp.@dnsmasq[0].server 2>/dev/null | tr '\n' ' ')"
  echo "      noresolv=$(uci -q get dhcp.@dnsmasq[0].noresolv 2>/dev/null || echo unset)"
  echo "      strictorder=$(uci -q get dhcp.@dnsmasq[0].strictorder 2>/dev/null || echo unset)"
  echo "      rebind_domain=$(uci -q get dhcp.@dnsmasq[0].rebind_domain 2>/dev/null | tr '\n' ' ')"
  echo "  - IPv6 UCI (not flipped by purge):"
  echo "      wan6.disabled=$(uci -q get network.wan6.disabled 2>/dev/null || echo unset)"
  echo "      dhcp.lan dhcpv6/ra/ndp=$(uci -q get dhcp.lan.dhcpv6 2>/dev/null || echo unset)/$(uci -q get dhcp.lan.ra 2>/dev/null || echo unset)/$(uci -q get dhcp.lan.ndp 2>/dev/null || echo unset)"
  echo "  - apk packages"
  echo
  echo "LEFTOVER scan (TT product must be gone or internet/split may still break):"
  for f in "$INIT" "$GUARD_INIT" "$BIN" "$PBR_NFT" "$HOTPLUG"; do
    if [ -e "$f" ]; then
      echo "  FAIL  still exists: $f"; left=$((left + 1))
    else
      echo "  ok    gone $f"
    fi
  done
  if find /usr/bin -maxdepth 1 -type f -name 'tt-client-*-linux-*' \
    | grep -q .; then
    echo "  FAIL  versioned client binaries remain"; left=$((left + 1))
  else
    echo "  ok    versioned client binaries gone"
  fi
  if [ -e "$TT_DIR" ]; then
    echo "  FAIL  still exists: $TT_DIR"; left=$((left + 1))
  else
    echo "  ok    gone $TT_DIR"
  fi
  if [ -f /etc/sysctl.d/99-moreprivate_tt_client-ipv6.conf ]; then
    echo "  FAIL  sysctl drop-in still present"; left=$((left + 1))
  else
    echo "  ok    sysctl drop-in gone"
  fi
  if ip rule show 2>/dev/null | grep -q "${MARK_PRIO}:.*${MARK}"; then
    echo "  FAIL  mark rule prio ${MARK_PRIO} still present"; left=$((left + 1))
  else
    echo "  ok    mark rule gone"
  fi
  if nft list table inet moreprivate_tt_client >/dev/null 2>&1; then
    echo "  FAIL  independent nft kill-switch table remains"; left=$((left + 1))
  else
    echo "  ok    independent nft kill-switch table gone"
  fi
  if uci -q get network.moreprivate_tt_client >/dev/null 2>&1; then
    echo "  FAIL  network.moreprivate_tt_client still set"; left=$((left + 1))
  else
    echo "  ok    network.moreprivate_tt_client gone"
  fi
  if uci -q get firewall.moreprivate_tt_client >/dev/null 2>&1 \
    || uci -q get firewall.moreprivate_tt_client_icmp_reply >/dev/null 2>&1 \
    || uci -q get firewall.lan_moreprivate_tt_client >/dev/null 2>&1 \
    || uci -q get firewall.moreprivate_tt_client_lan_wan >/dev/null 2>&1; then
    echo "  FAIL  TT firewall zone/forward still set"; left=$((left + 1))
  else
    echo "  ok    TT firewall zone/forward gone"
  fi
  if nft list set inet moreprivate_tt_client tt_direct4 >/dev/null 2>&1; then
    echo "  FAIL  nft tt_direct4 still loaded (PBR not cleared?)"; left=$((left + 1))
  else
    echo "  ok    tt_direct4 not loaded"
  fi
  if nft list set inet moreprivate_tt_client tt_direct_dns4 >/dev/null 2>&1; then
    echo "  FAIL  nft tt_direct_dns4 still loaded (PBR not cleared?)"; left=$((left + 1))
  else
    echo "  ok    tt_direct_dns4 not loaded"
  fi
  has_lan_wan=0
  for s in $(uci show firewall 2>/dev/null | sed -n 's/^\(firewall\.[^=]*\)=forwarding$/\1/p'); do
    [ "$(uci -q get "$s.src" 2>/dev/null)" = "lan" ] || continue
    [ "$(uci -q get "$s.dest" 2>/dev/null)" = "wan" ] || continue
    has_lan_wan=1
    break
  done
  if [ "$has_lan_wan" = 0 ]; then
    echo "  FAIL  no lan→wan forward (LAN may have no internet)"; left=$((left + 1))
  else
    echo "  ok    lan→wan forward present (direct)"
  fi
  if client_running; then
    echo "  FAIL  tt-client still running"; left=$((left + 1))
  else
    echo "  ok    no client process"
  fi
  if ip link show tun0 >/dev/null 2>&1; then
    echo "  FAIL  tun0 still exists"; left=$((left + 1))
  else
    echo "  ok    no tun0"
  fi
  echo
  if [ "$left" -ne 0 ]; then
    echo "status: purge incomplete (${left} leftover FAIL) — router may still be broken"
    return 1
  fi
  echo "OK purge — TT routing/direct policy/fail-closed gone; traffic should be direct WAN"
  echo "  review UNTOUCHED shared state above if you want stock DNS/IPv6 UCI"
}

main() {
  cmd="${1:-help}"
  [ $# -gt 0 ] && shift
  announce_start
  case "$cmd" in
    help|-h|--help) usage; exit 0 ;;
  esac
  need_root
  case "$cmd" in
    install)      cmd_install "$@" ;;
    upgrade)      cmd_upgrade "$@" ;;
    update-creds) cmd_update_creds "$@" ;;
    update-direct) cmd_update_direct "$@" ;;
    direct-enable) cmd_direct_enable "$@" ;;
    direct-disable) cmd_direct_disable "$@" ;;
    disable)      cmd_disable "$@" ;;
    enable)       cmd_enable "$@" ;;
    restart)      cmd_restart "$@" ;;
    rollback)     cmd_rollback "$@" ;;
    status)       cmd_status "$@" ;;
    tun-shape)    cmd_tun_shape "$@" ;;
    tun-shape-disable) cmd_tun_shape_disable "$@" ;;
    wan-shape)    cmd_wan_shape "$@" ;;
    wan-shape-disable) cmd_wan_shape_disable "$@" ;;
    purge)        cmd_purge "$@" ;;
    *) usage; die "unknown command: $cmd" ;;
  esac
}

main "$@"
