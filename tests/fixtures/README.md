# Early team-side fixtures

The two `team-side-early-*.json` files preserve the relevant structure of
League Client team-builder events observed on 2026-10-31 in queue 2400 (KIWI).
They capture the initial `CHAMPION_SELECT` / `BAN_PICK` state, when champions
are still unset but the local ally's `teamId` and `teamChatRoomId` are available.
The envelope's `payload` is a JSON string, as in the recorded event.

Only whitelisted phase, queue, slot, team and champion fields are retained.
Game IDs and room IDs are replaced with fixture constants. Player identities,
message identifiers, timestamps, chat content and authentication data are omitted.

The regression holds the legacy selection empty, stale or without a known team
while replaying this early event. The TLS/WAMP fixture also exercises a message
arriving before the phase event and a missing REST snapshot.
