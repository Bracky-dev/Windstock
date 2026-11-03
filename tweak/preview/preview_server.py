"""
The Research preview's little server: plain HTTP in front of research.py, so the Simulator
app can load real tasks, art and the game's font without TLS or the phone's DNS redirect.

    python3 preview_server.py            # serves trainer "bracky67" on 127.0.0.1:8799
    WS_USER=simtest python3 preview_server.py

Leave it running, then press Run in Xcode (ResearchPreview.xcodeproj).
"""
import json, os, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "..", "..", "server"))
import research as R

USER = os.environ.get("WS_USER", "bracky67")


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path.startswith("/research/art/") or path.startswith("/research/pokemon/") \
                or path.startswith("/research/font/"):
            st, hd, body = R.handle("GET", path, "", {}, b"", print, None)
            return self._send(st, hd.get("Content-Type", "application/octet-stream"), body)
        if path == "/research/events":
            return self._send(200, "application/json", json.dumps(R.events_view()).encode())
        if path == "/research/state":
            return self._send(200, "application/json", json.dumps(R.state(USER)).encode())
        if path == "/research/ping":
            n = R._notify.get(USER) or {"seq": 0, "count": 0}
            return self._send(200, "application/json",
                              json.dumps({"seq": n["seq"], "count": n["count"]}).encode())
        self._send(404, "text/plain", b"?")

    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        data = json.loads(self.rfile.read(n) or b"{}")
        if self.path.split("?")[0] == "/research/claim":
            return self._send(200, "application/json", json.dumps(R.claim(USER, data, print)).encode())
        self._send(404, "text/plain", b"?")


ThreadingHTTPServer(("127.0.0.1", 8799), H).serve_forever()
