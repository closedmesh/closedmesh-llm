# build-moe-helpers-windows.ps1 — build llama-moe-analyze / llama-moe-split
# from the patched llama.cpp source for the Windows release bundle.
#
# These two CLI tools are ClosedMesh additions to llama.cpp (see
# third_party/llama.cpp/patches/0003-moe-add-expert-analysis-and-split-tools.patch),
# so they do not appear in ggml-org/llama.cpp's official Windows
# release archives that release-closedmesh.ps1 currently fetches for
# rpc-server.exe / llama-server.exe. Building them ourselves is what
# unblocks compound-RAM serving for MoE models on Windows hosts.
#
# CPU-only build is sufficient: both tools are GGUF transformation
# utilities with no GPU dependency, so we skip CUDA/Vulkan/HIP to keep
# the windows-latest CI runner happy and quick.
#
# Usage:
#   powershell -NoProfile -File scripts/build-moe-helpers-windows.ps1 [-OutputDir <dir>]

[CmdletBinding()]
param(
    [string]$OutputDir
)

$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot  = [System.IO.Path]::GetFullPath((Join-Path $scriptDir ".."))
$llamaDir  = if ($env:CLOSEDMESH_LLAMA_DIR) { $env:CLOSEDMESH_LLAMA_DIR } else { Join-Path $repoRoot ".deps\llama.cpp" }
$buildDir  = Join-Path $llamaDir "build"

function Invoke-Native {
    param([string]$Command, [string[]]$Arguments)

    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE"
    }
}

function Prepare-PatchedLlama {
    $pinFile     = Join-Path $repoRoot "third_party\llama.cpp\upstream.txt"
    $patchDir    = Join-Path $repoRoot "third_party\llama.cpp\patches"
    $upstreamUrl = if ($env:LLAMA_UPSTREAM_URL) { $env:LLAMA_UPSTREAM_URL } else { "https://github.com/ggml-org/llama.cpp.git" }
    $targetSha   = if ($env:CLOSEDMESH_LLAMA_PIN_SHA) { $env:CLOSEDMESH_LLAMA_PIN_SHA } else { (Get-Content $pinFile -Raw).Trim() }

    if (-not (Test-Path $pinFile))  { throw "Missing llama.cpp upstream pin: $pinFile" }
    if (-not (Test-Path $patchDir)) { throw "Missing llama.cpp patch directory: $patchDir" }

    $llamaParent = Split-Path -Parent $llamaDir
    New-Item -ItemType Directory -Force -Path $llamaParent | Out-Null
    if (-not (Test-Path (Join-Path $llamaDir ".git"))) {
        if (Test-Path $llamaDir) { Remove-Item -Recurse -Force $llamaDir }
        Invoke-Native "git" @("clone", "--filter=blob:none", $upstreamUrl, $llamaDir)
    }

    Push-Location $llamaDir
    try {
        & git am --abort *> $null
        Invoke-Native "git" @("remote", "set-url", "origin", $upstreamUrl)
        Invoke-Native "git" @("fetch", "origin", "master", "--tags")
        Invoke-Native "git" @("config", "user.name", "ClosedMesh CI")
        Invoke-Native "git" @("config", "user.email", "ci@closedmesh.local")
        Invoke-Native "git" @("-c", "advice.detachedHead=false", "checkout", "--detach", "--quiet", $targetSha)
        Invoke-Native "git" @("reset", "--hard", "--quiet", $targetSha)
        Invoke-Native "git" @("clean", "-fdx", "-e", "build/")

        $patches = Get-ChildItem -Path $patchDir -Filter "*.patch" | Sort-Object Name
        foreach ($patch in $patches) {
            Invoke-Native "git" @("am", "--3way", $patch.FullName)
        }

        $patchedSha = (& git rev-parse HEAD).Trim()
        Write-Host "prepared llama.cpp"
        Write-Host "  upstream: $targetSha"
        Write-Host "  patched:  $patchedSha"
    } finally {
        Pop-Location
    }
}

Prepare-PatchedLlama

$cmakeArgs = @(
    "-B", $buildDir,
    "-S", $llamaDir,
    "-DCMAKE_BUILD_TYPE=Release",
    "-DCMAKE_CXX_FLAGS=/DPATH_MAX=4096",
    "-DGGML_RPC=ON",
    "-DGGML_METAL=OFF",
    "-DGGML_CUDA=OFF",
    "-DGGML_HIP=OFF",
    "-DGGML_VULKAN=OFF",
    "-DBUILD_SHARED_LIBS=OFF",
    "-DLLAMA_OPENSSL=OFF",
    "-DLLAMA_BUILD_TESTS=OFF",
    "-DGGML_BUILD_TESTS=OFF"
)

if (Get-Command ninja -ErrorAction SilentlyContinue) {
    $cmakeArgs = @("-G", "Ninja") + $cmakeArgs
}

$parallel = [Environment]::ProcessorCount
Invoke-Native "cmake" $cmakeArgs
Invoke-Native "cmake" @("--build", $buildDir, "--config", "Release", "--parallel", "$parallel",
                       "--target", "llama-moe-analyze", "llama-moe-split")

$built = @(
    Join-Path $buildDir "bin\llama-moe-analyze.exe"
    Join-Path $buildDir "bin\llama-moe-split.exe"
)
foreach ($p in $built) {
    if (-not (Test-Path $p)) { throw "Expected build output not found: $p" }
}

if ($OutputDir) {
    New-Item -ItemType Directory -Force -Path $OutputDir | Out-Null
    foreach ($p in $built) {
        Copy-Item -Force $p (Join-Path $OutputDir (Split-Path -Leaf $p))
    }
}

Write-Host ""
Write-Host "  llama-moe-analyze.exe: $($built[0])"
Write-Host "  llama-moe-split.exe:   $($built[1])"
