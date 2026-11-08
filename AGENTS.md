# Native macOS Transmission Remote

A native macOS app (Swift + AppKit) that talks to Transmission daemons over JSON-RPC. It's a from-scratch rewrite of the legacy Free Pascal / Lazarus app, preserved on the `legacy-pascal` branch (`rpc.pas` is the authoritative source for the RPC protocol; `main.pas`/`filtering.pas` for legacy behavior). Scope is a deliberately minimal app for the owner's daily use, not feature parity. Label filtering and the Labels column/group were intentionally dropped.

History lives in `CHANGELOG.md`, git, and `.context/` (numbered plans `01`–`08`). Feature docs: `docs/SERVER_SETTINGS.md`, `docs/CLOUDFLARE_ACCESS.md`.

## What exists

Verified against the owner's real server (~1040 torrents, Transmission 4.1.2):

- **List/actions:** live torrent list with state-coloured progress bar, sortable/hideable/reorderable columns (Size, Added, Tracker, Error, Ratio Limit hidden by default), start/stop/force-start/rename/move/verify/queue-move/priority/remove, fuzzy/exact toolbar search, sidebar filter groups (Status / Trackers / Folders, reorderable, live counts), status bar with per-status counts, free space and a rate sparkline.
- **Detail pane tabs:** Info (incl. piece map and speed sparkline), Files (tri-state wanted tree, priorities; folder actions apply to every file beneath), Trackers (read-only), Peers. Tabs fetch on demand, only while visible and exactly one torrent is selected, and preserve selection/focus across polls. Sort logic lives in Foundation-only types in `Models.swift` (`PeerSortKey`, `TrackerSortKey`, `TorrentPieces`) and `TorrentFileTree.swift`.
- **Add torrents:** toolbar pull-down, ⌘O / ⌘L, drag-and-drop, Dock/Open-With, `magnet:` URL scheme, optional clipboard pickup, duplicate detection.
- **Multi-server:** Server menu + toolbar dropdown, ⌘1–⌘0 switching, speed-limits pull-down (server-side `session-set`; turtle mode = the "slow" profile; only the preset lists are client-side per server), multi-host failover, remote→local path mappings, custom headers, Cloudflare Access sign-in.
- **Persistence:** window frame, splits, column state, sort, selected server; everything else in the preferences store below.
- Remove's data-deleting path and per-file wanted/priority writes were intentionally never fired against the owner's prod server.

## Layout (`Sources/`)

Main window:
- `main.swift` — explicit AppKit entry point (gotcha 1). `AppDelegate.swift` — lifecycle, menus, Dock/Finder icon handling. `ServerMenuSync.swift` — Server menu in-place update + ⌘1–⌘0 mapping.
- `MainWindowController.swift` — window, table, detail pane, status bar, sort/filter (`displayed` is the filtered view of `torrents`). Extensions: `+Actions` (toolbar, context menu, actions, search item), `+Speed` (`SpeedMenuModel`), `+Files`, `+Trackers`, `+Peers`, `+Pieces`, `+Add` (add flows, `pendingAdds`, `DropView`), `+Access` (once-per-episode sign-in prompt).
- `SidebarController.swift`, `Filtering.swift` (`StatusFilter`/`SidebarFilter`), `PieceMapView.swift`, `ProgressCellView.swift`, `SpeedGraphView.swift`, `Formatters.swift`, `Models.swift`.
- `ToolbarLayoutAppKit.swift` — `NSWindow.apply(toolbarLayout:)` and the display-mode observer. `PopUpEnum.swift` — use it for every enum-backed `NSPopUpButton`.

Networking:
- `TransmissionClient.swift` — `actor` over `URLSession`; Basic auth, the 409 / `X-Transmission-Session-Id` retry, typed RPC wrappers, `RequestHeaderSource`s, redirects refused (`RedirectRefuser`).
- `RefreshController.swift` — `@MainActor` poll loop (~4s, configurable): connection state, `session-get` each tick, pause-on-minimize, download dir + free space, `RateHistory`.
- `HostCandidates.swift` — host-list parsing + `ConnectionResolver`. `ConnectionDiagnostics.swift` — Test Connection error→message mapping. `ServerIdentity.swift` — stable ids, `SelectedServerStore`, `LastGoodHostStore`.
- `TorrentLink.swift` (magnet/URL/info-hash recognition), `PathMapping.swift`, `DefaultHandlers.swift` (Launch Services default-app status + Make Default).

Settings (one window; see *Settings window*):
- `SettingsWindowController.swift` (shell), `SettingsGeneralPane`, `SettingsConnectionPane`, `ServerSettingsPane` (server-side tabs), `BandwidthGroupsWindowController`, `CustomHeadersTable`.
- Foundation-only models: `SettingsEditor.swift` (per-server dirty/apply/revert), `ServerOptions.swift` (session-settings schema, `ServerSettingsScope`), `AppConfig.swift` (`PreferencesStore`, `TestIsolation`).

Custom headers / Cloudflare Access: `CustomHeaders.swift`, `HeaderSecretStore.swift`, `CloudflareAccess.swift`, `AccessOAuth.swift`, `AccessLoopback.swift`, `AccessSignIn.swift`, `AccessSessionStore.swift`, `AccessHeaderSource.swift`, `AccessSignInController.swift`, `Scripting.swift` (AppleScript).

**Dock/Finder icon** (`DockTile/`, its own target): macOS 26+ masks freeform icons into a gray squircle. `AppDelegate` sets `NSApp.applicationIconImage` from `Resources/DockIcon.png` (a plain PNG, not the asset catalog, whose rendition is already jailed); the `TransmissionRemoteDockTile.docktileplugin` draws the same PNG when the app isn't running; Finder gets a custom bundle icon via `AppDelegate.applyFinderIconIfNeeded` (`NSWorkspace.setIcon` with `AppIcon.icns`, which adds an `Icon\r` file at the bundle root).
- Always on. Re-applied on any launch where it's missing (Sparkle updates replace the bundle). Release-only: in Debug the root files break Xcode's incremental codesign.
- Use the `.icns`, not the 1024px PNG (the PNG makes IconServices file an `ExcUserFault`). `codesign --verify --deep` passes; only `--strict` objects.
- Launchpad and Spotlight stay jailed. The Dock loads plug-ins at launch/tile add, so `killall Dock` to pick up changes. Changing icon assets also needs `lsregister -f` and emptying `$DARWIN_USER_CACHE_DIR/com.apple.iconservices`.

The project is generated by **XcodeGen** from `project.yml`; the `.xcodeproj` and `build/` are gitignored.

## Build & run

```sh
xcodegen generate          # only after editing project.yml / adding files
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TransmissionRemote-*/Build/Products/Debug/"Transmission Remote.app"
```

Keep the build **clean with zero warnings** (Swift 6 strict concurrency `complete`).

**Local Debug signing (optional).** Debug is ad-hoc signed, so every rebuild is a new code identity and the Keychain re-asks for header values. To sign with your own certificate, create an untracked `Local.xcconfig` at the repo root (gitignored):

```
CODE_SIGN_STYLE[config=Debug] = Manual
CODE_SIGN_IDENTITY[config=Debug] = Apple Development
DEVELOPMENT_TEAM[config=Debug] = <your team ID>
```

`make test` / `make dev` pass `-xcconfig Local.xcconfig` when it exists. Raw `xcodebuild`, Xcode and `scripts/fixture/run-tests.sh` don't use it.

## Config

Preferences are JSON at `~/Library/Application Support/Transmission Remote/preferences.json` (`PreferencesStore` in `AppConfig.swift`): the `servers` array, `currentServer`, `refreshSeconds`, toolbar layout, etc. It's edited through the Settings window (⌘,). The owner's real server config lives there: **do not print the password**.

- **Migration:** on first run with no native store, the legacy JSONC at `~/.config/transmission-remote-mac/config.jsonc` is imported (left in place as a backup); otherwise `AppConfig.default` is seeded.
- **Testability:** `PreferencesStore` has path-injectable cores (`load(storeURL:legacyURL:)`, `save(_:to:)`, `encode`/`decode`, `loadLegacyJSONC(from:)`).
- **Stable server ids:** every `ServerConfig` has `id: UUID`. Entries without one get a minted id and `loadReportingFirstRun` writes back only the missing `id` keys (unknown keys survive). Duplicate/malformed ids are replaced. Settings binds per-server state by id; `RefreshController` tracks the active server by id (`SelectedServerID`, migrating `SelectedServerName`) and reconnects only when `ServerConfig.requiresReconnect` (endpoint, credentials, headers, Access flag; not name/presets/mappings).
- **Port/ratio input:** the port must parse via `ServerPort` (1–65535, digits only); while invalid, Apply and Test Connection are blocked. Decimals go through `ServerDecimal` (grouping rejected); readback compares with `ServerOptionValue.matches` (1e-6).
- **ATS:** `Info.plist` sets `NSAllowsArbitraryLoads` because the daemon is usually plain HTTP on a LAN/VPN and ATS blocks cleartext to named hosts (`n5.local`) though not bare IPs. A Tailscale host (`transmission.raptor-ruffe.ts.net`) speaks HTTPS and needs Use HTTPS.
- "Reveal Preferences in Finder" (File menu) selects the store.

### Settings window

`SettingsWindowController` + panes; resizable (min 760×560, autosave `SettingsWindow2`), source-list sidebar (**App ▸ General** + a row per server with status dot, Default badge, unsaved-edit dot). Explicit constraints, not a stack view (gotcha 3). Logic lives in Foundation-only `SettingsEditor` and `ServerSettingsScope`; controllers are thin. UI state persists in `UserDefaults` (skipped under `TestIsolation`; tests set `SettingsWindowController.remembersUIState = false`).

- A server shows tabs **Connection · Transfers · Speed · Network · Advanced**. Connection is stored on this Mac; the rest are the daemon's session settings. Groups are tiered (`ServerOption.Definition.tier`): essential always open, common collapsed.
- **One Apply / Revert per server.** `ServerSettingsScope.plan` + `apply` run the server `session-set` first (conflict check + readback); only on success is the local part saved via `SettingsEditor.applyServer(id)`, which never persists another server's pending edits. Then `onApplied` calls `refreshNow()` + `rebuildServerMenu()`. Changed host/credentials drop that server's session.
- **Apply is not the Return/default button.** Apply enables on every keystroke; live edits update just the affected row and **never** `reloadData()` mid-edit. Changing rows, adding a server, ⌘W and Quit ask Apply / Discard / Cancel (Quit returns `.terminateLater` during an Apply). Switching tabs keeps edits.
- **Routing never resets an open window:** `AppDelegate.openSettings` → `reopen(with:)` re-seeds only when the window isn't visible **and** nothing is pending (minimized counts as not visible). ⌘, = last selection; Server Settings… (⌥⌘,) = active server's last tab; Manage Servers… = Connection; Edit Presets… = Speed.
- **Server list edits apply immediately:** drag-reorder, Make Default, and − (undoable via Edit ▸ Undo). **+** adds an unsaved server its Apply saves.
- **Blocked states:** unsaved new server, connecting, offline (Retry / Test Connection). Presets stay editable. Values load when a server is first shown and on Revert, never from the poll, except that unedited Speed fields absorb limits changed from the speed menus (`ServerOptionsSession.absorb`).
- **Revert = discard + refetch** (`refetchServerValues`); it also clears `needsReload` and the changed-on-server notice. The Discard choice in prompts only drops edits.
- The active server reuses `refresh.activeClient`; others get a client via `ConnectionResolver.firstToRespond`.
- **General** controls apply immediately through `SettingsEditor`'s write-through setters (`applyImmediately`), never touching server dirty state. The refresh field applies on end-of-edit only.
- Verification hook: with `-PreferencesPath`, `-OpenSettings general|connection|transfers|speed|network|advanced` opens Settings at launch.

### Multi-host failover

A server's Host field takes a comma- or newline-separated list, e.g. `10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net`. Each token is a bare host, `host:port`, or `scheme://host[:port][/path]` (incl. bracketed IPv6); omitted parts are inherited from the server (`ServerConfig.connectionCandidates`).

- On connect and after any failed poll, `RefreshController.resolveReachableClient()` probes candidates in order (`session-get`, `probeTimeout` 5s) via the pure `ConnectionResolver.firstReachable` and uses the first that responds.
- **Test Connection probes every candidate concurrently** (`probeAll`) and reports a per-host ✓/✗ list; a single host keeps the focused message. It builds its `ServerConfig` from the current form fields.

### Custom headers & redirects

For a daemon behind an access proxy that wants headers on every request.

- `ServerConfig.headers: [CustomHeader]`, sent only while `useCustomHeaders` is on (decodes to on exactly when headers exist; off = kept, not sent, not validated). `preferences.json` stores only `{"name": …}` (a `value` key in the file is ignored). Values live in the **login Keychain** (one generic-password item per server; service `com.nickvance.transmission-remote-mac.custom-headers`, account = server UUID, JSON name→value). `load` hydrates, `save` persists (skipping unchanged) and deletes items for gone servers, so Undo of Remove Server writes values back. If the Keychain can't be read at launch, values are never written back that session. `TestIsolation` uses an in-memory store.
- `HeaderValidation` rejects empty/malformed/duplicate (case-insensitive) names, CR/LF or control characters in values, URLSession's reserved names (Authorization, Connection, Content-Length, Host, Proxy-Authenticate, Proxy-Authorization, WWW-Authenticate) and the app's own (Content-Type, X-Transmission-Session-Id). Settings blocks Apply/Test Connection on a problem; the client also drops invalid ones.
- **Sent over HTTPS or real loopback only** (`ServerConfig.sendsCustomHeaders`); the Settings UI warns about plain HTTP.
- `TransmissionClient` takes `[RequestHeaderSource]`: configured headers first (`StaticHeaderSource`), then extra sources (later wins on a repeated name). Sources are asked once per request, before the 409 retries. Host candidates copy the whole config, so failover and Test Connection send them too.
- **Redirects are refused** on every RPC request → `TransmissionError.redirected(status:location:)`; `ConnectionDiagnostics` explains same-host (Use HTTPS), other host (sign-in page; check headers) and other path (check RPC Path).
- UI: Cloudflare Access and Custom Headers share one collapsed **Access Proxy** disclosure group at the bottom of the Connection tab (auto-opens when one is on or a header is invalid; open state remembered per server). The code stays generic: no proxy-vendor names outside the Access files.

### Cloudflare Access sign-in

Browser sign-in via Cloudflare's **Managed OAuth** for a daemon behind Access. Required Access settings, lifetimes recommendation and the manual checklist: `docs/CLOUDFLARE_ACCESS.md`. Needs Managed OAuth on (loopback clients allowed) and the app's **Binding Cookie off**.

- **Discovery** (`AccessSignIn.discover`): a token-less `session-get` gets Access's `401` + `WWW-Authenticate: Bearer … resource_metadata`; the authorization server must be HTTPS on `*.cloudflareaccess.com` and offer S256, public clients and registration, with endpoints on its own host. A `302` to `/cdn-cgi/access/login` means Managed OAuth is off (`AccessError.managedOAuthOff`).
- **Sign-in:** register once per server (RFC 7591, no client auth, redirect `http://127.0.0.1:<port>/callback`), reusing client and port (busy port → new port + registration); PKCE S256 + `state` + `resource` in the default browser; the loopback listener ignores callbacks with the wrong `state`; exchange the code for tokens. Never opens a browser without a click.
- **Storage:** `ServerConfig.useCloudflareAccess` (in `requiresReconnect`); the `AccessSession` is a Keychain item per server (`…cloudflare-access`), so signing in/out never dirties Settings. Sign Out revokes tokens and keeps the registration. `AccessSessions.shared` is in-memory under `TestIsolation`.
- **Sending:** `cf-access-token: <token>` to the token's resource host only (LAN fallbacks never get it), leaving `Authorization` for Basic auth. Requests set `httpShouldHandleCookies = false`.
- **Renewal:** 30 s before `expiresAt` and when Access answers a sent token with its Bearer challenge (retry once). `AccessTokenRefresher` runs one refresh per server (refresh tokens rotate) and saves quietly. Only a 4xx refusal (`invalid_grant`) signs out; 5xx/429/non-token 200 do not. Then the request fails with `.expired` and the main window asks once.
- `SecRandomCopyBytes` failure is fatal.

### Path mappings (Reveal in Finder / Open)

`downloadDir` is a path on the remote daemon. `ServerConfig.pathMappings` (`remote=local` lines in Settings, ported from legacy `PathMap`) rewrite a remote prefix to a local one. `mapRemoteToLocal`: longest prefix wins regardless of order, case-sensitive, prefix match guarded by a trailing `/` (`/var` ≠ `/var2`), exact match returns the local path as-is. Right-click a torrent (or a file/folder in the Files tab) → **Reveal in Finder** / **Open**, enabled only when a mapping matches; if the local file isn't present a non-modal toast (`showToast`) appears.

### Magnet links, opened torrents, clipboard

- `Info.plist` registers `magnet:` and imports the `org.bittorrent.torrent` UTI; `application(_:open:)` → `MainWindowController.handleOpened`.
- **Pending-add queue** (`pendingAdds`, `+Add.swift`): externally arriving adds wait until the connection is `.connected`/`.failed` (a cold-launch magnet click arrives before the handshake), then show **one sheet at a time**. The same torrent (btih via `TorrentLink.identity`) arriving within 10s is dropped. "Add Magnet or URL…" bypasses the queue.
- Settings ▸ General: "Show options when adding" (default on; off = add straight to the default dir with a toast), "Add magnet links copied to the clipboard" (default **off**; checked on `didBecomeActiveNotification` gated on `NSPasteboard.changeCount`, never clears the clipboard, always shows the sheet because a bare 40-hex string may be a git SHA), and Make Default rows (`NSWorkspace.setDefaultApplication`, immediate).

## Title bar & toolbar layout

`ToolbarLayout` (`AppConfig.toolbarLayout`) is two choices: **Title bar** (`TitleBarStyle` full / hidden) and **Show button labels**, persisted as `titleBar` / `toolbarLabels`; edited in Settings ▸ General and the View menu. `MainWindowController.applyToolbarLayout` is the single owner of title visibility, toolbar style and display mode; the decisions (`showsTitle`, `showsToolTips`) are Foundation-only and tested.

- Title full → `.expanded`; hidden → `.unified`. Labels off = tooltips. **Hiding the toolbar forces the title visible**; `observeVisibility` re-applies on show/hide.
- The setting owns the display mode, but the user can change it from the palette/right-click: a KVO observer maps icon-only → labels off, anything else → labels on, routed through `AppDelegate.setToolbarLayout`. `applyToolbarLayout` sets `toolbarLayout` first so its own writes never look like user changes. `NSToolbar` autosave would otherwise override the setting, so it's applied after the toolbar attaches.
- **Never `.unifiedCompact`** (AppKit drops the display-mode controls, so icon-only couldn't be undone).
- **Search item:** only the live item (`willBeInsertedIntoToolbar == true`) may set `searchField`, or the palette copy steals it.
- `NSWindow.allowsAutomaticWindowTabbing = false` keeps tab items out of the View menu.
- **Toolbar autosave id is `MainToolbar3`.** Bump it when adding a default item (resets users' customization once). The server dropdown and Speed Limits pull-down are in `centeredItemIdentifiers`; the dropdown is a plain view item labelled "Server" so AppKit aligns it.
- **Proxy icon** is AppKit's: only with `representedURL` (the bundle), drawn from the icon's **16pt renditions** (`icon_16x16*`, `icon_32x32`), which must match the large artwork. A hand-placed image view in the title bar was tried and dropped (stopped drawing after a layout switch).

## Tests

XCTest in `Tests/` (target `TransmissionRemoteTests`, ~250+ hermetic tests). The business-logic sources are **compiled directly into the test bundle** rather than hosting the app (which would launch it and connect to the owner's server). Add new Foundation-only files to the target in `project.yml`. Shared helpers: `TorrentFactory`, `StubURLProtocol` (per-host state via `uniqueHost()`, sends 3xx through real redirect handling), `AccessStub`.

```sh
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote -configuration Debug test
```

**Policy.** The default run is hermetic: no daemon, no port probes, same answer on any machine. Daemon-backed tests are opt-in via env vars (forward with the `TEST_RUNNER_` prefix); skips in the default run are fine, a skip in opt-in mode is a failure. Tests needing files must generate them, not read `~/Downloads`.

- **Fixture gate:** `make fixture-test` / `scripts/fixture/run-tests.sh` runs `FixtureTransmissionTests`, `FixtureConcurrencyTests`, `FixtureFailoverTests`, `FixtureProxyTests` against Docker (a Transmission daemon + an nginx sidecar on host port **19092**; `scripts/fixture/nginx.conf`) and exits non-zero on any skip. The sidecar has `/redirect/…` (302 to another host), `/gated/…` (forwards only with `X-Fixture-Token: fixture-token`), `/access/…` (mimics Managed OAuth: 401 Bearer unless `cf-access-token: fixture-access-token`) and `/access-legacy/…` (302 to the login page).
- **Live tests** (`LiveConnectionTests`, `TEST_RUNNER_RUN_LIVE_TRANSMISSION_TESTS=1`) hit the real daemon, reading credentials from the legacy JSONC at runtime. Cleartext-HTTP cases `XCTSkip` in the `xctest` runner (its ATS ignores the bundle's `Info.plist`); verify those via the app + `curl`.
- **Real-Keychain round trip** is opt-in: `TEST_RUNNER_RUN_KEYCHAIN_TESTS=1`.
- **`ScriptingDictionaryTests`** cross-checks `Resources/TransmissionRemote.sdef` against `Sources/Scripting.swift` by source text (every `cocoa class` ⇄ `@objc(...)`).
- **`scripts/test-applescript.sh`** (opt-in; needs a built Debug app + Docker) drives the real AppleScript dictionary against the fixture, launching the app with `-PreferencesPath scripts/fixture/preferences.json` (isolated, credential-free). `TestIsolation` (`AppConfig.swift`) also suppresses real-`UserDefaults` reads/writes, the first-run update prompt, the last-good-host cache and launch-time `NSApp.activate`. It does not cover the pending-add queue, Add-options sheet or clipboard pickup (those need `didBecomeActiveNotification`/UI flows); verify them manually.

## Gotchas (don't regress)

1. **Use `main.swift`, not `@main`.** `@main` on a bare `NSApplicationDelegate` didn't install the delegate on this toolchain (no window, no config).
2. **`ENABLE_DEBUG_DYLIB: NO`** in `project.yml`, or Xcode 16's debug-dylib split fails to link (`_main` undefined).
3. **Don't lay the main UI out with `NSStackView`**: it collapsed the split view (and the table) to zero height. Use explicit constraints (split pinned above a fixed-height status bar). Same for the Settings sidebar/detail split.
4. **Outward actions on a live server are real.** Start/stop/rename/move hit the owner's production daemon (1000+ torrents). Use a disposable torrent, restore state, get the owner's OK before mutating, and never use broad `pkill -f "Transmission Remote"` (it also matches the legacy "Transmission Remote GUI"); use `pkill -f "Debug/Transmission Remote.app"`.

## Verifying changes in the running app

**Rendering:** plain `screencapture` is often blank because the window is on another Space. Capture by ID: `screencapture -x -o -l <windowID>` (ID from `CGWindowListCopyWindowInfo`, owner PID = the Debug app, layer 0). To render a setting without touching the owner's preferences, launch the Debug binary with `-PreferencesPath` pointing at a scratch copy of `scripts/fixture/preferences.json` with that key changed.

**State/behavior, preferred: the AppleScript dictionary** (`Resources/TransmissionRemote.sdef`, `Sources/Scripting.swift`). It reads model state, not UI internals:

```applescript
tell application id "com.nickvance.transmission-remote-mac"
  name of every torrent
  connection state
  set search text to "foo"
end tell
```

`first item of selection` does **not** work (`selection` is a plain list property); filter instead, e.g. `first item of (torrents whose name is "...")` (pattern used throughout `scripts/test-applescript.sh`).

**Accessibility tree**, for what the dictionary can't see (actual rendering, menu-item enablement). Needs accessibility permission for the controlling process; `entire contents of window 1` chokes on the 1041-row tree, so drill explicit paths. Right-click context menus can't be driven via System Events at all; verify them another way. Never use a global AppleScript `keystroke` for checks: it hits the user's real frontmost window.

**On macOS 27** the permission is Privacy & Security ▸ Device Control and Data Access (deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`), granted to the process macOS holds responsible: for Claude Code that's its bundled helper `~/Library/Application Support/Claude/claude-code/<version>/…/claude.app`, not `/Applications/Claude.app`. There System Events can count UI elements but not fetch them, so use the AX API directly (`AXUIElementCreateApplication` with the pid, find by `AXIdentifier`, `AXPress`, set `AXFocused`, `CGEvent.postToPid` for keys). Settings controls carry identifiers (`server-headers-add`, `server-headers-table`, `server-options-apply`, …). Isolated runs (`-PreferencesPath`) don't activate the app: call `NSRunningApplication.activate()` before typing. For the search filter, `set value of <searchField>` fires the action reliably; `keystroke` is flaky.
