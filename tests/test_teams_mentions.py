"""Tests for build-teams-mentions.py — Teams @mention payload builder.

Covers the bug where duplicate mentions of the same person were silently
dropped because all occurrences shared one <at id>.
"""
from __future__ import annotations

import json
import re
import sys
import os

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts"))
from importlib import import_module
btm = import_module("build-teams-mentions")

reindex_mentions = btm.reindex_mentions
build_payload = btm.build_payload

PARESH_ID = "fdea2635-c751-4112-8174-05ba00730daf"
JOSH_ID = "90b98fe6-a80b-46e1-9209-b5ebcdf6da6b"
MAURICIO_ID = "c19890c3-f551-4d53-b8dd-16fe907bfe14"


def _make_mention(mid: int, name: str, uid: str) -> dict:
    return {
        "id": mid,
        "mentionText": name,
        "mentioned": {
            "user": {
                "id": uid,
                "displayName": name,
                "userIdentityType": "aadUser",
            }
        },
    }


def _count_at_tags(html: str) -> int:
    return len(re.findall(r'<at id="\d+">[^<]+</at>', html))


def _extract_at_ids(html: str) -> list:
    return [int(m) for m in re.findall(r'<at id="(\d+)">', html)]


# === Core invariant: every <at> tag gets a unique id ===

class TestUniqueIds:
    def test_same_person_twice_gets_different_ids(self):
        """The original bug: Paresh in two rows shared id=5, second was dropped."""
        body = (
            '<tr><td><at id="0">Paresh Mewada</at></td></tr>'
            '<tr><td><at id="0">Paresh Mewada</at></td></tr>'
        )
        mentions = [_make_mention(0, "Paresh Mewada", PARESH_ID)]
        new_body, new_mentions = reindex_mentions(body, mentions)

        ids = _extract_at_ids(new_body)
        assert ids == [0, 1], f"Expected [0, 1], got {ids}"
        assert len(new_mentions) == 2
        assert new_mentions[0]["id"] != new_mentions[1]["id"]

    def test_same_person_three_times(self):
        body = (
            '<at id="0">Paresh Mewada</at> '
            '<at id="0">Paresh Mewada</at> '
            '<at id="0">Paresh Mewada</at>'
        )
        mentions = [_make_mention(0, "Paresh Mewada", PARESH_ID)]
        new_body, new_mentions = reindex_mentions(body, mentions)

        ids = _extract_at_ids(new_body)
        assert ids == [0, 1, 2]
        assert len(set(ids)) == 3, "All ids must be unique"

    def test_multiple_people_interleaved(self):
        body = (
            '<at id="0">Paresh Mewada</at> '
            '<at id="1">Josh Xu</at> '
            '<at id="0">Paresh Mewada</at> '
            '<at id="1">Josh Xu</at>'
        )
        mentions = [
            _make_mention(0, "Paresh Mewada", PARESH_ID),
            _make_mention(1, "Josh Xu", JOSH_ID),
        ]
        new_body, new_mentions = reindex_mentions(body, mentions)

        ids = _extract_at_ids(new_body)
        assert ids == [0, 1, 2, 3]
        assert len(new_mentions) == 4
        assert all(ids[i] < ids[i + 1] for i in range(len(ids) - 1)), "Ids must be strictly increasing"


# === Mention array matches <at> tags ===

class TestMentionArrayConsistency:
    def test_mention_count_equals_at_tag_count(self):
        body = (
            '<at id="0">A</at> <at id="1">B</at> '
            '<at id="0">A</at> <at id="2">C</at>'
        )
        mentions = [
            _make_mention(0, "A", PARESH_ID),
            _make_mention(1, "B", JOSH_ID),
            _make_mention(2, "C", MAURICIO_ID),
        ]
        new_body, new_mentions = reindex_mentions(body, mentions)

        at_count = _count_at_tags(new_body)
        assert at_count == len(new_mentions), (
            f"<at> tags ({at_count}) != mentions array ({len(new_mentions)})"
        )

    def test_each_mention_id_appears_exactly_once_in_body(self):
        body = '<at id="0">X</at> <at id="0">X</at> <at id="1">Y</at>'
        mentions = [
            _make_mention(0, "X", PARESH_ID),
            _make_mention(1, "Y", JOSH_ID),
        ]
        new_body, new_mentions = reindex_mentions(body, mentions)

        body_ids = _extract_at_ids(new_body)
        mention_ids = [m["id"] for m in new_mentions]
        assert body_ids == mention_ids, (
            f"Body ids {body_ids} != mention ids {mention_ids}"
        )

    def test_user_id_preserved_for_duplicates(self):
        body = '<at id="0">Paresh Mewada</at> <at id="0">Paresh Mewada</at>'
        mentions = [_make_mention(0, "Paresh Mewada", PARESH_ID)]
        _, new_mentions = reindex_mentions(body, mentions)

        for m in new_mentions:
            uid = m["mentioned"]["user"]["id"]
            assert uid == PARESH_ID, f"Expected {PARESH_ID}, got {uid}"


# === Edge cases ===

class TestEdgeCases:
    def test_no_mentions(self):
        body = "<p>No mentions here</p>"
        new_body, new_mentions = reindex_mentions(body, [])
        assert new_body == body
        assert new_mentions == []

    def test_single_mention(self):
        body = '<at id="0">Josh Xu</at>'
        mentions = [_make_mention(0, "Josh Xu", JOSH_ID)]
        new_body, new_mentions = reindex_mentions(body, mentions)
        assert _count_at_tags(new_body) == 1
        assert len(new_mentions) == 1
        assert new_mentions[0]["id"] == 0

    def test_non_sequential_original_ids(self):
        """Original ids might be 5, 8 — output should always be 0, 1, 2..."""
        body = '<at id="5">A</at> <at id="8">B</at> <at id="5">A</at>'
        mentions = [
            _make_mention(5, "A", PARESH_ID),
            _make_mention(8, "B", JOSH_ID),
        ]
        new_body, new_mentions = reindex_mentions(body, mentions)

        ids = _extract_at_ids(new_body)
        assert ids == [0, 1, 2], f"Expected [0, 1, 2], got {ids}"


# === build_payload integration ===

class TestBuildPayload:
    def test_full_payload_structure(self):
        body = '<at id="0">Paresh Mewada</at> <at id="0">Paresh Mewada</at> CC: <at id="1">Josh Xu</at>'
        mentions = [
            _make_mention(0, "Paresh Mewada", PARESH_ID),
            _make_mention(1, "Josh Xu", JOSH_ID),
        ]
        payload = build_payload(body, mentions, subject="Test")

        assert payload["subject"] == "Test"
        assert payload["body"]["contentType"] == "html"
        assert len(payload["mentions"]) == 3
        # Verify JSON-serializable
        json.dumps(payload)

    def test_real_world_scale(self):
        """Simulate today's hygiene report: 36 <at> tags across 9 people."""
        people = [
            ("Paresh Mewada", PARESH_ID),
            ("Mauricio Juanes Laviada", MAURICIO_ID),
            ("Josh Xu", JOSH_ID),
        ]
        # Build body with 12 mentions (4 per person, reusing same id per person)
        rows = []
        orig_mentions = []
        for i, (name, uid) in enumerate(people):
            orig_mentions.append(_make_mention(i, name, uid))
            for _ in range(4):
                rows.append(f'<tr><td><at id="{i}">{name}</at></td></tr>')

        body = "<table>" + "".join(rows) + "</table>"
        payload = build_payload(body, orig_mentions)

        assert len(payload["mentions"]) == 12, f"Expected 12 mentions, got {len(payload['mentions'])}"
        ids = [m["id"] for m in payload["mentions"]]
        assert ids == list(range(12)), "Ids must be 0..11 sequential"
        assert len(set(ids)) == 12, "All ids must be unique"

        # Verify each person's AAD id is correct in all their mentions
        for m in payload["mentions"]:
            name = m["mentionText"]
            expected_uid = next(uid for n, uid in people if n == name)
            assert m["mentioned"]["user"]["id"] == expected_uid


if __name__ == "__main__":
    import pytest
    sys.exit(pytest.main([__file__, "-v"]))
