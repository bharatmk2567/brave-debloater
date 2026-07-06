#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Brave Browser Debloater for Windows
    Disables non-core Brave features to mimic Brave Origin

.DESCRIPTION
    This script applies Group Policy registry entries to disable:
      - Brave News
      - Brave Rewards & Ads
      - Brave Wallet & Web3
      - Speedreader
      - Telemetry (P3A, daily usage ping, metrics)
      - Brave Talk
      - Tor private windows
      - Brave VPN
      - Wayback Machine integration
      - Web Discovery Project

    WARNING: Some policies cause Brave v147+ to crash even on Windows:
      - BraveAIChatEnabled (Leo AI)  - Toggle via brave://settings/leo instead
      - SyncDisabled                  - Breaks browser state restoration
      - PromotionsEnabled, BackgroundModeEnabled, BrowserSignin - Not in
        Brave Origin spec; may cause instability

    You must run this script as Administrator.

.USAGE
    Right-click PowerShell -> Run as Administrator
    Set-ExecutionPolicy -Scope Process RemoteSigned
    .\debloat-brave-windows.ps1                # Apply debloat (all features)
    .\debloat-brave-windows.ps1 -Interactive   # Choose which features to disable
    .\debloat-brave-windows.ps1 -DryRun       # Preview what would change
    .\debloat-brave-windows.ps1 -Restore      # Restore from a previous backup
    .\debloat-brave-windows.ps1 -Uninstall    # Remove all managed policies
    .\debloat-brave-windows.ps1 -Help          # Show help
#>

[CmdletBinding()]
param(
    [switch]$Restore,
    [switch]$DryRun,
    [switch]$Uninstall,
    [switch]$Interactive,
    [switch]$Help
)

$ErrorActionPreference = "Stop"

# Configuration
$RegPath = "HKLM:\SOFTWARE\Policies\BraveSoftware\Brave"
$BackupDir = Join-Path $env:USERPROFILE ".brave-debloat-backups"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

# All available policies with descriptions and safety flags.
# Safe=$true means offered in interactive mode.
# Safe=$false means excluded (known crash-causer or not in Brave Origin spec).
$AllPolicies = [ordered]@{
    BraveRewardsDisabled        = @{ Value = 1;  Type = "DWord"; Desc = "Brave Rewards & Ads"; Safe = $true }
    BraveWalletDisabled         = @{ Value = 1;  Type = "DWord"; Desc = "Brave Wallet & Web3"; Safe = $true }
    BraveVPNDisabled            = @{ Value = 1;  Type = "DWord"; Desc = "Brave VPN"; Safe = $true }
    BraveNewsDisabled           = @{ Value = 1;  Type = "DWord"; Desc = "Brave News"; Safe = $true }
    BraveTalkDisabled           = @{ Value = 1;  Type = "DWord"; Desc = "Brave Talk"; Safe = $true }
    TorDisabled                 = @{ Value = 1;  Type = "DWord"; Desc = "Tor private windows"; Safe = $true }
    BraveWaybackMachineEnabled  = @{ Value = 0;  Type = "DWord"; Desc = "Wayback Machine integration"; Safe = $true }
    BraveP3AEnabled             = @{ Value = 0;  Type = "DWord"; Desc = "Telemetry (P3A)"; Safe = $true }
    BraveStatsPingEnabled       = @{ Value = 0;  Type = "DWord"; Desc = "Daily usage ping"; Safe = $true }
    BraveWebDiscoveryEnabled    = @{ Value = 0;  Type = "DWord"; Desc = "Web Discovery Project"; Safe = $true }
    BraveSpeedreaderEnabled     = @{ Value = 0;  Type = "DWord"; Desc = "Speedreader"; Safe = $true }
    MetricsReportingEnabled     = @{ Value = 0;  Type = "DWord"; Desc = "Metrics reporting"; Safe = $true }
}

# Policies that will actually be applied (populated in interactive or default mode)
$Policies = [ordered]@{}

function Write-Header {
    Write-Host ""
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host "           Brave Browser Debloater for Windows" -ForegroundColor Cyan
    Write-Host "       Disables bloat to mimic Brave Origin experience" -ForegroundColor Cyan
    Write-Host "  ===============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Test-Admin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-BraveInstalled {
    $paths = @(
        "${env:ProgramFiles}\BraveSoftware\Brave-Browser\Application\brave.exe",
        "${env:ProgramFiles(x86)}\BraveSoftware\Brave-Browser\Application\brave.exe",
        "${env:LOCALAPPDATA}\BraveSoftware\Brave-Browser\Application\brave.exe"
    )
    foreach ($p in $paths) {
        if (Test-Path $p) { return $true }
    }
    $uninstall = Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*", "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -like "Brave Browser*" }
    return ($null -ne $uninstall)
}

function Test-BraveRunning {
    $proc = Get-Process -Name "brave" -ErrorAction SilentlyContinue
    return ($null -ne $proc)
}

function Invoke-Interactive {
    Write-Host ""
    Write-Host "Interactive Mode" -ForegroundColor Cyan
    Write-Host "Choose which features to disable. Press Enter to accept the default [Y/n]."
    Write-Host ""

    foreach ($policy in $AllPolicies.GetEnumerator()) {
        $name = $policy.Key
        $desc = $policy.Value.Desc
        $safe = $policy.Value.Safe

        if (-not $safe) { continue }

        $choice = Read-Host "Disable ${desc}? [Y/n]"
        if (-not $choice) { $choice = "Y" }

        if ($choice -match '^[Yy]$') {
            $Policies[$name] = $policy.Value
            Write-Host "  [OK] Will disable: $desc" -ForegroundColor Green
        } else {
            Write-Host "  [SKIPPED] $desc" -ForegroundColor Yellow
        }
        Write-Host ""
    }

    if ($Policies.Count -eq 0) {
        Write-Host "WARNING: No policies selected. Nothing to apply." -ForegroundColor Yellow
        exit 0
    }

    Write-Host ""
    Write-Host "Selected $($Policies.Count) policies to apply." -ForegroundColor Cyan
    Write-Host ""
}

function Convert-PsPathToRegExe {
    param (
        [Parameter(Mandatory=$true)]
        [string]$PsPath
    )

    # 1. Strip the PowerShell provider prefix if present (e.g., 'Registry::')
    $cleanPath = $PsPath -replace '^Registry::', ''

    # 2. Normalize forward slashes to backslashes
    $cleanPath = $cleanPath -replace '/', '\'

    # 3. Use Regex mapping to swap PowerShell drive letters with standard reg.exe hives
    switch -regex ($cleanPath) {
        '^HKLM:?\\?|^HKEY_LOCAL_MACHINE\\?'  { $cleanPath = $cleanPath -replace '^HKLM:?\\?|^HKEY_LOCAL_MACHINE\\?', 'HKLM\'; break }
        '^HKCU:?\\?|^HKEY_CURRENT_USER\\?'   { $cleanPath = $cleanPath -replace '^HKCU:?\\?|^HKEY_CURRENT_USER\\?', 'HKCU\'; break }
        '^HKCR:?\\?|^HKEY_CLASSES_ROOT\\?'   { $cleanPath = $cleanPath -replace '^HKCR:?\\?|^HKEY_CLASSES_ROOT\\?', 'HKCR\'; break }
        '^HKU:?\\?|^HKEY_USERS\\?'           { $cleanPath = $cleanPath -replace '^HKU:?\\?|^HKEY_USERS\\?', 'HKU\'; break }
        '^HKCC:?\\?|^HKEY_CURRENT_CONFIG\\?' { $cleanPath = $cleanPath -replace '^HKCC:?\\?|^HKEY_CURRENT_CONFIG\\?', 'HKCC\'; break }
    }

    # Trim any trailing backslashes
    return $cleanPath.TrimEnd('\')
}

function Backup-Registry {
    if (-not (Test-Path $RegPath)) {
        Write-Host "   No existing policies to backup." -ForegroundColor DarkGray
        return
    }

    $backupPath = Join-Path $BackupDir $Timestamp
    New-Item -ItemType Directory -Path $backupPath -Force | Out-Null

    $regFile = Join-Path $backupPath "brave-policies-backup.reg"
    $RegInfoPath = Convert-PsPathToRegExe $RegPath
    reg.exe export "$RegInfoPath" "$regFile" /y 2>&1 | Out-Null

    if ($LASTEXITCODE -eq 0) {
        Write-Host "   [OK] Backed up existing policies to: $regFile" -ForegroundColor Green
    } else {
        Write-Host "   [!] Could not export registry backup. Proceeding anyway..." -ForegroundColor Yellow
    }
}

function Set-Policies {
    param([switch]$DryRun)

    if ($DryRun) {
        Write-Host "  [DRY RUN] The following policies would be applied:" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "   Target: $RegPath" -ForegroundColor DarkGray
        Write-Host ""
        foreach ($policy in $Policies.GetEnumerator()) {
            $name = $policy.Key
            $value = $policy.Value.Value
            $type = $policy.Value.Type
            Write-Host "   Would set: $name = $value ($type)" -ForegroundColor DarkGray
        }
        Write-Host ""
        return
    }

    Write-Host "Applying Brave debloat policies..." -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path $RegPath)) {
        New-Item -Path $RegPath -Force | Out-Null
    }

    foreach ($policy in $Policies.GetEnumerator()) {
        $name = $policy.Key
        $value = $policy.Value.Value
        $type = $policy.Value.Type

        Set-ItemProperty -Path $RegPath -Name $name -Value $value -Type $type -Force
        Write-Host "   [OK] Set $name = $value" -ForegroundColor Green
    }

    Write-Host ""
    Write-Host "[OK] All policies applied successfully." -ForegroundColor Green
}

function Show-Summary {
    Write-Host ""
    Write-Host "  ===============================================================" -ForegroundColor Green
    Write-Host "    Debloating complete!" -ForegroundColor Green
    Write-Host "  ===============================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "The following features have been DISABLED:"
    foreach ($policy in $Policies.GetEnumerator()) {
        $desc = $policy.Value.Desc
        Write-Host "  * $desc"
    }
    Write-Host ""
    Write-Host "SKIPPED (crash-causing on some versions):" -ForegroundColor Yellow
    Write-Host "  * Leo AI Chat (policy can crash Brave)" -ForegroundColor Yellow
    Write-Host "  * Sync (policy breaks state restoration)" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "TIP: To disable Leo AI, go to brave://settings/leo" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "IMPORTANT: Please restart Brave Browser for changes to take effect." -ForegroundColor Yellow
    Write-Host ""
    Write-Host "You can verify policies at: brave://policy"
    Write-Host ""
    Write-Host "To undo these changes:" -ForegroundColor Cyan
    Write-Host "  .\debloat-brave-windows.ps1 -Restore" -ForegroundColor Cyan
    Write-Host "  .\debloat-brave-windows.ps1 -Uninstall" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "NOTE: You may see 'Managed by your organization' in Brave's menu." -ForegroundColor DarkGray
    Write-Host "      This is normal when policy values are active." -ForegroundColor DarkGray
    Write-Host ""
}

function Restore-Backup {
    Write-Host ""
    Write-Host "Available backups:" -ForegroundColor Cyan

    if (-not (Test-Path $BackupDir)) {
        Write-Host "   No backup directory found." -ForegroundColor Red
        return
    }

    $backups = Get-ChildItem -Path $BackupDir -Directory | Sort-Object Name

    if ($backups.Count -eq 0) {
        Write-Host "   No backups found." -ForegroundColor Red
        return
    }

    $index = 1
    foreach ($b in $backups) {
        Write-Host "  $index) $($b.Name)"
        $index++
    }
    Write-Host ""

    $choice = Read-Host "Select a backup to restore (1-$($backups.Count))"

    if ($choice -match '^\d+$') {
        $num = [int]$choice
        if ($num -ge 1 -and $num -le $backups.Count) {
            $selected = $backups[$num - 1]
            $regFile = Join-Path $selected.FullName "brave-policies-backup.reg"

            if (Test-Path $regFile) {
                Write-Host ""
                Write-Host "Restoring from: $($selected.Name)" -ForegroundColor Yellow
                $confirm = Read-Host "Are you sure? [y/N]"
                if ($confirm -match '^[Yy]$') {
                    reg.exe import "$regFile" 2>&1 | Out-Null
                    Write-Host "   [OK] Registry restored." -ForegroundColor Green
                    Write-Host "   Please restart Brave Browser." -ForegroundColor Cyan
                } else {
                    Write-Host "   Restore cancelled." -ForegroundColor DarkGray
                }
            } else {
                Write-Host "   No backup file found. Removing current policies instead..." -ForegroundColor Yellow
                $confirm = Read-Host "Remove all policies? [y/N]"
                if ($confirm -match '^[Yy]$') {
                    Remove-PoliciesAll
                }
            }
        } else {
            Write-Host "   Invalid selection." -ForegroundColor Red
        }
    } else {
        Write-Host "   Invalid input." -ForegroundColor Red
    }
}

function Remove-PoliciesAll {
    if (Test-Path $RegPath) {
        Remove-Item -Path $RegPath -Recurse -Force
        Write-Host "   [OK] Removed all managed policies." -ForegroundColor Green
    } else {
        Write-Host "   No managed policies found. Nothing to remove." -ForegroundColor DarkGray
    }
    Write-Host ""
    Write-Host "   All policies removed. Please restart Brave Browser." -ForegroundColor Cyan
}

function Uninstall-Policies {
    Write-Host ""
    if (-not (Test-Path $RegPath)) {
        Write-Host "No managed policies found. Nothing to remove." -ForegroundColor DarkGray
        return
    }
    Write-Host "WARNING: This will remove ALL managed policies from Brave." -ForegroundColor Yellow
    $confirm = Read-Host "Are you sure? [y/N]"
    if ($confirm -match '^[Yy]$') {
        Remove-PoliciesAll
    } else {
        Write-Host "Uninstall cancelled." -ForegroundColor DarkGray
    }
}

function Show-Help {
    Write-Host @"
Brave Browser Debloater for Windows

Usage:
  .\debloat-brave-windows.ps1              Apply debloat policies (all features)
  .\debloat-brave-windows.ps1 -Interactive  Choose which features to disable
  .\debloat-brave-windows.ps1 -DryRun      Preview what would change
  .\debloat-brave-windows.ps1 -Restore     Restore from a previous backup
  .\debloat-brave-windows.ps1 -Uninstall   Remove all managed policies
  .\debloat-brave-windows.ps1 -Help        Show this help message

This script disables Brave's non-core features by writing Group Policy
registry entries under HKLM:\SOFTWARE\Policies\BraveSoftware\Brave.

You must run PowerShell as Administrator to use this script.

Features disabled:
  Brave News, Rewards, Wallet/Web3, Speedreader, Telemetry, Talk, Tor,
  VPN, Wayback Machine, Web Discovery Project

Features NOT disabled (caused crashes in some versions):
  Leo AI Chat, Sync

Quick start:
  1. Close Brave completely
  2. Right-click PowerShell -> Run as Administrator
  3. cd to the folder containing this script
  4. Set-ExecutionPolicy -Scope Process RemoteSigned
  5. .\debloat-brave-windows.ps1
  6. Restart Brave and visit brave://policy to verify
"@
}

# --- Main Entry ---
if ($Help) {
    Show-Help
    exit 0
}

Write-Header

if (-not (Test-Admin)) {
    Write-Host "ERROR: This script must be run as Administrator." -ForegroundColor Red
    Write-Host "Right-click PowerShell and select 'Run as Administrator'." -ForegroundColor Yellow
    exit 1
}

if ($Restore) {
    Restore-Backup
    exit 0
}

if ($Uninstall) {
    Uninstall-Policies
    exit 0
}

if (-not (Test-BraveInstalled)) {
    Write-Host "WARNING: Brave Browser does not appear to be installed." -ForegroundColor Yellow
    Write-Host "         Policies will still be applied but may have no effect." -ForegroundColor Yellow
    Write-Host ""
} else {
    Write-Host "[OK] Brave Browser is installed." -ForegroundColor Green
}

if (Test-BraveRunning) {
    Write-Host "WARNING: Brave Browser appears to be running." -ForegroundColor Yellow
    Write-Host "Please close Brave completely before continuing." -ForegroundColor Yellow
    Write-Host ""
    $continue = Read-Host "Press [Enter] to continue after closing Brave, or type 'exit' to quit"
    if ($continue -eq "exit") { exit 0 }

    if (Test-BraveRunning) {
        Write-Host "Brave is still running. Exiting." -ForegroundColor Red
        exit 1
    }
}
Write-Host "[OK] Brave Browser is not running." -ForegroundColor Green

if ($Interactive) {
    Invoke-Interactive
    Write-Host "Creating backup of existing policies..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    Backup-Registry
    Set-Policies
    Show-Summary
    exit 0
}

if ($DryRun) {
    # In dry-run mode, populate all safe policies for preview
    foreach ($policy in $AllPolicies.GetEnumerator()) {
        if ($policy.Value.Safe) {
            $Policies[$policy.Key] = $policy.Value
        }
    }
    Set-Policies -DryRun
    exit 0
}

# Default mode: apply all safe policies
foreach ($policy in $AllPolicies.GetEnumerator()) {
    if ($policy.Value.Safe) {
        $Policies[$policy.Key] = $policy.Value
    }
}

Write-Host "Creating backup of existing policies..." -ForegroundColor Cyan
New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
Backup-Registry

Set-Policies
Show-Summary