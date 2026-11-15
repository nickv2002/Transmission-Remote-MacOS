---
name: release
description: Cut a Transmission Remote release (build, sign, notarize, changelog, tag, push, GitHub release, install). Use when the user says /release or asks to ship a release.
disable-model-invocation: true
model: haiku
---

Cut a release with the quiet target. Never run `make release` or `scripts/release.sh` directly; their output is huge.

1. Preflight: must be on `main` with a clean tree (`git status --porcelain` empty, untracked files count) and up to date with `origin/main`. If not, stop and report; don't fix it yourself.
2. Run `make release-quiet` (foreground, timeout 600000 ms; if it times out, rerun in the background and wait for the exit notification). It prints only `==>` progress lines. Full output is in `build/release.log`.
3. On failure, report the printed tail and the failing step. Don't retry blindly: the pipeline bumps the version, commits, tags, and pushes partway through, so check `git status`, `git log -3` and `git tag --points-at HEAD` before any retry and ask the user.
4. On success, report the tag and the GitHub release URL (`gh release view <tag> --json url --jq .url`).
