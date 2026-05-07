#!/bin/bash
# Archive mail from an account by date range. Moves matching messages to
# mail/local/<account>/ (not synced) and tags them with the account name.
# Skips flagged. Next mbsync run propagates server-side deletions (Expunge Both).
#
# Usage: archive-range.sh <account> <start|0> <end>
#   account : work | icloud | gmail
#   start   : YYYY-MM-DD, or 0 for "from the beginning"
#   end     : YYYY-MM-DD, notmuch-inclusive upper bound
#
# Scope per account:
#   work : work/Sent/** + work/Archive/**
#   icloud : icloud/Archive/** (Gmail-addressed excluded)
#   gmail  : icloud/Archive/** (Gmail-addressed only — same physical folder)
#
# Note: iCloud has no synced Sent folder (relay BCCs sent mail back to INBOX
# for threading), so Sent isn't in scope for icloud/gmail runs.
#
# Serializes against sync.sh / aerc check-mail via the shared .sync.lock.
#
# Examples:
#   archive-range.sh work 0 2024-01-01
#   archive-range.sh icloud 2023-01-01 2024-01-01
#   archive-range.sh gmail  0 2024-01-01

set -eu

ACCOUNT=${1:?usage: $0 <account> <start|0> <end>}
START=${2:?usage: $0 <account> <start|0> <end>}
END=${3:?usage: $0 <account> <start|0> <end>}

case "$ACCOUNT" in
    work)
        PATH_CLAUSE='(path:work/Sent/** OR path:work/Archive/**)'
        ;;
    icloud)
        PATH_CLAUSE='path:icloud/Archive/** AND NOT (to:you@gmail.com OR from:you@gmail.com)'
        ;;
    gmail)
        PATH_CLAUSE='path:icloud/Archive/** AND (to:you@gmail.com OR from:you@gmail.com)'
        ;;
    *)
        echo "unknown account: $ACCOUNT (must be work|icloud|gmail)" >&2
        exit 2
        ;;
esac

REPO="$(cd "$(dirname "$0")" && pwd)"
MAIL_DIR="$REPO/mail"
NOTMUCH_CONFIG="$REPO/config/notmuch-config"
LOCK="$REPO/config/.sync.lock"

if [ "$START" = "0" ]; then
    DATE_QUERY="date:..$END"
else
    DATE_QUERY="date:$START..$END"
fi

QUERY="$PATH_CLAUSE AND $DATE_QUERY AND NOT tag:flagged"

echo "=== archive-range: $ACCOUNT  $DATE_QUERY ==="
echo "=== query: $QUERY ==="

flock -n "$LOCK" podman run --rm --userns=keep-id \
    -e "QUERY=$QUERY" \
    -e "ACCOUNT=$ACCOUNT" \
    -v "$MAIL_DIR:/home/aerc/Mail" \
    -v "$NOTMUCH_CONFIG:/home/aerc/.notmuch-config:ro" \
    localhost/aerc bash -c '
set -eu
DEST=/home/aerc/Mail/local/$ACCOUNT
mkdir -p "$DEST/cur" "$DEST/new" "$DEST/tmp"

notmuch new --quiet 2>/dev/null

count=0
while IFS= read -r file; do
    [ -f "$file" ] || continue
    mv "$file" "$DEST/cur/$(basename "$file")"
    count=$((count + 1))
done < <(notmuch search --output=files "$QUERY")

echo "moved $count messages to $DEST/cur/"

notmuch new --quiet 2>/dev/null
notmuch tag +"$ACCOUNT" -- "path:local/$ACCOUNT/**"
echo "tag:$ACCOUNT total: $(notmuch count tag:$ACCOUNT)"
'

echo "=== done ==="
