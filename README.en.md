# KeyLink

[Русский](README.md) | **English**

KeyLink (the `luci-app-keylink` package) is a LuCI web interface for [Xray-core](https://github.com/XTLS/Xray-core) on OpenWrt, with server imports from links and subscriptions, domain- and IP-based routing, load balancing, encrypted DNS, and built-in DPI bypass without a VPN.

All settings are stored in UCI (`/etc/config/keylink`). The interface only edits UCI, while a separate script generates the Xray configuration from it on every startup. There is no need to edit Xray JSON manually, and configuration generation can be debugged directly from the command line.

## Features

- **Import servers from links**: `vless://` (including REALITY and Vision), `vmess://`, `trojan://`, `ss://` (SIP002 and legacy format), `hysteria2://` / `hy2://`. TCP, WebSocket, gRPC, XHTTP, and HTTPUpgrade transports. Multiple links can be pasted at once.
- **Hysteria2** with Salamander obfuscation, port hopping, and bandwidth limits. The port hopping format is automatically adjusted to the installed Xray version.
- **Subscriptions**: scheduled updates, optionally through an already running proxy. Server name filters, traffic usage, and expiration details. Server tags are preserved across updates, so routing rules keep working.
- **Latency checks** for individual servers or all servers at once, using real connections.
- **Load balancers**: lowest latency, least load, random, or round-robin. A balancer can include all servers from a subscription and use a fallback route.
- **Routing**: rules based on domains (`geosite:`, `domain:`, `full:`, `keyword:`, `regexp:`), IP addresses (`geoip:`, CIDR), LAN devices, ports, network, and protocol. Drag and drop to reorder rules.
- **Transparent proxy** for the entire LAN (TPROXY, IPv4), plus SOCKS5 and HTTP ports.
- **DNS**: Russian domains are resolved through local DNS, while other domains use DoH through the tunnel. dnsmasq is redirected automatically and restored when the service stops.
- **DPI bypass without a VPN**:
  - [ByeDPI](https://github.com/hufrea/byedpi): a SOCKS proxy with DPI desynchronization, 21 presets;
  - [Zapret 2](https://github.com/bol-van/zapret2) (nfqws2): packet-level desynchronization, 11 presets, and Discord voice bypass;
  - a multi-site strategy tester for both engines.

## Requirements

- OpenWrt 22.03 or later: fw4/nftables and ucode are required.
- Xray-core. Hysteria2 requires version 26.3.27 or later (check with `xray version`); if the repository version is older, the installer can install an official build.
- Around 30-40 MB of free storage, mostly for Xray and geo databases.

The package installs these dependencies: `xray-core`, `ucode`, `ucode-mod-uci`, `ucode-mod-fs`, `kmod-nft-tproxy`, `curl`. The `v2ray-geosite` (~2 MB) and `v2ray-geoip` (~22 MB) databases are installed when there is enough space. Without them, all rules except those using `geosite:`/`geoip:` still work.

DPI bypass requires additional packages, installed separately:

| Engine | Requirements |
|---|---|
| ByeDPI | byedpi package (`ciadpi` binary) |
| Zapret 2 | zapret2 package (`nfqws2` and Lua scripts), `kmod-nft-queue` |

Prebuilt OpenWrt packages are available from projects such as [1andrevich/ByeDPI-OpenWrt](https://github.com/1andrevich/ByeDPI-OpenWrt) and [1andrevich/zapret2-openwrt](https://github.com/1andrevich/zapret2-openwrt).

## Installation

### Using the installer

Copy the archive to your router and run the installer:

```sh
scp luci-app-keylink.tar.gz root@192.168.1.1:/tmp/
ssh root@192.168.1.1
cd /tmp && tar xzf luci-app-keylink.tar.gz && sh luci-app-keylink/install.sh
```

Or install the latest release with a single command:

```sh
wget -qO- https://github.com/remyweinstein/luci-app-keylink/releases/latest/download/install.sh | sh
```

The release installer already knows where to download the archive. To use a different source, specify it explicitly: `KEYLINK_URL=https://example.com/luci-app-keylink.tar.gz`.

### Creating a release

GitHub Actions creates a release automatically when a tag prefixed with `v` is pushed. For example, to publish `v1.0.0`:

```sh
git tag -a v1.0.0 -m "Release v1.0.0"
git push origin v1.0.0
```

The workflow creates a GitHub Release containing `luci-app-keylink.tar.gz` and a configured `install.sh`.

The installer:

1. Checks the system and available storage.
2. Installs dependencies through apk or opkg.
3. If the repository's Xray version is older than 26.3.27, offers to install an official build from [XTLS/Xray-core](https://github.com/XTLS/Xray-core/releases), with checksum verification, to support Hysteria2.
4. Copies files without changing existing settings.
5. Optionally installs ByeDPI and Zapret 2, trying the official repository first, then [1andrevich](https://github.com/1andrevich) builds.
6. Disables the engines' standalone services and locates the zapret2 files.

Options:

| Option | Action |
|---|---|
| `-y` | Run without prompts; DPI engines are only installed with `--with-...` |
| `--with-byedpi`, `--with-zapret` | Install the DPI engine |
| `--no-byedpi`, `--no-zapret` | Skip the engine without prompting |
| `--xray-update` | Install the latest official Xray even if the repository version is suitable; also usable for later Xray updates |
| `--no-xray-update` | Keep the repository's Xray without prompting |
| `--with-ru` | Install Russian translations for KeyLink and shared LuCI controls |
| `--lang en\|ru` | Installer message language, English by default |
| `--uninstall` | Remove keylink, keeping settings |
| `--purge` | Remove keylink and its settings |

If GitHub is unavailable, specify a mirror: `GH_MIRROR=https://your.mirror sh install.sh`.

### Updating

You can update from LuCI: General → Version → Check for updates. The button shows the installed and latest versions and runs the latest release installer (`install.sh -y --no-xray-update`) settings are kept, KeyLink restarts at the end, and progress is shown in the dialog. From the command line, use the same command as for installation.

Uninstalling first stops the service: dnsmasq settings are restored, and nftables rules and the cron job are removed. The xray-core, byedpi, and zapret2 packages remain installed and can be removed separately.

### Building the package

Place the `luci-app-keylink` directory in `feeds/luci/applications/` in an OpenWrt buildroot or SDK, then run:

```sh
./scripts/feeds update -a && ./scripts/feeds install -a
make package/luci-app-keylink/compile V=s
```

The built package will appear in `bin/packages/*/luci/`.

### Manual installation (for development)

```sh
# On the router: dependencies
apk add xray-core ucode ucode-mod-uci ucode-mod-fs kmod-nft-tproxy v2ray-geoip v2ray-geosite curl
# Or: opkg update && opkg install ...

# From your computer: package files
scp -r root/* root@192.168.1.1:/
scp -r htdocs/* root@192.168.1.1:/www/

# On the router
chmod +x /etc/init.d/keylink /usr/libexec/rpcd/keylink /usr/libexec/keylink/*.sh
rm -rf /tmp/luci-*; /etc/init.d/rpcd restart
/etc/init.d/keylink enable
/etc/init.d/keylink restart
```

The **Services > KeyLink** section will now appear in LuCI.

`restart` is also required on the first installation: it registers the LuCI configuration apply trigger with procd. Xray and the DPI engines do not start while "Enable" is off.

> If you already have byedpi or zapret2 installed with its own service, disable it (`/etc/init.d/byedpi disable && /etc/init.d/byedpi stop`, and the same for `zapret2`). KeyLink manages the engines itself. The standalone ByeDPI service uses port 1080 by default, which conflicts with Xray's SOCKS port, while the standalone zapret2 service installs its own nftables rules.

## Quick Start

1. **Servers**: paste links into "Add from links", or add a subscription on the "Subscriptions" tab.
2. **General**: enable the service, select the default route (a server or balancer), and enable the transparent proxy for LAN if needed.
3. **Routing**: review the rules. Russian websites and torrents use a direct connection by default.
4. Click **Save & Apply**.

If you do not have a VPN server and only need to bypass throttling of YouTube and Discord, open the **DPI Bypass** tab, find a strategy using the tester, and click the "YouTube and Discord via ..." quick-action button.

## Interface Language

KeyLink uses English as its base language. Install the optional Russian translation with:

```sh
wget -qO- https://github.com/remyweinstein/luci-app-keylink/releases/latest/download/install.sh | sh -s -- --with-ru
```

For an extracted release, run `sh install.sh --with-ru`. Later installer runs update an already installed translation even without this option.

If LuCI already uses Russian, the installer adds the translation automatically, including when upgrading an older KeyLink version. With the language set to `auto` (or unset), the translation is added if LuCI's Russian base catalog is installed. An explicitly selected English or other language is preserved.

Then select **Russian** under **System > System > Language and Style > Language** and click **Save & Apply**. Select **English** to switch back. This is LuCI's standard, system-wide language setting; the installer does not change it automatically.

With the OpenWrt SDK, `po/ru/keylink.po` builds into a separate `luci-i18n-keylink-ru` package: enable Russian in the LuCI translation build settings. Install the resulting `.ipk`/`.apk` together with `luci-i18n-base-ru` for shared LuCI controls. Use the KeyLink package and translation from the same build; the package may not be available in the official OpenWrt repository.

When installing from source, first run `PO2LMO=/path/to/po2lmo sh scripts/build-i18n.sh`, then `sh install.sh --with-ru`. The LuCI SDK host tools provide `po2lmo`; release archives already include the compiled translation. For manual file copying, place `i18n/keylink.ru.lmo` in `/usr/lib/lua/luci/i18n/` and install `luci-i18n-base-ru`.

Switching languages does not rename saved servers, subscriptions, or custom rules, including Russian names from older configurations.

## Useful Commands

```sh
# Preview the generated configuration without restarting the service
ucode /usr/share/keylink/gen_config.uc | less
ucode /usr/share/keylink/gen_config.uc > /tmp/c.json && xray run -test -c /tmp/c.json

# Logs
logread -e xray -e keylink

# Check server latency (get the section name from uci show keylink)
ubus call keylink ping '{"sid":"cfg0a1b2c"}'

# Update a subscription or all subscriptions
ucode /usr/share/keylink/subscribe.uc update cfg0a1b2c
ucode /usr/share/keylink/subscribe.uc all

# Show the arguments used to start the DPI engines
ucode /usr/share/keylink/dpi.uc args byedpi
ucode /usr/share/keylink/dpi.uc args zapret

# nftables rules
nft list table inet keylink
nft list table inet keylink_zapret

# Check DNS
nslookup youtube.com 127.0.0.1
```

## Adding Custom Presets

Presets are stored in `/usr/share/keylink/dpi_presets.json`. A new entry immediately appears in both the strategy list and the tester:

```json
{ "id": "my_preset", "name": "My preset", "args": "--disorder 1 --tlsrec 3+s" }
```

Argument rules:

- **ByeDPI**: omit `-i` and `-p`; the service sets them.
- **Zapret 2**: omit `--qnum` and `--lua-init`; the service adds them. Separate profiles with `--new`. `${FAKE}` is replaced with the directory containing zapret2's fake packets.

Values within arguments must not contain spaces: arguments are split on spaces without respecting quotes. You can validate a Zapret 2 preset before adding it with `nfqws2 --qnum=200 <arguments> --dry-run`.

## Troubleshooting

**The installer reports that v2ray-geoip or v2ray-geosite was not installed.** This almost always means there is not enough storage: the full geoip database takes about 22 MB. KeyLink still works without it. Without geoip, private networks are specified as explicit subnets, and `geoip:` rules are skipped. Without geosite, `geosite:` rules are skipped in the same way. Check `logread -e keylink` to see which conditions were skipped. For domain rules, use `domain:` and `full:`, which do not require databases.

**Xray does not start.** Run `ucode /usr/share/keylink/gen_config.uc > /tmp/c.json && xray run -test -c /tmp/c.json`: Xray will report the server or parameter causing the problem.

**Websites stop opening after enabling DNS.** If Xray is not running, DNS resolution fails for the network. Disable DNS on the "DNS" tab or run `/etc/init.d/keylink stop` to restore dnsmasq settings. Then check that the default route works.

**A subscription reports "no supported servers".** Try a different User-Agent. Many panels return link lists only to recognized clients, and some clients receive JSON configurations instead of links, which are not currently parsed.

**Hysteria2 does not connect.** Check `xray version`: version 26.3.27 or later is required. The OpenWrt 24.10 repository provides version 25.1.30, which causes Hysteria2 servers to be skipped (shown in `logread -e keylink`), while other servers continue to work. The installer offers to replace it with an official build; if you declined, run `sh install.sh --xray-update`. For port hopping, the server must forward the entire port range to its listening port.

**Zapret 2 has no effect.**
- Check that `kmod-nft-queue` is installed and the table exists: `nft list table inet keylink_zapret`.
- Disable the standalone zapret2 service.
- With hardware flow offloading enabled, some packets bypass nftables. Try disabling it.

**The tester shows that everything works without bypass.** The sites may not currently be blocked, or throttling may start later than the initial page load. Add a URL that downloads a substantial amount of data to the test list.

## Limitations

- The transparent proxy only supports IPv4. By default, DNS returns only IPv4 addresses to prevent traffic from bypassing the proxy over IPv6.
- Latency checks and subscription updates use applied settings. Save and apply a new server or subscription first.
- Xray/sing-box JSON and Clash YAML subscriptions are not supported; only link lists, either plain text or base64-encoded, are supported.
- Servers imported from subscriptions are overwritten on each update; manual changes to them are not preserved.

## Acknowledgments

- [Xray-core](https://github.com/XTLS/Xray-core): the proxy core.
- [hufrea/byedpi](https://github.com/hufrea/byedpi): the ByeDPI engine.
- [bol-van/zapret2](https://github.com/bol-van/zapret2): the Zapret 2 engine. Presets are based on examples from its documentation.
- [Loyalsoldier/v2ray-rules-dat](https://github.com/Loyalsoldier/v2ray-rules-dat): the geoip/geosite lists used by the default rules.
- [Re:HomeProxy](https://github.com/1andrevich/homeproxy-hiddify): the idea of built-in DPI bypass with a strategy tester.

The DPI bypass engines and Xray are distributed under their own licenses and are not included in this package.

## License

MIT. See [LICENSE](LICENSE).
