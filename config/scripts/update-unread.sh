#!/bin/sh
# Count unread messages across live INBOX folders and write the number to
# web-wrapper/unread so the browser wrapper can poll it for desktop
# notifications. Runs inside the aerc container (any sync path).
set -u
OUT=/home/aerc/.config/aerc/web-wrapper/unread
TMP="$OUT.tmp"
notmuch count 'tag:unread and (folder:icloud/INBOX or folder:work/INBOX)' \
    > "$TMP" 2>/dev/null && mv "$TMP" "$OUT"
