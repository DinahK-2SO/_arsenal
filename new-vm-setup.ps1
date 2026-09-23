function Install-WingetPackage {
    param(
        [Parameter(Mandatory=$true)][string]$Id,
        [string]$Override,
        [string]$MinicondaDirectory
    )

    $ErrorActionPreference = "Stop"
    $PSNativeCommandUseErrorActionPreference = $false

    if ($MinicondaDirectory -and
        (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "python.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "Scripts\conda.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "conda-meta\history") -PathType Leaf)) {
        Write-Host "[INFO] Miniconda already exists at $MinicondaDirectory; skipping installation." -ForegroundColor Cyan
        return
    }

    $repairMiniconda = $Id -eq "Anaconda.Miniconda3" -and $MinicondaDirectory -eq "C:\Miniconda" -and
        (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "_conda.exe") -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "install.log") -PathType Leaf) -and
        (-not (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "python.exe") -PathType Leaf)) -and
        (-not (Test-Path -LiteralPath (Join-Path $MinicondaDirectory "Scripts\conda.exe") -PathType Leaf))

    $installedOutput = & winget list --id $Id --exact --accept-source-agreements --disable-interactivity 2>&1
    $listExitCode = $LASTEXITCODE
    if ($listExitCode -eq 0 -and -not $repairMiniconda) {
        Write-Host "[INFO] $Id is already installed; skipping installation." -ForegroundColor Cyan
        return
    }
    if ($listExitCode -notin @(0, -1978335212)) {
        throw "Could not check whether $Id is installed (winget exit code $listExitCode). $($installedOutput -join ' ')"
    }

    if ($MinicondaDirectory -and (Test-Path -LiteralPath $MinicondaDirectory)) {
        if ($repairMiniconda) {
            Write-Warning "Removing incomplete Miniconda installation at '$MinicondaDirectory' before reinstalling. All files in this directory will be deleted."
            Remove-Item -LiteralPath $MinicondaDirectory -Recurse -Force -ErrorAction Stop
        }
        elseif (-not (Test-Path -LiteralPath $MinicondaDirectory -PathType Container) -or
            (Get-ChildItem -LiteralPath $MinicondaDirectory -Force | Select-Object -First 1)) {
            throw "Miniconda destination '$MinicondaDirectory' is not an empty directory or a recognized installation. Inspect it before retrying; no files were removed."
        }
    }

    $installArguments = @(
        "install", "--id", $Id, "--exact", "--source", "winget",
        "--accept-package-agreements", "--accept-source-agreements"
    )
    if ($repairMiniconda) {
        $installArguments += "--force"
    }
    else {
        $installArguments += "--no-upgrade"
    }
    if ($Override) {
        $installArguments += @("--override", $Override)
    }

    & winget @installArguments
    if ($LASTEXITCODE -ne 0) {
        throw "Installation of $Id failed (winget exit code $LASTEXITCODE)."
    }
    if ($MinicondaDirectory) {
        foreach ($relativePath in @("python.exe", "Scripts\conda.exe", "conda-meta\history")) {
            if (-not (Test-Path -LiteralPath (Join-Path $MinicondaDirectory $relativePath) -PathType Leaf)) {
                throw "Miniconda installation is incomplete: '$relativePath' is missing from '$MinicondaDirectory'. Check the installer log."
            }
        }
    }
}

Install-WingetPackage -Id "Microsoft.WindowsTerminal"

Install-WingetPackage -Id "Rustlang.Rustup"

function Find-UsableGit {
    $PSNativeCommandUseErrorActionPreference = $false
    $candidates = @(
        Get-Command git.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        Join-Path $env:ProgramFiles "Git\cmd\git.exe"
        Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe"
        Join-Path $env:LOCALAPPDATA "Programs\Git\cmd\git.exe"
    ) | Select-Object -Unique

    foreach ($candidate in $candidates) {
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) { continue }
        try {
            $version = & $candidate --version 2>&1
            if ($LASTEXITCODE -eq 0 -and ($version -join ' ') -match '^git version ') {
                return $candidate
            }
        }
        catch {
            continue
        }
    }

    return $null
}

$gitExecutable = Find-UsableGit
if ($gitExecutable) {
    Write-Host "[INFO] Usable Git found at $gitExecutable; skipping installation." -ForegroundColor Cyan
}
else {
    Install-WingetPackage -Id "Git.Git"
    $gitExecutable = Find-UsableGit
    if (-not $gitExecutable) { throw "No usable Git found after installation. Check the Git installation and PATH." }
}

& $gitExecutable config --global init.defaultBranch main
if ($LASTEXITCODE -ne 0) { throw "Could not set Git init.defaultBranch to main (exit code $LASTEXITCODE)." }

Install-WingetPackage -Id "OpenJS.NodeJS.LTS"

Install-WingetPackage -Id "Microsoft.PowerShell"

Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Override '/VERYSILENT /NORESTART /MERGETASKS="addcontextmenufiles,addcontextmenufolders,addtopath"'

Install-WingetPackage -Id "Anaconda.Miniconda3" -MinicondaDirectory "C:\Miniconda" -Override "/InstallationType=AllUsers /RegisterPython=1 /S /D=C:\Miniconda"

Install-WingetPackage -Id "Microsoft.DotNet.SDK.9"

Install-WingetPackage -Id "Microsoft.DotNet.SDK.10"

Install-WingetPackage -Id "Microsoft.NuGet"

Install-WingetPackage -Id "GitHub.Copilot"

Install-WingetPackage -Id "Microsoft.PowerToys"



#Requires -RunAsAdministrator
<#
.SYNOPSIS
Configures Windows 11 taskbar:
- Align left
- Show the Search box; hide Task View / Chat / Widgets
- Disable Widgets (including taskbar weather) for all users
- Keep only: Explorer, Windows Terminal (release), Edge, VS Code, Visual Studio 2026 (in that order)
- Remove other pinned apps (best effort for current user)
- Add Simplified Chinese with Microsoft Pinyin for the current user

.NOTES
- Supported model for taskbar pinning in Windows 11 is XML-based layout.
- Apply the XML through the current user's Start Layout policy, then reset pins.
- Sign out and sign back in to apply the layout. Policy refresh can restore pins
    that you manually unpin; organization policies may override these settings.
#>

$ErrorActionPreference = "Stop"

function Write-Info($msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Escape-XmlAttr([string]$s) {
    if ($null -eq $s) { return $null }
    return $s.Replace("&", "&amp;").Replace("<", "&lt;").Replace(">", "&gt;").Replace('"', "&quot;").Replace("'", "&apos;")
}

function Ensure-Dir([string]$path) {
    if (-not (Test-Path $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

function Set-DwordValue([string]$Path, [string]$Name, [int]$Value, [switch]$Required) {
    $PSNativeCommandUseErrorActionPreference = $false
    $registryPath = $Path -replace '^Registry::', '' -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'
    $output = & reg.exe add $registryPath /v $Name /t REG_DWORD /d $Value /f 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($Required) {
            throw "Required registry setting '$registryPath\$Name' was not applied (reg.exe exit code $LASTEXITCODE). Check administrator elevation and organization policy. $($output -join ' ')"
        }
        Write-Warn "Could not set '$registryPath\$Name'; continuing. $($output -join ' ')"
        return
    }
    if ($Required) {
        $actualValue = Get-ItemPropertyValue -LiteralPath $Path -Name $Name -ErrorAction Stop
        if ($actualValue -ne $Value) {
            throw "Required registry setting '$registryPath\$Name' could not be verified: expected $Value, found $actualValue."
        }
    }
}

function Find-Shortcut {
    param(
        [Parameter(Mandatory=$true)][string[]]$Patterns
    )

    $roots = @(
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs"
    ) | Where-Object { Test-Path $_ }

    foreach ($root in $roots) {
        foreach ($pattern in $Patterns) {
            $match = Get-ChildItem -Path $root -Filter "*.lnk" -File -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like $pattern } |
                Sort-Object FullName |
                Select-Object -First 1
            if ($match) {
                return $match.FullName
            }
        }
    }

    return $null
}

Write-Info "Resolving shortcuts..."

if (-not (Get-AppxPackage -Name "Microsoft.WindowsTerminal" -ErrorAction Stop)) {
    throw "Windows Terminal (release) is not installed for the current user. Install it before resetting taskbar pins."
}

# Edge is typically available in ProgramData Start Menu.
$edgeLink = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
if (-not (Test-Path $edgeLink)) {
    $edgeLink = Find-Shortcut -Patterns @("Microsoft Edge.lnk", "*Edge*.lnk")
}

$vscodeLink = Find-Shortcut -Patterns @("Visual Studio Code.lnk", "VS Code.lnk", "*Code*.lnk")
$vsLink     = Find-Shortcut -Patterns @("Visual Studio 2026*.lnk")

if (-not $vsLink) {
    $vsExecutable = Join-Path $env:ProgramFiles "Microsoft Visual Studio\18\Enterprise\Common7\IDE\devenv.exe"
    if (Test-Path -LiteralPath $vsExecutable -PathType Leaf) {
        $vsPrograms = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs"
        Ensure-Dir $vsPrograms
        $vsLink = Join-Path $vsPrograms "Visual Studio 2026.lnk"
        $shortcutShell = New-Object -ComObject WScript.Shell
        $vsShortcut = $shortcutShell.CreateShortcut($vsLink)
        $vsShortcut.TargetPath = $vsExecutable
        $vsShortcut.WorkingDirectory = Split-Path -Path $vsExecutable -Parent
        $vsShortcut.IconLocation = "$vsExecutable,0"
        $vsShortcut.Save()
    }
}

if (-not $edgeLink)   { throw "Microsoft Edge shortcut not found." }
if (-not $vscodeLink) { throw "Visual Studio Code shortcut not found." }
if (-not $vsLink)     { throw "Visual Studio 2026 shortcut not found, and devenv.exe was not found at '$vsExecutable'. Check the installation path before resetting taskbar pins." }

Write-Info "Edge   : $edgeLink"
Write-Info "VS Code: $vscodeLink"
Write-Info "VS     : $vsLink"

# -----------------------------
# 1) Current user taskbar look
# -----------------------------
Write-Info "Disabling Widgets (including taskbar weather) for all users..."
Set-DwordValue -Path "HKLM:\SOFTWARE\Policies\Microsoft\Dsh" -Name "AllowNewsAndInterests" -Value 0 -Required

Write-Info "Setting taskbar alignment and built-in taskbar items for current user..."

# Left align
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarAl" -Value 0

# Show the Search box
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarMode" -Value 2
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Search" -Name "SearchboxTaskbarModeCache" -Value 2

# Hide Task View / Chat
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "ShowTaskViewButton" -Value 0
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" -Name "TaskbarMn" -Value 0

# Do not open the Widgets board on hover
Set-DwordValue -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Dsh" -Name "IsPrelaunchEnabled" -Value 0

# ---------------------------------------------------------
# 2) Default user settings (so new users inherit the layout)
# ---------------------------------------------------------
Write-Info "Updating Default User hive so future profiles get the same taskbar settings..."

$defaultHiveName = "HKLM\TempDefaultUser"
$defaultNtUser   = "C:\Users\Default\NTUSER.DAT"

if (Test-Path $defaultNtUser) {
    & reg.exe load $defaultHiveName $defaultNtUser | Out-Null

    try {
        $duExplorer = "Registry::$defaultHiveName\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced"
        $duSearch   = "Registry::$defaultHiveName\Software\Microsoft\Windows\CurrentVersion\Search"
        $duDsh      = "Registry::$defaultHiveName\Software\Microsoft\Windows\CurrentVersion\Dsh"

        Set-DwordValue -Path $duExplorer -Name "TaskbarAl" -Value 0
        Set-DwordValue -Path $duExplorer -Name "ShowTaskViewButton" -Value 0
        Set-DwordValue -Path $duExplorer -Name "TaskbarMn" -Value 0

        Set-DwordValue -Path $duSearch -Name "SearchboxTaskbarMode" -Value 2
        Set-DwordValue -Path $duSearch -Name "SearchboxTaskbarModeCache" -Value 2
        Set-DwordValue -Path $duDsh -Name "IsPrelaunchEnabled" -Value 0
    }
    finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload $defaultHiveName | Out-Null
    }
}
else {
    Write-Warn "Default user hive not found at $defaultNtUser. Skipping new-user registry defaults."
}

# -----------------------------------
# 3) Build LayoutModification XML file
# -----------------------------------
Write-Info "Generating LayoutModification.xml..."

$edgeEsc   = Escape-XmlAttr $edgeLink
$vscodeEsc = Escape-XmlAttr $vscodeLink
$vsEsc     = Escape-XmlAttr $vsLink

$xml = @"
<?xml version="1.0" encoding="utf-8"?>
<LayoutModificationTemplate
    xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification"
    xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout"
    xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout"
    xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout"
    Version="1">
  <CustomTaskbarLayoutCollection PinListPlacement="Replace">
    <defaultlayout:TaskbarLayout>
      <taskbar:TaskbarPinList>
        <taskbar:DesktopApp DesktopApplicationID="Microsoft.Windows.Explorer" />
                <taskbar:UWA AppUserModelID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$edgeEsc" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$vscodeEsc" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$vsEsc" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@

# Default user layout (future profiles)
$defaultShell = "C:\Users\Default\AppData\Local\Microsoft\Windows\Shell"
Ensure-Dir $defaultShell
$defaultLayoutFile = Join-Path $defaultShell "LayoutModification.xml"
Set-Content -Path $defaultLayoutFile -Value $xml -Encoding UTF8

# Current user layout locations (best effort)
$currentShellLocal   = Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Shell"
$currentShellRoaming = Join-Path $env:APPDATA "Microsoft\Windows\Shell"
Ensure-Dir $currentShellLocal
Ensure-Dir $currentShellRoaming

Set-Content -Path (Join-Path $currentShellLocal "LayoutModification.xml") -Value $xml -Encoding UTF8
Set-Content -Path (Join-Path $currentShellRoaming "LayoutModification.xml") -Value $xml -Encoding UTF8

Write-Info "Layout XML written to:"
Write-Host "  $defaultLayoutFile"
Write-Host "  $(Join-Path $currentShellLocal 'LayoutModification.xml')"
Write-Host "  $(Join-Path $currentShellRoaming 'LayoutModification.xml')"

# -----------------------------------------------------
# 4) Current user Simplified Chinese and Microsoft Pinyin
# -----------------------------------------------------
Write-Info "Adding Simplified Chinese with Microsoft Pinyin for current user..."

$languageList = Get-WinUserLanguageList
$simplifiedChinese = $languageList | Where-Object { $_.LanguageTag -eq "zh-CN" } | Select-Object -First 1

if (-not $simplifiedChinese) {
    $simplifiedChinese = (New-WinUserLanguageList -Language "zh-CN")[0]
    $languageList.Add($simplifiedChinese)
}

$microsoftPinyinTip = "0804:{FA550B04-5AD7-411F-A5AC-CA038EC515D7}{6A498709-E00B-4C45-A018-8F9E4081AE40}"
if ($microsoftPinyinTip -notin $simplifiedChinese.InputMethodTips) {
    $simplifiedChinese.InputMethodTips.Add($microsoftPinyinTip)
}

Set-WinUserLanguageList -LanguageList $languageList -Force

# ---------------------------------------------------------
# 5) Best-effort reset of current user's pinned taskbar apps
# ---------------------------------------------------------
Write-Info "Resetting current user's pinned taskbar items (best effort)..."

Write-Info "Applying the current user's Start Layout policy before clearing pins..."
$layoutPolicyPath = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
$currentLayoutFile = Join-Path $currentShellLocal "LayoutModification.xml"
$null = [xml](Get-Content -LiteralPath $currentLayoutFile -Raw)
if (-not (Test-Path $layoutPolicyPath)) {
    New-Item -Path $layoutPolicyPath -Force -ErrorAction Stop | Out-Null
}
New-ItemProperty -Path $layoutPolicyPath -Name "StartLayoutFile" -Value $currentLayoutFile -PropertyType ExpandString -Force -ErrorAction Stop | Out-Null
New-ItemProperty -Path $layoutPolicyPath -Name "LockedStartLayout" -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null

try {
    $sessionId = (Get-Process -Id $PID).SessionId
    $explorerProcesses = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }
    $explorerProcesses | Stop-Process -Force -ErrorAction Stop
    $explorerProcesses | Wait-Process -ErrorAction SilentlyContinue

    $taskbandKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
    if (Test-Path $taskbandKey) {
        Remove-Item -Path $taskbandKey -Recurse -Force -ErrorAction Stop
    }

    $userPinnedTaskbar = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
    if (Test-Path $userPinnedTaskbar) {
        Get-ChildItem $userPinnedTaskbar -Force -ErrorAction Stop | Remove-Item -Force -Recurse -ErrorAction Stop
    }
}
finally {
    Write-Info "Restarting Explorer..."
    Start-Process explorer.exe
}

Write-Host ""
Write-Host "Done." -ForegroundColor Green
Write-Host "Sign out and sign back in to apply: Search box, File Explorer, Windows Terminal (release), Edge, VS Code, Visual Studio 2026." -ForegroundColor Green
Write-Warn "The Start Layout policy remains enabled and may restore these pins on policy refresh. Organization policies may override it."


