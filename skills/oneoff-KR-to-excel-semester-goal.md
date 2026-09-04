# oneoff-KR-to-excel-semester-goal

Confirm/adjust a semester's **Tier 0 reliability & latency targets** in a shared planning
Excel workbook by reconciling each scenario against the team's **ADO KR targets**, then
writing the changes **directly into the live (co-authored) workbook** via Excel for the web.

> Origin: built from the FY27 H1 "CMD T0 Reliability & Latency" planning readout task
> (EM owner = Josh Xu, area = Meeting Join). One-off per planning cycle / semester transition.

## When to use
Planning-readout prep asks an EM to "review the Tier 0 reliability/latency sheets and update
the FY** H* targets directly by <deadline> if any changes are needed", and the source of truth
for targets is an ADO KR query.

## Inputs (ask if not supplied)
1. **Worksheet** — SharePoint/OneDrive sharing link to the planning .xlsx.
2. **ADO KR query** — the shared query URL/GUID holding the semester KR targets.
3. **EM owner name** — whose rows to touch (auto-detect via Graph `/me` `displayName`).
4. **Area scope** — e.g. "Meeting Join" (the only lines to edit). Ignore everything else.

## Prerequisites
- Edge CDP on **9223** with the persistent profile, signed in as the EM:
  `msedge --remote-debugging-port=9223 --remote-allow-origins=* --user-data-dir=%USERPROFILE%\edge-cdp-profile`
- `py -3.12 -m pip install websocket-client openpyxl requests` (the hermes venv python has no pip; use `py -3.12`).
- `az` logged in (for ADO REST + Graph `/me`).
- Reusable helper: `${LOCAL_SKILLS}/data_tools/xl_coauthor.py` (CDP + co-authoring cell editor).

## Identity & access facts (learned)
- `az account get-access-token --resource graph` token in this tenant **lacks Files/Sites scopes**
  → Graph `/shares` returns accessDenied. **Do not** rely on Graph for the file.
- Instead, drive the **already-authenticated browser**: open the share link, then call the
  **same-origin** OneDrive API `/_api/v2.0/shares/<u!token>/driveItem[/content]` with session cookies.
- The EM usually has **edit** rights (EffectiveBasePermissions low-nibble = View+Add+Edit+Delete),
  but a REST/Graph **content PUT is still blocked**: `423 SPFileLockException` (file co-authored by
  other EMs) — and a full overwrite would **wipe their concurrent edits**. ⇒ Must co-author (below).

---

## Phase 1 — Authenticate & locate the file
1. Confirm the CDP browser is signed in as the EM (`/json` shows their Outlook/M365 tab).
2. Open the share link in a new tab; wait until `document.title` == the workbook name.
3. Resolve metadata via same-origin fetch (gives `driveId`, `itemId`, `size`, `webUrl`):
   `GET location.origin + "/_api/v2.0/shares/" + u!token + "/driveItem?select=id,name,size,parentReference,file"`
4. Download a local copy for analysis (openpyxl) using `xl_coauthor.download_via_share(top_tab, share_url)`.

## Phase 2 — Pull the ADO KR targets
```powershell
$T = az account get-access-token --resource 499b84ac-1321-427f-aa17-267ca6975798 --query accessToken -o tsv
# WIQL by stored query id -> ids; then workitemsbatch for fields
# https://domoreexp.visualstudio.com/MSTeams/_apis/wit/wiql/<QID>?api-version=7.0
# POST .../_apis/wit/workitemsbatch  body {"ids":[...]}
```
Key fields: `System.Title`, `Custom.KRTargetValue`, `Custom.FYBaseline`, `Custom.MayActual`, `Custom.OKRCycle`.
Parse the **title** for platform tags + metric, e.g.
`🟡 [TFL][Win][Tier0][create_meetup] reliability at 99.5%` → tags `{TFL,Win}`, metric `create_meetup`, KR `99.5`.
Latency titles: `[Win][T21][Tier0] Meeting Join time (in app) P95 3.15s` → kind `in app`, plat `TFW Win`, `3.15s`.
(🟡 = at-risk, 🟢 = on-track. `KRTargetValue` field can disagree with the title number — prefer the value
that does not regress below baseline/status; for clean platform matches the sheet's existing value == KR.)

## Phase 3 — Read the sheets (openpyxl, `data_only=False`)
**Reliability sheet** `CMD T0&T1 Reliability`: `Q`=Tier, `M`=EM Owner, `B`=Area `C`=Owner `D`=Metric(`(short_name)`)
`E`=FY26H2 Target, **`F`=FY27 H1 (edit target)**, `G`=Suggested, `H`=Group(platform e.g. "TFL Win"), `L`=Status.
- Filter `Q == "Tier 0"` AND `M == <EM>`. Detect **yellow** FY27H1 cells via fill rgb `FFFFFF00`.
**Latency sheet** `CMD T0 Latency`: `C`=Owner(team, e.g. CMD/Horizontals), `D`=Metric, `E`=Target,
**`L`=Funded FY27 (edit target)**, `KTLO` = keep existing. Your rows = `C=="CMD"` + Meeting-Join metrics.

## Phase 4 — Join rows → KR & decide
Match worksheet `Group`(platform)+`metric` to the ADO KR. Map e.g. `TFL Win→{TFL,Win}`, `TFW VDI 2.0→{TFW,VDI2}`,
latency `T21→TFW`, `[TFL][T2]→TFL Win`. **Decision rule (the "lower line"):**
- FY27 H1 = the existing FY26H2 target / matched **KR value** (they coincide for clean matches).
- Only change a **yellow** cell that is **below the existing target or blank** → raise to target / add it.
- A yellow cell already **at** the target (flagged only because target ≤ current status) → **keep as-is** (no change).
- **Never** lower a value, **never** inflate above target to chase current performance.
- Latency: leave `KTLO`; only set seconds where the sheet diverges from the funded KR (e.g. KTLO 4.6s vs KR 4.5s → 4.5s).
- **Only touch the EM's area rows; ignore everything else.**
Produce an explicit change list `[(sheet, cell, old, new)]` and log it.

## Phase 5 — Apply edits via Excel-for-web CO-AUTHORING  ⚠️ (do NOT REST-overwrite)
Use `${LOCAL_SKILLS}/data_tools/xl_coauthor.py`:
```python
import xl_coauthor as X
wac = X.find_wac(); xw = X.ExcelWeb(X.attach(wac)); xw.ready()
# reliability sheet is usually active; else xw.select_sheet("CMD T0&T1 Reliability")
for ref, old, new in rel_changes:
    print(ref, xw.set_cell(ref, new, expected_old=old))   # 'OK' or *_FAIL (aborts safely)
xw.select_sheet("CMD T0 Latency")
print("L55", xw.set_cell("L55", "4.5s", expected_old="KTLO"))
```
`set_cell` enters the value through the **formula bar editor**, pre-commit-verifies the typed text,
Escape-aborts on any mismatch, commits with Enter, then re-reads to confirm. **It never clobbers
other cells and merges via co-authoring** (other EMs editing their rows are preserved).

If the UI gets stuck (formula bar shows stale text for every cell / Name Box frozen): **reload** the
top tab to the share URL, wait ~28 s, `wac = X.find_wac()` again, and resume. A reload clears stale edit DOM.

## Phase 6 — Verify (ground truth)
Re-download with `download_via_share()` after ~10 s (co-author autosave), open with openpyxl, assert every
target cell == new value, spot-check neighbors unchanged, and confirm fills preserved (edited yellow cells
keep `FFFFFF00`). The workbook contains pivot tables/charts/images — **never** round-trip it through
openpyxl-save/upload (that would drop them); editing is only ever done in-browser.

---

## Critical gotchas (all learned the hard way)
- **Grid is canvas** — focusing the grid keyboard input and typing does NOT edit a cell. Use the formula bar editor.
- **No CDP `char` events** — they double every character ("99.5"→"9999..55"). Use keyDown+keyUp(text) only.
- **Always pre-commit-verify then Escape-abort** — a bad typed buffer once committed garbage `9999..5599.3` into F214.
- **WAC is a cross-origin OOPIF** — attach to its own target (`ppc-*-excel.officeapps.live.com/.../xlviewerinternal.aspx`),
  not the top page. The top page is same-origin to SharePoint and is used only for the REST download/verify.
- **Name Box clears flakily** — select-all + verify nb==ref before Enter, retry up to 6×.
- **`py -3.12`** for pip/openpyxl (the default `python` is the hermes venv with no pip).
- **PYTHONIOENCODING=utf-8** when printing ADO titles (status emoji 🟡/🟢 crash cp1252 console).

## Files
- `${LOCAL_SKILLS}/data_tools/xl_coauthor.py` — reusable CDP + co-authoring editor (download_via_share, ExcelWeb).
- Related: `${LOCAL_SKILLS}/semester-planning.md` (ADO OKR hierarchy), `${LOCAL_SKILLS}/data_tools/sharepoint-doc-extraction.md`,
  `${LOCAL_SKILLS}/data_tools/tool-Edge-Browser.md`.
