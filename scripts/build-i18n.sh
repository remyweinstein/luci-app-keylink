#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
OUT="${1:-$ROOT/i18n}"
PO2LMO="${PO2LMO:-po2lmo}"

command -v "$PO2LMO" >/dev/null 2>&1 || {
        echo "po2lmo is required (from the LuCI SDK host tools); set PO2LMO to its path." >&2
        exit 1
}

mkdir -p "$OUT"
"$PO2LMO" "$ROOT/po/ru/keylink.po" "$OUT/keylink.ru.lmo"
test -s "$OUT/keylink.ru.lmo"
