# scripts/swe-agent/

Turns a non-deterministic coding agent into a deterministic, repeatable workload
that can be traced under QEMU, and parameterises the whole capture by
**instance** and **language** so each new task is a descriptor rather than a
fork of the scripts.

## Layout

| Path | What it is |
|---|---|
| `stage_instance.py` | **Host side.** Fetches a SWE-bench instance, writes the problem statement, and verifies the checked-in descriptor against the live dataset. |
| `instances/<id>.env` | Per-instance facts: repo, `base_commit`, language module, model, gate commands. |
| `lang/<module>.sh` | Per-language toolchain + offline-cache + gate implementation. |
| `lib/common.sh` | `load_instance`, `assert_repo_pristine`, `run_offline`. |
| `provision_guest.sh` | Pass 1 — toolchain, checkout, offline cache, SWE-agent. |
| `record_trajectory.sh` | Pass 2 — one real LLM run through the proxy in record mode. |
| `replay_pinned.sh` | Pass 3 — offline replay pinned to the isolated vCPU. |
| `replay_proxy.py` | The record/replay HTTP proxy. |

All three passes run **inside the guest** and take the instance id as `$1`.

## Why record/replay

`temperature=0` does **not** make an LLM deterministic — providers batch
requests across users, so shared-batch composition can flip an argmax between
near-tied tokens and the generation diverges from there. Determinism comes from
the *recording*, not from sampling parameters: once a trajectory is recorded,
replay is exact by construction at any temperature.

That is what makes the two-pass capture valid — a `profile=on` pass to measure
the trajectory's length, then a sampling pass spaced from that measurement.

## Adding an instance

```bash
# 1. Fetch it and print a starter descriptor
python3 stage_instance.py <instance_id> --write-env

# 2. Write instances/<instance_id>.env, then verify + stage
python3 stage_instance.py <instance_id>
```

Step 2 re-reads the descriptor and **fails if `repo`, `base_commit` or
`REPO_NAME` disagree with the dataset**. That check exists because a wrong
`base_commit` produces a trace that is complete, well-formed, and of the wrong
tree — nothing downstream can detect it. Two research agents once disagreed
about one instance's commit.

**Validate the instance before spending VM time on it.** Build the repo at
`base_commit`, apply `test_patch`, and confirm the `FAIL_TO_PASS` test *runs and
fails*; then apply the gold patch and confirm it *runs and passes*. "The command
exited non-zero" is not evidence — a port clash, an unbuildable tree or a dead
harness all exit non-zero. Two candidates were rejected this way: one where the
repo predated the guest's Python, and one where the test failed only because a
stale server held its port.

## Language modules

A module supplies four hooks; `load_instance` refuses to run if any is missing,
because a silently skipped `lang_offline_gate` turns into a trace that dies on a
DNS lookup hours later.

| Hook | Job |
|---|---|
| `lang_toolchain` | Install the pinned compiler/runtime, assert the version. |
| `lang_deps` | Populate the offline dependency cache (network is UP here). |
| `lang_offline_gate` | Build **and test** under `unshare -n`. Must assert work happened. |
| `lang_clean_check` | Assert the build left no file that `git diff` would absorb. |

### The seven modules

| Module | Used by | Offline strategy | Gate counts work? |
|---|---|---|---|
| `c_make` | redis | vendored in-tree, nothing to cache; the gate rebuilds from `make distclean` | yes — `[ok]:` lines (`GATE_TEST_PATTERN`) |
| `go` | prometheus, gin | `go mod download` (+ `download all`) into `/opt/go`, then `GOPROXY=off` + `-mod=readonly` | **no — see the gap below** |
| `java_maven` | *(never used for a trace)* | `mvn dependency:go-offline` into `/opt/m2`, then `mvn -o` | yes — sums `Tests run: N` |
| `node_npm` | immutable-js | `npm ci` against the committed lockfile, then `npm_config_offline=true` | yes — `N passed`/`N passing` |
| `php_composer` | *(never used for a trace)* | `composer install` (or `update` when a library ships no lock) into `vendor/`, cache at `/opt/composer-cache` | yes — `OK (N tests` / `Tests: N` |
| `ruby_bundler` | rubocop | `bundle install` into `/opt/bundle` via a global `BUNDLE_PATH`, then `BUNDLE_FROZEN=true` | yes — `N examples,` |
| `rust_cargo` | ripgrep | `cargo fetch` into `/opt/cargo` (never `cargo vendor`), then `--offline` | yes — sums `N passed` |

Seven modules exist; **only five have ever produced a trace** — `c_make`, `go`,
`node_npm`, `ruby_bundler` and `rust_cargo`, behind redis, prometheus/gin,
immutable-js, rubocop and ripgrep respectively. `java_maven` and `php_composer`
are written and reviewed but have no instance descriptor in `instances/` (the
Java and PHP candidates are parked in `instances/dropped/`), so they have never
run end to end. Treat them as untested.

### KNOWN GAP: the Go module's offline gate asserts nothing about work done

The hook contract above says `lang_offline_gate` must assert work happened. Six
of the seven modules do — each greps its harness's own per-test line out of the
gate log and refuses a count below `GATE_MIN_TESTS`. **`lang/go.sh` does not.**
Its gate is three lines and ends at `run_offline "... && $GATE_BUILD_CMD &&
$GATE_TEST_CMD"`: it checks the exit code and counts nothing.

That would be a weak gate anywhere; here it is weaker still, because **both Go
descriptors run zero tests by construction**:

```
prometheus__prometheus-15142:  GATE_TEST_CMD='go test -c -o /dev/null ./tsdb'
gin-gonic__gin-3820:           GATE_TEST_CMD='go test -c -o /dev/null ./binding'
```

`go test -c` *compiles* the test binary and writes it out; with `-o /dev/null`
it is discarded and **never executed**. So the Go gate proves the module cache
is complete enough to compile, and nothing about whether the suite runs offline.
`-c -o /dev/null` is itself deliberate — `lang_clean_check` in `go.sh` notes that
a plain `go test -c ./pkg` drops a multi-MB binary that `git add -A` would
swallow into the agent's patch — so the two constraints are in genuine tension
and this is not a one-line fix.

Practical consequence: for a Go instance, a dependency needed only at test
runtime would not be caught by the gate and would surface as a network stall
inside the traced window, hours later. Neither Go capture has hit that, but the
gate is not what is protecting them. This is recorded here rather than fixed.

### The offline gate is the load-bearing step

Provisioning runs **with** network, so a missing dependency is fetched on demand
and never noticed. `run_offline` re-runs the build in an empty network namespace,
which is the only check that distinguishes "the cache is complete" from "the
cache looked complete because the network was up".

Two details it gets right:

- **Loopback is brought up** inside the namespace. A fresh netns has `lo` DOWN,
  so anything binding `127.0.0.1` — redis's harness starts real servers — fails
  with "Cannot assign requested address". That looks exactly like a missing
  dependency, and the tempting fix is to weaken the gate.
- **`c_make` rebuilds from `distclean`**, not incrementally. An incremental
  `make` right after `lang_deps` is a no-op that compiles nothing, and the gate
  would pass having done no work at all.

## Contract of the proxy

- **A replay miss is a hard 500**, never a passthrough. A miss means the agent
  diverged from the recorded trajectory; serving anything else would put a
  fabricated exchange into a trace we later treat as real.
- **Replay matches by sequence, not by content hash.** Content hashing was tried
  first and failed with **60 misses in 147 calls**: an agent's request carries
  its whole conversation *including tool output*, and `go test -race` prints
  elapsed times, so one timing difference changes that request's hash and every
  later one. No amount of key canonicalisation fixes that — the volatile data is
  in the body. Running off the end of the recording is fatal, never a wrap.
- **Only `Content-Type` is persisted** from the response. Cassettes are committed
  alongside traces, so an `Authorization` header on disk would be a permanent key
  leak. The key is read from `$LLM_API_KEY` in record mode only and is asserted
  absent from every cassette.
- One JSON file per exchange, written tempfile + atomic rename, so a re-recording
  diffs exchange-by-exchange and a reader never sees a torn file.

## Tests

```bash
python3 tests/test_replay_proxy.py       # 15 tests, no network, stdlib only
bash    tests/test_instance_loader.sh    # 16 checks (+3 more with passwordless sudo)
```

The loader tests assert what it **rejects** — a missing variable, a descriptor
whose `INSTANCE` disagrees with its filename, a language module missing a hook.
Every one of those, allowed through, yields a valid-looking trace of the wrong
thing.

## Why standard library only

The proxy runs inside a guest whose package set is deliberately minimal, and its
own CPU work lands in the trace — so its dependencies are part of the
measurement, not an implementation detail.
