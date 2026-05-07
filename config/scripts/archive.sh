#!/bin/sh
# Archive one or more messages into their own-account Archive folder:
#   mail/work/... → mail/work/Archive/cur/
#   mail/icloud/... → mail/icloud/Archive/cur/   (also covers Gmail-via-POP)
#   other paths (outlook/, local/, local_trash/) are not archived.
# Strips mbsync metadata (,U=N, ,FMD5=…) from filenames so the moved file
# is treated as a fresh local addition — prevents UID collisions in the dest.
# Accepts a single RFC822 message on stdin OR an mbox-concatenated stream
# (aerc's `:pipe -bm` with multiple marked messages uses the latter).
# Pass --confirm to prompt before acting (default Y on bare Enter).
set -eu

CONFIRM=0
[ "${1:-}" = "--confirm" ] && CONFIRM=1

msg=$(mktemp)
cat > "$msg"

ids_file=$(mktemp)
subject=$(python3 - "$msg" "$ids_file" <<'PY'
import mailbox, sys
from email import message_from_binary_file, policy
from email.header import decode_header, make_header

path, ids_out = sys.argv[1], sys.argv[2]

def get_mid(m):
    raw = (m.get("Message-ID") or m.get("Message-Id") or "").strip()
    return raw.lstrip("<").rstrip(">").split()[0] if raw else ""

def get_sub(m):
    s = m.get("Subject") or ""
    try:
        s = str(make_header(decode_header(s)))
    except Exception:
        pass
    return s.replace("\n", " ").strip()[:120]

with open(path, "rb") as f:
    head = f.read(5)

messages = []
if head.startswith(b"From "):
    for m in mailbox.mbox(path):
        messages.append(m)
else:
    with open(path, "rb") as f:
        messages.append(message_from_binary_file(f, policy=policy.compat32))

with open(ids_out, "w") as out:
    for m in messages:
        mid = get_mid(m)
        if mid:
            out.write(mid + "\n")

print(get_sub(messages[0]) if messages else "")
PY
)
rm -f "$msg"

if [ ! -s "$ids_file" ]; then
    rm -f "$ids_file"
    echo "archive: no Message-IDs found in input" >&2
    sleep 1
    exit 1
fi

ICLOUD_ARCHIVE=/home/aerc/Mail/icloud/Archive/cur
WORK_ARCHIVE=/home/aerc/Mail/work/Archive/cur
mkdir -p "$ICLOUD_ARCHIVE" "$WORK_ARCHIVE"

plan=$(mktemp)
while IFS= read -r msgid; do
    [ -n "$msgid" ] || continue
    for src in $(notmuch search --output=files "id:$msgid"); do
        [ -f "$src" ] || continue
        case "$src" in
            "$ICLOUD_ARCHIVE"/*|"$WORK_ARCHIVE"/*) continue ;;
            /home/aerc/Mail/work/*) printf '%s\t%s\n' "$src" "$WORK_ARCHIVE" >> "$plan" ;;
            /home/aerc/Mail/icloud/*) printf '%s\t%s\n' "$src" "$ICLOUD_ARCHIVE" >> "$plan" ;;
            *) ;;
        esac
    done
done < "$ids_file"
rm -f "$ids_file"

if [ ! -s "$plan" ]; then
    rm -f "$plan"
    echo "Nothing to archive (already in Archive or unrecognized path)."
    sleep 1
    exit 0
fi

n_files=$(wc -l < "$plan")

if [ "$CONFIRM" = "1" ]; then
    echo "Subject: $subject"
    echo
    awk -F'\t' '{print "  " $1 "\n    → " $2}' "$plan"
    echo
    printf "Archive %s file(s)? [Y/n] " "$n_files"
    read -r ans </dev/tty
    case "$ans" in n|N|no|NO) rm -f "$plan"; echo "Cancelled."; sleep 0.5; exit 0 ;; esac
fi

moved=0
while IFS="$(printf '\t')" read -r src dest; do
    [ -f "$src" ] || continue
    name=$(basename "$src")
    case "$name" in
        *:2,*) base=${name%%:2,*}; flags=":2,${name#*:2,}" ;;
        *)     base=$name;         flags="" ;;
    esac
    base=${base%%,*}
    mv "$src" "$dest/${base}${flags}"
    moved=$((moved + 1))
done < "$plan"
rm -f "$plan"

# Reindex synchronously: the icloud/gmail tabs are notmuch-backed, so aerc
# only drops the moved messages from the list once notmuch knows their new
# path. Backgrounding here leaves stale entries (esp. with `A` thread archive).
notmuch new --quiet

echo "Archived: $subject"
echo "  files moved: $moved"
exit 0
