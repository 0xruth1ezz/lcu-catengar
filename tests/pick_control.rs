//! Isolated native-window regression; never connects to League or requests UAC.
use catengar::{
    model::{RoundPick, Theme},
    platform, service, storage,
};
use std::{
    thread,
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::*,
    Graphics::Gdi::*,
    System::Threading::GetCurrentProcessId,
    UI::{HiDpi::GetDpiForWindow, WindowsAndMessaging::*},
};

fn wait(mut condition: impl FnMut() -> bool, seconds: u64) {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while !condition() {
        assert!(Instant::now() < deadline, "native pick control timed out");
        thread::sleep(Duration::from_millis(20));
    }
}
fn window(title: &str) -> Option<HWND> {
    struct Search<'a> {
        title: &'a str,
        found: Option<HWND>,
    }
    unsafe extern "system" fn visit(hwnd: HWND, param: LPARAM) -> windows::core::BOOL {
        unsafe {
            let search = &mut *(param.0 as *mut Search<'_>);
            let mut pid = 0;
            GetWindowThreadProcessId(hwnd, Some(&mut pid));
            if pid == GetCurrentProcessId() && IsWindowVisible(hwnd).as_bool() {
                let mut text = [0u16; 128];
                let len = GetWindowTextW(hwnd, &mut text);
                if String::from_utf16_lossy(&text[..len as usize]) == search.title {
                    search.found = Some(hwnd);
                }
            }
            true.into()
        }
    }
    let mut search = Search { title, found: None };
    unsafe {
        let _ = EnumWindows(
            Some(visit),
            LPARAM((&mut search as *mut Search<'_>) as isize),
        );
    }
    search.found
}

fn point(x: i32, y: i32) -> LPARAM {
    LPARAM(((x as u16 as u32) | ((y as u16 as u32) << 16)) as isize)
}
fn rect(hwnd: HWND) -> RECT {
    let mut r = RECT::default();
    unsafe {
        GetWindowRect(hwnd, &mut r).unwrap();
    }
    r
}
fn click(hwnd: HWND) {
    let r = rect(hwnd);
    let (x, y) = ((r.right - r.left) / 2, (r.bottom - r.top) / 2);
    // Drive only the isolated window. Global pointer injection can be denied
    // by the input desktop and would also interfere with the user's mouse.
    unsafe {
        SendMessageW(hwnd, WM_LBUTTONDOWN, Some(WPARAM(1)), Some(point(x, y)));
        SendMessageW(hwnd, WM_LBUTTONUP, Some(WPARAM(0)), Some(point(x, y)));
    }
}
fn capture(hwnd: HWND, name: &str) {
    let Some(directory) = std::env::var_os("CATENGAR_CAPTURE_DIR") else {
        return;
    };
    thread::sleep(Duration::from_millis(250));
    let path = std::path::PathBuf::from(directory).join(format!("{name}.png"));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    let r = rect(hwnd);
    // Optional visual evidence: crop only this isolated preview button.
    use std::os::windows::process::CommandExt;
    let result = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-NonInteractive", "-Command", r#"
            Add-Type -AssemblyName System.Drawing
            $bitmap = New-Object System.Drawing.Bitmap([int]$env:CATENGAR_CAPTURE_WIDTH, [int]$env:CATENGAR_CAPTURE_HEIGHT)
            $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
            $graphics.CopyFromScreen([int]$env:CATENGAR_CAPTURE_LEFT, [int]$env:CATENGAR_CAPTURE_TOP, 0, 0, $bitmap.Size)
            $bitmap.Save($env:CATENGAR_CAPTURE_PATH, [System.Drawing.Imaging.ImageFormat]::Png)
            $graphics.Dispose()
            $bitmap.Dispose()
        "#])
        .env("CATENGAR_CAPTURE_LEFT", r.left.to_string())
        .env("CATENGAR_CAPTURE_TOP", r.top.to_string())
        .env("CATENGAR_CAPTURE_WIDTH", (r.right-r.left).to_string())
        .env("CATENGAR_CAPTURE_HEIGHT", (r.bottom-r.top).to_string())
        .env("CATENGAR_CAPTURE_PATH", path)
        .creation_flags(0x08000000)
        .output().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stderr)
    );
}

#[test]
#[ignore = "opens isolated preview windows; run cargo test --test pick_control -- --ignored"]
fn single_button_toggles_drags_persists_and_hides_without_changing_saved_automation() {
    let root = tempfile::tempdir().unwrap();
    let driver = thread::spawn(|| {
        let result = std::panic::catch_unwind(|| {
            const TITLE: &str = "Catengar · 本局自动抢英雄";
            wait(
                || service::SERVICE.get().is_some() && window("Catengar").is_some(),
                15,
            );
            let app = service::global();
            let mut p = app.read().prefs;
            p.priority = vec![107];
            app.configure(p);
            let main = window("Catengar").unwrap();
            unsafe {
                PostMessageW(Some(main), WM_CLOSE, WPARAM(0), LPARAM(0)).unwrap();
            }
            wait(|| window("Catengar").is_none(), 3);
            let foreground = unsafe { GetForegroundWindow() };
            {
                let mut round = app.round_pick.lock().unwrap();
                round.enter(9);
                round.available = true;
            }
            wait(|| window(TITLE).is_some(), 5);
            let button = window(TITLE).unwrap();
            thread::sleep(Duration::from_millis(250));
            let start = rect(button);
            unsafe {
                assert_eq!(
                    GetForegroundWindow(),
                    foreground,
                    "button stole focus on appearance"
                );
                let style = GetWindowLongPtrW(button, GWL_EXSTYLE) as u32;
                assert_ne!(style & WS_EX_NOACTIVATE.0, 0);
                assert_ne!(style & WS_EX_TOPMOST.0, 0);
                assert_ne!(style & WS_EX_TOOLWINDOW.0, 0);
                let mut monitor = MONITORINFO {
                    cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                    ..Default::default()
                };
                assert!(
                    GetMonitorInfoW(
                        MonitorFromWindow(button, MONITOR_DEFAULTTONEAREST),
                        &mut monitor
                    )
                    .as_bool()
                );
                assert_eq!(monitor.rcWork.right - start.right, 16);
                assert!(
                    (start.top + start.bottom - monitor.rcWork.top - monitor.rcWork.bottom).abs()
                        <= 1
                );
                let scale = GetDpiForWindow(button) as f32 / 96.;
                assert_eq!(start.right - start.left, (168. * scale) as i32);
                assert_eq!(start.bottom - start.top, (44. * scale) as i32);
            }
            capture(button, "pick-control-paused-classic");
            click(button);
            wait(|| app.read().round_pick.override_pick == Some(true), 2);
            assert!(!app.read().prefs.auto_pick);
            for theme in Theme::ALL {
                let mut p = app.read().prefs;
                p.theme = theme;
                app.configure(p);
                capture(button, &format!("pick-control-enabled-{theme:?}"));
            }
            // Pointer movement moves the button itself; release must not toggle.
            unsafe {
                SendMessageW(button, WM_LBUTTONDOWN, Some(WPARAM(1)), Some(point(80, 20)));
                SendMessageW(button, WM_MOUSEMOVE, Some(WPARAM(1)), Some(point(-40, 100)));
            }
            wait(|| rect(button).left == start.left - 120, 2);
            unsafe {
                SendMessageW(button, WM_LBUTTONUP, Some(WPARAM(0)), Some(point(80, 20)));
            }
            let moved = rect(button);
            assert_eq!(moved.left, start.left - 120);
            assert_eq!(moved.top, start.top + 80);
            assert_eq!(app.read().round_pick.override_pick, Some(true));
            assert!(!app.read().prefs.auto_pick);
            let saved = app.read().snapshot.root.join("pick-control-window.json");
            assert!(saved.is_file());
            click(button);
            wait(|| app.read().round_pick.override_pick == Some(false), 2);
            assert!(window(TITLE).is_some(), "pausing removed the resume button");
            assert_eq!(
                unsafe { GetForegroundWindow() },
                foreground,
                "click or drag stole focus"
            );
            app.round_pick.lock().unwrap().available = false;
            wait(|| window(TITLE).is_none(), 3);
            {
                let mut round = app.round_pick.lock().unwrap();
                *round = RoundPick::default();
                round.enter(10);
                round.available = true;
            }
            wait(|| window(TITLE).is_some(), 3);
            let restored = rect(window(TITLE).unwrap());
            assert_eq!(restored.left, moved.left);
            assert_eq!(restored.top, moved.top);
            assert_eq!(app.read().round_pick.override_pick, None);
            assert!(!app.read().prefs.auto_pick);
            assert!(window("Catengar").is_none());
            *app.round_pick.lock().unwrap() = RoundPick::default();
            wait(|| window(TITLE).is_none(), 3);
            println!(
                "PASS: single button, right center, topmost/no focus, click vs drag, restored position, round lifecycle"
            );
        });
        if let Some(app) = service::SERVICE.get() {
            app.exit.store(true, std::sync::atomic::Ordering::Release);
        }
        result
    });
    platform::run(root.path().into(), true).unwrap();
    if let Err(error) = driver.join().unwrap() {
        std::panic::resume_unwind(error);
    }
    assert!(!storage::load_preferences(root.path()).unwrap().auto_pick);
    let log = std::fs::read_to_string(root.path().join("logs/activity.jsonl")).unwrap();
    for expected in [
        "已弹出独立抢英雄按钮",
        "点击独立按钮",
        "本局已开启",
        "本局已暂停",
        "拖动独立抢英雄按钮",
        "拖动结束",
        "当前不可抢英雄，关闭独立按钮",
        "玩家切换主题",
        "玩家修改优先英雄",
        "Catengar 已退出",
    ] {
        assert!(log.contains(expected), "missing journal event: {expected}");
    }
}
