#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

. "$ROOT/root/etc/init.d/keylink"

contains() {
	grep -qF "$2" "$1" || {
		printf 'FAIL: %s: missing %s\n' "$1" "$2" >&2
		exit 1
	}
}

not_contains() {
	if grep -qF "$2" "$1"; then
		printf 'FAIL: %s: unexpected %s\n' "$1" "$2" >&2
		exit 1
	fi
}

run_case() {
	local name="$1" tproxy="$2" wg="$3" ifaces="$4" sources="$5"

	(
		NFT_OUT="$TMP/$name.nft"
		TPROXY="$tproxy"
		WG_ENABLED="$wg"
		WG_IFACES_TEST="$ifaces"
		WG_SOURCES_TEST="$sources"

		config_get() {
			case "$3" in
				tproxy_port) eval "$1=12345" ;;
				lan_iface)   eval "$1=br-lan" ;;
				*)           eval "$1=\"\$4\"" ;;
			esac
		}

		config_get_bool() {
			case "$3" in
				tproxy)      eval "$1=\$TPROXY" ;;
				wg_enabled)  eval "$1=\$WG_ENABLED" ;;
				*)           eval "$1=\$4" ;;
			esac
		}

		config_list_foreach() {
			case "$3" in
				add_wg_iface)
					for v in $WG_IFACES_TEST; do add_wg_iface "$v"; done
					;;
				add_wg_source)
					for v in $WG_SOURCES_TEST; do add_wg_source "$v"; done
					;;
			esac
		}

		uci() { return 0; }
		logger() { :; }
		ip() {
			[ "$*" = "route show default" ] && return 0
			return 0
		}
		nft() {
			case "$*" in
				'-f -') cat > "$NFT_OUT" ;;
				*) return 0 ;;
			esac
		}

		setup_tproxy
	)
}

# LAN only must keep the previous rule shape and must not create WG objects.
run_case lan 1 0 '' ''
contains "$TMP/lan.nft" 'iifname "br-lan" jump keylink_proxy'
contains "$TMP/lan.nft" 'chain keylink_proxy'
not_contains "$TMP/lan.nft" 'set wg_ifaces'
not_contains "$TMP/lan.nft" '@wg_ifaces'

# WireGuard works without the LAN toggle and accepts several interfaces.
run_case wg 0 1 'wg0 wg1' '10.0.0.0/24 10.0.0.5'
contains "$TMP/wg.nft" 'set wg_ifaces {'
contains "$TMP/wg.nft" 'elements = { "wg0", "wg1" }'
contains "$TMP/wg.nft" 'set wg_sources4 {'
contains "$TMP/wg.nft" 'elements = { 10.0.0.0/24, 10.0.0.5/32 }'
contains "$TMP/wg.nft" 'iifname @wg_ifaces ip saddr @wg_sources4 jump keylink_proxy'
not_contains "$TMP/wg.nft" 'br-lan'

# Without source subnets every client on the selected interfaces is proxied.
run_case any 0 1 'wg0' ''
contains "$TMP/any.nft" 'iifname @wg_ifaces jump keylink_proxy'
not_contains "$TMP/any.nft" 'set wg_sources4'

# LAN and WireGuard rules coexist.
run_case both 1 1 'wg0' ''
contains "$TMP/both.nft" 'iifname "br-lan" jump keylink_proxy'
contains "$TMP/both.nft" 'iifname @wg_ifaces jump keylink_proxy'

# Invalid names and networks are dropped instead of breaking the nft script.
run_case bad 0 1 'wg0 bad;name' '10.0.0.0/24 999.1.1.1/33 10.0.0.1'
contains "$TMP/bad.nft" '"wg0"'
not_contains "$TMP/bad.nft" 'bad;name'
not_contains "$TMP/bad.nft" '999.1.1.1'
contains "$TMP/bad.nft" '10.0.0.1/32'

# With both sources disabled no nftables script is generated (stale rules are removed).
run_case off 0 0 'wg0' '10.0.0.0/24'
[ ! -s "$TMP/off.nft" ] || {
	echo 'FAIL: rules were generated with both sources disabled' >&2
	exit 1
}

# Stopping the service must remove the TPROXY table, rule, and routing table.
(
	calls=
	nft() { calls="$calls|nft $*"; }
	ip() { calls="$calls|ip $*"; }
	cleanup_tproxy
	case "$calls" in
		*"|nft delete table inet keylink"*"|ip rule del fwmark 0x1 lookup 100"*"|ip route flush table 100"*) ;;
		*)
			printf 'FAIL: cleanup_tproxy did not remove all objects: %s\n' "$calls" >&2
			exit 1
			;;
	esac
)

echo 'OK: TPROXY rules keep LAN, add/remove WireGuard sources, and validate UCI values'
