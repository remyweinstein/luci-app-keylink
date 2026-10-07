#!/bin/sh
# Установщик KeyLink для OpenWrt (apk и opkg). Справка: sh install.sh --help
# KeyLink installer for OpenWrt (apk and opkg). Help: sh install.sh --help

DEPS="xray-core ucode ucode-mod-uci ucode-mod-fs kmod-nft-tproxy curl"
# Базы для правил geosite:/geoip:. Необязательны: без них такие правила просто
# пропускаются. geosite (~2 МБ) полезнее и ставится первым, geoip (~22 МБ) — если хватит места.
GEO_DEPS="v2ray-geosite v2ray-geoip"
MIN_XRAY_HY2="26.3.27"
MIN_FREE_KB=40000
GH="${GH_MIRROR:-https://github.com}"
GH="${GH%/}"
# При выпуске релиза GitHub Actions подставляет сюда имя репозитория
KEYLINK_REPO="${KEYLINK_REPO:-__REPO__}"
STATE_DIR=/etc/keylink
FILE_LIST=$STATE_DIR/installed.list
TMP=/tmp/keylink-install.$$

ASSUME_YES=0
WANT_BYEDPI=ask
WANT_ZAPRET=ask
WANT_XRAY=ask
WITH_RU=0
XRAY_BIN=/usr/bin/xray
ACTION=install

# Для проверки установщика вне роутера: KL_TEST=1 DESTDIR=/tmp/root sh install.sh
DESTDIR="${DESTDIR:-}"
KL_TEST="${KL_TEST:-0}"

# ---------- язык ----------

# m <english> <русский> — сообщение на языке установщика
m() {
	if [ "$LNG" = ru ]; then printf '%s' "$2"; else printf '%s' "$1"; fi
}

# язык задаётся только ключом --lang, по умолчанию английский
detect_lang() {
	local a prev="" lang=""
	for a in "$@"; do
		case "$prev" in --lang) lang="$a" ;; esac
		case "$a" in --lang=*) lang="${a#--lang=}" ;; esac
		prev="$a"
	done
	case "$lang" in ru) LNG=ru ;; *) LNG=en ;; esac
}

# ---------- вывод ----------

if [ -t 1 ]; then
	C_OK='\033[32m'; C_WARN='\033[33m'; C_ERR='\033[31m'; C_B='\033[1m'; C_0='\033[0m'
else
	C_OK=''; C_WARN=''; C_ERR=''; C_B=''; C_0=''
fi

say()  { printf '%b\n' "${C_B}==>${C_0} $*"; }
ok()   { printf '%b\n' "  ${C_OK}✓${C_0} $*"; }
warn() { printf '%b\n' "  ${C_WARN}!${C_0} $*"; }
die()  { printf '%b\n' "${C_ERR}$(m 'Error:' 'Ошибка:')${C_0} $*" >&2; cleanup; exit 1; }

cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT INT TERM

# Вопрос да/нет. Работает и при запуске через «wget … | sh»: читает с терминала.
ask() {
	local prompt="$1" def="$2" ans hint
	if [ "$def" = y ]; then hint=$(m 'Y/n' 'Д/н'); else hint=$(m 'y/N' 'д/Н'); fi
	if [ "$ASSUME_YES" = 1 ] || ! [ -r /dev/tty ]; then
		[ "$def" = y ]; return
	fi
	printf '%b' "  $prompt [$hint] " > /dev/tty
	read -r ans < /dev/tty || ans=""
	case "$ans" in
		[YyДд]*) return 0 ;;
		[NnНн]*) return 1 ;;
		*) [ "$def" = y ] ;;
	esac
}

usage() {
	if [ "$LNG" = ru ]; then cat <<'EOF'
Установщик KeyLink для OpenWrt (apk и opkg).

  sh install.sh                      установка из распакованного архива
  KEYLINK_URL=https://…/luci-app-keylink.tar.gz sh install.sh
  wget -qO- https://…/install.sh | sh -s -- [ключи]

Ключи:
  -y, --yes            не задавать вопросов (движки DPI не ставятся, если не указаны явно)
  --with-byedpi        установить ByeDPI        --no-byedpi   не устанавливать
  --with-zapret        установить Zapret 2      --no-zapret   не устанавливать
  --xray-update        поставить последний официальный Xray из XTLS/Xray-core
  --no-xray-update     не предлагать замену Xray из репозитория OpenWrt
  --with-ru            установить русский перевод интерфейса LuCI
  --lang en|ru         язык установщика (по умолчанию английский)
  --uninstall          удалить keylink (настройки сохраняются)
  --purge              удалить вместе с настройками
  -h, --help           эта справка

Переменные окружения:
  KEYLINK_URL    адрес архива luci-app-keylink.tar.gz, если скрипт запущен не из архива
                 (по умолчанию — последний релиз репозитория KEYLINK_REPO)
  KEYLINK_REPO   репозиторий на GitHub в виде владелец/имя
  GH_MIRROR      зеркало GitHub (по умолчанию https://github.com)
EOF
	else cat <<'EOF'
KeyLink installer for OpenWrt (apk and opkg).

  sh install.sh                      install from an extracted archive
  KEYLINK_URL=https://…/luci-app-keylink.tar.gz sh install.sh
  wget -qO- https://…/install.sh | sh -s -- [options]

Options:
  -y, --yes            do not ask questions (DPI engines are installed only if requested)
  --with-byedpi        install ByeDPI           --no-byedpi   do not install it
  --with-zapret        install Zapret 2         --no-zapret   do not install it
  --xray-update        install the latest official Xray from XTLS/Xray-core
  --no-xray-update     do not offer to replace Xray from the OpenWrt repository
  --with-ru            install the Russian LuCI translation
  --lang en|ru         installer language (default: English)
  --uninstall          remove keylink (settings are kept)
  --purge              remove keylink and its settings
  -h, --help           show this help

Environment variables:
  KEYLINK_URL    luci-app-keylink.tar.gz URL when the script is not run from an archive
                 (default: the latest release of KEYLINK_REPO)
  KEYLINK_REPO   GitHub repository as owner/name
  GH_MIRROR      GitHub mirror (default: https://github.com)
EOF
	fi
	exit 0
}

detect_lang "$@"

while [ $# -gt 0 ]; do
	case "$1" in
		-y|--yes)       ASSUME_YES=1 ;;
		--with-byedpi)  WANT_BYEDPI=yes ;;
		--no-byedpi)    WANT_BYEDPI=no ;;
		--with-zapret)  WANT_ZAPRET=yes ;;
		--no-zapret)    WANT_ZAPRET=no ;;
		--xray-update)     WANT_XRAY=yes ;;
		--no-xray-update)  WANT_XRAY=no ;;
		--with-ru)      WITH_RU=1 ;;
		--lang)         [ $# -gt 1 ] && shift ;;
		--lang=*)       ;;
		--uninstall)    ACTION=uninstall ;;
		--purge)        ACTION=purge ;;
		-h|--help)      usage ;;
		*) die "$(m "unknown option: $1 (see --help)" "неизвестный ключ: $1 (см. --help)")" ;;
	esac
	shift
done

# ---------- окружение ----------

run() {
	# команды, меняющие систему; в тестовом режиме только печатаются
	if [ "$KL_TEST" = 1 ]; then echo "    [$(m test тест)] $*"; return 0; fi
	"$@"
}

fetch() {
	# fetch <url> <файл>; wget в OpenWrt — это uclient-fetch
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 -o "$2" "$1"
	else
		wget -q -T 30 -O "$2" "$1"
	fi
}

fetch_stdout() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL --connect-timeout 15 "$1"
	else
		wget -q -T 30 -O- "$1"
	fi
}

check_system() {
	[ "$KL_TEST" = 1 ] && { PM="test"; EXT="ipk"; ARCH="test"; return; }

	[ "$(id -u)" = 0 ] || die "$(m 'run as root' 'запустите от root')"
	[ -f /etc/openwrt_release ] || die "$(m 'this is not OpenWrt' 'это не OpenWrt')"
	. /etc/openwrt_release
	ARCH="$DISTRIB_ARCH"

	if command -v apk >/dev/null 2>&1; then
		PM=apk; EXT=apk
	elif command -v opkg >/dev/null 2>&1; then
		PM=opkg; EXT=ipk
	else
		die "$(m 'no package manager found (apk or opkg)' 'не найден менеджер пакетов (apk или opkg)')"
	fi

	command -v nft >/dev/null 2>&1 || die "$(m 'OpenWrt with nftables (fw4) is required, that is, 22.03 or later' \
		'нужен OpenWrt с nftables (fw4), то есть 22.03 или новее')"

	ok "$(m "OpenWrt ${DISTRIB_RELEASE:-?}, architecture $ARCH, packages: $PM" \
		"OpenWrt ${DISTRIB_RELEASE:-?}, архитектура $ARCH, пакеты: $PM")"
}

free_mb() {
	local free
	free=$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')
	[ -n "$free" ] || free=$(df -k / 2>/dev/null | awk 'NR == 2 { print $4 }')
	echo $(( ${free:-0} / 1024 ))
}

check_space() {
	local free
	free=$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')
	[ -n "$free" ] || free=$(df -k / 2>/dev/null | awk 'NR == 2 { print $4 }')
	[ -n "$free" ] || return 0
	if [ "$free" -lt "$MIN_FREE_KB" ]; then
		warn "$(m "$((free / 1024)) MB free, at least $((MIN_FREE_KB / 1024)) MB is recommended" \
			"свободно $((free / 1024)) МБ, рекомендуется не меньше $((MIN_FREE_KB / 1024)) МБ")"
		ask "$(m 'Continue anyway?' 'Продолжить всё равно?')" n || die "$(m 'not enough space' 'мало места')"
	else
		ok "$(m "$((free / 1024)) MB free" "свободно $((free / 1024)) МБ")"
	fi
}

pm_update() {
	case "$PM" in
		apk)  run apk update >/dev/null ;;
		opkg) run opkg update >/dev/null ;;
	esac
}

pm_installed() {
	case "$PM" in
		apk)  apk info -e "$1" >/dev/null 2>&1 ;;
		opkg) opkg list-installed 2>/dev/null | grep -q "^$1 " ;;
		*)    return 1 ;;
	esac
}

pm_install() {
	case "$PM" in
		apk)  run apk add "$@" ;;
		opkg) run opkg install "$@" ;;
		test) echo "    [$(m test тест)] $(m 'installing packages' 'установка пакетов'): $*" ;;
	esac
}

# pm_install_file <файл> [untrusted]
pm_install_file() {
	case "$PM" in
		apk)
			if [ "$2" = untrusted ]; then run apk add --allow-untrusted "$1"
			else run apk add "$1"; fi ;;
		opkg) run opkg install "$1" ;;
		test) echo "    [$(m test тест)] $(m 'installing file' 'установка файла') $1" ;;
	esac
}

pm_remove() {
	case "$PM" in
		apk)  run apk del "$@" ;;
		opkg) run opkg remove "$@" ;;
	esac
}

# Адрес файла из последнего релиза на GitHub: gh_asset <владелец/репо> <регулярка>
gh_asset() {
	fetch_stdout "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
		| grep -o 'https://github\.com/[^"]*' | grep -E "$2" | head -n 1 \
		| sed "s#^https://github\.com#$GH#"
}

disable_service() {
	for s in "$@"; do
		[ -x "$DESTDIR/etc/init.d/$s" ] || continue
		run "/etc/init.d/$s" stop >/dev/null 2>&1
		run "/etc/init.d/$s" disable >/dev/null 2>&1
		ok "$(m "the standalone $s service is stopped and disabled; keylink manages the engine" \
			"собственная служба $s остановлена и отключена — движком управляет keylink")"
	done
}

version_ge() {
	# version_ge A B — A >= B
	[ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

# ---------- установка ----------

install_deps() {
	say "$(m 'Dependencies' 'Зависимости')"
	pm_update || warn "$(m 'could not update package lists' 'не удалось обновить списки пакетов')"

	local missing="" p
	for p in $DEPS; do
		pm_installed "$p" || missing="$missing $p"
	done

	if [ -z "$missing" ]; then
		ok "$(m 'everything is already installed' 'всё уже установлено')"
	elif pm_install $missing > "$TMP.log" 2>&1; then
		ok "$(m 'installed' 'установлено'):$missing"
	else
		# по одному, чтобы понять, чего именно не хватает
		local failed=""
		for p in $missing; do
			pm_installed "$p" && continue
			pm_install "$p" > "$TMP.log" 2>&1 || failed="$failed $p"
		done
		if [ -n "$failed" ]; then
			echo "  $(m 'Package manager output:' 'Сообщение менеджера пакетов:')" >&2
			tail -n 5 "$TMP.log" | sed 's/^/    /' >&2
			rm -f "$TMP.log"
			die "$(m 'could not install' 'не удалось установить'):$failed"
		fi
		ok "$(m 'installed' 'установлено'):$missing"
	fi

	local geo_missing="" geo_failed=""
	for p in $GEO_DEPS; do
		pm_installed "$p" && continue
		if pm_install "$p" > "$TMP.log" 2>&1; then
			geo_missing="$geo_missing $p"
		else
			geo_failed="$geo_failed $p"
		fi
	done
	rm -f "$TMP.log"
	[ -n "$geo_missing" ] && ok "$(m 'installed' 'установлено'):$geo_missing"
	if [ -n "$geo_failed" ]; then
		warn "$(m "not installed:$geo_failed (probably not enough space: $(free_mb) MB free)" \
			"не установлено:$geo_failed (скорее всего, не хватило места: свободно $(free_mb) МБ)")"
		warn "$(m 'this is fine: rules with geoip:/geosite: are skipped, everything else works' \
			'это не страшно: правила с geoip:/geosite: будут пропускаться, остальное работает')"
	fi

	[ "$KL_TEST" = 1 ] && return
	check_xray
}

xray_version() {
	"${1:-$XRAY_BIN}" version 2>/dev/null | sed -n 's/^Xray \([0-9][0-9.]*\).*/\1/p' | head -n 1
}

check_xray() {
	local v
	v=$(xray_version)
	if [ "$WANT_XRAY" = yes ]; then
		update_xray || warn "$(m "keeping Xray ${v:-?}" "оставлен Xray ${v:-?}")"
	elif [ -z "$v" ]; then
		warn "$(m 'could not determine the Xray version' 'не удалось определить версию Xray')"
	elif version_ge "$v" "$MIN_XRAY_HY2"; then
		ok "Xray $v"
	else
		warn "$(m "Xray $v from the OpenWrt repository: Hysteria2 requires $MIN_XRAY_HY2 or later" \
			"Xray $v из репозитория OpenWrt: Hysteria2 требует $MIN_XRAY_HY2 или новее")"
		if [ "$WANT_XRAY" = ask ] && \
		   ask "$(m 'Download the official Xray from XTLS/Xray-core (~20 MB archive, ~35 MB on flash)?' \
			'Скачать официальный Xray из XTLS/Xray-core (архив ~20 МБ, на флеше ~35 МБ)?')" y; then
			update_xray || warn "$(m "keeping Xray $v: Hysteria2 will not work, other protocols work" \
				"оставлен Xray $v: Hysteria2 не будет работать, остальные протоколы работают")"
		else
			warn "$(m 'Hysteria2 will not work, other protocols work' 'Hysteria2 не будет работать, остальные протоколы работают')"
		fi
	fi
}

# Имя официальной сборки XTLS/Xray-core для архитектуры OpenWrt
xray_asset() {
	case "$ARCH" in
		aarch64*)              echo arm64-v8a ;;
		x86_64)                echo 64 ;;
		i386*|i486*|i686*)     echo 32 ;;
		arm_cortex-a*)         echo arm32-v7a ;;
		arm_arm1176*)          echo arm32-v6 ;;
		arm_*)                 echo arm32-v5 ;;
		mips64el*)             echo mips64le ;;
		mips64*)               echo mips64 ;;
		mipsel*)               echo mips32le ;;
		mips*)                 echo mips32 ;;
		riscv64*)              echo riscv64 ;;
		loongarch64*)          echo loong64 ;;
	esac
}

# Заменить /usr/bin/xray последней официальной сборкой (пакет xray-core остаётся)
update_xray() {
	say "$(m 'Official Xray' 'Официальный Xray')"
	local asset url sum got member v
	asset=$(xray_asset)
	[ -n "$asset" ] || { warn "$(m "no official Xray build for $ARCH" "нет официальной сборки Xray для $ARCH")"; return 1; }
	url="$GH/XTLS/Xray-core/releases/latest/download/Xray-linux-$asset.zip"

	if [ "$(free_mb)" -lt 36 ]; then
		warn "$(m "~36 MB of free space is required, $(free_mb) MB available" "нужно ~36 МБ свободного места, есть $(free_mb) МБ")"
		return 1
	fi
	command -v unzip >/dev/null 2>&1 || pm_install unzip >/dev/null 2>&1 \
		|| { warn "$(m 'could not install unzip' 'не удалось установить unzip')"; return 1; }

	mkdir -p "$TMP"
	fetch "$url" "$TMP/xray.zip" || { warn "$(m "could not download $url" "не удалось скачать $url")"; return 1; }
	sum=$(fetch_stdout "$url.dgst" 2>/dev/null | sed -n 's/^SHA2-256= *//p' | head -n 1)
	got=$(sha256sum "$TMP/xray.zip" | cut -d ' ' -f 1)
	if [ -z "$sum" ] || [ "$sum" != "$got" ]; then
		rm -f "$TMP/xray.zip"
		warn "$(m 'archive checksum mismatch' 'контрольная сумма архива не совпала')"
		return 1
	fi
	ok "$(m 'archive downloaded, checksum verified' 'архив скачан, контрольная сумма совпала')"

	# в сборках для MIPS есть вариант без FPU, он и нужен OpenWrt
	member=xray
	unzip -l "$TMP/xray.zip" 2>/dev/null | grep -q ' xray_softfloat$' && member=xray_softfloat

	if ! unzip -p "$TMP/xray.zip" "$member" > "$XRAY_BIN.new" 2>/dev/null; then
		rm -f "$XRAY_BIN.new" "$TMP/xray.zip"
		warn "$(m 'could not extract Xray (not enough space?)' 'не удалось распаковать Xray (мало места?)')"
		return 1
	fi
	rm -f "$TMP/xray.zip"
	chmod 755 "$XRAY_BIN.new"

	v=$(xray_version "$XRAY_BIN.new")
	if [ -z "$v" ]; then
		rm -f "$XRAY_BIN.new"
		warn "$(m "the downloaded Xray does not run on $ARCH" "скачанный Xray не запускается на $ARCH")"
		return 1
	fi
	mv -f "$XRAY_BIN.new" "$XRAY_BIN"
	# чтобы opkg upgrade не вернул старую версию из репозитория
	[ "$PM" = opkg ] && opkg flag hold xray-core >/dev/null 2>&1
	ok "Xray $v"
}

find_source() {
	local here
	here=$(cd "$(dirname "$0")" 2>/dev/null && pwd)

	if [ -n "$here" ] && [ -d "$here/root" ] && [ -d "$here/htdocs" ]; then
		SRC="$here"
		return
	fi

	# имя репозитория известно, только если workflow его подставил (владелец/имя)
	case "$KEYLINK_REPO" in
		*/*) [ -n "$KEYLINK_URL" ] || \
			KEYLINK_URL="$GH/$KEYLINK_REPO/releases/latest/download/luci-app-keylink.tar.gz" ;;
	esac

	[ -n "$KEYLINK_URL" ] || die "$(m "package files not found.
  Run install.sh from the extracted archive:
    tar xzf luci-app-keylink.tar.gz && sh luci-app-keylink/install.sh
  or specify the archive URL:
    KEYLINK_URL=https://…/luci-app-keylink.tar.gz sh install.sh" "не найдены файлы пакета.
  Запустите install.sh из распакованного архива:
    tar xzf luci-app-keylink.tar.gz && sh luci-app-keylink/install.sh
  или укажите адрес архива:
    KEYLINK_URL=https://…/luci-app-keylink.tar.gz sh install.sh")"

	say "$(m 'Downloading' 'Загрузка') $KEYLINK_URL"
	mkdir -p "$TMP/src"
	fetch "$KEYLINK_URL" "$TMP/pkg.tar.gz" || die "$(m 'could not download the archive' 'не удалось скачать архив')"
	tar xzf "$TMP/pkg.tar.gz" -C "$TMP/src" || die "$(m 'the archive is corrupted' 'архив повреждён')"
	SRC=$(find "$TMP/src" -type d -name root -path '*/root' | head -n 1)
	SRC="${SRC%/root}"
	[ -d "$SRC/htdocs" ] || die "$(m 'the archive has no root/ and htdocs/ directories' 'в архиве нет каталогов root/ и htdocs/')"
	ok "$(m 'archive extracted' 'архив распакован')"
}

install_files() {
	say "$(m 'KeyLink files' 'Файлы keylink')"
	[ -n "$SRC" ] || find_source

	local cfg="$DESTDIR/etc/config/keylink" keep=0
	if [ -f "$cfg" ]; then
		keep=1
		mkdir -p "$TMP"
		cp "$cfg" "$TMP/keylink.conf"
	fi

	mkdir -p "$DESTDIR/www" "$DESTDIR$STATE_DIR"
	cp -R "$SRC/root/." "$DESTDIR/" || die "$(m 'could not copy files' 'не удалось скопировать файлы')"
	cp -R "$SRC/htdocs/." "$DESTDIR/www/" || die "$(m 'could not copy the web interface' 'не удалось скопировать интерфейс')"

	if [ "$keep" = 1 ]; then
		cp "$TMP/keylink.conf" "$cfg"
		ok "$(m 'existing settings kept' 'существующие настройки сохранены')"
	fi

	# версия, репозиторий и язык установщика — для кнопки обновления в LuCI
	echo "$LNG" > "$DESTDIR$STATE_DIR/lang"
	if [ -s "$SRC/VERSION" ]; then
		cp "$SRC/VERSION" "$DESTDIR$STATE_DIR/version"
	else
		rm -f "$DESTDIR$STATE_DIR/version"
	fi
	case "${KEYLINK_REPO:-}" in
		*/*) echo "$KEYLINK_REPO" > "$DESTDIR$STATE_DIR/repo" ;;
	esac

	# список файлов для удаления (настройки в него не входят)
	{
		(cd "$SRC/root" && find . -type f ! -path './etc/config/keylink' | sed 's#^\.##')
		(cd "$SRC/htdocs" && find . -type f | sed 's#^\.#/www#')
	} > "$DESTDIR$FILE_LIST"

	chmod +x "$DESTDIR/etc/init.d/keylink" \
		"$DESTDIR/usr/libexec/rpcd/keylink" \
		"$DESTDIR"/usr/libexec/keylink/*.sh 2>/dev/null

	ok "$(m 'files installed' 'установлено файлов'): $(wc -l < "$DESTDIR$FILE_LIST")"
}

install_translation() {
	local target=/usr/lib/lua/luci/i18n/keylink.ru.lmo language install_base="$WITH_RU"
	if [ "$WITH_RU" != 1 ] && [ ! -f "$DESTDIR$target" ]; then
		# Preserve Russian UI when upgrading from versions without a catalog.
		language=$(uci -q -c "$DESTDIR/etc/config" get luci.main.lang 2>/dev/null) || language=auto
		case "$language" in
			ru) ;;
			auto|'')
				[ -f "$DESTDIR/usr/lib/lua/luci/i18n/base.ru.lmo" ] || return 0 ;;
			*) return 0 ;;
		esac
		install_base=1
	fi

	say "$(m 'Russian LuCI translation' 'Русский перевод LuCI')"
	if [ -s "$SRC/i18n/keylink.ru.lmo" ]; then
		mkdir -p "$DESTDIR${target%/*}"
		cp "$SRC/i18n/keylink.ru.lmo" "$DESTDIR$target" || die "$(m 'could not install the translation' 'не удалось установить перевод')"
	elif command -v po2lmo >/dev/null 2>&1 && [ -f "$SRC/po/ru/keylink.po" ]; then
		mkdir -p "$DESTDIR${target%/*}"
		po2lmo "$SRC/po/ru/keylink.po" "$DESTDIR$target" || die "$(m 'could not build the translation' 'не удалось собрать перевод')"
	elif [ "$WITH_RU" != 1 ] && [ -f "$DESTDIR$target" ]; then
		warn "$(m 'the sources have no compiled translation; keeping the installed one' \
			'в исходниках нет собранного перевода; сохранён ранее установленный')"
	else
		die "$(m 'no compiled translation: use a release archive or run sh scripts/build-i18n.sh with po2lmo from the LuCI SDK' \
			'нет собранного перевода: используйте архив релиза или выполните sh scripts/build-i18n.sh с po2lmo из LuCI SDK')"
	fi

	printf '%s\n' "$target" >> "$DESTDIR$FILE_LIST"
	if [ "$install_base" = 1 ]; then
		pm_installed luci-i18n-base-ru || pm_install luci-i18n-base-ru \
			|| warn "$(m 'could not install the translation of shared LuCI controls' 'не удалось установить перевод общих элементов LuCI')"
	fi
	run uci set 'luci.languages.ru=Русский (Russian)'
	run uci commit luci
	ok "$(m 'Russian is available in LuCI: System → System → Language and Style' \
		'русский доступен в LuCI: System → System → Language and Style')"
}

install_byedpi() {
	say "ByeDPI"
	if command -v ciadpi >/dev/null 2>&1 || command -v byedpi >/dev/null 2>&1; then
		ok "$(m 'already installed' 'уже установлен')"
		disable_service byedpi
		return 0
	fi

	if pm_install byedpi >/dev/null 2>&1 && command -v ciadpi >/dev/null 2>&1; then
		ok "$(m 'installed from the OpenWrt repository' 'установлен из репозитория OpenWrt')"
	else
		local url
		url=$(gh_asset 1andrevich/ByeDPI-OpenWrt "byedpi_.*${ARCH}\.${EXT}\$")
		if [ -z "$url" ]; then
			warn "$(m "no ByeDPI build found for $ARCH; install the package manually" \
				"не найдена сборка ByeDPI для $ARCH — установите пакет вручную")"
			return 1
		fi
		warn "$(m 'build from 1andrevich/ByeDPI-OpenWrt (not from the official repository)' \
			'сборка из 1andrevich/ByeDPI-OpenWrt (не из официального репозитория)')"
		fetch "$url" "$TMP/byedpi.$EXT" || { warn "$(m "could not download $url" "не удалось скачать $url")"; return 1; }
		pm_install_file "$TMP/byedpi.$EXT" untrusted >/dev/null 2>&1 \
			|| { warn "$(m 'could not install the ByeDPI package' 'не удалось установить пакет ByeDPI')"; return 1; }
		ok "$(m 'installed' 'установлен')"
	fi
	disable_service byedpi
}

install_zapret() {
	say "Zapret 2"
	pm_installed kmod-nft-queue || pm_install kmod-nft-queue >/dev/null 2>&1 \
		|| warn "$(m 'could not install kmod-nft-queue; Zapret 2 will not work without it' \
			'не удалось установить kmod-nft-queue — без него Zapret 2 работать не будет')"

	if [ -n "$(ucode /usr/share/keylink/dpi.uc bin zapret 2>/dev/null)" ]; then
		ok "$(m 'already installed' 'уже установлен')"
	elif pm_install zapret2 >/dev/null 2>&1 && command -v nfqws2 >/dev/null 2>&1; then
		ok "$(m 'installed from the OpenWrt repository' 'установлен из репозитория OpenWrt')"
	else
		warn "$(m 'build from 1andrevich/zapret2-openwrt (not from the official repository)' \
			'сборка из 1andrevich/zapret2-openwrt (не из официального репозитория)')"
		local base="$GH/1andrevich/zapret2-openwrt/releases/latest/download"
		if [ "$PM" = apk ]; then
			fetch "$base/zapret2-1andrevich.pub" "$DESTDIR/etc/apk/keys/zapret2-1andrevich.pub" \
				|| warn "$(m 'could not download the signing key' 'не удалось скачать ключ подписи')"
		fi
		fetch "$base/zapret2_${ARCH}.${EXT}" "$TMP/zapret2.$EXT" \
			|| { warn "$(m "no Zapret 2 build found for $ARCH; install the package manually" \
				"не найдена сборка Zapret 2 для $ARCH — установите пакет вручную")"; return 1; }
		pm_install_file "$TMP/zapret2.$EXT" >/dev/null 2>&1 \
			|| { warn "$(m 'could not install the Zapret 2 package' 'не удалось установить пакет Zapret 2')"; return 1; }
		ok "$(m 'installed' 'установлен')"
	fi

	disable_service zapret2 zapret
	locate_zapret
}

# Если пакет положил файлы в нестандартное место — запоминаем пути в UCI
locate_zapret() {
	[ "$KL_TEST" = 1 ] && return
	local bin lua fake changed=0

	if [ -z "$(ucode /usr/share/keylink/dpi.uc bin zapret 2>/dev/null)" ]; then
		bin=$(find /opt /usr -type f -name nfqws2 2>/dev/null | head -n 1)
		[ -n "$bin" ] && { uci set keylink.zapret.bin="$bin"; changed=1; }
	fi
	if ! ucode /usr/share/keylink/dpi.uc args zapret >/dev/null 2>&1; then
		lua=$(find /opt /usr -type f -name zapret-lib.lua 2>/dev/null | head -n 1)
		[ -n "$lua" ] && { uci set keylink.zapret.lua_dir="${lua%/*}"; changed=1; }
		fake=$(find /opt /usr -type f -name quic_initial_www_google_com.bin 2>/dev/null | head -n 1)
		[ -n "$fake" ] && { uci set keylink.zapret.fake_dir="${fake%/*}"; changed=1; }
	fi
	[ "$changed" = 1 ] && uci commit keylink && ok "$(m 'zapret2 file paths saved to settings' 'пути к файлам zapret2 записаны в настройки')"

	if [ -n "$(ucode /usr/share/keylink/dpi.uc bin zapret 2>/dev/null)" ] \
	   && ucode /usr/share/keylink/dpi.uc args zapret >/dev/null 2>&1; then
		ok "$(m 'nfqws2 and Lua scripts found' 'nfqws2 и Lua-скрипты найдены')"
	else
		warn "$(m 'nfqws2 or zapret-lib.lua not found; set the paths manually: uci set keylink.zapret.bin=… / lua_dir=…' \
			'не найдены nfqws2 или zapret-lib.lua — укажите пути вручную: uci set keylink.zapret.bin=… / lua_dir=…')"
	fi
}

choose_dpi() {
	if [ "$WANT_BYEDPI" = ask ] || [ "$WANT_ZAPRET" = ask ]; then
		say "$(m 'DPI bypass (optional)' 'Обход DPI (необязательно)')"
		echo "  $(m 'The engines lift blocking and throttling (YouTube, Discord) without a VPN server.' \
			'Движки снимают блокировки и замедление (YouTube, Discord) без VPN-сервера.')"
	fi
	if [ "$WANT_BYEDPI" = ask ]; then
		ask "$(m 'Install ByeDPI (SOCKS-level bypass, ~100 KB)?' 'Установить ByeDPI (обход на уровне SOCKS, ~100 КБ)?')" n \
			&& WANT_BYEDPI=yes || WANT_BYEDPI=no
	fi
	if [ "$WANT_ZAPRET" = ask ]; then
		ask "$(m 'Install Zapret 2 (packet-level bypass, ~1 MB)?' 'Установить Zapret 2 (обход на уровне пакетов, ~1 МБ)?')" n \
			&& WANT_ZAPRET=yes || WANT_ZAPRET=no
	fi
}

finish() {
	say "$(m 'Finishing' 'Завершение')"
	rm -rf "$DESTDIR"/tmp/luci-indexcache* "$DESTDIR"/tmp/luci-modulecache 2>/dev/null
	# reload перезапускает rpcd с новыми плагинами и ACL, но сохраняет сессии:
	# обновление из LuCI не выкидывает пользователя на страницу входа
	run /etc/init.d/rpcd reload
	run /etc/init.d/keylink enable
	ok "$(m 'service enabled at boot' 'служба добавлена в автозагрузку')"

	# Даже при enabled=0 нужно зарегистрировать UCI-триггер в procd,
	# иначе первое «Сохранить и применить» в LuCI не запустит службу.
	if run /etc/init.d/keylink restart; then
		ok "$(m 'service registered in procd, saved settings applied' 'служба зарегистрирована в procd, сохранённые настройки применены')"
	else
		warn "$(m 'could not restart KeyLink; check logread -e keylink' 'не удалось перезапустить KeyLink — проверьте logread -e keylink')"
	fi

	echo
	if [ "$LNG" = ru ]; then
		printf '%b\n' "${C_OK}Готово.${C_0} Откройте LuCI → Службы → KeyLink:"
		echo "  1. «Серверы» или «Подписки» — добавьте серверы;"
		echo "  2. «Общие» — включите службу и выберите основной маршрут;"
		echo "  3. «Сохранить и применить»."
		[ "$WANT_BYEDPI" = yes ] || [ "$WANT_ZAPRET" = yes ] && \
			echo "  Для обхода DPI: вкладка «Обход DPI» — подберите стратегию тестером."
		echo "  Если страницы нет, обновите браузер с очисткой кэша (Ctrl+F5)."
	else
		printf '%b\n' "${C_OK}Done.${C_0} Open LuCI → Services → KeyLink:"
		echo "  1. Servers or Subscriptions: add servers;"
		echo "  2. General: enable the service and choose the default route;"
		echo "  3. Save & Apply."
		[ "$WANT_BYEDPI" = yes ] || [ "$WANT_ZAPRET" = yes ] && \
			echo "  For DPI bypass: on the DPI Bypass tab, pick a strategy with the tester."
		echo "  If the page is missing, reload the browser with a cache refresh (Ctrl+F5)."
	fi
}

do_install() {
	say "$(m 'Installing KeyLink' 'Установка KeyLink')"
	check_system
	[ "$KL_TEST" = 1 ] || check_space
	ask "$(m 'Continue?' 'Продолжить?')" y || exit 0

	find_source        # сначала убедиться, что есть что ставить
	install_deps
	install_files
	install_translation
	choose_dpi
	[ "$WANT_BYEDPI" = yes ] && { install_byedpi || warn "$(m 'ByeDPI not installed; everything else works' 'ByeDPI не установлен, остальное работает')"; }
	[ "$WANT_ZAPRET" = yes ] && { install_zapret || warn "$(m 'Zapret 2 not installed; everything else works' 'Zapret 2 не установлен, остальное работает')"; }
	finish
}

# ---------- удаление ----------

do_uninstall() {
	say "$(m 'Removing KeyLink' 'Удаление KeyLink')"
	check_system
	if [ "$ACTION" = purge ]; then
		ask "$(m 'Remove keylink together with its settings?' 'Удалить keylink вместе с настройками?')" y || exit 0
	else
		ask "$(m 'Remove keylink? Settings stay in /etc/config/keylink' 'Удалить keylink? Настройки останутся в /etc/config/keylink')" y || exit 0
	fi

	# stop возвращает настройки dnsmasq и убирает правила nftables
	if [ -x "$DESTDIR/etc/init.d/keylink" ]; then
		run /etc/init.d/keylink stop
		run /etc/init.d/keylink disable
		ok "$(m 'service stopped' 'служба остановлена')"
	fi

	if grep -q 'keylink/sub-cron.sh' "$DESTDIR/etc/crontabs/root" 2>/dev/null; then
		sed -i '\#/usr/libexec/keylink/sub-cron.sh#d' "$DESTDIR/etc/crontabs/root"
		run /etc/init.d/cron restart >/dev/null 2>&1
		ok "$(m 'cron job removed' 'задание cron удалено')"
	fi

	local n=0 f
	if [ -f "$DESTDIR$FILE_LIST" ]; then
		while IFS= read -r f; do
			[ -n "$f" ] && rm -f "$DESTDIR$f" && n=$((n + 1))
		done < "$DESTDIR$FILE_LIST"
	else
		# установка без списка файлов (например, ручное копирование)
		for f in /etc/init.d/keylink /usr/libexec/rpcd/keylink /usr/share/luci/menu.d/luci-app-keylink.json \
		         /usr/share/rpcd/acl.d/luci-app-keylink.json; do
			rm -f "$DESTDIR$f" && n=$((n + 1))
		done
	fi
	rm -rf "$DESTDIR/usr/libexec/keylink" "$DESTDIR/usr/share/keylink" \
	       "$DESTDIR/www/luci-static/resources/keylink" \
	       "$DESTDIR/www/luci-static/resources/view/keylink" \
	       "$DESTDIR/var/etc/keylink" "$DESTDIR"/tmp/keylink-*
	rm -f "$DESTDIR$FILE_LIST"
	rm -f "$DESTDIR/usr/lib/lua/luci/i18n/keylink.ru.lmo"
	ok "$(m 'files removed' 'удалено файлов'): $n"

	if [ "$ACTION" = purge ]; then
		rm -rf "$DESTDIR/etc/config/keylink" "$DESTDIR$STATE_DIR"
		ok "$(m 'settings removed' 'настройки удалены')"
	else
		rmdir "$DESTDIR$STATE_DIR" 2>/dev/null
	fi

	rm -rf "$DESTDIR"/tmp/luci-indexcache* "$DESTDIR"/tmp/luci-modulecache 2>/dev/null
	run /etc/init.d/rpcd restart

	echo
	local rmcmd="opkg remove"
	[ "$PM" = apk ] && rmcmd="apk del"
	printf '%b\n' "${C_OK}$(m 'Done.' 'Готово.')${C_0} $(m \
		'The xray-core, byedpi, and zapret2 packages were not removed; remove them yourself if needed:' \
		'Пакеты xray-core, byedpi и zapret2 не удалялись — при необходимости удалите их сами:')"
	echo "  $rmcmd xray-core byedpi zapret2"
}

case "$ACTION" in
	install)         do_install ;;
	uninstall|purge) do_uninstall ;;
esac
