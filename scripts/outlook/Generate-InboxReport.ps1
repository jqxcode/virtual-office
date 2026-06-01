<#
.SYNOPSIS
    Generates an HTML inbox report from Outlook, separating meetings, external, and regular emails.
.DESCRIPTION
    - Enumerates all Inbox items via Outlook COM
    - Separates meeting schedule emails (invites, cancelled, forwarded) from external and regular emails
    - External emails (subject tagged with [External]) are shown in their own foldable section
    - Meeting invites sorted by scheduled time (future first), with dynamic NOW divider
    - Regular emails grouped by sender with expandable detail view
    - All sections are foldable
    - Outputs an interactive HTML report
.NOTES
    Requires Outlook desktop to be running/configured.
    Run: .\Generate-InboxReport.ps1
    Output: ~\inbox_report.html
#>

param(
    [string]$OutputPath = "$env:USERPROFILE\inbox_report.html"
)

Write-Host "📬 Generating Inbox Report..." -ForegroundColor Cyan

$outlook = New-Object -ComObject Outlook.Application
$namespace = $outlook.GetNamespace("MAPI")
$inbox = $namespace.GetDefaultFolder(6)
$items = $inbox.Items

$newInvites = @()
$cancelled = @()
$forwarded = @()
$externalEmails = @()
$regularEmails = @()

Write-Host "  Enumerating inbox items..." -NoNewline
foreach ($item in $items) {
    try {
        $cls = $item.MessageClass
        if ($cls -match "EventPoll") { continue }

        $name = $item.SenderName; if (-not $name) { $name = "(unknown)" }
        $subject = $item.Subject; if (-not $subject) { $subject = "(no subject)" }

        if ($cls -match "IPM\.Schedule\.Meeting") {
            $startTime = ""
            $isRecurring = $false
            $recurDesc = ""

            try {
                $appt = $item.GetAssociatedAppointment($false)
                if ($appt) {
                    $startTime = $appt.Start.ToString("yyyy-MM-ddTHH:mm:ss")
                    $isRecurring = $appt.IsRecurring
                    if ($isRecurring) {
                        try {
                            $pat = $appt.GetRecurrencePattern()
                            $recurDesc = switch ($pat.RecurrenceType) {
                                0 { "Daily" } 1 { "Weekly" } 2 { "Monthly" } 3 { "MonthNth" }
                                5 { "Yearly" } 6 { "YearNth" } default { "Recurring" }
                            }
                        } catch { $recurDesc = "Recurring" }
                    }
                }
            } catch {}

            $type = switch -Wildcard ($cls) {
                "*Meeting.Request" { "invite" }
                "*Meeting.Canceled" { "cancel" }
                "*Meeting.Notification.Forward" { "forward" }
                default { $null }
            }
            if (-not $type) { continue }

            $obj = [PSCustomObject]@{ Subject=$subject; Organizer=$name; MeetingTime=$startTime; IsRecurring=$isRecurring; RecurDesc=$recurDesc }
            switch ($type) { "invite" { $newInvites += $obj } "cancel" { $cancelled += $obj } "forward" { $forwarded += $obj } }
        } else {
            $imp = $item.Importance
            $impLabel = switch ($imp) { 0 { "Low" } 1 { "Normal" } 2 { "High" } default { "Normal" } }
            $body = ($item.Body -replace '\r?\n', ' ' -replace '\s+', ' ').Trim()
            if ($body.Length -gt 120) { $body = $body.Substring(0, 120) + "..." }
            $senderEmail = $item.SenderEmailAddress
            if ($item.SenderEmailType -eq "EX") { try { $exu = $item.Sender.GetExchangeUser(); if ($exu) { $senderEmail = $exu.PrimarySmtpAddress } } catch {} }
            if ($senderEmail -match "^/O=") { $senderEmail = "" }

            $receivedTime = $item.ReceivedTime
            if ($subject -match '\[External\]') {
                $cleanSubject = ($subject -replace '(?i)\[external\]', '').Trim()
                if (-not $cleanSubject) { $cleanSubject = "(no subject)" }
                $externalEmails += [PSCustomObject]@{ SenderName=$name; Subject=$cleanSubject; Received=$receivedTime.ToString("yyyy-MM-dd HH:mm"); ReceivedSort=$receivedTime }
            } else {
                $regularEmails += [PSCustomObject]@{ SenderName=$name; SenderEmail=$senderEmail; Subject=$subject; Importance=$impLabel; ImpSort=$imp; Preview=$body; Received=$receivedTime.ToString("yyyy-MM-dd HH:mm"); ReceivedSort=$receivedTime }
            }
        }
    } catch {}
}
[System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) | Out-Null

# Sort: invites by meeting time DESCENDING (future first)
$newInvites = $newInvites | Sort-Object MeetingTime -Descending
$cancelled = $cancelled | Sort-Object MeetingTime -Descending
$forwarded = $forwarded | Sort-Object MeetingTime -Descending
$externalEmails = $externalEmails | Sort-Object ReceivedSort -Descending
$emailsBySender = $regularEmails | Group-Object SenderName | Sort-Object Count -Descending
$highImp = ($regularEmails | Where-Object { $_.Importance -eq 'High' }).Count
$totalMeetings = $newInvites.Count + $cancelled.Count + $forwarded.Count
$totalExternal = $externalEmails.Count
$totalAll = $totalMeetings + $totalExternal + $regularEmails.Count

Write-Host " Done! ($totalAll items)"
Write-Host "  Meetings: $totalMeetings | External: $totalExternal | Regular: $($regularEmails.Count) | Senders: $($emailsBySender.Count)"

# --- BUILD HTML ---
$html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8">
<title>Inbox Report</title>
<style>
*{box-sizing:border-box;margin:0;padding:0}
body{font-family:'Segoe UI',system-ui,sans-serif;background:#1a1a2e;color:#eee;padding:20px;max-width:1200px;margin:0 auto}
h1{text-align:center;margin-bottom:5px;color:#00d4ff;font-size:24px}
.subtitle{text-align:center;color:#888;margin-bottom:20px;font-size:13px}
.stats{display:flex;justify-content:center;gap:20px;margin-bottom:25px;flex-wrap:wrap}
.stat-box{background:#16213e;border:1px solid #0f3460;border-radius:8px;padding:10px 20px;text-align:center}
.stat-box .num{font-size:24px;font-weight:bold;color:#00d4ff}
.stat-box .num.orange{color:#ffa502}.stat-box .num.red{color:#ff4757}.stat-box .num.green{color:#2ed573}.stat-box .num.purple{color:#a29bfe}
.stat-box .label{font-size:11px;color:#aaa}
.section-header{display:flex;align-items:center;cursor:pointer;user-select:none;margin:30px 0 0;padding:10px 0;border-bottom:2px solid #0f3460}
.section-header h2{font-size:18px;font-weight:600;flex:1}
.section-header h2.meetings{color:#ffa502}.section-header h2.external{color:#a29bfe}.section-header h2.emails{color:#00d4ff}
.section-header .fold-btn{font-size:14px;color:#888;transition:transform .2s}
.section-header .fold-btn.collapsed{transform:rotate(-90deg)}
.section-content{overflow:hidden;transition:max-height .3s ease}
.section-content.collapsed{max-height:0!important;overflow:hidden;padding:0}
.tab-bar{display:flex;gap:8px;margin:15px 0}
.tab-btn{background:#16213e;border:1px solid #0f3460;color:#aaa;padding:6px 16px;border-radius:6px;cursor:pointer;font-size:13px;transition:all .2s}
.tab-btn.active{background:#0f3460;color:#ffa502;border-color:#ffa502}.tab-btn:hover{border-color:#ffa502}
.meeting-group{display:none}.meeting-group.show{display:block}
.meeting-item{background:#16213e;border:1px solid #0f3460;border-radius:6px;padding:10px 14px;margin-bottom:5px;display:flex;align-items:center;gap:10px;font-size:13px}
.meeting-item:hover{border-color:#ffa502}
.type-badge{font-size:10px;padding:3px 8px;border-radius:4px;flex-shrink:0;font-weight:600}
.type-badge.invite{background:#2ed573;color:#000}.type-badge.cancel{background:#ff4757;color:#fff}.type-badge.forward{background:#ffa502;color:#000}
.meeting-item .subj{font-weight:500;flex:1;color:#ddd}
.meeting-item .org{color:#888;font-size:12px;flex-shrink:0;max-width:150px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.meeting-item .mtime{color:#ffa502;font-size:11px;flex-shrink:0;min-width:160px;text-align:right;font-weight:500}
.recur-badge{font-size:9px;padding:2px 6px;border-radius:3px;background:#7c4dff;color:#fff;flex-shrink:0}
.meeting-item.past{opacity:0.55}.meeting-item.upcoming{border-color:#2ed573}
.now-line{display:flex;align-items:center;margin:14px 0;gap:10px}
.now-line .line{flex:1;height:2px;background:linear-gradient(90deg,#2ed573,#ffa502,#ff4757)}
.now-line .label{color:#ffa502;font-size:12px;font-weight:600;white-space:nowrap;padding:4px 12px;background:#2d1f00;border:1px solid #ffa502;border-radius:4px}
.external-list{margin-top:15px}
.external-item{background:#16213e;border:1px solid #0f3460;border-radius:6px;padding:10px 14px;margin-bottom:5px;display:flex;align-items:center;gap:10px;font-size:13px}
.external-item:hover{border-color:#a29bfe}
.external-item .sender{color:#a29bfe;font-size:12px;flex-shrink:0;max-width:180px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.external-item .subj{font-weight:500;flex:1;color:#ddd}
.external-item .date{color:#888;font-size:11px;flex-shrink:0;min-width:130px;text-align:right}
.sender-row{background:#16213e;border:1px solid #0f3460;border-radius:8px;margin-bottom:5px;overflow:hidden;transition:all .2s}
.sender-row:hover{border-color:#00d4ff}
.sender-header{display:flex;align-items:center;padding:10px 14px;cursor:pointer;user-select:none}
.sender-header .count{background:#00d4ff;color:#000;font-weight:bold;border-radius:50%;width:30px;height:30px;display:flex;align-items:center;justify-content:center;font-size:12px;margin-right:10px;flex-shrink:0}
.sender-header .count.high{background:#ff4757;color:#fff}
.sender-header .name{font-weight:600;flex:1;font-size:14px}
.sender-header .email{color:#666;font-size:11px;margin-left:8px}
.sender-header .toggle-btn{background:#0f3460;color:#00d4ff;border:1px solid #00d4ff;border-radius:4px;padding:3px 10px;font-size:11px;cursor:pointer;transition:all .2s}
.sender-header .toggle-btn:hover{background:#00d4ff;color:#000}
.email-list{display:none;padding:0 14px 10px 54px}.email-list.show{display:block}
.email-item{padding:5px 0;border-bottom:1px solid #0f3460;font-size:12px;display:flex;align-items:flex-start;gap:8px}
.email-item:last-child{border-bottom:none}
.imp{font-size:9px;padding:2px 5px;border-radius:3px;flex-shrink:0;margin-top:2px}
.imp.High{background:#ff4757;color:#fff}.imp.Normal{background:#2f3542;color:#888}.imp.Low{background:#1e272e;color:#555}
.email-item .subj{font-weight:500;color:#ddd}
.email-item .preview{color:#666;font-size:11px;margin-top:1px}
.email-item .date{color:#555;font-size:10px;flex-shrink:0;margin-left:auto;min-width:90px;text-align:right}
.search-box{display:block;margin:0 auto 15px;padding:8px 14px;width:380px;max-width:100%;background:#16213e;border:1px solid #0f3460;border-radius:6px;color:#eee;font-size:13px}
.search-box:focus{outline:none;border-color:#00d4ff}
.hidden{display:none!important}
</style></head><body>
<h1>📬 Inbox Email Report</h1>
<p class="subtitle">Generated $(Get-Date -Format 'MMMM dd, yyyy h:mm tt') | Sorted: Future → Past</p>
<div class="stats">
<div class="stat-box"><div class="num">$totalAll</div><div class="label">Total Inbox</div></div>
<div class="stat-box"><div class="num orange">$totalMeetings</div><div class="label">Meeting Emails</div></div>
<div class="stat-box"><div class="num purple">$totalExternal</div><div class="label">External</div></div>
<div class="stat-box"><div class="num green">$($regularEmails.Count)</div><div class="label">Regular Emails</div></div>
<div class="stat-box"><div class="num red">$highImp</div><div class="label">High Importance</div></div>
</div>

<!-- MEETINGS SECTION (foldable) -->
<div class="section-header" onclick="toggleSection('meetings-content')">
<h2 class="meetings">📅 Meeting Schedule Emails ($totalMeetings)</h2>
<span class="fold-btn" id="meetings-content-btn">▼</span>
</div>
<div class="section-content" id="meetings-content">
<div class="tab-bar">
<button class="tab-btn active" onclick="showMeetingTab('NewInvite');event.stopPropagation()">New Invite ($($newInvites.Count))</button>
<button class="tab-btn" onclick="showMeetingTab('Cancelled');event.stopPropagation()">Cancelled ($($cancelled.Count))</button>
<button class="tab-btn" onclick="showMeetingTab('Forwarded');event.stopPropagation()">Forwarded ($($forwarded.Count))</button>
</div>
<div class="meeting-group show" id="tab-NewInvite">
"@

# New Invites - sorted DESCENDING (future first)
foreach ($m in $newInvites) {
    $subj = [System.Web.HttpUtility]::HtmlEncode($m.Subject)
    $org = [System.Web.HttpUtility]::HtmlEncode($m.Organizer)
    $mt = $m.MeetingTime
    if ($mt) { $displayTime = ([datetime]$mt).ToString("MMM dd, yyyy  h:mm tt") } else { $displayTime = "—"; $mt = "" }
    $recurBadge = if ($m.IsRecurring) { "<span class='recur-badge'>🔁 $($m.RecurDesc)</span>" } else { "" }
    $html += "<div class='meeting-item' data-time='$mt'>$recurBadge<span class='type-badge invite'>Invite</span><span class='subj'>$subj</span><span class='org'>$org</span><span class='mtime'>📅 $displayTime</span></div>`n"
}
$html += "</div>`n"

# Cancelled
$html += "<div class='meeting-group' id='tab-Cancelled'>`n"
foreach ($m in $cancelled) {
    $subj = [System.Web.HttpUtility]::HtmlEncode($m.Subject)
    $org = [System.Web.HttpUtility]::HtmlEncode($m.Organizer)
    $mt = $m.MeetingTime
    if ($mt) { $displayTime = ([datetime]$mt).ToString("MMM dd, yyyy  h:mm tt") } else { $displayTime = "—"; $mt = "" }
    $recurBadge = if ($m.IsRecurring) { "<span class='recur-badge'>🔁 $($m.RecurDesc)</span>" } else { "" }
    $html += "<div class='meeting-item' data-time='$mt'>$recurBadge<span class='type-badge cancel'>Cancelled</span><span class='subj'>$subj</span><span class='org'>$org</span><span class='mtime'>📅 $displayTime</span></div>`n"
}
$html += "</div>`n"

# Forwarded
$html += "<div class='meeting-group' id='tab-Forwarded'>`n"
foreach ($m in $forwarded) {
    $subj = [System.Web.HttpUtility]::HtmlEncode($m.Subject)
    $org = [System.Web.HttpUtility]::HtmlEncode($m.Organizer)
    $mt = $m.MeetingTime
    if ($mt) { $displayTime = ([datetime]$mt).ToString("MMM dd, yyyy  h:mm tt") } else { $displayTime = "—"; $mt = "" }
    $recurBadge = if ($m.IsRecurring) { "<span class='recur-badge'>🔁 $($m.RecurDesc)</span>" } else { "" }
    $html += "<div class='meeting-item' data-time='$mt'>$recurBadge<span class='type-badge forward'>Forwarded</span><span class='subj'>$subj</span><span class='org'>$org</span><span class='mtime'>📅 $displayTime</span></div>`n"
}
$html += "</div></div>`n"

# EXTERNAL EMAILS SECTION (foldable)
$html += @"

<div class="section-header" onclick="toggleSection('external-content')">
<h2 class="external">🌐 External Emails ($totalExternal)</h2>
<span class="fold-btn" id="external-content-btn">▼</span>
</div>
<div class="section-content" id="external-content">
<div class="external-list">
"@

foreach ($e in $externalEmails) {
    $sender = [System.Web.HttpUtility]::HtmlEncode($e.SenderName)
    $subj = [System.Web.HttpUtility]::HtmlEncode($e.Subject)
    $html += "<div class='external-item'><span class='sender'>$sender</span><span class='subj'>$subj</span><span class='date'>$($e.Received)</span></div>`n"
}

$html += "</div></div>`n"

# REGULAR EMAILS SECTION (foldable)
$html += @"

<div class="section-header" onclick="toggleSection('emails-content')">
<h2 class="emails">📧 Regular Emails ($($regularEmails.Count)) — $($emailsBySender.Count) senders</h2>
<span class="fold-btn" id="emails-content-btn">▼</span>
</div>
<div class="section-content" id="emails-content">
<input type="text" class="search-box" placeholder="🔍 Filter senders..." oninput="filterSenders(this.value)">
<div id="sender-list">
"@

foreach ($g in $emailsBySender) {
    $senderName = [System.Web.HttpUtility]::HtmlEncode($g.Name)
    $count = $g.Count
    $firstEmail = ($g.Group | Select-Object -First 1).SenderEmail; if (-not $firstEmail) { $firstEmail = "" }
    $emailEnc = [System.Web.HttpUtility]::HtmlEncode($firstEmail)
    $countClass = if ($count -ge 8) { "high" } else { "" }
    $sorted = $g.Group | Sort-Object @{Expression={$_.ImpSort};Descending=$true}, @{Expression={$_.ReceivedSort};Descending=$true}

    $html += "<div class='sender-row' data-name='$($senderName.ToLower())'><div class='sender-header' onclick='toggleEmails(this)'><div class='count $countClass'>$count</div><span class='name'>$senderName</span><span class='email'>$emailEnc</span><button class='toggle-btn'>▼ View</button></div><div class='email-list'>`n"
    foreach ($e in $sorted) {
        $subj = [System.Web.HttpUtility]::HtmlEncode($e.Subject)
        $prev = [System.Web.HttpUtility]::HtmlEncode($e.Preview)
        $html += "<div class='email-item'><span class='imp $($e.Importance)'>$($e.Importance)</span><div><div class='subj'>$subj</div><div class='preview'>$prev</div></div><span class='date'>$($e.Received)</span></div>`n"
    }
    $html += "</div></div>`n"
}

$html += @"
</div></div>

<script>
// Dynamic NOW line for New Invites (sorted future-first = descending by time)
(function(){
  const now=new Date();
  const container=document.getElementById('tab-NewInvite');
  const items=container.querySelectorAll('.meeting-item');
  let inserted=false;
  // Items sorted descending: first items are future, later items are past
  for(let i=0;i<items.length;i++){
    const t=items[i].dataset.time;
    if(!t)continue;
    const itemTime=new Date(t);
    if(itemTime<=now&&!inserted){
      const nl=document.createElement('div');nl.className='now-line';
      nl.innerHTML='<div class="line"></div><span class="label">⏱ NOW — '+now.toLocaleString('en-US',{month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'})+'</span><div class="line"></div>';
      container.insertBefore(nl,items[i]);
      inserted=true;
    }
    if(!inserted){items[i].classList.add('upcoming')}
    else{items[i].classList.add('past')}
  }
  if(!inserted&&items.length>0){
    const nl=document.createElement('div');nl.className='now-line';
    nl.innerHTML='<div class="line"></div><span class="label">⏱ NOW — '+now.toLocaleString('en-US',{month:'short',day:'numeric',year:'numeric',hour:'numeric',minute:'2-digit'})+'</span><div class="line"></div>';
    container.appendChild(nl);
    items.forEach(el=>el.classList.add('upcoming'));
  }
})();

function toggleSection(id){
  const el=document.getElementById(id);
  const btn=document.getElementById(id+'-btn');
  el.classList.toggle('collapsed');
  btn.classList.toggle('collapsed');
}
function toggleEmails(h){const l=h.nextElementSibling;const b=h.querySelector('.toggle-btn');l.classList.toggle('show');b.textContent=l.classList.contains('show')?'▲ Hide':'▼ View'}
function filterSenders(q){q=q.toLowerCase();document.querySelectorAll('.sender-row').forEach(r=>{r.classList.toggle('hidden',!r.dataset.name.includes(q))})}
function showMeetingTab(id){document.querySelectorAll('.meeting-group').forEach(g=>g.classList.remove('show'));document.querySelectorAll('.tab-btn').forEach(b=>b.classList.remove('active'));document.getElementById('tab-'+id).classList.add('show');event.target.classList.add('active')}
</script></body></html>
"@

$html | Out-File $OutputPath -Encoding UTF8
$size = [math]::Round((Get-Item $OutputPath).Length / 1KB, 1)
Write-Host "✅ Report saved: $OutputPath ($size KB)" -ForegroundColor Green
