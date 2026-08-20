#!/usr/bin/env python3
"""Serve files với CORS + PNA headers để trang Play Console (https) có thể fetch.

Usage: local_serve.py [root_dir] [port]
"""
import http.server
import sys

ROOT = sys.argv[1] if len(sys.argv) > 1 else "."
PORT = int(sys.argv[2]) if len(sys.argv) > 2 else 8899


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=ROOT, **kw)

    def end_headers(self):
        self.send_header("Access-Control-Allow-Origin", self.headers.get("Origin", "*"))
        self.send_header("Access-Control-Allow-Private-Network", "true")
        self.send_header("Access-Control-Allow-Methods", "GET, OPTIONS")
        self.send_header("Access-Control-Allow-Headers", "*")
        super().end_headers()

    def do_OPTIONS(self):
        self.send_response(204)
        self.end_headers()

    def log_message(self, fmt, *args):
        print("[srv]", fmt % args, flush=True)


http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
