#!/bin/bash
# Writes a one-paragraph human summary of a release to <out-file>, to be placed
# at the top of the GitHub release body and the Sparkle appcast description.
#
# Usage: scripts/release_summary.sh <version> <prev-tag> <out-file>
#
# Tries the owner's `cldp` (personal Claude profile, print mode) to draft the
# summary from the commits since <prev-tag>. Fails open: if cldp is missing or
# errors, it prompts on a TTY for a summary (blank line = skip). Without a TTY
# it skips. A skip leaves <out-file> absent and exits 0.
#
# Env overrides:
#   RELEASE_SUMMARY_SKIP=1   skip the cldp attempt (go straight to the prompt)
#   RELEASE_SUMMARY_ARGS     args passed to cldp (default: -p --model haiku)
set -euo pipefail

version="${1:?usage: release_summary.sh <version> <prev-tag> <out-file>}"
prev_tag="${2:-}"
out_file="${3:?usage: release_summary.sh <version> <prev-tag> <out-file>}"

cldp_args="${RELEASE_SUMMARY_ARGS:--p --model claude-haiku-5-5}"
cldp_timeout=180

end_ref="${RELEASE_SUMMARY_END:-HEAD}"
range="$end_ref"
if [[ -n "$prev_tag" ]]; then
  range="${prev_tag}..${end_ref}"
fi

commits=$(git log "$range" --reverse --oneline --no-merges --pretty=format:'- %s' || true)

prompt=$(cat <<EOF
Write a concise, human-readable summary of release ${version} of a macOS Transmission remote app, for the top of its GitHub release page. Base it on these commit subjects:

${commits}

Output only a JSON object with one key, "summary", whose value is a single sentence of at most 25 words (plain text, no markdown, no line breaks). Describe what users will notice, not the commit mechanics. Output nothing outside the JSON object.
EOF
)

# Ask cldp via a login interactive shell, since the cldp alias lives in
# ~/.bash_profile. Markers isolate the reply from the profile-switch chatter
# and shell-integration escape codes that also land on stdout.
try_cldp() {
  local raw
  raw=$(printf '%s' "$prompt" | perl -e 'alarm shift; exec @ARGV' "$cldp_timeout" \
    bash -lic "printf '\n<<<BEGIN>>>\n'; cldp ${cldp_args}; rc=\$?; printf '\n<<<END rc=%s>>>\n' \"\$rc\"" \
    2>/dev/null || true)
  local body rc
  # The alias prints its own profile-switch notices after BEGIN; drop them.
  body=$(printf '%s\n' "$raw" | sed -n '/<<<BEGIN>>>/,/<<<END/p' | sed '1d;$d' \
    | grep -v -e '^Switched to profile ' -e '^All claude commands in this shell' || true)
  rc=$(printf '%s\n' "$raw" | sed -n 's/.*<<<END rc=\([0-9]*\)>>>.*/\1/p')
  if [[ "$rc" != "0" ]]; then
    return 1
  fi
  # The reply is a JSON object: {"summary": "..."}. Take the "summary" string
  # from the first JSON object in the body; anything unparseable fails open.
  local summary
  summary=$(printf '%s' "$body" | python3 -I -c '
import json, re, sys
text = sys.stdin.read()
match = re.search(r"\{.*\}", text, re.S)
if not match:
    sys.exit(1)
value = json.loads(match.group(0)).get("summary", "")
if not isinstance(value, str) or not value.strip():
    sys.exit(1)
print(" ".join(value.split()))
') || return 1
  [[ -n "$summary" ]] || return 1
  printf '%s\n' "$summary"
}

summary=""
source_label=""
if [[ "${RELEASE_SUMMARY_SKIP:-0}" != "1" ]]; then
  if summary=$(try_cldp); then
    source_label="cldp"
  else
    summary=""
  fi
fi

if [[ -z "$summary" ]]; then
  if [[ -t 0 ]]; then
    echo "==> cldp summary unavailable; enter a one-line release summary (blank to skip):"
    read -r -p "> " summary || summary=""
    if [[ -n "$summary" ]]; then
      source_label="manual"
    fi
  fi
fi

if [[ -z "$summary" ]]; then
  echo "==> no release summary (skipped)"
  exit 0
fi

printf '%s\n' "$summary" > "$out_file"
echo "==> release summary written to $out_file (${source_label})"
