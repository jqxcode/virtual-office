"""Post hygiene summary to Teams with proper @mentions.

Reads mPoster-hygiene-teams.json, re-indexes mentions to ensure unique
incrementing IDs, posts via Python requests (only method that preserves
mentions correctly), saves response.
"""
from __future__ import annotations
import json
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

PAYLOAD_IN = "Q:/src/tmp/mPoster-hygiene-teams.json"
PAYLOAD_OUT = "Q:/src/tmp/mPoster-hygiene-teams-final.json"
RESPONSE_OUT = "Q:/src/tmp/mPoster-hygiene-teams-response.json"
TEAM_ID = "31ee74d6-0a8f-41a6-b0da-c4d9e3a1db3b"
CHANNEL_ID = "19:183d481e40af45d09aac7322433fc7ab@thread.tacv2"


def get_token() -> str:
    return subprocess.check_output([
        "powershell", "-NoProfile", "-Command",
        "az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv"
    ]).decode().strip()


def reindex_mentions(payload: dict, dedupe: bool = True) -> dict:
    """Re-index <at id="N"> tags to unique incrementing IDs matching the mentions array.

    When dedupe=True (default), each unique user is @mentioned only ONCE (the first
    occurrence in the body); later occurrences of the same user are converted to plain
    text. This keeps the total mention count at (unique owners + CC) instead of one per
    table row, staying well under Teams' practical per-message @mention limit (~20).
    Exceeding that limit is why the 2026-07-23 summary (68 mentions, e.g. one owner
    repeated 35x) rendered as plain text / did not notify. Everyone still gets exactly
    one working @mention and still appears (as text) in every row they own.
    """
    body = payload.get("body", {}).get("content", "")
    mentions = payload.get("mentions", [])
    mention_map = {str(m["id"]): m for m in mentions}

    new_mentions: list = []
    seen_user: dict = {}   # aad user id -> assigned new mention id
    counter = {"n": 0}

    def _user_id(m):
        return ((m or {}).get("mentioned") or {}).get("user", {}).get("id")

    def _repl(match):
        old_id, display_name = match.group(1), match.group(2)
        m = mention_map.get(old_id)
        uid = _user_id(m)
        # Duplicate mention of an already-mentioned user -> plain text.
        if dedupe and uid is not None and uid in seen_user:
            return display_name
        new_id = counter["n"]
        counter["n"] += 1
        if m is not None:
            mm = json.loads(json.dumps(m))  # deep copy
            mm["id"] = new_id
            new_mentions.append(mm)
            if uid is not None:
                seen_user[uid] = new_id
        else:
            print(f"WARNING: no mention entry for at id={old_id} ({display_name})")
        return f'<at id="{new_id}">{display_name}</at>'

    # Single left-to-right pass; replacement text is not re-scanned (collision-free).
    new_body = re.sub(r'<at id="(\d+)">(.*?)</at>', _repl, body)

    payload["body"]["content"] = new_body
    payload["mentions"] = new_mentions
    return payload


def main():
    # Load payload
    with open(PAYLOAD_IN) as f:
        payload = json.load(f)

    # Re-index
    payload = reindex_mentions(payload)

    # Save final payload
    with open(PAYLOAD_OUT, "w") as f:
        json.dump(payload, f, indent=2)

    at_count = len(re.findall(r'<at id="\d+">', payload["body"]["content"]))
    mention_count = len(payload.get("mentions", []))
    print(f"Payload: {at_count} at-tags, {mention_count} mentions")

    # Get token
    token = get_token()

    # Post via requests
    import requests
    url = f"https://graph.microsoft.com/v1.0/teams/{TEAM_ID}/channels/{CHANNEL_ID}/messages"
    resp = requests.post(
        url,
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
        json=payload,
    )

    print(f"HTTP {resp.status_code}")

    if resp.status_code == 201:
        result = resp.json()
        msg_id = result.get("id", "")
        print(f"Message ID: {msg_id}")

        # Save response
        with open(RESPONSE_OUT, "w") as f:
            json.dump(result, f, indent=2)

        # Verify mentions were stored
        stored_mentions = len(result.get("mentions", []))
        print(f"Stored mentions: {stored_mentions}")
        if stored_mentions == 0:
            print("ERROR: Graph API stored 0 mentions! Check payload format.")
    else:
        print(f"ERROR: {resp.text[:500]}")
        sys.exit(1)


if __name__ == "__main__":
    main()
