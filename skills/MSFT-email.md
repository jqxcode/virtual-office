# MSFT-email

Microsoft 365 (Outlook) inbox triage, filtering, and HTML reporting for **Josh.Xu@microsoft.com** — the **portable** successor to `msft-outlook-email-inbox-clean`. It is driven by the **WorkIQ MCP (Microsoft Graph)**, so it runs regardless of the desktop Outlook flavor: **New Outlook (`olk.exe`)**, classic Outlook (COM), or OWA.

> Why this exists: the original skill used classic-Outlook COM automation. Machines running **New Outlook (`olk.exe`) have no COM/MAPI surface**, and `New-Object -ComObject Outlook.Application` there just launches the classic "Welcome to Outlook" setup wizard. The Graph/MCP path avoids all of that. Prefer this skill; only fall back to COM when a classic Outlook MAPI profile is present **and** MCP is unavailable.

## Prerequisites
- **WorkIQ MCP** connected (M365 Copilot), signed in as Josh.Xu@microsoft.com. Mailbox userId `90b98fe6-a80b-46e1-9209-b5ebcdf6da6b`.
- Tools used: `workiq-fetch`, `workiq-search_paths`, `workiq-do_action`, `workiq-delete_entity`, `workiq-update_entity`, `workiq-get_schema`.
- (COM fallback only) classic Outlook running + `scripts/outlook/Generate-InboxReport.ps1` under **Windows PowerShell 5.1** (see caveats).

## Category detection (Graph — validated 2026-07-01)
The canonical global-noise classifier is
`scripts/email_triage_rules.py::global_noise_reason`. The generator imports it,
and execution/report-refresh prompts must apply the same semantics rather than
maintaining a looser duplicate rule.

| Category | Detection rule |
|---|---|
| Meeting object | case-insensitive `@odata.type` contains `eventMessage` (requests, updates, responses, cancellations) |
| Meeting cancel/forward | subject starts with `Canceled:` / `Cancelled:` / `Meeting Forward Notification:` (case-insensitive) |
| Automatic reply / OOF | **all** subjects starting with `Automatic reply:` / `Auto reply:` / `Autoreply:` / `Out of Office:`, regardless of sender or underlying topic; the prefix always wins |
| Malformed meeting-only fallback | Teams join URL + `Meeting ID:` + `Passcode:` occur together near the start of `bodyPreview`, within the exact conservative bounds in the canonical module |
| Verified NDR / bounce | subject starts `Undeliverable:` **and** sender is `MicrosoftExchange*@service.microsoft.com` or display name `Microsoft Outlook` **and** body/preview contains delivery-failure evidence (`couldn't be delivered`, `wasn't found`, `Recipient Unknown`, or canonical variants) |
| **External** | subject contains `[EXTERNAL]` (case-insensitive) |
| Importance | `importance` ∈ {`low`,`normal`,`high`} |
| Sender | `from.emailAddress.address` / `from.emailAddress.name` |

`@odata.type` is returned automatically for meeting messages — you do **not** need to `$select` it.
The malformed/plain fallback intentionally does **not** match substantive work
mail whose quoted history merely contains an old Teams join block. This can miss
long or heavily prefaced malformed meeting templates; review those instead of
broadening automatic deletion.

## Folder map — `M / z-Notifications / …` (validated 2026-07-01)
Resolve ids **by name at runtime** (folders are stable but ids change if recreated):
`GET /me/mailFolders` → find `M` → `/childFolders` → find `z-Notifications` → `/childFolders` → find target.

| Target | Well-known / path | Cached id (last validated) |
|---|---|---|
| Inbox | `/me/mailFolders/inbox` | `AQMkAGZm…IBDAAAAA==` |
| Junk (block target) | `/me/mailFolders/junkemail` | — |
| Deleted Items | `/me/mailFolders/deleteditems` | — |
| M/z-Notifications/**Food** | resolve by name | `…AAthz4gMAAA=` (72 items) |
| M/z-Notifications/**TeamsNotification** | resolve by name | `…AAAB94v1AAA=` (1627) |
| M/z-Notifications/**0-ActionNeeded** | resolve by name | `…AAbvYyJ-AAA=` (464) |

(Siblings also present: `Lockbox`, `MeetingResponses`, `SellBuy`.)

## Phases

### Phase 1 — Enumerate & categorize (read-only)
1. `GET /me/mailFolders/inbox?$select=totalItemCount,unreadItemCount` for the total.
2. Page messages: `GET /me/mailFolders/inbox/messages?$select=subject,from,importance,receivedDateTime,isRead&$orderby=receivedDateTime desc&$top=25`.
   - **Paging:** WorkIQ **rejects `$skip`** (`400: $skip is not permitted`). Page with a **cursor**: append `&$filter=receivedDateTime lt <receivedDateTime-of-last-item>` and repeat until empty. **25 items per collection** is the hard cap.
3. Bucket each message using the detection table into: newInvites / cancelled / forwarded / external / regular(by sender).

### Phase 2 — Delete noise → Deleted Items (recoverable)
`workiq-delete_entity /me/messages/{id}` for:
- Office 365 / SharePoint notifications, Power BI, Lockbox
- **All messages matched by `scripts/email_triage_rules.py::global_noise_reason`**: event objects, cancellation/forward prefixes, automatic replies/OOF, conservative malformed meeting-only fallback, and verified Microsoft Exchange NDR/bounces.
- The automatic-reply prefix wins over topic/vendor classification: `Automatic reply: Bot Protection Shiproom` is noise even though Bot Protection is a legitimate work topic.
- `Automatic reply: Josh:Naveen` from `navshri@microsoft.com` is therefore
  global noise even though its OOF-until-Oct-9 body and thread topic are
  otherwise legitimate.
- `Undeliverable: Bot Protection Shiproom` is also global noise only when its
  Microsoft Exchange/Outlook sender identity and delivery-failure body evidence
  satisfy the canonical rule. `Undeliverable:` alone is not enough.
- Azure User Access Review; Event Polls
> Runs **unattended — no review gate**; meeting invites are deleted outright (recoverable in Deleted Items). If you ever want to eyeball invites first, generate the Phase 6 report *before* Phase 2.

### Phase 3 — Block → Junk
`workiq-do_action /me/mailFolders/inbox/messages/{id}/move` with `jsonBody={"destinationId":"junkemail"}`:
- Named vendor spam: Chatsworth, IBC, Emerson.
- **Unsolicited external-domain marketing/recruiting** senders (e.g. `tristar.com`, `infowaygroup.com`, ScyllaDB, Identiverse, ElevateIT) — cold outreach from a non-`microsoft.com`/`skype.net` domain, **except Fidelity**.
> ⚠️ **Do NOT blanket-junk by the `[EXTERNAL]` subject tag.** That tag also rides on **internal colleagues'** replies in externally-sourced threads and on **genuine external work/personal** mail (a partner vendor in an active project thread, a personal referral). Junk only true unsolicited external mail; when a sender is borderline (active work thread / personal), **confirm with the user** before junking.
> WorkIQ does **not** expose `messageRules`, so "block" = move existing mail to Junk (optionally add `/me/inferenceClassification/overrides`). A true server-side block rule must be created in the Outlook UI.

### Phase 4 — Mark important
`workiq-update_entity` with `entityUrl=/me/messages/{id}` + **`jsonBody={"importance":"high"}`** for: **Madhu Sudan, Zoran Cvetkovic, Vivek Mohan**. (The payload param is `jsonBody`, NOT `body`; `If-Match` is optional. Skip items already `high`.)

### Phase 5 — Filter to folders (move)
`workiq-do_action /me/mailFolders/inbox/messages/{id}/move` `jsonBody={"destinationId":"<folderId>"}`:
| Sender / condition | Destination |
|---|---|
| FreeFood DL (recipients/subject contains `freefood` / `free food`) | Food |
| Tiffany Smit | Food |
| CMD Automation Service Account | TeamsNotification |
| `gautosa\d+@microsoft.com` | TeamsNotification |
| Global Regulation Program / Weekly Feed | TeamsNotification |
| Azure Access Review (if kept, not deleted) | 0-ActionNeeded |

### Phase 6 — Report
Build the dark-theme, foldable HTML report (same layout as the COM version): **Meetings** (future→past, dynamic NOW divider, tabs Invite/Cancelled/Forwarded) · **External** (`[EXTERNAL]` stripped) · **Regular** (grouped by sender, expandable, importance tags). Two ways:
- **Portable (preferred):** render from the MCP categorization to `~/inbox_report.html`.
- **COM fallback:** `Add-Type -AssemblyName System.Web; & "<repo>/scripts/outlook/Generate-InboxReport.ps1"` (classic Outlook only).

Every report MUST include the VO subtitle directly under the title:
`Agent: pEmailer | Job: MSFT-email | Start: <PST start> | Complete: <PST now>`.

### Phase 7 — Open
`Start-Process msedge.exe -ArgumentList '--disable-extensions --new-tab "file:///C:/Users/qitxu/inbox_report.html"'` (`--disable-extensions` avoids the enterprise DLP extension crash).

## Portal deployment / server reload

- Changes to `email-triage-server.py` or
  `scripts/email_triage_rules.py` are **not active in an already-running
  process**. A successful file edit is not deployment.
- Before restarting, query `http://127.0.0.1:8765/api/status` and wait for the
  worker to be operationally idle: `status` must not be `queued` or `running`.
  Never terminate/reload the server while an action or refresh worker is active.
- Once idle, stop the exact listening PID, start
  `email-triage-server.py` again, then re-query `/api/status` and verify the
  listener is responsive. Only then treat classifier/prompt changes as deployed.

## WorkIQ operations reference
- **Read:** `workiq-fetch /me/mailFolders/inbox/messages?$select=…&$top=25`
- **Move:** `workiq-do_action /me/mailFolders/inbox/messages/{id}/move` with `jsonBody={"destinationId":"<id|junkemail|deleteditems>"}` (returns the full moved message — large, ignore it)
- **Delete:** `workiq-delete_entity /me/messages/{id}` → HTTP **204**, moves to Deleted Items (recoverable)
- **Mark:** `workiq-update_entity` with `entityUrl=/me/messages/{id}` + **`jsonBody={"importance":"high"}`** — payload param is `jsonBody`, NOT `body` (`body` throws "An error occurred invoking update_entity"); `If-Match` optional
- **Folders:** `workiq-fetch /me/mailFolders` and `…/{id}/childFolders`

### Bulk deletion pattern (validated)
There is **no bulk delete** — `/$batch` is denied (see caveats), so you delete/move **one message per call**. To purge many (e.g. all meeting mail):
1. Enumerate & bucket ids (page with the `receivedDateTime` cursor).
2. Load ids into a scratch table and issue `delete_entity` in **parallel batches of ≤4** (bigger batches throttle — see caveats). Mark each id done only on `204`; retry `429`s in the next batch.
3. Verify: re-check the subject filters (`Canceled:` / `Meeting Forward Notification:` → empty) and re-scan the top pages for any leftover `@odata.type` meeting messages.

## Caveats (learned the hard way)
- A machine may run **New Outlook (`olk.exe`)** → **no COM/MAPI**. Use MCP. `New-Object -ComObject Outlook.Application` on such a box opens the classic setup wizard and hangs.
- `[Runtime.InteropServices.Marshal]::GetActiveObject` **does not exist in PowerShell 7** (.NET Core). The COM fallback needs **Windows PowerShell 5.1** + a configured classic Outlook MAPI profile.
- **WorkIQ query limits:** `$skip` rejected → page with a `receivedDateTime lt <cursor>` filter; **25 items/collection** cap; `messageRules` not exposed; **`isof('microsoft.graph.eventMessage…')` rejected** (`ErrorInvalidUrlQueryFilter`) → you cannot server-side filter by `@odata.type`; page and inspect it (it is auto-returned), or use subject `startswith` (supported) for `Canceled:` / `Meeting Forward Notification:`.
- **`POST /$batch` is denied** (`Access denied for POST path: /$batch`) → no batched multi-delete; one message per call.
- **Mailbox write concurrency ≈ 4.** Firing >4–6 parallel `delete_entity`/`move` calls returns `429 ApplicationThrottled` ("over its MailboxConcurrency limit", with `retryAfterSeconds`). Keep mutation batches **≤4** and retry throttled ones.
- Deletes go to **Deleted Items** (recoverable); moves are reversible.

## Validation log
- **2026-07-01** (WorkIQ MCP): Inbox 132 items / 104 unread. Confirmed every category detection on live mail (eventMessageRequest invites, `Canceled:` cancels, `Meeting Forward Notification:` forwards, `[EXTERNAL]`), sender + importance fields, folder targets (Food 72 / TeamsNotification 1627 / 0-ActionNeeded 464 / Junk 37), and `move`/`delete`/`childFolders` operations. COM path confirmed **not** runnable on this machine (New Outlook `olk.exe` only; no classic MAPI profile).
- **2026-07-02** (WorkIQ MCP): Executed a full meeting-mail purge end-to-end — deleted **15 cancellations + 2 forward notifications + 46 invites = 63** messages via per-message `delete_entity` in ≤4 parallel batches (hit `429` at 6–9 concurrency). Inbox **132 → 64**; post-purge subject filters empty and top-page rescan clean. This run is where the `$batch`-denied, `isof`-denied, and concurrency≈4 caveats were confirmed.
- **2026-07-02** (WorkIQ MCP, "run every other rule once"): On the 64-item inbox ran all remaining phases — deleted 3 auto-replies; marked Vivek + Madhu **high** (this is where `update_entity` was found to require **`jsonBody`**, not `body`); filtered Global Regulations + Weekly Feed (×2) → TeamsNotification; junked tristar (×3) + infowaygroup marketing. Office365/PowerBI/Lockbox/access-review/CMD-Automation/gautosa/FreeFood/Tiffany/Chatsworth/IBC/Emerson had **0** matches (already clean/foldered). Inbox 64 → 56. Deliberately **kept** fireflies.ai (active work thread) + a personal gmail referral per user — validating the refined Phase 3 guidance (don't junk by the `[EXTERNAL]` tag).
