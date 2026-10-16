"""Synthetic Anki sync service: never connects to a real account."""
from compression import zstd
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
import json
import sqlite3


def collection():
    db = sqlite3.connect(":memory:")
    db.executescript("""
        CREATE TABLE col (ver INTEGER, conf TEXT, crt INTEGER);
        INSERT INTO col VALUES (18, '', 0);
        CREATE TABLE config (key TEXT, val BLOB);
        INSERT INTO config VALUES ('rollover', X'34');
        CREATE TABLE revlog (id INTEGER PRIMARY KEY, ease INTEGER, type INTEGER, time INTEGER);
    """)
    # Noon UTC stays within the same Berlin study day even across DST.
    now = datetime.now(timezone.utc).replace(hour=12, minute=0, second=0, microsecond=0)
    for day in range(365):
        if day % 6 == 0:
            continue  # Includes today: exercise the zero-study warning.
        timestamp = int((now - timedelta(days=day)).timestamp() * 1000)
        for answer in range(1 + day % 80):
            db.execute("INSERT INTO revlog VALUES (?, 3, 1, 6000)", (timestamp + answer,))
    db.commit()
    result = db.serialize()
    db.close()
    return result


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        data = zstd.decompress(self.rfile.read(int(self.headers["Content-Length"])))
        method = self.path.removeprefix("/sync/")
        if method == "hostKey":
            if json.loads(data) != {"u": "demo", "p": "demo"}:
                self.send_error(403)
                return
            body = b'{"key":"demo-key"}'
        elif json.loads(self.headers["anki-sync"])["k"] != "demo-key":
            self.send_error(403)
            return
        elif method == "meta":
            body = b'{"cont":true}'
        elif method == "download":
            body = collection()
        else:
            self.send_error(404)
            return
        body = zstd.compress(body)
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


HTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
