# Product

<!-- impeccable:product-schema 1 -->

## Platform

windows

Native Windows desktop application. The implementation uses Rust and NSH, with a native Windows-rendered
interface and no Node or JavaScript runtime. The owner confirmed a full Rust +
NSH rewrite on 2026-10-31. Champion
details use one floating dialog with a single `haidou.pro` tab that opens the
champion's page in WebView2. The main interface and LCU automation remain native.
Windows is recorded explicitly because this application does not fit the skill's
web, iOS, Android, or adaptive platform categories.

## Users

The owner and a small circle of League of Legends players. Optimize for familiar,
frequent use. The existing interface and project documentation are in Chinese;
champion search supports the client's localized names and English aliases.

Audience and scope were confirmed by the owner during initialization on
2026-09-19. Implementation facts below are grounded in the repository.

## Product Purpose

catengar reduces repetitive pre-game interactions so players can keep their
attention on the game. It currently accepts match confirmations when enabled and
selects available preferred champions in supported ARAM/Mayhem sessions.

Success means that saved preferences produce predictable actions, the player can
quickly understand connection and automation state, and routine use needs little
attention after configuration.

## Positioning

A lightweight companion to the League client running on the same Windows PC.
Its current selection mechanism uses an ordered list of the player's own champion
preferences and only upgrades to an available champion with a higher priority.
Players can choose continuous upgrades or stop for the round after the app's
first confirmed automatic selection.
Automation state, champion metadata, and portraits come from the local client.
Champion details additionally display the public Haidou champion page on demand.

## Operating Context

- Open catengar alongside the League client. Connection discovery and recovery
  happen automatically; the interface also offers manual reconnection and an
  administrator retry when needed.
- Search the champion library, add or remove champions, and reorder up to 32
  preferences. Earlier entries have higher priority.
- Only the top-right control on each library card changes selection. A centered
  button below each portrait opens champion details without changing priorities.
  The floating dialog immediately loads the complete
  `https://haidou.pro/champion/{id}/` page in its sole `haidou.pro` tab using
  WebView2. It offers refresh, retry after startup failure, and an action to open
  the page in the default browser. Page traffic is separate from LCU traffic
  and uses no client credentials.
- Match acceptance and champion selection have separate switches. Both start off
  on first run; subsequent launches restore saved preferences.
- The automatic selection switch leads the entire champion panel; preferences
  remain editable while it is off. Directly below it, the checkbox
  "总是按照优先顺序选取英雄" defaults on and saves as `always_prioritize`; old settings
  without that field also default on. Checked means continued priority upgrades;
  unchecked means stopping for the round after a confirmed automatic selection.
  A separate activity log page keeps timestamped
  connection and automation history accessible without crowding the main task.
  Logs persist locally across restarts, cover every historical record through
  pagination, and can be cleared without resetting preferences or cached assets.
- Closing the main window hides it to the system tray and leaves automation
  running. The tray provides restore and full-exit actions. Repeated launches
  restore the existing instance.
- Successful actions produce brief, dismissible application notifications that
  do not take focus, including while the main window is hidden.
- Check the project's published stable GitHub releases automatically after
  startup and periodically, with a passive notice for a newer version. Settings
  offers manual checking and the explicit "更新并重启" action; downloading,
  installing, and restarting require that action. This interaction was chosen
  by the owner on 2026-09-19.
- While connected, the lower-right account area shows the local player's name,
  avatar, complete friend ID with one-click copying, and the current game phase.
  Account details disappear when disconnected; connection progress remains in
  the footer. Game phases and connection health use separate wording.
- Preferences and cached resources remain under
  `%LOCALAPPDATA%\LoLRengar`, preserving the existing storage location after the
  rename to catengar.

## Capabilities and Constraints

### Confirmed direction

More pre-game helper features may be added. Keep the application native to
Windows and its integration local to the League client. The specific additional
features remain undecided; this direction does not make them implemented or
authorize an unrequested feature expansion.

### Existing behavior to preserve

- Automatic match acceptance is independent of champion selection. Automatic
  selection is limited to recognized ARAM/Mayhem queues; unknown modes do not
  trigger selection.
- Selection respects actual availability and the player's ordered preferences.
  A submitted champion request is reported as successful only after the client
  confirms ownership. Contention and failures must not produce false success.
- Continuous selection keeps a higher-priority held champion and can upgrade
  through the bench even after selection is complete. With A before B before C,
  keep A when only B and C are available. When the checkbox is off, stop only
  after an app-submitted selection is confirmed by LCU; manually holding a
  preferred champion or an HTTP 204 alone does not finish the round, and failures
  or confirmation timeouts remain retryable.
- During the same application session, a completed round stays stopped across
  connection loss, theme or priority-list changes, and master-switch toggles.
  Rechecking the policy resumes continuous selection. A verified exit from
  `ChampSelect` or a changed positive 64-bit `gameData.gameId` rearms the next
  round. Completion is runtime state, not a preference saved across app exits.
- Reconnection retains local preferences. Lost connections, permissions problems,
  unavailable resources, and unsupported client behavior need understandable
  states and recovery paths.
- Automation communication and client resources use the local LCU. Authentication
  material stays out of logs and saved settings; client assets have no external
  CDN fallback. The public Haidou webpage is separate and receives no LCU
  credentials. If WebView2 cannot start, the dialog explains the Runtime
  requirement and offers retry and the external browser action. Unavailable
  portraits or the external webpage must not prevent configured selection
  behavior.
- The current app does not initiate queueing, spend rerolls, request teammate
  trades, configure runes automatically, or perform in-game actions. These are
  current boundaries, not a permanent rejection of future pre-game helpers.
- Runtime use is through a portable executable. Development and first-time
  dependency downloads are separate from the player's runtime requirements.
- Updates require a user-writable portable application directory and use the
  embedded engine through built-in Windows PowerShell, without updater UAC,
  Node, or Python. Only verified, newer stable release packages from the project
  repository are eligible; drafts and prereleases are excluded. Older builds
  without the updater need one manual installation to gain this capability.
- Update installation waits through matching, selection, gameplay, and unknown
  connected phases, with a separate game-process guard. It preserves preferences,
  cached assets, and logs. File replacement or relaunch failures attempt recovery
  and report failures honestly rather than promise unconditional rollback.
- Preserve existing preference compatibility, Chinese input support, immediate
  theme switching, and responsiveness while loading the champion library.

## Brand Commitments

The existing product name is `catengar`; the interface identifies it as
`League 助手`. Current Chinese copy is brief and task-oriented. The shipped feline
icon is `assets/catengar-icon.png`, with Windows icon sizes in
`assets/catengar.ico`.

These are the incumbent identity and assets. No additional binding aesthetic
direction was established during initialization.

## Evidence on Hand

- `README.md`: documented workflows, automation boundaries, local storage,
  connection behavior, build instructions, and verification commands.
- `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `.cargo/config.toml`:
  pinned Rust/NSH dependencies and portable x64 build configuration.
- `src/ui.rs`, `src/platform.rs`: NSH components, five palettes, native windows,
  tray, notifications, WebView2 detail lifecycle and Windows accessibility.
- `src/model.rs`, `src/engine.rs`, `src/service.rs`, `src/transport.rs`:
  preference rules, confirmed selections, round state, local client automation,
  resource caching, event reconciliation and connection recovery.
- `src/auth.rs`, `src/auth_discovery.ps1`: authentication discovery and private
  elevated helper protocol; credentials are excluded from diagnostics.
- `src/storage.rs`, `src/journal.rs`: compatible settings and persistent logs.
- `src/updater.rs`, `src/updater.ps1`, `.github/workflows/`:
  explicit update consent, stable-release validation, game protection,
  replacement, recovery and pre-release publishing.
- `assets/catengar-icon.png`, `assets/catengar.ico`: retained application identity.
- `tests/`, `scripts/test-*`, `scripts/test_release.py`: offline regression
  fixtures; validation results belong to the specific build, not this brief.

## Product Principles

1. Make repeated use quick for players who already know the tool.
2. Let explicit player preferences govern automation; keep controls and current
   state understandable.
3. Report outcomes truthfully and recover without losing the player's setup.
4. Stay unobtrusive while working in the background; respect game focus.
5. Expand pre-game usefulness while preserving the native, local foundation.

## Open Decisions

- Which additional pre-game helpers, if any, should be built next.
- Any broader distribution audience, additional interface languages, or
  product-specific accessibility requirements beyond the existing implementation.
