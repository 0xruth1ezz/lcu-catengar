//! Worker-owned decision state. Only a confirmed client snapshot completes a pick.
use crate::{
    journal::Entry,
    model::*,
    notifications::Notice,
    team_side::early_selection,
    transport::{
        Api, CONVERSATIONS, GAME, PHASE, PICKABLE, READY, Response, SESSION, SUBSET, TEAM_PICKABLE,
        TEAM_SESSION, TEAMBUILDER,
    },
};
use anyhow::{Result, bail};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, HashMap},
    sync::Mutex,
};

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
    next_discovery: u64,
    chat_revision: u64,
    waiting_logged: bool,
    room_waiting_logged: bool,
}
#[derive(Default)]
pub struct Engine {
    pub completed: bool,
    pub game_id: i64,
    pending: Vec<PendingPick>,
    next_pick_refresh: u64,
    pick_rate_limit_until: u64,
    pick_state: String,
    accept_done: bool,
    ready_state: String,
    observed_current: Option<i32>,
    observed_bench: Option<Vec<i32>>,
    pick_retry: HashMap<Selection, u64>,
    accept_retry: Retry,
    audit: BTreeMap<i32, Audit>,
    side: Side,
    pub logs: Vec<Entry>,
    pub notices: Vec<Notice>,
    notifier: Option<Box<dyn Fn(Notice) + Send>>,
}
struct PendingPick {
    champion: i32,
    until: u64,
    next_check: u64,
}
impl Engine {
    pub fn with_notifier(notifier: impl Fn(Notice) + Send + 'static) -> Self {
        Self {
            notifier: Some(Box::new(notifier)),
            ..Self::default()
        }
    }
    fn notify(&mut self, notice: Notice) {
        if let Some(notifier) = &self.notifier {
            notifier(notice);
        } else {
            self.notices.push(notice);
        }
    }
    fn log(&mut self, kind: &str, level: &str, msg: impl Into<String>) {
        self.logs.push(Entry::new(kind, level, msg));
    }
    fn selection_state(&mut self, message: String) {
        if self.pick_state != message {
            self.log("pick", "info", &message);
            self.pick_state = message;
        }
    }
    pub fn disconnected(&mut self, s: &Snapshot) {
        self.finish(s, true);
        self.pending.clear();
        self.pick_retry.clear();
        self.next_pick_refresh = 0;
        self.pick_rate_limit_until = 0;
        self.observed_current = None;
        self.observed_bench = None;
        self.ready_state.clear();
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
        self.pending.clear();
        self.side = Side::default();
        self.pick_retry.clear();
        self.next_pick_refresh = 0;
        self.pick_rate_limit_until = 0;
        self.pick_state.clear();
        self.observed_current = None;
        self.observed_bench = None;
    }
    pub fn pending_due(&self, now: u64) -> bool {
        self.pending.iter().any(|p| now >= p.next_check)
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
        self.tick_with_control(api, prefs, s, now, &Mutex::new(RoundPick::default()))
    }
    pub fn tick_with_control(
        &mut self,
        api: &mut impl Api,
        prefs: &impl Fn() -> Preferences,
        s: &mut Snapshot,
        now: u64,
        control: &Mutex<RoundPick>,
    ) -> Result<()> {
        let result = self.tick_inner(api, prefs, s, now, control);
        if result.is_err() {
            control.lock().unwrap().available = false;
        }
        result
    }
    fn tick_inner(
        &mut self,
        api: &mut impl Api,
        prefs: &impl Fn() -> Preferences,
        s: &mut Snapshot,
        now: u64,
        control: &Mutex<RoundPick>,
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
        if s.phase != phase {
            self.log(
                "connection",
                "info",
                format!("对局阶段：{}。", phase_label(phase)),
            );
        }
        s.phase = phase.into();
        s.connected = true;
        if phase != "ReadyCheck" {
            self.accept_done = false;
            self.accept_retry = Retry::default();
            self.ready_state.clear();
        }
        if phase != "ChampSelect" {
            *control.lock().unwrap() = RoundPick::default();
            self.finish(s, false);
            self.reset_round();
            s.current = 0;
            s.queue = 0;
            s.bench.clear();
            s.pick_supported = None;
            s.pick_completed = false;
        }
        if phase == "ReadyCheck" {
            let ready = api.get(READY, false)?;
            let ready_state = format!(
                "对局确认状态：HTTP {}，state={}，本机响应={}，自动接受={}。",
                ready.status,
                ready.data["state"].as_str().unwrap_or("未知"),
                ready.data["playerResponse"].as_str().unwrap_or("未知"),
                prefs().auto_accept
            );
            if self.ready_state != ready_state {
                self.log("client", "info", &ready_state);
                self.ready_state = ready_state;
            }
            if self.accept_done || !prefs().auto_accept {
                return Ok(());
            }
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
                self.log("accept", "info", "准备提交自动接受对局请求。");
                let result = match api.write(
                    "POST",
                    "/lol-matchmaking/v1/ready-check/accept",
                    None,
                    revision,
                ) {
                    Ok(result) => result,
                    Err(error) => {
                        self.log(
                            "accept",
                            "failure",
                            "自动接受请求中断，结果未确认，将重新获取客户端状态。",
                        );
                        return Err(error);
                    }
                };
                if let Some(result) = result {
                    self.accept_retry.record(now, result.ok());
                    if result.ok() {
                        self.accept_done = true;
                        s.accepted += 1;
                        self.log("accept", "success", "已自动接受对局，等待其他玩家确认。");
                        self.notify("已自动接受对局".into());
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
                } else {
                    self.log(
                        "accept",
                        "info",
                        "自动接受请求已取消：客户端状态在提交前发生变化。",
                    );
                }
            }
            return Ok(());
        }
        if phase != "ChampSelect" {
            return Ok(());
        }
        // Reconcile gameflow independently of team-side discovery. A missed
        // event or cached loading response must not disable the whole round.
        let refresh_selection = now >= self.next_pick_refresh;
        if refresh_selection {
            self.next_pick_refresh = now + 250;
        }
        let game = api.get(GAME, refresh_selection)?;
        if !game.ok() {
            control.lock().unwrap().available = false;
            self.selection_state(format!(
                "已进入选人，等待对局信息（HTTP {}）。",
                game.status
            ));
            return Ok(());
        }
        if game.data["phase"]
            .as_str()
            .is_some_and(|v| v != "ChampSelect")
        {
            control.lock().unwrap().available = false;
            self.selection_state("已进入选人，等待对局信息同步。".into());
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
            if self.game_id != game_id {
                self.log(
                    "client",
                    "info",
                    format!(
                        "进入选人对局：gameId={game_id}，队列={}。",
                        game.data["gameData"]["queue"]["id"]
                    ),
                );
            }
            self.game_id = game_id;
        }
        control.lock().unwrap().enter(game_id);
        let prefs = || {
            let saved = prefs();
            control.lock().unwrap().effective(saved)
        };
        let queue = &game.data["gameData"]["queue"];
        s.queue = integer(&queue["id"]);
        let mode = queue["gameMode"].as_str().unwrap_or("");
        let supported = aram(s.queue, mode);
        s.pick_supported = Some(supported);
        s.pick_completed = self.completed;
        let side_supported = side_supported(&game.data);
        if !supported {
            control.lock().unwrap().available = false;
            self.selection_state(format!(
                "当前队列 {}（{}）不支持自动抢英雄。",
                s.queue, mode
            ));
        }
        if !supported && !side_supported {
            return Ok(());
        }
        // The server's team-builder event already contains the local side when
        // the room opens. The legacy session can stay incomplete until game start.
        // Read this before the legacy session and its pick-specific validation.
        let early_side = if side_supported && self.side_pending() {
            self.early_side(api, game_id, now)?
        } else {
            false
        };
        let p = prefs();
        // Keep observing the selection lifecycle while the local switch is off.
        let refresh_pick = supported
            && refresh_selection
            && p.auto_pick
            && !p.priority.is_empty()
            && (p.always_prioritize || !self.completed);
        let refresh_session = refresh_selection || self.pending_due(now);
        let (session_path, session) = selection_session(api, refresh_session, game_id)?;
        if !session.ok() {
            control.lock().unwrap().available = false;
            self.selection_state(format!(
                "选人接口尚未就绪（HTTP {}），正在重试。",
                session.status
            ));
            return Ok(());
        }
        if refresh_session {
            for pending in &mut self.pending {
                pending.next_check = now + 250;
            }
        }
        let selected_game = session.data["gameId"]
            .as_i64()
            .filter(|id| *id > 0)
            .unwrap_or(0);
        if game_id > 0 && selected_game > 0 && game_id != selected_game {
            control.lock().unwrap().available = false;
            self.selection_state("选人数据仍属于上一局，等待当前对局同步。".into());
            return Ok(());
        }
        {
            let mut round = control.lock().unwrap();
            if game_id == 0 {
                round.enter(selected_game);
            }
            round.available = supported && champion_changes_open(&session.data);
        }
        if supported {
            let p = prefs();
            self.selection_state(if !champion_changes_open(&session.data) {
                if session.data["timer"]["phase"] == "GAME_STARTING" {
                    "客户端已进入游戏启动阶段，本局自动抢英雄结束。".into()
                } else {
                    "选人数据尚未提供本机玩家，或当前正在观战。".into()
                }
            } else if !p.auto_pick {
                "选人已就绪，自动抢英雄已关闭；可用悬浮按钮为本局开启。".into()
            } else if p.priority.is_empty() {
                "自动抢英雄已开启，但优先列表为空。".into()
            } else if !p.always_prioritize && self.completed {
                "本局已完成一次自动抢取；可用悬浮按钮恢复。".into()
            } else {
                format!(
                    "自动抢英雄正在监听 {} 个优先英雄（{}）。",
                    p.priority.len(),
                    if session_path == SESSION {
                        "标准选人接口"
                    } else {
                        "team-builder 选人接口"
                    }
                )
            });
        }
        if side_supported && !early_side {
            self.observe_side(&session.data);
            // Notify and send as soon as matchmaking enters champion select;
            // pickable reads and automatic picks must not hold up this notice.
            self.send_side(api, now, false)?;
            if self.side.side == 0 && !self.side.waiting_logged {
                self.side.waiting_logged = true;
                self.log("side", "info", "已进入选人，等待客户端提供本局阵营数据。");
            }
        }
        if supported {
            self.pick(
                api,
                &prefs,
                s,
                now,
                &session.data,
                &game.data,
                refresh_pick,
                session_path,
            )?;
        }
        Ok(())
    }
    #[allow(clippy::too_many_arguments)]
    fn pick(
        &mut self,
        api: &mut impl Api,
        prefs: &impl Fn() -> Preferences,
        s: &mut Snapshot,
        now: u64,
        session: &Value,
        game: &Value,
        refresh: bool,
        session_path: &str,
    ) -> Result<()> {
        let mode = game["gameData"]["queue"]["gameMode"].as_str().unwrap_or("");
        s.current = own_champion(session);
        s.bench = bench_ids(session);
        if self.observed_current != Some(s.current) {
            let previous = self
                .observed_current
                .map(|id| format!("{}（{}）", s.name(id), id))
                .unwrap_or_else(|| "未记录".into());
            let source = if self
                .pending
                .iter()
                .any(|pending| pending.champion == s.current)
            {
                "匹配自动抢取请求"
            } else {
                "未匹配本程序自动请求，可能来自玩家操作或客户端分配"
            };
            self.log(
                "client",
                "info",
                format!(
                    "本机英雄变化：{previous} → {}（{}）；{source}，gameId={}。",
                    s.name(s.current),
                    s.current,
                    self.game_id
                ),
            );
            self.observed_current = Some(s.current);
        }
        let mut bench = s.bench.clone();
        bench.sort_unstable();
        if self.observed_bench.as_ref() != Some(&bench) {
            self.log(
                "client",
                "info",
                format!(
                    "可用替补池变化：{:?} → {:?}，gameId={}。",
                    self.observed_bench.as_deref().unwrap_or_default(),
                    bench,
                    self.game_id
                ),
            );
            self.observed_bench = Some(bench);
        }
        let mut p = prefs();
        self.observe(&p, s, &[]);
        for pending in std::mem::take(&mut self.pending) {
            let id = pending.champion;
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
                self.notify(format!("已抢到 {}", s.name(id)).into());
            } else if now < pending.until {
                self.pending.push(pending);
            } else {
                self.log(
                    "pick",
                    "warning",
                    format!(
                        "未确认抢到 {}：等待 3 秒仍未确认归属，将重新检查。",
                        s.name(id)
                    ),
                );
            }
        }
        if !p.auto_pick || p.priority.is_empty() || (!p.always_prioritize && self.completed) {
            return Ok(());
        }
        let pickable_path = if session_path == SESSION {
            PICKABLE
        } else {
            TEAM_PICKABLE
        };
        let pickable_response = if own_pick_action(session).is_some() {
            Some(api.get(pickable_path, refresh)?)
        } else {
            None
        };
        // The personal ARAM card pool remains swappable after locking a card.
        // It has its own resource/event and need not appear in benchChampions.
        let subset_response = api.get(SUBSET, refresh)?;
        let ids = |response: Option<&crate::transport::Response>| -> Vec<i32> {
            response
                .filter(|r| r.ok())
                .and_then(|r| r.data.as_array())
                .into_iter()
                .flatten()
                .map(integer)
                .filter(|id| *id > 0)
                .collect()
        };
        let pickable = ids(pickable_response.as_ref());
        let subset = ids(Some(&subset_response));
        p = prefs();
        self.observe(&p, s, &pickable);
        self.observe(&p, s, &subset);
        if (!p.always_prioritize && self.completed) || now < self.pick_rate_limit_until {
            return Ok(());
        }
        let choices = selection_candidates(&p, s.queue, mode, session, &pickable, &subset);
        self.pick_retry.retain(|choice, _| choices.contains(choice));
        for choice in choices {
            // A pending lower-priority request never holds up a better candidate.
            // Avoid duplicate requests or downgrading an already accepted upgrade.
            if self
                .pending
                .iter()
                .any(|pending| p.rank(pending.champion) <= p.rank(choice.champion))
                || self.pick_retry.get(&choice).is_some_and(|next| now < *next)
            {
                continue;
            }
            if prefs() != p {
                return Ok(());
            }
            let phase_value = json!("ChampSelect");
            let mut observed = vec![(PHASE, &phase_value), (GAME, game), (session_path, session)];
            if choice.action.is_some() && pickable.contains(&choice.champion) {
                observed.push((pickable_path, &pickable_response.as_ref().unwrap().data));
            } else if subset.contains(&choice.champion)
                && (choice.action.is_some() || !s.bench.contains(&choice.champion))
            {
                observed.push((SUBSET, &subset_response.data));
            }
            let Some(revision) = api.guard(&observed) else {
                return Ok(());
            };
            let id = choice.champion;
            let (method, path, body) = if let Some(action) = choice.action {
                (
                    "PATCH",
                    format!("{session_path}/actions/{action}"),
                    Some(json!({"championId":id,"completed":true})),
                )
            } else {
                ("POST", format!("{session_path}/bench/swap/{id}"), None)
            };
            self.log(
                "pick",
                "info",
                format!(
                    "准备抢取 {}（{}）· 顺位 {} · {method} {path} · gameId={}。",
                    s.name(id),
                    id,
                    p.rank(id) + 1,
                    self.game_id
                ),
            );
            let result = match api.write(method, &path, body, revision) {
                Ok(result) => result,
                Err(error) => {
                    if let Some(entry) = self.audit.get_mut(&id) {
                        entry.attempted = true;
                        entry.unconfirmed = true;
                    }
                    self.log(
                        "pick",
                        "failure",
                        format!("{}的选取请求中断，结果未确认。", s.name(id)),
                    );
                    return Err(error);
                }
            };
            let Some(result) = result else {
                self.log(
                    "pick",
                    "info",
                    format!(
                        "{}（{}）的抢取请求已取消：客户端状态在提交前发生变化。",
                        s.name(id),
                        id
                    ),
                );
                return Ok(());
            };
            if let Some(e) = self.audit.get_mut(&id) {
                e.attempted = true;
                e.unconfirmed = true;
            }
            if result.ok() {
                self.pick_retry.remove(&choice);
                self.pending.push(PendingPick {
                    champion: id,
                    until: now + 3000,
                    next_check: now,
                });
                self.log(
                    "pick",
                    "info",
                    format!(
                        "{}（{}）的请求已提交（HTTP {}），等待归属确认。",
                        s.name(id),
                        id,
                        result.status
                    ),
                );
                break;
            } else {
                // Retry a rejected candidate promptly without blocking another
                // champion or the alternative API route for the same champion.
                self.pick_retry.insert(choice, now + 250);
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
                if result.status == 429 {
                    self.pick_rate_limit_until = now + 1000;
                    break;
                }
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
        let side = own_side(session);
        if side == 0 {
            return;
        }
        let room = room_id(session);
        if room.len() > 256 {
            return;
        }
        if !room.is_empty() {
            if !self.side.room.is_empty() && room_key(room) != room_key(&self.side.room) {
                self.side = Side::default();
            }
            self.side.room = room.into();
        }
        if self.side.side == 0 {
            self.side.side = side;
            let message = if side == 1 {
                "本局我方为蓝色方"
            } else {
                "本局我方为红色方"
            };
            self.log("side", "info", message);
            self.notify(Notice::TeamSide(side));
        }
        self.side.game = session["gameId"].as_i64().unwrap_or(0);
    }
    fn early_side(&mut self, api: &mut impl Api, game_id: i64, now: u64) -> Result<bool> {
        let message = match api.get(TEAMBUILDER, false) {
            Ok(message) if message.ok() => message,
            _ => return Ok(false),
        };
        let Some(selection) = early_selection(&message.data, game_id) else {
            return Ok(false);
        };
        self.observe_side(&selection);
        self.send_side(api, now, true)?;
        Ok(true)
    }
    fn send_side(&mut self, api: &mut impl Api, now: u64, early: bool) -> Result<()> {
        if self.side.side == 0 || self.side.finished || now < self.side.next {
            return Ok(());
        }
        let chat_revision = api.chat_revision();
        if now < self.side.next_discovery && chat_revision == self.side.chat_revision {
            return Ok(());
        }
        self.side.chat_revision = chat_revision;
        self.side.next_discovery = now + 250;
        let conversations = match api.get(CONVERSATIONS, true) {
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
            if !self.side.room_waiting_logged {
                self.side.room_waiting_logged = true;
                self.log("side", "info", "阵营已确认，等待当前选人聊天室就绪。");
            }
            return Ok(());
        }
        let phase = api.get(PHASE, false)?;
        if !phase.ok() || phase.data != "ChampSelect" {
            return Ok(());
        }
        let game = api.get(GAME, false)?;
        if !game.ok()
            || !side_supported(&game.data)
            || game.data["phase"]
                .as_str()
                .is_some_and(|phase| phase != "ChampSelect")
        {
            return Ok(());
        }
        let latest_game_id = game.data["gameData"]["gameId"].as_i64().unwrap_or(0);
        if self.side.game > 0 && latest_game_id > 0 && self.side.game != latest_game_id {
            return Ok(());
        }
        let source = if early { TEAMBUILDER } else { SESSION };
        let session = api.get(source, false)?;
        if !session.ok() {
            return Ok(());
        }
        let selected = if early {
            let game_id = game.data["gameData"]["gameId"].as_i64().unwrap_or(0);
            let Some(selected) = early_selection(&session.data, game_id) else {
                return Ok(());
            };
            selected
        } else {
            session.data.clone()
        };
        if own_side(&selected) != self.side.side
            || room_key(room_id(&selected)) != room_key(&self.side.room)
            || (self.side.game > 0 && selected["gameId"].as_i64() != Some(self.side.game))
        {
            return Ok(());
        }
        let Some(revision) = api.guard(&[
            (PHASE, &phase.data),
            (GAME, &game.data),
            (source, &session.data),
        ]) else {
            return Ok(());
        };
        let path = format!(
            "/lol-chat/v1/conversations/{}/messages",
            percent_encoding::utf8_percent_encode(rooms[0], percent_encoding::NON_ALPHANUMERIC)
        );
        let msg = Notice::TeamSide(self.side.side).message();
        self.log(
            "side",
            "info",
            format!(
                "准备发送阵营提示：第 {} 次，gameId={}。",
                self.side.attempts + 1,
                self.side.game
            ),
        );
        match api.write(
            "POST",
            &path,
            Some(json!({"body":msg,"type":"chat"})),
            revision,
        ) {
            Ok(Some(result)) => {
                self.side.next = now + 1000;
                self.side.attempts += 1;
                if result.ok() {
                    self.side.finished = true;
                    self.log("side", "success", "阵营提示已发送到选人聊天。");
                } else if self.side.attempts >= 5
                    // A newly created client room can initially reject a valid
                    // message with 400 while chat finishes joining it.
                    || (!matches!(result.status, 400 | 404 | 409 | 429) && result.status < 500)
                {
                    self.side.finished = true;
                    self.log(
                        "side",
                        "failure",
                        format!(
                            "阵营消息未能发送（HTTP {}），本局已停止重试。",
                            result.status
                        ),
                    );
                } else {
                    self.log(
                        "side",
                        "warning",
                        format!(
                            "阵营消息发送失败（HTTP {}），将在 1 秒后重试。",
                            result.status
                        ),
                    );
                }
            }
            Ok(None) => self.log(
                "side",
                "info",
                "阵营提示请求已取消：客户端状态在提交前发生变化。",
            ),
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
fn selection_session(
    api: &mut impl Api,
    fresh: bool,
    game_id: i64,
) -> Result<(&'static str, Response)> {
    let primary = api.get(SESSION, fresh)?;
    let current_game = |session: &Value| {
        let id = session["gameId"].as_i64().unwrap_or(0);
        game_id == 0 || id == 0 || game_id == id
    };
    let usable = |response: &Response| {
        let session = &response.data;
        let local = session["localPlayerCellId"].as_i64().filter(|id| *id >= 0);
        response.ok()
            && current_game(session)
            && local.is_some()
            && session["myTeam"]
                .as_array()
                .is_some_and(|team| team.iter().any(|player| player["cellId"].as_i64() == local))
    };
    // Never reopen an explicitly closed session using an older alternate copy.
    if usable(&primary)
        || (primary.ok()
            && current_game(&primary.data)
            && (primary.data["timer"]["phase"] == "GAME_STARTING"
                || primary.data["isSpectating"] == true))
    {
        return Ok((SESSION, primary));
    }
    let alternate = api.get(TEAM_SESSION, fresh)?;
    if usable(&alternate) {
        Ok((TEAM_SESSION, alternate))
    } else {
        Ok((SESSION, primary))
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
