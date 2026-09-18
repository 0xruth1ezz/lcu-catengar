const std = @import("std");
pub const c = @cImport({
    // Zig 0.16 translate-c cannot lower mingw's fortified wchar wrappers.
    // We only import Win32 declarations, and never call these CRT wrappers.
    @cUndef("_FORTIFY_SOURCE");
    @cDefine("_FORTIFY_SOURCE", "0");
    @cDefine("WIN32_LEAN_AND_MEAN", "1");
    @cInclude("windows.h");
    @cInclude("winhttp.h");
    @cInclude("shellapi.h");
    @cInclude("shlobj.h");
    @cInclude("sddl.h");
});
pub const Mutex = struct {
    value: c.SRWLOCK = std.mem.zeroes(c.SRWLOCK),
    pub fn lock(self: *Mutex) void {
        c.AcquireSRWLockExclusive(&self.value);
    }
    pub fn unlock(self: *Mutex) void {
        c.ReleaseSRWLockExclusive(&self.value);
    }
};
pub fn now() u64 {
    return c.GetTickCount64();
}
pub fn sleep(ms: u32) void {
    c.Sleep(ms);
}
pub fn toastPosition(width: f32, height: f32) struct { x: f32, y: f32 } {
    var work: c.RECT = std.mem.zeroes(c.RECT);
    if (c.SystemParametersInfoW(c.SPI_GETWORKAREA, 0, &work, 0) == 0) {
        work.right = c.GetSystemMetrics(c.SM_CXSCREEN);
        work.bottom = c.GetSystemMetrics(c.SM_CYSCREEN);
    }
    const dpi = c.GetDpiForSystem();
    const scale = @as(f32, @floatFromInt(if (dpi == 0) 96 else dpi)) / 96;
    return .{
        .x = @max(@as(f32, @floatFromInt(work.left)) / scale, @as(f32, @floatFromInt(work.right)) / scale - width - 16),
        .y = @max(@as(f32, @floatFromInt(work.top)) / scale, @as(f32, @floatFromInt(work.bottom)) / scale - height - 16),
    };
}
pub fn prepareToastWindow() void {
    // The pinned Native Windows host ignores authored popup x/y at create.
    // Its HWND exists before the first canvas paint, so finish placement
    // here without showing or activating an empty window.
    const hwnd = c.FindWindowW(std.unicode.utf8ToUtf16LeStringLiteral("NativeSdkWindowsHost"), std.unicode.utf8ToUtf16LeStringLiteral("catengar · 操作成功")) orelse return;
    var process_id: c.DWORD = 0;
    _ = c.GetWindowThreadProcessId(hwnd, &process_id);
    if (process_id != c.GetCurrentProcessId()) return;
    const style = c.GetWindowLongPtrW(hwnd, c.GWL_EXSTYLE);
    const desired = (style | c.WS_EX_TOOLWINDOW | c.WS_EX_NOACTIVATE) & ~@as(isize, c.WS_EX_APPWINDOW);
    if (style != desired) _ = c.SetWindowLongPtrW(hwnd, c.GWL_EXSTYLE, desired);
    var rect: c.RECT = undefined;
    var work: c.RECT = undefined;
    if (c.GetWindowRect(hwnd, &rect) == 0 or c.SystemParametersInfoW(c.SPI_GETWORKAREA, 0, &work, 0) == 0) return;
    const margin: c_int = @intCast(@max(96, c.GetDpiForWindow(hwnd)) / 6);
    const x = @max(work.left, work.right - (rect.right - rect.left) - margin);
    const y = @max(work.top, work.bottom - (rect.bottom - rect.top) - margin);
    if (rect.left != x or rect.top != y) _ = c.SetWindowPos(hwnd, null, x, y, 0, 0, c.SWP_NOSIZE | c.SWP_NOACTIVATE | c.SWP_NOZORDER | c.SWP_NOOWNERZORDER);
}
pub fn isAdmin() bool {
    return c.IsUserAnAdmin() != 0;
}
pub fn elevate() bool {
    var executable: [32768]u16 = undefined;
    const len = c.GetModuleFileNameW(null, &executable, executable.len);
    if (len == 0 or len >= executable.len) return false;
    var cwd: [32768]u16 = undefined;
    const cwd_len = c.GetCurrentDirectoryW(cwd.len, &cwd);
    const result = c.ShellExecuteW(null, std.unicode.utf8ToUtf16LeStringLiteral("runas"), &executable, std.unicode.utf8ToUtf16LeStringLiteral("--elevated-restart"), if (cwd_len > 0 and cwd_len < cwd.len) &cwd else null, c.SW_SHOWNORMAL);
    return @intFromPtr(result) > 32;
}
pub fn dataDirectory(allocator: std.mem.Allocator) ![]const u8 {
    var buffer: [32768]u16 = undefined;
    const len = c.GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("LOCALAPPDATA"), &buffer, buffer.len);
    if (len == 0 or len >= buffer.len) return error.NoDataDirectory;
    const base = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..len]);
    defer allocator.free(base);
    // Keep the existing data directory across the catengar rename.
    return std.fs.path.join(allocator, &.{ base, "LoLRengar" });
}
