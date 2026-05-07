# aerc — containerized CLI mail setup

A working aerc setup that runs in Podman with three mail backends (iCloud + Gmail
via POP + a work O365 account via DavMail), notmuch-backed search, periodic sync
via systemd timer, and a browser-accessible TUI via ttyd.

This repo is the *configuration* — the `mail/` Maildir tree and credential files
are gitignored. See **CLAUDE.md** for the full architecture, sync design, and
operational notes.

## Setup

1. Install [Podman](https://podman.io/) and (for the host-side timer) systemd.

2. Clone the repo somewhere (the scripts are path-agnostic; they resolve their
   own location):
   ```sh
   git clone <this-repo> ~/.containers/aerc
   cd ~/.containers/aerc
   ```

3. Fill in credentials. Each `*.example` file shows what's expected:
   ```sh
   cp config/.icloud-app-password.example   config/.icloud-app-password
   cp config/.gmail-app-password.example    config/.gmail-app-password
   cp config/.work-password.example         config/.work-password
   cp config/.discord-webhook.example       config/.discord-webhook   # optional
   cp config/.notify.env.example            config/.notify.env        # optional
   ```
   Then edit each one with real values. They're gitignored.

4. Edit the static configs to match your accounts:
   - `config/accounts.conf` — From addresses, aliases, folders
   - `config/mbsyncrc` — IMAP hosts, usernames
   - `config/getmailrc` — Gmail address (only the user line)
   - `config/notmuch-config` — `name=` and `primary_email=`
   - `config/notmuch-querymap-{icloud,gmail}` — Gmail filter address

5. Build and start:
   ```sh
   podman build -t localhost/aerc:latest .
   ln -s "$PWD"/systemd/aerc-web.container ~/.config/containers/systemd/
   ln -s "$PWD"/systemd/aerc-sync.service  ~/.config/systemd/user/
   ln -s "$PWD"/systemd/aerc-sync.timer    ~/.config/systemd/user/
   systemctl --user daemon-reload
   systemctl --user enable --now aerc-sync.timer aerc-web.service
   ```

6. The TUI lives inside the persistent `aerc-web` container. Add this shell
   function to attach (replacing the path with wherever you cloned):
   ```sh
   aerc() { podman exec -it aerc-web screen -DRS mail; }
   ```
   Or expose `mail.example.com` via Caddy → `127.0.0.1:7681` for browser access.

## Outgoing mail

This setup expects a separate `postfix-relay` container that does
envelope-From-based routing (iCloud SMTP / Gmail SMTP / DavMail) and BCCs sent
mail back to the sender's INBOX so it threads via `mbsync`. The relay isn't in
this repo — every account's `outgoing` line just points at it. You can either
build your own relay or replace each account's `outgoing` with direct upstream
SMTP and per-account `copy-to`.

## What's not included

- The actual `mail/` Maildir tree (your email)
- Credential files (`.icloud-app-password` etc.)
- The `postfix-relay` container
- The DavMail container (`~/.containers/davmail/`)
- The Caddy config (`mail.example.com`, `files.example.com` reverse proxies)
