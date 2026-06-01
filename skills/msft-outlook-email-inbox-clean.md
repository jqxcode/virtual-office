# msft-outlook-email-inbox-clean

Microsoft Outlook Inbox Email Cleaning & Organization Skill

## Overview
Automated inbox triage, filtering, and report generation for Josh.Xu@microsoft.com Outlook inbox using COM automation.

## Prerequisites
- Outlook desktop running with Josh.Xu@microsoft.com account configured
- PowerShell with COM access
- Edge browser for report viewing
- Script: `C:\Users\qitxu\scripts\Generate-InboxReport.ps1`

## Step-by-Step Process

### Phase 1: Enumerate & Categorize
1. Connect to Outlook via COM: `New-Object -ComObject Outlook.Application`
2. Get inbox: `$namespace.GetDefaultFolder(6)`
3. Enumerate ALL items, categorize by:
   - `$item.MessageClass` → meeting items (`IPM.Schedule.Meeting.*`)
   - `$item.Subject` → external (`[External]`), access review, file blocked
   - `$item.SenderName` / `$item.SenderEmailAddress` → known senders
   - `$item.To` / Recipients → distribution lists (freefood, etc.)

### Phase 2: Delete Junk/Noise
Delete these categories immediately:
- **Office 365 notifications** — sender matches "Office365" or "Microsoft 365"
- **Microsoft Power BI** — sender matches "Power BI"
- **Lockbox** — sender matches "Lockbox"
- **Meeting cancellations** — MessageClass = `IPM.Schedule.Meeting.Canceled`
- **Meeting forwards** — MessageClass = `IPM.Schedule.Meeting.Notification.Forward`
- **Automatic replies** — subject starts with "Automatic reply:" or "Out of Office:"
- **Azure User Access Review** — subject/sender contains "access review"
- **Event Polls** — MessageClass contains "EventPoll"

### Phase 3: Block & Spam
Move to Junk folder (`$namespace.GetDefaultFolder(23)`):
- **Chatsworth Products** — any sender matching "chatsworth"
- **IBC Team** — any sender matching "ibc" (word boundary)
- **Emerson** — any sender matching "emerson"
- **All [External] senders EXCEPT Fidelity** — subject contains "[External]" but sender does NOT match "fidelity"

### Phase 4: Mark Important
Set `$item.Importance = 2` (High) + `$item.Save()` for:
- **Madhu Sudan** — sender matches "madhu"
- **Zoran Cvetkovic** — sender matches "zoran"
- **Vivek Mohan** — sender matches "vivek mohan"

### Phase 5: Filter to Folders
Move matching emails to target folders (navigate via `$root.Folders.Item("M").Folders.Item("z-Notifications").Folders.Item(...)`):

| Sender/Condition | Target Folder |
|---|---|
| FreeFood DL (To/Recipients contains "freefood") | M/z-Notifications/Food |
| Tiffany Smit | M/z-Notifications/Food |
| CMD Automation (mcmautomationaccount@microsoft.com) | M/z-Notifications/TeamsNotification |
| gautosa***@microsoft.com (regex: `gautosa\d+@microsoft\.com`) | M/z-Notifications/TeamsNotification |
| Global Regulation Program / Weekly Feed | M/z-Notifications/TeamsNotification |
| Azure Access Review (if not deleted) | M/z-Notifications/0-ActionNeeded |

### Phase 6: Generate Report
Run: `& "C:\Users\qitxu\scripts\Generate-InboxReport.ps1"`

Report features:
- Dark theme, interactive HTML
- **Foldable sections**: Meetings, External, Regular Emails
- **Meetings**: sorted future→past, dynamic NOW line, tabs (Invite/Cancelled/Forwarded)
- **External**: sorted by date, [External] tag stripped
- **Regular**: grouped by sender, expandable detail with importance tags
- Search/filter box for senders

### Phase 7: Open Report
```powershell
Start-Process "msedge.exe" -ArgumentList '--disable-extensions --new-tab "file:///C:/Users/qitxu/inbox_report.html"'
```
Use `--disable-extensions` to avoid enterprise DLP extension crash.

## Technical Notes

### Outlook COM Key Facts
- Use `foreach` enumeration, NOT index-based `$items.Item($i)` (throws OOB errors)
- Meeting time: `$item.GetAssociatedAppointment($false).Start` (NOT `$item.Start`)
- SMTP from Exchange: `$item.Sender.GetExchangeUser().PrimarySmtpAddress`
- Release COM: `[System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook)`
- Full enumeration of ~200+ items takes 60-180 seconds

### Known Limitations
- **Rule creation via COM fails** in cached Exchange mode — use Outlook UI or scheduled scripts
- **Outlook UI count** may lag behind actual count (cached mode sync delay)
- **Graph API Mail.Read** scope not available via az CLI token
- **EWS** returns 401 with current token setup

### Folder Structure
```
\\Josh.Xu@microsoft.com\
  Inbox (default folder 6)
  M\
    z-Notifications\
      TeamsNotification
      Food
      0-ActionNeeded
```

### Scheduled Tasks (workarounds for broken rules)
- `Move-FreeFoodEmails.ps1` — runs every 5 min, moves freefood DL emails to Food