#!/usr/bin/env python3
"""Minimal CGI test harness for rxpip_server.rexx.

Why not `python -m http.server --cgi`? It only forwards a small header
whitelist (no X-Rxpip-*), and when started as root it drops to `nobody`,
which silently breaks writes. Apache/mod_cgi forwards every request header
as HTTP_* and runs the script as the web user, so this harness does the
same: it runs the script as the current user and forwards all headers.

Usage:  cgi_harness.py --port 8089 --script server/rxpip_server.rexx \
                        --repo /path/to/repo [--interp regina]
"""
import argparse
import os
import subprocess
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlsplit


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    script = None
    repo = None
    interp = "regina"

    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def _run(self):
        parts = urlsplit(self.path)
        if not parts.path.endswith("/rxpip_server.rexx"):
            self.send_error(404)
            return
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        env = {k: v for k, v in os.environ.items() if k in ("PATH", "HOME", "TMPDIR")}
        env.update({
            "REQUEST_METHOD": self.command,
            "QUERY_STRING": parts.query,
            "CONTENT_LENGTH": str(length) if length else "",
            "SCRIPT_NAME": parts.path,
            "RXPIP_REPO_ROOT": self.repo,
            "GATEWAY_INTERFACE": "CGI/1.1",
        })
        for k, v in os.environ.items():
            if k.startswith("RXPIP_"):
                env[k] = v
        env["RXPIP_REPO_ROOT"] = self.repo
        for k, v in self.headers.items():
            env["HTTP_" + k.upper().replace("-", "_")] = v
        proc = subprocess.run([self.interp, self.script], input=body,
                              env=env, capture_output=True)
        out = proc.stdout
        sep = out.find(b"\n\n")
        sep_len = 2
        crlf = out.find(b"\r\n\r\n")
        if crlf != -1 and (sep == -1 or crlf < sep):
            sep, sep_len = crlf, 4
        if sep == -1:
            self.send_response(500)
            payload = b"CGI script produced no headers\n" + proc.stderr
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        head, payload = out[:sep], out[sep + sep_len:]
        status = 200
        headers = []
        for line in head.decode("latin-1").splitlines():
            if ":" not in line:
                continue
            k, v = line.split(":", 1)
            if k.strip().lower() == "status":
                status = int(v.strip().split()[0])
            else:
                headers.append((k.strip(), v.strip()))
        self.send_response(status)
        have_len = False
        for k, v in headers:
            if k.lower() == "content-length":
                have_len = True
            self.send_header(k, v)
        if not have_len:
            self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    do_GET = _run
    do_POST = _run


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=8089)
    ap.add_argument("--script", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--interp", default="regina")
    a = ap.parse_args()
    Handler.script = os.path.abspath(a.script)
    Handler.repo = os.path.abspath(a.repo)
    Handler.interp = a.interp
    ThreadingHTTPServer(("127.0.0.1", a.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
