#!/usr/bin/env python3
"""Send HMP commands to a QEMU monitor unix socket and print each reply.

    hmp.py <monitor.sock> "<command>" ["<command>" ...]

This drove every savevm in the memcached/RocksDB/Redis/MongoDB capture
campaigns while living only in /tmp -- exactly the "the recipe exists on one
disk" failure the 2026-09-04 audit was written about. It lives in the repo now.

The per-command wait is generous because `savevm` on a large guest writes the
whole of guest RAM into the qcow2 before it returns; a 24 GB guest is minutes,
not seconds, and a short timeout here looks identical to a hung monitor.
"""
import socket, sys, time

TIMEOUT = 1800  # seconds per command; savevm on a big guest is the long pole

def main():
    if len(sys.argv) < 3:
        sys.exit("usage: hmp.py <monitor.sock> <command> [command ...]")
    sock, cmds = sys.argv[1], sys.argv[2:]
    s = socket.socket(socket.AF_UNIX)
    s.connect(sock)
    s.settimeout(TIMEOUT)
    time.sleep(0.4)
    try:
        s.recv(65536)          # drain the banner
    except Exception:
        pass
    for c in cmds:
        s.sendall((c + "\n").encode())
        time.sleep(1.0)
        buf, t0 = b"", time.time()
        while time.time() - t0 < TIMEOUT:
            try:
                d = s.recv(65536)
                if not d:
                    break
                buf += d
                if buf.rstrip().endswith(b"(qemu)"):
                    break
            except socket.timeout:
                break
        print(f"--- {c} ---")
        print(buf.decode(errors="replace").strip()[:4000])

if __name__ == "__main__":
    main()
