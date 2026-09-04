"""Post hygiene summary to Teams with proper @mentions.

Reads mPoster-hygiene-teams.json, re-indexes mentions to ensure unique
incrementing IDs, posts via Python requests (only method that preserves
mentions correctly), saves response.
"""
from __future__ import annotations
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from zoneinfo import ZoneInfo

sys.stdout.reconfigure(encoding="utf-8")

REPO_ROOT = Path(__file__).resolve().parent.parent
SRC_ROOT = Path(os.environ.get("SRC_ROOT", REPO_ROOT.parent.parent))
PAYLOAD_IN = SRC_ROOT / "tmp" / "mPoster-hygiene-teams.json"
PAYLOAD_OUT = SRC_ROOT / "tmp" / "mPoster-hygiene-teams-final.json"
RESPONSE_OUT = SRC_ROOT / "tmp" / "mPoster-hygiene-teams-response.json"
AUDIT_DIR = REPO_ROOT / "output" / "audit"
TEAM_ID = "31ee74d6-0a8f-41a6-b0da-c4d9e3a1db3b"
CHANNEL_ID = "19:183d481e40af45d09aac7322433fc7ab@thread.tacv2"
CHANNEL_NAME = "Meeting US (PRODUCTION)"
AGENT_NAME = "mPoster"
JOB_NAME = "hygiene-teams-summary"
SYSTEM_VERSION = "0.4.0"
# Teams renders @mentions reliably only up to ~this many per channel message. Observed:
# 29 rendered fine (2026-07-02); 68 did NOT (2026-07-23, one owner repeated 35x). At or below
# the cap we tag EVERY name occurrence (per EM request: "every name should be tagged"); above
# it we dedupe to one @mention per unique user so the message still renders and notifies.
MAX_RENDER_MENTIONS = 30
# NOTE: default is now to tag EVERY name occurrence (dedupe=False) per the EM's explicit
# requirement "every row with a name must be a real @mention" -- which matches the template's
# own instruction. Dedupe remains available (dedupe=True / "auto") as a fallback. The 2026-07-23
# non-render was most likely the message SIZE (that body was ~48KB: 68 rows incl. 42 stale
# items), not the mention count -- today's report is ~24KB and well within limits.
# The standing CC recipient (Josh Xu) is always tagged on the CC line (see reindex_mentions).
CC_USER_ID = "90b98fe6-a80b-46e1-9209-b5ebcdf6da6b"


def get_token() -> str:
    return subprocess.check_output([
        "powershell", "-NoProfile", "-Command",
        "az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv"
    ]).decode().strip()


def append_audit(payload: dict, status_code: int) -> None:
    now = datetime.now(ZoneInfo("America/Los_Angeles"))
    mentions = [
        item.get("mentionText", "")
        for item in payload.get("mentions", [])
        if item.get("mentionText")
    ]
    entry = {
        "action": "teams_post",
        "agent": AGENT_NAME,
        "job": JOB_NAME,
        "run_id": now.strftime("%Y%m%d-%H%M%S"),
        "timestamp": now.isoformat(),
        "system_version": SYSTEM_VERSION,
        "details": {
            "channel_id": CHANNEL_ID,
            "channel_name": CHANNEL_NAME,
            "message_subject": payload.get("subject", ""),
            "mentions": mentions,
            "http_status": status_code,
        },
    }
    AUDIT_DIR.mkdir(parents=True, exist_ok=True)
    audit_path = AUDIT_DIR / f"{now:%Y-%m}.jsonl"
    with audit_path.open("a", encoding="utf-8", newline="\n") as audit_file:
        audit_file.write(json.dumps(entry, ensure_ascii=True) + "\n")


def reindex_mentions(payload: dict, dedupe=False) -> dict:
    """Re-index <at id="N"> tags to unique incrementing IDs matching the mentions array.

    dedupe:
      False (default) -> tag EVERY name occurrence (every row's owner is a real @mention),
          per the EM requirement and the template's own instruction.
      True  -> dedupe to one @mention per unique user (later duplicates -> plain text);
          the CC user's tag is kept on their LAST occurrence (the "CC: ..." line).
      "auto" -> dedupe only if the message would exceed MAX_RENDER_MENTIONS tags.

    Either way the mentions array stays 1:1 with the <at> tags (unique incrementing ids).
    """
    body = payload.get("body", {}).get("content", "")
    mentions = payload.get("mentions", [])
    mention_map = {str(m["id"]): m for m in mentions}

    def _user_id(old_id):
        m = mention_map.get(old_id)
        return ((m or {}).get("mentioned") or {}).get("user", {}).get("id")

    tags = re.findall(r'<at id="(\d+)">(.*?)</at>', body)
    if dedupe == "auto":
        dedupe = len(tags) > MAX_RENDER_MENTIONS
        print(f"reindex_mentions: {len(tags)} raw tags, dedupe={dedupe} "
              f"(cap={MAX_RENDER_MENTIONS})")

    # When deduping, keep exactly one tag per unique user. For the CC user keep their LAST
    # occurrence (the "CC: ..." line); for everyone else keep their FIRST occurrence.
    keep_idx: dict = {}   # occurrence index -> kept as a tag
    if dedupe:
        first_idx: dict = {}
        last_idx: dict = {}
        for i, (oid, _name) in enumerate(tags):
            u = _user_id(oid)
            if u is None:
                continue
            first_idx.setdefault(u, i)
            last_idx[u] = i
        for u, fi in first_idx.items():
            keep_idx[last_idx[u] if u == CC_USER_ID else fi] = True

    occ = {"i": 0}
    counter = {"n": 0}
    new_mentions: list = []

    def _repl(match):
        idx = occ["i"]
        occ["i"] += 1
        old_id, display_name = match.group(1), match.group(2)
        m = mention_map.get(old_id)
        uid = _user_id(old_id)
        # When deduping, occurrences not chosen as the kept tag become plain text.
        if dedupe and uid is not None and not keep_idx.get(idx):
            return display_name
        new_id = counter["n"]
        counter["n"] += 1
        if m is not None:
            mm = json.loads(json.dumps(m))  # deep copy
            mm["id"] = new_id
            new_mentions.append(mm)
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
    append_audit(payload, resp.status_code)

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
