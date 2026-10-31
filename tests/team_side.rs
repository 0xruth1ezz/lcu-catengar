use catengar::{
    engine::Engine,
    model::{Preferences, Snapshot},
    notifications::{Notice, NoticeQueue},
    team_side::early_selection,
    transport::{
        Api, CONVERSATIONS, Cache, GAME, PHASE, PICKABLE, READY, Response, SESSION, TEAMBUILDER,
    },
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
    after_conversations: Option<(String, Value)>,
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
            after_conversations: None,
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
        let response = Response {
            status: if self.values.contains_key(path) {
                200
            } else {
                404
            },
            data: self.values.get(path).cloned().unwrap_or(Value::Null),
        };
        if path == CONVERSATIONS
            && let Some((path, value)) = self.after_conversations.take()
        {
            self.values.insert(path, value);
        }
        Ok(response)
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

fn early_fixture(side: u8) -> Value {
    serde_json::from_str(if side == 1 {
        include_str!("fixtures/team-side-early-blue.json")
    } else {
        include_str!("fixtures/team-side-early-red.json")
    })
    .unwrap()
}

fn edit_early(message: &mut Value, edit: impl FnOnce(&mut Value)) {
    let mut payload: Value = serde_json::from_str(message["payload"].as_str().unwrap()).unwrap();
    edit(&mut payload);
    message["payload"] = json!(payload.to_string());
}

fn early_room(f: &mut Fixture, side: u8) {
    f.values.insert(TEAMBUILDER.into(), early_fixture(side));
    f.values.insert(
        CONVERSATIONS.into(),
        json!([{"id":"fixture-room@lol-champ-select.pvp.net","type":"championSelect"}]),
    );
    f.values.get_mut(GAME).unwrap()["gameData"]["queue"] = json!({"id":2400,"gameMode":"KIWI"});
}

#[test]
fn recorded_early_team_data_notifies_before_legacy_team_or_champion_exists() {
    for side in [1, 2] {
        for legacy in [
            None,
            Some(json!({"gameId":8,"localPlayerCellId":0,"myTeam":[]})),
            Some(
                json!({"gameId":9,"localPlayerCellId":6,"myTeam":[{"cellId":6,"team":0,"championId":0}]}),
            ),
        ] {
            let mut f = Fixture::new(0);
            early_room(&mut f, side);
            if let Some(legacy) = legacy {
                f.values.insert(SESSION.into(), legacy);
            } else {
                f.values.remove(SESSION);
            }
            let mut e = f.engine();
            e.tick(&mut f, &Preferences::default, &mut Snapshot::default(), 0)
                .unwrap();
            assert_eq!(
                f.chats(),
                [&json!({"body":Notice::TeamSide(side).message(),"type":"chat"})]
            );
            let events = f.events.lock().unwrap();
            let notice = events
                .iter()
                .position(|v| v.starts_with("notice:"))
                .unwrap();
            let legacy = events
                .iter()
                .position(|v| v == &format!("get:{SESSION}"))
                .unwrap();
            assert!(
                notice < legacy,
                "early side must not wait for the legacy session"
            );
        }
    }
}

#[test]
fn legacy_session_catching_up_does_not_repeat_early_side_notice() {
    let mut f = Fixture::new(0);
    early_room(&mut f, 2);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    for now in [100, 1000, 40000] {
        e.tick(&mut f, &Preferences::default, &mut s, now).unwrap();
    }
    f.values.get_mut(SESSION).unwrap()["myTeam"][0]["team"] = json!(2);
    f.values.get_mut(SESSION).unwrap()["chatDetails"] =
        json!({"multiUserChatId":"c1~fixture-room@lol-champ-select.pvp.net"});
    for now in [45000, 46000] {
        e.tick(&mut f, &Preferences::default, &mut s, now).unwrap();
    }
    assert_eq!(f.chats().len(), 1);
    assert_eq!(e.notices, [Notice::TeamSide(2)]);
}

#[test]
fn early_data_requires_current_game_local_ally_and_explicit_team() {
    for change in 0..7 {
        let mut data = early_fixture(2);
        edit_early(&mut data, |p| match change {
            0 => p["gameId"] = json!(8),
            1 => p["phaseName"] = json!("GAME_START"),
            2 => p["championSelectState"]["isSpectating"] = json!(true),
            3 => p["championSelectState"]["localPlayerCellId"] = json!(-1),
            4 => p["championSelectState"]["localPlayerCellId"] = json!(0), // enemy, not us
            5 => p["championSelectState"]["cells"]["alliedTeam"][1]["teamId"] = json!(200),
            _ => p["championSelectState"]["teamChatRoomId"] = json!(""),
        });
        assert!(
            early_selection(&data, 9).is_none(),
            "invalid early data {change}"
        );
        let mut f = Fixture::new(0);
        early_room(&mut f, 2);
        f.values.insert(TEAMBUILDER.into(), data);
        let mut e = Engine::default();
        e.tick(&mut f, &Preferences::default, &mut Snapshot::default(), 0)
            .unwrap();
        assert!(f.chats().is_empty() && e.notices.is_empty());
    }
    assert!(early_selection(&early_fixture(2), 0).is_none());
}

#[test]
fn early_data_supports_encoded_or_decoded_payload_and_snapshot_list() {
    let encoded = early_fixture(1);
    let expected = early_selection(&encoded, 9).unwrap();
    let decoded = json!({"payload":serde_json::from_str::<Value>(encoded["payload"].as_str().unwrap()).unwrap()});
    assert_eq!(early_selection(&decoded, 9), Some(expected.clone()));
    assert_eq!(
        early_selection(&json!([encoded, decoded]), 9),
        Some(expected)
    );
    assert!(early_selection(&json!([early_fixture(1), early_fixture(2)]), 9).is_none());
}

#[test]
fn early_side_rechecks_phase_game_and_source_after_room_discovery() {
    for (path, changed) in [
        (PHASE, json!("Lobby")),
        (
            GAME,
            json!({"phase":"ChampSelect","gameData":{"gameId":10,"queue":{"id":2400,"gameMode":"KIWI"}}}),
        ),
        (TEAMBUILDER, early_fixture(1)),
    ] {
        let mut f = Fixture::new(0);
        early_room(&mut f, 2);
        f.after_conversations = Some((path.into(), changed));
        let mut e = Engine::default();
        e.tick(&mut f, &Preferences::default, &mut Snapshot::default(), 0)
            .unwrap();
        assert!(f.chats().is_empty(), "stale source: {path}");
    }
}

#[test]
fn early_event_survives_later_phase_event_and_missing_rest_snapshot() {
    let mut cache = Cache::default();
    let event = Response {
        status: 200,
        data: early_fixture(2),
    };
    cache.apply(TEAMBUILDER, event.clone());
    cache.apply(
        PHASE,
        Response {
            status: 200,
            data: json!("ChampSelect"),
        },
    );
    for response in [
        Response {
            status: 404,
            data: Value::Null,
        },
        Response {
            status: 200,
            data: json!([]),
        },
    ] {
        let result = cache.reconcile(TEAMBUILDER, response, cache.revision);
        assert_eq!(result, event);
    }
    cache.apply(
        TEAMBUILDER,
        Response {
            status: 404,
            data: Value::Null,
        },
    );
    let deleted = cache.reconcile(
        TEAMBUILDER,
        Response {
            status: 404,
            data: Value::Null,
        },
        cache.revision,
    );
    assert_eq!(deleted.status, 404);
}

#[test]
fn newly_joined_chat_rejection_is_retried_without_repeating_popup() {
    let mut f = Fixture::new(0);
    early_room(&mut f, 2);
    f.chat_status = 400;
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    f.chat_status = 200;
    e.tick(&mut f, &Preferences::default, &mut s, 1000).unwrap();
    e.tick(&mut f, &Preferences::default, &mut s, 2000).unwrap();
    assert_eq!(f.chats().len(), 2);
    assert_eq!(e.notices, [Notice::TeamSide(2)]);
    assert!(
        e.logs
            .iter()
            .any(|entry| entry.kind == "side" && entry.level == "success")
    );
}
