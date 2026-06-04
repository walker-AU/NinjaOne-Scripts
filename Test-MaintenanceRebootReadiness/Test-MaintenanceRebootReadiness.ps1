<#
.SYNOPSIS
    Tests whether a device meets the configured requirements for a maintenance reboot.

.DESCRIPTION
    Determines whether a device is eligible for a maintenance reboot by evaluating
    the following conditions in order:

    1. Maintenance window compliance.
    2. System uptime requirements.
    3. Active user session conditions.

    Evaluation stops as soon as a blocking condition is found.

.PARAMETER WindowStart
    Required maintenance window start time in local system time using 24-hour HH:mm
    format.

.PARAMETER WindowEnd
    Required maintenance window end time in local system time using 24-hour HH:mm
    format.

.PARAMETER Monday
    Boolean value indicating whether the maintenance window is allowed on
    Monday.

.PARAMETER Tuesday
    Boolean value indicating whether the maintenance window is allowed on
    Tuesday.

.PARAMETER Wednesday
    Boolean value indicating whether the maintenance window is allowed on
    Wednesday.

.PARAMETER Thursday
    Boolean value indicating whether the maintenance window is allowed on
    Thursday.

.PARAMETER Friday
    Boolean value indicating whether the maintenance window is allowed on
    Friday.

.PARAMETER Saturday
    Boolean value indicating whether the maintenance window is allowed on
    Saturday.

.PARAMETER Sunday
    Boolean value indicating whether the maintenance window is allowed on
    Sunday.

.PARAMETER UptimeUnit
    Unit used for the configured uptime threshold. Supported values are Minutes,
    Hours, or Days.

.PARAMETER UptimeValue
    Positive whole number used for the configured uptime threshold.

.PARAMETER IdleThresholdMinutes
    Whole number used as the active-user idle threshold. Sessions in Active state
    with idle time below this value are treated as active. Set to 0 to skip the
    active user session check.

.PARAMETER BlockIfActiveSession
    Boolean value indicating whether any Active session should block reboot
    eligibility regardless of idle time.

.EXAMPLE
    .\Test-MaintenanceRebootReadiness.ps1 -WindowStart '02:00' -WindowEnd '03:00' -UptimeUnit Days -UptimeValue 1 -IdleThresholdMinutes 15

.EXIT CODES
    0 - Device is eligible to reboot.
    1 - Device is not eligible to reboot.
    2 - Validation error or unexpected script failure.

.NOTES
    Author: Sam Walker
    Created: 2026-06-02
    Version: 1.0.0
#>

[CmdletBinding()]
param(
    # Maintenance window start time in local system time using 24-hour HH:mm format.
    [string]$WindowStart = "00:00",

    # Maintenance window end time in local system time using 24-hour HH:mm format.
    [string]$WindowEnd = "00:01",

    # Whether Monday is enabled for the maintenance window.
    [bool]$Monday = $true,

    # Whether Tuesday is enabled for the maintenance window.
    [bool]$Tuesday = $true,

    # Whether Wednesday is enabled for the maintenance window.
    [bool]$Wednesday = $true,

    # Whether Thursday is enabled for the maintenance window.
    [bool]$Thursday = $true,

    # Whether Friday is enabled for the maintenance window.
    [bool]$Friday = $true,

    # Whether Saturday is enabled for the maintenance window.
    [bool]$Saturday = $true,

    # Whether Sunday is enabled for the maintenance window.
    [bool]$Sunday = $true,

    # Unit used for the uptime threshold. Expected values are Minutes, Hours, or Days.
    [ValidateSet("Minutes", "Hours", "Days")]
    [string]$UptimeUnit = "Days",

    # Whole number used for the uptime threshold.
    [int]$UptimeValue = 1,

    # Active-session idle threshold in minutes; 0 skips active user session check.
    [int]$IdleThresholdMinutes = 15,

    # Whether any Active session blocks reboot regardless of idle time.
    [bool]$BlockIfActiveSession = $true
)

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"

# =============================================================================
# Shared Input Helpers
# =============================================================================
function ConvertTo-TimeOfDay {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be supplied in 24-hour HH:mm format."
    }

    $trimmedValue = $Value.Trim()

    if ($trimmedValue -notmatch "^(?:[01][0-9]|2[0-3]):[0-5][0-9]$") {
        throw "$Name must use 24-hour HH:mm format, for example 02:00 or 14:30."
    }

    return [datetime]::ParseExact(
        $trimmedValue,
        "HH:mm",
        [System.Globalization.CultureInfo]::InvariantCulture
    ).TimeOfDay
}

function ConvertTo-UptimeUnit {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "$Name must be supplied as Minutes, Hours, or Days."
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        "minute"  { return "Minutes" }
        "minutes" { return "Minutes" }
        "min"     { return "Minutes" }
        "mins"    { return "Minutes" }
        "hour"    { return "Hours" }
        "hours"   { return "Hours" }
        "hr"      { return "Hours" }
        "hrs"     { return "Hours" }
        "day"     { return "Days" }
        "days"    { return "Days" }
        default   { throw "$Name must be Minutes, Hours, or Days." }
    }
}

# =============================================================================
# NinjaOne Variable Overrides
# =============================================================================
# NinjaOne script variables are exposed as environment variables. When supplied,
# they override the PowerShell parameters above and are validated later in the
# relevant check section.
if (-not [string]::IsNullOrWhiteSpace($env:WindowStart)) { $WindowStart = $env:WindowStart }
if (-not [string]::IsNullOrWhiteSpace($env:WindowEnd))   { $WindowEnd   = $env:WindowEnd }
if (-not [string]::IsNullOrWhiteSpace($env:Monday))      { $Monday      = [System.Convert]::ToBoolean($env:Monday) }
if (-not [string]::IsNullOrWhiteSpace($env:Tuesday))     { $Tuesday     = [System.Convert]::ToBoolean($env:Tuesday) }
if (-not [string]::IsNullOrWhiteSpace($env:Wednesday))   { $Wednesday   = [System.Convert]::ToBoolean($env:Wednesday) }
if (-not [string]::IsNullOrWhiteSpace($env:Thursday))    { $Thursday    = [System.Convert]::ToBoolean($env:Thursday) }
if (-not [string]::IsNullOrWhiteSpace($env:Friday))      { $Friday      = [System.Convert]::ToBoolean($env:Friday) }
if (-not [string]::IsNullOrWhiteSpace($env:Saturday))    { $Saturday    = [System.Convert]::ToBoolean($env:Saturday) }
if (-not [string]::IsNullOrWhiteSpace($env:Sunday))      { $Sunday      = [System.Convert]::ToBoolean($env:Sunday) }
if (-not [string]::IsNullOrWhiteSpace($env:UptimeUnit))  { $UptimeUnit  = $env:UptimeUnit }
if ($env:UptimeValue -match "^\d+$") { $UptimeValue = [int]$env:UptimeValue }
if ($env:IdleThresholdMinutes -match "^\d+$") { $IdleThresholdMinutes = [int]$env:IdleThresholdMinutes }
if (-not [string]::IsNullOrWhiteSpace($env:BlockIfActiveSession)) { $BlockIfActiveSession = [System.Convert]::ToBoolean($env:BlockIfActiveSession) }

# =============================================================================
# Input Validation
# =============================================================================
$UptimeUnit = $UptimeUnit.Trim()

if ($UptimeValue -lt 1) {
    Write-Host "FAIL: UptimeValue must be 1 or greater."
    exit 2
}

if ($IdleThresholdMinutes -lt 0) {
    Write-Host "FAIL: IdleThresholdMinutes must be 0 or greater."
    exit 2
}

# =============================================================================
# Check 1 Helpers: Time Window
# =============================================================================
# Adapted from Test Device Time Window.ps1. This gate must run first so devices
# outside the maintenance window stop before uptime or user-session checks.
function Get-DayMap {
    param(
        [Parameter(Mandatory = $true)]
        [bool]$Monday,

        [Parameter(Mandatory = $true)]
        [bool]$Tuesday,

        [Parameter(Mandatory = $true)]
        [bool]$Wednesday,

        [Parameter(Mandatory = $true)]
        [bool]$Thursday,

        [Parameter(Mandatory = $true)]
        [bool]$Friday,

        [Parameter(Mandatory = $true)]
        [bool]$Saturday,

        [Parameter(Mandatory = $true)]
        [bool]$Sunday
    )

    return @{
        Monday = $Monday
        Tuesday = $Tuesday
        Wednesday = $Wednesday
        Thursday = $Thursday
        Friday = $Friday
        Saturday = $Saturday
        Sunday = $Sunday
    }
}

function Test-TimeWithinWindow {
    param(
        [Parameter(Mandatory = $true)]
        [timespan]$CurrentTime,

        [Parameter(Mandatory = $true)]
        [timespan]$WindowStart,

        [Parameter(Mandatory = $true)]
        [timespan]$WindowEnd
    )

    if ($WindowStart -eq $WindowEnd) {
        throw "WindowStart and WindowEnd cannot be the same value."
    }

    if ($WindowStart -lt $WindowEnd) {
        return ($CurrentTime -ge $WindowStart -and $CurrentTime -lt $WindowEnd)
    }

    return ($CurrentTime -ge $WindowStart -or $CurrentTime -lt $WindowEnd)
}

# =============================================================================
# Check 2 Helpers: Device Uptime
# =============================================================================
# Adapted from Test Device Uptime.ps1. This gate runs before active-user
# detection because it is the cheaper blocker to evaluate.
function ConvertTo-UptimeThreshold {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Unit,

        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    switch ($Unit) {
        "Minutes" { return [timespan]::FromMinutes($Value) }
        "Hours"   { return [timespan]::FromHours($Value) }
        "Days"    { return [timespan]::FromDays($Value) }
        default   { throw "Unsupported uptime unit: $Unit" }
    }
}

function Get-UptimeSnapshot {
    param(
        [Parameter(Mandatory = $true)]
        [datetime]$CurrentDateTime
    )

    try {
        $counter = Get-Counter -Counter "\System\System Up Time"
        $counterSample = $counter.CounterSamples | Select-Object -First 1

        if ($counterSample -and $null -ne $counterSample.CookedValue) {
            $uptime = [timespan]::FromSeconds([double]$counterSample.CookedValue)

            return [pscustomobject]@{
                LastBootTime = $CurrentDateTime - $uptime
                Uptime = $uptime
                Source = "Performance counter"
            }
        }
    }
    catch {
        $performanceCounterError = $_.Exception.Message
    }

    try {
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem

        if ($operatingSystem.LastBootUpTime) {
            $lastBootTime = $operatingSystem.LastBootUpTime

            return [pscustomobject]@{
                LastBootTime = $lastBootTime
                Uptime = $CurrentDateTime - $lastBootTime
                Source = "CIM"
            }
        }
    }
    catch {
        $cimError = $_.Exception.Message
    }

    throw "Unable to detect system uptime. Performance counter error: $performanceCounterError CIM error: $cimError"
}

function Format-Uptime {
    param(
        [Parameter(Mandatory = $true)]
        [timespan]$Value
    )

    return "{0} days, {1} hours, {2} minutes, {3} seconds" -f `
        [math]::Floor($Value.TotalDays),
        $Value.Hours,
        $Value.Minutes,
        $Value.Seconds
}

function Format-ConfiguredThreshold {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Value,

        [Parameter(Mandatory = $true)]
        [string]$Unit
    )

    if ($Value -eq 1) {
        switch ($Unit) {
            "Minutes" { return "1 minute" }
            "Hours"   { return "1 hour" }
            "Days"    { return "1 day" }
            default   { throw "Unsupported uptime unit: $Unit" }
        }
    }

    return "$Value $($Unit.ToLowerInvariant())"
}

# =============================================================================
# Check 3 Helpers: Active User Sessions
# =============================================================================
# Adapted from Test Active User Session.ps1. This gate blocks reboot when a
# session is Active and idle time is below the configured threshold.
function Get-QUserPath {
    $candidatePaths = @(
        "$env:SystemRoot\Sysnative\quser.exe",
        "$env:SystemRoot\System32\quser.exe",
        "quser.exe"
    )

    foreach ($candidatePath in $candidatePaths) {
        if ($candidatePath -eq "quser.exe") {
            return $candidatePath
        }

        if (Test-Path -LiteralPath $candidatePath) {
            return $candidatePath
        }
    }
}

function Get-QueryUserOutput {
    $quserPath = Get-QUserPath
    $previousErrorActionPreference = $ErrorActionPreference
    $output = @()
    $exitCode = $null

    try {
        $ErrorActionPreference = "Continue"
        $output = @(& $quserPath 2>&1)
        $exitCode = $LASTEXITCODE
    }
    catch {
        $output = @($_)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }

    $textOutput = @($output | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) {
            $_.Exception.Message
        }
        else {
            $_.ToString()
        }
    })

    $joinedOutput = ($textOutput -join " ").Trim()

    if ($joinedOutput -match "No User exists") {
        return @()
    }

    if ($exitCode -ne 0) {
        throw "Failed to query user sessions. Exit code: $exitCode Output: $joinedOutput"
    }

    return @($textOutput | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
}

function Get-ColumnValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Line,

        [Parameter(Mandatory = $true)]
        [int]$Start,

        [Parameter(Mandatory = $true)]
        [int]$End
    )

    if ($Line.Length -le $Start) {
        return ""
    }

    $length = [math]::Min($End, $Line.Length) - $Start

    if ($length -le 0) {
        return ""
    }

    return $Line.Substring($Start, $length).Trim()
}

function ConvertTo-IdleMinutes {
    param(
        [AllowNull()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return 0
    }

    $trimmedValue = $Value.Trim().ToLowerInvariant()

    switch ($trimmedValue) {
        "."    { return 0 }
        "none" { return 0 }
    }

    if ($trimmedValue -match "^\d+$") {
        return [int]$trimmedValue
    }

    if ($trimmedValue -match "^(?<Hours>\d+):(?<Minutes>[0-5]?\d)$") {
        return ([int]$Matches.Hours * 60) + [int]$Matches.Minutes
    }

    if ($trimmedValue -match "^(?<Days>\d+)\+(?<Hours>\d+):(?<Minutes>[0-5]?\d)$") {
        return ([int]$Matches.Days * 1440) + ([int]$Matches.Hours * 60) + [int]$Matches.Minutes
    }

    throw "Unsupported idle time format detected: $Value"
}

function Get-UserSessions {
    $queryOutput = Get-QueryUserOutput

    if ($queryOutput.Count -eq 0) {
        return @()
    }

    $header = $queryOutput | Select-Object -First 1
    $usernameStart = $header.IndexOf("USERNAME")
    $sessionNameStart = $header.IndexOf("SESSIONNAME")
    $idStart = $header.IndexOf("ID", $sessionNameStart + "SESSIONNAME".Length)
    $stateStart = $header.IndexOf("STATE")
    $idleStart = $header.IndexOf("IDLE TIME")
    $logonStart = $header.IndexOf("LOGON TIME")

    if ($usernameStart -lt 0 -or $sessionNameStart -lt 0 -or $idStart -lt 0 -or $stateStart -lt 0 -or $idleStart -lt 0 -or $logonStart -lt 0) {
        throw "Unable to parse query user header: $header"
    }

    $sessionLines = @($queryOutput | Select-Object -Skip 1)

    return @($sessionLines | ForEach-Object {
        $line = $_
        $username = Get-ColumnValue -Line $line -Start $usernameStart -End $sessionNameStart
        $sessionName = Get-ColumnValue -Line $line -Start $sessionNameStart -End $idStart
        $id = Get-ColumnValue -Line $line -Start $idStart -End $stateStart
        $state = Get-ColumnValue -Line $line -Start $stateStart -End $idleStart
        $idleTime = Get-ColumnValue -Line $line -Start $idleStart -End $logonStart
        $logonTime = ""

        if ($line.Length -gt $logonStart) {
            $logonTime = $line.Substring($logonStart).Trim()
        }

        if ($username.StartsWith(">")) {
            $username = $username.Substring(1).Trim()
        }

        $idleMinutes = ConvertTo-IdleMinutes -Value $idleTime

        [pscustomobject]@{
            Username = $username
            SessionName = $sessionName
            Id = $id
            State = $state
            IdleTime = $idleTime
            IdleMinutes = $idleMinutes
            LogonTime = $logonTime
        }
    })
}

function Format-MinuteLabel {
    param(
        [Parameter(Mandatory = $true)]
        [int]$Value
    )

    if ($Value -eq 1) {
        return "1 minute"
    }

    return "$Value minutes"
}

# =============================================================================
# Main Workflow
# =============================================================================
# The script exits as soon as a blocking condition is found. This keeps the
# workflow decision simple:
#   0 = all gates passed; reboot may proceed
#   1 = a normal gate failed; do not reboot
#   2 = validation or unexpected script failure
try {
    Write-Host ""
    Write-Host "Reboot Eligibility Check" -ForegroundColor Cyan

    # -------------------------------------------------------------------------
    # Check 1: Time Window
    # -------------------------------------------------------------------------
    # This is intentionally first. If the device is outside the maintenance
    # window, no uptime or active-user checks are performed.
    $resolvedWindowStart = ConvertTo-TimeOfDay -Name "WindowStart" -Value $WindowStart
    $resolvedWindowEnd = ConvertTo-TimeOfDay -Name "WindowEnd" -Value $WindowEnd

    $dayMap = Get-DayMap `
        -Monday $Monday `
        -Tuesday $Tuesday `
        -Wednesday $Wednesday `
        -Thursday $Thursday `
        -Friday $Friday `
        -Saturday $Saturday `
        -Sunday $Sunday

    $now = Get-Date
    $currentDay = $now.DayOfWeek.ToString()
    $currentTime = $now.TimeOfDay
    $isDayAllowed = [bool]$dayMap[$currentDay]
    $isTimeWithinWindow = Test-TimeWithinWindow `
        -CurrentTime $currentTime `
        -WindowStart $resolvedWindowStart `
        -WindowEnd $resolvedWindowEnd
    $isTimeWindowMatched = $isDayAllowed -and $isTimeWithinWindow

    Write-Host ""
    Write-Host "Time Window Check" -ForegroundColor Cyan
    Write-Host "  Start               : $($resolvedWindowStart.ToString("hh\:mm"))" -ForegroundColor Gray
    Write-Host "  End                 : $($resolvedWindowEnd.ToString("hh\:mm"))" -ForegroundColor Gray
    Write-Host "  Current date/time   : $($now.ToString("yyyy-MM-dd HH:mm:ss"))" -ForegroundColor Gray
    Write-Host "  Current day enabled : $isDayAllowed" -ForegroundColor Gray
    Write-Host "  Time within window  : $isTimeWithinWindow" -ForegroundColor Gray

    if (-not $isTimeWindowMatched) {
        Write-Host ""
        Write-Host "Determination" -ForegroundColor Cyan
        Write-Host "  Device is not eligible to reboot. Current time is outside the allowed window." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Exit code" -ForegroundColor Cyan
        Write-Host "  1" -ForegroundColor Gray
        exit 1
    }

    # -------------------------------------------------------------------------
    # Check 2: Uptime
    # -------------------------------------------------------------------------
    # The reboot should only proceed when the device has been online for at
    # least the configured threshold.
    $resolvedUptimeUnit = ConvertTo-UptimeUnit -Name "UptimeUnit" -Value $UptimeUnit
    $resolvedUptimeValue = $UptimeValue
    $uptimeThreshold = ConvertTo-UptimeThreshold -Unit $resolvedUptimeUnit -Value $resolvedUptimeValue

    $uptimeNow = Get-Date
    $uptimeSnapshot = Get-UptimeSnapshot -CurrentDateTime $uptimeNow
    $lastBootTime = $uptimeSnapshot.LastBootTime
    $currentUptime = $uptimeSnapshot.Uptime
    $isUptimeMatched = $currentUptime -ge $uptimeThreshold

    Write-Host ""
    Write-Host "Uptime Check" -ForegroundColor Cyan
    Write-Host "  Threshold          : $(Format-ConfiguredThreshold -Value $resolvedUptimeValue -Unit $resolvedUptimeUnit)" -ForegroundColor Gray
    Write-Host "  Last boot time     : $($lastBootTime.ToString("yyyy-MM-dd HH:mm:ss"))" -ForegroundColor Gray
    Write-Host "  Uptime             : $(Format-Uptime -Value $currentUptime)" -ForegroundColor Gray
    Write-Host "  Detection source   : $($uptimeSnapshot.Source)" -ForegroundColor Gray
    Write-Host "  Uptime matched     : $isUptimeMatched" -ForegroundColor Gray

    if (-not $isUptimeMatched) {
        Write-Host ""
        Write-Host "Determination" -ForegroundColor Cyan
        Write-Host "  Device is not eligible to reboot. Current uptime is below the configured threshold." -ForegroundColor Yellow
        Write-Host ""
        Write-Host "Exit code" -ForegroundColor Cyan
        Write-Host "  1" -ForegroundColor Gray
        exit 1
    }

    # -------------------------------------------------------------------------
    # Check 3: Active User Sessions
    # -------------------------------------------------------------------------
    # BlockIfActiveSession has priority over IdleThresholdMinutes. When enabled,
    # any Active session blocks reboot. Otherwise, set IdleThresholdMinutes to 0
    # to skip this check, or use a positive idle threshold.
    $resolvedIdleThresholdMinutes = $IdleThresholdMinutes

    Write-Host ""
    Write-Host "Active User Session Check" -ForegroundColor Cyan
    Write-Host "  Block if active session: $BlockIfActiveSession" -ForegroundColor Gray

    if ($BlockIfActiveSession) {
        $sessions = @(Get-UserSessions)
        $activeSessions = @($sessions | Where-Object { $_.State -eq "Active" })
        $hasActiveUserSession = $activeSessions.Count -gt 0

        Write-Host "  Idle threshold         : ignored" -ForegroundColor Gray
        Write-Host "  Total sessions         : $($sessions.Count)" -ForegroundColor Gray
        Write-Host "  Active sessions matched: $($activeSessions.Count)" -ForegroundColor Gray

        if ($sessions.Count -gt 0) {
            Write-Host ""
            $formattedSessions = $sessions |
                Select-Object Username, SessionName, Id, State, IdleTime, IdleMinutes, LogonTime |
                Format-Table -AutoSize |
                Out-String
            Write-Host $formattedSessions.TrimEnd()
        }
        else {
            Write-Host "  No user sessions detected." -ForegroundColor Yellow
        }

        if ($hasActiveUserSession) {
            Write-Host ""
            Write-Host "Determination" -ForegroundColor Cyan
            Write-Host "  Device is not eligible to reboot. Active user session found." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Exit code" -ForegroundColor Cyan
            Write-Host "  1" -ForegroundColor Gray
            exit 1
        }
    }
    elseif ($resolvedIdleThresholdMinutes -eq 0) {
        Write-Host "  Idle threshold         : disabled" -ForegroundColor Gray
        Write-Host "  Active user check      : skipped" -ForegroundColor Gray
    }
    else {
        $sessions = @(Get-UserSessions)
        $activeSessions = @($sessions | Where-Object {
            $_.State -eq "Active" -and $_.IdleMinutes -lt $resolvedIdleThresholdMinutes
        })
        $hasActiveUserSession = $activeSessions.Count -gt 0

        Write-Host "  Idle threshold         : $(Format-MinuteLabel -Value $resolvedIdleThresholdMinutes)" -ForegroundColor Gray
        Write-Host "  Total sessions         : $($sessions.Count)" -ForegroundColor Gray
        Write-Host "  Active sessions matched: $($activeSessions.Count)" -ForegroundColor Gray

        if ($sessions.Count -gt 0) {
            Write-Host ""
            $formattedSessions = $sessions |
                Select-Object Username, SessionName, Id, State, IdleTime, IdleMinutes, LogonTime |
                Format-Table -AutoSize |
                Out-String
            Write-Host $formattedSessions.TrimEnd()
        }
        else {
            Write-Host "  No user sessions detected." -ForegroundColor Yellow
        }

        if ($hasActiveUserSession) {
            Write-Host ""
            Write-Host "Determination" -ForegroundColor Cyan
            Write-Host "  Device is not eligible to reboot. Active user session found." -ForegroundColor Yellow
            Write-Host ""
            Write-Host "Exit code" -ForegroundColor Cyan
            Write-Host "  1" -ForegroundColor Gray
            exit 1
        }
    }

    Write-Host ""
    Write-Host "Determination" -ForegroundColor Cyan
    Write-Host "  Device is eligible to reboot." -ForegroundColor Green
    Write-Host ""
    Write-Host "Exit code" -ForegroundColor Cyan
    Write-Host "  0" -ForegroundColor Gray
    exit 0
}
catch {
    Write-Host ""
    Write-Host "Reboot Eligibility Check" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Unhandled exception" -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    Write-Host "Exit code" -ForegroundColor Cyan
    Write-Host "  2" -ForegroundColor Gray
    exit 2
}
