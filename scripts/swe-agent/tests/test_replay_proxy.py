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
