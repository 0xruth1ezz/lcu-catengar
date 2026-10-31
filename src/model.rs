use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::PathBuf;

pub const MAX_PRIORITY: usize = 32;
pub fn yes() -> bool {
    true
}
pub fn one() -> u32 {
    1
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Preferences {
    pub version: u32,
    pub theme: Theme,
    pub auto_accept: bool,
    pub auto_pick: bool,
    pub always_prioritize: bool,
    pub priority: Vec<i32>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            version: 1,
            theme: Theme::ClassicGold,
            auto_accept: false,
            auto_pick: false,
            always_prioritize: true,
            priority: vec![],
        }
    }
}
impl Preferences {
    pub fn normalize(&mut self) {
        let mut seen = std::collections::HashSet::new();
        self.priority.retain(|id| *id > 0 && seen.insert(*id));
        self.priority.truncate(MAX_PRIORITY);
    }
    pub fn rank(&self, id: i32) -> usize {
        self.priority
            .iter()
            .position(|v| *v == id)
            .unwrap_or(MAX_PRIORITY)
    }
    pub fn toggle(&mut self, id: i32) {
        if self.priority.contains(&id) {
            self.priority.retain(|v| *v != id);
        } else if id > 0 && self.priority.len() < MAX_PRIORITY {
            self.priority.push(id);
        }
    }
    pub fn reorder(&mut self, id: i32, up: bool) {
        let i = self.rank(id);
        if i >= self.priority.len() || (up && i == 0) || (!up && i + 1 == self.priority.len()) {
            return;
        }
        self.priority.swap(i, if up { i - 1 } else { i + 1 });
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Theme {
    ChatgptDark,
    ChatgptLight,
    Nord,
    Catppuccin,
    #[default]
    #[serde(other)]
    ClassicGold,
}
impl Theme {
    pub const ALL: [Self; 5] = [
        Self::ClassicGold,
        Self::ChatgptDark,
        Self::ChatgptLight,
        Self::Nord,
        Self::Catppuccin,
    ];
    pub fn label(self) -> &'static str {
        match self {
            Self::ClassicGold => "经典金色",
            Self::ChatgptDark => "OAI 深色",
            Self::ChatgptLight => "OAI 浅色",
            Self::Nord => "Nord 北欧",
            Self::Catppuccin => "Catppuccin",
        }
    }
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
pub struct Champion {
    pub id: i32,
    pub name: String,
    pub alias: String,
    pub asset: String,
    #[serde(default)]
    pub portrait: String,
}
impl Champion {
    pub fn valid(&self) -> bool {
        candidate(self.id, &self.alias) && !self.name.is_empty() && valid_asset(&self.asset)
    }
    pub fn matches(&self, query: &str) -> bool {
        let query = query.trim().to_lowercase();
        self.name.to_lowercase().contains(&query) || self.alias.to_lowercase().contains(&query)
    }
}
pub fn candidate(id: i32, alias: &str) -> bool {
    id > 0 && !alias.to_ascii_lowercase().starts_with("jade_")
}
pub fn valid_asset(path: &str) -> bool {
    path.starts_with("/lol-game-data/assets/")
        && !path.contains("..")
        && !path
            .chars()
            .any(|c| "\\:%?#\r\n".contains(c) || c.is_control())
}
pub fn integer(v: &Value) -> i32 {
    v.as_i64().and_then(|v| v.try_into().ok()).unwrap_or(0)
}
pub fn aram(queue: i32, mode: &str) -> bool {
    matches!(queue, 450 | 2400) || matches!(mode, "ARAM" | "ARAM_MAYHEM")
}
pub fn own_champion(session: &Value) -> i32 {
    let Some(local) = session["localPlayerCellId"].as_i64().filter(|v| *v >= 0) else {
        return 0;
    };
    session["myTeam"]
        .as_array()
        .and_then(|team| team.iter().find(|p| p["cellId"].as_i64() == Some(local)))
        .map(|p| integer(&p["championId"]))
        .unwrap_or(0)
}
pub fn bench_ids(session: &Value) -> Vec<i32> {
    session["benchChampions"]
        .as_array()
        .or_else(|| session["benchChampionIds"].as_array())
        .into_iter()
        .flatten()
        .filter(|v| v["isAvailable"].as_bool() != Some(false))
        .map(|v| integer(if v.is_object() { &v["championId"] } else { v }))
        .filter(|id| *id > 0)
        .take(64)
        .collect()
}
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Selection {
    pub champion: i32,
    pub action: Option<i32>,
}
pub fn choose(
    prefs: &Preferences,
    queue: i32,
    mode: &str,
    session: &Value,
    pickable: &[i32],
) -> Option<Selection> {
    if !prefs.auto_pick || !aram(queue, mode) || session["isSpectating"].as_bool() == Some(true) {
        return None;
    }
    let local = session["localPlayerCellId"].as_i64().filter(|v| *v >= 0)?;
    let current = own_champion(session);
    let bench = if session["benchEnabled"].as_bool() == Some(true) {
        bench_ids(session)
    } else {
        vec![]
    };
    for &id in prefs.priority.iter().take(prefs.rank(current)) {
        if current > 0 && bench.contains(&id) {
            return Some(Selection {
                champion: id,
                action: None,
            });
        }
        if !pickable.contains(&id) {
            continue;
        }
        for action in session["actions"]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_array)
            .flatten()
        {
            if action["type"] == "pick"
                && action["actorCellId"].as_i64() == Some(local)
                && action["isInProgress"] == true
                && action["completed"] != true
                && let Some(action) = action["id"].as_i64().and_then(|id| i32::try_from(id).ok())
            {
                return Some(Selection {
                    champion: id,
                    action: Some(action),
                });
            }
        }
    }
    None
}
pub fn should_accept(enabled: bool, phase: &str, ready: &Value) -> bool {
    enabled
        && phase == "ReadyCheck"
        && ready["state"] == "InProgress"
        && ready["playerResponse"] == "None"
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Profile {
    pub name: String,
    pub riot_id: String,
    pub icon_id: Option<u32>,
    pub portrait: String,
}
#[derive(Clone, Debug, PartialEq)]
pub struct Snapshot {
    pub connected: bool,
    pub websocket: bool,
    pub status: String,
    pub phase: String,
    pub auth_retry: bool,
    pub settings_error: String,
    pub profile: Profile,
    pub champions: Vec<Champion>,
    pub queue: i32,
    pub current: i32,
    pub bench: Vec<i32>,
    pub pick_supported: Option<bool>,
    pub pick_completed: bool,
    pub accepted: u64,
    pub swapped: u64,
    pub perks: usize,
    pub styles: usize,
    pub root: PathBuf,
}
impl Default for Snapshot {
    fn default() -> Self {
        Self {
            connected: false,
            websocket: false,
            status: "正在寻找 League 客户端…".into(),
            phase: "未连接".into(),
            auth_retry: false,
            settings_error: String::new(),
            profile: Profile::default(),
            champions: vec![],
            queue: 0,
            current: 0,
            bench: vec![],
            pick_supported: None,
            pick_completed: false,
            accepted: 0,
            swapped: 0,
            perks: 0,
            styles: 0,
            root: PathBuf::new(),
        }
    }
}
impl Snapshot {
    pub fn name(&self, id: i32) -> String {
        self.champions
            .iter()
            .find(|c| c.id == id)
            .map(|c| c.name.clone())
            .unwrap_or_else(|| format!("英雄 {id}"))
    }
    pub fn can_install(&self) -> bool {
        !self.connected
            || matches!(
                self.phase.as_str(),
                "None" | "Lobby" | "EndOfGame" | "TerminatedInError"
            )
    }
}
pub fn phase_label(phase: &str) -> &str {
    match phase {
        "None" => "空闲",
        "Lobby" => "组队中",
        "Matchmaking" => "寻找对局",
        "ReadyCheck" => "确认对局",
        "ChampSelect" => "选择英雄",
        "GameStart" => "正在开始",
        "InProgress" => "对局中",
        "Reconnect" => "重新连接对局",
        "WaitingForStats" => "等待结算",
        "PreEndOfGame" | "EndOfGame" => "对局结束",
        "TerminatedInError" => "对局已结束",
        _ => phase,
    }
}
