<#
=========================================================================================
NinjaOne Device Report Script (Standalone, Secure)
=========================================================================================

Author:     walkerAU
Version:    1.1
Date:       2025-10-22
Purpose:    This PowerShell script connects to the NinjaOne API using OAuth2 Client 
            Credentials (via an encrypted secret file), retrieves all organizations, 
            locations, and devices (with pagination), and outputs a clean, readable table 
            of devices including creation date, system name, organization, location, 
            approval status, and last contact time.

-----------------------------------------------------------------------------------------
KEY FEATURES
-----------------------------------------------------------------------------------------
- No dependencies on external modules — just PowerShell and a stored secret file.
- Uses **encrypted client secret** for secure credential handling.
- Authenticates automatically (OAuth2 Client Credentials flow).
- Handles pagination for organizations, locations, and devices.
- Supports device filtering via the NinjaOne `df` (device filter) parameter.
- Displays output in a color-coded, neatly truncated table sorted by organization and system name.
- Optional report export to CSV.

-----------------------------------------------------------------------------------------
SECURE SETUP: ENCRYPTED CLIENT SECRET
-----------------------------------------------------------------------------------------
To avoid storing your Client Secret in plain text, create an encrypted version once
on the same machine. PowerShell uses your user/machine key for encryption.

Example:
    # Create a secure client secret file (only readable by this user on this PC)
    ConvertTo-SecureString -String "YOUR_CLIENT_SECRET" -AsPlainText -Force |
        Export-Clixml -Path "C:\N1\clientsecret.xml"

Then, reference that file path in the script or when running it:
    .\Get-NinjaDeviceReport.ps1 -ClientId "YOUR_CLIENT_ID" `
        -EncryptedClientSecretPath "C:\N1\clientsecret.xml"

PowerShell will decrypt it automatically at runtime for authentication.

-----------------------------------------------------------------------------------------
USAGE EXAMPLE
-----------------------------------------------------------------------------------------
You can either hardcode your parameters at the top of the script (easiest), or run it
with parameters supplied on the command line.

Example (after editing the parameters inside the script):
       powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\Get-NinjaDeviceReport.ps1"

Or, pass a device filter dynamically when running:
       .\Get-NinjaDeviceReport.ps1 -Filter "class = WINDOWS_SERVER AND offline"

To adjust which devices are retrieved, you can set the `$Filter` value to things like:
       'status = PENDING'
       'status = APPROVED'
       'online'
       'class = WINDOWS_SERVER'
       'class = WINDOWS_SERVER AND offline'

For a full list of available filter options, see:
       https://app.ninjarmm.com/apidocs-beta/core-resources/articles/devices/device-filters

Common region values:
       OC, US2, EU, CA, APP, FED
   (These correspond to your NinjaOne instance region.)

To export results directly to a CSV file:
       .\Get-NinjaDeviceReport.ps1 -CreateReport $true -ReportPath "C:\Reports\Devices.csv"

-----------------------------------------------------------------------------------------
OUTPUT FIELDS
-----------------------------------------------------------------------------------------
- created          : Date/time device was created (converted from Unix timestamp)
- systemName       : System name of the device
- organizationName : Friendly organization name (via /organizations)
- locationName     : Device location name (via /locations)
- approvalStatus   : Device approval status
- offline          : Whether the device is offline (True/False)
- lastContact      : Last contact time (converted from Unix timestamp)

-----------------------------------------------------------------------------------------
NOTES
-----------------------------------------------------------------------------------------
- Default OAuth2 scope is 'monitoring'.
- Region-based API endpoints (https://<region>.ninjarmm.com/api/v2).
- Pagination handled automatically for large result sets.
- Console output is color-coded for clarity (info, success, warning, error).

=========================================================================================
#>

param(
    [string]$ClientId = 'YOUR_CLIENT_ID_HERE',                     	# Your NinjaOne API Client ID (from Administration > Apps > API)
    [string]$EncryptedClientSecretPath = 'C:\N1\clientsecret.xml', 	# Full path to your encrypted client secret (.xml) file (see setup notes above)
    [string]$Region = 'OC',                                        	# Your NinjaOne region (e.g. OC, US2, EU, CA, APP, FED)
    [string]$Scope = 'monitoring',                                 	# Default OAuth2 scope for NinjaOne API
    [string]$Filter = 'status = PENDING',							# Device filter (see API docs for examples)
    [bool]$CreateReport = $false,                                  	# If true, export results to CSV
    [string]$ReportPath = "C:\N1\NinjaDeviceReport.csv"            	# Output CSV path (used only if -CreateReport is true)
)

# =====================================================================================
# HELPER FUNCTIONS
# =====================================================================================

function Connect-NinjaOne {
    param(
        [Parameter(Mandatory)][string]$ClientId,
        [Parameter(Mandatory)][string]$EncryptedClientSecretPath,
        [string]$Scope = 'monitoring',
        [string]$Region = 'OC'
    )

    $BaseApiUri = "https://$Region.ninjarmm.com/api/v2"
    $AuthUri    = "https://$Region.ninjarmm.com/oauth/token"

    Write-Host "Connecting to NinjaOne ($Region region)..." -ForegroundColor Cyan

    try {
        $SecureSecret = Import-Clixml $EncryptedClientSecretPath
        $Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
        $ClientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr)
    }
    catch {
        Write-Host "Failed to load encrypted client secret: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }

    $Body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    try {
        $TokenResponse = Invoke-RestMethod -Uri $AuthUri -Method Post -Body $Body
        $AccessToken   = $TokenResponse.access_token
        if (-not $AccessToken) { throw "No access token returned." }

        Write-Host "Authentication successful.`n" -ForegroundColor Green
        return [pscustomobject]@{
            AccessToken = $AccessToken
            BaseApiUri  = $BaseApiUri
        }
    }
    catch {
        Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }
}

function Invoke-NinjaAfterPagination {
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,
        [Parameter(Mandatory)][string]$ResourceBase,
        [hashtable]$Query = @{},
        [int]$PageSize = 200,
        [int]$StartAfter,
        [string]$IdProperty = 'id'
    )

    $after = $StartAfter
    $AllResults = @()

    do {
        $pairs = @()
        if ($PageSize) { $pairs += "pageSize=$PageSize" }
        if ($PSBoundParameters.ContainsKey('StartAfter')) { $pairs += "after=$after" }

        foreach ($k in $Query.Keys) {
            $v = $Query[$k]
            if ($null -ne $v -and $v -ne '') {
                $pairs += ('{0}={1}' -f [uri]::EscapeDataString([string]$k),
                                         [uri]::EscapeDataString([string]$v))
            }
        }

        $queryString = if ($pairs.Count) { '?' + ($pairs -join '&') } else { '' }
        $resource    = "$($Session.BaseApiUri)/$ResourceBase$queryString"

        try {
            $resp = Invoke-RestMethod -Uri $resource -Headers @{ Authorization = "Bearer $($Session.AccessToken)" }
            $items = if ($resp -and ($resp.PSObject.Properties.Name -contains 'Body')) { $resp.Body } else { $resp }
            $items = @($items)

            if (-not $items -or $items.Count -eq 0) { break }

            $AllResults += $items
            Write-Host "Fetched $($AllResults.Count) total from $ResourceBase..." -ForegroundColor DarkGray

            $last   = $items[-1]
            $idProp = $last.PSObject.Properties[$IdProperty]
            if (-not $idProp -or $null -eq $idProp.Value) { break }
            $after = [int]$idProp.Value
        }
        catch {
            Write-Host "Error fetching page ($ResourceBase): $($_.Exception.Message)" -ForegroundColor Red
            break
        }
    } while ($items.Count -eq $PageSize)

    return $AllResults
}

function Truncate-String($Value, $MaxLength) {
    if ($null -eq $Value) { return "" }
    if ($Value.Length -le $MaxLength) { return $Value }
    return $Value.Substring(0, $MaxLength - 3) + "..."
}

# =====================================================================================
# MAIN SCRIPT LOGIC
# =====================================================================================

$Session = Connect-NinjaOne -ClientId $ClientId -EncryptedClientSecretPath $EncryptedClientSecretPath -Scope $Scope -Region $Region

# --- Fetch Organizations ---
Write-Host "Fetching organizations..." -ForegroundColor Cyan
$OrgResults = @(Invoke-NinjaAfterPagination -Session $Session -ResourceBase 'organizations' -PageSize 5000)
$OrgLookup = @{}
foreach ($org in $OrgResults) { $OrgLookup[$org.id] = $org.name }
Write-Host "Organizations retrieved: $($OrgLookup.Count)`n" -ForegroundColor Green

# --- Fetch Locations ---
Write-Host "Fetching locations..." -ForegroundColor Cyan
$LocResults = @(Invoke-NinjaAfterPagination -Session $Session -ResourceBase 'locations' -PageSize 5000)
$LocationLookup = @{}
foreach ($loc in $LocResults) { $LocationLookup[$loc.id] = $loc.name }
Write-Host "Locations retrieved: $($LocationLookup.Count)`n" -ForegroundColor Green

# --- Fetch Devices ---
Write-Host "Fetching devices..." -ForegroundColor Cyan
$Query = @{}
if ($Filter) { $Query['df'] = $Filter }
$Devices = @(Invoke-NinjaAfterPagination -Session $Session -ResourceBase 'devices' -Query $Query -PageSize 5000)

if ($Devices -and $Devices.Count -gt 0) {
    Write-Host "`nDevices retrieved ($($Devices.Count)):`n" -ForegroundColor Green

    $Devices = $Devices | ForEach-Object {
        [PSCustomObject]@{
            created          = (Get-Date 1970-01-01).AddSeconds([math]::Floor($_.created))
            systemName       = $_.systemName
            organizationName = Truncate-String $OrgLookup[$_.organizationId] 30
            locationName     = Truncate-String $LocationLookup[$_.locationId] 25
            approvalStatus   = $_.approvalStatus
            offline          = $_.offline
            lastContact      = if ($_.lastContact) { (Get-Date 1970-01-01).AddSeconds([math]::Floor($_.lastContact)) } else { $null }
        }
    } | Sort-Object organizationName, systemName

    $Devices | Format-Table -AutoSize

    # --- Summary ---
    $OnlineCount  = ($Devices | Where-Object { -not $_.offline }).Count
    $OfflineCount = ($Devices | Where-Object { $_.offline }).Count
    $OrgCount     = ($Devices | Select-Object -ExpandProperty organizationName -Unique).Count
    Write-Host "`nSummary: $($Devices.Count) total devices - $OnlineCount online, $OfflineCount offline across $OrgCount organizations.`n" -ForegroundColor Cyan

    # --- Optional CSV Export ---
    if ($CreateReport) {
        try {
            $Devices | Export-Csv -Path $ReportPath -NoTypeInformation
            Write-Host "Report saved to: $ReportPath" -ForegroundColor Green
        }
        catch {
            Write-Host "Failed to save report: $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
else {
    Write-Host "`nNo devices returned." -ForegroundColor Yellow
}
