# Server Options

Open **Server Options** from the toolbar button after Speed Limits, or **Server → Server Options…** (⌥⌘,), for the selected server. The native AppKit panel exposes 50 writable session fields in Transmission 4.1.4, including the deprecated µTP fallback. Blocklist management is deliberately excluded because RPC cannot remove downloaded rules. Older servers keep supported controls; missing capabilities are disabled.

| Tab | Controls |
| --- | --- |
| Download | Automatic start/sequential defaults, watch-folder .torrent disposal, default/incomplete folders, `.part` naming, seeding ratio and idle limits |
| Network | Peer port/randomisation, forwarding, encryption, peer limits/discovery, ordered TCP/µTP transports, protocol-specific port tests |
| Bandwidth | Regular and alternative limits, turtle mode, schedule, bandwidth group management |
| Queue | Download/seeding queue limits and stalled-torrent handling |
| Advanced | Default trackers and tiers, cache size, peer request queue, RPC brute-force protection, three script-hook enable/path pairs |

Paths refer to the server's filesystem. Changing the download folder does not move torrents. Script paths refer to existing server files; the app neither uploads nor executes scripts. Default trackers use one URL per line and blank lines between tiers. Schedules follow the server's time zone and support overnight intervals. Speeds use decimal kB/s; cache uses MiB.

The per-add Start choice overrides the server's automatic-start default. Server watch-folder disposal is distinct from this Mac's local .torrent removal setting. Modern transport preferences replace the deprecated µTP checkbox when available; the two setters are never sent together by the editor. µTP itself remains supported, with µTP then TCP the default preference in Transmission 4.1.4.

## Editing and saving

- A native segmented selector sits on the border of a boxed settings area and changes sections without starting text editing. Pointer selection clears the focus halo; keyboard navigation keeps its native focus indicator. Fields support click/Tab access and validation-error focus. Clicking blank form space dismisses text focus while retaining the unsaved draft; the tracker editor has an inset around its text.
- Opening, typing, changing tabs and testing ports do not save settings. **Apply** sends only changed, active settings. Disabled companion fields retain their drafts and are omitted from the write.
- Each window retains its original server connection. Switching servers in the main window never redirects an existing editor's writes.
- Apply validates the draft, checks current values for conflicts, sends a sparse `session-set`, then verifies readback. Unrelated changes are preserved. Already-applied edits are not resent.
- An uncertain response, rejected value or failed readback requires **Reload** before another save. RPC has no atomic compare-and-swap; edits by another client between preflight and write remain possible.
- Reload, Close and Quit protect unsaved drafts. Failed loads preserve the existing draft. Controls are disabled during operations.
- Unknown future encryption/transport values remain unchanged until explicitly edited. Capabilities use returned fields and RPC version metadata, not the daemon's product version string.

## Groups and diagnostics

The **Server Options** toolbar button follows Speed Limits; **Remove** still requires confirmation.

**Manage Bandwidth Groups…** opens a server-bound editor for named groups, download/upload limits and whether they honor session limits. **Apply Group** is a separate save boundary with conflict checks, sparse writes and verified readback. Group creation is explicit; Transmission has no group rename/delete RPC. Assign or clear a group for selected torrents using **Torrent → Bandwidth Group…** or the torrent context menu. Assignments retain the original connection and torrent hashes, detect changed/removed targets and verify the result.

Port tests check the server's currently applied incoming port, regardless of unsaved edits. Automatic tests retain compatibility with older servers; explicit IPv4/IPv6 requires RPC 6.0 / Transmission 4.1 or newer. Missing results and request errors are never reported as a closed port. RPC failures are read before success arguments, preserving the server’s error even when its arguments object is empty.

A closed incoming port means the daemon’s external test could not reach it. It does not mean this app cannot connect, or prove VPN failure. RPC cannot determine VPN state or forwarding at a VPN provider.

Settings without session setters—such as watch-directory setup, preallocation, umask, HTTP proxy and RPC listening/credentials—still require server-side configuration. Protocol coverage is based on the [4.1.4 implementation](https://github.com/transmission/transmission/blob/4.1.4/libtransmission/rpcimpl.cc) and [RPC specification](https://github.com/transmission/transmission/blob/4.1.4/docs/rpc-spec.md).

## Testing

```sh
# Standalone model, lifecycle, RPC and native AppKit suites through CLT:
bash scripts/test-server-options.sh

# Complete project suite with full Xcode and XcodeGen:
xcodegen generate
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug test
```

The standalone suites cover settings validation, exact wire names, sparse writes, missing capabilities, transport fallback, multiline trackers, dependencies, conflicts, uncertain writes, group operations/assignments, port protocols, accessibility and light/dark minimum-size layouts. Full Xcode remains necessary to execute the original XCTest target and normal packaging route.

Native arrow/Space navigation requires a foreground application. That check runs in the standalone helper and is explicitly skipped in the background-only Xcode test host; the rest of the suites run in both.

The helper supports Command Line Tools and full Xcode, hosts AppKit on its main-thread event loop, and requires an explicit completion marker so an early application exit cannot be mistaken for passing tests. Its output is saved in `build/server-options-tests/results.log`.
