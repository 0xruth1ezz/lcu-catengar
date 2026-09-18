const std = @import("std");
const win = @import("windows.zig");
const c = win.c;

/// Native's Windows tray loader needs an ICO file. Keep the portable executable
/// self-contained and materialize its embedded icon in our existing data folder.
pub fn prepare(allocator: std.mem.Allocator, io: std.Io, root: []const u8) ![]const u8 {
    const path = try std.fs.path.join(allocator, &.{ root, "catengar.ico" });
    errdefer allocator.free(path);
    const bytes = @embedFile("catengar_icon");
    if (std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(bytes.len + 1))) |current| {
        defer allocator.free(current);
        if (std.mem.eql(u8, current, bytes)) return path;
    } else |_| {}
    var file = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer file.deinit(io);
    try file.file.writeStreamingAll(io, bytes);
    try file.replace(io);
    return path;
}

pub fn applyWindow() void {
    // The pinned Windows host does not set WM_SETICON from AppInfo.icon_path.
    // Its main HWND exists before the application's start callback.
    const hwnd = c.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("NativeSdkWindowsHost"), std.unicode.utf8ToUtf16LeStringLiteral("catengar")) orelse return;
    var process_id: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &process_id);
    if (process_id != c.GetCurrentProcessId()) return;
    const module = c.GetModuleHandleW(null);
    const resource: [*c]const u16 = @ptrFromInt(100);
    const dpi = c.GetDpiForWindow(hwnd);
    const big = c.LoadImageW(module, resource, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYICON, dpi), c.LR_SHARED);
    const small = c.LoadImageW(module, resource, c.IMAGE_ICON, c.GetSystemMetricsForDpi(c.SM_CXSMICON, dpi), c.GetSystemMetricsForDpi(c.SM_CYSMICON, dpi), c.LR_SHARED);
    // LR_SHARED icons live for the process lifetime; the OS owns their cleanup.
    if (big != null) _ = c.SendMessageW(hwnd, c.WM_SETICON, c.ICON_BIG, @bitCast(@intFromPtr(big)));
    if (small != null) _ = c.SendMessageW(hwnd, c.WM_SETICON, c.ICON_SMALL, @bitCast(@intFromPtr(small)));
}
