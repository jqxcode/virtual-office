$ErrorActionPreference = "SilentlyContinue"
if (-not (Get-Process OUTLOOK -ErrorAction SilentlyContinue)) {
    Write-Output "Outlook not running; nothing to do."
    exit 0
}

$outlook = $null
$namespace = $null
try {
    $outlook = [Runtime.InteropServices.Marshal]::GetActiveObject("Outlook.Application")
    $namespace = $outlook.GetNamespace("MAPI")
    $inbox = $namespace.GetDefaultFolder(6)
    $root = $namespace.Folders.Item("Josh.Xu@microsoft.com")
    $foodFolder = $root.Folders.Item("M").Folders.Item("z-Notifications").Folders.Item("Food")

    $matches = New-Object System.Collections.Generic.List[object]
    foreach ($item in $inbox.Items) {
        try {
            if ($item -and $item.Class -eq 43) {
                $to = [string]$item.To
                $cc = [string]$item.CC
                $subject = [string]$item.Subject
                $recips = @()
                try { foreach ($r in $item.Recipients) { $recips += ([string]$r.Name + '|' + [string]$r.Address) } } catch {}
                if ($to -match 'freefood' -or $cc -match 'freefood' -or (($recips -join '; ') -match 'freefood') -or $subject -match 'free\s*food') {
                    $matches.Add($item) | Out-Null
                }
            }
        } catch {}
    }

    $moved = 0
    foreach ($item in @($matches)) {
        try {
            [void]$item.Move($foodFolder)
            $moved++
        } catch {}
    }

    Write-Output ("Moved {0} freefood email(s)." -f $moved)
}
finally {
    if ($namespace) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($namespace) }
    if ($outlook) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($outlook) }
    [gc]::Collect(); [gc]::WaitForPendingFinalizers()
}
