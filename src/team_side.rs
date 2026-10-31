//! Early champion-select data arrives before the legacy session exposes a team.
use serde_json::{Value, json};

/// Normalize only the local player's side and room, never player identities or JWTs.
/// The messaging endpoint returns an envelope with a JSON-encoded payload.
pub fn early_selection(message: &Value, game_id: i64) -> Option<Value> {
    if game_id <= 0 {
        return None;
    }
    if let Some(messages) = message.as_array() {
        let mut selected = None;
        for candidate in messages.iter().filter_map(|m| early_selection(m, game_id)) {
            if selected.as_ref().is_some_and(|s| s != &candidate) {
                return None;
            }
            selected = Some(candidate);
        }
        return selected;
    }
    let payload = &message["payload"];
    let decoded;
    let payload = if let Some(encoded) = payload.as_str() {
        decoded = serde_json::from_str::<Value>(encoded).ok()?;
        &decoded
    } else {
        payload
    };
    if payload["phaseName"] != "CHAMPION_SELECT" || payload["gameId"].as_i64() != Some(game_id) {
        return None;
    }
    let selection = &payload["championSelectState"];
    if selection["isSpectating"] == true {
        return None;
    }
    let local = selection["localPlayerCellId"]
        .as_i64()
        .filter(|id| *id >= 0)?;
    let team = selection["cells"]["alliedTeam"]
        .as_array()?
        .iter()
        .find(|player| player["cellId"].as_i64() == Some(local))?["teamId"]
        .as_i64()
        .filter(|team| matches!(team, 1 | 2))?;
    let room = selection["teamChatRoomId"]
        .as_str()
        .filter(|room| !room.is_empty() && room.len() <= 256)?;
    Some(json!({
        "gameId": game_id,
        "localPlayerCellId": local,
        "myTeam": [{"cellId": local, "team": team}],
        "chatDetails": {"multiUserChatId": room}
    }))
}
