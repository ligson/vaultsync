# Repository Rules

This repository is documentation-first for now.

## Working rules

- Keep design, requirements, and notes in `docs/`.
- Keep reusable patterns and decisions in `docs/notes/`.
- Keep formal specs and architecture docs in `docs/specs/`.
- Update `CHANGELOG.md` for every meaningful change.
- Prefer small, focused documents over one giant note.
- When a decision becomes stable, write it down instead of keeping it only in chat.

## Current project direction

- Backend target: Go + SQLite.
- Deployment target: single NAS instance.
- Security target: client-side encryption with server-side ciphertext only.
- Do not design for multi-instance or cluster deployment in the first version.

