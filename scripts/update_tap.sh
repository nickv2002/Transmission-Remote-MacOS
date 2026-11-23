#!/bin/bash
# Renders the Homebrew cask for a release and commits it to the shared tap, nickv2002/homebrew-tap.
# Reads the SHA-256 of the release zip in dist/.
#
# Usage: scripts/update_tap.sh <version> [--push]
#
# The tap checkout is $TAP_DIR (default: ../homebrew-tap next to this repo); it is cloned there if missing.
# Without --push the commit stays local, so the result can be checked with `brew style` first.
set -euo pipefail

version="${1:?usage: update_tap.sh <version> [--push]}"
push=0
[[ "${2:-}" == "--push" ]] && push=1

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"
tap_dir="${TAP_DIR:-$repo_root/../homebrew-tap}"
tap_slug="nickv2002/homebrew-tap"
dist="${DIST_DIR:-dist}"

# Same dotted name release.sh uploads (GitHub turns the space into a dot).
zip_path="$dist/Transmission.Remote-${version}.zip"
[[ -f "$zip_path" ]] || { echo "error: release asset missing: $zip_path" >&2; exit 1; }
app_sha=$(shasum -a 256 "$zip_path" | cut -d' ' -f1)

if [[ ! -d "$tap_dir/.git" ]]; then
  echo "==> cloning ${tap_slug} into ${tap_dir}"
  gh repo clone "$tap_slug" "$tap_dir"
fi
if [[ -n "$(git -C "$tap_dir" status --porcelain)" ]]; then
  echo "error: ${tap_dir} has uncommitted changes" >&2
  exit 1
fi
if git -C "$tap_dir" ls-remote --exit-code origin main >/dev/null 2>&1; then
  git -C "$tap_dir" pull --ff-only --quiet
fi

cask="$tap_dir/Casks/transmission-remote.rb"
mkdir -p "$tap_dir/Casks"
sed -e "s/@VERSION@/${version}/g" -e "s/@SHA256_APP@/${app_sha}/g" \
  packaging/homebrew/transmission-remote.rb > "$cask"
if grep -q '@[A-Z0-9_]*@' "$cask"; then echo "error: unfilled placeholder in $cask" >&2; exit 1; fi

if command -v brew >/dev/null 2>&1; then
  brew style "$cask"
fi

git -C "$tap_dir" add Casks/transmission-remote.rb
if git -C "$tap_dir" diff --cached --quiet; then
  echo "==> tap already at ${version}"
else
  git -C "$tap_dir" commit --quiet -m "transmission-remote ${version}"
  echo "==> tap commit: $(git -C "$tap_dir" log --oneline -1)"
fi
if [[ $push -eq 1 ]]; then
  git -C "$tap_dir" push --quiet origin HEAD:main
  echo "==> pushed ${tap_slug}"
fi
