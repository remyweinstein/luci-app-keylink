#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

# Load only finish() and the message helper, without executing the installer on the host.
for fn in m finish; do
        eval "$(sed -n '/^'"$fn"'() {$/,/^}$/p' "$ROOT/install.sh")"
done
LNG=en

check_finish() (
        enabled="$1"
        KL_TEST="$2"
        DESTDIR="$TEST_DIR"
        WANT_BYEDPI=no
        WANT_ZAPRET=no
        C_OK=''
        C_0=''
        calls=''

        say() { :; }
        ok() { :; }
        warn() { :; }
        run() { calls="${calls}$*|"; }
        uci() { printf '%s\n' "$enabled"; }

        finish >/dev/null
        expected='/etc/init.d/rpcd reload|/etc/init.d/keylink enable|/etc/init.d/keylink restart|'
        if [ "$calls" != "$expected" ]; then
                printf 'FAIL: enabled=%s KL_TEST=%s: %s\n' "$enabled" "$KL_TEST" "$calls" >&2
                exit 1
        fi
)

# Fresh installation, upgrade, and installer dry run must register triggers.
check_finish 0 0
check_finish 1 0
check_finish 0 1

# Registration must not start processes or alter networking while disabled.
(
        . "$ROOT/root/etc/init.d/keylink"
        config_load() { :; }
        config_get_bool() { enabled=0; }
        mkdir() { echo 'FAIL: disabled service tried to start' >&2; exit 1; }
        start_service
)

echo 'OK: installation registers the service without enabling disabled engines'
