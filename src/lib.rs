pub mod auth;
pub mod engine;
pub mod journal;
pub mod model;
pub mod notifications;
pub mod platform;
pub mod service;
pub mod storage;
pub mod transport;
pub mod ui;
pub mod updater;

pub const VERSION: &str = env!("CARGO_PKG_VERSION");
pub fn display_version() -> &'static str {
    VERSION.strip_suffix(".0").unwrap_or(VERSION)
}
