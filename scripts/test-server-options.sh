#!/bin/bash
# Run the same Swift Testing suites as the Xcode target using Command Line Tools.
set -euo pipefail
cd "$(dirname "$0")/.."
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    test_libs="$developer_dir/Library/Developer/usr/lib"
    plugins="$developer_dir/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
else
    frameworks="$developer_dir/Platforms/MacOSX.platform/Developer/Library/Frameworks"
    test_libs="$developer_dir/Platforms/MacOSX.platform/Developer/usr/lib"
    plugin_dir="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins"
    plugins="$plugin_dir/testing/libTestingMacros.dylib"
    # Older toolchains place the library directly in plugins/.
    [[ -f "$plugins" ]] || plugins="$plugin_dir/libTestingMacros.dylib"
fi
[[ -f "$plugins" ]] || { echo "Swift Testing macros were not found in the selected developer tools." >&2; exit 1; }
mkdir -p build/server-options-tests
cat > build/server-options-tests/Runner.swift <<'SWIFT'
import AppKit
import Testing
@main @MainActor struct ServerOptionsTestRunner {
    static func main() {
        // AppKit controls need a main-thread event loop, including while an
        // asynchronous test is suspended. A bare async main is not an app host.
        let app = NSApplication.shared
        Task { @MainActor in
            let result: CInt = await Testing.__swiftPMEntryPoint()
            FileHandle.standardOutput.write(Data("SERVER_OPTIONS_TESTS_COMPLETED=\(result)\n".utf8))
            exit(result)
        }
        app.run()
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 -strict-concurrency=complete -warnings-as-errors \
    -module-cache-path build/module-cache \
    -F "$frameworks" -load-plugin-library "$plugins" \
    -Xlinker -rpath -Xlinker "$frameworks" -Xlinker -rpath -Xlinker "$test_libs" \
    Sources/ServerOptions.swift Sources/ServerOptionsFeatures.swift Sources/ServerOptionsWindowController.swift Sources/BandwidthGroupsWindowController.swift \
    Sources/AppConfig.swift Sources/PathMapping.swift Sources/SMBMountResolver.swift Sources/SpeedPresets.swift Sources/PopUpEnum.swift \
    Sources/Models.swift Sources/Formatters.swift Sources/TransmissionClient.swift \
    Tests/ServerOptionsTests.swift Tests/ServerOptionsWindowTests.swift Tests/ServerOptionsRPCTests.swift Tests/ServerOptionsFeatureTests.swift \
    build/server-options-tests/Runner.swift -o build/server-options-tests/run
# Never mistake an AppKit-initiated early exit for a completed test run.
build/server-options-tests/run "$@" 2>&1 | tee build/server-options-tests/results.log
grep -qx 'SERVER_OPTIONS_TESTS_COMPLETED=0' build/server-options-tests/results.log
