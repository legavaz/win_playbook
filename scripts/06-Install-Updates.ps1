<#
.SYNOPSIS
    Searches, downloads and installs pending Windows software updates.
.DESCRIPTION
    Uses the Windows Update COM API. Writes a progress log. Does not reboot unless
    -Reboot is supplied AND the installer reports a reboot requirement.
.PARAMETER LogFile
    Log path. Default C:\ProgramData\OSPlaybook\wu-install.log.
.PARAMETER Reboot
    Reboot automatically after a successful install when Windows asks for it.
.EXAMPLE
    .\06-Install-Updates.ps1
.EXAMPLE
    .\06-Install-Updates.ps1 -Reboot
#>
[CmdletBinding()]
param(
    [string]$LogFile = (Join-Path $env:ProgramData 'OSPlaybook\wu-install.log'),
    [switch]$Reboot
)

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $LogFile
New-Item -ItemType Directory -Path $dir -Force | Out-Null

function L($m) {
    "$([datetime]::Now.ToString('HH:mm:ss')) $m" | Out-File -FilePath $LogFile -Append -Encoding utf8
}

L 'start'
$rebootRequired = $false

try {
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $result = $searcher.Search("IsInstalled=0 and Type='Software' and IsHidden=0")
    L ('found ' + $result.Updates.Count)

    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $result.Updates) {
        L (' - ' + $u.Title)
        if (-not $u.EulaAccepted) {
            try { $u.AcceptEula() } catch { }
        }
        $coll.Add($u) | Out-Null
    }

    if ($coll.Count -gt 0) {
        $downloader = $session.CreateUpdateDownloader()
        $downloader.Updates = $coll
        $dr = $downloader.Download()
        L ('download result: ' + $dr.ResultCode)

        $installer = $session.CreateUpdateInstaller()
        $installer.Updates = $coll
        $ir = $installer.Install()
        $rebootRequired = [bool]$ir.RebootRequired
        L ('install result: ' + $ir.ResultCode + ' rebootRequired=' + $ir.RebootRequired)

        for ($n = 0; $n -lt $coll.Count; $n++) {
            L ('  [' + $n + '] code=' + $ir.GetUpdateResult($n).ResultCode + ' ' + $coll.Item($n).Title)
        }
    }
}
catch {
    L ('ERROR: ' + $_.Exception.Message)
}

L 'end'
Get-Content $LogFile -ErrorAction SilentlyContinue

if ($Reboot -and $rebootRequired) {
    shutdown.exe /r /t 60 /c "Windows Update: reboot to finish installation"
}
elseif ($rebootRequired) {
    Write-Output 'Reboot required. Run again with -Reboot or restart manually.'
}
