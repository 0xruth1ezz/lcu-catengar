//! Credentials travel through a private, bounded pipe. Never log discovery output.
use anyhow::{Result, anyhow, bail};
use base64::Engine as _;
use serde::{Deserialize, Serialize};
use std::{
    io::{Read, Write},
    os::windows::{io::AsRawHandle, process::CommandExt},
    path::PathBuf,
    process::{Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, Instant},
};
use windows::{
    Win32::{
        Foundation::*,
        Security::Authorization::*,
        Security::*,
        Storage::FileSystem::*,
        System::{
            Diagnostics::ToolHelp::*, Pipes::*, SystemInformation::GetSystemDirectoryW,
            Threading::*,
        },
        UI::{Shell::*, WindowsAndMessaging::SW_HIDE},
    },
    core::{HSTRING, PCWSTR},
};

#[derive(Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Credentials {
    pub port: u16,
    pub token: String,
    pub pid: u32,
}
impl Credentials {
    pub fn valid(&self) -> bool {
        self.port > 0
            && self.pid > 0
            && !self.token.is_empty()
            && self.token.len() <= 256
            && !self.token.chars().any(char::is_whitespace)
            && !self.token.contains('\0')
    }
}
impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("pid", &self.pid)
            .field("port", &self.port)
            .field("token", &"[redacted]")
            .finish()
    }
}
#[derive(Clone, Debug, PartialEq)]
pub enum Identity {
    Starting,
    Ready(Credentials),
    NotRunning,
    ClientStarting,
    AdminRequired,
    Authorizing,
    Cancelled,
    HelperMissing,
    Failed,
}
impl Identity {
    pub fn label(&self) -> &'static str {
        match self {
            Self::Starting => "正在读取 LCU 认证",
            Self::Ready(_) => "正在连接 League 客户端",
            Self::NotRunning => "等待 League 客户端启动",
            Self::ClientStarting => "已检测到客户端，等待认证信息就绪",
            Self::AdminRequired | Self::Authorizing => "正在启动认证助手并验证权限",
            Self::Cancelled => "Windows 已取消授权，可点击「授权连接」重试",
            Self::HelperMissing => "缺少 catengar-auth.exe，请将它放在主程序旁",
            Self::Failed => "认证读取暂时失败，正在自动重试",
        }
    }
}
pub struct Handle(pub HANDLE);
unsafe impl Send for Handle {}
impl Drop for Handle {
    fn drop(&mut self) {
        if !self.0.is_invalid() {
            unsafe {
                let _ = CloseHandle(self.0);
            }
        }
    }
}
pub fn elevated(process: HANDLE) -> bool {
    unsafe {
        let mut token = HANDLE::default();
        if OpenProcessToken(process, TOKEN_QUERY, &mut token).is_err() {
            return false;
        }
        let token = Handle(token);
        let mut info = TOKEN_ELEVATION::default();
        let mut len = 0;
        GetTokenInformation(
            token.0,
            TokenElevation,
            Some((&mut info as *mut TOKEN_ELEVATION).cast()),
            std::mem::size_of_val(&info) as u32,
            &mut len,
        )
        .is_ok()
            && info.TokenIsElevated != 0
    }
}
pub fn is_admin() -> bool {
    unsafe { elevated(GetCurrentProcess()) }
}
pub fn hidden_powershell() -> Command {
    let mut directory = [0u16; 32768];
    let length = unsafe { GetSystemDirectoryW(Some(&mut directory)) } as usize;
    assert!(
        length > 0 && length < directory.len(),
        "Windows system directory unavailable"
    );
    let system = PathBuf::from(String::from_utf16_lossy(&directory[..length]));
    let mut c = Command::new(system.join("WindowsPowerShell/v1.0/powershell.exe"));
    c.args([
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
    ]);
    c.creation_flags(0x08000000);
    c
}
fn client_paths() -> Vec<serde_json::Value> {
    let mut paths = vec![];
    unsafe {
        let Ok(snapshot) = CreateToolhelp32Snapshot(TH32CS_SNAPPROCESS, 0) else {
            return paths;
        };
        let snapshot = Handle(snapshot);
        let mut entry = PROCESSENTRY32W {
            dwSize: std::mem::size_of::<PROCESSENTRY32W>() as u32,
            ..Default::default()
        };
        let mut valid = Process32FirstW(snapshot.0, &mut entry).is_ok();
        while valid && paths.len() < 8 {
            let len = entry
                .szExeFile
                .iter()
                .position(|v| *v == 0)
                .unwrap_or(entry.szExeFile.len());
            let name = String::from_utf16_lossy(&entry.szExeFile[..len]);
            if ["LeagueClient.exe", "LeagueClientUx.exe"]
                .iter()
                .any(|v| name.eq_ignore_ascii_case(v))
                && let Ok(process) = OpenProcess(
                    PROCESS_QUERY_LIMITED_INFORMATION,
                    false,
                    entry.th32ProcessID,
                )
            {
                let process = Handle(process);
                let mut path = [0u16; 1024];
                let mut length = path.len() as u32;
                if QueryFullProcessImageNameW(
                    process.0,
                    PROCESS_NAME_WIN32,
                    windows::core::PWSTR(path.as_mut_ptr()),
                    &mut length,
                )
                .is_ok()
                {
                    paths.push(serde_json::json!({"pid":entry.th32ProcessID,"path":String::from_utf16_lossy(&path[..length as usize])}));
                }
            }
            valid = Process32NextW(snapshot.0, &mut entry).is_ok();
        }
    }
    paths
}
pub fn discover() -> Identity {
    // Base64 keeps observed filesystem paths out of PowerShell syntax.
    let mut observed_paths = client_paths();
    while serde_json::to_vec(&observed_paths)
        .unwrap_or_default()
        .len()
        > 4096
    {
        observed_paths.pop();
    }
    let paths = base64::engine::general_purpose::STANDARD
        .encode(serde_json::to_vec(&observed_paths).unwrap_or_default());
    let script = format!(
        "$env:PSModulePath = $PSHOME + '\\Modules'\n$hasAdministratorToken = ${}\n$clientPaths = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('{paths}')) | ConvertFrom-Json)\n{}",
        if is_admin() { "true" } else { "false" },
        include_str!("auth_discovery.ps1")
    );
    let mut child = match encoded_powershell(&script)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
    {
        Ok(c) => c,
        Err(_) => return Identity::Failed,
    };
    let start = Instant::now();
    let status = loop {
        match child.try_wait() {
            Ok(Some(s)) => break s,
            Ok(None) if start.elapsed() < Duration::from_secs(8) => {
                std::thread::sleep(Duration::from_millis(50))
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return Identity::Failed;
            }
        }
    };
    match status.code() {
        Some(0) => {
            let mut bytes = vec![];
            if let Some(stdout) = child.stdout.take() {
                let _ = stdout.take(4097).read_to_end(&mut bytes);
            }
            let parsed = serde_json::from_slice::<Credentials>(&bytes)
                .ok()
                .filter(Credentials::valid);
            bytes.fill(0);
            parsed.map(Identity::Ready).unwrap_or(Identity::Failed)
        }
        Some(2) => Identity::NotRunning,
        Some(3) => Identity::ClientStarting,
        Some(13) => Identity::AdminRequired,
        _ => Identity::Failed,
    }
}
fn encoded_powershell(script: &str) -> Command {
    // PowerShell parses -Command differently from the CRT argument quoting
    // used by std::process. A UTF-16 encoded command preserves quotes, Unicode
    // paths and embedded scripts exactly, without a command-shell intermediary.
    let bytes: Vec<u8> = script.encode_utf16().flat_map(u16::to_le_bytes).collect();
    let mut command = hidden_powershell();
    command
        .arg("-EncodedCommand")
        .arg(base64::engine::general_purpose::STANDARD.encode(bytes));
    command
}

pub const PACKET_SIZE: usize = 272;
pub fn encode(identity: &Identity) -> [u8; PACKET_SIZE] {
    let mut b = [0; PACKET_SIZE];
    b[..4].copy_from_slice(b"CAH1");
    b[4] = match identity {
        Identity::Ready(_) => 1,
        Identity::NotRunning => 2,
        Identity::AdminRequired => 3,
        Identity::ClientStarting => 5,
        _ => 4,
    };
    if let Identity::Ready(c) = identity {
        if c.valid() {
            b[6..8].copy_from_slice(&c.port.to_le_bytes());
            b[8..12].copy_from_slice(&c.pid.to_le_bytes());
            b[12..14].copy_from_slice(&(c.token.len() as u16).to_le_bytes());
            b[14..14 + c.token.len()].copy_from_slice(c.token.as_bytes());
        } else {
            b[4] = 4;
        }
    }
    b
}
pub fn decode(b: &[u8]) -> Result<Identity> {
    if b.len() != PACKET_SIZE || &b[..4] != b"CAH1" || b[5] != 0 {
        bail!("InvalidAuthPacket");
    }
    if b[4] != 1 {
        if b[6..].iter().any(|v| *v != 0) {
            bail!("InvalidAuthPacket");
        }
        return match b[4] {
            2 => Ok(Identity::NotRunning),
            3 => Ok(Identity::AdminRequired),
            4 => Ok(Identity::Failed),
            5 => Ok(Identity::ClientStarting),
            _ => Err(anyhow!("InvalidAuthPacket")),
        };
    }
    let len = u16::from_le_bytes([b[12], b[13]]) as usize;
    if len == 0 || len > 256 || b[14 + len..].iter().any(|v| *v != 0) {
        bail!("InvalidAuthPacket");
    }
    let c = Credentials {
        port: u16::from_le_bytes([b[6], b[7]]),
        pid: u32::from_le_bytes(b[8..12].try_into()?),
        token: String::from_utf8(b[14..14 + len].to_vec())?,
    };
    if !c.valid() {
        bail!("InvalidAuthPacket");
    }
    Ok(Identity::Ready(c))
}
fn pipe_name(nonce: &str) -> Result<String> {
    if nonce.len() != 32 || !nonce.bytes().all(|b| b.is_ascii_hexdigit()) {
        bail!("InvalidNonce");
    }
    Ok(format!(r"\\.\pipe\catengar.auth.{nonce}"))
}
fn process_path(handle: HANDLE) -> Result<PathBuf> {
    unsafe {
        let mut b = vec![0u16; 32768];
        let mut len = b.len() as u32;
        QueryFullProcessImageNameW(
            handle,
            PROCESS_NAME_WIN32,
            windows::core::PWSTR(b.as_mut_ptr()),
            &mut len,
        )?;
        Ok(PathBuf::from(String::from_utf16(&b[..len as usize])?))
    }
}

struct Broker {
    pipe: Handle,
    process: Handle,
}
impl Broker {
    fn start(stop: &AtomicBool) -> Result<Self> {
        unsafe {
            let nonce = uuid::Uuid::new_v4().simple().to_string();
            let pipe = HSTRING::from(pipe_name(&nonce)?);
            let mut descriptor = PSECURITY_DESCRIPTOR::default();
            ConvertStringSecurityDescriptorToSecurityDescriptorW(
                windows::core::w!("D:P(A;;GA;;;SY)(A;;GA;;;BA)(A;;GA;;;OW)"),
                SDDL_REVISION_1,
                &mut descriptor,
                None,
            )?;
            let attrs = SECURITY_ATTRIBUTES {
                nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
                lpSecurityDescriptor: descriptor.0,
                bInheritHandle: false.into(),
            };
            let raw = CreateNamedPipeW(
                &pipe,
                PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE,
                PIPE_TYPE_MESSAGE
                    | PIPE_READMODE_MESSAGE
                    | PIPE_NOWAIT
                    | PIPE_REJECT_REMOTE_CLIENTS,
                1,
                PACKET_SIZE as u32,
                PACKET_SIZE as u32,
                0,
                Some(&attrs),
            );
            let _ = LocalFree(Some(HLOCAL(descriptor.0)));
            if raw.is_invalid() {
                bail!("HelperPipe");
            }
            let pipe = Handle(raw);
            let helper = std::env::current_exe()?.with_file_name("catengar-auth.exe");
            if !helper.is_file() {
                bail!("HelperMissing");
            }
            let args = format!("--pipe {nonce} --parent {}", std::process::id());
            let (tx, rx) = crossbeam_channel::bounded(1);
            // ShellExecuteEx may wait for UAC. The watcher stays interruptible.
            std::thread::spawn(move || {
                let file = HSTRING::from(helper.as_os_str());
                let params = HSTRING::from(args);
                let verb = if is_admin() {
                    windows::core::w!("open")
                } else {
                    windows::core::w!("runas")
                };
                let mut info = SHELLEXECUTEINFOW {
                    cbSize: std::mem::size_of::<SHELLEXECUTEINFOW>() as u32,
                    fMask: SEE_MASK_NOCLOSEPROCESS | SEE_MASK_FLAG_NO_UI,
                    lpVerb: verb,
                    lpFile: PCWSTR(file.as_ptr()),
                    lpParameters: PCWSTR(params.as_ptr()),
                    nShow: SW_HIDE.0,
                    ..Default::default()
                };
                let result = ShellExecuteExW(&mut info).map(|_| Handle(info.hProcess));
                let _ = tx.send(result);
            });
            let process = loop {
                if stop.load(Ordering::Acquire) {
                    bail!("Stopped");
                }
                match rx.recv_timeout(Duration::from_millis(100)) {
                    Ok(r) => break r?,
                    Err(crossbeam_channel::RecvTimeoutError::Timeout) => {}
                    Err(_) => bail!("HelperLaunch"),
                }
            };
            if !elevated(process.0) {
                bail!("HelperNotElevated");
            }
            let start = Instant::now();
            loop {
                if stop.load(Ordering::Acquire)
                    || start.elapsed() > Duration::from_secs(15)
                    || WaitForSingleObject(process.0, 0) != WAIT_TIMEOUT
                {
                    bail!("HelperTimeout");
                }
                let result = ConnectNamedPipe(pipe.0, None);
                if result.is_ok() || GetLastError() == ERROR_PIPE_CONNECTED {
                    break;
                }
                std::thread::sleep(Duration::from_millis(50));
            }
            let mut pid = 0;
            GetNamedPipeClientProcessId(pipe.0, &mut pid)?;
            if pid != GetProcessId(process.0) {
                bail!("HelperIdentity");
            }
            Ok(Self { pipe, process })
        }
    }
    fn read(&self) -> Result<Option<Identity>> {
        unsafe {
            if WaitForSingleObject(self.process.0, 0) != WAIT_TIMEOUT {
                bail!("HelperExited");
            }
            let mut available = 0;
            PeekNamedPipe(self.pipe.0, None, 0, None, Some(&mut available), None)?;
            if available == 0 {
                return Ok(None);
            }
            let mut bytes = [0u8; PACKET_SIZE];
            let mut count = 0;
            ReadFile(self.pipe.0, Some(&mut bytes), Some(&mut count), None)?;
            let result = decode(&bytes[..count as usize]);
            bytes.fill(0);
            result.map(Some)
        }
    }
}
pub struct Watcher {
    pub identity: Arc<Mutex<(u64, Identity)>>,
    pub retry: Arc<AtomicBool>,
    pub refresh: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
    thread: Option<std::thread::JoinHandle<()>>,
}
impl Watcher {
    pub fn start() -> Self {
        let identity = Arc::new(Mutex::new((0, Identity::Starting)));
        let retry = Arc::new(AtomicBool::new(false));
        let refresh = Arc::new(AtomicBool::new(false));
        let stop = Arc::new(AtomicBool::new(false));
        let (data, retry2, refresh2, stop2) = (
            identity.clone(),
            retry.clone(),
            refresh.clone(),
            stop.clone(),
        );
        let thread = std::thread::spawn(move || {
            let mut broker: Option<Broker> = None;
            let mut cancelled = false;
            let mut next = Instant::now();
            while !stop2.load(Ordering::Acquire) {
                if retry2.swap(false, Ordering::AcqRel) {
                    cancelled = false;
                    next = Instant::now();
                }
                if refresh2.swap(false, Ordering::AcqRel) && broker.is_none() {
                    next = Instant::now();
                }
                let mut result = None;
                if let Some(b) = &broker {
                    match b.read() {
                        Ok(Some(v)) => result = Some(v),
                        Ok(None) => {}
                        Err(_) => {
                            broker = None;
                            result = Some(Identity::Failed);
                            next = Instant::now() + Duration::from_secs(3);
                        }
                    }
                } else if Instant::now() >= next {
                    let mut found = discover();
                    if found == Identity::AdminRequired && !cancelled {
                        {
                            let mut d = data.lock().unwrap();
                            d.0 += 1;
                            d.1 = Identity::Authorizing;
                        }
                        match Broker::start(&stop2) {
                            Ok(b) => {
                                broker = Some(b);
                                found = Identity::Authorizing;
                            }
                            Err(e) => {
                                if e.downcast_ref::<windows::core::Error>().is_some_and(|e| {
                                    e.code()
                                        == windows::core::HRESULT::from_win32(ERROR_CANCELLED.0)
                                }) {
                                    cancelled = true;
                                    found = Identity::Cancelled;
                                } else if e.to_string() == "HelperMissing" {
                                    found = Identity::HelperMissing;
                                } else {
                                    found = Identity::Failed;
                                }
                            }
                        }
                    } else if found == Identity::AdminRequired && cancelled {
                        found = Identity::Cancelled;
                    }
                    next = Instant::now()
                        + Duration::from_secs(if matches!(found, Identity::Ready(_)) {
                            5
                        } else {
                            3
                        });
                    result = Some(found);
                }
                if let Some(v) = result {
                    let mut d = data.lock().unwrap();
                    d.0 += 1;
                    d.1 = v;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
        Self {
            identity,
            retry,
            refresh,
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Watcher {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
pub fn serve_helper() -> Result<()> {
    if !is_admin() {
        bail!("AdminRequired");
    }
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 5 || args[1] != "--pipe" || args[3] != "--parent" {
        bail!("InvalidArguments");
    }
    let parent_id: u32 = args[4].parse()?;
    let name = pipe_name(&args[2])?;
    let parent = Handle(unsafe {
        OpenProcess(
            PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_SYNCHRONIZE,
            false,
            parent_id,
        )?
    });
    let expected = std::env::current_exe()?.with_file_name("catengar.exe");
    if !process_path(parent.0)?
        .to_string_lossy()
        .eq_ignore_ascii_case(&expected.to_string_lossy())
    {
        bail!("ParentIdentity");
    }
    let mut pipe = std::fs::OpenOptions::new().write(true).open(name)?;
    unsafe {
        let mut server = 0;
        GetNamedPipeServerProcessId(HANDLE(pipe.as_raw_handle()), &mut server)?;
        if server != parent_id {
            bail!("ParentIdentity");
        }
    }
    loop {
        if unsafe { WaitForSingleObject(parent.0, 0) } != WAIT_TIMEOUT {
            break;
        }
        let result = discover();
        let mut bytes = encode(&result);
        let sent = pipe.write_all(&bytes);
        bytes.fill(0);
        sent?;
        if unsafe {
            WaitForSingleObject(
                parent.0,
                if matches!(result, Identity::Ready(_)) {
                    5000
                } else {
                    3000
                },
            )
        } != WAIT_TIMEOUT
        {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn powershell_command_preserves_unicode_quotes_and_empty_arrays() {
        let output = super::encoded_powershell("[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)\n$env:PSModulePath = $PSHOME + '\\Modules'\n$paths = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('W10=')) | ConvertFrom-Json)\n@{text='中文 \\\"quoted\\\"'; count=$paths.Count} | ConvertTo-Json -Compress")
            .output().unwrap();
        assert!(output.status.success());
        let data: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(data["count"], 0);
        assert_eq!(data["text"], "中文 \\\"quoted\\\"");
    }
}
