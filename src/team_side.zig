const std = @import("std");
const t = @import("types.zig");
const logic = @import("logic.zig");
const lcu = @import("lcu.zig");

pub const conversations_path = "/lol-chat/v1/conversations";

pub fn supported(game: std.json.Value) bool {
    const queue = logic.get(logic.get(game, "gameData"), "queue");
    const queue_mode = logic.str(logic.get(queue, "gameMode"));
    const mode = if (queue_mode.len > 0) queue_mode else logic.str(logic.get(logic.get(game, "map"), "gameMode"));
    // Arena teams also use small team numbers, but have no red/blue side.
    if (std.mem.eql(u8, mode, "CHERRY") or std.mem.eql(u8, mode, "TFT")) return false;
    const queue_id = logic.integer(logic.get(queue, "id"));
    if (logic.isAram(queue_id, mode)) return true;
    for ([_][]const u8{ "CLASSIC", "KIWI", "URF", "ONEFORALL" }) |known| {
        if (std.mem.eql(u8, mode, known)) return true;
    }
    return switch (queue_id) {
        400, 420, 430, 440 => true,
        else => false,
    };
}

pub fn ownSide(session: std.json.Value) t.TeamSide {
    if (logic.yes(logic.get(session, "isSpectating"))) return .unknown;
    const local = logic.get(session, "localPlayerCellId");
    if (local != .integer or local.integer < 0) return .unknown;
    for (logic.items(logic.get(session, "myTeam"))) |player| {
        const cell = logic.get(player, "cellId");
        if (cell != .integer or cell.integer != local.integer) continue;
        // Champ-select's team is 1/2, unlike the in-game teamId (100/200).
        return switch (logic.integer(logic.get(player, "team"))) {
            1 => .blue,
            2 => .red,
            else => .unknown,
        };
    }
    return .unknown;
}

fn roomId(session: std.json.Value) []const u8 {
    const details = logic.get(session, "chatDetails");
    const id = logic.str(logic.get(details, "multiUserChatId"));
    return if (id.len > 0) id else logic.str(logic.get(details, "chatRoomName"));
}

fn roomKey(id: []const u8) []const u8 {
    const local = id[0 .. std.mem.indexOfScalar(u8, id, '@') orelse id.len];
    return if (std.mem.startsWith(u8, local, "c1~")) local[3..] else local;
}

/// Owned by the service worker. Retained on disconnect; reset only on a
/// verified phase exit, game-ID change, or a different selection chat room.
pub const Notice = struct {
    side: t.TeamSide = .unknown,
    game_id: i64 = 0,
    room: t.Text(256) = .{},
    needs_selection_sync: bool = true,
    ready: bool = false,
    finished: bool = false,
    next_attempt: u64 = 0,
    attempts: u8 = 0,
    read_error_logged: bool = false,

    pub fn observe(self: *Notice, session: std.json.Value, state: *t.Snapshot) void {
        const room = roomId(session);
        if (room.len > self.room.bytes.len) return;
        if (room.len > 0) {
            if (self.room.len > 0 and !std.mem.eql(u8, self.room.text(), room)) self.* = .{};
            self.room.set(room);
        }
        const side = ownSide(session);
        self.needs_selection_sync = side == .unknown and !logic.yes(logic.get(session, "isSpectating"));
        if (side == .unknown) return;
        const game_id = logic.get(session, "gameId");
        if (game_id == .integer and game_id.integer > 0) self.game_id = game_id.integer;
        if (self.side == .unknown) {
            self.side = side;
            state.last_team_side = side;
            state.side_notices += 1;
            state.logEvent(.side, .info, side.message());
        }
        self.ready = side == self.side;
    }

    pub fn send(self: *Notice, temp: std.mem.Allocator, client: anytype, state: *t.Snapshot, now: u64) !void {
        if (!self.ready or self.finished or now < self.next_attempt) return;
        self.next_attempt = now + 1000;
        self.sendInner(temp, client, state) catch |err| {
            if (err == error.AuthenticationExpired) return err;
            if (!self.finished and !self.read_error_logged) {
                state.logEvent(.side, .warning, "选人聊天暂不可用，阵营提示将稍后重试。");
                self.read_error_logged = true;
            }
        };
    }

    fn sendInner(self: *Notice, temp: std.mem.Allocator, client: anytype, state: *t.Snapshot) !void {
        const response = try lcu.requestAuthenticated(client, temp, "GET", conversations_path, "");
        if (!response.ok()) return error.ChatUnavailable;
        const conversations = try response.json(temp);
        defer conversations.deinit();
        var room: ?[]const u8 = null;
        for (logic.items(conversations.value)) |conversation| {
            if (!logic.eql(logic.get(conversation, "type"), "championSelect")) continue;
            const id = logic.str(logic.get(conversation, "id"));
            if (id.len == 0 or id.len > 256) continue;
            if (self.room.len > 0 and
                !std.mem.eql(u8, roomKey(id), roomKey(self.room.text())) and
                !std.mem.eql(u8, roomKey(logic.str(logic.get(conversation, "pid"))), roomKey(self.room.text()))) continue;
            // Refuse an ambiguous list rather than writing into an old room.
            if (room != null) return;
            room = id;
        }
        const id = room orelse return;
        // Recheck after discovering the room. In WS mode the write additionally
        // uses CachedClient's generation guard; REST mode reads these afresh.
        const phase = try lcu.requestAuthenticated(client, temp, "GET", "/lol-gameflow/v1/gameflow-phase", "");
        if (!phase.ok()) return;
        const phase_json = try phase.json(temp);
        defer phase_json.deinit();
        if (!logic.eql(phase_json.value, "ChampSelect")) return;
        const selection = try lcu.requestAuthenticated(client, temp, "GET", "/lol-champ-select/v1/session", "");
        if (!selection.ok()) return;
        const session = try selection.json(temp);
        defer session.deinit();
        if (ownSide(session.value) != self.side or !std.mem.eql(u8, roomId(session.value), self.room.text())) return;
        const game_id = logic.get(session.value, "gameId");
        if (self.game_id > 0 and (game_id != .integer or game_id.integer != self.game_id)) return;
        var escaped: std.Io.Writer.Allocating = .init(temp);
        defer escaped.deinit();
        try std.Uri.Component.percentEncode(&escaped.writer, id, struct {
            fn allowed(byte: u8) bool {
                return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
            }
        }.allowed);
        const path = try std.fmt.allocPrint(temp, "{s}/{s}/messages", .{ conversations_path, escaped.written() });
        const body = try std.json.Stringify.valueAlloc(temp, .{ .body = self.side.chatMessage(), .type = "chat" }, .{});
        self.attempts += 1;
        const result = lcu.requestAuthenticated(client, temp, "POST", path, body) catch |err| {
            if (err == error.AuthenticationExpired) return err;
            // A transport failure may follow a delivered message. Do not send
            // it twice after reconnecting when the result is unknowable.
            self.finished = true;
            state.logEvent(.side, .warning, "阵营消息发送中断，结果未确认；本局不重复发送，仍可查看浮窗提示。");
            return err;
        };
        if (result.ok()) {
            self.finished = true;
            state.logEvent(.side, .success, "阵营提示已发送到选人聊天。");
        } else if (self.attempts >= 5 or (result.status != 404 and result.status != 409 and result.status != 429 and result.status < 500)) {
            self.finished = true;
            state.logEvent(.side, .failure, "阵营消息未能发送到选人聊天，本局已停止重试。");
        }
    }
};
