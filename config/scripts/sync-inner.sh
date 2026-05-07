#!/bin/sh
# Full mail sync, runs inside the aerc container. Shared between:
#   - sync.sh (host systemd timer) via podman run
#   - aerc's per-account check-mail-cmd (any P press triggers full sync)
# Callers wrap this in flock on config/.sync.lock to serialize.
set -u
getmail --getmaildir /home/aerc/.config/aerc --rcfile getmailrc --quiet
mbsync icloud
mbsync work
notmuch new --quiet
sh /home/aerc/.config/aerc/scripts/rebuild-addrbook.sh
sh /home/aerc/.config/aerc/scripts/update-unread.sh
# Discord notifier: only runs if config/.notify.env was loaded (sync.sh
# passes it via --env-file when it exists).
[ -n "${NOTIFY_IMAP_HOST:-}" ] && python3 /home/aerc/.config/aerc/scripts/discord-notify.py
