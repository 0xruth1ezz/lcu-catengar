use catengar::{
    auth::{self, Credentials, Identity},
    engine::{Engine, Retry, own_side, side_supported},
    model::*,
    storage,
    transport::{Api, Cache, GAME, PHASE, PICKABLE, READY, Response, SESSION},
};
use serde_json::{Value, json};
use std::collections::HashMap;

fn prefs() -> Preferences {
    Preferences {
        auto_accept: true,
        auto_pick: true,
        priority: vec![107, 103, 22],
        ..Default::default()
    }
}
fn session(current: i32) -> Value {
    json!({"localPlayerCellId":0,"myTeam":[{"cellId":0,"championId":current,"team":0}],"benchEnabled":true,"benchChampionIds":[107,103,22],"gameId":9})
}
#[derive(Default)]
struct Fake {
    values: HashMap<String, Value>,
    writes: Vec<(String, String, Option<Value>)>,
    status: u16,
    fail_write: bool,
    stale: bool,
}
impl Fake {
    fn select(current: i32) -> Self {
        let mut f = Self {
            status: 204,
            ..Default::default()
        };
        f.values.insert(PHASE.into(), json!("ChampSelect"));
        f.values.insert(GAME.into(),json!({"phase":"ChampSelect","gameData":{"gameId":9,"queue":{"id":450,"gameMode":"ARAM"}}}));
        f.values.insert(SESSION.into(), session(current));
        f.values.insert(PICKABLE.into(), json!([]));
        f
    }
}
impl Api for Fake {
    fn get(&mut self, path: &str, _fresh: bool) -> anyhow::Result<Response> {
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
        method: &str,
        path: &str,
        body: Option<Value>,
        _: u64,
    ) -> anyhow::Result<Option<Response>> {
        if self.stale {
            return Ok(None);
        }
        self.writes.push((method.into(), path.into(), body));
        if self.fail_write {
            anyhow::bail!("network");
        }
        Ok(Some(Response {
            status: self.status,
            data: Value::Null,
        }))
    }
    fn revision(&self) -> u64 {
        0
    }
}
#[test]
fn default_switches_are_off_and_policy_is_on() {
    let p = Preferences::default();
    assert!(!p.auto_accept && !p.auto_pick && p.always_prioritize);
}
#[test]
fn unknown_theme_preserves_other_preferences() {
    let p: Preferences =
        serde_json::from_value(json!({"theme":"future_theme","auto_accept":true,"priority":[107]}))
            .unwrap();
    assert_eq!(p.theme, Theme::ClassicGold);
    assert!(p.auto_accept);
    assert_eq!(p.priority, [107]);
}
#[test]
fn unreadable_settings_and_cache_survive_offline_service_shutdown() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(
        temp.path().join("settings.json"),
        b"broken original settings",
    )
    .unwrap();
    std::fs::write(
        temp.path().join("priority-champions.json"),
        b"original cache",
    )
    .unwrap();
    let app = catengar::service::Service::start(temp.path().into(), true).unwrap();
    std::thread::sleep(std::time::Duration::from_millis(250));
    app.stop();
    assert!(!app.read().prefs.auto_accept);
    assert_eq!(
        std::fs::read(temp.path().join("settings.json")).unwrap(),
        b"broken original settings"
    );
    assert_eq!(
        std::fs::read(temp.path().join("priority-champions.json")).unwrap(),
        b"original cache"
    );
}
#[test]
fn settings_remain_backward_compatible() {
    let temp = tempfile::tempdir().unwrap();
    std::fs::write(
        temp.path().join("settings.json"),
        r#"{"version":1,"theme":"nord","auto_accept":true,"priority":[107,107,-1,103]}"#,
    )
    .unwrap();
    let p = storage::load_preferences(temp.path()).unwrap();
    assert!(p.always_prioritize && p.auto_accept);
    assert_eq!(p.theme, Theme::Nord);
    assert_eq!(p.priority, vec![107, 103]);
}
#[test]
fn settings_limit_dedupe_reorder_and_remove() {
    let mut p = Preferences {
        priority: (-2..40).collect(),
        ..Default::default()
    };
    p.normalize();
    assert_eq!(p.priority.len(), 32);
    p.toggle(99);
    assert_eq!(p.priority.len(), 32);
    p.reorder(1, false);
    assert_eq!(&p.priority[..2], &[2, 1]);
    p.toggle(1);
    p.toggle(99);
    assert_eq!(p.priority.last(), Some(&99));
}
#[test]
fn settings_roundtrip_is_atomic() {
    let temp = tempfile::tempdir().unwrap();
    let p = prefs();
    storage::save_preferences(temp.path(), &p).unwrap();
    assert_eq!(storage::load_preferences(temp.path()).unwrap(), p);
    assert_eq!(std::fs::read_dir(temp.path()).unwrap().count(), 1);
}
#[test]
fn unknown_settings_version_is_rejected() {
    let t = tempfile::tempdir().unwrap();
    std::fs::write(t.path().join("settings.json"), r#"{"version":2}"#).unwrap();
    assert!(storage::load_preferences(t.path()).is_err());
}
#[test]
fn jade_entries_never_enter_library() {
    assert!(!candidate(100, "jAdE_Rengar"));
    assert!(!candidate(-1, "Rengar"));
    assert!(candidate(107, "Rengar"));
}
#[test]
fn local_asset_paths_cannot_escape_lcu() {
    for p in [
        "https://evil/image",
        "/lol-game-data/assets/../x",
        "/lol-game-data/assets/%2e%2e/x",
        "/lol-game-data/assets/a?x",
        "/lol-game-data/assets/a\\b",
    ] {
        assert!(!valid_asset(p), "{p}");
    }
    assert!(valid_asset(
        "/lol-game-data/assets/v1/champion-icons/107.png"
    ));
}
#[test]
fn portrait_paths_stay_under_cache() {
    for p in [
        "cache/../settings.json",
        "../x",
        "cache/C:/x",
        "C:/x",
        "/cache/x",
        "cache/a\\b",
    ] {
        assert!(!storage::valid_portrait(p), "{p}");
    }
    assert!(storage::valid_portrait("cache/版本/107.png"));
}
#[test]
fn offline_priority_cache_preserves_names_and_safe_portraits() {
    let temp = tempfile::tempdir().unwrap();
    let mut c = Champion {
        id: 107,
        name: "雷恩加尔".into(),
        alias: "Rengar".into(),
        asset: "/lol-game-data/assets/v1/champion-icons/107.png".into(),
        portrait: "cache/v/107.png".into(),
    };
    std::fs::create_dir_all(temp.path().join("cache/v")).unwrap();
    std::fs::write(temp.path().join(&c.portrait), b"fixture").unwrap();
    storage::save_priorities(temp.path(), &prefs(), &[c.clone()]).unwrap();
    assert_eq!(
        storage::load_priorities(temp.path(), &prefs()).unwrap(),
        vec![c.clone()]
    );
    c.portrait = "../secret".into();
    storage::save_priorities(temp.path(), &prefs(), &[c]).unwrap();
    assert!(
        storage::load_priorities(temp.path(), &prefs()).unwrap()[0]
            .portrait
            .is_empty()
    );
}
#[test]
fn auto_accept_requires_exact_ready_state() {
    let r = json!({"state":"InProgress","playerResponse":"None"});
    assert!(should_accept(true, "ReadyCheck", &r));
    assert!(!should_accept(false, "ReadyCheck", &r));
    assert!(!should_accept(true, "Lobby", &r));
    for answer in ["Accepted", "Declined"] {
        assert!(!should_accept(
            true,
            "ReadyCheck",
            &json!({"state":"InProgress","playerResponse":answer})
        ));
    }
}
#[test]
fn unknown_modes_and_spectators_never_pick() {
    let p = prefs();
    assert!(choose(&p, 420, "CLASSIC", &session(22), &[]).is_none());
    let mut s = session(22);
    s["isSpectating"] = json!(true);
    assert!(choose(&p, 450, "ARAM", &s, &[]).is_none());
    s["isSpectating"] = json!(false);
    s["localPlayerCellId"] = Value::Null;
    assert!(choose(&p, 450, "ARAM", &s, &[]).is_none());
}
#[test]
fn known_and_explicit_rotated_aram_queues_are_supported() {
    assert!(aram(450, ""));
    assert!(aram(2400, ""));
    assert!(aram(999, "ARAM_MAYHEM"));
    assert!(!aram(0, ""));
}
#[test]
fn higher_priority_held_champion_is_kept() {
    assert!(choose(&prefs(), 450, "ARAM", &session(107), &[]).is_none());
    assert_eq!(
        choose(&prefs(), 450, "ARAM", &session(103), &[])
            .unwrap()
            .champion,
        107
    );
}
#[test]
fn bench_candidates_include_entries_despite_ui_availability_hints() {
    let mut s = session(22);
    s["benchChampions"] =
        json!([{"championId":107,"isAvailable":false},{"championId":103,"isAvailable":true}]);
    assert_eq!(bench_ids(&s), vec![107, 103, 22]);
    assert_eq!(
        choose(&prefs(), 450, "ARAM", &s, &[]).unwrap().champion,
        107
    );
}
#[test]
fn bench_does_not_wait_for_client_animation() {
    let mut s = session(22);
    s["benchChampionIds"] = json!([107]);
    s["allowRerolling"] = json!(false);
    s["rerollsRemaining"] = json!(0);
    s["benchEnabled"] = json!(true);
    assert_eq!(
        choose(&prefs(), 450, "ARAM", &s, &[]).unwrap().champion,
        107
    );
}
#[test]
fn card_pick_requires_own_unfinished_action_and_candidate_id() {
    let mut s = session(0);
    s["benchChampionIds"] = json!([]);
    s["actions"] =
        json!([[{"id":4,"actorCellId":0,"type":"pick","isInProgress":true,"completed":false}]]);
    assert!(choose(&prefs(), 450, "ARAM", &s, &[]).is_none());
    assert_eq!(
        choose(&prefs(), 450, "ARAM", &s, &[107]).unwrap().action,
        Some(4)
    );
    s["actions"][0][0]["isInProgress"] = json!(false);
    assert_eq!(
        choose(&prefs(), 450, "ARAM", &s, &[107]).unwrap().action,
        Some(4)
    );
    s["actions"][0][0]["actorCellId"] = json!(1);
    assert!(choose(&prefs(), 450, "ARAM", &s, &[107]).is_none());
}
#[test]
fn retry_backoff_is_bounded_and_target_changes_reset() {
    let mut r = Retry::default();
    assert!(r.allowed(1, 0));
    r.record(0, false);
    assert!(!r.allowed(1, 499));
    assert!(r.allowed(1, 500));
    for _ in 0..10 {
        r.record(1000, false);
    }
    assert!(!r.allowed(1, 4999));
    assert!(r.allowed(1, 5000));
    assert!(r.allowed(2, 1));
}
#[test]
fn successful_accept_is_not_repeated_even_across_disconnect() {
    let mut f = Fake {
        status: 204,
        ..Default::default()
    };
    f.values.insert(PHASE.into(), json!("ReadyCheck"));
    f.values.insert(
        READY.into(),
        json!({"state":"InProgress","playerResponse":"None"}),
    );
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    for now in [0, 1000, 3000] {
        e.tick(&mut f, &prefs, &mut s, now).unwrap();
        e.disconnected(&s);
    }
    assert_eq!(f.writes.len(), 1);
    assert_eq!(s.accepted, 1);
    f.values.insert(PHASE.into(), json!("Lobby"));
    e.tick(&mut f, &prefs, &mut s, 4000).unwrap();
    f.values.insert(PHASE.into(), json!("ReadyCheck"));
    e.tick(&mut f, &prefs, &mut s, 5000).unwrap();
    assert_eq!(s.accepted, 2);
}
#[test]
fn http_204_alone_never_completes_pick() {
    let mut f = Fake::select(22);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    assert!(!e.completed);
    assert_eq!(s.swapped, 0);
    assert_eq!(f.writes[0].1, "/lol-champ-select/v1/session/bench/swap/107");
    assert!(!e.logs.iter().any(|e| e.level == "success"));
}
#[test]
fn only_confirmed_automatic_selection_completes_round() {
    let mut f = Fake::select(22);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    f.values.insert(SESSION.into(), session(107));
    e.tick(&mut f, &prefs, &mut s, 100).unwrap();
    assert!(e.completed);
    assert_eq!(s.swapped, 1);
    e.tick(&mut f, &prefs, &mut s, 200).unwrap();
    assert_eq!(s.swapped, 1);
}
#[test]
fn manually_held_priority_does_not_complete_round() {
    let mut f = Fake::select(107);
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert!(!e.completed);
    assert!(f.writes.is_empty());
}
#[test]
fn stopped_round_survives_disconnect_theme_and_switch_changes() {
    let mut f = Fake::select(22);
    let mut p = prefs();
    p.always_prioritize = false;
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &|| p.clone(), &mut s, 0).unwrap();
    f.values.insert(SESSION.into(), session(107));
    e.tick(&mut f, &|| p.clone(), &mut s, 100).unwrap();
    e.disconnected(&s);
    p.theme = Theme::Nord;
    p.auto_pick = false;
    e.tick(&mut f, &|| p.clone(), &mut s, 200).unwrap();
    p.auto_pick = true;
    f.values.insert(SESSION.into(), session(22));
    e.tick(&mut f, &|| p.clone(), &mut s, 4000).unwrap();
    assert!(e.completed);
    assert_eq!(f.writes.len(), 1);
    p.always_prioritize = true;
    e.tick(&mut f, &|| p.clone(), &mut s, 5000).unwrap();
    assert_eq!(f.writes.len(), 2);
}
#[test]
fn new_64_bit_game_id_rearms_round() {
    let mut f = Fake::select(22);
    let p = Preferences {
        always_prioritize: false,
        ..prefs()
    };
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &|| p.clone(), &mut s, 0).unwrap();
    f.values.insert(SESSION.into(), session(107));
    e.tick(&mut f, &|| p.clone(), &mut s, 100).unwrap();
    let id = 9_223_372_036_854_775_000i64;
    f.values.get_mut(GAME).unwrap()["gameData"]["gameId"] = json!(id);
    let mut s2 = session(22);
    s2["gameId"] = json!(id);
    f.values.insert(SESSION.into(), s2);
    e.tick(&mut f, &|| p.clone(), &mut s, 4000).unwrap();
    assert!(!e.completed);
    assert_eq!(f.writes.len(), 2);
}
#[test]
fn failed_and_unconfirmed_picks_remain_retryable() {
    for status in [409, 204] {
        let mut f = Fake::select(22);
        f.values.get_mut(SESSION).unwrap()["benchChampionIds"] = json!([107]);
        f.status = status;
        let mut e = Engine::default();
        let mut s = Snapshot::default();
        e.tick(&mut f, &prefs, &mut s, 0).unwrap();
        e.tick(&mut f, &prefs, &mut s, 4001).unwrap();
        assert_eq!(f.writes.len(), 2);
        assert!(!e.completed);
        assert_eq!(s.swapped, 0);
    }
}
#[test]
fn stale_decision_does_not_write() {
    let mut f = Fake::select(22);
    f.stale = true;
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert!(f.writes.is_empty());
    assert!(!e.completed);
}
#[test]
fn mismatched_game_and_selection_are_ignored() {
    let mut f = Fake::select(22);
    f.values.get_mut(SESSION).unwrap()["gameId"] = json!(10);
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert!(f.writes.is_empty());
}
#[test]
fn websocket_events_win_over_older_rest_reads() {
    let mut c = Cache::default();
    let initial = c.revision;
    c.apply(
        PHASE,
        Response {
            status: 200,
            data: json!("ChampSelect"),
        },
    );
    let result = c.reconcile(
        PHASE,
        Response {
            status: 200,
            data: json!("Lobby"),
        },
        initial,
    );
    assert_eq!(result.data, "ChampSelect");
}
#[test]
fn phase_change_invalidates_cached_selection() {
    let mut c = Cache::default();
    c.apply(
        SESSION,
        Response {
            status: 200,
            data: session(22),
        },
    );
    let before = c.revision;
    c.apply(
        PHASE,
        Response {
            status: 200,
            data: json!("Lobby"),
        },
    );
    let result = c.reconcile(
        SESSION,
        Response {
            status: 200,
            data: session(22),
        },
        before,
    );
    assert_eq!(result.status, 409);
}
#[test]
fn team_side_requires_known_player_team_and_supported_mode() {
    let mut s = session(22);
    s["myTeam"][0]["team"] = json!(1);
    assert_eq!(own_side(&s), 1);
    s["isSpectating"] = json!(true);
    assert_eq!(own_side(&s), 0);
    assert!(!side_supported(
        &json!({"gameData":{"queue":{"id":450,"gameMode":"CHERRY"}}})
    ));
}
#[test]
fn interrupted_chat_is_never_repeated() {
    let mut f = Fake::select(107);
    f.values.get_mut(SESSION).unwrap()["myTeam"][0]["team"] = json!(1);
    f.values.get_mut(SESSION).unwrap()["chatDetails"] = json!({"multiUserChatId":"room"});
    f.values.insert(
        "/lol-chat/v1/conversations".into(),
        json!([{"id":"c1~room@server","type":"championSelect"}]),
    );
    f.fail_write = true;
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    e.disconnected(&s);
    e.tick(&mut f, &prefs, &mut s, 2000).unwrap();
    assert_eq!(f.writes.len(), 1);
    assert_eq!(e.notices.len(), 1);
}
#[test]
fn auth_packet_roundtrip_and_invalid_packet_rejection() {
    let c = Credentials {
        port: 2999,
        pid: 123,
        token: "test-secret".into(),
    };
    let packet = auth::encode(&Identity::Ready(c.clone()));
    assert_eq!(auth::decode(&packet).unwrap(), Identity::Ready(c));
    for at in [0, 5, 271] {
        let mut p = packet;
        p[at] = 255;
        assert!(auth::decode(&p).is_err());
    }
    assert!(auth::decode(&packet[..100]).is_err());
    assert!(!format!("{:?}", auth::decode(&packet).unwrap()).contains("test-secret"));
}
#[test]
fn auth_packet_rejects_whitespace_and_oversized_token() {
    for token in ["x\ny".into(), "x".repeat(257), String::new()] {
        let c = Credentials {
            port: 1,
            pid: 1,
            token,
        };
        assert!(!c.valid());
    }
}
#[test]
fn updater_blocks_gameplay_unknown_and_matchmaking() {
    let mut s = Snapshot {
        connected: true,
        ..Default::default()
    };
    for phase in [
        "ReadyCheck",
        "ChampSelect",
        "Matchmaking",
        "InProgress",
        "GameStart",
        "Reconnect",
        "unknown",
        "",
    ] {
        s.phase = phase.into();
        assert!(!s.can_install());
    }
    for phase in ["None", "Lobby", "EndOfGame", "TerminatedInError"] {
        s.phase = phase.into();
        assert!(s.can_install());
    }
}
#[test]
fn journal_persists_pages_and_clears_without_touching_settings() {
    let temp = tempfile::tempdir().unwrap();
    storage::save_preferences(temp.path(), &prefs()).unwrap();
    let (j, h) = catengar::journal::Journal::start(temp.path().into());
    for n in 0..45 {
        j.log("pick", "info", format!("event {n}"));
    }
    let page = j
        .page(20)
        .recv_timeout(std::time::Duration::from_secs(5))
        .unwrap();
    assert_eq!(page.total, 45);
    assert_eq!(page.entries.len(), 20);
    assert_eq!(page.entries[0].message, "event 24");
    j.log("pick", "info", "new live event");
    let frozen = j.page_at(20, Some(45)).recv().unwrap();
    assert_eq!(frozen.total, 45);
    assert_eq!(frozen.entries[0].message, "event 24");
    assert_eq!(j.page(0).recv().unwrap().total, 46);
    assert!(j.clear().recv().unwrap());
    let cleared = j.page(0).recv().unwrap();
    assert_eq!(cleared.total, 1);
    assert_eq!(cleared.entries[0].kind, "user");
    assert_eq!(cleared.entries[0].message, "玩家已清空历史日志。");
    j.log("app", "info", "after clear");
    assert_eq!(j.page(0).recv().unwrap().total, 2);
    j.stop();
    h.join().unwrap();
    assert_eq!(storage::load_preferences(temp.path()).unwrap(), prefs());
}

#[test]
fn journal_preserves_worker_event_time_and_flushes_on_stop() {
    use catengar::journal::{Entry, Journal};
    let temp = tempfile::tempdir().unwrap();
    let (journal, worker) = Journal::start(temp.path().into());
    let entry = Entry {
        timestamp: "2026-10-31 01:02:03.456".into(),
        ..Entry::new("pick", "success", "worker event")
    };
    journal.append(entry.clone());
    journal.stop();
    worker.join().unwrap();
    let saved = std::fs::read_to_string(&journal.path).unwrap();
    assert_eq!(serde_json::from_str::<Entry>(saved.trim()).unwrap(), entry);
}

#[test]
fn ready_response_is_observed_with_automation_off_without_duplicate_logs() {
    let mut f = Fake::default();
    f.values.insert(PHASE.into(), json!("ReadyCheck"));
    f.values.insert(
        READY.into(),
        json!({"state":"InProgress","playerResponse":"None"}),
    );
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    let count = e.logs.len();
    e.tick(&mut f, &Preferences::default, &mut s, 100).unwrap();
    assert_eq!(e.logs.len(), count);
    f.values.get_mut(READY).unwrap()["playerResponse"] = json!("Accepted");
    e.tick(&mut f, &Preferences::default, &mut s, 200).unwrap();
    assert_eq!(e.logs.len(), count + 1);
    assert!(e.logs.last().unwrap().message.contains("本机响应=Accepted"));
    assert!(f.writes.is_empty());
    assert_eq!(s.accepted, 0);
}

#[test]
fn interrupted_acceptance_is_logged_without_claiming_success() {
    let mut f = Fake {
        fail_write: true,
        ..Default::default()
    };
    f.values.insert(PHASE.into(), json!("ReadyCheck"));
    f.values.insert(
        READY.into(),
        json!({"state":"InProgress","playerResponse":"None"}),
    );
    let mut e = Engine::default();
    assert!(e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).is_err());
    let entries: Vec<_> = e.logs.iter().filter(|e| e.kind == "accept").collect();
    assert_eq!(entries.len(), 2);
    assert!(entries[0].message.contains("准备提交"));
    assert_eq!(entries[1].level, "failure");
    assert!(entries[1].message.contains("结果未确认"));
}
