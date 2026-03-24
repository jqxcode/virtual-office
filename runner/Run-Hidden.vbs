' Run-Hidden.vbs - Launches a command with no visible window
' Usage: wscript Run-Hidden.vbs "pwsh -NoProfile -File ..."
Set objShell = CreateObject("WScript.Shell")
objShell.Run WScript.Arguments(0), 0, False
