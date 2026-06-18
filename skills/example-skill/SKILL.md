---
name: example-skill
description: Replace this with your skill's one-line description — shown in /skills list.
---

# Example Skill

Replace this file with your own skill prompt. The `name` in the frontmatter must
match the directory name. The `description` is shown when users run `/skills`.

To add more skills, create additional directories under `skills/` in the template
repo, each containing a `SKILL.md`. SKILL.md is re-rendered on every boot from
the template source; scripts and reference files are copy-if-not-exists.

## Personalisation placeholders

Use `{OWNER_NAME}` or `{EA_NAME}` anywhere in this file. They are substituted
at boot time from the `HERMES_OWNER_NAME` / `HERMES_EA_NAME` Railway Variables.
If a variable isn't set yet, the placeholder is kept verbatim — so you can set
(or change) the variables any time and the next redeploy picks them up. No race.

Example: "Never act without {OWNER_NAME}'s explicit approval."
