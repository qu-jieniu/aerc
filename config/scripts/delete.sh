#!/bin/sh
# Universal delete. For each message on stdin:
#   - if every file is already under local_trash/  → permanent rm
#   - otherwise                                    → mv to local_trash
# Accepts a single RFC822 message OR an mbox-concatenated stream (aerc's
# `:pipe -m` with multiple marked messages uses the latter).
# Pass --confirm to prompt in a term pane. Bindings:
#   d = :pipe -m  sh delete.sh --confirm   (confirm, any tab)
#   D = :pipe -bm sh delete.sh             (silent, main tabs)
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
    echo "delete: no Message-IDs found in input" >&2
    exit 1
fi

n_msgs=$(wc -l < "$ids_file")

# Build plan: "action<TAB>src" per file. action ∈ {rm, mv}.
plan=$(mktemp)
any_rm=0; any_mv=0
while IFS= read -r msgid; do
    [ -n "$msgid" ] || continue
    files=$(notmuch search --output=files "id:$msgid")
    [ -n "$files" ] || continue
    all_in_trash=1
    for f in $files; do
        case "$f" in
            /home/aerc/Mail/local_trash/*) ;;
            *) all_in_trash=0; break ;;
        esac
    done
    for f in $files; do
        if [ "$all_in_trash" = "1" ]; then
            printf 'rm\t%s\n' "$f" >> "$plan"
            any_rm=1
        else
            printf 'mv\t%s\n' "$f" >> "$plan"
            any_mv=1
        fi
    done
done < "$ids_file"
rm -f "$ids_file"

if [ ! -s "$plan" ]; then
    rm -f "$plan"
    echo "delete: no files found for the given Message-IDs" >&2
    exit 1
fi

if [ "$any_rm" = "1" ] && [ "$any_mv" = "1" ]; then
    action="Delete+trash (mixed: some already in local_trash, some not)"
elif [ "$any_rm" = "1" ]; then
    action="PERMANENTLY delete"
else
    action="Move to local_trash"
fi

n_files=$(wc -l < "$plan")

if [ "$CONFIRM" = "1" ]; then
    echo "Subject: $subject"
    [ "$n_msgs" -gt 1 ] && echo "(+$((n_msgs - 1)) more message(s))"
    echo
    echo "Files:"
    awk -F'\t' '{print "  [" $1 "] " $2}' "$plan"
    echo
    printf "%s: %s file(s)? [Y/n] " "$action" "$n_files"
    read -r ans </dev/tty
    case "$ans" in n|N|no|NO) rm -f "$plan"; echo "Cancelled."; sleep 0.5; exit 0 ;; esac
fi

TRASH=/home/aerc/Mail/local_trash/cur
mkdir -p "$TRASH"
while IFS="$(printf '\t')" read -r act src; do
    [ -f "$src" ] || continue
    if [ "$act" = "rm" ]; then
        rm -f "$src"
    else
        name=$(basename "$src")
        case "$name" in
            *:2,*) base=${name%%:2,*}; flags=${name#*:2,} ;;
            *)     base=$name;         flags="" ;;
        esac
        case "$flags" in *S*) ;; *) flags="${flags}S" ;; esac
        flags=$(printf '%s' "$flags" | fold -w1 | sort -u | tr -d '\n')
        mv "$src" "$TRASH/${base}:2,${flags}"
    fi
done < "$plan"
rm -f "$plan"

# Reindex synchronously: the icloud/gmail/archive tabs are notmuch-backed, so
# aerc only drops the moved messages from the list once notmuch knows their
# new path. Backgrounding here leaves stale entries on multi-message delete.
notmuch new --quiet

if [ "$CONFIRM" = "1" ]; then
    echo "Done: $n_files file(s) processed."
fi
exit 0
