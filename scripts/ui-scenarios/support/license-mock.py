#!/usr/bin/env python3
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# Copyright 2026 Riera Technologies Ltd
"""license-mock.py - local stand-in for the Lemon Squeezy License API (UIT-1).

Started by scripts/ui-check.sh for scenarios that declare "requires": {"licenseMock": true};
the harness exports CASTELLUM_LICENSE_ENDPOINT=http://127.0.0.1:<port>/v1/licenses to the
app launch (honoured by Debug builds only). Never talks to the network beyond 127.0.0.1.

Usage: license-mock.py --port-file FILE [--max-seconds N] [--log FILE]
  Binds 127.0.0.1 on a free port, writes the port to FILE, serves until killed (or N s).
Behaviour: POST /v1/licenses/{activate,validate,deactivate}, form-encoded like the real API.
  Any key activates (an instance is created); validate / deactivate need a known instance id,
  else 404. Keys are never logged or echoed: the log has the action and instance id only.
  Fixture ids: store 11, product 22 (the Debug build has no pin). 3 activations per key.
"""
import argparse, json, sys, threading, time, uuid
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import parse_qs

LIMIT = 3
INSTANCES = {}  # instance id -> key (memory only)
META = {"store_id": 11, "order_id": 5, "product_id": 22, "product_name": "Castellum"}


def key_obj(key):
    usage = sum(1 for k in INSTANCES.values() if k == key)
    return {"id": 1, "status": "active" if usage else "inactive", "activation_limit": LIMIT,
            "activation_usage": usage, "created_at": "2026-10-12T09:00:00.000000Z",
            "expires_at": "2027-10-12T09:00:00.000000Z"}


class Handler(BaseHTTPRequestHandler):
    log_file = None

    def log_message(self, *args):  # silence the default stderr access log (it would carry nothing secret, but stay quiet)
        pass

    def reply(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        form = {k: v[0] for k, v in parse_qs(self.rfile.read(length).decode()).items()}
        action = self.path.rstrip("/").rsplit("/", 1)[-1]
        key, inst = form.get("license_key", ""), form.get("instance_id", "")
        if Handler.log_file:
            with open(Handler.log_file, "a") as f:
                f.write(f"{time.time():.0f} {action} instance={inst or '-'}\n")
        if action == "activate" and key:
            if sum(1 for k in INSTANCES.values() if k == key) >= LIMIT:
                return self.reply(400, {"activated": False, "error": "This license key has reached the activation limit.",
                                        "license_key": key_obj(key), "instance": None, "meta": META})
            iid = str(uuid.uuid4())
            INSTANCES[iid] = key
            return self.reply(200, {"activated": True, "error": None, "license_key": key_obj(key),
                                    "instance": {"id": iid, "name": form.get("instance_name", ""),
                                                 "created_at": "2026-10-12T09:00:00.000000Z"}, "meta": META})
        flag = {"validate": "valid", "deactivate": "deactivated"}.get(action)
        if flag:
            if INSTANCES.get(inst) != key:
                return self.reply(404, {flag: False, "error": "license_key or instance not found.",
                                        "license_key": None, "meta": None})
            if action == "deactivate":
                del INSTANCES[inst]
            return self.reply(200, {flag: True, "error": None, "license_key": key_obj(key),
                                    "instance": {"id": inst}, "meta": META})
        self.reply(404, {"error": "unknown action"})


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port-file", required=True)
    ap.add_argument("--max-seconds", type=int, default=600)
    ap.add_argument("--log")
    a = ap.parse_args()
    Handler.log_file = a.log
    srv = HTTPServer(("127.0.0.1", 0), Handler)
    with open(a.port_file, "w") as f:
        f.write(str(srv.server_address[1]))
    threading.Timer(a.max_seconds, srv.shutdown).start()
    srv.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
