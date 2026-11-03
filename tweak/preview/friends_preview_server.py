"""Fake /friends backend for FriendsPreview (plain HTTP on 127.0.0.1:8799), with the real art."""
import json, os, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

SRV = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "server")
NOW = int(time.time() * 1000)
LEVELS = ["Friend", "Good Friend", "Great Friend", "Ultra Friend", "Best Friend"]


def friend(i, name, lvl, team, days, nxt, online, ago_h, today=False):
    return {"id": i, "name": name, "level": lvl, "team": team, "online": online,
            "seen_ms": NOW - int(ago_h * 3600 * 1000), "since": NOW - days * 86400000 - 86400000 * 3,
            "days": days, "friendship": [0, 1, 7, 30, 90].index(max(x for x in [0, 1, 7, 30, 90] if x <= days)),
            "friendship_name": LEVELS[[0, 1, 7, 30, 90].index(max(x for x in [0, 1, 7, 30, 90] if x <= days))],
            "next_days": nxt, "today": today}


ROOM = {"trade": "t1", "state": "open", "friend": "bob", "friend_name": "AshKetchum99",
        "mine": {"uid": "2", "id": 25, "name": "Pikachu", "nickname": "Sparky", "cp": 512, "shiny": True},
        "theirs": {"uid": "9", "id": 143, "name": "Snorlax", "nickname": "", "cp": 1650, "shiny": False},
        "my_ok": False, "their_ok": True, "cost": 100, "problem": None, "why": None, "result": None,
        "chat": [{"me": False, "text": "Hi! I'll put up my Snorlax -- pick whatever you like!", "ms": NOW},
                 {"me": True, "text": "Would you take my shiny Pikachu?", "ms": NOW},
                 {"me": False, "text": "Sure, deal!", "ms": NOW}]}
STATE = {"me": {"name": "Bracky", "level": 27, "team": 1, "code": "482915730264"},
         "friends": [friend("bob", "AshKetchum99", 31, 2, 94, None, True, 0, True),
                     friend("misty", "MistyWaterflower", 24, 1, 12, 30, False, 3),
                     friend("brock", "RockSolidBrock", 19, 3, 3, 7, False, 26),
                     friend("gary", "GaryOak", 8, 0, 0, 1, False, 80)],
         "incoming": [{"id": "jess", "name": "Jessie", "level": 15, "team": 2, "online": False,
                       "seen_ms": NOW, "sent": NOW}],
         "outgoing": [{"id": "james", "name": "James", "level": 14, "team": 3, "online": False,
                       "seen_ms": NOW, "sent": NOW}],
         "max": 200, "levels": LEVELS}


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
        p = self.path.split("?")[0]
        for pre, d in (("/research/art/", "research_art"), ("/research/font/", "research_art/fonts"),
                       ("/friends/art/", "friends_art")):
            if p.startswith(pre):
                f = os.path.join(SRV, d, os.path.basename(p))
                if os.path.exists(f):
                    return self._send(200, "application/octet-stream", open(f, "rb").read())
                return self._send(404, "text/plain", b"?")
        if p == "/friends/state":
            return self._send(200, "application/json", json.dumps(STATE).encode())
        if p == "/friends/trade":
            return self._send(200, "application/json", json.dumps(ROOM).encode())
        if p == "/friends/box":
            return self._send(200, "application/json", json.dumps({"ok": True, "stardust": 48210, "trades_today": 1,
                "daily_limit": 10, "pokemon": [
                    {"uid": "1", "id": 16, "name": "Pidgey", "nickname": "", "cp": 150, "shiny": False, "blocked": None},
                    {"uid": "2", "id": 25, "name": "Pikachu", "nickname": "Sparky", "cp": 512, "shiny": True, "blocked": None},
                    {"uid": "3", "id": 6, "name": "Charizard", "nickname": "", "cp": 2210, "shiny": False,
                     "blocked": "it's a favourite (unfavourite it in the game first)"}]}).encode())
        if p == "/research/ping":
            return self._send(200, "application/json", b'{"seq":0,"count":0,"friend_requests":1}')
        self._send(404, "text/plain", b"?")

    def do_POST(self):
        self.rfile.read(int(self.headers.get("Content-Length") or 0))
        if self.path.startswith("/friends/trade"):
            return self._send(200, "application/json", json.dumps(ROOM).encode())
        out = dict(STATE, message="Friend request sent to Jessie.")
        self._send(200, "application/json", json.dumps(out).encode())


ThreadingHTTPServer(("127.0.0.1", 8799), H).serve_forever()
