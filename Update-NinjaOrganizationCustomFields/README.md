# 🛠️ Update-NinjaOrganizationCustomFields.ps1
A secure, standalone PowerShell script that connects to the NinjaOne API using OAuth2 client credentials.
It reads a CSV of organizations and custom field values, then updates each matching organization’s custom field in bulk — securely, efficiently, and with clear, color-coded progress and summary output.

---

## 1. Prerequisites

You must first create an API Client in NinjaOne.

1. Log in to your NinjaOne console.  
2. Go to **Administration → Apps → API**.  
3. Select **Add client app**.  
4. Fill out the following details:  
   - Application Platform: `API Services (machine-to-machine)`
   - Name: Provide a descriptive name  
   - Redirect URIs: Leave blank  
   - Scopes: `Monitoring Management`  
   - Allowed Grant Types: `Client Credentials`  
5. Click **Save**.  
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
---
## 🧩 3. Configure the Script

Open **Update-NinjaOrganizationCustomFields.ps1** and review or update the parameter values near the top of the script:

```powershell
param(
    [string]$ClientId = 'YOUR_CLIENT_ID_HERE',                        # NinjaOne API Client ID (Administration > Apps > API)
    [string]$EncryptedClientSecretPath = 'C:\N1\clientsecret.xml',    # Full path to your encrypted client secret (.xml)
    [string]$Region = 'OC',                                           # NinjaOne region (e.g. OC, US2, EU, CA, APP, FED)
    [string]$Scope = 'monitoring management',                         # Required OAuth2 scopes for API access
    [string]$CustomFieldName = 'YOUR_CUSTOM_FIELD_NAME_HERE',         # The custom field name to update — must match exactly as it appears in NinjaOne (case-sensitive)
    [string]$CsvPath = 'C:\N1\organization_customfields.csv'          # Path to your CSV input file (must include: organization,customfieldvalue)
)
```
---
## 📄 4. CSV Format

Your CSV file **must follow this exact format** and use the **exact column names** shown below:
- The column names **must be exactly** `organization` and `customfieldvalue` *(all lowercase, no spaces).*  
- The `organization` value must exactly match the organization name in NinjaOne.  
- The `customfieldvalue` value defines the data assigned to the specified custom field.
```csv
organization,customfieldvalue
Example IT,ABC123
Tech Corp,XYZ456
```
---
## ▶️ 5. Run the Script

You can run **Update-NinjaOrganizationCustomFields.ps1** either interactively or by passing parameters at runtime.

### 🧠 Option 1 - Basic Run
If you’ve already configured your parameters inside the script, simply run it directly from PowerShell, **ISE**, or **VS Code**:
```powershell
powershell.exe -ExecutionPolicy Bypass -File "C:\Scripts\Update-NinjaOrganizationCustomFields.ps1"
```

### ⚙️ Option 2 - Run with Parameters
To override parameters at runtime or use different input files, run it from the terminal:
```powershell
.\Update-NinjaOrganizationCustomFields.ps1 `
    -ClientId "YOUR_CLIENT_ID" `
    -EncryptedClientSecretPath "C:\N1\clientsecret.xml" `
    -Region "OC" `
    -CustomFieldName "YOUR_CUSTOM_FIELD_NAME_HERE" `
    -CsvPath "C:\N1\organization_customfields.csv"
```
---
## 📊 6. Output Details

When you run the script, it displays progress and results directly in the PowerShell console using color-coded messages.

```text
--- Processing 5 rows from CSV ---

[UPDATED]   Example IT (ID: 101)
[NOTFOUND]  Missing Org: no matching organization
[FAILED]    Demo Company: Failed to update organization ID {202} - Bad Request (400)
[SKIPPED]   <NO NAME>: missing organization
[SKIPPED]   Test Org: missing customfieldvalue
```

At the end, a summary section provides a clear overview:

```text
Update Summary:
----------------------------------
Updated   : 1
Not Found : 1
Failed    : 1
Skipped   : 2
----------------------------------
```
