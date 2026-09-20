const std = @import("std");
const types = @import("types.zig");
const win = @import("windows.zig");
const c = win.c;
pub const Credentials = struct { port: u16, token: types.Text(256), pid: u32 };

// stdout is a private pipe to this process. Never print it, store it, or pass the
// token in a subsequent command line. The powershell child has no visible window.
const discovery_script = @embedFile("auth_discovery.ps1");

fn discoveryCommand(allocator: std.mem.Allocator) ![]u8 {
    // WMI can omit ExecutablePath even with an elevated token. The limited
    // process query obtains only the image path, without reading process memory.
    const ProcessPath = struct { pid: u32, path: []const u8 };
    var paths: std.ArrayList(ProcessPath) = .empty;
    defer {
        for (paths.items) |item| allocator.free(item.path);
        paths.deinit(allocator);
    }
    const snapshot = c.CreateToolhelp32Snapshot(c.TH32CS_SNAPPROCESS, 0);
    if (snapshot != c.INVALID_HANDLE_VALUE) {
        defer _ = c.CloseHandle(snapshot);
        var entry = std.mem.zeroes(c.PROCESSENTRY32W);
        entry.dwSize = @sizeOf(c.PROCESSENTRY32W);
        var found = c.Process32FirstW(snapshot, &entry);
        var total: usize = 0;
        while (found != 0) : (found = c.Process32NextW(snapshot, &entry)) {
            const name = std.mem.sliceTo(&entry.szExeFile, 0);
            const wide = std.unicode.utf8ToUtf16LeStringLiteral;
            if (c.CompareStringOrdinal(name.ptr, @intCast(name.len), wide("LeagueClient.exe"), -1, 1) != c.CSTR_EQUAL and
                c.CompareStringOrdinal(name.ptr, @intCast(name.len), wide("LeagueClientUx.exe"), -1, 1) != c.CSTR_EQUAL) continue;
            const process = c.OpenProcess(c.PROCESS_QUERY_LIMITED_INFORMATION, 0, entry.th32ProcessID) orelse continue;
            defer _ = c.CloseHandle(process);
            var buffer: [32768]u16 = undefined;
            var length: c.DWORD = buffer.len;
            if (c.QueryFullProcessImageNameW(process, 0, &buffer, &length) == 0) continue;
            const path = try std.unicode.utf16LeToUtf8Alloc(allocator, buffer[0..length]);
            // Bound the encoded data to leave room for the fixed script within
            // Windows' command-line limit. WMI remains the primary path source.
            if (paths.items.len >= 16 or total + path.len > 4096) {
                allocator.free(path);
                continue;
            }
            errdefer allocator.free(path);
            try paths.append(allocator, .{ .pid = entry.th32ProcessID, .path = path });
            total += path.len;
        }
    }
    const json = try std.json.Stringify.valueAlloc(allocator, paths.items, .{});
    defer allocator.free(json);
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(json.len));
    defer allocator.free(encoded);
    _ = std.base64.standard.Encoder.encode(encoded, json);
    // Paths are base64 JSON data, never interpolated as PowerShell syntax. This
    // command contains no credentials and launches no process chosen by a client.
    return std.fmt.allocPrint(allocator, "$clientPaths = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{s}')) | ConvertFrom-Json\n$hasAdministratorToken = {s}\n{s}", .{ encoded, if (win.isAdmin()) "$true" else "$false", discovery_script });
}

pub fn discover(allocator: std.mem.Allocator, io: std.Io) !Credentials {
    // The elevated helper must never resolve an executable through PATH/CWD.
    var system: [32768]u16 = undefined;
    const len = c.GetSystemDirectoryW(&system, system.len);
    if (len == 0 or len >= system.len) return error.DiscoveryFailed;
    const directory = try std.unicode.utf16LeToUtf8Alloc(allocator, system[0..len]);
    defer allocator.free(directory);
    const powershell = try std.fs.path.join(allocator, &.{ directory, "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer allocator.free(powershell);
    const command = try discoveryCommand(allocator);
    defer allocator.free(command);
    const output = try std.process.run(allocator, io, .{
        .argv = &.{ powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", command },
        .stdout_limit = .limited(4096),
        .stderr_limit = .limited(4096),
        .create_no_window = true,
        .timeout = .{ .duration = .{ .raw = .fromSeconds(8), .clock = .awake } },
    });
    defer {
        @memset(output.stdout, 0);
        @memset(output.stderr, 0);
        allocator.free(output.stdout);
        allocator.free(output.stderr);
    }
    switch (output.term) {
        .exited => |code| switch (code) {
            0 => {},
            2 => return error.ClientNotRunning,
            3 => return error.ClientNotReady,
            13 => return error.AdminRequired,
            else => return error.DiscoveryFailed,
        },
        else => return error.DiscoveryFailed,
    }
    return parse(allocator, output.stdout);
}
pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) !Credentials {
    const Wire = struct { port: u16, token: []const u8, pid: u32 };
    const parsed = try std.json.parseFromSlice(Wire, allocator, bytes, .{});
    defer parsed.deinit();
    const v = parsed.value;
    if (v.port == 0 or v.token.len == 0 or v.token.len > 256 or v.pid == 0) return error.InvalidCredentials;
    if (std.mem.indexOfAny(u8, v.token, "\r\n\x00") != null) return error.InvalidCredentials;
    return .{ .port = v.port, .token = types.Text(256).init(v.token), .pid = v.pid };
}
