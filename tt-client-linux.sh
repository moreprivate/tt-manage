#!/bin/sh
# tt-client-linux.sh — TrustTunnel manager for the current Linux machine.
# Local-machine only: no UCI, netifd, dnsmasq, LAN forwarding, or router state.
set -eu

VERSION_SCRIPT="0.1.0"
TT_DIR="/etc/trusttunnel"
CLIENT_TOML="${TT_DIR}/client.toml"
DIRECT_CONF="${TT_DIR}/direct.conf"
RELEASE_META="${TT_DIR}/release.env"
POLICY="/usr/local/libexec/trusttunnel-linux-policy"
BIN="/usr/local/bin/trusttunnel_client"
INIT="/etc/systemd/system/trusttunnel.service"
GUARD_INIT="/etc/systemd/system/trusttunnel-guard.service"
GITHUB_REPO="${TT_GITHUB_REPO:-moreprivate/tt-client}"
MARK="0x8802"
MARK_PRIO="20000"
TUN_TABLE="880"
TUNNEL_DNS_SERVERS_DEFAULT="1.1.1.1 1.0.0.1"

die() { echo "error: $*" >&2; exit 1; }
log() { echo "==> $*"; }
need_root() { [ "$(id -u)" = 0 ] || die "run as root"; }
need_file() { [ -f "$1" ] || die "not found: $1"; }
normalize_list() { printf '%s\n' "$1" | tr ',\t\r\n' '    ' | tr -s ' ' | sed 's/^ //;s/ $//'; }
is_ipv4() { echo "$1" | awk -F. 'NF==4 {for(i=1;i<=4;i++) if($i !~ /^[0-9]+$/ || $i>255) exit 1; exit 0} {exit 1}'; }
toml_get_str() { sed -n "s/^$1[[:space:]]*=[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$2" | head -1; }

usage() {
  cat <<EOF
NAME
    tt-client-linux.sh ${VERSION_SCRIPT} — TrustTunnel on the current Linux host

SYNOPSIS
    $0 install --config FILE [--binary FILE | --version TAG]
    $0 upgrade [--binary FILE | --version TAG]
    $0 update-creds --config FILE
    $0 enable | disable | rollback | status | purge

DESCRIPTION
    All local IPv4 traffic is fail-closed into TrustTunnel. Only the configured
    endpoint TCP address and port use the ordinary uplink. No LAN forwarding,
    router firewall, dnsmasq, or OpenWrt state is touched. DNS uses the host's
    existing resolver configuration, but its packets follow the tunnel route.
    LIST values accept commas or whitespace. Config: upstream_protocol auto|http2|http3
    (profiles from add-user default to http3). status reports live H2/H3 via ss.

    --binary FILE and --version TAG are accepted by install/upgrade. Releases
    come from ${GITHUB_REPO}; checksums and the embedded binary version are verified.

    install is clean-only. Use upgrade for an installed host, rollback to switch
    to the previous successful binary, disable/enable for service control, and
    purge to remove TT-owned files and restore ordinary routing.
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
  log "download https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}"
  http_fetch "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}" "$stage/$asset" \
    || { rm -rf "$stage"; die "binary download failed"; }
  http_fetch "https://github.com/${GITHUB_REPO}/releases/download/${tag}/${asset}.sha256" "$stage/$asset.sha256" \
    || { rm -rf "$stage"; die "checksum download failed"; }
  expect="$(awk '{print $1; exit}' "$stage/$asset.sha256")"; got="$(sha256sum "$stage/$asset" | awk '{print $1}')"
  [ "$expect" = "$got" ] || { rm -rf "$stage"; die "binary checksum mismatch"; }
  chmod 755 "$stage/$asset"
  actual="$($stage/$asset --version 2>/dev/null)" || { rm -rf "$stage"; die "downloaded binary is not runnable"; }
  embedded="${actual#trusttunnel_client }"
  echo "$embedded" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$' \
    || { rm -rf "$stage"; die "downloaded client reported invalid embedded version: $actual"; }
  if echo "$tag" | grep -qE '^v?[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$'; then
    expected="${tag#v}"
    [ "$embedded" = "$expected" ] \
      || { rm -rf "$stage"; die "embedded version '$embedded' does not match semver release tag '$tag'"; }
  fi
  log "embedded client version: $embedded"
  echo "$stage/$asset"
}

binary_target() {
  local tag="$1"; echo "/usr/local/bin/trusttunnel_client-${tag}-linux-$(release_arch)";
}

install_binary() {
  local src="$1" tag="$2" target
  need_file "$src"; [ -s "$src" ] || die "binary is empty"
  target="$(binary_target "$tag")"
  if [ -e "$target" ]; then
    [ "$(sha256sum "$src" | awk '{print $1}')" = "$(sha256sum "$target" | awk '{print $1}')" ] || die "binary collision: $target"
  else
    cp "$src" "$target"; chmod 755 "$target"
  fi
  "$target" --version >/dev/null 2>&1 || die "binary is not runnable: $target"
  ln -sfn "$(basename "$target")" "$BIN"
  echo "  $($target --version)"
}

save_meta() {
  local source="$1" tag="$2" tmp="${RELEASE_META}.new.$$"
  printf 'RELEASE_SOURCE=%s\nRELEASE_TAG=%s\nBINARY_SHA256=%s\n' "$source" "$tag" "$(sha256sum "$BIN" | awk '{print $1}')" >"$tmp"
  chmod 600 "$tmp"; mv -f "$tmp" "$RELEASE_META"
}

client_pids() { pgrep -f '^/usr/local/bin/trusttunnel_client([[:space:]]|$)' 2>/dev/null || true; }
client_running() { [ -n "$(client_pids)" ]; }

write_client_config() {
  local src="$1" tmp="${CLIENT_TOML}.new.$$" protocol=""
  need_file "$src"; parse_vps_ip "$src" >/dev/null || die "config has no IPv4 endpoint address"; parse_vps_port "$src" >/dev/null || die "config has no endpoint port"
  protocol="$(toml_get_str upstream_protocol "$src" 2>/dev/null || true)"
  [ "$protocol" = auto ] || [ "$protocol" = http2 ] || [ "$protocol" = http3 ] \
    || die 'config must use upstream_protocol = "auto", "http2", or "http3"'
  cp "$src" "$tmp"
  if grep -qE '^exclusions[[:space:]]*=' "$tmp"; then sed -i 's/^exclusions[[:space:]]*=.*/exclusions = []/' "$tmp"; else printf '\nexclusions = []\n' >>"$tmp"; fi
  if grep -qE '^change_system_dns[[:space:]]*=' "$tmp"; then sed -i 's/^change_system_dns[[:space:]]*=.*/change_system_dns = false/' "$tmp"; fi
  chmod 600 "$tmp"; mv -f "$tmp" "$CLIENT_TOML"
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
destroy table inet trusttunnel
table inet trusttunnel {
 chain output_mark { type route hook output priority mangle; policy accept;
   ip protocol tcp ip daddr \$VPS_IP tcp dport \$ENDPOINT_PORT meta mark set \$MARK
   ip protocol udp ip daddr \$VPS_IP udp dport \$ENDPOINT_PORT meta mark set \$MARK
 }
 chain output_guard { type filter hook output priority filter - 1; policy accept;
   oifname != "tun0" ip protocol tcp ip daddr \$VPS_IP tcp dport \$ENDPOINT_PORT accept
   oifname != "tun0" ip protocol udp ip daddr \$VPS_IP udp dport \$ENDPOINT_PORT accept
   oifname != "tun0" counter reject
 }
}
NFT
    while ip rule del priority "\$PRIO" 2>/dev/null; do :; done
    ip rule add priority "\$PRIO" fwmark "\$MARK/0xffffffff" lookup main
    # Keep the kernel's existing endpoint route (including its gateway). A
    # synthetic `dev UPLINK` /32 can incorrectly ARP for a remote VPS.
    ip rule del priority $((MARK_PRIO + 1)) 2>/dev/null || true
    ip rule add priority $((MARK_PRIO + 1)) unreachable
    if [ "\$mode" = full ] && ip link show tun0 >/dev/null 2>&1; then
      ip route replace default dev tun0 table "\$TABLE"
      ip rule del priority $((MARK_PRIO + 1)) 2>/dev/null || true
      ip rule add priority $((MARK_PRIO + 1)) lookup "\$TABLE"
    fi
    ip route flush cache 2>/dev/null || true
    ;;
  stop)
    nft delete table inet trusttunnel 2>/dev/null || true
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
Description=TrustTunnel local client
After=network-online.target trusttunnel-guard.service
Wants=network-online.target
Requires=trusttunnel-guard.service

[Service]
Type=simple
ExecStartPre=$POLICY start
ExecStart=$BIN -c $CLIENT_TOML
ExecStartPost=$POLICY full
Restart=always
RestartSec=5
AmbientCapabilities=CAP_NET_RAW
CapabilityBoundingSet=CAP_NET_RAW
NoNewPrivileges=true
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
  cat >"$GUARD_INIT" <<EOF
[Unit]
Description=TrustTunnel local fail-closed policy
Before=trusttunnel.service
After=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$POLICY start
ExecStop=$POLICY stop

[Install]
WantedBy=multi-user.target
EOF
  chmod 644 "$INIT" "$GUARD_INIT"
}

uplink_dev() { ip route get "$1" | sed -n 's/.* dev \([^ ]*\).*/\1/p' | head -1; }
wait_tunnel() {
  local i=0
  while [ "$i" -lt 20 ]; do ip link show tun0 >/dev/null 2>&1 && return 0; i=$((i+1)); sleep 2; done
  return 1
}

verify() {
  local vps="$1" route ipout
  ip link show tun0 >/dev/null 2>&1 || die "tun0 is not present"
  route="$(ip route get "$vps" 2>/dev/null)"
  echo "$route" | grep -q 'dev tun0' || die "endpoint non-marked traffic is not routed through tun0: $route"
  ipout=""
  if command -v curl >/dev/null 2>&1; then ipout="$(curl -4fsS --max-time 20 https://1.1.1.1/cdn-cgi/trace 2>/dev/null | sed -n 's/^ip=//p' | head -1)"; fi
  if [ -n "$ipout" ] && [ "$ipout" = "$vps" ]; then log "OK local tunnel egress IP=$ipout"; else echo "WARNING: automatic egress identity unavailable or unexpected (${ipout:-none}); check with a non-direct IP checker"; fi
  echo "  route: $route"
}

service_start() { systemctl enable --now trusttunnel.service >/dev/null; }
service_stop() { systemctl stop trusttunnel.service >/dev/null 2>&1 || true; }
service_restart() { systemctl restart trusttunnel.service; }

upgrade_rollback() {
  local rc="$?"
  if [ "$rc" -ne 0 ] && [ -n "${OLD_BIN:-}" ] && [ -x "$OLD_BIN" ]; then
    service_stop
    ln -sfn "$(basename "$OLD_BIN")" "$BIN"
    systemctl start trusttunnel.service >/dev/null 2>&1 || true
    [ -z "${NEW_BIN:-}" ] || [ "$NEW_BIN" = "$OLD_BIN" ] || rm -f "$NEW_BIN"
    echo "WARNING: upgrade failed; restored $(basename "$OLD_BIN")" >&2
  fi
  exit "$rc"
}

cmd_install() {
  local config="" binary="" tag="" src source vps port uplink
  while [ "$#" -gt 0 ]; do case "$1" in --config) config="$2"; shift 2;; --binary) binary="$2"; shift 2;; --version) tag="$2"; shift 2;; *) die "unknown install option: $1";; esac; done
  [ -n "$config" ] || die "install requires --config FILE"; [ ! -e "$CLIENT_TOML" ] || die "already installed; use upgrade or purge"
  trap 'rc=$?; if [ "$rc" -ne 0 ]; then systemctl stop trusttunnel.service >/dev/null 2>&1 || true; systemctl disable trusttunnel.service trusttunnel-guard.service >/dev/null 2>&1 || true; "$POLICY" stop >/dev/null 2>&1 || true; rm -f "$INIT" "$GUARD_INIT" "$POLICY" "$CLIENT_TOML" "$DIRECT_CONF" "$RELEASE_META" "$BIN"; rm -f /usr/local/bin/trusttunnel_client-*-linux-*; systemctl daemon-reload >/dev/null 2>&1 || true; fi; exit "$rc"' EXIT
  need_file "$config"; mkdir -p "$TT_DIR" /usr/local/libexec
  vps="$(parse_vps_ip "$config")"; port="$(parse_vps_port "$config")"; uplink="$(uplink_dev "$vps")"; [ -n "$uplink" ] || die "cannot determine uplink for endpoint"
  if [ -n "$binary" ]; then src="$binary"; source=local; tag="${tag:-$(basename "$binary")}"; else tag="${tag:-$(latest_tag)}"; src="$(download_binary "$tag")"; source="github:${GITHUB_REPO}"; fi
  write_client_config "$config"; install_binary "$src" "$tag"; write_policy "$vps" "$port" "$uplink"; write_units; save_meta "$source" "$tag"
  systemctl daemon-reload; systemctl enable trusttunnel-guard.service >/dev/null; service_start
  wait_tunnel || die "TrustTunnel did not create tun0"; verify "$vps"; trap - EXIT; log "install complete"
}

cmd_upgrade() {
  local binary="" tag="" src source vps port uplink
  [ -f "$CLIENT_TOML" ] || die "not installed"
  while [ "$#" -gt 0 ]; do case "$1" in --binary) binary="$2"; shift 2;; --version) tag="$2"; shift 2;; *) die "unknown upgrade option: $1";; esac; done
  OLD_BIN="$(readlink -f "$BIN")"; NEW_BIN=""; trap upgrade_rollback EXIT
  vps="$(parse_vps_ip "$CLIENT_TOML")"; port="$(parse_vps_port "$CLIENT_TOML")"; uplink="$(uplink_dev "$vps")"
  if [ -n "$binary" ]; then src="$binary"; source=local; tag="${tag:-$(basename "$binary")}"; else tag="${tag:-$(latest_tag)}"; src="$(download_binary "$tag")"; source="github:${GITHUB_REPO}"; fi
  service_stop; install_binary "$src" "$tag"; NEW_BIN="$(readlink -f "$BIN")"; write_policy "$vps" "$port" "$uplink"; write_units; save_meta "$source" "$tag"; systemctl daemon-reload; service_start; wait_tunnel || die "upgrade did not restore tun0"; verify "$vps"; trap - EXIT
}

cmd_update_creds() { local cfg="$2"; [ "$1" = --config ] || die "update-creds requires --config FILE"; write_client_config "$cfg"; service_restart; }
cmd_enable() { systemctl enable --now trusttunnel.service; }
cmd_disable() { systemctl disable --now trusttunnel.service; }
cmd_rollback() {
  local cur prev
  cur="$(readlink -f "$BIN")"; prev="$(find /usr/local/bin -maxdepth 1 -type f -name 'trusttunnel_client-*-linux-*' ! -path "$cur" | head -1)"; [ -n "$prev" ] || die "no previous binary available"; service_stop; ln -sfn "$(basename "$prev")" "$BIN"; service_start
}
cmd_status() {
  local vps="" port="" conf="" tcp_n=0 udp_n=0 active=0
  echo "=== TrustTunnel Linux status ==="
  [ -L "$BIN" ] && echo "  binary [*] $(readlink -f "$BIN")" || echo "  FAIL binary missing"
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
  systemctl is-enabled trusttunnel.service 2>/dev/null && echo "  ok    enabled" || echo "  warn  disabled"
  if systemctl is-active trusttunnel.service 2>/dev/null; then
    echo "  ok    active"
    active=1
  else
    echo "  FAIL inactive"
  fi
  ip rule show | grep -q "$MARK_PRIO" && echo "  ok    endpoint mark rule" || echo "  FAIL endpoint mark rule"
  ip route show table "$TUN_TABLE" 2>/dev/null | grep -q tun0 && echo "  ok    default route via tun0" || echo "  FAIL tunnel default route"
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
cmd_purge() { service_stop; systemctl disable trusttunnel.service trusttunnel-guard.service >/dev/null 2>&1 || true; systemctl daemon-reload; "$POLICY" stop 2>/dev/null || true; rm -f "$INIT" "$GUARD_INIT" "$POLICY" "$CLIENT_TOML" "$DIRECT_CONF" "$RELEASE_META" "$BIN"; rm -f /usr/local/bin/trusttunnel_client-*-linux-*; rmdir "$TT_DIR" 2>/dev/null || true; systemctl daemon-reload; log "purged TT-owned local state"; }

cmd="${1:-help}"; shift || true
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
