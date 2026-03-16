#Requires -Version 5.1
<#
.SYNOPSIS
  Reports Windows lifecycle status (Client or Server) using endoflife.date.

.DESCRIPTION
  Detects whether the local OS is Windows Client or Windows Server, queries lifecycle data
  from endoflife.date, and maps the machine to a matching release cycle using strict,
  high-confidence rules only.

  The goal is to determine lifecycle state (supported, end of active support, end of security
  support) accurately without making assumptions. If the OS cannot be confidently matched
  to a published cycle, the lifecycle state is reported as UNKNOWN.

  MAPPING LOGIC (summary):
    • Windows Client
        - Uses DisplayVersion/ReleaseId (e.g., 22H2, 23H2, 25H2).
        - Windows 11: maps to cycles such as "11-23h2-w" or "11-23h2-e" using edition hints.
        - Windows 10: maps only when an exact cycle match exists.
    • Windows Server
        - If the OS name includes a year (e.g., "Windows Server 2019"), that year is used.
        - If the name includes a version (e.g., "Windows Server, version 1809"), that version
          is used if present in the dataset.
        - If neither identifier is present, the script does not guess.

.NOTES
  Author: Sam Walker
  Date:   2025-08-12
  Client API: https://endoflife.date/api/v1/products/windows/
  Server API: https://endoflife.date/api/v1/products/windows-server/

.PARAMETER ClientApiUrl
  Optional override for Windows Client lifecycle endpoint.

.PARAMETER ServerApiUrl
  Optional override for Windows Server lifecycle endpoint.

.PARAMETER Diagnostics
  Outputs additional mapping details for troubleshooting.
#>

[CmdletBinding()]
param(
  [string]$ClientApiUrl = "https://endoflife.date/api/v1/products/windows/",
  [string]$ServerApiUrl = "https://endoflife.date/api/v1/products/windows-server/",
  [switch]$Diagnostics,

  # ======================================================================
  # Custom Field Output Options
  
  # Each lifecycle property below can be individually enabled/disabled.
  # If enabled, the script will attempt to write that value to the
  # corresponding NinjaOne custom field name.
  #
  # - Set the Enable* boolean to $true to activate a field.
  # - Adjust the *CustomFieldName string if you want a different field.
  #
  # No fields are written unless explicitly enabled.
  # ======================================================================

  # ----------------------------------------------------------------------
  # WYSIWYG (HTML Summary Block)
  # Writes the full lifecycle summary card (HTML) to a NinjaOne WYSIWYG custom field.
  # ----------------------------------------------------------------------
  [bool]   $EnableWysiwyg               = $true,
  [string] $WysiwygCustomFieldName      = "osLifecycleWysiwyg",

  # ----------------------------------------------------------------------
  # EOL & EOAS Flags
  # Boolean flags indicating whether the OS is past End Of Active Support or End Of Life.
  # ----------------------------------------------------------------------
  [bool]   $EnableIsEol                 = $true,
  [string] $IsEolCustomFieldName        = "osIsEndoflife",

  [bool]   $EnableIsEoas                = $false,
  [string] $IsEoasCustomFieldName       = "windowsOsIsEOAS",
  
  # ----------------------------------------------------------------------
  # EOL & EOAS Days Remaining
  # Number of days remaining until End Of Active Support or End Of Life.
  # ----------------------------------------------------------------------
  [bool]   $EnableDaysToEol             = $true,
  [string] $DaysToEolCustomFieldName    = "osDaysToEndoflife",

  [bool]   $EnableDaysToEoas            = $false,
  [string] $DaysToEoasCustomFieldName   = "osDaysToEOAS",

  # ----------------------------------------------------------------------
  # Support Dates
  # Writes the official EOAS and EOL lifecycle dates returned by the API.
  # ----------------------------------------------------------------------
  [bool]   $EnableEolDate               = $false,
  [string] $EolDateCustomFieldName      = "osEOLDate",

  [bool]   $EnableEoasDate              = $false,
  [string] $EoasDateCustomFieldName     = "osEOASDate",

  # ----------------------------------------------------------------------
  # Overall Status & Recommendation
  # High-level lifecycle status and upgrade recommendation derived from API flags.
  # ----------------------------------------------------------------------
  [bool]   $EnableStatus                = $false,
  [string] $StatusCustomFieldName       = "osLifecycleStatus",

  [bool]   $EnableRecommendation        = $false,
  [string] $RecommendationCustomFieldName = "osRecommendation",
  

  # ======================================================================
  # Windows OS Details
  # ----------------------------------------------------------------------
  # OS details retrieved from Windows.
  # ======================================================================
  
  # ----------------------------------------------------------------------
  # OS Name (Caption from Win32_OperatingSystem)
  # The native Windows OS name as reported by the operating system itself, e.g. "Microsoft Windows 10 Enterprise LTSC".
  # Useful when you need the exact edition/variant provided directly by Windows.
  # ----------------------------------------------------------------------
  [bool]   $EnableOsCaption               = $true,
  [string] $OsCaptionCustomFieldName      = "osCaption",
    
  # ----------------------------------------------------------------------
  # OS Build
  # Example: "19045.5011" (CurrentBuild.UBR)
  # ----------------------------------------------------------------------
  [bool]   $EnableOsBuild                 = $true,
  [string] $OsBuildCustomFieldName        = "osBuildVersion",
    
  # ----------------------------------------------------------------------
  # Feature Update / Release
  # Example: "25H2"
  # Uses DisplayVersion or ReleaseId from the Windows registry.
  # ----------------------------------------------------------------------
  [bool]   $EnableFeatureUpdate           = $true,
  [string] $FeatureUpdateCustomFieldName  = "osFeatureUpdate",
  
  # ----------------------------------------------------------------------
  # Product Name
  # Example: "Windows 10 Enterprise LTSC 2019"
  # Retrieved from HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProductName
  # ----------------------------------------------------------------------
  [bool]   $EnableOsProductName           = $false,
  [string] $OsProductNameFieldName        = "osProductName",
  
  # ----------------------------------------------------------------------
  # Edition
  # Example: "Enterprise"
  # Retrieved from HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\EditionID
  # ----------------------------------------------------------------------
  [bool]   $EnableOsEdition               = $false,
  [string] $OsEditionCustomFieldName      = "osEdition"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# =============================================================================
# Section 1: Helper functions
# =============================================================================

function Get-PropValue {
  <#
    .SYNOPSIS
      StrictMode-safe property read.
    .DESCRIPTION
      Returns $null if the property does not exist on the given object.
  #>
  param(
    [Parameter(Mandatory)]$Object,
    [Parameter(Mandatory)][string]$Name
  )
  $p = $Object.PSObject.Properties[$Name]
  if ($p) { return $p.Value }
  return $null
}

function ConvertTo-DateOrNull {
  <#
    .SYNOPSIS
      Converts a value to a DateTime or returns $null.
  #>
  param([object]$Value)
  if ($null -eq $Value) { return $null }
  try { return (Get-Date $Value) } catch { return $null }
}

# =============================================================================
# Section 2: Local OS discovery
# =============================================================================

function Get-LocalWindowsFacts {
  <#
    .SYNOPSIS
      Collects the minimum local OS information required for lifecycle mapping.
  .DESCRIPTION
      Uses Win32_OperatingSystem and the CurrentVersion registry key to determine:
        - Server vs Client
        - Edition hints used for Win11 flavor selection
        - DisplayVersion/ReleaseId needed for strict client mapping
        - Server year/version hints used for strict server mapping
  #>

  $os = Get-CimInstance -ClassName Win32_OperatingSystem
  $cv = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'

  $caption     = $os.Caption
  $productType = [int]$os.ProductType

  # ProductType: 1 = workstation, 2 = domain controller, 3 = server
  $isServer = ($productType -ne 1) -or ($caption -match '\bServer\b')

  $editionId   = Get-PropValue -Object $cv -Name "EditionID"
  $productName = Get-PropValue -Object $cv -Name "ProductName"

  # Not all builds expose DisplayVersion. ReleaseId is older naming.
  $displayVersion = Get-PropValue -Object $cv -Name "DisplayVersion"
  $releaseId      = Get-PropValue -Object $cv -Name "ReleaseId"
  $effectiveDV    = if ($displayVersion) { $displayVersion } else { $releaseId }

  # Build numbers help with client "Windows 10 vs 11" determination.
  $build = 0
  $ubr   = 0
  $cb = Get-PropValue -Object $cv -Name "CurrentBuild"
  $u  = Get-PropValue -Object $cv -Name "UBR"
  if ($cb -as [int]) { $build = [int]$cb }
  if ($u  -as [int]) { $ubr   = [int]$u  }

  $clientMajor = if ($build -ge 22000) { "11" } else { "10" }

  # Used only to avoid mapping consumer/pro installs to enterprise lifecycle rows.
  $isEduEnt =
    ($editionId -match '^(Enterprise|Education)') -or
    ($caption -match '\b(Enterprise|Education)\b') -or
    ($productName -match '\b(Enterprise|Education)\b')

  # Best-effort hints for LTSC/IoT for Windows 11 variant selection.
  $isIoT  = ($editionId -match 'IoT') -or ($caption -match '\bIoT\b') -or ($productName -match '\bIoT\b')
  $isLTSC = ($caption -match 'LTSC|LTSB') -or ($productName -match 'LTSC|LTSB')

  # Server mapping hints:
  # - Most LTSC servers include a year in the name: "Windows Server 2019".
  # - Some server builds may present as "Windows Server, version 1809".
  $serverYear = $null
  if ($caption -match '(20\d{2})') { $serverYear = $Matches[1] }
  elseif ($productName -match '(20\d{2})') { $serverYear = $Matches[1] }

  $serverVersion = $null
  if ($caption -match '\bversion\s+(\d{4})\b') { $serverVersion = $Matches[1] }
  elseif ($productName -match '\bversion\s+(\d{4})\b') { $serverVersion = $Matches[1] }

  [PSCustomObject]@{
    ComputerName = $env:COMPUTERNAME
    Caption      = $caption
    ProductName  = $productName
    EditionId    = $editionId

    EffectiveDisplayVersion = $effectiveDV
    FullBuild    = "$build.$ubr"

    IsServer     = $isServer
    ClientMajor  = $clientMajor

    IsEducationOrEnterprise = $isEduEnt
    IsIoT        = $isIoT
    IsLTSC       = $isLTSC

    ServerYearHint    = $serverYear
    ServerVersionHint = $serverVersion

    Now = Get-Date
  }
}

# =============================================================================
# Section 3: API query and normalization
# =============================================================================

function Get-EndOfLifeReleases {
  <#
    .SYNOPSIS
      Retrieves releases from endoflife.date and normalizes fields used by the script.
    .DESCRIPTION
      Normalizes each release into a predictable object containing:
        - Cycle/Label
        - EOAS/EOL dates
        - isEoas/isEol booleans (when present)
        - latest build/link (when present)
  #>
  param(
    [Parameter(Mandatory)][string]$ApiUrl,
    [Parameter(Mandatory)][string]$ProductName
  )

  $resp = Invoke-RestMethod -Method Get -Uri $ApiUrl -ContentType "application/json" -MaximumRedirection 10
  $rels = $resp.result.releases
  if (-not $rels) { throw "API response did not include result.releases[]." }

  foreach ($r in $rels) {
    $latestObj   = Get-PropValue -Object $r -Name "latest"
    $latestBuild = $null
    $latestLink  = $null
    if ($null -ne $latestObj) {
      $latestBuild = Get-PropValue -Object $latestObj -Name "name"
      $latestLink  = Get-PropValue -Object $latestObj -Name "link"
    }

    [PSCustomObject]@{
      Product     = $ProductName
      Cycle       = Get-PropValue -Object $r -Name "name"
      Label       = Get-PropValue -Object $r -Name "label"
      ReleaseDate = ConvertTo-DateOrNull (Get-PropValue -Object $r -Name "releaseDate")

      EOAS        = ConvertTo-DateOrNull (Get-PropValue -Object $r -Name "eoasFrom")
      EOL         = ConvertTo-DateOrNull (Get-PropValue -Object $r -Name "eolFrom")

      ApiIsEoas   = Get-PropValue -Object $r -Name "isEoas"
      ApiIsEol    = Get-PropValue -Object $r -Name "isEol"

      Maintained  = Get-PropValue -Object $r -Name "isMaintained"
      LatestBuild = $latestBuild
      Link        = $latestLink
    }
  }
}

# =============================================================================
# Section 4: Strict mapping logic (build candidate cycle names)
# =============================================================================

function Get-ClientFlavorSuffix {
  <#
    .SYNOPSIS
      Determines the Windows Client lifecycle suffix used in endoflife.date cycle names.

    .DESCRIPTION
      endoflife.date can publish separate lifecycle rows for Windows client variants, using
      suffixes like:
        -w       (consumer/pro “workstation” style row)
        -e       (Enterprise/Education row)
        -e-lts   (Enterprise LTSC/LTSB row)
        -iot-lts (IoT Enterprise LTSC/LTSB row)

      This function selects the suffix strictly from local OS identifiers gathered by
      Get-LocalWindowsFacts, so we do not guess.

      Data sources (where the detection flags come from):
        - Registry: HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion
            EditionID, ProductName
        - WMI/CIM: Win32_OperatingSystem
            Caption

      Detection flags (computed in Get-LocalWindowsFacts):
        - IsEducationOrEnterprise: EditionID/Caption/ProductName contains Enterprise or Education
        - IsLTSC: Caption/ProductName contains LTSC or LTSB
        - IsIoT: EditionID/Caption/ProductName contains IoT
  #>
  param([Parameter(Mandatory)]$Facts)

  # If local OS metadata indicates LTSC/LTSB (or IoT), return the matching endoflife.date suffix.
  if ($Facts.IsLTSC -and $Facts.IsIoT) { return "iot-lts" }
  if ($Facts.IsLTSC -and $Facts.IsEducationOrEnterprise) { return "e-lts" }

  # Otherwise fall back to Enterprise/Education vs standard workstation row.
  if ($Facts.IsEducationOrEnterprise) { return "e" } else { return "w" }
}

function Build-ExpectedClientCycles {
  <#
    .SYNOPSIS
      Builds strict candidate cycle names for Windows Client installs.
    .DESCRIPTION
      - Requires DisplayVersion or ReleaseId from the local machine.
      - Windows 11: returns exactly one candidate (always suffixed), e.g. 11-24h2-w / 11-24h2-e-lts.
      - Windows 10: returns two candidates. If LTSC/IoT is detected, prefer the *-lts variant first.
  #>
  param([Parameter(Mandatory)]$Facts)

  # Need DisplayVersion/ReleaseId to build a cycle name (no guessing).
  if (-not $Facts.EffectiveDisplayVersion) { return @() }

  # Normalise local values to match endoflife.date naming.
  $dv     = $Facts.EffectiveDisplayVersion.ToLowerInvariant()
  $suffix = Get-ClientFlavorSuffix -Facts $Facts

  # Windows 11 cycles are always suffixed in our mapping.
  if ($Facts.ClientMajor -eq "11") {
    return @("11-$dv-$suffix")
  }

  # Windows 10: try the base cycle and a suffixed cycle.
  $base     = "10-$dv"
  $specific = "$base-$suffix"

  # If this looks like an LTSC/IoT variant, prefer the more specific row first.
  if ($suffix -like "*lts") {
    return @($specific, $base)
  }

  # Otherwise, prefer the general row first.
  return @($base, $specific)
}

function Build-ExpectedServerCycles {
  <#
    .SYNOPSIS
      Builds strict candidate cycle names for Windows Server installs.
    .DESCRIPTION
      Uses only explicit identifiers present in the OS name:
        - Year-based:   "Windows Server 2019"        -> cycle "2019"
        - Version-based:"Windows Server, version 1809"-> cycle "1809"
      If neither identifier is present, returns no candidates (no guessing).
  #>
  param([Parameter(Mandatory)]$Facts)

  $candidates = @()
  if ($Facts.ServerYearHint)    { $candidates += $Facts.ServerYearHint }
  if ($Facts.ServerVersionHint) { $candidates += $Facts.ServerVersionHint }
  return $candidates
}

# =============================================================================
# Section 5: Strict match (exact cycle only)
# =============================================================================

function Find-ReleaseByExactCycle {
  <#
    .SYNOPSIS
      Returns the first API release whose Cycle exactly matches any candidate.
  #>
  param(
    [Parameter(Mandatory)]$Releases,
    [Parameter(Mandatory)][string[]]$CandidateCycles
  )

  foreach ($c in $CandidateCycles) {
    $hit = $Releases | Where-Object { $_.Cycle -eq $c } | Select-Object -First 1
    if ($hit) { return $hit }
  }
  return $null
}

# =============================================================================
# Section 6: Support status (derived from API booleans)
# =============================================================================

function Get-SupportStatusFromApiFlags {
  <#
    .SYNOPSIS
      Converts API boolean flags into a simplified support status.
    .DESCRIPTION
      If the API booleans are missing, returns Unknown.
  #>
  param(
    [Parameter()]$ApiIsEoas,
    [Parameter()]$ApiIsEol
  )

  if ($null -eq $ApiIsEoas -or $null -eq $ApiIsEol) { return "Unknown" }
  if ($ApiIsEol)  { return "OutOfSupport" }
  if ($ApiIsEoas) { return "SecurityOnly" }
  return "FullySupported"
}

# =============================================================================
# Section 7: Main
# =============================================================================

Write-Host "=== Windows OS Lifecycle Report ===`n"

$facts = Get-LocalWindowsFacts

Write-Host "Computer Name   : $($facts.ComputerName)"
Write-Host "OS Name         : $($facts.Caption)"
Write-Host "ProductName     : $($facts.ProductName)"
Write-Host "Edition         : $($facts.EditionId)"
Write-Host "Display/Release : $($facts.EffectiveDisplayVersion)"
Write-Host "Build           : $($facts.FullBuild)"
Write-Host "OS Type         : $(if ($facts.IsServer) { 'Server' } else { 'Client' })"
Write-Host ""

Write-Host "Querying lifecycle data..."

$apiUrl  = if ($facts.IsServer) { $ServerApiUrl } else { $ClientApiUrl }
$product = if ($facts.IsServer) { "windows-server" } else { "windows" }

try {
  $releases = Get-EndOfLifeReleases -ApiUrl $apiUrl -ProductName $product
}
catch {
  Write-Host "[Error] Failed to query lifecycle API: $($_.Exception.Message)"
  exit 1
}

# Build candidate cycle(s) and attempt strict matching.
[string[]]$candidateCycles = @()
$mappingNote = $null

if ($facts.IsServer) {
  $candidateCycles = @(Build-ExpectedServerCycles -Facts $facts)
  $mappingNote = if (@($candidateCycles).Count -eq 0) {
    "Server: OS name did not expose a year (20xx) or 'version ####'; refusing to guess."
  } else {
    "Server: strict match against cycle(s): " + ($candidateCycles -join ", ")
  }
}
else {
  $candidateCycles = @(Build-ExpectedClientCycles -Facts $facts)
  $mappingNote = if (@($candidateCycles).Count -eq 0) {
    "Client: DisplayVersion/ReleaseId missing; refusing to guess."
  } else {
    "Client: strict match against cycle(s): " + ($candidateCycles -join ", ")
  }
}

if ($Diagnostics) {
  Write-Host "[Diagnostics]"
  Write-Host "  Product dataset : $product"
  Write-Host "  Candidate cycles: $(if (@($candidateCycles).Count -gt 0) { $candidateCycles -join ', ' } else { '<none>' })"
  Write-Host "  Note            : $mappingNote"
  if (-not $facts.IsServer -and $facts.ClientMajor -eq "11") {
    Write-Host "  Win11 flavor    : $(Get-ClientFlavorSuffix -Facts $facts)"
  }
  Write-Host ""
}

$match = $null
if (@($candidateCycles).Count -gt 0) {
  $match = Find-ReleaseByExactCycle -Releases $releases -CandidateCycles $candidateCycles
}

if (-not $match) {
  Write-Host "Lifecycle match  : UNKNOWN"
  Write-Host "Reason           : $mappingNote"
  Write-Host ""
  Write-Host "Status           : Unknown"
  Write-Host "Recommendation   : Unable to determine lifecycle reliably from this machine + dataset."
  exit 0
}

# Date deltas for reporting convenience
$now = $facts.Now
$daysToEOAS = if ($match.EOAS) { ($match.EOAS - $now).Days } else { $null }
$daysToEOL  = if ($match.EOL)  { ($match.EOL  - $now).Days } else { $null }

# Support status from API booleans (preferred)
$status = Get-SupportStatusFromApiFlags -ApiIsEoas $match.ApiIsEoas -ApiIsEol $match.ApiIsEol

$recommendation =
  switch ($status) {
    "OutOfSupport"   { "CRITICAL: Upgrade to a supported release immediately." }
    "SecurityOnly"   { "Plan: Upgrade before EOL (security updates end)." }
    "FullySupported" { "OK: Supported." }
    default          { "Unknown: API did not provide isEoas/isEol for this cycle." }
  }

# =============================================================================
# Section 8: Output
# =============================================================================

Write-Host "Lifecycle match  : $($match.Cycle)"
Write-Host "Release label    : $($match.Label)"
if ($match.ReleaseDate) { Write-Host "Release date     : $($match.ReleaseDate.ToShortDateString())" }
if ($match.LatestBuild) { Write-Host "Latest build     : $($match.LatestBuild)" }

if ($match.EOAS) { Write-Host "EOAS             : $($match.EOAS.ToShortDateString()) (days: $daysToEOAS)" }
if ($match.EOL)  { Write-Host "EOL              : $($match.EOL.ToShortDateString()) (days: $daysToEOL)" }

Write-Host "IsEOAS           : $($match.ApiIsEoas)"
Write-Host "IsEOL            : $($match.ApiIsEol)"
Write-Host "Maintained       : $($match.Maintained)"
if ($match.Link) { Write-Host "Reference        : $($match.Link)" }

Write-Host ""
Write-Host "Status           : $status"
Write-Host "Recommendation   : $recommendation"

# =============================================================================
# Section 9: Optional Custom Field Writes (NinjaOne)
# =============================================================================
# Attempts to update each custom field that was enabled in the parameters.
# All updates run independently; any failures set $ExitCode to 1 so the script
# can report partial failure to NinjaOne at the end.
# =============================================================================

# Initialize exit code; will change to 1 if any custom field update fails
$ExitCode = 0

# ----------------------------------------------------------------------
# WYSIWYG
# ----------------------------------------------------------------------
if ($EnableWysiwyg) {
    Write-Host "`nAttempting to set WYSIWYG custom field: '$WysiwygCustomFieldName'..."

    try {
      # ============================
      # Build WYSIWYG Lifecycle Card
      # ============================

      # --- Status Icon Map ---
      $StatusIcons = @{
          'FullySupported' = @{ class='fas fa-check-circle';       color='#007644' }
          'SecurityOnly'   = @{ class='fas fa-exclamation-circle'; color='#FAC905' }
          'OutOfSupport'   = @{ class='fas fa-times-circle';       color='#D53948' }
          'Unknown'        = @{ class='fas fa-question-circle';    color='#CCCCCC' }
      }
      
      # Friendly status text for display (keep $status unchanged for logic/keys)
      $displayStatus = switch ($status) {
        "FullySupported" { "Fully Supported" }
        "SecurityOnly"   { "Security Only" }
        "OutOfSupport"   { "Out of Support" }
        default          { "Unknown" }
      }

      $StatusIconData = $StatusIcons[$status]
      if (-not $StatusIconData) { $StatusIconData = $StatusIcons['Unknown'] }

      $StatusIcon = "<i class='$($StatusIconData.class)' style='color:$($StatusIconData.color);'></i>"

      # --- Date + Days Formatting ---
      function Format-DateDays {
          param([datetime]$Date, [int]$Days)

          if (-not $Date) { return "Unknown" }

          $str = $Date.ToString("dd/MM/yyyy")
          return "$str (days: $Days)"
      }

      # --- Colour helper for EOAS/EOL lines ---
      function Get-DateColor {
          param([int]$Days)

          if ($Days -gt 0) { return '#007644' }  # Green = future
          if ($Days -lt 0) { return '#D53948' }  # Red = past
          return '#FAC905'                       # Orange = today
      }

      # Build data values
      $eoasText = Format-DateDays -Date $match.EOAS -Days $daysToEOAS
      $eolText  = Format-DateDays -Date $match.EOL  -Days $daysToEOL

      $eoasColor = Get-DateColor -Days $daysToEOAS
      $eolColor  = Get-DateColor -Days $daysToEOL

      $eoasColored = "<span style='color:$eoasColor;'>$eoasText</span>"
      $eolColored  = "<span style='color:$eolColor;'>$eolText</span>"

      # endoflife.date product page (used to link the Release label)
      $eolProductPage = if ($facts.IsServer) { "https://endoflife.date/windows-server" } else { "https://endoflife.date/windows" }

      # Build card using string builder (Ninja compatible)
      [System.Collections.Generic.List[string]]$CardHTML = [System.Collections.Generic.List[string]]::new()
      $LabelColWidth = '240px'

      # Card start (full width)
      $CardHTML.Add('<div class="card" style="width:100%; max-width:none; display:block; box-sizing:border-box;">')

      # Title bar
      $CardHTML.Add('  <div class="card-title-box">')
      $CardHTML.Add('    <div class="card-title"><i class="fa-brands fa-windows" style="color:#0087d4;"></i>&nbsp;&nbsp;Windows OS Lifecycle Details</div>')
      $CardHTML.Add('  </div>')

      # Body
      $CardHTML.Add('  <div class="card-body" style="margin:0; padding:0;">')
      $CardHTML.Add('    <div role="table" style="margin:0; padding:0; width:100%; box-sizing:border-box;">')

      # --- Subheading helper ---
      function Add-Header {
          param($Text, $CardHTML)
          $CardHTML.Add("<div style='font-weight:700; margin-top:6px; margin-bottom:2px; color:#555;'>$Text</div>")
      }

      # --- Row helper ---
      function Add-Row {
          param($Label, $Value, $CardHTML, $LabelColWidth)

          $enc = [System.Web.HttpUtility]::HtmlEncode($Label)

          $CardHTML.Add("<div role='row' style='display:flex; margin:0; padding:0; font-size:13px; line-height:1;'>")
          $CardHTML.Add("  <div role='columnheader' style='width:$LabelColWidth; font-weight:600; padding:0px 0px;'>$enc</div>")
          $CardHTML.Add("  <div role='cell' style='width:100%; padding:0px 0px;'>$Value</div>")
          $CardHTML.Add('</div>')
      }

      # ============================
      # Section: Summary
      # ============================
      Add-Header "Summary" $CardHTML

      Add-Row "Status" "$StatusIcon&nbsp;$displayStatus"  $CardHTML '176px'
      Add-Row "Recommendation" $recommendation            $CardHTML '176px'

      # ============================
      # System + Lifecycle side-by-side
      # ============================
      $CardHTML.Add("<div style='display:flex; gap:28px; align-items:flex-start; flex-wrap:wrap; width:100%; margin-top:5px;'>")

      # ---- Left: System Information ----
      $CardHTML.Add("<div style='flex:1 1 520px; min-width:420px;'>")

      Add-Header "System Information" $CardHTML

      Add-Row "OS Name"           $facts.Caption                 $CardHTML $LabelColWidth
      Add-Row "ProductName"       $facts.ProductName             $CardHTML $LabelColWidth
      Add-Row "Edition"           $facts.EditionId               $CardHTML $LabelColWidth
      Add-Row "Display/Release"   $facts.EffectiveDisplayVersion $CardHTML $LabelColWidth
      Add-Row "Build"             $facts.FullBuild               $CardHTML $LabelColWidth
      Add-Row "OS Type"           $(if ($facts.IsServer) { 'Server' } else { 'Client' }) $CardHTML $LabelColWidth

      $CardHTML.Add("</div>")

      # ---- Right: Lifecycle Information ----
      $CardHTML.Add("<div style='flex:1 1 520px; min-width:420px;'>")

      Add-Header "Lifecycle Information" $CardHTML

      # 1) Lifecycle match removed
      # 2) Release label turned into link to endoflife.date product page
      $releaseLabelLinked = "<a href='$eolProductPage' target='_blank'>$($match.Label)</a>"
      Add-Row "Release label"          $releaseLabelLinked                               $CardHTML $LabelColWidth
      Add-Row "Release date"           $match.ReleaseDate.ToString("dd/MM/yyyy")         $CardHTML $LabelColWidth
      Add-Row "Latest build"           $match.LatestBuild                                $CardHTML $LabelColWidth

      Add-Row "End of Active Support"  $eoasColored                                      $CardHTML $LabelColWidth
      Add-Row "End of Life"            $eolColored                                       $CardHTML $LabelColWidth

      Add-Row "Reference"              "<a href='$($match.Link)' target='_blank'>$($match.Link)</a>" $CardHTML $LabelColWidth

      $CardHTML.Add("</div>")

      # close side-by-side wrapper
      $CardHTML.Add("</div>")

      # Close table + card
      $CardHTML.Add('    </div>')
      $CardHTML.Add('  </div>')
      $CardHTML.Add('</div>')

      # Join into final HTML
      $wysiwygValue = $CardHTML -join ''

      Set-NinjaProperty $WysiwygCustomFieldName $wysiwygValue
      Write-Host "Custom field '$WysiwygCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set custom field '$WysiwygCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# EOL Flag
# ----------------------------------------------------------------------
if ($EnableIsEol) {
    Write-Host "`nAttempting to set IsEOL custom field: '$IsEolCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $IsEolCustomFieldName -Value $match.ApiIsEol
        Write-Host "Custom field '$IsEolCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set IsEOL field '$IsEolCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# EOAS Flag
# ----------------------------------------------------------------------
if ($EnableIsEoas) {
    Write-Host "`nAttempting to set IsEOAS custom field: '$IsEoasCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $IsEoasCustomFieldName -Value $match.ApiIsEoas
        Write-Host "Custom field '$IsEoasCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set IsEOAS field '$IsEoasCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# EOL Date
# ----------------------------------------------------------------------
if ($EnableEolDate) {
    Write-Host "`nAttempting to set EOL Date custom field: '$EolDateCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $EolDateCustomFieldName -Value $match.EOL
        Write-Host "Custom field '$EolDateCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set EOL Date field '$EolDateCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# EOAS Date
# ----------------------------------------------------------------------
if ($EnableEoasDate) {
    Write-Host "`nAttempting to set EOAS Date custom field: '$EoasDateCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $EoasDateCustomFieldName -Value $match.EOAS
        Write-Host "Custom field '$EoasDateCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set EOAS Date field '$EoasDateCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Days to EOL
# ----------------------------------------------------------------------
if ($EnableDaysToEol) {
    Write-Host "`nAttempting to set DaysToEOL custom field: '$DaysToEolCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $DaysToEolCustomFieldName -Value $daysToEOL
        Write-Host "Custom field '$DaysToEolCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set DaysToEOL field '$DaysToEolCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Days to EOAS
# ----------------------------------------------------------------------
if ($EnableDaysToEoas) {
    Write-Host "`nAttempting to set DaysToEOAS custom field: '$DaysToEoasCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $DaysToEoasCustomFieldName -Value $daysToEOAS
        Write-Host "Custom field '$DaysToEoasCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set DaysToEOAS field '$DaysToEoasCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Lifecycle Status
# ----------------------------------------------------------------------
if ($EnableStatus) {
    Write-Host "`nAttempting to set Status custom field: '$StatusCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $StatusCustomFieldName -Value $status
        Write-Host "Custom field '$StatusCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set Status field '$StatusCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Recommendation
# ----------------------------------------------------------------------
if ($EnableRecommendation) {
    Write-Host "`nAttempting to set Recommendation custom field: '$RecommendationCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $RecommendationCustomFieldName -Value $recommendation
        Write-Host "Custom field '$RecommendationCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set Recommendation field '$RecommendationCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# OS Name (Caption)
# ----------------------------------------------------------------------
if ($EnableOsCaption) {
    Write-Host "`nAttempting to set OS Caption custom field: '$OsCaptionCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $OsCaptionCustomFieldName -Value $facts.Caption
        Write-Host "Custom field '$OsCaptionCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set OS Caption field '$OsCaptionCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# OS Build
# ----------------------------------------------------------------------
if ($EnableOsBuild) {
    Write-Host "`nAttempting to set OS Build custom field: '$OsBuildCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $OsBuildCustomFieldName -Value $facts.FullBuild
        Write-Host "Custom field '$OsBuildCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set OS Build field '$OsBuildCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Feature Update / Release
# ----------------------------------------------------------------------
if ($EnableFeatureUpdate) {
    Write-Host "`nAttempting to set Feature Update custom field: '$FeatureUpdateCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $FeatureUpdateCustomFieldName -Value $facts.EffectiveDisplayVersion
        Write-Host "Custom field '$FeatureUpdateCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set Feature Update field '$FeatureUpdateCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Product Name
# ----------------------------------------------------------------------
if ($EnableOsProductName) {
    Write-Host "`nAttempting to set Product Name custom field: '$OsProductNameFieldName'..."
    try {
        Set-NinjaProperty -Name $OsProductNameFieldName -Value $facts.ProductName
        Write-Host "Custom field '$OsProductNameFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set Product Name field '$OsProductNameFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# ----------------------------------------------------------------------
# Edition
# ----------------------------------------------------------------------
if ($EnableOsEdition) {
    Write-Host "`nAttempting to set Edition custom field: '$OsEditionCustomFieldName'..."
    try {
        Set-NinjaProperty -Name $OsEditionCustomFieldName -Value $facts.EditionId
        Write-Host "Custom field '$OsEditionCustomFieldName' was set successfully."
    }
    catch {
        Write-Host "[ERROR] Unable to set Edition field '$OsEditionCustomFieldName': $($_.Exception.Message)"
        $ExitCode = 1
    }
}

# Exit with accumulated status (0 = all fields updated successfully, 1 = one or more failures)
exit $ExitCode