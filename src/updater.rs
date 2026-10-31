//! The Rust coordinator retains the audited Windows replacement engine.
use crate::{auth::hidden_powershell, storage};
use anyhow::{Result, bail};
use serde::{Deserialize, Serialize};
use std::{
    path::PathBuf,
    process::Stdio,
    time::{Duration, Instant},
};
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct State {
    pub status: String,
    pub version: String,
    pub sha256: String,
    pub stage: String,
    pub ticket: String,
    pub message: String,
}
impl Default for State {
    fn default() -> Self {
        Self {
            status: "idle".into(),
            version: String::new(),
            sha256: String::new(),
            stage: String::new(),
            ticket: String::new(),
            message: String::new(),
        }
    }
}
impl State {
    pub fn available(&self) -> bool {
        matches!(self.status.as_str(), "available" | "ready")
    }
    pub fn busy(&self) -> bool {
        matches!(self.status.as_str(), "checking" | "downloading" | "arming")
    }
    pub fn description(&self) -> &str {
        match self.status.as_str() {
            "idle" => "启动后自动检查 GitHub 正式版",
            "checking" => "正在检查新版本…",
            "current" => "已是最新正式版",
            "available" => "发现新版本，更新后自动重启",
            "downloading" => "正在下载并校验更新包…",
            "ready" => "更新包已就绪，点击更新并重启以安装",
            "arming" | "armed" => "正在准备重启…",
            _ => &self.message,
        }
    }
}
pub fn start(
    root: PathBuf,
    action: &'static str,
    state: State,
) -> crossbeam_channel::Receiver<Result<State>> {
    let (tx, rx) = crossbeam_channel::bounded(1);
    std::thread::spawn(move || {
        let _ = tx.send(perform(root, action, state));
    });
    rx
}
pub fn previous_result(root: &std::path::Path) -> State {
    let path = root.join("updates/last-result.json");
    let result = storage::read_bounded(&path, 8192)
        .ok()
        .and_then(|bytes| serde_json::from_slice::<State>(&bytes).ok())
        .filter(|s| matches!(s.status.as_str(), "updated" | "failed"));
    if result.is_some() {
        let _ = std::fs::remove_file(path);
    }
    result.unwrap_or_default()
}
fn perform(root: PathBuf, action: &str, state: State) -> Result<State> {
    let dir = root.join("updates");
    std::fs::create_dir_all(&dir)?;
    let engine = dir.join("engine-rust-nsh.ps1");
    let script = format!("\u{feff}{}", include_str!("updater.ps1"));
    storage::atomic_write(&engine, script.as_bytes())?;
    let request = dir.join(format!("request-{}.json", uuid::Uuid::new_v4().simple()));
    let payload = serde_json::json!({"current":crate::VERSION,"version":state.version,"sha256":state.sha256,"stage":state.stage,"executable":std::env::current_exe()?,"parent":std::process::id(),"receipt":dir.join("last-result.json")});
    storage::atomic_write(&request, &serde_json::to_vec(&payload)?)?;
    let mut child = hidden_powershell()
        .arg("-File")
        .arg(engine)
        .args(["-Mode", action, "-Request"])
        .arg(&request)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;
    let deadline = Instant::now()
        + Duration::from_secs(if action == "Prepare" {
            240
        } else if action == "Install" {
            10
        } else {
            30
        });
    loop {
        if action == "Install" && PathBuf::from(format!("{}.ready", request.display())).is_file() {
            return Ok(State {
                status: "armed".into(),
                ticket: request.to_string_lossy().into_owned(),
                ..state
            });
        }
        if child.try_wait()?.is_some() {
            break;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            bail!("UpdateTimeout");
        }
        std::thread::sleep(Duration::from_millis(100));
    }
    let result = PathBuf::from(format!("{}.result", request.display()));
    let bytes = storage::read_bounded(&result, 8192)?;
    let value = serde_json::from_slice(&bytes)?;
    let _ = std::fs::remove_file(result);
    let _ = std::fs::remove_file(request);
    Ok(value)
}
pub fn commit(ticket: &str) -> Result<()> {
    storage::atomic_write(&PathBuf::from(format!("{ticket}.commit")), b"install")
}
