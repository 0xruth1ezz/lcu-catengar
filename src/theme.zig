const std = @import("std");

pub const Preset = enum(u8) {
    chatgpt_dark,
    chatgpt_light,
    nord,
    catppuccin,
    classic_gold,

    pub fn fromName(name: []const u8) Preset {
        return std.meta.stringToEnum(Preset, name) orelse default_preset;
    }
    pub fn label(self: Preset) []const u8 {
        return switch (self) {
            .chatgpt_dark => "ChatGPT 深色",
            .chatgpt_light => "ChatGPT 浅色",
            .nord => "Nord 北欧",
            .catppuccin => "Catppuccin",
            .classic_gold => "经典金色",
        };
    }
};
pub const default_preset: Preset = .classic_gold;
pub const presets = [_]Preset{ .classic_gold, .chatgpt_dark, .chatgpt_light, .nord, .catppuccin };

/// RGB values are kept independent of the renderer and configuration format.
/// ChatGPT palettes are an adaptation, not an official client theme export.
/// Nord: https://www.nordtheme.com/docs/colors-and-palettes/
/// Catppuccin Mocha: https://catppuccin.com/palette/
pub const Palette = struct {
    dark: bool = true,
    background: u24,
    surface: u24,
    subtle: u24,
    pressed: u24,
    border: u24,
    text: u24,
    muted: u24,
    accent: u24,
    accent_text: u24,
    success: u24,
    warning: u24,
    danger: u24,
};
pub fn palette(preset: Preset) Palette {
    return switch (preset) {
        .chatgpt_dark => .{
            .background = 0x212121,
            .surface = 0x282828,
            .subtle = 0x303030,
            .pressed = 0x424242,
            .border = 0x484848,
            .text = 0xf4f4f4,
            .muted = 0xb4b4b4,
            .accent = 0xf4f4f4,
            .accent_text = 0x212121,
            .success = 0x65c49a,
            .warning = 0xe6bd70,
            .danger = 0xf28b82,
        },
        .chatgpt_light => .{
            .dark = false,
            .background = 0xf7f7f8,
            .surface = 0xffffff,
            .subtle = 0xededee,
            .pressed = 0xdadadc,
            .border = 0xd5d5d8,
            .text = 0x0d0d0d,
            .muted = 0x646467,
            .accent = 0x212121,
            .accent_text = 0xffffff,
            .success = 0x18794e,
            .warning = 0x91610a,
            .danger = 0xb42318,
        },
        .nord => .{
            .background = 0x2e3440,
            .surface = 0x3b4252,
            .subtle = 0x434c5e,
            .pressed = 0x4c566a,
            .border = 0x5a657c,
            .text = 0xeceff4,
            .muted = 0xd8dee9,
            .accent = 0x88c0d0,
            .accent_text = 0x2e3440,
            .success = 0xa3be8c,
            .warning = 0xebcb8b,
            .danger = 0xe58e97,
        },
        .catppuccin => .{
            .background = 0x181825,
            .surface = 0x1e1e2e,
            .subtle = 0x313244,
            .pressed = 0x45475a,
            .border = 0x585b70,
            .text = 0xcdd6f4,
            .muted = 0xa6adc8,
            .accent = 0xcba6f7,
            .accent_text = 0x1e1e2e,
            .success = 0xa6e3a1,
            .warning = 0xf9e2af,
            .danger = 0xf38ba8,
        },
        .classic_gold => .{
            .background = 0x0a0a0a,
            .surface = 0x171717,
            .subtle = 0x262626,
            .pressed = 0x3c3c3c,
            .border = 0x393939,
            .text = 0xfafafa,
            .muted = 0xa1a1a1,
            .accent = 0xd6b773,
            .accent_text = 0x181715,
            .success = 0x4ade80,
            .warning = 0xf5b942,
            .danger = 0xff6467,
        },
    };
}
