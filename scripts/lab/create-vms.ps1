<#
.SYNOPSIS
  Creates the two OpsDB lab VMs in VirtualBox (vm-oracle, vm-apps).

.DESCRIPTION
  Reproduces the VM layout actually used in phase 1 (2026-10-12):
    vm-oracle  Oracle Linux 8.10, 4 GB RAM, 2 vCPU, 3 disks (os 30G / data 20G / fra 16G)
    vm-apps    Ubuntu 22.04.5 Server, 5 GB RAM, 2 vCPU, 1 disk (os 40G)
  Both VMs: NIC1 = NAT (internet), NIC2 = host-only 192.168.56.0/24 (static IPs set in the OS installer).
  Graphics: VMSVGA + 64 MB VRAM. The VirtualBox default (VBoxVGA, 8 MB) froze the
  Oracle Linux graphical installer.

  The plan was 3 vCPU per VM. Both run with 2 vCPU because the third vCPU was
  repeatedly starved on this laptop (see docs/install/oracle.md, Troubleshooting).

  Run in PowerShell on the Windows host. The OS installation itself is interactive.

.PARAMETER VmDir
  Folder that holds the VMs. Default E:\VMs

.PARAMETER IsoDir
  Folder that holds the installer ISOs. Default E:\lab-iso
#>
param(
    [string]$VmDir  = "E:\VMs",
    [string]$IsoDir = "E:\lab-iso",
    [string]$HostOnlyAdapter = "VirtualBox Host-Only Ethernet Adapter"
)

$ErrorActionPreference = "Stop"
$VBM = "C:\Program Files\Oracle\VirtualBox\VBoxManage.exe"

function Invoke-VBM {
    & $VBM @args
    if ($LASTEXITCODE -ne 0) { throw "VBoxManage $($args -join ' ') failed ($LASTEXITCODE)" }
}

& $VBM setproperty machinefolder $VmDir

# Host-only network must exist: 192.168.56.1/24, DHCP disabled.
& $VBM list hostonlyifs | Select-String "Name:|IPAddress:|DHCP:"

# Keep Windows from throttling the VM processes on battery / Energy saver.
# Needs an elevated PowerShell; skipped with a warning otherwise.
$vboxDir = Split-Path $VBM
foreach ($exe in "VirtualBoxVM.exe", "VBoxHeadless.exe") {
    try   { powercfg /powerthrottling disable /path (Join-Path $vboxDir $exe) }
    catch { Write-Warning "powercfg failed for $exe - run this script as Administrator" }
}

function New-LabVm {
    param([string]$Name, [string]$OsType, [int]$MemoryMb, [int]$Cpus,
          [hashtable[]]$Disks, [string]$Iso)

    Invoke-VBM createvm --name $Name --ostype $OsType --register
    Invoke-VBM modifyvm $Name --memory $MemoryMb --cpus $Cpus --ioapic on `
        --nic1 nat --nic2 hostonly --hostonlyadapter2 $HostOnlyAdapter `
        --graphicscontroller vmsvga --vram 64
    Invoke-VBM storagectl $Name --name SATA --add sata --controller IntelAhci --portcount ($Disks.Count + 1)

    $port = 0
    foreach ($d in $Disks) {
        $path = Join-Path $VmDir "$Name\$($d.File)"
        Invoke-VBM createmedium disk --filename $path --size $d.SizeMb
        Invoke-VBM storageattach $Name --storagectl SATA --port $port --device 0 --type hdd --medium $path
        $port++
    }
    Invoke-VBM storageattach $Name --storagectl SATA --port $port --device 0 --type dvddrive --medium (Join-Path $IsoDir $Iso)

    & $VBM showvminfo $Name --machinereadable |
        Select-String "^memory|^cpus|^nic1|^nic2|^graphicscontroller|^vram|^`"SATA-\d-0`""
}

New-LabVm -Name vm-oracle -OsType Oracle_64 -MemoryMb 4096 -Cpus 2 -Iso "OracleLinux-R8-U10-x86_64-dvd.iso" -Disks @(
    @{ File = "os.vdi";   SizeMb = 30720 },   # /, /boot, swap, /u01 (Oracle software)
    @{ File = "data.vdi"; SizeMb = 20480 },   # /u02  datafiles + redo
    @{ File = "fra.vdi";  SizeMb = 16384 }    # /u03  fast recovery area (capped at 15 GB)
)

New-LabVm -Name vm-apps -OsType Ubuntu_64 -MemoryMb 5120 -Cpus 2 -Iso "ubuntu-22.04.5-live-server-amd64.iso" -Disks @(
    @{ File = "os.vdi"; SizeMb = 40960 }
)

Write-Host @"

Next:
  1. Start each VM with:  & `"$VBM`" startvm <name>
     Oracle Linux: Troubleshooting > Install ... in basic graphics mode.
  2. Static IPs on the second NIC (enp0s8): vm-oracle 192.168.56.10/24, vm-apps 192.168.56.20/24, no gateway.
  3. After install: detach the ISO (storageattach ... --medium emptydrive), then
     & `"$VBM`" startvm <name> --type headless
"@
