#!/bin/sh
# Вызывается cron каждый час; сам решает, какие подписки пора обновить.
[ "$(uci -q get keylink.main.enabled)" = 1 ] || exit 0

out=$(ucode /usr/share/keylink/subscribe.uc cron)
rc=$?
[ "$out" != "[ ]" ] && [ "$out" != "[]" ] && logger -t keylink-sub "$out"
[ $rc = 10 ] && /etc/init.d/keylink reload
exit 0
