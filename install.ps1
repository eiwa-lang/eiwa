# Eiwa Windows Installer — `irm https://eiwa.dev/install.ps1 | iex`
#
# Downloads the latest Eiwa release from GitHub Releases and installs it to
# $HOME\.eiwa (override with EIWA_INSTALL_DIR), adding $HOME\.eiwa\bin to your User PATH.

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13

$Repo = "eiwa-lang/eiwa"
$BaseUrl = "https://github.com/$Repo/releases/download"
$ApiUrl = "https://api.github.com/repos/$Repo/releases/latest"

function Say($msg) { Write-Host $msg -ForegroundColor Green }
function Warn($msg) { Write-Host $msg -ForegroundColor Yellow }
function Die($msg) { Write-Host $msg -ForegroundColor Red; exit 1 }

# --- detect architecture ---
$Arch = $env:PROCESSOR_ARCHITECTURE
switch -Regex ($Arch) {
    'AMD64|x86_64|x64' { $ArchTriple = 'x86_64' }
    'ARM64|aarch64'    { $ArchTriple = 'arm64' }
    Default            { Die "Eiwa installer: unsupported Windows architecture '$Arch'" }
}
$OsTriple = "windows"

# --- resolve version ---
$Version = $env:EIWA_VERSION
if (-not $Version) {
    Say "Resolving latest Eiwa release..."
    try {
        $ReleaseJson = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing -Headers @{ "User-Agent" = "Eiwa-Installer" }
        $Version = $ReleaseJson.tag_name
    } catch {
        Die "Eiwa installer: could not resolve the latest release from GitHub API: $_"
    }
}
if (-not $Version) {
    Die "Eiwa installer: could not determine version to install."
}

$CleanVersion = $Version -replace '^v',''
Say "Installing Eiwa $CleanVersion ($OsTriple-$ArchTriple)..."

# --- install locations ---
$InstallDir = if ($env:EIWA_INSTALL_DIR) { $env:EIWA_INSTALL_DIR } else { Join-Path $HOME ".eiwa" }
$BinDir = Join-Path $InstallDir "bin"

if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}
if (-not (Test-Path $BinDir)) {
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
}

# --- download + verify ---
$ZipName = "eiwa-$CleanVersion-$OsTriple-$ArchTriple.zip"
$TarName = "eiwa-$CleanVersion-$OsTriple-$ArchTriple.tar.gz"
$DownloadUrl = "$BaseUrl/$Version/$ZipName"
$IsZip = $true

$TempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("eiwa-install-" + [System.Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $TempDir -Force | Out-Null

try {
    $ArchiveFile = Join-Path $TempDir $ZipName
    Say "Downloading $DownloadUrl..."
    try {
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchiveFile -UseBasicParsing
    } catch {
        # Fallback to tar.gz if zip is not present
        $IsZip = $false
        $DownloadUrl = "$BaseUrl/$Version/$TarName"
        $ArchiveFile = Join-Path $TempDir $TarName
        Say "Retrying download with $DownloadUrl..."
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $ArchiveFile -UseBasicParsing
    }

    # Verify sha256 checksum if available
    try {
        $ShaUrl = "$DownloadUrl.sha256"
        $ShaFile = "$ArchiveFile.sha256"
        Invoke-WebRequest -Uri $ShaUrl -OutFile $ShaFile -UseBasicParsing
        $ExpectedHash = (Get-Content $ShaFile).Trim().Split()[0].ToLower()
        $ActualHash = (Get-FileHash -Path $ArchiveFile -Algorithm SHA256).Hash.ToLower()
        if ($ExpectedHash -ne $ActualHash) {
            Die "Eiwa installer: checksum verification failed for $ArchiveFile"
        }
        Say "Checksum verified successfully."
    } catch {
        # Optional checksum skip if remote .sha256 is not published
    }

    # --- extract ---
    Say "Extracting Eiwa to $InstallDir..."
    if ($IsZip) {
        Expand-Archive -Path $ArchiveFile -DestinationPath $TempDir -Force
    } else {
        tar -xzf $ArchiveFile -C $TempDir
    }

    # Locate extracted payload directory
    $ExtractedDir = Get-ChildItem -Path $TempDir -Directory | Where-Object { $_.Name -like "eiwa-*" } | Select-Object -First 1
    $SourceDir = if ($ExtractedDir) { $ExtractedDir.FullName } else { $TempDir }

    # Copy files to $InstallDir
    Copy-Item -Path "$SourceDir\*" -Destination $InstallDir -Recurse -Force

} finally {
    Remove-Item -Path $TempDir -Recurse -Force -ErrorAction SilentlyContinue
}

# --- PATH setup ---
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
if ($UserPath -split ';' -notcontains $BinDir) {
    Say "Adding $BinDir to User PATH environment variable..."
    $NewUserPath = if ($UserPath) { "$UserPath;$BinDir" } else { $BinDir }
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")
    $env:Path = "$env:Path;$BinDir"
    Warn "Added $BinDir to PATH. Restart your terminal or editor to refresh environment variables."
} else {
    $env:Path = "$env:Path;$BinDir"
}

Say ""
Say "================================================="
Say "  Eiwa $CleanVersion installed successfully!     "
Say "================================================="
Say ""
Say "To get started:"
Say "  eiwa --help"
Say "  eiwa init my-app"
Say "  cd my-app && eiwa run"
Say ""
Warn "Note: 'eiwac' links LLVM and C libraries on Windows."
Warn "If needed, ensure LLVM/Clang or MSVC Build Tools are installed."
