# microsoft-connect-writing

End-to-end skill for writing Microsoft Connect **manager comments** for direct reports: read/write Connect forms via Edge CDP, distill a prior manager's voice via the Nuwa methodology, iteratively improve drafts (gap analysis + tone calibration + hard/soft critique), and scaffold Key Results from the manager's standing KRs translated to IC level.

This skill is the manager-side companion to `local_skills/msft-connect.md` (self-Connect). Use this one when filling **Manager Comments** on a direct report's form (`https://v2.msconnect.microsoft.com/manager/<pernr>`).

## When to use

- Filling Manager Comments (Past / Future) for any direct report in the current cycle
- Carrying a prior manager's voice/style forward when you inherit a report
- Translating organizational/team standing KRs into per-IC KR scaffolding
- Iteratively refining a draft (push → reread form → revise → push again)

## Sub-jobs (callable from VO mManager)

| Sub-job | Purpose |
|---|---|
| `read` | Read a report's Connect form (past + future textboxes) via CDP |
| `read-history` | Pull prior cycles' manager comments for one report from `viewhistory` |
| `distill-voice` | Nuwa-Skill 6-parallel-subagent voice distillation from N historical Connects |
| `draft-past` | Draft Past manager comments using distilled voice + current cycle facts |
| `draft-future` | Draft Future manager comments — translate standing KRs to IC level |
| `push` | Write Past and/or Future HTML into the form, click Save as draft, verify |
| `gap-analysis` | Compare prior-cycle forward asks vs current-cycle delivery (named gaps) |
| `tone-calibrate` | Adjust draft for performer level (SWE 2 floor / Principal multiplier) |
| `suggest-krs` | Generate per-IC KR list from standing manager KRs + role calibration |

---

## 1. CDP wiring (port 9223)

All interactions go through headless Edge CDP. Same wiring as `scorm-rise-automation` and `msft-connect.md`.

### Launch fresh Edge (per push, to avoid React state desync)

```python
import subprocess, time, os
def fresh_edge(url):
    subprocess.run(["powershell", "-Command",
                    "Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force"],
                   check=False, capture_output=True)
    time.sleep(5)
    subprocess.Popen([
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "--headless=new",
        "--remote-debugging-port=9223",
        "--remote-allow-origins=*",
        f"--user-data-dir={os.path.expanduser('~/edge-cdp-profile')}",
        url,
    ])
    time.sleep(18)  # MSAL SSO + React render
```

**Why fresh Edge per push:** When the form already has saved content, `innerHTML` changes don't reliably propagate to React state on a reused tab. Killing msedge and reopening forces a fresh React mount that picks up the new innerHTML on first render. **Re-using a tab to write twice is the #1 source of silent save loss.**

### One-shot WebSocket eval pattern

```python
import json, websocket
def evl(ws, expr, rid):
    ws.send(json.dumps({"id": rid, "method": "Runtime.evaluate",
                        "params": {"expression": expr,
                                   "returnByValue": True,
                                   "awaitPromise": True}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == rid:
            return m.get("result", {}).get("result", {}).get("value")
```

Do NOT use async/await inside the expression. Use synchronous `evl()` calls with `time.sleep()` between them in Python. Long-lived async-awaiting WebSocket calls time out on the v2 Connect React mount.

### Locate the form's textboxes

The Manager Comments form has **exactly 2** `[role=textbox]` contenteditable divs:

| Index | Field | Char ceiling (observed) |
|---|---|---|
| 0 | Past (What did they deliver and how) | ~6000 |
| 1 | Future (What should they focus on and how you'll support) | ~6000 |

Wait loop until both are mounted:

```python
for i in range(20):
    time.sleep(4)
    n = evl(ws, "document.querySelectorAll('[role=textbox]').length", rid) or 0
    if n >= 2:
        break
```

If after 80 s the count is still <2, the form is likely in **non-editable status** — Posted, Returned, or Advanced past In-Review. Read `document.body.innerText.slice(0, 500)` to confirm; this is the "unauthorized mid-session" pattern. The report's form went off the In-Review list; manual paste is needed once it returns.

### Read

```javascript
(() => {
  const els = [...document.querySelectorAll('[role=textbox]')];
  return {
    past: els[0]?.innerText || '',
    future: els[1]?.innerText || '',
    past_len: els[0]?.innerText.length || 0,
    future_len: els[1]?.innerText.length || 0
  };
})()
```

**Always re-read the form before drafting an edit.** Local drafts go stale across sessions because (a) you may have saved an interim version you forgot about, (b) the report may have advanced status, (c) auto-save sometimes overwrites with empty content on a stale tab. Drafting against an out-of-date assumption produces edits the user has to discard.

### Write

```javascript
(() => {
  const el = document.querySelectorAll('[role=textbox]')[INDEX];   // 0=past, 1=future
  el.focus();
  el.innerHTML = NEW_HTML;
  el.dispatchEvent(new InputEvent('input', {bubbles: true}));
  el.dispatchEvent(new Event('change', {bubbles: true}));
  el.blur();
  return el.innerText.length;
})()
```

Required event sequence: `focus → set innerHTML → InputEvent(input) → Event(change) → blur`. Skipping `change` leaves the Save button disabled. Skipping `blur` leaves React's internal isDirty flag set on the wrong field.

### Save and verify

```javascript
// Click Save as draft (case-insensitive match in case label changes)
(() => {
  const b = [...document.querySelectorAll('button')]
              .find(x => /save as draft/i.test(x.innerText));
  if (b) { b.click(); return {clicked: true}; }
  return {clicked: false};
})()
```

After click: **`time.sleep(30)`**. Then **close the WS, open a fresh WS, navigate back to the URL, wait for the textboxes to remount, re-read.** This catches the silent-save-loss case where `clicked: true` is returned but innerHTML doesn't persist because the React state never accepted the change. Verify by content check, not just length:

```javascript
{
  past_len: p.length,
  c_marker_1: p.includes('<a specific unique phrase from your new draft>'),
  c_marker_2: p.includes('<another unique phrase>')
}
```

If any check is false after a 30 s wait, the save lost it. Re-run with a fresh Edge process; do **not** re-run on the same tab.

---

## 2. Voice distillation (Nuwa-Skill method)

When you inherit a report from a prior manager, their historical Connect manager comments are the most concentrated artifact of that manager's voice. Distilling that voice lets the report's Connect feel continuous instead of a regime change — which is what the report and the skip-level reader both want.

### Inputs

- N ≥ 3 historical Connect manager comments for the report (text dumps from `viewhistory`)
- More cycles = better signal. 5–7 cycles gives a sharp profile

### Method: 6 parallel subagents + 3-layer verification

Launch 6 specialist subagents **in parallel** (one message, multiple Agent tool blocks). Each focuses on one axis of voice. Then a verification pass (you do this synthesis yourself).

| Subagent | Axis | Output |
|---|---|---|
| A. Opener patterns | First-sentence templates | "Thank you, X, for ... during this connection period." |
| B. Pivot phrases | Transition phrases between sections | "However, there are areas...", "Apart from above list,", "Going forwards..." |
| C. Signature vocabulary | Recurring nouns/verbs | "proactive follow-ups", "closing the loop", "high-leverage", "ROI", "dev days" |
| D. Grammar / ESL markers | Idiosyncrasies | "Lets" (no apostrophe), capital-noun habit (Bugs, IcMs, Reliability), occasional "in in" |
| E. Standing KRs | Recurring forward-asks across cycles | 3–7 KR phrases that appear cycle after cycle, often verbatim |
| F. Closer patterns | Sign-off | "Lets discuss these in our regular 1:1" |

### 3-layer verification matrix

After the 6 subagents return, build a verification table — do not trust any single subagent in isolation:

1. **Frequency:** does this pattern appear in ≥ 2 of N cycles? (Coincidence filter)
2. **Co-occurrence:** does this pattern travel with another distilled pattern? (Pattern-of-life filter)
3. **Counter-evidence:** are there cycles where the manager *did not* use this pattern? (Overfitting filter)

A pattern that passes all three is in the **frozen mental model**. Patterns that fail any one go into "interesting but tentative" — usable when you want flavor, but not load-bearing.

### Output artifact

Save the distillation to:
```
{onedrive-work}\1-MSTeamsFiles\0-EM\connect\{YYYY-MM-DD}\{report}_all_manager_comments.md
```

Sections in the file:
1. Raw historical Connects (one per cycle, with date headers)
2. Per-subagent output (6 sections, preserved verbatim — do not summarize away)
3. Frozen mental model (the verified intersection)
4. Standing KRs (verbatim phrases the manager has repeated)
5. Voice template (a fill-in-the-blanks paragraph skeleton ready to apply)

### Example: Madhu voice profile (Raimond cycles 2022-06 → 2024-10)

Frozen patterns from 5-cycle distillation (verified all 3 layers):

- **Opener:** `Thank you, [Name], for [contribution] during this connection period.` Note `connection period`, not `connect period` — characteristic.
- **Pivots:** `However, there are areas requiring immediate attention`; `Apart from above list,`; `Going forwards, I would also encourage`.
- **Vocab:** *proactive follow-ups*, *closing the loop*, *getting things done*, *high-leverage*, *craftsmanship*, *ROI*, *dev days*.
- **Capital nouns:** *Bugs*, *IcMs*, *IcM SLA*, *Calling*, *Reliability* (treated as proper-noun categories).
- **ESL markers:** `Lets` (no apostrophe); occasional `in in`.
- **Closer:** `Lets discuss these in our regular 1:1`.
- **5 standing KRs** (verbatim across cycles):
  1. Thriving score >75 (sometimes 80+)
  2. 90%+ of committed PRs delivered without release-type change
  3. 1 innovation reaching R0
  4. 20% bug reduction in 6 months
  5. 0 out-of-SLA security items

---

## 3. Drafting workflow

### Structure (Madhu-style, proven for both lower-performer and Principal calibrations)

**Past (6 paragraphs):**
1. `Thank you, [Name], for [headline contribution] during this connection period.` (Open + optional context line like IC transition or new role.)
2. **One consolidated achievement paragraph** with named projects, numbers, partner-team list. Resist the urge to split achievements into 4–5 paragraphs — the consolidated single block is the Madhu signature and reads more strongly. Mix categories with `On reliability and live-site: ...; On architecture: ...; On reducing manual testing: ...; On innovation and culture: ...`.
3. **Bridge paragraph:** one specific signature pattern that's worth calling out plus the setback reflection paired with the structural fix.
4. **`However, there are areas to keep sharpening this cycle.`** Hard critiques — named gaps with specifics: "the 99% target set last cycle was not fully met"; "the cycle is short of the R0 standard"; "going forwards, prove the rotation is sticky across a full cycle."
5. **`On opportunities to deepen further:`** (Optional, for Principal calibration) Soft asks — multiplier-pattern next-step framing rather than gap framing: "going from one team to 2-3 adjacent teams replicating the same automation playbook is where the Principal multiplier truly compounds."
6. **`Lets discuss these in our regular 1:1.`** Closer.

**Future:**
1. Acknowledge the goals the report wrote (or critique if they read as aspirations rather than KRs).
2. `Apart from above, below are my expectations for you to thrive this cycle — I am adding detailed Key Results as goals to encourage your growth:`
3. `<ul><li>` per KR (see KR scaffolding below).
4. Calibration disclaimer: `These detailed Key Results are scaffolding for your growth, not a fixed checklist — if any feels unrealistic with current scope, lets reset it up front rather than mid-cycle.`
5. Closer: `Lets work together on these in our regular 1:1.`

### Gap analysis (read prior cycle's Future before writing current cycle's Past)

This is non-negotiable. The previous cycle's manager comments encode the contract the report agreed to. The current cycle's Past has to honestly grade against it.

1. Pull prior cycle's Future via `read-history`.
2. List the named asks (often 5–10 bullet points).
3. For each ask, check against current cycle's delivery facts (self-Connect + WSR + IcM/Bug/PR data + your own observation).
4. Categorize: **Met / Partially met / Missed / Carried-forward.**
5. **Missed** items go into the `However, there are areas to keep sharpening` paragraph **by name**. Naming them is the calibration discipline — it prevents drift cycle-over-cycle.

### Tone calibration

| Performer level | Past — Achievement framing | Past — `However` paragraph | Future — KR floor |
|---|---|---|---|
| SWE 2 lower-performer | Single consolidated paragraph, no softener like *"While X is a reliable contributor"* — name the contributions and let them stand alone | Name the prior-cycle asks that were missed; do not euphemize. Reliability 99.0%+. AI PR ≥30%. Design doc for any PR >300 LOC. | Include hygiene KRs explicitly (training, sprint updates, DRI shift) |
| Senior SWE typical | Consolidated paragraph; add bridge paragraph for one signature habit | Mix one hard gap with one growth ask | Reliability 99.0–99.5%. AI PR ≥30%. |
| Principal SWE | Consolidated achievement paragraph + bridge for the multiplier signature (mentor pattern, doc habit, etc.) | Hard critiques **plus** `On opportunities to deepen further` paragraph for multiplier asks (1 team → 2-3 adjacent teams) | Reliability ≥99.5%. AI PR ≥40%. Design doc for any architectural-impact PR (not LOC-based). Add multiplier KRs: cross-team architecture reviews, AI capability adoption beyond personal use, mentor with dev-day-delta tracked. |

**Do not insert "While X is a reliable contributor" softeners** for lower performers — that's exactly the calibration-blurring habit Connect tries to surface. The single-paragraph consolidated achievement framing is the softener that's already calibrated; adding another one tilts the read.

### Avoiding the "draft without reading the form" trap

If the user has been actively iterating in the browser (typing into the form while you're drafting offline), the form state may already be different from your local copy. **Always run `read` first** before generating a revision. The phrase to internalize: "you didn't reference the current draft, did you???" is the failure mode this prevents.

---

## 4. KR scaffolding

### Madhu's standing KR grammar

```
[verb] [metric] [target] [scope/time window]
```

Examples (verbatim from the corpus):
- `drive 20%+ of MJ team-area backlog features end-to-end as owner`
- `90%+ of committed PRs delivered without release-type change`
- `0 out-of-SLA ICM, postmortem, S360, SFI items this cycle`
- `≥30% of your PRs leveraging Copilot/Claude tooling with logged dev-day savings`

### EM → IC translation matrix

The standing KRs were originally EM-scope. To apply them to an IC, translate one axis at a time. The two axes that matter:

| Axis | EM frame | IC frame |
|---|---|---|
| Ambiguous → quantitative | "thriving environment" | (defer to 1:1, not a Connect KR) |
| Centralized → distributed | "team-wide reliability KR" | "owned-scenario reliability ≥99.x%" |

Examples:

| EM standing KR | IC-translated KR |
|---|---|
| Team thriving score >75 | (drop — move to 1:1) |
| 90%+ team features delivered without release-type change | 90%+ of *committed* PRs delivered without release-type change |
| 1 team innovation reaching R0 | 1 innovation reaching R0 *with adoption beyond personal use* (3+ team members, OR 1+ sister-team adoption) |
| 20% team bug reduction in 6 months | 25+ bugs closed/cycle in owned area with 0 P0/P1 regressions from your PRs |
| 0 out-of-SLA security items team-wide | 0 out-of-SLA ICM, postmortem, S360, SFI items in owned scope |

### Standard KR list to offer (Past-cycle delivery → Future-cycle KR)

For a typical Meeting Join / Meeting Notes IC, the KR scaffolding list should cover:

1. **Reliability** — owned-scenario % target with no-regression-across-rings clause
2. **Operational hygiene** — DRI-shift close-out, zero out-of-SLA ICM/postmortem/S360/SFI, on-time training and Connects and sprint updates
3. **Feature ownership** — % of team-area backlog driven end-to-end as owner, leading major functionality in N+ features
4. **Delivery predictability** — % committed PRs delivered without release-type change, zero unplanned spill-over per sprint
5. **Personal throughput** — PRs/month, bugs closed/cycle, peer reviews/month
6. **Innovation** — 1 project to R0 with adoption metric (not just shipped)
7. **Design discipline** — design doc before code for any PR >300 LOC (or any architectural-impact PR at Principal)
8. **AI productivity adoption** — % of PRs leveraging Copilot/Claude tooling with logged dev-day savings (≥30% IC floor, ≥40% Principal)

For Principal-level, add:

9. **Architecture multiplier** — N draft-first migration plans per cycle; 100% architecture decisions documented with trade-off trail
10. **Mentor multiplier** — extend [signature pattern from Past] to N+ adjacent teams with per-team delta tracked
11. **Partner architecture reviews** — N cross-team architecture reviews per cycle (named partner teams)

---

## 5. Push script template

A self-contained push script for Past and/or Future. Save to local scratch (`C:\src\tmp\connect-{report}\push_{description}.py`) — **never** save run scripts under OneDrive (OneDrive is for archive content only; run scripts must be local so they're not subject to sync conflicts mid-execution).

```python
"""Push <description> for <report> Connect manager comments."""
import json, sys, time, subprocess, requests, websocket
sys.stdout.reconfigure(encoding="utf-8")

URL = "https://v2.msconnect.microsoft.com/manager/<PERNR>"

PAST_HTML = (
    "<p>Thank you, <Name>, for <headline> during this connection period.</p>"
    "<p>This connection period <Name> delivered across <areas>. On reliability and live-site: ...; On architecture: ...; On reducing manual testing: ...; On innovation and culture: ...</p>"
    "<p>Apart from above, one pattern I would highlight specifically: ... &mdash; that is craftsmanship that compounds across cycles.</p>"
    "<p>However, there are areas to keep sharpening this cycle. ...</p>"
    "<p>On opportunities to deepen further: ...</p>"
    "<p>Lets discuss these in our regular 1:1.</p>"
)

FUTURE_HTML = (
    "<p>Acknowledge their stated goals.</p>"
    "<p>Apart from above, below are my expectations for you to thrive this cycle &mdash; I am adding detailed Key Results as goals to encourage your growth:</p>"
    "<ul>"
    "<li>Reliability: ...</li>"
    "<li>Operational hygiene: ...</li>"
    "<li>Feature ownership: ...</li>"
    "<li>Delivery predictability: ...</li>"
    "<li>Personal throughput: ...</li>"
    "<li>Innovation: ...</li>"
    "<li>Design discipline: ...</li>"
    "<li>AI productivity adoption: ...</li>"
    "</ul>"
    "<p>These detailed Key Results are scaffolding for your growth, not a fixed checklist &mdash; if any feels unrealistic with current scope, lets reset it up front rather than mid-cycle. Lets work together on these in our regular 1:1.</p>"
)


def evl(ws, expr, rid):
    ws.send(json.dumps({"id": rid, "method": "Runtime.evaluate",
                        "params": {"expression": expr, "returnByValue": True, "awaitPromise": True}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == rid:
            return m.get("result", {}).get("result", {}).get("value")


def nav(ws, url, rid):
    ws.send(json.dumps({"id": rid, "method": "Page.navigate", "params": {"url": url}}))
    while True:
        m = json.loads(ws.recv())
        if m.get("id") == rid:
            return


def fresh_edge(url):
    subprocess.run(["powershell", "-Command",
                    "Get-Process msedge -ErrorAction SilentlyContinue | Stop-Process -Force"],
                   check=False, capture_output=True)
    time.sleep(5)
    subprocess.Popen([
        r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe",
        "--headless=new",
        "--remote-debugging-port=9223",
        "--remote-allow-origins=*",
        f"--user-data-dir={subprocess.os.path.expanduser('~/edge-cdp-profile')}",
        url,
    ])
    time.sleep(18)


def wait_textboxes(ws, rid_seed, n_required=2, attempts=20):
    rid = rid_seed
    for _ in range(attempts):
        time.sleep(4)
        rid += 1
        n = evl(ws, "document.querySelectorAll('[role=textbox]').length", rid) or 0
        if n >= n_required:
            return rid
    return rid


def write_field(ws, rid_seed, index, html):
    rid = rid_seed + 1
    return rid, evl(ws, f"""
      (() => {{
        const el = document.querySelectorAll('[role=textbox]')[{index}];
        el.focus();
        el.innerHTML = {json.dumps(html)};
        el.dispatchEvent(new InputEvent('input', {{bubbles: true}}));
        el.dispatchEvent(new Event('change', {{bubbles: true}}));
        el.blur();
        return el.innerText.length;
      }})()
    """, rid)


def click_save(ws, rid_seed):
    rid = rid_seed + 1
    return rid, evl(ws, """
      (() => {
        const b = [...document.querySelectorAll('button')].find(x => /save as draft/i.test(x.innerText));
        if (b) { b.click(); return {clicked: true}; }
        return {clicked: false};
      })()
    """, rid)


def main(push_past=True, push_future=True):
    fresh_edge(URL)
    tabs = requests.get('http://127.0.0.1:9223/json').json()
    page = next((t for t in tabs if t['type'] == 'page' and 'v2.msconnect' in t['url']), None)
    ws = websocket.create_connection(page['webSocketDebuggerUrl'], timeout=60)
    rid = 1
    nav(ws, URL, rid)
    rid = wait_textboxes(ws, rid)

    rid += 1
    before = evl(ws, """
      (() => {
        const els = [...document.querySelectorAll('[role=textbox]')];
        return {past_len: els[0]?.innerText.length || 0, future_len: els[1]?.innerText.length || 0};
      })()
    """, rid)
    print(f"BEFORE: {before}")

    if push_past:
        rid, n = write_field(ws, rid, 0, PAST_HTML)
        print(f"WROTE past: {n}")
        time.sleep(5)
    if push_future:
        rid, n = write_field(ws, rid, 1, FUTURE_HTML)
        print(f"WROTE future: {n}")
        time.sleep(5)

    rid, save = click_save(ws, rid)
    print(f"SAVE: {save}")
    print("Waiting 30s...")
    time.sleep(30)
    ws.close()

    # Verify via fresh navigation
    time.sleep(2)
    tabs2 = requests.get('http://127.0.0.1:9223/json').json()
    page2 = next((t for t in tabs2 if t['type'] == 'page' and 'v2.msconnect' in t['url']), None)
    ws2 = websocket.create_connection(page2['webSocketDebuggerUrl'], timeout=60)
    rid2 = 1
    nav(ws2, URL, rid2)
    rid2 = wait_textboxes(ws2, rid2)
    time.sleep(3)
    rid2 += 1
    final = evl(ws2, """
      (() => {
        const els = [...document.querySelectorAll('[role=textbox]')];
        const p = els[0]?.innerText || '';
        const f = els[1]?.innerText || '';
        return {
          past_len: p.length,
          future_len: f.length,
          c_past_marker: p.includes('UNIQUE PHRASE FROM PAST DRAFT'),
          c_future_marker: f.includes('UNIQUE PHRASE FROM FUTURE DRAFT')
        };
      })()
    """, rid2)
    print(f"FINAL: {json.dumps(final, ensure_ascii=False, indent=2)}")
    ws2.close()


if __name__ == "__main__":
    main()
```

---

## 6. Failure modes and recovery

| Symptom | Likely cause | Recovery |
|---|---|---|
| `clicked: true` but verify shows old content | React state desync (innerHTML didn't propagate) | Fresh Edge process, retry once. If still fails, the form may be locked. |
| Verify shows < 2 textboxes after 80 s wait | Form moved off In-Review (Posted/Returned/Advanced) | Read body.innerText to confirm; manual paste needed once status reverts |
| `WebSocket timeout` mid-eval | async/await pattern in JS expression | Rewrite as sync `evl()` calls with Python `time.sleep` between |
| Save loses bullet formatting | Pasted plain text instead of `<ul><li>` HTML | Re-push as HTML string, not innerText |
| Manager comment for wrong report | Wrong pernr in URL | Pernr is in the report's profile or visible in the URL when you click into their form from `/perspective/team` |

---

## 7. File layout

```
C:\src\tmp\connect-{report}\           # local run scripts (push_*.py, diagnose.py)
                                         # NEVER under OneDrive — that's archive only

C:\Users\qitxu\OneDrive - Microsoft\
    1-MSTeamsFiles\0-EM\connect\
        {YYYY-MM-DD}\                  # session date as folder
            {report}_all_manager_comments.md     # voice distillation source-of-truth
            {report}_current.txt                  # report's self-Connect text
            {report}_prior.txt                    # prior cycle manager Future
            connect-{period}.md                   # full archive
```

---

## 8. Related skills

- `local_skills/msft-connect.md` — self-Connect (writing your own Connect; complementary side of the workflow)
- `local_skills/transcript-download.md` — pull recap-meeting transcripts when feedback came in a 1:1 review
- `summarize-learning-from-wechat-to-wish.md` — broader skill for distilling learnings (the Nuwa method here is a specialization)
- Memory: `feedback_run_scripts_local_not_onedrive` — run scripts go local, never OneDrive
- Memory: `feedback_popup_screenshot_first` — when CDP push fails mid-form, screenshot first to identify status

$ARGUMENTS
