Add-Type -AssemblyName PresentationFramework

# System-installed
$smartctl = "C:\Program Files\smartmontools\bin\smartctl.exe"

# Folder of running script or EXE
if ($PSCommandPath) {
    $scriptDir = Split-Path -Parent $PSCommandPath
} elseif ($MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptDir = Split-Path -Parent $([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
}

# Local EXE fallback
$localSmartctl = Join-Path $scriptDir "smartctl.exe"

# Embedded fallback (%TEMP%)
$embeddedSmartctl = Join-Path $env:TEMP "smartctl.exe"

if (-not (Test-Path $smartctl)) {
    if (Test-Path $localSmartctl) {
        $smartctl = $localSmartctl
    } else {
        $smartctl = $embeddedSmartctl
    }
}

Write-Output "Using smartctl at $smartctl"


# Admin check
function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
if (-not (Test-IsAdministrator)) {
    Write-Warning "This script is not running elevated. smartctl typically requires Administrator to query \\.\PhysicalDriveN. Run PowerShell as Administrator for reliable results."
}

# Enumerate physical disks (use CIM for cross-version compatibility)
$disks = Get-CimInstance -ClassName Win32_DiskDrive

# ------------------------------
# Helper: get drive letters associated with a physical disk (CIM-based)
# ------------------------------
function Get-DriveLettersForDisk {
    param([Parameter(Mandatory=$true)][object]$Disk)

    $letters = @()

    # Use CIM associations (works in PowerShell 5.1 and PowerShell Core)
    try {
        $partitions = Get-CimAssociatedInstance -InputObject $Disk -ResultClassName Win32_DiskPartition -ErrorAction Stop
    } catch {
        $partitions = @()
    }

    foreach ($part in $partitions) {
        try {
            $logicalDisks = Get-CimAssociatedInstance -InputObject $part -ResultClassName Win32_LogicalDisk -ErrorAction Stop
        } catch {
            $logicalDisks = @()
        }
        foreach ($ld in $logicalDisks) {
            if ($ld.DeviceID) { $letters += $ld.DeviceID }  # e.g. "C:"
        }
    }

    return ($letters | Sort-Object)
}

# ------------------------------
# Helper: robustly get smartctl output for a disk
# ------------------------------
function Get-SmartOutputForDisk {
    param(
        [Parameter(Mandatory=$true)][object] $Disk,
        [Parameter(Mandatory=$true)][string] $SmartCtlPath
    )

    $deviceId = $Disk.DeviceID  # e.g. \\.\PhysicalDrive0

    # Build a sequence of argument arrays to try
    $attempts = @()
    $attempts += ,@("-A", $deviceId)                           # try raw device path
    if ($Disk.Model -match "NVMe") {
        $attempts += ,@("-A", "-d", "nvme", $deviceId)         # explicit NVMe
    }
    # common device-type fallbacks
    $attempts += ,@("-A", "-d", "ata", $deviceId)
    $attempts += ,@("-A", "-d", "sat", $deviceId)
    $attempts += ,@("-A", "-d", "scsi", $deviceId)
    $attempts += ,@("-A", "-d", "auto", $deviceId)

    foreach ($args in $attempts) {
        try {
            $out = & $SmartCtlPath @args 2>&1
        } catch {
            $out = $_.Exception.Message
        }

        $text = ($out -join "`n")
        if ($LASTEXITCODE -eq 0 -and -not ($text -match "Unable to open device|No such file|Device does not support|failed to|Permission denied|not found")) {
            return ,($text -split "`r?`n")
        }
    }

    # Final fallback: map PhysicalDriveN -> sda/sdb/... (0->sda)
    $m = [regex]::Match($deviceId, '\d+$')
    if ($m.Success) {
        $idx = [int]$m.Value
        if ($idx -ge 0 -and $idx -lt 26) {
            $sdName = "sd" + [char](97 + $idx)
            try {
                $out = & $SmartCtlPath -A $sdName 2>&1
            } catch {
                $out = $_.Exception.Message
            }
            $text = ($out -join "`n")
            if ($LASTEXITCODE -eq 0 -and -not ($text -match "Unable to open device|No such file|failed to")) {
                return ,($text -split "`r?`n")
            }
        }
    }

    return $null
}

# ------------------------------
# Parse SSD health
# ------------------------------
function Get-SSDHealth {
    param ($smartOutput, $isNVMe)

    if (-not $smartOutput) { return $null }

    # NVMe: look for "Percentage Used" or an ID 05 line with a percent and convert to health %
    if ($isNVMe) {
        foreach ($line in $smartOutput) {
            if ($line -match 'Percentage\s*Used' -or $line -match 'Percent\s*Used' -or $line -match 'Percentage_Used') {
                if ($line -match '(\d+)\s*%') {
                    return [Math]::Max(0, 100 - [int]$matches[1])
                }
            }
            if ($line -match '^\s*05\b' -and $line -match '(\d+)\s*%') {
                return [Math]::Max(0, 100 - [int]$matches[1])
            }
        }
        return $null
    }

    # SATA: find Wear_Leveling / Wear_Leveling_Count and extract the VALUE (normalized) column (4th token)
    foreach ($line in $smartOutput) {
        if ($line -match 'Wear[_ ]?Level' -or $line -match 'Wear_Leveling_Count') {
            if ($line -match '^\s*\d+\s+\S+\s+\S+\s+(\d{1,3})\b') {
                return [int]$matches[1]
            }
            $parts = ($line -split '\s+') | Where-Object { $_ -ne '' }
            if ($parts.Length -ge 4 -and $parts[3] -match '^\d{1,3}$') {
                return [int]$parts[3]
            }
            $nums = $line -split '\s+' | Where-Object { $_ -match '^\d+$' }
            foreach ($n in $nums) {
                $v = [int]$n
                if ($v -ge 0 -and $v -le 100) { return $v }
            }
        }
    }

    return $null
}

# ------------------------------
# Build disk order by Windows drive letter
# ------------------------------
$diskInfoList = @()
foreach ($disk in $disks) {
    $letters = Get-DriveLettersForDisk -Disk $disk
    $primaryLetter = $null
    if ($letters.Count -gt 0) {
        # pick smallest letter (e.g. C: before D:)
        $primaryLetter = ($letters | Sort-Object)[0]
    }
    # Sort key: letter (like "C:") or "~" to push unknowns to end
    $sortKey = if ($primaryLetter) { $primaryLetter } else { "~" }
    $diskInfoList += [PSCustomObject]@{
        Disk = $disk
        Letters = $letters
        PrimaryLetter = $primaryLetter
        SortKey = $sortKey
    }
}

# Sort by SortKey ascending (C:, D:, ... then "~")
$diskInfoList = $diskInfoList | Sort-Object -Property SortKey

# ------------------------------
# Main loop: build UI panels per disk in windows-letter order
# ------------------------------
$stackPanels = @()

foreach ($info in $diskInfoList) {
    $disk = $info.Disk
    $smart = Get-SmartOutputForDisk -Disk $disk -SmartCtlPath $smartctl
    if (-not $smart) {
        # couldn't query this device; show unknown panel
        $panel = New-Object System.Windows.Controls.StackPanel
        $panel.Margin = "0,0,0,12"

        $title = New-Object System.Windows.Controls.TextBlock
        $lettersText = if ($info.PrimaryLetter) { " ($($info.PrimaryLetter))" } else { "" }
        $title.Text = "$($disk.Model)$lettersText [Unknown]"
        $title.FontWeight = "Bold"
        $title.FontSize = 14

        $statusText = New-Object System.Windows.Controls.TextBlock
        $statusText.Text = "Could not query SMART"
        $statusText.Foreground = [System.Windows.Media.Brushes]::Gray
        $statusText.FontSize = 13

        $detailText = New-Object System.Windows.Controls.TextBlock
        $detailText.Text = "smartctl could not read this device (insufficient permissions or unsupported bridge)."
        $detailText.FontSize = 11
        $detailText.Foreground = [System.Windows.Media.Brushes]::Gray

        $panel.Children.Add($title)
        $panel.Children.Add($statusText)
        $panel.Children.Add($detailText)

        $stackPanels += $panel
        continue
    }

    # SSD/HDD detection
    $rotationLineObj = $smart | Select-String "Rotation Rate" -SimpleMatch
    $rotationLine = if ($rotationLineObj) { $rotationLineObj.Line } else { $null }
    $isNVMe = ($disk.Model -match "NVMe") -or ($smart -join "`n" -match "NVMe")

    $isSSD = $true
    if ($rotationLine) {
        if ($rotationLine -match "Solid State|SSD") {
            $isSSD = $true
        } elseif ($rotationLine -match "\d+\s*rpm") {
            $isSSD = $false
        }
    } else {
        $modelLower = $disk.Model.ToLower()
        if ($modelLower -match "ssd|nvme|pci[e]?|crucial|samsung|wd sn|kingston|intel") {
            $isSSD = $true
        } else {
            $isSSD = $false
        }
    }

    # Initialize
    $status = "Good"
    $color = [System.Windows.Media.Brushes]::Green
    $detail = ""
    $healthPct = $null

    if ($isSSD) {
        $healthPct = Get-SSDHealth -smartOutput $smart -isNVMe $isNVMe

        if ($healthPct -ne $null) {
            if ($healthPct -ge 90) {
                $status = "Good"
                $color = [System.Windows.Media.Brushes]::Green
            } elseif ($healthPct -ge 70) {
                $status = "Caution"
                $color = [System.Windows.Media.Brushes]::Orange
            } else {
                $status = "Bad"
                $color = [System.Windows.Media.Brushes]::Red
            }
            $detail = "Health $healthPct%"
        } else {
            $status = "Unknown"
            $color = [System.Windows.Media.Brushes]::Gray
            $detail = "Could not parse SMART health (wear-leveling/Percentage Used not found)"
        }
    } else {
        # HDD logic
        $realloc = ($smart | Select-String "Reallocated_Sector" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        $pending = ($smart | Select-String "Current_Pending_Sector" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        $offline = ($smart | Select-String "Offline_Uncorrectable" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1

        $realloc = if ($realloc) { [int]$realloc } else { 0 }
        $pending = if ($pending) { [int]$pending } else { 0 }
        $offline = if ($offline) { [int]$offline } else { 0 }

        if (($pending -gt 0) -or ($offline -gt 0)) {
            $status = "Bad"
            $color = [System.Windows.Media.Brushes]::Red
            $detail = "Pending or unreadable sectors"
        } elseif ($realloc -gt 0) {
            $status = "Caution"
            $color = [System.Windows.Media.Brushes]::Orange
            $detail = "Reallocated sectors present ($realloc)"
        } else {
            $detail = "No critical SMART issues"
        }
    }

    # Build WPF panel
    $panel = New-Object System.Windows.Controls.StackPanel
    $panel.Margin = "0,0,0,12"

    $title = New-Object System.Windows.Controls.TextBlock
    $lettersText = if ($info.PrimaryLetter) { " ($($info.PrimaryLetter))" } else { "" }
    $driveType = if ($isSSD) { "SSD" } else { "HDD" }
    $title.Text = "$($disk.Model)$lettersText [$driveType] - $($disk.DeviceID)"
    $title.FontWeight = "Bold"
    $title.FontSize = 14

    $statusText = New-Object System.Windows.Controls.TextBlock
    if ($healthPct -ne $null) {
        $statusText.Text = "$status ($healthPct%)"
    } else {
        $statusText.Text = $status
    }
    $statusText.Foreground = $color
    $statusText.FontSize = 13

    $detailText = New-Object System.Windows.Controls.TextBlock
    $detailText.Text = $detail
    $detailText.FontSize = 11
    $detailText.Foreground = [System.Windows.Media.Brushes]::Gray

    $panel.Children.Add($title)
    $panel.Children.Add($statusText)
    $panel.Children.Add($detailText)

    $stackPanels += $panel
}

# ------------------------------
# Build WPF window
# ------------------------------
$window = New-Object System.Windows.Window
$window.Title = "Disk Health Status"
$window.SizeToContent = "WidthAndHeight"
$window.ResizeMode = "NoResize"
$window.WindowStartupLocation = "CenterScreen"

$root = New-Object System.Windows.Controls.StackPanel
$root.Margin = 15

foreach ($p in $stackPanels) {
    $root.Children.Add($p)
}

# Add OK button
$ok = New-Object System.Windows.Controls.Button
$ok.Content = "OK"
$ok.Width = 80
$ok.HorizontalAlignment = "Right"
$ok.Add_Click({ $window.Close() })
$root.Children.Add($ok)

$window.Content = $root

# Ensure window starts visible and normal
$window.WindowState = 'Normal'
$window.Topmost = $true

# Play popup sound
[System.Media.SystemSounds]::Exclamation.Play()

# ------------------------------
# Build log text
# ------------------------------
$logLines = @()
$dateStr = Get-Date -Format "ddMMyyyy"
$logFile = Join-Path $scriptDir "DiskHealth-$dateStr.log"

foreach ($info in $diskInfoList) {
    $disk = $info.Disk
    $lettersText = if ($info.PrimaryLetter) { " ($($info.PrimaryLetter))" } else { "" }
    $smart = Get-SmartOutputForDisk -Disk $disk -SmartCtlPath $smartctl

    # Determine health string
    $rotationLineObj = $smart | Select-String "Rotation Rate" -SimpleMatch
    $rotationLine = if ($rotationLineObj) { $rotationLineObj.Line } else { $null }
    $isNVMe = ($disk.Model -match "NVMe") -or ($smart -join "`n" -match "NVMe")

    $isSSD = $true
    if ($rotationLine) {
        if ($rotationLine -match "Solid State|SSD") {
            $isSSD = $true
        } elseif ($rotationLine -match "\d+\s*rpm") {
            $isSSD = $false
        }
    } else {
        $modelLower = $disk.Model.ToLower()
        if ($modelLower -match "ssd|nvme|pci[e]?|crucial|samsung|wd sn|kingston|intel") {
            $isSSD = $true
        } else {
            $isSSD = $false
        }
    }

    # Determine status and healthPct
    if ($isSSD) {
        $healthPct = Get-SSDHealth -smartOutput $smart -isNVMe $isNVMe
        if ($healthPct -ne $null) {
            if ($healthPct -ge 90) { $status = "Good" }
            elseif ($healthPct -ge 70) { $status = "Caution" }
            else { $status = "Bad" }
            $healthStr = "$status ($healthPct%)"
        } else {
            $healthStr = "Unknown"
        }
    } else {
        $realloc = ($smart | Select-String "Reallocated_Sector" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        $pending = ($smart | Select-String "Current_Pending_Sector" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1
        $offline = ($smart | Select-String "Offline_Uncorrectable" -SimpleMatch) | ForEach-Object { ($_ -split '\s+')[-1] } | Where-Object { $_ -match '^\d+$' } | Select-Object -First 1

        $realloc = if ($realloc) { [int]$realloc } else { 0 }
        $pending = if ($pending) { [int]$pending } else { 0 }
        $offline = if ($offline) { [int]$offline } else { 0 }

        if (($pending -gt 0) -or ($offline -gt 0)) { $healthStr = "Bad (Pending/Unreadable sectors)" }
        elseif ($realloc -gt 0) { $healthStr = "Caution (Reallocated sectors $realloc)" }
        else { $healthStr = "Good" }
    }

    $logLines += "$($disk.Model)$lettersText [$($disk.DeviceID)]: $healthStr"
	$logLines += ""   # adds an empty line

}

# Write log file
try {
    $logLines | Out-File -FilePath $logFile -Encoding UTF8
} catch {
    Write-Warning "Failed to write log to ${logFile}: $_"
}


# Show popup
$window.ShowDialog() | Out-Null