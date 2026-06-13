# Transmission Remote (native macOS) — Feature Backlog

Candidate features beyond the current MVP, drawn from features you've explicitly
asked for plus features that exist in the legacy Pascal app (`../*.pas` / `*.lfm`)
and could be ported. **Rank these to decide what to tackle next.**

Status today (done): connect to one server, live torrent list with progress,
sortable columns, start/stop/force-start, rename, move, basic detail pane,
name search/filter.

Each item notes the underlying Transmission RPC method(s) and/or the legacy source
file, and a rough size (S/M/L).

---

## A. Explicitly identified

- [ ] **Fuzzy / subsequence search matching** — alternate match mode for the search
  box (e.g. `ppgrl` → papergirls), with ranking by match quality. Extends the
  current exact-substring filter near `rebuildDisplayed()`. _(S–M)_

---

## B. Torrent actions (per-torrent, build on the existing toolbar/menu)

- [ ] **Remove torrent** — with and without deleting local data; confirmation
  sheet. `torrent-remove` (`delete-local-data`). _(S)_
- [ ] **Verify / recheck local data** — `torrent-verify`. _(S)_
- [ ] **Reannounce (ask tracker for peers now)** — `torrent-reannounce`. _(S)_
- [ ] **Queue management** — move to top / up / down / bottom; show queue position.
  `queue-move-top|up|down|bottom`. _(S–M)_
- [ ] **Labels** — view/add/remove labels on a torrent. `torrent-set` `labels`. _(M)_
- [ ] **Per-torrent speed limits** — down/up KB/s caps. `torrent-set`
  `downloadLimit(ed)` / `uploadLimit(ed)`. _(M)_
- [ ] **Per-torrent seed-ratio limit** — `torrent-set` `seedRatioLimit` /
  `seedRatioMode`. _(S–M)_
- [ ] **Bandwidth priority** — high / normal / low. `torrent-set`
  `bandwidthPriority`. _(S)_

## C. Add torrents (was out of MVP scope; major feature)

- [ ] **Add via .torrent file** — open panel + options sheet. `torrent-add`. _(M)_
- [ ] **Add via magnet / URL** — paste box. `torrent-add` (legacy `addlink.pas`). _(S–M)_
- [ ] **Drag-and-drop / Dock drop** — drop `.torrent` files or magnet links onto
  the window or app icon. _(M)_

## D. Detail pane — richer tabs (legacy: General / Trackers / Peers / Files)

- [ ] **Files tab** — per-file list with size, %, and priority; mark files
  wanted/unwanted (skip). `torrent-set` `files-wanted` / `files-unwanted` /
  `priority-high|normal|low`. _(L)_
- [ ] **Peers tab** — connected peers: address, client, %, up/down. _(M)_
  - [ ] Optional: country flags via GeoIP (legacy `GeoIP.pas` + `flags/`). _(M)_
- [ ] **Trackers tab** — list trackers + status; add/edit/remove. `torrent-set`
  `trackerAdd` / `trackerReplace` / `trackerRemove`. _(M)_
- [ ] **General tab polish** — comment, full dates, error detail, and a small
  up/down speed graph (legacy has live speed graphs). _(M)_

## E. Organize / view

- [ ] **Sidebar filter groups** — filter by status (downloading / seeding /
  active / inactive / stopped / error / queued), by tracker, by label, by
  download directory (legacy `filtering.pas`). _(L)_
- [ ] **Column customization** — show/hide/reorder columns; add columns like Size,
  Added date, Queue position, Tracker, Ratio limit, Labels (legacy `colsetup.pas`).
  _(M)_
- [ ] **Group/aggregate status bar** — counts per filter group. _(S)_

## F. Server / session-wide

- [ ] **Alternative speed limits (turtle mode)** — one-click global throttle toggle
  in the toolbar. `session-set` `alt-speed-enabled`. _(S)_
- [ ] **Daemon settings editor** — global down/up limits, ports, peer limits,
  seed-ratio default, blocklist, turtle schedule. `session-get` / `session-set`
  (legacy `daemonoptions.pas`). _(L)_
- [ ] **Session stats** — cumulative up/down, ratio, uptime. `session-stats`. _(S)_
- [ ] **Free-space display** — show free space for the download dir. `free-space`. _(S)_
- [ ] **Port test / blocklist update** — `port-test`, `blocklist-update`. _(S)_

## G. Connection / config

- [ ] **Multiple connection profiles** — switch between servers (legacy
  `connoptions.pas`). _(M)_
- [ ] **Keychain for credentials** — move password out of the plaintext config
  (already flagged in `AppConfig`/config template). _(S–M)_
- [ ] **Local↔remote path mapping** — translate a locally-mounted share path to the
  daemon's path for Move (legacy `connoptionspathsframe.pas`; noted in the port
  plan as a future enhancement). _(M)_
- [ ] **Proxy / HTTPS client-cert support** — (legacy `connoptionsproxyframe.pas`). _(M)_

## H. macOS-native niceties

- [ ] **Completion notifications** — native `UNUserNotification` when a torrent
  finishes. _(S)_
- [ ] **Menu-bar (status item) summary** — up/down speed + counts in the menu bar. _(M)_
- [ ] **Pause-on-hidden already done; persist window/column state** — _(S)_
- [ ] **Distribution** — code-sign (Developer ID), notarize, build a DMG. _(M)_
- [ ] **Localization** — (legacy ships many `lang/` files; low priority for personal
  use). _(L)_
