"""
Teams @mention scanner for Virtual Office.

Scans configured Teams channels AND unread chats for messages mentioning
Josh Xu, detects questions, classifies technical vs non-technical,
and outputs structured JSON for the researcher agent to process.

Usage:
    python scan-mentions.py                  # scan channels + unread chats
    python scan-mentions.py --dry-run        # scan but don't update state
    python scan-mentions.py --verbose        # detailed output
    python scan-mentions.py --channel <id>   # scan specific channel only
    python scan-mentions.py --channels-only  # skip chat scanning
    python scan-mentions.py --chats-only     # skip channel scanning
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
import threading
import queue
import time
from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List, Optional

sys.stdout.reconfigure(encoding="utf-8")

VO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG_PATH = os.path.join(VO_ROOT, "config", "mention-scanner.json")


def load_config() -> Dict[str, Any]:
    with open(CONFIG_PATH, encoding="utf-8") as f:
        return json.load(f)


def load_state(state_path: str) -> Dict[str, Any]:
    full_path = os.path.join(VO_ROOT, state_path)
    if os.path.exists(full_path):
        with open(full_path, encoding="utf-8") as f:
            return json.load(f)
    return {"channels": {}, "processedMessageIds": []}


def save_state(state_path: str, state: Dict[str, Any]) -> None:
    full_path = os.path.join(VO_ROOT, state_path)
    tmp_path = full_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        json.dump(state, f, indent=2, ensure_ascii=False)
    os.replace(tmp_path, full_path)


class TeamsMcpClient:
    """Communicate with Agency Teams MCP via subprocess."""

    def __init__(self, verbose: bool = False):
        self.verbose = verbose
        self.exe = r"C:\Users\qitxu\AppData\Roaming\agency\CurrentVersion\agency.exe"
        self.proc: Optional[subprocess.Popen] = None
        self.stdout_q: queue.Queue = queue.Queue()
        self._req_id = 10

    def connect(self) -> bool:
        if not os.path.exists(self.exe):
            print(f"ERROR: Agency exe not found at {self.exe}", file=sys.stderr)
            return False

        self.proc = subprocess.Popen(
            [self.exe, "mcp", "teams", "--transport", "stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
        )

        # Thread-based IO for Windows pipes
        threading.Thread(
            target=lambda: [
                self.stdout_q.put(line.decode(errors="replace").strip())
                for line in self.proc.stdout
                if line.decode(errors="replace").strip()
            ],
            daemon=True,
        ).start()
        threading.Thread(
            target=lambda: [None for _ in self.proc.stderr], daemon=True
        ).start()

        # Initialize (wait for Entra auth)
        self._send(
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {
                    "protocolVersion": "2024-11-05",
                    "capabilities": {},
                    "clientInfo": {"name": "mention-scanner", "version": "1.0"},
                },
            }
        )
        time.sleep(8)
        self._drain(3)
        self._send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        time.sleep(2)
        self._drain(2)

        if self.verbose:
            print("Teams MCP connected")
        return True

    def _send(self, obj: Dict[str, Any]) -> None:
        data = (json.dumps(obj) + "\n").encode()
        self.proc.stdin.write(data)
        self.proc.stdin.flush()

    def _recv(self, timeout: int = 25) -> Optional[str]:
        try:
            return self.stdout_q.get(timeout=timeout)
        except Exception:
            return None

    def _drain(self, timeout: int = 3) -> List[str]:
        items: List[str] = []
        while True:
            try:
                items.append(self.stdout_q.get(timeout=timeout))
            except Exception:
                break
        return items

    def call_tool(self, tool_name: str, args: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        self._req_id += 1
        req = {
            "jsonrpc": "2.0",
            "id": self._req_id,
            "method": "tools/call",
            "params": {"name": tool_name, "arguments": args},
        }
        self._send(req)
        # Collect response lines
        for _ in range(30):
            line = self._recv(timeout=15)
            if line is None:
                break
            try:
                resp = json.loads(line)
                if resp.get("id") == self._req_id:
                    return resp
            except json.JSONDecodeError:
                continue
        return None

    def _parse_tool_response(self, resp: Optional[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
        """Extract parsed JSON from MCP tool response."""
        if not resp:
            return None
        try:
            result = resp.get("result", {})
            content = result.get("content", [])
            if content and isinstance(content, list):
                text = content[0].get("text", "")
                return json.loads(text)
        except (json.JSONDecodeError, KeyError, IndexError):
            pass
        return None

    def list_channel_messages(
        self, team_id: str, channel_id: str, top: int = 50
    ) -> List[Dict[str, Any]]:
        resp = self.call_tool(
            "ListChannelMessages",
            {"teamId": team_id, "channelId": channel_id, "top": top},
        )
        data = self._parse_tool_response(resp)
        if data:
            return data.get("messages", data.get("value", []))
        return []

    def list_chats(self, fetch_all: bool = False) -> List[Dict[str, Any]]:
        """List recent chats with hasUnreadMessages flag."""
        args: Dict[str, Any] = {}
        if fetch_all:
            args["fetchAllPages"] = True
        resp = self.call_tool("ListChats", args)
        data = self._parse_tool_response(resp)
        if data:
            return data.get("chats", data.get("value", []))
        return []

    def list_chat_messages(
        self, chat_id: str, top: int = 20
    ) -> List[Dict[str, Any]]:
        """List messages in a specific chat."""
        resp = self.call_tool(
            "ListChatMessages", {"chatId": chat_id, "top": top}
        )
        data = self._parse_tool_response(resp)
        if data:
            return data.get("messages", data.get("value", []))
        return []

    def disconnect(self) -> None:
        if self.proc:
            try:
                self.proc.terminate()
            except Exception:
                pass


def get_sender_name(msg: Dict[str, Any]) -> str:
    """Extract sender display name from a Teams message, handling various formats."""
    from_obj = msg.get("from")
    if not from_obj or not isinstance(from_obj, dict):
        return "Unknown"
    # Try user.displayName first
    user = from_obj.get("user")
    if user and isinstance(user, dict):
        name = user.get("displayName", "")
        if name:
            return name
    # Try application.displayName (bots, connectors)
    app = from_obj.get("application")
    if app and isinstance(app, dict):
        name = app.get("displayName", "")
        if name:
            return name
    # Try device
    device = from_obj.get("device")
    if device and isinstance(device, dict):
        name = device.get("displayName", "")
        if name:
            return name
    return "Unknown"


def strip_html(html: str) -> str:
    """Remove HTML tags, keep text content."""
    text = re.sub(r"<[^>]+>", " ", html)
    text = re.sub(r"&nbsp;", " ", text)
    text = re.sub(r"&amp;", "&", text)
    text = re.sub(r"&lt;", "<", text)
    text = re.sub(r"&gt;", ">", text)
    text = re.sub(r"&#\d+;", "", text)
    return re.sub(r"\s+", " ", text).strip()


def mentions_me(body_html: str, body_text: str, config: Dict[str, Any]) -> bool:
    """Check if message mentions Josh Xu via @mention tag or text."""
    scanner_cfg = config["scanner"]
    name = scanner_cfg["myDisplayName"]
    aliases = scanner_cfg["myAliases"]

    # Check <at> tags in HTML (Teams @mention format)
    at_mentions = re.findall(r"<at[^>]*>([^<]+)</at>", body_html, re.IGNORECASE)
    for mention in at_mentions:
        mention_lower = mention.strip().lower()
        if name.lower() in mention_lower:
            return True
        for alias in aliases:
            if alias.lower() == mention_lower:
                return True

    # Also check raw text for @Name patterns
    text_lower = body_text.lower()
    for alias in aliases + [name]:
        if f"@{alias.lower()}" in text_lower:
            return True

    return False


def is_question(text: str, config: Dict[str, Any]) -> bool:
    """Detect if message contains a question."""
    patterns = config["classification"]["questionPatterns"]
    for pattern in patterns:
        if re.search(pattern, text):
            return True
    return False


def is_action_request(text: str, config: Dict[str, Any]) -> bool:
    """Detect if message requests an action from Josh."""
    patterns = config["classification"].get("actionRequestPatterns", [])
    for pattern in patterns:
        if re.search(pattern, text):
            return True
    return False


def classify_technical(text: str, config: Dict[str, Any]) -> Dict[str, Any]:
    """Classify whether the question is technical and extract matched keywords."""
    keywords = config["classification"]["technicalKeywords"]
    text_lower = text.lower()
    matched: List[str] = []
    for kw in keywords:
        if kw.lower() in text_lower:
            matched.append(kw)

    is_tech = len(matched) >= 1
    return {"isTechnical": is_tech, "matchedKeywords": matched}


def check_high_priority(text: str, config: Dict[str, Any]) -> bool:
    """Check if message contains high-priority indicators."""
    for pattern in config["classification"]["highPriorityPatterns"]:
        if re.search(pattern, text):
            return True
    return False


def message_id_hash(channel_id: str, msg_id: str) -> str:
    """Create a stable hash for dedup."""
    return hashlib.sha256(f"{channel_id}:{msg_id}".encode()).hexdigest()[:16]


def parse_timestamp(ts: str) -> Optional[datetime]:
    """Parse ISO timestamp from Teams API."""
    if not ts:
        return None
    # Handle various formats
    ts = ts.replace("Z", "+00:00")
    try:
        return datetime.fromisoformat(ts)
    except ValueError:
        return None


def scan_channels(
    config: Dict[str, Any],
    state: Dict[str, Any],
    mcp_client: Optional[TeamsMcpClient] = None,
    channel_filter: Optional[str] = None,
    dry_run: bool = False,
    verbose: bool = False,
) -> List[Dict[str, Any]]:
    """Scan channels and return detected mentions with questions."""
    scanner_cfg = config["scanner"]
    lookback = timedelta(hours=scanner_cfg["lookbackHours"])
    cutoff = datetime.now(timezone.utc) - lookback
    processed_ids = set(state.get("processedMessageIds", []))
    results: List[Dict[str, Any]] = []

    channels = config["channels"]
    if channel_filter:
        channels = [c for c in channels if c["id"] == channel_filter]

    use_mcp = mcp_client is not None

    for ch in channels:
        ch_id = ch["id"]
        if verbose:
            print(f"Scanning {ch['teamName']} / {ch['channelName']}...")

        messages: List[Dict[str, Any]] = []
        if use_mcp:
            messages = mcp_client.list_channel_messages(
                ch["teamId"],
                ch["channelId"],
                top=scanner_cfg["maxMessagesPerChannel"],
            )
        else:
            if verbose:
                print(f"  (no MCP client, skipping)")
            continue

        if verbose:
            print(f"  Found {len(messages)} messages")

        for msg in messages:
            msg_id = msg.get("id", "")
            dedup_hash = message_id_hash(ch["channelId"], msg_id)

            if dedup_hash in processed_ids:
                continue

            # Check timestamp
            created = msg.get("createdDateTime", "")
            msg_time = parse_timestamp(created)
            if msg_time and msg_time < cutoff:
                continue

            # Get body
            body = msg.get("body", {})
            body_html = body.get("content", "") if isinstance(body, dict) else str(body)
            body_text = strip_html(body_html)

            if not body_text:
                continue

            # Check if mentions me
            if not mentions_me(body_html, body_text, config):
                continue

            # Classify the mention
            has_question = is_question(body_text, config)
            has_action = is_action_request(body_text, config)
            classification = classify_technical(body_text, config)
            is_high_pri = check_high_priority(body_text, config)
            sender_name = get_sender_name(msg)

            # Determine tier: actionable (question or action request) vs informational
            if has_question or has_action:
                tier = "actionable"
            else:
                tier = "informational"

            if verbose:
                if tier == "actionable":
                    tech_label = "TECHNICAL" if classification["isTechnical"] else "non-technical"
                    q_or_a = "question" if has_question else "action-request"
                    print(f"  ACTIONABLE ({q_or_a}) [{tech_label}] from {sender_name}: {body_text[:80]}...")
                else:
                    print(f"  Mention (informational) from {sender_name}: {body_text[:80]}...")

            processed_ids.add(dedup_hash)

            result = {
                "dedupHash": dedup_hash,
                "messageId": msg_id,
                "channel": {
                    "id": ch_id,
                    "teamName": ch["teamName"],
                    "channelName": ch["channelName"],
                    "priority": ch["priority"],
                },
                "sender": sender_name,
                "timestamp": created,
                "bodyText": body_text,
                "bodyHtml": body_html,
                "tier": tier,
                "isQuestion": has_question,
                "isActionRequest": has_action,
                "isTechnical": classification["isTechnical"],
                "matchedKeywords": classification["matchedKeywords"],
                "isHighPriority": is_high_pri,
            }
            results.append(result)

    # Update state
    if not dry_run:
        state["processedMessageIds"] = list(processed_ids)[-500:]  # keep last 500
        state["lastScan"] = datetime.now(timezone.utc).isoformat()
        save_state(scanner_cfg["stateFile"], state)

    return results


def scan_chats(
    config: Dict[str, Any],
    state: Dict[str, Any],
    mcp_client: Optional[TeamsMcpClient] = None,
    dry_run: bool = False,
    verbose: bool = False,
) -> List[Dict[str, Any]]:
    """Scan unread chats for mentions with questions."""
    if mcp_client is None:
        if verbose:
            print("Chat scan: no MCP client, skipping")
        return []

    scanner_cfg = config["scanner"]
    lookback = timedelta(hours=scanner_cfg["lookbackHours"])
    cutoff = datetime.now(timezone.utc) - lookback
    processed_ids = set(state.get("processedMessageIds", []))
    results: List[Dict[str, Any]] = []

    if verbose:
        print("\n--- Scanning unread chats ---")

    chats = mcp_client.list_chats(fetch_all=False)
    if verbose:
        print(f"Found {len(chats)} recent chats")

    unread_chats = [c for c in chats if c.get("hasUnreadMessages", False)]
    if verbose:
        print(f"  Unread: {unread_chats.__len__()}")

    for chat in unread_chats:
        chat_id = chat.get("id", "")
        chat_topic = chat.get("topic", "") or "(1:1 chat)"
        chat_type = chat.get("chatType", "unknown")

        # Check last message preview timestamp
        preview = chat.get("lastMessagePreview", {})
        preview_ts = preview.get("createdDateTime", "")
        preview_time = parse_timestamp(preview_ts)
        if preview_time and preview_time < cutoff:
            continue

        if verbose:
            print(f"  Scanning chat: {chat_topic} [{chat_type}]")

        messages = mcp_client.list_chat_messages(chat_id, top=20)
        if verbose:
            print(f"    {len(messages)} messages")

        for msg in messages:
            msg_id = msg.get("id", "")
            dedup_hash = message_id_hash(chat_id, msg_id)

            if dedup_hash in processed_ids:
                continue

            created = msg.get("createdDateTime", "")
            msg_time = parse_timestamp(created)
            if msg_time and msg_time < cutoff:
                continue

            body = msg.get("body", {})
            body_html = body.get("content", "") if isinstance(body, dict) else str(body)
            body_text = strip_html(body_html)

            if not body_text:
                continue

            # For chats: check if mentions me OR if it's a direct question to me
            has_mention = mentions_me(body_html, body_text, config)
            is_direct_chat = chat_type == "oneOnOne"

            if not has_mention and not is_direct_chat:
                continue

            # Don't process my own messages
            sender_name = get_sender_name(msg)
            if sender_name == config["scanner"]["myDisplayName"]:
                processed_ids.add(dedup_hash)
                continue

            # Classify
            has_question = is_question(body_text, config)
            has_action = is_action_request(body_text, config)
            classification = classify_technical(body_text, config)
            is_high_pri = check_high_priority(body_text, config)

            if has_question or has_action:
                tier = "actionable"
            else:
                tier = "informational"

            if verbose:
                if tier == "actionable":
                    q_or_a = "question" if has_question else "action-request"
                    print(f"    ACTIONABLE ({q_or_a}) from {sender_name}: {body_text[:80]}...")
                else:
                    print(f"    Mention (informational) from {sender_name}: {body_text[:80]}...")

            processed_ids.add(dedup_hash)

            result = {
                "dedupHash": dedup_hash,
                "messageId": msg_id,
                "channel": {
                    "id": f"chat:{chat_id[:20]}",
                    "teamName": "Chat",
                    "channelName": chat_topic,
                    "priority": "high" if is_high_pri else "medium",
                    "chatType": chat_type,
                    "chatId": chat_id,
                },
                "sender": sender_name,
                "timestamp": created,
                "bodyText": body_text,
                "bodyHtml": body_html,
                "tier": tier,
                "isQuestion": has_question,
                "isActionRequest": has_action,
                "isTechnical": classification["isTechnical"],
                "matchedKeywords": classification["matchedKeywords"],
                "isHighPriority": is_high_pri,
                "isUnread": True,
                "source": "chat",
            }
            results.append(result)

    # Update state
    if not dry_run:
        state["processedMessageIds"] = list(processed_ids)[-500:]
        state["lastScan"] = datetime.now(timezone.utc).isoformat()
        save_state(scanner_cfg["stateFile"], state)

    return results



# NOTE on read state:
# - Channel messages: read state is CLIENT-SIDE only (Teams app tracks it).
#   No Graph API to mark channels as read. Use Teams app: right-click > "Mark as read".
# - Chat messages: Graph API supports POST /me/chats/{id}/markChatReadForUser
#   but this is a delegated-only permission and changes the user's unread state.
#   We intentionally do NOT mark chats as read -- the scanner should be invisible.
#   The hasUnreadMessages flag on ListChats is used for filtering, not mutation.


def save_draft(
    mention: Dict[str, Any], output_dir: str
) -> str:
    """Save a draft answer file for a detected mention."""
    full_dir = os.path.join(VO_ROOT, output_dir)
    os.makedirs(full_dir, exist_ok=True)

    ts = mention["timestamp"][:10].replace("-", "")
    ch_slug = re.sub(r"[^a-zA-Z0-9]", "-", mention["channel"]["channelName"]).lower()
    topic_words = re.sub(r"[^a-zA-Z0-9\s]", "", mention["bodyText"])[:60].split()
    topic_slug = "-".join(topic_words[:5]).lower() if topic_words else "question"
    filename = f"{ts}-{ch_slug}-{topic_slug}.md"
    filepath = os.path.join(full_dir, filename)

    # Don't overwrite existing drafts
    if os.path.exists(filepath):
        return filepath

    priority_badge = ""
    if mention["isHighPriority"]:
        priority_badge = " **[HIGH PRIORITY]**"
    tech_badge = "Technical" if mention["isTechnical"] else "Non-technical"
    source_type = mention.get("source", "channel")
    unread_badge = " (UNREAD)" if mention.get("isUnread") else ""
    location = f"{mention['channel']['teamName']} / {mention['channel']['channelName']}"

    content = f"""# Draft Answer{priority_badge}

## Question Details
- **From**: {mention['sender']}
- **Source**: {source_type.upper()}{unread_badge}
- **Location**: {location}
- **Timestamp**: {mention['timestamp']}
- **Classification**: {tech_badge}
- **Keywords**: {', '.join(mention['matchedKeywords']) if mention['matchedKeywords'] else 'none'}
- **Status**: PENDING RESEARCH

## Original Message
{mention['bodyText']}

## Researched Answer
<!-- TODO: Agent will fill this in with research from:
     - TMP codebase (ADO code search)
     - Kusto telemetry (Scenario_CMD_View)
     - ADO work items (bug context, feature specs)
     - Architecture memory (project_media_stack.md, project_native_shell_repo.md)
-->

_Research pending..._

## Sources
<!-- Links to code, Kusto queries, ADO items, docs -->

## Confidence
<!-- high / medium / low -->

## Draft Reply
<!-- ASCII-only text suitable for Teams posting -->

---
_Generated by teams-mention-auto-responder | {datetime.now(timezone.utc).strftime('%Y-%m-%d %H:%M UTC')}_
"""
    with open(filepath, "w", encoding="utf-8") as f:
        f.write(content)
    return filepath


def main() -> None:
    parser = argparse.ArgumentParser(description="Scan Teams channels for @mentions")
    parser.add_argument("--dry-run", action="store_true", help="Don't update state")
    parser.add_argument("--verbose", action="store_true", help="Detailed output")
    parser.add_argument("--channel", type=str, help="Scan specific channel ID only")
    parser.add_argument("--channels-only", action="store_true", help="Skip chat scanning")
    parser.add_argument("--chats-only", action="store_true", help="Skip channel scanning")
    parser.add_argument(
        "--no-mcp",
        action="store_true",
        help="Skip MCP connection (for testing config/classification)",
    )
    parser.add_argument(
        "--output-json",
        action="store_true",
        help="Output results as JSON to stdout",
    )
    args = parser.parse_args()

    config = load_config()
    state = load_state(config["scanner"]["stateFile"])

    mcp_client: Optional[TeamsMcpClient] = None
    if not args.no_mcp:
        mcp_client = TeamsMcpClient(verbose=args.verbose)
        if not mcp_client.connect():
            print("Failed to connect to Teams MCP", file=sys.stderr)
            sys.exit(1)

    try:
        all_results: List[Dict[str, Any]] = []

        # Scan channels
        if not args.chats_only:
            channel_results = scan_channels(
                config=config,
                state=state,
                mcp_client=mcp_client,
                channel_filter=args.channel,
                dry_run=args.dry_run,
                verbose=args.verbose,
            )
            all_results.extend(channel_results)

        # Scan unread chats
        if not args.channels_only:
            chat_results = scan_chats(
                config=config,
                state=state,
                mcp_client=mcp_client,
                dry_run=args.dry_run,
                verbose=args.verbose,
            )
            all_results.extend(chat_results)

        # Save draft files for actionable technical mentions
        drafts: List[str] = []
        for mention in all_results:
            if mention.get("tier") == "actionable" and mention["isTechnical"]:
                draft_path = save_draft(mention, config["scanner"]["outputDir"])
                drafts.append(draft_path)
                if args.verbose:
                    print(f"  Draft saved: {draft_path}")

        # Summary
        total = len(all_results)
        actionable = [r for r in all_results if r.get("tier") == "actionable"]
        informational = [r for r in all_results if r.get("tier") == "informational"]
        high_pri = sum(1 for r in all_results if r.get("isHighPriority"))
        from_channels = sum(1 for r in all_results if r.get("source") != "chat")
        from_chats = sum(1 for r in all_results if r.get("source") == "chat")

        if args.output_json:
            output = {
                "scanTime": datetime.now(timezone.utc).isoformat(),
                "totalMentions": total,
                "actionable": len(actionable),
                "informational": len(informational),
                "fromChannels": from_channels,
                "fromChats": from_chats,
                "highPriority": high_pri,
                "mentions": all_results,
                "drafts": drafts,
            }
            print(json.dumps(output, indent=2, ensure_ascii=False))
        else:
            print(f"\nScan complete: {total} mentions found")
            print(f"  Actionable (questions + action requests): {len(actionable)}")
            print(f"  Informational: {len(informational)}")
            print(f"  High priority: {high_pri}")
            print(f"  From channels: {from_channels} | From chats: {from_chats}")
            print(f"  Draft files created: {len(drafts)}")
            if drafts:
                for d in drafts:
                    print(f"    {d}")

    finally:
        if mcp_client:
            mcp_client.disconnect()


if __name__ == "__main__":
    main()
