<#
=========================================================================================
Update-NinjaOrganizationCustomFields - NinjaOne Organization Custom Field Bulk Updater (Standalone, Secure)
=========================================================================================

Author:     walkerAU
Version:    1.0
Date:       2025-10-24
Purpose:    This PowerShell script connects to the NinjaOne API using Client 
            Credentials (via an encrypted secret file), reads a CSV of organizations 
            and custom field values, and updates a specified custom field for each 
            matching organization. It supports case-insensitive matching by name and 
            uses encrypted authentication for secure execution.
			
Requirements:
			The API client must have both "monitoring" and "management" scopes enabled
			in the NinjaOne Admin portal. These scopes are required for authentication
			and to allow updates to organization custom fields.
			
-----------------------------------------------------------------------------------------
KEY FEATURES
-----------------------------------------------------------------------------------------
- Standalone: No dependencies on external modules - just PowerShell and a stored secret file.
- Secure: Uses an encrypted client secret (machine/user protected).
- Matches organizations by name (case-insensitive).
- Updates one custom field per organization.
- Displays progress and summary in a clear, color-coded output.
- Validates parameters and CSV path before connecting to the API.

-----------------------------------------------------------------------------------------
CSV INPUT FORMAT
-----------------------------------------------------------------------------------------
Your CSV file must follow this exact format and use the exact column names shown below:

organization,customfieldvalue
Example IT,ABC123
Tech Corp,XYZ456

- The "organization" column must exactly match the organization name in NinjaOne.
- The "customfieldvalue" column contains the value to assign.

-----------------------------------------------------------------------------------------
SECURE SETUP: ENCRYPTED CLIENT SECRET
-----------------------------------------------------------------------------------------
To avoid storing your Client Secret in plain text, create an encrypted version once
on the same machine. PowerShell uses your user/machine key for encryption.

Example:
    # Create a secure client secret file (only readable by this user on this PC)
    ConvertTo-SecureString -String "YOUR_CLIENT_SECRET" -AsPlainText -Force |
        Export-Clixml -Path "C:\N1\clientsecret.xml"

Then, reference that file path when running the script:
    .\Update-NinjaOrganizationCustomFields.ps1 -ClientId "YOUR_CLIENT_ID" `
        -EncryptedClientSecretPath "C:\N1\clientsecret.xml"

-----------------------------------------------------------------------------------------
USAGE EXAMPLE
-----------------------------------------------------------------------------------------
You can either hardcode your parameters at the top of the script (easiest), 
run it interactively in PowerShell ISE or VS Code, or execute it directly 
from a PowerShell terminal or command line.

Example (after editing the parameters inside the script):
       powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\Update-NinjaOrganizationCustomFields.ps1"

Or, run it interactively (e.g. in ISE):
       Open the script, review or modify parameters, then run.

Or, pass parameters directly when executing:
       .\Update-NinjaOrganizationCustomFields.ps1 `
           -ClientId "YOUR_CLIENT_ID" `
           -EncryptedClientSecretPath "C:\N1\clientsecret.xml" `
           -Region "OC" `
           -CustomFieldName "YOUR_CUSTOM_FIELD_NAME_HERE" `
           -CsvPath "C:\N1\organization_customfields.csv"

-----------------------------------------------------------------------------------------
NOTES
-----------------------------------------------------------------------------------------
- Default OAuth2 scope: "monitoring management"
- Region-based API endpoints (https://<region>.ninjarmm.com/api/v2)
=========================================================================================
#>

# =====================================================================================
# PARAMETERS
# =====================================================================================
# Controls authentication, region settings, and input sources for this script.
# Modify defaults below or supply as arguments when executing.
# =====================================================================================

param(
    [string]$ClientId = 'YOUR_CLIENT_ID_HERE',                      	# Your NinjaOne API Client ID (from Administration > Apps > API)
    [string]$EncryptedClientSecretPath = 'C:\N1\clientsecret.xml',  	# Full path to your encrypted client secret (.xml) file (see setup notes above)
    [string]$Region = 'OC',                                         	# Your NinjaOne region (e.g. OC, US2, EU, CA, APP, FED)
    [string]$Scope = 'monitoring management',                       	# Required OAuth2 scopes: monitoring management
    [string]$CustomFieldName = 'YOUR_CUSTOM_FIELD_NAME_HERE',       	# The name of the custom field to update - make sure it matches exactly as it appears in NinjaOne (case-sensitive)
    [string]$CsvPath = 'C:\N1\organization_customfields.csv'        	# Path to your CSV input file
)

# =====================================================================================
# HELPER FUNCTIONS
# =====================================================================================

function Connect-NinjaOne {
    param(
        [Parameter(Mandatory)][string]$ClientId,                 	# API Client ID from NinjaOne
        [Parameter(Mandatory)][string]$EncryptedClientSecretPath, 	# Path to encrypted client secret file (.xml)
        [string]$Scope = 'monitoring management',                	# OAuth2 scopes required for access
        [string]$Region = 'OC'                                   	# NinjaOne region (e.g. OC, US2, EU, CA, APP, FED)
    )

    # Build base API and authentication endpoints
    $BaseApiUri = "https://$Region.ninjarmm.com/api/v2"
    $AuthUri    = "https://$Region.ninjarmm.com/oauth/token"

    Write-Host "Connecting to NinjaOne ($Region region)..." -ForegroundColor Cyan

    try {
        # Import and decrypt the stored client secret
        $SecureSecret = Import-Clixml $EncryptedClientSecretPath
        $Ptr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
        $ClientSecret = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr)
    }
    catch {
        Write-Host "Failed to load encrypted client secret: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }

    # Prepare authentication payload for token request
    $Body = @{
        grant_type    = 'client_credentials'
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    try {
        # Request access token using client credentials
        $TokenResponse = Invoke-RestMethod -Uri $AuthUri -Method Post -Body $Body -ErrorAction Stop
        $AccessToken   = $TokenResponse.access_token
        if (-not $AccessToken) { throw "No access token returned." }

        Write-Host "Authentication successful.`n" -ForegroundColor Green

        # Return session object containing token and base URI
        return [pscustomobject]@{
            AccessToken = $AccessToken
            BaseApiUri  = $BaseApiUri
        }
    }
    catch {
        # Display error if authentication fails
        Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Get-NinjaOrganizations {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session   # Authenticated API session object
    )

    Write-Host "Fetching organizations..." -ForegroundColor Cyan

    try {
        # Retrieve all organizations from the NinjaOne API
        $Organizations = Invoke-RestMethod -Uri "$($Session.BaseApiUri)/organizations" `
            -Headers @{ Authorization = "Bearer $($Session.AccessToken)" } `
            -ErrorAction Stop

        Write-Host "Retrieved $($Organizations.Count) organizations.`n" -ForegroundColor Green
        return $Organizations
    }
    catch {
        # Display a clear error if retrieval fails
        Write-Host "Failed to fetch organizations: $($_.Exception.Message)" -ForegroundColor Red
        return $null
    }
}

function Set-NinjaOrganizationCustomField {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][PSCustomObject]$Session,   # Authenticated API session object
        [Parameter(Mandatory)][int]$Id,                   # Target organization ID
        [Parameter(Mandatory)][PSCustomObject]$Fields     # Custom field(s) and value(s) to update
    )

    # Build the full API endpoint for updating organization custom fields
    $Uri = "$($Session.BaseApiUri)/organization/$Id/custom-fields"

    try {
        # Send PATCH request with JSON body and authorization header
        Invoke-RestMethod -Uri $Uri `
            -Method Patch `
            -Headers @{
                Authorization = "Bearer $($Session.AccessToken)"
                "Content-Type" = "application/json"
            } `
            -Body ($Fields | ConvertTo-Json) `
			-ErrorAction Stop
    }
    catch {
        # Throw a clear error message if the update fails
        throw "Failed to update organization ID {$Id}: $($_.Exception.Message)"
    }
}

# =====================================================================================
# VALIDATION & SESSION SETUP
# =====================================================================================

# --- Validate Required Parameters ---
if ($CustomFieldName -eq 'YOUR_CUSTOM_FIELD_NAME_HERE') {
    Write-Host "Please specify a valid -CustomFieldName before running." -ForegroundColor Yellow
    return
}

# --- Validate CSV Path ---
if (-not (Test-Path $CsvPath)) {
    Write-Host "CSV file not found at path: $CsvPath" -ForegroundColor Red
    return
}

# --- Establish API Session ---
$Session = Connect-NinjaOne -ClientId $ClientId -EncryptedClientSecretPath $EncryptedClientSecretPath -Scope $Scope -Region $Region
if (-not $Session) { return }

# --- Get Organizations ---
$Organizations = Get-NinjaOrganizations -Session $Session
if (-not $Organizations) { return }

# =====================================================================================
# MAIN SCRIPT LOGIC
# =====================================================================================

# --- Load CSV ---
Write-Host "Reading CSV file: $CsvPath" -ForegroundColor Cyan
$CsvData = Import-Csv -Path $CsvPath
if (-not $CsvData -or $CsvData.Count -eq 0) {
    Write-Host "No data found in CSV file." -ForegroundColor Red
    return
}

# --- Process Each Row ---
$UpdatedCount = 0
$NotFound = 0
$Failed = 0
$Skipped = 0

Write-Host ""
Write-Host ("--- Processing {0} rows from CSV ---" -f $CsvData.Count) -ForegroundColor Cyan
Write-Host ""

foreach ($row in $CsvData) {
    $CsvName = $row.organization
    $CustomValue = $row.customfieldvalue

    # --- Handle missing data ---
    if (-not $CsvName) {
        Write-Host "[SKIPPED]   <NO NAME>: missing organization" -ForegroundColor Yellow
        $Skipped++
        continue
    }
    elseif (-not $CustomValue) {
        Write-Host ("[SKIPPED]   {0}: missing customfieldvalue" -f $CsvName) -ForegroundColor Yellow
        $Skipped++
        continue
    }

    # --- Match organization ---
    $Match = $Organizations | Where-Object { $_.name -ieq $CsvName }

    if ($Match) {
        $OrgId = $Match.id
        try {
            Set-NinjaOrganizationCustomField -Session $Session -Id $OrgId -Fields @{ $CustomFieldName = $CustomValue } | Out-Null
            Write-Host ("[UPDATED]   {0} (ID: {1})" -f $CsvName, $OrgId) -ForegroundColor Green
            $UpdatedCount++
        }
        catch {
            $ErrorMsg = ($_ | Out-String).Trim()
            Write-Host ("[FAILED]    {0}: {1}" -f $CsvName, $ErrorMsg) -ForegroundColor Red
            $Failed++
        }
    }
    else {
        Write-Host ("[NOTFOUND]  {0}: no matching organization" -f $CsvName) -ForegroundColor Red
        $NotFound++
    }
}

# --- Summary ---
Write-Host "`nUpdate Summary:" -ForegroundColor Cyan
Write-Host "----------------------------------"
Write-Host ("Updated   : {0}" -f $UpdatedCount)
Write-Host ("Not Found : {0}" -f $NotFound)
Write-Host ("Failed    : {0}" -f $Failed)
Write-Host ("Skipped   : {0}" -f $Skipped)
Write-Host "----------------------------------`n"
