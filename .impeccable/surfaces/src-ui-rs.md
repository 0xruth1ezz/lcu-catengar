---
version: 1
slug: "src-ui-rs"
primary_target: "src/ui.rs"
related_targets: ["src/platform.rs"]
---

# Current-round pick control

Mode: Operate. Extend the established native Windows interface with a small control used beside League champion selection. The user specified right-center placement, dragging, topmost visibility, and a toggle that affects only this game.

## Direction contract

THESIS: One persistent, local pause/resume action lets the player keep a satisfactory champion without reopening the main window.

OWN-WORLD: Inherit Catengar's selected palette, Microsoft YaHei UI, compact rounded buttons, and visible text states. Preserve DESIGN.md and the existing main surface.

STORY: Enter selection, see whether automation is enabled, pause or enable it, and drag the button itself out of the way. The next round inherits saved settings. Closing champion changes removes the control.

FIRST VIEWPORT: One 168 by 44 logical-pixel button at the current monitor's right center. No panel, title bar, or secondary copy. Its action label includes the current-round scope. Enabled and paused states use text as well as palette roles. It appears without taking focus.

FORM: Precisely specified local extension; no concept seed or new visual world. Native button popup with a movement threshold separating dragging from activation; saved position is clamped to available monitors.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance
