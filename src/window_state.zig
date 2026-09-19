const std = @import("std");
const c = @import("windows.zig").c;

/// Physical screen coordinates, independent of Native's cached scene frame.
const Bounds = struct {
    version: u32 = 1,
    left: i32,
    top: i32,
    width: i32,
    height: i32,

    fn valid(self: Bounds) bool {
        return self.version == 1 and self.width >= 100 and self.height >= 100 and
            self.width <= 32768 and self.height <= 32768 and
            self.left >= -131072 and self.left <= 131072 and
            self.top >= -131072 and self.top <= 131072;
    }

    fn visible(self: Bounds, work: c.RECT) Bounds {
        const width = @min(self.width, work.right - work.left);
        const height = @min(self.height, work.bottom - work.top);
        return .{
            .left = std.math.clamp(self.left, work.left, work.right - width),
            .top = std.math.clamp(self.top, work.top, work.bottom - height),
            .width = width,
            .height = height,
        };
    }
};

/// Restores once, before the first paint. Afterwards Win32/user actions own
/// placement: reconnects, focus changes and UAC never call the restore path.
pub const State = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    hwnd: c.HWND = null,
    last_saved: ?Bounds = null,
    moving: bool = false,
    restoring: bool = false,
    writable: bool = true,

    pub fn init(a: std.mem.Allocator, io: std.Io, root: []const u8) !State {
        return .{ .allocator = a, .io = io, .path = try std.fs.path.join(a, &.{ root, "window.json" }) };
    }

    pub fn install(self: *State, hwnd: c.HWND) void {
        if (hwnd == null or self.hwnd != null) return;
        self.hwnd = hwnd;
        self.restoring = true;
        defer self.restoring = false;
        const bytes = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, self.allocator, .limited(4096)) catch null;
        if (bytes) |json| {
            defer self.allocator.free(json);
            const parsed = std.json.parseFromSlice(Bounds, self.allocator, json, .{ .ignore_unknown_fields = true }) catch null;
            if (parsed) |value| {
                defer value.deinit();
                self.writable = value.value.version == 1;
                if (value.value.valid()) {
                    const bounds = value.value;
                    var rect: c.RECT = .{ .left = bounds.left, .top = bounds.top, .right = bounds.left + bounds.width, .bottom = bounds.top + bounds.height };
                    var monitor = std.mem.zeroes(c.MONITORINFO);
                    monitor.cbSize = @sizeOf(c.MONITORINFO);
                    const target = if (c.GetMonitorInfoW(c.MonitorFromRect(&rect, c.MONITOR_DEFAULTTONEAREST), &monitor) != 0)
                        bounds.visible(monitor.rcWork)
                    else
                        bounds;
                    // No ShowWindow, activation or delayed reposition after UAC.
                    _ = c.SetWindowPos(hwnd, null, target.left, target.top, target.width, target.height, c.SWP_NOACTIVATE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER);
                }
            }
        }
        _ = c.SetWindowSubclass(hwnd, windowProc, 2, @intFromPtr(self));
    }

    fn save(self: *State) void {
        if (!self.writable or self.restoring or self.moving or self.hwnd == null) return;
        // Hidden/minimized/maximized frames must not replace the user's normal
        // placement (minimization can report the sentinel -32000 coordinates).
        if (c.IsWindowVisible(self.hwnd) == 0 or c.IsIconic(self.hwnd) != 0 or c.IsZoomed(self.hwnd) != 0) return;
        var rect: c.RECT = undefined;
        if (c.GetWindowRect(self.hwnd, &rect) == 0) return;
        const bounds: Bounds = .{ .left = rect.left, .top = rect.top, .width = rect.right - rect.left, .height = rect.bottom - rect.top };
        if (!bounds.valid()) return;
        if (self.last_saved) |old| if (std.meta.eql(old, bounds)) return;
        const bytes = std.json.Stringify.valueAlloc(self.allocator, bounds, .{ .whitespace = .indent_2 }) catch return;
        defer self.allocator.free(bytes);
        var file = std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{ .replace = true }) catch return;
        defer file.deinit(self.io);
        file.file.writeStreamingAll(self.io, bytes) catch return;
        file.replace(self.io) catch return;
        self.last_saved = bounds;
    }

    pub fn deinit(self: *State) void {
        if (self.hwnd != null) _ = c.RemoveWindowSubclass(self.hwnd, windowProc, 2);
        self.hwnd = null;
        self.allocator.free(self.path);
    }

    fn windowProc(hwnd: c.HWND, message: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM, _: c.UINT_PTR, data: c.DWORD_PTR) callconv(.winapi) c.LRESULT {
        const self: *State = @ptrFromInt(data);
        switch (message) {
            c.WM_ENTERSIZEMOVE => self.moving = true,
            c.WM_EXITSIZEMOVE => {
                self.moving = false;
                self.save();
            },
            c.WM_WINDOWPOSCHANGED => self.save(),
            c.WM_NCDESTROY => {
                _ = c.RemoveWindowSubclass(hwnd, windowProc, 2);
                self.hwnd = null;
            },
            else => {},
        }
        return c.DefSubclassProc(hwnd, message, wparam, lparam);
    }
};

test "saved placement round-trips negative monitor coordinates" {
    const expected: Bounds = .{ .left = -1900, .top = -180, .width = 1400, .height = 950 };
    const bytes = try std.json.Stringify.valueAlloc(std.testing.allocator, expected, .{});
    defer std.testing.allocator.free(bytes);
    const parsed = try std.json.parseFromSlice(Bounds, std.testing.allocator, bytes, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.valid());
    try std.testing.expectEqualDeep(expected, parsed.value);
}

test "valid user placement is unchanged and disconnected monitors remain reachable" {
    const work: c.RECT = .{ .left = -2560, .top = 0, .right = 0, .bottom = 1400 };
    const expected: Bounds = .{ .left = -2300, .top = 100, .width = 1200, .height = 800 };
    try std.testing.expectEqualDeep(expected, expected.visible(work));
    const primary: c.RECT = .{ .left = 0, .top = 40, .right = 1920, .bottom = 1080 };
    try std.testing.expectEqualDeep(Bounds{ .left = 0, .top = 100, .width = 1200, .height = 800 }, expected.visible(primary));
    var invalid = expected;
    invalid.width = std.math.maxInt(i32);
    try std.testing.expect(!invalid.valid());
    invalid = expected;
    invalid.version = 2;
    try std.testing.expect(!invalid.valid());
}

test "Win32 move persists and hiding focus changes and repeated install do not reposition" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fs.path.join(a, &.{ ".zig-cache", "tmp", &tmp.sub_path });
    defer a.free(root);
    const previous_dpi = c.SetThreadDpiAwarenessContext(c.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    defer _ = c.SetThreadDpiAwarenessContext(previous_dpi);
    const hwnd = c.CreateWindowExW(c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), std.unicode.utf8ToUtf16LeStringLiteral("Catengar placement test"), c.WS_POPUP, 80, 80, 200, 160, null, null, null, null) orelse return error.TestWindow;
    defer _ = c.DestroyWindow(hwnd);
    var state = try State.init(a, io, root);
    defer state.deinit();
    state.install(hwnd);
    const win = @import("windows.zig");
    win.setAuthorizationOwner(hwnd);
    defer win.setAuthorizationOwner(null);
    try std.testing.expectEqual(hwnd, win.authorizationOwner());
    win.setAuthorizationOwner(c.GetDesktopWindow());
    try std.testing.expect(win.authorizationOwner() == null);
    win.setAuthorizationOwner(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    _ = c.SendMessageW(hwnd, c.WM_ENTERSIZEMOVE, 0, 0);
    try std.testing.expect(c.SetWindowPos(hwnd, null, 230, 150, 220, 180, c.SWP_NOACTIVATE | c.SWP_NOZORDER) != 0);
    _ = c.SendMessageW(hwnd, c.WM_EXITSIZEMOVE, 0, 0);
    const bytes = try tmp.dir.readFileAlloc(io, "window.json", a, .limited(4096));
    defer a.free(bytes);
    const parsed = try std.json.parseFromSlice(Bounds, a, bytes, .{});
    defer parsed.deinit();
    try std.testing.expectEqualDeep(Bounds{ .left = 230, .top = 150, .width = 220, .height = 180 }, parsed.value);

    const before = state.last_saved.?;
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATEAPP, 0, 0);
    _ = c.SendMessageW(hwnd, c.WM_ACTIVATEAPP, 1, 0);
    _ = c.ShowWindow(hwnd, c.SW_MINIMIZE);
    try std.testing.expectEqualDeep(before, state.last_saved.?);
    _ = c.ShowWindow(hwnd, c.SW_HIDE);
    state.install(hwnd);
    try std.testing.expect(c.IsWindowVisible(hwnd) == 0);
    try std.testing.expectEqualDeep(before, state.last_saved.?);
    _ = c.ShowWindow(hwnd, c.SW_SHOWNOACTIVATE);
    var rect: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(hwnd, &rect) != 0);
    try std.testing.expectEqualDeep(c.RECT{ .left = 230, .top = 150, .right = 450, .bottom = 330 }, rect);

    // A fresh process/window can restore before its first show, without changing
    // the original window or relying on Native's stale (0,0) scene coordinates.
    const reopened = c.CreateWindowExW(c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE, std.unicode.utf8ToUtf16LeStringLiteral("STATIC"), null, c.WS_POPUP, 0, 0, 200, 160, null, null, null, null) orelse return error.TestWindow;
    defer _ = c.DestroyWindow(reopened);
    var restored = try State.init(a, io, root);
    defer restored.deinit();
    restored.install(reopened);
    try std.testing.expect(c.IsWindowVisible(reopened) == 0);
    var restored_rect: c.RECT = undefined;
    try std.testing.expect(c.GetWindowRect(reopened, &restored_rect) != 0);
    try std.testing.expectEqualDeep(rect, restored_rect);
}
