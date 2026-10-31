//! Selection opportunities are decided by API responses, not UI timers.
use catengar::{
    engine::Engine,
    model::{Preferences, RoundPick, Snapshot},
    transport::{Api, Cache, GAME, PHASE, PICKABLE, PROFILE, Response, SESSION, SUBSET},
};
use serde_json::{Value, json};
use std::{
    cell::RefCell,
    collections::HashMap,
    sync::{Arc, Mutex},
};

fn prefs() -> Preferences {
    Preferences {
        auto_pick: true,
        priority: vec![107, 103, 22],
        ..Default::default()
    }
}

#[test]
fn client_changes_are_logged_once_and_distinguish_confirmed_automation() {
    let mut f = Fake::new(22);
    f.bench(&[103, 107]);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &Preferences::default, &mut s, 0).unwrap();
    let count = e.logs.len();
    f.bench(&[107, 103]); // A reordered pool is not an availability change.
    e.tick(&mut f, &Preferences::default, &mut s, 100).unwrap();
    assert_eq!(e.logs.len(), count);
    f.session()["myTeam"][0]["championId"] = json!(103);
    e.tick(&mut f, &Preferences::default, &mut s, 200).unwrap();
    let change = e.logs.last().unwrap();
    assert_eq!(change.kind, "client");
    assert!(change.message.contains("可能来自玩家操作或客户端分配"));
    assert!(change.message.contains("gameId=9"));
    assert!(f.writes.is_empty());
    e.tick(&mut f, &prefs, &mut s, 300).unwrap();
    assert_eq!(s.swapped, 0);
    f.session()["myTeam"][0]["championId"] = json!(107);
    e.tick(&mut f, &prefs, &mut s, 400).unwrap();
    assert_eq!(s.swapped, 1);
    assert!(
        e.logs
            .iter()
            .any(|entry| entry.kind == "client" && entry.message.contains("；匹配自动抢取请求"))
    );
    assert!(e.logs.iter().any(|entry| entry.kind == "pick"
        && entry.level == "success"
        && entry.message.contains("已抢到")));
}
fn action(active: bool, completed: bool) -> Value {
    json!([[{"id":4,"actorCellId":0,"type":"pick","isInProgress":active,"completed":completed}]])
}
struct Fake {
    values: HashMap<String, Value>,
    fresh_values: HashMap<String, Value>,
    reads: Vec<(String, bool)>,
    writes: Vec<(String, String, Option<Value>)>,
    statuses: HashMap<String, u16>,
    before_write: Option<Box<dyn FnMut()>>,
}
impl Fake {
    fn new(current: i32) -> Self {
        Self {
            values: HashMap::from([
                (PHASE.into(), json!("ChampSelect")),
                (
                    GAME.into(),
                    json!({"phase":"ChampSelect","gameData":{"gameId":9,"queue":{"id":2400,"gameMode":"ARAM_MAYHEM"}}}),
                ),
                (
                    SESSION.into(),
                    json!({"gameId":9,"localPlayerCellId":0,"myTeam":[{"cellId":0,"championId":current}],"benchEnabled":false,"benchChampions":[],"actions":action(false, false),"timer":{"phase":"PLANNING","adjustedTimeLeftInPhase":30000}}),
                ),
                (PICKABLE.into(), json!([])),
                (SUBSET.into(), json!([])),
            ]),
            fresh_values: HashMap::new(),
            reads: vec![],
            writes: vec![],
            statuses: HashMap::new(),
            before_write: None,
        }
    }
    fn session(&mut self) -> &mut Value {
        self.values.get_mut(SESSION).unwrap()
    }
    fn bench(&mut self, ids: &[i32]) {
        self.session()["benchChampions"] = json!(
            ids.iter()
                .map(|id| json!({"championId":id,"isAvailable":false}))
                .collect::<Vec<_>>()
        );
    }
}
impl Api for Fake {
    fn get(&mut self, path: &str, fresh: bool) -> anyhow::Result<Response> {
        self.reads.push((path.into(), fresh));
        if fresh && let Some(value) = self.fresh_values.remove(path) {
            self.values.insert(path.into(), value);
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
        method: &str,
        path: &str,
        body: Option<Value>,
        _: u64,
    ) -> anyhow::Result<Option<Response>> {
        self.writes.push((method.into(), path.into(), body));
        if let Some(callback) = &mut self.before_write {
            callback();
        }
        Ok(Some(Response {
            status: self.statuses.get(path).copied().unwrap_or(204),
            data: Value::Null,
        }))
    }
    fn revision(&self) -> u64 {
        0
    }
    fn guard(&self, observed: &[(&str, &Value)]) -> Option<u64> {
        observed
            .iter()
            .all(|(path, value)| self.values.get(*path) == Some(*value))
            .then_some(0)
    }
}

#[test]
fn card_is_requested_during_planning_before_action_becomes_active() {
    let mut f = Fake::new(0);
    f.values.insert(PICKABLE.into(), json!([107]));
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    assert_eq!(
        f.writes,
        vec![(
            "PATCH".into(),
            format!("{SESSION}/actions/4"),
            Some(json!({"championId":107,"completed":true}))
        )]
    );
    assert_eq!(s.swapped, 0);
    f.session()["myTeam"][0]["championId"] = json!(107);
    e.tick(&mut f, &prefs, &mut s, 10).unwrap();
    assert_eq!(s.swapped, 1);
}

#[test]
fn stale_gameflow_cannot_hide_the_round_button_or_block_picks() {
    let mut f = Fake::new(22);
    f.bench(&[107]);
    f.fresh_values.insert(GAME.into(), f.values[GAME].clone());
    f.values.get_mut(GAME).unwrap()["phase"] = json!("Lobby");
    let control = Mutex::new(RoundPick::default());
    Engine::default()
        .tick_with_control(&mut f, &prefs, &mut Snapshot::default(), 0, &control)
        .unwrap();
    assert!(control.lock().unwrap().available);
    assert_eq!(f.writes.len(), 1);
}

#[test]
fn team_builder_session_restores_button_and_automation_when_public_session_is_unavailable() {
    const MODERN: &str = "/lol-lobby-team-builder/champ-select/v1/session";
    for incomplete in [false, true] {
        let mut f = Fake::new(22);
        f.bench(&[107]);
        let valid = f.values.remove(SESSION).unwrap();
        f.values.insert(MODERN.into(), valid);
        if incomplete {
            f.values
                .insert(SESSION.into(), json!({"gameId":9,"localPlayerCellId":-1}));
        }
        let control = Mutex::new(RoundPick::default());
        let mut engine = Engine::default();
        let mut snapshot = Snapshot::default();
        engine
            .tick_with_control(&mut f, &prefs, &mut snapshot, 0, &control)
            .unwrap();
        assert!(control.lock().unwrap().available);
        assert_eq!(f.writes.len(), 1);
        assert_eq!(f.writes[0].1, format!("{MODERN}/bench/swap/107"));
        f.values.get_mut(MODERN).unwrap()["myTeam"][0]["championId"] = json!(107);
        engine
            .tick_with_control(&mut f, &prefs, &mut snapshot, 250, &control)
            .unwrap();
        assert_eq!(snapshot.swapped, 1);
    }
}

#[test]
fn unsupported_subset_rest_does_not_erase_a_live_card_event() {
    let mut c = Cache::default();
    let event = Response {
        status: 200,
        data: json!([107]),
    };
    c.apply(SUBSET, event.clone());
    assert_eq!(
        c.reconcile(
            SUBSET,
            Response {
                status: 404,
                data: Value::Null
            },
            c.revision
        ),
        event
    );
    // A successful empty list is authoritative; old cards must not survive it.
    let empty = Response {
        status: 200,
        data: json!([]),
    };
    assert_eq!(c.reconcile(SUBSET, empty.clone(), c.revision), empty);
}

#[test]
fn write_guard_ignores_countdowns_and_profile_updates_but_rejects_changed_choices() {
    let mut f = Fake::new(22);
    f.bench(&[107]);
    let original = f.values[SESSION].clone();
    let phase = json!("ChampSelect");
    let mut c = Cache::default();
    c.apply(
        PHASE,
        Response {
            status: 200,
            data: phase.clone(),
        },
    );
    c.apply(
        SESSION,
        Response {
            status: 200,
            data: original.clone(),
        },
    );
    let mut ticking = original.clone();
    ticking["timer"]["adjustedTimeLeftInPhase"] = json!(29000);
    ticking["timer"]["phase"] = json!("FINALIZATION");
    c.apply(
        SESSION,
        Response {
            status: 200,
            data: ticking.clone(),
        },
    );
    let token = c
        .guard(&[(PHASE, &phase), (SESSION, &original)])
        .expect("countdown must not block submission");
    ticking["timer"]["adjustedTimeLeftInPhase"] = json!(28000);
    c.apply(
        SESSION,
        Response {
            status: 200,
            data: ticking.clone(),
        },
    );
    c.apply(
        PROFILE,
        Response {
            status: 200,
            data: json!({"profileIconId":5}),
        },
    );
    assert!(
        c.permits(token),
        "unrelated events between guard and write must not cancel the pick"
    );
    for change in ["ownership", "bench", "terminal", "game", "phase"] {
        c.apply(
            SESSION,
            Response {
                status: 200,
                data: original.clone(),
            },
        );
        let token = c.guard(&[(PHASE, &phase), (SESSION, &original)]).unwrap();
        let mut changed = original.clone();
        match change {
            "ownership" => changed["myTeam"][0]["championId"] = json!(107),
            "bench" => changed["benchChampions"] = json!([]),
            "terminal" => changed["timer"]["phase"] = json!("GAME_STARTING"),
            "game" => changed["gameId"] = json!(10),
            _ => c.apply(
                PHASE,
                Response {
                    status: 200,
                    data: json!("Lobby"),
                },
            ),
        }
        c.apply(
            SESSION,
            Response {
                status: 200,
                data: changed,
            },
        );
        assert!(!c.permits(token), "stale {change} must cancel the pick");
    }
}

#[test]
fn alternate_session_uses_its_own_action_and_does_not_bypass_pause_or_game_start() {
    const MODERN: &str = "/lol-lobby-team-builder/champ-select/v1/session";
    let mut f = Fake::new(0);
    let session = f.values.remove(SESSION).unwrap();
    f.values.insert(MODERN.into(), session.clone());
    f.values.insert(
        "/lol-lobby-team-builder/champ-select/v1/pickable-champion-ids".into(),
        json!([107]),
    );
    let control = Mutex::new(RoundPick::default());
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    let off = Preferences {
        auto_pick: false,
        ..prefs()
    };
    e.tick_with_control(&mut f, &|| off.clone(), &mut s, 0, &control)
        .unwrap();
    assert!(control.lock().unwrap().available);
    assert!(f.writes.is_empty());
    control.lock().unwrap().toggle(&off, false);
    e.tick_with_control(&mut f, &|| off.clone(), &mut s, 250, &control)
        .unwrap();
    assert_eq!(f.writes[0].1, format!("{MODERN}/actions/4"));
    let mut closed = session;
    closed["timer"]["phase"] = json!("GAME_STARTING");
    f.values.insert(SESSION.into(), closed);
    e.tick_with_control(&mut f, &prefs, &mut s, 500, &control)
        .unwrap();
    assert!(!control.lock().unwrap().available);
    assert_eq!(f.writes.len(), 1);
    // An incomplete spectator view is authoritative too; an older alternate
    // player session must never reopen automation for a spectator.
    f.values
        .insert(SESSION.into(), json!({"gameId":9,"isSpectating":true}));
    e.tick_with_control(&mut f, &prefs, &mut s, 750, &control)
        .unwrap();
    assert!(!control.lock().unwrap().available);
    assert_eq!(f.writes.len(), 1);
}

#[test]
fn personal_cards_work_without_pickable_response_or_shared_bench() {
    for current in [0, 22] {
        let mut f = Fake::new(current);
        f.values.remove(PICKABLE);
        f.values.insert(SUBSET.into(), json!([107, 103]));
        f.session()["allowSubsetChampionPicks"] = json!(true);
        f.session()["actions"] = action(false, current > 0);
        let mut e = Engine::default();
        e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
        let expected = if current == 0 {
            format!("{SESSION}/actions/4")
        } else {
            format!("{SESSION}/bench/swap/107")
        };
        assert_eq!(f.writes.len(), 1);
        assert_eq!(f.writes[0].1, expected);
    }
}

#[test]
fn bench_request_does_not_depend_on_pickable_endpoint_or_ui_enable_flags() {
    let mut f = Fake::new(22);
    f.bench(&[107]);
    f.values.remove(PICKABLE);
    f.values.remove(SUBSET);
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert_eq!(f.writes.len(), 1);
    assert_eq!(f.writes[0].1, format!("{SESSION}/bench/swap/107"));
}

#[test]
fn initial_pick_can_try_a_bench_candidate_before_pickable_list_arrives() {
    let mut f = Fake::new(0);
    f.bench(&[107]);
    f.values.remove(PICKABLE);
    f.values.remove(SUBSET);
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert_eq!(f.writes.len(), 1);
    assert_eq!(f.writes[0].1, format!("{SESSION}/actions/4"));
}

#[test]
fn cached_ticks_cannot_postpone_pending_confirmation_forever_after_switch_off() {
    let mut f = Fake::new(22);
    f.bench(&[107]);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    let p = Preferences {
        auto_pick: false,
        ..prefs()
    };
    e.tick(&mut f, &|| p.clone(), &mut s, 1).unwrap();
    assert!(!e.pending_due(250));
    for now in [50, 100, 200] {
        e.tick(&mut f, &|| p.clone(), &mut s, now).unwrap();
    }
    assert!(e.pending_due(251));
    let mut confirmed = f.values[SESSION].clone();
    confirmed["myTeam"][0]["championId"] = json!(107);
    f.fresh_values.insert(SESSION.into(), confirmed);
    e.tick(&mut f, &|| p.clone(), &mut s, 250).unwrap();
    assert_eq!(s.swapped, 1);
    assert_eq!(f.writes.len(), 1);
}

#[test]
fn round_switch_pauses_and_resumes_without_modifying_saved_preferences() {
    let control = Mutex::new(RoundPick::default());
    let mut f = Fake::new(22);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    let saved = prefs();
    e.tick_with_control(&mut f, &|| saved.clone(), &mut s, 0, &control)
        .unwrap();
    assert!(control.lock().unwrap().available);
    assert_eq!(control.lock().unwrap().toggle(&saved, false), Some(false));
    f.bench(&[107]);
    e.tick_with_control(&mut f, &|| saved.clone(), &mut s, 1, &control)
        .unwrap();
    assert!(f.writes.is_empty());
    assert_eq!(control.lock().unwrap().toggle(&saved, false), Some(true));
    e.tick_with_control(&mut f, &|| saved.clone(), &mut s, 2, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 1);
    assert_eq!(saved, prefs());
}

#[test]
fn local_enable_overrides_saved_off_and_one_shot_only_until_next_round() {
    let control = Mutex::new(RoundPick::default());
    let p = Preferences {
        auto_pick: false,
        always_prioritize: false,
        ..prefs()
    };
    let mut f = Fake::new(22);
    f.bench(&[103]);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 0, &control)
        .unwrap();
    assert!(f.writes.is_empty());
    control.lock().unwrap().toggle(&p, false);
    e.completed = true; // Explicitly resume an already completed one-shot round.
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 1, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 1);
    f.session()["myTeam"][0]["championId"] = json!(103);
    f.bench(&[107]);
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 2, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 2);
    f.values.get_mut(GAME).unwrap()["gameData"]["gameId"] = json!(10);
    f.session()["gameId"] = json!(10);
    f.session()["myTeam"][0]["championId"] = json!(22);
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 3, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 2);
    assert_eq!(control.lock().unwrap().override_pick, None);
    assert!(!p.auto_pick);
    assert!(!p.always_prioritize);
}

#[test]
fn round_pause_survives_disconnect_but_not_a_verified_phase_exit() {
    let control = Mutex::new(RoundPick::default());
    let mut f = Fake::new(22);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick_with_control(&mut f, &prefs, &mut s, 0, &control)
        .unwrap();
    control.lock().unwrap().toggle(&prefs(), false);
    f.values.remove(PHASE);
    assert!(
        e.tick_with_control(&mut f, &prefs, &mut s, 1, &control)
            .is_err()
    );
    assert!(!control.lock().unwrap().available);
    assert_eq!(control.lock().unwrap().override_pick, Some(false));
    e.disconnected(&s);
    f.values.insert(PHASE.into(), json!("ChampSelect"));
    f.bench(&[107]);
    e.tick_with_control(&mut f, &prefs, &mut s, 2, &control)
        .unwrap();
    assert!(f.writes.is_empty());
    assert!(control.lock().unwrap().available);
    f.values.insert(PHASE.into(), json!("Lobby"));
    e.tick_with_control(&mut f, &prefs, &mut s, 3, &control)
        .unwrap();
    assert_eq!(*control.lock().unwrap(), RoundPick::default());
    f.values.insert(PHASE.into(), json!("ChampSelect"));
    e.tick_with_control(&mut f, &prefs, &mut s, 4, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 1);
}

#[test]
fn control_lifetime_uses_terminal_phase_not_countdown_or_pick_completion() {
    let control = Mutex::new(RoundPick::default());
    let p = Preferences {
        auto_pick: false,
        ..prefs()
    };
    let mut f = Fake::new(22);
    f.session()["timer"] = json!({"phase":"FINALIZATION", "adjustedTimeLeftInPhase":0});
    f.session()["actions"] = action(false, true);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 0, &control)
        .unwrap();
    assert!(control.lock().unwrap().available);
    let mut terminal = f.values[SESSION].clone();
    terminal["timer"]["phase"] = json!("GAME_STARTING");
    f.fresh_values.insert(SESSION.into(), terminal);
    e.tick_with_control(&mut f, &|| p.clone(), &mut s, 250, &control)
        .unwrap();
    assert!(!control.lock().unwrap().available);
    assert_eq!(control.lock().unwrap().toggle(&p, false), None);
    f.bench(&[107]);
    e.tick_with_control(&mut f, &prefs, &mut s, 251, &control)
        .unwrap();
    assert!(f.writes.is_empty());
}

#[test]
fn round_pause_during_a_response_cancels_further_requests() {
    let control = Arc::new(Mutex::new(RoundPick::default()));
    let mut f = Fake::new(22);
    f.bench(&[107, 103]);
    f.statuses.insert(format!("{SESSION}/bench/swap/107"), 409);
    let changed = control.clone();
    f.before_write = Some(Box::new(move || {
        changed.lock().unwrap().toggle(&prefs(), false);
    }));
    let mut e = Engine::default();
    e.tick_with_control(&mut f, &prefs, &mut Snapshot::default(), 0, &control)
        .unwrap();
    assert_eq!(f.writes.len(), 1);
    assert_eq!(control.lock().unwrap().override_pick, Some(false));
}

#[test]
fn spectator_and_unsupported_modes_never_offer_a_round_control() {
    for spectator in [true, false] {
        let control = Mutex::new(RoundPick::default());
        let mut f = Fake::new(22);
        if spectator {
            f.session()["isSpectating"] = json!(true);
        } else {
            f.values.get_mut(GAME).unwrap()["gameData"]["queue"] =
                json!({"id":420,"gameMode":"CLASSIC"});
        }
        let mut e = Engine::default();
        e.tick_with_control(&mut f, &prefs, &mut Snapshot::default(), 0, &control)
            .unwrap();
        assert!(!control.lock().unwrap().available);
    }
}

#[test]
fn rejected_top_choice_falls_through_then_retries_without_ui_delay() {
    let mut f = Fake::new(22);
    f.bench(&[107, 103]);
    f.statuses.insert(format!("{SESSION}/bench/swap/107"), 409);
    f.statuses.insert(format!("{SESSION}/actions/4"), 409);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    assert_eq!(
        f.writes.iter().map(|w| w.1.as_str()).collect::<Vec<_>>(),
        [
            format!("{SESSION}/bench/swap/107"),
            format!("{SESSION}/actions/4"),
            format!("{SESSION}/bench/swap/103")
        ]
    );
    assert_eq!(s.swapped, 0);
    e.tick(&mut f, &prefs, &mut s, 249).unwrap();
    assert_eq!(f.writes.len(), 3);
    f.statuses.clear();
    e.tick(&mut f, &prefs, &mut s, 250).unwrap();
    assert_eq!(f.writes.len(), 4);
    assert_eq!(f.writes[3].1, format!("{SESSION}/bench/swap/107"));
}

#[test]
fn rejected_swap_can_use_the_own_pick_action_for_the_same_candidate() {
    let mut f = Fake::new(22);
    f.bench(&[107]);
    f.values.insert(PICKABLE.into(), json!([107]));
    f.statuses.insert(format!("{SESSION}/bench/swap/107"), 400);
    let mut e = Engine::default();
    e.tick(&mut f, &prefs, &mut Snapshot::default(), 0).unwrap();
    assert_eq!(f.writes.len(), 2);
    assert_eq!(f.writes[0].0, "POST");
    assert_eq!(f.writes[1].0, "PATCH");
    assert_eq!(
        f.writes[1].2,
        Some(json!({"championId":107,"completed":true}))
    );
}

#[test]
fn pending_lower_choice_does_not_block_a_new_better_candidate() {
    let mut f = Fake::new(22);
    f.bench(&[103]);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    assert!(e.pending_due(1));
    f.bench(&[107, 103]);
    e.tick(&mut f, &prefs, &mut s, 1).unwrap();
    assert_eq!(f.writes.len(), 2);
    assert_eq!(f.writes[1].1, format!("{SESSION}/bench/swap/107"));
    e.tick(&mut f, &prefs, &mut s, 2).unwrap();
    assert_eq!(f.writes.len(), 2);
    assert_eq!(s.swapped, 0);
    f.session()["myTeam"][0]["championId"] = json!(107);
    e.tick(&mut f, &prefs, &mut s, 10).unwrap();
    assert_eq!(s.swapped, 1);
    e.tick(&mut f, &prefs, &mut s, 20).unwrap();
    assert_eq!(s.swapped, 1);
}

#[test]
fn disabled_auto_pick_cancels_fallbacks_immediately() {
    let mut f = Fake::new(22);
    f.bench(&[107, 103]);
    f.statuses.insert(format!("{SESSION}/bench/swap/107"), 409);
    // Re-read the preference after the response, before trying the next option.
    let shared = std::rc::Rc::new(RefCell::new(prefs()));
    let changed = shared.clone();
    f.before_write = Some(Box::new(move || changed.borrow_mut().auto_pick = false));
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &|| shared.borrow().clone(), &mut s, 0)
        .unwrap();
    e.tick(&mut f, &|| shared.borrow().clone(), &mut s, 1000)
        .unwrap();
    assert_eq!(f.writes.len(), 1);
}

#[test]
fn server_rate_limit_stops_the_batch_and_retries_after_one_second() {
    let mut f = Fake::new(22);
    f.bench(&[107, 103]);
    f.statuses.insert(format!("{SESSION}/bench/swap/107"), 429);
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    e.tick(&mut f, &prefs, &mut s, 999).unwrap();
    assert_eq!(f.writes.len(), 1);
    f.statuses.clear();
    e.tick(&mut f, &prefs, &mut s, 1000).unwrap();
    assert_eq!(f.writes.len(), 2);
}

#[test]
fn rest_reconciliation_recovers_a_card_list_when_events_are_missing() {
    let mut f = Fake::new(0);
    f.values.remove(SUBSET); // Startup 404 may otherwise be cached forever.
    let mut e = Engine::default();
    let mut s = Snapshot::default();
    e.tick(&mut f, &prefs, &mut s, 0).unwrap();
    f.fresh_values.insert(SUBSET.into(), json!([107]));
    e.tick(&mut f, &prefs, &mut s, 249).unwrap();
    assert!(f.writes.is_empty());
    e.tick(&mut f, &prefs, &mut s, 250).unwrap();
    assert_eq!(f.writes.len(), 1);
    assert!(f.reads.contains(&(SESSION.into(), true)));
    assert!(f.reads.contains(&(SUBSET.into(), true)));
}

#[test]
fn unrelated_events_do_not_discard_card_lists_but_newer_lists_and_phase_changes_do() {
    let mut c = Cache::default();
    c.apply(
        PHASE,
        Response {
            status: 200,
            data: json!("ChampSelect"),
        },
    );
    let before = c.revision;
    c.apply(
        PROFILE,
        Response {
            status: 200,
            data: json!({"profileIconId":1}),
        },
    );
    c.apply(
        SESSION,
        Response {
            status: 200,
            data: json!({"timer":{"adjustedTimeLeftInPhase":10000}}),
        },
    );
    let incoming = Response {
        status: 200,
        data: json!([107]),
    };
    assert_eq!(c.reconcile(SUBSET, incoming.clone(), before), incoming);
    let before = c.revision;
    let newer = Response {
        status: 200,
        data: json!([103]),
    };
    c.apply(SUBSET, newer.clone());
    assert_eq!(c.reconcile(SUBSET, incoming.clone(), before), newer);
    let before = c.revision;
    c.apply(
        PHASE,
        Response {
            status: 200,
            data: json!("Lobby"),
        },
    );
    assert_eq!(c.reconcile(SUBSET, incoming, before).status, 409);
}
