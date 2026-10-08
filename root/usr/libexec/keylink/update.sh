#!/bin/sh
# update.sh check  — установленная и последняя версии (JSON)
# update.sh start  — запустить обновление в фоне
# update.sh status — ход обновления: идёт ли, код завершения, конец журнала (JSON)
#
# Для пакетных установок обновляет APK/IPK через менеджер пакетов; для остальных
# скачивает install.sh последнего релиза, который сохраняет настройки и перезапускает KeyLink.

. /usr/share/libubox/jshn.sh

D=/tmp/keylink-update
STATE=/etc/keylink
GH="${GH_MIRROR:-https://github.com}"
GH="${GH%/}"
REPO=$(cat "$STATE/repo" 2>/dev/null)
case "$REPO" in */*) ;; *) REPO=remyweinstein/luci-app-keylink ;; esac

running() {
	[ -f "$D/pid" ] && kill -0 "$(cat "$D/pid")" 2>/dev/null
}

# язык, на котором KeyLink устанавливали; у установок до v0.3.7 его нет —
# тогда русский, если стоит русский перевод интерфейса
lang() {
	local l
	l=$(cat "$STATE/lang" 2>/dev/null)
	[ -n "$l" ] || { [ -f /usr/lib/lua/luci/i18n/keylink.ru.lmo ] && l=ru; }
	[ "$l" = ru ] && echo ru || echo en
}

version() {
	tr -cd 'A-Za-z0-9._-' < "$STATE/version" 2>/dev/null
}

case "$1" in
check)
	url=$(curl -fsSIL -o /dev/null -w '%{url_effective}' --connect-timeout 15 \
		"$GH/$REPO/releases/latest" 2>/dev/null)
	latest=""
	case "$url" in */tag/*) latest=$(printf '%s' "${url##*/tag/}" | tr -cd 'A-Za-z0-9._-') ;; esac
	json_init
	json_add_string current "$(version)"
	json_add_string latest "$latest"
	[ -n "$latest" ] || json_add_string error "Could not check for updates"
	json_dump
	;;
start)
	if running; then
		echo '{ "error": "An update is already running" }'
		exit 0
	fi
	mkdir -p "$D"
	rm -f "$D/rc"
	: > "$D/log"
	# обновление может заменить этот файл, поэтому запускаем копию
	cp "$0" "$D/update.sh"
	# отдельная сессия, чтобы обновление пережило перезапуск rpcd
	ss=""; command -v setsid >/dev/null 2>&1 && ss=setsid
	( cd / && $ss sh "$D/update.sh" run </dev/null >/dev/null 2>&1 & )
	echo '{ "started": true }'
	;;
run)
	echo $$ > "$D/pid"
	{
		if [ -f "$STATE/package" ]; then
			if command -v apk >/dev/null 2>&1; then
				echo "==> $GH/$REPO/releases/latest/download/luci-app-keylink.apk"
				curl -fsSL --connect-timeout 15 -o "$D/luci-app-keylink.apk" \
					"$GH/$REPO/releases/latest/download/luci-app-keylink.apk" &&
				apk add --allow-untrusted "$D/luci-app-keylink.apk"
			elif command -v opkg >/dev/null 2>&1; then
				echo "==> $GH/$REPO/releases/latest/download/luci-app-keylink.ipk"
				curl -fsSL --connect-timeout 15 -o "$D/luci-app-keylink.ipk" \
					"$GH/$REPO/releases/latest/download/luci-app-keylink.ipk" &&
				opkg install "$D/luci-app-keylink.ipk"
			else
				echo "Error: no supported package manager found"
				false
			fi
		else
			echo "==> $GH/$REPO/releases/latest/download/install.sh"
			curl -fsSL --connect-timeout 15 -o "$D/install.sh" \
				"$GH/$REPO/releases/latest/download/install.sh" &&
			KEYLINK_REPO="$REPO" sh "$D/install.sh" -y --no-xray-update --lang "$(lang)"
		fi
	} >> "$D/log" 2>&1 </dev/null
	echo $? > "$D/rc"
	rm -f "$D/pid" "$D/install.sh" "$D/luci-app-keylink.apk" "$D/luci-app-keylink.ipk"
	;;
status)
	json_init
	if running; then json_add_boolean running 1; else json_add_boolean running 0; fi
	[ -s "$D/rc" ] && json_add_int rc "$(tr -cd 0-9 < "$D/rc")"
	json_add_string current "$(version)"
	json_add_string log "$(tail -n 40 "$D/log" 2>/dev/null)"
	json_dump
	;;
esac
