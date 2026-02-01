# Disk Health Status (PowerShell)

A Windows PowerShell GUI utility that uses **[smartctl (smartmontools)](https://github.com/smartmontools/smartmontools)** to query SMART data from all physical disks, evaluate SSD/HDD health, display results and inform you in a glance in a simple WPF popup ordered by Windows drive letter, and write a dated health log to disk.

---

## Why?
* I wanted to task-schedule a pop-up at boot weekly to quickly inform me about my disks health, and could not find anything that had  this function. CrystalDiskInfo is great but I have to either run it continoously or to remember opening it and going through different tabs.

## Features

* Enumerates all physical disks via CIM (`Win32_DiskDrive`).
* Robust `smartctl` invocation with multiple device-type fallbacks (raw, NVMe, ATA, SAT, SCSI, auto).
* Supports both **SSD (SATA & NVMe)** and **HDD** health evaluation.
* Parses SMART data conservatively, without vendor-specific assumptions beyond common attributes.
* Orders disks by their associated Windows drive letters (C:, D:, …) for clarity.
* Displays results in a **WPF GUI popup** with color-coded status.
* Writes a **dated UTF‑8 log file** summarizing disk health.
* Works when `smartctl.exe` is system-installed, colocated with the script, or extracted to `%TEMP%`.

---

## Screenshot

<img width="530" height="380" alt="image" src="https://github.com/user-attachments/assets/fbddc294-568a-4e82-bd56-1f837bf57a71" />


---

## Usage

Download from releases.

Run from an **elevated PowerShell session**:

```powershell
powershell -ExecutionPolicy Bypass -File .\DiskHealth.ps1
```

Or double‑click  one of the prepackaged exe's (log/nolog) with embedded `smartctl`.

---

## Recommended powershell script to register a weekly check at boot with elevation via Task Scheduler

```powershell
# Action
$Action = New-ScheduledTaskAction -Execute "PowerShell.exe" `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"C:\Scripts\DiskHealth\disk_health.ps1`""

# Trigger: Weekly at a specific time (runs even if machine was off)
$Trigger = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At 09:00AM

# Run elevated as SYSTEM
$Principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Register the task
Register-ScheduledTask -TaskName "DiskHealthWeekly" `
    -Action $Action `
    -Trigger $Trigger `
    -Principal $Principal `
    -Description "Run Disk Health WPF script weekly at boot"
```

---

## Requirements

* Windows 10 / 11
* PowerShell 5.1 or PowerShell 7+
* **[smartmontools (smartctl)](https://github.com/smartmontools/smartmontools)**

  * Recommended: system installation at `C:\Program Files\smartmontools\bin\smartctl.exe`
* Administrator privileges (strongly recommended)

> Without elevation, `smartctl` may fail to access `\\.\PhysicalDriveN` and some disks will report **Unknown**.

---

## smartctl Resolution Order

The script selects `smartctl.exe` using the following priority:

1. System-installed path:

   ```text
   C:\Program Files\smartmontools\bin\smartctl.exe
   ```
2. `smartctl.exe` in the same directory as the running script or compiled EXE
3. Fallback to `%TEMP%\smartctl.exe` (for embedded or extracted deployments)

The chosen path is printed to stdout at runtime.

---

## Health Evaluation Logic

### SSD (SATA / NVMe)

* **NVMe**

  * Uses `Percentage Used` (or equivalent) from SMART / NVMe log
  * Health is computed as:

    ```text
    Health % = 100 − Percentage Used
    ```

* **SATA SSD**

  * Looks for common wear attributes such as:

    * `Wear_Leveling`
    * `Wear_Leveling_Count`
  * Extracts the **normalized VALUE column** (0–100)

* **Status thresholds**:

  * `≥ 90%` → **Good**
  * `70–89%` → **Caution**
  * `< 70%` → **Bad**

If no reliable wear indicator is found, the disk is marked **Unknown**.

---

### HDD

Evaluates critical SMART attributes:

* `Reallocated_Sector_Count`
* `Current_Pending_Sector`
* `Offline_Uncorrectable`

**Status logic**:

* Pending or unreadable sectors > 0 → **Bad**
* Reallocated sectors > 0 → **Caution**
* Otherwise → **Good**

---

## Disk Ordering

Disks are sorted by their **associated Windows drive letters**:

* The smallest drive letter (e.g. `C:` before `D:`) is used as the primary sort key.
* Disks without mounted volumes are shown last.

This makes the UI consistent with how users perceive disk layout in Windows.

---

## GUI Output

For each disk, the popup shows:

* Model name
* Primary drive letter (if any)
* Disk type (SSD / HDD)
* Physical device ID (`\\.\PhysicalDriveN`)
* Health status (color-coded)
* Additional detail text (health %, reallocated sectors, or error reason)

Color coding:

* **Green**: Good
* **Orange**: Caution
* **Red**: Bad
* **Gray**: Unknown / unreadable

A system notification sound is played when the window appears.

---

## Logging

A log file is written next to the script or executable:

```text
DiskHealth-DDMMYYYY.log
```

Each disk is logged on its own block, for example:

```text
Samsung SSD 970 EVO Plus (C:) [\\.\PhysicalDrive0]: Good (96%)

Seagate ST2000DM008 (D:) [\\.\PhysicalDrive1]: Caution (Reallocated sectors 12)
```

Encoding: UTF‑8

---

## Limitations and Notes

* USB bridges and some RAID controllers may block SMART passthrough.
* Vendor-specific SMART attributes are intentionally ignored unless widely standardized.
* Results should be treated as **diagnostic indicators**, not guarantees of disk longevity.
* Always maintain backups, regardless of reported health.

---

## License

GPL‑3.0

---

## Acknowledgements

* **smartmontools** project for `smartctl`
* Microsoft WMI / CIM infrastructure
