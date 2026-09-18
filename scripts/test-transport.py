"""Offline TLS/WAMP fault fixtures; uses Python's standard library only.

Usage: python scripts/test-transport.py [path/to/zig.exe]
Never reads League credentials or starts the GUI. All ports are OS-assigned.
"""
import base64
import hashlib
import http.server
import json
import pathlib
import socket
import ssl
import subprocess
import sys
import threading

ROOT = pathlib.Path(__file__).resolve().parent.parent


class Fixture(http.server.ThreadingHTTPServer):
    daemon_threads = True

    def __init__(self):
        super().__init__(("127.0.0.1", 0), Handler)
        self.token = "fixture-one"
        self.streams = []
        self.lock = threading.Lock()
        self.writes = 0
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain(ROOT / "scripts/fixtures/loopback.pem")
        self.socket = context.wrap_socket(self.socket, server_side=True)


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def handle(self):
        try:
            super().handle()
        except (ConnectionResetError, BrokenPipeError):
            # The test deliberately cancels WinHTTP handles with pending reads.
            pass

    def log_message(self, *_):
        pass

    def reply(self, status, value):
        body = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        self.server.writes += 1
        self.reply(500, None)

    def do_GET(self):
        expected = "Basic " + base64.b64encode(("riot:" + self.server.token).encode()).decode()
        if self.headers.get("Authorization") != expected:
            self.reply(401, None)
            return
        if self.path == "/" and self.headers.get("Upgrade", "").lower() == "websocket":
            digest = hashlib.sha1((self.headers["Sec-WebSocket-Key"] + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()
            self.send_response(101)
            self.send_header("Upgrade", "websocket")
            self.send_header("Connection", "Upgrade")
            self.send_header("Sec-WebSocket-Accept", base64.b64encode(digest).decode())
            self.end_headers()
            with self.server.lock:
                self.server.streams.append(self.connection)
            try:
                # Read all five subscription frames before sending a phase event.
                for _ in range(5):
                    first = self.rfile.read(2)
                    if len(first) != 2:
                        return
                    length = first[1] & 127
                    if length == 126:
                        length = int.from_bytes(self.rfile.read(2), "big")
                    mask = self.rfile.read(4)
                    data = self.rfile.read(length)
                    message = json.loads(bytes(v ^ mask[i % 4] for i, v in enumerate(data)))
                    if message[0] != 5:
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
        if self.path == "/fixture/drop":
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
            self.reply(200, "Lobby")
        else:
            self.reply(404, None)


def main():
    zig = sys.argv[1] if len(sys.argv) > 1 else ROOT / ".tools/zig-x86_64-windows-0.16.0/zig.exe"
    servers = [Fixture(), Fixture()]
    for server in servers:
        threading.Thread(target=server.serve_forever, daemon=True).start()
    try:
        result = subprocess.run([str(zig), "build", "test-transport", "--summary", "all", "--",
                                 *(str(server.server_port) for server in servers)], cwd=ROOT, timeout=180)
        if any(server.writes for server in servers):
            raise AssertionError("expired credentials must block writes")
        return result.returncode
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()


if __name__ == "__main__":
    sys.exit(main())
