#!/bin/sh
# Fast work-only sync via DavMail, then notmuch reindex.
# Always exits 0 — see sync-icloud.sh for rationale.
mbsync work && notmuch new --quiet \
    && sh /home/aerc/.config/aerc/scripts/rebuild-addrbook.sh \
    && sh /home/aerc/.config/aerc/scripts/update-unread.sh
exit 0
