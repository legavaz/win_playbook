<#
.SYNOPSIS
    Re-enables Microsoft Defender disabled by a tweaker (policy, product key, drivers).
.DESCRIPTION
    The product key HKLM\SOFTWARE\Microsoft\Windows Defender is ACL-protected: only
    SYSTEM, TrustedInstaller and WinDefend can write to it. Administrators get read
    access only, so the fix is executed by a one-off scheduled task running as SYSTEM.
    The script removes DisableAntiSpyware/DisableAntiVirus, restores boot/demand start
    types for Defender drivers, starts WinDefend and adds exclusions.
.PARAMETER ExclusionPath
    Directories excluded from real-time scanning. Keep this narrow (dev folders, caches).
.EXAMPLE
    .\03-Enable-Defender.ps1 -ExclusionPath 'C:\project','C:\Users\me\AppData\Local\npm-cache'
#>
[CmdletBinding()]
param(
    [string[]]$ExclusionPath = @()
)

$ErrorActionPreference = 'Stop'

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this script as Administrator.'
}

$work = Join-Path $env:ProgramData 'OSPlaybook'
New-Item -ItemType Directory -Path $work -Force | Out-Null
$log = Join-Path $work 'defender-enable.log'
$inner = Join-Path $work 'defender-enable.ps1'
$exclFile = Join-Path $work 'defender-exclusions.txt'
$taskName = 'OSPlaybook-EnableDefender'

Remove-Item $log -ErrorAction SilentlyContinue
$ExclusionPath | Set-Content -Path $exclFile -Encoding UTF8

$innerScript = @'
$ErrorActionPreference = 'Continue'
$log = '__LOG__'
function L($m) { "$([datetime]::Now.ToString('HH:mm:ss')) $m" | Out-File -FilePath $log -Append -Encoding utf8 }
L 'start'

Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows Defender' -Recurse -Force -ErrorAction SilentlyContinue

$p = 'HKLM:\SOFTWARE\Microsoft\Windows Defender'
foreach ($n in @('DisableAntiSpyware', 'DisableAntiVirus')) {
    try {
        Remove-ItemProperty -Path $p -Name $n -ErrorAction Stop
        L "removed $n"
    }
    catch {
        try {
            Set-ItemProperty -Path $p -Name $n -Value 0 -Type DWord -ErrorAction Stop
            L "zeroed $n"
        }
        catch {
            L "FAIL $n : $($_.Exception.Message)"
        }
    }
}

foreach ($s in @(
        @{ n = 'WdBoot'; v = 0 },
        @{ n = 'WdFilter'; v = 0 },
        @{ n = 'WdNisDrv'; v = 3 },
        @{ n = 'WdNisSvc'; v = 3 },
        @{ n = 'SecurityHealthService'; v = 2 }
    )) {
    try {
        Set-ItemProperty -Path ('HKLM:\SYSTEM\CurrentControlSet\Services\' + $s.n) -Name Start -Value $s.v -Type DWord -ErrorAction Stop
        L ('start-type ' + $s.n + '=' + $s.v)
    }
    catch {
        L ('FAIL start-type ' + $s.n + ' : ' + $_.Exception.Message)
    }
}

sc.exe start WinDefend | Out-Null
for ($i = 0; $i -lt 12; $i++) {
    Start-Sleep -Seconds 5
    if ((Get-Service WinDefend).Status -eq 'Running') { break }
}

$st = Get-MpComputerStatus -ErrorAction SilentlyContinue
L ('AMService=' + $st.AMServiceEnabled + ' RealTime=' + $st.RealTimeProtectionEnabled + ' Mode=' + $st.AMRunningMode)

$ex = @(Get-Content '__EXCL__' -ErrorAction SilentlyContinue | Where-Object { $_ -ne '' })
if ($ex.Count -gt 0) {
    try {
        Add-MpPreference -ExclusionPath $ex -ErrorAction Stop
        L ('exclusions: ' + ($ex -join '; '))
    }
    catch {
        L ('excl FAIL: ' + $_.Exception.Message)
    }
}

L 'end'
'@

$content = $innerScript.Replace('__LOG__', $log).Replace('__EXCL__', $exclFile)
$utf8Bom = New-Object System.Text.UTF8Encoding($true)
[IO.File]::WriteAllText($inner, $content, $utf8Bom)

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ('-NoProfile -ExecutionPolicy Bypass -File "{0}"' -f $inner)
$principalTask = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principalTask -Settings $settings -Force | Out-Null

Start-ScheduledTask -TaskName $taskName
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Seconds 5
    if (Select-String -Path $log -Pattern ' end$' -Quiet) { break }
}
Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue

Write-Output '--- log ---'
Get-Content $log -ErrorAction SilentlyContinue

if (-not (Select-String -Path $log -Pattern 'AMService=True' -Quiet)) {
    Write-Warning 'Defender did not report AMService=True. A reboot may be required; then run 05-Test-Configuration.ps1.'
}
