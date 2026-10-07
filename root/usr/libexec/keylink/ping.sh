#!/bin/sh
# ping.sh <section> <url>  →  {"ms":123} или {"error":"..."}

sid="$1"
url="$2"
port=$(( 20000 + ($$ * 7919 + $(date +%s)) % 10000 ))
dir=/tmp/keylink-ping.$$
hex=$(printf '%04X' "$port")

fail() {
	[ -n "$pid" ] && kill "$pid" 2>/dev/null
	rm -rf "$dir"
	echo "{ \"error\": \"$1\" }"
	exit 0
}

mkdir -p "$dir"
ucode /usr/share/keylink/gen_config.uc test "$sid" "$port" > "$dir/config.json" 2>"$dir/err" \
	|| fail "$(head -n 1 "$dir/err" | tr -d '"\\')"

XRAY_LOCATION_ASSET=/usr/share/v2ray xray run -c "$dir/config.json" >/dev/null 2>&1 &
pid=$!

# ждём, пока поднимется SOCKS (до ~3 с)
i=0
while ! grep -q ":$hex 00000000:0000 0A" /proc/net/tcp; do
	i=$((i + 1))
	[ $i -gt 15 ] && fail "Xray did not start"
	kill -0 "$pid" 2>/dev/null || fail "Xray did not start; check the settings"
	sleep 0.2 2>/dev/null || sleep 1
done

# Два запроса подряд по одному соединению: первый включает рукопожатие,
# второй показывает чистую задержку через прокси.
out=$(curl -s --max-time 10 -x "socks5h://127.0.0.1:$port" \
	-o /dev/null -o /dev/null -w '%{http_code} %{time_total}\n' "$url" "$url" 2>/dev/null)

kill "$pid" 2>/dev/null
rm -rf "$dir"

last=$(echo "$out" | tail -n 1)
code=${last%% *}
sec=${last#* }

case "$code" in
	200|204)
		ms=$(awk -v s="$sec" 'BEGIN { printf "%d", s * 1000 }')
		echo "{ \"ms\": $ms }"
		;;
	000|'')
		echo '{ "error": "No response" }'
		;;
	*)
		echo "{ \"error\": \"HTTP $code\" }"
		;;
esac
