<#
.SYNOPSIS
    ZiGrep installer for Windows (native, no WSL required).

.DESCRIPTION
    Downloads the prebuilt Windows binary from the latest GitHub release,
    verifies its SHA-256 against the published checksum file, installs
    zigrep.exe and zgrep.exe into a per-user directory and adds that
    directory to the user PATH.

.EXAMPLE
    One-liner (PowerShell):
    irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.ps1 | iex

.EXAMPLE
    Download and run explicitly:
    irm https://raw.githubusercontent.com/DannyBaanks/ZiGrep/main/install.ps1 -OutFile install.ps1
    ./install.ps1
#>
[CmdletBinding()]
param(
    [string]$Version = "latest",
    [string]$InstallDir = "",
    # Override the download base URL (used by the test suite and useful for
    # corporate mirrors / proxies). Empty means the official GitHub releases.
    [string]$BaseUrlOverride = "",
    # Skip the user PATH update (used by the test suite).
    [switch]$NoPathUpdate
)

$ErrorActionPreference = "Stop"
$Repo = "DannyBaanks/ZiGrep"

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "WARN $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "ERR $msg" -ForegroundColor Red }

# Defined before the first call: PowerShell resolves function names at
# runtime, not at parse time.
function Install-ToPath {
    if ($NoPathUpdate) {
        Write-Warn "PATH update skipped (-NoPathUpdate)"
        return
    }

    # Add the install directory to the USER PATH (no admin rights needed).
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) { $parts = @($userPath -split ";" | Where-Object { $_ }) }

    if ($parts -notcontains $InstallDir) {
        $newPath = (@($parts) + $InstallDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Ok "added $InstallDir to the user PATH"
        Write-Host ""
        Write-Host "  Restart your terminal (or open a new one) so the PATH change applies." -ForegroundColor Yellow
    } else {
        Write-Ok "$InstallDir is already in the user PATH"
    }

    # Make it usable in this session too.
    if (($env:Path -split ";") -notcontains $InstallDir) {
        $env:Path = "$env:Path;$InstallDir"
    }

    Write-Host ""
    Write-Host "  Version check:" -ForegroundColor Cyan
    & (Join-Path $InstallDir "zigrep.exe") --version
    Write-Host ""
    Write-Host "  Try it:" -ForegroundColor Cyan
    Write-Host "    zigrep --help"
    Write-Host "    zigrep -n TODO src"
    Write-Host ""
    Write-Host "  ZiGrep is ready." -ForegroundColor Green
}

Write-Host ""
Write-Host "  ZiGrep - native Windows installer" -ForegroundColor Green
Write-Host "  (Windows-native build; no WSL, no C runtime needed)" -ForegroundColor DarkGray
Write-Host ""

# ---------------------------------------------------------------------------
# 1. Detect architecture
# ---------------------------------------------------------------------------
$arch = $env:PROCESSOR_ARCHITECTURE
if ($arch -eq "ARM64") {
    $TargetArch = "aarch64"
} elseif ($arch -eq "AMD64" -or $arch -eq "x86_64") {
    $TargetArch = "x86_64"
} else {
    Write-Err "Unsupported architecture: $arch (expected AMD64 or ARM64)."
    exit 1
}

if (-not $InstallDir) {
    $InstallDir = Join-Path $env:LOCALAPPDATA "Programs\ZiGrep"
}

$AssetName = "zigrep-windows-$TargetArch.zip"

if ($BaseUrlOverride) {
    $BaseUrl = $BaseUrlOverride.TrimEnd("/")
} elseif ($Version -eq "latest") {
    $BaseUrl = "https://github.com/$Repo/releases/latest/download"
} else {
    $tag = $Version
    if (-not $tag.StartsWith("v")) { $tag = "v$Version" }
    $BaseUrl = "https://github.com/$Repo/releases/download/$tag"
}
$DownloadUrl = "$BaseUrl/$AssetName"
$ChecksumsUrl = "$BaseUrl/SHA256SUMS.txt"

Write-Step "Architecture: $TargetArch"
Write-Step "Install directory: $InstallDir"

# ---------------------------------------------------------------------------
# 2. Download the release asset
# ---------------------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("zigrep-install-" + [Guid]::NewGuid().ToString("N").Substring(0, 8))
New-Item -ItemType Directory -Path $tmp -Force | Out-Null

$zipPath = Join-Path $tmp $AssetName
$sumsPath = Join-Path $tmp "SHA256SUMS.txt"

try {
    Write-Step "Downloading $AssetName"
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $zipPath -UseBasicParsing
    } catch {
        Write-Err "Could not download the prebuilt binary: $($_.Exception.Message)"
        Write-Host ""
        Write-Host "Fallback: build from source with Zig 0.16+" -ForegroundColor Yellow
        if (Get-Command zig -ErrorAction SilentlyContinue) {
            # Clone the release tag, not the default branch: the Windows port
            # lives in a release, and the default branch may not have it (or
            # may not build on Windows at all).
            $cloneRef = $null
            if ($Version -eq "latest") {
                # Resolve the real latest tag through the GitHub API.
                try {
                    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers @{ "User-Agent" = "ZiGrep-Installer" }
                    $cloneRef = $rel.tag_name
                } catch {
                    Write-Warn "Could not resolve the latest release tag ($($_.Exception.Message))."
                }
            } else {
                $cloneRef = $Version
                if (-not $cloneRef.StartsWith("v")) { $cloneRef = "v$cloneRef" }
            }
            if (-not $cloneRef) {
                Write-Err "Cannot determine which release to build from. Use -Version <tag>."
                exit 1
            }
            Write-Step "Cloning $Repo at $cloneRef and building..."
            $repoDir = Join-Path $tmp "repo"
            git clone --depth 1 --branch $cloneRef "https://github.com/$Repo.git" $repoDir | Out-Null
            Push-Location $repoDir
            try {
                zig build -Doptimize=ReleaseFast
            } finally {
                Pop-Location
            }
            New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
            Copy-Item (Join-Path $repoDir "zig-out\bin\zigrep.exe") (Join-Path $InstallDir "zigrep.exe") -Force
            Copy-Item (Join-Path $repoDir "zig-out\bin\zgrep.exe") (Join-Path $InstallDir "zgrep.exe") -Force
            Install-ToPath
            exit 0
        } else {
            Write-Err "Zig is not installed. Install Zig 0.16+ from https://ziglang.org/download/"
            Write-Host "or download the binary manually from https://github.com/$Repo/releases"
            exit 1
        }
    }

    # -----------------------------------------------------------------------
    # 3. Verify the checksum (the release publishes SHA256SUMS.txt)
    # -----------------------------------------------------------------------
    Write-Step "Verifying SHA-256"
    $expected = $null
    try {
        Invoke-WebRequest -Uri $ChecksumsUrl -OutFile $sumsPath -UseBasicParsing
        foreach ($line in (Get-Content $sumsPath)) {
            if ($line -match '^\s*([0-9a-fA-F]{64})\s+\*?(.+?)\s*$') {
                if ($Matches[2] -like "*$AssetName") {
                    $expected = $Matches[1].ToLower()
                    break
                }
            }
        }
    } catch {
        Write-Warn "Could not fetch SHA256SUMS.txt ($($_.Exception.Message))."
    }

    $actual = (Get-FileHash $zipPath -Algorithm SHA256).Hash.ToLower()
    if ($expected) {
        if ($actual -ne $expected) {
            Write-Err "Checksum mismatch!"
            Write-Host "  expected: $expected"
            Write-Host "  actual  : $actual"
            exit 1
        }
        Write-Ok "checksum matches ($actual)"
    } else {
        Write-Warn "No published checksum for $AssetName; continuing without verification."
    }

    # -----------------------------------------------------------------------
    # 4. Extract and install
    # -----------------------------------------------------------------------
    Write-Step "Extracting"
    $extractDir = Join-Path $tmp "extract"
    Expand-Archive -Path $zipPath -DestinationPath $extractDir -Force

    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $installed = 0
    foreach ($name in @("zigrep.exe", "zgrep.exe")) {
        $src = Join-Path $extractDir $name
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $InstallDir $name) -Force
            $installed++
        }
    }
    if ($installed -eq 0) {
        Write-Err "The archive did not contain zigrep.exe / zgrep.exe."
        exit 1
    }
    # Keep the installer next to the binaries so the install tree is
    # self-contained (re-runnable to upgrade).
    $installerInZip = Join-Path $extractDir "install.ps1"
    if (Test-Path $installerInZip) {
        Copy-Item $installerInZip (Join-Path $InstallDir "install.ps1") -Force
    }
    Write-Ok "installed $installed executable(s) into $InstallDir"

    Install-ToPath
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
