---
name: release-transgui
description: Cut a Transmission Remote release (check in and merge pending work to main, build, sign, notarize, changelog, tag, push, GitHub release, install). Use when the user says /release-transgui or asks to ship a release.
disable-model-invocation: true
model: haiku
---

Cut a release with the quiet target. Never run `make release` or `scripts/release.sh` directly; their output is huge.

1. **Get pending work onto `main`.** The changelog is built from commit subjects since the last tag, so every subject must read as a user-facing changelog line (e.g. `Add Torrent ▸ Properties… window (⌘I)`), never `WIP`/`fix`/`Merge branch …`.
   - **Look before committing.** Review `git status --porcelain` and `git diff --stat`. Commit only files that belong to the work. Stray or unexplained files (scratch output, logs, secrets, `preferences.json`, anything outside `Sources/ Tests/ Resources/ docs/ scripts/ project.yml AGENTS.md README.md .claude/`): stop and ask.
   - **Verify the tree first.** If there are uncommitted source changes, run `make test` (timeout 600000 ms). The build must be zero-warning and the tests must pass. On failure, stop and report; don't commit.
   - **Dirty tree on a feature branch:** commit there with one changelog-ready subject. Then `git checkout main && git pull --ff-only`, `git rebase main <branch>`, `git checkout main && git merge --ff-only <branch>`, `git branch -d <branch>`. Fast-forward only, so no merge commit lands in the changelog.
   - **Dirty tree on `main`:** commit directly.
   - **Clean feature branch with commits not on `main`:** same rebase + fast-forward merge as above.
   - **Stop and report** on rebase conflicts, a non-fast-forward `main`, or a branch already pushed with an open PR (ask whether to merge the PR instead).
   - **Never force-push.** Don't push here; the release pushes `main`.
2. **Preflight.** You must now be on `main` with a clean tree (`git status --porcelain` empty, untracked files count) and not behind `origin/main` (`git fetch origin main`, then `git rev-list --count HEAD..origin/main` is `0`). Local commits ahead are fine. If any check fails, stop and report.
3. **Release.** Run `make release-quiet` (foreground, timeout 600000 ms; if it times out, rerun in the background and wait for the exit notification). It prints only `==>` progress lines. Full output is in `build/release.log`.
4. **On failure,** report the printed tail and the failing step. Don't retry blindly: the pipeline bumps the version, commits, tags and pushes partway through. Check `git status`, `git log -3` and `git tag --points-at HEAD` before any retry, and ask the user.
5. **On success,** report the commits that were merged, the tag, and the GitHub release URL (`gh release view <tag> --repo nickv2002/Transmission-Remote-MacOS --json url --jq .url`; without `--repo` gh may answer "release not found").
6. **Link the release on shipped PRs.** For each PR in this release (a `(#N)` suffix on a commit subject in `git log --format=%s <previous tag>..<tag>`), comment on it: `gh pr comment N --repo nickv2002/Transmission-Remote-MacOS --body "Thanks! This shipped in [<tag>](<release URL>)."`. Mention the commented PRs in the report, as markdown links.
