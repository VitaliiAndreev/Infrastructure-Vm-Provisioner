<#
.SYNOPSIS
    Provision one or more Hyper-V Ubuntu VMs from a JSON config stored in the
    local SecretStore vault.

.DESCRIPTION
    Reads the VmProvisionerConfig secret, validates each VM definition, performs
    idempotency and safety checks, then provisions each VM that passes all checks.

    Run setup-secrets.ps1 once first to populate the vault before running
    this script.

.NOTES
    REQUIREMENTS
    - Windows 11 with Hyper-V enabled.
    - Run as Administrator (Hyper-V cmdlets require elevation).
    - Microsoft.PowerShell.SecretManagement + Microsoft.PowerShell.SecretStore
      installed by setup-secrets.ps1.
    - PowerShell 5.1 (ships with Windows 11) or later. PS 7 is recommended
      but not required.

    IDEMPOTENCY
    - If a Hyper-V VM with the same vmName already exists, that entry is
      skipped rather than re-created.
    - If the target ipAddress responds to a ping, that entry is aborted to
      avoid a static-IP conflict with an existing machine.

    SECURITY
    - No secrets are passed as command-line arguments or written to disk.
      All sensitive values are read at runtime from the encrypted vault.
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

. "$PSScriptRoot\common.ps1"
. "$PSScriptRoot\iso.ps1"

# ---------------------------------------------------------------------------
# 1. Ensure SecretManagement modules are loaded
#    Import only - provisioning should have no side effects on the module
#    environment. Installing modules is setup-secrets.ps1's responsibility.
# ---------------------------------------------------------------------------

foreach ($mod in @(
    'Microsoft.PowerShell.SecretManagement',
    'Microsoft.PowerShell.SecretStore'
)) {
    if (-not (Get-Module -ListAvailable -Name $mod)) {
        throw "Module '$mod' is not installed. Run setup-secrets.ps1 first."
    }
    Import-Module $mod -ErrorAction Stop
}

# ---------------------------------------------------------------------------
# 2. Read VmProvisionerConfig from the local vault
# ---------------------------------------------------------------------------

$vaultName  = 'VmProvisioner'
$secretName = 'VmProvisionerConfig'

Write-Host "Reading '$secretName' from vault '$vaultName' ..." -ForegroundColor Cyan

$vault = Get-SecretVault -Name $vaultName -ErrorAction SilentlyContinue
if ($null -eq $vault) {
    throw "Vault '$vaultName' not found. Run setup-secrets.ps1 first."
}

$configJson = Get-Secret -Vault $vaultName -Name $secretName `
    -AsPlainText -ErrorAction Stop

# ---------------------------------------------------------------------------
# 3. Parse and validate JSON
#    Done here (not relying solely on setup-secrets.ps1) because the vault
#    could hold stale or manually-edited data. Failing fast is safer than
#    discovering a missing field mid-provisioning.
# ---------------------------------------------------------------------------

$vmDefs = @(ConvertFrom-VmConfigJson -Json $configJson)
Write-Host "✓ Config validated - $($vmDefs.Count) VM definition(s) found." `
    -ForegroundColor Green

# ---------------------------------------------------------------------------
# 4. Idempotency and safety checks
#
#    For each VM definition two checks run in order:
#
#    a) VM existence  - if a VM with vmName already exists in Hyper-V,
#       skip that entry. Re-creating an existing VM risks data loss.
#
#    b) IP conflict   - if ipAddress responds to a ping, abort that entry.
#       Assigning a static IP already in use will cause network conflicts
#       that are difficult to diagnose inside the VM.
#
#    VMs that pass both checks are collected in $vmsToProvision for the
#    subsequent provisioning steps (Steps 4-6).
# ---------------------------------------------------------------------------

$vmsToProvision = [System.Collections.Generic.List[object]]::new()

foreach ($vm in $vmDefs) {
    Write-Host ""
    Write-Host "--- Checking: $($vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Check a) VM existence
    # ------------------------------------------------------------------
    # Get-VM throws on a missing name in PS 5.1 without -ErrorAction, so
    # SilentlyContinue is required to get a $null return instead.
    $existing = Get-VM -Name $vm.vmName -ErrorAction SilentlyContinue
    if ($null -ne $existing) {
        Write-Warning "VM '$($vm.vmName)' already exists in Hyper-V - skipping."
        continue
    }

    # ------------------------------------------------------------------
    # Check b) IP conflict
    # ------------------------------------------------------------------
    # [System.Net.NetworkInformation.Ping] is used instead of
    # Test-Connection because Test-Connection's -TimeoutSeconds parameter
    # was only added in PS 7. The .NET API works identically on PS 5.1 and
    # PS 7. A 1000 ms timeout avoids a long wait per entry when the address
    # is offline (the expected state for a VM that doesn't exist yet).
    $ping       = [System.Net.NetworkInformation.Ping]::new()
    $pingResult = $ping.Send($vm.ipAddress, 1000)
    $ping.Dispose()

    if ($pingResult.Status -eq
            [System.Net.NetworkInformation.IPStatus]::Success) {
        Write-Warning (
            "IP $($vm.ipAddress) is already in use on the network - " +
            "skipping '$($vm.vmName)' to avoid a static-IP conflict."
        )
        continue
    }

    Write-Host "✓ '$($vm.vmName)' passed all checks - queued for provisioning." `
        -ForegroundColor Green
    $vmsToProvision.Add($vm)
}

Write-Host ""

if ($vmsToProvision.Count -eq 0) {
    Write-Host "No VMs to provision - all entries were skipped." `
        -ForegroundColor Yellow
    exit 0
}

Write-Host "$($vmsToProvision.Count) VM(s) queued for provisioning." `
    -ForegroundColor Cyan

# ---------------------------------------------------------------------------
# 5. Disk image acquisition
#
#    For each VM queued for provisioning:
#
#    a) Base image cache - the Ubuntu cloud image (.vhd.zip) is downloaded
#       once per Ubuntu version into vhdPath. The extracted .vhd is
#       immediately converted to .vhdx because:
#         - Hyper-V Gen 2 VMs require .vhdx for checkpoint support.
#         - .vhdx supports dynamic sizing up to 64 TB vs 2040 GB for .vhd.
#       The zip and intermediate .vhd are deleted after conversion;
#       only the .vhdx base image is kept as the reusable cache artifact.
#
#    b) Per-VM disk - a flat copy of the base .vhdx is made for each VM so
#       every VM has its own independent disk. A differencing disk would be
#       lighter (stores only the delta), but ties all VMs to the base file;
#       a corrupted or deleted base would render every differencing VM
#       unbootable. The flat copy is resized to vm.diskGB after creation.
#
#    The per-VM .vhdx path is stored as vm._vhdxPath for use in Steps 5-6.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    Write-Host ""
    Write-Host "--- Disk acquisition: $($vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Ensure the vhdPath directory exists before writing any files to it.
    # ------------------------------------------------------------------
    if (-not (Test-Path -Path $vm.vhdPath -PathType Container)) {
        New-Item -ItemType Directory -Path $vm.vhdPath -Force | Out-Null
        Write-Host "  Created directory: $($vm.vhdPath)"
    }

    # ------------------------------------------------------------------
    # Base image cache
    # Naming convention: ubuntu-{version}-server-cloudimg-amd64.vhdx
    # One cached .vhdx per (vhdPath, ubuntuVersion) pair.
    # ------------------------------------------------------------------
    $baseImageName = "ubuntu-$($vm.ubuntuVersion)-server-cloudimg-amd64.vhdx"
    $baseImagePath = Join-Path $vm.vhdPath $baseImageName

    if (Test-Path $baseImagePath) {
        Write-Host "  Base image already cached: $baseImagePath" `
            -ForegroundColor Green
    }
    else {
        # URL pattern: https://cloud-images.ubuntu.com/releases/{version}/release/
        #              ubuntu-{version}-server-cloudimg-amd64-azure.vhd.tar.gz
        #
        # Ubuntu 22.04+ no longer ships a .vhd.zip. The '-azure' VHD is the
        # only pre-built .vhd format on the CDN. Despite the name it is
        # a standard VHD and is fully compatible with Hyper-V Gen 2 — both
        # Azure and Hyper-V use UEFI + the same VHD spec.
        $downloadUrl = (
            "https://cloud-images.ubuntu.com/releases/$($vm.ubuntuVersion)" +
            "/release/ubuntu-$($vm.ubuntuVersion)-server-cloudimg-amd64-azure.vhd.tar.gz"
        )
        $archivePath = Join-Path $vm.vhdPath `
                           "ubuntu-$($vm.ubuntuVersion)-server-cloudimg-amd64-azure.vhd.tar.gz"
        $extractDir  = Join-Path $vm.vhdPath "_extract_$($vm.ubuntuVersion)"

        Write-Host "  Downloading base image ..."
        Write-Host "    From: $downloadUrl"
        Write-Host "    To  : $archivePath"

        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
        }
        catch {
            throw (
                "Failed to download Ubuntu $($vm.ubuntuVersion) image " +
                "from '$downloadUrl': $_"
            )
        }

        # tar.exe ships with Windows 10 1803+ (C:\Windows\System32\tar.exe)
        # and handles .tar.gz natively — no third-party tool required.
        Write-Host "  Extracting archive ..."
        New-Item -ItemType Directory -Path $extractDir -Force | Out-Null
        tar -xzf $archivePath -C $extractDir
        if ($LASTEXITCODE -ne 0) {
            throw "tar extraction failed for '$archivePath' (exit code $LASTEXITCODE)."
        }

        # Locate the .vhd inside the extracted directory. The archive should
        # contain exactly one .vhd file; a count check guards against an
        # unexpected archive structure breaking a silent assumption.
        $vhdFiles = @(Get-ChildItem -Path $extractDir -Filter '*.vhd' -Recurse)
        if ($vhdFiles.Count -eq 0) {
            throw (
                "No .vhd file found inside '$archivePath'. " +
                "The archive layout may have changed on the Ubuntu CDN."
            )
        }
        if ($vhdFiles.Count -gt 1) {
            Write-Warning (
                "Multiple .vhd files found inside archive; " +
                "using first: $($vhdFiles[0].Name)"
            )
        }

        # The VHD extracted from the tar is sparse on NTFS. Convert-VHD
        # requires a fully allocated (non-sparse) file and fails with
        # 0xC03A001A otherwise. Copying the file before converting
        # materialises all sparse extents — Copy-Item does not carry over
        # the NTFS sparse attribute to the destination.
        Write-Host "  Materialising sparse extents ..."
        # Keep the .vhd extension — Convert-VHD rejects files that don't
        # end in .vhd or .vhdx regardless of content.
        $denseVhdPath = Join-Path $extractDir 'base-dense.vhd'
        Copy-Item -Path $vhdFiles[0].FullName -Destination $denseVhdPath

        # Convert-VHD is part of the Hyper-V PowerShell module (available
        # whenever Hyper-V is enabled). Dynamic allocation keeps the on-disk
        # footprint small until blocks are actually written by the VM.
        Write-Host "  Converting .vhd to .vhdx (Dynamic) ..."
        Convert-VHD -Path $denseVhdPath `
                    -DestinationPath $baseImagePath `
                    -VHDType Dynamic `
                    -ErrorAction Stop

        # Remove the archive and extraction directory - the converted .vhdx
        # is the only artifact needed going forward.
        Remove-Item -Path $archivePath -Force
        Remove-Item -Path $extractDir  -Recurse -Force

        Write-Host "  ✓ Base image cached: $baseImagePath" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Patch cloud-init datasource config in the base VHDX.
    #
    # The Ubuntu Azure cloud image ships with a cloud-init config that
    # restricts the datasource to Azure only:
    #   datasource_list: [ Azure ]
    # (set in /etc/cloud/cloud.cfg.d/90_dpkg.cfg inside the image)
    #
    # On a local Hyper-V host there is no Azure IMDS at 169.254.169.254,
    # so cloud-init cannot find the Azure datasource and falls back to
    # 'None'. The seed ISO (our NoCloud datasource) is never consulted,
    # which means the VM gets no static IP, no configured user, and SSH
    # is never enabled.
    #
    # The fix writes a higher-priority override file, 99-nocloud.cfg,
    # into /etc/cloud/cloud.cfg.d/ inside the base VHDX. cloud-init
    # reads .cfg files in lexicographic order, so 99-nocloud.cfg takes
    # precedence over 90_dpkg.cfg. The override adds NoCloud so
    # cloud-init reads the seed ISO on first boot.
    #
    # Implementation:
    #   1. Mount the base VHDX as a disk via Mount-VHD (no drive letter).
    #   2. Use WSL2's wsl --mount to expose the root ext4 partition inside
    #      the WSL2 kernel (wsl --mount was added in Windows 11 21H2).
    #   3. Write the override file as root inside WSL2.
    #   4. Unmount and dismount in a finally block.
    #
    # A sentinel file alongside the VHDX tracks that patching has been
    # done, so subsequent provision runs skip this step.
    # ------------------------------------------------------------------
    $patchedSentinel = $baseImagePath -replace '\.vhdx$', '.nocloud-patched'

    if (-not (Test-Path $patchedSentinel)) {
        Write-Host "  Patching datasource config in base image ..."

        # WSL2 is required for wsl --mount (kernel) and wsl -u root (distro).
        # If either is missing, install now and exit — the script must be
        # re-run after WSL2 is fully initialised (which may require a reboot).
        #
        # wsl --install on Windows 11 is idempotent: it enables the
        # 'Windows Subsystem for Linux' and 'Virtual Machine Platform'
        # features if absent, and installs Ubuntu as the default distro.
        # Running as Administrator (already required by this script) is
        # sufficient — no separate elevated prompt is needed.
        $wslExe    = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
        $wslReady  = $false
        if ($null -ne $wslExe) {
            # A distro must exist; wsl -u root -e sh requires one.
            $distroList = wsl --list --quiet 2>&1
            $wslReady   = ($LASTEXITCODE -eq 0) -and ("$distroList" -match '\S')
        }

        if (-not $wslReady) {
            Write-Host "  WSL2 is not ready - installing now ..." -ForegroundColor Cyan
            wsl --install
            Write-Host ""
            Write-Host (
                "  WSL2 has been installed. A reboot may be required " +
                "to complete setup. Please reboot and re-run provision.ps1."
            ) -ForegroundColor Yellow
            exit 0
        }

        # Attach the base VHDX as a raw disk (no drive letter — Windows
        # cannot read the ext4 partition, so assigning one would only
        # cause a 'Format disk?' prompt).
        $patchVhd = Mount-VHD -Path $baseImagePath -NoDriveLetter -PassThru
        $patchDiskNr = $patchVhd.DiskNumber
        $physDrive   = "\\.\PhysicalDrive$patchDiskNr"

        try {
            # Approach: wsl --mount --bare attaches the raw disk to the WSL2
            # kernel without mounting any partitions. The kernel then exposes
            # all partitions as /dev/sdXN block devices inside WSL, which we
            # can mount and inspect from a shell script. This avoids the
            # unreliable wsl --mount --partition N + --name path, where N's
            # meaning varies across WSL builds and --name may not create the
            # mount at the expected path.

            # Snapshot the current block devices so we can identify the new
            # one after --bare attachment.
            $devsBefore = @(
                wsl -u root -e sh -c "lsblk -d -o NAME --noheadings 2>/dev/null" 2>&1 |
                Where-Object { $_ -match '^\S+$' }
            )

            wsl --unmount $physDrive 2>&1 | Out-Null
            $bareOut = wsl --mount $physDrive --bare 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw (
                    "wsl --mount --bare failed (exit $LASTEXITCODE): $bareOut. " +
                    "Ensure WSL2 (not WSL1) is installed and this script is " +
                    "running as Administrator."
                )
            }

            # Identify the newly attached disk.
            $devsAfter = @(
                wsl -u root -e sh -c "lsblk -d -o NAME --noheadings 2>/dev/null" 2>&1 |
                Where-Object { $_ -match '^\S+$' }
            )
            $newDevs = @($devsAfter | Where-Object { $devsBefore -notcontains $_ })
            if ($newDevs.Count -ne 1) {
                throw (
                    "Expected exactly 1 new block device after --bare mount, " +
                    "found $($newDevs.Count): $($newDevs -join ', '). " +
                    "lsblk before: $($devsBefore -join ',')  " +
                    "lsblk after:  $($devsAfter  -join ',')"
                )
            }
            $diskDev = "/dev/$($newDevs[0].Trim())"
            Write-Host "  Attached as WSL block device: $diskDev"

            # Shell script: iterate partition devices (sdX1, sdX2, ...), try
            # mounting each as ext4, confirm root by checking /etc/os-release,
            # then write 99-nocloud.cfg and sync before unmounting.
            # sync ensures kernel buffers are flushed to the backing VHDX
            # before we detach, which prevents a silent data-loss scenario
            # where the write succeeds in kernel memory but never reaches disk.
            #
            # The script is written to a Windows temp file and executed by
            # path rather than passed via -c. Passing multi-line/multi-word
            # scripts through wsl.exe argument quoting is unreliable; file
            # execution bypasses that entirely.
            $patchScriptLines = @(
                "M=/tmp/vmpatch"
                'mkdir -p "$M"'
                "for P in ${diskDev}[0-9]*; do"
                '  [ -b "$P" ] || continue'
                '  if mount -t ext4 "$P" "$M" 2>/dev/null; then'
                '    if [ -f "$M/etc/os-release" ]; then'
                '      CFG="$M/etc/cloud/cloud.cfg.d"'
                '      mkdir -p "$CFG"'
                '      printf "datasource_list: [ NoCloud, None ]\n" > "$CFG/99-nocloud.cfg"'
                '      echo "OK:$P:$(ls $CFG)"'
                '      sync'
                '      umount "$M"'
                '      rmdir "$M"'
                '      exit 0'
                '    fi'
                '    umount "$M" 2>/dev/null'
                '  fi'
                'done'
                "echo FAIL:no_root_on_${diskDev}"
                "lsblk ${diskDev} 2>&1"
                'rmdir "$M" 2>/dev/null'
                'exit 1'
            )
            # Encode the script as base64 so it can be passed to WSL as a
            # single argument to 'echo', avoiding:
            #   - temp file path issues (spaces, /mnt/c/ permission gaps)
            #   - BOM injected by PowerShell 5.1 when piping to stdin
            #   - wsl.exe argument-splitting on multi-word -c strings
            # Base64 is [A-Za-z0-9+/=] only — safe as an unquoted sh arg.
            $scriptUtf8 = [System.Text.Encoding]::UTF8.GetBytes(
                $patchScriptLines -join "`n"
            )
            $scriptB64  = [Convert]::ToBase64String($scriptUtf8)

            $patchOut = wsl -u root -e sh -c "echo $scriptB64 | base64 -d | sh" 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Root ext4 patch failed (exit $LASTEXITCODE): $patchOut"
            }

            # patchOut is "OK:<device>:<cfg dir listing>"
            # The listing must include both 99-nocloud.cfg (our file) and
            # ideally 90_dpkg.cfg (the Azure override we're superseding),
            # confirming we wrote to the correct partition.
            if ("$patchOut" -notmatch '^OK:') {
                throw "Unexpected patch output (expected OK:...): $patchOut"
            }
            Write-Host "  cloud.cfg.d: $($patchOut -replace '^OK:[^:]+:','')"
            Write-Host "  ✓ NoCloud datasource enabled in base image." `
                -ForegroundColor Green
        }
        finally {
            wsl --unmount $physDrive 2>&1 | Out-Null
            Dismount-VHD -Path $baseImagePath
        }

        # Create the sentinel so subsequent runs skip the patch.
        New-Item -ItemType File -Path $patchedSentinel -Force | Out-Null
    }

    # ------------------------------------------------------------------
    # Per-VM disk
    # Naming: {vmName}.vhdx in the same vhdPath as the base image.
    # ------------------------------------------------------------------
    $vmDiskPath = Join-Path $vm.vhdPath "$($vm.vmName).vhdx"

    if (Test-Path $vmDiskPath) {
        # The VM existence check in Step 3 confirmed no Hyper-V VM with
        # this name exists, yet a disk file is already present. This can
        # happen if a previous run created the disk but failed before VM
        # creation, or if the operator deleted the VM but kept the disk.
        # Reuse the disk rather than overwriting - the operator may have
        # intentionally preserved it (e.g. to inspect the filesystem).
        Write-Warning (
            "Per-VM disk already exists and will be reused: $vmDiskPath. " +
            "Delete it manually if you want a fresh disk."
        )
    }
    else {
        Write-Host "  Copying base image to per-VM disk ..."
        Copy-Item -Path $baseImagePath -Destination $vmDiskPath

        # Resize to the configured diskGB. The Ubuntu cloud base image is
        # typically ~2 GB; diskGB is expected to be larger (e.g. 40 GB).
        # Resize-VHD cannot shrink a disk (the partition table would be
        # left inconsistent), so we verify the target is larger first.
        $diskBytes   = [int64]$vm.diskGB * 1GB
        $currentSize = (Get-VHD -Path $vmDiskPath).Size

        if ($diskBytes -le $currentSize) {
            Write-Warning (
                "diskGB ($($vm.diskGB) GB) is not larger than the base image " +
                "($([math]::Round($currentSize / 1GB, 1)) GB) - resize skipped."
            )
        }
        else {
            Write-Host "  Resizing to $($vm.diskGB) GB ..."
            Resize-VHD -Path $vmDiskPath -SizeBytes $diskBytes
        }

        Write-Host "  ✓ Per-VM disk ready: $vmDiskPath ($($vm.diskGB) GB)" `
            -ForegroundColor Green
    }

    # Store the disk path on the VM object so Steps 5-6 can reference it
    # without recomputing the path.
    Add-Member -InputObject $vm -MemberType NoteProperty `
               -Name '_vhdxPath' -Value $vmDiskPath -Force
}

# ---------------------------------------------------------------------------
# 6. Cloud-init seed ISO generation
#
#    cloud-init's NoCloud datasource reads from a filesystem volume labelled
#    'cidata'. Three files are placed in the root of the ISO:
#
#      meta-data      - instance identity (instance-id, local-hostname).
#      user-data      - cloud-config: OS user, SSH, installed packages.
#      network-config - cloud-init network v2 format: static IP, gateway,
#                       DNS. Kept separate from user-data so cloud-init's
#                       network module processes it before other modules
#                       that require network access (e.g. package install).
#
#    The ISO is placed in vm.vmConfigPath (separate from the OS disk in
#    vm.vhdPath). Step 6 mounts it as a DVD drive; cloud-init reads it on
#    first boot only — subsequent boots skip it because the instance state
#    is already recorded in /var/lib/cloud/.
#
#    SECURITY - user-data contains vm.password in plaintext so cloud-init
#    can hash it internally (plain_text_passwd). The ISO persists on the
#    host after provisioning; delete it once the VM is running, or restrict
#    read access to vm.vmConfigPath to the provisioning account only.
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    Write-Host ""
    Write-Host "--- Cloud-init ISO: $($vm.vmName) ---" -ForegroundColor Cyan

    # Ensure the vmConfigPath directory exists.
    if (-not (Test-Path -Path $vm.vmConfigPath -PathType Container)) {
        New-Item -ItemType Directory -Path $vm.vmConfigPath -Force | Out-Null
        Write-Host "  Created directory: $($vm.vmConfigPath)"
    }

    # ------------------------------------------------------------------
    # meta-data
    # instance-id must change if the instance is re-created from scratch;
    # using vmName satisfies this for our one-VM-per-name model. It also
    # sets the Linux hostname on first boot via local-hostname.
    # ------------------------------------------------------------------
    $metaData = @"
instance-id: $($vm.vmName)
local-hostname: $($vm.vmName)
"@

    # ------------------------------------------------------------------
    # user-data (cloud-config)
    #
    # plain_text_passwd lets cloud-init hash the password internally,
    # avoiding the need to pre-compute a sha512crypt hash on Windows.
    # lock_passwd must be false — without it cloud-init locks the account
    # after setting the password, blocking SSH password auth even when
    # ssh_pwauth is true.
    # Specifying users: without 'default' in the list intentionally omits
    # the cloud image's built-in 'ubuntu' user; only our configured user
    # is created.
    # package_upgrade is false to keep the first boot fast; operators can
    # run upgrades afterwards.
    #
    # Values that may contain YAML-special characters (colon, hash, quote)
    # are wrapped in YAML double-quoted strings. Backslashes and double
    # quotes within those strings are escaped below.
    # ------------------------------------------------------------------
    $yamlUsername = $vm.username -replace '\\', '\\' -replace '"', '\"'
    $yamlPassword = $vm.password -replace '\\', '\\' -replace '"', '\"'

    $userData = @"
#cloud-config

users:
  - name: "$yamlUsername"
    plain_text_passwd: "$yamlPassword"
    lock_passwd: false
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: [adm, cdrom, dip, plugdev, lxd]

ssh_pwauth: true

packages:
  - openssh-server

package_update: true
package_upgrade: false
"@

    # ------------------------------------------------------------------
    # network-config (cloud-init network configuration v2 / netplan)
    #
    # Matching on driver: hv_netvsc rather than a fixed interface name
    # (eth0, enp0s*, etc.) because the kernel-assigned name varies across
    # Ubuntu releases and Hyper-V generations. hv_netvsc is the driver for
    # all Hyper-V synthetic NICs, so this match always hits the right NIC.
    # ------------------------------------------------------------------
    $networkConfig = @"
version: 2
ethernets:
  eth0:
    match:
      driver: hv_netvsc
    dhcp4: false
    addresses:
      - $($vm.ipAddress)/$($vm.subnetMask)
    routes:
      - to: default
        via: $($vm.gateway)
    nameservers:
      addresses:
        - $($vm.dns)
"@

    $seedIsoPath = Join-Path $vm.vmConfigPath "$($vm.vmName)-seed.iso"
    Write-Host "  Writing: $seedIsoPath"

    New-SeedIso -OutputPath $seedIsoPath -Files @{
        'meta-data'      = $metaData
        'user-data'      = $userData
        'network-config' = $networkConfig
    }

    Write-Host "  ✓ Seed ISO ready: $seedIsoPath" -ForegroundColor Green

    # Store the ISO path on the VM object for Step 6.
    Add-Member -InputObject $vm -MemberType NoteProperty `
               -Name '_seedIsoPath' -Value $seedIsoPath -Force
}

# ---------------------------------------------------------------------------
# 7. Virtual switch and NAT setup
#
#    All VMs share one Internal switch named 'VmLAN'. An Internal
#    switch creates a virtual NIC on the host (vEthernet (VmLAN))
#    through which the host can SSH into the VMs. VMs cannot reach the
#    physical network directly, but a NetNat rule routes their outbound
#    traffic through the host's physical NIC — required for cloud-init's
#    package installs on first boot.
#
#    Gateway and subnet are derived from the queued VMs' config. All VMs
#    must share the same gateway and subnetMask: a single Internal switch
#    maps to one subnet, so mixing subnets would give some VMs a wrong
#    default route.
# ---------------------------------------------------------------------------

$firstVm = $vmsToProvision[0]

foreach ($vm in $vmsToProvision) {
    if ($vm.gateway    -ne $firstVm.gateway -or
        $vm.subnetMask -ne $firstVm.subnetMask) {
        throw (
            "All VM definitions must share the same gateway and subnetMask " +
            "— they will all be attached to the same Internal switch. " +
            "Conflicting entries: '$($firstVm.vmName)' " +
            "($($firstVm.gateway)/$($firstVm.subnetMask)) vs " +
            "'$($vm.vmName)' ($($vm.gateway)/$($vm.subnetMask))."
        )
    }
}

$switchName   = 'VmLAN'
$natName      = 'VmLAN-NAT'
$gatewayIp    = $firstVm.gateway
$prefixLength = [int]$firstVm.subnetMask

# Derive the network address for the NAT prefix (e.g. 192.168.1.1/24
# -> 192.168.1.0/24). Each byte of the gateway is masked with the
# corresponding byte of the subnet mask built from the CIDR prefix.
$gatewayBytes = [System.Net.IPAddress]::Parse($gatewayIp).GetAddressBytes()
$maskBits     = '1' * $prefixLength + '0' * (32 - $prefixLength)
$networkBytes = [byte[]](
    ([Convert]::ToByte($maskBits.Substring( 0, 8), 2) -band $gatewayBytes[0]),
    ([Convert]::ToByte($maskBits.Substring( 8, 8), 2) -band $gatewayBytes[1]),
    ([Convert]::ToByte($maskBits.Substring(16, 8), 2) -band $gatewayBytes[2]),
    ([Convert]::ToByte($maskBits.Substring(24, 8), 2) -band $gatewayBytes[3])
)
$natPrefix = "$([System.Net.IPAddress]::new($networkBytes))/$prefixLength"

Write-Host ""
Write-Host "--- Virtual switch: $switchName ---" -ForegroundColor Cyan

# ------------------------------------------------------------------
# Switch creation (idempotent)
# ------------------------------------------------------------------
$existingSwitch = Get-VMSwitch -Name $switchName -ErrorAction SilentlyContinue
if ($null -ne $existingSwitch) {
    # Guard against a pre-existing switch with the same name but the wrong
    # type. An External switch would expose VMs directly on the physical
    # network rather than the isolated internal LAN this script expects.
    if ($existingSwitch.SwitchType -ne 'Internal') {
        throw (
            "A switch named '$switchName' already exists but is type " +
            "'$($existingSwitch.SwitchType)', expected 'Internal'. " +
            "Rename or remove it before running this script."
        )
    }
    Write-Host "  Switch '$switchName' already exists - skipping." `
        -ForegroundColor Green
}
else {
    Write-Host "  Creating Internal switch '$switchName' ..."
    New-VMSwitch -Name $switchName -SwitchType Internal | Out-Null
    Write-Host "  ✓ Switch created." -ForegroundColor Green
}

# ------------------------------------------------------------------
# Host vNIC IP assignment (idempotent)
# After New-VMSwitch, Windows creates a host adapter named
# 'vEthernet (VmProvisioner)'. Assigning the gateway IP to it puts
# the host on the same subnet as the VMs, enabling SSH from host.
# ------------------------------------------------------------------
$hostAdapter = Get-NetAdapter |
    Where-Object { $_.Name -eq "vEthernet ($switchName)" }
if ($null -eq $hostAdapter) {
    throw "Host virtual NIC 'vEthernet ($switchName)' not found."
}

$existingIp = Get-NetIPAddress `
    -InterfaceIndex $hostAdapter.InterfaceIndex `
    -AddressFamily IPv4 `
    -ErrorAction SilentlyContinue |
    Where-Object { $_.IPAddress -eq $gatewayIp }

if ($null -ne $existingIp) {
    Write-Host "  Host vNIC already has IP $gatewayIp - skipping." `
        -ForegroundColor Green
}
else {
    Write-Host "  Assigning $gatewayIp/$prefixLength to host vNIC ..."
    New-NetIPAddress `
        -InterfaceIndex $hostAdapter.InterfaceIndex `
        -IPAddress      $gatewayIp `
        -PrefixLength   $prefixLength | Out-Null
    Write-Host "  ✓ Host vNIC configured." -ForegroundColor Green
}

# ------------------------------------------------------------------
# NAT rule (idempotent)
# Routes VM traffic out through the host's physical NIC so VMs can
# reach the internet. Required for cloud-init package installs.
# ------------------------------------------------------------------
$existingNat = Get-NetNat -Name $natName -ErrorAction SilentlyContinue
if ($null -ne $existingNat) {
    Write-Host "  NAT rule '$natName' already exists - skipping." `
        -ForegroundColor Green
}
else {
    Write-Host "  Creating NAT rule for $natPrefix ..."
    New-NetNat -Name $natName `
               -InternalIPInterfaceAddressPrefix $natPrefix | Out-Null
    Write-Host "  ✓ NAT rule created ($natPrefix)." -ForegroundColor Green
}

# ---------------------------------------------------------------------------
# 8. VM creation
#
#    For each queued VM:
#      - Create the VM (Gen 2, static RAM, VHDX from Step 4)
#      - Attach the seed ISO as a DVD drive (cloud-init reads it on boot)
#      - Configure Secure Boot for Ubuntu's UEFI shim
#      - Connect to the VmLAN switch created in Section 7
#      - Start the VM, then poll port 22 until cloud-init finishes
#      - Detach and delete the seed ISO once SSH is reachable
# ---------------------------------------------------------------------------

foreach ($vm in $vmsToProvision) {
    Write-Host ""
    Write-Host "--- Creating VM: $($vm.vmName) ---" -ForegroundColor Cyan

    # -Path directs Hyper-V to store the VM configuration files (.vmcx etc.)
    # in vmConfigPath, keeping them co-located with the seed ISO and separate
    # from the OS disk in vhdPath.
    # MemoryStartupBytes is static RAM — dynamic memory is not used because
    # runner workloads benefit from a predictable allocation and dynamic
    # memory adds balloon-driver overhead inside the guest.
    Write-Host "  Creating VM (Gen 2, $($vm.cpuCount) vCPU, $($vm.ramGB) GB RAM) ..."
    New-VM -Name             $vm.vmName `
           -Generation       2 `
           -MemoryStartupBytes ([int64]$vm.ramGB * 1GB) `
           -VHDPath          $vm._vhdxPath `
           -Path             $vm.vmConfigPath | Out-Null

    Set-VMProcessor -VMName $vm.vmName -Count $vm.cpuCount

    # ------------------------------------------------------------------
    # Secure Boot
    # The default template 'MicrosoftWindows' rejects Ubuntu's shim
    # bootloader. 'MicrosoftUEFICertificateAuthority' trusts third-party
    # UEFI bootloaders signed by Microsoft, which Ubuntu's shim is.
    # Setting the first boot device to the VHDX avoids a PXE network-boot
    # attempt that would add a timeout before every boot.
    # ------------------------------------------------------------------
    $osDisk = Get-VMHardDiskDrive -VMName $vm.vmName | Select-Object -First 1
    Set-VMFirmware -VMName              $vm.vmName `
                   -EnableSecureBoot    On `
                   -SecureBootTemplate  'MicrosoftUEFICertificateAuthority' `
                   -FirstBootDevice     $osDisk

    # ------------------------------------------------------------------
    # Seed ISO
    # Attached as a DVD drive. cloud-init does not require the ISO to be
    # bootable — the NoCloud datasource scans all block devices for a
    # volume labelled 'cidata'. The DVD drive sits below the VHDX in the
    # boot order and is never attempted as a boot source.
    # ------------------------------------------------------------------
    Add-VMDvdDrive -VMName $vm.vmName -Path $vm._seedIsoPath

    # ------------------------------------------------------------------
    # Network
    # ------------------------------------------------------------------
    Connect-VMNetworkAdapter -VMName      $vm.vmName `
                             -Name        'Network Adapter' `
                             -SwitchName  $switchName

    Write-Host "  Starting VM ..."
    Start-VM -VMName $vm.vmName
    Write-Host "  ✓ VM started." -ForegroundColor Green

    # ------------------------------------------------------------------
    # Poll port 22 until cloud-init finishes, then delete seed ISO
    #
    # cloud-init runs on first boot: applies netplan (static IP), installs
    # openssh-server, and creates the OS user. SSH becoming reachable is
    # the reliable completion signal — it requires all of the above to have
    # succeeded.
    #
    # The seed ISO is deleted in a finally block so it is removed regardless
    # of whether SSH succeeds or times out. cloud-init reads all seed files
    # into /var/lib/cloud/ at the very start of its run; by the time any
    # timeout fires the ISO is no longer read and is safe to delete.
    # Leaving it on disk is never acceptable — it contains the plaintext
    # password.
    #
    # [System.Net.Sockets.TcpClient] is used instead of Test-NetConnection
    # because Test-NetConnection's output format differs between PS 5.1 and
    # PS 7; the .NET API is consistent across both versions.
    # ------------------------------------------------------------------
    $timeoutMinutes      = 10
    $pollIntervalSeconds = 10
    $deadline            = (Get-Date).AddMinutes($timeoutMinutes)
    $sshReady            = $false

    try {
        Write-Host "  Polling SSH on $($vm.ipAddress):22 ..." -NoNewline

        while ((Get-Date) -lt $deadline) {
            # Abort early if the VM is no longer running — no point waiting
            # out the full timeout if it has already crashed or shut down.
            $vmState = (Get-VM -Name $vm.vmName).State
            if ($vmState -ne 'Running') {
                Write-Host ''
                throw (
                    "VM '$($vm.vmName)' stopped unexpectedly " +
                    "(state: $vmState). Check the Hyper-V console."
                )
            }

            $tcpClient = $null
            try {
                $tcpClient = [System.Net.Sockets.TcpClient]::new()
                if ($tcpClient.ConnectAsync($vm.ipAddress, 22).Wait(2000)) {
                    $sshReady = $true
                    break
                }
            }
            catch { }
            finally {
                if ($null -ne $tcpClient) { $tcpClient.Dispose() }
            }
            Write-Host '.' -NoNewline
            Start-Sleep -Seconds $pollIntervalSeconds
        }

        Write-Host ''

        if (-not $sshReady) {
            throw (
                "SSH on $($vm.ipAddress) did not become reachable within " +
                "$timeoutMinutes minutes. Check the Hyper-V console for " +
                "boot errors."
            )
        }

        Write-Host "  ✓ SSH reachable on $($vm.ipAddress)." -ForegroundColor Green
    }
    finally {
        # Remove-VMDvdDrive detaches before Remove-Item deletes — deleting a
        # file still attached leaves a broken DVD drive reference in the VM.
        $dvdDrive = Get-VMDvdDrive -VMName $vm.vmName |
            Where-Object { $_.Path -eq $vm._seedIsoPath }
        if ($null -ne $dvdDrive) {
            Remove-VMDvdDrive -VMName            $vm.vmName `
                              -ControllerNumber   $dvdDrive.ControllerNumber `
                              -ControllerLocation $dvdDrive.ControllerLocation
        }
        if (Test-Path $vm._seedIsoPath) {
            Remove-Item -Path $vm._seedIsoPath -Force
            Write-Host "  ✓ Seed ISO removed." -ForegroundColor Green
        }
    }

    Write-Host "  ✓ $($vm.vmName) ready." -ForegroundColor Green
    Write-Host "    Connect: ssh $($vm.username)@$($vm.ipAddress)" `
        -ForegroundColor Cyan
}

Write-Host ""
Write-Host "Provisioning complete." -ForegroundColor Green
