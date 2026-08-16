#!/usr/bin/env bash
set -euo pipefail

DATA_DIR="${PZ_DATA_DIR:-/zomboid}"
SAVE_ROOT="${PZ_SAVE_ROOT:-${DATA_DIR}/Zomboid}"

BUCKET="${PZ_BACKUP_BUCKET:?PZ_BACKUP_BUCKET must be set}"
KEY="${PZ_RESTORE_KEY:?PZ_RESTORE_KEY must be set (e.g. backups/pz-20260815T221653Z.tar.gz)}"

EXPECTED_DIRS=(Saves db Server)

log() { printf '[restore] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

log "restoring s3://${BUCKET}/${KEY} -> ${SAVE_ROOT}"

archive="${WORK}/archive.tar.gz"
aws s3 cp "s3://${BUCKET}/${KEY}" "$archive" --only-show-errors \
    || die "could not download s3://${BUCKET}/${KEY}"

size="$(du -h "$archive" | cut -f1)"
log "downloaded ${size}"

gzip -t "$archive" || die "archive fails gzip integrity check - refusing to restore"
tar tzf "$archive" >"${WORK}/listing.txt" 2>/dev/null || die "archive is not a readable tar"

entries="$(wc -l <"${WORK}/listing.txt")"
(( entries > 0 )) || die "archive is empty"

for d in "${EXPECTED_DIRS[@]}"; do
    grep -q "^${d}/" "${WORK}/listing.txt" \
        || die "archive has no ${d}/ - wrong archive, or a torn one"
done

grep -q '^Saves/Multiplayer/.*/players\.db$' "${WORK}/listing.txt" \
    || die "archive contains no players.db - refusing to restore a worldless backup"

log "archive verified: ${entries} entries, all expected directories present"

count_characters() {
    local db="$1"
    sqlite3 "$db" 'SELECT COUNT(*) FROM networkPlayers;' 2>/dev/null || echo "unreadable"
}

staging="${WORK}/staging"
mkdir -p "$staging"
tar xzf "$archive" -C "$staging" || die "extraction failed"

players_db="$(find "${staging}/Saves" -name players.db -print -quit 2>/dev/null || true)"
[[ -n "$players_db" ]] || die "extracted tree has no players.db"

characters="$(count_characters "$players_db")"
[[ "$characters" != "unreadable" ]] || die "players.db in the archive is not a readable SQLite database - the archive is torn"

if [[ "$characters" == "0" ]]; then
    log "WARNING: this archive contains NO characters - it may be from a server"
    log "         nobody has played on. Restoring it over a live world would"
    log "         delete every character."
    if [[ "${PZ_RESTORE_ALLOW_EMPTY:-false}" != "true" ]]; then
        die "refusing to restore a characterless archive; set PZ_RESTORE_ALLOW_EMPTY=true if this is genuinely what you want"
    fi
    log "PZ_RESTORE_ALLOW_EMPTY=true - proceeding anyway."
else
    log "archive holds ${characters} character(s)"
fi

for d in "${EXPECTED_DIRS[@]}"; do
    [[ -d "${staging}/${d}" ]] || die "extracted tree is missing ${d}/"
done
log "extracted and sanity-checked"

ts="$(date -u +%Y%m%dT%H%M%SZ)"
aside="${SAVE_ROOT}/.pre-restore-${ts}"
mkdir -p "$aside"

for d in "${EXPECTED_DIRS[@]}"; do
    if [[ -e "${SAVE_ROOT}/${d}" ]]; then
        mv "${SAVE_ROOT}/${d}" "${aside}/${d}"
        log "moved existing ${d}/ aside"
    fi
done
log "previous state preserved at ${aside}"

for d in "${EXPECTED_DIRS[@]}"; do
    mv "${staging}/${d}" "${SAVE_ROOT}/${d}"
done

log "restore complete from ${KEY}"
log "previous state kept at ${aside} - delete it once the world is confirmed good"
