# Current Decisions

## Locked in

- Backend: Go.
- Metadata store: SQLite.
- Deployment: single NAS instance.
- Files on disk: ciphertext only.
- Key management: client-side, never stored as plaintext on the server.
- Scope: private sync first, shared folders later if ever needed.

## Documentation habits

- Update `CHANGELOG.md` for every meaningful change.
- Save durable knowledge in `docs/notes/`.
- Put formal product or architecture writeups in `docs/specs/`.

