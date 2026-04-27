# VM StartStop TagBased — Azure Automation Runbook

A PowerShell runbook for Azure Automation that automatically **starts and stops Virtual Machines** based on an `AutoShutdownSchedule` tag applied at the VM or Resource Group level.

> **Original Author:** Amalkumar  
> **Runbook Name:** `VM_StartStop_TagBased`  
> **Version:** 1.0 


---

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Automation Account Setup](#automation-account-setup)
- [RBAC Permissions](#rbac-permissions)
- [Parameters](#parameters)
- [Tag Configuration](#tag-configuration)
- [Schedule Examples](#schedule-examples)
- [How It Works](#how-it-works)
- [Testing (Simulate Mode)](#testing-simulate-mode)
- [Files](#files)

---

## Overview

This runbook scans all Virtual Machines in an Azure subscription and checks whether each VM (or its parent Resource Group) has an `AutoShutdownSchedule` tag. It compares the current UTC time against the schedule and:

- **Stops** the VM if the current time falls **within** the schedule window
- **Starts** the VM if the current time falls **outside** the schedule window

The runbook is designed to run on a **recurring schedule** (e.g., every hour) via Azure Automation.

---

## Prerequisites

- Azure Automation Account with **System-Assigned Managed Identity** enabled
- The following **Az PowerShell modules** imported into the Automation Account:
  - `Az.Accounts`
  - `Az.Compute`
  - `Az.Resources`
- An Automation **Variable** named `Default Azure Subscription ID` containing your subscription GUID

---

## Automation Account Setup

### 1. Enable Managed Identity

```
Automation Account → Identity → System assigned → Status: On → Save
```

Copy the **Object (principal) ID** — you'll need it for role assignment.

### 2. Create Automation Variable

```
Automation Account → Shared Resources → Variables → Add a variable

Name  : Default Azure Subscription ID
Type  : String
Value : <your-subscription-id-guid>
```

### 3. Import Required Modules

```
Automation Account → Shared Resources → Modules → Browse gallery

Search and import:
  - Az.Accounts
  - Az.Compute
  - Az.Resources
```

> Import `Az.Accounts` first, as the others depend on it. Wait for each to finish before importing the next.

### 4. Create the Runbook

```
Automation Account → Runbooks → Create a runbook

Name        : VM_StartStop_TagBased
Runbook type: PowerShell
```

Paste the contents of `VM_StartStop_TagBased.ps1`, click **Save**, then **Publish**.

### 5. Create a Schedule and Link It

```
Automation Account → Schedules → Add a schedule

Name      : VM-StartStop-Hourly
Frequency : Hourly
Interval  : 1
```

Then link it to the runbook:

```
Runbook → Link to schedule → Select schedule → Set parameters:
  Simulate = false
```

---

## RBAC Permissions

The Automation Account's Managed Identity requires the following role assignments at **subscription scope**:

| Role | Scope | Purpose |
|---|---|---|
| `Reader` | Subscription | List VMs and Resource Groups |
| `Virtual Machine Contributor` | Subscription | Start and Stop VMs |

### Assign Roles

```
Subscription → Access Control (IAM) → Add role assignment
  → Role: Virtual Machine Contributor
  → Assign access to: Managed Identity
  → Select: <your Automation Account name>

Repeat for Reader role.
```

> Alternatively, assign `Contributor` at subscription scope for a simpler setup, at the cost of broader permissions.

---

## Parameters

| Parameter | Type | Default | Description |
|---|---|---|---|
| `AzureCredentialName` | String | `"Use *Default Automation Credential* Asset"` | Legacy — not used when Managed Identity is enabled |
| `AzureSubscriptionName` | String | `"Use *Default Azure Subscription* Variable Value"` | Legacy — subscription is set via Automation Variable |
| `Simulate` | Bool | `$false` | If `$true`, no power actions are taken — only logs what would happen |

---

## Tag Configuration

Apply the tag directly to a **VM** or to a **Resource Group**.

| Tag Name | Tag Value |
|---|---|
| `AutoShutdownSchedule` | See examples below |

### Rules

- Tag name is **case-insensitive**
- Tag value is **comma-separated** for multiple ranges
- All times are interpreted as **UTC**
- A **VM-level tag takes precedence** over a Resource Group tag
- If a VM has **no tag and its RG has no tag**, the VM is skipped entirely

---

## Schedule Examples

### Stop all day (VM never runs)
```
0:00 -> 23:59:59
```

### Business hours only — stop nights and weekends
```
19:00 -> 07:00, Saturday, Sunday
```
VM is stopped from 7 PM to 7 AM on weekdays, and all day on weekends.

### Stop during overnight window only
```
18:00 -> 06:00
```
Crosses midnight — handled automatically by the runbook.

### Stop on weekends only
```
Saturday, Sunday
```

### Stop outside core hours (multiple windows)
```
0:00 -> 08:00, 18:00 -> 23:59:59, Saturday, Sunday
```
VM runs only between 8 AM and 6 PM on weekdays.

### Stop on a specific date
```
December 25
```

### Apply to all VMs in a Resource Group
Tag the **Resource Group** instead of individual VMs. All VMs in the RG will inherit the schedule automatically.

### Override a Resource Group schedule on one VM
Tag the specific **VM** directly with its own `AutoShutdownSchedule` value. VM-level tags are checked first and always win.

---

## How It Works

```
Runbook triggered (hourly schedule)
    │
    ├── Connect-AzAccount -Identity
    ├── Get all VMs in subscription
    ├── Get all Resource Groups with AutoShutdownSchedule tag
    │
    └── For each VM:
          │
          ├── Has VM-level tag?        → Use VM tag
          ├── VM's RG has tag?         → Use RG tag (inherited)
          └── No tag found?            → Skip VM
                │
                ├── Parse comma-separated time ranges
                ├── CheckScheduleEntry() for each range (UTC comparison)
                │
                ├── Any range matched?
                │     YES → StoppedDeallocated (Stop-AzVM -Force)
                │     NO  → Started            (Start-AzVM)
```

### Midnight-Crossing Logic

When `rangeStart > rangeEnd` (e.g. `18:00 -> 06:00`), the runbook automatically adjusts:
- If current time is between `rangeStart` and midnight → push `rangeEnd` to tomorrow
- Otherwise → pull `rangeStart` back to yesterday

---

## Testing (Simulate Mode)

Run the runbook manually with `Simulate = $true` to validate your tag configuration without affecting any VMs.

```
Runbook → Start → Parameters:
  Simulate = true
```

Check the **Output** stream for messages like:

```
[myVM]: SIMULATION -- Would have stopped VM. (No action taken)
[myVM]: SIMULATION -- Would have started VM. (No action taken)
[myVM]: Current power state [running] is correct.
```

---

## Files

```
.
├── VM_StartStop_TagBased.ps1   # The PowerShell runbook
└── README.md                   # This file
```

---

## References

- [Original script documentation](https://automys.com/library/asset/scheduled-virtual-machine-shutdown-startup-microsoft-azure)
- [Azure Automation Managed Identity](https://learn.microsoft.com/en-us/azure/automation/enable-managed-identity-for-automation)
- [Az.Compute PowerShell module](https://learn.microsoft.com/en-us/powershell/module/az.compute/)
