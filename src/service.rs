use crate::{
    auth::{Identity, Watcher},
    engine::Engine,
    journal::Journal,
    model::*,
    storage,
    transport::{self, Api, Client},
    updater,
};
use anyhow::Result;
use crossbeam_channel::{Receiver, Sender};
use serde_json::Value;
use sha2::{Digest, Sha256};
use std::{
    collections::VecDeque,
    path::PathBuf,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, Ordering},
    },
    thread,
    time::{Duration, Instant},
};

pub static SERVICE: OnceLock<Arc<Service>> = OnceLock::new();
pub fn global() -> &'static Arc<Service> {
    SERVICE.get().expect("service initialized before NSH root")
}
#[derive(Clone, Debug, PartialEq)]
pub struct State {
    pub prefs: Preferences,
    pub snapshot: Snapshot,
    pub update: updater::State,
}
#[derive(Clone, Copy)]
pub enum Command {
    Reconnect,
    Authorize,
    CheckUpdate,
    InstallUpdate,
    Quit,
}
pub struct Service {
    pub state: Arc<Mutex<State>>,
    pub journal: Journal,
    pub notices: Mutex<VecDeque<String>>,
    tx: Sender<Command>,
    thread: Mutex<Option<thread::JoinHandle<()>>>,
    journal_thread: Mutex<Option<thread::JoinHandle<()>>>,
    pub exit: AtomicBool,
}
impl Service {
    pub fn start(root: PathBuf, offline: bool) -> Result<Arc<Self>> {
        std::fs::create_dir_all(&root)?;
        let mut snapshot = Snapshot {
            root: root.clone(),
            ..Snapshot::default()
        };
        let prefs = storage::load_preferences(&root).unwrap_or_else(|_| {
            snapshot.settings_error = "设置无法读取，自动功能已关闭。修改偏好后会尝试保存。".into();
            Preferences::default()
        });
        snapshot.champions = storage::load_priorities(&root, &prefs).unwrap_or_default();
        if offline {
            snapshot.status = "离线预览 · 未连接客户端".into();
        }
        let (journal, journal_thread) = Journal::start(root.clone());
        let (tx, rx) = crossbeam_channel::unbounded();
        let app = Arc::new(Self {
            state: Arc::new(Mutex::new(State {
                prefs,
                snapshot,
                update: updater::previous_result(&root),
            })),
            journal,
            notices: Mutex::new(VecDeque::new()),
            tx,
            thread: Mutex::new(None),
            journal_thread: Mutex::new(Some(journal_thread)),
            exit: AtomicBool::new(false),
        });
        let worker = app.clone();
        let handle = thread::spawn(move || worker.run(rx, root, offline));
        *app.thread.lock().unwrap() = Some(handle);
        Ok(app)
    }
    pub fn read(&self) -> State {
        self.state.lock().unwrap().clone()
    }
    pub fn command(&self, c: Command) {
        let _ = self.tx.send(c);
    }
    pub fn configure(&self, mut p: Preferences) {
        p.normalize();
        let mut state = self.state.lock().unwrap();
        if p.auto_accept != state.prefs.auto_accept {
            self.journal.log(
                "accept",
                "info",
                if p.auto_accept {
                    "已开启自动接受对局。"
                } else {
                    "已关闭自动接受对局。"
                },
            );
        }
        if p.auto_pick != state.prefs.auto_pick {
            self.journal.log(
                "pick",
                "info",
                if p.auto_pick {
                    "已开启自动选取英雄。"
                } else {
                    "已关闭自动选取英雄。"
                },
            );
        }
        if p.always_prioritize != state.prefs.always_prioritize {
            self.journal.log(
                "pick",
                "info",
                if p.always_prioritize {
                    "选取策略：持续按优先顺序选取英雄。"
                } else {
                    "选取策略：本轮自动抢到任意优先英雄后停止。"
                },
            );
        }
        state.prefs = p;
    }
    pub fn notify(&self, message: impl Into<String>) {
        self.notices.lock().unwrap().push_back(message.into());
    }
    pub fn stop(&self) {
        self.command(Command::Quit);
        if let Some(t) = self.thread.lock().unwrap().take() {
            let _ = t.join();
        }
        self.journal.stop();
        if let Some(t) = self.journal_thread.lock().unwrap().take() {
            let _ = t.join();
        }
    }
    fn publish(&self, s: &Snapshot) {
        let mut state = self.state.lock().unwrap();
        // Catalog work belongs to a separate worker; never replace newer assets.
        let champions = std::mem::take(&mut state.snapshot.champions);
        let perks = state.snapshot.perks;
        let styles = state.snapshot.styles;
        let profile = state.snapshot.profile.clone();
        state.snapshot = s.clone();
        if s.connected && profile.icon_id == s.profile.icon_id && !profile.portrait.is_empty() {
            state.snapshot.profile.portrait = profile.portrait;
        }
        state.snapshot.champions = champions;
        state.snapshot.perks = perks;
        state.snapshot.styles = styles;
    }
    fn run(self: Arc<Self>, rx: Receiver<Command>, root: PathBuf, offline: bool) {
        self.journal
            .log("app", "info", "Catengar 已启动，开始记录本机 LCU 活动。");
        let watcher = (!offline).then(Watcher::start);
        let mut client: Option<Client> = None;
        let mut assets: Option<Resources> = None;
        let mut engine = Engine::default();
        let start = Instant::now();
        let initial = self.read();
        // Preserve an unreadable configuration until the player edits preferences.
        let mut last_saved = (!initial.snapshot.settings_error.is_empty()).then_some(initial.prefs);
        let mut next_save = 0;
        let mut next_connect = 0;
        let mut failed_revision = 0;
        let mut next_phase = 0;
        let mut next_ready = 0;
        let mut next_side = 0;
        let mut next_profile = 0;
        let mut last_live = false;
        let mut next_update = 10_000;
        let mut manual_update = false;
        let mut update_job: Option<Receiver<Result<updater::State>>> = None;
        let mut install_requested = false;
        let mut install_after_download = false;
        loop {
            let now = start.elapsed().as_millis() as u64;
            let state = self.read();
            let mut snapshot = state.snapshot;
            let prefs = state.prefs;
            let mut reconnect = false;
            let mut quit = false;
            while let Ok(c) = rx.try_recv() {
                match c {
                    Command::Quit => quit = true,
                    Command::Reconnect => reconnect = true,
                    Command::Authorize => {
                        if let Some(w) = &watcher {
                            w.retry.store(true, Ordering::Release);
                        }
                    }
                    Command::CheckUpdate => {
                        if update_job.is_none() {
                            next_update = now;
                            manual_update = true;
                        }
                    }
                    Command::InstallUpdate => {
                        if update_job.is_none()
                            && snapshot.can_install()
                            && state.update.available()
                        {
                            install_requested = true;
                        }
                    }
                }
            }
            if quit {
                break;
            }
            if now >= next_save {
                if last_saved.as_ref() != Some(&prefs) {
                    match storage::save_preferences(&root, &prefs) {
                        Ok(()) => {
                            last_saved = Some(prefs.clone());
                            snapshot.settings_error.clear();
                        }
                        Err(_) => {
                            snapshot.settings_error =
                                "设置尚未保存，将自动重试。请检查目录权限。".into()
                        }
                    }
                }
                if snapshot.settings_error.is_empty()
                    && storage::save_priorities(&root, &prefs, &snapshot.champions).is_err()
                {
                    self.journal
                        .log("app", "warning", "优先英雄资料暂未缓存，将自动重试。");
                }
                next_save = now + 2000;
            }
            if let Some(job) = &update_job
                && let Ok(result) = job.try_recv()
            {
                update_job = None;
                match result {
                    Ok(mut update) => {
                        if update.status == "ready" && install_after_download {
                            install_requested = self.read().snapshot.can_install();
                            install_after_download = false;
                        }
                        if update.status == "available" {
                            self.notify(format!("发现新版本 v{}", update.version));
                        }
                        if update.status == "armed" {
                            // Recheck the actual current state immediately before committing.
                            if self.read().snapshot.can_install()
                                && updater::commit(&update.ticket).is_ok()
                            {
                                self.exit.store(true, Ordering::Release);
                            } else {
                                update.status = "ready".into();
                                update.ticket.clear();
                                update.message = "对局正在进行，暂缓安装。".into();
                            }
                        }
                        self.state.lock().unwrap().update = update;
                    }
                    Err(_) => {
                        install_after_download = false;
                        let mut s = self.state.lock().unwrap();
                        s.update.status = "failed".into();
                        s.update.message = "更新服务未能完成，请稍后重试。".into();
                    }
                }
            }
            if !offline && update_job.is_none() {
                let update = self.read().update;
                if install_requested && snapshot.can_install() {
                    install_requested = false;
                    let action = if update.status == "ready" {
                        "Install"
                    } else {
                        "Prepare"
                    };
                    install_after_download = action == "Prepare";
                    update_job = Some(updater::start(root.clone(), action, update));
                    self.state.lock().unwrap().update.status = if action == "Install" {
                        "arming"
                    } else {
                        "downloading"
                    }
                    .into();
                } else if now >= next_update && (manual_update || !update.available()) {
                    manual_update = false;
                    next_update = now + 6 * 60 * 60 * 1000;
                    update_job = Some(updater::start(root.clone(), "Check", update));
                    self.state.lock().unwrap().update.status = "checking".into();
                }
            }
            if offline {
                self.publish(&snapshot);
                thread::sleep(Duration::from_millis(100));
                continue;
            }
            let watcher = watcher.as_ref().unwrap();
            let (revision, identity) = watcher.identity.lock().unwrap().clone();
            let credentials = if let Identity::Ready(c) = &identity {
                Some(c)
            } else {
                None
            };
            snapshot.auth_retry = matches!(
                identity,
                Identity::Cancelled | Identity::HelperMissing | Identity::Failed
            );
            if client.as_ref().is_some_and(|c| {
                Some(c.identity()) != credentials || c.expired.load(Ordering::Acquire)
            }) || reconnect
            {
                if snapshot.connected {
                    self.journal.log(
                        "connection",
                        "warning",
                        "LCU 已断开，自动功能暂停；正在恢复连接。",
                    );
                }
                engine.disconnected(&snapshot);
                client = None;
                assets = None;
                snapshot.connected = false;
                snapshot.websocket = false;
                snapshot.profile = Profile::default();
                snapshot.current = 0;
                snapshot.bench.clear();
                snapshot.queue = 0;
                snapshot.pick_supported = None;
                snapshot.phase = "未连接".into();
                failed_revision = if reconnect { revision } else { 0 };
                next_connect = now + 1000;
                watcher.refresh.store(true, Ordering::Release);
            }
            if client.is_none() {
                snapshot.status = identity.label().into();
                if let Some(c) = credentials
                    && now >= next_connect
                    && (failed_revision == 0 || revision > failed_revision)
                {
                    match Client::new(c.clone()) {
                        Ok(c) => {
                            client = Some(c);
                            next_phase = 0;
                            next_ready = 0;
                            next_side = 0;
                            next_profile = 0;
                            last_live = false;
                        }
                        Err(_) => {
                            next_connect = now + 1000;
                            failed_revision = revision;
                            watcher.refresh.store(true, Ordering::Release);
                        }
                    }
                }
            }
            if let Some(c) = client.as_mut() {
                let live = c.websocket.load(Ordering::Acquire);
                snapshot.websocket = live;
                let result = (|| -> Result<()> {
                    if live && now >= next_phase {
                        c.get(transport::PHASE, true)?;
                        next_phase = now + if prefs.auto_accept { 1000 } else { 15000 };
                    }
                    if live
                        && snapshot.phase == "ReadyCheck"
                        && prefs.auto_accept
                        && now >= next_ready
                    {
                        c.get(transport::READY, true)?;
                        next_ready = now + 500;
                    }
                    if live
                        && snapshot.phase == "ChampSelect"
                        && engine.side_pending()
                        && now >= next_side
                    {
                        c.get(transport::GAME, true)?;
                        c.get(transport::SESSION, true)?;
                        next_side = now + 1000;
                    }
                    let connected = snapshot.connected;
                    engine.tick(
                        c,
                        &|| self.state.lock().unwrap().prefs.clone(),
                        &mut snapshot,
                        now,
                    )?;
                    if !connected {
                        self.journal.log(
                            "connection",
                            "success",
                            "LCU 已连接，自动功能可按开关配置运行。",
                        );
                    }
                    if live != last_live {
                        self.journal.log(
                            "connection",
                            if live { "success" } else { "warning" },
                            if live {
                                "WebSocket 已连接，实时监听对局和可用英雄。"
                            } else {
                                "WebSocket 暂不可用，暂用 REST 并自动重试。"
                            },
                        );
                        last_live = live;
                    }
                    snapshot.status = if live {
                        "已连接 · WebSocket 实时监听"
                    } else {
                        "已连接 · REST 降级，正在恢复 WebSocket"
                    }
                    .into();
                    if now >= next_profile {
                        if let Ok(profile) = c.get(transport::PROFILE, false) {
                            if profile.ok() {
                                let mut profile = parse_profile(&profile.data);
                                if profile.icon_id == snapshot.profile.icon_id {
                                    profile.portrait = snapshot.profile.portrait.clone();
                                }
                                snapshot.profile = profile;
                            } else if profile.status == 404 {
                                snapshot.profile = Profile::default();
                            }
                        }
                        next_profile = now + if live { 500 } else { 30000 };
                    }
                    Ok(())
                })();
                if result.is_err() {
                    self.journal
                        .log("connection", "failure", "LCU 通信中断，准备重新获取认证。");
                    engine.disconnected(&snapshot);
                    snapshot.connected = false;
                    snapshot.websocket = false;
                    snapshot.profile = Profile::default();
                    snapshot.phase = "未连接".into();
                    snapshot.status = "正在重新验证 LCU 认证并恢复连接".into();
                    snapshot.current = 0;
                    snapshot.bench.clear();
                    snapshot.queue = 0;
                    snapshot.pick_supported = None;
                    client = None;
                    assets = None;
                    failed_revision = revision;
                    next_connect = now + 1000;
                    watcher.refresh.store(true, Ordering::Release);
                } else if assets.is_none() {
                    assets = Some(Resources::start(
                        credentials.unwrap().clone(),
                        self.state.clone(),
                        root.clone(),
                    ));
                }
            }
            for entry in engine.logs.drain(..) {
                self.journal.log(&entry.kind, &entry.level, entry.message);
            }
            for notice in engine.notices.drain(..) {
                self.notify(notice);
            }
            self.publish(&snapshot);
            if let Some(c) = &client {
                let delay = if c.websocket.load(Ordering::Acquire) {
                    100
                } else if snapshot.phase == "ChampSelect" {
                    250
                } else if snapshot.phase == "ReadyCheck" {
                    500
                } else {
                    1000
                };
                let _ = c.wake.recv_timeout(Duration::from_millis(delay));
            } else {
                thread::sleep(Duration::from_millis(100));
            }
        }
        drop(assets);
        drop(client);
        drop(watcher);
        let state = self.read();
        if last_saved.as_ref() != Some(&state.prefs) {
            let _ = storage::save_preferences(&root, &state.prefs);
        }
        if state.snapshot.settings_error.is_empty() {
            let _ = storage::save_priorities(&root, &state.prefs, &state.snapshot.champions);
        }
        engine.disconnected(&state.snapshot);
        for e in engine.logs {
            self.journal.log(&e.kind, &e.level, e.message);
        }
        self.journal
            .log("app", "info", "Catengar 已退出，后台自动功能已停止。");
    }
}
fn parse_profile(v: &Value) -> Profile {
    let name = v["gameName"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| v["displayName"].as_str())
        .unwrap_or("")
        .to_owned();
    let tag = v["tagLine"].as_str().unwrap_or("");
    let riot_id = if tag.is_empty() {
        name.clone()
    } else {
        format!("{name}#{tag}")
    };
    Profile {
        name,
        riot_id,
        icon_id: v["profileIconId"].as_u64().and_then(|n| n.try_into().ok()),
        portrait: String::new(),
    }
}
struct Resources {
    stop: Arc<AtomicBool>,
    thread: Option<thread::JoinHandle<()>>,
}
impl Resources {
    fn start(
        credentials: crate::auth::Credentials,
        state: Arc<Mutex<State>>,
        root: PathBuf,
    ) -> Self {
        let stop = Arc::new(AtomicBool::new(false));
        let stopped = stop.clone();
        let thread = thread::spawn(move || {
            let Ok(mut client) = Client::resources(credentials) else {
                return;
            };
            let mut stage = 0;
            let mut cache = String::new();
            let mut index = 0;
            let mut next = Instant::now();
            let mut failed_portraits = std::collections::HashMap::<i32, Instant>::new();
            let mut next_profile = Instant::now();
            while !stopped.load(Ordering::Acquire) {
                thread::sleep(Duration::from_millis(100));
                if Instant::now() < next {
                    continue;
                }
                let snapshot = state.lock().unwrap().snapshot.clone();
                if matches!(snapshot.phase.as_str(), "ChampSelect" | "ReadyCheck") {
                    continue;
                }
                if stage < 5 {
                    if metadata(&mut client, &state, &root, stage, &mut cache).is_ok() || stage > 1
                    {
                        stage += 1;
                    } else {
                        next = Instant::now() + Duration::from_secs(5);
                    }
                    continue;
                }
                let prefs = state.lock().unwrap().prefs.clone();
                if let Some(id) = snapshot.profile.icon_id.filter(|_| {
                    snapshot.profile.portrait.is_empty() && Instant::now() >= next_profile
                }) {
                    next_profile = Instant::now() + Duration::from_secs(30);
                    let portrait = format!("{cache}/profile-{id}.jpg");
                    if download(
                        &client,
                        &root,
                        &format!("/lol-game-data/assets/v1/profile-icons/{id}.jpg"),
                        &portrait,
                    )
                    .is_ok()
                    {
                        let mut current = state.lock().unwrap();
                        if current.snapshot.profile.icon_id == Some(id) {
                            current.snapshot.profile.portrait = portrait;
                        }
                    }
                }
                let candidates = state.lock().unwrap().snapshot.champions.clone();
                let ready = |c: &&Champion| {
                    c.portrait.is_empty()
                        && failed_portraits
                            .get(&c.id)
                            .is_none_or(|retry| Instant::now() >= *retry)
                };
                let desired = prefs
                    .priority
                    .iter()
                    .find_map(|id| candidates.iter().find(|c| c.id == *id && ready(c)).cloned())
                    .or_else(|| {
                        let result = candidates
                            .iter()
                            .cycle()
                            .skip(index)
                            .take(candidates.len())
                            .find(ready)
                            .cloned();
                        index = (index + 1) % candidates.len().max(1);
                        result
                    });
                if let Some(champ) = desired {
                    let portrait = format!("{cache}/champion-{}.png", champ.id);
                    if download(&client, &root, &champ.asset, &portrait).is_ok() {
                        if let Some(c) = state
                            .lock()
                            .unwrap()
                            .snapshot
                            .champions
                            .iter_mut()
                            .find(|c| c.id == champ.id)
                        {
                            c.portrait = portrait;
                        }
                    } else {
                        failed_portraits.insert(champ.id, Instant::now() + Duration::from_secs(30));
                    }
                } else {
                    next = Instant::now() + Duration::from_secs(2);
                }
                if client.expired.load(Ordering::Acquire) {
                    break;
                }
            }
        });
        Self {
            stop,
            thread: Some(thread),
        }
    }
}
impl Drop for Resources {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::Release);
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}
fn metadata(
    client: &mut Client,
    state: &Mutex<State>,
    root: &std::path::Path,
    stage: usize,
    cache: &mut String,
) -> Result<()> {
    if stage == 0 {
        let version = client.get("/lol-patch/v1/game-version", true)?;
        let locale = client.get("/riotclient/region-locale", true)?;
        let key = if version.ok() && locale.ok() {
            format!(
                "{:x}",
                Sha256::digest(format!("{}{}", version.data, locale.data).as_bytes())
            )
        } else {
            uuid::Uuid::new_v4().simple().to_string()
        };
        *cache = format!("cache/{}", &key[..24]);
        std::fs::create_dir_all(root.join(&*cache))?;
        return Ok(());
    }
    let (path, name) = [
        (
            "/lol-game-data/assets/v1/champion-summary.json",
            "champions.json",
        ),
        ("/lol-perks/v1/perks", "perks.json"),
        ("/lol-perks/v1/styles", "styles.json"),
        (
            "/lol-game-data/assets/v1/summoner-spells.json",
            "summoner-spells.json",
        ),
    ][stage - 1];
    let response = client.get(path, true)?;
    if !response.ok() {
        if stage == 1 {
            anyhow::bail!("CatalogUnavailable");
        }
        return Ok(());
    }
    storage::atomic_write(
        &root.join(&*cache).join(name),
        &serde_json::to_vec(&response.data)?,
    )?;
    if stage == 1 {
        let entries = response
            .data
            .as_array()
            .ok_or_else(|| anyhow::anyhow!("InvalidCatalog"))?;
        let mut ids = vec![];
        if let Ok(profile) = client.get(transport::PROFILE, true)
            && let Some(id) = profile.data["summonerId"].as_u64()
            && let Ok(inventory) = client.get(
                &format!("/lol-champions/v1/inventories/{id}/champions-minimal"),
                true,
            )
            && inventory.ok()
        {
            ids = inventory
                .data
                .as_array()
                .into_iter()
                .flatten()
                .map(|v| integer(&v["id"]))
                .filter(|id| *id > 0)
                .collect();
        }
        let mut champions: Vec<Champion> = entries
            .iter()
            .filter_map(|v| {
                let id = integer(&v["id"]);
                let alias = v["alias"].as_str().unwrap_or("");
                if !candidate(id, alias) || (!ids.is_empty() && !ids.contains(&id)) {
                    return None;
                }
                let mut c = Champion {
                    id,
                    name: v["name"].as_str().unwrap_or("").into(),
                    alias: alias.into(),
                    asset: v["squarePortraitPath"].as_str().unwrap_or("").into(),
                    portrait: String::new(),
                };
                let portrait = format!("{cache}/champion-{id}.png");
                if root.join(&portrait).is_file() {
                    c.portrait = portrait;
                }
                c.valid().then_some(c)
            })
            .collect();
        champions.sort_by(|a, b| a.alias.cmp(&b.alias));
        champions.dedup_by_key(|c| c.id);
        if !champions.is_empty() {
            state.lock().unwrap().snapshot.champions = champions;
        }
    } else if stage == 2 {
        state.lock().unwrap().snapshot.perks = response.data.as_array().map(Vec::len).unwrap_or(0);
    } else if stage == 3 {
        state.lock().unwrap().snapshot.styles = response.data.as_array().map(Vec::len).unwrap_or(0);
    }
    Ok(())
}
fn download(client: &Client, root: &std::path::Path, asset: &str, portrait: &str) -> Result<()> {
    if !valid_asset(asset) || !storage::valid_portrait(portrait) {
        anyhow::bail!("InvalidAsset");
    }
    if root.join(portrait).is_file() {
        return Ok(());
    }
    let (status, bytes) = client.bytes(asset, 2 * 1024 * 1024)?;
    if !(200..300).contains(&status) || bytes.is_empty() {
        anyhow::bail!("ImageUnavailable");
    }
    storage::atomic_write(&root.join(portrait), &bytes)
}
