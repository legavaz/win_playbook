<#
.SYNOPSIS
    Configures a fixed Windows pagefile or reverts to system-managed.
.DESCRIPTION
    Sets AutomaticManagedPagefile = False, writes the PagingFiles registry value and
    mirrors it through WMI. A reboot is required to apply.
.PARAMETER InitialMB
    Initial pagefile size in MB. Default 4096.
.PARAMETER MaximumMB
    Maximum pagefile size in MB. Default 12288.
.PARAMETER Revert
    Restores system-managed pagefile.
.EXAMPLE
    .\02-Set-Pagefile.ps1 -InitialMB 4096 -MaximumMB 12288
.EXAMPLE
    .\02-Set-Pagefile.ps1 -Revert
#>
[CmdletBinding()]
param(
    [int]$InitialMB = 4096,
    [int]$MaximumMB = 12288,
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}
if ($MaximumMB -lt $InitialMB) { throw 'MaximumMB must be greater than or equal to InitialMB.' }

$mm = 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
$backupDir = Join-Path $env:ProgramData ('OSPlaybook\backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
reg export 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management' (Join-Path $backupDir 'memory-management.reg') /y | Out-Null

$cs = Get-CimInstance Win32_ComputerSystem

if ($Revert) {
    Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $true }
    Set-ItemProperty -Path $mm -Name PagingFiles -Value ([string[]]@()) -Type MultiString
    Write-Output 'Reverted to system-managed pagefile. Reboot required.'
    Write-Output ('Backup: ' + $backupDir)
    return
}

$value = '{0}\pagefile.sys {1} {2}' -f $env:SystemDrive, $InitialMB, $MaximumMB
Set-ItemProperty -Path $mm -Name PagingFiles -Value $value -Type MultiString
Set-CimInstance -InputObject $cs -Property @{ AutomaticManagedPagefile = $false }

$pf = Get-CimInstance Win32_PageFileSetting
if ($pf) {
    Set-CimInstance -InputObject $pf -Property @{ InitialSize = $InitialMB; MaximumSize = $MaximumMB }
}

Write-Output ('Pagefile configured: ' + $value)
Write-Output ('Registry value now: ' + ((Get-ItemProperty $mm).PagingFiles -join '; '))
Write-Output ('Backup: ' + $backupDir)
Write-Output 'Reboot required to apply.'
