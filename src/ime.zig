const std = @import("std");
const native = @import("native_sdk");
const win = @import("windows.zig");
const c = win.c;

/// The canvas owns text editing; IMM/TSF still need a real Win32 caret and
/// candidate anchor on its focused HWND. All calls stay on the UI thread.
pub const Bridge = struct {
    hwnd: c.HWND = null,
    active: bool = false,
    caret_owned: bool = false,
    caret: c.RECT = std.mem.zeroes(c.RECT),

    pub fn sync(self: *Bridge, runtime: *const native.Runtime, frame: native.platform.GpuFrame) void {
        if (!std.mem.eql(u8, frame.label, "main-canvas")) return;
        if (self.hwnd == null) {
            const main = win.mainWindow() orelse return;
            const hwnd = c.FindWindowExW(main, null, std.unicode.utf8ToUtf16LeStringLiteral("NativeSdkGpuSurface"), null) orelse return;
            if (c.SetWindowSubclass(hwnd, windowProc, 1, @intFromPtr(self)) == 0) return;
            self.hwnd = hwnd;
        }
        if (c.GetFocus() != self.hwnd) {
            self.deactivate();
            return;
        }
        const nodes = runtime.canvasWidgetSemantics(frame.window_id, frame.label) catch return;
        const focused_id = focusedWidget(runtime, frame);
        for (nodes) |node| {
            if (node.role != .textbox or node.id != focused_id or node.state.disabled) continue;
            const geometry = runtime.canvasWidgetTextGeometry(frame.window_id, frame.label, node.id) catch continue;
            const bounds = geometry.caret_bounds orelse geometry.selection_bounds orelse node.bounds;
            const rect = caretRect(bounds, node.bounds, c.GetDpiForWindow(self.hwnd));
            const changed = !std.meta.eql(self.caret, rect);
            if (!self.active) {
                self.active = true;
                // Restore the thread's default context; do not create a separate
                // context or change the user's input language/conversion mode.
                _ = c.ImmAssociateContextEx(self.hwnd, null, c.IACE_DEFAULT);
            }
            if (changed or !self.caret_owned) {
                const resized = self.caret.bottom - self.caret.top != rect.bottom - rect.top or self.caret.right - self.caret.left != rect.right - rect.left;
                self.caret = rect;
                if (resized) self.destroyCaret();
                self.position();
            }
            return;
        }
        self.deactivate();
    }

    fn caretRect(bounds: native.geometry.RectF, field: native.geometry.RectF, dpi: c.UINT) c.RECT {
        const scale = @as(f32, @floatFromInt(@max(96, dpi))) / 96;
        const inset = @min(4, field.width / 2);
        const x = std.math.clamp(bounds.x, field.x + inset, field.x + field.width - inset);
        const y = std.math.clamp(bounds.y, field.y, field.y + field.height);
        return .{
            .left = @intFromFloat(@round(x * scale)),
            .top = @intFromFloat(@round(y * scale)),
            .right = @intFromFloat(@round(x * scale) + @max(1, scale)),
            .bottom = @intFromFloat(@round((y + @max(1, bounds.height)) * scale)),
        };
    }

    fn focusedWidget(runtime: *const native.Runtime, frame: native.platform.GpuFrame) native.canvas.ObjectId {
        // Semantics retains authored state. The SDK keeps live pointer/keyboard
        // focus separately, so node.state.focused does not track a clicked field.
        for (runtime.views[0..runtime.view_count]) |*view| {
            if (view.open and view.window_id == frame.window_id and std.mem.eql(u8, view.label, frame.label)) {
                return view.canvasWidgetRenderState().focused_id orelse 0;
            }
        }
        return 0;
    }

    fn position(self: *Bridge) void {
        if (!self.active or self.hwnd == null or c.GetFocus() != self.hwnd) return;
        if (!self.caret_owned) {
            // Keep it invisible: the canvas already paints the visible caret.
            self.caret_owned = c.CreateCaret(self.hwnd, null, @max(1, self.caret.right - self.caret.left), @max(1, self.caret.bottom - self.caret.top)) != 0;
        }
        if (self.caret_owned) _ = c.SetCaretPos(self.caret.left, self.caret.top);
        const context = c.ImmGetContext(self.hwnd) orelse return;
        defer _ = c.ImmReleaseContext(self.hwnd, context);
        var composition: c.COMPOSITIONFORM = std.mem.zeroes(c.COMPOSITIONFORM);
        composition.dwStyle = c.CFS_POINT;
        composition.ptCurrentPos = .{ .x = self.caret.left, .y = self.caret.top };
        _ = c.ImmSetCompositionWindow(context, &composition);
        var candidate: c.CANDIDATEFORM = std.mem.zeroes(c.CANDIDATEFORM);
        candidate.dwStyle = c.CFS_EXCLUDE;
        candidate.ptCurrentPos = .{ .x = self.caret.left, .y = self.caret.bottom + 2 };
        candidate.rcArea = self.caret;
        candidate.rcArea.bottom += 2;
        _ = c.ImmSetCandidateWindow(context, &candidate);
    }

    fn destroyCaret(self: *Bridge) void {
        if (self.caret_owned) _ = c.DestroyCaret();
        self.caret_owned = false;
    }

    fn deactivate(self: *Bridge) void {
        const was_active = self.active;
        self.active = false;
        self.destroyCaret();
        if (was_active and self.hwnd != null) {
            if (c.ImmGetContext(self.hwnd)) |context| {
                // An unfinished composition must not leak into the next field
                // or leave a candidate popup behind when hiding to the tray.
                _ = c.ImmNotifyIME(context, c.NI_COMPOSITIONSTR, c.CPS_CANCEL, 0);
                _ = c.ImmReleaseContext(self.hwnd, context);
            }
        }
    }

    pub fn deinit(self: *Bridge) void {
        self.deactivate();
        if (self.hwnd) |hwnd| _ = c.RemoveWindowSubclass(hwnd, windowProc, 1);
        self.hwnd = null;
    }

    fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, _: c.UINT_PTR, data: c.DWORD_PTR) callconv(.winapi) c.LRESULT {
        const self: *Bridge = @ptrFromInt(data);
        switch (message) {
            c.WM_IME_STARTCOMPOSITION, c.WM_INPUTLANGCHANGE => self.position(),
            c.WM_IME_NOTIFY => if (wparam == c.IMN_OPENCANDIDATE or wparam == c.IMN_CHANGECANDIDATE) {
                self.position();
            },
            c.WM_KILLFOCUS => self.deactivate(),
            c.WM_NCDESTROY => self.deinit(),
            else => {},
        }
        // Keep the SDK's preedit/commit routing and the system's candidate UI.
        return c.DefSubclassProc(hwnd, message, wparam, lparam);
    }
};

test "IME follows runtime focus even when authored textbox semantics is unfocused" {
    const a = std.testing.allocator;
    const harness = try native.TestHarness().create(a, .{});
    defer harness.destroy(a);
    harness.null_platform.gpu_surfaces = true;
    var context: u8 = 0;
    const app: native.App = .{ .context = &context, .name = "ime-focus" };
    try harness.start(app);
    _ = try harness.runtime.createView(.{ .window_id = 1, .label = "main-canvas", .kind = .gpu_surface, .frame = .{ .x = 0, .y = 0, .width = 240, .height = 160 } });
    const children = [_]native.canvas.Widget{.{ .id = 2, .kind = .search_field, .frame = .{ .x = 12, .y = 16, .width = 180, .height = 36 }, .text = "" }};
    var nodes: [2]native.canvas.WidgetLayoutNode = undefined;
    const layout = try native.canvas.layoutWidgetTree(.{ .kind = .stack, .children = &children }, .{ .x = 0, .y = 0, .width = 240, .height = 160 }, &nodes);
    _ = try harness.runtime.setCanvasWidgetLayout(1, "main-canvas", layout);
    const frame: native.platform.GpuFrame = .{ .window_id = 1, .label = "main-canvas" };
    try std.testing.expectEqual(@as(u64, 0), Bridge.focusedWidget(&harness.runtime, frame));
    try harness.runtime.dispatchPlatformEvent(app, .{ .gpu_surface_input = .{ .window_id = 1, .label = "main-canvas", .kind = .pointer_down, .x = 40, .y = 30 } });
    const semantics = try harness.runtime.canvasWidgetSemantics(1, "main-canvas");
    try std.testing.expect(!semantics[0].state.focused);
    try std.testing.expectEqual(@as(u64, 2), Bridge.focusedWidget(&harness.runtime, frame));
    harness.runtime.views[0].focused = false;
    try std.testing.expectEqual(@as(u64, 0), Bridge.focusedWidget(&harness.runtime, frame));
}

test "IME anchor scales to physical pixels and stays inside a scrolled search field" {
    const field = native.geometry.RectF.init(40, 400, 200, 32);
    const rect = Bridge.caretRect(.{ .x = 80, .y = 408, .width = 1, .height = 18 }, field, 192);
    try std.testing.expectEqualDeep(c.RECT{ .left = 160, .top = 816, .right = 162, .bottom = 852 }, rect);
    const clipped = Bridge.caretRect(.{ .x = 400, .y = 408, .width = 1, .height = 18 }, field, 144);
    try std.testing.expectEqual(@as(c.LONG, 354), clipped.left);
}
