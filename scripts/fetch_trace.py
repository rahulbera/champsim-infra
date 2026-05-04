#!/usr/bin/env python3
"""fetch_trace.py — make a trace available on a node's local disk.

Given an NFS-resident trace path (and optionally its expected SHA-256
checksum), ensure a complete, validated copy exists in a local cache
directory and print the absolute local path to stdout.

Concurrency is the load-bearing concern: with 16-32 Slurm array jobs
landing on a node within seconds of each other, all wanting the same
trace, naive code would either race the same file open for write or
have one job consume another's torn copy. We avoid both by:

  * taking a per-trace POSIX advisory lock (flock) before doing any
    cache lookup or fetch — concurrent callers serialize at the lock
    and the second-in-line typically sees a complete cached file;
  * fetching into a per-pid tempfile in the same directory and using
    rename(2) for atomic publication — readers either see no entry or
    a complete entry, never a partial one.

The cache key is the path's basename. For ChampSim traces this is
unique enough in practice (workload + seed + suffix); if you mix tlists
across projects with colliding basenames, change the key derivation.
"""

import argparse
import fcntl
import hashlib
import os
import sys
import tempfile

CACHE_DIR_DEFAULT = "/tmp/trace_cache"

# 8 MiB matches the TraceReader's compressed-side buffer. Big enough to
# coalesce NFS RPCs into the kernel's readahead window during the read,
# small enough to keep memory bounded when many jobs fetch in parallel.
COPY_BUF_BYTES = 8 * 1024 * 1024


def _ensure_dir(path):
    os.makedirs(path, exist_ok=True)


def _checksum_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(COPY_BUF_BYTES), b""):
            h.update(chunk)
    return h.hexdigest()


def _copy_with_checksum(src, dst):
    """Copy src->dst in 8 MiB chunks, returning the actual SHA-256 hex.

    Caller is responsible for the rename to publish the file.
    """
    h = hashlib.sha256()
    with open(src, "rb") as fin, open(dst, "wb") as fout:
        for chunk in iter(lambda: fin.read(COPY_BUF_BYTES), b""):
            fout.write(chunk)
            h.update(chunk)
        fout.flush()
        os.fsync(fout.fileno())
    return h.hexdigest()


def fetch(path, checksum=None, cache_dir=CACHE_DIR_DEFAULT, log=None):
    """Ensure `path` is cached locally; return absolute path of cached file.

    If `checksum` is given, the cached copy must match (case-insensitive
    hex SHA-256) — a bad cache entry is removed and re-fetched once.

    Raises RuntimeError on any hard failure: source missing, checksum
    mismatch after a fresh fetch, or unrecoverable I/O error.
    """
    if not os.path.isabs(path):
        raise RuntimeError(f"trace path must be absolute: {path}")

    name = os.path.basename(path)
    if not name:
        raise RuntimeError(f"cannot derive filename from path: {path}")

    _ensure_dir(cache_dir)
    locks_dir = os.path.join(cache_dir, ".locks")
    _ensure_dir(locks_dir)

    cached_path = os.path.join(cache_dir, name)
    lock_path = os.path.join(locks_dir, name + ".lock")

    if log is None:
        def log(msg):
            print(f"fetch_trace: {msg}", file=sys.stderr)

    # Per-trace exclusive lock. Other jobs wanting this same trace block
    # here until we either return a cached copy or finish a fresh fetch.
    with open(lock_path, "w") as lockfh:
        fcntl.flock(lockfh.fileno(), fcntl.LOCK_EX)

        # Fast path: cached copy exists and (optionally) matches the
        # expected checksum. Without a checksum, presence is taken as
        # validity — that's the user's contract by omitting it.
        if os.path.exists(cached_path):
            if checksum is None:
                log(f"cache hit (no checksum): {name}")
                return cached_path
            actual = _checksum_file(cached_path)
            if actual.lower() == checksum.lower():
                log(f"cache hit (checksum ok): {name}")
                return cached_path
            log(f"cached copy of {name} has wrong sha256 "
                f"(got {actual}, want {checksum.lower()}); re-fetching")
            os.remove(cached_path)

        if not os.path.exists(path):
            raise RuntimeError(f"source trace not found: {path}")

        # Fetch into a tempfile in the cache dir so rename(2) is atomic
        # (same filesystem). delete=False because we close it ourselves
        # before reopening for the copy.
        tmp = tempfile.NamedTemporaryFile(
            dir=cache_dir, prefix=name + ".tmp.", delete=False
        )
        tmp_path = tmp.name
        tmp.close()
        try:
            log(f"fetching {path} -> {cached_path}")
            actual = _copy_with_checksum(path, tmp_path)
            if checksum is not None and actual.lower() != checksum.lower():
                raise RuntimeError(
                    f"checksum mismatch after fetch of {path}: "
                    f"got {actual}, expected {checksum.lower()}"
                )
            os.rename(tmp_path, cached_path)
        except Exception:
            # Don't leave a tempfile behind on failure; future jobs will
            # try again with a clean slate.
            try:
                os.remove(tmp_path)
            except OSError:
                pass
            raise

        log(f"fetched {name}")
        return cached_path


def main():
    p = argparse.ArgumentParser(
        description="Fetch a trace into a node-local cache; print the "
                    "cached path on stdout."
    )
    p.add_argument("--path", required=True,
                   help="absolute path to the source trace (typically NFS)")
    p.add_argument("--checksum", default=None,
                   help="expected SHA-256 (hex). If omitted, presence in "
                        "cache is taken as validity.")
    p.add_argument("--cache-dir", default=CACHE_DIR_DEFAULT,
                   help=f"local cache directory (default: {CACHE_DIR_DEFAULT})")
    args = p.parse_args()

    try:
        local = fetch(args.path,
                      checksum=args.checksum,
                      cache_dir=args.cache_dir)
    except Exception as e:
        print(f"fetch_trace: {e}", file=sys.stderr)
        sys.exit(1)
    print(local)


if __name__ == "__main__":
    main()
