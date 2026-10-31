"""Offline TLS/WAMP fault fixtures; uses Python's standard library only.

Usage: python scripts/test-transport.py [path/to/cargo.exe]
Never reads League credentials or starts the GUI. All ports are OS-assigned.
"""
import base64
import hashlib
import http.server
import json
import os
import pathlib
import socket
import ssl
import subprocess
import sys
import threading
import time
import urllib.parse

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.token = "fixture-one"
        self.streams = []
        self.lock = threading.Lock()
        self.writes = 0
        self.early_side = False
        self.selection = False
        self.selected_champion = 22
        self.countdown = 30000
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(ROOT / "scripts/fixtures/loopback.pem")
        self.socket = context.wrap_socket(self.socket, server_side=True)

    def selection_session(self):
        return {"gameId": 9, "localPlayerCellId": 0,
                "myTeam": [{"cellId": 0, "championId": self.selected_champion}],
                "benchChampions": [{"championId": 107}], "actions": [],
                "timer": {"phase": "PLANNING", "adjustedTimeLeftInPhase": self.countdown}}

    def event(self, path, data):
        message = json.dumps([8, "OnJsonApiEvent", {"uri": path, "eventType": "Update", "data": data}]).encode()
        frame = bytes([0x81, 126]) + len(message).to_bytes(2, "big") + message
        with self.lock:
            for stream in self.streams:
                stream.sendall(frame)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        self.request_count = 0
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            # The test deliberately cancels sockets with pending reads.
            pass

    def log_message(self, *_):
        pass

    def reply(self, status, value):
        body = b"" if status == 204 else json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.writes += 1
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw) if raw else None
        if self.server.selection and self.path == "/lol-lobby-team-builder/champ-select/v1/session/bench/swap/107":
            self.server.selected_champion = 107
            self.reply(204, None)
        elif (self.server.early_side
                and urllib.parse.unquote(self.path) == "/lol-chat/v1/conversations/fixture-room@lol-champ-select.pvp.net/messages"
                and body == {"body": "🟥 本局我方为红色方 - by (Catengar)", "type": "chat"}):
            self.reply(200, None)
        else:
            self.reply(500, None)

    def do_GET(self):
        self.request_count += 1
        expected = "Basic " + base64.b64encode(("riot:" + self.server.token).encode()).decode()
        if self.headers.get("Authorization") != expected:
            self.reply(401, None)
            return
        if self.path == "/" and self.headers.get("Upgrade", "").lower() == "websocket":
            # Model a server that routes a connection at its first request.
            # A WebSocket must not borrow a pooled ordinary REST connection.
            if self.request_count != 1:
                self.reply(400, None)
                return
            digest = hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            with self.server.lock:
                self.server.streams.append(self.connection)
            try:
                # One generic WAMP subscription covers all relevant LCU events.
                for _ in range(1):
                    first = self.rfile.read(2)
                    if len(first) != 2:
                        return
                    length = first[1] & 127
                    if length == 126:
                        length = int.from_bytes(self.rfile.read(2), "big")
                    mask = self.rfile.read(4)
                    data = self.rfile.read(length)
                    message = json.loads(bytes(v ^ mask[i % 4] for i, v in enumerate(data)))
                    if message != [5, "OnJsonApiEvent"]:
                        raise ValueError("expected WAMP subscription")
                message = json.dumps([8, "OnJsonApiEvent_lol-gameflow_v1_gameflow-phase", {
                    "uri": "/lol-gameflow/v1/gameflow-phase", "eventType": "Update", "data": "Lobby"
                }]).encode()
                frame = bytes([0x81, 126]) + len(message).to_bytes(2, "big") + message
                self.connection.sendall(frame)
                # Do not cooperate with close handshakes: cancellation must work.
                while self.connection.recv(4096):
                    pass
            except (OSError, ValueError):
                pass
            finally:
                with self.server.lock:
                    if self.connection in self.server.streams:
                        self.server.streams.remove(self.connection)
                self.close_connection = True
            return
        if self.path == "/fixture/selection":
            self.server.selection = True
            self.server.event("/lol-gameflow/v1/gameflow-phase", "ChampSelect")
            self.reply(200, None)
        elif self.path == "/lol-gameflow/v1/session" and (self.server.selection or self.server.early_side):
            self.reply(200, {"phase": "ChampSelect", "gameData": {"gameId": 9, "queue": {"id": 2400, "gameMode": "KIWI"}}})
        elif self.path == "/lol-lobby-team-builder/champ-select/v1/session" and self.server.selection:
            self.reply(200, self.server.selection_session())
        elif self.path == "/lol-lobby-team-builder/champ-select/v1/subset-champion-list" and self.server.selection:
            # Every optional REST read races with a countdown update. This used
            # to cancel every pick despite unchanged ownership and candidates.
            self.server.countdown -= 100
            self.server.event("/lol-lobby-team-builder/champ-select/v1/session", self.server.selection_session())
            time.sleep(0.1)
            self.reply(404, None)
        elif self.path == "/fixture/early-side":
            self.server.selection = False
            self.server.early_side = True
            payload = json.loads((ROOT / "tests/fixtures/team-side-early-red.json").read_text(encoding="utf-8"))
            # Preserve the actual ordering: server team data can arrive before phase.
            events = [
                ("/riot-messaging-service/v1/message/teambuilder/v1/tbdGameDtoV1", payload),
                ("/lol-gameflow/v1/gameflow-phase", "ChampSelect"),
                ("/lol-gameflow/v1/session", {"phase": "ChampSelect", "gameData": {"gameId": 9, "queue": {"id": 2400, "gameMode": "KIWI"}}}),
            ]
            with self.server.lock:
                for path, data in events:
                    message = json.dumps([8, "OnJsonApiEvent", {"uri": path, "eventType": "Update", "data": data}]).encode()
                    frame = bytes([0x81, 126]) + len(message).to_bytes(2, "big") + message
                    for stream in self.server.streams:
                        stream.sendall(frame)
            self.reply(200, None)
        elif self.path == "/fixture/lobby":
            self.server.early_side = False
            self.server.selection = False
            self.reply(200, None)
        elif self.path == "/lol-chat/v1/conversations" and self.server.early_side:
            self.reply(200, [{"id": "fixture-room@lol-champ-select.pvp.net", "type": "championSelect"}])
        elif self.path == "/fixture/subset":
            message = json.dumps([8, "OnJsonApiEvent", {
                "uri": "/lol-lobby-team-builder/champ-select/v1/subset-champion-list",
                "eventType": "Update", "data": [107, 103]
            }]).encode()
            frame = bytes([0x81, 126]) + len(message).to_bytes(2, "big") + message
            with self.server.lock:
                for stream in self.server.streams:
                    stream.sendall(frame)
            self.reply(200, None)
        elif self.path == "/fixture/chat":
            message = json.dumps([8, "OnJsonApiEvent", {
                "uri": "/lol-chat/v1/conversations/c1~fixture@server",
                "eventType": "Create", "data": {"type": "championSelect"}
            }]).encode()
            frame = bytes([0x81, 126]) + len(message).to_bytes(2, "big") + message
            with self.server.lock:
                for stream in self.server.streams:
                    stream.sendall(frame)
            self.reply(200, None)
        elif self.path == "/fixture/drop":
            with self.server.lock:
                streams = list(self.server.streams)
            for stream in streams:
                try:
                    stream.shutdown(socket.SHUT_RDWR)
                except OSError:
                    pass
            self.reply(200, None)
        elif self.path == "/fixture/rotate":
            self.server.token = "fixture-two"
            self.reply(200, None)
        elif self.path == "/lol-gameflow/v1/gameflow-phase":
            self.reply(200, "ChampSelect" if self.server.early_side or self.server.selection else "Lobby")
        else:
            self.reply(404, None)


def main():
    cargo = sys.argv[1] if len(sys.argv) > 1 else "cargo"
    servers = [Fixture(), Fixture()]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        environment = dict(os.environ, CATENGAR_TRANSPORT_PORTS=",".join(str(s.server_port) for s in servers))
        result = subprocess.run([str(cargo), "test", "--locked", "--test", "transport", "--", "--ignored"],
                                cwd=ROOT, env=environment, timeout=180)
        if [server.writes for server in servers] != [2, 0]:
            raise AssertionError("exactly one champion swap and one early team-side message are expected; expired credentials must block writes")
        return result.returncode
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    sys.exit(main())
