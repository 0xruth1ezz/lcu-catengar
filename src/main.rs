#![windows_subsystem = "windows"]
fn main() {
    if std::env::args().any(|a| a == "--version") {
        return;
    }
    let offline = std::env::args().any(|a| a == "--preview")
        || std::env::var_os("CATENGAR_OFFLINE").is_some();
    let mut root = catengar::storage::data_dir();
    if offline && std::env::var_os("CATENGAR_DATA_DIR").is_none() {
        root = root.with_file_name("LoLRengar-preview");
    }
    if let Err(error) = catengar::platform::run(root, offline) {
        nsh_platform_windows::fatal_error(&format!("Catengar 无法启动：{error}"));
    }
}
