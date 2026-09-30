"""Protocol fixture for test_harbor_rest_native.nim.

This is a controlled Harbor HTTP peer, not a mocked HTTP transport. It lets the
test split SSE frames across TCP/chunk boundaries and block the terminal event
until Nim acknowledges the first callback. A real paid model cannot reproduce
these transport conditions deterministically. Production compatibility is also
checked separately against the locally built Harbor server.
"""
import http.server
import json
import pathlib
import sys
import time

root = pathlib.Path(sys.argv[1])


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        with (root / "http.log").open("a") as log:
            log.write((fmt % args) + "\n")

    def json(self, value):
        data = json.dumps(value).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or "{}")
        if self.path == "/api/v1/tasks":
            assert body["prompt"] == "first"
            assert "url" not in body["repo"]
            assert body["agents"][0]["type"] == "claude"
            self.json({"taskId": "task", "sessionIds": ["session"]})
        elif self.path.endswith("/prompt"):
            if body["prompt"] == "reject":
                self.json({"accepted": False, "stopReason": "delivery_uncertain"})
                return
            assert body["prompt"] == "second", body
            self.json({"sessionId": "session", "accepted": True})
        elif self.path.endswith("/stop"):
            (root / "stopped").touch()
            self.json({})
        else:
            self.send_error(404)

    def do_GET(self):
        if self.path.startswith("/api/v1/sessions/session/events/history"):
            self.json({"events": [], "total_count": 3})
            return
        assert self.path == "/api/v1/sessions/session/events"
        cursor = self.headers.get("Last-Event-ID", "0")
        assert cursor in ("0", "3"), cursor
        second = cursor == "3"
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(data):
            raw = data.encode()
            self.wfile.write(f"{len(raw):x}\r\n".encode() + raw + b"\r\n")
            self.wfile.flush()

        event_id = 4 if second else 1
        message = "second" if second else "first"
        # Split both the SSE field name and the JSON payload over chunks.
        chunk(f"id: {event_id}\r\nda")
        chunk('ta: {"type":"log",\r\ndata: "message":"')
        chunk(message + '"}\r\n\r\n')
        deadline = time.monotonic() + 5
        while not (root / message).exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        assert (root / message).exists(), "callback was buffered until EOF"
        chunk(f'id: {event_id + 1}\ndata: {{"type":"turn_complete","stop_reason":"end_turn"}}\n\n')
        try:
            self.wfile.write(b"0\r\n\r\n")
        except BrokenPipeError:
            pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_port, flush=True)
server.serve_forever()
