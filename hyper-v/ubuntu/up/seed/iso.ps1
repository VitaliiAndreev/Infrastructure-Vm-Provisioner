<#
.SYNOPSIS
    ISO creation helper dot-sourced by provision.ps1.

.NOTES
    Do not run this file directly. It is intended to be dot-sourced:
        . "$PSScriptRoot\iso.ps1"
#>

# ---------------------------------------------------------------------------
# New-SeedIso
#   Creates a cloud-init NoCloud seed ISO containing meta-data, user-data,
#   and network-config files, using the Windows-built-in IMAPI2 COM objects.
#
#   Parameters:
#     OutputPath - full path to the .iso file to write (overwritten if exists)
#     Files      - hashtable of { filename => content (string) }
#
#   The volume label is fixed to 'cidata' — that is the label cloud-init's
#   NoCloud datasource scans for on all attached block devices at first boot.
#
#   A small C# shim (IsoStreamWriter) is compiled once per session via
#   Add-Type. IMAPI2 returns the finished ISO image as a COM IStream, which
#   PowerShell cannot read directly; the shim bridges the gap.
# ---------------------------------------------------------------------------

function New-SeedIso {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $OutputPath,

        [Parameter(Mandatory)]
        [hashtable] $Files
    )

    # Compile the IStream-to-file helper exactly once per PowerShell session.
    # IMAPI2's CreateResultImage() returns a COM IStream; this shim reads it
    # chunk by chunk and writes it to a regular FileStream.
    if (-not ('IsoStreamWriter' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.ComTypes;
public static class IsoStreamWriter {
    public static void ToFile(object comStream, string outputPath) {
        IStream stream = (IStream)comStream;
        using (FileStream fileStream = new FileStream(outputPath, FileMode.Create)) {
            byte[] buffer = new byte[65536];
            IntPtr bytesReadPointer = Marshal.AllocHGlobal(IntPtr.Size);
            try {
                while (true) {
                    stream.Read(buffer, buffer.Length, bytesReadPointer);
                    int bytesRead = Marshal.ReadInt32(bytesReadPointer);
                    if (bytesRead == 0) break;
                    fileStream.Write(buffer, 0, bytesRead);
                }
            } finally {
                Marshal.FreeHGlobal(bytesReadPointer);
            }
        }
    }
}
'@
    }

    # Write each cloud-init file to a temp directory so IMAPI2 can read them
    # via AddTree. UTF-8 without BOM is required — a BOM in user-data causes
    # cloud-init to reject the '#cloud-config' header and skip the file.
    $tempDir   = Join-Path $env:TEMP "seed-$(([System.Guid]::NewGuid().ToString('N')))"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    New-Item -ItemType Directory -Path $tempDir | Out-Null

    try {
        foreach ($name in $Files.Keys) {
            [System.IO.File]::WriteAllText(
                (Join-Path $tempDir $name),
                $Files[$name],
                $utf8NoBom
            )
        }

        # IMAPI2FS is a Windows built-in COM server (available since Vista).
        # FileSystemsToCreate = 3 requests ISO 9660 (bit 0) + Joliet (bit 1),
        # giving broad compatibility. VolumeName 'cidata' is the marker that
        # cloud-init's NoCloud datasource recognises on a scanned block device.
        $fsi = New-Object -ComObject IMAPI2FS.MsftFileSystemImage
        $fsi.FileSystemsToCreate = 3
        $fsi.VolumeName = 'cidata'
        $fsi.Root.AddTree($tempDir, $false)

        $image = $fsi.CreateResultImage()
        [IsoStreamWriter]::ToFile($image.ImageStream, $OutputPath)
    }
    finally {
        Remove-Item -Path $tempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}
