#!/usr/bin/env bash
# Bring up the disposable Transmission daemon fixture used by
# Tests/FixtureTransmissionTests.swift. RPC is published on host port 19091
# (NEVER 9091 — that's the owner's real production server).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DATA_DIR="$DIR/.data"
CONFIG_DIR="$DATA_DIR/config"
DOWNLOADS_DIR="$DATA_DIR/downloads"

mkdir -p "$CONFIG_DIR" "$DOWNLOADS_DIR"

# Run the container as the invoking user, not a hardcoded id, so the fixture
# is portable across machines.
export PUID="$(id -u)"
export PGID="$(id -g)"

# Only seed settings.json if the scratch config doesn't already have one, so
# re-running up.sh against an already-running (or previously-configured)
# fixture doesn't stomp its rotated/hashed state. The linuxserver image
# rewrites settings.json on daemon startup (e.g. hashing the plaintext
# password), so we copy our template in as a starting point rather than
# bind-mounting the checked-in template path directly (which would let the
# container mutate the file we keep in git).
if [ ! -f "$CONFIG_DIR/settings.json" ]; then
    echo "Seeding fixture settings.json from template..."
    cp "$DIR/settings.json.template" "$CONFIG_DIR/settings.json"
fi

docker compose -f "$DIR/docker-compose.yml" up -d

echo "Waiting for the fixture Transmission daemon on http://localhost:19091 ..."
elapsed=0
timeout=30
until curl -s -o /dev/null -w '%{http_code}' http://localhost:19091/transmission/rpc | grep -qE '^(200|401|409)$'; do
    if [ "$elapsed" -ge "$timeout" ]; then
        echo "Timed out after ${timeout}s waiting for the fixture daemon to respond." >&2
        exit 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
done

echo "Fixture Transmission daemon is up on http://localhost:19091 (took ${elapsed}s)."

# Deterministic fixture for the delete-local-data removal test: a small file
# we create ourselves (not a real peer download, since DHT/PEX/LPD are
# disabled and no peer port is published), plus a matching .torrent the
# container can add and immediately consider complete/verified.
SEED_FILE="$DOWNLOADS_DIR/fixture-delete-me.bin"
SEED_TORRENT="$CONFIG_DIR/fixture-delete-me.torrent"
if [ ! -f "$SEED_TORRENT" ]; then
    echo "Seeding deterministic delete-local-data fixture file..."
    dd if=/dev/zero of="$SEED_FILE" bs=1024 count=1024 2>/dev/null
    docker exec transgui-fixture-transmission \
        transmission-create -o /config/fixture-delete-me.torrent /downloads/fixture-delete-me.bin
fi
