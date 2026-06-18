---
name: example-skill
description: Replace this with your skill's one-line description — shown in /skills list.
---

# Example Skill

Replace this file with your own skill prompt. The `name` in the frontmatter must
match the directory name. The `description` is shown when users run `/skills`.

To add more skills, create additional directories under `skills/` in the template
repo, each containing a `SKILL.md`. They are seeded on first boot and user edits
are never overwritten on redeploy.

## Personalisation placeholders

Use `${HERMES_OWNER_NAME}` or `${HERMES_EA_NAME}` anywhere in this file to insert
the owner's or EA's name at deploy time. Set the corresponding Railway Variable
and the value is substituted when the skill is first written to the volume.

Example: "Never act without ${HERMES_OWNER_NAME}'s explicit approval."
