#!/usr/bin/env bash

set -euo pipefail

STEAM_APP_ID=380870
INSTALL_DIR="${PZ_INSTALL_DIR:-/opt/pzserver}"
DATA_DIR="${PZ_DATA_DIR:-/zomboid}"
CONTROL_FIFO="${DATA_DIR}/.pz-control"

SERVER_NAME="${PZ_SERVER_NAME:-servertest}"
ADMIN_USER="${PZ_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${PZ_ADMIN_PASSWORD:-}"

MEMORY="${PZ_MEMORY:-8g}"

STEAM_BRANCH="${PZ_STEAM_BRANCH:-}"

UPDATE_ON_BOOT="${PZ_UPDATE_ON_BOOT:-false}"

SHUTDOWN_WARNING="${PZ_SHUTDOWN_WARNING:-Server shutting down - saving world}"
SAVE_WAIT="${PZ_SAVE_WAIT:-25}"       # Save delay
QUIT_WAIT="${PZ_QUIT_WAIT:-60}"       # JVM exit timeout

log() { printf '[entrypoint] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

[[ -n "$ADMIN_PASSWORD" ]] || die "PZ_ADMIN_PASSWORD must be set (first boot prompts for it interactively otherwise)."

mkdir -p "$DATA_DIR" "$INSTALL_DIR"

if [[ ! -w "$DATA_DIR" ]]; then
    die "$DATA_DIR is not writable by uid $(id -u). Fix ownership on the host/volume."
fi

install_server() {
    local branch_args=()
    [[ -n "$STEAM_BRANCH" ]] && branch_args=(-beta "$STEAM_BRANCH")

    log "Running SteamCMD for app ${STEAM_APP_ID} (branch: ${STEAM_BRANCH:-public})"
    steamcmd \
        +force_install_dir "$INSTALL_DIR" \
        +login anonymous \
        +app_update "$STEAM_APP_ID" "${branch_args[@]}" validate \
        +quit
}

if [[ ! -f "${INSTALL_DIR}/start-server.sh" ]]; then
    log "No server installation found - performing first-time install."
    install_server
elif [[ "$UPDATE_ON_BOOT" == "true" ]]; then
    log "PZ_UPDATE_ON_BOOT=true - updating server."
    install_server
else
    log "Existing installation found; skipping update (PZ_UPDATE_ON_BOOT=false)."
fi

[[ -f "${INSTALL_DIR}/start-server.sh" ]] || die "start-server.sh missing after install."

WORKSHOP_SRC="${INSTALL_DIR}/steamapps/workshop"
WORKSHOP_DST="${DATA_DIR}/workshop"

mkdir -p "$WORKSHOP_DST"
if [[ -L "$WORKSHOP_SRC" ]]; then
    :  # Linked.
elif [[ -d "$WORKSHOP_SRC" ]]; then
    log "Migrating existing workshop content to persistent volume."
    cp -a "${WORKSHOP_SRC}/." "$WORKSHOP_DST/" 2>/dev/null || true
    rm -rf "$WORKSHOP_SRC"
    ln -s "$WORKSHOP_DST" "$WORKSHOP_SRC"
else
    mkdir -p "$(dirname "$WORKSHOP_SRC")"
    ln -s "$WORKSHOP_DST" "$WORKSHOP_SRC"
fi

patch_heap() {
    local json="${INSTALL_DIR}/ProjectZomboid64.json"
    if [[ -f "$json" ]]; then
        sed -i -E "s/-Xms[0-9]+[mMgG]/-Xms${MEMORY}/g; s/-Xmx[0-9]+[mMgG]/-Xmx${MEMORY}/g" "$json"

        if ! grep -q -- '-Xms' "$json"; then
            sed -i -E "s/^(\s*)(\"-Xmx${MEMORY}\")/\1\"-Xms${MEMORY}\",\n\1\2/" "$json"
        fi
        log "Patched heap to -Xms${MEMORY} / -Xmx${MEMORY} in ProjectZomboid64.json"
    fi

    local sh="${INSTALL_DIR}/start-server.sh"
    if grep -qE -- '-Xm[sx][0-9]' "$sh" 2>/dev/null; then
        log "Patching heap in start-server.sh"
        sed -i -E "s/-Xms[0-9]+[mMgG]/-Xms${MEMORY}/g; s/-Xmx[0-9]+[mMgG]/-Xmx${MEMORY}/g" "$sh"
    fi
}
patch_heap

CONFIG_DIR="${DATA_DIR}/Zomboid/Server"
INI_FILE="${CONFIG_DIR}/${SERVER_NAME}.ini"
SANDBOX_FILE="${CONFIG_DIR}/${SERVER_NAME}_SandboxVars.lua"
USER_DB="${DATA_DIR}/Zomboid/db/${SERVER_NAME}.db"

collect_assignments() {
    local prefix="$1" out="$2" var key count=0
    : >"$out"
    for var in $(compgen -v "$prefix" || true); do
        key="${var#"$prefix"}"
        [[ -n "$key" ]] || continue
        printf '%s=%s\n' "${key//__/.}" "${!var}" >>"$out"
        count=$(( count + 1 ))
    done
    printf '%s' "$count"
}

apply_patch() {
    local label="$1" script="$2" target="$3" assignments="$4" out errs n
    n="$(wc -l <"$assignments")"

    if [[ ! -f "$target" ]]; then
        log "WARNING: ${target} does not exist yet - skipping ${label} patch."
        log "         PZ generates it on first boot; these settings apply from the next start."
        return 0
    fi

    out="$(mktemp)"
    errs="$(mktemp)"

    if ! gawk -f "$script" "$assignments" "$target" >"$out" 2>"$errs"; then
        cat "$errs" >&2
        rm -f "$out" "$errs"
        die "${label} patch failed."
    fi

    if [[ -s "$errs" ]]; then
        cat "$errs" >&2
        rm -f "$out" "$errs"
        die "Unknown ${label} setting(s) - refusing to boot with a misspelled config."
    fi

    if [[ ! -s "$out" ]]; then
        rm -f "$out" "$errs"
        die "${label} patch produced an empty file - refusing to overwrite ${target}."
    fi

    cat "$out" >"$target"
    log "Applied ${n} ${label} setting(s) to $(basename "$target")"
    rm -f "$out" "$errs"
}

patch_config() {
    local ini_assign sandbox_assign n_ini n_sandbox
    ini_assign="$(mktemp)"
    sandbox_assign="$(mktemp)"

    n_ini="$(collect_assignments PZ_INI_ "$ini_assign")"
    n_sandbox="$(collect_assignments PZ_SANDBOX_ "$sandbox_assign")"

    if (( n_ini > 0 )); then
        apply_patch "ini" /usr/local/bin/patch-ini.awk "$INI_FILE" "$ini_assign"
    else
        log "No PZ_INI_* settings supplied; leaving ${SERVER_NAME}.ini untouched."
    fi

    if (( n_sandbox > 0 )); then
        apply_patch "sandbox" /usr/local/bin/patch-sandbox.awk "$SANDBOX_FILE" "$sandbox_assign"
    else
        log "No PZ_SANDBOX_* settings supplied; leaving SandboxVars untouched."
    fi

    rm -f "$ini_assign" "$sandbox_assign"
}
patch_config

promote_admins() {
    local steam_ids="${PZ_ADMIN_STEAM_IDS:-}"
    [[ -n "$steam_ids" ]] || return 0

    if [[ ! -f "$USER_DB" ]]; then
        log "WARNING: ${USER_DB} does not exist yet - skipping admin promotion."
        return 0
    fi

    local admin_role
    admin_role="$(sqlite3 "$USER_DB" "SELECT id FROM role WHERE name='admin';")"
    [[ -n "$admin_role" ]] || die "No 'admin' role found in ${USER_DB}."

    local steam_id changed
    IFS=',' read -ra _admin_steam_ids <<<"$steam_ids"
    for steam_id in "${_admin_steam_ids[@]}"; do
        steam_id="$(printf '%s' "$steam_id" | tr -d '[:space:]')"
        [[ -n "$steam_id" ]] || continue
        [[ "$steam_id" =~ ^[0-9]{17}$ ]] \
            || die "Invalid admin SteamID64 '${steam_id}'."

        changed="$(sqlite3 "$USER_DB" \
            "UPDATE whitelist SET role=${admin_role} WHERE steamid='${steam_id}'; SELECT changes();")"

        if [[ "$changed" == "0" ]]; then
            log "WARNING: no login for SteamID64 '${steam_id}' exists yet - it must connect once before it can be promoted."
        else
            log "Granted admin (role ${admin_role}) to ${changed} login(s) for SteamID64 '${steam_id}'."
        fi
    done
}
promote_admins

rm -f "$CONTROL_FIFO"
mkfifo -m 0600 "$CONTROL_FIFO"
exec 3<>"$CONTROL_FIFO"
log "Console FIFO ready at ${CONTROL_FIFO} (use: pz-console <command>)"

# shellcheck disable=SC2317,SC2329
send_cmd() {
    printf '%s\n' "$*" >&3
}

cd "$INSTALL_DIR"

SERVER_ARGS=(
    -servername "$SERVER_NAME"
    -adminusername "$ADMIN_USER"
    -adminpassword "$ADMIN_PASSWORD"
)
if [[ -n "${PZ_EXTRA_ARGS:-}" ]]; then
    # shellcheck disable=SC2206
    SERVER_ARGS+=(${PZ_EXTRA_ARGS})
fi

log "Starting Project Zomboid server '${SERVER_NAME}' (heap ${MEMORY})"
./start-server.sh "${SERVER_ARGS[@]}" <"$CONTROL_FIFO" &
PZ_PID=$!
log "Server JVM running as pid ${PZ_PID}"

GRACEFUL=false

# shellcheck disable=SC2317,SC2329
shutdown_handler() {
    trap '' TERM INT   # Ignore repeats while draining.
    GRACEFUL=true

    log "Signal received - beginning graceful shutdown."

    if ! kill -0 "$PZ_PID" 2>/dev/null; then
        log "JVM already gone; nothing to drain."
        return
    fi

    send_cmd "servermsg \"${SHUTDOWN_WARNING}\""
    sleep 2

    log "Issuing save; allowing ${SAVE_WAIT}s to complete."
    send_cmd "save"
    sleep "$SAVE_WAIT"

    log "Issuing quit."
    send_cmd "quit"

    local waited=0
    while kill -0 "$PZ_PID" 2>/dev/null && (( waited < QUIT_WAIT )); do
        sleep 1
        waited=$(( waited + 1 ))   # Avoid set -e with (( waited++ )).
    done

    if kill -0 "$PZ_PID" 2>/dev/null; then
        log "WARNING: JVM still alive after ${QUIT_WAIT}s - sending SIGTERM."
        kill -TERM "$PZ_PID" 2>/dev/null || true
        sleep 10
        kill -KILL "$PZ_PID" 2>/dev/null || true
    else
        log "JVM exited cleanly after ${waited}s."
    fi
}

trap shutdown_handler TERM INT

while kill -0 "$PZ_PID" 2>/dev/null; do
    wait "$PZ_PID" && EXIT_CODE=0 || EXIT_CODE=$?
done

exec 3>&-

if [[ "$GRACEFUL" == "true" ]]; then
    log "Server stopped gracefully."
    exit 0
fi

log "Server stopped unexpectedly (exit ${EXIT_CODE:-0})."
exit "${EXIT_CODE:-0}"
