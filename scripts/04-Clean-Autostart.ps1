<#
.SYNOPSIS
    Disables autostart entries and scheduled tasks, with backups.
.DESCRIPTION
    Removes HKCU Run values and marks them disabled in StartupApproved\Run, so the
    application cannot silently re-enable itself by re-adding the Run value.
    Scheduled tasks are disabled (not deleted) and their XML is exported first.
.PARAMETER RunValue
    Names of values under HKCU\...\CurrentVersion\Run.
.PARAMETER TaskName
    Names of scheduled tasks to disable.
.PARAMETER Revert
    Re-enables the listed tasks and removes the StartupApproved "disabled" marks.
.EXAMPLE
    .\04-Clean-Autostart.ps1 -RunValue '<ValueName>' -TaskName '<TaskName>'
.EXAMPLE
    .\04-Clean-Autostart.ps1 -Revert -TaskName 'ZoomUpdateTask'
#>
[CmdletBinding()]
param(
    [string[]]$RunValue = @(),
    [string[]]$TaskName = @(),
    [switch]$Revert
)

$ErrorActionPreference = 'Stop'

$runKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'
$apprKey = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run'
$backupDir = Join-Path $env:ProgramData ('OSPlaybook\backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

reg export 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' (Join-Path $backupDir 'hkcu-run.reg') /y 2>$null | Out-Null
reg export 'HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' (Join-Path $backupDir 'startup-approved.reg') /y 2>$null | Out-Null

if (-not (Test-Path $apprKey)) { New-Item -Path $apprKey -Force | Out-Null }

$disabledMark = [byte[]](3, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)

if (-not $Revert) {
    foreach ($name in $RunValue) {
        $current = (Get-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue).$name
        if (-not $current) {
            Write-Output ('SKIP (not in Run): ' + $name)
            continue
        }
        Remove-ItemProperty -Path $runKey -Name $name -ErrorAction SilentlyContinue
        New-ItemProperty -Path $apprKey -Name $name -Value $disabledMark -PropertyType Binary -Force | Out-Null
        Write-Output ('DISABLED startup: ' + $name + '  ->  ' + $current)
    }
}
else {
    foreach ($name in $RunValue) {
        Remove-ItemProperty -Path $apprKey -Name $name -ErrorAction SilentlyContinue
        Write-Output ('StartupApproved mark removed: ' + $name + ' (restore its Run value from hkcu-run.reg)')
    }
}

foreach ($name in $TaskName) {
    $tasks = @(Get-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue)
    if ($tasks.Count -eq 0) {
        Write-Output ('SKIP (task not found): ' + $name)
        continue
    }
    foreach ($t in $tasks) {
        $safe = ($t.TaskPath + $t.TaskName) -replace '[\\/:*?"<>|]', '_'
        try {
            Export-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath |
                Set-Content -Path (Join-Path $backupDir ('task_' + $safe + '.xml')) -Encoding UTF8
        }
        catch { }

        $actions = ($t.Actions | ForEach-Object { $_.Execute }) -join '; '
        if ($Revert) {
            Enable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
            Write-Output ('ENABLED task: ' + $t.TaskPath + $t.TaskName)
        }
        else {
            Disable-ScheduledTask -TaskName $t.TaskName -TaskPath $t.TaskPath -ErrorAction SilentlyContinue | Out-Null
            Write-Output ('DISABLED task: ' + $t.TaskPath + $t.TaskName + '  [' + $actions + ']')
        }
    }
}

Write-Output ('Backup: ' + $backupDir)
