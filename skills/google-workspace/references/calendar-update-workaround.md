# Calendar Update Workaround

`google_api.py` does not expose a `calendar update` subcommand (only `list`,
`create`, `delete`). To update an existing event, use the Google Calendar API
directly via Python.

## Pattern

```python
import json, sys
sys.path.insert(0, "/data/.hermes/skills/productivity/google-workspace/scripts")
from google_api import get_credentials

creds = get_credentials()
from googleapiclient.discovery import build
service = build("calendar", "v3", credentials=creds)

event_id = "EVENT_ID_HERE"

# Fetch current event
event = service.events().get(calendarId="primary", eventId=event_id).execute()

# Mutate fields
event["description"] = "Updated description text"
# event["summary"] = "New Title"
# event["location"] = "123 Main St"
# event["start"] = {"dateTime": "2026-06-27T14:00:00-04:00", "timeZone": "America/Toronto"}
# event["end"] = {"dateTime": "2026-06-27T15:00:00-04:00", "timeZone": "America/Toronto"}

# Write back
updated = service.events().update(
    calendarId="primary", eventId=event_id, body=event
).execute()

print(json.dumps({
    "status": "updated",
    "summary": updated["summary"],
    "start": updated["start"],
    "description": updated.get("description", ""),
    "htmlLink": updated["htmlLink"],
}, indent=2))
```

## Notes

- `get_credentials()` respects HERMES_HOME, so this works for any profile.
- Always `.get()` first then mutate — don't build the event body from scratch
  or you'll clobber fields (attendees, recurrence, reminders, etc.).
- `calendarId="primary"` works for the authenticated user's main calendar.
  For shared calendars, use the calendar's email address.
- Fields you don't touch in the dict are preserved.
