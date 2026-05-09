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

function Resolve-CommandPath {
    param([string]$Name)
    $cmd = Get-Command $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Import-CmdEnvironment {
    param([Parameter(Mandatory=$true)][string]$CommandLine)
    $output = & cmd.exe /s /c "$CommandLine && set"
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to initialize Windows build environment with command: $CommandLine"
    }
    foreach ($line in $output) {
        if ($line -match '^(?<name>[^=]+)=(?<value>.*)$') {
            Set-Item -Path "env:$($Matches.name)" -Value $Matches.value
        }
    }
}

# Inline copy of build-windows.ps1::Ensure-MsvcToolchain. windows-latest
# ships MinGW (`C:\mingw64\bin\c++.exe`) on $env:PATH; if we don't activate
# MSVC first, CMake happily picks the MinGW gcc/g++ and then chokes on
# /DPATH_MAX=4096 (MSVC syntax) with `linker input file not found`.
function Ensure-MsvcToolchain {
    if ((Resolve-CommandPath "cl") -and (Resolve-CommandPath "link")) {
        return
    }

    $programFilesX86 = ${env:ProgramFiles(x86)}
    $vswhereCandidates = @()
    if ($programFilesX86) { $vswhereCandidates += (Join-Path $programFilesX86 "Microsoft Visual Studio\Installer\vswhere.exe") }
    if ($env:ProgramFiles) { $vswhereCandidates += (Join-Path $env:ProgramFiles "Microsoft Visual Studio\Installer\vswhere.exe") }
    $vswhereFromPath = Resolve-CommandPath "vswhere"
    if ($vswhereFromPath) { $vswhereCandidates += $vswhereFromPath }

    $vcvars64 = $null
    $vswhere = $vswhereCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -Unique -First 1
    if ($vswhere) {
        $installationPathOutput = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1
        $installationPath = if ($installationPathOutput) { $installationPathOutput.Trim() } else { "" }
        if ($installationPath) {
            $candidate = Join-Path $installationPath "VC\Auxiliary\Build\vcvars64.bat"
            if (Test-Path $candidate) { $vcvars64 = $candidate }
        }
    }

    if (-not $vcvars64) {
        $searchRoots = @($programFilesX86, $env:ProgramFiles) | Where-Object { $_ } | Select-Object -Unique
        foreach ($searchRoot in $searchRoots) {
            $candidate = Get-ChildItem -Path $searchRoot -Filter vcvars64.bat -Recurse -ErrorAction SilentlyContinue |
                Where-Object { $_.FullName -like '*Microsoft Visual Studio*VC\Auxiliary\Build\vcvars64.bat' } |
                Select-Object -First 1
            if ($candidate) { $vcvars64 = $candidate.FullName; break }
        }
    }

    if (-not $vcvars64 -or -not (Test-Path $vcvars64)) {
        throw "Visual Studio Build Tools with vcvars64.bat were not found on this runner."
    }

    Import-CmdEnvironment "`"$vcvars64`" >nul"

    if (-not (Resolve-CommandPath "cl")) {
        throw "MSVC toolchain initialization completed, but cl.exe is still not on PATH."
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

Ensure-MsvcToolchain
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

if (Resolve-CommandPath "ninja") {
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
