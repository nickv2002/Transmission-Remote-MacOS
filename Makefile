.PHONY: help release build notarize install test generate dev run clean fixture-up fixture-down fixture-test

VERSION ?= $(shell scripts/next_version.sh)

# Default target: show available commands
help:
	@echo "Transmission Remote — available make targets:"
	@echo ""
	@echo "  Development"
	@echo "    dev        Debug build, then open the app"
	@echo "    run        Open the most recent debug build (no rebuild)"
	@echo "    test       Run unit tests"
	@echo "    generate   Regenerate the Xcode project from project.yml"
	@echo "    clean      Remove DerivedData for this project"
	@echo "    fixture-up    Bring up the disposable Docker Transmission fixture (port 19091)"
	@echo "    fixture-down  Tear down the fixture and wipe its scratch data"
	@echo "    fixture-test  Up, run FixtureTransmissionTests, then down (always, even on failure)"
	@echo ""
	@echo "  Release pipeline"
	@echo "    release    Full pipeline: build → sign → notarize → changelog → tag → push → GitHub release → install"
	@echo "    build      Archive and export a Developer-ID-signed Release build"
	@echo "    notarize   Notarize, staple, and zip (pass VERSION=x.y.z to override)"
	@echo "    install    Copy the exported .app to /Applications"
	@echo ""
	@echo "  Override defaults with: make <target> VERSION=2026.06.23.1"

# Full release pipeline: build → sign → notarize → changelog → tag → push → GitHub release → install
release:
	scripts/release.sh

# Archive and export a Developer-ID-signed Release build
build:
	scripts/build_release.sh

# Notarize, staple, and zip (requires VERSION, e.g. make notarize VERSION=2026.06.23.1)
notarize:
	scripts/notarize.sh "$(VERSION)"

# Install the exported .app to /Applications
install:
	scripts/install_local.sh

# Run unit tests
test:
	xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
		-configuration Debug test

# Regenerate the Xcode project from project.yml
generate:
	xcodegen generate

# Directory the currently-configured Debug build actually lands in (avoids
# opening stale copies when multiple DerivedData/TransmissionRemote-* dirs exist)
BUILT_PRODUCTS_DIR = $(shell xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
	-configuration Debug -showBuildSettings 2>/dev/null | \
	awk -F'= ' '/ BUILT_PRODUCTS_DIR =/ { print $$2 }')

# Debug build, then open the app
dev: generate
	xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
		-configuration Debug build
	open "$(BUILT_PRODUCTS_DIR)/Transmission Remote.app"

# Open the most recent debug build without rebuilding
run:
	open "$(BUILT_PRODUCTS_DIR)/Transmission Remote.app"

# Remove DerivedData for this project
clean:
	rm -rf ~/Library/Developer/Xcode/DerivedData/TransmissionRemote-*

# Bring up the disposable Docker Transmission fixture used by FixtureTransmissionTests
fixture-up:
	scripts/fixture/up.sh

# Tear down the fixture and wipe its scratch data
fixture-down:
	scripts/fixture/down.sh

# Up, run FixtureTransmissionTests, then down — unconditionally, even on failure
fixture-test:
	scripts/fixture/run-tests.sh
