#!/bin/bash
# Cuts a release: bumps the version, builds + signs + notarizes, generates a
# changelog, tags, pushes, publishes a GitHub Release, and installs the build
# into /Applications. The only command the owner needs to run.
set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

branch=$(git rev-parse --abbrev-ref HEAD)
if [[ "$branch" != "main" ]]; then
  echo "error: must be on main (currently on $branch)" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is not clean" >&2
  exit 1
fi

version=$(scripts/next_version.sh)
tag="v${version}"
prev_tag=$(git describe --tags --abbrev=0 2>/dev/null || true)

echo "==> releasing ${tag} (previous tag: ${prev_tag:-none})"

# Drafted now, while the owner is still at the terminal, so any manual prompt
# happens before the long build. Stored apart from the changelog body, which
# changelog.sh rewrites. Fails open: no file means no summary on the release.
mkdir -p build
release_summary_file="build/release-summary.md"
rm -f "$release_summary_file"
scripts/release_summary.sh "$version" "$prev_tag" "$release_summary_file"

echo "==> updating project.yml version"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${version}\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${version}\"/" project.yml

scripts/build_release.sh
scripts/notarize.sh "$version"
scripts/changelog.sh "$version" "$prev_tag"
scripts/verification_notes.sh "$version"

echo "==> signing update for Sparkle"
# GitHub replaces spaces with dots in asset filenames, so use dots here to match.
zip_name="Transmission.Remote-${version}.zip"
zip_path="dist/${zip_name}"
sig_output=$(sign_update "$zip_path")
signature=$(printf '%s' "$sig_output" | grep -oE 'sparkle:edSignature="[^"]*"' \
  | sed 's/sparkle:edSignature="//;s/"//')

if [[ -z "$signature" ]]; then
  echo "error: could not extract edSignature from sign_update output" >&2
  echo "sign_update output: $sig_output" >&2
  exit 1
fi

file_size=$(/usr/bin/stat -f%z "$zip_path")
download_url="https://github.com/nickv2002/Transmission-Remote-MacOS/releases/download/v${version}/${zip_name}"

scripts/update_appcast.sh "$version" "$download_url" "$signature" "$file_size"

echo "==> committing version bump + changelog + appcast"
git add project.yml CHANGELOG.md appcast.xml
git commit -m "Release ${version}"

echo "==> tagging ${tag}"
git tag "$tag"

echo "==> pushing"
git push
git push --tags

echo "==> creating GitHub release"
release_body_file="build/release-body.md"
if [[ -s "$release_summary_file" ]]; then
  { cat "$release_summary_file"; echo; cat build/release-notes.md; } > "$release_body_file"
else
  cp build/release-notes.md "$release_body_file"
fi
gh release create "$tag" "dist/Transmission.Remote-${version}.zip" \
  --repo nickv2002/Transmission-Remote-MacOS \
  --title "${version}" --notes-file "$release_body_file"

scripts/install_local.sh

echo "==> done: ${tag}"
