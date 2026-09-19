const std = @import("std");
comptime {
    @import("portable_target.zig").requireBaseline();
}
const native = @import("native_sdk");
const runner = @import("runner");
const t = @import("types.zig");
const Service = @import("service.zig").Service;
const win = @import("windows.zig");
const themes = @import("theme.zig");
const grid = @import("champion_grid.zig");
const portraits = @import("portraits.zig");
const portrait_worker = @import("portrait_worker.zig");
const preview_catalog = @import("catengar_options").preview_catalog;
const toasts = @import("toasts.zig");
const titlebar = @import("titlebar.zig");
const ui_state = @import("ui_state.zig");
const journal = @import("journal.zig");
const details = @import("champion_details.zig");
const updater = @import("updater.zig");
const update_timer_key = 73;
const toast_timer_key = 71;
const profile_copy_timer_key = 72;
const profile_image_id = 0x50524f46;
const profile_job_index = t.max_champions;
const app_author = "0xruth1ezz";
const app_repository = app_author ++ "/lcu-catengar";
const app_repository_url = "https://github.com/" ++ app_repository;
pub const panic = std.debug.FullPanic(native.debug.capturePanic);
const canvas = native.canvas;
const App = native.UiApp(Model, Msg);
const Effects = App.Effects;
var service: *Service = undefined;
var channel: native.ChannelHandle = undefined;
var instance: @import("instance.zig").Instance = undefined;
var native_start: ?*const fn (*anyopaque, *native.Runtime) anyerror!void = null;
var native_runtime: ?*native.Runtime = null;
var ime: @import("ime.zig").Bridge = .{};
var window_state: @import("window_state.zig").State = undefined;
var portrait_loader: ?*portrait_worker.Worker = null;
var portrait_channel: native.ChannelHandle = undefined;
var journal_channel: native.ChannelHandle = undefined;
var journal_worker: ?*journal.Worker = null;
var update_worker: ?*updater.Worker = null;
var update_channel: native.ChannelHandle = undefined;

pub const Row = struct { id: i32, name: []const u8, alias: []const u8, image: u64, source_x: usize = 0, source_y: usize = 0, action_label: []const u8 = "", view_label: []const u8 = "", selection_icon: []const u8 = "plus", return_focus: bool = false, rank: usize, selected: bool };
pub const ThemeRow = struct { id: u8, name: []const u8, selected: bool };
pub const Model = struct {
    snapshot: t.Snapshot = .{},
    preferences: t.Preferences = .{},
    theme_picker_open: bool = false,
    about_open: bool = false,
    about_link_failed: bool = false,
    about_return_focus: bool = false,
    detail: details.State = .{},
    software_update: updater.State = .{},
    page: enum { home, settings, logs } = .home,
    journal_page: journal.Page = .{},
    log_scroll: f32 = 0,
    confirm_clear_logs: bool = false,
    log_notice: t.Text(128) = .{},
    diagnostics_open: bool = false,
    titlebar_hover: bool = false,
    titlebar_logo_ready: bool = false,
    has_cjk_font: bool = false,
    search: canvas.TextBuffer(128) = .{},
    library_scroll: f32 = 0,
    library_height: f32 = 800 - titlebar.height - 1,
    canvas_width: f32 = 1120,
    canvas_height: f32 = 800,
    portraits: portraits.Store = .{},
    image_pending: [t.max_champions]bool = @splat(false),
    image_failed: [t.max_champions]bool = @splat(false),
    profile_image_path: t.Text(768) = .{},
    profile_image_generation: u64 = 0,
    profile_image_pending: bool = false,
    profile_image_ready: bool = false,
    profile_image_failed: bool = false,
    profile_copy_id: t.Text(128) = .{},
    profile_copy: enum { idle, copied, failed } = .idle,
    ui_error: t.Text(160) = .{},
    toasts: toasts.State = .{},
    toast_x: f32 = 0,
    toast_y: f32 = 0,
    pub fn toastTitle(self: *const Model) []const u8 {
        return self.toasts.messages[0].title.text();
    }
    pub fn toastBody(self: *const Model) []const u8 {
        return self.toasts.messages[0].body.text();
    }
    pub fn toastIcon(self: *const Model) []const u8 {
        return if (self.toasts.messages[0].is_update) "download" else "check-circle";
    }
    pub fn canInstallUpdate(self: *const Model) bool {
        return updater.canInstall(&self.snapshot);
    }
    pub fn pickPolicyDescription(self: *const Model) []const u8 {
        if (self.preferences.always_prioritize) return "持续选择可用的最高优先级英雄，保留已持有的更高优先级英雄。";
        if (self.preferences.auto_pick and self.selecting() and self.snapshot.pick_completed) return "本轮已自动抢到英雄，优选已停止；下一轮重新开始。";
        return "本轮自动抢到任意优先英雄后停止，下一轮重新开始。";
    }
    pub fn themeOptions(self: *const Model, arena: std.mem.Allocator) []const ThemeRow {
        const rows = arena.alloc(ThemeRow, themes.presets.len) catch return &.{};
        for (themes.presets, rows) |preset, *row_value| {
            row_value.* = .{ .id = @intFromEnum(preset), .name = preset.label(), .selected = self.preferences.theme == preset };
        }
        return rows;
    }
    pub fn themeLabel(self: *const Model) []const u8 {
        return self.preferences.theme.label();
    }
    pub fn versionLabel(_: *const Model) []const u8 {
        return @import("catengar_options").version_label;
    }
    pub fn aboutVersion(_: *const Model) []const u8 {
        return @import("catengar_options").version;
    }
    pub fn aboutAuthor(_: *const Model) []const u8 {
        return app_author;
    }
    pub fn aboutRepository(_: *const Model) []const u8 {
        return app_repository;
    }
    pub fn aboutLogo(self: *const Model) u64 {
        return if (self.titlebar_logo_ready) @import("app_icon.zig").titlebar_image_id else 0;
    }
    pub fn detailWidth(self: *const Model) f32 {
        return @min(980, self.canvas_width - 64);
    }
    pub fn detailHeight(self: *const Model) f32 {
        return @min(680, self.canvas_height - 64);
    }
    pub fn isHome(self: *const Model) bool {
        return self.page == .home;
    }
    pub fn isSettings(self: *const Model) bool {
        return self.page == .settings;
    }
    pub fn isLogs(self: *const Model) bool {
        return self.page == .logs;
    }
    pub fn logRows(self: *const Model) []const t.LogEntry {
        return self.journal_page.entries[0..self.journal_page.count];
    }
    pub fn logPageLabel(self: *const Model, allocator: std.mem.Allocator) []const u8 {
        const p = &self.journal_page;
        if (p.loading) return "正在读取日志…";
        if (p.total == 0) return "共 0 条记录";
        return std.fmt.allocPrint(allocator, "第 {d}–{d} 条 / 共 {d} 条", .{ p.total - p.end + 1, p.total - p.start, p.total }) catch "";
    }
    pub fn canOlderLogs(self: *const Model) bool {
        return self.journal_page.start > 0 and !self.journal_page.loading and !self.journal_page.clearing;
    }
    pub fn canNewerLogs(self: *const Model) bool {
        return !self.journal_page.live and !self.journal_page.loading and !self.journal_page.clearing;
    }
    pub fn hasProfile(self: *const Model) bool {
        return @import("profile.zig").visible(&self.snapshot);
    }
    pub fn profileName(self: *const Model) []const u8 {
        return self.snapshot.profile.name.text();
    }
    pub fn profileId(self: *const Model) []const u8 {
        return if (self.snapshot.profile.riot_id.len > 0) self.snapshot.profile.riot_id.text() else "好友 ID 暂不可用";
    }
    pub fn profileImage(self: *const Model) u64 {
        return if (self.profile_image_ready) profile_image_id else 0;
    }
    pub fn profileCopyLabel(self: *const Model) []const u8 {
        return switch (self.profile_copy) {
            .idle => "复制 ID",
            .copied => "已复制",
            .failed => "重试复制",
        };
    }
    pub fn profileCopyIcon(self: *const Model) []const u8 {
        return if (self.profile_copy == .copied) "check" else "copy";
    }
    pub fn profileCopyAccessibleLabel(self: *const Model) []const u8 {
        return if (self.profile_copy == .copied) "已复制完整好友 ID" else "复制完整好友 ID";
    }
    pub fn profileCopyFailed(self: *const Model) bool {
        return self.profile_copy == .failed;
    }
    pub fn query(self: *const Model) []const u8 {
        return self.search.text();
    }
    pub fn hasChampions(self: *const Model) bool {
        return self.snapshot.champion_count > 0;
    }
    pub fn gridColumns(self: *const Model) usize {
        return grid.columns(self.canvas_width);
    }
    fn gridWindow(self: *const Model) grid.Window {
        return grid.window(self.matchCount(), self.gridColumns(), self.library_scroll, self.library_height);
    }
    pub fn gridTop(self: *const Model) f32 {
        return self.gridWindow().top;
    }
    pub fn gridBottom(self: *const Model) f32 {
        return self.gridWindow().bottom;
    }
    pub fn matchCount(self: *const Model) usize {
        var n: usize = 0;
        for (self.snapshot.champions[0..self.snapshot.champion_count]) |*champ| if (self.matches(champ)) {
            n += 1;
        };
        return n;
    }
    fn matches(self: *const Model, champ: *const t.Champion) bool {
        const q = std.mem.trim(u8, self.query(), " \r\n\t");
        return q.len == 0 or std.mem.indexOf(u8, champ.name.text(), q) != null or std.ascii.indexOfIgnoreCase(champ.alias.text(), q) != null;
    }
    fn row(self: *const Model, arena: std.mem.Allocator, i: usize) Row {
        const c = &self.snapshot.champions[i];
        const rank = self.preferences.rank(c.id);
        const selected = rank < t.max_priority;
        return .{ .id = c.id, .name = c.name.text(), .alias = c.alias.text(), .image = if (self.portraits.ready[i]) portraits.imageId(i) else 0, .source_x = portraits.x(i), .source_y = portraits.y(i), .action_label = std.fmt.allocPrint(arena, "{s} {s}", .{ if (selected) "取消优先选择" else "优先选择", c.name.text() }) catch c.name.text(), .view_label = std.fmt.allocPrint(arena, "查看 {s}", .{c.name.text()}) catch "查看英雄", .selection_icon = if (selected) "check" else "plus", .return_focus = self.detail.return_focus == c.id, .rank = rank + 1, .selected = selected };
    }
    pub fn champions(self: *const Model, arena: std.mem.Allocator) []const Row {
        const window = self.gridWindow();
        const rows = arena.alloc(Row, window.end - window.start) catch return &.{};
        var matched: usize = 0;
        var n: usize = 0;
        for (self.snapshot.champions[0..self.snapshot.champion_count], 0..) |*champ, i| {
            if (!self.matches(champ)) continue;
            defer matched += 1;
            if (matched < window.start) continue;
            if (matched >= window.end) break;
            rows[n] = self.row(arena, i);
            n += 1;
        }
        return rows[0..n];
    }
    pub fn priorities(self: *const Model, arena: std.mem.Allocator) []const Row {
        const rows = arena.alloc(Row, self.preferences.count) catch return &.{};
        for (self.preferences.ids(), 0..) |id, n| {
            rows[n] = .{ .id = id, .name = std.fmt.allocPrint(arena, "英雄 #{d}", .{id}) catch "英雄", .alias = "等待客户端资料", .image = 0, .rank = n + 1, .selected = true };
            for (self.snapshot.champions[0..self.snapshot.champion_count], 0..) |champ, i| if (champ.id == id) {
                rows[n] = self.row(arena, i);
                break;
            };
        }
        return rows;
    }
    pub fn status(self: *const Model) []const u8 {
        if (self.ui_error.len > 0) return self.ui_error.text();
        return self.snapshot.status.text();
    }
    pub fn connectionLabel(self: *const Model) []const u8 {
        return ui_state.connectionLabel(&self.snapshot);
    }
    pub fn connectionNotice(self: *const Model) []const u8 {
        return ui_state.connectionNotice(&self.snapshot);
    }
    pub fn hasConnectionNotice(self: *const Model) bool {
        return self.connectionNotice().len > 0;
    }
    pub fn canAuthorize(self: *const Model) bool {
        return self.snapshot.auth_retry_available and self.snapshot.connection != .helper_missing;
    }
    pub fn canReconnect(self: *const Model) bool {
        return !self.snapshot.connected and self.snapshot.connection != .authorizing and !self.canAuthorize();
    }
    pub fn selecting(self: *const Model) bool {
        return self.snapshot.connected and std.mem.eql(u8, self.snapshot.phase.text(), "ChampSelect") and self.snapshot.pick_supported == true;
    }
    pub fn phaseLabel(self: *const Model) []const u8 {
        return ui_state.phaseLabel(&self.snapshot);
    }
    pub fn queueLabel(self: *const Model) []const u8 {
        return switch (self.snapshot.queue_id) {
            450 => "ARAM",
            2400 => "ARAM MAYHEM",
            0 => "等待进入选人",
            else => "其他队列",
        };
    }
    pub fn currentLabel(self: *const Model) []const u8 {
        if (self.snapshot.current == 0) return "尚未分配英雄";
        for (self.snapshot.champions[0..self.snapshot.champion_count]) |*c| if (c.id == self.snapshot.current) return c.name.text();
        return "客户端已分配英雄";
    }
    pub fn libraryLabel(self: *const Model, a: std.mem.Allocator) []const u8 {
        const count = self.matchCount();
        if (std.mem.trim(u8, self.query(), " \r\n\t").len > 0) return std.fmt.allocPrint(a, "找到 {d} / {d} 位英雄", .{ count, self.snapshot.champion_count }) catch "";
        return std.fmt.allocPrint(a, "共 {d} 位英雄", .{count}) catch "";
    }
};
pub const Msg = union(enum) {
    set_theme: u8,
    toggle_theme_picker,
    close_theme_picker,
    toggle_settings,
    toggle_diagnostics,
    open_about,
    close_about,
    open_repository,
    check_updates,
    install_update,
    open_update_settings,
    update_timer: native.EffectTimer,
    update_ready: native.EffectChannelEvent,
    preview_updates,
    preview_update_blocked,
    view_champion: i32,
    close_champion,
    detail_web_tab,
    reload_detail_web,
    open_detail_browser,
    open_logs,
    go_home,
    latest_logs,
    older_logs,
    newer_logs,
    logs_scrolled: canvas.ScrollState,
    ask_clear_logs,
    cancel_clear_logs,
    clear_logs,
    open_log_directory,
    journal_changed: native.EffectChannelEvent,
    preview_logs,
    show_window,
    hide_window,
    minimize_window,
    zoom_window,
    titlebar_hover: bool,
    quit,
    toggle_accept,
    toggle_pick,
    toggle_always_prioritize,
    reconnect,
    authorize_helper,
    toggle_priority: i32,
    remove: i32,
    move_up: i32,
    move_down: i32,
    search: canvas.TextInputEvent,
    library_scrolled: canvas.ScrollState,
    resized: native.geometry.SizeF,
    toast_timer: native.EffectTimer,
    dismiss_toast,
    preview_toasts,
    preview_connection,
    copy_profile,
    profile_copy_timer: native.EffectTimer,
    snapshot: native.EffectChannelEvent,
    portraits_ready: native.EffectChannelEvent,
};
fn notifyPortraits() bool {
    return portrait_channel.post("ready") != .closed;
}
fn notifyJournal() bool {
    return journal_channel.post("logs") != .closed;
}
fn notifyUpdate() bool {
    return update_channel.post("update") != .closed;
}
fn frameMsg(model: *const Model, frame: native.platform.GpuFrame) ?Msg {
    if (native_runtime) |runtime| ime.sync(runtime, frame);
    if (model.canvas_width == frame.size.width and model.canvas_height == frame.size.height) return null;
    return .{ .resized = frame.size };
}
fn notify() bool {
    return channel.post("state") != .closed;
}
fn initFx(model: *Model, fx: *Effects) void {
    const icon = @import("app_icon.zig");
    if (fx.registerImageBytes(icon.titlebar_image_id, icon.titlebar_png)) |_| {
        model.titlebar_logo_ready = true;
    } else |_| {}
    channel = fx.openChannel(.{ .key = 1, .on_event = Effects.channelMsg(.snapshot), .max_pending = 1 });
    portrait_channel = fx.openChannel(.{ .key = 2, .on_event = Effects.channelMsg(.portraits_ready), .max_pending = 1 });
    journal_channel = fx.openChannel(.{ .key = 3, .on_event = Effects.channelMsg(.journal_changed), .max_pending = 1 });
    update_channel = fx.openChannel(.{ .key = 4, .on_event = Effects.channelMsg(.update_ready), .max_pending = 1 });
    journal_worker = journal.Worker.create(if (preview_catalog.len > 0) ".zig-cache/catengar-preview" else service.root, notifyJournal) catch null;
    if (journal_worker) |worker| {
        if (preview_catalog.len == 0) service.attachLog(worker.sink());
    } else {
        model.journal_page.error_message.set("日志服务未能启动，请重新打开应用。");
        model.journal_page.loading = false;
    }
    portrait_loader = portrait_worker.Worker.create(notifyPortraits) catch null;
    instance.watch(notify) catch {};
    if (preview_catalog.len > 0) {
        loadPortraits(model, fx);
        return;
    }
    update_worker = updater.Worker.create(service.root, @import("catengar_options").version, notifyUpdate) catch null;
    fx.startTimer(.{ .key = update_timer_key, .interval_ms = 10000, .mode = .one_shot, .on_fire = Effects.timerMsg(.update_timer) });
    if (channel.live()) service.start(notify) catch {
        model.ui_error.set("后台服务启动失败，请重新打开工具。");
    };
}
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    var changed = false;
    switch (msg) {
        .check_updates => checkUpdates(model),
        .open_update_settings => {
            model.page = .settings;
            model.about_open = false;
            model.theme_picker_open = false;
        },
        .update_timer => |timer| {
            if (timer.outcome != .fired) return;
            if (!model.software_update.busy() and !model.software_update.available()) checkUpdates(model);
            fx.startTimer(.{ .key = update_timer_key, .interval_ms = 6 * 60 * 60 * 1000, .mode = .one_shot, .on_fire = Effects.timerMsg(.update_timer) });
        },
        .install_update => beginUpdate(model),
        .update_ready => |event| {
            if (event.kind != .data) return;
            if (update_worker) |worker| if (worker.take()) |result| {
                if (result.status == .armed) {
                    service.copy(&model.snapshot);
                    if (updater.canInstall(&model.snapshot)) {
                        updater.commit(result.ticket.text()) catch {
                            model.software_update.status = .failed;
                            model.software_update.message.set("更新未能启动，程序保持运行。请重试。");
                            return;
                        };
                        fx.quitApp();
                    } else model.software_update.status = .ready;
                    return;
                }
                model.software_update.status = result.status;
                model.software_update.message = result.message;
                if (result.version.len > 0) model.software_update.version = result.version;
                if (result.sha256.len > 0) model.software_update.sha256 = result.sha256;
                if (result.stage.len > 0) model.software_update.stage = result.stage;
                if (result.status == .available and !std.mem.eql(u8, result.version.text(), model.software_update.notified_version.text())) {
                    model.software_update.notified_version = result.version;
                    model.toasts.updateAvailable(result.version.text(), win.now());
                    startToastTimer(model, fx);
                }
                if (result.status == .ready) beginUpdate(model);
            };
        },
        .preview_updates => {
            if (preview_catalog.len == 0) return;
            model.page = .settings;
            model.software_update.version.set("0.2.0");
            model.software_update.status = switch (model.software_update.status) {
                .available => .downloading,
                .downloading => .ready,
                .ready => .failed,
                else => .available,
            };
            model.software_update.message.set("更新包校验未通过，原版本未被替换。请点击“检查更新”后重试。");
            if (model.software_update.status == .available) {
                model.toasts.updateAvailable("0.2.0", win.now());
                startToastTimer(model, fx);
            }
        },
        .preview_update_blocked => {
            if (preview_catalog.len == 0) return;
            model.software_update.status = .available;
            model.software_update.version.set("0.2.0");
            model.snapshot.connected = true;
            model.snapshot.phase.set("InProgress");
        },
        .view_champion => |id| {
            for (model.snapshot.champions[0..model.snapshot.champion_count]) |*champ| if (champ.id == id) {
                closeDetailWeb(model);
                model.detail.begin(id, champ.name.text());
                showDetailWeb(model);
                break;
            };
        },
        .close_champion => {
            closeDetailWeb(model);
            model.detail.open = false;
            model.detail.return_focus = model.detail.id;
        },
        .detail_web_tab => {
            showDetailWeb(model);
        },
        .reload_detail_web => {
            closeDetailWeb(model);
            model.detail.reload +%= 1;
            showDetailWeb(model);
        },
        .open_detail_browser => {
            model.detail.link_error = false;
            if (native_runtime) |runtime| {
                runtime.openExternalUrl(model.detail.url.text()) catch {
                    model.detail.link_error = true;
                };
            } else model.detail.link_error = true;
        },
        .toggle_theme_picker => model.theme_picker_open = !model.theme_picker_open,
        .close_theme_picker => model.theme_picker_open = false,
        .open_about => {
            model.about_open = true;
            model.about_link_failed = false;
            model.about_return_focus = false;
            model.theme_picker_open = false;
        },
        .close_about => {
            model.about_open = false;
            model.about_return_focus = true;
        },
        .open_repository => {
            model.about_link_failed = false;
            if (native_runtime) |runtime| {
                runtime.openExternalUrl(app_repository_url) catch {
                    model.about_link_failed = true;
                };
            } else model.about_link_failed = true;
        },
        .toggle_settings => {
            model.about_return_focus = false;
            model.page = if (model.page == .settings) .home else .settings;
            model.theme_picker_open = false;
            model.confirm_clear_logs = false;
        },
        .toggle_diagnostics => model.diagnostics_open = !model.diagnostics_open,
        .go_home => {
            model.page = .home;
            model.theme_picker_open = false;
            model.confirm_clear_logs = false;
        },
        .open_logs => {
            model.page = .logs;
            model.theme_picker_open = false;
            model.confirm_clear_logs = false;
            model.log_scroll = 0;
            if (journal_worker) |worker| worker.request(null);
        },
        .logs_scrolled => |scroll| model.log_scroll = scroll.offset_y,
        .latest_logs, .older_logs, .newer_logs => {
            const worker = journal_worker orelse return;
            const p = &model.journal_page;
            const before: ?usize = switch (msg) {
                .older_logs => if (model.canOlderLogs()) p.start else return,
                .newer_logs => if (model.canNewerLogs()) (if (p.end + journal.page_size >= p.total) null else p.end + journal.page_size) else return,
                else => null,
            };
            model.log_scroll = 0;
            model.confirm_clear_logs = false;
            worker.request(before);
            model.journal_page.loading = true;
        },
        .ask_clear_logs => model.confirm_clear_logs = true,
        .cancel_clear_logs => model.confirm_clear_logs = false,
        .clear_logs => {
            if (!model.confirm_clear_logs or model.journal_page.clearing) return;
            model.confirm_clear_logs = false;
            model.log_notice.set("");
            if (journal_worker) |worker| {
                worker.clear();
                model.journal_page.clearing = true;
            }
        },
        .open_log_directory => if (journal_worker) |worker| {
            worker.openDirectory();
        },
        .journal_changed => |event| {
            if (event.kind != .data) return;
            if (journal_worker) |worker| {
                const old_clear = model.journal_page.clear_revision;
                worker.read(&model.journal_page);
                if (model.journal_page.clear_revision != old_clear) {
                    model.log_scroll = 0;
                    model.log_notice.set("历史日志已清空，新事件会继续记录。");
                }
            }
        },
        .preview_logs => if (preview_catalog.len > 0) {
            if (journal_worker) |worker| for (0..65) |i| {
                var buffer: [512]u8 = undefined;
                const message = std.fmt.bufPrint(&buffer, "预览记录 {d:0>3} · 顺位英雄测试：已提交选取请求；只有客户端确认归属后才记录成功。", .{i}) catch unreachable;
                const sink = worker.sink();
                sink.emit(sink.context, t.LogEntry.init(.pick, if (i % 3 == 0) .success else if (i % 3 == 1) .failure else .info, message));
            };
        },
        .copy_profile => {
            if (!model.hasProfile() or model.snapshot.profile.riot_id.len == 0) return;
            fx.cancelTimer(profile_copy_timer_key);
            model.profile_copy = .failed;
            if (native_runtime) |runtime| {
                // The typed data API reports a locked clipboard; the SDK's
                // legacy text-only effect currently swallows that failure.
                if (runtime.writeClipboardData(.{ .mime_type = "text/plain", .bytes = model.snapshot.profile.riot_id.text() })) |_| {
                    model.profile_copy = .copied;
                    fx.startTimer(.{ .key = profile_copy_timer_key, .interval_ms = 2500, .on_fire = Effects.timerMsg(.profile_copy_timer) });
                } else |_| {}
            }
        },
        .profile_copy_timer => |timer| {
            if (timer.outcome == .fired) model.profile_copy = .idle;
        },
        .preview_connection => if (preview_catalog.len > 0) {
            model.snapshot.connected = !model.snapshot.connected;
        },
        .set_theme => |id| {
            const preset = std.enums.fromInt(themes.Preset, id) orelse return;
            model.theme_picker_open = false;
            if (model.preferences.theme == preset) return;
            model.preferences.theme = preset;
            const palette = themes.palette(preset);
            win.styleMainWindow(palette.dark, palette.surface);
            changed = true;
        },
        .show_window => fx.showWindow("main"),
        .hide_window => {
            model.titlebar_hover = false;
            fx.hideWindow("main");
        },
        .minimize_window => {
            model.titlebar_hover = false;
            fx.minimizeWindow("main");
        },
        .zoom_window => win.toggleMainWindowZoom(),
        .titlebar_hover => |hovered| model.titlebar_hover = hovered,
        .quit => fx.quitApp(),
        .toggle_accept => {
            model.preferences.auto_accept = !model.preferences.auto_accept;
            changed = true;
        },
        .toggle_pick => {
            model.preferences.auto_pick = !model.preferences.auto_pick;
            changed = true;
        },
        .toggle_always_prioritize => {
            model.preferences.always_prioritize = !model.preferences.always_prioritize;
            changed = true;
        },
        .toggle_priority => |id| {
            if (model.preferences.rank(id) < t.max_priority) {
                model.preferences.remove(id);
            } else {
                model.preferences.add(id);
            }
            changed = true;
        },
        .remove => |id| {
            model.preferences.remove(id);
            changed = true;
        },
        .move_up => |id| {
            model.preferences.move(id, true);
            changed = true;
        },
        .move_down => |id| {
            model.preferences.move(id, false);
            changed = true;
        },
        .search => |edit| {
            model.detail.return_focus = 0;
            model.search.apply(edit);
            model.library_scroll = 0;
        },
        .library_scrolled => |scroll| {
            model.library_scroll = @max(0, scroll.offset_y);
            model.library_height = @max(grid.stride, scroll.viewport_extent_y);
        },
        .resized => |size| {
            model.canvas_width = size.width;
            model.canvas_height = size.height;
            // Overestimate until the scroll widget reports its actual viewport.
            model.library_height = @max(grid.stride, size.height - titlebar.height - 1);
        },
        .toast_timer => |timer| {
            if (timer.outcome == .fired) model.toasts.expire(win.now()) else model.toasts.count = 0;
            if (model.toasts.count == 0) fx.cancelTimer(toast_timer_key);
        },
        .dismiss_toast => {
            model.toasts.dismiss(win.now());
            if (model.toasts.count == 0) fx.cancelTimer(toast_timer_key);
        },
        .preview_toasts => if (preview_catalog.len > 0) {
            // Exercise the real queue and overlay while the main window is hidden.
            model.snapshot.accepted += 1;
            model.snapshot.swapped += 1;
            model.snapshot.last_pick_name.set("傲之追猎者");
            observeToasts(model, fx);
            fx.hideWindow("main");
        },
        .reconnect => {
            service.reconnect.store(true, .release);
            model.ui_error.set("");
        },
        .authorize_helper => {
            service.auth_retry.store(true, .release);
            model.ui_error.set("");
        },
        .snapshot => |event| {
            if (event.kind != .data) return;
            if (instance.takeActivation()) fx.showWindow("main");
            if (preview_catalog.len > 0) return;
            const old_generation = model.snapshot.catalog_generation;
            service.mutex.lock();
            model.snapshot = service.snapshot;
            service.mutex.unlock();
            if (old_generation != model.snapshot.catalog_generation) {
                if (portrait_loader) |loader| loader.cancelQueued();
                model.profile_image_pending = false;
                model.profile_image_generation +%= 1;
                for (0..portraits.atlas_count) |i| _ = fx.unregisterImage(portraits.imageId(i * portraits.per_atlas));
                model.portraits.deinit(std.heap.page_allocator);
                model.image_pending = @splat(false);
                model.image_failed = @splat(false);
                model.library_scroll = 0;
            }
            observeToasts(model, fx);
        },
        .portraits_ready => |event| {
            if (event.kind != .data) return;
            flushPortraits(model, fx);
        },
    }
    if (changed and preview_catalog.len == 0) service.configure(model.preferences);
    loadPortraits(model, fx);
}
fn closeDetailWeb(model: *Model) void {
    if (model.detail.web_ready) if (native_runtime) |runtime| runtime.closeView(1, "champion-web") catch {};
    model.detail.web_ready = false;
    model.detail.web_error = false;
}
fn checkUpdates(model: *Model) void {
    if (model.software_update.busy() or model.software_update.status == .ready) return;
    model.software_update.message.set("");
    if (preview_catalog.len > 0) {
        model.software_update.status = .current;
        return;
    }
    if (update_worker) |worker| {
        model.software_update.status = .checking;
        worker.submit(.{ .action = .Check });
    } else {
        model.software_update.status = .failed;
        model.software_update.message.set("更新服务未能启动，请重新打开程序。");
    }
}
fn beginUpdate(model: *Model) void {
    if (!model.software_update.available() or preview_catalog.len > 0) return;
    service.copy(&model.snapshot);
    if (!updater.canInstall(&model.snapshot)) return;
    if (update_worker) |worker| {
        const action: updater.Action = if (model.software_update.status == .ready) .Install else .Prepare;
        model.software_update.status = if (action == .Install) .arming else .downloading;
        model.software_update.message.set("");
        worker.submit(.{ .action = action, .version = model.software_update.version, .sha256 = model.software_update.sha256, .stage = model.software_update.stage });
    }
}
fn showDetailWeb(model: *Model) void {
    const runtime = native_runtime orelse return;
    model.detail.web_error = false;
    if (!model.detail.web_ready) {
        _ = runtime.createView(.{
            .label = "champion-web",
            .kind = .webview,
            .parent = "main-canvas",
            .frame = native.geometry.RectF.init(0, 0, 1, 1),
            .url = model.detail.url.text(),
            .bridge_enabled = false,
        }) catch {
            model.detail.web_error = true;
            return;
        };
        model.detail.web_ready = true;
    }
}
fn detailWebPanes(model: *const Model, out: []App.WebViewPane) usize {
    if (!model.detail.open or !model.detail.web_ready or model.detail.web_error) return 0;
    out[0] = .{ .label = "champion-web", .anchor = "英雄网页区域", .url = model.detail.url.text(), .reload_token = model.detail.reload };
    return 1;
}
fn observeToasts(model: *Model, fx: *Effects) void {
    const was_empty = model.toasts.count == 0;
    model.toasts.observe(&model.snapshot, win.now());
    if (was_empty and model.toasts.count > 0) {
        startToastTimer(model, fx);
    }
}
fn startToastTimer(model: *Model, fx: *Effects) void {
    const position = win.toastPosition(380, 116);
    model.toast_x = position.x;
    model.toast_y = position.y;
    fx.startTimer(.{ .key = toast_timer_key, .interval_ms = 150, .mode = .repeating, .on_fire = Effects.timerMsg(.toast_timer) });
}
fn toastWindows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    if (model.toasts.count == 0) return &.{};
    scratch.windows[0] = .{
        .label = "success-toast",
        .canvas_label = "toast-canvas",
        .title = "Catengar · 通知",
        .width = 380,
        .height = 116,
        .x = model.toast_x,
        .y = model.toast_y,
        .resizable = false,
        .titlebar = .chromeless,
        .transparent = true,
        .always_on_top = true,
        .activate_on_show = false,
        .allows_fullscreen = false,
        .on_close = .dismiss_toast,
    };
    return scratch.windows[0..1];
}
fn toastView(ui: *App.Ui, model: *const Model, _: []const u8) App.Ui.Node {
    win.prepareToastWindow();
    return canvas.CompiledMarkupView(Model, Msg, @embedFile("toast.native")).build(ui, model);
}
fn flushPortraits(model: *Model, fx: *Effects) void {
    const loader = portrait_loader orelse return;
    var dirty: [portraits.atlas_count]bool = @splat(false);
    var added: [t.max_champions]bool = @splat(false);
    while (loader.take()) |result| {
        defer result.deinit();
        if (result.index == profile_job_index) {
            if (result.generation != model.profile_image_generation or !model.hasProfile()) continue;
            model.profile_image_pending = false;
            model.profile_image_failed = true;
            if (result.pixels) |pixels| {
                fx.registerImage(profile_image_id, portraits.tile, portraits.tile, pixels) catch continue;
                model.profile_image_ready = true;
                model.profile_image_failed = false;
            }
            continue;
        }
        if (result.generation != model.snapshot.catalog_generation or result.index >= model.snapshot.champion_count) continue;
        const index = result.index;
        model.image_pending[index] = false;
        const pixels = result.pixels orelse {
            model.image_failed[index] = true;
            continue;
        };
        _ = model.portraits.put(std.heap.page_allocator, index, portraits.tile, portraits.tile, pixels) catch {
            model.image_failed[index] = true;
            continue;
        };
        dirty[index / portraits.per_atlas] = true;
        added[index] = true;
    }
    for (dirty, 0..) |changed, slot| if (changed) {
        fx.registerImage(portraits.imageId(slot * portraits.per_atlas), portraits.side, portraits.side, model.portraits.pixels[slot]) catch {
            for (0..portraits.per_atlas) |j| {
                const index = slot * portraits.per_atlas + j;
                if (index >= t.max_champions) break;
                if (added[index]) model.image_failed[index] = true;
            }
            continue;
        };
        for (0..portraits.per_atlas) |j| {
            const index = slot * portraits.per_atlas + j;
            if (index >= t.max_champions) break;
            if (added[index]) model.portraits.ready[index] = true;
        }
    };
}
fn loadPortraits(model: *Model, fx: *Effects) void {
    const path = if (model.hasProfile()) model.snapshot.profile.icon_path.text() else "";
    const id = if (model.hasProfile()) model.snapshot.profile.riot_id.text() else "";
    if (!std.mem.eql(u8, model.profile_copy_id.text(), id)) {
        model.profile_copy_id.set(id);
        model.profile_copy = .idle;
        fx.cancelTimer(profile_copy_timer_key);
    }
    if (!std.mem.eql(u8, model.profile_image_path.text(), path)) {
        _ = fx.unregisterImage(profile_image_id);
        model.profile_image_path.set(path);
        model.profile_image_generation +%= 1;
        model.profile_image_pending = false;
        model.profile_image_ready = false;
        model.profile_image_failed = false;
    }
    const loader = portrait_loader orelse return;
    if (path.len > 0 and !model.profile_image_ready and !model.profile_image_pending and !model.profile_image_failed) {
        model.profile_image_pending = loader.submit(.{ .generation = model.profile_image_generation, .index = profile_job_index, .path = model.profile_image_path });
    }
    var pending: usize = if (model.profile_image_pending) 1 else 0;
    for (model.image_pending) |p| if (p) {
        pending += 1;
    };
    const window = model.gridWindow();
    // Only decode visible/overscan and selected heroes. Retain decoded tiles
    // when they leave the viewport; scrolling back never re-decodes them.
    {
        var matched: usize = 0;
        for (model.snapshot.champions[0..model.snapshot.champion_count], 0..) |*c, i| {
            const matches = model.matches(c);
            const urgent = model.preferences.rank(c.id) < t.max_priority or (matches and matched >= window.start and matched < window.end);
            if (matches) matched += 1;
            if (pending >= 8) return;
            if (!urgent or model.portraits.ready[i] or model.image_pending[i] or model.image_failed[i] or c.icon_path.len == 0) continue;
            if (!loader.submit(.{ .generation = model.snapshot.catalog_generation, .index = i, .path = c.icon_path })) return;
            model.image_pending[i] = true;
            pending += 1;
        }
    }
}
fn color(rgb: u24) canvas.Color {
    return canvas.Color.rgb8(@intCast(rgb >> 16), @intCast((rgb >> 8) & 0xff), @intCast(rgb & 0xff));
}
fn tokens(model: *const Model) canvas.DesignTokens {
    const p = themes.palette(model.preferences.theme);
    var theme = canvas.DesignTokens.theme(.{ .color_scheme = if (p.dark) .dark else .light });
    // Windows already supplies wheel/precision-touchpad deltas. Native's
    // default adds velocity = delta * 60 with only 14% decay per second,
    // making one notch coast for seconds. Follow input without extra inertia.
    theme.scroll.wheel_velocity_scale = 0;
    theme.scroll.overscroll = .none;
    theme.colors.background = color(p.background);
    theme.colors.surface = color(p.surface);
    theme.colors.surface_subtle = color(p.subtle);
    theme.colors.surface_pressed = color(p.pressed);
    theme.colors.border = color(p.border);
    theme.colors.text = color(p.text);
    theme.colors.text_muted = color(p.muted);
    theme.colors.accent = color(p.accent);
    theme.colors.accent_text = color(p.accent_text);
    theme.colors.success = color(p.success);
    theme.colors.warning = color(p.warning);
    theme.colors.destructive = color(p.danger);
    theme.colors.disabled = color(p.subtle);
    theme.colors.focus_ring = theme.colors.accent;
    theme.controls.button_outline = .{ .background = color(p.surface), .border = color(p.border) };
    theme.controls.button_group_style = .detached;
    theme.controls.button_group = .{
        .background = color(p.surface),
        .foreground = color(p.muted),
        .hover_background = color(p.subtle),
        .active_background = color(p.accent),
        .active_foreground = color(p.accent_text),
        .border = color(p.border),
        .radius = 8,
    };
    if (model.has_cjk_font) theme.typography.font_id = 64;
    return theme;
}
fn command(name: []const u8) ?Msg {
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-updates")) return .preview_updates;
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-update-blocked")) return .preview_update_blocked;
    if (std.mem.eql(u8, name, "catengar.show")) return .show_window;
    if (std.mem.eql(u8, name, "catengar.quit")) return .quit;
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-toasts")) return .preview_toasts;
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-connection")) return .preview_connection;
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-logs")) return .preview_logs;
    return null;
}
const tray_items = [_]native.TrayMenuItem{
    .{ .id = 1, .label = "打开 Catengar", .command = "catengar.show" },
    .{ .separator = true },
    .{ .id = 2, .label = "完全退出", .command = "catengar.quit" },
};
fn startNative(context: *anyopaque, runtime: *native.Runtime) !void {
    native_runtime = runtime;
    const hwnd = win.mainWindow();
    window_state.install(hwnd);
    win.setAuthorizationOwner(hwnd);
    @import("app_icon.zig").applyWindow();
    const palette = themes.palette(service.preferences.theme);
    win.styleMainWindow(palette.dark, palette.surface);
    // Native 6b053188's Runtime.initAt skips defaults larger than 4096 bytes,
    // including the status-item register. Initialize its small live headers;
    // leave unused menu storage untouched. Otherwise poisoned active flags
    // make the very first tray install fail with InvalidTrayOptions.
    for (&runtime.status_items) |*item| {
        item.id = 0;
        item.active = false;
        item.visible = true;
        item.title = "";
        item.item_count = 0;
    }
    runtime.status_item_count = 0;
    if (native_start) |start| try start(context, runtime);
}
fn mainView(ui: *canvas.Ui(Msg), model: *const Model) canvas.Ui(Msg).Node {
    var content = ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        titlebar.build(Msg, ui, model.titlebar_hover, model.titlebar_logo_ready),
        canvas.CompiledMarkupView(Model, Msg, @embedFile("app.native")).build(ui, model),
    });
    if (model.about_open or model.detail.open) content = disableBackground(ui, content);
    return ui.el(.stack, .{ .grow = 1 }, .{
        content,
        if (model.about_open) canvas.CompiledMarkupView(Model, Msg, @embedFile("about.native")).build(ui, model) else ui.el(.stack, .{}, .{}),
        if (model.detail.open) canvas.CompiledMarkupView(Model, Msg, @embedFile("champion_detail.native")).build(ui, model) else ui.el(.stack, .{}, .{}),
    });
}
// Native's disabled flag is per-widget, not inherited. Keep the backdrop
// visible while excluding every underlying control from pointer/Tab routing.
fn disableBackground(ui: *canvas.Ui(Msg), source: canvas.Ui(Msg).Node) canvas.Ui(Msg).Node {
    var node = source;
    node.widget.state.disabled = true;
    if (source.nodes.len > 0) {
        const children = ui.arena.dupe(canvas.Ui(Msg).Node, source.nodes) catch {
            ui.failed = true;
            return node;
        };
        for (children) |*child| child.* = disableBackground(ui, child.*);
        node.nodes = children;
    }
    return node;
}
const scene: native.ShellConfig = .{ .windows = &.{.{ .label = "main", .title = "Catengar", .width = 1120, .height = 800, .restore_state = false, .titlebar = .chromeless, .min_width = 880, .min_height = 720, .close_policy = .hide, .views = &.{.{ .label = "main-canvas", .kind = .gpu_surface, .fill = true }} }} };
pub fn main(init: std.process.Init) !void {
    defer ime.deinit();
    const root = try win.dataDirectory(std.heap.page_allocator);
    defer std.heap.page_allocator.free(root);
    instance = (try @import("instance.zig").Instance.acquire(std.heap.page_allocator, init.io, root)) orelse return;
    defer instance.deinit();
    window_state = try @import("window_state.zig").State.init(std.heap.page_allocator, init.io, root);
    defer window_state.deinit();
    defer win.setAuthorizationOwner(null);
    service = try std.heap.page_allocator.create(Service);
    service.* = .{};
    defer std.heap.page_allocator.destroy(service);
    try service.init(init.io);
    defer {
        service.deinit();
        if (journal_worker) |worker| worker.destroy();
    }
    const icon_path = try @import("app_icon.zig").prepare(std.heap.page_allocator, init.io, root);
    defer std.heap.page_allocator.free(icon_path);
    const font_bytes = @import("font.zig").load(std.heap.page_allocator, init.io) catch null;
    defer if (font_bytes) |bytes| std.heap.page_allocator.free(bytes);
    var fonts: [1]App.FontRegistration = undefined;
    if (font_bytes) |bytes| fonts[0] = .{ .id = 64, .name = "Windows CJK", .ttf = bytes };
    const app = try App.create(std.heap.page_allocator, .{
        .name = "Catengar",
        .scene = scene,
        .canvas_label = "main-canvas",
        .tokens_fn = tokens,
        .fonts = if (font_bytes != null) &fonts else &.{},
        .update_fx = update,
        .on_frame = frameMsg,
        .init_fx = initFx,
        .on_command = command,
        .windows_fn = toastWindows,
        .window_view = toastView,
        .status_item = .{
            .title = "C",
            .icon_path = icon_path,
            .tooltip = "Catengar · League 助手",
            .activation_command = "catengar.show",
            .items = &tray_items,
        },
        .view = mainView,
        .web_panes = detailWebPanes,
    });
    defer app.destroy();
    defer if (portrait_loader) |loader| loader.destroy();
    defer if (update_worker) |worker| worker.destroy();
    defer app.model.portraits.deinit(std.heap.page_allocator);
    app.model.preferences = service.preferences;
    if (preview_catalog.len == 0) app.model.software_update.notice = updater.readNotice(init.io, root);
    app.model.has_cjk_font = font_bytes != null;
    service.copy(&app.model.snapshot);
    if (preview_catalog.len > 0) {
        try @import("preview.zig").load(std.heap.page_allocator, init.io, preview_catalog, &app.model.snapshot);
        app.model.preferences.auto_accept = false;
        app.model.preferences.auto_pick = false;
    }
    var native_app = app.app();
    native_start = native_app.start_fn;
    native_app.start_fn = startNative;
    try runner.runWithOptions(native_app, .{
        .app_name = "Catengar",
        .window_title = "Catengar",
        .bundle_id = "dev.catengar.lcu",
        .icon_path = icon_path,
        // runWithOptions does not inherit app.zon's permission register.
        // Honor its filesystem grant for our existing local LCU cache.
        .security = .{
            .permissions = &.{native.security.permission_filesystem},
            .navigation = .{ .allowed_origins = &.{ "zero://app", "zero://inline", "https://haidou.pro" }, .external_links = .{ .action = .open_system_browser, .allowed_urls = &.{ app_repository_url, "https://haidou.pro/champion/*" } } },
        },
        .default_frame = native.geometry.RectF.init(0, 0, 1120, 800),
        .js_window_api = false,
    }, init);
}
