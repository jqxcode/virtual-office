"""Build Teams Graph API payload with per-occurrence @mentions.

Given an HTML body containing <at id="N">Name</at> tags and an original
mentions array (Graph API format), re-index all <at> tags so each occurrence
gets its own incrementing id, and build a matching mentions array.

Usage as library:
    from build_teams_mentions import reindex_mentions

Usage as CLI:
    python build-teams-mentions.py --payload input.json --output output.json
"""
from __future__ import annotations

import json
import re
import sys
from typing import Dict, List, Tuple


def reindex_mentions(
    body_html: str,
    original_mentions: List[Dict],
) -> Tuple[str, List[Dict]]:
    """Re-index <at id="N"> tags so each occurrence gets a unique id.

    Args:
        body_html: HTML string with <at id="N">Name</at> tags.
        original_mentions: Graph API mentions array mapping old ids to user info.

    Returns:
        (new_body_html, new_mentions_array) where every <at> has a unique id
        and new_mentions_array has one entry per <at> tag.
    """
    id_to_user: Dict[int, Dict] = {}
    for m in original_mentions:
        user = m.get("mentioned", {}).get("user", {})
        id_to_user[m["id"]] = {
            "id": user.get("id", ""),
            "displayName": user.get("displayName", ""),
            "userIdentityType": user.get("userIdentityType", "aadUser"),
        }

    new_mentions: List[Dict] = []
    counter = 0

    def _replace(match: re.Match) -> str:
        nonlocal counter
        old_id = int(match.group(1))
        name = match.group(2)
        new_id = counter
        counter += 1

        user = id_to_user.get(old_id, {
            "id": "",
            "displayName": name,
            "userIdentityType": "aadUser",
        })

        new_mentions.append({
            "id": new_id,
            "mentionText": name,
            "mentioned": {"user": dict(user)},
        })
        return f'<at id="{new_id}">{name}</at>'

    new_body = re.sub(r'<at id="(\d+)">([^<]+)</at>', _replace, body_html)
    return new_body, new_mentions


def build_payload(
    body_html: str,
    mentions: List[Dict],
    subject: str = "",
) -> Dict:
    """Build a complete Graph API chatMessage payload."""
    new_body, new_mentions = reindex_mentions(body_html, mentions)
    payload: Dict = {
        "body": {
            "contentType": "html",
            "content": new_body,
        },
        "mentions": new_mentions,
    }
    if subject:
        payload["subject"] = subject
    return payload


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser()
    parser.add_argument("--payload", required=True, help="Input JSON payload file")
    parser.add_argument("--output", required=True, help="Output JSON payload file")
    args = parser.parse_args()

    with open(args.payload, encoding="utf-8") as f:
        data = json.load(f)

    result = build_payload(
        body_html=data["body"]["content"],
        mentions=data.get("mentions", []),
        subject=data.get("subject", ""),
    )

    with open(args.output, "w", encoding="utf-8") as f:
        json.dump(result, f, indent=2, ensure_ascii=False)

    at_count = len(result["mentions"])
    print(f"Wrote {args.output}: {at_count} mentions", file=sys.stderr)
