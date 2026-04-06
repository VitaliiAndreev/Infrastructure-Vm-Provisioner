<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after common.ps1 is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-DiskImageAcquisition
#   Ensures a per-VM VHDX disk is ready in the configured vhdPath directory.
#
#   Two sub-steps run in order:
#
#   a) Base image cache - downloads the Ubuntu cloud image for the requested
#      ubuntuVersion if not already cached, extracts the .vhd from the
#      tar.gz archive, converts to VHDX (required for Hyper-V Gen 2), and
#      patches the cloud-init datasource config via WSL2 so the NoCloud
#      seed ISO is consulted on first boot. One cached VHDX exists per
#      (vhdPath, ubuntuVersion) pair; subsequent runs skip the download.
#      A sentinel file alongside the VHDX records that patching is done
#      so re-runs also skip the WSL2 mount step.
#
#   b) Per-VM disk - copies the base VHDX to a per-VM file and resizes it
#      to Vm.diskGB. Each VM gets an independent flat copy rather than a
#      differencing disk: a corrupted or deleted base cannot render existing
#      VMs unbootable, and the flat copy is self-contained for backup.
#
#   On return, $Vm._vhdxPath is set via Add-Member for use by
#   Invoke-VmCreation.
# ---------------------------------------------------------------------------
function Invoke-DiskImageAcquisition {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [object] $Vm
    )

    Write-Host ""
    Write-Host "--- Disk acquisition: $($Vm.vmName) ---" -ForegroundColor Cyan

    # ------------------------------------------------------------------
    # Ensure the vhdPath directory exists before writing any files to it.
    # ------------------------------------------------------------------
    if (-not (Test-Path -Path $Vm.vhdPath -PathType Container)) {
        New-Item -ItemType Directory -Path $Vm.vhdPath -Force | Out-Null
        Write-Host "  Created directory: $($Vm.vhdPath)"
    }

    # ------------------------------------------------------------------
    # Base image cache
    # Naming convention: ubuntu-{version}-server-cloudimg-amd64.vhdx
    # One cached .vhdx per (vhdPath, ubuntuVersion) pair.
    # ------------------------------------------------------------------
    $baseImageName = "ubuntu-$($Vm.ubuntuVersion)-server-cloudimg-amd64.vhdx"
    $baseImagePath = Join-Path $Vm.vhdPath $baseImageName

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
        # a standard VHD and is fully compatible with Hyper-V Gen 2 - both
        # Azure and Hyper-V use UEFI + the same VHD spec.
        $downloadUrl = (
            "https://cloud-images.ubuntu.com/releases/$($Vm.ubuntuVersion)" +
            "/release/ubuntu-$($Vm.ubuntuVersion)-server-cloudimg-amd64-azure.vhd.tar.gz"
        )
        $archivePath = Join-Path $Vm.vhdPath `
                           "ubuntu-$($Vm.ubuntuVersion)-server-cloudimg-amd64-azure.vhd.tar.gz"
        $extractDir  = Join-Path $Vm.vhdPath "_extract_$($Vm.ubuntuVersion)"

        Write-Host "  Downloading base image ..."
        Write-Host "    From: $downloadUrl"
        Write-Host "    To  : $archivePath"

        try {
            Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath -UseBasicParsing
        }
        catch {
            throw (
                "Failed to download Ubuntu $($Vm.ubuntuVersion) image " +
                "from '$downloadUrl': $_"
            )
        }

        # tar.exe ships with Windows 10 1803+ (C:\Windows\System32\tar.exe)
        # and handles .tar.gz natively - no third-party tool required.
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
        # materialises all sparse extents - Copy-Item does not carry over
        # the NTFS sparse attribute to the destination.
        Write-Host "  Materialising sparse extents ..."
        # Keep the .vhd extension - Convert-VHD rejects files that don't
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
    # ------------------------------------------------------------------
    $patchedSentinel = $baseImagePath -replace '\.vhdx$', '.nocloud-patched'

    if (-not (Test-Path $patchedSentinel)) {
        Write-Host "  Patching datasource config in base image ..."

        # WSL2 is required for wsl --mount (kernel) and wsl -u root (distro).
        # If either is missing, install now and exit - the script must be
        # re-run after WSL2 is fully initialised (which may require a reboot).
        #
        # wsl --install on Windows 11 is idempotent: it enables the
        # 'Windows Subsystem for Linux' and 'Virtual Machine Platform'
        # features if absent, and installs Ubuntu as the default distro.
        # Running as Administrator (already required by this script) is
        # sufficient - no separate elevated prompt is needed.
        $wslExe   = Get-Command 'wsl.exe' -ErrorAction SilentlyContinue
        $wslReady = $false
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

        # Attach the base VHDX as a raw disk (no drive letter - Windows
        # cannot read the ext4 partition, so assigning one would only
        # cause a 'Format disk?' prompt).
        $patchVhd    = Mount-VHD -Path $baseImagePath -NoDriveLetter -PassThru
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
            # The script is encoded as base64 so it can be passed to WSL as a
            # single argument to 'echo', avoiding:
            #   - temp file path issues (spaces, /mnt/c/ permission gaps)
            #   - BOM injected by PowerShell 5.1 when piping to stdin
            #   - wsl.exe argument-splitting on multi-word -c strings
            # Base64 is [A-Za-z0-9+/=] only - safe as an unquoted sh arg.
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
    $vmDiskPath = Join-Path $Vm.vhdPath "$($Vm.vmName).vhdx"

    if (Test-Path $vmDiskPath) {
        # The VM existence check in provision.ps1 confirmed no Hyper-V VM
        # with this name exists, yet a disk file is already present. This
        # can happen if a previous run created the disk but failed before VM
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
        $diskBytes   = [int64]$Vm.diskGB * 1GB
        $currentSize = (Get-VHD -Path $vmDiskPath).Size

        if ($diskBytes -le $currentSize) {
            Write-Warning (
                "diskGB ($($Vm.diskGB) GB) is not larger than the base image " +
                "($([math]::Round($currentSize / 1GB, 1)) GB) - resize skipped."
            )
        }
        else {
            Write-Host "  Resizing to $($Vm.diskGB) GB ..."
            Resize-VHD -Path $vmDiskPath -SizeBytes $diskBytes
        }

        Write-Host "  ✓ Per-VM disk ready: $vmDiskPath ($($Vm.diskGB) GB)" `
            -ForegroundColor Green
    }

    # Store the disk path on the VM object so Invoke-VmCreation can
    # reference it without recomputing the path.
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_vhdxPath' -Value $vmDiskPath -Force
}
