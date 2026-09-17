#!/usr/bin/env bash
# Tear down the disposable Transmission daemon fixture and wipe its scratch
# data. Safe to run even if the fixture was never started.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

docker compose -f "$DIR/docker-compose.yml" down -v
rm -rf "$DIR/.data"

echo "Fixture torn down and scratch data removed."
