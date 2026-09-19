# Product

<!-- impeccable:product-schema 1 -->

## Platform

windows

Native Windows desktop application. The existing implementation uses Zig and
vercel-labs/native, with a GPU-rendered interface and no WebView, Node, or browser
runtime. Preserve the native, local architecture. Windows is recorded explicitly
because this application does not fit the skill's web, iOS, Android, or adaptive
platform categories.

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
Game data and portraits come from the local client.

## Operating Context

- Open catengar alongside the League client. Connection discovery and recovery
  happen automatically; the interface also offers manual reconnection and an
  administrator retry when needed.
- Search the champion library, add or remove champions, and reorder up to 32
  preferences. Earlier entries have higher priority.
- Match acceptance and champion selection have separate switches. Both start off
  on first run; subsequent launches restore saved preferences.
- The automatic selection switch leads the entire champion panel; preferences
  remain editable while it is off. A separate activity log page keeps timestamped
  connection and automation history accessible without crowding the main task.
  Logs persist locally across restarts, cover every historical record through
  pagination, and can be cleared without resetting preferences or cached assets.
- Closing the main window hides it to the system tray and leaves automation
  running. The tray provides restore and full-exit actions. Repeated launches
  restore the existing instance.
- Successful actions produce brief, dismissible application notifications that
  do not take focus, including while the main window is hidden.
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
- Reconnection retains local preferences. Lost connections, permissions problems,
  unavailable resources, and unsupported client behavior need understandable
  states and recovery paths.
- Communication and game resources use the local LCU. Authentication material
  stays out of logs and saved settings; champion resources have no external CDN
  fallback. Unavailable portraits must not prevent configured selection behavior.
- The current app does not initiate queueing, spend rerolls, request teammate
  trades, configure runes automatically, or perform in-game actions. These are
  current boundaries, not a permanent rejection of future pre-game helpers.
- Runtime use is through a portable executable. Development and first-time
  dependency downloads are separate from the player's runtime requirements.
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
- `app.zon`, `build.zig.zon`: Windows application manifest and existing native
  stack.
- `src/app.native`, `src/main.zig`, `src/titlebar.zig`, `src/toast.native`:
  implemented interface, status copy, window behavior, and notifications.
- `src/types.zig`, `src/logic.zig`, `src/service.zig`, `src/settings.zig`:
  preference limits, selection rules, automation, and persistence.
- `src/theme.zig`, `src/font.zig`, `src/ime.zig`: existing appearance options,
  Chinese font loading, and Windows input-method integration.
- `assets/catengar-icon.png`, `assets/catengar.ico`: shipped application identity.
- `src/tests.zig`, `src/transport_test.zig`, `src/native_image_test.zig`:
  repository verification assets; their presence is not a claim that they were
  run during this documentation task.

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
