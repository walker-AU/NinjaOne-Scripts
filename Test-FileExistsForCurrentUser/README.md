# 🔎 Test-FileExistsForCurrentUser.ps1

---

### Overview
This script is designed to run under the **SYSTEM** account and check whether a specific file or file pattern exists for the **currently logged-in user**.  
It makes it possible to perform logged-in-user-level checks in platforms like NinjaOne, where conditions and compound conditions run exclusively in the SYSTEM context.

The script detects the active user session, builds the correct profile path for that user, performs the file search, and returns a **structured exit code** that NinjaOne can use to determine whether remediation should run.

For example, this script can check whether an executable exists in the logged-in user's LocalAppData folder. If the file is missing, NinjaOne can then run a remediation script as the **Current Logged on User** to install the software.

---

### How It Works
1. Detects the **currently logged-in user**.
2. Builds the full path by combining the user’s profile directory with the specified `Relative User Folder Path`
3. Searches the folder for the given `File Name Pattern`, supporting wildcards and nested paths.
4. Determines the result:
   - File found or no logged-in user - `exit 0`
   - Unexpected error - `exit 1`
   - File not found - `exit 2`
  
---

## 🧰 Script Variables

Add the following Script Variables when importing this script into NinjaOne:

| Display Name | Variable Name | Type | Description |
|--------------|---------------|------|-------------|
| **Relative User Folder Path** | `relativeUserFolderPath` | Text | Folder path under the user’s profile to search in. Supports nested paths and wildcards. Multiple matching folders are searched. Examples: AppData\Local\8x8*, AppData\Roaming\Zoom, Documents\Logs*, Desktop\MyApp |
| **File Name Pattern** | `fileNamePattern` | Text | File name or wildcard pattern to detect. Supports any file type. Using a full filename or extension pattern is recommended for accuracy (e.g., 8x8-Work.exe, 8x8*.exe, config.json), but extensionless patterns are also allowed (e.g., 8x8*, myfile). |

---

## Using in a Condition or Compound Condition

This script is intended to be used inside a **Condition** or **Compound Condition** in NinjaOne as a **Script result condition**.

When setting up your condition:

- Set the **Result code** to **equal to 2**
- Set the **Output** to **does not contain**

This ensures the condition only triggers when the logged-in user does not have the expected file or pattern, allowing NinjaOne to run your remediation script in the appropriate context (such as the current logged-in user).

<img width="403.5" height="534.75" alt="image" src="https://github.com/user-attachments/assets/fb5dea6c-fea8-483b-a545-62bbc120ab37" />
