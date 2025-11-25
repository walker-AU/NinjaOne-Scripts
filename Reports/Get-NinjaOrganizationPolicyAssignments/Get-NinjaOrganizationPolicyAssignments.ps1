<#
=========================================================================================
NinjaOne Organization Policy Assignment Report (Standalone, Secure)
=========================================================================================

Author:     walkerAU
Version:    1.0
Date:       2025-11-26
Purpose:    Securely connect to the NinjaOne API using Client Credentials, retrieve
            full lists of organizations (detailed), policies, and node roles, and
            generate a complete Organization > NodeRole > Policy mapping in either:

              1) ROW MODE:
                      Organization | NodeRole | PolicyId | PolicyName

              2) COLUMN MODE:
                      Organization | <NodeRole1> | <NodeRole2> | ...

            In column mode, each cell contains the **PolicyName** assigned for that
            org/nodeRole pair.

-----------------------------------------------------------------------------------------
KEY FEATURES
-----------------------------------------------------------------------------------------
- Standalone: No dependencies on external modules - just PowerShell and a stored secret file.
- Secure: Uses an encrypted client secret (machine/user protected).
- Authenticates to the NinjaOne API using Client Credentials
- FULL Pagination handler supporting:
        • cursor-style responses
        • items + pageSize responses
        • raw arrays
- Retrieves:
        • /v2/organizations-detailed
        • /v2/policies
        • /v2/roles
- Two report modes:
        Row Mode    : Organization | NodeRole | PolicyId | PolicyName
        Column Mode : Pivot table with NodeRole columns and PolicyName cells
- Clean formatting, sorted output, optional CSV export

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
    .\Get-NinjaOrganizationPolicyAssignments.ps1 -ClientId "YOUR_CLIENT_ID" `
        -EncryptedClientSecretPath "C:\N1\clientsecret.xml"

=========================================================================================
#>

param(
    [string]$ClientId = "YOUR_CLIENT_ID_HERE",                         # Your NinjaOne API Client ID
    [string]$EncryptedClientSecretPath = "C:\N1\clientsecret.xml",     # Path to encrypted client secret (.xml)
    [string]$Region = "OC",                                            # Region (e.g., OC, US2, CA, EU, APP, FED)
    [string]$Scope = "monitoring",                                     # Required OAuth2 scopes: monitoring
    [ValidateSet("Row","Column")]                                      # Report output mode
    [string]$ReportStyle = "Row",
    [bool]$CreateReport = $false,                                      # Export CSV option
    [string]$ReportPath = "C:\N1\NinjaOrgPolicyAssignmentReport.csv"   # CSV output path
)

# =====================================================================================
# AUTH
# =====================================================================================

function Connect-NinjaOne {
    param(
        [string]$ClientId,
        [string]$EncryptedClientSecretPath,
        [string]$Scope,
        [string]$Region
    )

    $BaseApiUri = "https://$Region.ninjarmm.com/api/v2"
    $AuthUri    = "https://$Region.ninjarmm.com/oauth/token"

    Write-Host "Connecting to NinjaOne ($Region region)..." -ForegroundColor Cyan

    try {
        $SecureSecret = Import-Clixml $EncryptedClientSecretPath
        $Ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureSecret)
        $ClientSecret = [Runtime.InteropServices.Marshal]::PtrToStringAuto($Ptr)
    }
    catch {
        Write-Host "Failed to load encrypted client secret: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }

    $Body = @{
        grant_type    = "client_credentials"
        client_id     = $ClientId
        client_secret = $ClientSecret
        scope         = $Scope
    }

    try {
        $Response = Invoke-RestMethod -Uri $AuthUri -Method Post -Body $Body
        if (-not $Response.access_token) { throw "No access token returned." }

        Write-Host "Authentication successful.`n" -ForegroundColor Green

        return [pscustomobject]@{
            AccessToken = $Response.access_token
            BaseApiUri  = $BaseApiUri
        }
    }
    catch {
        Write-Host "Authentication failed: $($_.Exception.Message)" -ForegroundColor Red
        exit
    }
}

function Invoke-NinjaApiRequest {
    param(
        [pscustomobject]$Session,
        [string]$Resource
    )

    $Uri = "$($Session.BaseApiUri)/$Resource"
    $Headers = @{ Authorization = "Bearer $($Session.AccessToken)" }

    return Invoke-RestMethod -Uri $Uri -Headers $Headers -Method Get
}

# =====================================================================================
# UNIVERSAL PAGINATION HANDLER
# =====================================================================================

function Invoke-NinjaPaginatedRequest {
    param(
        [pscustomobject]$Session,
        [string]$ResourceBase,
        [int]$PageSize = 500
    )

    $Results = @()
    $Cursor  = $null
    $After   = $null

    do {
        $qp = @("pageSize=$PageSize")
        if ($Cursor) { $qp += "cursor=$Cursor" }
        if ($After)  { $qp += "after=$After"   }

        $QueryString = '?' + ($qp -join '&')
        $Resource    = "$ResourceBase$QueryString"

        $Resp = Invoke-NinjaApiRequest -Session $Session -Resource $Resource

        # CASE 1 — cursor-style wrapper
        if ($Resp.PSObject.Properties.Name -contains "results") {
            $Chunk = @($Resp.results)
        }
        # CASE 2 — items/pageSize wrapper
        elseif ($Resp.PSObject.Properties.Name -contains "items") {
            $Chunk = @($Resp.items)
        }
        # CASE 3 — raw array
        elseif ($Resp -is [System.Collections.IEnumerable] -and $Resp.GetType().Name -eq "Object[]") {
            $Chunk = @($Resp)
        }
        else {
            $Chunk = @($Resp)
        }

        $Results += $Chunk

        # Cursor continuation
        if ($Resp.PSObject.Properties.Name -contains "cursor" -and $Resp.cursor.name) {
            $Cursor = $Resp.cursor.name
        }
        else {
            $Cursor = $null
        }

        # ID-based continuation
        if ($Chunk.Count -gt 0 -and $Chunk[-1].id) {
            $After = $Chunk[-1].id
        }

    } while ($Cursor -or ($Chunk.Count -eq $PageSize))

    return $Results
}

# =====================================================================================
# MAIN
# =====================================================================================

# Establish API Session
$Session = Connect-NinjaOne -ClientId $ClientId -EncryptedClientSecretPath $EncryptedClientSecretPath -Scope $Scope -Region $Region

# Retrieve Organizations (Detailed)
Write-Host "Fetching organizations..." -ForegroundColor Cyan
$Orgs = Invoke-NinjaPaginatedRequest -Session $Session -ResourceBase "organizations-detailed"
Write-Host "Organizations retrieved: $($Orgs.Count)" -ForegroundColor Green

# Retrieve Policies
Write-Host "Fetching policies..." -ForegroundColor Cyan
$Policies = Invoke-NinjaPaginatedRequest -Session $Session -ResourceBase "policies"
$PolicyLookup = @{}
foreach ($p in $Policies) { $PolicyLookup[$p.id] = $p.name }
Write-Host "Policies retrieved: $($Policies.Count)" -ForegroundColor Green

# Retrieve Node Roles
Write-Host "Fetching node roles..." -ForegroundColor Cyan
$Roles = Invoke-NinjaPaginatedRequest -Session $Session -ResourceBase "roles"
$RoleLookup = @{}
foreach ($r in $Roles) { $RoleLookup[$r.id] = $r.name }
Write-Host "NodeRoles retrieved: $($Roles.Count)" -ForegroundColor Green

# =====================================================================================
# BUILD REPORT
# =====================================================================================

# -----------------------------------------------------------
# ROW MODE
# -----------------------------------------------------------
if ($ReportStyle -eq "Row") {

    Write-Host "Building ROW report..." -ForegroundColor Cyan

    $Report = foreach ($org in $Orgs) {

        foreach ($pol in $org.policies) {

            [pscustomobject]@{
                Organization = $org.name
                NodeRole     = $RoleLookup[$pol.nodeRoleId]
                PolicyId     = $pol.policyId
                PolicyName   = $PolicyLookup[$pol.policyId]
            }
        }
    }

    $Report = $Report | Sort-Object Organization, NodeRole, PolicyName
}

# -----------------------------------------------------------
# COLUMN MODE (PIVOT)
# -----------------------------------------------------------
if ($ReportStyle -eq "Column") {

    Write-Host "Building COLUMN report..." -ForegroundColor Cyan

    $AllNodeRoleNames = $Roles.name | Sort-Object -Unique

    $Report = foreach ($org in $Orgs) {

        $row = [ordered]@{ Organization = $org.name }

        # Initialize blank NodeRole columns
        foreach ($roleName in $AllNodeRoleNames) {
            $row[$roleName] = ""
        }

        # Fill assigned policy names
        foreach ($pol in $org.policies) {
            $roleName   = $RoleLookup[$pol.nodeRoleId]
            $policyName = $PolicyLookup[$pol.policyId]

            if ($roleName -and $policyName) {
                $row[$roleName] = $policyName
            }
        }

        [pscustomobject]$row
    }

    $Report = $Report | Sort-Object Organization
}

# =====================================================================================
# OUTPUT
# =====================================================================================

Write-Host "`nPolicy Assignment Report:`n" -ForegroundColor Cyan
$Report | Format-Table -AutoSize

Write-Host "`nSummary:" -ForegroundColor Cyan
Write-Host "----------------------------------"
Write-Host ("Organizations     : {0}" -f $Orgs.Count)
Write-Host ("Policies          : {0}" -f $Policies.Count)
Write-Host ("NodeRoles         : {0}" -f $Roles.Count)
Write-Host "----------------------------------`n"

# =====================================================================================
# CSV EXPORT
# =====================================================================================

if ($CreateReport) {
    try {
        $Report | Export-Csv -Path $ReportPath -NoTypeInformation
        Write-Host "Report saved to: $ReportPath" -ForegroundColor Green
    }
    catch {
        Write-Host "Failed to save CSV: $($_.Exception.Message)" -ForegroundColor Red
    }
}
