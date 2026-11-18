<#
.SYNOPSIS
    Read-only inventory of a Windows workstation for the OS optimization playbook.
.DESCRIPTION
    Collects OS, hardware, memory, storage, pagefile, startup, services, security,
    power, NetBIOS and event-log data. Changes nothing.
.PARAMETER OutFile
    Optional path for a full text transcript of the report.
.EXAMPLE
    .\01-Diagnose.ps1 -OutFile C:\Temp\win-report.txt
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'SilentlyContinue'
if ($OutFile) { Start-Transcript -Path $OutFile -Force | Out-Null }

function Section([string]$Title) {
    Write-Output ''
    Write-Output ('=== ' + $Title + ' ===')
}

try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $uptime = (Get-Date) - $os.LastBootUpTime

    Section 'SYSTEM'
    [pscustomobject]@{
        Computer      = $env:COMPUTERNAME
        OS            = $os.Caption
        Version       = $os.Version
        Build         = $os.BuildNumber
        Installed     = $os.InstallDate
        LastBoot      = $os.LastBootUpTime
        UptimeHours   = [math]::Round($uptime.TotalHours, 1)
        PendingReboot = ((Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') -or
                         (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'))
    } | Format-List

    Section 'HARDWARE'
    Get-CimInstance Win32_Processor |
        Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed | Format-List
    Get-CimInstance Win32_PhysicalMemory |
        Select-Object BankLabel, @{n = 'GB'; e = { $_.Capacity / 1GB } }, Speed | Format-Table -Auto
    Get-PhysicalDisk |
        Select-Object FriendlyName, MediaType, BusType, @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB) } }, HealthStatus |
        Format-Table -Auto
    Get-StorageReliabilityCounter -PhysicalDisk (Get-PhysicalDisk) |
        Select-Object DeviceId, Temperature, Wear, ReadErrorsTotal, WriteErrorsTotal | Format-Table -Auto

    Section 'MEMORY'
    'Commit: {0:N1} / {1:N1} GB (used / limit)' -f (($os.TotalVirtualMemorySize - $os.FreeVirtualMemory) / 1MB), ($os.TotalVirtualMemorySize / 1MB)
    'Free physical: {0:N1} GB' -f ($os.FreePhysicalMemory / 1MB)
    'Processes: {0}' -f (Get-Process).Count
    Get-Process | Sort-Object WS -Descending |
        Select-Object -First 15 @{n = 'MB'; e = { [math]::Round($_.WS / 1MB) } }, ProcessName | Format-Table -Auto

    Section 'STORAGE'
    Get-Volume | Where-Object DriveLetter |
        Select-Object DriveLetter, FileSystemLabel,
            @{n = 'SizeGB'; e = { [math]::Round($_.Size / 1GB, 1) } },
            @{n = 'FreeGB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } },
            @{n = 'FreePct'; e = { [math]::Round(100 * $_.SizeRemaining / $_.Size) } } |
        Format-Table -Auto

    Section 'PAGEFILE'
    Get-CimInstance Win32_PageFileSetting | Select-Object Name, InitialSize, MaximumSize | Format-Table -Auto
    Get-CimInstance Win32_PageFileUsage | Select-Object Name, AllocatedBaseSize, PeakUsage | Format-Table -Auto
    'AutomaticManagedPagefile: ' + $cs.AutomaticManagedPagefile

    Section 'STARTUP - RUN'
    Get-CimInstance Win32_StartupCommand | Select-Object Name, Location, Command | Format-Table -Auto -Wrap

    Section 'STARTUP - STARTUPAPPROVED'
    $appr = Get-ItemProperty 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
    if ($appr) {
        $appr.PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } | ForEach-Object {
            if ($_.Value[0] -eq 2 -or $_.Value[0] -eq 6) { $state = 'enabled' } else { $state = 'disabled' }
            '{0} : {1}' -f $_.Name, $state
        }
    }

    Section 'SCHEDULED TASKS - NON MICROSOFT'
    Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskName, TaskPath, State | Sort-Object State, TaskName | Format-Table -Auto

    Section 'SERVICES'
    $svc = @(Get-CimInstance Win32_Service)
    'Total: {0} | Auto: {1} | Auto running: {2} | Auto stopped: {3}' -f `
        $svc.Count,
        (@($svc | Where-Object { $_.StartMode -eq 'Auto' })).Count,
        (@($svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -eq 'Running' })).Count,
        (@($svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.State -ne 'Running' })).Count
    $svc | Where-Object { $_.StartMode -eq 'Auto' -and $_.PathName -notmatch '(?i)\\windows\\' } |
        Select-Object Name, State, PathName | Format-Table -Auto -Wrap

    Section 'SECURITY'
    Get-MpComputerStatus |
        Select-Object AMServiceEnabled, RealTimeProtectionEnabled, AntivirusSignatureAge, AMRunningMode | Format-List
    Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct |
        Select-Object displayName | Format-Table -Auto
    Get-CimInstance -Namespace root\Microsoft\Windows\DeviceGuard -ClassName Win32_DeviceGuard |
        Select-Object VirtualizationBasedSecurityStatus, SecurityServicesRunning | Format-List
    try { 'SecureBoot: ' + (Confirm-SecureBootUEFI) } catch { 'SecureBoot: unavailable' }

    Section 'POWER AND NETBIOS'
    powercfg /getactivescheme
    'HiberbootEnabled: ' + (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power').HiberbootEnabled
    Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\NetBT\Parameters\Interfaces' | ForEach-Object {
        [pscustomobject]@{
            Interface      = $_.PSChildName
            NetbiosOptions = (Get-ItemProperty $_.PSPath).NetbiosOptions
        }
    } | Format-Table -Auto

    Section 'EVENTS - LAST 7 DAYS'
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = (Get-Date).AddDays(-7) })
    'Critical/Error: ' + $ev.Count
    $ev | Group-Object ProviderName, Id | Sort-Object Count -Descending |
        Select-Object -First 12 Count, Name | Format-Table -Auto
    'NetBIOS conflicts (4321): ' + (@(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 4321; StartTime = (Get-Date).AddDays(-7) })).Count
    'Boot drivers not loaded (7026): ' + (@(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 7026; StartTime = (Get-Date).AddDays(-7) })).Count

    Section 'TEMP CACHE'
    foreach ($p in @($env:TEMP, 'C:\Windows\Temp', (Join-Path $env:LOCALAPPDATA 'npm-cache'), (Join-Path $env:USERPROFILE '.cache'))) {
        if (Test-Path $p) {
            $sum = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue |
                    Where-Object { -not $_.PSIsContainer } |
                    Measure-Object -Property Length -Sum).Sum
            '{0,-55} {1,8:N2} GB' -f $p, ($sum / 1GB)
        }
    }
}
finally {
    if ($OutFile) { Stop-Transcript | Out-Null }
}
