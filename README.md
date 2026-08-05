# TrustTunnel management

Three standalone scripts install and operate the TrustTunnel server and
clients:

| Script | Runs on | Manages |
|---|---|---|
| `tt-server.sh` | Debian/Ubuntu VPS | server, users, certificates, service |
| `tt-client-openwrt.sh` | OpenWrt router | tunnel, DNS split, IP split, LAN forwarding |
| `tt-client-linux.sh` | Linux host | tunnel and fail-closed local routing |

The scripts are deliberately independent of the source repositories. They
download verified release assets from `moreprivate/tt-server` and
`moreprivate/tt-client`, or accept a reviewed local binary.

Always read the built-in help first:

```sh
bash tt-server.sh help
sh tt-client-openwrt.sh help
sh tt-client-linux.sh help
```

## Quick start

### Server

On the VPS:

```sh
bash tt-server.sh install --custom-sni camouflage.example
bash tt-server.sh add-user openwrt
```

`--custom-sni` is mandatory and must be an ASCII DNS hostname. The generated
profile is written to `/opt/trusttunnel/clients/openwrt.toml`; copy it to the
client device and keep it private. The server may have zero users: that is a
valid deny-all state. New profiles default to `upstream_protocol = "http3"`
(endpoint always listens H2+H3; override with `--upstream-protocol http2|auto`).
Client `status` reports configured protocol and live H2/H3 from `ss`.
New profiles set `health_check_timeout_ms = 15000` (needs a client that understands the key).
Optional OpenWrt bufferbloat control: `wan-shape --download KBIT --upload KBIT` (CAKE via SQM).

### OpenWrt router

Tunnel all supported traffic:

```sh
sh tt-client-openwrt.sh install --config ./openwrt.toml
```

Full country-direct example:

```sh
sh tt-client-openwrt.sh install \
  --config ./openwrt.toml \
  --direct-countries "nl" \
  --direct-dns-domains "nl" \
  --direct-dns-servers "80.80.80.80 80.80.81.81" \
  --tunnel-dns-servers "1.1.1.1 1.0.0.1"
```

Omit the direct options for tunnel-only mode. Country mode derives IP ranges
from IPdeny, DNS suffixes from the country codes, and resolver addresses from
the router's WAN DNS. Explicit direct options override the derived values.

### Linux host

```sh
sh tt-client-linux.sh install --config ./linux.toml
```

This script changes only the current Linux host. It does not configure
OpenWrt, dnsmasq, UCI, LAN forwarding, or another machine.

## Traffic model

OpenWrt split routing has two independent stages:

1. A DNS name is sent to either a direct resolver or a tunnel resolver.
2. The returned IPv4 address is routed either directly through WAN or through
   `tun0`.

With direct mode enabled:

- TCP, UDP, and ICMP to the direct IPv4 list use WAN.
- Other supported IPv4 traffic uses the tunnel.
- Only the configured server IP and TCP port use WAN to establish the tunnel.
- Other traffic to the server IP, including SSH, uses the tunnel.
- If the tunnel is unavailable, non-direct traffic is rejected; it does not
  fall back to WAN.

The router's tunnel DNS defaults to `1.1.1.1 1.0.0.1`. LAN devices must use
the router as their DNS server for DNS split routing to apply.

IPv6 is disabled by default by the OpenWrt script. Set `SKIP_IPV6=1` only when
IPv6 is configured and intentionally managed elsewhere.

## Direct profile options

Use country-derived values:

```sh
sh tt-client-openwrt.sh update-direct --direct-countries "nl ch"
```

Or provide a complete custom profile:

```sh
sh tt-client-openwrt.sh update-direct \
  --direct-ip-file ./direct.zone \
  --direct-dns-domains "nl ch" \
  --direct-dns-servers "80.80.80.80 80.80.81.81"
```

Important options:

| Option | Meaning |
|---|---|
| `--direct-countries LIST` | IPdeny IPv4 ranges plus derived DNS values |
| `--direct-ip-file FILE` | Custom IPv4 CIDR list |
| `--direct-dns-domains LIST` | DNS suffixes resolved directly |
| `--direct-dns-servers LIST` | Direct resolver IPv4 addresses |
| `--tunnel-dns-servers LIST` | Resolver addresses used for other names |

Automatic values retain their provenance and refresh when countries change;
omitted manual overrides are preserved. Active profile updates are
transactional and restore the previous policy on failure.

## Lifecycle commands

Server:

```sh
bash tt-server.sh status
bash tt-server.sh upgrade [--binary PATH | --version TAG]
bash tt-server.sh rollback
bash tt-server.sh add-user NAME
bash tt-server.sh del-user NAME
bash tt-server.sh disable
bash tt-server.sh enable
bash tt-server.sh purge
```

OpenWrt:

```sh
sh tt-client-openwrt.sh status
sh tt-client-openwrt.sh upgrade [--binary PATH | --version TAG]
sh tt-client-openwrt.sh rollback
sh tt-client-openwrt.sh update-creds --config ./openwrt.toml
sh tt-client-openwrt.sh update-direct [OPTIONS]
sh tt-client-openwrt.sh direct-enable
sh tt-client-openwrt.sh direct-disable
sh tt-client-openwrt.sh wan-shape --download KBIT --upload KBIT   # CAKE ~85–95% ISP rate
sh tt-client-openwrt.sh wan-shape-disable
sh tt-client-openwrt.sh disable
sh tt-client-openwrt.sh enable
sh tt-client-openwrt.sh restart
sh tt-client-openwrt.sh purge
```

Linux:

```sh
sh tt-client-linux.sh status
sh tt-client-linux.sh upgrade [--binary PATH | --version TAG]
sh tt-client-linux.sh rollback
sh tt-client-linux.sh update-creds --config ./linux.toml
sh tt-client-linux.sh disable
sh tt-client-linux.sh enable
sh tt-client-linux.sh purge
```

`install` is clean-only. Use `upgrade` on an installed system, or `purge`
before reinstalling. Each successful upgrade keeps the active version and one
rollback version; older binaries are removed. A failed upgrade removes only
its candidate. `rollback` swaps the active and previous version.

## OpenWrt prerequisites

Stock OpenWrt can install the required packages when matching feeds are
available:

```text
kmod-tun ip-full firewall4 dnsmasq ca-certificates
```

The script checks packages before changing TrustTunnel state and attempts
`apk update`/`apk add` for missing packages. `kmod-tun` must match the running
kernel. Custom firmware must include it at build time:

```text
CONFIG_PACKAGE_kmod-tun=y
CONFIG_PACKAGE_firewall4=y
CONFIG_PACKAGE_dnsmasq=y
CONFIG_PACKAGE_ip-full=y
CONFIG_PACKAGE_ca-certificates=y
# CONFIG_PACKAGE_dnsmasq-full is not set
```

The script does not modify OpenWrt NTP service settings. It performs only a
best-effort clock check before HTTPS/package operations; if the clock is wrong,
correct it manually before retrying.

## Verification

On the server:

```sh
ss -tn state established '( sport = :443 )'
```

On OpenWrt:

```sh
sh tt-client-openwrt.sh status
```

From a LAN client using the router for DNS, check both a known non-direct
address and an ordinary hostname. If `1.1.1.1` is in the direct list, use a
different non-direct public-IP checker for the tunnel identity test.

## Releases and builds

### Local build API

**Only four commands** (from `tt-manage/`). Run `make help` for the same list.

| Command | What it does |
|---|---|
| **`make build`** | Full product: server + client + **signed** release APKs |
| **`make build-router`** | Server + client only (use for OpenWrt / protocol work) |
| **`make clean`** | Clear caches and intermediate trees; **keep finished products** |
| **`make distclean`** | Delete **all** of `../.tt-build/` (products + tools) — rare |

```sh
cd tt-manage
make help
make build-router              # after client/server code changes
make build                     # full product including APKs
make clean && make build       # refresh caches, then full product
make distclean && make build   # only if tooling under .tt-build is corrupted
```

#### What `clean` vs `distclean` keep

| Path under `../.tt-build/` | `make clean` | `make distclean` |
|---|---|---|
| `server/tt-server-*` | **kept** | deleted |
| `client/tt-client-*` | **kept** | deleted |
| `tt-mobile-*-release.apk` | **kept** | deleted |
| `flutter/`, `android-sdk/`, `docker-*` caches | deleted | deleted |

There is **no** `clean-all` / `clean-products` / `clean-server` public API — only
`clean` and `distclean`.

#### Model (same as self-hosted GitHub runner)

- Host needs **Docker** only (image `adguard/core-libs:2.12`).
- Flutter (**3.44.8**) and Android packages bootstrap into workspace **`.tt-build/`**.
- **No** host `~/flutter` and **no** host Android SDK mounts.
- Do **not** drive builds with per-repo `make` under `tt-server` / `tt-client` /
  `tt-mobile` for this flow.

#### Outputs

After a successful build:

| Artifact | Path |
|---|---|
| Server | `../.tt-build/server/tt-server-*-linux-*` |
| Client (OpenWrt, etc.) | `../.tt-build/client/tt-client-*-linux-*` |
| Phone APK | `../.tt-build/tt-mobile-arm64-v8a-release.apk` |
| APK alias | `../.tt-build/tt-mobile-release.apk` (same as arm64) |
| Other ABIs | `../.tt-build/tt-mobile-{armeabi-v7a,x86_64}-release.apk` |

#### APK signing (once)

Release APKs need a keystore under **`$HOME/.config/tt-mobile/`** (not in git).
Same key for local + CI so installs replace each other:

```sh
cd ../tt-mobile && make aux-setup-android-signing
# → ~/.config/tt-mobile/trusttunnel.keystore  (back up offline)
# GH secrets: ANDROID_KEYSTORE_BASE64, ANDROID_KEYSTORE_PASSWORD,
#             ANDROID_KEY_ALIAS, ANDROID_KEY_PASSWORD
```

#### Release asset names (GitHub)

- `tt-server-TAG-linux-ARCH`
- `tt-client-TAG-linux-ARCH`
- `tt-client-android-TAG.tar.gz`
- `tt-mobile-arm64-v8a-release.apk` (primary; also `armeabi-v7a` / `x86_64`)
- `tt-mobile-release.apk` (alias of the arm64 APK)

Install the arm64 APK on modern phones (~15–35MB split release). A fat multi-ABI
APK is not the default (native size multiplies by ~3×).

Every binary release has a checksum sidecar and manifest. Use `--version TAG`
to pin a release or `--binary PATH` for a local file (same flag on server and clients).

The component workflows are manual-only. Upstream rebasing is manual. The
release chain workflow lives in `tt-manage` and dispatches server → client →
mobile in order. Its scheduled run uses GitHub-hosted infrastructure; its
organization secret is `CHAIN_TOKEN`.

## License

Apache 2.0. See [LICENSE](LICENSE).
