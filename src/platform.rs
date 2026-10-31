//! Win32 host for NSH surfaces, tray lifetime, placement and single instance.
use crate::{
    auth::Handle,
    model::Champion,
    service::{self, Service},
    storage,
};
use anyhow::{Result, bail};
use nsh_platform_windows::{App, AppOptions, AppView, Appearance, Root};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    rc::Rc,
    sync::{Mutex, OnceLock, atomic::Ordering},
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::*,
        Graphics::{Dwm::*, Gdi::*},
        Storage::FileSystem::*,
        System::{
            LibraryLoader::GetModuleHandleW,
            Ole::{OleInitialize, OleUninitialize},
        },
        UI::{
            HiDpi::*,
            Input::KeyboardAndMouse::{ReleaseCapture, SetCapture},
            Shell::*,
            WindowsAndMessaging::*,
        },
    },
    core::{HSTRING, PCWSTR, w},
};

static ICON: OnceLock<PathBuf> = OnceLock::new();
static DETAIL: Mutex<Option<Champion>> = Mutex::new(None);
static REQUEST: Mutex<Option<Champion>> = Mutex::new(None);
static TOAST: Mutex<String> = Mutex::new(String::new());
static PICK_DRAG: Mutex<Option<PickDrag>> = Mutex::new(None);
struct PickDrag {
    cursor: POINT,
    origin: POINT,
    moved: bool,
}
static INSTANCE_RESTORE: OnceLock<u32> = OnceLock::new();
pub fn icon_path() -> &'static PathBuf {
    ICON.get().expect("icon initialized")
}
pub fn open_detail(c: Champion) {
    *REQUEST.lock().unwrap() = Some(c);
}
pub fn detail_champion() -> Champion {
    DETAIL.lock().unwrap().clone().unwrap_or_default()
}
pub fn toast_message() -> String {
    TOAST.lock().unwrap().clone()
}
pub fn open_url(url: &str) {
    let url = url.to_owned();
    std::thread::spawn(move || unsafe {
        ShellExecuteW(
            None,
            w!("open"),
            &HSTRING::from(url),
            None,
            None,
            SW_SHOWNORMAL,
        );
    });
}
pub fn reveal_logs() {
    let path = service::global().journal.path.clone();
    std::thread::spawn(move || unsafe {
        let _ = OleInitialize(None);
        let file = HSTRING::from(path.as_os_str());
        let id = ILCreateFromPathW(&file);
        if !id.is_null() {
            let _ = SHOpenFolderAndSelectItems(id, None, 0);
            ILFree(Some(id));
        } else {
            let parent = HSTRING::from(path.parent().unwrap().as_os_str());
            ShellExecuteW(None, w!("open"), &parent, None, None, SW_SHOWNORMAL);
        }
        OleUninitialize();
    });
}
const TRAY: u32 = WM_APP + 51;
const OPEN: usize = 1001;
const EXIT: usize = 1002;
unsafe fn restore(hwnd: HWND) {
    unsafe {
        let _ = ShowWindow(
            hwnd,
            if IsIconic(hwnd).as_bool() {
                SW_RESTORE
            } else {
                SW_SHOW
            },
        );
        let _ = SetForegroundWindow(hwnd);
    }
}
#[derive(Clone, Debug, Serialize, Deserialize)]
struct Placement {
    version: u32,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
}
impl Placement {
    fn valid(&self, min_height: i32) -> bool {
        self.version == 1
            && (100..=32768).contains(&self.width)
            && (min_height..=32768).contains(&self.height)
            && (-131072..=131072).contains(&self.left)
            && (-131072..=131072).contains(&self.top)
    }
    fn visible(&self, work: RECT) -> Self {
        let width = self.width.min(work.right - work.left);
        let height = self.height.min(work.bottom - work.top);
        Self {
            version: 1,
            left: self.left.clamp(work.left, work.right - width),
            top: self.top.clamp(work.top, work.bottom - height),
            width,
            height,
        }
    }
}
unsafe fn save_placement(hwnd: HWND, filename: &str) {
    unsafe {
        if IsIconic(hwnd).as_bool() || IsZoomed(hwnd).as_bool() {
            return;
        }
        let mut r = RECT::default();
        if GetWindowRect(hwnd, &mut r).is_ok() {
            let p = Placement {
                version: 1,
                left: r.left,
                top: r.top,
                width: r.right - r.left,
                height: r.bottom - r.top,
            };
            let path = service::global().read().snapshot.root.join(filename);
            if let Ok(bytes) = serde_json::to_vec(&p) {
                let _ = storage::atomic_write(&path, &bytes);
            }
        }
    }
}
unsafe fn load_placement(hwnd: HWND, root: &std::path::Path, filename: &str) {
    unsafe {
        let Ok(bytes) = storage::read_bounded(&root.join(filename), 4096) else {
            return;
        };
        let Ok(p) = serde_json::from_slice::<Placement>(&bytes) else {
            return;
        };
        if !p.valid(if filename == "pick-control-window.json" {
            32
        } else {
            100
        }) {
            return;
        }
        let r = RECT {
            left: p.left,
            top: p.top,
            right: p.left + p.width,
            bottom: p.top + p.height,
        };
        let monitor = MonitorFromRect(&r, MONITOR_DEFAULTTONEAREST);
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetMonitorInfoW(monitor, &mut info).as_bool() {
            let p = p.visible(info.rcWork);
            let _ = SetWindowPos(
                hwnd,
                None,
                p.left,
                p.top,
                p.width,
                p.height,
                SWP_NOZORDER | SWP_NOACTIVATE,
            );
        }
    }
}
unsafe extern "system" fn host_proc(
    hwnd: HWND,
    msg: u32,
    wparam: WPARAM,
    lparam: LPARAM,
    _id: usize,
    kind: usize,
) -> LRESULT {
    unsafe {
        if kind == 3
            && let Some(result) = pick_control_pointer(hwnd, msg, lparam)
        {
            return result;
        }
        if msg == WM_CLOSE {
            if kind == 3 {
                return LRESULT(0); // This control lives for the selection phase.
            }
            if kind == 0 {
                save_placement(hwnd, "window.json");
                let _ = ShowWindow(hwnd, SW_HIDE);
            } else {
                let _ = ShowWindow(hwnd, SW_HIDE);
            }
            return LRESULT(0);
        }
        if Some(&msg) == INSTANCE_RESTORE.get() {
            restore(hwnd);
            return LRESULT(0);
        }
        if msg == WM_EXITSIZEMOVE && kind == 0 {
            save_placement(hwnd, "window.json");
        }
        if kind == 3 && matches!(msg, WM_EXITSIZEMOVE | WM_DISPLAYCHANGE) {
            keep_control_on_screen(hwnd);
            save_placement(hwnd, "pick-control-window.json");
        }
        if kind == 0 && msg == WM_GETMINMAXINFO {
            let info = &mut *(lparam.0 as *mut MINMAXINFO);
            let scale = GetDpiForWindow(hwnd) as f32 / 96.;
            info.ptMinTrackSize = POINT {
                x: (880. * scale) as i32,
                y: (720. * scale) as i32,
            };
            return LRESULT(0);
        }
        if kind == 0 && msg == WM_NCCALCSIZE && wparam.0 != 0 {
            return LRESULT(0);
        }
        if kind == 0 && msg == WM_NCHITTEST && !IsZoomed(hwnd).as_bool() {
            let x = (lparam.0 as u16 as i16) as i32;
            let y = ((lparam.0 >> 16) as u16 as i16) as i32;
            let mut r = RECT::default();
            if GetWindowRect(hwnd, &mut r).is_ok() {
                let b = (8 * GetDpiForWindow(hwnd) / 96) as i32;
                let left = x < r.left + b;
                let right = x >= r.right - b;
                let top = y < r.top + b;
                let bottom = y >= r.bottom - b;
                let hit = match (left, right, top, bottom) {
                    (true, _, true, _) => HTTOPLEFT,
                    (_, true, true, _) => HTTOPRIGHT,
                    (true, _, _, true) => HTBOTTOMLEFT,
                    (_, true, _, true) => HTBOTTOMRIGHT,
                    (true, _, _, _) => HTLEFT,
                    (_, true, _, _) => HTRIGHT,
                    (_, _, true, _) => HTTOP,
                    (_, _, _, true) => HTBOTTOM,
                    _ => 0,
                };
                if hit != 0 {
                    return LRESULT(hit as isize);
                }
            }
        }
        if matches!(kind, 2 | 3) && msg == WM_MOUSEACTIVATE {
            return LRESULT(MA_NOACTIVATE as isize);
        }
        if msg == TRAY {
            match (lparam.0 as u32) & 0xffff {
                WM_LBUTTONUP | WM_LBUTTONDBLCLK => restore(hwnd),
                WM_RBUTTONUP | WM_CONTEXTMENU => {
                    if let Ok(menu) = CreatePopupMenu() {
                        let _ = AppendMenuW(menu, MF_STRING, OPEN, w!("打开 Catengar"));
                        let _ = AppendMenuW(menu, MF_SEPARATOR, 0, None);
                        let _ = AppendMenuW(menu, MF_STRING, EXIT, w!("完全退出"));
                        let mut point = POINT::default();
                        let _ = GetCursorPos(&mut point);
                        let _ = SetForegroundWindow(hwnd);
                        let selected = TrackPopupMenu(
                            menu,
                            TPM_RETURNCMD | TPM_RIGHTBUTTON,
                            point.x,
                            point.y,
                            None,
                            hwnd,
                            None,
                        )
                        .0 as usize;
                        if selected == OPEN {
                            restore(hwnd);
                        } else if selected == EXIT {
                            save_placement(hwnd, "window.json");
                            PostQuitMessage(0);
                        }
                        let _ = DestroyMenu(menu);
                    }
                }
                _ => {}
            }
            return LRESULT(0);
        }
        if kind == 0 && msg == RegisterWindowMessageW(w!("TaskbarCreated")) {
            add_tray(hwnd);
            return LRESULT(0);
        }
        DefSubclassProc(hwnd, msg, wparam, lparam)
    }
}
unsafe fn window_icon(hwnd: HWND) -> HICON {
    unsafe {
        let icon = LoadIconW(
            Some(GetModuleHandleW(None).unwrap_or_default().into()),
            PCWSTR(std::ptr::without_provenance(1)),
        )
        .unwrap_or_default();
        if !icon.is_invalid() {
            SendMessageW(
                hwnd,
                WM_SETICON,
                Some(WPARAM(1)),
                Some(LPARAM(icon.0 as isize)),
            );
            SendMessageW(
                hwnd,
                WM_SETICON,
                Some(WPARAM(0)),
                Some(LPARAM(icon.0 as isize)),
            );
        }
        icon
    }
}
unsafe fn add_tray(hwnd: HWND) {
    unsafe {
        let mut data = NOTIFYICONDATAW {
            cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
            hWnd: hwnd,
            uID: 1,
            uFlags: NIF_ICON | NIF_TIP | NIF_MESSAGE,
            uCallbackMessage: TRAY,
            hIcon: window_icon(hwnd),
            ..Default::default()
        };
        let tip: Vec<u16> = "Catengar · League 助手".encode_utf16().collect();
        data.szTip[..tip.len()].copy_from_slice(&tip);
        let _ = Shell_NotifyIconW(NIM_ADD, &data);
    }
}
fn surface<T: nsh_core::element::Component>(
    title: &str,
    size: (i32, i32),
    kind: usize,
) -> Result<Rc<AppView>>
where
    T::Props: Default,
{
    let state = service::global().read();
    let appearance = if state.prefs.theme == crate::model::Theme::ChatgptLight {
        Appearance::Light
    } else {
        Appearance::Dark
    };
    let view = AppView::new(
        None,
        AppOptions {
            title: title.into(),
            app_id: "dev.catengar.lcu".into(),
            size,
            appearance,
            data_dir: Some(state.snapshot.root.join("nsh")),
            limits: nsh_platform_windows::Limits::standalone(),
            ..Default::default()
        },
    )?;
    unsafe {
        if !SetWindowSubclass(view.hwnd(), Some(host_proc), 1, kind).as_bool() {
            bail!("WindowSubclassFailed");
        }
        window_icon(view.hwnd());
    }
    view.load(App::Rust(Root::of::<T>()));
    Ok(view)
}
unsafe fn keep_control_on_screen(hwnd: HWND) {
    unsafe {
        let mut rect = RECT::default();
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        if GetWindowRect(hwnd, &mut rect).is_ok()
            && GetMonitorInfoW(MonitorFromWindow(hwnd, MONITOR_DEFAULTTONEAREST), &mut info)
                .as_bool()
        {
            let p = Placement {
                version: 1,
                left: rect.left,
                top: rect.top,
                width: rect.right - rect.left,
                height: rect.bottom - rect.top,
            }
            .visible(info.rcWork);
            let _ = SetWindowPos(
                hwnd,
                Some(HWND_TOPMOST),
                p.left,
                p.top,
                p.width,
                p.height,
                SWP_NOACTIVATE,
            );
        }
    }
}

unsafe fn pick_control_pointer(hwnd: HWND, msg: u32, lparam: LPARAM) -> Option<LRESULT> {
    unsafe {
        let mut point = POINT {
            x: (lparam.0 as u16 as i16) as i32,
            y: ((lparam.0 >> 16) as u16 as i16) as i32,
        };
        match msg {
            WM_LBUTTONDOWN | WM_LBUTTONDBLCLK => {
                let mut rect = RECT::default();
                let _ = GetWindowRect(hwnd, &mut rect);
                let _ = ClientToScreen(hwnd, &mut point);
                *PICK_DRAG.lock().unwrap() = Some(PickDrag {
                    cursor: point,
                    origin: POINT {
                        x: rect.left,
                        y: rect.top,
                    },
                    moved: false,
                });
                SetCapture(hwnd);
                Some(LRESULT(0))
            }
            WM_MOUSEMOVE => {
                let mut drag = PICK_DRAG.lock().unwrap();
                if let Some(drag) = drag.as_mut() {
                    let _ = ClientToScreen(hwnd, &mut point);
                    let dx = point.x - drag.cursor.x;
                    let dy = point.y - drag.cursor.y;
                    let threshold = GetSystemMetricsForDpi(SM_CXDRAG, GetDpiForWindow(hwnd)).max(4);
                    drag.moved |= dx.abs() >= threshold || dy.abs() >= threshold;
                    if drag.moved {
                        let _ = SetWindowPos(
                            hwnd,
                            None,
                            drag.origin.x + dx,
                            drag.origin.y + dy,
                            0,
                            0,
                            SWP_NOACTIVATE | SWP_NOZORDER | SWP_NOSIZE,
                        );
                        return Some(LRESULT(0));
                    }
                }
                None
            }
            WM_LBUTTONUP => {
                let drag = PICK_DRAG.lock().unwrap().take();
                let _ = ReleaseCapture();
                if let Some(drag) = drag {
                    if drag.moved {
                        keep_control_on_screen(hwnd);
                        save_placement(hwnd, "pick-control-window.json");
                    } else {
                        service::global().toggle_round_pick();
                    }
                }
                Some(LRESULT(0))
            }
            WM_CAPTURECHANGED | WM_CANCELMODE | WM_DESTROY => {
                *PICK_DRAG.lock().unwrap() = None;
                if msg == WM_CANCELMODE {
                    let _ = ReleaseCapture();
                }
                None
            }
            _ => None,
        }
    }
}

unsafe fn show_pick_control(main: HWND, root: &std::path::Path) -> Result<Rc<AppView>> {
    unsafe {
        let control = surface::<crate::ui::PickControl>("Catengar · 本局自动抢英雄", (168, 44), 3)?;
        let hwnd = control.hwnd();
        SetWindowLongPtrW(hwnd, GWL_STYLE, WS_POPUP.0 as isize);
        SetWindowLongPtrW(
            hwnd,
            GWL_EXSTYLE,
            (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST).0 as isize,
        );
        let foreground = GetForegroundWindow();
        let anchor = if foreground.0.is_null() {
            main
        } else {
            foreground
        };
        let mut info = MONITORINFO {
            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
            ..Default::default()
        };
        let _ = GetMonitorInfoW(
            MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST),
            &mut info,
        );
        let scale = GetDpiForWindow(anchor) as f32 / 96.;
        let width = (168. * scale) as i32;
        let height = (44. * scale) as i32;
        let _ = SetWindowPos(
            hwnd,
            Some(HWND_TOPMOST),
            info.rcWork.right - width - 16,
            info.rcWork.top + (info.rcWork.bottom - info.rcWork.top - height) / 2,
            width,
            height,
            SWP_NOACTIVATE | SWP_FRAMECHANGED,
        );
        load_placement(hwnd, root, "pick-control-window.json");
        keep_control_on_screen(hwnd);
        let round = DWMWCP_ROUND;
        let _ = DwmSetWindowAttribute(
            hwnd,
            DWMWA_WINDOW_CORNER_PREFERENCE,
            (&round as *const DWM_WINDOW_CORNER_PREFERENCE).cast(),
            std::mem::size_of_val(&round) as u32,
        );
        let _ = ShowWindow(hwnd, SW_SHOWNOACTIVATE);
        Ok(control)
    }
}

pub fn run(root: PathBuf, offline: bool) -> Result<()> {
    std::fs::create_dir_all(&root)?;
    use sha2::{Digest, Sha256};
    let key = format!(
        "Catengar.Restore.{:x}",
        Sha256::digest(
            std::fs::canonicalize(&root)?
                .to_string_lossy()
                .to_lowercase()
                .as_bytes()
        )
    );
    let restore_message = unsafe { RegisterWindowMessageW(&HSTRING::from(key)) };
    if restore_message == 0 {
        bail!("InstanceMessageFailed");
    }
    let _ = INSTANCE_RESTORE.set(restore_message);
    let lock = unsafe {
        CreateFileW(
            &HSTRING::from(root.join("catengar.lock").as_os_str()),
            GENERIC_READ.0 | GENERIC_WRITE.0,
            FILE_SHARE_MODE(0),
            None,
            OPEN_ALWAYS,
            FILE_ATTRIBUTE_NORMAL,
            None,
        )
    };
    let _lock = match lock {
        Ok(h) => Handle(h),
        Err(e) => {
            if e.code() == windows::core::HRESULT::from_win32(ERROR_SHARING_VIOLATION.0) {
                unsafe {
                    let _ = AllowSetForegroundWindow(ASFW_ANY);
                    let _ =
                        PostMessageW(Some(HWND_BROADCAST), restore_message, WPARAM(0), LPARAM(0));
                }
                return Ok(());
            }
            return Err(e.into());
        }
    };
    let icon = root.join("catengar-icon.png");
    storage::atomic_write(&icon, include_bytes!("../assets/catengar-icon.png"))?;
    let _ = ICON.set(icon);
    let service = Service::start(root.clone(), offline)?;
    if service::SERVICE.set(service.clone()).is_err() {
        bail!("ServiceAlreadyStarted");
    }
    let ui = std::thread::Builder::new()
        .name("catengar-ui".into())
        .stack_size(8 << 20)
        .spawn(move || -> Result<()> {
            unsafe {
                let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
                OleInitialize(None)?;
                let _ = SetCurrentProcessExplicitAppUserModelID(w!("dev.catengar.lcu"));
                let main = surface::<crate::ui::App>("Catengar", (1120, 800), 0)?;
                let hwnd = main.hwnd();
                let style = GetWindowLongPtrW(hwnd, GWL_STYLE) as u32;
                SetWindowLongPtrW(hwnd, GWL_STYLE, (style & !WS_CAPTION.0) as isize);
                let _ = SetWindowPos(
                    hwnd,
                    None,
                    0,
                    0,
                    0,
                    0,
                    SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED,
                );
                let round = DWMWCP_ROUND;
                let _ = DwmSetWindowAttribute(
                    hwnd,
                    DWMWA_WINDOW_CORNER_PREFERENCE,
                    (&round as *const DWM_WINDOW_CORNER_PREFERENCE).cast(),
                    std::mem::size_of_val(&round) as u32,
                );
                load_placement(hwnd, &root, "window.json");
                add_tray(hwnd);
                main.show();
                SetTimer(Some(hwnd), 1, 100, None);
                let mut details: Option<Rc<AppView>> = None;
                let mut toast: Option<(Rc<AppView>, Instant)> = None;
                let mut pick_control: Option<Rc<AppView>> = None;
                let mut msg = MSG::default();
                while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                    let _ = TranslateMessage(&msg);
                    DispatchMessageW(&msg);
                    if msg.message != WM_TIMER {
                        continue;
                    }
                    if service::global().exit.load(Ordering::Acquire) {
                        break;
                    }
                    if service::global().read().round_pick.available {
                        if pick_control.is_none() {
                            pick_control = Some(show_pick_control(hwnd, &root)?);
                        }
                    } else if let Some(control) = pick_control.take() {
                        control.stop();
                        let _ = DestroyWindow(control.hwnd());
                    }
                    if details
                        .as_ref()
                        .is_some_and(|v| !IsWindowVisible(v.hwnd()).as_bool())
                        && let Some(old) = details.take()
                    {
                        old.stop();
                        let _ = DestroyWindow(old.hwnd());
                    }
                    if let Some(c) = REQUEST.lock().unwrap().take() {
                        if let Some(old) = details.take() {
                            old.stop();
                            let _ = DestroyWindow(old.hwnd());
                        }
                        *DETAIL.lock().unwrap() = Some(c);
                        let detail =
                            surface::<crate::ui::Details>("Catengar · 英雄资料", (960, 740), 1)?;
                        SetWindowLongPtrW(detail.hwnd(), GWLP_HWNDPARENT, hwnd.0 as isize);
                        detail.show();
                        details = Some(detail);
                    }
                    if toast.as_ref().is_some_and(|(v, time)| {
                        time.elapsed() > Duration::from_millis(4500)
                            || !IsWindowVisible(v.hwnd()).as_bool()
                    }) && let Some((v, _)) = toast.take()
                    {
                        v.stop();
                        let _ = DestroyWindow(v.hwnd());
                    }
                    let next_notice = service::global()
                        .notices
                        .lock()
                        .unwrap()
                        .take(toast.is_some());
                    if let Some(notice) = next_notice {
                        if let Some((old, _)) = toast.take() {
                            old.stop();
                            let _ = DestroyWindow(old.hwnd());
                        }
                        *TOAST.lock().unwrap() = notice.message();
                        let v = surface::<crate::ui::Toast>("Catengar · 通知", (360, 140), 2)?;
                        let h = v.hwnd();
                        SetWindowLongPtrW(h, GWL_STYLE, WS_POPUP.0 as isize);
                        SetWindowLongPtrW(
                            h,
                            GWL_EXSTYLE,
                            (WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TOPMOST).0 as isize,
                        );
                        let foreground = GetForegroundWindow();
                        let anchor = if foreground.0.is_null() {
                            hwnd
                        } else {
                            foreground
                        };
                        let monitor = MonitorFromWindow(anchor, MONITOR_DEFAULTTONEAREST);
                        let mut info = MONITORINFO {
                            cbSize: std::mem::size_of::<MONITORINFO>() as u32,
                            ..Default::default()
                        };
                        let _ = GetMonitorInfoW(monitor, &mut info);
                        let scale = GetDpiForWindow(anchor) as f32 / 96.;
                        let width = (360. * scale) as i32;
                        let height = (140. * scale) as i32;
                        let _ = SetWindowPos(
                            h,
                            Some(HWND_TOPMOST),
                            info.rcWork.right - width - 16,
                            info.rcWork.bottom - height - 16,
                            width,
                            height,
                            SWP_NOACTIVATE | SWP_FRAMECHANGED,
                        );
                        let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
                        toast = Some((v, Instant::now()));
                    }
                }
                let _ = KillTimer(Some(hwnd), 1);
                let data = NOTIFYICONDATAW {
                    cbSize: std::mem::size_of::<NOTIFYICONDATAW>() as u32,
                    hWnd: hwnd,
                    uID: 1,
                    ..Default::default()
                };
                let _ = Shell_NotifyIconW(NIM_DELETE, &data);
                if let Some(v) = details {
                    v.stop();
                    let _ = DestroyWindow(v.hwnd());
                }
                if let Some((v, _)) = toast {
                    v.stop();
                    let _ = DestroyWindow(v.hwnd());
                }
                if let Some(control) = pick_control {
                    save_placement(control.hwnd(), "pick-control-window.json");
                    control.stop();
                    let _ = DestroyWindow(control.hwnd());
                }
                main.stop();
                let _ = DestroyWindow(hwnd);
                drop(main);
                OleUninitialize();
                Ok(())
            }
        })?;
    let result = ui.join().map_err(|_| anyhow::anyhow!("UI thread failed"))?;
    service.stop();
    result
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn placement_recovers_removed_monitor() {
        let p = Placement {
            version: 1,
            left: -3000,
            top: 2000,
            width: 1120,
            height: 800,
        };
        let p = p.visible(RECT {
            left: 0,
            top: 0,
            right: 1920,
            bottom: 1040,
        });
        assert_eq!((p.left, p.top), (0, 240));
        assert!(p.valid(100));
    }
}
