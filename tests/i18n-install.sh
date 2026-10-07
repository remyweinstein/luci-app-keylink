#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

for fn in m install_files install_translation do_uninstall; do
        eval "$(sed -n '/^'"$fn"'() {$/,/^}$/p' "$ROOT/install.sh")"
done

SRC="$ROOT"
DESTDIR="$TEST_DIR/root"
TMP="$TEST_DIR/tmp"
STATE_DIR=/etc/keylink
FILE_LIST=$STATE_DIR/installed.list
TARGET="$DESTDIR/usr/lib/lua/luci/i18n/keylink.ru.lmo"
WITH_RU=0
PM=test
ACTION=purge
C_OK=''
C_0=''
calls=''
packages=''
TEST_LANGUAGE=en
LNG=en
say() { :; }
ok() { :; }
warn() { :; }
die() { echo "$*" >&2; exit 1; }
run() { calls="${calls}$*|"; }
pm_installed() { return 1; }
pm_install() { packages="${packages}$*|"; }
check_system() { :; }
ask() { return 0; }
uci() {
        test "$*" = "-q -c $DESTDIR/etc/config get luci.main.lang" || exit 1
        [ "$TEST_LANGUAGE" != missing ] || return 1
        printf '%s\n' "$TEST_LANGUAGE"
}

# English-only installs must not register or install another language.
install_files
install_translation
test ! -f "$TARGET"
test -z "$calls"
test -z "$packages"
# A source checkout has no VERSION and the repository is not substituted.
test ! -f "$DESTDIR/etc/keylink/version"
test ! -f "$DESTDIR/etc/keylink/repo"

# A release archive records its version and repository for the LuCI update button.
(
        SRC="$TEST_DIR/release"
        DESTDIR="$TEST_DIR/release-root"
        KEYLINK_REPO=owner/name
        mkdir -p "$SRC"
        cp -R "$ROOT/root" "$ROOT/htdocs" "$SRC/"
        echo v9.9.9 > "$SRC/VERSION"
        install_files
        test "$(cat "$DESTDIR/etc/keylink/version")" = v9.9.9
        test "$(cat "$DESTDIR/etc/keylink/repo")" = owner/name
        test "$(cat "$DESTDIR/etc/keylink/lang")" = en
        LNG=ru install_files
        test "$(cat "$DESTDIR/etc/keylink/lang")" = ru
)

# A pre-i18n installation has no KeyLink catalog, but LuCI may already use Russian.
check_language() (
        DESTDIR="$TEST_DIR/$1"
        TARGET="$DESTDIR/usr/lib/lua/luci/i18n/keylink.ru.lmo"
        TEST_LANGUAGE="$2"
        install_files
        if [ "$3" = 1 ]; then
                mkdir -p "${TARGET%/*}"
                printf 'base translation' > "${TARGET%/*}/base.ru.lmo"
        fi
        printf '\n# existing user settings\n' >> "$DESTDIR/etc/config/keylink"
        install_translation
        if [ "$4" = 1 ]; then
                cmp "$SRC/i18n/keylink.ru.lmo" "$TARGET"
                grep -qx '/usr/lib/lua/luci/i18n/keylink.ru.lmo' "$DESTDIR$FILE_LIST"
                test "$packages" = 'luci-i18n-base-ru|'
                test "$calls" = 'uci set luci.languages.ru=Русский (Russian)|uci commit luci|'
        else
                test ! -f "$TARGET"
                test -z "$calls"
                test -z "$packages"
        fi
        grep -q '# existing user settings' "$DESTDIR/etc/config/keylink"
)
check_language russian ru 0 1
check_language automatic_russian auto 1 1
check_language unset_russian missing 1 1
check_language empty_russian '' 1 1
check_language automatic_english auto 0 0
check_language unset_english missing 0 0
check_language explicit_english en 1 0
check_language other_language de 1 0

WITH_RU=1
install_translation
cmp "$SRC/i18n/keylink.ru.lmo" "$TARGET"
grep -qx '/usr/lib/lua/luci/i18n/keylink.ru.lmo' "$DESTDIR$FILE_LIST"
test "$packages" = 'luci-i18n-base-ru|'
test "$calls" = 'uci set luci.languages.ru=Русский (Russian)|uci commit luci|'

# Upgrade a previously installed translation without passing --with-ru again.
printf 'old catalog' > "$TARGET"
printf '\n# user settings\n' >> "$DESTDIR/etc/config/keylink"
WITH_RU=0
install_files
install_translation
cmp "$SRC/i18n/keylink.ru.lmo" "$TARGET"
test "$(grep -c '/usr/lib/lua/luci/i18n/keylink.ru.lmo' "$DESTDIR$FILE_LIST")" = 1
grep -q '# user settings' "$DESTDIR/etc/config/keylink"

# Removal must delete only KeyLink's catalog, not another app's translation.
printf 'shared catalog' > "${TARGET%/*}/base.ru.lmo"
do_uninstall >/dev/null
test ! -f "$TARGET"
test -f "${TARGET%/*}/base.ru.lmo"
test ! -e "$DESTDIR/etc/config/keylink"

echo 'OK: optional Russian install, language detection, legacy upgrades, preserved settings, and translation removal'
