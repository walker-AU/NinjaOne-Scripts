<#
.SYNOPSIS
    HP BIOS Update Utility

.DESCRIPTION
    Uses HP Client Management Script Library (HPCMSL) to check for and apply
    BIOS updates on supported HP devices. The script performs pre-flight checks
    for HP hardware, administrator rights, and AC power before taking update
    action.

    In Install mode, the script downloads the latest available BIOS update,
    suspends BitLocker when enabled, and starts the BIOS flash process. In
    Audit mode, it reports whether a newer BIOS is available without downloading
    or flashing.

    A timestamped log is written for each run, and explicit exit codes are
    returned for reporting.

.PARAMETER Mode
    Sets the run mode. Valid values are Install and Audit.
    Install checks for an available BIOS update, downloads it, and starts the flash process.
    Audit checks for an available BIOS update only. It does not download or flash.
    Defaults to Install.

.PARAMETER WorkingPath
    Base folder used by the script for logs and BIOS update files.
    The script creates its own Packages and Logs subfolders under this path.
    Existing files are not deleted.
    Defaults to C:\Temp\HP\BIOS.

.PARAMETER BIOSPassword
    Optional BIOS setup password for systems that require a password before flashing firmware.
    Leave blank for systems without a BIOS setup password.

.PARAMETER SkipACPowerCheck
    Controls whether the AC power safety check is skipped.
    Defaults to $false.
    Set to $true only when power state detection is unreliable or AC power is handled outside this script.

.REQUIREMENTS
    - PowerShell 5.1 or later
    - Administrator privileges
    - HP Client Management Script Library (HPCMSL)
    - Internet connectivity to HP repositories

.DEFAULTS
    - Mode: Install
    - Working path: C:\Temp\HP\BIOS
    - BIOS package path: C:\Temp\HP\BIOS\Packages
    - Log path: C:\Temp\HP\BIOS\Logs
    - BitLocker suspension: 3 reboots

.EXIT CODES
    0 - Success / no update needed
    1 - Script failure
    2 - Not an HP device
    3 - No AC power
    4 - BIOS update available in audit mode

.NOTES
    Author: Sam Walker
    Created: 2026-05-29
    Version: 1.0.0

    This script is intended for HP devices only.
#>

param(
    [ValidateSet("Install", "Audit")]
    [string]$Mode = "Install",
    [string]$WorkingPath = "C:\Temp\HP\BIOS",
    [string]$BIOSPassword,
    [bool]$SkipACPowerCheck = $false
)

$ErrorActionPreference = "Stop"

$ExitSuccess = 0
$ExitScriptFailure = 1
$ExitNotHP = 2
$ExitNoACPower = 3
$ExitAuditUpdateAvailable = 4

# ============================================================
# Logging
# ============================================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "$timestamp [$Level] $Message"

    Write-Host $logLine

    if ($script:LogFile) {
        Add-Content -Path $script:LogFile -Value $logLine
    }
}

function Test-HPRepositoryConnectivity {
    $hpHosts = @(
        "hpia.hpcloud.hp.com",
        "ftp.hp.com"
    )

    $results = foreach ($hpHost in $hpHosts) {
        try {
            $testResult = Test-NetConnection `
                -ComputerName $hpHost `
                -Port 443 `
                -InformationLevel Detailed `
                -WarningAction SilentlyContinue `
                -ErrorAction Stop

            [PSCustomObject]@{
                Host      = $hpHost
                Reachable = [bool]$testResult.TcpTestSucceeded
                Detail    = "TCP 443 reachable: $($testResult.TcpTestSucceeded)"
            }
        }
        catch {
            [PSCustomObject]@{
                Host      = $hpHost
                Reachable = $false
                Detail    = $_.Exception.Message
            }
        }
    }

    [PSCustomObject]@{
        Reachable = [bool]($results | Where-Object { $_.Reachable } | Select-Object -First 1)
        Results   = $results
    }
}

# =============================
# NinjaOne Variable Override
# =============================
# Override with NinjaOne variables if provided.
# This allows the script to use technician-supplied values from the NinjaOne UI instead of the default parameters.
if (-not [string]::IsNullOrWhiteSpace($env:Mode)) { $Mode = $env:Mode }
if (-not [string]::IsNullOrWhiteSpace($env:WorkingPath)) { $WorkingPath = $env:WorkingPath }
if (-not [string]::IsNullOrWhiteSpace($env:BIOSPassword)) { $BIOSPassword = $env:BIOSPassword }
if (-not [string]::IsNullOrWhiteSpace($env:SkipACPowerCheck)) { $SkipACPowerCheck = [System.Convert]::ToBoolean($env:SkipACPowerCheck) }

# ============================================================
# Parameter Validation
# ============================================================

if ($Mode -notin @("Install", "Audit")) {
    Write-Log "Invalid Mode '$Mode'. Valid values are Install and Audit." "ERROR"
    exit $ExitScriptFailure
}

# ============================================================
# Working Folder
# ============================================================

$packagePath = Join-Path $WorkingPath "Packages"
$logPath = Join-Path $WorkingPath "Logs"

New-Item -Path $WorkingPath -ItemType Directory -Force | Out-Null
New-Item -Path $packagePath -ItemType Directory -Force | Out-Null
New-Item -Path $logPath -ItemType Directory -Force | Out-Null

$logTimestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$script:LogFile = Join-Path $logPath "HP-BIOS-Update-$logTimestamp.log"

Write-Log "Starting HP BIOS update process."
Write-Log "Working path: $WorkingPath"
Write-Log "BIOS package path: $packagePath"
Write-Log "Log file: $script:LogFile"
Write-Log "Mode: $Mode"
Write-Log "Skip AC power check: $SkipACPowerCheck"
Write-Log "Existing package files are preserved; matching CMSL downloads may be overwritten."

# ============================================================
# Pre-flight Checks
# ============================================================

$computerSystem = Get-CimInstance Win32_ComputerSystem
$manufacturer = $computerSystem.Manufacturer

if ($manufacturer -notmatch "HP|Hewlett-Packard") {
    Write-Log "Device manufacturer is '$manufacturer'. Not an HP device. Exiting."
    exit $ExitNotHP
}

Write-Log "HP device detected."

$isAdmin = ([Security.Principal.WindowsPrincipal] `
    [Security.Principal.WindowsIdentity]::GetCurrent()
).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Log "Script must be run as Administrator." "ERROR"
    exit $ExitScriptFailure
}

Write-Log "Administrator rights confirmed."

# ============================================================
# AC Power Check
# ============================================================

if ($SkipACPowerCheck) {
    Write-Log "AC power check skipped by parameter." "WARN"
}
else {
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue

    if ($battery) {
        if ($battery.BatteryStatus -ne 2) {
            Write-Log "Device is not connected to AC power. Exiting." "ERROR"
            exit $ExitNoACPower
        }

        Write-Log "AC power detected."
    }
    else {
        Write-Log "No battery detected. Assuming desktop or always-on power."
    }
}

# ============================================================
# HP CMSL Module
# ============================================================

try {
    if (-not (Get-Module -ListAvailable -Name HPCMSL)) {
        Write-Log "HPCMSL module not found. Installing."

        Install-PackageProvider -Name NuGet -Force | Out-Null
        Install-Module -Name HPCMSL -Scope AllUsers -Force -AcceptLicense
    }

    Import-Module HPCMSL -Force
}
catch {
    Write-Log "Failed to install or import HPCMSL. $_" "ERROR"
    exit $ExitScriptFailure
}

Write-Log "HPCMSL module loaded."

$hpcmslModule = Get-Module HPCMSL

if ($hpcmslModule) {
    Write-Log "HPCMSL module version: $($hpcmslModule.Version)"
}

# ============================================================
# Current BIOS Information
# ============================================================

$bios = Get-CimInstance Win32_BIOS
$currentBIOSVersion = $bios.SMBIOSBIOSVersion
$platformId = Get-HPDeviceProductID

Write-Log "Current BIOS version: $currentBIOSVersion"
Write-Log "HP Platform ID: $platformId"

# ============================================================
# Check for Available BIOS Update
# ============================================================

Write-Log "Checking for available BIOS updates."

try {
    $availableUpdate = Get-HPBIOSUpdates -Latest -ErrorAction Stop
}
catch {
    Write-Log "HP CMSL could not retrieve BIOS update metadata from HP." "ERROR"

    $hpConnectivity = Test-HPRepositoryConnectivity

    if ($hpConnectivity.Reachable) {
        Write-Log "Failure category: HP CMSL retrieval failed, but basic HP HTTPS connectivity succeeded." "ERROR"
        Write-Log "A proxy, SSL inspection rule, CMSL repository issue, or HP service issue may be blocking update retrieval." "ERROR"
    }
    else {
        Write-Log "Failure category: Network issue or HP site unavailable." "ERROR"
        Write-Log "Basic HTTPS connectivity to HP update hosts failed." "ERROR"
    }

    foreach ($result in $hpConnectivity.Results) {
        Write-Log "HP connectivity test: $($result.Host) - $($result.Detail)" "ERROR"
    }

    Write-Log "Original HP CMSL error: $($_.Exception.Message)" "ERROR"
    exit $ExitScriptFailure
}

if (-not $availableUpdate) {
    Write-Log "Failure category: No update available."
    Write-Log "No BIOS update found."
    exit $ExitSuccess
}

Write-Log "BIOS update appears to be available."

$latestBIOSVersion = $availableUpdate.Ver

if (-not $latestBIOSVersion) {
    $latestBIOSVersion = $availableUpdate.Version
}

if (-not $latestBIOSVersion) {
    Write-Log "HP CMSL reported an available update, but no BIOS version was returned." "ERROR"
    Write-Log "Available update object: $($availableUpdate | Out-String)" "ERROR"
    exit $ExitScriptFailure
}

Write-Log "Available BIOS version: $latestBIOSVersion"

# ============================================================
# Stop Here If Audit Mode
# ============================================================

if ($Mode -eq "Audit") {
    Write-Log "Audit mode enabled. BIOS update is available; download and flash skipped."
    exit $ExitAuditUpdateAvailable
}

# ============================================================
# Download BIOS Update
# ============================================================

Write-Log "Downloading BIOS update to: $packagePath"

Push-Location $packagePath

try {
    $downloadedUpdate = Get-HPBIOSUpdates `
        -Download `
        -Version $latestBIOSVersion `
        -Overwrite
}
catch {
    Write-Log "Failed to download BIOS update. $_" "ERROR"
    exit $ExitScriptFailure
}
finally {
    Pop-Location
}

Write-Log "BIOS update download completed."

# ============================================================
# BitLocker Safety
# ============================================================

try {
    $systemDrive = $env:SystemDrive
    $bitlocker = Get-BitLockerVolume -MountPoint $systemDrive -ErrorAction SilentlyContinue

    if ($bitlocker -and $bitlocker.ProtectionStatus -eq "On") {
        Write-Log "Suspending BitLocker for 3 reboots."

        Suspend-BitLocker `
            -MountPoint $systemDrive `
            -RebootCount 3
    }
    else {
        Write-Log "BitLocker not enabled or not detected on $systemDrive."
    }
}
catch {
    Write-Log "Could not check or suspend BitLocker. $_" "WARN"
}

# ============================================================
# Flash BIOS
# ============================================================

Write-Log "Starting BIOS flash process."
Write-Log "Do not power off the device during BIOS update."

try {
    $flashParams = @{
        Flash     = $true
        Version   = $latestBIOSVersion
        BitLocker = "Suspend"
        Yes       = $true
        Overwrite = $true
    }

    if ($BIOSPassword) {
        $flashParams.Password = $BIOSPassword
    }

    Get-HPBIOSUpdates @flashParams

    Write-Log "BIOS flash command completed."
    Write-Log "A reboot may be required."
    exit $ExitSuccess
}
catch {
    Write-Log "BIOS flash failed. $_" "ERROR"
    exit $ExitScriptFailure
}