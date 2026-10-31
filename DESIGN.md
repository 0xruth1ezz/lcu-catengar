---
name: "Catengar"
description: "Observed native Windows interface for the Chinese League client helper; incumbent identity preserved."
colors:
  classic-bg: "#0a0a0a"
  classic-surface: "#171717"
  classic-subtle: "#262626"
  classic-border: "#393939"
  classic-text: "#fafafa"
  classic-muted: "#a1a1a1"
  classic-accent: "#d6b773"
  classic-on-accent: "#181715"
  classic-danger: "#ff6467"
  chatgpt-dark-bg: "#171717"
  chatgpt-dark-surface: "#212121"
  chatgpt-dark-subtle: "#303030"
  chatgpt-dark-border: "#4a4a4a"
  chatgpt-dark-text: "#f5f5f5"
  chatgpt-dark-muted: "#b4b4b4"
  chatgpt-dark-accent: "#ffffff"
  chatgpt-dark-on-accent: "#171717"
  chatgpt-dark-danger: "#ff8080"
  chatgpt-light-bg: "#f7f7f8"
  chatgpt-light-surface: "#ffffff"
  chatgpt-light-subtle: "#eeeeef"
  chatgpt-light-border: "#d0d0d5"
  chatgpt-light-text: "#202123"
  chatgpt-light-muted: "#606067"
  chatgpt-light-accent: "#202123"
  chatgpt-light-on-accent: "#ffffff"
  chatgpt-light-danger: "#b42318"
  nord-bg: "#2e3440"
  nord-surface: "#3b4252"
  nord-subtle: "#434c5e"
  nord-border: "#5a657c"
  nord-text: "#eceff4"
  nord-muted: "#d8dee9"
  nord-accent: "#88c0d0"
  nord-on-accent: "#2e3440"
  nord-danger: "#e58e97"
  catppuccin-bg: "#181825"
  catppuccin-surface: "#1e1e2e"
  catppuccin-subtle: "#313244"
  catppuccin-border: "#585b70"
  catppuccin-text: "#cdd6f4"
  catppuccin-muted: "#a6adc8"
  catppuccin-accent: "#cba6f7"
  catppuccin-on-accent: "#1e1e2e"
  catppuccin-danger: "#f38ba8"
  window-close: "#ff5f57"
  window-minimize: "#febc2e"
  window-maximize: "#28c840"
  dialog-scrim: "#00000099"
typography:
  heading:
    fontFamily: "Microsoft YaHei UI"
    fontSize: "20px"
    fontWeight: 600
  body:
    fontFamily: "Microsoft YaHei UI"
    fontSize: "14px"
  label-medium:
    fontFamily: "Microsoft YaHei UI"
    fontSize: "14px"
    fontWeight: 500
  label-strong:
    fontFamily: "Microsoft YaHei UI"
    fontSize: "14px"
    fontWeight: 600
  muted:
    fontFamily: "Microsoft YaHei UI"
    fontSize: "12px"
rounded:
  control: "7px"
  panel: "12px"
  traffic: "8px"
  switch-thumb: "9px"
spacing:
  row-inset: "4px"
  tile: "5px"
  priority-gap: "8px"
  compact: "8px"
  control-gap: "10px"
  regular: "12px"
  panel-gap: "16px"
  section: "16px"
  champion-panel: "20px"
  page-panel: "20px"
  shell: "24px"
  dialog: "28px"
components:
  button-standard:
    backgroundColor: "{colors.classic-subtle}"
    textColor: "{colors.classic-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0px 12px"
    height: "36px"
  button-compact:
    backgroundColor: "{colors.classic-subtle}"
    textColor: "{colors.classic-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0px"
    width: "28px"
    height: "36px"
  button-surface:
    backgroundColor: "{colors.classic-surface}"
    textColor: "{colors.classic-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0px 12px"
    height: "28px"
  search-input:
    backgroundColor: "{colors.classic-surface}"
    textColor: "{colors.classic-text}"
    typography: "{typography.body}"
    rounded: "{rounded.control}"
    padding: "0px 12px"
    height: "36px"
  page-panel:
    backgroundColor: "{colors.classic-surface}"
    rounded: "{rounded.panel}"
    padding: "{spacing.page-panel}"
  champion-panel:
    backgroundColor: "{colors.classic-surface}"
    rounded: "{rounded.panel}"
    padding: "{spacing.champion-panel}"
  switch-on:
    backgroundColor: "{colors.classic-accent}"
    rounded: "{rounded.panel}"
    padding: "3px"
    width: "42px"
    height: "24px"
  switch-off:
    backgroundColor: "{colors.classic-border}"
    rounded: "{rounded.panel}"
    padding: "3px"
    width: "42px"
    height: "24px"
  portrait-library:
    backgroundColor: "{colors.classic-subtle}"
    rounded: "{rounded.control}"
    size: "76px"
  about-dialog:
    backgroundColor: "{colors.classic-surface}"
    rounded: "{rounded.panel}"
    padding: "{spacing.dialog}"
    width: "440px"
---

# Design System: Catengar

## Overview

**Creative North Star: not established.** This document records the coherent
incumbent interface preserved in the full Rust + NSH rewrite. It does not select
a new visual metaphor, mood, or brand direction. Qualitative brand language and
visual anti-references remain unconfirmed.

The native Windows interface uses compact Chinese controls, rounded tonal
panels, champion portraits, and a persistent connection footer. The feline
application icon and the names `Catengar` and `League 助手` retain the identity
recorded in [PRODUCT.md](PRODUCT.md). Five themes change the palette while
keeping the same component shapes and hierarchy.

The 2026-10-31 Hallmark refinement follows the owner's practical, compact
direction. `src/theme.rs` owns the shared palette, font, spacing, and sizing
tokens; `src/ui.rs` composes the native controls. Before/after captures under
`.hallmark/review/` use seven real locally cached champions in an isolated
offline profile. This is not evidence of a live client connection. Earlier
`.impeccable/review/` images document the previous layout. The floating Haidou
page is external content and does not define this application's visual system.

**Key Characteristics:**

- One Chinese UI font with a small heading, body, and metadata hierarchy.
- Tonal background, panel, and control layers shared by five palettes.
- Compact rectangular actions with rounded corners and visible focus outlines.
- Portraits and ordered rows carry champion information.
- A restrained native shell with three colored window controls.

## Colors

The frontmatter preserves each palette's actual source roles. The prefix names
are stable internal theme identifiers; the suffixes match the implementation. Hex values
are the direct RGB values from `Colors`, not a newly constructed palette.

### Primary

Each theme's `accent` is its primary state color: warm gold in Classic, white
in OAI 深色, dark ink in OAI 浅色, pale cyan in Nord, and pale mauve in
Catppuccin. It marks enabled switches, checked policy controls, selected theme
borders, the details source label, and focus outlines. `on-accent` is the
contrasting content used over that accent. The general action button retains
the `subtle` fill; it is not automatically an accent-filled CTA.

### Neutral

`bg` fills the main window, `surface` fills the title bar and main panels,
`subtle` fills controls and portrait fallbacks, and `border` separates content.
`text` carries primary labels; `muted` carries counts, supporting instructions,
version information, timestamps, and connection details.

### Status and fixed chrome

`danger` is theme-specific and carries settings warnings and failed log entries.
Connection status is stated in text in the footer.
The red, amber, and green window controls retain their fixed colors in all
themes. `dialog-scrim` dims the underlying app when About is open.

**The Theme Roles Rule.** Resolve every normal surface, text, border, and state
color through the selected palette. Fixed window controls are the observed
exceptions.

The frontmatter component examples use Classic, the current default. Their
palette roles translate directly to any other theme; those references do not
make Classic mandatory. No generated tonal ramp is a shipping token.

## Typography

The shell, detail window, and toast set **Microsoft YaHei UI**. No separate
display font, monospaced family, custom letter spacing, or explicit shared
line-height is established. Native text rendering supplies unspecified metrics.

- `heading` is used for the app and page headings.
- `body` is used for action labels, champion names, and prose.
- `label-medium` emphasizes switch labels, the title-bar name, and toast content.
- `label-strong` identifies subsections such as the library and priority list.
- `muted` is the smaller supporting-text role.

Keep Chinese labels brief and task-oriented. Priority names occupy one line;
long supporting or diagnostic content belongs in the available scrolling region.
The chosen font family is an implementation fact; fallback policy has not been
separately specified.

## Layout

The main native window opens at 1120 by 800 logical units and has a 880 by 720
minimum, scaled by Windows DPI. There is no mobile layout or browser breakpoint
system. The title bar is 40 units high. A 24-unit padded shell, capped at 1360
units and centered, stacks the page heading, persistent Heroes/Logs/Settings
navigation, page content, and connection footer. Primary content expands to use
remaining space and owns its scrolling.

Home places the automatic-selection, match-acceptance, and selection-policy
controls in one toolbar above two peer panels. The flexible champion library
sits beside a 300-unit priority column with a 16-unit gap. Library columns are
calculated in 104-unit increments, between two and eight columns; the virtual
row estimate is 144 units. Champion names stay visible below the portraits.
Both panels scroll independently. Settings align categories on the left with
their controls on the right, separated by rules; theme choices wrap when needed.
Logs align local time, event type, and message columns below one toolbar.

Spacing is a collection of observed values, not a fabricated strict grid. Use
the frontmatter's shell, section, panel, and compact spacing roles in their
corresponding contexts. A layout change must preserve independent scrolling,
accessible controls at the native minimum size, and room for the footer.

The detail window opens at 960 by 740 logical units. Its native header contains
the champion name and refresh, external-browser, and close actions above the
embedded page. External-page layout and responsiveness remain owned by Haidou.

## Elevation & Depth

The application defines no reusable shadow vocabulary. Depth comes from tonal
layers, rounded containment, thin separators, and the About scrim. The dialog
uses a surface fill above that scrim. Any operating-system window shadow or
capture cursor highlight is not an application token.

No custom motion duration or easing vocabulary is established. Button hover
and press change opacity; the switch thumb changes position with its state.
Do not infer an animation standard from a static screenshot.

## Shapes

Controls, portraits, and inputs share the `control` radius; large panels and the
About dialog share `panel`. Switches are compact pills with a circular thumb.
Window controls are circles. Portraits crop to their rounded box with cover
fitting, and absent images show the first two name characters on a subtle fill.
Thin separators organize sections without adding decorative frames to every
container.

## Components

### Buttons and navigation

The standard button uses the subtle fill, body label, and the frontmatter's
control dimensions. Hover opacity is 0.8, pressed opacity is 0.65, and disabled
opacity is 0.35. A focused button has a two-unit accent outline offset by two
units. Disabled state must remain distinguishable from focus or selection.

Compact priority actions inherit the same treatment. The library's top-right
add/remove control is 28 units square; its checked glyph changes with selection.
The centered `查看` action uses the surface variant below the portrait.
Persistent `英雄`, `日志`, and `设置` navigation uses the same control shape;
the current destination has a subtle fill and selected accessibility state.
Escape returns to Heroes, or closes About when it is open.

### Search field

The search field uses the surface fill, control radius, body text, muted
placeholder and border, and accent caret. It fills the library column, with an
instant two-unit accent focus outline. Typing filters the real champion names
and aliases and resets the virtual list to its top.

### Switch and policy checkbox

The switch's label and pill form one focusable target at least 44 units high.
On uses `accent` with an
`on-accent` thumb; off uses `border` with a `muted` thumb. The thumb is 18 units
square and moves 18 units between states. Switches and the policy checkbox use
the same accent focus outline as buttons. The checkbox preserves its visible
Chinese label and checked glyph; state is not communicated through color alone.

### Theme choices

The five existing theme names are shown as ordinary buttons. A one-unit border
uses `accent` for the selected theme and `border` otherwise. Changing the theme
updates the existing UI immediately; the selected treatment does not introduce
a new component shape or typography.

### Panels, champion tiles, and priority rows

Panels provide surface containment. The library tile gives the portrait, the
separate add/remove control, and `查看` distinct targets. Preserve that separation
when extending tile content. Priority rows use a two-digit muted rank, a
36-unit portrait, a one-line name, and compact up/down/remove actions. First and
last reorder actions visibly disable where movement is unavailable.

The round-only automatic-selection control remains a standalone draggable
168-by-44 topmost button. It has no surrounding panel or title bar; main-window
navigation and layout do not affect its visibility or round-scoped behavior.

### About, detail window, and notifications

About centers a fixed-width rounded surface with heading, short explanation,
version/author metadata, and full-width actions over the scrim. The native detail
window keeps its own controls outside the embedded web page. Loading and failure
messages use the same body/supporting-text hierarchy. Toast content also inherits
the app font and palette, with a compact title and close action.

The HTML/CSS entries in the sidecar are documentation previews of native
components. They are not a second implementation and do not establish Windows
keyboard behavior, dialog focus management, WebView2 behavior, or accessibility
conformance. Source and runtime validation remain necessary for those properties.

## Do's and Don'ts

### Do:

- **Do** preserve the feline icon, existing Chinese identity, and five named themes.
- **Do** resolve native UI colors through the selected theme's established roles.
- **Do** keep metadata subordinate through the smaller muted text role.
- **Do** keep library selection and champion-details actions as separate controls.
- **Do** retain a visible accent focus outline on custom focusable controls.
- **Do** validate scrolling and control visibility at the native minimum size.

### Don't:

- **Don't** introduce a new visual metaphor or brand voice as an extraction fact.
- **Don't** style the app from the embedded Haidou page or offline fixture portraits.
- **Don't** invent shadows, motion tokens, or mobile breakpoints absent from the source.
- **Don't** treat documentation previews as proof of native keyboard or accessibility behavior.
