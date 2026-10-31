//! Run with scripts/test-transport.py: local TLS/WAMP servers, no League access.
use catengar::{
    auth::Credentials,
    transport::{Api, Client, PHASE},
};
use std::{
    sync::atomic::Ordering,
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
    let observed = serde_json::json!("ChampSelect");
    assert!(first.guard(&[(PHASE, &observed)]).is_none());
    assert_eq!(second.get(PHASE, true).unwrap().data, "Lobby");
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
