# NSH Windows backend (local keyboard fix)

Upstream: https://github.com/longbridge/nsh, commit `a5036af48ddc193b5023ece9b9196c76b8f8d3f5` (0.3.0).
Licensed under Apache-2.0; the original license is in LICENSE.

Catengar vendors only the Windows backend. Core, engine and components still use
that pinned upstream revision. Cargo.toml expands the upstream workspace values
without changing dependency features. Source changes are limited to input.rs,
access.rs and mount.rs. The upstream test font and OFL are copied into tests/fonts;
text.rs changes only its test include path:

- Tab/Shift+Tab visit visible enabled controls and fields in the active modal scope.
- Generic controls receive focus/blur events, focus styles and UI Automation focus.
- Enter/Space activate the focused control once, with repeat and modal guards.
- Mouse focus and programmatic focus use the same state and scroll controls into view.

The input module includes regression cases for traversal, disabled/hidden controls,
explicit opt-out and scoped traversal. Run `cargo test -p nsh-platform-windows --lib input::tests::keyboard`.
Remove this override when upstream provides equivalent Windows keyboard support.
