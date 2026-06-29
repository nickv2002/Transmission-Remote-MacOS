#!/bin/bash
# Prepends a new release entry to appcast.xml.
# Usage: update_appcast.sh <version> <download_url> <ed_signature> <file_size_bytes>
set -euo pipefail

version="${1:?usage: update_appcast.sh <version> <download_url> <signature> <length>}"
download_url="${2:?}"
signature="${3:?}"
length="${4:?}"

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
appcast="${repo_root}/appcast.xml"
changelog="${repo_root}/CHANGELOG.md"

pub_date=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Extract bullet points for this version from CHANGELOG.md.
# "## VERSION — DATE" starts the section; next "## " heading ends it.
notes_lines=$(awk \
  "/^## ${version} /{found=1; next} /^## /{if(found)exit} found && /^- /{print}" \
  "$changelog")

if [[ -n "$notes_lines" ]]; then
  notes_html="<ul>"
  while IFS= read -r line; do
    notes_html+="<li>${line#- }</li>"
  done <<< "$notes_lines"
  notes_html+="</ul>"
else
  notes_html="<ul><li>See CHANGELOG for details.</li></ul>"
fi

new_item=$(cat <<ITEM
    <item>
      <title>${version}</title>
      <sparkle:version>${version}</sparkle:version>
      <sparkle:minimumSystemVersion>15.0</sparkle:minimumSystemVersion>
      <pubDate>${pub_date}</pubDate>
      <description><![CDATA[${notes_html}]]></description>
      <enclosure
        url="${download_url}"
        sparkle:edSignature="${signature}"
        length="${length}"
        type="application/octet-stream"/>
    </item>
ITEM
)

python3 - "$appcast" "$new_item" <<'PYEOF'
import sys
appcast_path = sys.argv[1]
new_item = sys.argv[2]
with open(appcast_path, 'r', encoding='utf-8') as f:
    content = f.read()
updated = content.replace('  </channel>', new_item + '\n  </channel>', 1)
if updated == content:
    print("error: </channel> not found in appcast.xml", file=sys.stderr)
    sys.exit(1)
with open(appcast_path, 'w', encoding='utf-8') as f:
    f.write(updated)
PYEOF

echo "==> appcast.xml updated with ${version}"
