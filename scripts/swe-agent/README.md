# scripts/swe-agent/

Record/replay proxy that turns a non-deterministic coding agent into a
deterministic, repeatable workload for tracing.

## Why

`temperature=0` does **not** make an LLM deterministic — providers batch
requests across users, so shared-batch composition can flip an argmax between
near-tied tokens and the generation diverges from there. Determinism here comes
from the *recording*, not from sampling parameters: once a trajectory is
recorded, replay is exact by construction at any temperature.

That is what makes the two-pass capture valid — a `profile=on` pass to measure
the trajectory's length, then a sampling pass spaced from that measurement.

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
  fabricated exchange into a trace we later treat as real. With guest
  networking off a silent fallback is impossible anyway — but failing loudly
  turns drift into a diagnosable error instead of a quietly wrong trace.
- The cassette key is a SHA-256 over the request body with volatile fields
  (`request_id`, `user`, `metadata`, timestamps) removed and JSON keys sorted.
  Over-specify it and every replay misses; under-specify it and two different
  requests collide onto one response. Both directions are unit-tested.
- **Only `Content-Type` is persisted** from the response. Cassettes are
  committed alongside traces, so an `Authorization` header written to disk
  would be a permanent key leak. The API key is read from the environment in
  record mode only and never reaches a cassette.
- One JSON file per exchange, written tempfile + atomic rename, so a
  re-recording diffs exchange-by-exchange and a reader never sees a torn file.

## Tests

```bash
python3 tests/test_replay_proxy.py
```

12 tests, no network, standard library only.

## Why standard library only

This runs inside a guest whose package set is deliberately minimal, and the
proxy's own CPU work lands in the trace — so its dependencies are part of the
measurement, not an implementation detail.
