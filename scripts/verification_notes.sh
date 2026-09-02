#!/bin/bash
# Appends a Verification section (zip SHA256 + code signature/notarization
# info) to build/release-notes.md, so every GitHub release documents how to
# confirm a downloaded build hasn't been corrupted or tampered with.
# Usage: scripts/verification_notes.sh <version>
set -euo pipefail

version="${1:?usage: verification_notes.sh <version>}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$repo_root"

app_path="build/export/Transmission Remote.app"
zip_name="Transmission.Remote-${version}.zip"
dist_zip="dist/${zip_name}"
notes_file="build/release-notes.md"

zip_sha=$(shasum -a 256 "$dist_zip" | awk '{print $1}')
codesign_info=$(codesign -dv --verbose=4 "$app_path" 2>&1)
cdhash=$(echo "$codesign_info" | grep '^CDHash=' | cut -d= -f2)
team_id=$(echo "$codesign_info" | grep '^TeamIdentifier=' | cut -d= -f2)
notarization=$(echo "$codesign_info" | grep '^Notarization Ticket=' | cut -d= -f2)

{
  echo
  echo "## Verification"
  echo
  echo "- SHA256 (\`${zip_name}\`): \`${zip_sha}\`"
  echo "- Code signature: Developer ID Application, Team ID \`${team_id}\`"
  echo "- Notarization: ${notarization}"
  echo "- CDHash: \`${cdhash}\`"
  echo
  echo "Verify after unzipping with:"
  echo '```sh'
  echo "shasum -a 256 ${zip_name}"
  echo 'codesign -dv --verbose=4 "Transmission Remote.app"'
  echo '```'
} >> "$notes_file"

echo "==> verification info appended to $notes_file"
