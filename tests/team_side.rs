use catengar::{
    engine::Engine,
    model::{Preferences, Snapshot},
    notifications::{Notice, NoticeQueue},
    transport::{Api, CONVERSATIONS, Cache, GAME, PHASE, PICKABLE, READY, Response, SESSION},
};
use serde_json::{Value, json};
use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

struct Fixture {
    values: HashMap<String, Value>,
    writes: Vec<(String, Value)>,
    events: Arc<Mutex<Vec<String>>>,
    chat_revision: u64,
    fail_pick: bool,
    chat_status: u16,
    stale: bool,
}
impl Fixture {
    fn new(side: u8) -> Self {
        Self {
            values: HashMap::from([
                (PHASE.into(), json!("ChampSelect")),
                (
                    GAME.into(),
                    json!({"phase":"ChampSelect", "gameData":{"gameId":9,"queue":{"id":450,"gameMode":"ARAM"}}}),
                ),
                (
                    SESSION.into(),
                    json!({"gameId":9,"localPlayerCellId":0,"myTeam":[{"cellId":0,"team":side,"championId":22}],"benchEnabled":true,"benchChampionIds":[107],"chatDetails":{"multiUserChatId":"room"}}),
                ),
                (
                    CONVERSATIONS.into(),
                    json!([{"id":"c1~room@server","type":"championSelect"}]),
                ),
            ]),
            writes: vec![],
            events: Arc::default(),
            chat_revision: 0,
            fail_pick: false,
            chat_status: 204,
            stale: false,
        }
    }
    fn engine(&self) -> Engine {
        let events = self.events.clone();
        Engine::with_notifier(move |n| {
            events
                .lock()
                .unwrap()
                .push(format!("notice:{}", n.message()))
        })
    }
    fn chats(&self) -> Vec<&Value> {
        self.writes
            .iter()
            .filter(|(path, _)| path.ends_with("/messages"))
            .map(|(_, body)| body)
            .collect()
    }
}
impl Api for Fixture {
    fn get(&mut self, path: &str, _: bool) -> anyhow::Result<Response> {
        self.events.lock().unwrap().push(format!("get:{path}"));
        if self.fail_pick && path == PICKABLE {
            anyhow::bail!("pickable read failed");
        }
        Ok(Response {
            status: if self.values.contains_key(path) {
                200
            } else {
                404
            },
            data: self.values.get(path).cloned().unwrap_or(Value::Null),
        })
    }
    fn write(
        &mut self,
        _: &str,
        path: &str,
        body: Option<Value>,
        _: u64,
    ) -> anyhow::Result<Option<Response>> {
        if self.stale {
            return Ok(None);
        }
        self.events.lock().unwrap().push(format!("write:{path}"));
        self.writes.push((path.into(), body.unwrap_or(Value::Null)));
        Ok(Some(Response {
            status: self.chat_status,
            data: Value::Null,
        }))
    }
    fn revision(&self) -> u64 {
        0
    }
    fn chat_revision(&self) -> u64 {
        self.chat_revision
    }
}

#[test]
fn matching_completion_notifies_and_sends_both_colors_with_automation_disabled() {
    for (side, color, emoji) in [(1, "蓝", "🟦"), (2, "红", "🟥")] {
        let mut f = Fixture::new(side);
        let mut e = f.engine();
        let mut s = Snapshot::default();
        f.values.insert(PHASE.into(), json!("ReadyCheck"));
        f.values.insert(
            READY.into(),
            json!({"state":"InProgress","playerResponse":"Accepted"}),
        );
        e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
        assert!(f.chats().is_empty());
        f.values.insert(PHASE.into(), json!("ChampSelect"));
        e.tick(&mut f, &Preferences::default, &mut s, 100).unwrap();
        let message = format!("{emoji} 本局我方为{color}色方 - by (Catengar)");
        assert_eq!(f.chats(), [&json!({"body":message,"type":"chat"})]);
        let events = f.events.lock().unwrap().clone();
        let notice = events
            .iter()
            .position(|v| v == &format!("notice:{message}"))
            .unwrap();
        let chat = events
            .iter()
            .position(|v| v == &format!("get:{CONVERSATIONS}"))
            .unwrap();
        assert!(
            notice < chat,
            "popup must be delivered before blocking chat I/O"
        );
        for now in [200, 400, 1000, 5000] {
            e.tick(&mut f, &Preferences::default, &mut s, now).unwrap();
        }
        e.disconnected(&s);
        e.tick(&mut f, &Preferences::default, &mut s, 6000).unwrap();
        assert_eq!(f.chats().len(), 1);
        assert_eq!(
            f.events
                .lock()
                .unwrap()
                .iter()
                .filter(|v| v.starts_with("notice:"))
                .count(),
            1
        );
    }
}

#[test]
fn pick_failure_cannot_suppress_chat_or_popup() {
    let mut f = Fixture::new(1);
    f.values.get_mut(SESSION).unwrap()["actions"] =
        json!([[{"id":1,"actorCellId":0,"type":"pick","isInProgress":true,"completed":false}]]);
    f.fail_pick = true;
    let mut e = f.engine();
    let prefs = || Preferences {
        auto_pick: true,
        priority: vec![107],
        ..Default::default()
    };
    assert!(e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).is_err());
    assert_eq!(f.chats().len(), 1);
    let events = f.events.lock().unwrap();
    let notice = events
        .iter()
        .position(|v| v.starts_with("notice:"))
        .unwrap();
    let chat = events.iter().position(|v| v.starts_with("write:")).unwrap();
    let pick = events
        .iter()
        .position(|v| v == &format!("get:{PICKABLE}"))
        .unwrap();
    assert!(notice < chat && chat < pick);
}

#[test]
fn room_creation_event_sends_without_waiting_for_retry_timer() {
    let mut f = Fixture::new(2);
    let rooms = f.values.insert(CONVERSATIONS.into(), json!([])).unwrap();
    let mut e = f.engine();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    assert_eq!(
        f.events
            .lock()
            .unwrap()
            .iter()
            .filter(|v| v.starts_with("notice:"))
            .count(),
        1
    );
    assert!(f.chats().is_empty());
    f.values.insert(CONVERSATIONS.into(), rooms);
    e.tick(&mut f, &Preferences::default, &mut s, 50).unwrap();
    assert!(f.chats().is_empty());
    f.chat_revision += 1;
    e.tick(&mut f, &Preferences::default, &mut s, 51).unwrap();
    assert_eq!(f.chats().len(), 1);
}

#[test]
fn missing_room_event_is_recovered_by_short_rest_retry() {
    let mut f = Fixture::new(1);
    let rooms = f.values.insert(CONVERSATIONS.into(), json!([])).unwrap();
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    f.values.insert(CONVERSATIONS.into(), rooms);
    e.tick(&mut f, &Preferences::default, &mut s, 250).unwrap();
    assert_eq!(f.chats().len(), 1);
}

#[test]
fn delayed_team_data_sends_as_soon_as_side_is_known() {
    let mut f = Fixture::new(0);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    assert!(f.chats().is_empty() && e.notices.is_empty());
    f.values.get_mut(SESSION).unwrap()["myTeam"][0]["team"] = json!(2);
    e.tick(&mut f, &Preferences::default, &mut s, 1).unwrap();
    assert_eq!(f.chats().len(), 1);
    assert_eq!(e.notices, [Notice::TeamSide(2)]);
}

#[test]
fn only_current_unambiguous_champion_select_room_is_used() {
    for rooms in [
        json!([{"id":"c1~room@server","type":"party"}]),
        json!([{"id":"c1~previous@server","type":"championSelect"}]),
        json!([{"id":"c1~room@server","type":"championSelect"},{"id":"other","pid":"room","type":"championSelect"}]),
    ] {
        let mut f = Fixture::new(1);
        f.values.insert(CONVERSATIONS.into(), rooms);
        let mut e = Engine::default();
        e.tick(&mut f, &Preferences::default, &mut Snapshot::default(), 0)
            .unwrap();
        assert!(f.chats().is_empty());
        assert_eq!(e.notices.len(), 1);
    }
}

#[test]
fn retryable_post_errors_keep_one_second_backoff_despite_chat_events() {
    let mut f = Fixture::new(1);
    f.chat_status = 503;
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    for now in 0..6000 {
        f.chat_revision += 1;
        e.tick(&mut f, &Preferences::default, &mut s, now).unwrap();
    }
    assert_eq!(f.chats().len(), 5);
    assert_eq!(e.notices.len(), 1);
}

#[test]
fn stale_decision_retries_without_counting_an_unsent_message() {
    let mut f = Fixture::new(1);
    f.stale = true;
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    for now in (0..2000).step_by(250) {
        e.tick(&mut f, &Preferences::default, &mut s, now).unwrap();
    }
    assert!(f.chats().is_empty());
    f.stale = false;
    e.tick(&mut f, &Preferences::default, &mut s, 2000).unwrap();
    assert_eq!(f.chats().len(), 1);
}

#[test]
fn cancelled_round_allows_a_new_side_notice() {
    let mut f = Fixture::new(1);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    f.values.insert(PHASE.into(), json!("Lobby"));
    e.tick(&mut f, &Preferences::default, &mut s, 1).unwrap();
    f.values.insert(PHASE.into(), json!("ChampSelect"));
    f.values.get_mut(SESSION).unwrap()["myTeam"][0]["team"] = json!(2);
    e.tick(&mut f, &Preferences::default, &mut s, 2).unwrap();
    assert_eq!(f.chats().len(), 2);
    assert_eq!(e.notices, [Notice::TeamSide(1), Notice::TeamSide(2)]);
}

#[test]
fn team_side_preempts_active_toast_and_queued_messages() {
    let mut q = NoticeQueue::default();
    q.push("已自动接受对局".into());
    assert!(q.take(false).is_some());
    q.push("其他通知".into());
    assert!(q.take(true).is_none());
    q.push(Notice::TeamSide(1));
    assert_eq!(q.take(true), Some(Notice::TeamSide(1)));
    assert!(q.take(true).is_none());
    assert_eq!(q.take(false), Some("其他通知".into()));
}

#[test]
fn conversation_events_wake_notices_without_invalidating_pick_decisions() {
    let mut cache = Cache::default();
    for path in [CONVERSATIONS, "/lol-chat/v1/conversations/c1~room@server"] {
        let before = cache.chat_revision;
        cache.apply(
            path,
            Response {
                status: 200,
                data: json!({}),
            },
        );
        assert_eq!(cache.chat_revision, before + 1);
        assert_eq!(cache.revision, 0);
    }
    let before = cache.chat_revision;
    cache.apply(
        "/lol-chat/v1/conversations/room/messages",
        Response {
            status: 200,
            data: json!({}),
        },
    );
    assert_eq!(cache.chat_revision, before);
}
