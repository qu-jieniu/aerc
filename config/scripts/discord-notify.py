#!/usr/bin/env python3
# Poll a work IMAP folder via DavMail; post new-message notifications to Discord.
# Invoked from sync.sh in the aerc container.
#
# Config via environment (see config/.notify.env.example):
#   NOTIFY_IMAP_HOST, NOTIFY_IMAP_PORT, NOTIFY_IMAP_USER, NOTIFY_IMAP_FOLDER
#   NOTIFY_TICKET_ID_RE   regex with one capture group; matched against Subject
#   NOTIFY_TICKET_URL_FMT format string with one {} where the captured id goes
#   NOTIFY_TICKET_URL_RE  fallback regex run against the first 4 KB of body
import imaplib
import json
import os
import re
import socket
import sys
import time
import urllib.request
from email import policy
from email.header import decode_header, make_header
from email.parser import HeaderParser
from pathlib import Path

HOST = os.environ["NOTIFY_IMAP_HOST"]
PORT = int(os.environ.get("NOTIFY_IMAP_PORT", "1143"))
USER = os.environ["NOTIFY_IMAP_USER"]
FOLDER = os.environ["NOTIFY_IMAP_FOLDER"]
# Subject-side ticket id: long HTML bodies can push the URL past the 4 KB
# body slice, so we look in the Subject first when the helpdesk embeds an id.
TICKET_ID_RE = re.compile(os.environ["NOTIFY_TICKET_ID_RE"]) if os.environ.get("NOTIFY_TICKET_ID_RE") else None
TICKET_URL_FMT = os.environ.get("NOTIFY_TICKET_URL_FMT", "")
TICKET_URL_RE = re.compile(os.environ["NOTIFY_TICKET_URL_RE"]) if os.environ.get("NOTIFY_TICKET_URL_RE") else None
CONFIG = Path("/home/aerc/.config/aerc")
CACHE = CONFIG / f".notify-uidnext-{FOLDER.replace('/', '-')}"
# DavMail reassigns UIDs when O365 modifies a message (rules, flags, category
# changes), so UIDNEXT alone will renotify the same email. Dedup by Message-ID.
SEEN = CONFIG / f".notify-seen-{FOLDER.replace('/', '-')}"
SEEN_MAX = 200
# DavMail auth-failure alerting: fires when the O365 OAuth refresh token has
# expired (LOGIN returns AUTHENTICATIONFAILED) so the user knows to redo the
# device-code flow in the DavMail container. Throttled so we don't spam the
# webhook every 3 min while the user sleeps.
REAUTH_STATE = CONFIG / ".notify-davmail-reauth-last"
REAUTH_THROTTLE_SEC = 6 * 3600


def decode(s):
    if not s:
        return ""
    return str(make_header(decode_header(s)))


def post_webhook(content):
    webhook = (CONFIG / ".discord-webhook").read_text().strip()
    payload = json.dumps({"content": content}).encode()
    req = urllib.request.Request(
        webhook,
        data=payload,
        headers={
            "Content-Type": "application/json",
            "User-Agent": "aerc-discord-notify/1.0",
        },
    )
    urllib.request.urlopen(req, timeout=10).read()


def notify(subject, url):
    lines = [f"📧 **{decode(subject)}**"]
    if url:
        lines.append(url)
    post_webhook("\n".join(lines))


def notify_reauth(reason):
    now = int(time.time())
    last = 0
    if REAUTH_STATE.exists():
        try:
            last = int(REAUTH_STATE.read_text().strip())
        except ValueError:
            pass
    if now - last < REAUTH_THROTTLE_SEC:
        return
    content = (
        "⚠️ **DavMail reauth needed** — work mail sync is failing.\n"
        f"`{reason}`\n"
        "Run `podman logs davmail` and complete the device-code flow, "
        "or restart the davmail container."
    )
    try:
        post_webhook(content)
        REAUTH_STATE.write_text(str(now))
    except Exception as e:
        print(f"discord-notify: reauth webhook failed: {e}", file=sys.stderr)


def main():
    password = (CONFIG / ".work-password").read_text().strip()
    try:
        # 30s timeout so a broken DavMail (hung on interactive OAuth) doesn't
        # stall every 3-min sync tick.
        conn = imaplib.IMAP4(HOST, PORT, timeout=30)
        conn.login(USER, password)
    except imaplib.IMAP4.error as e:
        # DavMail returned NO/BAD to LOGIN — O365 token expired or invalid.
        notify_reauth(f"LOGIN error: {e}")
        raise
    except socket.timeout as e:
        # DavMail accepted the TCP connection but never completed LOGIN —
        # usually means it's stuck waiting for interactive device-code reauth.
        notify_reauth(f"LOGIN timed out after 30s: {e}")
        raise
    except (ConnectionError, OSError) as e:
        # DavMail container down or network blip. Don't spam on this — mbsync
        # work also fails and the journal surfaces it.
        print(f"discord-notify: IMAP connect failed: {e}", file=sys.stderr)
        return
    try:
        typ, data = conn.select(f'"{FOLDER}"', readonly=True)
        if typ != "OK":
            print(f"discord-notify: cannot select {FOLDER}: {data}", file=sys.stderr)
            return
        typ, data = conn.status(f'"{FOLDER}"', "(UIDNEXT)")
        uidnext = int(data[0].decode().split("UIDNEXT ")[1].rstrip(")"))

        if not CACHE.exists():
            CACHE.write_text(str(uidnext))
            return

        last = int(CACHE.read_text().strip())
        if uidnext <= last:
            return

        typ, data = conn.uid("search", None, f"UID {last}:{uidnext - 1}")
        if typ != "OK" or not data[0]:
            CACHE.write_text(str(uidnext))
            return

        seen = []
        if SEEN.exists():
            seen = [l.strip() for l in SEEN.read_text().splitlines() if l.strip()]
        seen_set = set(seen)

        for uid in data[0].split():
            # Partial TEXT fetch: we only need the first few KB to regex the
            # ticket URL — helpdesk bodies can be large with image attachments.
            typ, fetched = conn.uid(
                "fetch",
                uid,
                "(BODY.PEEK[HEADER.FIELDS (FROM SUBJECT MESSAGE-ID)] BODY.PEEK[TEXT]<0.4096>)",
            )
            if typ != "OK" or not fetched:
                continue
            headers = body = ""
            for part in fetched:
                if not isinstance(part, tuple):
                    continue
                meta = part[0].decode("utf-8", errors="replace")
                payload = part[1].decode("utf-8", errors="replace")
                if "HEADER.FIELDS" in meta:
                    headers = payload
                elif "BODY[TEXT]" in meta or "TEXT]" in meta:
                    body = payload
            if not headers:
                continue
            # Parse via email module with policy.default so folded headers
            # (long Subject wrapped across lines) are unfolded and
            # RFC 2047 encoded-words are decoded in one shot.
            parsed = HeaderParser(policy=policy.default).parsestr(headers)
            subject = str(parsed["Subject"]) if parsed["Subject"] else ""
            message_id = str(parsed["Message-ID"]) if parsed["Message-ID"] else ""
            if message_id and message_id in seen_set:
                continue
            url = ""
            if TICKET_ID_RE and TICKET_URL_FMT:
                id_match = TICKET_ID_RE.search(subject)
                if id_match:
                    url = TICKET_URL_FMT.format(id_match.group(1))
            if not url and TICKET_URL_RE:
                body_match = TICKET_URL_RE.search(body)
                if body_match:
                    url = body_match.group(0)
            try:
                notify(subject, url)
            except Exception as e:
                print(f"discord-notify: webhook failed for uid {uid}: {e}", file=sys.stderr)
                continue
            if message_id:
                seen.append(message_id)
                seen_set.add(message_id)

        if len(seen) > SEEN_MAX:
            seen = seen[-SEEN_MAX:]
        SEEN.write_text("\n".join(seen) + "\n" if seen else "")
        CACHE.write_text(str(uidnext))
    finally:
        conn.logout()


if __name__ == "__main__":
    main()
