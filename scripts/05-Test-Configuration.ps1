<#
.SYNOPSIS
    Acceptance checks for the OS optimization playbook.
.DESCRIPTION
    Read-only. Produces a PASS/WARN/FAIL table. Exit code 1 when any check fails.
.PARAMETER MinPagefileMB
    Minimum allocated pagefile size in MB. Default 4096.
.PARAMETER RequireDefender
    Treat a disabled Defender as FAIL.
.PARAMETER CheckUpdates
    Also query Windows Update for pending software updates (slow, needs network).
.EXAMPLE
    .\05-Test-Configuration.ps1 -MinPagefileMB 4096 -RequireDefender
#>
[CmdletBinding()]
param(
    [int]$MinPagefileMB = 4096,
    [switch]$RequireDefender,
    [switch]$CheckUpdates
)

$ErrorActionPreference = 'SilentlyContinue'
$results = New-Object System.Collections.Generic.List[object]

function Add-Check([string]$Name, [string]$State, [string]$Detail) {
    $results.Add([pscustomobject]@{ Check = $Name; State = $State; Detail = $Detail })
}

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

# --- reboot ---------------------------------------------------------------
$pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
           (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired')
if ($pending) { Add-Check 'Pending reboot' 'WARN' 'Reboot to apply staged changes' }
else { Add-Check 'Pending reboot' 'PASS' 'none' }

# --- pagefile -------------------------------------------------------------
$pf = Get-CimInstance Win32_PageFileUsage
$allocated = 0
if ($pf) { $allocated = ($pf | Measure-Object -Property AllocatedBaseSize -Maximum).Maximum }
if ($allocated -ge $MinPagefileMB) { Add-Check 'Pagefile allocated' 'PASS' ($allocated.ToString() + ' MB') }
elseif ($allocated -gt 0) { Add-Check 'Pagefile allocated' 'FAIL' ($allocated.ToString() + ' MB < ' + $MinPagefileMB + ' MB') }
else { Add-Check 'Pagefile allocated' 'WARN' 'not reported yet (reboot?)' }

$limitGB = [math]::Round($os.TotalVirtualMemorySize / 1MB, 1)
$ramGB = [math]::Round($cs.TotalPhysicalMemory / 1GB, 1)
if (($limitGB - $ramGB) -ge 3) { Add-Check 'Commit limit' 'PASS' ($limitGB.ToString() + ' GB (RAM ' + $ramGB + ' GB)') }
else { Add-Check 'Commit limit' 'FAIL' ($limitGB.ToString() + ' GB, only ' + [math]::Round($limitGB - $ramGB, 1) + ' GB above RAM') }

# --- defender -------------------------------------------------------------
$mp = Get-MpComputerStatus
if ($mp) {
    if ($mp.AMServiceEnabled -and $mp.RealTimeProtectionEnabled) {
        Add-Check 'Defender service' 'PASS' ([string]$mp.AMRunningMode)
    }
    elseif ($RequireDefender) {
        Add-Check 'Defender service' 'FAIL' ('AMService=' + $mp.AMServiceEnabled + ' RealTime=' + $mp.RealTimeProtectionEnabled)
    }
    else {
        Add-Check 'Defender service' 'WARN' ('AMService=' + $mp.AMServiceEnabled + ' RealTime=' + $mp.RealTimeProtectionEnabled)
    }
    $excl = @((Get-MpPreference).ExclusionPath | Where-Object { $_ })
    if ($excl.Count -gt 0) { Add-Check 'Defender exclusions' 'PASS' ($excl.Count.ToString() + ' paths') }
    else { Add-Check 'Defender exclusions' 'WARN' 'none configured' }
}
else {
    Add-Check 'Defender service' 'FAIL' 'Get-MpComputerStatus unavailable'
}

# --- disk -----------------------------------------------------------------
$sys = Get-Volume -DriveLetter $env:SystemDrive.TrimEnd(':')
if ($sys) {
    $freePct = [math]::Round(100 * $sys.SizeRemaining / $sys.Size)
    if ($freePct -ge 15) { Add-Check 'System disk free' 'PASS' ($freePct.ToString() + '%') }
    elseif ($freePct -ge 8) { Add-Check 'System disk free' 'WARN' ($freePct.ToString() + '%') }
    else { Add-Check 'System disk free' 'FAIL' ($freePct.ToString() + '%') }
}
$disk = Get-PhysicalDisk | Select-Object -First 1
if ($disk) {
    if ($disk.HealthStatus -eq 'Healthy') { Add-Check 'Disk health' 'PASS' ([string]$disk.HealthStatus) }
    else { Add-Check 'Disk health' 'FAIL' ([string]$disk.HealthStatus) }
}

# --- autostart ------------------------------------------------------------
$run = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$runProps = @($run.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' })
if ($runProps.Count -le 5) { Add-Check 'HKCU Run entries' 'PASS' ($runProps.Count.ToString() + ' entries') }
else { Add-Check 'HKCU Run entries' 'WARN' ($runProps.Count.ToString() + ' entries') }

$tasks = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' })
$tasksEnabled = @($tasks | Where-Object { $_.State -ne 'Disabled' })
if ($tasksEnabled.Count -le 5) { Add-Check 'Non-Microsoft tasks' 'PASS' ($tasksEnabled.Count.ToString() + ' enabled of ' + $tasks.Count) }
else { Add-Check 'Non-Microsoft tasks' 'WARN' ($tasksEnabled.Count.ToString() + ' enabled of ' + $tasks.Count) }

# --- network --------------------------------------------------------------
$conflicts = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4321; StartTime = (Get-Date).AddDays(-1) })
if ($conflicts.Count -eq 0) { Add-Check 'NetBIOS conflicts (24h)' 'PASS' '0' }
else { Add-Check 'NetBIOS conflicts (24h)' 'WARN' ($conflicts.Count.ToString() + ' events') }

# --- updates --------------------------------------------------------------
if ($CheckUpdates) {
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $found = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
        if ($found.Updates.Count -eq 0) { Add-Check 'Pending updates' 'PASS' '0' }
        else { Add-Check 'Pending updates' 'WARN' ($found.Updates.Count.ToString() + ' pending') }
    }
    catch {
        Add-Check 'Pending updates' 'WARN' ('search failed: ' + $_.Exception.Message)
    }
}

$results | Format-Table -Auto -Wrap

$failed = @($results | Where-Object { $_.State -eq 'FAIL' })
$warned = @($results | Where-Object { $_.State -eq 'WARN' })
Write-Output ''
Write-Output ('PASS: {0}  WARN: {1}  FAIL: {2}' -f ($results.Count - $failed.Count - $warned.Count), $warned.Count, $failed.Count)

if ($failed.Count -gt 0) { exit 1 }
