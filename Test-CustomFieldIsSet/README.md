# 🧩 Test-CustomFieldIsSet.ps1

---

### Overview
This script checks whether a specified **NinjaOne custom field** is set or empty.  
It is useful for validating setup, ensuring required fields are populated, or confirming that a field has been intentionally left blank.

By default, the script **passes when the field has a value**.  
You can optionally reverse this behavior so it **passes when the field is empty** by using the **Field Must Be Empty To Pass** checkbox variable.

---

### How It Works
1. Retrieves the value of a specified **Custom Field** from NinjaOne.  
2. Checks if the field contains a meaningful value (not null, empty, or whitespace).  
3. Determines pass or fail based on the **Field Must Be Empty To Pass** variable.  
4. Exits with:
   - `exit 0` - Pass  
   - `exit 1` - Fail  

---

### 🧰 Script Variables

Add the following Script Variables to this script

| Display Name | Variable Name | Type | Description |
|---------------|----------------|--------|--------------|
| **Custom Field Name** | `customFieldName` | Text | The name of the custom field to check. |
| **Field Must Be Empty To Pass** | `fieldMustBeEmptyToPass` | Checkbox | If checked, the script will **pass** when the custom field is empty or not set. If unchecked, the script will **pass** when the field has a value. |

---

### Using in a Condition or Compound Condition

This script can be used in **Conditions** or **Compound Conditions** in NinjaOne as a **Script Result**.  

When setting up your condition:
- Set the **Result code** to **not equal to 0**  
- Set the **Output** to **does not contain**  

This allows the condition to trigger properly when the script fails, based on your chosen logic.

#### Example configuration screenshot
<img width="535" height="713" alt="Screenshot 2025-10-17 135525" src="https://github.com/user-attachments/assets/b63bfed2-4e13-4665-951e-23e07874359f" />

