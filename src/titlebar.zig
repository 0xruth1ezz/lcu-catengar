const native = @import("native_sdk");
const canvas = native.canvas;

pub const height = 48;

/// Real, keyboard-accessible buttons sit below the decorative traffic lights.
/// Native excludes their hit targets from the surrounding OS drag region.
pub fn build(comptime Msg: type, ui: *canvas.Ui(Msg), hovered: bool) canvas.Ui(Msg).Node {
    return ui.column(.{}, .{
        ui.row(.{
            .height = height,
            .padding = 12,
            .cross = .center,
            .window_drag = true,
            .style_tokens = .{ .background = .surface },
            .semantics = .{ .label = "窗口标题栏" },
        }, .{
            ui.row(.{
                .gap = 2,
                .width = 80,
                .on_hover_enter = .{ .titlebar_hover = true },
                .on_hover_leave = .{ .titlebar_hover = false },
            }, .{
                light(Msg, ui, 0xff6058, 0xd84840, "x", .hide_window, "关闭到托盘", hovered),
                light(Msg, ui, 0xffbd2e, 0xd89b20, "minus", .minimize_window, "最小化", hovered),
                light(Msg, ui, 0x28c840, 0x1ba832, "maximize-2", .zoom_window, "最大化或还原", hovered),
            }),
            ui.spacer(1),
            ui.text(.{ .size = .sm, .style_tokens = .{ .foreground = .text_muted } }, "Catengar"),
            ui.spacer(1),
            ui.el(.stack, .{ .width = 80 }, .{}),
        }),
        ui.el(.stack, .{ .height = 1, .opacity = 0.35, .style_tokens = .{ .background = .border } }, .{}),
    });
}

fn light(comptime Msg: type, ui: *canvas.Ui(Msg), rgb: u24, edge: u24, comptime icon: []const u8, message: Msg, label: []const u8, hovered: bool) canvas.Ui(Msg).Node {
    return ui.el(.stack, .{ .width = 24, .height = 24 }, .{
        ui.button(.{
            .width = 24,
            .height = 24,
            .variant = .ghost,
            .on_press = message,
            .style = .{ .radius = 12 },
            .semantics = .{ .label = label },
        }, ""),
        ui.column(.{ .main = .center, .cross = .center }, .{
            ui.el(.stack, .{
                .width = 14,
                .height = 14,
                .style = .{ .background = color(rgb), .border = color(edge), .stroke_width = 0.6, .radius = 7 },
            }, .{
                // A small specular edge gives the lights a glass-like finish.
                ui.column(.{ .cross = .center, .padding = 1.5 }, .{
                    ui.el(.stack, .{ .width = 7, .height = 2, .style = .{ .background = canvas.Color.rgba8(255, 255, 255, 85), .radius = 1 } }, .{}),
                }),
                ui.column(.{ .main = .center, .cross = .center, .opacity = if (hovered) 1 else 0 }, .{
                    if (comptime @import("std").mem.eql(u8, icon, "minus"))
                        ui.el(.stack, .{ .width = 8, .height = 1.25, .style = .{ .background = canvas.Color.rgba8(0, 0, 0, 170), .radius = 0.5 } }, .{})
                    else if (comptime @import("std").mem.eql(u8, icon, "maximize-2"))
                        ui.el(.stack, .{ .width = 6, .height = 6, .style = .{ .border = canvas.Color.rgba8(0, 0, 0, 170), .stroke_width = 1, .radius = 0.75 } }, .{})
                    else
                        ui.icon(.{ .width = 9, .height = 9, .style = .{ .foreground = canvas.Color.rgba8(0, 0, 0, 170) } }, icon),
                }),
            }),
        }),
    });
}

fn color(rgb: u24) canvas.Color {
    return canvas.Color.rgb8(@intCast(rgb >> 16), @intCast((rgb >> 8) & 255), @intCast(rgb & 255));
}
