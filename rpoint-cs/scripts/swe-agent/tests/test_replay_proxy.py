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


class TestSequenceMatching(unittest.TestCase):
    """Sequence replay must be immune to request-body drift.

    An agent's request carries its whole conversation including tool output,
    and tool output is not reproducible (elapsed times, mtimes). Content
    hashing therefore diverges permanently after the first differing byte --
    measured at 60 misses in 147 calls on a real trajectory.
    """

    def setUp(self):
        import tempfile
        self.tmp = tempfile.mkdtemp()
        self.c = replay_proxy.Cassettes(self.tmp)
        for i, txt in enumerate(["first", "second", "third"]):
            k = replay_proxy.canonical_key(("req-%d" % i).encode())
            self.c.save(k, 200, {"Content-Type": "application/json"},
                        ('{"n":"%s"}' % txt).encode())
            self.c.append_order(k)

    def test_order_is_recorded(self):
        self.assertEqual(len(self.c.order()), 3)

    def test_sequence_ignores_body_drift(self):
        """Bodies that never appeared in the recording still replay in order."""
        import http.server, threading, urllib.request
        h = replay_proxy.make_handler("replay", self.c, None, None, "sequence")
        srv = http.server.HTTPServer(("127.0.0.1", 0), h)
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        got = []
        for i in range(3):
            req = urllib.request.Request(
                "http://127.0.0.1:%d/v1/chat/completions" % srv.server_address[1],
                data=('{"totally":"different-%d"}' % i).encode(),
                headers={"Content-Type": "application/json"})
            with urllib.request.urlopen(req) as r:
                got.append(json.loads(r.read())["n"])
        srv.shutdown()
        self.assertEqual(got, ["first", "second", "third"])

    def _post_bodies(self, bodies):
        """Drive a sequence-mode server with the given request bodies."""
        import http.server, threading, urllib.error, urllib.request
        h = replay_proxy.make_handler("replay", self.c, None, None, "sequence")
        srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), h)
        srv.daemon_threads = True
        threading.Thread(target=srv.serve_forever, daemon=True).start()
        out = []
        for b in bodies:
            req = urllib.request.Request(
                "http://127.0.0.1:%d/v1/chat/completions" % srv.server_address[1],
                data=b, headers={"Content-Type": "application/json"})
            try:
                with urllib.request.urlopen(req) as r:
                    out.append((r.status, r.read()))
            except urllib.error.HTTPError as e:
                out.append((e.code, e.read()))
        srv.shutdown()
        return out

    def test_running_off_the_end_is_fatal(self):
        """More requests than recorded exchanges must fail, never wrap.

        Bodies must DIFFER: an agent's request carries the conversation so far,
        so consecutive requests are never byte-identical. Identical ones mean a
        retry and are handled by the test below.
        """
        res = self._post_bodies([b'{"x":0}', b'{"x":1}', b'{"x":2}', b'{"x":3}'])
        self.assertEqual([c for c, _ in res], [200, 200, 200, 500])

    def test_a_retry_does_not_consume_the_next_exchange(self):
        """A byte-identical repeat is a retry, not progress.

        litellm retries on a dropped connection. If the retry consumed the next
        cassette, every later exchange would be served the wrong response and
        nothing would report a miss -- silent, total divergence.
        """
        res = self._post_bodies([b'{"x":0}', b'{"x":0}', b'{"x":1}'])
        self.assertEqual([c for c, _ in res], [200, 200, 200])
        names = [json.loads(b)["n"] for _, b in res]
        # The retry re-serves "first"; only the new body advances to "second".
        self.assertEqual(names, ["first", "first", "second"])


if __name__ == "__main__":
    unittest.main(verbosity=2)
