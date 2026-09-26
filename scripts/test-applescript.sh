#!/usr/bin/env bash
# End-to-end AppleScript scripting-dictionary test: brings up the Docker
# fixture daemon, launches the Debug build pointed at an isolated preferences
# file (never the owner's real server/credentials), drives the mutating verbs
# from Resources/TransmissionRemote.sdef against the fixture torrent, and
# tears everything down — unconditionally, even on failure.
#
# What this does NOT cover: the pending-add queue, the Add-options sheet, and
# clipboard-magnet pickup are all triggered by didBecomeActiveNotification/UI
# flows that the scripted `add` command bypasses entirely. Those remain
# covered only by the manual verification recipes in CLAUDE.md, not here.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIXTURE_DIR="$DIR/fixture"
REPO_ROOT="$(cd "$DIR/.." && pwd)"
BUNDLE_ID="com.nickvance.transmission-remote-mac"
APP_PATH="${TRANSGUI_DEBUG_APP:-}"
PREFS_PATH="$FIXTURE_DIR/preferences.json"

if [ -z "$APP_PATH" ]; then
    APP_PATH="$(find "$HOME/Library/Developer/Xcode/DerivedData" -maxdepth 6 \
        -path '*/TransmissionRemote-*/Build/Products/Debug/Transmission Remote.app' \
        -print -quit 2>/dev/null)"
fi
if [ -z "$APP_PATH" ] || [ ! -d "$APP_PATH" ]; then
    echo "Could not find the Debug build. Build it first:" >&2
    echo "  xcodebuild -project $REPO_ROOT/TransmissionRemote.xcodeproj -scheme TransmissionRemote -configuration Debug build" >&2
    exit 1
fi

cleanup() {
    # Match only the Debug build under test, never the legacy "Transmission
    # Remote GUI" app or an installed /Applications copy.
    pkill -f "$APP_PATH/Contents/MacOS/Transmission Remote" 2>/dev/null
    bash "$FIXTURE_DIR/down.sh"
}
trap cleanup EXIT

bash "$FIXTURE_DIR/up.sh" || exit 1

echo "Launching isolated Debug build: $APP_PATH"
# -g: launch without activating it, so it doesn't steal focus from whatever
# app is frontmost.
open -g -n -a "$APP_PATH" --args -PreferencesPath "$PREFS_PATH"

# Wait for the app to connect to the fixture daemon before driving any verb.
connected=0
for _ in $(seq 1 30); do
    state="$(osascript -e "tell application id \"$BUNDLE_ID\" to connection state" 2>/dev/null)"
    if [ "$state" = "connected" ]; then
        connected=1
        break
    fi
    sleep 1
done
if [ "$connected" -ne 1 ]; then
    echo "App never reached 'connected' state against the fixture daemon." >&2
    exit 1
fi

# Defense in depth: even with an isolated preferences file, refuse to run any
# mutating verb unless the connected server is unmistakably the fixture.
current_server="$(osascript -e "tell application id \"$BUNDLE_ID\" to current server" 2>/dev/null)"
if [ "$current_server" != "AppleScriptFixture" ]; then
    echo "Refusing to proceed: connected server is '$current_server', not the fixture." >&2
    exit 1
fi

fail=0
assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" != "$actual" ]; then
        echo "FAIL: $desc (expected '$expected', got '$actual')" >&2
        fail=1
    else
        echo "ok: $desc"
    fi
}

run_osa() {
    osascript "$@" 2>&1
}

assert_no_error() {
    local desc="$1" output="$2"
    if [[ "$output" == *"execution error"* ]]; then
        echo "FAIL: $desc: $output" >&2
        fail=1
        return 1
    fi
    return 0
}

# Add the deterministic delete-local-data fixture torrent, then capture its
# stable id (info hash) — `selection` is a plain list *property*, not an
# element, so Cocoa Scripting doesn't support ordinal/filter access into it
# (`first item of selection` fails with "Can't make ... into type
# specifier"); every read-back below re-queries `torrents whose id is ...`
# instead, which supports filtering because `torrents` is a declared element.
added_name="$(run_osa -e "tell application id \"$BUNDLE_ID\"" \
    -e "  add \"$FIXTURE_DIR/.data/config/fixture-delete-me.torrent\" paused true" \
    -e "end tell")"
assert_eq "add fixture torrent" "fixture-delete-me.bin" "$added_name"

torrent_id="$(osascript -e "tell application id \"$BUNDLE_ID\" to id of first item of (torrents whose name is \"fixture-delete-me.bin\")" 2>&1)"
assert_no_error "look up fixture torrent id" "$torrent_id"

# Runs the given AppleScript command lines with `selection` set to the
# fixture torrent (by id, so a `rename` earlier in the run doesn't break the
# lookup) — used to drive a verb, not to read its result back.
run_on_target() {
    run_osa -e "tell application id \"$BUNDLE_ID\"" \
        -e "  set target to (first item of (torrents whose id is \"$torrent_id\"))" \
        -e "  set selection to {target}" \
        -e "$1" \
        -e "end tell"
}

read_property() {
    # Reads a single property back via a fresh `torrents whose id is ...`
    # query, after any in-flight verb/poll has settled.
    osascript -e "tell application id \"$BUNDLE_ID\" to $1 of first item of (torrents whose id is \"$torrent_id\")" 2>&1
}

run_on_target "  start" >/dev/null
sleep 1
status="$(read_property "status")"
if assert_no_error "start" "$status"; then
    assert_eq "start -> not stopped" "true" "$([ "$status" != "stopped" ] && echo true || echo false)"
fi

run_on_target "  stop" >/dev/null
sleep 1
status="$(read_property "status")"
if assert_no_error "stop" "$status"; then
    assert_eq "stop -> stopped" "stopped" "$status"
fi

run_on_target "  force start" >/dev/null
sleep 1
status="$(read_property "status")"
if assert_no_error "force start" "$status"; then
    assert_eq "force start -> not stopped" "true" "$([ "$status" != "stopped" ] && echo true || echo false)"
fi

run_on_target "  verify" >/dev/null
echo "ok: verify (no error)"

run_on_target "  reannounce" >/dev/null
echo "ok: reannounce (no error)"

run_on_target "  set priority to \"high\"" >/dev/null
sleep 1
prio="$(read_property "priority")"
assert_eq "set priority to high" "high" "$prio"

run_on_target "  rename to \"fixture-renamed\"" >/dev/null
sleep 1
new_name="$(read_property "name")"
assert_eq "rename" "fixture-renamed" "$new_name"

qerr="$(run_on_target "  queue move to \"down\"")"
[ -z "$qerr" ] && echo "ok: queue move" || { echo "FAIL: queue move: $qerr" >&2; fail=1; }

lerr="$(run_on_target "  set location to \"/downloads\"")"
[ -z "$lerr" ] && echo "ok: set location" || { echo "FAIL: set location: $lerr" >&2; fail=1; }

run_on_target "  stop" >/dev/null
sleep 1
run_on_target "  remove deleting data true" >/dev/null
remaining="$(osascript -e "tell application id \"$BUNDLE_ID\" to count of (torrents whose id is \"$torrent_id\")" 2>/dev/null)"
assert_eq "remove deleting data" "0" "$remaining"

if [ "$fail" -ne 0 ]; then
    echo "One or more AppleScript assertions failed." >&2
    exit 1
fi
echo "All AppleScript scripting-dictionary assertions passed."
