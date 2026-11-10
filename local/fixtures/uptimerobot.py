"""Local UptimeRobot API response; never contacts the monitored URL."""

import json
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200 if self.path == "/healthz" else 404)
        self.end_headers()

    def do_POST(self):
        url = urlparse(self.path)
        self.rfile.read(int(self.headers.get("Content-Length", 0)))
        if url.path != "/v2/getMonitors":
            self.send_error(404)
            return
        if parse_qs(url.query).get("api_key") != ["local-uptimerobot"]:
            self.send_error(403)
            return
        # Read on every request so local checks can simulate an outage by
        # updating the fixture ConfigMap, without restarting the server.
        monitor = json.loads(Path("/fixtures/monitor.json").read_text())
        payload = json.dumps({
            "stat": "ok",
            "pagination": {"offset": 0, "limit": 50, "total": 1},
            "monitors": [monitor],
        }).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *_args):
        pass  # The request URL contains the API key.


ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
