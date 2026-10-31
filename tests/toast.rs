//! Isolated native-window regression; never connects to League or requests UAC.
use catengar::{notifications::Notice, platform, service};
use std::{
    thread,
    time::{Duration, Instant},
};
use windows::Win32::{
    Foundation::*, Graphics::Gdi::*, System::Threading::GetCurrentProcessId,
    UI::WindowsAndMessaging::*,
};

fn wait(mut condition: impl FnMut() -> bool, seconds: u64) {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while !condition() {
        assert!(Instant::now() < deadline, "native toast timed out");
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

#[test]
#[ignore = "opens isolated preview windows; run cargo test --test toast -- --ignored"]
fn side_toast_replaces_acceptance_at_bottom_right_while_main_is_hidden() {
    let root = tempfile::tempdir().unwrap();
    let driver = thread::spawn(|| {
        let result = std::panic::catch_unwind(|| {
            wait(
                || service::SERVICE.get().is_some() && window("Catengar").is_some(),
                15,
            );
            service::global().notify("已自动接受对局");
            wait(|| window("Catengar · 通知").is_some(), 5);
            // Keep the acceptance toast active, then simulate returning to the client.
            let main = window("Catengar").unwrap();
            unsafe {
                PostMessageW(Some(main), WM_CLOSE, WPARAM(0), LPARAM(0)).unwrap();
            }
            wait(|| window("Catengar").is_none(), 3);
            for side in [1, 2] {
                let message = Notice::TeamSide(side).message();
                let start = Instant::now();
                service::global().notify(Notice::TeamSide(side));
                wait(
                    || platform::toast_message() == message && window("Catengar · 通知").is_some(),
                    2,
                );
                let elapsed = start.elapsed();
                assert!(
                    elapsed < Duration::from_secs(2),
                    "waited for the old toast to expire"
                );
                let toast = window("Catengar · 通知").unwrap();
                unsafe {
                    assert_ne!(GetForegroundWindow(), toast, "toast stole keyboard focus");
                    let style = GetWindowLongPtrW(toast, GWL_EXSTYLE) as u32;
                    assert_ne!(style & WS_EX_NOACTIVATE.0, 0);
                    assert_ne!(style & WS_EX_TOPMOST.0, 0);
                    let mut rect = RECT::default();
                    GetWindowRect(toast, &mut rect).unwrap();
                    let mut monitor = MONITORINFO {
                        cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                        ..Default::default()
                    };
                    assert!(
                        GetMonitorInfoW(
                            MonitorFromWindow(toast, MONITOR_DEFAULTTONEAREST),
                            &mut monitor
                        )
                        .as_bool()
                    );
                    assert_eq!(monitor.rcWork.right - rect.right, 16);
                    assert_eq!(monitor.rcWork.bottom - rect.bottom, 16);
                }
                println!(
                    "side {side}: visible after {} ms, bottom right, no activation",
                    elapsed.as_millis()
                );
                thread::sleep(Duration::from_millis(150));
            }
            wait(|| window("Catengar · 通知").is_none(), 7);
            assert!(window("Catengar").is_none());
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
    let log = std::fs::read_to_string(root.path().join("logs/activity.jsonl")).unwrap();
    for expected in [
        "通知已入队",
        "通知已显示",
        "被更高优先级通知替换",
        "通知到时自动关闭",
    ] {
        assert!(log.contains(expected), "missing journal event: {expected}");
    }
}
