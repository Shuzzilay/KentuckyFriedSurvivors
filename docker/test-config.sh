#!/usr/bin/env bash
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA="${HERE}/testdata"
INI_AWK="${HERE}/patch-ini.awk"
SB_AWK="${HERE}/patch-sandbox.awk"

command -v gawk    >/dev/null || { echo "[test] gawk is required"; exit 1; }
command -v sqlite3 >/dev/null || { echo "[test] sqlite3 is required"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()   { echo "  PASS: $*"; PASS=$(( PASS + 1 )); }
bad()  { echo "  FAIL: $*"; FAIL=$(( FAIL + 1 )); }
check() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$3', got '$2')"; fi; }

STOCK_INI="${DATA}/servertest.ini"
STOCK_SB="${DATA}/servertest_SandboxVars.lua"

echo "[test] sandbox: scope-qualified assignment"
cat >"$WORK/sb.txt" <<'EOF'
CharacterFreePoints=6
MultiHitZombies=true
MultiplierConfig.Global=5.0
MinutesPerPage=1.0
ZombieLore.Transmission=2
EOF
gawk -f "$SB_AWK" "$WORK/sb.txt" "$STOCK_SB" >"$WORK/sb.lua" 2>"$WORK/sb.err"
check "no warnings"        "$(wc -c <"$WORK/sb.err")" "0"
check "line count preserved" "$(wc -l <"$WORK/sb.lua")" "$(wc -l <"$STOCK_SB")"
check "exactly 5 lines changed" "$(diff "$STOCK_SB" "$WORK/sb.lua" | grep -c '^>')" "5"
check "float value written"  "$(grep -cE '^        Global = 5\.0,$' "$WORK/sb.lua")" "1"
check "nested indent kept"   "$(grep -cE '^        Transmission = 2,$' "$WORK/sb.lua")" "1"

echo "[test] sandbox: duplicate key names resolve by scope"
printf 'MultiplierConfig.Farming=2.0\n' >"$WORK/f1.txt"
gawk -f "$SB_AWK" "$WORK/f1.txt" "$STOCK_SB" >"$WORK/f1.lua" 2>/dev/null
check "scoped hits nested"    "$(grep -cE '^        Farming = 2\.0,$' "$WORK/f1.lua")" "1"
check "scoped spares top"     "$(grep -cE '^    Farming = 3,$'       "$WORK/f1.lua")" "1"

printf 'Farming=6\n' >"$WORK/f2.txt"
gawk -f "$SB_AWK" "$WORK/f2.txt" "$STOCK_SB" >"$WORK/f2.lua" 2>/dev/null
check "bare hits top"         "$(grep -cE '^    Farming = 6,$'       "$WORK/f2.lua")" "1"
check "bare spares nested"    "$(grep -cE '^        Farming = 1\.0,$' "$WORK/f2.lua")" "1"

echo "[test] empty assignments must be a byte-identical no-op"
: >"$WORK/empty.txt"
gawk -f "$SB_AWK" "$WORK/empty.txt" "$STOCK_SB" >"$WORK/e.lua" 2>/dev/null
if cmp -s "$STOCK_SB" "$WORK/e.lua"; then ok "sandbox unchanged"; else bad "sandbox corrupted by empty input"; fi
gawk -f "$INI_AWK" "$WORK/empty.txt" "$STOCK_INI" >"$WORK/e.ini" 2>/dev/null
check "ini keys unchanged" \
    "$(diff <(grep -E '^[A-Za-z0-9_]+=' "$STOCK_INI") <(grep -E '^[A-Za-z0-9_]+=' "$WORK/e.ini") | grep -c '^[<>]')" "0"

echo "[test] unknown settings are reported, not silently dropped"
printf 'NoSuchSetting=1\n' >"$WORK/bad.txt"
gawk -f "$SB_AWK" "$WORK/bad.txt" "$STOCK_SB" >/dev/null 2>"$WORK/bad.err"
check "sandbox warns" "$(grep -c 'no such setting: NoSuchSetting' "$WORK/bad.err")" "1"
gawk -f "$INI_AWK" "$WORK/bad.txt" "$STOCK_INI" >/dev/null 2>"$WORK/bad2.err"
check "ini warns"     "$(grep -c 'no such setting: nosuchsetting' "$WORK/bad2.err")" "1"

echo "[test] ini: values containing the delimiters survive"
cat >"$WORK/ini.txt" <<'EOF'
Mods=PropaneTankRefill;AnotherMod
WorkshopItems=3780731664;2169435993
ServerWelcomeMessage=Welcome! Use /all to chat. a=b;c=d
PublicName=Derp Enterprise
EOF
gawk -f "$INI_AWK" "$WORK/ini.txt" "$STOCK_INI" >"$WORK/out.ini" 2>"$WORK/ini.err"
check "no warnings"      "$(wc -c <"$WORK/ini.err")" "0"
check "semicolon list"   "$(grep -c '^Mods=PropaneTankRefill;AnotherMod$' "$WORK/out.ini")" "1"
check "equals in value"  "$(grep -c '^ServerWelcomeMessage=Welcome! Use /all to chat\. a=b;c=d$' "$WORK/out.ini")" "1"
check "space in value"   "$(grep -c '^PublicName=Derp Enterprise$' "$WORK/out.ini")" "1"

echo "[test] ini: key match is case-insensitive, file casing is preserved"
printf 'publicname=lowercased key\n' >"$WORK/case.txt"
gawk -f "$INI_AWK" "$WORK/case.txt" "$STOCK_INI" >"$WORK/case.ini" 2>/dev/null
check "canonical casing emitted" "$(grep -c '^PublicName=lowercased key$' "$WORK/case.ini")" "1"

echo "[test] admin promotion writes the B42 role FK"
DB="$WORK/servertest.db"
sqlite3 "$DB" <<'EOF'
CREATE TABLE role (id INTEGER PRIMARY KEY, name TEXT);
INSERT INTO role (id, name) VALUES (2,'user'), (7,'admin');
CREATE TABLE whitelist (id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL, username TEXT, steamid TEXT, role INTEGER NOT NULL);
INSERT INTO whitelist (username, steamid, role) VALUES
    ('test', '76561197969138678', 2),
    ('second-login', '76561197969138678', 2),
    ('someoneelse', '76561198000000000', 2);
EOF
ADMIN_ROLE="$(sqlite3 "$DB" "SELECT id FROM role WHERE name='admin';")"
check "admin role id" "$ADMIN_ROLE" "7"
CHANGED="$(sqlite3 "$DB" "UPDATE whitelist SET role=${ADMIN_ROLE} WHERE steamid='76561197969138678'; SELECT changes();")"
check "all Steam logins promoted" "$CHANGED" "2"
check "first login is admin"      "$(sqlite3 "$DB" "SELECT role FROM whitelist WHERE username='test';")" "7"
check "second login is admin"     "$(sqlite3 "$DB" "SELECT role FROM whitelist WHERE username='second-login';")" "7"
check "others untouched"          "$(sqlite3 "$DB" "SELECT role FROM whitelist WHERE username='someoneelse';")" "2"
MISSING="$(sqlite3 "$DB" "UPDATE whitelist SET role=${ADMIN_ROLE} WHERE steamid='76561197999999999'; SELECT changes();")"
check "absent user is a no-op" "$MISSING" "0"

echo
echo "[test] ${PASS} passed, ${FAIL} failed"
[[ "$FAIL" -eq 0 ]]
