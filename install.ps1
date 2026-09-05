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

# --- create env helpers ---
$EnvPs1 = Join-Path $InstallDir "env.ps1"
$EnvCmd = Join-Path $InstallDir "env.cmd"

$EnvPs1Content = @'
$BinDir = Join-Path $PSScriptRoot "bin"
if ($env:Path -split ';' -notcontains $BinDir) {
    $env:Path = "$BinDir;$env:Path"
}
'@
Set-Content -Path $EnvPs1 -Value $EnvPs1Content -Encoding UTF8

$EnvCmdContent = @'
@echo off
set "PATH=%~dp0bin;%PATH%"
'@
Set-Content -Path $EnvCmd -Value $EnvCmdContent -Encoding ASCII

# --- PATH setup ---
$UserPath = [Environment]::GetEnvironmentVariable("Path", "User")
$UserEntries = if ($UserPath) { ($UserPath -split ';') | Where-Object { $_.Trim() -ne "" } } else { @() }

if ($UserEntries -notcontains $BinDir) {
    Say "Adding $BinDir to User PATH environment variable..."
    $NewUserPath = ($UserEntries + $BinDir) -join ';'
    [Environment]::SetEnvironmentVariable("Path", $NewUserPath, "User")

    # Broadcast WM_SETTINGCHANGE to notify running applications
    try {
        Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(
    System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
"@ -ErrorAction SilentlyContinue
        $HWND_BROADCAST = [System.IntPtr]0xffff
        $WM_SETTINGCHANGE = 0x001a
        $result = [System.UIntPtr]::Zero
        [Win32.NativeMethods]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE, [System.UIntPtr]::Zero, "Environment", 2, 5000, [ref]$result) | Out-Null
    } catch {
        # Non-critical if P/Invoke is not supported in current environment
    }
}

# Ensure current session has $BinDir in PATH
$CurrentEntries = ($env:Path -split ';') | Where-Object { $_.Trim() -ne "" }
if ($CurrentEntries -notcontains $BinDir) {
    $env:Path = "$BinDir;$env:Path"
}

Say ""
Say "================================================="
Say "  Eiwa $CleanVersion installed successfully!     "
Say "================================================="
Say ""
Say "Eiwa is ready to use in this PowerShell session!"
Say "  eiwa --help"
Say "  eiwa init my-app"
Say "  cd my-app && eiwa run"
Say ""
Say "For other already open terminals (CMD, VS Code, Git Bash):"
Say "  PowerShell:  . ~\.eiwa\env.ps1"
Say "  CMD:         %USERPROFILE%\.eiwa\env.cmd"
Say "  Or restart the terminal to reload environment variables."
Say ""
Warn "Note: 'eiwac' links LLVM and C libraries on Windows."
Warn "If needed, install LLVM via winget: winget install LLVM.LLVM"
