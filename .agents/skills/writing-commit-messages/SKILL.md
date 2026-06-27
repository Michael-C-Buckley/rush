---
name: writing-commit-messages
description: Uses Linux kernel commit message guidelines. Use when writing or editing Git commit messages.
---

# Writing Commit Messages

Use Linux kernel-style commits:

- Every commit must have a subject and a message
- Format subjects as `subsystem: imperative summary`, e.g. `ui: add profile overlay toggle`.
- Keep subjects concise and lowercase after the subsystem unless a proper noun requires capitalization.
- Use the imperative mood: `add`, `fix`, `remove`, `update`; avoid `added`, `adds`, or gerunds.
- Explain the problem being solved and why the change is needed.
- Describe what changed, not implementation trivia.
- Keep the body wrapped to about 75 columns.
