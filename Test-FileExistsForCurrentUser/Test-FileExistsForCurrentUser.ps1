# ===============================================================
# Test-FileExistsForCurrentUser.ps1
# Author: walkerAU
# Date: 2025-19-11
# ===============================================================
# Designed to run under SYSTEM context. Detects whether a file or file pattern
# exists for the currently logged-in user by searching a specified relative path
# within that user's profile directory.
#
# Supports wildcard patterns, nested paths, and all file types. Ideal for
# logged-in-user-level checks in NinjaOne where conditions run only as SYSTEM.
#
# When using this script inside a NinjaOne Condition, configure the condition
# to trigger remediation only when the Result Code is equal to 2.
#
# =============================
# Script Parameters
# =============================
# RelativeUserFolderPath: Relative folder path under the user's profile directory.
#                         Supports nested paths and wildcards.
#                         Examples: "AppData\Local\8x8*", "AppData\Roaming\Zoom", "Documents\Logs*", "Desktop\MyApp"
#
# FileNamePattern:        File name or wildcard pattern expected inside the folder.
#                         Supports any file type.
#                         Examples: "8x8-Work.exe", "*.exe", "config.json", "8x8*", "myfile"
[CmdletBinding()]
param (
    [string]$RelativeUserFolderPath = "AppData\Local\8x8*",
    [string]$FileNamePattern        = "8x8*.exe"
)

# =============================
# NinjaOne Variable Overrides
# =============================
# Override parameters with environment variables if provided by NinjaOne
# This allows the script to use technician-supplied values from the NinjaOne UI instead of the default parameters.
if ($env:RelativeUserFolderPath) { $RelativeUserFolderPath = $env:RelativeUserFolderPath }
if ($env:FileNamePattern)        { $FileNamePattern        = $env:FileNamePattern }

# =============================
# Global Error Handling
# =============================
# Force terminating errors and ensure unexpected failures exit with code 1 (script error).
$ErrorActionPreference = "Stop"

trap {
    Write-Host "Unexpected error occurred - unable to evaluate. Exiting 1."
    Write-Host $_.Exception.Message
    exit 1
}

# =============================
# Input Validation & Normalization
# =============================
# Trim whitespace from inputs (common issue with copy/paste in UI).
$RelativeUserFolderPath = $RelativeUserFolderPath.Trim()
$FileNamePattern        = $FileNamePattern.Trim()

# Validate that the RelativeUserFolderPath parameter is not empty.
if ([string]::IsNullOrWhiteSpace($RelativeUserFolderPath)) {
    Write-Host "RelativeUserFolderPath parameter cannot be empty."
    exit 1   # script error
}

# Validate that the FileNamePattern parameter is not empty.
if ([string]::IsNullOrWhiteSpace($FileNamePattern)) {
    Write-Host "FileNamePattern parameter cannot be empty."
    exit 1   # script error
}

# Normalize folder pattern: remove leading/trailing slashes.
# Safeguard: prevents malformed paths like "\App\" or "App\\"
$RelativeUserFolderPath = $RelativeUserFolderPath.Trim("\ /")

# Prevent invalid input consisting only of slashes.
if ($RelativeUserFolderPath -match '^[\\/]+$') {
    Write-Host "RelativeUserFolderPath cannot consist only of slashes."
    exit 1   # script error
}

# FileNamePattern must not contain slashes (should be a filename, not a path).
if ($FileNamePattern -like "*\*" -or $FileNamePattern -like "/*") {
    Write-Host "FileNamePattern must be a filename only, not a path."
    exit 1   # script error
}

# =============================
# Detect Current Logged-On User
# =============================
try {
    $LoggedOnUser = (Get-WmiObject Win32_ComputerSystem).UserName

    if (-not $LoggedOnUser) {
        Write-Host "No logged-on user detected. Exiting 0."
        exit 0
    }

    $NTAccount = New-Object System.Security.Principal.NTAccount($LoggedOnUser)
    $UserSID   = $NTAccount.Translate([System.Security.Principal.SecurityIdentifier]).Value
    
    # Resolve USERPROFILE using the user's Volatile Environment key.
    $VolatileKey = "Registry::HKEY_USERS\$UserSID\Volatile Environment"
    $UserProfile = (Get-Item $VolatileKey).GetValue("USERPROFILE")

    if (-not $UserProfile) {
        Write-Host "Unable to resolve USERPROFILE for $LoggedOnUser. Exiting 0."
        exit 0
    }

    Write-Host "Current logged-on user detected: $LoggedOnUser"
}
catch {
    Write-Host "Failed to determine logged-on user. Exiting 1."
    exit 1
}

# =============================
# Build Target Search Path
# =============================
# Build the full path from USERPROFILE + user-specified relative folder.
$SearchPattern = Join-Path $UserProfile $RelativeUserFolderPath

Write-Host "Searching for folder pattern: $SearchPattern"
Write-Host "Looking for file name pattern: $FileNamePattern"

# =============================
# Locate Matching Folders
# =============================
# Split the full search path into parent directory and folder pattern.
$ParentFolder  = Split-Path $SearchPattern -Parent
$FolderPattern = Split-Path $SearchPattern -Leaf

# Match folders at the parent directory level only.
$MatchedFolders = Get-ChildItem `
    -Path $ParentFolder `
    -Filter $FolderPattern `
    -Directory `
    -ErrorAction SilentlyContinue

if (-not $MatchedFolders) {
    # File not found - FAIL
    # No folders matched the specified folder pattern.
    Write-Host "No folders matched pattern: $RelativeUserFolderPath"
    Write-Host "File '$FileNamePattern' not found - FAIL"
    exit 2   # Exit code 2 used for file not found
}

Write-Host "Found $($MatchedFolders.Count) matching folder(s)."

# =============================
# Search & Result
# =============================
# Iterate through all folders that matched the pattern. Each folder is a potential
# location for the target file.
foreach ($Folder in $MatchedFolders) {
    Write-Host "Checking folder: $($Folder.FullName)"

    # Look for the expected file in this folder (supports wildcards).
    $FileMatches = Get-ChildItem `
        -Path $Folder.FullName `
        -Filter $FileNamePattern `
        -File `
        -ErrorAction SilentlyContinue

    # File found - PASS
    # The file exists for the current logged-on user.
    if ($FileMatches) {
        Write-Host "File found: $($FileMatches[0].FullName)"
        Write-Host "PASS: File detected for the current logged-on user."
        exit 0
    }
}

# File not found - FAIL
# No matching file found in any matched folder.
Write-Host "File '$FileNamePattern' not found in any matched folder."
Write-Host "FAIL: File not detected for the current logged-on user."
exit 2   # Exit code 2 used for file not found