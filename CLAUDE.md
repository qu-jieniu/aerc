# aerc — CLI Email Setup

## Overview

Containerized CLI email client (aerc + mbsync + notmuch + getmail6) running in Alpine 3.21 via Podman.
Three mail backends:
- **iCloud** (custom domain `@example.com` + `@icloud.com`) via mbsync to local Maildir
- **Gmail** (`you@gmail.com`) pulled via POP3 (getmail6) into iCloud INBOX then pushed to iCloud
- **Work** (`@university.edu` via DavMail → O365) via mbsync

aerc surfaces four tabs:
- `icloud` — notmuch-filtered view of iCloud Maildir (excludes Gmail-addressed mail)
- `gmail` — notmuch-filtered view (only Gmail-addressed mail)
- `work` — work Maildir
- `archive` — notmuch query view of local archive folders (pers, local_trash)

Outgoing mail goes through the `postfix-relay` container (see `~/.containers/postfix-relay/`), which routes to the correct upstream SMTP based on envelope From.
Periodic sync runs from a systemd user timer (`aerc-sync.timer`) every 3 min whether or not aerc is open.
notmuch indexes all mail for full-text search and backs the filtered views.

The same aerc instance is accessible two ways — a persistent container runs aerc inside `screen` 24/7, and both the CLI (`aerc` shell function) and a browser-based TUI (`mail.example.com`, ttyd-served) attach to that session. State survives browser close and terminal exit.

## Architecture

```
Gmail ── POP3 ── getmail6 ── local iCloud INBOX ── mbsync ── iCloud IMAP
                                    │                  │
                                    │               aerc (inside `screen` in aerc-web container)
                                    │                 ↑ ↑
                                 notmuch              │ └─── podman exec: CLI `aerc` alias
                                    │                 └───── ttyd → Caddy → mail.example.com (web)
                             Archive tab                        │
                                    │                           smtp://mail.example.com:1587
                             local/ (tag:pers)                  │
                                                         postfix-relay ── iCloud SMTP (you@example.com)
                                                         (sender-based       Gmail SMTP (you@gmail.com)
                                                          routing)           DavMail → O365 (work)

Sync cadence: aerc-sync.timer (host systemd) every 3 min → sync.sh → sync-inner.sh (ephemeral container, full chain).
On-demand: P in aerc runs scoped check-mail-cmd (account-specific). Both serialize on config/.sync.lock.
```

## Accounts

| Address | Role | Upstream SMTP (via relay) |
|---|---|---|
| `you@example.com` | Primary iCloud custom domain | smtp.mail.me.com:587 |
| `you@icloud.com` | iCloud native alias | smtp.mail.me.com:587 |
| `you@gmail.com` | Gmail (separate aerc account) | smtp.gmail.com:587 |
| `you@university.edu` / `you-alias@university.edu` | O365 (work) | davmail:1025 → work |

- Each address is backed by its own aerc account → envelope-from follows the current tab.
- aerc 0.18 uses the account's `from` config for SMTP MAIL FROM, *not* the edited compose-header From — you must switch accounts (`Ctrl+Right/Left` in compose) to change envelope-from.
- `aliases` on each account auto-switches the *From header* on replies when the To matches an alias (does NOT change envelope).

## Shell Commands

```bash
aerc                        # Open mail client (instant, syncs in background)
mail-mbox /path/to/file     # Open an mbox file in aerc
mail-import /path/to/file   # Import mbox into archive (uses Python mailbox)
```

Defined in `~/.bashrc.d/aerc.sh`. `aerc` is a function: it `podman exec`s into the persistent `aerc-web` container and attaches to its screen session (auto-starts `aerc-web.service` if down). `mail-mbox` and `mail-import` are ephemeral (`podman run --rm`).

## How It Works

1. Persistent `aerc-web` container (managed by Quadlet, see `systemd/aerc-web.container`) runs ttyd → screen → aerc. Both CLI and browser attach to the same screen session.
2. Host systemd timer `aerc-sync.timer` runs `sync.sh` every 3 min → full sync chain inside a **separate** ephemeral podman container (decoupled from aerc-web so sync keeps working even if the web UI is down).
3. `P` in any tab runs that account's scoped `check-mail-cmd` (see Sync Design); notmuch-only tabs (archive) skip the shared lock.
4. Four tabs: `icloud`, `gmail`, `work`, `archive`. iCloud/Gmail are notmuch-filtered views over the iCloud Maildir (auto-separate Gmail-addressed mail from iCloud).
5. Reply: the current tab's account controls envelope-from; aerc's `aliases` adjusts only the From *header* on replies.
6. Sent copies come back in via the relay's `sender_bcc_maps` (see Outgoing SMTP) — no aerc `copy-to`.
7. `d` on any tab: confirmation prompt (`[Y/n]`, bare Enter = yes) in a term pane → move to local_trash (or permanent delete if already in local_trash, auto-detected).
8. `D` (main tabs): silent move to local_trash, no prompt.
9. `a` archives to the message's own-account Archive folder (source-path-based: `mail/work/…` → work Archive, `mail/icloud/…` → iCloud Archive — also covers Gmail-via-POP since Gmail lives in the iCloud Maildir). Confirmation prompt (`[Y/n]`, bare Enter = yes). Filenames are stripped of mbsync metadata (`,U=N`, `,FMD5=…`) on move to prevent duplicate-UID collisions in the destination folder. `A` prefixes `:mark -T` to archive the whole current thread in one pass.
9a. `archive.sh` and `delete.sh` accept **both** a single RFC822 message and aerc's mbox-concatenated stdin (which is what `:pipe -m` emits when multiple messages are marked), so multi-select delete/archive — including `A` (thread archive) — iterates over every message. Parser uses `mailbox.mbox` when the stream starts with `From `, else treats it as a single message.
9b. Both scripts run `notmuch new --quiet` synchronously before exiting. The icloud/gmail/archive tabs are notmuch-backed, so aerc only drops moved messages from the list once notmuch records their new path; backgrounding the reindex leaves stale entries on multi-message ops (notably `A` thread archive). The pipe pane stays open ~1 s while indexing — acceptable trade for correctness.
10. `S` to save attachments → `~/mail-attachments/` (syncthing-synced) → `files.example.com`.
11. `U` to browse URLs via urlscan.
12. `?` opens `config/shortcuts.txt` in a less pane.
13. Quit `q` in the screen-attached aerc detaches/exits; the container keeps running (state preserved).

## Sync Design

Two trigger paths, one lock, one shared set of sync scripts — no race conditions.

### Trigger paths

- **Periodic (every 3 min, host-side):** `aerc-sync.timer` (user systemd) → `sync.sh` → `podman run --rm` → `config/scripts/sync-inner.sh` runs the **full chain**: getmail Gmail POP → `mbsync icloud` → `mbsync work` → `notmuch new` → `discord-notify.py`. Runs whether aerc is open or not.
- **On-demand (`P` in aerc):** runs the account's `check-mail-cmd`, which invokes a **scoped** sync for responsiveness:
  - `icloud` and `gmail` tabs → `sync-icloud.sh` (getmail + mbsync icloud + notmuch)
  - `work` tab → `sync-work.sh` (mbsync work + notmuch)
  - `archive` tab → `notmuch new` only
- **aerc internal `check-mail` timer:** disabled (`check-mail = 0`) on every account — the host timer handles periodic sync uniformly.
- **Default cadence:** 3 minutes (`OnUnitActiveSec=3min` in `aerc-sync.timer`). `check-mail-timeout = 5m` per account caps any on-demand sync that hangs.

### Race condition prevention

All paths serialize on a **single lock file**: `config/.sync.lock`.

- Host `sync.sh` uses `flock -n` — if aerc's on-demand sync is mid-flight, the timer tick **skips** silently and fires again 3 min later.
- In-container `check-mail-cmd` uses `flock` (blocking, no `-n`) — if the host timer is mid-sync, pressing P **waits** for it to finish, then runs its own scoped sync afterward. `check-mail-timeout=5m` kills any runaway.
- The lock file sits inside `config/`, which is bind-mounted into the container at `/home/aerc/.config/aerc/.sync.lock` — host and container operate on the **same inode**, so their flocks coordinate.
- busybox flock (in the Alpine container) has no `-w` flag; dropped from the command line to keep the lock purely blocking.
- notmuch's own Xapian write-lock is a safety net for `notmuch new` overlaps.

### Other sync details

- **Expunge Both:** deletes propagate both ways
- **Remove Near:** folder deletions on server propagate to local
- **local_trash:** shared top-level folder (`mail/local_trash/`), used by all accounts, not synced upstream
- **Sent copies:** handled by relay `sender_bcc_maps` (see Outgoing SMTP section), not aerc `copy-to`

## Outgoing SMTP

All outgoing goes through the `postfix-relay` container: `outgoing = smtp+insecure+none://mail.example.com:1587` in every account. No auth, no TLS (relay's `mynetworks` trusts the podman bridge). The `+insecure` disables aerc's opportunistic STARTTLS, `+none` disables SASL AUTH — both are needed or aerc errors with "STARTTLS not supported" / "authentication not enabled". The relay does envelope-From-based routing to the correct upstream (iCloud, Gmail, DavMail→work) with upstream credentials pulled from the same `.icloud-app-password` / `.gmail-app-password` / `.work-password` files mounted into both containers.

msmtp and `config/msmtprc` were removed — the relay replaces them. If the relay container is down, sends fail.

**Sent-copy handling:** relay uses `sender_bcc_maps` to Bcc each outgoing message to the sender's own address — so sent mail lands in that account's INBOX via the provider (→ mbsync/POP → aerc thread view). Covers both aerc and phone sends uniformly. aerc's per-account `copy-to` is NOT set (would create duplicates). Map: `you@example.com`, `you@icloud.com`, `you@gmail.com` → self (Gmail round-trips via getmail POP into iCloud INBOX); `you@university.edu`, `you-alias@university.edu` → self (work INBOX via DavMail).

## Gmail POP

Gmail forwarding is **off**. getmail6 polls Gmail POP3 directly and delivers to `mail/icloud/INBOX/`; mbsync pushes those up to iCloud on the next run.

- Config: `config/getmailrc` (`SimplePOP3SSLRetriever`, `pop.gmail.com:995`, `delete = false`, `read_all = false`)
- Password: `config/.gmail-app-password` (Gmail app password)
- UIDL cache: `config/oldmail-pop.gmail.com-995-you@gmail.com` (auto-created, gitignored)
- Log: `config/.getmail.log` (one line per delivered message, gitignored)
- Gmail-side setting: POP enabled for "mail that arrives from now on" (avoids history flood)
- `delete = false` means mail stays on Gmail; Gmail's own POP state + getmail's oldmail cache prevent re-fetching

## Discord Notifications

`config/scripts/discord-notify.py` polls a work IMAP folder via DavMail on every sync tick and posts new-message subjects/senders to a Discord webhook. Folder is NOT synced via mbsync — notification-only.

- Config: `config/.notify.env` (gitignored, copied from `.notify.env.example`). Defines `NOTIFY_IMAP_HOST/PORT/USER/FOLDER` and the optional `NOTIFY_TICKET_ID_RE` / `NOTIFY_TICKET_URL_FMT` / `NOTIFY_TICKET_URL_RE` for helpdesk URL extraction. `sync.sh` passes the file through to the container via `podman run --env-file`. If the file isn't present the notifier just no-ops.
- State: UIDNEXT cached in `config/.notify-uidnext-<folder>` (gitignored, folder name slugified). First run records current UIDNEXT without notifying; subsequent runs notify on UIDs ≥ cached.
- Dedup: rolling Message-ID cache in `config/.notify-seen-<folder>` (last 200, gitignored). DavMail reassigns UIDs whenever O365 touches a message (rules, flags, categories), so UIDNEXT alone renotifies the same email multiple times — Message-ID dedup is the correctness layer.
- Webhook URL: `config/.discord-webhook` (gitignored).
- URL extraction: when `NOTIFY_TICKET_ID_RE` matches the Subject (e.g. a `[TICKET-NNNNNN]` prefix from a Freshservice-style helpdesk), the captured id goes into `NOTIFY_TICKET_URL_FMT`. Subject-side is preferred over body-side because long HTML bodies with inline images can push the URL past the 4 KB body slice. `NOTIFY_TICKET_URL_RE` is the body-side fallback.
- Partial body fetch: only the first 4 KB of each message body is fetched (BODY[TEXT]<0.4096>) — used by the fallback regex path. HTML ticket bodies with inline images can push the URL past this window, which is why the subject-based path is preferred.
- To add another folder or account: duplicate the script and the env block, chain it in `sync.sh` / `sync-inner.sh`.
- Webhook failures are logged to the service journal but don't block the sync chain.
- DavMail reauth alerts: the script connects with a 30 s `socket.timeout`, since the real failure mode isn't a clean `AUTHENTICATIONFAILED` — when the O365 token expires, DavMail drops into its interactive device-code prompt and just stops responding to IMAP. On `TimeoutError` (or any `imaplib.IMAP4.error`), the script posts a `⚠️ DavMail reauth needed` message to the webhook and writes epoch to `config/.notify-davmail-reauth-last` for throttling (6 h, prevents spam on every 3-min tick). Pure TCP connect failures (container down) print to stderr only — mbsync work already surfaces those.

## DavMail OAuth Refresh

`~/.containers/davmail/refresh-token.sh` is the one-shot tool to renew DavMail's stored O365 refresh token (~every 90 days, or whenever your work provider invalidates it via password reset / conditional access). Run it from one terminal; it handles the full dance.

Critical details, learned the hard way:

- **DavMail derives the AES key for the stored refresh token from the IMAP LOGIN password.** The script's trigger LOGIN must therefore send the **real** work account password from `.work-password` — not a dummy. Mismatched keys cause `javax.crypto.BadPaddingException` on every subsequent daemon restart, after which DavMail falls back to interactive device-code and hangs every IMAP client silently.
- **Run inside the existing `davmail` daemon container, not a separate `davmail-auth` one.** We used to spin up `podman run --rm -it davmail-auth` during reauth; that produced a separately-generated in-memory key context that didn't always round-trip. The current script just does `podman compose up` (foreground) on the same service defined in `compose.yaml` — same container name, same process identity, same key material.
- **Delete the old `refreshToken=` line from `davmail.properties` before reauth.** If decryption is broken because the old ciphertext is garbage, the daemon may keep trying to use it even after a successful OAuth; wiping the line first guarantees a clean slate. Backup is written to `davmail.properties.pre-refresh`.
- **Stop the sync timer during reauth** so mbsync work doesn't hit port 1143 with stale IMAP LOGINs that would pollute the auth flow (`systemctl --user stop aerc-sync.timer`). The script doesn't do this itself — it assumes you stop/restart the timer around invocation.

Flow:
1. `podman compose down` (stops daemon, clears in-memory auth state).
2. Strip any `davmail.oauth.*.refreshToken=` line from `davmail.properties`.
3. Spawn a backgrounded `ncat` that triggers an IMAP LOGIN with the real password after the foreground container comes up.
4. `podman compose up` (foreground, you see DavMail's stdout in your terminal).
5. DavMail prints the microsoftonline URL + `Authentication code:` prompt.
6. You sign in via browser → paste blank-page URL → see `Authenticated username: …` then `> … OK Authenticated`.
7. Ctrl+C. The script's EXIT trap runs `podman compose up -d` to bring the daemon back detached.

## Compose

- **Editor:** `vim -u /home/aerc/.config/aerc/vimrc` — loads a mail-specific vimrc that enables `spell` (en_us) for filetype=mail, forces `fileformat=unix`, and strips trailing `\r` (`^M`) on save.
- **Signature:** none — `signature-file` is not set on any account.
- **reply-to-self:** true — replying to own sent message addresses original recipients
- **Reply templates:** `quoted_reply` (default) with full From address (Name <email>) and blank line before quote; `quoted_reply_outlook` used by work (Outlook-style `________________________________` separator + `From/Sent/To/Subject` header block).
- **Forward templates:** `forward` (default, Gmail-style `---------- Forwarded message ----------` separator) and `forward_outlook` used by work (mirrors the Outlook reply block, plus Cc if present). Bound via `f = :forward -T <name>` in binds.conf.
- **Header layout:** compose shows `To, Cc, Bcc, From, Subject` one per row; viewer shows `From, To, Cc, Bcc, Subject, Date` one per row (`,` = new row, `|` = columns within a row).
- **Address completion:** `address-book-cmd = sh addr-complete.sh '%s'` greps a flat cache (`config/.addrbook`, gitignored) of every correspondent notmuch has seen. Cache is rebuilt by `rebuild-addrbook.sh` at the end of every sync path (`sync-inner.sh`, `sync-icloud.sh`, `sync-work.sh`). Lookup is sub-ms; full rebuild ≈10s on the current index. aerc's `fuzzy-complete = true` (in `[general]`) handles the ranking.
- **Switching envelope-from:** aerc uses the *account's* `from` for SMTP MAIL FROM, not the composed header edit. To send as Gmail/iCloud/work, use `Ctrl+Right/Left` (`:switch-account -n/-p`) in compose. iCloud and Gmail accounts share the same Maildir source; only outgoing identity differs.

## Web Access

Browser-based TUI at `https://mail.example.com/`. Caddy serves:
- `/` → static HTML wrapper (`config/web-wrapper/index.html`) that iframes ttyd, calls `navigator.keyboard.lock()` to free browser-reserved Ctrl+keys, and polls `/unread` for desktop notifications.
- `/tty/*` → reverse-proxied to `localhost:7681` (ttyd inside the container).

**Pieces:**
- `config/scripts/web-start.sh` runs `ttyd -b /tty ... screen -c screenrc -D -R -S mail aerc` inside the container.
- `config/screenrc` configures `vbell off` (audible bell passthrough) and 10k scrollback.
- `config/web-wrapper/manifest.webmanifest` makes it installable as a PWA (standalone window → Keyboard Lock works automatically). Icon is `config/web-wrapper/icon.svg` (envelope on amber background, declared `purpose: "any maskable"` so iOS/Android home-screen installs use it).
- `config/web-wrapper/unread` is written by `update-unread.sh` after each sync; wrapper polls every 30s and fires `Notification` + updates tab title on count increase.

**Keyboard:**
- Default ttyd via PWA releases `Ctrl+T/W/N/Tab` through to aerc. `Ctrl+L` and `Ctrl+R` are still browser-captured.
- screen's default prefix `Ctrl+A` doesn't conflict with any aerc binding — no tmux-style prefix remap needed.

**Security note:** no auth on `mail.example.com` currently. Entire mailbox is reachable via the WebSocket. Protect at the network layer or add `basic_auth` in the Caddy block.

## systemd / Quadlet

Three units, all source-of-truth in the repo under `systemd/`, symlinked into systemd's search paths:

| File | Live path (symlink) | Kind |
|---|---|---|
| `systemd/aerc-web.container` | `~/.config/containers/systemd/` | Quadlet → generates `aerc-web.service` |
| `systemd/aerc-sync.service` | `~/.config/systemd/user/` | Hand-written (calls `sync.sh`) |
| `systemd/aerc-sync.timer` | `~/.config/systemd/user/` | Fires aerc-sync.service every 3 min |

**Why Quadlet for aerc-web but not sync:** Quadlet can't wrap `flock` around `podman run`, which sync needs. So aerc-web uses Quadlet (clean declarative), sync stays as a plain `.service` that shells out to `sync.sh`.

**Service policies:**
- `aerc-web.container`: `Restart=always` with `StartLimitBurst=3` — container comes back on any stop (clean or crash), with a burst cap so a truly broken config doesn't infinite-loop.
- `aerc-sync.service`: `TimeoutStartSec=5min`, `TimeoutStopSec=15s` — hard ceiling on one sync cycle; if mbsync's own `Timeout 60` somehow doesn't catch a hang, systemd kills the whole process tree and releases `.sync.lock` so subsequent ticks aren't silently blocked.

**Edit-and-reload workflow:** changes to any unit file in `~/.containers/aerc/systemd/` are live after `systemctl --user daemon-reload`; restart the affected unit.

**Bootstrap on a fresh machine:**
```sh
ln -s ~/.containers/aerc/systemd/aerc-web.container  ~/.config/containers/systemd/
ln -s ~/.containers/aerc/systemd/aerc-sync.service   ~/.config/systemd/user/
ln -s ~/.containers/aerc/systemd/aerc-sync.timer     ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now aerc-sync.timer
systemctl --user start aerc-web.service
```

## Files

```
~/.containers/aerc/
├── Dockerfile                  # Alpine 3.21: aerc, isync, notmuch, w3m, urlscan, chafa, getmail6, ttyd, screen
├── sync.sh                     # host entry: flock -n on config/.sync.lock, podman run sync-inner.sh
├── archive-range.sh            # Manual bulk archive by date range: archive-range.sh <work|icloud|gmail> <start|0> <end>
├── systemd/                    # Unit files, symlinked into systemd's search paths
│   ├── aerc-web.container      # Quadlet → aerc-web.service (generated)
│   ├── aerc-sync.service       # Calls sync.sh; activated by the timer
│   └── aerc-sync.timer         # OnUnitActiveSec=3min
├── config/
│   ├── accounts.conf           # 4 accounts: icloud, gmail, work (maildir), archive (notmuch)
│   ├── aerc.conf               # UI, filters, compose, templates, per-account overrides
│   ├── binds.conf              # Vim-style keybindings, per-account overrides
│   ├── vimrc                   # Mail-mode vim: spell en_us, fileformat=unix, strip ^M
│   ├── screenrc                # Aerc-web session screenrc: vbell off, 10k scrollback
│   ├── shortcuts.txt           # Custom ? cheatsheet (opened via :term less ...)
│   ├── mbsyncrc                # iCloud IMAP (imap.mail.me.com, user: APPLE_ID_USERNAME)
│   ├── notmuch-config          # Search index config (no auto-tags)
│   ├── getmailrc               # Gmail POP3 → iCloud INBOX Maildir
│   ├── notmuch-querymap        # archive tab: pers, work (tag-based, not local_trash), local_trash
│   ├── notmuch-querymap-icloud # icloud tab: excludes to/from you@gmail.com, per folder
│   ├── notmuch-querymap-gmail  # gmail tab: only to/from you@gmail.com, per folder
│   ├── scripts/
│   │   ├── sync-inner.sh       # Full sync chain (used by host timer via podman run)
│   │   ├── sync-icloud.sh      # Fast iCloud+Gmail on-demand: getmail + mbsync icloud + notmuch + addrbook
│   │   ├── sync-work.sh      # Fast work on-demand: mbsync work + notmuch + addrbook
│   │   ├── rebuild-addrbook.sh # Dump notmuch correspondents → .addrbook for address completion
│   │   ├── addr-complete.sh    # aerc address-book-cmd: grep the .addrbook cache
│   │   ├── update-unread.sh    # Writes unread count to web-wrapper/unread for browser polling
│   │   ├── delete.sh           # Universal delete: d = --confirm, D = silent; mv to local_trash OR rm if already there
│   │   ├── archive.sh          # a binding: per-account archive (work/ → work/Archive, icloud/ → icloud/Archive); strips mbsync metadata on move
│   │   ├── save-html.sh        # W binding: save HTML + embedded (cid:) images into per-email subdir
│   │   ├── web-start.sh        # ttyd + screen wrapper for aerc-web container
│   │   └── discord-notify.py   # Polls a work IMAP folder via DavMail, posts to webhook (env-driven)
│   ├── web-wrapper/            # Keyboard-lock wrapper + PWA manifest served by Caddy; `unread` written here
│   ├── templates/
│   │   ├── quoted_reply        # Default reply template
│   │   ├── quoted_reply_outlook# Work reply template (Outlook-style quote block)
│   │   ├── forward             # Default forward template (Gmail-style "Forwarded message" separator)
│   │   └── forward_outlook     # Work forward template (Outlook-style header block)
│   ├── .icloud-app-password    # iCloud app-specific password (gitignored)
│   ├── .gmail-app-password     # Gmail app password (gitignored)
│   ├── .work-password          # Work / DavMail password (gitignored)
│   ├── .discord-webhook        # Discord webhook URL (gitignored)
│   ├── .notify.env             # discord-notify.py runtime config (gitignored)
│   ├── .notify-uidnext-*       # Discord poll state: last seen UIDNEXT (gitignored)
│   ├── .notify-seen-*          # Discord poll state: rolling Message-ID cache (gitignored)
│   ├── .addrbook               # Flat cache of notmuch correspondents (gitignored)
│   └── .sync.lock              # Shared lock file (host + container share via bind mount)
├── mail/
│   ├── icloud/                 # Synced Maildir
│   │   ├── INBOX/
│   │   ├── Archive/
│   │   ├── Drafts/
│   │   └── Junk/
│   ├── local/                  # Local-only archive store (not synced upstream)
│   │   ├── INBOX/              # Personal archive (4350+ msgs, tag:pers)
│   │   └── work/             # University archive (~12k files, tag:work), populated by archive-range.sh
│   ├── local_trash/            # Shared trash (top-level, both accounts use it)
│   ├── outlook/                # Legacy Outlook mail (1986 messages, local only)
│   └── .notmuch/               # notmuch database

~/mail-attachments              # → ~/.containers/syncthing/syncthing-data/mail-attachments (symlink)
~/.bashrc.d/aerc.sh             # Shell aliases: aerc, mail-mbox, mail-import
```

## mbsync

Two channels: `icloud` (imap.mail.me.com) and `work` (DavMail → O365 (work) at mail.example.com:1143, plaintext since traffic is internal).
- iCloud Patterns: `* !Notes !Trash !"Sent Messages" !"Deleted Messages"`
- University Patterns: `INBOX Drafts Junk Archive Sent VIP`
- Key settings per account: `AuthMechs LOGIN`, `PipelineDepth 1`, `Timeout 60`, `CopyArrivalDate yes`, `Expunge Both`, `Remove Near`. `Timeout 60` bounds how long mbsync will sit on a silent/hung IMAP socket (was `0` = forever, which caused multi-hour sync hangs when DavMail auth broke mid-flight).
- `PassCmd` uses `tr -d '\r\n' <file` instead of `cat` — defensive against password files with trailing newlines (a trailing `\n` in the LOGIN command made DavMail hang waiting for the rest of the line).
- Sync service has `TimeoutStartSec=5min` as a last-resort kill — if anything slips past mbsync's own timeout, systemd forcibly stops the stuck cycle and releases `.sync.lock` so the next 3-min tick isn't blocked silently.
- **Local-move hazard:** mbsync annotates maildir filenames with `,U=N` (the server UID for that folder). Each IMAP folder has its own UID namespace, so moving a file between folders preserves a UID that is meaningless — and may collide — in the destination. A collision aborts that channel's sync with `Maildir error: duplicate UID N`. `archive.sh` strips `,U=…` (and any `,FMD5=…`) on move so the file enters the destination as a fresh local addition. Any new script that shuffles files between mbsync-managed folders must do the same.

## notmuch

Indexes all mail under `~/Mail/` (icloud + work + local + outlook + local_trash).
No auto-tags on new messages. Manual tags: `pers` (personal archive).

**Querymaps** (three files, one per notmuch-backed account):
- `notmuch-querymap` → archive tab: `pers` (tag:pers and not path:local_trash/**), `local_trash` (path:local_trash/**)
- `notmuch-querymap-icloud` → icloud tab: INBOX/Archive/Drafts/Junk each scoped to `path:icloud/<folder>/**` and **excluding** Gmail-addressed mail
- `notmuch-querymap-gmail` → gmail tab: same folder paths but **only** Gmail-addressed mail (to/from `you@gmail.com`)

**University stays as maildir source** (not notmuch) — simpler, no filtering needed since University is a separate server.
Notmuch-backed accounts all set `maildir-store = /home/aerc/Mail` and `multi-file-strategy = act-one` (messages may have multiple backing files; `act-one` lets move operations pick one automatically).
Legacy outlook mail (1986 messages) in `mail/outlook/` — indexed by notmuch, searchable via `:query path:outlook/**`.

## Key aerc Shortcuts

| Key | Context | Action |
|---|---|---|
| `j/k` | list | Navigate messages |
| `g/G` | list | Jump to top/bottom |
| `Enter` | list | Open message |
| `d` | any list/view | Confirm prompt `[Y/n]` (Enter=yes) → move to local_trash, or permadelete if already there |
| `D` | list/view | Silent move to local_trash (main tabs only) |
| `a` | list/view | Confirm prompt `[Y/n]` (Enter=yes) → archive to the source file's own-account Archive folder |
| `v` | list | Toggle mark |
| `Space` | list | Mark + next |
| `V` | list | Select all |
| `C/m` | list | Compose |
| `rr` | list/view | Reply all (quoted) |
| `Rr` | list/view | Reply (quoted) |
| `f` | view | Forward |
| `P` | any tab | Run account's check-mail-cmd (scoped sync; blocks on `.sync.lock`) |
| `?` | global | Open custom shortcut cheatsheet (`config/shortcuts.txt`) |
| `U` | view | Browse URLs (urlscan, parses raw MIME for intact URLs) |
| `W` | view | Save HTML email + embedded images to per-email subdir in mail-attachments; prints files.example.com URL |
| `S` | view | Save attachment |
| `o` | view | Open attachment |
| `Ctrl+j/k` | view | Next/prev MIME part |
| `Ctrl+l` | view | Open link |
| `H` | view | Toggle headers |
| `/` | list | Search |
| `\` | list | Filter |
| `c` | list | Change folder |
| `Ctrl+n/p` | global | Switch tabs (also `Alt+n/p`, `]t` / `[t`) |
| `q` | global | Quit |

## Bulk Archive (`archive-range.sh`)

Manual script for moving large date-range chunks of mail out of an active account into local storage. Server-side messages are deleted on the next mbsync run (Expunge Both).

```
~/.containers/aerc/archive-range.sh <work|icloud|gmail> <start|0> <end>
```

- **start** = `0` means "from the beginning"; otherwise `YYYY-MM-DD`.
- **end** = `YYYY-MM-DD`, inclusive.
- Skips `tag:flagged` messages.
- Destination: `mail/local/<account>/cur/`. Tags moved messages with `tag:<account>`.
- Per-account scope: work covers Sent+Archive folders; icloud/gmail cover icloud/Archive (Gmail-addressed filtered for the account name).
- Serializes against sync via the shared `config/.sync.lock`.

The Archive tab's `notmuch-querymap` includes folders for each tag:
- `pers` → `tag:pers and not path:local_trash/**`
- `work` → `tag:work and not path:local_trash/**`
- `local_trash` → `path:local_trash/**`

To add another (e.g., `outlook`), append a `tag:` querymap entry and add the folder to the archive account's `folders =` list.

### Synthetic Message-IDs for University stubs

DavMail/EWS sometimes returns Sent-folder messages from O365 without a `Message-ID` header (115 such files in University at last check). notmuch refuses to index these. A one-shot Python pass prepends `Message-ID: <uuid@local.generated>` to any such file under `mail/work/` so they become searchable. Re-runnable: skips files that already have a Message-ID. The modification stays purely local — mbsync tracks by server UID, so adding headers locally never propagates.

## Mail Attachments (Syncthing-backed)

Saved attachments, HTML-saved emails (`W` binding), and any files you want to attach while composing all live in `~/.containers/syncthing/syncthing-data/mail-attachments/`. That folder is:

- Synced to your phone / other devices via syncthing — drop an image into the folder on your phone → appears on the server.
- Bind-mounted into the aerc container at `/home/aerc/mail-attachments` (see `~/.bashrc.d/aerc.sh`).
- Set as aerc's `default-save-path` (so `S` saves attachments there).
- Written to by `save-html.sh` (the `W` binding): creates `<timestamp>_<subject>/index.html` plus any cid: images as sibling files (src refs rewritten to local filenames).
- Served by Caddy at `files.example.com` (read-only browse).
- Also accessible on the host at `~/mail-attachments` (symlink).

Attach from aerc compose: `:attach /home/aerc/mail-attachments/<filename>`.

## Caddy Integration

- `files.example.com` — serves `~/.containers/syncthing/syncthing-data/mail-attachments/` (browse enabled; see Mail Attachments section)
- `mail.example.com` — web aerc (see Web Access section): `/tty/*` → ttyd on `127.0.0.1:7681`, `/` → `config/web-wrapper/` file_server.

## Rebuilding

```bash
cd ~/.containers/aerc && podman build -t localhost/aerc:latest .
# aerc-web is now running on the old image layers; restart to pick up the new build:
systemctl --user restart aerc-web.service
```

## aerc Docs

- aerc(1): https://man.archlinux.org/man/aerc.1
- aerc-config(5): https://man.archlinux.org/man/aerc-config.5
- aerc-accounts(5): https://man.archlinux.org/man/aerc-accounts.5
- aerc-binds(5): https://man.archlinux.org/man/aerc-binds.5
- aerc-templates(7): https://man.archlinux.org/man/aerc-templates.7
- aerc-notmuch(5): https://man.archlinux.org/man/aerc-notmuch.5
- aerc-maildir(5): https://man.archlinux.org/man/aerc-maildir.5
- mbsync(1): https://isync.sourceforge.io/mbsync.html
- notmuch(1): https://notmuchmail.org/manpages/
- postfix main.cf(5): https://www.postfix.org/postconf.5.html (for the relay container)

## Known Issues

- iCloud IMAP User must be Apple ID username (`APPLE_ID_USERNAME`), not custom domain email
- iCloud app-specific password required (appleid.apple.com > Sign-In & Security)
- `mouse-enabled = false` — mouse disabled entirely; use keyboard nav (press `?` for cheatsheet)
- mbsync `PipelineDepth 1` makes sync slow but reliable (iCloud throttles)
- busybox flock (Alpine) lacks `-w`; check-mail-cmd uses plain blocking flock, capped by `check-mail-timeout = 5m`
- notmuch `multi-file-strategy = act-one` needed for Archive delete/move (default `refuse` silently fails)
