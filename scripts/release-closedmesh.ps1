# release-closedmesh.ps1 — package the closedmesh binary for the closedmesh.com installer (Windows).
#
# Produces dist-release\closedmesh-windows-x86_64-<flavor>.zip, where <flavor> is one
# of: cuda, vulkan, cpu. Mirrors scripts/release-closedmesh.sh for the macOS/Linux side.
#
# This bundle is SELF-CONTAINED: it ships closedmesh.exe AND the
# llama.cpp helper binaries (rpc-server.exe, llama-server.exe) plus
# every shipped DLL. Pre-0.66.4 the script only packaged closedmesh.exe,
# which meant every Windows install joined the mesh fine but failed
# every model load with "rpc-server.exe not found in
# C:\Users\…\AppData\Local\closedmesh\bin" because the runtime calls
# resolve_binary("rpc-server", …) on every load. The
# closedmesh-llm Windows CI doesn't compile llama.cpp itself yet
# (release.yml::build_windows only runs `cargo build --release -p
# closedmesh`), so until that lands we pull the matching helpers from
# ggml-org/llama.cpp's official Windows release at packaging time.
#
# Keep $LlamaCppTag in lockstep with the .deps/llama.cpp checkout
# (see `git -C .deps/llama.cpp describe --tags`). llama.cpp does break
# RPC and CLI protocol inside major releases; closedmesh.exe and the
# helpers must speak the same one.
#
# Usage:
#   powershell -NoProfile -File scripts/release-closedmesh.ps1 -Flavor cuda [-OutputDir dist-release]

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('cuda', 'vulkan', 'cpu')]
    [string]$Flavor,

    [string]$OutputDir,

    [string]$LlamaCppTag = 'b9041'
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

# Map closedmesh flavor → llama.cpp official Windows release asset.
function Get-LlamaCppAsset {
    param([string]$F, [string]$Tag)
    switch ($F) {
        'cuda'   { return "llama-$Tag-bin-win-cuda-12.4-x64.zip" }
        'vulkan' { return "llama-$Tag-bin-win-vulkan-x64.zip" }
        'cpu'    { return "llama-$Tag-bin-win-cpu-x64.zip" }
        default  { throw "Unsupported flavor: $F" }
    }
}

# Fetch and extract a llama.cpp release ZIP into a temp dir, returning
# the directory containing the unpacked files. Caller is responsible
# for nuking it when done.
function Fetch-LlamaCppArchive {
    param([string]$Asset, [string]$Tag)

    $url = "https://github.com/ggml-org/llama.cpp/releases/download/$Tag/$Asset"
    $tmp = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))
    Write-Host "  Fetching $url"
    Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile (Join-Path $tmp $Asset)
    $extract = Join-Path $tmp 'unpack'
    Expand-Archive -Path (Join-Path $tmp $Asset) -DestinationPath $extract -Force
    return @{ Tmp = $tmp; Extract = $extract }
}

$stage = New-Item -ItemType Directory -Path (Join-Path ([System.IO.Path]::GetTempPath()) ([System.Guid]::NewGuid().ToString()))
$llamaUnpack = $null
$cudartUnpack = $null
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

    # Bundle the matching llama.cpp helpers + DLLs.
    $llamaAsset = Get-LlamaCppAsset -F $Flavor -Tag $LlamaCppTag
    $llamaUnpack = Fetch-LlamaCppArchive -Asset $llamaAsset -Tag $LlamaCppTag
    $rpcSrc = Get-ChildItem -Path $llamaUnpack.Extract -Filter 'rpc-server.exe' -Recurse -File | Select-Object -First 1
    $srvSrc = Get-ChildItem -Path $llamaUnpack.Extract -Filter 'llama-server.exe' -Recurse -File | Select-Object -First 1
    if (-not $rpcSrc -or -not $srvSrc) {
        throw "llama.cpp $LlamaCppTag $Flavor build did not contain rpc-server.exe / llama-server.exe under $($llamaUnpack.Extract)"
    }
    Copy-Item $rpcSrc.FullName (Join-Path $stage 'rpc-server.exe')
    Copy-Item $srvSrc.FullName (Join-Path $stage 'llama-server.exe')

    # Drop every DLL the llama.cpp build ships. rpc-server / llama-server
    # LoadLibrary() a fan-out of ggml-*.dll variants (ggml-base, ggml-cpu-
    # <isa>, ggml-vulkan / ggml-cuda, llama, llama-common, libomp140, …).
    # Missing any one of them surfaces as exit 0xC0000135 with no stderr;
    # easier to just bundle the whole DLL set.
    Get-ChildItem -Path $rpcSrc.DirectoryName -Filter '*.dll' -File | ForEach-Object {
        Copy-Item -Force $_.FullName (Join-Path $stage $_.Name)
    }

    # CUDA flavor: also bundle the CUDA runtime DLLs from the matching
    # cudart-* zip on the same release. Users without a system-wide
    # CUDA install need these or every load dies with 0xC0000135.
    if ($Flavor -eq 'cuda') {
        $cudartAsset = "cudart-llama-bin-win-cuda-12.4-x64.zip"
        $cudartUnpack = Fetch-LlamaCppArchive -Asset $cudartAsset -Tag $LlamaCppTag
        Get-ChildItem -Path $cudartUnpack.Extract -Filter '*.dll' -Recurse -File | ForEach-Object {
            Copy-Item -Force $_.FullName (Join-Path $stage $_.Name)
        }
    }

    if (Test-Path $zipPath) { Remove-Item $zipPath }
    Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zipPath

    $hash = (Get-FileHash -Algorithm SHA256 -Path $zipPath).Hash.ToLower()
    Set-Content -Path $shaPath -Value $hash -NoNewline -Encoding ASCII
} finally {
    Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
    if ($llamaUnpack)  { Remove-Item -Recurse -Force $llamaUnpack.Tmp  -ErrorAction SilentlyContinue }
    if ($cudartUnpack) { Remove-Item -Recurse -Force $cudartUnpack.Tmp -ErrorAction SilentlyContinue }
}

Write-Host ""
Write-Host "  Archive: $zipPath"
Write-Host "  SHA256:  $hash"
Write-Host ""
