const std = @import("std");
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
const toast_timer_key = 71;
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

pub const Row = struct { id: i32, name: []const u8, alias: []const u8, image: u64, source_x: usize = 0, source_y: usize = 0, action_label: []const u8 = "", rank: usize, selected: bool };
pub const ThemeRow = struct { id: u8, name: []const u8, selected: bool };
pub const Model = struct {
    snapshot: t.Snapshot = .{},
    preferences: t.Preferences = .{},
    theme_picker_open: bool = false,
    titlebar_hover: bool = false,
    has_cjk_font: bool = false,
    search: canvas.TextBuffer(128) = .{},
    library_scroll: f32 = 0,
    library_height: f32 = 300,
    canvas_width: f32 = 1120,
    canvas_height: f32 = 800,
    portraits: portraits.Store = .{},
    image_pending: [t.max_champions]bool = @splat(false),
    image_failed: [t.max_champions]bool = @splat(false),
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
        return .{ .id = c.id, .name = c.name.text(), .alias = c.alias.text(), .image = if (self.portraits.ready[i]) portraits.imageId(i) else 0, .source_x = portraits.x(i), .source_y = portraits.y(i), .action_label = std.fmt.allocPrint(arena, "{s} {s}", .{ if (selected) "取消优先选择" else "优先选择", c.name.text() }) catch c.name.text(), .rank = rank + 1, .selected = selected };
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
    pub fn phaseLabel(self: *const Model) []const u8 {
        const phase = self.snapshot.phase.text();
        const pairs = .{ .{ "None", "客户端空闲" }, .{ "Lobby", "房间内" }, .{ "Matchmaking", "寻找对局" }, .{ "ReadyCheck", "等待接受" }, .{ "ChampSelect", "英雄选择" }, .{ "InProgress", "对局中" }, .{ "GameStart", "开始对局" }, .{ "EndOfGame", "对局结束" } };
        inline for (pairs) |pair| if (std.mem.eql(u8, phase, pair[0])) return pair[1];
        return phase;
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
    pub fn logs(self: *const Model) []const t.Text(192) {
        return self.snapshot.logs[0..@min(self.snapshot.log_count, 3)];
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
    show_window,
    hide_window,
    minimize_window,
    zoom_window,
    titlebar_hover: bool,
    quit,
    toggle_accept,
    toggle_pick,
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
    snapshot: native.EffectChannelEvent,
    portraits_ready: native.EffectChannelEvent,
};
fn notifyPortraits() bool {
    return portrait_channel.post("ready") != .closed;
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
    channel = fx.openChannel(.{ .key = 1, .on_event = Effects.channelMsg(.snapshot), .max_pending = 1 });
    portrait_channel = fx.openChannel(.{ .key = 2, .on_event = Effects.channelMsg(.portraits_ready), .max_pending = 1 });
    portrait_loader = portrait_worker.Worker.create(notifyPortraits) catch null;
    instance.watch(notify) catch {};
    if (preview_catalog.len > 0) {
        loadPortraits(model, fx);
        return;
    }
    if (channel.live()) service.start(notify) catch {
        model.ui_error.set("后台服务启动失败，请重新打开工具。");
    };
}
pub fn update(model: *Model, msg: Msg, fx: *Effects) void {
    var changed = false;
    switch (msg) {
        .toggle_theme_picker => model.theme_picker_open = !model.theme_picker_open,
        .close_theme_picker => model.theme_picker_open = false,
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
            model.library_height = @max(grid.stride, size.height - 418 - titlebar.height - 1);
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
fn observeToasts(model: *Model, fx: *Effects) void {
    const was_empty = model.toasts.count == 0;
    model.toasts.observe(&model.snapshot, win.now());
    if (was_empty and model.toasts.count > 0) {
        const position = win.toastPosition(380, 116);
        model.toast_x = position.x;
        model.toast_y = position.y;
        fx.startTimer(.{ .key = toast_timer_key, .interval_ms = 150, .mode = .repeating, .on_fire = Effects.timerMsg(.toast_timer) });
    }
}
fn toastWindows(model: *const Model, scratch: *App.WindowsScratch) []const App.WindowDescriptor {
    if (model.toasts.count == 0) return &.{};
    scratch.windows[0] = .{
        .label = "success-toast",
        .canvas_label = "toast-canvas",
        .title = "Catengar · 操作成功",
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
                if (added[index]) model.image_failed[index] = true;
            }
            continue;
        };
        for (0..portraits.per_atlas) |j| {
            const index = slot * portraits.per_atlas + j;
            if (added[index]) model.portraits.ready[index] = true;
        }
    };
}
fn loadPortraits(model: *Model, fx: *Effects) void {
    _ = fx;
    const loader = portrait_loader orelse return;
    var pending: usize = 0;
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
    if (std.mem.eql(u8, name, "catengar.show")) return .show_window;
    if (std.mem.eql(u8, name, "catengar.quit")) return .quit;
    if (preview_catalog.len > 0 and std.mem.eql(u8, name, "catengar.preview-toasts")) return .preview_toasts;
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
    return ui.column(.{ .grow = 1, .style_tokens = .{ .background = .background } }, .{
        titlebar.build(Msg, ui, model.titlebar_hover),
        canvas.CompiledMarkupView(Model, Msg, @embedFile("app.native")).build(ui, model),
    });
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
    defer service.deinit();
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
            .tooltip = "Catengar · 极地助手",
            .activation_command = "catengar.show",
            .items = &tray_items,
        },
        .view = mainView,
    });
    defer app.destroy();
    defer if (portrait_loader) |loader| loader.destroy();
    defer app.model.portraits.deinit(std.heap.page_allocator);
    app.model.preferences = service.preferences;
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
        .security = .{ .permissions = &.{native.security.permission_filesystem} },
        .default_frame = native.geometry.RectF.init(0, 0, 1120, 800),
        .js_window_api = false,
    }, init);
}
