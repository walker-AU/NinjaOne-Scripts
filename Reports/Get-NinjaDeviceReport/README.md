# 🖥️ Get-NinjaDeviceReport.ps1

A secure PowerShell script that connects to the NinjaOne API using OAuth2 client credentials.  
It retrieves organizations, locations, and devices (with pagination and optional filtering) and outputs a clean, readable table or CSV report showing each device’s creation date, system name, organization, location, approval status, and last contact time.

## ⚙️ 1. Prerequisites

You must first create an API Client in NinjaOne.

1. Log in to your NinjaOne console.  
2. Go to Administration → Apps → API.  
3. Select **Add client app**.  
4. Fill out the following details:  
   - Application Platform: `API Services (machine-to-machine)`
   - Name: Provide a descriptive name 
   - Redirect URIs: Leave blank  
   - Scopes: `Monitoring`  
   - Allowed Grant Types: `Client Credentials`  
5. Click Save.  
6. Copy your **Client ID** and **Client Secret** – you’ll need these in the next step.
---
## 🔐 2. Securely Store Your Client Secret

To avoid storing your Client Secret in plain text, create an encrypted version once on the same machine where the script will run. PowerShell uses your user/machine key for encryption, so only that user on that computer can decrypt it.

Run this once to create the encrypted secret file:

```powershell
# Create a secure version of your client secret (only readable by this user)
ConvertTo-SecureString -String "YOUR_CLIENT_SECRET" -AsPlainText -Force |
    Export-Clixml -Path "C:\N1\clientsecret.xml"
```
Then reference that file path in the script or when running it:
```
.\Get-NinjaDeviceReport.ps1 -ClientId "YOUR_CLIENT_ID" `
    -EncryptedClientSecretPath "C:\N1\clientsecret.xml"
```
---
## 🧩 3. Configure the Script

Open **Get-NinjaDeviceReport.ps1** and update the parameter values near the top:

```powershell
param(
    [string]$ClientId = 'YOUR_CLIENT_ID_HERE',                     	# Your NinjaOne API Client ID (from Administration > Apps > API)
    [string]$EncryptedClientSecretPath = 'C:\N1\clientsecret.xml', 	# Full path to your encrypted client secret (.xml) file (see setup notes above)
    [string]$Region = 'OC',                                        	# Your NinjaOne region (e.g. OC, US2, EU, CA, APP, FED)
    [string]$Scope = 'monitoring',                                 	# Default OAuth2 scope for NinjaOne API
    [string]$Filter = 'status = PENDING',					        # Device filter (see API docs for examples)
    [bool]$CreateReport = $false,                                  	# If true, export results to CSV
    [string]$ReportPath = "C:\N1\NinjaDeviceReport.csv"            	# Output CSV path (used only if -CreateReport is true)
)
```
---
## ▶️ 4. Run the Script

You can run it directly or with custom parameters.

### Basic Run

```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\Get-NinjaDeviceReport.ps1"
```
### Run with Custom Filter and CSV Output
```
.\Get-NinjaDeviceReport.ps1 -Filter "class = WINDOWS_SERVER AND offline" `
    -CreateReport $true -ReportPath "C:\Reports\NinjaDevices.csv"
```
---
## 🔍 5. Filter Examples

You can adjust which devices are retrieved using the `$Filter` parameter.  
Filters use the same syntax as the NinjaOne `df` (device filter) query parameter.

### Common Examples

```powershell
'status = PENDING'
'status = APPROVED'
'online'
'class = WINDOWS_SERVER'
'class = WINDOWS_SERVER AND offline'
```
For a full list of available filter options, see the official [NinjaOne Device Filters documentation](https://app.ninjarmm.com/apidocs-beta/core-resources/articles/devices/device-filters).

---
## 📊 6. Output Details

When you run the script, it outputs a clean PowerShell table with the following fields. If `-CreateReport` is set to `$true`, the same data is also exported to the CSV file specified by `-ReportPath`.

```text
created              systemName     organizationName    locationName     approvalStatus    offline    lastContact
-------              -----------    ----------------    -------------    ---------------   --------   ------------
2025-02-12 10:42:11  AHO-WSL12F9Z   Example IT          Sydney Office    APPROVED          False      2025-10-22 08:33:27
