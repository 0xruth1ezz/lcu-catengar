//! Hallmark v2.0.0: locked native theme, app scope, restrained colour.
use crate::model::Theme;

pub(crate) const UI_FONT: &str = "Microsoft YaHei UI";
pub(crate) const TEXT_BODY: f32 = 14.;
pub(crate) const TEXT_SMALL: f32 = 12.;
pub(crate) const TEXT_HEADING: f32 = 20.;
pub(crate) const CONTROL_HEIGHT: f32 = 36.;
pub(crate) const CONTROL_RADIUS: f32 = 7.;
pub(crate) const PANEL_RADIUS: f32 = 12.;
pub(crate) const CONTENT_MAX: f32 = 1360.;
pub(crate) const SPACE_1: f32 = 4.;
pub(crate) const SPACE_2: f32 = 8.;
pub(crate) const SPACE_3: f32 = 12.;
pub(crate) const SPACE_4: f32 = 16.;
pub(crate) const SPACE_5: f32 = 20.;
pub(crate) const SPACE_6: f32 = 24.;
pub(crate) const SPACE_7: f32 = 28.;
pub(crate) const WINDOW_CLOSE: u32 = 0xff5f57;
pub(crate) const WINDOW_MINIMIZE: u32 = 0xfebc2e;
pub(crate) const WINDOW_MAXIMIZE: u32 = 0x28c840;
pub(crate) const DIALOG_SCRIM: u32 = 0x00000099;

#[derive(Clone, Copy)]
pub(crate) struct Colors {
    pub bg: u32,
    pub surface: u32,
    pub subtle: u32,
    pub border: u32,
    pub text: u32,
    pub muted: u32,
    pub accent: u32,
    pub on_accent: u32,
    pub danger: u32,
}
pub(crate) fn colors(theme: Theme) -> Colors {
    match theme {
        Theme::ClassicGold => Colors {
            bg: 0x0a0a0a,
            surface: 0x171717,
            subtle: 0x262626,
            border: 0x393939,
            text: 0xfafafa,
            muted: 0xa1a1a1,
            accent: 0xd6b773,
            on_accent: 0x181715,
            danger: 0xff6467,
        },
        Theme::ChatgptDark => Colors {
            bg: 0x171717,
            surface: 0x212121,
            subtle: 0x303030,
            border: 0x4a4a4a,
            text: 0xf5f5f5,
            muted: 0xb4b4b4,
            accent: 0xffffff,
            on_accent: 0x171717,
            danger: 0xff8080,
        },
        Theme::ChatgptLight => Colors {
            bg: 0xf7f7f8,
            surface: 0xffffff,
            subtle: 0xeeeeef,
            border: 0xd0d0d5,
            text: 0x202123,
            muted: 0x606067,
            accent: 0x202123,
            on_accent: 0xffffff,
            danger: 0xb42318,
        },
        Theme::Nord => Colors {
            bg: 0x2e3440,
            surface: 0x3b4252,
            subtle: 0x434c5e,
            border: 0x5a657c,
            text: 0xeceff4,
            muted: 0xd8dee9,
            accent: 0x88c0d0,
            on_accent: 0x2e3440,
            danger: 0xe58e97,
        },
        Theme::Catppuccin => Colors {
            bg: 0x181825,
            surface: 0x1e1e2e,
            subtle: 0x313244,
            border: 0x585b70,
            text: 0xcdd6f4,
            muted: 0xa6adc8,
            accent: 0xcba6f7,
            on_accent: 0x1e1e2e,
            danger: 0xf38ba8,
        },
    }
}
