"""Post hygiene summary to Teams with proper @mentions.

Reads poster-hygiene-teams.json, re-indexes mentions to ensure unique
incrementing IDs, posts via Python requests (only method that preserves
mentions correctly), saves response.
"""
from __future__ import annotations
import json
import re
import subprocess
import sys

sys.stdout.reconfigure(encoding="utf-8")

PAYLOAD_IN = "Q:/src/tmp/poster-hygiene-teams.json"
PAYLOAD_OUT = "Q:/src/tmp/poster-hygiene-teams-final.json"
RESPONSE_OUT = "Q:/src/tmp/poster-hygiene-teams-response.json"
TEAM_ID = "31ee74d6-0a8f-41a6-b0da-c4d9e3a1db3b"
CHANNEL_ID = "19:183d481e40af45d09aac7322433fc7ab@thread.tacv2"


def get_token() -> str:
    return subprocess.check_output([
        "powershell", "-NoProfile", "-Command",
        "az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv"
    ]).decode().strip()


def reindex_mentions(payload: dict) -> dict:
    """Ensure every <at id="N"> in body has a matching mention entry with unique incrementing ID."""
    body = payload.get("body", {}).get("content", "")
    mentions = payload.get("mentions", [])

    # Build lookup: old_id -> mention data
    mention_map = {str(m["id"]): m for m in mentions}

    # Find all <at id="N"> tags in order
    at_tags = re.findall(r'<at id="(\d+)">(.*?)</at>', body)

    new_mentions = []
    new_body = body

    for new_id, (old_id, display_name) in enumerate(at_tags):
        # Replace this specific occurrence (first match only)
        old_tag = f'<at id="{old_id}">{display_name}</at>'
        new_tag = f'<at id="{new_id}">{display_name}</at>'
        new_body = new_body.replace(old_tag, new_tag, 1)

        # Find the mention data for this old_id
        if old_id in mention_map:
            m = json.loads(json.dumps(mention_map[old_id]))  # deep copy
            m["id"] = new_id
            new_mentions.append(m)
        else:
            print(f"WARNING: no mention entry for at id={old_id} ({display_name})")

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
