const std = @import("std");
const types = @import("types.zig");
pub const Credentials = struct { port: u16, token: types.Text(256), pid: u32 };

// stdout is a private pipe to this process. Never print it, store it, or pass the
// token in a subsequent command line. The powershell child has no visible window.
const discovery_script =
    \\$ErrorActionPreference='Stop'; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false)
    \\$env:PSModulePath=$PSHOME+'\Modules'
    \\try { $ps=@(Get-CimInstance Win32_Process -Filter "Name='LeagueClientUx.exe'" -OperationTimeoutSec 3) } catch { exit 13 }
    \\if ($ps.Count -eq 0) { exit 2 }
    \\foreach ($p in ($ps | Sort-Object CreationDate -Descending)) {
    \\  if (!$p.CommandLine) { continue }
    \\  $port=[regex]::Match($p.CommandLine,'--app-port[= ]+"?(\d+)')
    \\  $token=[regex]::Match($p.CommandLine,'--remoting-auth-token[= ]+"?([^\s"]+)')
    \\  if ($port.Success -and $token.Success) {
    \\    @{port=[int]$port.Groups[1].Value;token=$token.Groups[1].Value;pid=$p.ProcessId} | ConvertTo-Json -Compress
    \\    exit 0
    \\  }
    \\}
    \\exit 13
;

pub fn discover(allocator: std.mem.Allocator, io: std.Io) !Credentials {
    // The elevated helper must never resolve an executable through PATH/CWD.
    const c = @import("windows.zig").c;
    var system: [32768]u16 = undefined;
    const len = c.GetSystemDirectoryW(&system, system.len);
    if (len == 0 or len >= system.len) return error.DiscoveryFailed;
    const directory = try std.unicode.utf16LeToUtf8Alloc(allocator, system[0..len]);
    defer allocator.free(directory);
    const powershell = try std.fs.path.join(allocator, &.{ directory, "WindowsPowerShell", "v1.0", "powershell.exe" });
    defer allocator.free(powershell);
    const output = try std.process.run(allocator, io, .{
        .argv = &.{ powershell, "-NoLogo", "-NoProfile", "-NonInteractive", "-Command", discovery_script },
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
