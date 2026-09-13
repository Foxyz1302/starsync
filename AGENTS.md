# AGENTS.md — sync_relay_project

Project conventions for agents. Global interaction rules live in the
user-level AGENTS.md; this file holds repo-specific facts only.
Source of truth order: codebase > `HANDOFF.md` + `docs/ROADMAP.md` >
chat history.

## Wishlist drafts

The user drops raw idea/bug lists as drafts (gitignored, never
committed: `docs/Wishlist.md`, `docs/drafts/`). Agent duty on sight:
translate each entry into its proper place — `docs/ROADMAP.md`
backlog (ordered, one sitting-sized item each) or Epics, real bugs
with repro detail preserved — then confirm placement with the user
and delete the draft. Drafts must never be committed, even partially.

## Commits

Few commits, one per topic/session — never per fix. Rewriting
unpushed history (amend, squash) is expected, not exceptional.
Commit code + its docs together. No `flutter analyze` unless asked
or diagnosing; scoped `dart analyze` on touched files is the
pre-commit check. Tests run only when the code under test changed.

## Releases (user pushes tags, CI does the rest)

Release flow: `tool/release.sh [patch|minor|major]` derives the
version (no typing), bumps all pubspecs, commits, tags → review →
`git push --follow-tags` → `.gitea/workflows/release.yml`
builds and publishes the Forgejo release (manifest already written
by release.sh — predictable asset URL, no CI roundtrip). `tool/release_publish.sh` is the same
flow by hand. Workflows live in `.gitea/workflows` (this forge reads
`.gitea` first, `.github` is ignored when it exists).
Never commit secrets: tokens arrive via env (`DISCORD_WEBHOOK_URL`,
`RELEASE_TOKEN`) or Actions-provided (`GITHUB_TOKEN/GITEA_TOKEN`).
