#!/usr/bin/env python3
"""replay_proxy.py — record/replay proxy for LLM API calls.

Turns a non-deterministic agent into a deterministic, repeatable workload:
RECORD once against the real upstream, then REPLAY forever with no network.

Standard library only, by design. This runs inside a guest whose package set is
deliberately minimal, and the proxy's own CPU work lands in the trace -- so its
dependencies are part of the measurement.
"""
import hashlib
import http.server
import json
import os
import sys
import urllib.request

# Fields that vary per run and must NOT contribute to the cassette key.
# Include one of these and every single replay misses; exclude a field that
# genuinely changes the response and two exchanges collide onto one cassette.
VOLATILE_FIELDS = {
    "request_id",
    "id",
    "user",
    "metadata",
    "stream_options",
    "timestamp",
    "created",
}


def canonical_key(body: bytes) -> str:
    """SHA-256 over a canonicalised request body.

    Canonical form: JSON with volatile fields dropped, keys sorted, no
    insignificant whitespace. A body that is not valid JSON is hashed verbatim
    rather than raising -- an unparseable request should still replay.
    """
    try:
        obj = json.loads(body)
    except (ValueError, TypeError):
        return hashlib.sha256(body).hexdigest()

    if isinstance(obj, dict):
        obj = {k: v for k, v in obj.items() if k not in VOLATILE_FIELDS}

    canon = json.dumps(obj, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(canon.encode("utf-8")).hexdigest()


class ReplayMiss(Exception):
    """A request had no cassette. Fatal by design -- see the module docstring."""


# Response headers worth preserving. Everything else is dropped, which also
# guarantees Authorization can never reach a cassette: these files are
# committed next to the traces, and a leaked key is permanent.
KEEP_RESPONSE_HEADERS = {"content-type"}


class Cassettes:
    """One JSON file per exchange, named by request key.

    One file per exchange rather than a single store, so that `git diff` on a
    re-recording shows exactly which exchanges changed.
    """

    def __init__(self, dirpath):
        self.dir = dirpath
        os.makedirs(self.dir, exist_ok=True)

    def _path(self, key):
        return os.path.join(self.dir, key + ".json")

    def save(self, key, status, headers, body):
        safe_headers = {
            k: v for k, v in headers.items() if k.lower() in KEEP_RESPONSE_HEADERS
        }
        doc = {
            "key": key,
            "status": status,
            "headers": safe_headers,
            "body": body.decode("utf-8", errors="replace"),
        }
        tmp = self._path(key) + ".tmp"
        with open(tmp, "w") as f:
            json.dump(doc, f, indent=1, sort_keys=True)
        os.replace(tmp, self._path(key))   # atomic: no torn cassette

    def load(self, key):
        try:
            with open(self._path(key)) as f:
                doc = json.load(f)
        except FileNotFoundError:
            return None
        return doc["status"], doc.get("headers", {}), doc["body"].encode("utf-8")

    def count(self):
        return len([n for n in os.listdir(self.dir) if n.endswith(".json")])


def make_handler(mode, cassettes, upstream, api_key):
    """Build a BaseHTTPRequestHandler subclass bound to this configuration."""

    class Handler(http.server.BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, fmt, *args):
            sys.stderr.write("[proxy] " + (fmt % args) + "\n")

        def _respond(self, status, headers, body):
            self.send_response(status)
            for k, v in headers.items():
                self.send_header(k, v)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_POST(self):
            length = int(self.headers.get("Content-Length", 0))
            body = self.rfile.read(length)
            key = canonical_key(body)

            if mode == "replay":
                hit = cassettes.load(key)
                if hit is None:
                    # Loud on purpose. A miss means the agent diverged from the
                    # recorded trajectory; serving anything else would put a
                    # fabricated exchange into a trace we later treat as real.
                    msg = ("REPLAY MISS for key %s on %s -- the agent diverged "
                           "from the recording.\n" % (key, self.path)).encode()
                    sys.stderr.write("[proxy] " + msg.decode())
                    self._respond(500, {"Content-Type": "text/plain"}, msg)
                    return
                status, headers, rbody = hit
                self._respond(status, headers, rbody)
                return

            # RECORD: forward upstream, persist, return verbatim.
            req = urllib.request.Request(
                upstream.rstrip("/") + self.path, data=body,
                headers={"Content-Type": "application/json",
                         "Authorization": "Bearer " + api_key})
            with urllib.request.urlopen(req) as r:
                rbody = r.read()
                status = r.status
                headers = {"Content-Type": r.headers.get("Content-Type",
                                                         "application/json")}
            cassettes.save(key, status, headers, rbody)
            self._respond(status, headers, rbody)

    return Handler


def main(argv):
    import argparse
    p = argparse.ArgumentParser(description="record/replay proxy for LLM API calls")
    p.add_argument("--mode", choices=["record", "replay"], required=True)
    p.add_argument("--cassettes", required=True, help="cassette directory")
    p.add_argument("--port", type=int, default=8000)
    p.add_argument("--upstream", default="", help="upstream base URL (record mode)")
    args = p.parse_args(argv)

    api_key = os.environ.get("LLM_API_KEY", "")
    if args.mode == "record":
        if not args.upstream:
            p.error("--upstream is required in record mode")
        if not api_key:
            p.error("LLM_API_KEY must be set in record mode")

    cassettes = Cassettes(args.cassettes)
    handler = make_handler(args.mode, cassettes, args.upstream, api_key)
    srv = http.server.HTTPServer(("127.0.0.1", args.port), handler)
    sys.stderr.write("[proxy] %s mode on 127.0.0.1:%d, %d cassettes in %s\n"
                     % (args.mode, args.port, cassettes.count(), args.cassettes))
    srv.serve_forever()


if __name__ == "__main__":
    main(sys.argv[1:])
