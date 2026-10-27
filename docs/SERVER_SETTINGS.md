# Server Settings

Server settings live in the one **Settings** window (⌘,), under each server in the sidebar. Open the active server's settings with the **Server Settings** toolbar button (after Speed Limits) or **Server → Server Settings…** (⌥⌘,); both open the tab you used last for that server. **Server → Manage Servers…** opens its Connection tab, and **Edit Presets…** in the speed menus opens its Speed tab with the presets focused. Any server can be edited, not only the active one; a server other than the active one connects with its own client and is labelled "Not the active server".

The server tabs expose 50 writable session fields in Transmission 4.1.4, including the deprecated µTP fallback. Blocklist management is deliberately excluded because RPC cannot remove downloaded rules. Older servers keep supported controls; missing capabilities are disabled.

| Tab | Stored | Controls |
| --- | --- | --- |
| Connection | this Mac | Name, hosts (fallback list), port, HTTPS, RPC path, credentials, path mappings |
| Transfers | server | Default folder and automatic start; seeding ratio and idle limits; download/seeding queues. Collapsed: incomplete-files folder, `.part` naming, sequential download, stalled torrents |
| Speed | server + this Mac | Regular limits and turtle-mode limits; **Menu presets** (this Mac). Collapsed: schedule, bandwidth groups (**Manage Groups…**) |
| Network | server | Peer port, random port, port forwarding, **Test Incoming Port**. Collapsed: encryption, peer limits |
| Advanced | server | Peer discovery (PEX, DHT, LPD, transports/µTP), watch-folder .torrent disposal, cache and request queue, RPC brute-force protection. Collapsed: default trackers, server scripts |

Every group heading is tagged **Stored on the server** (shared by every client of that daemon) or **Stored on this Mac**. Essential settings sit at the top of each tab; common groups below them start collapsed, as do Default trackers and Server scripts on the Advanced tab. Groups remember whether they're open. A setting always shares its group with the setting it depends on.

Paths refer to the server's filesystem. Changing the download folder does not move torrents. Script paths refer to existing server files; the app neither uploads nor executes scripts. Default trackers use one URL per line and blank lines between tiers. Schedules follow the server's time zone and support overnight intervals. Speeds use decimal kB/s; cache uses MiB.

The per-add Start choice overrides the server's automatic-start default (a caption cross-references General ▸ "Show options when adding torrents"). Server watch-folder disposal is distinct from this Mac's local .torrent removal setting, and the two captions say so. Modern transport preferences replace the deprecated µTP checkbox when available; the two setters are never sent together by the editor.

## Editing and saving

- **One Apply and one Revert per server.** They cover the Connection tab, the presets and the server tabs together. General has no Apply: its controls apply immediately and never mark a server as edited.
- **Apply order.** The server-side changes go first: validate, check current values for conflicts, send a sparse `session-set`, verify the readback. Only after that succeeds are the Mac-side fields saved (which may reconnect and rebuild the Server menu). If the server write fails or needs a Reload, nothing is saved locally and every edit is kept. After an Apply, the toolbar speed pull-down and Server ▸ Speed Limits refresh.
- **Unsaved edits** show a dot on the server's row and in the window's close button. Switching tabs keeps edits. Selecting another row, adding a server, closing (⌘W) or quitting asks **Apply / Discard / Cancel**. Opening Settings from a menu while it's already open only changes the selection; it never discards edits.
- **Return** commits the focused field and never applies; **Esc** does nothing special. Apply and Revert have no key equivalents.
- **Reload** (server tabs) loads the server's current values again, asking first if server-tab edits would be lost. Values load when a server is first selected, never from the poll — except that the Speed fields follow limits changed from the speed menus when they have no unsaved edits. If they do, the status line says the limits changed on the server; Reload, and the conflict check blocks a stale Apply meanwhile.
- **Blocked states.** A new server shows "Apply the connection first" until it's saved. While connecting the tabs show a spinner; when unreachable, "Can't reach <server>" with **Retry** and **Test Connection**. The Mac-side presets stay editable throughout.
- **The server list.** Drag rows to reorder, **+** to add, **−** to remove (Edit ▸ Undo puts it back), right-click ▸ **Make Default**. These apply immediately.
- An uncertain response, rejected value or failed readback requires **Reload** before another server-side save. RPC has no atomic compare-and-swap; edits by another client between preflight and write remain possible.
- Unknown future encryption/transport values remain unchanged until explicitly edited. Capabilities use returned fields and RPC version metadata, not the daemon's product version string.
- **Keyboard and VoiceOver.** ↑/↓ move through the sidebar and Ctrl-Tab / Ctrl-Shift-Tab through the tabs (⌘1–⌘0 still switch servers). Rows read e.g. "N5, server, connected, default, edited"; scope tags are accessibility help; Apply results are announced; a validation error opens the field's group and focuses it.
- The window is resizable (minimum 760×560) and remembers its frame (`SettingsWindow2`), selection, per-server tab and open groups.

## Groups and diagnostics

**Manage Groups…** (Speed tab) opens the bandwidth groups editor as a sheet over Settings: named groups, download/upload limits and whether they honor session limits. **Apply Group** is its own save boundary with conflict checks, sparse writes and verified readback; **Done** closes the sheet. Group creation is explicit; Transmission has no group rename/delete RPC. Assign or clear a group for selected torrents using **Torrent → Bandwidth Group…** or the torrent context menu.

Port tests check the server's currently applied incoming port, regardless of unsaved edits. Automatic tests retain compatibility with older servers; explicit IPv4/IPv6 requires RPC 6.0 / Transmission 4.1 or newer. Missing results and request errors are never reported as a closed port.

A closed incoming port means the daemon's external test could not reach it. It does not mean this app cannot connect, or prove VPN failure.

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

`ServerSettingsScopeTests` cover the tier mapping (every field has one tab, tier and group; no dependent field is more hidden than its parent), availability, the apply plan and its order (a failed server write saves nothing locally and keeps every edit), poll-absorbed speed values, and per-server apply/revert in `SettingsEditor`. `ServerSettingsWindowTests` drive the embedded form against a stub service: controls, dependencies, Return/Esc, apply order with presets, blocked states and Retry, remembered tabs, group expansion on validation errors, and light/dark layout at the minimum size. `ServerReorderDropTests` cover dragging rows in the sidebar.

Native arrow/Space navigation requires a foreground application. That check runs in the standalone helper and is explicitly skipped in the background-only Xcode test host.

To look at the window without driving the UI, launch the Debug binary with an isolated preferences file and `-OpenSettings general|connection|transfers|speed|network|advanced` (honored only together with `-PreferencesPath`).
