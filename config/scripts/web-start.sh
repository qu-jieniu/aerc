#!/bin/sh
# Serve aerc as a web terminal over ttyd, wrapped in screen for persistence
# across WebSocket disconnects. ttyd mounts under /tty/ so the wrapper at / can
# iframe it and call navigator.keyboard.lock() to release browser-reserved keys.
# screen's default prefix Ctrl+A does not conflict with aerc — no custom rcfile
# needed.
exec ttyd \
    -p 7681 -W \
    -b /tty \
    -t fontSize=14 \
    -t 'titleFixed=aerc' \
    -t 'disableLeaveAlert=true' \
    -t 'bellStyle=sound' \
    screen -c /home/aerc/.config/aerc/screenrc -D -R -S mail aerc
