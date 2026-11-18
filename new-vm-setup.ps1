#Requires -RunAsAdministrator
<#
.SYNOPSIS
Installs development tools and configures Windows 11 appearance, taskbar, and input language.

.DESCRIPTION
- Set Windows and apps to Dark mode with a manual accent for the current user
- Align left
- Show the Search box; hide Task View / Chat
- Attempt to disable Widgets (including taskbar weather) for all users
- Install or update Intelligent Terminal to the latest official GitHub release
- Pin in order: File Explorer, Intelligent Terminal, Windows Terminal (release), Edge, VS Code, Everything, Visual Studio 2026
- Remove other pinned apps (best effort for current user)
- Add Simplified Chinese with Microsoft Pinyin for the current user

.PARAMETER RequireWidgetsPolicy
Report a terminating error at the end if the Widgets policy could not be verified.
All independent setup steps are still attempted first.

.PARAMETER AccentColor
Windows color preset: yellogold (default, #FFB900), green (#107C10), or plumlight (#E3008C).

.NOTES
- Failed steps are reported as warnings and summarized at the end. Dependent
    actions such as clearing pins are skipped if their prerequisites did not succeed.
- Supported model for taskbar pinning in Windows 11 is XML-based layout.
- Apply the XML through the current user's Start Layout policy, then reset pins.
- Sign out and sign back in to apply the layout. Policy refresh can restore pins
    that you manually unpin; organization policies may override these settings.
#>
param(
    [switch]$RequireWidgetsPolicy,
    [ValidateSet("yellogold", "green", "plumlight")]
    [string]$AccentColor = "yellogold"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$setupFailures = [System.Collections.Generic.List[string]]::new()

function Write-Info($msg) {
    Write-Host "[INFO] $msg" -ForegroundColor Cyan
}

function Write-Warn($msg) {
    Write-Host "[WARN] $msg" -ForegroundColor Yellow
}

function Invoke-SetupStep([string]$StepName, [scriptblock]$StepAction) {
    try {
        & $StepAction
    } catch {
        $failure = "${StepName}: $($_.Exception.Message)"
        if ($_.ErrorDetails -and $_.ErrorDetails.Message -and $_.ErrorDetails.Message -ne $_.Exception.Message) {
            $failure += " $($_.ErrorDetails.Message)"
        }
        $setupFailures.Add($failure)
        Write-Warn "$failure Continuing with the next independent step."
    }
}

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
        "--accept-package-agreements", "--accept-source-agreements", "--disable-interactivity"
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

function Find-VimDirectory {
    $ErrorActionPreference = "Stop"
    $installationRoots = @($env:ProgramW6432, $env:ProgramFiles, ${env:ProgramFiles(x86)})
    if ($env:LOCALAPPDATA) {
        $installationRoots += Join-Path $env:LOCALAPPDATA "Programs"
    }

    $candidates = @(
        foreach ($registryPath in @(
            "HKCU:\SOFTWARE\Vim\Gvim",
            "HKCU:\SOFTWARE\WOW6432Node\Vim\Gvim",
            "HKLM:\SOFTWARE\Vim\Gvim",
            "HKLM:\SOFTWARE\WOW6432Node\Vim\Gvim"
        )) {
            if (Test-Path -LiteralPath $registryPath) {
                $registeredPath = (Get-ItemProperty -LiteralPath $registryPath -ErrorAction Stop).path
                if (-not [string]::IsNullOrWhiteSpace($registeredPath)) {
                    Split-Path -Path ([Environment]::ExpandEnvironmentVariables($registeredPath.Trim().Trim('"'))) -Parent
                }
            }
        }

        foreach ($root in ($installationRoots | Where-Object { $_ } | Select-Object -Unique)) {
            $vimRoot = Join-Path $root "Vim"
            if (-not (Test-Path -LiteralPath $vimRoot -PathType Container)) { continue }
            $vimRoot
            Get-ChildItem -LiteralPath $vimRoot -Directory -Filter "vim*" -ErrorAction Stop |
                Where-Object { $_.Name -match '^vim\d+$' } |
                Sort-Object { [int]($_.Name.Substring(3)) } -Descending |
                Select-Object -ExpandProperty FullName
        }

        Get-Command vim.exe -CommandType Application -All -ErrorAction SilentlyContinue |
            ForEach-Object { Split-Path -Path $_.Source -Parent }
    )

    foreach ($candidate in ($candidates | Where-Object { $_ } | Select-Object -Unique)) {
        if (Test-Path -LiteralPath (Join-Path $candidate "vim.exe") -PathType Leaf) {
            return $candidate
        }
    }

    throw "Vim installation could not be located after installing vim.vim. Check that vim.exe exists in the installation directory."
}

function Add-PathDirectory {
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [Parameter(Mandatory=$true)][string]$Directory
    )

    $normalizedDirectory = $Directory.TrimEnd('\')
    foreach ($entry in ($Path -split ';')) {
        $expandedEntry = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        if ($expandedEntry -ieq $normalizedDirectory) { return $Path }
    }

    if ([string]::IsNullOrWhiteSpace($Path)) { return $Directory }
    return "$($Path.TrimEnd(';'));$Directory"
}

function Find-UsableGit {
    $PSNativeCommandUseErrorActionPreference = $false
    $candidates = @(
        Get-Command git.exe -CommandType Application -All -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source
        Join-Path $env:ProgramFiles "Git\cmd\git.exe"
        if (${env:ProgramFiles(x86)}) { Join-Path ${env:ProgramFiles(x86)} "Git\cmd\git.exe" }
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

function Install-LatestIntelligentTerminal {
    $name = "Microsoft.IntelligentTerminal"
    # A GitHub rate limit must not prevent a first-time installation from WinGet.
    $installed = Get-AppxPackage -Name $name -ErrorAction Stop
    if (-not $installed) {
        Install-WingetPackage -Id $name
        $installed = Get-AppxPackage -Name $name -ErrorAction Stop
    }
    $release = Invoke-RestMethod -Uri "https://api.github.com/repos/microsoft/intelligent-terminal/releases/latest" -TimeoutSec 30 -ErrorAction Stop
    $bundles = @($release.assets | Where-Object { $_.name -match '^Microsoft\.IntelligentTerminal_\d+\.\d+\.\d+\.\d+_8wekyb3d8bbwe\.msixbundle$' })
    if ($bundles.Count -ne 1) {
        throw "Expected one official Intelligent Terminal MSIX bundle in release '$($release.tag_name)'; found $($bundles.Count)."
    }
    $bundle = $bundles[0]
    $latest = [version]($bundle.name.Split('_')[1])
    if ($installed -and [version]$installed.Version -ge $latest) {
        Write-Info "Intelligent Terminal $($installed.Version) is installed (latest release: $latest)."
        return
    }

    # Also handle an older installation or a WinGet catalog that trails the GitHub release.
    Write-Info "Installing Intelligent Terminal $latest from the official release..."
    $downloadPath = Join-Path ([IO.Path]::GetTempPath()) "$([guid]::NewGuid()).msixbundle"
    try {
        Invoke-WebRequest -Uri $bundle.browser_download_url -UseBasicParsing -OutFile $downloadPath -ErrorAction Stop
        $hash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash
        if ("sha256:$hash" -ne $bundle.digest) {
            throw "Intelligent Terminal download does not match the SHA-256 digest for release '$($release.tag_name)'."
        }
        Add-AppxPackage -Path $downloadPath -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $downloadPath) { Remove-Item -LiteralPath $downloadPath -Force }
    }
    $installed = Get-AppxPackage -Name $name -ErrorAction Stop
    if (-not $installed -or [version]$installed.Version -lt $latest) {
        throw "Intelligent Terminal $latest is not registered for the current user after installation."
    }
    Write-Info "Verified Intelligent Terminal $($installed.Version) for the current user."
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

function Set-SetupRegistryValue([string]$Path, [string]$Name, $Value, [Microsoft.Win32.RegistryValueKind]$Type = "DWord") {
    Invoke-SetupStep "$Path\$Name" {
        if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -ErrorAction Stop | Out-Null }
        Set-ItemProperty -LiteralPath $Path -Name $Name -Type $Type -Value $Value -ErrorAction Stop
    }
}

# Windows accent DWORDs use AABBGGRR, not web RGB order.
$yellowGold = 0xFF00B9FF  # #FFB900
$green      = 0xFF107C10  # #107C10
$plumLight  = 0xFF8C00E3  # #E3008C

# Explorer shades in BBGGRR order: Light3, Light2, Light1, accent, Dark1, Dark2, Dark3.
$accentPresets = @{
    "yellogold" = 0x45E8FF, 0x2AD5FF, 0x0DC2FF, $yellowGold, 0x009DE1, 0x005D9B, 0x00215C
    "green"     = 0x81EF95, 0x32E545, 0x15A119, $green,      0x0E6D0E, 0x084B08, 0x032B03
    "plumlight" = 0xEE94FF, 0xCB4FFF, 0xA404FF, $plumLight,  0x7B00CD, 0x530099, 0x2E0069
}

function Set-DarkAppearance([int[]]$Shades) {
    $currentVersion = "HKCU:\Software\Microsoft\Windows\CurrentVersion"
    $personalize = "$currentVersion\Themes\Personalize"
    $accent = "$currentVersion\Explorer\Accent"
    $dwm = "HKCU:\Software\Microsoft\Windows\DWM"
    $desktop = "HKCU:\Control Panel\Desktop"
    Set-SetupRegistryValue $personalize "SystemUsesLightTheme" 0
    Set-SetupRegistryValue $personalize "AppsUseLightTheme" 0
    Set-SetupRegistryValue $desktop "AutoColorization" 0

    # Each entry is four bytes (R, G, B, 0); keep the existing eighth legacy slot.
    [byte[]]$palette = foreach ($shade in ($Shades + 0x94B200)) {
        [BitConverter]::GetBytes($shade -band 0xFFFFFF)
    }
    Set-SetupRegistryValue $accent "AccentPalette" $palette Binary
    $selectAccentColor = $Shades[3]
    $startColor = 0xFF000000 -bor $Shades[4]
    # DWM ColorizationColor uses AARRGGBB; bytes 12..14 are the central accent.
    $colorizationColor = 0xC4000000 -bor ([int]$palette[12] -shl 16) -bor ([int]$palette[13] -shl 8) -bor $palette[14]
    Set-SetupRegistryValue $accent "AccentColorMenu" $selectAccentColor
    Set-SetupRegistryValue $accent "StartColorMenu" $startColor
    Set-SetupRegistryValue $dwm "AccentColor" $selectAccentColor
    Set-SetupRegistryValue $dwm "ColorizationColor" $colorizationColor
}

function Disable-WidgetsForAllUsers {
    $path = "HKLM:\SOFTWARE\Policies\Microsoft\Dsh"
    $name = "AllowNewsAndInterests"
    try {
        $value = $null
        if (Test-Path -LiteralPath $path -ErrorAction Stop) {
            $value = (Get-Item -LiteralPath $path -ErrorAction Stop).GetValue($name)
        } else {
            New-Item -Path $path -ErrorAction Stop | Out-Null
        }
        if ($value -isnot [int] -or $value -ne 0) {
            New-ItemProperty -LiteralPath $path -Name $name -PropertyType DWord -Value 0 -Force -ErrorAction Stop | Out-Null
            $value = Get-ItemPropertyValue -LiteralPath $path -Name $name -ErrorAction Stop
            if ($value -isnot [int] -or $value -ne 0) {
                throw "Could not verify '$path\$name': expected REG_DWORD 0, found '$value'."
            }
        }
    } catch [System.UnauthorizedAccessException], [System.Security.SecurityException] {
        throw "Windows denied access to '$path\$name'. Could not confirm Widgets are disabled for all users. On a managed device, ask your administrator to disable the 'Allow widgets' policy."
    }
    Write-Info "Verified '$path\$name' is REG_DWORD 0 (Widgets disabled by machine policy)."
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

function Get-VisualStudioShortcut {
    $vsLink = Find-Shortcut -Patterns @("Visual Studio 2026*.lnk")
    if ($vsLink) { return $vsLink }
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
        return $vsLink
    }
    throw "Visual Studio 2026 shortcut not found, and devenv.exe was not found at '$vsExecutable'."
}

function Set-TaskbarPreferences([string]$HiveRoot) {
    $base = "$HiveRoot\Software\Microsoft\Windows\CurrentVersion"
    Set-SetupRegistryValue "$base\Explorer\Advanced" "TaskbarAl" 0
    Set-SetupRegistryValue "$base\Search" "SearchboxTaskbarMode" 2
    Set-SetupRegistryValue "$base\Search" "SearchboxTaskbarModeCache" 2
    Set-SetupRegistryValue "$base\Explorer\Advanced" "ShowTaskViewButton" 0
    Set-SetupRegistryValue "$base\Explorer\Advanced" "TaskbarMn" 0
    Set-SetupRegistryValue "$base\Dsh" "IsPrelaunchEnabled" 0
}

function Set-DefaultProfileTaskbar {
    $hive = "VMSetupDefault_$([guid]::NewGuid().ToString('N'))"
    $ntUser = Join-Path $env:SystemDrive "Users\Default\NTUSER.DAT"
    & reg.exe load "HKLM\$hive" $ntUser
    if ($LASTEXITCODE -ne 0) { throw "Could not load '$ntUser' (reg.exe exit code $LASTEXITCODE); no defaults were written." }
    try {
        Set-TaskbarPreferences "HKLM:\$hive"
    } finally {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        & reg.exe unload "HKLM\$hive"
        if ($LASTEXITCODE -ne 0) { throw "Could not unload 'HKLM\$hive' (reg.exe exit code $LASTEXITCODE)." }
    }
}

function New-TaskbarLayout([string]$VsLink) {
    foreach ($name in "Microsoft.IntelligentTerminal", "Microsoft.WindowsTerminal") {
        if (-not (Get-AppxPackage -Name $name -ErrorAction Stop)) {
            throw "$name is not registered for the current user; keeping existing pins."
        }
    }
    $edgeLink = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Microsoft Edge.lnk"
    if (-not (Test-Path -LiteralPath $edgeLink -PathType Leaf)) {
        $edgeLink = Find-Shortcut -Patterns @("Microsoft Edge.lnk", "*Edge*.lnk")
    }
    $vscodeLink = Find-Shortcut -Patterns @("Visual Studio Code.lnk", "VS Code.lnk", "*Code*.lnk")
    $everythingLink = Find-Shortcut -Patterns "Everything.lnk"
    if (-not $edgeLink)       { throw "Microsoft Edge shortcut not found; keeping existing pins." }
    if (-not $vscodeLink)     { throw "Visual Studio Code shortcut not found; keeping existing pins." }
    if (-not $everythingLink) { throw "Everything.lnk not found; keeping existing pins." }
    if (-not $vsLink)         { throw "Visual Studio shortcut unavailable; keeping existing pins." }

    $edgeEsc = Escape-XmlAttr $edgeLink
    $vscodeEsc = Escape-XmlAttr $vscodeLink
    $everythingEsc = Escape-XmlAttr $everythingLink
    $vsEsc = Escape-XmlAttr $vsLink

    return @"
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
        <taskbar:UWA AppUserModelID="Microsoft.IntelligentTerminal_8wekyb3d8bbwe!App" />
        <taskbar:UWA AppUserModelID="Microsoft.WindowsTerminal_8wekyb3d8bbwe!App" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$edgeEsc" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$vscodeEsc" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$everythingEsc" />
        <taskbar:DesktopApp DesktopApplicationLinkPath="$vsEsc" />
      </taskbar:TaskbarPinList>
    </defaultlayout:TaskbarLayout>
  </CustomTaskbarLayoutCollection>
</LayoutModificationTemplate>
"@
}

function Write-TaskbarLayout([string]$Directory, [string]$Xml) {
    Ensure-Dir $Directory
    $file = Join-Path $Directory "LayoutModification.xml"
    Set-Content -LiteralPath $file -Value $Xml -Encoding UTF8
    Write-Info "Layout written to '$file'."
    return $file
}

function Set-PinyinLanguage {
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
}

function Set-StartLayoutPolicy([string]$LayoutFile) {
    $layoutPolicyPath = "HKCU:\Software\Policies\Microsoft\Windows\Explorer"
    $layout = [xml](Get-Content -LiteralPath $LayoutFile -Raw)
    if ($layout.DocumentElement.LocalName -ne "LayoutModificationTemplate") { throw "Invalid taskbar layout in '$LayoutFile'." }
    if (-not (Test-Path -LiteralPath $layoutPolicyPath)) {
        New-Item -Path $layoutPolicyPath -ErrorAction Stop | Out-Null
    }
    New-ItemProperty -LiteralPath $layoutPolicyPath -Name "StartLayoutFile" -Value $LayoutFile -PropertyType ExpandString -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -LiteralPath $layoutPolicyPath -Name "LockedStartLayout" -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
}

function Reset-TaskbarPins {
    try {
        $sessionId = (Get-Process -Id $PID).SessionId
        $explorerProcesses = Get-Process explorer -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $sessionId }
        foreach ($process in $explorerProcesses) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            $process | Wait-Process -ErrorAction SilentlyContinue
        }

        $taskbandKey = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband"
        if (Test-Path $taskbandKey) { Remove-Item -LiteralPath $taskbandKey -Recurse -Force -ErrorAction Stop }

        $userPinnedTaskbar = Join-Path $env:APPDATA "Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar"
        if (Test-Path $userPinnedTaskbar) {
            Get-ChildItem -LiteralPath $userPinnedTaskbar -Force -ErrorAction Stop | Remove-Item -Force -Recurse -ErrorAction Stop
        }
    } finally {
        Invoke-SetupStep "Restart Explorer" { Start-Process explorer.exe -ErrorAction Stop }
    }
}

function Update-TaskbarLayout {
    $vsLink = Invoke-SetupStep "Resolve Visual Studio shortcut" { Get-VisualStudioShortcut }
    $xml = Invoke-SetupStep "Prepare seven-pin taskbar layout" { New-TaskbarLayout $vsLink }
    if (-not $xml) { return }

    Invoke-SetupStep "Default profile layout file" {
        Write-TaskbarLayout (Join-Path $env:SystemDrive "Users\Default\AppData\Local\Microsoft\Windows\Shell") $xml | Out-Null
    }
    $localFile = Invoke-SetupStep "Current user local layout file" {
        Write-TaskbarLayout (Join-Path $env:LOCALAPPDATA "Microsoft\Windows\Shell") $xml
    }
    Invoke-SetupStep "Current user roaming layout file" {
        Write-TaskbarLayout (Join-Path $env:APPDATA "Microsoft\Windows\Shell") $xml | Out-Null
    }
    if (-not $localFile) {
        Write-Warn "No new local layout file; skipping layout policy and pin reset."
        return
    }
    Invoke-SetupStep "Apply Start Layout policy and reset pins" {
        Set-StartLayoutPolicy $localFile
        Write-Info "Start Layout policy applied; policy refresh may restore unpinned apps."
        Reset-TaskbarPins
    }
}

foreach ($id in "Microsoft.WindowsTerminal", "vim.vim", "Rustlang.Rustup") {
    Invoke-SetupStep "Install $id" { Install-WingetPackage -Id $id }
}
$vimDirectory = Invoke-SetupStep "Locate Vim for PATH" { Find-VimDirectory }
if ($vimDirectory) {
    Invoke-SetupStep "Vim user PATH" {
        $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
        $updated = Add-PathDirectory -Path $userPath -Directory $vimDirectory
        if ($updated -cne $userPath) { [Environment]::SetEnvironmentVariable("Path", $updated, "User") }
    }
    Invoke-SetupStep "Vim session PATH" {
        $env:Path = Add-PathDirectory -Path $env:Path -Directory $vimDirectory
    }
}
Invoke-SetupStep "Install Git" {
    $git = Find-UsableGit
    if ($git) { Write-Info "Usable Git found at $git; skipping installation." }
    else { Install-WingetPackage -Id "Git.Git" }
}
Invoke-SetupStep "Git init.defaultBranch" {
    $git = Find-UsableGit
    if (-not $git) { throw "No usable Git installation found." }
    & $git config --global init.defaultBranch main
    if ($LASTEXITCODE -ne 0) { throw "git config failed (exit code $LASTEXITCODE)." }
}

foreach ($id in "OpenJS.NodeJS.LTS", "Microsoft.PowerShell") {
    Invoke-SetupStep "Install $id" { Install-WingetPackage -Id $id }
}
Invoke-SetupStep "Install Microsoft.VisualStudioCode" {
    Install-WingetPackage -Id "Microsoft.VisualStudioCode" -Override '/VERYSILENT /NORESTART /MERGETASKS="addcontextmenufiles,addcontextmenufolders,addtopath"'
}
Invoke-SetupStep "Install Anaconda.Miniconda3" {
    Install-WingetPackage -Id "Anaconda.Miniconda3" -MinicondaDirectory "C:\Miniconda" -Override "/InstallationType=AllUsers /RegisterPython=1 /S /D=C:\Miniconda"
}
foreach ($id in "Microsoft.DotNet.SDK.9", "Microsoft.DotNet.SDK.10", "Microsoft.NuGet", "GitHub.Copilot", "Microsoft.PowerToys") {
    Invoke-SetupStep "Install $id" { Install-WingetPackage -Id $id }
}
Invoke-SetupStep "Intelligent Terminal installation / latest release check" { Install-LatestIntelligentTerminal }
Invoke-SetupStep "Install Everything" {
    if (-not (Find-Shortcut -Patterns "Everything.lnk")) { Install-WingetPackage -Id "voidtools.Everything" }
}

Invoke-SetupStep "Dark mode and $AccentColor accent" { Set-DarkAppearance -Shades $accentPresets[$AccentColor] }
$widgetsVerified = Invoke-SetupStep "Disable Widgets for all users" { Disable-WidgetsForAllUsers; $true }
Invoke-SetupStep "Current user taskbar settings" { Set-TaskbarPreferences "HKCU:" }
Invoke-SetupStep "Default profile taskbar settings" { Set-DefaultProfileTaskbar }
Invoke-SetupStep "Simplified Chinese and Microsoft Pinyin" { Set-PinyinLanguage }
Invoke-SetupStep "Taskbar layout" { Update-TaskbarLayout }

if ($setupFailures.Count) {
    Write-Warn "Finished with $($setupFailures.Count) failed step(s):"
    foreach ($failure in $setupFailures) { Write-Warn "  - $failure" }
} else {
    Write-Info "Done."
}
Write-Info "Sign out and sign back in to refresh the settings that were applied."
if ($RequireWidgetsPolicy -and -not $widgetsVerified) {
    throw "Other setup steps have finished, but the required Widgets policy was not verified."
}
