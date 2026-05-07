#!/bin/sh
# Save HTML part of email + any embedded (cid:) images to a per-email
# subdirectory in the shared attachments dir, so files.example.com renders
# the HTML with all inline images intact.
tmpfile=$(mktemp /tmp/msg.XXXXXX)
cat > "$tmpfile"

python3 -c "
import email, email.header, mimetypes, os, re, sys, time

with open('$tmpfile', 'rb') as f:
    msg = email.message_from_binary_file(f)

raw = msg.get('Subject', 'email')
parts = email.header.decode_header(raw)
subj = ''.join(
    p.decode(enc or 'utf-8', errors='replace') if isinstance(p, bytes) else p
    for p, enc in parts
)
subj = ''.join(c if c.isalnum() or c in ' -_' else '_' for c in subj)[:50].strip()
ts = time.strftime('%Y%m%d-%H%M%S')
dirname = f'{ts}_{subj}' if subj else ts
outdir = f'/home/aerc/mail-attachments/{dirname}'
os.makedirs(outdir, exist_ok=True)

html_part = None
images = []  # (cid, filename, payload)
for part in msg.walk():
    ctype = part.get_content_type()
    if ctype == 'text/html' and html_part is None:
        html_part = part
        continue
    cid = part.get('Content-ID', '').strip().lstrip('<').rstrip('>')
    disp = (part.get('Content-Disposition') or '').lower()
    if ctype.startswith('image/') and (cid or 'inline' in disp):
        payload = part.get_payload(decode=True)
        if not payload:
            continue
        ext = mimetypes.guess_extension(ctype) or '.bin'
        fname = part.get_filename()
        if fname:
            fname = ''.join(c if c.isalnum() or c in ' -_.' else '_' for c in fname)[:60]
        else:
            fname = f'img{len(images) + 1:02d}{ext}'
        images.append((cid, fname, payload))

if html_part is None:
    print('No HTML part found')
    sys.exit(0)

html = html_part.get_payload(decode=True) or b''
charset = html_part.get_content_charset() or 'utf-8'
try:
    html_text = html.decode(charset, errors='replace')
except LookupError:
    html_text = html.decode('utf-8', errors='replace')

for cid, fname, payload in images:
    with open(os.path.join(outdir, fname), 'wb') as out:
        out.write(payload)
    if cid:
        html_text = re.sub(
            r'cid:' + re.escape(cid), fname, html_text, flags=re.IGNORECASE
        )

with open(os.path.join(outdir, 'index.html'), 'w', encoding='utf-8') as out:
    out.write(html_text)

print(f'Saved: {dirname}/ ({len(images)} image(s))')
print(f'https://files.example.com/{dirname}/index.html')
"
rm -f "$tmpfile"
