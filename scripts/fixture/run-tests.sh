#!/usr/bin/env bash
# Bring up the fixture, run every fixture-backed test class against it, and tear
# the fixture down again — unconditionally, even if a test assertion fails. This
# is the one-command fixture gate; `up.sh`/`down.sh` are also available
# separately for interactive debugging.
#
# Fixture mode is strict: a skipped test is a failure. The env var being set
# means the caller asked for these tests to run, so a skip (missing daemon,
# missing setup file, anything) must not look like a pass.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"
LOG="$(mktemp -t fixture-tests.XXXXXX)"

trap 'bash "$DIR/down.sh"; rm -f "$LOG"' EXIT

bash "$DIR/up.sh" || exit 1

RUN_FIXTURE_TRANSMISSION_TESTS=1 TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 \
    xcodebuild -project "$REPO_ROOT/TransmissionRemote.xcodeproj" \
    -scheme TransmissionRemote -configuration Debug test \
    -only-testing:TransmissionRemoteTests/FixtureTransmissionTests \
    -only-testing:TransmissionRemoteTests/FixtureConcurrencyTests \
    -only-testing:TransmissionRemoteTests/FixtureFailoverTests 2>&1 | tee "$LOG"
status=${PIPESTATUS[0]}

if grep -q "Test skipped" "$LOG"; then
    echo "run-tests: fixture mode treats skips as failures:" >&2
    grep "Test skipped" "$LOG" | sed 's/^ */  /' | sort -u >&2
    status=1
fi
if ! grep -q "\*\* TEST SUCCEEDED \*\*" "$LOG"; then
    echo "run-tests: no successful test run was reported." >&2
    status=1
fi

exit $status
