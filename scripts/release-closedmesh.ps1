# release-closedmesh.ps1 — package the closedmesh binary for the closedmesh.com installer (Windows).
#
# Produces dist-release\closedmesh-windows-x86_64-<flavor>.zip, where <flavor> is one
# of: cuda, vulkan, cpu. Mirrors scripts/release-closedmesh.sh for the macOS/Linux side.
#
# Usage:
#   powershell -NoProfile -File scripts/release-closedmesh.ps1 -Flavor cuda [-OutputDir dist-release]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cuda', 'vulkan', 'cpu')]
    [string]$Flavor,

    [string]$OutputDir
)

$ErrorActionPreference = 'Stop'

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = Resolve-Path (Join-Path $scriptDir '..')
$defaultDist = Join-Path $repoRoot 'dist-release'
if (-not $OutputDir) { $OutputDir = $defaultDist }

# Windows installer only ships x86_64 today; aarch64 (Snapdragon X) is future work.
$platformSuffix = "windows-x86_64-$Flavor"
$asset = "closedmesh-$platformSuffix.zip"
$zipPath = Join-Path $OutputDir $asset
$shaPath = "$zipPath.sha256"

$bin = Join-Path $repoRoot 'target\release\closedmesh.exe'
if (-not (Test-Path -PathType Leaf $bin)) {
    Write-Error "release-closedmesh: built binary not found at $bin. Run the appropriate just release-build-*-windows recipe first."
    exit 1
}

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir | Out-Null
}

$stage = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))
try {
    Copy-Item $bin (Join-Path $stage 'closedmesh.exe')

    $licensePath = Join-Path $repoRoot 'LICENSE'
    if (Test-Path $licensePath) {
        Copy-Item $licensePath (Join-Path $stage 'LICENSE')
    }

    # Ship a reference scheduled-task XML so users can re-create the autostart
    # manually if install.ps1 --service can't be re-run later.
    $taskRef = Join-Path $repoRoot 'dist\closedmesh-task.xml'
    if (Test-Path $taskRef) {
        Copy-Item $taskRef (Join-Path $stage 'closedmesh-task.xml')
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath

    $hash = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    Set-Content -Path $shaPath -Value $hash -NoNewline -Encoding ASCII
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "  Archive: $zipPath"
Write-Host "  SHA256:  $hash"
Write-Host ""
