#!/usr/bin/env bash

set -euo pipefail

VOLUME_TAG_KEY="${PZ_VOLUME_TAG_KEY:-pz:role}"
VOLUME_TAG_VALUE="${PZ_VOLUME_TAG_VALUE:-data}"

REQUESTED_DEVICE="${PZ_ATTACH_DEVICE:-/dev/xvdf}"

HOST_ROOT="/.bottlerocket/rootfs"
MOUNT_POINT="${HOST_ROOT}/mnt/pz-data"

PZ_UID="${PZ_UID:-1000}"
PZ_GID="${PZ_GID:-1000}"

ATTACH_TIMEOUT="${PZ_ATTACH_TIMEOUT:-120}"

log() { printf '[bootstrap] %s\n' "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

TOKEN="$(curl -sf -X PUT "http://169.254.169.254/latest/api/token" \
    -H "X-aws-ec2-metadata-token-ttl-seconds: 300")" \
    || die "could not obtain IMDSv2 token"

imds() {
    curl -sf -H "X-aws-ec2-metadata-token: ${TOKEN}" \
        "http://169.254.169.254/latest/meta-data/$1"
}

INSTANCE_ID="$(imds instance-id)" || die "could not read instance-id"
AZ="$(imds placement/availability-zone)" || die "could not read availability-zone"
export AWS_DEFAULT_REGION="${AZ%?}"   # Strip AZ suffix.

log "instance=${INSTANCE_ID} az=${AZ} region=${AWS_DEFAULT_REGION}"

VOLUME_ID="$(aws ec2 describe-volumes \
    --filters "Name=tag:${VOLUME_TAG_KEY},Values=${VOLUME_TAG_VALUE}" \
              "Name=availability-zone,Values=${AZ}" \
    --query 'Volumes[0].VolumeId' --output text)" \
    || die "describe-volumes failed (is ec2:DescribeVolumes on the instance role?)"

[[ "$VOLUME_ID" != "None" && -n "$VOLUME_ID" ]] \
    || die "no volume tagged ${VOLUME_TAG_KEY}=${VOLUME_TAG_VALUE} in ${AZ}"

log "found data volume ${VOLUME_ID}"

ATTACHED_TO="$(aws ec2 describe-volumes --volume-ids "$VOLUME_ID" \
    --query 'Volumes[0].Attachments[0].InstanceId' --output text)"

if [[ "$ATTACHED_TO" == "$INSTANCE_ID" ]]; then
    log "volume already attached to this instance"
elif [[ "$ATTACHED_TO" != "None" && -n "$ATTACHED_TO" ]]; then
    die "volume ${VOLUME_ID} is attached to ${ATTACHED_TO}, not us - refusing to steal it"
else
    log "attaching ${VOLUME_ID} as ${REQUESTED_DEVICE}"
    aws ec2 attach-volume \
        --volume-id "$VOLUME_ID" \
        --instance-id "$INSTANCE_ID" \
        --device "$REQUESTED_DEVICE" >/dev/null \
        || die "attach-volume failed (is ec2:AttachVolume on the instance role?)"
fi

DEVICE="${HOST_ROOT}/dev/disk/by-id/nvme-Amazon_Elastic_Block_Store_${VOLUME_ID//-/}"

waited=0
while [[ ! -e "$DEVICE" ]] && (( waited < ATTACH_TIMEOUT )); do
    sleep 2
    waited=$(( waited + 2 ))
done

[[ -e "$DEVICE" ]] || die "device ${DEVICE} did not appear within ${ATTACH_TIMEOUT}s"

REAL_DEVICE="$(readlink -f "$DEVICE")"
log "device ready: ${DEVICE} -> ${REAL_DEVICE} (after ${waited}s)"

if blkid "$REAL_DEVICE" >/dev/null 2>&1; then
    log "existing filesystem detected - NOT formatting"
else
    log "no filesystem found - creating ext4 (first boot for this volume)"
    mkfs.ext4 -L pz-data "$REAL_DEVICE"
fi

mkdir -p "$MOUNT_POINT"

if mountpoint -q "$MOUNT_POINT"; then
    log "${MOUNT_POINT} already mounted"
else
    mount "$REAL_DEVICE" "$MOUNT_POINT" || die "mount failed"
    log "mounted ${REAL_DEVICE} at ${MOUNT_POINT} (host: /mnt/pz-data)"
fi

mkdir -p "${MOUNT_POINT}/server-install"
chown "${PZ_UID}:${PZ_GID}" "$MOUNT_POINT" "${MOUNT_POINT}/server-install"

log "data volume ready"
