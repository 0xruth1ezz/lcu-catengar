const std = @import("std");
const t = @import("types.zig");
const logic = @import("logic.zig");
const auth = @import("auth.zig");
const lcu = @import("lcu.zig");
const settings = @import("settings.zig");
const win = @import("windows.zig");
const events = @import("events.zig");
const a = std.heap.page_allocator;

pub const Service = struct {
    mutex: win.Mutex = .{},
    snapshot: t.Snapshot = .{},
    preferences: t.Preferences = .{},
    prefs_version: u64 = 0,
    stop: std.atomic.Value(bool) = .init(false),
    reconnect: std.atomic.Value(bool) = .init(false),
    auth_retry: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,
    notify: ?*const fn () bool = null,
    root: []const u8 = "",
    config_path: []const u8 = "",
    config_valid: bool = true,
    pending_pick: i32 = 0,
    pending_until: u64 = 0,
    pending_resynced: bool = false,

    pub fn init(self: *Service, io: std.Io) !void {
        self.root = try win.dataDirectory(a);
        self.config_path = try std.fs.path.join(a, &.{ self.root, "settings.json" });
        try std.Io.Dir.cwd().createDirPath(io, self.root);
        if (std.Io.Dir.cwd().readFileAlloc(io, self.config_path, a, .limited(64 * 1024))) |bytes| {
            defer a.free(bytes);
            self.preferences = settings.decode(a, bytes) catch {
                self.config_valid = false;
                self.snapshot.log("设置文件无法读取，已使用关闭状态；修改设置后会保存新的配置。");
                return;
            };
        } else |err| {
            if (err == error.FileNotFound) {
                try settings.save(a, io, self.config_path, &self.preferences);
            } else {
                self.config_valid = false;
                self.snapshot.log("设置文件读取失败，当前使用默认设置。");
            }
        }
    }
    pub fn deinit(self: *Service) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| thread.join();
        if (self.root.len > 0) a.free(self.root);
        if (self.config_path.len > 0) a.free(self.config_path);
    }
    pub fn start(self: *Service, notify: *const fn () bool) !void {
        self.notify = notify;
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }
    pub fn configure(self: *Service, preferences: t.Preferences) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        self.preferences = preferences;
        self.prefs_version += 1;
    }
    pub fn copy(self: *Service, target: *t.Snapshot) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        target.* = self.snapshot;
    }
    fn prefs(self: *Service) t.Preferences {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.preferences;
    }
    fn publish(self: *Service, state: *const t.Snapshot) bool {
        self.mutex.lock();
        if (std.meta.eql(self.snapshot, state.*)) {
            self.mutex.unlock();
            return true;
        }
        self.snapshot = state.*;
        self.mutex.unlock();
        return if (self.notify) |callback| callback() else true;
    }
    fn sleep(self: *Service, ms: u64) void {
        const until = win.now() + ms;
        while (!self.stop.load(.acquire) and !self.reconnect.load(.acquire) and win.now() < until) win.sleep(50);
    }
    fn persist(self: *Service, io: std.Io, seen: *u64, state: *t.Snapshot) void {
        self.mutex.lock();
        const version = self.prefs_version;
        const p = self.preferences;
        self.mutex.unlock();
        if (seen.* == version) return;
        settings.save(a, io, self.config_path, &p) catch {
            state.log("设置保存失败，请检查本地目录权限。");
            return;
        };
        seen.* = version;
    }
    fn disconnect(self: *Service, state: *t.Snapshot, client: *?lcu.Client, stream: *?*events.Stream) void {
        state.connected = false;
        state.websocket = false;
        state.current = 0;
        state.bench_count = 0;
        state.queue_id = 0;
        state.phase.set("未连接");
        state.status.set("LCU 连接已变化，正在重新获取认证");
        self.pending_pick = 0;
        self.pending_until = 0;
        self.pending_resynced = false;
        _ = self.publish(state);
        if (stream.*) |s| s.destroy();
        stream.* = null;
        if (client.*) |*v| v.deinit();
        client.* = null;
    }
    fn run(self: *Service) void {
        // Worker-owned I/O must inherit Windows' environment for executable lookup.
        var threaded: std.Io.Threaded = .init(a, .{ .environ = .{ .block = .global } });
        defer threaded.deinit();
        const io = threaded.io();
        const state = a.create(t.Snapshot) catch return;
        defer a.destroy(state);
        self.copy(state);
        const watcher = auth.Watcher.create() catch {
            state.status.set("无法启动 LCU 认证监视，请重新打开应用");
            _ = self.publish(state);
            return;
        };
        defer watcher.destroy();
        var recovery: auth.Recovery = .{};
        var next_health: u64 = 0;
        var client: ?lcu.Client = null;
        defer if (client) |*c| c.deinit();
        var stream: ?*events.Stream = null;
        defer if (stream) |s| s.destroy();
        var next_ws: u64 = 0;
        var phase_version: u64 = 0;
        var seen_version: u64 = 0;
        defer self.persist(io, &seen_version, state);
        var gate: logic.RetryGate = .{};
        var accept_gate: logic.RetryGate = .{};
        var metadata_stage: usize = 0;
        var icon_cursor: usize = 0;
        var cache: t.Text(768) = .{};
        var connection_nonce: u64 = 0;
        var next_metadata: u64 = 0;
        while (!self.stop.load(.acquire)) {
            self.persist(io, &seen_version, state);
            if (self.auth_retry.swap(false, .acq_rel)) watcher.requestHelper();
            var identity = watcher.read();
            defer @memset(std.mem.asBytes(&identity), 0);
            state.auth_retry_available = switch (identity.status) {
                .permission_required, .helper_missing, .helper_failed => true,
                else => false,
            };
            const changed = recovery.changed(identity);
            const manual = self.reconnect.swap(false, .acq_rel);
            const dead = if (stream) |s| !s.alive.load(.acquire) else false;
            const expired = if (client) |v| v.auth_expired else false;
            if (changed or manual or dead or expired) {
                self.disconnect(state, &client, &stream);
                if (changed and !manual and !dead and !expired) {
                    recovery = .{};
                } else {
                    recovery.failed(identity, win.now());
                    watcher.refresh();
                }
                state.log("LCU 已断开或认证已更新，正在自动恢复连接。");
            }
            if (client == null) {
                state.connected = false;
                state.websocket = false;
                state.current = 0;
                state.bench_count = 0;
                state.queue_id = 0;
                state.phase.set("未连接");
                if (!recovery.available(identity, win.now())) {
                    state.status.set(switch (identity.status) {
                        .starting => "正在读取 LCU 认证",
                        .ready => "正在重新验证 LCU 认证并恢复连接",
                        .not_running => "等待 League 客户端启动",
                        .admin_required => "认证助手暂时无法读取客户端，正在重试",
                        .authorizing => "等待授权认证助手",
                        .permission_required => "认证助手未获授权，可点击「授权认证助手」重试",
                        .helper_missing => "缺少 catengar-auth.exe，请将它放在主程序旁",
                        .helper_failed => "认证助手已停止，可点击「授权认证助手」重试",
                        .failed => "认证读取暂时失败，正在自动重试",
                    });
                    if (!self.publish(state)) break;
                    self.sleep(100);
                    continue;
                }
                client = lcu.Client.init(identity.credentials) catch {
                    recovery.failed(identity, win.now());
                    watcher.refresh();
                    state.status.set("无法连接 LCU，正在重试");
                    if (!self.publish(state)) break;
                    continue;
                };
                recovery.connected(identity);
                metadata_stage = 0;
                icon_cursor = 0;
                connection_nonce = win.now();
                next_metadata = 0;
                // Keep the displayed catalog and decoded portraits across a
                // reconnect. Metadata replaces them only if its content changes.
                cache.set("");
                gate = .{};
                accept_gate = .{};
                self.pending_pick = 0;
                next_ws = 0;
                next_health = win.now() + 15000;
                state.log("已取得 LCU 认证，正在连接本机客户端。");
            }
            var arena: std.heap.ArenaAllocator = .init(a);
            defer arena.deinit();
            const temp = arena.allocator();
            if (stream == null and win.now() >= next_ws) {
                var ws_error: ?anyerror = null;
                stream = events.Stream.create(&client.?) catch |err| blk: {
                    ws_error = err;
                    break :blk null;
                };
                if (stream) |s| {
                    s.cache.sync(temp, &client.?, false) catch |err| {
                        ws_error = err;
                        s.destroy();
                        stream = null;
                    };
                }
                next_ws = win.now() + 10000;
                if (stream) |s| {
                    phase_version = s.cache.phaseVersion();
                    state.log("WebSocket 已连接，实时监听对局和可用英雄。");
                } else {
                    var message: [192]u8 = undefined;
                    state.log(std.fmt.bufPrint(&message, "WebSocket 暂不可用（{s}），10 秒后重试。", .{@errorName(ws_error orelse error.WebSocketDisconnected)}) catch "WebSocket 暂不可用，正在重试。");
                }
            }
            state.websocket = stream != null;
            const tick_result = if (stream) |s| blk: {
                if (client.?.auth_expired) break :blk error.AuthenticationExpired;
                // A quiet/half-open WS may not report a rotated token. A single
                // low-frequency authenticated probe also repairs a missed phase.
                if (win.now() >= next_health) {
                    s.cache.health(temp, &client.?) catch |err| break :blk err;
                    next_health = win.now() + 15000;
                }
                const version = s.cache.phaseVersion();
                if (version != phase_version) {
                    gate = .{};
                    accept_gate = .{};
                    self.pending_pick = 0;
                    // A phase boundary may precede a resource's first event.
                    // Fill missing resources once, never poll them in the hot path.
                    s.cache.sync(temp, &client.?, true) catch |err| break :blk err;
                    phase_version = version;
                }
                if (self.pending_pick != 0 and !self.pending_resynced and win.now() >= self.pending_until) {
                    // Recover once if a successful write's confirmation event was lost.
                    s.cache.sync(temp, &client.?, false) catch |err| break :blk err;
                    self.pending_resynced = true;
                }
                var cached: events.CachedClient = .{ .rest = &client.?, .cache = &s.cache };
                break :blk self.tick(temp, &cached, state, &gate, &accept_gate);
            } else self.tick(temp, &client.?, state, &gate, &accept_gate);
            tick_result catch {
                self.disconnect(state, &client, &stream);
                recovery.failed(identity, win.now());
                watcher.refresh();
                continue;
            };
            // Automation always runs before optional asset work. Asset work pauses
            // entirely in ready-check/champion-select so it cannot delay a pick.
            const phase = state.phase.text();
            if (!std.mem.eql(u8, phase, "ChampSelect") and !std.mem.eql(u8, phase, "ReadyCheck") and win.now() >= next_metadata) {
                if (metadata_stage < 5) {
                    metadata(temp, io, &client.?, self.root, state, metadata_stage, connection_nonce, &cache) catch {
                        if (client.?.auth_expired) continue;
                        state.log("部分 LCU 静态资源暂不可用，将自动重试。");
                        next_metadata = win.now() + 5000;
                        if (!self.publish(state)) break;
                        self.sleep(500);
                        continue;
                    };
                    metadata_stage += 1;
                } else if (icon_cursor < state.champion_count) {
                    while (icon_cursor < state.champion_count and state.champions[icon_cursor].icon_path.len > 0) : (icon_cursor += 1) {}
                    if (icon_cursor == state.champion_count) continue;
                    const champ = &state.champions[icon_cursor];
                    cacheIcon(temp, io, &client.?, cache.text(), champ) catch {};
                    if (champ.icon_path.len > 0) state.icon_count += 1;
                    icon_cursor += 1;
                }
            }
            if (!self.publish(state)) break;
            if (stream) |s| s.wait(if (icon_cursor < state.champion_count) 50 else 100) else self.sleep(if (std.mem.eql(u8, phase, "ChampSelect")) 250 else if (std.mem.eql(u8, phase, "ReadyCheck")) 500 else 1000);
        }
    }
    pub fn tick(self: *Service, temp: std.mem.Allocator, client: anytype, state: *t.Snapshot, gate: *logic.RetryGate, accept_gate: *logic.RetryGate) !void {
        const phase_response = try lcu.requestAuthenticated(client, temp, "GET", "/lol-gameflow/v1/gameflow-phase", "");
        const phase_json = try phase_response.json(temp);
        defer phase_json.deinit();
        state.phase.set(logic.str(phase_json.value));
        state.connected = true;
        state.status.set(if (state.websocket) "已连接 · WebSocket 实时监听" else "已连接 · REST 降级，正在恢复 WebSocket");
        const phase = state.phase.text();
        if (!std.mem.eql(u8, phase, "ChampSelect")) {
            state.current = 0;
            state.bench_count = 0;
            state.queue_id = 0;
            gate.* = .{};
            self.pending_pick = 0;
        }
        if (std.mem.eql(u8, phase, "ReadyCheck")) {
            const p = self.prefs();
            if (!p.auto_accept) return;
            const response = try lcu.requestAuthenticated(client, temp, "GET", "/lol-matchmaking/v1/ready-check", "");
            if (!response.ok()) return;
            const ready = try response.json(temp);
            defer ready.deinit();
            if (logic.shouldAccept(p.auto_accept, phase, ready.value) and accept_gate.allowed(1, win.now())) {
                // Recheck the switch immediately before the write; no queued writes survive OFF.
                if (!self.prefs().auto_accept) return;
                const accepted = try lcu.requestAuthenticated(client, temp, "POST", "/lol-matchmaking/v1/ready-check/accept", "");
                accept_gate.record(win.now(), accepted.ok());
                if (accepted.ok()) {
                    // Wait for the ReadyCheck phase to end before another accept,
                    // even if the next read briefly repeats playerResponse=None.
                    accept_gate.next_ms = std.math.maxInt(u64);
                    state.accepted += 1;
                    state.log("已接受对局，等待其他玩家确认。");
                } else state.log("接受对局暂未成功，将根据客户端状态重试。");
            }
        } else accept_gate.* = .{};
        if (!std.mem.eql(u8, phase, "ChampSelect")) return;
        // Read queue metadata fresh; never carry an ARAM queue into a different lobby.
        const game_response = try lcu.requestAuthenticated(client, temp, "GET", "/lol-gameflow/v1/session", "");
        if (!game_response.ok()) return;
        const game = try game_response.json(temp);
        defer game.deinit();
        const game_phase = logic.str(logic.get(game.value, "phase"));
        if (game_phase.len > 0 and !std.mem.eql(u8, game_phase, phase)) return;
        const queue = logic.get(logic.get(game.value, "gameData"), "queue");
        state.queue_id = logic.integer(logic.get(queue, "id"));
        const mode = logic.str(logic.get(queue, "gameMode"));
        if (!logic.isAram(state.queue_id, mode)) return;
        const response = try lcu.requestAuthenticated(client, temp, "GET", "/lol-champ-select/v1/session", "");
        if (!response.ok()) return;
        const session = try response.json(temp);
        defer session.deinit();
        state.current = logic.ownChampion(session.value);
        state.bench_count = logic.benchIds(session.value, &state.bench);
        if (self.pending_pick != 0) {
            if (state.current == self.pending_pick) {
                state.swapped += 1;
                state.last_pick_name.set(championName(state, self.pending_pick));
                state.log(try std.fmt.allocPrint(temp, "已选择 {s} · 客户端已确认", .{championName(state, self.pending_pick)}));
                self.pending_pick = 0;
            } else if (win.now() < self.pending_until) return else self.pending_pick = 0;
        }
        var p = self.prefs();
        if (!p.auto_pick or p.count == 0) return;
        var pickable: [256]i32 = undefined;
        var pickable_count: usize = 0;
        // Only query card picks when our own action is active.
        var active_pick = false;
        const local = logic.integer(logic.get(session.value, "localPlayerCellId"));
        for (logic.items(logic.get(session.value, "actions"))) |group| for (logic.items(group)) |action| {
            if (logic.integer(logic.get(action, "actorCellId")) == local and logic.eql(logic.get(action, "type"), "pick") and logic.yes(logic.get(action, "isInProgress")) and !logic.yes(logic.get(action, "completed"))) active_pick = true;
        };
        if (active_pick) {
            const available = try lcu.requestAuthenticated(client, temp, "GET", "/lol-champ-select/v1/pickable-champion-ids", "");
            if (available.ok()) {
                const list = try available.json(temp);
                defer list.deinit();
                for (logic.items(list.value)) |id| {
                    if (pickable_count == pickable.len) break;
                    pickable[pickable_count] = logic.integer(id);
                    pickable_count += 1;
                }
            }
        }
        p = self.prefs();
        const choice = logic.choose(&p, state.queue_id, mode, session.value, pickable[0..pickable_count]) orelse return;
        if (!gate.allowed(choice.champion, win.now())) return;
        if (!std.meta.eql(self.prefs(), p)) return;
        const prefix = if (choice.legacy) "/lol-champ-select/v1/session" else "/lol-lobby-team-builder/champ-select/v1/session";
        const path = if (choice.action) |id| try std.fmt.allocPrint(temp, "{s}/actions/{d}", .{ prefix, id }) else try std.fmt.allocPrint(temp, "{s}/bench/swap/{d}", .{ prefix, choice.champion });
        const body = if (choice.action != null) try std.fmt.allocPrint(temp, "{{\"championId\":{d},\"completed\":true}}", .{choice.champion}) else "";
        const result = try lcu.requestAuthenticated(client, temp, if (choice.action != null) "PATCH" else "POST", path, body);
        gate.record(win.now(), result.ok());
        if (result.ok()) {
            // Confirm ownership from the next WS session update, not the HTTP status.
            self.pending_pick = choice.champion;
            self.pending_resynced = false;
            self.pending_until = win.now() + 3000;
            state.log("选人请求已提交，等待客户端事件确认。");
        } else {
            state.log(try std.fmt.allocPrint(temp, "英雄暂不可交换（HTTP {d}），刷新可用池后重试。", .{result.status}));
        }
    }
};

fn championName(state: *const t.Snapshot, id: i32) []const u8 {
    for (state.champions[0..state.champion_count]) |*champ| if (champ.id == id) return champ.name.text();
    return "目标英雄";
}

fn metadata(temp: std.mem.Allocator, io: std.Io, client: *lcu.Client, root: []const u8, state: *t.Snapshot, stage: usize, nonce: u64, cache: *t.Text(768)) !void {
    if (stage == 0) {
        const version = try lcu.requestAuthenticated(client, temp, "GET", "/lol-patch/v1/game-version", "");
        const locale = try lcu.requestAuthenticated(client, temp, "GET", "/riotclient/region-locale", "");
        var hash = std.hash.Wyhash.init(0);
        hash.update(version.body);
        hash.update(locale.body);
        if (!version.ok() or !locale.ok()) hash.update(std.mem.asBytes(&nonce));
        const key = try std.fmt.allocPrint(temp, "{x}", .{hash.final()});
        const dir = try std.fs.path.join(temp, &.{ root, "cache", key });
        try std.Io.Dir.cwd().createDirPath(io, dir);
        cache.set(dir);
        return;
    }
    const endpoints = [_][]const u8{
        "/lol-game-data/assets/v1/champion-summary.json",
        "/lol-perks/v1/perks",
        "/lol-perks/v1/styles",
        "/lol-game-data/assets/v1/summoner-spells.json",
    };
    const filenames = [_][]const u8{ "champions.json", "perks.json", "styles.json", "summoner-spells.json" };
    const response = try lcu.requestAuthenticated(client, temp, "GET", endpoints[stage - 1], "");
    // Optional indexes may not exist on a client version. Champion list is required.
    if (stage > 1 and !response.ok()) {
        state.log("部分符文或技能资料暂不可用，英雄资料仍可正常使用。");
        return;
    }
    const parsed = try response.json(temp);
    defer parsed.deinit();
    const file = try std.fs.path.join(temp, &.{ cache.text(), filenames[stage - 1] });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = response.body });
    const entries = logic.items(parsed.value);
    if (stage == 1) {
        if (parsed.value != .array) return error.InvalidCatalog;
        // The static summary also contains champions from other games/modes
        // (e.g. Jade_ variants). Prefer the current account's LoL inventory IDs.
        var inventory: []const logic.Value = &.{};
        const summoner_response = try lcu.requestAuthenticated(client, temp, "GET", "/lol-summoner/v1/current-summoner", "");
        if (summoner_response.ok()) {
            const summoner = try summoner_response.json(temp);
            const summoner_id = logic.get(summoner.value, "summonerId");
            if (summoner_id == .integer and summoner_id.integer > 0) {
                const inventory_path = try std.fmt.allocPrint(temp, "/lol-champions/v1/inventories/{d}/champions-minimal", .{summoner_id.integer});
                const inventory_response = try lcu.requestAuthenticated(client, temp, "GET", inventory_path, "");
                if (inventory_response.ok()) {
                    const list = try inventory_response.json(temp);
                    inventory = logic.items(list.value);
                }
            }
        }
        const champions = try temp.alloc(t.Champion, t.max_champions);
        var count: usize = 0;
        for (entries) |entry| {
            const id = logic.integer(logic.get(entry, "id"));
            const alias = logic.str(logic.get(entry, "alias"));
            if (!logic.candidateChampion(id, alias) or count == t.max_champions) continue;
            if (inventory.len > 0) {
                var found = false;
                for (inventory) |owned| if (logic.integer(logic.get(owned, "id")) == id) {
                    found = true;
                    break;
                };
                if (!found) continue;
            }
            const champ = &champions[count];
            champ.* = .{ .id = id };
            champ.name.set(logic.str(logic.get(entry, "name")));
            champ.alias.set(alias);
            champ.asset.set(logic.str(logic.get(entry, "squarePortraitPath")));
            count += 1;
        }
        const generation = @import("catalog.zig").generation(cache.text(), champions[0..count]);
        if (generation != state.catalog_generation) {
            state.catalog_generation = generation;
            state.champion_count = count;
            state.icon_count = 0;
            @memcpy(state.champions[0..count], champions[0..count]);
            // Resolve existing disk entries in one worker pass, rather than
            // publishing one champion every 50ms and decoding the whole catalog.
            for (state.champions[0..count]) |*champ| {
                const path = try iconPath(temp, cache.text(), champ);
                if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
                    champ.icon_path.set(path);
                    state.icon_count += 1;
                } else |_| {}
            }
        }
        state.log("英雄资料已从当前客户端载入，可搜索并设置优先级。");
    } else if (stage == 2) state.perk_count = entries.len else if (stage == 3) state.style_count = if (parsed.value == .array) entries.len else logic.items(logic.get(parsed.value, "styles")).len;
}

fn cacheIcon(temp: std.mem.Allocator, io: std.Io, client: *lcu.Client, cache: []const u8, champ: *t.Champion) !void {
    if (!logic.validAsset(champ.asset.text())) return error.InvalidAsset;
    const path = try iconPath(temp, cache, champ);
    if (std.Io.Dir.cwd().access(io, path, .{})) |_| {
        champ.icon_path.set(path);
        return;
    } else |_| {}
    const response = try lcu.requestAuthenticated(client, temp, "GET", champ.asset.text(), "");
    if (!response.ok() or response.body.len == 0) return error.ImageUnavailable;
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .replace = true });
    defer atomic.deinit(io);
    try atomic.file.writeStreamingAll(io, response.body);
    try atomic.replace(io);
    champ.icon_path.set(path);
}
fn iconPath(temp: std.mem.Allocator, cache: []const u8, champ: *const t.Champion) ![]const u8 {
    const name = try std.fmt.allocPrint(temp, "champion-{d}-{x}.png", .{ champ.id, std.hash.Wyhash.hash(0, champ.asset.text()) });
    return std.fs.path.join(temp, &.{ cache, name });
}
