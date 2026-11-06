//! Run with scripts/test-transport.py: local TLS/WAMP servers, no League access.
use catengar::{
    auth::Credentials,
    engine::Engine,
    model::{Preferences, RoundPick, Snapshot},
    notifications::Notice,
    team_side::early_selection,
    transport::{Api, Client, GAME, PHASE, SUBSET, TEAMBUILDER},
};
use std::{
    sync::{Mutex, atomic::Ordering},
    thread,
    time::{Duration, Instant},
};

fn wait(mut check: impl FnMut() -> bool, seconds: u64) {
    let deadline = Instant::now() + Duration::from_secs(seconds);
    while !check() {
        assert!(Instant::now() < deadline, "fixture condition timed out");
        thread::sleep(Duration::from_millis(25));
    }
}
fn identity(port: u16, token: &str) -> Credentials {
    Credentials {
        port,
        pid: std::process::id(),
        token: token.into(),
    }
}
#[test]
#[ignore = "requires isolated Python TLS fixture; run scripts/test-transport.py"]
fn tls_events_reconnect_rotation_and_bounded_shutdown() {
    let ports: Vec<u16> = std::env::var("CATENGAR_TRANSPORT_PORTS")
        .expect("fixture ports")
        .split(',')
        .map(|p| p.parse().unwrap())
        .collect();
    assert_eq!(ports.len(), 2);
    let mut first = Client::new(identity(ports[0], "fixture-one")).unwrap();
    let mut second = Client::new(identity(ports[1], "fixture-one")).unwrap();
    assert_eq!(first.get(PHASE, true).unwrap().data, "Lobby");
    wait(
        || first.websocket.load(Ordering::Acquire) && second.websocket.load(Ordering::Acquire),
        8,
    );
    wait(|| first.revision() > 1, 5);
    while first.wake.try_recv().is_ok() {}
    let chat_revision = first.chat_revision();
    first.get("/fixture/chat", true).unwrap();
    wait(|| first.chat_revision() > chat_revision, 5);
    assert!(first.wake.recv_timeout(Duration::from_secs(1)).is_ok());
    let revision = first.revision();
    first.get("/fixture/subset", true).unwrap();
    wait(|| first.revision() > revision, 5);
    // This resource is 404 over REST in the fixture. Its live event must be
    // retained in the candidate cache and participate in the write guard.
    let cards = first.get(SUBSET, false).unwrap();
    assert_eq!(cards.data, serde_json::json!([107, 103]));
    assert!(first.guard(&[(SUBSET, &cards.data)]).is_some());
    let observed = serde_json::json!("ChampSelect");
    assert!(first.guard(&[(PHASE, &observed)]).is_none());
    first.get("/fixture/selection", true).unwrap();
    wait(|| first.get(PHASE, false).unwrap().data == "ChampSelect", 5);
    let control = Mutex::new(RoundPick::default());
    let mut picks = Engine::default();
    let mut picked = Snapshot::default();
    let enabled = || Preferences {
        auto_pick: true,
        priority: vec![107],
        ..Default::default()
    };
    picks
        .tick_with_control(&mut first, &enabled, &mut picked, 0, &control)
        .unwrap();
    assert!(
        control.lock().unwrap().available,
        "fallback session must make the button available"
    );
    assert_eq!(
        picked.swapped, 0,
        "HTTP success still requires ownership confirmation"
    );
    picks
        .tick_with_control(&mut first, &enabled, &mut picked, 250, &control)
        .unwrap();
    assert_eq!(
        picked.swapped, 1,
        "countdown events must not starve actual TLS writes"
    );
    let revision = first.revision();
    first.get("/fixture/early-side", true).unwrap();
    wait(|| first.revision() >= revision + 3, 5);
    let early = first.get(TEAMBUILDER, true).unwrap(); // REST 404 must not erase the live event
    assert!(early_selection(&early.data, 9).is_some());
    assert_eq!(
        first.get(GAME, false).unwrap().data["gameData"]["gameId"],
        9
    );
    let mut engine = Engine::default();
    let mut snapshot = Snapshot::default();
    engine
        .tick(&mut first, &Preferences::default, &mut snapshot, 0)
        .unwrap();
    assert_eq!(engine.notices, [Notice::TeamSide(2)]);
    assert!(
        engine
            .logs
            .iter()
            .any(|entry| entry.kind == "side" && entry.level == "success")
    );
    engine
        .tick(&mut first, &Preferences::default, &mut snapshot, 1000)
        .unwrap();
    first.get("/fixture/lobby", true).unwrap();
    assert_eq!(first.get(PHASE, true).unwrap().data, "Lobby");
    assert_eq!(second.get(PHASE, true).unwrap().data, "Lobby");
    // Replay consecutive selections on one live TLS/WAMP connection, with
    // gameflow a full round behind and only the alternate session available.
    let mut rounds = Engine::default();
    let mut selected = Snapshot::default();
    let one_shot = || Preferences {
        auto_pick: true,
        always_prioritize: false,
        priority: vec![107],
        ..Default::default()
    };
    for (round, side) in [1, 2, 1].into_iter().enumerate() {
        let now = round as u64 * 100_000;
        first.get("/fixture/next-round", true).unwrap();
        wait(|| first.get(PHASE, false).unwrap().data == "ChampSelect", 5);
        rounds
            .tick_with_control(&mut first, &one_shot, &mut selected, now, &control)
            .unwrap();
        assert!(control.lock().unwrap().available);
        assert_eq!(rounds.game_id, 10 + round as i64);
        assert_eq!(control.lock().unwrap().game_id, rounds.game_id);
        rounds
            .tick_with_control(&mut first, &one_shot, &mut selected, now + 250, &control)
            .unwrap();
        assert_eq!(selected.swapped, round as u64 + 1);
        assert!(rounds.completed);
        first.get("/fixture/catch-up", true).unwrap();
        rounds
            .tick_with_control(&mut first, &one_shot, &mut selected, now + 500, &control)
            .unwrap();
        assert_eq!(
            first.get("/fixture/writes", true).unwrap().data,
            4 + round * 2
        );
        let sides: Vec<_> = rounds
            .notices
            .iter()
            .filter(|n| matches!(n, Notice::TeamSide(_)))
            .collect();
        assert_eq!(sides.len(), round + 1);
        assert_eq!(sides.last(), Some(&&Notice::TeamSide(side)));
        assert_eq!(
            rounds
                .logs
                .iter()
                .filter(|entry| entry.kind == "side" && entry.level == "success")
                .count(),
            round + 1,
            "the server must accept exactly one message for this room"
        );
        first.get("/fixture/lobby", true).unwrap();
        assert_eq!(first.get(PHASE, true).unwrap().data, "Lobby");
        rounds
            .tick_with_control(&mut first, &one_shot, &mut selected, now + 750, &control)
            .unwrap();
        assert!(!control.lock().unwrap().available);
    }
    first.get("/fixture/drop", true).unwrap();
    wait(|| !first.websocket.load(Ordering::Acquire), 5);
    assert_eq!(first.get(PHASE, false).unwrap().data, "Lobby");
    wait(|| first.websocket.load(Ordering::Acquire), 15);
    first.get("/fixture/rotate", true).unwrap();
    assert!(first.get(PHASE, true).is_err());
    assert!(first.expired.load(Ordering::Acquire));
    assert!(
        first
            .write("POST", "/fixture/must-not-write", None, first.revision())
            .is_err()
    );
    assert_eq!(second.get(PHASE, true).unwrap().data, "Lobby");
    let start = Instant::now();
    drop(first);
    drop(second);
    assert!(start.elapsed() < Duration::from_secs(5));
    let mut rotated = Client::new(identity(ports[0], "fixture-two")).unwrap();
    assert_eq!(rotated.get(PHASE, true).unwrap().data, "Lobby");
    wait(|| rotated.websocket.load(Ordering::Acquire), 8);
    let start = Instant::now();
    drop(rotated);
    assert!(start.elapsed() < Duration::from_secs(4));
}
