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
    # The parameter NAMES are the public API (-Version, -InstallDir,
    # -BaseUrlOverride, -NoPathUpdate), but the VARIABLES behind them carry a
    # prefix on purpose.
    #
    # `irm ... | iex` evaluates this script in the CALLER's scope, and
    # PowerShell creates the parameter variables THERE. With plain names the
    # installer overwrote whatever the user had called `$Version` or
    # `$InstallDir` (and, worse, died with "Cannot overwrite the variable
    # InstallDir because it is optimized" when such a variable already existed
    # in an enclosing scope, aborting without installing anything). Prefixed
    # names leave the user's session alone.
    [Alias("Version")][string]$RequestedVersion = "latest",
    [Alias("InstallDir")][string]$RequestedInstallDir = "",
    # Override the download base URL (used by the test suite and useful for
    # corporate mirrors / proxies). Empty means the official GitHub releases.
    [Alias("BaseUrlOverride")][string]$RequestedBaseUrlOverride = "",
    # Skip the user PATH update (used by the test suite).
    [Alias("NoPathUpdate")][switch]$RequestedNoPathUpdate
)

$ErrorActionPreference = "Stop"
# Internal names, deliberately different from the parameter variables above.
$repoSlug = "DannyBaanks/ZiGrep"
$versionToUse = $RequestedVersion
$skipPathUpdate = [bool]$RequestedNoPathUpdate
$baseUrlToUse = $RequestedBaseUrlOverride

function Write-Step($msg) { Write-Host "==> $msg" -ForegroundColor Cyan }
function Write-Ok($msg) { Write-Host "OK  $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "WARN $msg" -ForegroundColor Yellow }
function Write-Err($msg) { Write-Host "ERR $msg" -ForegroundColor Red }

# Run a native command without letting its stderr abort the installer.
#
# $ErrorActionPreference = "Stop" turns a native command's stderr into a
# terminating NativeCommandError in Windows PowerShell. zigrep prints its
# version on stdout, but git prints "Cloning into ..." on stderr, so the
# installer used to die on a perfectly healthy install.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        [switch]$Capture
    )
    # Function scope: the caller's preference is not modified.
    $ErrorActionPreference = "Continue"
    if ($Capture) {
        $raw = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
        # A native command's stderr arrives as ErrorRecord objects; render
        # them as plain text instead of the "NativeCommandError" decoration.
        $parts = foreach ($item in $raw) {
            if ($item -is [System.Management.Automation.ErrorRecord]) { $item.ToString() }
            else { [string]$item }
        }
        return [pscustomobject]@{ Output = (($parts -join "`n")).Trim(); ExitCode = $code }
    }
    & $FilePath @Arguments
    return [pscustomobject]@{ Output = ""; ExitCode = $LASTEXITCODE }
}

# Defined before the first call: PowerShell resolves function names at
# runtime, not at parse time.
function Install-ToPath {
    if ($skipPathUpdate) {
        Write-Warn "PATH update skipped (-NoPathUpdate)"
        return
    }

    # Add the install directory to the USER PATH (no admin rights needed).
    $userPath = [Environment]::GetEnvironmentVariable("Path", "User")
    $parts = @()
    if ($userPath) { $parts = @($userPath -split ";" | Where-Object { $_ }) }

    if ($parts -notcontains $targetDir) {
        $newPath = (@($parts) + $targetDir) -join ";"
        [Environment]::SetEnvironmentVariable("Path", $newPath, "User")
        Write-Ok "added $targetDir to the user PATH"
        Write-Host ""
        Write-Host "  Restart your terminal (or open a new one) so the PATH change applies." -ForegroundColor Yellow
    } else {
        Write-Ok "$targetDir is already in the user PATH"
    }

    # Make it usable in this session too.
    if (($env:Path -split ";") -notcontains $targetDir) {
        $env:Path = "$env:Path;$targetDir"
    }

    Write-Host ""
    Write-Host "  Version check:" -ForegroundColor Cyan
    # Run the check through Invoke-Native: the binary may write on stderr and
    # that must not abort the installer.
    $check = Invoke-Native -FilePath (Join-Path $targetDir "zigrep.exe") -Arguments @("--version") -Capture
    if ($check.Output) { Write-Host "    $($check.Output)" }
    if ($check.ExitCode -ne 0) {
        Write-Warn "the version check returned exit code $($check.ExitCode)"
    }
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

# The parameters are only READ here: assigning to them is what used to abort
# the installer when `iex` had turned them into constants (see the note above).
$targetDir = if ($RequestedInstallDir) { $RequestedInstallDir } else { Join-Path $env:LOCALAPPDATA "Programs\ZiGrep" }

$AssetName = "zigrep-windows-$TargetArch.zip"

if ($baseUrlToUse) {
    $BaseUrl = $baseUrlToUse.TrimEnd("/")
} elseif ($versionToUse -eq "latest") {
    $BaseUrl = "https://github.com/$repoSlug/releases/latest/download"
} else {
    $tag = $versionToUse
    if (-not $tag.StartsWith("v")) { $tag = "v$versionToUse" }
    $BaseUrl = "https://github.com/$repoSlug/releases/download/$tag"
}
$DownloadUrl = "$BaseUrl/$AssetName"
$ChecksumsUrl = "$BaseUrl/SHA256SUMS.txt"

Write-Step "Architecture: $TargetArch"
Write-Step "Install directory: $targetDir"

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
            if ($versionToUse -eq "latest") {
                # Resolve the real latest tag through the GitHub API.
                try {
                    $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repoSlug/releases/latest" -Headers @{ "User-Agent" = "ZiGrep-Installer" }
                    $cloneRef = $rel.tag_name
                } catch {
                    Write-Warn "Could not resolve the latest release tag ($($_.Exception.Message))."
                }
            } else {
                $cloneRef = $versionToUse
                if (-not $cloneRef.StartsWith("v")) { $cloneRef = "v$versionToUse" }
            }
            if (-not $cloneRef) {
                Write-Err "Cannot determine which release to build from. Use -Version <tag>."
                exit 1
            }
            Write-Step "Cloning $repoSlug at $cloneRef and building..."
            $repoDir = Join-Path $tmp "repo"
            $clone = Invoke-Native -FilePath "git" -Arguments @("clone", "--depth", "1", "--branch", $cloneRef, "https://github.com/$repoSlug.git", $repoDir) -Capture
            if ($clone.ExitCode -ne 0) {
                Write-Err "git clone failed with exit code $($clone.ExitCode)"
                if ($clone.Output) { Write-Host $clone.Output -ForegroundColor DarkGray }
                exit 1
            }
            Push-Location $repoDir
            try {
                $build = Invoke-Native -FilePath "zig" -Arguments @("build", "-Doptimize=ReleaseFast") -Capture
            } finally {
                Pop-Location
            }
            if ($build.ExitCode -ne 0) {
                Write-Err "zig build failed with exit code $($build.ExitCode)"
                if ($build.Output) { Write-Host $build.Output -ForegroundColor DarkGray }
                exit 1
            }
            New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
            Copy-Item (Join-Path $repoDir "zig-out\bin\zigrep.exe") (Join-Path $targetDir "zigrep.exe") -Force
            Copy-Item (Join-Path $repoDir "zig-out\bin\zgrep.exe") (Join-Path $targetDir "zgrep.exe") -Force
            Install-ToPath
            exit 0
        } else {
            Write-Err "Zig is not installed. Install Zig 0.16+ from https://ziglang.org/download/"
            Write-Host "or download the binary manually from https://github.com/$repoSlug/releases"
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

    New-Item -ItemType Directory -Path $targetDir -Force | Out-Null
    $installed = 0
    foreach ($name in @("zigrep.exe", "zgrep.exe")) {
        $src = Join-Path $extractDir $name
        if (Test-Path $src) {
            Copy-Item $src (Join-Path $targetDir $name) -Force
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
        Copy-Item $installerInZip (Join-Path $targetDir "install.ps1") -Force
    }
    Write-Ok "installed $installed executable(s) into $targetDir"

    Install-ToPath
} finally {
    Remove-Item -Recurse -Force $tmp -ErrorAction SilentlyContinue
}
