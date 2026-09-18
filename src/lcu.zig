const std = @import("std");
const w = @import("windows.zig");
const c = w.c;
const Credentials = @import("auth.zig").Credentials;

pub fn requestAuthenticated(client: anytype, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !Response {
    const response = try client.request(allocator, method, path, body);
    try response.authenticated();
    return response;
}

pub const Response = struct {
    status: u32,
    body: []const u8,
    pub fn ok(self: Response) bool {
        return self.status >= 200 and self.status < 300;
    }
    pub fn json(self: Response, a: std.mem.Allocator) !std.json.Parsed(std.json.Value) {
        try self.authenticated();
        if (!self.ok()) return error.HttpStatus;
        return std.json.parseFromSlice(std.json.Value, a, self.body, .{ .allocate = .alloc_always });
    }
    pub fn authenticated(self: Response) !void {
        if (self.status == 401 or self.status == 403) return error.AuthenticationExpired;
    }
};
pub const Client = struct {
    session: c.HINTERNET,
    connection: c.HINTERNET,
    port: u16,
    auth_expired: bool = false,
    authorization: [512]u16 = @splat(0),
    pub fn init(creds: Credentials) !Client {
        const session = c.WinHttpOpen(std.unicode.utf8ToUtf16LeStringLiteral("catengar/0.1"), c.WINHTTP_ACCESS_TYPE_NO_PROXY, null, null, 0) orelse return error.HttpOpen;
        errdefer _ = c.WinHttpCloseHandle(session);
        _ = c.WinHttpSetTimeouts(session, 1500, 1500, 1500, 1500);
        const conn = c.WinHttpConnect(session, std.unicode.utf8ToUtf16LeStringLiteral("127.0.0.1"), creds.port, 0) orelse return error.HttpConnect;
        var result: Client = .{ .session = session, .connection = conn, .port = creds.port };
        var plain: [270]u8 = undefined;
        defer @memset(&plain, 0);
        const source = try std.fmt.bufPrint(&plain, "riot:{s}", .{creds.token.text()});
        var encoded: [380]u8 = undefined;
        defer @memset(&encoded, 0);
        const token = std.base64.standard.Encoder.encode(&encoded, source);
        var header: [500]u8 = undefined;
        defer @memset(&header, 0);
        const h = try std.fmt.bufPrint(&header, "Authorization: Basic {s}\r\nContent-Type: application/json\r\n", .{token});
        const n = try std.unicode.utf8ToUtf16Le(&result.authorization, h);
        result.authorization[n] = 0;
        return result;
    }
    pub fn deinit(self: *Client) void {
        _ = c.WinHttpCloseHandle(self.connection);
        _ = c.WinHttpCloseHandle(self.session);
        @memset(&self.authorization, 0);
    }
    pub fn webSocket(self: *Client) !*@import("socket.zig").Socket {
        if (self.auth_expired) return error.AuthenticationExpired;
        return @import("socket.zig").Socket.create(self.port, &self.authorization) catch |err| {
            if (err == error.AuthenticationExpired) self.auth_expired = true;
            return err;
        };
    }
    pub fn request(self: *Client, a: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) !Response {
        if (self.auth_expired) return error.AuthenticationExpired;
        if (path.len == 0 or path[0] != '/' or std.mem.startsWith(u8, path, "//") or std.mem.indexOfAny(u8, path, "\r\n") != null) return error.InvalidPath;
        const verb = try std.unicode.utf8ToUtf16LeAllocZ(a, method);
        defer a.free(verb);
        const endpoint = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
        defer a.free(endpoint);
        const req = c.WinHttpOpenRequest(self.connection, verb.ptr, endpoint.ptr, null, null, null, c.WINHTTP_FLAG_SECURE) orelse return error.HttpRequest;
        defer _ = c.WinHttpCloseHandle(req);
        // LCU's self-signed certificate is accepted ONLY on this fixed loopback connection.
        var security: u32 = c.SECURITY_FLAG_IGNORE_UNKNOWN_CA | c.SECURITY_FLAG_IGNORE_CERT_CN_INVALID | c.SECURITY_FLAG_IGNORE_CERT_DATE_INVALID | c.SECURITY_FLAG_IGNORE_CERT_WRONG_USAGE;
        if (c.WinHttpSetOption(req, c.WINHTTP_OPTION_SECURITY_FLAGS, &security, @sizeOf(u32)) == 0) return error.TlsOptions;
        var redirects: u32 = c.WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if (c.WinHttpSetOption(req, c.WINHTTP_OPTION_REDIRECT_POLICY, &redirects, @sizeOf(u32)) == 0) return error.RedirectOptions;
        if (c.WinHttpSendRequest(req, &self.authorization, 0xffffffff, if (body.len == 0) null else @ptrCast(@constCast(body.ptr)), @intCast(body.len), @intCast(body.len), 0) == 0) return error.HttpSend;
        if (c.WinHttpReceiveResponse(req, null) == 0) return error.HttpReceive;
        var status: u32 = 0;
        var size: u32 = @sizeOf(u32);
        if (c.WinHttpQueryHeaders(req, c.WINHTTP_QUERY_STATUS_CODE | c.WINHTTP_QUERY_FLAG_NUMBER, null, &status, &size, null) == 0) return error.HttpHeaders;
        if (status == 401 or status == 403) {
            self.auth_expired = true;
            return error.AuthenticationExpired;
        }
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(a);
        while (true) {
            var buffer: [16384]u8 = undefined;
            var read: u32 = 0;
            if (c.WinHttpReadData(req, &buffer, buffer.len, &read) == 0) return error.HttpRead;
            if (read == 0) break;
            if (data.items.len + read > 16 * 1024 * 1024) return error.ResponseTooLarge;
            try data.appendSlice(a, buffer[0..read]);
        }
        return .{ .status = status, .body = try data.toOwnedSlice(a) };
    }
};
