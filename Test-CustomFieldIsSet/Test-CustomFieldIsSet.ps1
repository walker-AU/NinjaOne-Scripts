# ===============================================================
# Script: Test-CustomFieldIsSet.ps1
# Author: Sam Walker
# Date: 2025-10-17
#
# Notes:
#   - Checks whether a specified NinjaOne custom field is set or empty.
#   - Can be configured to pass when the field has a value (default)
#     or when the field is empty (by enabling "Field Must Be Empty To Pass").
#   - Designed for use in NinjaOne as a quick validation or compliance check.
# ===============================================================

# =============================
# Test Custom Field Is Set
# =============================

# This script retrieves the value of a specified NinjaOne custom field.
# It evaluates the value and determines success or failure based on whether it is empty.
# Use the 'FieldMustBeEmptyToPass' flag if the field should be empty for the script to pass.

[CmdletBinding()]
param (
    [string]$CustomFieldName,       # The name of the custom field to check
    [bool]$FieldMustBeEmptyToPass   # If set, the script will pass when the field is empty or null
)

# =============================
# NinjaOne Variable Overrides
# =============================

# Override with NinjaOne variables if provided.
# This allows the script to use technician-supplied values from the NinjaOne UI instead of the default parameters.
if ($env:CustomFieldName -and $env:CustomFieldName -ne "null") { $CustomFieldName = $env:CustomFieldName }
if ($env:FieldMustBeEmptyToPass -and $env:FieldMustBeEmptyToPass -ne "null") { $FieldMustBeEmptyToPass = [System.Convert]::ToBoolean($env:FieldMustBeEmptyToPass) }

# =============================
# Input Validation
# =============================

# Ensure a custom field name was provided before proceeding.
if (-not $CustomFieldName) {
    Write-Error "Custom field name not provided. Please set 'CustomFieldName' as a script variable."
    exit 1
}

# =============================
# Retrieve Custom Field Value
# =============================

# Try to get the value of the specified custom field from NinjaOne.
try {
    $value = Ninja-Property-Get $CustomFieldName
} catch {
    Write-Error "Failed to retrieve custom field: $CustomFieldName"
    exit 1
}

# =============================
# Main Logic
# =============================

# Display the retrieved value for reference.
Write-Host "Custom field '$CustomFieldName' value: '$value'"

# Determine whether the field has a meaningful value (not null, empty, or whitespace).
$FieldHasValue = -not [string]::IsNullOrWhiteSpace($value)

# =============================
# Pass/Fail Evaluation
# =============================

# Decide whether the script should pass or fail based on the field value
# and whether the user wants it to pass when the field is empty.

if ($FieldMustBeEmptyToPass) {
    # The user has chosen to pass when the field is empty.
    if (-not $FieldHasValue) {
        # Field is empty - this is the expected result.
        Write-Host "PASS: Field is empty, as expected."
        exit 0
    } else {
        # Field has a value, but it was expected to be empty.
        Write-Host "FAIL: Field has a value, but should be empty."
        exit 1
    }
} else {
    # The user has chosen to pass when the field has a value.
    if (-not $FieldHasValue) {
        # Field is empty, but a value was expected.
        Write-Host "FAIL: Field is empty, but a value was expected."
        exit 1
    } else {
        # Field has a value, which is the expected result.
        Write-Host "PASS: Field has a value, as expected."
        exit 0
    }
}
