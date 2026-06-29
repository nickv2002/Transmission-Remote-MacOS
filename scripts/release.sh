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

echo "==> updating project.yml version"
sed -i '' -E "s/MARKETING_VERSION: \"[^\"]*\"/MARKETING_VERSION: \"${version}\"/" project.yml
sed -i '' -E "s/CURRENT_PROJECT_VERSION: \"[^\"]*\"/CURRENT_PROJECT_VERSION: \"${version}\"/" project.yml

scripts/build_release.sh
scripts/notarize.sh "$version"
scripts/changelog.sh "$version" "$prev_tag"

echo "==> signing update for Sparkle"
zip_path="dist/Transmission Remote-${version}.zip"
sig_output=$(sign_update "$zip_path")
signature=$(printf '%s' "$sig_output" | grep -oE 'sparkle:edSignature="[^"]*"' \
  | sed 's/sparkle:edSignature="//;s/"//')

if [[ -z "$signature" ]]; then
  echo "error: could not extract edSignature from sign_update output" >&2
  echo "sign_update output: $sig_output" >&2
  exit 1
fi

file_size=$(/usr/bin/stat -f%z "$zip_path")
version_encoded=$(python3 -c "import urllib.parse, sys; print(urllib.parse.quote(sys.argv[1]))" "$version")
download_url="https://github.com/nickv2002/Transmission-Remote-MacOS/releases/download/v${version}/Transmission%20Remote-${version_encoded}.zip"

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
gh release create "$tag" "dist/Transmission Remote-${version}.zip" \
  --repo nickv2002/Transmission-Remote-MacOS \
  --title "${version}" --notes-file build/release-notes.md

scripts/install_local.sh

echo "==> done: ${tag}"
