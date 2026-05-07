#!/bin/sh
# Dump all correspondents from notmuch into a flat cache file.
# Run after every sync (see sync-*.sh). Output: email<TAB>name per line.
set -u
OUT=/home/aerc/.config/aerc/.addrbook
TMP="$OUT.tmp"

notmuch address \
    --format=text \
    --deduplicate=address \
    --output=recipients \
    --output=sender \
    '*' 2>/dev/null | \
awk '
    {
        if (match($0, /<[^<>]+>/)) {
            email = substr($0, RSTART+1, RLENGTH-2)
            name  = substr($0, 1, RSTART-1)
            gsub(/^[[:space:]"]+|[[:space:]"]+$/, "", name)
            print email "\t" name
        } else if ($0 ~ /@/) {
            print $0 "\t"
        }
    }
' > "$TMP" && mv "$TMP" "$OUT"
