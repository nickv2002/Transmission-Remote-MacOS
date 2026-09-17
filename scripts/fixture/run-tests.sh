#!/usr/bin/env bash
# Bring up the fixture, run FixtureTransmissionTests against it, and tear the
# fixture down again — unconditionally, even if a test assertion fails. This
# is the safe, one-shot way to exercise the fixture; `up.sh`/`down.sh` are
# also available separately for interactive debugging.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$DIR/../.." && pwd)"

trap 'bash "$DIR/down.sh"' EXIT

bash "$DIR/up.sh" || exit 1

RUN_FIXTURE_TRANSMISSION_TESTS=1 TEST_RUNNER_RUN_FIXTURE_TRANSMISSION_TESTS=1 \
    xcodebuild -project "$REPO_ROOT/TransmissionRemote.xcodeproj" \
    -scheme TransmissionRemote -configuration Debug test \
    -only-testing:TransmissionRemoteTests/FixtureTransmissionTests
status=$?

exit $status
