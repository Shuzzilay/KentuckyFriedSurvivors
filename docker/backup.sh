#!/usr/bin/env bash

set -euo pipefail

DATA_DIR="${PZ_DATA_DIR:-/zomboid}"
SAVE_ROOT="${PZ_SAVE_ROOT:-${DATA_DIR}/Zomboid}"
CONTROL_FIFO="${DATA_DIR}/.pz-control"

BUCKET="${PZ_BACKUP_BUCKET:?PZ_BACKUP_BUCKET must be set}"
PREFIX="${PZ_BACKUP_PREFIX:-backups}"
INTERVAL="${PZ_BACKUP_INTERVAL:-900}"     # 15 min
SAVE_WAIT="${PZ_BACKUP_SAVE_WAIT:-20}"    # Flush delay

METRIC_NAMESPACE="${PZ_METRIC_NAMESPACE:-PZServer}"

LOG_DIR="${SAVE_ROOT}/Logs"
LOG_RETENTION_DAYS="${PZ_LOG_RETENTION_DAYS:-7}"

JVM_MATCH="${PZ_JVM_MATCH:-ProjectZomboid64}"
CPU_SAMPLE_S="${PZ_CPU_SAMPLE_S:-10}"
CLK_TCK=100   # USER_HZ. Constant on Linux x86_64; getconf is not in this image.

log() { printf '[backup] %s\n' "$*" >&2; }

flush_world() {
    if [[ ! -p "$CONTROL_FIFO" ]]; then
        log "WARNING: no control FIFO at ${CONTROL_FIFO} (server down?) - archiving as-is"
        return 0
    fi

    if timeout 5 bash -c "printf 'save\n' > '${CONTROL_FIFO}'"; then
        log "save issued; waiting ${SAVE_WAIT}s for flush"
        sleep "$SAVE_WAIT"
    else
        log "WARNING: FIFO write timed out (server not reading?) - archiving as-is"
    fi
}

backup_once() {
    local ts archive
    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    archive="/tmp/pz-${ts}.tar.gz"

    local -a paths=()
    local d
    for d in Saves db Server; do
        if [[ -e "${SAVE_ROOT}/${d}" ]]; then
            paths+=("$d")
        fi
    done

    if (( ${#paths[@]} == 0 )); then
        log "nothing to back up under ${SAVE_ROOT} yet - skipping this cycle"
        return 0
    fi

    flush_world

    log "archiving: ${paths[*]}"
    tar czf "$archive" -C "$SAVE_ROOT" "${paths[@]}"

    local size
    size="$(du -h "$archive" | cut -f1)"

    aws s3 cp "$archive" "s3://${BUCKET}/${PREFIX}/pz-${ts}.tar.gz" --only-show-errors
    log "uploaded pz-${ts}.tar.gz (${size}) to s3://${BUCKET}/${PREFIX}/"

    rm -f "$archive"
}

emit_volume_metric() {
    local pct avail_gb
    pct="$(df -P "$DATA_DIR" | awk 'NR==2 { gsub(/%/, "", $5); print $5 }')"
    avail_gb="$(df -Pk "$DATA_DIR" | awk 'NR==2 { printf "%.1f", $4 / 1048576 }')"

    [[ -n "$pct" ]] || { log "WARNING: could not read disk usage for ${DATA_DIR}"; return 0; }

    aws cloudwatch put-metric-data \
        --namespace "$METRIC_NAMESPACE" \
        --metric-data \
            "MetricName=DataVolumeUsedPercent,Value=${pct},Unit=Percent" \
            "MetricName=DataVolumeAvailableGB,Value=${avail_gb},Unit=Gigabytes" \
        2>/dev/null \
        || log "WARNING: could not publish volume metrics (continuing)"

    log "volume: ${pct}% used, ${avail_gb} GB free"
}

emit_host_metrics() {
    local load1 cores load_per_core mem_total mem_avail mem_pct

    load1="$(awk '{ print $1 }' /proc/loadavg 2>/dev/null)"
    cores="$(nproc 2>/dev/null || echo 1)"

    load_per_core="$(awk -v l="$load1" -v c="$cores" 'BEGIN { printf "%.2f", l / c }')"

    mem_total="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo 2>/dev/null)"
    mem_avail="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo 2>/dev/null)"

    if [[ -z "$load1" || -z "$mem_total" || -z "$mem_avail" ]]; then
        log "WARNING: could not read /proc load or memory"
        return 0
    fi

    mem_pct="$(awk -v t="$mem_total" -v a="$mem_avail" \
        'BEGIN { printf "%.1f", (t - a) * 100 / t }')"

    aws cloudwatch put-metric-data \
        --namespace "$METRIC_NAMESPACE" \
        --metric-data \
            "MetricName=HostLoadPerCore,Value=${load_per_core},Unit=None" \
            "MetricName=HostMemoryUsedPercent,Value=${mem_pct},Unit=Percent" \
        2>/dev/null \
        || log "WARNING: could not publish host metrics (continuing)"

    log "host: load ${load1} (${load_per_core}/core over ${cores}), memory ${mem_pct}% used"
}

put_metrics() {
    aws cloudwatch put-metric-data \
        --namespace "$METRIC_NAMESPACE" \
        --metric-data "$@" 2>/dev/null
}

# Needs pid_mode=task on the task definition; the JVM lives in the pz container.
find_jvm_pid() {
    local p comm
    for p in /proc/[0-9]*; do
        comm="$(tr '\0' ' ' <"${p}/cmdline" 2>/dev/null)" || continue
        case "$comm" in
            *"$JVM_MATCH"*) basename "$p"; return 0 ;;
        esac
    done
    return 1
}

# utime+stime, read past the comm field so a name with spaces cannot shift them.
cpu_jiffies() {
    awk '{ t = substr($0, index($0, ") ") + 2); split(t, f, " "); print f[12] + f[13] }' \
        "/proc/$1/stat" 2>/dev/null
}

emit_jvm_metrics() {
    local pid t0 t1 cores rss_kb rss_mb

    if ! pid="$(find_jvm_pid)"; then
        log "WARNING: no process matching '${JVM_MATCH}' - skipping JVM metrics"
        return 0
    fi

    t0="$(cpu_jiffies "$pid")"
    sleep "$CPU_SAMPLE_S"
    t1="$(cpu_jiffies "$pid")"

    if [[ -z "$t0" || -z "$t1" ]]; then
        log "WARNING: could not read /proc/${pid}/stat"
        return 0
    fi

    # Cores, not percent: >1.0 would mean the JVM is using more than one core.
    cores="$(awk -v a="$t0" -v b="$t1" -v s="$CPU_SAMPLE_S" -v hz="$CLK_TCK" \
        'BEGIN { printf "%.2f", (b - a) / hz / s }')"

    rss_kb="$(awk '/^VmRSS:/ { print $2 }' "/proc/${pid}/status" 2>/dev/null)"
    rss_mb="$(awk -v k="${rss_kb:-0}" 'BEGIN { printf "%.0f", k / 1024 }')"

    put_metrics \
        "MetricName=JvmCpuCores,Value=${cores},Unit=Count" \
        "MetricName=JvmMemoryResidentMB,Value=${rss_mb},Unit=Megabytes" \
        || log "WARNING: could not publish JVM metrics (continuing)"

    log "jvm: pid ${pid}, ${cores} cores, ${rss_mb} MB resident"
}

# PZ never prunes its own logs and they are not in the backup, so they only grow.
prune_server_logs() {
    [[ -d "$LOG_DIR" ]] || return 0

    local before after
    before="$(du -sm "$LOG_DIR" 2>/dev/null | cut -f1)"

    # busybox find here, so -exec ... \; rather than + .
    find "$LOG_DIR" -mindepth 1 -maxdepth 1 -mtime "+${LOG_RETENTION_DAYS}" \
        -exec rm -rf {} \; 2>/dev/null || true

    after="$(du -sm "$LOG_DIR" 2>/dev/null | cut -f1)"
    [[ -n "$after" ]] || return 0

    put_metrics "MetricName=ServerLogsMB,Value=${after},Unit=Megabytes" \
        || log "WARNING: could not publish log size metric (continuing)"

    log "logs: ${after} MB (was ${before:-?} MB, keeping ${LOG_RETENTION_DAYS} days)"
}

trap 'log "signal received - exiting"; exit 0' TERM INT

log "starting: every ${INTERVAL}s -> s3://${BUCKET}/${PREFIX}/ (root ${SAVE_ROOT})"

while true; do
    backup_once || log "ERROR: backup cycle failed - retrying in ${INTERVAL}s"

    emit_volume_metric || true
    emit_host_metrics  || true
    emit_jvm_metrics   || true
    prune_server_logs  || true

    sleep "$INTERVAL" &
    wait $!
done
