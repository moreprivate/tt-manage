# MorePrivate tt-* management

`tt-manage` contains deployment scripts and the local build chain for the
MorePrivate tt-* server, native client, and Flutter Android app.

| File | Runs on | Scope |
|---|---|---|
| `tt-server.sh` | Debian/Ubuntu VPS | Endpoint service, users, certificates, firewall |
| `tt-client-openwrt.sh` | OpenWrt router | Tunnel, split DNS/IP routing, LAN policy |
| `tt-client-linux.sh` | Linux host | Tunnel and fail-closed local routing |

The scripts download checksum-verified assets from `moreprivate/tt-server` and
`moreprivate/tt-client`, or accept a pinned `--version TAG` / local
`--binary PATH`. Read their built-in help first:

```sh
bash tt-server.sh help
sh tt-client-openwrt.sh help
sh tt-client-linux.sh help
```

## Deployment

### Server

```sh
bash tt-server.sh install --custom-sni camouflage.example
bash tt-server.sh add-user router
```

`--custom-sni` is mandatory and must be an ASCII DNS hostname. Profiles are
written under `/opt/moreprivate/tt-server/clients/`. New profiles default to
`upstream_protocol = "http2"` and `http_connections_num = 4`. Override the
connection count in the TOML when needed; `0` retains the client library
fallback of 8. Override the transport with
`--upstream-protocol auto|http2|http3`.
The endpoint supports H2 and H3. A server with no users is a valid deny-all
state.

### OpenWrt

```sh
sh tt-client-openwrt.sh install --config ./router.toml
sh tt-client-openwrt.sh install --config ./router.toml \\
  --direct-countries "nl ch"
# Nonstandard UCI WAN interface:
sh tt-client-openwrt.sh install --config ./router.toml --wan-if wan2
```

Country mode derives IPv4 ranges from IPdeny, DNS suffixes from country codes,
and direct resolvers from WAN DNS. `--direct-ip-file`,
`--direct-dns-domains`, and `--direct-dns-servers` override those automatic
values. LAN clients must use the router for DNS. The endpoint TCP port uses
WAN; other traffic to the server IP, including SSH, uses the tunnel.
`--wan-if IFACE` selects the logical UCI WAN interface or an explicit WAN
netdev (default `wan`); the manager resolves/uses it and writes
`listener.tun.bound_if` in the installed client configuration.

The script disables IPv6 by default and does not modify OpenWrt NTP settings.
It performs only a best-effort clock check before HTTPS/package operations.
Required packages are `kmod-tun`, `ip-full`, `firewall4`, `dnsmasq`, and
`ca-certificates`; custom firmware should include them at image build time.

### Linux host

```sh
sh tt-client-linux.sh install --config ./host.toml
```

This changes only the current Linux host; it does not configure OpenWrt,
UCI, LAN forwarding, or another machine. It does manage a dedicated local
`dnsmasq` instance on `127.0.0.1:53` for tunnel-routed DNS.

## Lifecycle and verification

All scripts support `status`, `upgrade`, `rollback`, `disable`, `enable`, and
`purge`; `install` is clean-only. Successful upgrades retain one previous
binary, and failed upgrades leave the active version untouched.

`disable` is platform-specific. On OpenWrt it leaves the router's direct
routing behavior available, which is intentional for router operation. On a
Linux host it leaves the fail-closed policy active, so it effectively disables
Internet access. Use `enable` to resume the tunnel; on Linux, use `purge` only
when you want to remove MorePrivate routing and restore ordinary direct WAN.

```sh
bash tt-server.sh status
sh tt-client-openwrt.sh status
sh tt-client-openwrt.sh update-direct --direct-countries "nl ch"
sh tt-client-linux.sh status
```

OpenWrt `status` reports tunnel state, policy ownership, DNS routing, and
diagnostic route/forwarding checks. From a LAN client using the router for DNS,
verify a non-direct public-IP checker; do not use `1.1.1.1` as the tunnel
identity probe when it is in the direct set.

## Local build chain

From `tt-manage/`:

```sh
make check
make build-server   # server targets (x86_64 + aarch64)
make build-client   # all Linux client binaries + Android AAR
make build-mobile   # client outputs + signed Android APKs
make build          # server + client + signed Android APKs
make clean          # remove caches/intermediates, keep products
make distclean      # remove products and all .tt-build tooling
```

The chain uses Docker with a pinned `adguard/core-libs` image and keeps tools and outputs
under `../.tt-build`; it does not depend on a host Flutter or Android SDK.
Create the persistent signing key once with
`(cd ../tt-mobile && make aux-setup-android-signing)`. Outputs are placed
under `.tt-build/server`, `.tt-build/client`, and `.tt-build/mobile`.

The scheduled GitHub workflow **Build release chain** dispatches the component
workflows in order: server, client, then mobile. Component workflows are
manual and refuse to replace an existing release unless
`delete_existing=true` is explicitly selected.

## Repositories

- [tt-server](https://github.com/moreprivate/tt-server)
- [tt-client](https://github.com/moreprivate/tt-client)
- [tt-mobile](https://github.com/moreprivate/tt-mobile)

## License

Apache 2.0. See [LICENSE](LICENSE).
