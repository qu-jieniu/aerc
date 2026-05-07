#!/bin/sh
# aerc address-book-cmd: fast lookup against the notmuch-backed cache at
# .addrbook (rebuilt by rebuild-addrbook.sh after each sync). aerc handles
# ranking/fuzzy-matching itself, so a plain case-insensitive grep suffices.
set -u
BOOK=/home/aerc/.config/aerc/.addrbook
[ -f "$BOOK" ] || exit 0
q=${1:-}
if [ -z "$q" ]; then
    cat "$BOOK"
else
    grep -iF -- "$q" "$BOOK"
fi
