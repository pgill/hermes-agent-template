---
name: google-workspace
description: "Gmail, Calendar, Drive, Docs, Sheets via OAuth + Python CLI."
version: 2.0.0
author: Nous Research
license: MIT
platforms: [linux, macos, windows]
required_credential_files:
  - path: google_token.json
    description: Google OAuth2 token (created by setup script)
  - path: google_client_secret.json
    description: Google OAuth2 client credentials (downloaded from Google Cloud Console)
metadata:
  hermes:
    tags: [Google, Gmail, Calendar, Drive, Sheets, Docs, Contacts, Email, OAuth]
    homepage: https://github.com/NousResearch/hermes-agent
    related_skills: [himalaya]
    class_level: true
---

# Google Workspace

Gmail, Calendar, Drive, Contacts, Sheets, and Docs — through OAuth and a thin CLI wrapper.

## References

- `references/gmail-search-syntax.md` — Gmail search operators (is:unread, from:, newer_than:, etc.)
- `references/calendar-update-workaround.md` — Workaround for updating calendar events
- `references/html-email-extraction.md` — Extracting body from HTML-only emails

## Scripts

- `scripts/setup.py` — OAuth2 setup (run once to authorize)
- `scripts/google_api.py` — API CLI for Gmail, Calendar, Drive, Sheets, Docs

## Setup

The setup is fully non-interactive — you (the agent) drive it step by step so it works on CLI, Telegram, Discord, or any platform.

Define a shorthand first:

```bash
GSETUP="python ${HERMES_HOME:-$HOME/.hermes}/skills/google-workspace/scripts/setup.py"
```

### Step 0: Check if already set up

```bash
$GSETUP --check
```

If it prints `AUTHENTICATED`, skip to Usage — setup is done.

### Step 1: Create OAuth credentials (~5 minutes, one-time)

Tell the user:

> You need a Google Cloud OAuth client. This is a one-time setup:
>
> 1. Go to [Google Cloud Console](https://console.cloud.google.com/projectselector2/home/dashboard) and create or select a project
> 2. Go to the [API Library](https://console.cloud.google.com/apis/library) and enable these APIs:
>    **Gmail API, Google Calendar API, Google Drive API, Google Sheets API, Google Docs API, People API**
> 3. Go to [Credentials](https://console.cloud.google.com/apis/credentials) → Create Credentials → **OAuth 2.0 Client ID**
> 4. Application type: **Desktop app** → Create
> 5. Go to [Audience](https://console.cloud.google.com/auth/audience) → Test users → **Add your Google email as a test user**
> 6. Download the JSON file and tell me the file path
>
> If using the Hermes CLI: don't send a bare file path starting with `/` as its own message — it can be mistaken for a slash command. Send it in a sentence like: `The file is at /home/user/Downloads/client_secret.json`

Once they provide the path:

```bash
$GSETUP --client-secret /path/to/client_secret.json
```

If the user pastes raw `client_id` / `client_secret` values instead of a file path, write a valid Desktop OAuth JSON file yourself, save it (e.g. `~/Downloads/hermes-google-client-secret.json`), then run `--client-secret` against it.

### Step 2: Get authorization URL

```bash
$GSETUP --auth-url
```

Agent rules for this step:
- Send the printed URL to the user as a single line
- Tell the user the browser will likely show an error page after approval (failing on `http://localhost:1`) — **this is expected**
- Tell them to **copy the ENTIRE URL from the browser address bar** (it contains their auth code)
- If the user gets `Error 403: access_denied`, send them to [Audience settings](https://console.cloud.google.com/auth/audience) to add themselves as a test user

### Step 3: Exchange the code

The user will paste back either a URL like `http://localhost:1/?code=4/0A...&scope=...` or just the code string. Either works:

```bash
$GSETUP --auth-code "THE_URL_OR_CODE_THE_USER_PASTED"
```

### Step 4: Verify

```bash
$GSETUP --check
```

Should print `AUTHENTICATED`. Setup is complete — the token auto-refreshes from now on.

### Notes

- Token is stored at `~/.hermes/google_token.json` and auto-refreshes.
- If auth breaks later, run `$GSETUP --revoke` then redo Steps 2–4.
- To install Python deps manually: `$GSETUP --install-deps`

## Usage

All commands go through the API script:

```bash
GAPI="python ${HERMES_HOME:-$HOME/.hermes}/skills/google-workspace/scripts/google_api.py"
```

### Gmail

```bash
# Search (returns JSON array with id, from, subject, date, snippet)
$GAPI gmail search "is:unread" --max 10
$GAPI gmail search "from:boss@company.com newer_than:1d"
$GAPI gmail search "has:attachment filename:pdf newer_than:7d"

# Read full message
$GAPI gmail get MESSAGE_ID

# Draft (creates a draft — does NOT send; user reviews and sends manually)
$GAPI gmail draft --to user@example.com --subject "Hello" --body "Message text"
$GAPI gmail draft --to user@example.com --subject "Report" --body "<h1>Q4</h1><p>Details...</p>" --html
$GAPI gmail draft --to user@example.com --subject "Follow-up" --body "Details" --thread-id THREAD_ID

# Send (requires explicit user approval — see Rule 1)
$GAPI gmail send --to user@example.com --subject "Hello" --body "Message text"
$GAPI gmail send --to user@example.com --subject "Report" --body "<h1>Q4</h1><p>Details...</p>" --html

# Reply (automatically threads; sends immediately — same approval bar as send)
$GAPI gmail reply MESSAGE_ID --body "Thanks, that works for me."

# Labels
$GAPI gmail labels
$GAPI gmail modify MESSAGE_ID --add-labels LABEL_ID
$GAPI gmail modify MESSAGE_ID --remove-labels UNREAD
```

### Calendar

```bash
# List events (defaults to next 7 days)
$GAPI calendar list
$GAPI calendar list --start 2026-03-01T00:00:00Z --end 2026-03-07T23:59:59Z

# Create event (ISO 8601 with timezone required)
$GAPI calendar create --summary "Team Standup" --start 2026-03-01T10:00:00-05:00 --end 2026-03-01T10:30:00-05:00
$GAPI calendar create --summary "Lunch" --start 2026-03-01T12:00:00Z --end 2026-03-01T13:00:00Z --location "Cafe"
$GAPI calendar create --summary "Review" --start 2026-03-01T14:00:00Z --end 2026-03-01T15:00:00Z --attendees "alice@co.com,bob@co.com"

# Delete event
$GAPI calendar delete EVENT_ID
```

### Drive

```bash
# Search files
$GAPI drive search "quarterly report" --max 10
$GAPI drive search "mimeType='application/pdf'" --raw-query --max 5

# Get file metadata
$GAPI drive get FILE_ID

# Upload
$GAPI drive upload /path/to/report.pdf
$GAPI drive upload /path/to/image.png --name "Logo.png" --parent FOLDER_ID

# Download
$GAPI drive download FILE_ID
$GAPI drive download DOC_ID --output ~/doc.pdf

# Create folder
$GAPI drive create-folder "Reports"

# Share
$GAPI drive share FILE_ID --email alice@example.com --role reader
$GAPI drive share FILE_ID --type anyone --role reader  # anyone with link

# Delete (defaults to trash; use --permanent to skip)
$GAPI drive delete FILE_ID
```

### Contacts

```bash
$GAPI contacts list --max 20
```

### Sheets

```bash
# Create
$GAPI sheets create --title "Q4 Budget"

# Read
$GAPI sheets get SHEET_ID "Sheet1!A1:D10"

# Write
$GAPI sheets update SHEET_ID "Sheet1!A1:B2" --values '[["Name","Score"],["Alice","95"]]'

# Append rows
$GAPI sheets append SHEET_ID "Sheet1!A:C" --values '[["new","row","data"]]'
```

### Docs

```bash
# Read
$GAPI docs get DOC_ID

# Create
$GAPI docs create --title "Meeting Notes"
$GAPI docs create --title "Draft" --body "First paragraph..."

# Append text
$GAPI docs append DOC_ID --text "Additional content"
```

## Output Format

All commands return JSON. Key fields:

- **Gmail search**: `[{id, threadId, from, to, subject, date, snippet, labels}]`
- **Gmail get**: `{id, threadId, from, to, subject, date, labels, body}`
- **Gmail draft**: `{status: "drafted", draftId, messageId, threadId}`
- **Gmail send/reply**: `{status: "sent", id, threadId}`
- **Calendar list**: `[{id, summary, start, end, location, description, htmlLink}]`
- **Calendar create**: `{status: "created", id, summary, htmlLink}`
- **Drive search**: `[{id, name, mimeType, modifiedTime, webViewLink}]`
- **Drive upload**: `{status: "uploaded", id, name, mimeType, webViewLink}`
- **Drive download**: `{status: "downloaded", id, name, path, mimeType}`
- **Sheets get**: `[[cell, cell, ...], ...]`
- **Sheets create**: `{status: "created", spreadsheetId, title, spreadsheetUrl}`
- **Docs create**: `{status: "created", documentId, title, url}`

## Rules

1. **Email is draft-and-you-send.** When composing outbound email, ALWAYS use `gmail draft` (not `gmail send`) unless the user has explicitly said "send it" for this specific message. The workflow is: create a draft → notify the user (subject, recipients, summary) → user opens Gmail and hits send. `gmail send` and `gmail reply` send immediately — only use them with clear, explicit, per-message approval from the user.
2. **Confirm before destructive/external actions.** Never create/delete calendar events, delete Drive files, share files, or modify Docs/Sheets without confirming with the user first. Show what will be done and ask for approval.
3. **Check auth before first use** — run `setup.py --check`. If it fails, guide the user through Setup above.
4. **Calendar times must include timezone** — always use ISO 8601 with offset (e.g. `2026-03-01T10:00:00-05:00`) or UTC (`Z`).
5. **Respect rate limits** — avoid rapid-fire sequential API calls.
6. **Use the Gmail search syntax reference** for complex queries — load it with `skill_view("google-workspace", file_path="references/gmail-search-syntax.md")`.

## Troubleshooting

- **`NOT_AUTHENTICATED`** → Run Setup Steps 1–4 above
- **`REFRESH_FAILED`** → Token revoked or expired — `$GSETUP --revoke` then redo Steps 2–4
- **`HttpError 403: Insufficient Permission`** → Missing scope — `$GSETUP --revoke` then redo Steps 2–4
- **`AUTHENTICATED (partial)`** → Missing scopes — `$GSETUP --revoke` then redo Steps 2–4
- **`HttpError 403: Access Not Configured`** → User needs to enable the API in Google Cloud Console
- **`Error 403: access_denied`** → User needs to add themselves as a test user in [Audience settings](https://console.cloud.google.com/auth/audience)
- **`ModuleNotFoundError`** → Run `$GSETUP --install-deps`
- **`gmail get` returns empty body** → HTML-only email — see `references/html-email-extraction.md`
- **Calendar update not supported** → See `references/calendar-update-workaround.md`

## Revoking Access

```bash
$GSETUP --revoke
```
