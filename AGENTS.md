# Native macOS Transmission Remote

## What this is

A **native macOS app in Swift + AppKit** that talks to a single Transmission
BitTorrent daemon over JSON-RPC. It's a from-scratch rewrite of the legacy
Free Pascal / Lazarus app, which is preserved on the `legacy-pascal` branch for
reference (protocol/feature behavior, `rpc.pas` is the authoritative source for the Transmission RPC protocol).

- Scope is a deliberately minimal MVP for the owner's daily use — not feature parity.

## Current status (feature-parity pass complete)

Done and verified against the owner's real server (~1040 torrents, Transmission
4.1.2). Core MVP: connect, live torrent list with a state-coloured progress bar,
sortable columns, **start / stop / force-start / rename / move / verify / queue-move
/ bandwidth priority / remove**, and a fuzzy/exact toolbar search.

All `feature-ranking.md` items above "Other stuff not worth doing yet" are now
implemented:

- **Files tab** — tabbed detail pane (Info / Files / Peers); a directory-tree
  `NSOutlineView` of the torrent's files with a tri-state wanted checkbox
  (`files-wanted`/`files-unwanted`), aggregated size, live progress, and priority
  (`priority-*`) — folder actions apply to every file beneath. Fetched on demand
  per selected torrent, refreshed on the poll with expansion/selection preserved
  by path; column sorting applies within each folder level.
- **Trackers tab** — a read-only sortable `NSTableView` between Files and Peers
  (Tracker URL, Status, Update In, Seeds, Leechers), mirroring the legacy
  `FillTrackersList`. Fetched on demand per selected torrent
  (`torrent-get` `["id","trackerStats"]`, `fetchTrackers`), only while the tab is
  visible and exactly one torrent is selected; selection (by tracker id) and focus
  preserved across polls; 3-state header sort, widths persist
  (`TrackersColumnWidths`). Status text/countdown (`TrackerStatsInfo.statusText`,
  `secondsUntilNextAnnounce`; a failed scrape surfaces after a good announce) and
  `TrackerSortKey.sorted` are Foundation-only and unit-tested
  (`TorrentTrackerTests`). No add/edit/remove tracker actions.
- **Peers tab** — a flat sortable `NSTableView` of the selected torrent's
  connected peers: Address (`ip:port`), Client, Flags (`flagStr`), a progress
  bar, and ↓/↑ rates. Fetched on demand per selected torrent
  (`torrent-get` `["id","peers"]`, mirroring `fetchFiles`), only while the tab is
  visible and exactly one torrent is selected; refreshed on the poll with
  selection (by `address:port` identity) and focus preserved. Header clicks cycle
  ascending → descending → unsorted (daemon order) like the Files tab; column
  widths persist (`PeersColumnWidths`), sort is session-only. Peer decoding is
  tolerant (daemons omit zero-valued fields); sorting lives in the
  Foundation-only `PeerSortKey.sorted` (numeric-aware address compare, stable
  address/port tie-break) and is unit-tested.
- **Add torrents** — Add toolbar pull-down + File-menu (⌘O file, ⌘L magnet/URL),
  drag-and-drop onto the window, and Dock/Open-With (`CFBundleDocumentTypes` in
  `Info.plist`). Shared options sheet (destination prefilled from session
  download-dir, Start-when-added) → `torrent-add` with duplicate detection.
- **Sidebar filter groups** — source-list `NSOutlineView`: Status / Trackers /
  Folders with live counts (native take on `filtering.pas`). Applied before search.
- **Column customization** — Size / Added / Tracker / Error columns (hidden by
  default), all sortable (Error ascending lists errored torrents first); right-click header menu toggles visibility + Auto-Size; reordering
  and column state persist.
- **Aggregate status bar + free-space** — per-status counts and the download dir's
  free space (`free-space` RPC).
- **Info tab polish** — comment, full dates, error detail, downloaded/uploaded-ever,
  tracker, and a download/upload speed sparkline.
- **Piece map** (fork addition, ported from the legacy `pbDownloaded`/`ProcessPieces`)
  — a "Pieces" row above the Info grid: a thin classic progress bar, a map of which
  pieces the daemon has beneath it, and the precise percentage at the right. The
  bitfield (`torrent-get` `["id","pieces","pieceCount","pieceSize"]`,
  `fetchPieces`) is fetched on demand like Peers — only while the Info tab is
  visible and exactly one torrent is selected, refreshed on the poll; the classic
  bar/percent come from the list poll itself so they move before the bitfield
  lands. The row collapses (padding included) for none/multi selection. Decoding
  (MSB-first bits, padding ignored), `haveCount`, the per-pixel
  `coverage(columns:)` downsample (overlap-weighted, snapped to exact 0/1) and the
  tooltip `summary` live in the Foundation-only `TorrentPieces` (`Models.swift`,
  tested). The map tints each column by its coverage (floor 25% so a lone piece
  in a busy column still shows) and merges equal-coverage runs into one fill.
  **Settings ▸ General ▸ "Show piece map in the Info tab"** (`showPieceMap`, default
  on, applies immediately) hides the row and stops the `pieces` fetch; the gate is
  `PieceMapView.isActive` (tested).
- **Persistence** — window frame, split positions, column order/width/visibility,
  and sort descriptor all persist across launches.

Native follow-ups (`04-native-followups.md`) also done: blue app icon (modern
icns), sortable **Ratio-Limit column** (hidden by default), disambiguated sidebar
folder labels (minimal unique suffix), and a "Connecting…" first-launch state
that no longer flashes an offline/error message before the first handshake.

Round-2 follow-ups (`05-native-followups-2.md`) done and verified live:
**asset-catalog AppIcon** so the Dock tile renders the blue badge (the `.icns`
stays for Finder; needed an IconServices/Dock cache flush — `lsregister -f` +
empty `$DARWIN_USER_CACHE_DIR/com.apple.iconservices` + `killall Dock`); ETA shows
**"—" for completed/seeding** torrents (`Torrent.etaDisplay`; "∞" only while
genuinely downloading); **folder-dupe locations merged** (counts keyed on
`Torrent.normalizedDownloadDir`, folder filter matches normalized on both sides);
**sidebar scroll preserved across polls** (structure-fingerprint → in-place count
updates + `reloadItem`, full reload only on structural change with scroll
save/restore); and **reorderable sidebar sections** (`SidebarGroup` order in
`UserDefaults` `SidebarGroupOrder`, drag-to-reorder group rows + right-click Move
Up/Down). Follow-up after the plan: the Folders group sorts by its **displayed
label** (the disambiguating suffix) via `localizedStandardCompare`, not the full
download path.

Round-3 (`06-multi-server-and-polish.md`) done and verified live: **search
placeholder** reflects the active match mode ("Fuzzy/Exact filter by name");
**color-tinted sidebar status icons** (`StatusFilter.color`, `Node.tint`,
`FilterCellView` tint param — consistent with `progressColor`); **adaptive
region-aware Added date** (`Formatters.compactDate` numeric-short when the column
is narrow, full `date` + time when wide; the flip is driven by a custom
`AddedDateCellView` that re-picks its form in `layout()` against a measured ~162pt
threshold — so it adapts **live mid-drag** as the column resizes, with no resize
notification needed; `cellText` keeps the full form so Auto-Size fits it);
**multi-server** — `config.jsonc` moved outright to a
`servers: [ServerConfig]` array shape (no backward-compat decode; falls back to a
single localhost default), `TransmissionClient.init(server:)`, a **Server menu**
(right of Edit) that checkmarks the active server and switches the live connection,
selection persisted in `UserDefaults` `SelectedServerName` (resolved
UserDefaults → `currentServer` → first), and a **bottom-left fetch spinner + idle dot**
(`RefreshController.onFetchingChanged`, transition-coalesced; `circle.fill` dot
tinted by connection state when idle, `NSProgressIndicator` while polling — note the
spinner is near-invisible against a fast LAN server whose fetch is ~2ms). The owner's
real config was migrated by hand to the new shape (backed up first); a second
example `Local` entry was added so the Server menu has two to switch between.
Follow-up fix this round: the app menu gained standard **Hide / Hide Others /
Show All** items so **⌘H** is bound (it was a no-op before).

Round-4 (title bar + server switching, no plan file): a **server dropdown** centered
in the toolbar replaces the server name in the title; **Toolbar size** Default /
Compact (Settings ▸ General and **View ▸ Toolbar Size**; see *Title bar & toolbar
layout*); **View ▸ Customize Toolbar…**; **Server ▸ Manage Servers…** opens Settings
on the Servers tab (since Round-6: the active server's Connection tab); **drag-to-reorder servers** in Settings; **⌘1–⌘0** switch to
servers 1–10 in Server-menu order; outline toolbar symbols. Both layouts were
verified by window capture; menu items, tooltips, and clicks were not driven (no
accessibility permission in that session).

Round-5 (speed limits, no plan file): **Speed Limits toolbar pull-down** right of the server
dropdown (both in `centeredItemIdentifiers`; autosave id bumped to `MainToolbar3`) and a matching
**Server ▸ Speed Limits** submenu, both rendered from the Foundation-only `SpeedMenuModel`
(`MainWindowController+Speed.swift`). Limits are **server-side** (`session-set`
`speed-limit-*` / `alt-speed-*`, KB/s; setting a limit also leaves turtle mode, as legacy did); turtle
mode is the "slow" profile (toggle + Turtle Down/Up submenus). Only the **preset lists**
(`ServerConfig.downSpeedPresets`/`upSpeedPresets`, Settings ▸ Servers) are client-side, per server.
`RefreshController` now polls `session-get` each tick (`session`, `onSessionChanged`), refetches right
after a change (`updateSession`), and feeds `RateHistory` to the status-bar `RateSparklineView`;
rates show the active limit, e.g. `↓ 1.2 MB/s (500 KB/s)`. Verified against a local mock RPC server
(layout capture + `session-set` payloads); menu clicks were not driven.

Round-6 (unified Settings, no plan file): the separate Server Options window is gone. **One Settings window** with a sidebar (**App ▸ General** + one row per server) shows, for a server, a header and five tabs: **Connection** (this Mac) and **Transfers / Speed / Network / Advanced** (the daemon's session settings; Queue merged into Transfers, speed presets and bandwidth groups on Speed). **Server ▸ Server Settings…** (⌥⌘,) and the toolbar button (label "Server Settings", identifier still `serverOptions`) open the active server's last tab; any server can be edited. `ServerConfig` gained a stable **`id: UUID`** (minted for old preferences and written back by adding only the `id` keys). See `docs/SERVER_SETTINGS.md` and *Config ▸ Settings window* below. Verified by unit tests and window captures with `-OpenSettings`; no Apply was sent to the owner's server.

Round-7 (custom headers + redirects, branch `cf-access-headers`): each server can carry **custom HTTP headers** sent with every RPC request (first use: an access proxy's service-token headers), edited in a **Custom Headers** table on the Connection tab. Names live in `preferences.json`, values in the **Keychain**. RPC requests **refuse redirects**: a 3xx becomes `TransmissionError.redirected`, which Test Connection explains (HTTPS upgrade / sign-in page on another host / other path). The code stays generic: no proxy-vendor names. See *Config ▸ Custom headers & redirects*. Verified by unit tests, the Docker fixture gate (`make fixture-test`: 28 tests incl. the three `FixtureProxyTests` against the nginx sidecar, no skips), and the live Debug app driven through the AX API (add a row, reserved name blocks Apply, fix, Apply, saved file has names only).

Round-8 (Cloudflare Access sign-in, same branch): **"Sign in with Cloudflare Access"** on the Connection tab signs in with Cloudflare's **Managed OAuth** (the documented flow for apps) in the **default browser**, any login method the Access app offers. Tokens live in the **Keychain**, the access token goes out as `cf-access-token` (so `Authorization` stays Transmission's Basic login), and it **renews itself** with the refresh token; the browser is needed again only when the grant ends, and never opens without a click. Needs **Managed OAuth on** for the Access application (with loopback clients allowed) and the app's **Binding Cookie off** (with it on, Access refuses its own OAuth tokens). See *Config ▸ Cloudflare Access sign-in* and `docs/CLOUDFLARE_ACCESS.md`. Verified by unit tests (the whole flow against stubs), the fixture gate (31 tests), and live: browser sign-in, Test Connection through Access with Transmission's own login, Keychain contents, and an automatic renewal after the access token expired.

Round-9 (hardening of Round-7/8, branch `access-hardening`): Cloudflare Access and Custom Headers moved into one **collapsed "Access Proxy" disclosure group** at the bottom of the Connection tab (both features still off by default; the group auto-opens when one is on or a header is invalid; open state remembered per server). A 5xx/429/non-token 200 on refresh no longer signs the user out (only a 4xx refusal does); custom headers go only over HTTPS or loopback (`ServerConfig.sendsCustomHeaders`); the loopback listener ignores callbacks whose `state` isn't the expected one; `SecRandomCopyBytes` failure is fatal; header values reject control characters; Delete removes header rows; `Local.xcconfig` is gitignored.

Intentionally dropped: **label filtering and the Labels column/sidebar group.**

- **Remove**'s data-deleting path and the per-file wanted/priority **writes** were
  intentionally **not** fired against the owner's prod server. Read paths and
  non-destructive RPCs (`torrent-get files/fileStats`, `free-space`, `torrent-add`
  duplicate) were validated live.

- Plans live in `.context/`, numbered chronologically: `01-mac-port-plan.md` (MVP),
  `02-feature-backlog.md`, `03-feature-ranking.md` (ranked backlog), `04-native-followups.md`
  (icon recolor, Ratio-Limit column, folder-filter fix, connecting state),
  `05-native-followups-2.md` (Dock icon, completed-ETA, folder dupes, sidebar scroll +
  reordering), `06-multi-server-and-polish.md` (search placeholder, tinted sidebar
  icons, adaptive Added date, multi-server + Server menu, fetch spinner/idle dot),
  `07-resize-tints-window-frame.md` (column h-scroll, status tints, window frame),
  `08-native-prefs-and-tests.md` (Application Support preferences store + Settings
  window replacing JSONC; XCTest unit-test target).

## Layout (`Sources/`)

- `main.swift` — explicit AppKit entry point (see gotcha below).
- `AppDelegate.swift` — app lifecycle, menus (Settings… ⌘,, Find ⌘F, Edit, View, Server).
- `ServerMenuSync.swift` — Server menu in-place update check + ⌘1–⌘0 key mapping (tested).
- `ToolbarLayoutAppKit.swift` — `NSWindow.apply(toolbarLayout:)` and the `NSToolbar` display-mode observer (tested); ignores AppKit's transient mode resets while applying.
- `PopUpEnum.swift` — `NSPopUpButton` ⇄ `CaseIterable` enum bridging (`configure`/`select`/`selectedCase`); use it for every enum-backed popup (tested).
- `SettingsWindowController.swift` — the Settings window shell: sidebar (General + servers, drag-reorder, footer +/−/Default), server header, the five server tabs, Apply/Revert, routing and the pending-edit guards (tested).
- `SettingsGeneralPane.swift` / `SettingsConnectionPane.swift` — the General pane and a server's Connection tab (with Test Connection under the credentials) + speed presets.
- `ServerSettingsPane.swift` — the server-side tabs (`ServerSettingsFormController`), disclosure groups with scope tags, blocked-state notice.
- `ServerOptions.swift` — Foundation-only session-settings schema (pane/tier/group per field), editor, `ServerOptionsSession`, and `ServerSettingsScope` (availability, apply plan) (tested).
- `BandwidthGroupsWindowController.swift` — the bandwidth groups editor, shown as a sheet from the Speed tab.
- `SettingsEditor.swift` — Foundation-only editing model behind Settings: per-server dirty/apply/revert (tested).
- `ConnectionDiagnostics.swift` — Test Connection error→message mapping, incl. refused redirects (`redirectKind`, `shortRedirect`) (tested).
- `CloudflareAccess.swift` — Access constants (`cf-access-token`, the login-redirect path, team-domain check) and `AccessError` (tested).
- `AccessOAuth.swift` — Managed OAuth pieces: Bearer-challenge parsing, resource/authorization-server metadata and their checks, PKCE S256, registration/authorization/token/refresh/revocation requests (tested).
- `AccessLoopback.swift` — the one-shot 127.0.0.1 listener for the OAuth redirect (`AuthorizationCallbackReceiver`) and its result page (`page(for:)`: the app's icon and name over a card styled like Access's pages; no script, nothing from the query echoed) (tested).
- `AccessSignIn.swift` — the sign-in flow (discover → register or reuse → browser → code exchange), refresh and revoke; cookie-less; injectable network/browser/clock/receiver (tested).
- `AccessSessionStore.swift` — `AccessSession` (discovery, registration, tokens, expiry) in the Keychain; `AccessSessions` app-wide cache, change notification (or a quiet save), prune (tested).
- `AccessHeaderSource.swift` — `AccessTokenHeaderSource` (`cf-access-token` to the token's host only, renewal before expiry and on refusal), `AccessTokenRefresher` (one refresh per server), `AccessSignInReason` (tested).
- `AccessSignInController.swift` — app-wide sign-in runner and phases shared by Settings and the main window; sign-out revokes and keeps the registration; `appURL(for:)`, `statusText` (tested).
- `MainWindowController+Access.swift` — the once-per-episode sign-in prompt and Server ▸ Sign In to Cloudflare Access….
- `CustomHeaders.swift` — `CustomHeader` (encodes its name only) + `HeaderValidation` (reserved/malformed/duplicate names, line breaks) (tested).
- `HeaderSecretStore.swift` — header values: `KeychainHeaderStore` (login Keychain, one item per server id) and `InMemoryHeaderStore` (tests, `-PreferencesPath` runs); `hydrate`/`persist` (tested).
- `CustomHeadersTable.swift` — the Connection tab's headers table (Name / secure Value, +/−) and `HeaderCellView` (tested via `ServerSettingsWindowTests`).
- `HostCandidates.swift` — comma-separated host parsing + `ConnectionResolver` (tested).
- `TorrentLink.swift` — magnet / `.torrent` URL / bare info-hash recognition (tested).
- `DefaultHandlers.swift` — Launch Services default-app status + Make Default for
  `magnet:` and `.torrent` (Settings → General).
- `PathMapping.swift` — `ServerConfig.pathMappings` + remote→local mapping and the
  `remote=local` text parse/format used by the Settings editor (tested).
- `MainWindowController.swift` — window, `NSTableView`, detail pane, status bar,
  sorting, search/filter (`displayed` is the filtered view of the `torrents` model).
- `MainWindowController+Actions.swift` — toolbar (incl. Add pull-down, server
  dropdown, `applyToolbarLayout`), context menu, action methods, and the search
  toolbar item.
- `MainWindowController+Files.swift` — the Files tab tree (NSOutlineView) +
  wanted/priority actions (a folder's act on every file beneath it).
- `MainWindowController+Trackers.swift` — the Trackers tab table (same shape as Peers; sort logic is `TrackerSortKey.sorted` in `Models.swift`).
- `MainWindowController+Peers.swift` — the Peers tab table (NSTableView):
  on-demand per-torrent peers fetch + 3-state column sort (sort logic itself is
  `PeerSortKey.sorted` in `Models.swift`).
- `MainWindowController+Pieces.swift` — the Info tab's piece-map row: on-demand
  per-torrent `pieces` fetch (`loadPiecesIfNeeded`, same gating as Peers) +
  `updatePieceMap` (called from `updateDetail` every poll).
- `PieceMapView.swift` — the row itself (caption, classic bar + piece map,
  percent label); collapses to zero height via its own constraint (tested).
- `TorrentFileTree.swift` — the Files tab's Foundation-only tree model
  (`FileNode`: a leaf, or a folder aggregating its subtree) — build, per-level
  sort, and the in-place poll merge that keeps AppKit's expansion/selection
  alive across refreshes (tested).
- `MainWindowController+Add.swift` — add-torrent flows (file/magnet/drag) + `DropView`.
- `SidebarController.swift` — the source-list filter sidebar (`NSOutlineView`).
- `Filtering.swift` — `StatusFilter` / `SidebarFilter` (filter predicates).
- `TransmissionClient.swift` — `actor` over `URLSession`; HTTP Basic auth + the
  **409 / `X-Transmission-Session-Id` CSRF retry**; typed RPC wrappers; custom headers via `RequestHeaderSource`; redirects refused (`RedirectRefuser`).
- `RefreshController.swift` — `@MainActor` poll loop (~4s), connection state,
  pause-on-minimize, default download-dir + free-space.
- `Models.swift`, `AppConfig.swift`, `Formatters.swift`, `ProgressCellView.swift`,
  `SpeedGraphView.swift`.

**Squircle-jail escape** (`DockTile/`, repo root, its own target): macOS 26+ masks
our freeform icon into a gray squircle. Two parts get around it: `AppDelegate` sets
`NSApp.applicationIconImage` from `Resources/DockIcon.png` (a plain PNG, **not** the
asset catalog, whose rendition is already jailed) while the app is running, and the
`TransmissionRemoteDockTile.docktileplugin` NSDockTilePlugIn (embedded in
`Contents/PlugIns`, named by `NSDockTilePlugIn` in `Info.plist`) has the Dock draw
the same PNG when the app isn't running. **Finder** is handled by the app giving
its own bundle a custom icon (`AppDelegate.applyFinderIconIfNeeded`,
`NSWorkspace.setIcon` with `AppIcon.icns`). That adds an `Icon\r` file and a
Finder-info flag at the bundle root. Finder doesn't mask custom icons. All of
this is always on, with no setting.
- The icon is re-applied on any launch where it's missing, because a Sparkle update
  replaces the bundle.
- It's Release-only: in a Debug build the root files would break Xcode's next
  incremental codesign.
- Use the `.icns`, not the 1024px PNG. The PNG makes IconServices file an
  `ExcUserFault` report.
- Plain `codesign --verify --deep` still passes; only `--strict` objects to the root
  files.
- Verified end to end with signed Release builds: a real Sparkle update between two
  versions (local feed signed with a throwaway EdDSA key) installed fine and
  re-applied the icon, and the Dock's `com.apple.dock.external.extra` host loads
  the plug-in.

Launchpad and Spotlight stay jailed. The Dock loads plug-ins when it launches or
when a tile is added, so run `killall Dock` to pick up changes.

Project is generated by **XcodeGen** from `project.yml` (committed). The generated
`.xcodeproj` and `build/` are gitignored.

## Build & run

```sh
xcodegen generate          # only after editing project.yml / adding files
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug build
open ~/Library/Developer/Xcode/DerivedData/TransmissionRemote-*/Build/Products/Debug/"Transmission Remote.app"
```

Keep the build **clean with zero warnings** (Swift 6 strict concurrency `complete`).

**Local Debug signing (optional).** `project.yml` ad-hoc signs Debug, so every rebuild is a new code identity and the Keychain asks again for the header values. To sign Debug with your own Apple Development certificate, create an **untracked** `Local.xcconfig` at the repo root (keep it out of git, e.g. via `.git/info/exclude`):

```
CODE_SIGN_STYLE[config=Debug] = Manual
CODE_SIGN_IDENTITY[config=Debug] = Apple Development
DEVELOPMENT_TEAM[config=Debug] = <your team ID>
```

`make test` / `make dev` pass `-xcconfig Local.xcconfig` when the file exists; it overrides `project.yml`'s target settings without touching it, and XcodeGen never sees it. Builds started from Xcode, raw `xcodebuild` calls and `scripts/fixture/run-tests.sh` don't use it.

## Config

Config is now a **native preferences store**, edited through a native **Settings
window** (⌘,) — no more hand-edited JSONC.

- Persisted as JSON at
  `~/Library/Application Support/Transmission Remote/preferences.json`
  (`PreferencesStore` in `AppConfig.swift`). Holds the `servers` array
  (host/port/credentials/HTTPS/rpcPath), `currentServer`, and `refreshSeconds`.
  The owner's real server config lives there — **do not print the password**.
- **Migration:** on first run, if no native store exists, `PreferencesStore.load`
  migrates the legacy JSONC at `~/.config/transmission-remote-mac/config.jsonc`
  (left in place as a backup) into the native store; otherwise it seeds
  `AppConfig.default`. Verified live: the owner's real server (with credentials)
  migrated correctly.
- **Stable server ids:** every `ServerConfig` has an `id: UUID`. Entries without one decode with a minted id and `PreferencesStore.loadReportingFirstRun` adds just the missing `id` keys to the file (every other key, known or not, is kept). Host candidates copy the id. Duplicate or malformed ids are replaced on decode and written back. Settings binds per-server state by id; `RefreshController` tracks the active server by id (`SelectedServerStore`, `UserDefaults` `SelectedServerID`, migrating the old `SelectedServerName`), keys the last-good host by id (`LastGoodHostStore`, migrating `LastGoodHost.<name>`), and reconnects only when `ServerConfig.requiresReconnect` (endpoint/credentials, not name/presets/mappings) — all in `ServerIdentity.swift` (tested).
- **Port and ratio input:** the Connection port must parse via `ServerPort` (1–65535, digits only); while it doesn't, the field is marked, Apply is disabled and refused, and Test Connection reports it. Decimal options (seed ratio) parse/render through `ServerDecimal` ("." always the decimal point; the locale's separator only when it's the sole one; grouping rejected) and readback compares with `ServerOptionValue.matches` (1e-6 tolerance).
- **Settings window** (`SettingsWindowController.swift` + `SettingsGeneralPane`, `SettingsConnectionPane`, `ServerSettingsPane`): resizable (min 760×560, frame autosave `SettingsWindow2`), a source-list sidebar with **App ▸ General** and one row per server (status dot, "Default" badge, unsaved-edit dot). The layout uses explicit constraints, not a stack view, for the sidebar/detail split (gotcha #3). All editing logic lives in the Foundation-only **`SettingsEditor`** and **`ServerSettingsScope`**; the controllers are thin view layers. Selection, each server's last tab and expanded groups persist in `UserDefaults` (skipped under `TestIsolation`; tests set `SettingsWindowController.remembersUIState = false`).
  - **A server**: header (name, Connected/Connecting/Offline, endpoint · version, "Not the active server") and tabs **Connection · Transfers · Speed · Network · Advanced**. Connection holds name/hosts/port/HTTPS/rpcPath/credentials/path mappings; the speed presets sit on the Speed tab next to the limits they feed. Group headings say **Stored on the server** or **Stored on this Mac**. Tiers come from `ServerOption.Definition.tier`: essential groups always open, common groups collapsed by default, Default trackers and Server scripts collapsed on Advanced.
  - **One Apply / Revert per server** replaces Save Server and the old Server Options Apply. `ServerSettingsScope.plan` + `apply` run the server-side `session-set` first (existing conflict check + readback); only on success is the local part saved via `SettingsEditor.applyServer(id)` → `onChange`, which never persists another server's pending edits. Then `onApplied` calls `refreshNow()` + `rebuildServerMenu()` so the toolbar speed pull-down and Server ▸ Speed Limits re-render. A changed host/credentials drops that server's session so it reconnects.
  - **Apply is not the Return/default button** (no key equivalents on Apply/Revert); Return commits the focused field. Apply enables on **every keystroke**. Live edits update just the affected row, **never** `reloadData()` mid-edit. Changing rows, adding a server, ⌘W and Quit ask **Apply / Discard / Cancel** (Quit returns `.terminateLater` while an Apply runs). Switching tabs keeps edits.
  - **Routing never resets an open window**: `AppDelegate.openSettings` calls `reopen(with:)`, which re-seeds only when the window isn't visible **and** nothing is pending (a minimized window isn't "visible" either); otherwise it just routes (⌘, = last selection, Server Settings… = active server's last tab, Manage Servers… = Connection, Edit Presets… = Speed with presets focused).
  - **Server list edits apply immediately**: drag-reorder, **Make Default** (**Default** text button in the sidebar footer next to +/−, and the right-click menu; enabled for a saved non-default server), and **−** (undoable via Edit ▸ Undo, which the Edit menu now has). **+** adds an unsaved server that its Apply saves.
  - **Blocked states**: an unsaved new server ("Apply the connection first"), connecting (spinner), offline ("Can't reach …" with Retry and Test Connection). Presets stay editable. Values load when a server is first shown and on Revert, never from the poll, except that unedited Speed fields absorb limits changed from the speed menus (`ServerOptionsSession.absorb`; with edits the status line asks for a Revert).
  - **Revert = discard + refetch.** There is no separate Reload button: Revert drops the server's local and server-tab edits and reloads its values (`refetchServerValues`), which also clears `needsReload` after a failed write and the changed-on-server notice. The Discard choice in the close/quit/switch prompts only drops edits (no network).
  - The active server reuses `refresh.activeClient`; any other server gets its own client via `ConnectionResolver.firstToRespond` (`SettingsWindowController.resolveService`).
  - **Test Connection** (in the Connection form, under the credentials; not in the footer) builds a `ServerConfig` from the **current form fields** and probes every host candidate (`SettingsConnectionPane.testConnection`, messages via `ConnectionDiagnostics`).
  - **General**: a **General** group (refresh interval field + stepper, auto-check-for-updates, Files/Info options) and an **Incoming Torrents** group (default add-file handling, show-options-when-adding, clipboard, default-app rows). Every control **applies immediately** through `SettingsEditor`'s write-through setters (`applyImmediately`), so it never touches any server's dirty state. The refresh field applies on end-of-edit only, so typing "10" doesn't apply "1" first.
  - Verification hook: with `-PreferencesPath`, `-OpenSettings general|connection|transfers|speed|network|advanced` opens Settings at launch (window captures without driving the UI).
- `PreferencesStore` exposes path-injectable cores
  (`load(storeURL:legacyURL:)`, `save(_:to:)`, `encode`/`decode`,
  `loadLegacyJSONC(from:)`) so the store is unit-tested against temp dirs without
  touching the real Application Support file.
- "Reveal Preferences in Finder" (File menu) selects the JSON store.

### Hosts & ATS

The app talks to a self-hosted daemon, usually over **plain HTTP** on a LAN/VPN.
macOS App Transport Security blocks cleartext HTTP to _named_ hosts by default, so
`Info.plist` sets **`NSAllowsArbitraryLoads`** — otherwise `n5.local` would fail
where the bare IP `10.0.1.2` works. Verified live: `10.0.1.2` and `n5.local` both
connect over HTTP; the **Tailscale** host
`transmission.raptor-ruffe.ts.net` speaks **HTTPS** (valid cert) on :9091 and :443,
so it needs **Use HTTPS** checked (plain HTTP there returns "Client sent an HTTP
request to an HTTPS server").

### Multi-host failover

One server can list **several hosts** for the same daemon — type a comma- **or
line-separated** list in the Host field, e.g.
`10.0.1.2, n5.local, https://transmission.raptor-ruffe.ts.net`. The Host field is a
**2-line wrapping field** so a fallback list stays visible at once. On connect (and
after any failed poll) the app probes the candidates **in order** and uses the
first that responds, so leaving/joining the tailnet fails over transparently.

- `ServerConfig.connectionCandidates` (`HostCandidates.swift`) splits the Host
  field on commas **and newlines** (`split(whereSeparator:)` on `","`/`.isNewline`,
  so `\r\n` is handled as one separator) and parses each token as a connection
  string: bare host, `host:port`, or `scheme://host[:port][/path]` (incl. bracketed
  IPv6). Parts a token omits are inherited from the server (useHTTPS, port, rpcPath,
  credentials). A single host yields one candidate — existing configs are unchanged.
  `hasMultipleHostCandidates` derives from the parsed count (not a raw `,` test).
- `ConnectionResolver.firstReachable(_:probe:)` is the pure, injectable selection
  core (unit-tested). `RefreshController.resolveReachableClient()` uses it with a
  real `session-get` probe and a short per-candidate timeout (`probeTimeout`, 5s),
  re-resolving whenever a poll fails. `TransmissionClient.init(server:timeout:)`
  takes the probe timeout.
- **Test Connection probes EVERY candidate concurrently** (`probeAll`, a `TaskGroup`
  preserving candidate order) and reports a **per-host ✓/✗ list** — a header
  ("N of M hosts responded") plus one line per host
  (`✓ http://host:port — Transmission x` / `✗ … — <short reason>`, via
  `shortError`). A single-host server keeps the focused success/failure message.
  Verified live against the owner's N5 server: all three hosts (IP, `.local`,
  Tailscale-HTTPS) respond, and failover resolves to a reachable host
  (`LiveConnectionTests`).

### Cloudflare Access sign-in

Browser sign-in for a daemon behind Cloudflare Access with **Managed OAuth** ([docs](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/)). Details, the required Access settings and the manual checklist are in `docs/CLOUDFLARE_ACCESS.md`.

- **Discovery** (`AccessSignIn.discover`): a token-less `session-get` POST gets Access's `401` with `WWW-Authenticate: Bearer … resource_metadata="…"`; the resource metadata (same host) names the authorization server, which must be HTTPS on `*.cloudflareaccess.com`; its RFC 8414 metadata must offer S256, public clients and registration, with endpoints on its own host. A `302` to `/cdn-cgi/access/login` instead means Managed OAuth is off (`AccessError.managedOAuthOff`).
- **Sign-in:** register once per server (RFC 7591, `token_endpoint_auth_method: none`, redirect `http://127.0.0.1:<port>/callback`), reusing the client and its port (a busy port → new port + new registration); open the authorization URL (PKCE S256, `state`, `resource`) in the default browser; `LoopbackCallbackServer` takes the code; exchange it for access + refresh tokens.
- **Storage:** `ServerConfig.useCloudflareAccess` (in `preferences.json`, part of `requiresReconnect`) turns it on; the `AccessSession` is a Keychain item per server (`…cloudflare-access` service), so signing in/out never dirties Settings. Items in an older format read as signed out. Sign Out revokes the tokens and keeps the registration. `AccessSessions.shared` is in-memory under `TestIsolation` and in the test bundle.
- **Sending:** `TransmissionClient.init` adds `AccessTokenHeaderSource` for a server using Access over HTTPS: `cf-access-token: <oauth token>` only to the token's resource host (LAN fallbacks never get it), leaving `Authorization` for Basic auth.
- **Renewal:** the token is renewed 30 s before `expiresAt`, and when Access answers a sent token with its Bearer challenge (the hook's `requestRejected()`; the client retries once). `AccessTokenRefresher` runs one refresh per server (Access rotates refresh tokens) and saves quietly, without restarting the connection. A failed refresh (`invalid_grant`, the grant ended) signs the session out and announces it; the request fails with `.expired`, and the main window asks once.
- **Lifetimes:** Cloudflare's [recommendation for CLI and agent clients](https://developers.cloudflare.com/cloudflare-one/access-controls/applications/http-apps/managed-oauth/#managed-oauth-settings) is a 5–15 minute access token and a 1–2 week grant session (summarized in `docs/CLOUDFLARE_ACCESS.md`, which also has the steps to put Transmission's `/transmission/rpc` behind an Access application and a tunnel).
- **No cookies:** sign-in and RPC requests set `httpShouldHandleCookies = false`.

### Custom headers & redirects

For a daemon behind an access proxy (one that wants service-token headers on every request, and redirects anything else to its sign-in page).

- `ServerConfig.headers: [CustomHeader]`, ordered, sent only while `useCustomHeaders` is on (the "Send custom headers" checkbox; decodes to on exactly when headers exist; part of `requiresReconnect`; off = kept, not sent, not validated). `preferences.json` stores only `{"name": …}` (decodes to `[]` when absent; a `value` key in the file is ignored). Values live in the **login Keychain**: one generic-password item per server, service `com.nickvance.transmission-remote-mac.custom-headers`, account = server UUID, data = JSON name→value. `PreferencesStore.load` fills them in (`hydrate`); `save` writes them (`persist`, skipping unchanged ones) and deletes items for servers that are gone, so removing a header or server removes its value and Undo of Remove Server writes it back. If the Keychain can't be read at launch, values are **never written back that session** (a denied prompt must not erase them). Under `TestIsolation` an in-memory store is used.
- **Validation** (`HeaderValidation`): rejects empty/malformed names, duplicates (case-insensitive), values with CR/LF, URLSession's reserved names (Authorization, Connection, Content-Length, Host, Proxy-Authenticate, Proxy-Authorization, WWW-Authenticate) and the app's own (Content-Type, X-Transmission-Session-Id). Settings blocks Apply and Test Connection on a problem; the client also drops anything invalid, so a hand-edited file can't clobber the built-in headers.
- **Sending:** `TransmissionClient` takes `[RequestHeaderSource]`: the configured headers first (`StaticHeaderSource`), then any extra sources passed to `init` (a later source wins on a repeated name). Sources are asked once per request, before the 409 retries, so a runtime source (a token fetched on demand) can be added without touching `perform()`. Custom headers are set before the built-in ones. Host candidates copy the whole config, so failover probes and Test Connection send them too.
- **Reconnect:** headers (names, values, order) are part of `requiresReconnect`; `SettingsWindowController.sameConnection` defers to it.
- **Redirects** are refused on every RPC request (a per-task delegate), so a 3xx comes back as `TransmissionError.redirected(status:location:)` instead of the login page failing to decode. `ConnectionDiagnostics` distinguishes same host over HTTPS ("Turn on Use HTTPS"), another host (likely a sign-in page; check Custom Headers) and another path (check the RPC Path).

### Remote→local path mappings (Reveal in Finder / Open)

A torrent's `downloadDir` is a path on the **remote** daemon (e.g. `/video/...`),
which the Mac can't open directly. Each server can carry a list of **path
mappings** that rewrite a remote prefix to a local one (e.g.
`/video=/Volumes/Video`), so files can be revealed/opened locally. Ported from the
legacy app's per-connection `PathMap` (`main.pas` `MapRemoteToLocal`).

- `ServerConfig.pathMappings: [PathMapping]` (`PathMapping.swift`), persisted in
  `preferences.json`. Backward-compatible: configs predating this decode to `[]`.
- `ServerConfig.mapRemoteToLocal(_:)` — longest matching prefix wins regardless of
  list order (mirrors `mapLocalToRemote`'s tie-break), case-sensitive; an exact
  match returns the local path as-is outright, a prefix match (guarded by a
  trailing `/`, so `/var` ≠ `/var2`) appends the remainder. Both sides are
  `/`-based on macOS.
- **Settings UI** (`SettingsWindowController`): a multi-line `NSTextView` editor in
  the server form, one `remote=local` per line (mirrors the legacy `edPaths` memo),
  with an example caption. `PathMapping.parse`/`.format` bridge text ↔ array; it
  flows through the existing live-sync/dirty/`SettingsEditor` path.
- **Actions** (`MainWindowController+Actions.swift` / `+Files.swift`): right-click a
  torrent (or a file or folder in the Files tab) → **Reveal in Finder** / **Open**. The items
  are **enabled only when a mapping matches** the target's remote path; if it maps
  but the local file isn't present (not mounted/synced) a **non-modal toast**
  (`MainWindowController.showToast`) appears instead of opening. Reveal uses
  `NSWorkspace.activateFileViewerSelecting`, Open uses `NSWorkspace.open`.
- Verified against real N5 data: with `/video=/Volumes/Video` + `/undupe=/Volumes/undupe`,
  all 1040 torrents map and 1039 resolve to existing local files (the 1 miss is the
  toast case). Algorithm covered by `PathMappingTests`.

### Magnet links, opened torrents, clipboard (issue #11)

Ported from the legacy app (`RegisterURLHandler`, `CheckClipboardLink`,
`ShowAddTorrentWindow`):

- `Info.plist` registers the **`magnet:` URL scheme** (`CFBundleURLTypes`) and
  **imports the `org.bittorrent.torrent` UTI** (the doc type referenced it without
  declaring it). `application(_:open:)` → `MainWindowController.handleOpened`
  routes file URLs to the file route and `magnet:`/http(s) to the link route.
- **Pending-add queue** (`pendingAdds`, `+Add.swift`): externally-arriving adds
  (opened URLs, drops, the file panel, clipboard) wait until the connection is
  `.connected`/`.failed` — a magnet click that cold-launches the app arrives before
  the handshake, when neither the client nor the default download dir is known —
  then show **one sheet at a time**. The same torrent (keyed on the magnet's btih
  hash, `TorrentLink.identity`) arriving again within 10s is
  dropped (copy-then-click). "Add Magnet or URL…" bypasses the queue.
- **Settings → General**: "Show options when adding torrents" (default on; off =
  add straight to the daemon's default dir, started, with a toast), "Add magnet
  links copied to the clipboard" (default **off**; checked on
  `didBecomeActiveNotification`, gated on `NSPasteboard.changeCount`, never clears
  the clipboard; clipboard links **always** get the sheet — a bare 40-hex string
  may just be a git SHA), and **Magnet links / .torrent files: <app>** rows with a **Make
  Default** button (`NSWorkspace.setDefaultApplication`, acts immediately, not on
  Save; compared by bundle id). Needed because another torrent client may
  already own `magnet:`.
- Verified: cold + warm `open -a <Debug app> magnet:…` shows the sheet with the
  link and the server's folder (Cancelled via AX on prod); sequential sheets +
  repeat suppression; skip-dialog add and clipboard pickup against the Docker
  fixture only.

## Title bar & toolbar layout

`ToolbarLayout` (`AppConfig.toolbarLayout`) is two independent choices: **Title bar**
(`TitleBarStyle` full / hidden) and **Show button labels** (Bool). Settings ▸ General
and the View menu (**Title Bar ▸ Full/Hidden**, **Show Button Labels**) edit them; they
persist as `titleBar` / `toolbarLabels` (legacy `toolbarLayout: "compact"` decodes to
labels off, title kept). `MainWindowController.applyToolbarLayout` is the single owner
of title visibility, toolbar style, and display mode. The decisions (`showsTitle`,
`showsToolTips`) are Foundation-only properties
on `ToolbarLayout` (tested in `ToolbarLayoutTests`); the controller only maps them onto
AppKit:

- Title full → `.expanded` (title row above the toolbar); title hidden → `.unified` (one
  row, labels still draw beneath the icons). Labels off = tooltips.
- **Hiding the toolbar forces the title visible** (a hidden title with no toolbar is a
  blank bar); `observeVisibility` re-applies the layout when the toolbar is shown/hidden.

Behavior no config shows:

- **The setting owns the display mode, but the toolbar can change it.** `NSToolbar`
  autosave persists the mode (`TB Display Mode`) and would override the setting, so
  it's applied after the toolbar attaches. The palette's *Show:* popup and the
  right-click menu stay enabled: a KVO observer on `displayMode` maps icon-only →
  labels off, anything else → labels on and routes it through
  `AppDelegate.setToolbarLayout` like the View menu does. `applyToolbarLayout` sets
  `toolbarLayout` first, so its own mode writes never look like user changes.
- **Never `.unifiedCompact`.** It makes AppKit drop the display-mode controls (palette
  *Show:* popup, right-click Icon and Text / Icon Only), so icon-only could not be undone.
- **Search item:** only the live toolbar item (`willBeInsertedIntoToolbar == true`) may
  set `searchField`; the palette copy would otherwise steal it (placeholder went stale).
- **No window tabbing.** `NSWindow.allowsAutomaticWindowTabbing = false` at launch
  keeps Show Tab Bar / Show All Tabs out of the View menu.
- **Autosave id is `MainToolbar2`**, bumped so saved toolbars gained the dropdown.
  Bump it again when adding a default item; that resets users' customization once.
- **The server dropdown is a plain view item** labelled "Server" like the buttons, so
  AppKit aligns it with them and draws the label when labels are on; no manual offset.
- **The proxy icon is AppKit's.** It appears only with `representedURL` (the
  bundle) and is drawn from the bundle icon's **16pt renditions**
  (`icon_16x16*`, `icon_32x32`), ignoring any image set on the button. Keep those
  renditions matching the large artwork. After changing icon assets, `touch` and
  `lsregister -f` the Debug app to refresh the cached icon. A hand-placed image
  view in the title bar was tried and dropped: it stopped drawing after a layout
  switch even with a correct frame.

## Tests

XCTest unit tests live in `Tests/`, built by the `TransmissionRemoteTests`
target (XcodeGen `bundle.unit-test`). Rather than host the application (which would
launch the real app and connect to the owner's server), the **business-logic
source files are compiled directly into the test bundle**, so tests run standalone
via `xctest` with no `TEST_HOST`.

Coverage (~250 hermetic tests): `FuzzyMatch` (subsequence + ranking), `Formatters`
(size/speed/percent/ratio/eta/dates), `Filtering` (every `StatusFilter` predicate,
tints, `SidebarFilter`), `Models` (status/eta-display/normalizeDownloadDir/
trackerHost/seed-ratio + RPC `torrent-get`/files decoding), **`TorrentFileTree`**
(tree build/grouping, folder aggregates, per-level sort + tie-breaks, in-place
poll merge vs. structural rebuild), **`TorrentPeer`** (peers RPC decoding incl.
omitted-field defaults; per-column sort in both directions, numeric-aware IP
address order, stable address/port tie-breaks), **`TorrentPieces`** (bitfield decoding,
`has`/`haveCount` with padding ignored, `coverage(columns:)` exact/averaged/
spread/straddling cases, `summary`) + **`PieceMapView`** (collapse/expand,
percent label, tooltip), `AppConfig` /
`PreferencesStore` (decode defaults, round-trip, migration, default seeding,
native-store precedence), `ConnectionDiagnostics` (every `TransmissionError` maps
to a field-targeted message), **`SettingsEditor`** (add/remove/edit/default/
refresh, move/reorder, name trim+dedupe, default-follows-rename, dirty detection,
save, reset), **`ServerMenuSync`** (in-place update check, ⌘1–⌘0 key mapping),
**`ToolbarLayout`** (properties, `apply(toolbarLayout:)` style/mode, display-mode round trip, `PopUpEnum`), **`SidebarController`** (counts clear on `update(with: [])`, as on a server switch), **server drag-reorder** (`SettingsWindowController` pasteboard/drop layer),
and **`HostCandidates`/`ConnectionResolver`** (comma- and newline-list parsing
incl. scheme/port/path/IPv6/inheritance + first-reachable failover selection),
and **`PathMapping`** (remote→local exact/prefix mapping, separator guard,
longest-prefix-wins regardless of list order, case-sensitivity; `parse`/`format`
round-trip), and **`TorrentFileRemover`** (Trash / permanent delete of an added
`.torrent`; the settings' decode defaults, round-trip, and survival through
`SettingsEditor` normalize/save), and **`TorrentLink`** (magnet/hash/`.torrent`-URL
recognition, strict vs. loose) plus the `showAddOptions`/`addLinksFromClipboard`
settings' decode defaults, round-trip, and editor plumbing.
Unified Settings adds **`ServerSettingsScopeTests`** (tier mapping and dependency rule, availability, apply plan/order incl. a failed server write keeping every edit, speed absorb, per-server apply/revert/remove-undo in `SettingsEditor`, active-server rename follow) and **`ServerSettingsWindowTests`** (the embedded form against a stub service: controls, Return/Esc, apply order with presets, blocked states + Retry, per-server tab memory, validation focus expanding collapsed groups, layout at minimum size); **`ServerReorderDropTests`** now drive the sidebar.
Cloudflare Access adds **`AccessOAuthTests`** (challenge parsing, metadata checks against real Access documents, the RFC 7636 PKCE vector, request shapes), **`AccessSignInTests`** (the whole flow against stubs via `AccessStub`: stub browser and loopback receiver, no real ports; registration reuse and busy port, Managed OAuth off, untrusted metadata, denied/forged callbacks, timeout, cancel, refresh/rotation, revocation, the loopback request parsing and result page), **`AccessSessionStoreTests`**, **`AccessHeaderSourceTests`** (host scoping, quiet renewal, one shared refresh, ended grant, refused token renewed and retried, refusal classification, messages, reconnect on sign-in), **`AccessSignInControllerTests`** and **`CloudflareAccessTests`**, plus Access cases in `ServerSettingsWindowTests`. The fixture's `/access/…` answers like Managed OAuth (401 Bearer challenge unless `cf-access-token: fixture-access-token`); `/access-legacy/…` like an app with it off (302 to the login page). Custom headers add **`CustomHeadersTests`** (old/new config shapes, values never encoded, validation, `hydrate`/`persist` incl. removed headers and servers; an opt-in real-Keychain round trip behind `TEST_RUNNER_RUN_KEYCHAIN_TESTS=1`), **`RequestHeadersTests`** (headers on the wire incl. the 409 retry, reserved names never clobbering built-ins, runtime sources, host candidates), **`RedirectTests`** (301/302/303/307/308 refused, relative Locations, diagnostics) and header cases in `ServerIdentityTests` and `ServerSettingsWindowTests`. Wire tests use **`StubURLProtocol`** (`Tests/`), which keeps state per host (`uniqueHost()`) so parallel suites don't collide, and sends 3xx replies through URLSession's real redirect handling. **`FixtureProxyTests`** run against an nginx sidecar in the fixture (`scripts/fixture/nginx.conf`, host port **19092**): `/redirect/…` answers 302 to a login page on another host; `/gated/…` forwards to the daemon only with `X-Fixture-Token: fixture-token`; `/access/…` and `/access-legacy/…` mimic Cloudflare Access with and without Managed OAuth (see above).
A `TorrentFactory` helper builds `Torrent` values from a default JSON dict.

```sh
xcodebuild -project TransmissionRemote.xcodeproj -scheme TransmissionRemote \
  -configuration Debug test
```

**Test policy.** The default `xcodebuild test` run is hermetic: it never touches a
daemon and never probes a port, so the same tree gives the same answer on any
machine. Daemon-backed tests are opt-in through their env vars. The one-command
gate for the fixture is `scripts/fixture/run-tests.sh`: it runs the fixture classes
(`FixtureTransmissionTests`, `FixtureConcurrencyTests`, `FixtureFailoverTests`, `FixtureProxyTests`) and
exits non-zero on any skip, so a passing fixture run means every test ran. Skips in
the default run are fine (they are the opt-in gates); a skip in opt-in mode is a
failure. Tests needing local files must generate them, not read `~/Downloads`.

**Live connection tests** (`LiveConnectionTests`) hit the real daemon and are
**skipped by default**. They read credentials from the legacy JSONC at runtime
(never hard-coded) and cover IP/`.local`/Tailscale-HTTPS, multi-host failover
resolution, plus failures (unknown host, wrong password). Note: a host-less test bundle's ATS is governed by the
`xctest` runner (not the bundle's `Info.plist`), so the cleartext-HTTP cases
`XCTSkip` in the runner — those are verified through the app + `curl` instead.
Forward the opt-in env var with the `TEST_RUNNER_` prefix:

```sh
TEST_RUNNER_RUN_LIVE_TRANSMISSION_TESTS=1 xcodebuild ... test \
  -only-testing:TransmissionRemoteTests/LiveConnectionTests
```

**Scripting dictionary tests**: `ScriptingDictionaryTests` (hermetic, always runs) cross-checks
`Resources/TransmissionRemote.sdef` against `Sources/Scripting.swift` by comparing source text
(that file isn't compiled into the test bundle — it depends on `AppDelegate`/`MainWindowController`,
which aren't) — every `cocoa class` the sdef declares must have a matching `@objc(...)` in
`Scripting.swift` and vice versa, catching a renamed/dead command class without launching the app.

**`scripts/test-applescript.sh`** (opt-in, requires a built Debug app + Docker) drives the real
AppleScript dictionary against the fixture daemon: adds the seeded delete-local-data torrent, then
runs `start`/`stop`/`force start`/`verify`/`reannounce`/`set priority`/`rename`/`queue move`/
`set location`/`remove deleting data`, asserting each verb's effect via `torrents whose id is ...`
(not the UI). It launches the Debug app with `-PreferencesPath scripts/fixture/preferences.json`
(an isolated, credential-free preferences file pointed at the fixture's `AppleScriptFixture` server)
so it never reads or mutates the owner's real server list — see `TestIsolation` in `AppConfig.swift`,
which also suppresses the real-`UserDefaults` reads/writes (`SelectedServerName`, the first-run
auto-update prompt, the last-good-host cache) and the launch-time `NSApp.activate` so a run never
steals focus or leaks into the owner's real defaults domain. It does **not** cover the pending-add
queue, the Add-options sheet, or clipboard-magnet pickup — those are triggered by
`didBecomeActiveNotification`/UI flows that the scripted `add` command bypasses entirely; those
remain covered only by the manual verification recipes below.

## Gotchas (learned the hard way — don't regress these)

1. **Use `main.swift`, not `@main`.** `@main` on a bare `NSApplicationDelegate`
   did not install the delegate on this toolchain (window never appeared, no
   config written). The explicit `NSApplication.shared` + `app.run()` entry point
   in `main.swift` is required.
2. **`ENABLE_DEBUG_DYLIB: NO`** in `project.yml` — the explicit entry point needs
   this, or Xcode 16's debug-dylib split fails to link (`_main` undefined).
3. **Don't lay the main UI out with `NSStackView`** — it collapsed the split view
   (and the torrent table inside it) to zero height, so the list didn't show. Use
   explicit Auto Layout constraints (split pinned above a fixed-height status bar).
4. **Outward actions on a live server are real.** Start/stop/rename/move hit the
   owner's production daemon (1000+ torrents). Test against a disposable torrent and
   restore state; get the owner's OK before mutating, and never use broad
   `pkill -f "Transmission Remote"` — it also matches the legacy "Transmission
   Remote GUI" app. Match `pkill -f "Debug/Transmission Remote.app"` instead.

## Verifying changes in the running app

`screencapture` of the screen often returns blank because the window opens on a
different Mission Control **Space**. For **rendering**, capture the window by ID
instead: `screencapture -x -o -l <windowID>` works across Spaces and when covered.
Get the ID from `CGWindowListCopyWindowInfo` (owner PID = the Debug app, layer 0).
To render a given setting without touching the owner's preferences, launch the
Debug binary with `-PreferencesPath` pointing at a scratch copy of
`scripts/fixture/preferences.json` with that key changed (e.g.
`"toolbarLayout": "compact"`).

For **state and behavior**, use the **accessibility tree** (the source of truth
here). Requires accessibility permission for the controlling process.

```applescript
tell application "System Events" to tell process "Transmission Remote"
  -- the torrent table:
  table 1 of scroll area 1 of splitter group 1 of window 1
  -- the toolbar search field:
  text field 1 of (last UI element of toolbar 1 of window 1)
end tell
```

Notes: `entire contents of window 1` **chokes** on the 1041-row tree — drill explicit
paths.

**On macOS 27** the permission is **Privacy & Security ▸ Device Control and Data Access** (formerly Accessibility; deep link `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`). It must be granted to the process macOS holds responsible, which for Claude Code is its bundled helper `~/Library/Application Support/Claude/claude-code/<version>/…/claude.app`, not `/Applications/Claude.app`. There, **System Events can count UI elements but can't fetch them** ("Can't get object"; `entire contents` returns nothing), in both AppleScript and JXA. Use the AX API directly instead (`AXUIElementCreateApplication` with the app's pid, find elements by `AXIdentifier`, `AXPress` buttons, set `AXFocused`, and post key events with `CGEvent.postToPid`). The Settings controls carry identifiers for this (`server-headers-add`, `server-headers-table`, `server-options-apply`, …). Isolated runs (`-PreferencesPath`) don't activate the app, so bring it forward with `NSRunningApplication.activate()` before typing. To drive the search filter in a test, **`set value of <searchField>`** fires
the filter action reliably; `keystroke` into the field is flaky.

**Prefer the AppleScript scripting dictionary** (`Resources/TransmissionRemote.sdef`,
`Sources/Scripting.swift`) over the AX tree above wherever it covers the same ground — it reads
real model state instead of UI internals, so it doesn't break when the view hierarchy changes:

```applescript
tell application id "com.nickvance.transmission-remote-mac"
  -- the torrent list, instead of drilling the table:
  name of every torrent
  -- connection state, instead of reading the status dot:
  connection state
  -- driving the search filter, instead of `set value of <searchField>`:
  set search text to "foo"
end tell
```

Keep the AX tree for what the dictionary can't see: actual rendering, context-menu presence/content,
and menu-item enablement (see `macapp-ax-context-menu-verification` — right-click menus specifically
can't be driven via System Events at all; verify those another way). Note `first item of selection`
does **not** work (`selection` is a plain list property, not an element) — filter `torrents` instead,
e.g. `first item of (torrents whose name is "...")` (see `scripts/test-applescript.sh` for the
pattern used throughout that script).
