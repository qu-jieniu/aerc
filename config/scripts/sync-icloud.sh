#!/bin/sh
# Fast iCloud-only sync: getmail Gmail POP, mbsync iCloud, notmuch reindex.
# Always exits 0 — transient upstream failures (iCloud throttling, network
# blips) should not flash "exit status 1" notifications in aerc. Errors
# still hit stderr; the 3-min timer retries.
getmail --getmaildir /home/aerc/.config/aerc --rcfile getmailrc --quiet
mbsync icloud && notmuch new --quiet \
    && sh /home/aerc/.config/aerc/scripts/rebuild-addrbook.sh \
    && sh /home/aerc/.config/aerc/scripts/update-unread.sh
exit 0
