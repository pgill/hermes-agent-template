# HTML-Only Email Extraction

## Problem

`$GAPI gmail get MESSAGE_ID` returns an empty or whitespace-only `body` field
when the email has no `text/plain` MIME part. This is common with:
- School / institutional emails (e.g. Havergal, Veracross-powered mailers)
- Marketing newsletters and transactional emails
- Any sender using an HTML email builder

## Workaround

Use the Google API directly to fetch the raw message and extract HTML parts:

```python
import sys, os, base64, re
sys.path.insert(0, os.path.expanduser('~/.hermes/skills/productivity/google-workspace/scripts'))
from google_api import get_credentials
from googleapiclient.discovery import build

creds = get_credentials()
service = build('gmail', 'v1', credentials=creds)
msg = service.users().messages().get(userId='me', id='MESSAGE_ID', format='full').execute()

def find_parts(payload, mime_type):
    """Recursively walk MIME parts to find all parts of a given type."""
    parts = []
    if payload.get('mimeType') == mime_type:
        data = payload.get('body', {}).get('data', '')
        if data:
            parts.append(base64.urlsafe_b64decode(data).decode('utf-8', errors='replace'))
    for part in payload.get('parts', []):
        parts.extend(find_parts(part, mime_type))
    return parts

payload = msg.get('payload', {})

# Prefer text/plain, fall back to stripped HTML
texts = find_parts(payload, 'text/plain')
if texts and texts[0].strip():
    body = texts[0]
else:
    htmls = find_parts(payload, 'text/html')
    if htmls:
        text = htmls[0]
        text = re.sub(r'<style[^>]*>.*?</style>', '', text, flags=re.DOTALL)
        text = re.sub(r'<[^>]+>', ' ', text)
        # Decode common HTML entities
        for entity, char in [('&nbsp;', ' '), ('&amp;', '&'), ('&lt;', '<'),
                             ('&gt;', '>'), ('&#39;', "'"), ('&quot;', '"')]:
            text = text.replace(entity, char)
        body = re.sub(r'\s+', ' ', text).strip()
    else:
        body = ''

print(body[:10000])
```

## Notes

- This pattern works inside `terminal()` — run it as a python3 -c one-liner or
  save to a temp script. Also works inside `delegate_task` subagents.
- `execute_code` may be blocked in cron mode; use `terminal()` instead.
- The text/plain check includes `.strip()` because some HTML-only emails
  still have a text/plain part that's just whitespace (single space).
