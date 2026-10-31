//! Worker-owned decision state. Only a confirmed client snapshot completes a pick.
use crate::{
    journal::Entry,
    model::*,
    transport::{Api, GAME, PHASE, PICKABLE, READY, SESSION},
};
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::collections::BTreeMap;

#[derive(Clone, Debug, Default)]
pub struct Retry {
    target: i32,
    next: u64,
    attempts: u32,
}
impl Retry {
    pub fn allowed(&mut self, target: i32, now: u64) -> bool {
        if self.target != target {
            *self = Self {
                target,
                ..Self::default()
            };
        }
        now >= self.next
    }
    pub fn record(&mut self, now: u64, ok: bool) {
        self.attempts = if ok { 0 } else { (self.attempts + 1).min(5) };
        self.next = now
            + if ok {
                1000
            } else {
                (250u64 << self.attempts).min(4000)
            };
    }
}
#[derive(Clone, Debug, Default)]
struct Audit {
    rank: usize,
    available: bool,
    held: bool,
    attempted: bool,
    unconfirmed: bool,
    automatic: bool,
}
#[derive(Clone, Debug, Default)]
struct Side {
    side: u8,
    room: String,
    game: i64,
    finished: bool,
    attempts: u8,
    next: u64,
}
#[derive(Default)]
pub struct Engine {
    pub completed: bool,
    pub game_id: i64,
    pending: Option<(i32, u64)>,
    accept_done: bool,
    pick_retry: Retry,
    accept_retry: Retry,
    audit: BTreeMap<i32, Audit>,
    side: Side,
    pub logs: Vec<Entry>,
    pub notices: Vec<String>,
}
impl Engine {
    fn log(&mut self, kind: &str, level: &str, msg: impl Into<String>) {
        self.logs.push(Entry::new(kind, level, msg));
    }
    pub fn disconnected(&mut self, s: &Snapshot) {
        self.finish(s, true);
        self.pending = None;
        self.pick_retry = Retry::default();
    }
    fn finish(&mut self, s: &Snapshot, interrupted: bool) {
        let audit = std::mem::take(&mut self.audit);
        for (id, e) in audit {
            let result = if e.automatic {
                "已自动选中"
            } else if e.held {
                "曾持有（非自动选取）"
            } else if e.unconfirmed {
                "请求尚未确认"
            } else if e.attempted {
                "请求未成功"
            } else if e.available {
                "出现过可用机会，未提交选取"
            } else {
                "未发现可用机会"
            };
            self.log(
                "pick",
                "info",
                format!(
                    "{} · 顺位 {} · {}（{}）：{}",
                    if interrupted {
                        "记录截至连接中断"
                    } else {
                        "本轮选人结果"
                    },
                    e.rank,
                    s.name(id),
                    id,
                    result
                ),
            );
        }
    }
    fn reset_round(&mut self) {
        self.completed = false;
        self.game_id = 0;
        self.pending = None;
        self.side = Side::default();
        self.pick_retry = Retry::default();
    }
    pub fn pending_due(&self, now: u64) -> bool {
        self.pending.is_some_and(|(_, until)| now >= until)
    }
    pub fn side_pending(&self) -> bool {
        self.side.side == 0 || !self.side.finished
    }
    pub fn tick(
        &mut self,
        api: &mut impl Api,
        prefs: &impl Fn() -> Preferences,
        s: &mut Snapshot,
        now: u64,
    ) -> Result<()> {
        let phase = api.get(PHASE, false)?;
        if !phase.ok() {
            bail!("PhaseUnavailable");
        }
        let Some(phase) = phase.data.as_str().filter(|v| !v.is_empty()) else {
            bail!("InvalidPhase");
        };
        if !matches!(
            phase,
            "None"
                | "Lobby"
                | "Matchmaking"
                | "CheckedIntoTournament"
                | "ReadyCheck"
                | "ChampSelect"
                | "GameStart"
                | "InProgress"
                | "Reconnect"
                | "WaitingForStats"
                | "PreEndOfGame"
                | "EndOfGame"
                | "TerminatedInError"
        ) {
            bail!("UnknownPhase");
        }
        s.phase = phase.into();
        s.connected = true;
        if phase != "ReadyCheck" {
            self.accept_done = false;
            self.accept_retry = Retry::default();
        }
        if phase != "ChampSelect" {
            self.finish(s, false);
            self.reset_round();
            s.current = 0;
            s.queue = 0;
            s.bench.clear();
            s.pick_supported = None;
            s.pick_completed = false;
        }
        if phase == "ReadyCheck" {
            if self.accept_done || !prefs().auto_accept {
                return Ok(());
            }
            let ready = api.get(READY, false)?;
            if ready.ok()
                && should_accept(prefs().auto_accept, phase, &ready.data)
                && self.accept_retry.allowed(1, now)
            {
                if !prefs().auto_accept {
                    return Ok(());
                }
                let Some(revision) = api.guard(&[(PHASE, &json!(phase)), (READY, &ready.data)])
                else {
                    return Ok(());
                };
                if let Some(result) = api.write(
                    "POST",
                    "/lol-matchmaking/v1/ready-check/accept",
                    None,
                    revision,
                )? {
                    self.accept_retry.record(now, result.ok());
                    if result.ok() {
                        self.accept_done = true;
                        s.accepted += 1;
                        self.log("accept", "success", "已自动接受对局，等待其他玩家确认。");
                        self.notices.push("已自动接受对局".into());
                    } else {
                        self.log(
                            "accept",
                            "failure",
                            format!(
                                "自动接受失败（HTTP {}），将根据匹配状态重试。",
                                result.status
                            ),
                        );
                    }
                }
            }
            return Ok(());
        }
        if phase != "ChampSelect" {
            return Ok(());
        }
        let game = api.get(GAME, false)?;
        if !game.ok() {
            return Ok(());
        }
        if game.data["phase"]
            .as_str()
            .is_some_and(|v| v != "ChampSelect")
        {
            return Ok(());
        }
        let game_id = game.data["gameData"]["gameId"]
            .as_i64()
            .filter(|id| *id > 0)
            .unwrap_or(0);
        if game_id > 0 {
            if self.game_id > 0 && game_id != self.game_id {
                self.finish(s, false);
                self.reset_round();
            }
            self.game_id = game_id;
        }
        let queue = &game.data["gameData"]["queue"];
        s.queue = integer(&queue["id"]);
        let mode = queue["gameMode"].as_str().unwrap_or("");
        let supported = aram(s.queue, mode);
        s.pick_supported = Some(supported);
        s.pick_completed = self.completed;
        let side_supported = side_supported(&game.data);
        if !supported && !side_supported {
            return Ok(());
        }
        let session = api.get(SESSION, self.pending_due(now))?;
        if !session.ok() {
            return Ok(());
        }
        let selected_game = session.data["gameId"]
            .as_i64()
            .filter(|id| *id > 0)
            .unwrap_or(0);
        if game_id > 0 && selected_game > 0 && game_id != selected_game {
            return Ok(());
        }
        if side_supported {
            self.observe_side(&session.data);
        }
        if supported {
            self.pick(api, prefs, s, now, &session.data, &game.data)?;
        }
        if side_supported {
            self.send_side(api, now)?;
        }
        Ok(())
    }
    fn pick(
        &mut self,
        api: &mut impl Api,
        prefs: &impl Fn() -> Preferences,
        s: &mut Snapshot,
        now: u64,
        session: &Value,
        game: &Value,
    ) -> Result<()> {
        let mode = game["gameData"]["queue"]["gameMode"].as_str().unwrap_or("");
        s.current = own_champion(session);
        s.bench = bench_ids(session);
        let mut p = prefs();
        self.observe(&p, s, &[]);
        if let Some((id, until)) = self.pending {
            if s.current == id {
                self.completed = true;
                s.pick_completed = true;
                s.swapped += 1;
                if let Some(e) = self.audit.get_mut(&id) {
                    e.automatic = true;
                    e.unconfirmed = false;
                    e.held = true;
                }
                self.log(
                    "pick",
                    "success",
                    format!(
                        "已抢到 {}（{}）· 客户端已确认归属。{}",
                        s.name(id),
                        id,
                        if p.always_prioritize {
                            ""
                        } else {
                            "本轮优选已停止。"
                        }
                    ),
                );
                self.notices.push(format!("已抢到 {}", s.name(id)));
                self.pending = None;
            } else if now < until {
                return Ok(());
            } else {
                self.log(
                    "pick",
                    "warning",
                    format!(
                        "未确认抢到 {}：等待 3 秒仍未确认归属，将重新检查。",
                        s.name(id)
                    ),
                );
                self.pending = None;
            }
        }
        if !p.auto_pick || p.priority.is_empty() || (!p.always_prioritize && self.completed) {
            return Ok(());
        }
        let local = session["localPlayerCellId"].as_i64();
        let active = local.is_some_and(|v| v >= 0)
            && session["actions"]
                .as_array()
                .into_iter()
                .flatten()
                .filter_map(Value::as_array)
                .flatten()
                .any(|a| {
                    a["actorCellId"].as_i64() == local
                        && a["type"] == "pick"
                        && a["isInProgress"] == true
                        && a["completed"] != true
                });
        let pickable = if active {
            let r = api.get(PICKABLE, false)?;
            if r.ok() {
                r.data
                    .as_array()
                    .into_iter()
                    .flatten()
                    .map(integer)
                    .collect()
            } else {
                vec![]
            }
        } else {
            vec![]
        };
        p = prefs();
        self.observe(&p, s, &pickable);
        if !p.always_prioritize && self.completed {
            return Ok(());
        }
        let Some(choice) = choose(&p, s.queue, mode, session, &pickable) else {
            return Ok(());
        };
        if !self.pick_retry.allowed(choice.champion, now) || prefs() != p {
            return Ok(());
        }
        let phase_value = json!("ChampSelect");
        let pickable_value = json!(pickable);
        let mut observed = vec![(PHASE, &phase_value), (GAME, game), (SESSION, session)];
        if active {
            observed.push((PICKABLE, &pickable_value));
        }
        let Some(revision) = api.guard(&observed) else {
            return Ok(());
        };
        let id = choice.champion;
        let (method, path, body) = if let Some(action) = choice.action {
            (
                "PATCH",
                format!("{SESSION}/actions/{action}"),
                Some(json!({"championId":id,"completed":true})),
            )
        } else {
            ("POST", format!("{SESSION}/bench/swap/{id}"), None)
        };
        self.log(
            "pick",
            "info",
            format!(
                "尝试抢取 {}（{}）· 顺位 {}。",
                s.name(id),
                id,
                p.rank(id) + 1
            ),
        );
        if let Some(e) = self.audit.get_mut(&id) {
            e.attempted = true;
            e.unconfirmed = true;
        }
        let result = api.write(method, &path, body, revision)?;
        if let Some(result) = result {
            self.pick_retry.record(now, result.ok());
            if result.ok() {
                self.pending = Some((id, now + 3000));
                self.log(
                    "pick",
                    "info",
                    format!("{}的请求已提交，等待归属确认。", s.name(id)),
                );
            } else {
                if let Some(e) = self.audit.get_mut(&id) {
                    e.unconfirmed = false;
                }
                self.log(
                    "pick",
                    "failure",
                    format!(
                        "未抢到 {}：HTTP {}，将根据可用池重试。",
                        s.name(id),
                        result.status
                    ),
                );
            }
        }
        Ok(())
    }
    fn observe(&mut self, p: &Preferences, s: &Snapshot, pickable: &[i32]) {
        for (&id, e) in &mut self.audit {
            e.held |= id == s.current;
        }
        if p.auto_pick {
            for (rank, &id) in p.priority.iter().enumerate() {
                let e = self.audit.entry(id).or_default();
                e.rank = rank + 1;
                e.held |= s.current == id;
                e.available |= s.current == id || s.bench.contains(&id) || pickable.contains(&id);
            }
        }
    }
    fn observe_side(&mut self, session: &Value) {
        let room = room_id(session);
        if room.len() > 256 {
            return;
        }
        if !room.is_empty() {
            if !self.side.room.is_empty() && room != self.side.room {
                self.side = Side::default();
            }
            self.side.room = room.into();
        }
        let side = own_side(session);
        if side == 0 {
            return;
        }
        if self.side.side == 0 {
            self.side.side = side;
            let message = if side == 1 {
                "本局我方为蓝色方"
            } else {
                "本局我方为红色方"
            };
            self.log("side", "info", message);
            self.notices.push(message.into());
        }
        self.side.game = session["gameId"].as_i64().unwrap_or(0);
    }
    fn send_side(&mut self, api: &mut impl Api, now: u64) -> Result<()> {
        if self.side.side == 0 || self.side.finished || now < self.side.next {
            return Ok(());
        }
        self.side.next = now + 1000;
        let conversations = match api.get("/lol-chat/v1/conversations", true) {
            Ok(v) if v.ok() => v,
            _ => return Ok(()),
        };
        let rooms: Vec<_> = conversations
            .data
            .as_array()
            .into_iter()
            .flatten()
            .filter(|c| c["type"] == "championSelect")
            .filter_map(|c| {
                let id = c["id"].as_str()?;
                if id.is_empty() || id.len() > 256 {
                    return None;
                }
                if !self.side.room.is_empty()
                    && room_key(id) != room_key(&self.side.room)
                    && room_key(c["pid"].as_str().unwrap_or("")) != room_key(&self.side.room)
                {
                    return None;
                }
                Some(id)
            })
            .collect();
        if rooms.len() != 1 {
            return Ok(());
        }
        let phase = api.get(PHASE, false)?;
        if !phase.ok() || phase.data != "ChampSelect" {
            return Ok(());
        }
        let session = api.get(SESSION, false)?;
        if !session.ok()
            || own_side(&session.data) != self.side.side
            || room_id(&session.data) != self.side.room
            || (self.side.game > 0 && session.data["gameId"].as_i64() != Some(self.side.game))
        {
            return Ok(());
        }
        let Some(revision) = api.guard(&[(PHASE, &phase.data), (SESSION, &session.data)]) else {
            return Ok(());
        };
        let path = format!(
            "/lol-chat/v1/conversations/{}/messages",
            percent_encoding::utf8_percent_encode(rooms[0], percent_encoding::NON_ALPHANUMERIC)
        );
        let msg = if self.side.side == 1 {
            "🟦 本局我方为蓝色方 - by (Catengar)"
        } else {
            "🟥 本局我方为红色方 - by (Catengar)"
        };
        match api.write(
            "POST",
            &path,
            Some(json!({"body":msg,"type":"chat"})),
            revision,
        ) {
            Ok(Some(result)) => {
                self.side.attempts += 1;
                if result.ok() {
                    self.side.finished = true;
                    self.log("side", "success", "阵营提示已发送到选人聊天。");
                } else if self.side.attempts >= 5
                    || (!matches!(result.status, 404 | 409 | 429) && result.status < 500)
                {
                    self.side.finished = true;
                    self.log("side", "failure", "阵营消息未能发送，本局已停止重试。");
                }
            }
            Ok(None) => {}
            Err(_) => {
                self.side.finished = true;
                self.log(
                    "side",
                    "warning",
                    "阵营消息发送中断，结果未确认；本局不重复发送。",
                );
            }
        }
        Ok(())
    }
}
pub fn side_supported(game: &Value) -> bool {
    let q = &game["gameData"]["queue"];
    let mode = q["gameMode"]
        .as_str()
        .filter(|m| !m.is_empty())
        .or_else(|| game["map"]["gameMode"].as_str())
        .unwrap_or("");
    if matches!(mode, "CHERRY" | "TFT") {
        return false;
    }
    let id = integer(&q["id"]);
    aram(id, mode)
        || matches!(mode, "CLASSIC" | "KIWI" | "URF" | "ONEFORALL")
        || matches!(id, 400 | 420 | 430 | 440)
}
pub fn own_side(session: &Value) -> u8 {
    if session["isSpectating"] == true {
        return 0;
    }
    let Some(local) = session["localPlayerCellId"].as_i64().filter(|v| *v >= 0) else {
        return 0;
    };
    let side = session["myTeam"]
        .as_array()
        .into_iter()
        .flatten()
        .find(|p| p["cellId"].as_i64() == Some(local))
        .map(|p| integer(&p["team"]))
        .unwrap_or(0);
    if matches!(side, 1 | 2) { side as u8 } else { 0 }
}
fn room_id(session: &Value) -> &str {
    session["chatDetails"]["multiUserChatId"]
        .as_str()
        .filter(|s| !s.is_empty())
        .or_else(|| session["chatDetails"]["chatRoomName"].as_str())
        .unwrap_or("")
}
fn room_key(id: &str) -> &str {
    let local = id.split('@').next().unwrap_or(id);
    local.strip_prefix("c1~").unwrap_or(local)
}
