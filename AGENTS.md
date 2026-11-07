# AGENTS.md

Repo-specific rules. Global interaction rules live in the user-level
AGENTS.md. Source of truth: the code, then the docs below.

## Docs

- [README.md](README.md): the front door (what, download, getting started).
  [docs/GUIDE.md](docs/GUIDE.md): the user manual (every feature, setting,
  shortcut, the dedicated server). [docs/HOW-IT-WORKS.md](docs/HOW-IT-WORKS.md):
  plain tour. [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md): packages, sync,
  media, updater, decisions. [docs/PROTOCOL.md](docs/PROTOCOL.md): wire format.
  [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md): build, test, release, gotchas.
  [docs/ROADMAP.md](docs/ROADMAP.md): backlog and epics.
- Docs describe current truth only: no dates, no "fixed" notes, no phase
  logs (git has history, plans go in ROADMAP).
- Each fact lives in exactly one file; others link to it.
- Code and its docs change in the same commit. A wire change also bumps
  `RelayConstants.protoVersion` and edits PROTOCOL.md.
- Say "server" (there is only one), never "room", in UI, code and docs.

## Wishlist drafts

The user drops raw idea/bug lists as drafts (gitignored, never committed:
`docs/Wishlist.md`, `docs/drafts/`). On sight, translate each entry into its
place in `docs/ROADMAP.md` (ordered backlog item or epic; keep repro detail
for real bugs), confirm placement with the user, then delete the draft.
Drafts must never be committed, even partially.

## Commits

Few commits, one per topic/session, never per fix. Rewriting unpushed
history (amend, squash) is normal. Commit code + its docs together. No
`flutter analyze` unless asked or diagnosing; scoped `dart analyze` on touched
files is the pre-commit check. Run tests only when the code under test changed.
A user-facing change adds a plain-words line to `CHANGELOG.md`'s
"Unreleased" in the same commit.

## Settings and new users

Keep settings tidy: anything new goes straight to its one home in the
settings layout (common rows first, the rest under "More"; the player panel
only for what you adjust while watching, with the same widget). Prefer a
good default over a new switch. Check every change against a first-time or
one-time user: someone who clicks an invite link and watches must not need
to touch anything new. Details: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md)
("Where a new setting goes").

## Releases

`tool/release.sh [patch|minor|major]`, `git push github --follow-tags`,
wait for GitHub's `release` run, then `tool/sign_release.sh X.Y.Z --push`
(signs the update file; also bridges it to the Gitea for 1.4.x apps).
Details: [docs/DEVELOPMENT.md](docs/DEVELOPMENT.md). Never commit
secrets: tokens come from env (`DISCORD_WEBHOOK_URL`, `RELEASE_TOKEN`) or
Actions (`GITHUB_TOKEN`/`GITEA_TOKEN`).
