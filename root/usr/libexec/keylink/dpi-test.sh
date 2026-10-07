#!/bin/sh
# dpi-test.sh <byedpi|zapret> [id ...]
# Перебирает пресеты и проверяет каждым сайты из keylink.main.dpi_test_sites.
# Результаты: $D/info (JSON) и $D/results (по строке JSON на пресет).

set -f
engine="$1"; shift
only="$*"

D=/tmp/keylink-dpitest
DPI=/usr/share/keylink/dpi.uc
TEST_MARK=0x00400000        # отличается от боевой метки 0x00200000
TEST_Q=201
TAB=$(printf '\t')

mkdir -p "$D"
if [ -f "$D/pid" ] && kill -0 "$(cat "$D/pid")" 2>/dev/null; then
	echo "busy"; exit 1
fi
echo $$ > "$D/pid"
set +f; rm -f "$D"/s.* "$D/stop" "$D/results" "$D/error"; set -f
: > "$D/results"

bp=""; zp=""; xp=""
cleanup() {
	for p in $bp $zp $xp; do kill "$p" 2>/dev/null; done
	[ "$engine" = zapret ] && nft delete table inet keylink_ztest 2>/dev/null
	set +f
	rm -f "$D/pid" "$D"/s.* "$D/xray.json"
}
trap 'cleanup; exit 0' INT TERM
trap cleanup EXIT

fail() {
	printf '%s' "$1" | tr -d '"\\' | tr '\n\t' '  ' | head -c 300 > "$D/error"
	exit 1
}

SITES=$(uci -q get keylink.main.dpi_test_sites)
[ -n "$SITES" ] || SITES="https://www.youtube.com/ https://discord.com/ https://rutracker.org/forum/index.php"
TO=$(uci -q get keylink.main.dpi_test_timeout)
case "$TO" in ''|*[!0-9]*) TO=8 ;; esac

BIN=$(ucode $DPI bin "$engine" 2>&1) || fail "$BIN"
ucode $DPI list "$engine" > "$D/presets" 2>"$D/error" || fail "$(cat "$D/error")"

if [ -n "$only" ]; then
	for id in $only; do grep "^$id$TAB" "$D/presets"; done > "$D/presets.sel"
	mv "$D/presets.sel" "$D/presets"
fi
total=$(wc -l < "$D/presets")

# info: какие сайты и сколько пресетов
{
	printf '{"engine":"%s","total":%d,"started":%d,"sites":[' "$engine" "$total" "$(date +%s)"
	n=0; for u in $SITES; do [ $n -gt 0 ] && printf ','; printf '"%s"' "$u"; n=$((n + 1)); done
	printf ']}'
} > "$D/info"

rand_port() {
	echo $(( 30000 + ($$ * 7919 + $(date +%s)) % 20000 ))
}

wait_port() {
	local hex i=0
	hex=$(printf '%04X' "$1")
	while ! grep -q ":$hex 00000000:0000 0A" /proc/net/tcp; do
		i=$((i + 1)); [ $i -gt 25 ] && return 1
		kill -0 "$2" 2>/dev/null || return 1
		sleep 0.2 2>/dev/null || sleep 1
	done
}

# Проверка всех сайтов параллельно. $1 — аргументы прокси для curl (или пусто)
# Печатает: "ok":[...],"ms":[...]
run_sites() {
	local proxy="$1" i=0 pids="" ok="" ms="" rc code t
	for u in $SITES; do
		(
			out=$(curl -s -o /dev/null --max-time "$TO" $proxy \
				-w '%{http_code} %{time_total}' "$u" </dev/null 2>/dev/null)
			echo "$? $out" > "$D/s.$i"
		) &
		pids="$pids $!"
		i=$((i + 1))
	done
	wait $pids

	i=0
	for u in $SITES; do
		read -r rc code t < "$D/s.$i" 2>/dev/null || { rc=1; code=000; t=0; }
		if [ "$rc" = 0 ] && [ "$code" != 000 ]; then
			ok="$ok,1"; ms="$ms,$(awk -v s="$t" 'BEGIN { printf "%d", s * 1000 }')"
		else
			ok="$ok,0"; ms="$ms,0"
		fi
		i=$((i + 1))
	done
	printf '"ok":[%s],"ms":[%s]' "${ok#,}" "${ms#,}"
}

result() {
	echo "{\"id\":\"$1\",$2}" >> "$D/results"
}

errline() {
	printf '"error":"%s"' "$(printf '%s' "$1" | tr -d '"\\' | tr '\n' ' ' | head -c 160)"
}

# Без обхода — чтобы было видно, что вообще заблокировано
result "_direct" "$(run_sites "")"

if [ "$engine" = byedpi ]; then
	port=$(rand_port)
	while IFS="$TAB" read -r id args; do
		[ -f "$D/stop" ] && break
		"$BIN" -i 127.0.0.1 -p "$port" $args </dev/null >"$D/err" 2>&1 &
		bp=$!
		if wait_port "$port" "$bp"; then
			result "$id" "$(run_sites "-x socks5h://127.0.0.1:$port")"
		else
			result "$id" "$(errline "$(cat "$D/err")")"
		fi
		kill "$bp" 2>/dev/null; wait "$bp" 2>/dev/null; bp=""
	done < "$D/presets"
else
	# Временный Xray: SOCKS → freedom с тестовой меткой; эти пакеты идут в очередь TEST_Q
	nft -f - <<NFT || fail "Could not create nftables rules; is kmod-nft-queue installed?"
table inet keylink_ztest {
	chain post {
		type filter hook postrouting priority 102; policy accept;
		meta mark and 0x40000000 != 0 return
		meta mark and $TEST_MARK == 0 return
		ct mark set ct mark or $TEST_MARK
		tcp dport { 80, 443 } ct original packets 1-12 queue num $TEST_Q bypass
		udp dport 443 ct original packets 1-12 queue num $TEST_Q bypass
	}
	chain pre {
		type filter hook prerouting priority -102; policy accept;
		meta mark and 0x40000000 != 0 return
		ct mark and $TEST_MARK == 0 return
		tcp sport { 80, 443 } ct reply packets 1-6 queue num $TEST_Q bypass
	}
	chain predefrag {
		type filter hook output priority -402; policy accept;
		meta mark and 0x40000000 != 0 notrack
	}
}
NFT
	sysctl -q -w net.netfilter.nf_conntrack_tcp_be_liberal=1 2>/dev/null

	port=$(rand_port)
	cat > "$D/xray.json" <<JSON
{ "log": { "loglevel": "none" },
  "inbounds": [ { "listen": "127.0.0.1", "port": $port, "protocol": "socks", "settings": { "udp": false } } ],
  "outbounds": [ { "protocol": "freedom", "streamSettings": { "sockopt": { "mark": $((TEST_MARK)) } } } ] }
JSON
	xray run -c "$D/xray.json" </dev/null >/dev/null 2>&1 &
	xp=$!
	wait_port "$port" "$xp" || fail "Temporary Xray instance did not start"

	while IFS="$TAB" read -r id args; do
		[ -f "$D/stop" ] && break
		"$BIN" --qnum=$TEST_Q $args </dev/null >"$D/err" 2>&1 &
		zp=$!
		sleep 1
		if kill -0 "$zp" 2>/dev/null; then
			result "$id" "$(run_sites "-x socks5h://127.0.0.1:$port")"
		else
			result "$id" "$(errline "$(tail -n 3 "$D/err")")"
		fi
		kill "$zp" 2>/dev/null; wait "$zp" 2>/dev/null; zp=""
	done < "$D/presets"
fi
exit 0
