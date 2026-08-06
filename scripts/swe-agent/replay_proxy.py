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
