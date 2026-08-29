#!/bin/sh
# tt-client-linux.sh — MorePrivate tt-client manager for the current Linux machine.
# Local-machine only: no UCI, netifd, LAN forwarding, or router state.
set -eu

VERSION_SCRIPT="0.1.4"
TT_DIR="/etc/moreprivate/tt-client"
CLIENT_TOML="${TT_DIR}/client.toml"
DIRECT_CONF="${TT_DIR}/direct.conf"
RELEASE_META="${TT_DIR}/release.env"
RESOLV_BACKUP="${TT_DIR}/resolv.conf.original"
RESOLV_CONF="/etc/resolv.conf"
RESOLVED_STATE="${TT_DIR}/resolved.state"
HOST_DNS_STATE="${TT_DIR}/dns-takeover.state"
NM_DNS_CONF="/etc/NetworkManager/conf.d/moreprivate-tt-client.conf"
HOST_DNS_UNITS="systemd-resolved.service dnsmasq.service unbound.service named.service bind9.service"
DNSMASQ_CONF="${TT_DIR}/dnsmasq.conf"
DNSMASQ_PID="${TT_DIR}/dnsmasq.pid"
POLICY="/usr/local/libexec/moreprivate-tt-client-policy"
BIN="/usr/local/bin/tt-client"
INIT="/etc/systemd/system/moreprivate-tt-client-linux.service"
GUARD_INIT="/etc/systemd/system/tt-client-guard.service"
DNSMASQ_INIT="/etc/systemd/system/moreprivate-tt-dnsmasq.service"
SERVICE_NAME="moreprivate-tt-client-linux"
GUARD_SERVICE_NAME="tt-client-guard"
DNSMASQ_SERVICE_NAME="moreprivate-tt-dnsmasq"
DNSMASQ_BIN=""
GITHUB_REPO="${TT_GITHUB_REPO:-moreprivate/tt-client}"
MARK="0x8802"
MARK_PRIO="20000"
TUN_TABLE="880"
TUNNEL_DNS_SERVERS_DEFAULT="1.1.1.1 1.0.0.1"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
# One line at process start for every command: name, script version, UTC time.
announce_start() {
  echo "${0##*/} ${VERSION_SCRIPT}  $(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
}
need_file() { [ -f "$1" ] || die "not found: $1"; }
normalize_list() { printf '%s\n' "$1" | tr ',\t\r\n' '    ' | tr -s ' ' | sed 's/^ //;s/ $//'; }
is_ipv4() { echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0} {exit 1}'; }
toml_get_str() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }

usage() {
  cat <<EOF
NAME
    tt-client-linux.sh ${VERSION_SCRIPT} — MorePrivate tt-client on the current Linux host

SYNOPSIS
    $0 install --config FILE [--binary PATH | --version TAG]
    $0 upgrade [--binary PATH | --version TAG]
    $0 update-creds --config FILE
    $0 enable | disable | rollback | status | purge

DESCRIPTION
    All local IPv4 traffic is fail-closed into MorePrivate tt-client. Only the configured
    endpoint TCP address and port use the ordinary uplink. No LAN forwarding,
    router firewall, or OpenWrt state is touched. A dedicated dnsmasq instance
    owns 127.0.0.1:53 and forwards DNS through the tunnel. systemd-resolved and
    any other host resolver on UDP/53 are stopped so NSS cannot bypass that
    listener.
    LIST values accept commas or whitespace. Config: upstream_protocol auto|http2|http3
    (profiles from add-user default to http3). status reports live H2/H3 via ss.

    install/upgrade: --binary PATH or --version TAG (same as server/OpenWrt).
    Releases from ${GITHUB_REPO}; checksums and embedded binary version verified.

    install is clean-only. Use upgrade for an installed host, rollback to switch
    to the previous successful binary, and enable/disable for tunnel service
    control. On Linux, disable stops the tunnel but leaves fail-closed routing
    active, effectively disabling Internet access. Use purge to remove
    TT-owned files and restore ordinary routing.
EOF
}

parse_vps_ip() {
  local f="$1" ip
  ip="$(sed -n 's/.*addresses[[:space:]]*=[[:space:]]*\[.*"\([0-9][0-9.]*\):[0-9][0-9]*".*/\1/p' "$f" | head -1)"
  [ -n "$ip" ] || ip="$(sed -n 's/^hostname[[:space:]]*=[[:space:]]*"\([0-9][0-9.]*\)".*/\1/p' "$f" | head -1)"
  is_ipv4 "$ip" || return 1
  echo "$ip"
}

parse_vps_port() {
  local p
  p="$(sed -n 's/.*addresses[[:space:]]*=[[:space:]]*\[.*"[0-9][0-9.]*:\([0-9][0-9]*\)".*/\1/p' "$1" | head -1)"
  echo "$p" | grep -qE '^[0-9]+$' && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
  echo "$p"
}

http_fetch() {
  if command -v curl >/dev/null 2>&1; then curl -fsSL --max-time 120 -o "$2" "$1" && return 0; fi
  if command -v wget >/dev/null 2>&1; then wget -q -O "$2" "$1" && return 0; fi
  return 1
}

release_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo x86_64;;
    aarch64|arm64) echo aarch64;;
    mipsel*) echo mipsel;;
    *) die "unsupported Linux architecture: $(uname -m); use --binary FILE";;
  esac
}

latest_tag() {
  local f="${TT_DIR}/latest.$$" tag
  mkdir -p "$TT_DIR"
  http_fetch "https://api.github.com/repos/${GITHUB_REPO}/releases/latest" "$f" \
    || die "cannot query latest release"
  tag="$(sed -n 's/.*"tag_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$f" | head -1)"
  rm -f "$f"
  [ -n "$tag" ] || die "latest release has no tag_name"
  echo "$tag"
}

download_binary() {
  local tag="$1" arch asset stage expect got actual
  echo "$tag" | grep -qE '^[A-Za-z0-9._-]+$' || die "invalid release tag: $tag"
  arch="$(release_arch)"; asset="tt-client-${tag}-linux-${arch}"
  stage="${TT_DIR}/download.$$"; mkdir -p "$stage"
  log "download https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}" >&2
  http_fetch "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}" "$stage/$asset" \
    || { rm -rf "$stage"; die "binary download failed"; }
  http_fetch "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}.sha256" "$stage/$asset.sha256" \
    || { rm -rf "$stage"; die "checksum download failed"; }
  expect="$(awk '{print $1; exit}' "$stage/$asset.sha256")"; got="$(sha256sum "$stage/$asset" | awk '{print $1}')"
  [ "$expect" = "$got" ] || { rm -rf "$stage"; die "binary checksum mismatch"; }
  chmod 755 "$stage/$asset"
  actual="$($stage/$asset --version 2>/dev/null)" || { rm -rf "$stage"; die "downloaded binary is not runnable"; }
  embedded="$(printf '%s\n' "$actual" | awk '{print $NF}')"
  echo "$embedded" | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$' \
    || { rm -rf "$stage"; die "downloaded client reported invalid embedded version: $actual"; }
  echo "$tag" | grep -qE '^[0-9]{8}T[0-9]{6}Z-[0-9a-fA-F]{12}$' \
    || { rm -rf "$stage"; die "invalid release tag format: $tag"; }
  [ "$embedded" = "$tag" ] \
    || { rm -rf "$stage"; die "embedded version '$embedded' does not match release tag '$tag'"; }
  log "embedded client version: $embedded" >&2
  echo "$stage/$asset"
}

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

binary_target() {
  printf '/usr/local/bin/%s' "$(basename "$1")"
}

install_binary() {
  local src="$1" tag="$2" target
  need_file "$src"; [ -s "$src" ] || die "binary is empty"
  target="$(binary_target "$src")"
  case "$(basename "$src")" in
    "tt-client-${tag}-linux-"*) ;;
    *) die "binary filename does not match its release tag: $(basename "$src")" ;;
  esac
  if [ -e "$target" ]; then
    [ "$(sha256sum "$src" | awk '{print $1}')" = "$(sha256sum "$target" | awk '{print $1}')" ] || die "binary collision: $target"
  else
    cp "$src" "$target"; chmod 755 "$target"
  fi
  "$target" --version >/dev/null 2>&1 || die "binary is not runnable: $target"
  ln -sfn "$(basename "$target")" "$BIN"
  echo "  $($target --version 2>/dev/null)"
}

save_meta() {
  local source="$1" tag="$2" tmp="${RELEASE_META}.new.$$"
  printf 'RELEASE_SOURCE=%s\nRELEASE_TAG=%s\nBINARY_SHA256=%s\n' "$source" "$tag" "$(sha256sum "$BIN" | awk '{print $1}')" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$RELEASE_META"
}

client_pids() {
  local proc_path="" process_exe="" found=1

  [ -d /proc/1 ] || return 127
  for proc_path in /proc/[0-9]*; do
    [ -d "$proc_path" ] || continue
    process_exe="$(readlink "$proc_path/exe" 2>/dev/null)" || continue
    process_exe="${process_exe% (deleted)}"
    case "$process_exe" in
      "$BIN"|/usr/local/bin/tt-client-*-linux-*)
        printf '%s\n' "${proc_path##*/}"
        found=0
        ;;
    esac
  done
  return "$found"
}

write_client_config() {
  local src="$1" tmp="${CLIENT_TOML}.new.$$" protocol=""
  need_file "$src"; parse_vps_ip "$src" >/dev/null || die "config has no IPv4 endpoint address"; parse_vps_port "$src" >/dev/null || die "config has no endpoint port"
  protocol="$(toml_get_str upstream_protocol "$src" 2>/dev/null || true)"
  [ "$protocol" = auto ] || [ "$protocol" = http2 ] || [ "$protocol" = http3 ] \
    || die 'config must use upstream_protocol = "auto", "http2", or "http3"'
  cp "$src" "$tmp"
  if grep -qE '^exclusions[[:space:]]*=' "$tmp"; then sed -i 's/^exclusions[[:space:]]*=.*/exclusions = []/' "$tmp"; else printf '\nexclusions = []\n' >>"$tmp"; fi
  # The manager owns the host resolver via a dedicated dnsmasq instance.  Do
  # not let tt-client rewrite resolv.conf or race the manager's listener.
  if grep -qE '^change_system_dns[[:space:]]*=' "$tmp"; then sed -i 's/^change_system_dns[[:space:]]*=.*/change_system_dns = false/' "$tmp"; else printf '\nchange_system_dns = false\n' >>"$tmp"; fi
  chmod 600 "$tmp"; mv -f "$tmp" "$CLIENT_TOML"
}

port53_lines() {
  ss -ulnp 2>/dev/null | awk '$0 ~ /[.:]53([ \t]|$)/ {print}'
}

port53_busy() {
  port53_lines | grep -Eq '(^|[[:space:]])([0-9.]+:53|\[::\]:53|\*:53|:::53)[[:space:]]'
}

nm_reload() {
  if command -v nmcli >/dev/null 2>&1; then
    nmcli general reload >/dev/null 2>&1 || true
  fi
  systemctl reload NetworkManager.service >/dev/null 2>&1 || true
}

record_dns_unit() {
  local unit="$1" active enabled
  [ -f "$HOST_DNS_STATE" ] || : >"$HOST_DNS_STATE"
  awk -v u="$unit" '$1=="UNIT" && $2==u {found=1} END{exit found?0:1}' "$HOST_DNS_STATE" 2>/dev/null && return 0
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  printf 'UNIT %s %s %s\n' "$unit" "$active" "$enabled" >>"$HOST_DNS_STATE"
}

stop_foreign_dnsmasq() {
  local pid="" exe="" our=""
  our="$(systemctl show -p MainPID --value "$DNSMASQ_SERVICE_NAME.service" 2>/dev/null || true)"
  for pid in $(port53_lines | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p'); do
    [ -n "$pid" ] || continue
    [ "$pid" = "${our:-0}" ] && continue
    exe="$(readlink "/proc/${pid}/exe" 2>/dev/null || true)"
    exe="${exe% (deleted)}"
    case "$exe" in
      */dnsmasq)
        kill "$pid" 2>/dev/null || true
        ;;
    esac
  done
}

stop_host_dns_unit() {
  local unit="$1" enabled=""
  systemctl cat "$unit" >/dev/null 2>&1 || return 0
  record_dns_unit "$unit"
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [ "$unit" = systemd-resolved.service ]; then
    if [ "$enabled" != masked ]; then
      systemctl disable --now "$unit" >/dev/null 2>&1 || true
      systemctl mask "$unit" >/dev/null 2>&1 || true
    else
      systemctl stop "$unit" >/dev/null 2>&1 || true
    fi
    return 0
  fi
  systemctl stop "$unit" >/dev/null 2>&1 || true
  if [ "$enabled" != masked ]; then
    systemctl disable "$unit" >/dev/null 2>&1 || true
  fi
}

takeover_host_dns() {
  local unit="" i=0
  if [ -d /etc/NetworkManager/conf.d ]; then
    printf '%s\n' '[main]' 'dns=none' 'rc-manager=unmanaged' >"$NM_DNS_CONF"
    [ -f "$HOST_DNS_STATE" ] || : >"$HOST_DNS_STATE"
    grep -q '^NM_TOUCHED=' "$HOST_DNS_STATE" 2>/dev/null || printf 'NM_TOUCHED=1\n' >>"$HOST_DNS_STATE"
    nm_reload
  fi
  for unit in $HOST_DNS_UNITS; do
    stop_host_dns_unit "$unit"
  done
  stop_foreign_dnsmasq
  if command -v nscd >/dev/null 2>&1; then
    nscd -i hosts >/dev/null 2>&1 || true
  fi
  chmod 600 "$HOST_DNS_STATE" 2>/dev/null || true
  while port53_busy && [ "$i" -lt 8 ]; do
    stop_foreign_dnsmasq
    i=$((i+1)); sleep 1
  done
}

configure_resolver() {
  local tmp="${RESOLV_CONF}.moreprivate.$$"
  [ -e "$RESOLV_BACKUP" ] || cp -a "$RESOLV_CONF" "$RESOLV_BACKUP" 2>/dev/null || true
  # Stop other resolvers before replacing resolv.conf: systemd-resolved stop
  # hooks may restore the stub symlink, and a host dnsmasq on *:53 will
  # prevent the managed listener from binding 127.0.0.1:53.
  takeover_host_dns
  printf '%s\n' '# Managed by MorePrivate tt-client; restored on purge' \
    'nameserver 127.0.0.1' \
    'options timeout:2 attempts:2' >"$tmp"
  chmod 644 "$tmp"
  rm -f "$RESOLV_CONF"
  mv -f "$tmp" "$RESOLV_CONF"
  if port53_busy; then
    echo "error: UDP port 53 is already in use:" >&2
    port53_lines >&2 || true
    die "cannot bind the managed resolver on 127.0.0.1:53"
  fi
}

write_dnsmasq() {
  local srv=""
  DNSMASQ_BIN="$(command -v dnsmasq 2>/dev/null || true)"
  [ -n "$DNSMASQ_BIN" ] || die "dnsmasq is required for the Linux host resolver"
  {
    printf '%s\n' \
      'listen-address=127.0.0.1' \
      'bind-interfaces' \
      'interface=lo' \
      'no-resolv' \
      'no-hosts'
    for srv in $TUNNEL_DNS_SERVERS_DEFAULT; do
      printf 'server=%s\n' "$srv"
    done
    printf 'pid-file=%s\n' "$DNSMASQ_PID"
  } >"$DNSMASQ_CONF"
  chmod 600 "$DNSMASQ_CONF"
}

restore_resolver() {
  [ -e "$RESOLV_BACKUP" ] && mv -f "$RESOLV_BACKUP" "$RESOLV_CONF" || true
}

restore_host_dns() {
  local kind unit active enabled
  rm -f "$NM_DNS_CONF"
  if [ -f "$HOST_DNS_STATE" ]; then
    while read -r kind unit active enabled; do
      case "$kind" in
        UNIT)
          [ -n "$unit" ] || continue
          if [ "$unit" = systemd-resolved.service ] && [ "${enabled:-}" != masked ]; then
            systemctl unmask "$unit" >/dev/null 2>&1 || true
          fi
          case "${enabled:-}" in
            enabled|enabled-runtime) systemctl enable "$unit" >/dev/null 2>&1 || true ;;
          esac
          case "${active:-}" in
            active|activating) systemctl start "$unit" >/dev/null 2>&1 || true ;;
          esac
          ;;
        NM_TOUCHED=*)
          nm_reload
          ;;
      esac
    done <"$HOST_DNS_STATE"
    rm -f "$HOST_DNS_STATE"
  fi
  if [ -f "$RESOLVED_STATE" ]; then
    RESOLVED_ACTIVE=""
    RESOLVED_ENABLED=""
    # Saved as KEY=value lines written by this script (0.1.3 leftover).
    # shellcheck disable=SC1090
    . "$RESOLVED_STATE"
    if [ "${RESOLVED_ENABLED:-}" != masked ]; then
      systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    fi
    case "${RESOLVED_ENABLED:-}" in
      enabled|enabled-runtime) systemctl enable systemd-resolved.service >/dev/null 2>&1 || true ;;
    esac
    case "${RESOLVED_ACTIVE:-}" in
      active|activating) systemctl start systemd-resolved.service >/dev/null 2>&1 || true ;;
    esac
    rm -f "$RESOLVED_STATE"
  fi
  restore_resolver
}

write_policy() {
  local vps="$1" port="$2" uplink="$3"
  cat >"$POLICY" <<EOF
#!/bin/sh
set -eu
VPS_IP="$vps"; ENDPOINT_PORT="$port"; UPLINK="$uplink"; MARK="$MARK"; PRIO="$MARK_PRIO"; TABLE="$TUN_TABLE"
mode="\${1:-start}"
case "\$mode" in
  start|full)
    nft -f - <<NFT
destroy table inet moreprivate_tt_client
table inet moreprivate_tt_client {
 chain output_mark { type route hook output priority mangle; policy accept;
   ip protocol tcp ip daddr \$VPS_IP tcp dport \$ENDPOINT_PORT meta mark set \$MARK
   ip protocol udp ip daddr \$VPS_IP udp dport \$ENDPOINT_PORT meta mark set \$MARK
 }
 chain output_guard { type filter hook output priority filter - 1; policy accept;
   oifname "lo" accept
   ip daddr 127.0.0.0/8 accept
   ip6 daddr ::1 accept
   oifname != "tun0" ip protocol tcp ip daddr \$VPS_IP tcp dport \$ENDPOINT_PORT accept
   oifname != "tun0" ip protocol udp ip daddr \$VPS_IP udp dport \$ENDPOINT_PORT accept
   oifname != "tun0" counter reject
 }
}
NFT
    while ip rule del priority "\$PRIO" 2>/dev/null; do :; done
    ip rule add priority "\$PRIO" fwmark "\$MARK/0xffffffff" lookup main
    # Keep the kernel's existing endpoint route (including its gateway). A
    # A synthetic dev UPLINK /32 can incorrectly ARP for a remote VPS.
    ip rule del priority $((MARK_PRIO + 1)) 2>/dev/null || true
    ip rule add priority $((MARK_PRIO + 1)) unreachable
    if [ "\$mode" = full ] && ip link show tun0 >/dev/null 2>&1; then
      tun_src="\$(ip -4 -o addr show dev tun0 2>/dev/null | awk '{print \$4; exit}' | cut -d/ -f1)"
      if [ -n "\$tun_src" ]; then
        ip route replace default dev tun0 src "\$tun_src" table "\$TABLE"
      else
        ip route replace default dev tun0 table "\$TABLE"
      fi
      ip rule del priority $((MARK_PRIO + 1)) 2>/dev/null || true
      ip rule add priority $((MARK_PRIO + 1)) lookup "\$TABLE"
    fi
    ip route flush cache 2>/dev/null || true
    ;;
  stop)
    nft delete table inet moreprivate_tt_client 2>/dev/null || true
    ip rule del priority "\$PRIO" 2>/dev/null || true
    ip rule del priority $((MARK_PRIO + 1)) 2>/dev/null || true
    ip route flush table "\$TABLE" 2>/dev/null || true
    ;;
  *) exit 2;;
esac
EOF
  chmod 755 "$POLICY"
}

write_units() {
  cat >"$INIT" <<EOF
[Unit]
Description=MorePrivate tt-client local client
After=network-online.target tt-client-guard.service
Wants=network-online.target
Requires=tt-client-guard.service

[Service]
Type=simple
ExecStartPre=$POLICY start
ExecStart=$BIN -c $CLIENT_TOML
ExecStartPost=$POLICY full
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW CAP_NET_BIND_SERVICE
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  cat >"$GUARD_INIT" <<EOF
[Unit]
Description=MorePrivate tt-client local fail-closed policy
Before=$SERVICE_NAME.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$POLICY start
ExecStop=$POLICY stop
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_RAW
NoNewPrivileges=true

[Install]
WantedBy=multi-user.target
EOF
  cat >"$DNSMASQ_INIT" <<EOF
[Unit]
Description=MorePrivate local DNS forwarder
After=$SERVICE_NAME.service
Requires=$SERVICE_NAME.service
Conflicts=systemd-resolved.service dnsmasq.service unbound.service named.service bind9.service

[Service]
Type=simple
ExecStart=$DNSMASQ_BIN --keep-in-foreground --conf-file=$DNSMASQ_CONF
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$INIT" "$GUARD_INIT" "$DNSMASQ_INIT"
}

uplink_dev() { ip route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
wait_tunnel() {
  local i=0
  while [ "$i" -lt 20 ]; do ip link show tun0 >/dev/null 2>&1 && return 0; i=$((i+1)); sleep 2; done
  return 1
}

# Query the managed 127.0.0.1 resolver directly. getent/NSS often hits
# systemd-resolved (127.0.0.53) and never reaches dnsmasq.
lookup_tunnel_dns() {
  local name="$1" out=""
  if command -v python3 >/dev/null 2>&1; then
    out="$(NAME="$name" timeout 4s python3 - <<'PY' 2>/dev/null || true
import os, socket, struct, sys
name = os.environ.get("NAME", "")
def encode(n):
    out = b""
    for lab in n.strip(".").split("."):
        b = lab.encode("idna")
        out += bytes([len(b)]) + b
    return out + b"\x00"
q = b"\x12\x34\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00" + encode(name) + b"\x00\x01\x00\x01"
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(q, ("127.0.0.1", 53))
data, _ = s.recvfrom(4096)
if len(data) < 12:
    sys.exit(1)
if (data[3] & 0x0F) != 0 or struct.unpack("!H", data[6:8])[0] < 1:
    sys.exit(1)
i = 12
while i < len(data) and data[i]:
    if data[i] & 0xC0 == 0xC0:
        i += 2
        break
    i += 1 + data[i]
else:
    i += 1
i += 4
anc = struct.unpack("!H", data[6:8])[0]
for _ in range(anc):
    if i >= len(data):
        sys.exit(1)
    if data[i] & 0xC0 == 0xC0:
        i += 2
    else:
        while i < len(data) and data[i]:
            i += 1 + data[i]
        i += 1
    if i + 10 > len(data):
        sys.exit(1)
    typ, _cls, _ttl, rdlen = struct.unpack("!HHIH", data[i:i + 10])
    i += 10
    if typ == 1 and rdlen == 4:
        print(socket.inet_ntoa(data[i:i + 4]))
        sys.exit(0)
    i += rdlen
sys.exit(1)
PY
)"
    [ -n "$out" ] && { echo "$out"; return 0; }
  fi
  if command -v dig >/dev/null 2>&1; then
    out="$(timeout 4s dig +time=2 +tries=1 +short A "$name" @127.0.0.1 2>/dev/null | awk '/^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/{print; exit}')" || true
    [ -n "$out" ] && { echo "$out"; return 0; }
  fi
  if command -v nslookup >/dev/null 2>&1; then
    out="$(timeout 4s nslookup "$name" 127.0.0.1 2>/dev/null | awk '/^Name:/{n=1; next} n && /Address/{print $NF; exit}')" || true
    echo "$out" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' || out=""
    [ -n "$out" ] && { echo "$out"; return 0; }
  fi
  out="$(timeout 4s getent ahostsv4 "$name" 2>/dev/null | awk '/^[0-9]+\./{print $1; exit}')" || true
  [ -n "$out" ] && { echo "$out"; return 0; }
  return 1
}

dns_debug() {
  echo "  dns debug: resolv.conf=$(tr '\n' ' ' <"$RESOLV_CONF" 2>/dev/null)" >&2
  echo "  dns debug: systemd-resolved=$(systemctl is-active systemd-resolved.service 2>/dev/null || true) dnsmasq=$(systemctl is-active "$DNSMASQ_SERVICE_NAME.service" 2>/dev/null || true)" >&2
  echo "  dns debug: route 1.1.1.1=$(ip route get 1.1.1.1 2>/dev/null | tr '\n' ' ')" >&2
  ss -ulnp 2>/dev/null | awk '/:53 /{print "  dns debug: listen "$0}' >&2 || true
  journalctl -u "$DNSMASQ_SERVICE_NAME.service" -n 20 --no-pager >&2 || true
}

verify() {
  local vps="$1" route dns_route dns numeric_ip hostname_ip
  ip link show tun0 >/dev/null 2>&1 || die "tun0 is not present"
  route="$(ip route get "$vps" 2>/dev/null)"
  echo "$route" | grep -q 'dev tun0' || die "endpoint non-marked traffic is not routed through tun0: $route"
  dns_route="$(ip route get 1.1.1.1 2>/dev/null)"
  echo "$dns_route" | grep -q 'dev tun0' || die "tunnel DNS server 1.1.1.1 is not routed through tun0: $dns_route"
  echo "  check DNS resolution"
  dns=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    dns="$(lookup_tunnel_dns google.com || true)"
    [ -n "$dns" ] && break
    sleep 1
  done
  if [ -z "$dns" ]; then
    dns_debug
    die "DNS validation failed: google.com cannot be resolved through the tunnel"
  fi
  echo "  dns: ok ($dns)"
  command -v curl >/dev/null 2>&1 || die "curl is required for egress validation"
  echo "  check numeric Cloudflare egress"
  numeric_ip="$(timeout 25s curl -4fsSL --max-time 20 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)"
  echo "  check hostname Cloudflare egress"
  hostname_ip="$(timeout 25s curl -4fsSL --max-time 20 https://cloudflare.com/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)"
  [ -n "$numeric_ip" ] || die "numeric egress validation failed"
  [ -n "$hostname_ip" ] || die "hostname egress validation failed"
  [ "$numeric_ip" = "$vps" ] || die "numeric egress IP $numeric_ip does not match VPS_IP $vps"
  [ "$hostname_ip" = "$vps" ] || die "hostname egress IP $hostname_ip does not match VPS_IP $vps"
  log "OK tunnel egress: numeric=$numeric_ip hostname=$hostname_ip"
  echo "  route: $route"
}

service_start() {
  systemctl enable "$SERVICE_NAME.service" >/dev/null
  echo "==> start $SERVICE_NAME.service"
  if ! timeout 30s systemctl start "$SERVICE_NAME.service"; then
    echo "error: $SERVICE_NAME.service failed to start" >&2
    systemctl status "$SERVICE_NAME.service" --no-pager -l >&2 || true
    journalctl -u "$SERVICE_NAME.service" -n 40 --no-pager >&2 || true
    return 1
  fi
}
guard_start() {
  systemctl enable "$GUARD_SERVICE_NAME.service" >/dev/null
  echo "==> start $GUARD_SERVICE_NAME.service"
  if ! timeout 30s systemctl start "$GUARD_SERVICE_NAME.service"; then
    echo "error: $GUARD_SERVICE_NAME.service failed to start" >&2
    systemctl status "$GUARD_SERVICE_NAME.service" --no-pager -l >&2 || true
    journalctl -u "$GUARD_SERVICE_NAME.service" -n 40 --no-pager >&2 || true
    return 1
  fi
}
dnsmasq_start() {
  local i=0 state=""
  if port53_busy; then
    echo "error: UDP port 53 is already in use:" >&2
    port53_lines >&2 || true
    echo "error: $DNSMASQ_SERVICE_NAME.service cannot bind 127.0.0.1:53" >&2
    return 1
  fi
  systemctl enable "$DNSMASQ_SERVICE_NAME.service" >/dev/null
  echo "==> start $DNSMASQ_SERVICE_NAME.service"
  if ! timeout 30s systemctl start "$DNSMASQ_SERVICE_NAME.service"; then
    echo "error: $DNSMASQ_SERVICE_NAME.service failed to start (is another service using 127.0.0.1:53?)" >&2
    systemctl status "$DNSMASQ_SERVICE_NAME.service" --no-pager -l >&2 || true
    journalctl -u "$DNSMASQ_SERVICE_NAME.service" -n 40 --no-pager >&2 || true
    return 1
  fi
  while [ "$i" -lt 15 ]; do
    state="$(systemctl is-active "$DNSMASQ_SERVICE_NAME.service" 2>/dev/null || true)"
    if [ "$state" = active ] && command -v ss >/dev/null 2>&1 \
      && ss -uln 2>/dev/null | grep -Eq '(127\.0\.0\.1|0\.0\.0\.0|\*):53[[:space:]]'; then
      return 0
    fi
    if [ "$state" = failed ]; then
      break
    fi
    i=$((i+1)); sleep 1
  done
  echo "error: $DNSMASQ_SERVICE_NAME.service did not become ready on 127.0.0.1:53 (state=${state:-unknown})" >&2
  systemctl status "$DNSMASQ_SERVICE_NAME.service" --no-pager -l >&2 || true
  journalctl -u "$DNSMASQ_SERVICE_NAME.service" -n 40 --no-pager >&2 || true
  port53_lines >&2 || true
  return 1
}
dnsmasq_stop() { systemctl stop "$DNSMASQ_SERVICE_NAME.service" >/dev/null 2>&1 || true; }
service_stop() {
  local pids="" process_status=0
  systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true
  pids="$(client_pids)" || process_status=$?
  case "$process_status" in
    0) die "tt-client did not stop (pid $(printf '%s' "$pids" | tr '\n' ' '))" ;;
    1) return 0 ;;
    *) die "cannot verify that tt-client stopped (process check status ${process_status})" ;;
  esac
}
service_restart() { systemctl restart "$SERVICE_NAME.service"; }

upgrade_rollback() {
  local rc="$?"
  if [ "$rc" -ne 0 ] && [ -n "${OLD_BIN:-}" ] && [ -x "$OLD_BIN" ]; then
    service_stop
    ln -sfn "$(basename "$OLD_BIN")" "$BIN"
    systemctl start "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    [ -z "${NEW_BIN:-}" ] || [ "$NEW_BIN" = "$OLD_BIN" ] || rm -f "$NEW_BIN"
    echo "WARNING: upgrade failed; restored $(basename "$OLD_BIN")" >&2
  fi
  exit "$rc"
}

cmd_install() {
  local config="" binary="" tag="" src source vps port uplink
  while [ "$#" -gt 0 ]; do case "$1" in --config) config="$2"; shift 2;; --binary) binary="$2"; shift 2;; --version) tag="$2"; shift 2;; *) die "unknown install option: $1";; esac; done
  [ -n "$config" ] || die "install requires --config FILE"; [ ! -e "$CLIENT_TOML" ] || die "already installed; use upgrade or purge"
  trap 'rc=$?; if [ "$rc" -ne 0 ]; then dnsmasq_stop; systemctl stop "$SERVICE_NAME.service" >/dev/null 2>&1 || true; systemctl disable "$SERVICE_NAME.service" "$GUARD_SERVICE_NAME.service" "$DNSMASQ_SERVICE_NAME.service" >/dev/null 2>&1 || true; "$POLICY" stop >/dev/null 2>&1 || true; restore_host_dns; rm -f "$INIT" "$GUARD_INIT" "$DNSMASQ_INIT" "$DNSMASQ_CONF" "$DNSMASQ_PID" "$POLICY" "$CLIENT_TOML" "$DIRECT_CONF" "$RELEASE_META" "$BIN"; rm -f /usr/local/bin/tt-client-*-linux-*; systemctl daemon-reload >/dev/null 2>&1 || true; fi; exit "$rc"' EXIT
  need_file "$config"; mkdir -p "$TT_DIR" /usr/local/libexec
  vps="$(parse_vps_ip "$config")"; port="$(parse_vps_port "$config")"; uplink="$(uplink_dev "$vps")"; [ -n "$uplink" ] || die "cannot determine uplink for endpoint"
  # Resolve/download a release while the host resolver is still intact.  The
  # managed 127.0.0.1 resolver is installed only after this step; dnsmasq is
  # not started until the service has been prepared below.
  if [ -n "$binary" ]; then src="$binary"; source=local; tag="${tag:-$(binary_tag_from_file "$binary")}"; else tag="${tag:-$(latest_tag)}"; src="$(download_binary "$tag")"; source="github:${GITHUB_REPO}"; fi
  configure_resolver
  write_client_config "$config"; install_binary "$src" "$tag"; write_policy "$vps" "$port" "$uplink"; write_dnsmasq; write_units; save_meta "$source" "$tag"
  systemctl daemon-reload; guard_start; service_start
  echo "==> wait for tun0"; wait_tunnel || die "MorePrivate tt-client did not create tun0"
  # ExecStartPost may run before tun0 exists; apply the tunnel table now.
  "$POLICY" full
  dnsmasq_start; echo "==> validate DNS and egress"; verify "$vps"; trap - EXIT; log "install complete"
}

cmd_upgrade() {
  local binary="" tag="" src source vps port uplink
  [ -f "$CLIENT_TOML" ] || die "not installed"
  while [ "$#" -gt 0 ]; do case "$1" in --binary) binary="$2"; shift 2;; --version) tag="$2"; shift 2;; *) die "unknown upgrade option: $1";; esac; done
  OLD_BIN="$(readlink -f "$BIN")"; NEW_BIN=""; trap upgrade_rollback EXIT
  vps="$(parse_vps_ip "$CLIENT_TOML")"; port="$(parse_vps_port "$CLIENT_TOML")"; uplink="$(uplink_dev "$vps")"
  if [ -n "$binary" ]; then src="$binary"; source=local; tag="${tag:-$(binary_tag_from_file "$binary")}"; else tag="${tag:-$(latest_tag)}"; src="$(download_binary "$tag")"; source="github:${GITHUB_REPO}"; fi
  service_stop; configure_resolver; install_binary "$src" "$tag"; NEW_BIN="$(readlink -f "$BIN")"; write_policy "$vps" "$port" "$uplink"; write_dnsmasq; write_units; save_meta "$source" "$tag"; systemctl daemon-reload; service_start; wait_tunnel || die "upgrade did not restore tun0"; "$POLICY" full; dnsmasq_start; verify "$vps"; trap - EXIT
}

cmd_update_creds() { local cfg="$2"; [ "$1" = --config ] || die "update-creds requires --config FILE"; write_client_config "$cfg"; service_restart; }
cmd_enable() {
  configure_resolver
  systemctl enable --now "$SERVICE_NAME.service"
  # dnsmasq Requires=$SERVICE_NAME.service and is therefore stopped when the
  # client is disabled; bring it back explicitly so 127.0.0.1 remains live.
  dnsmasq_start
}
cmd_disable() {
  systemctl disable --now "$SERVICE_NAME.service"
}
cmd_rollback() {
  local cur prev
  cur="$(readlink -f "$BIN")"; prev="$(find /usr/local/bin -maxdepth 1 -type f -name 'tt-client-*-linux-*' ! -path "$cur" | head -1)"; [ -n "$prev" ] || die "no previous binary available"; service_stop; ln -sfn "$(basename "$prev")" "$BIN"; service_start
}
cmd_status() {
  local vps="" port="" conf="" tcp_n=0 udp_n=0 active=0
  local enabled_state="" enabled_status=0 active_state="" active_status=0
  echo "=== MorePrivate tt-client Linux status ==="
  [ -L "$BIN" ] && echo "  binary [*] $(readlink -f "$BIN")" || echo "  FAIL binary missing"
  [ -x "$BIN" ] && echo "  product: $($BIN --version 2>/dev/null | head -1 || echo unknown)"
  if [ -f "$CLIENT_TOML" ]; then
    echo "  ok    $CLIENT_TOML"
    conf="$(toml_get_str upstream_protocol "$CLIENT_TOML" 2>/dev/null || true)"
    vps="$(parse_vps_ip "$CLIENT_TOML" 2>/dev/null || true)"
    port="$(parse_vps_port "$CLIENT_TOML" 2>/dev/null || true)"
    [ -n "$conf" ] && echo "  info  upstream_protocol=${conf} (configured)"
    [ -n "$vps" ] && [ -n "$port" ] && echo "  info  endpoint=${vps}:${port}"
  else
    echo "  FAIL config missing"
  fi
  enabled_state="$(systemctl is-enabled "$SERVICE_NAME.service" 2>/dev/null)" || enabled_status=$?
  case "$enabled_state" in
    enabled|enabled-runtime|linked|linked-runtime|alias) echo "  ok    enabled (${enabled_state})" ;;
    disabled|masked|masked-runtime|static|indirect|generated|transient) echo "  warn  not enabled (${enabled_state})" ;;
    not-found) echo "  FAIL unit not found" ;;
    *) echo "  FAIL cannot determine enablement (status ${enabled_status})" ;;
  esac
  active_state="$(systemctl is-active "$SERVICE_NAME.service" 2>/dev/null)" || active_status=$?
  case "$active_state" in
    active) echo "  ok    active"; active=1 ;;
    activating|reloading) echo "  warn  ${active_state}" ;;
    inactive|failed|deactivating) echo "  FAIL ${active_state}" ;;
    unknown) echo "  FAIL unit state unknown" ;;
    *) echo "  FAIL cannot determine activity (status ${active_status})" ;;
  esac
  ip rule show | grep -q "$MARK_PRIO" && echo "  ok    endpoint mark rule" || echo "  FAIL endpoint mark rule"
  ip route show table "$TUN_TABLE" 2>/dev/null | grep -q tun0 && echo "  ok    default route via tun0" || echo "  FAIL tunnel default route"
  grep -q 'nameserver 127.0.0.1' "$RESOLV_CONF" 2>/dev/null && echo "  ok    resolv.conf -> 127.0.0.1" || echo "  FAIL resolv.conf is not the managed resolver"
  if systemctl is-active "$DNSMASQ_SERVICE_NAME.service" >/dev/null 2>&1; then
    echo "  ok    $DNSMASQ_SERVICE_NAME.service"
  else
    echo "  FAIL $DNSMASQ_SERVICE_NAME.service"
  fi
  if systemctl cat systemd-resolved.service >/dev/null 2>&1 && systemctl is-active systemd-resolved.service >/dev/null 2>&1; then
    echo "  warn  systemd-resolved is active (NSS may bypass 127.0.0.1)"
  fi
  if [ "$active" = 1 ] && [ -n "$vps" ] && [ -n "$port" ] && command -v ss >/dev/null 2>&1; then
    tcp_n="$(ss -tn 2>/dev/null | awk -v n="${vps}:${port}" '$1~/ESTAB/ && index($0,n){c++} END{print c+0}')"
    udp_n="$(ss -un 2>/dev/null | awk -v n="${vps}:${port}" '$1~/ESTAB/ && index($0,n){c++} END{print c+0}')"
    if [ "$udp_n" -gt 0 ] && [ "$tcp_n" -gt 0 ]; then
      echo "  ok    live transport: mixed H2+H3 (tcp×${tcp_n} udp×${udp_n})"
    elif [ "$udp_n" -gt 0 ]; then
      echo "  ok    live transport: H3 (udp ESTAB×${udp_n})"
    elif [ "$tcp_n" -gt 0 ]; then
      echo "  ok    live transport: H2 (tcp ESTAB×${tcp_n})"
    else
      echo "  warn  live transport: none (no ESTAB to ${vps}:${port})"
    fi
  elif [ "$active" = 1 ]; then
    echo "  info  live transport: not tested (ss/endpoint missing)"
  fi
}
cmd_purge() { dnsmasq_stop; service_stop; systemctl disable "$SERVICE_NAME.service" "$GUARD_SERVICE_NAME.service" "$DNSMASQ_SERVICE_NAME.service" >/dev/null 2>&1 || true; systemctl daemon-reload; "$POLICY" stop 2>/dev/null || true; restore_host_dns; rm -f "$INIT" "$GUARD_INIT" "$DNSMASQ_INIT" "$DNSMASQ_CONF" "$DNSMASQ_PID" "$POLICY" "$CLIENT_TOML" "$DIRECT_CONF" "$RELEASE_META" "$BIN"; rm -f /usr/local/bin/tt-client-*-linux-*; rmdir "$TT_DIR" 2>/dev/null || true; systemctl daemon-reload; log "purged TT-owned local state"; }

cmd="${1:-help}"
[ "$#" -eq 0 ] || shift
announce_start
case "$cmd" in
  help|-h|--help) usage; exit 0 ;;
esac
need_root
case "$cmd" in
  install) cmd_install "$@";;
  upgrade) cmd_upgrade "$@";;
  update-creds) cmd_update_creds "$@";;
  enable) cmd_enable;;
  disable) cmd_disable;;
  rollback) cmd_rollback;;
  status) cmd_status;;
  purge) cmd_purge;;
  *) die "unknown command: $cmd (run help)";;
esac
