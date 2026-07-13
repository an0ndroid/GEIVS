"""Tests for the Signal bridge's brief-routing regex.

Importing bridge is side-effect free: the server only starts under
`if __name__ == "__main__"`, so importing just defines config + BRIEF_RE.
"""
import os
import sys
import unittest
import unittest.mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "services"))
import bridge  # noqa: E402


class TestBriefRouting(unittest.TestCase):
    def test_brief_phrases_route_to_visual_brief(self):
        for msg in ["daily brief", "give me my daily brief", "morning brief",
                    "brief", "my brief", "BRIEF", "Morning Brief please"]:
            self.assertTrue(bridge.BRIEF_RE.search(msg), f"expected match: {msg!r}")

    def test_other_messages_go_to_the_agent(self):
        for msg in ["brief me on the weather", "check my inbox", "send a tweet",
                    "debrief the team", "briefly explain n8n", "what's on my calendar"]:
            self.assertFalse(bridge.BRIEF_RE.search(msg), f"expected NO match: {msg!r}")

    def test_owner_list_parsing(self):
        # OWNERS is derived from JEEVES_OWNERS/JEEVES_OWNER; it must be a non-empty list.
        self.assertIsInstance(bridge.OWNERS, list)
        self.assertTrue(len(bridge.OWNERS) >= 1)
        self.assertEqual(bridge.OWNER, bridge.OWNERS[0])


class TestRestMode(unittest.TestCase):
    """Signal API mode defaults to 'daemon' (Richard's dev box); 'rest' targets
    bbernhard/signal-cli-rest-api (the containerized product path)."""

    def test_default_mode_is_daemon(self):
        self.assertEqual(bridge.SIGNAL_API_MODE, "daemon")

    def test_rest_send_posts_v2_send(self):
        calls = []
        with unittest.mock.patch.object(bridge, "SIGNAL_API_MODE", "rest"), \
             unittest.mock.patch.object(bridge, "SIGNAL_ACCOUNT", "+1bot"), \
             unittest.mock.patch.object(bridge, "rest_request", lambda *a, **k: calls.append((a, k))):
            ok = bridge.send_signal("hello", "+1recipient")
        self.assertTrue(ok)
        (method, path, body), _ = calls[0]
        self.assertEqual(method, "POST")
        self.assertEqual(path, "/v2/send")
        self.assertEqual(body, {"message": "hello", "number": "+1bot", "recipients": ["+1recipient"]})

    def test_rest_send_failure_returns_false(self):
        def boom(*a, **k):
            raise RuntimeError("connection refused")
        with unittest.mock.patch.object(bridge, "SIGNAL_API_MODE", "rest"), \
             unittest.mock.patch.object(bridge, "rest_request", boom):
            self.assertFalse(bridge.send_signal("hello"))

    def test_daemon_mode_still_uses_rpc(self):
        calls = []
        with unittest.mock.patch.object(bridge, "rpc", lambda *a, **k: calls.append((a, k)) or {}):
            bridge.send_signal("hello", "+1recipient")
        self.assertTrue(calls)

    def test_file_to_base64_attachment_roundtrips(self):
        import base64
        import tempfile
        with tempfile.NamedTemporaryFile(suffix=".wav", delete=False) as f:
            f.write(b"RIFF....WAVEfmt ")
            path = f.name
        try:
            uri = bridge._file_to_base64_attachment(path)
            self.assertTrue(uri.startswith("data:audio/"))
            b64_part = uri.split(",", 1)[1]
            self.assertEqual(base64.b64decode(b64_part), b"RIFF....WAVEfmt ")
        finally:
            os.remove(path)

    def test_backoff_sleep_caps(self):
        with unittest.mock.patch.object(bridge.time, "sleep") as mock_sleep:
            bridge._backoff_sleep(0)
            bridge._backoff_sleep(10)
        mock_sleep.assert_any_call(1)
        mock_sleep.assert_any_call(30)

    def test_rest_poll_loop_requires_signal_account(self):
        with unittest.mock.patch.object(bridge, "SIGNAL_ACCOUNT", ""):
            bridge.rest_poll_loop()  # should log and return immediately, not raise/hang


if __name__ == "__main__":
    unittest.main()
