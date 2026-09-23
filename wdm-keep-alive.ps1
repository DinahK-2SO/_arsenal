<#
.SYNOPSIS
  Make an unattended DevBox VM render WinUI 3 apps (and screenshot them) even after you RDP-disconnect.

.WHY
  When you disconnect RDP, your interactive session goes to the "Disconnected" state and loses its
  display. Windows Desktop Window Manager (DWM) then stops compositing that session, so WinUI 3 /
  DirectComposition apps never *present* a frame and `winapp ui screenshot` (PrintWindow) captures a
  blank window (GetForegroundWindow()==0). This is an OS behavior, not a benchmark bug, and it cannot
  be fixed from a non-elevated runtime.

  The fix is to reattach the disconnected session to the **console** session (`tscon <id> /dest:console`),
  which owns the VM's Microsoft Hyper-V display. The session becomes Active again, DWM composites, and
  apps render normally. `tscon` requires elevation, so this installs a **SYSTEM scheduled task** that
  does it automatically — registered ONCE (elevated), then no runtime elevation is ever needed.

  It only reconnects sessions that are currently DISCONNECTED, so it is a no-op while you are connected
  (it never kicks you off).

.USAGE
  # Run ONCE from an ELEVATED PowerShell (accept the UAC prompt while you are connected):
  .\Setup-UnattendedRenderHost.ps1

  # Then verify: start your benchmark, disconnect RDP, wait ~20s, and confirm captures render.
  # (Test-WinUI3Render.ps1 in the investigation folder is a ready PASS/FAIL probe.)

  # To remove everything:
  .\Setup-UnattendedRenderHost.ps1 -Uninstall

.NOTES
  Reversible: creates one scheduled task + one helper script under C:\ProgramData\BenchRenderHost,
  and sets the AC display timeout to "never". -Uninstall undoes the task + files (leaves powercfg).
#>
#Requires -RunAsAdministrator
[CmdletBinding()]
param(
  [int]$DebounceSeconds = 3,
  [switch]$Uninstall
)
$ErrorActionPreference = 'Stop'
$TaskName = 'BenchKeepSessionOnConsole'
$Dir      = 'C:\ProgramData\BenchRenderHost'
$Recon    = Join-Path $Dir 'Reconnect-DisconnectedToConsole.ps1'

if ($Uninstall) {
  Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction SilentlyContinue
  Remove-Item $Dir -Recurse -Force -ErrorAction SilentlyContinue
  Write-Host "Removed scheduled task '$TaskName' and $Dir."
  return
}

New-Item -ItemType Directory -Force $Dir | Out-Null

# ── Helper (runs as SYSTEM): reconnect a DISCONNECTED user session to the console. ──
# ONE-SHOT: fired by the EVENT trigger (on RDP disconnect) + a 1-min safety poll. Before parking a
# session it checks whether a connection AUTHENTICATED recently (EventID 1149) — which fires at the
# very start of a (re)connect — and if so it skips. That makes reconnecting safe *no matter how slow*
# the handshake is (a slow 10s+ reconnect is still detected the instant it authenticates), so the
# returning user is never kicked ("another connection was made").
@'
param([int]$DebounceSeconds = 3)
$ErrorActionPreference = 'SilentlyContinue'
$log = 'C:\ProgramData\BenchRenderHost\reconnect.log'
Start-Sleep -Seconds $DebounceSeconds
# ROBUST reconnect guard: an RDP (re)connect AUTHENTICATES first (RemoteConnectionManager EventID
# 1149) and only then attaches the session — which on a slow link can take many seconds. If a
# connection authenticated in the last 45 s, a connect is IN PROGRESS (however slow the handshake),
# so do NOT park the session on the console — that would kick the returning user. This decouples
# reconnect-safety from the handshake duration (a fixed debounce alone cannot).
$connecting = Get-WinEvent -FilterHashtable @{
    LogName='Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational'; Id=1149;
    StartTime=(Get-Date).AddSeconds(-45)
} -MaxEvents 1 -ErrorAction SilentlyContinue
if ($connecting) { "$(Get-Date -Format s) skip: a connection is in progress (recent 1149)" | Out-File -Append $log -Encoding utf8; return }
# Otherwise a real "walked away" disconnect: park any still-disconnected session on the console.
foreach ($ln in ((& "$env:SystemRoot\System32\quser.exe" 2>$null) | Select-Object -Skip 1)) {
    if ($ln -match '\s(\d+)\s+Disc\b') {
        $sid = $Matches[1]
        & "$env:SystemRoot\System32\tscon.exe" $sid /dest:console 2>&1 | Out-File -Append $log -Encoding utf8
        "$(Get-Date -Format s) reconnected session $sid to console" | Out-File -Append $log -Encoding utf8
    }
}
'@ | Set-Content -LiteralPath $Recon -Encoding UTF8

# ── Keep the console display awake so DWM keeps compositing (belt-and-suspenders). ──
powercfg /change monitor-timeout-ac 0
powercfg /change standby-timeout-ac 0

# ── Best-effort: stop the idle, unattended console session from LOCKING. A LOCKED session is
#    fg=0 and blanks WinUI 3 exactly like a disconnected one, and `tscon` does NOT clear a lock.
#    This hardening is SECONDARY (the reconnect task below is the real fix), so it is NON-FATAL:
#    on a managed/GPO DevBox these keys may be system-owned. Never let it abort the install.
#    NOTE: do NOT `New-Item -Force` an existing key — that tries to delete+recreate a protected
#    key ("unauthorized operation") and could wipe existing policy values. Guard with Test-Path. ──
try {
    $polSys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    if (-not (Test-Path $polSys)) { New-Item -Path $polSys -Force | Out-Null }
    New-ItemProperty -Path $polSys -Name InactivityTimeoutSecs -Value 0 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
} catch {
    Write-Warning "Idle-lock policy (InactivityTimeoutSecs) not set — likely a managed/GPO box. Continuing without it. ($($_.Exception.Message))"
}
# Screen saver + its "require password" off for the CURRENT user (the elevated user's HKCU):
try {
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveActive    -Value '0' -Force -ErrorAction Stop
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaverIsSecure -Value '0' -Force -ErrorAction Stop
    Set-ItemProperty 'HKCU:\Control Panel\Desktop' -Name ScreenSaveTimeOut   -Value '0' -Force -ErrorAction Stop
} catch {
    Write-Warning "Screen saver not disabled for the current user. Continuing. ($($_.Exception.Message))"
}

# ── Register the SYSTEM task: EVENT-DRIVEN. It fires the one-shot reconnector ($Recon) on the
#    Windows "RDP session disconnected" event (TerminalServices-LocalSessionManager, EventID 24),
#    so a disconnect is handled in ~1-2 s + the debounce (near-zero blank window, no polling grace).
#    A 1-minute poll + a boot trigger are kept only as safety nets in case an event is ever missed.
#    Before parking, the reconnector skips if a connection authenticated recently (EventID 1149), so
#    a *reconnect* is safe no matter how slow the handshake. ──
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Recon`" -DebounceSeconds $DebounceSeconds"

# Event trigger (EventID 24 = an RDP session was disconnected). Built via the CIM trigger class
# because New-ScheduledTaskTrigger has no event-trigger parameter.
$subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational"><Select Path="Microsoft-Windows-TerminalServices-LocalSessionManager/Operational">*[System[(EventID=24)]]</Select></Query></QueryList>'
$evtClass = Get-CimClass -Namespace ROOT\Microsoft\Windows\TaskScheduler -ClassName MSFT_TaskEventTrigger
$tEvent = New-CimInstance -CimClass $evtClass -ClientOnly
$tEvent.Enabled = $true
$tEvent.Subscription = $subscription
# Safety nets (only matter if an event is ever missed): a 1-minute poll + a boot trigger.
$tPoll    = New-ScheduledTaskTrigger -Once -At (Get-Date).AddSeconds(30) -RepetitionInterval (New-TimeSpan -Minutes 1)
$tStartup = New-ScheduledTaskTrigger -AtStartup

$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
  -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
# Kill any already-running (old) loop instance first, so re-running this script cleanly swaps in
# the new event-driven task (the previous version ran a forever loop).
Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($tEvent, $tPoll, $tStartup) `
  -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null

# Do NOT trust that registration "succeeded" just because we reached this line — the CIM-based
# ScheduledTasks cmdlets can surface errors that slip past $ErrorActionPreference. Confirm the
# task actually exists (and is running) before claiming success; otherwise fail loudly.
$installed = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $installed) {
    Write-Error "FAILED: scheduled task '$TaskName' was not registered — nothing was installed."
    exit 1
}

Write-Host ""
Write-Host "Installed '$TaskName' (SYSTEM; EVENT-DRIVEN on RDP disconnect, ~$($DebounceSeconds)s debounce; + 1-min safety poll)."
Write-Host "On disconnect it reconnects your session to the console so WinUI 3 apps render; it skips while a"
Write-Host "connection is authenticating (EventID 1149), so you can RDP back in — even on a slow link — unkicked."
Write-Host ""
Write-Host "VERIFY:"
Write-Host "  1) Start your benchmark, then disconnect RDP."
Write-Host "  2) Within ~$($DebounceSeconds)s it parks the session on the console; confirm captures render."
Write-Host "     e.g. pwsh -File <investigation>\Test-WinUI3Render.ps1 -Tag verify   # expect PASS-RENDERED"
Write-Host "  3) Reconnect a few times to confirm you are NOT kicked. Activity: $Dir\reconnect.log"