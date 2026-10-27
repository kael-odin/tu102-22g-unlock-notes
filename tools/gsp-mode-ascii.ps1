# gsp-mode-ascii.ps1 - toggle EnableGpuFirmware on the TU102 (10DE:1E07)
# display driver instance.
#
# Why: after a pre-OS unlock the card is in a state the stock WDDM path does not
# expect. With EnableGpuFirmware=1 the driver loads GSP-RM and accepts it; with
# the value absent you get Code 43 on that boot (and the next normal boot is
# fine again, because the register state is gone).
#
# Pure ASCII on purpose (PowerShell 5.1 reads UTF-8-without-BOM as GBK).
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File gsp-mode-ascii.ps1 on
#   powershell -ExecutionPolicy Bypass -File gsp-mode-ascii.ps1 off
#   powershell -ExecutionPolicy Bypass -File gsp-mode-ascii.ps1 status

param([string]$Mode = 'status')

if ($Mode -notin @('on','off','status')) { Write-Host "usage: gsp-mode-ascii.ps1 [on|off|status]"; exit 2 }

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'gsp-mode-log.txt'
"=== gsp-mode $Mode $(Get-Date) ===" | Out-File $log -Encoding ascii
function Log($m) { Write-Host $m; $m | Out-File $log -Append -Encoding ascii }

$class = 'HKLM:\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
$hits = 0
Get-ChildItem $class -ErrorAction SilentlyContinue | ForEach-Object {
    $props = Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue
    $mid = $props.MatchingDeviceId
    if ($mid -and $mid -like '*VEN_10DE&DEV_1E07*') {
        $hits++
        $before = $props.EnableGpuFirmware
        if ($Mode -eq 'on') {
            Set-ItemProperty -Path $_.PSPath -Name EnableGpuFirmware -Value 1 -Type DWord
        } elseif ($Mode -eq 'off') {
            Remove-ItemProperty -Path $_.PSPath -Name EnableGpuFirmware -ErrorAction SilentlyContinue
        }
        $now = (Get-ItemProperty $_.PSPath -ErrorAction SilentlyContinue).EnableGpuFirmware
        Log "instance $($_.PSChildName) desc=$($props.DriverDesc) EnableGpuFirmware=$before -> $now"
    }
}
if ($hits -eq 0) { Log "NO 1E07 INSTANCE FOUND (is the card present and driver-bound?)"; exit 1 }
Log "DONE-OK"
Write-Host ""
Write-Host "Reboot for 'off' to fully take effect. Window closes in 8 seconds."
Start-Sleep -Seconds 8
