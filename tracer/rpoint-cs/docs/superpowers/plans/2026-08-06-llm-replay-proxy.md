# LLM Replay Proxy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A local HTTP proxy that records LLM request/response pairs against a real upstream, then replays them exactly with no network — turning a non-deterministic agent into a deterministic, repeatable workload.

**Architecture:** One stdlib-only Python file, two modes. RECORD forwards to the upstream and writes each exchange to a cassette keyed by a hash of the canonicalised request body. REPLAY serves from cassettes and **fails loudly on a miss** — never falling through to the network. The agent points its `base_url` at the proxy.

**Tech Stack:** Python 3 standard library only (`http.server`, `urllib.request`, `hashlib`, `json`). No third-party dependencies, because this must run inside a guest whose package set we are deliberately keeping minimal, and because the proxy's own CPU work lands in the trace.

## Global Constraints

- **Python standard library only.** No `flask`, no `requests`, no `httpx`.
- **A replay miss is a hard error** (HTTP 500 + non-zero exit signal in the log), never a passthrough. With guest networking down a silent fallback is impossible anyway, but failing loudly turns environment drift into a diagnosable error rather than a corrupted trace.
- The API key is read from the environment (`LLM_API_KEY`) in RECORD mode only. It must **never** be written into a cassette — cassettes are committed alongside traces.
- Cassette files are JSON, one exchange per file, named by the request hash, so a diff shows exactly which exchange changed.
- Tests run with `python3 tests/test_replay_proxy.py` and must not require network.

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/swe-agent/replay_proxy.py` (create) | the proxy: canonicalisation, cassette store, RECORD and REPLAY handlers, CLI |
| `scripts/swe-agent/tests/test_replay_proxy.py` (create) | unit tests: canonicalisation, round trip, miss-is-fatal, key excludes volatile fields |
| `scripts/swe-agent/README.md` (create) | how to run both modes, and the cassette-key contract |

---

## Task 1: Cassette key canonicalisation

The fiddliest part of the whole proxy, and the one that fails silently if wrong: over-specify the key and every replay misses; under-specify it and two different requests collide onto one response.

**Files:**
- Create: `scripts/swe-agent/replay_proxy.py`
- Create: `scripts/swe-agent/tests/test_replay_proxy.py`

**Interfaces:**
- Produces: `canonical_key(body: bytes) -> str` returning a 64-char hex SHA-256; `VOLATILE_FIELDS: set[str]`.

- [ ] **Step 1: Write the failing test**

Create `scripts/swe-agent/tests/test_replay_proxy.py`:

```python
#!/usr/bin/env python3
"""Unit tests for replay_proxy. No network, no third-party deps."""
import json
import os
import sys
import unittest

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))
import replay_proxy  # noqa: E402


class TestCanonicalKey(unittest.TestCase):
    def test_identical_bodies_match(self):
        a = json.dumps({"model": "glm-5.2", "messages": [{"role": "user", "content": "hi"}]}).encode()
        b = json.dumps({"model": "glm-5.2", "messages": [{"role": "user", "content": "hi"}]}).encode()
        self.assertEqual(replay_proxy.canonical_key(a), replay_proxy.canonical_key(b))

    def test_key_order_does_not_matter(self):
        """A client that reorders JSON keys must still hit the same cassette."""
        a = b'{"model": "glm-5.2", "messages": []}'
        b = b'{"messages": [], "model": "glm-5.2"}'
        self.assertEqual(replay_proxy.canonical_key(a), replay_proxy.canonical_key(b))

    def test_volatile_fields_are_excluded(self):
        """Per-run noise must not change the key, or every replay misses."""
        base = {"model": "glm-5.2", "messages": [{"role": "user", "content": "hi"}]}
        a = json.dumps(base).encode()
        noisy = dict(base, request_id="abc-123", user="session-9", metadata={"ts": 1})
        b = json.dumps(noisy).encode()
        self.assertEqual(replay_proxy.canonical_key(a), replay_proxy.canonical_key(b))

    def test_different_prompts_differ(self):
        a = b'{"model": "glm-5.2", "messages": [{"role": "user", "content": "hi"}]}'
        b = b'{"model": "glm-5.2", "messages": [{"role": "user", "content": "bye"}]}'
        self.assertNotEqual(replay_proxy.canonical_key(a), replay_proxy.canonical_key(b))

    def test_temperature_is_part_of_the_key(self):
        """Sampling params change the response, so they must change the key."""
        a = b'{"model": "glm-5.2", "messages": [], "temperature": 0}'
        b = b'{"model": "glm-5.2", "messages": [], "temperature": 1}'
        self.assertNotEqual(replay_proxy.canonical_key(a), replay_proxy.canonical_key(b))

    def test_non_json_body_still_keys(self):
        """Must not crash on a body the agent sends that is not JSON."""
        k = replay_proxy.canonical_key(b"not json at all")
        self.assertEqual(len(k), 64)


if __name__ == "__main__":
    unittest.main(verbosity=2)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `ModuleNotFoundError: No module named 'replay_proxy'`

- [ ] **Step 3: Write the minimal implementation**

Create `scripts/swe-agent/replay_proxy.py`:

```python
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `Ran 6 tests ... OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/swe-agent/replay_proxy.py scripts/swe-agent/tests/test_replay_proxy.py
git commit -m "swe-agent: cassette key canonicalisation for the replay proxy

Keys a cassette on the request body with volatile fields dropped, JSON keys
sorted and whitespace normalised. This is the part that fails silently if it
is wrong: over-specify the key and every replay misses, under-specify it and
two different requests collide onto one response. Tested both directions."
```

---

## Task 2: Cassette store, RECORD and REPLAY

**Files:**
- Modify: `scripts/swe-agent/replay_proxy.py`
- Modify: `scripts/swe-agent/tests/test_replay_proxy.py`

**Interfaces:**
- Consumes: `canonical_key` from Task 1.
- Produces: `Cassettes(dirpath)` with `.save(key, status, headers, body) -> None`, `.load(key) -> tuple[int, dict, bytes] | None`, `.count() -> int`; exception `ReplayMiss`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/swe-agent/tests/test_replay_proxy.py`, before the `__main__` block:

```python
class TestCassettes(unittest.TestCase):
    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.c = replay_proxy.Cassettes(self.tmp)

    def test_round_trip(self):
        key = "a" * 64
        self.c.save(key, 200, {"Content-Type": "application/json"}, b'{"ok":true}')
        got = self.c.load(key)
        self.assertIsNotNone(got)
        status, headers, body = got
        self.assertEqual(status, 200)
        self.assertEqual(body, b'{"ok":true}')
        self.assertEqual(headers["Content-Type"], "application/json")

    def test_miss_returns_none(self):
        self.assertIsNone(self.c.load("b" * 64))

    def test_count(self):
        self.assertEqual(self.c.count(), 0)
        self.c.save("c" * 64, 200, {}, b"{}")
        self.assertEqual(self.c.count(), 1)

    def test_api_key_never_persisted(self):
        """Cassettes are committed alongside traces; a leaked key is permanent."""
        self.c.save("d" * 64, 200, {"Authorization": "Bearer SECRET-KEY-XYZ"}, b"{}")
        import pathlib
        blob = "".join(p.read_text() for p in pathlib.Path(self.tmp).glob("*.json"))
        self.assertNotIn("SECRET-KEY-XYZ", blob)
        self.assertNotIn("Authorization", blob)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `AttributeError: module 'replay_proxy' has no attribute 'Cassettes'`

- [ ] **Step 3: Write the implementation**

Append to `scripts/swe-agent/replay_proxy.py`:

```python
import os


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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `Ran 10 tests ... OK`

- [ ] **Step 5: Commit**

```bash
git add scripts/swe-agent/replay_proxy.py scripts/swe-agent/tests/test_replay_proxy.py
git commit -m "swe-agent: cassette store for the replay proxy

One JSON file per exchange named by request key, so a re-recording diffs
exchange-by-exchange. Writes are tempfile + atomic rename, so a reader never
sees a torn cassette.

Only Content-Type survives into a cassette. That is what guarantees the API
key cannot leak: cassettes are committed alongside traces, so a leaked
Authorization header would be permanent."
```

---

## Task 3: The HTTP server and CLI

**Files:**
- Modify: `scripts/swe-agent/replay_proxy.py`
- Modify: `scripts/swe-agent/tests/test_replay_proxy.py`
- Create: `scripts/swe-agent/README.md`

**Interfaces:**
- Consumes: `canonical_key`, `Cassettes`, `ReplayMiss`.
- Produces: `make_handler(mode, cassettes, upstream, api_key)`; `main(argv)`.

- [ ] **Step 1: Write the failing test**

Append to `scripts/swe-agent/tests/test_replay_proxy.py`, before the `__main__` block:

```python
class TestReplayServer(unittest.TestCase):
    """Drives a real server over loopback. No upstream, so REPLAY only."""

    def setUp(self):
        import http.server
        import tempfile
        import threading
        self.tmp = tempfile.mkdtemp()
        self.c = replay_proxy.Cassettes(self.tmp)
        body = b'{"model":"glm-5.2","messages":[{"role":"user","content":"hi"}]}'
        self.key = replay_proxy.canonical_key(body)
        self.body = body
        self.c.save(self.key, 200, {"Content-Type": "application/json"},
                    b'{"choices":[{"message":{"content":"hello"}}]}')

        handler = replay_proxy.make_handler("replay", self.c, None, None)
        self.srv = http.server.HTTPServer(("127.0.0.1", 0), handler)
        self.port = self.srv.server_address[1]
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()

    def tearDown(self):
        self.srv.shutdown()

    def _post(self, payload):
        import urllib.error
        import urllib.request
        req = urllib.request.Request(
            "http://127.0.0.1:%d/v1/chat/completions" % self.port,
            data=payload, headers={"Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req) as r:
                return r.status, r.read()
        except urllib.error.HTTPError as e:
            return e.code, e.read()

    def test_hit_serves_the_recorded_response(self):
        status, body = self._post(self.body)
        self.assertEqual(status, 200)
        self.assertIn(b"hello", body)

    def test_miss_is_a_hard_error_not_a_passthrough(self):
        """The single most important behaviour: drift must be loud."""
        status, body = self._post(b'{"model":"glm-5.2","messages":[{"role":"user","content":"UNSEEN"}]}')
        self.assertEqual(status, 500)
        self.assertIn(b"REPLAY MISS", body)
```

- [ ] **Step 2: Run test to verify it fails**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `AttributeError: module 'replay_proxy' has no attribute 'make_handler'`

- [ ] **Step 3: Write the implementation**

Append to `scripts/swe-agent/replay_proxy.py`:

```python
import http.server
import sys
import urllib.request


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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `python3 scripts/swe-agent/tests/test_replay_proxy.py`
Expected: `Ran 12 tests ... OK`

- [ ] **Step 5: Write the README**

Create `scripts/swe-agent/README.md`:

```markdown
# scripts/swe-agent/

Record/replay proxy that turns a non-deterministic coding agent into a
deterministic, repeatable workload for tracing.

## Why

`temperature=0` does **not** make an LLM deterministic — providers batch
requests across users, so shared-batch composition can flip an argmax between
near-tied tokens and the generation diverges. Determinism here comes from the
*recording*, not from sampling parameters: once a trajectory is recorded,
replay is exact by construction at any temperature.

## Use

```bash
# Pass 2 — RECORD (needs network and a key)
LLM_API_KEY=... python3 replay_proxy.py --mode record \
    --cassettes ./cassettes/<instance-id> \
    --upstream https://<glm-endpoint> --port 8000

# Pass 3 — REPLAY (no network, no key)
python3 replay_proxy.py --mode replay \
    --cassettes ./cassettes/<instance-id> --port 8000
```

Point the agent's `base_url` at `http://127.0.0.1:8000`.

## Contract

- **A replay miss is a hard 500**, never a passthrough. A miss means the agent
  diverged from the recorded trajectory; serving anything else would put a
  fabricated exchange into a trace we later treat as real.
- The cassette key is a SHA-256 over the request body with volatile fields
  (`request_id`, `user`, `metadata`, timestamps) removed and JSON keys sorted.
  Over-specify it and every replay misses; under-specify it and two different
  requests collide onto one response.
- **Only `Content-Type` is persisted** from the response. Cassettes are
  committed alongside traces, so an `Authorization` header written to disk
  would be a permanent key leak.
- One JSON file per exchange, so a re-recording diffs exchange-by-exchange.
```

- [ ] **Step 6: Commit**

```bash
git add scripts/swe-agent/replay_proxy.py scripts/swe-agent/tests/test_replay_proxy.py scripts/swe-agent/README.md
git commit -m "swe-agent: HTTP server and CLI for the replay proxy

RECORD forwards to the upstream and persists each exchange; REPLAY serves from
cassettes and returns a hard 500 on a miss, never a passthrough. A miss means
the agent diverged from the recording, and serving anything else would put a
fabricated exchange into a trace we later treat as real.

Standard library only: this runs in a guest whose package set is deliberately
minimal, and the proxy's own CPU work lands in the trace, so its dependencies
are part of the measurement."
```

---

## Self-Review

**Spec coverage.** Spec §9 requires: two modes (Tasks 2-3), cassette key
canonicalisation excluding volatile fields (Task 1), miss-is-fatal (Task 3),
per-task cassettes stored alongside the `.traj` (Task 2 directory layout), and
the API key confined to Pass 2 (Task 3 CLI, enforced by `LLM_API_KEY` being
read only in record mode). Spec §11.1 requires unit tests for canonicalisation
and a record/replay round trip — Tasks 1 and 2.

**Type consistency.** `canonical_key(bytes) -> str` is used identically in
Tasks 2 and 3. `Cassettes.load` returns `(status, headers, body)` or `None`,
and Task 3's handler unpacks exactly that triple. `make_handler(mode,
cassettes, upstream, api_key)` matches its call in `main` and in the test.

**Placeholder scan.** No TBDs, and no deliberately-broken values: every code
block is intended to be used verbatim.

---

## Not in this plan

- **Guest build/record/trace scripts** (spec §5, §7, §8) — needs the final
  Prometheus instance pick and, for Pass 2, the API key.
- **Conversion and validation driver** (spec §10).
