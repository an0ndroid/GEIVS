"""Tests for the Signal bridge's brief-routing regex.

Importing bridge is side-effect free: the server only starts under
`if __name__ == "__main__"`, so importing just defines config + BRIEF_RE.
"""
import os
import sys
import unittest

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


if __name__ == "__main__":
    unittest.main()
