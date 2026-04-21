<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after Infrastructure.Common and Invoke-BaseImagePatch.ps1
    are loaded.
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

        Write-Host "  [OK] Base image cached: $baseImagePath" -ForegroundColor Green
    }

    # ------------------------------------------------------------------
    # Patch cloud-init datasource config in the base VHDX.
    # See Invoke-BaseImagePatch.ps1 for full implementation details.
    # ------------------------------------------------------------------
    $patchedSentinel = $baseImagePath -replace '\.vhdx$', '.nocloud-patched'
    Invoke-BaseImagePatch -BaseImagePath $baseImagePath -SentinelPath $patchedSentinel

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

        Write-Host "  [OK] Per-VM disk ready: $vmDiskPath ($($Vm.diskGB) GB)" `
            -ForegroundColor Green
    }

    # Store the disk path on the VM object so Invoke-VmCreation can
    # reference it without recomputing the path.
    Add-Member -InputObject $Vm -MemberType NoteProperty `
               -Name '_vhdxPath' -Value $vmDiskPath -Force
}
