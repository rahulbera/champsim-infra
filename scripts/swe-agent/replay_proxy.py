#!/usr/bin/env python3
"""replay_proxy.py — record/replay proxy for LLM API calls.

Turns a non-deterministic agent into a deterministic, repeatable workload:
RECORD once against the real upstream, then REPLAY forever with no network.

Standard library only, by design. This runs inside a guest whose package set is
deliberately minimal, and the proxy's own CPU work lands in the trace -- so its
dependencies are part of the measurement.
"""
import hashlib
import json
import os

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
