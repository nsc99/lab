#!/usr/bin/env python3
"""Local same-origin preview over SSH-forwarded Homepage and Anker ports."""
import http.client
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit

HOP_HEADERS = {"connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
               "te", "trailer", "transfer-encoding", "upgrade"}
ASSETS = Path(__file__).resolve().parent.parent / "cluster/apps/homepage"
LOCAL_ASSETS = {
    "/api/config/custom.css": ("custom.css", "text/css"),
    "/anki-study.html": ("anki-study.html", "text/html"),
    "/anki-study.css": ("anki-study.css", "text/css"),
    "/anki-study.mjs": ("anki-study.mjs", "application/javascript"),
}


class Proxy(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def proxy(self):
        pathname = urlsplit(self.path).path
        if self.command in {"GET", "HEAD"} and pathname in LOCAL_ASSETS:
            # Preview current worktree edits immediately, without a pod rollout.
            filename, content_type = LOCAL_ASSETS[pathname]
            data = (ASSETS / filename).read_bytes()
            self.send_response(200)
            self.send_header("Content-Type", content_type + "; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            if self.command != "HEAD":
                self.wfile.write(data)
            return
        activity = pathname == "/anki/activity"
        port = 3081 if activity else 3001
        path = self.path.removeprefix("/anki") if activity else self.path
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        headers = {key: value for key, value in self.headers.items()
                   if key.lower() not in HOP_HEADERS}
        headers["Host"] = "localhost:3000"
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=15)
        try:
            connection.request(self.command, path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read()
        except (OSError, http.client.HTTPException):
            self.send_error(502, "Local preview backend is reconnecting")
            return
        finally:
            connection.close()
        self.send_response(response.status)
        for key, value in response.getheaders():
            if key.lower() not in HOP_HEADERS | {"content-length"}:
                self.send_header(key, value)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(data)

    do_GET = proxy
    do_HEAD = proxy
    do_POST = proxy


ThreadingHTTPServer(("127.0.0.1", 3000), Proxy).serve_forever()
