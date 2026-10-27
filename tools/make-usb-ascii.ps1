# make-usb-ascii.ps1 - prepare a bootable UEFI USB for the TU102 dump/unlock app.
#
# Pure ASCII on purpose: Windows PowerShell 5.1 reads a UTF-8 (no BOM) script as
# GBK, and any non-ASCII byte inside a string literal becomes a parser error.
# Keep this file ASCII-only.
#
# What it does:
#   wipe the target USB disk, create an MBR + 1 GB FAT32 active partition,
#   install the given .EFI as \EFI\Boot\BOOTX64.EFI, and pre-create the two
#   1 MiB placeholder files the dump image fills.
#
# Usage (elevated PowerShell):
#   powershell -ExecutionPolicy Bypass -File make-usb-ascii.ps1 -DriveLetter G -Image .\TU102DUMP.EFI

param(
    [Parameter(Mandatory=$true)][string]$DriveLetter,
    [Parameter(Mandatory=$true)][string]$Image
)

$ErrorActionPreference = 'Stop'
$log = Join-Path $PSScriptRoot 'make-usb-log.txt'
"=== make-usb-ascii $(Get-Date) ===" | Out-File $log -Encoding ascii
function Log($m) { Write-Host $m; $m | Out-File $log -Append -Encoding ascii }

if (-not (Test-Path $Image)) { Log "REFUSED: image not found: $Image"; exit 1 }

$p  = Get-Partition -DriveLetter $DriveLetter[0] -ErrorAction Stop
$d  = Get-Disk -Number $p.DiskNumber
if ($d.BusType -ne 'USB') { Log "REFUSED: target $($DriveLetter): bus is $($d.BusType), not USB"; exit 1 }
$osDisk = (Get-Partition -DriveLetter $env:SystemDrive[0]).DiskNumber
if ($d.Number -eq $osDisk) { Log "REFUSED: target is the OS disk"; exit 1 }

Log "Wiping USB disk $($d.Number): $($d.FriendlyName) ($([math]::Round($d.Size/1GB,2))GB)"
Clear-Disk -Number $d.Number -RemoveData -RemoveOEM -Confirm:$false
Initialize-Disk -Number $d.Number -PartitionStyle MBR
$part = New-Partition -DiskNumber $d.Number -Size 1GB -IsActive -AssignDriveLetter
Format-Volume -Partition $part -FileSystem FAT32 -NewFileSystemLabel 'TU102' | Out-Null
$u = "$($part.DriveLetter):"
Log "USB FAT32 partition ready at $u"

New-Item -ItemType Directory -Force "$u\EFI\Boot" | Out-Null
Copy-Item $Image "$u\EFI\Boot\BOOTX64.EFI" -Force

# Pre-allocate the two 1 MiB slots the dump app writes into.
$zero = New-Object byte[] (1MB)
[IO.File]::WriteAllBytes("$u\tu102p30.bin", $zero)
[IO.File]::WriteAllBytes("$u\tu102p11.bin", $zero)

$hash = (Get-FileHash "$u\EFI\Boot\BOOTX64.EFI").Hash
Log "BOOTX64.EFI sha256: $hash"
Log "DONE-OK"
Write-Host ""
Write-Host "USB ready. Remove it safely, then boot from it."
Write-Host "This window closes in 10 seconds."
Start-Sleep -Seconds 10
