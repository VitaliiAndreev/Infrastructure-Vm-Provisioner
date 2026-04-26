<#
.NOTES
    Do not run this file directly. It is intended to be dot-sourced by
    provision.ps1 after Infrastructure.Common is loaded.
#>

# ---------------------------------------------------------------------------
# Invoke-BaseImagePatch
#   Patches the cloud-init datasource config inside a base VHDX so that the
#   NoCloud seed ISO is consulted on first boot instead of the Azure IMDS.
#
#   The Ubuntu Azure cloud image ships with a datasource restriction:
#     datasource_list: [ Azure ]
#   On a local Hyper-V host, cloud-init cannot reach the Azure IMDS, falls
#   back to 'None', and never reads the seed ISO. This function writes a
#   higher-priority override file (99-nocloud.cfg) into
#   /etc/cloud/cloud.cfg.d/ inside the VHDX to add NoCloud.
#
#   Implementation:
#     1. Skip immediately if the sentinel file is present (already patched).
#     2. Check WSL2 readiness (wsl.exe + at least one registered distro).
#        If not ready, run wsl --install and throw a Wsl2NotReady error.
#        provision.ps1 catches that specific error and exits with code 0 after
#        printing the reboot prompt. Throwing rather than calling exit 0 here
#        keeps this function unit-testable.
#     3. Mount the VHDX via Mount-VHD (no drive letter).
#     4. Attach the raw disk to the WSL2 kernel with wsl --mount --bare.
#     5. Identify the new block device by diffing lsblk before and after.
#     6. Run a base64-encoded shell script that mounts each partition as ext4,
#        finds the root by checking /etc/os-release, writes 99-nocloud.cfg,
#        and syncs to flush kernel write buffers before detach.
#     7. Unmount and dismount in a finally block (always runs).
#     8. Create the sentinel file so subsequent runs skip steps 2-7.
#
#   Parameters:
#     BaseImagePath  - absolute path to the base .vhdx to patch.
#     SentinelPath   - absolute path to the sentinel file that marks the
#                      patch as done (conventionally <base>.nocloud-patched).
# ---------------------------------------------------------------------------

function Invoke-BaseImagePatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $BaseImagePath,

        [Parameter(Mandatory)]
        [string] $SentinelPath
    )

    if (Test-Path $SentinelPath) {
        return    # already patched on a previous run - nothing to do
    }

    Write-Host "  Patching datasource config in base image ..."

    # WSL2 is required for wsl --mount (kernel) and wsl -u root (distro).
    # If either is missing, install now and signal the caller to exit so the
    # operator can reboot before re-running provision.ps1.
    #
    # wsl --install on Windows 11 is idempotent: it enables the
    # 'Windows Subsystem for Linux' and 'Virtual Machine Platform'
    # features if absent, and installs Ubuntu as the default distro.
    # Running as Administrator (already required by this script) is
    # sufficient - no separate elevated prompt is needed.
    #
    # Throwing rather than calling exit 0 keeps this function testable.
    # provision.ps1 catches the Wsl2NotReady prefix and exits with 0.
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
        throw (
            "Wsl2NotReady: WSL2 has been installed. A reboot may be required " +
            "to complete setup. Please reboot and re-run provision.ps1."
        )
    }

    # Attach the base VHDX as a raw disk (no drive letter - Windows
    # cannot read the ext4 partition, so assigning one would only
    # cause a 'Format disk?' prompt).
    $patchVhd    = Mount-VHD -Path $BaseImagePath -NoDriveLetter -PassThru
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
        Write-Host "  [OK] NoCloud datasource enabled in base image." `
            -ForegroundColor Green
    }
    finally {
        wsl --unmount $physDrive 2>&1 | Out-Null
        Dismount-VHD -Path $BaseImagePath
    }

    # Create the sentinel so subsequent runs skip the patch.
    New-Item -ItemType File -Path $SentinelPath -Force | Out-Null
}
