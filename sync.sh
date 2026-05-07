#!/bin/bash
# Host-side timer entry: acquire shared lock, run sync-inner.sh inside a
# one-shot aerc container. `flock -n` means overlapping timer ticks skip.
# The lock file lives inside config/ so aerc's in-container check-mail-cmd
# sees the same inode (bind-mounted) and coordinates with this.
set -u

REPO="$(cd "$(dirname "$0")" && pwd)"
LOCK=$REPO/config/.sync.lock
NOTIFY_ENV=$REPO/config/.notify.env

# Pass discord-notify config through to the container if present; otherwise the
# script just won't run (sync-inner.sh tolerates missing env).
ENV_FLAG=
[ -f "$NOTIFY_ENV" ] && ENV_FLAG="--env-file=$NOTIFY_ENV"

exec /usr/bin/flock -n "$LOCK" /usr/bin/podman run --rm \
    --network=pasta:-T,8080 \
    $ENV_FLAG \
    -v $REPO/config:/home/aerc/.config/aerc \
    -v $REPO/mail:/home/aerc/Mail \
    -v $REPO/config/mbsyncrc:/home/aerc/.mbsyncrc:ro \
    -v $REPO/config/notmuch-config:/home/aerc/.notmuch-config:ro \
    --userns=keep-id \
    localhost/aerc:latest \
    sh /home/aerc/.config/aerc/scripts/sync-inner.sh
