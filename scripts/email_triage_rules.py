"""Canonical rules shared by the MSFT email triage portal."""

from __future__ import annotations

import re


AUTOMATIC_REPLY_PREFIXES = (
    "automatic reply:",
    "auto reply:",
    "autoreply:",
    "out of office:",
)
MEETING_SUBJECT_PREFIXES = (
    "canceled:",
    "cancelled:",
    "meeting forward notification:",
)
TEAMS_JOIN_URL_MARKERS = (
    "teams.microsoft.com/meet/",
    "teams.microsoft.com/l/meetup-join/",
)
TEAMS_MEETING_MARKERS = (
    "meeting id:",
    "passcode:",
)
NDR_SUBJECT_PREFIX = "undeliverable:"
NDR_EVIDENCE_MARKERS = (
    "couldn't be delivered",
    "could not be delivered",
    "wasn't found",
    "was not found",
    "recipient unknown",
)


def clean_text(value: object) -> str:
    text = str(value or "")
    text = re.sub(r"[\u200b-\u200f\u202a-\u202e\u2060\ufeff]", "", text)
    return re.sub(r"\s+", " ", text).strip()


def normalize_subject(subject: object) -> str:
    normalized = clean_text(subject)
    previous = None
    while previous != normalized:
        previous = normalized
        normalized = re.sub(
            r"^\s*((re|fw|fwd)\s*:\s*|\[external\]\s*)",
            "",
            normalized,
            flags=re.I,
        )
    return normalized.strip() or "(无主题)"


def normalized_thread_key(subject: object) -> str:
    return normalize_subject(subject).casefold()


def _has_quoted_history_before(text: str, marker_position: int) -> bool:
    prefix = text[:marker_position]
    quote_markers = (
        "-----original message-----",
        "from:",
        "sent:",
        "wrote:",
    )
    if any(marker in prefix for marker in quote_markers):
        return True
    divider = prefix.find("________________________________")
    if divider < 0:
        return False
    meaningful_before_divider = re.sub(r"[\W_]+", "", prefix[:divider])
    return len(meaningful_before_divider) > 30


def is_plain_meeting_only(message: dict) -> bool:
    """Conservatively recognize malformed Teams meeting-only messages.

    All three Teams markers must occur together near the start of the preview.
    This intentionally does not match ordinary work mail that contains a meeting
    block only in quoted history. Long or heavily prefaced meeting templates may
    be missed and should be reviewed rather than auto-deleted.
    """

    preview = clean_text(message.get("bodyPreview")).casefold()
    join_positions = [
        position
        for marker in TEAMS_JOIN_URL_MARKERS
        if (position := preview.find(marker)) >= 0
    ]
    if not join_positions:
        return False
    positions = [
        min(join_positions),
        *(preview.find(marker) for marker in TEAMS_MEETING_MARKERS),
    ]
    if any(position < 0 for position in positions):
        return False
    first = min(positions)
    last = max(positions)
    if first > 400 or last > 1400 or last - first > 1100:
        return False
    if _has_quoted_history_before(preview, first):
        return False
    return len(preview[:first]) <= 280


def meeting_noise_reason(message: dict) -> str | None:
    """Return the canonical meeting-noise recoverable-delete reason, if any."""

    message_type = clean_text(message.get("@odata.type")).casefold()
    subject = clean_text(message.get("subject")).casefold()
    if "eventmessage" in message_type:
        return "eventMessage object"
    if subject.startswith(MEETING_SUBJECT_PREFIXES):
        return "meeting subject prefix"
    if subject.startswith(AUTOMATIC_REPLY_PREFIXES):
        return "automatic reply / OOF prefix"
    if is_plain_meeting_only(message):
        return "plain Teams meeting-only message"
    return None


def is_meeting_noise(message: dict) -> bool:
    return meeting_noise_reason(message) is not None


def _sender_identities(message: dict) -> list[tuple[str, str]]:
    identities = []
    for field in ("from", "sender"):
        address = (message.get(field) or {}).get("emailAddress") or {}
        identities.append(
            (
                clean_text(address.get("name")).casefold(),
                clean_text(address.get("address")).casefold(),
            )
        )
    return identities


def ndr_noise_reason(message: dict) -> str | None:
    """Recognize verified Microsoft Exchange NDR/bounce messages."""

    subject = clean_text(message.get("subject")).casefold()
    if not subject.startswith(NDR_SUBJECT_PREFIX):
        return None
    sender_matches = any(
        name == "microsoft outlook"
        or bool(
            re.fullmatch(
                r"microsoftexchange[^@]*@service\.microsoft\.com",
                address,
                flags=re.I,
            )
        )
        for name, address in _sender_identities(message)
    )
    if not sender_matches:
        return None
    body = message.get("body") or {}
    body_content = body.get("content") if isinstance(body, dict) else body
    evidence = " ".join(
        (
            clean_text(message.get("bodyPreview")),
            clean_text(body_content),
        )
    ).casefold()
    if not any(marker in evidence for marker in NDR_EVIDENCE_MARKERS):
        return None
    return "verified Microsoft Exchange NDR / bounce"


def global_noise_reason(message: dict) -> str | None:
    return ndr_noise_reason(message) or meeting_noise_reason(message)


def is_global_noise(message: dict) -> bool:
    return global_noise_reason(message) is not None


def global_noise_standard_for_prompt() -> str:
    return (
        "Use scripts/email_triage_rules.py::global_noise_reason as the canonical "
        "global-noise standard. "
        "Recoverably delete messages when @odata.type contains eventMessage "
        "(requests, updates, responses, cancellations), the subject starts "
        "Canceled:/Cancelled: or Meeting Forward Notification:, or the subject "
        "starts Automatic reply:/Auto reply:/Autoreply:/Out of Office:. Prefix "
        "classification wins over any legitimate underlying topic. Also delete a "
        "malformed plain Teams meeting-only message only when the Teams join URL, "
        "Meeting ID, and Passcode occur together near the start of bodyPreview "
        "under the module's conservative bounds. Do not classify substantive work "
        "mail merely because a meeting block appears later in quoted history. Also "
        "recoverably delete an NDR/bounce only when the subject starts "
        "Undeliverable:, the sender address matches "
        "MicrosoftExchange*@service.microsoft.com or the display name is Microsoft "
        "Outlook, and body/bodyPreview contains delivery-failure evidence such as "
        "couldn't be delivered, wasn't found, or Recipient Unknown. An "
        "Undeliverable: subject alone is insufficient."
    )


def meeting_noise_standard_for_prompt() -> str:
    """Backward-compatible alias for callers not yet renamed."""

    return global_noise_standard_for_prompt()
