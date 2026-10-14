# Windows PowerShell installation script for Komari Agent

$ErrorActionPreference = 'Stop'

# Logging functions with colors
function Log-Info { param([string]$Message) Write-Host "$Message"    -ForegroundColor Cyan }
function Log-Success { param([string]$Message) Write-Host "$Message"    -ForegroundColor Green }
function Log-Warning { param([string]$Message) Write-Host "[WARNING] $Message"    -ForegroundColor Yellow }
function Log-Error { param([string]$Message) Write-Host "[ERROR] $Message"    -ForegroundColor Red }
function Log-Step { param([string]$Message) Write-Host "$Message"    -ForegroundColor Magenta }
function Log-Config { param([string]$Message) Write-Host "- $Message"    -ForegroundColor White }

# Default parameters
$InstallDir = Join-Path $Env:ProgramFiles "Komari"
$ServiceName = "komari-agent"
$GitHubProxy = ""
$KomariArgs = @()
$InstallVersion = ""
$ExistingInstallAction = ""
$InstallDirExplicit = $false

# Parse script arguments
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        "--install-dir" { $InstallDir = $args[$i + 1]; $InstallDirExplicit = $true; $i++; continue }
        "--install-service-name" { $ServiceName = $args[$i + 1]; $i++; continue }
        "--install-ghproxy" { $GitHubProxy = $args[$i + 1]; $i++; continue }
        "--install-version" { $InstallVersion = $args[$i + 1]; $i++; continue }
        "--install-existing" { $ExistingInstallAction = $args[$i + 1]; $i++; continue }
        Default { $KomariArgs += $args[$i] }
    }
}

function Confirm-ExistingInstall {
    param([bool]$Exists, [string]$Action)
    if ($Action -and $Action -notin @('overwrite', 'cancel')) {
        throw '--install-existing must be overwrite or cancel.'
    }
    if (-not $Exists) { return $true }
    if ($Action) { return $Action -eq 'overwrite' }
    Log-Warning 'An existing Komari directory or service was found.'
    Write-Host '[1] Overwrite / upgrade (back up the binary and keep configuration)'
    Write-Host '[2] Cancel (default)'
    return (Read-Host 'Choose 1 or 2') -eq '1'
}

# Quote a value the way the Windows C runtime command-line parser expects,
# so arguments survive command-line re-quoting boundaries (Start-Process
# -ArgumentList, powershell -File, cmd /c, ...) even when they contain
# spaces such as C:\Users\John Doe\... (komari-monitor/komari#655).
function ConvertTo-CommandLineArg {
    param([Parameter(Mandatory = $true)][AllowEmptyString()][string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    $escaped = $Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1'
    return '"' + $escaped + '"'
}

# Ensure running as Administrator. Instead of failing, re-launch this script
# elevated and re-quote its own arguments: wrappers that elevate externally
# (Start-Process and friends) regularly split arguments of paths containing
# spaces, which breaks installs for user names with spaces (komari#655).
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltinRole]::Administrator)) {
    if ([string]::IsNullOrEmpty($PSCommandPath)) {
        Log-Error "Cannot elevate a script that was not run from a file. Save it as install.ps1 and run it again as Administrator."
        exit 1
    }
    Log-Warning "Administrator privileges are required. Requesting elevation, please accept the UAC prompt..."
    $hostExe = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $relaunchArgs = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', (ConvertTo-CommandLineArg $PSCommandPath))
    foreach ($a in $args) {
        $relaunchArgs += ConvertTo-CommandLineArg ([string]$a)
    }
    try {
        $elevated = Start-Process -FilePath $hostExe -Verb RunAs -Wait -PassThru -ArgumentList ($relaunchArgs -join ' ')
        exit $elevated.ExitCode
    }
    catch {
        Log-Error "Elevation failed or was cancelled: $_"
        Log-Error "Please run this script as Administrator."
        exit 1
    }
}

# Detect the existing installation before downloading or changing any files.
$ExistingService = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
$ExistingParameters = $null
if ($ExistingService) {
    $ExistingParameters = Get-ItemProperty -LiteralPath "HKLM:\SYSTEM\CurrentControlSet\Services\$ServiceName\Parameters" -ErrorAction SilentlyContinue
    if (-not $ExistingParameters -or -not $ExistingParameters.Application) {
        Log-Error 'The existing service is not an NSSM-managed Komari installation. No changes made.'
        exit 1
    }
    $ExistingApplication = [Environment]::ExpandEnvironmentVariables($ExistingParameters.Application).Trim('"')
    $ExistingDirectory = Split-Path -Path $ExistingApplication -Parent
    if (-not $InstallDirExplicit) {
        $InstallDir = $ExistingDirectory
    } elseif ([IO.Path]::GetFullPath($InstallDir).TrimEnd('\') -ne [IO.Path]::GetFullPath($ExistingDirectory).TrimEnd('\')) {
        Log-Error 'The service is installed in a different directory. Use its existing directory to upgrade, or another service name for a separate installation.'
        exit 1
    }
}
if (-not (Confirm-ExistingInstall -Exists ([bool]($ExistingService -or (Test-Path -LiteralPath $InstallDir))) -Action $ExistingInstallAction)) {
    Log-Info 'Installation cancelled. Existing files and service were left untouched.'
    exit 0
}

# Prepare GitHub proxy display
if ($GitHubProxy -ne '') { $ProxyDisplay = $GitHubProxy } else { $ProxyDisplay = '(direct)' }

# Detect architecture early for constructing binary name
switch ($env:PROCESSOR_ARCHITECTURE) {
    'AMD64' { $arch = 'amd64' }
    'ARM64' { $arch = 'arm64' }
    'x86' { $arch = '386' }
    Default { Log-Error "Unsupported architecture: $env:PROCESSOR_ARCHITECTURE"; exit 1 }
}

# Ensure installation directory exists for nssm and agent
Log-Step "Ensuring installation directory exists: $InstallDir"
New-Item -ItemType Directory -Path $InstallDir -Force -ErrorAction SilentlyContinue | Out-Null # Ensure $InstallDir exists

# Check for nssm and download if not present
$nssmExeToUse = Join-Path $InstallDir "nssm.exe"

# First, check if nssm is in PATH and is functional
$nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
if ($nssmCmd) {
    Log-Info "nssm found in PATH at $($nssmCmd.Source)."
    try {
        $nssmVersionOutput = nssm version 2>&1
        Log-Info "Detected nssm version: $nssmVersionOutput"
    }
    catch {
        Log-Warning "nssm found in PATH failed to execute 'nssm version'. Will attempt to use/download local copy. Error: $_"
        $nssmCmd = $null # Force re-evaluation for local copy or download
    }
}

# If nssm not found in PATH or the one in PATH failed, check local $InstallDir
if (-not $nssmCmd) {
    if (Test-Path $nssmExeToUse) {
        Log-Info "nssm found at $nssmExeToUse. Attempting to use it by adding $InstallDir to PATH."
        $env:Path = "$($InstallDir);$($env:Path)"
        $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue
        if ($nssmCmd) {
            try {
                $nssmVersionOutput = nssm version 2>&1
            }
            catch {
                Log-Warning "nssm from $InstallDir failed to execute 'nssm version'. Error: $_"
                $nssmCmd = $null # Mark as unusable
            }
        }
        else {
            Log-Warning "Failed to make nssm from $nssmExeToUse available via PATH. Will attempt download."
        }
    }
}

# If still no usable nssm command, proceed to download
if (-not $nssmCmd) {
    Log-Info "nssm not found or not usable. Attempting to download to $InstallDir..."
    $NssmVersion = "2.24"
    $NssmZipUrl = "https://nssm.cc/release/nssm-$NssmVersion.zip"
    $TempNssmZipPath = Join-Path $env:TEMP "nssm-$NssmVersion.zip"
    $TempExtractDir = Join-Path $env:TEMP "nssm_extract_temp"

    try {
        Log-Info "Downloading nssm from $NssmZipUrl..."
        Invoke-WebRequest -Uri $NssmZipUrl -OutFile $TempNssmZipPath -UseBasicParsing

        if (Test-Path $TempExtractDir) { Remove-Item -Recurse -Force $TempExtractDir }
        New-Item -ItemType Directory -Path $TempExtractDir -Force | Out-Null
        Expand-Archive -Path $TempNssmZipPath -DestinationPath $TempExtractDir -Force
        
        $NssmSourceDirInsideZip = "nssm-$NssmVersion" # Used for Get-ChildItem search path
        # The path part within the extracted nssm folder, e.g., "nssm-2.24\win32"
        # 'win32' nssm is used for both 'amd64' and 'arm64' PowerShell architectures.
        $NssmArchSubDir = Join-Path "nssm-$NssmVersion" "win32"
        $NssmSourceExePath = Join-Path (Join-Path $TempExtractDir $NssmArchSubDir) "nssm.exe"

        if (-not (Test-Path $NssmSourceExePath)) {
            Log-Error "Could not find nssm.exe at expected path: $NssmSourceExePath after extraction."
            # Fallback search for nssm.exe within the extracted directory
            $foundNssmFallback = Get-ChildItem -Path $TempExtractDir -Recurse -Filter "nssm.exe" | 
            Where-Object { $_.FullName -like "*$NssmArchSubDir\nssm.exe" } | 
            Select-Object -First 1
            if ($foundNssmFallback) {
                Log-Warning "Found nssm.exe at $($foundNssmFallback.FullName) using fallback search. Using this."
                $NssmSourceExePath = $foundNssmFallback.FullName
            }
            else {
                Log-Error "nssm.exe ($NssmArchSubDir) still not found in $TempExtractDir. Please install nssm manually (from https://nssm.cc) and ensure it's in your PATH."
                exit 1
            }
        }
        
        Copy-Item -Path $NssmSourceExePath -Destination $nssmExeToUse -Force

        $env:Path = "$($InstallDir);$($env:Path)"
        $nssmCmd = Get-Command nssm -ErrorAction SilentlyContinue # Re-check after adding to PATH
        if ($nssmCmd) {
            Log-Success "Downloaded nssm is now configured and available in PATH."
        }
        else {
            Log-Error "Failed to configure downloaded nssm in PATH from $nssmExeToUse. Please ensure $InstallDir is in your system PATH or nssm is installed globally."
            exit 1
        }
    }
    catch {
        Log-Error "Failed to download or configure nssm: $_"
        Log-Error "Please install nssm manually from https://nssm.cc and ensure nssm.exe is in your PATH."
        exit 1
    }
    finally {
        if (Test-Path $TempNssmZipPath) { Remove-Item $TempNssmZipPath -Force -ErrorAction SilentlyContinue }
        if (Test-Path $TempExtractDir) { Remove-Item $TempExtractDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

# Final check that nssm is operational
try {
    $nssmVersionOutput = nssm version 2>&1
}
catch {
    Log-Error "nssm command failed to execute even after setup attempts. Please check the nssm installation and PATH. Error: $_"
    exit 1
}

Log-Step "Installation configuration:"
Log-Config "Service name: $ServiceName"
Log-Config "Install directory: $InstallDir"
Log-Config "GitHub proxy: $ProxyDisplay"
Log-Config "Agent arguments: supplied values are hidden to protect credentials"
if ($InstallVersion -ne "") {
    Log-Config "Specified agent version: $InstallVersion"
} else {
    Log-Config "Agent version: Latest"
}

# Paths
$BinaryName = "komari-agent-windows-$arch.exe"
$AgentPath = Join-Path $InstallDir "komari-agent.exe"
if ($ExistingService) { $AgentPath = $ExistingApplication }

function Get-LatestSnapshotVersion {
    param([Parameter(Mandatory = $true)][string]$AssetName)

    $ApiUrl = "https://api.github.com/repos/htt050715/komari-agent/releases?per_page=100"
    $ApiUrls = @($ApiUrl)
    if ($GitHubProxy -ne "") {
        $ApiUrls = @("$GitHubProxy/$ApiUrl", $ApiUrl)
    }

    for ($i = 0; $i -lt $ApiUrls.Count; $i++) {
        try {
            Log-Info "Fetching snapshot releases from GitHub API..."
            $releases = Invoke-RestMethod -Uri $ApiUrls[$i] -UseBasicParsing
        }
        catch {
            $releases = $null
        }

        if ($releases) {
            $latestSnapshot = $releases |
            Where-Object {
                $_.draft -eq $false -and
                $_.prerelease -eq $true -and
                $_.tag_name -like "Snapshot-*" -and
                (@($_.assets.name) -contains $AssetName)
            } |
            Sort-Object -Property @{ Expression = { [datetime]$_.published_at }; Descending = $true }, @{ Expression = { $_.tag_name }; Descending = $true } |
            Select-Object -First 1

            if ($latestSnapshot) {
                return $latestSnapshot.tag_name
            }
        }

        if ($i -lt ($ApiUrls.Count - 1)) {
            Log-Warning "Failed to resolve snapshot releases through GitHub proxy, retrying directly."
        }
    }

    throw "No snapshot release contains asset $AssetName."
}

$versionToInstall = ""
if ($InstallVersion -ne "") {
    Log-Info "Attempting to install specified version: $InstallVersion"
    if ($InstallVersion -ieq "snapshot") {
        Log-Info "Resolving the latest snapshot version..."
        try {
            $versionToInstall = Get-LatestSnapshotVersion -AssetName $BinaryName
            Log-Success "Latest snapshot version fetched: $versionToInstall"
        }
        catch {
            Log-Error "Failed to resolve the latest snapshot version: $_"
            exit 1
        }
    }
    else {
        $versionToInstall = $InstallVersion
    }
}
else {
    $ApiUrl = "https://api.github.com/repos/htt050715/komari-agent/releases/latest"
    try {
        Log-Step "Fetching latest release version from GitHub API..."
        $release = Invoke-RestMethod -Uri $ApiUrl -UseBasicParsing
        $versionToInstall = $release.tag_name
        Log-Success "Latest version fetched: $versionToInstall"
    }
    catch {
        Log-Error "Failed to fetch latest version: $_"
        exit 1
    }
}
Log-Success "Installing Komari Agent version: $versionToInstall"

# Construct download URL
$BinaryName = "komari-agent-windows-$arch.exe"
$DownloadUrl = if ($GitHubProxy) { "$GitHubProxy/https://github.com/htt050715/komari-agent/releases/download/$versionToInstall/$BinaryName" } else { "https://github.com/htt050715/komari-agent/releases/download/$versionToInstall/$BinaryName" }

function Invoke-Nssm {
    param([string[]]$NssmArgs)
    $null = & $nssmCmd.Source @NssmArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "NSSM $($NssmArgs[0]) failed (exit $LASTEXITCODE)." }
}

function Install-Agent {
    $downloadPath = Join-Path $InstallDir ('.komari-download-' + [guid]::NewGuid().ToString('N') + '.exe')
    $backupPath = $null
    $serviceTouched = $false
    $binaryTouched = $false
    $newServiceCreated = $false
    $wasRunning = $ExistingService -and $ExistingService.Status -ne 'Stopped'
    $oldArgs = if ($ExistingParameters) { [string]$ExistingParameters.AppParameters } else { '' }
    try {
        # Keep the old agent running until the download is complete.
        Log-Info "Downloading from $DownloadUrl"
        Invoke-WebRequest -Uri $DownloadUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
        if ((Get-Item -LiteralPath $downloadPath).Length -eq 0) { throw 'Downloaded binary is empty.' }
        if (Test-Path -LiteralPath $AgentPath) {
            $backupPath = "$AgentPath.backup-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$([guid]::NewGuid().ToString('N'))"
            Copy-Item -LiteralPath $AgentPath -Destination $backupPath -ErrorAction Stop
            Log-Info "Previous binary backed up to $backupPath"
        }
        if ($ExistingService) {
            $serviceTouched = $true
            Stop-Service -Name $ServiceName -ErrorAction Stop
            (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
        }
        $binaryTouched = $true
        Copy-Item -LiteralPath $downloadPath -Destination $AgentPath -Force -ErrorAction Stop
        $argString = ($KomariArgs | ForEach-Object { ConvertTo-CommandLineArg ([string]$_) }) -join ' '
        if ($ExistingService) {
            # Leave the service identity, account, working directory and environment intact.
            if ($KomariArgs.Count -gt 0) {
                Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppParameters', $argString)
            }
        } else {
            Invoke-Nssm -NssmArgs @('install', $ServiceName, $AgentPath)
            $newServiceCreated = $true
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppParameters', $argString)
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppDirectory', $InstallDir)
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'DisplayName', 'Komari Agent Service')
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'Start', 'SERVICE_AUTO_START')
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppExit', 'Default', 'Restart')
            Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppRestartDelay', '5000')
        }
        Start-Service -Name $ServiceName -ErrorAction Stop
        (Get-Service -Name $ServiceName).WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
    } catch {
        $installError = $_
        Log-Warning 'Installation failed. Restoring the previous installation...'
        try {
            if ($serviceTouched -or $newServiceCreated) {
                Stop-Service -Name $ServiceName -ErrorAction Stop
                (Get-Service -Name $ServiceName).WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
            }
            if ($binaryTouched) {
                if ($backupPath) {
                    Copy-Item -LiteralPath $backupPath -Destination $AgentPath -Force -ErrorAction Stop
                } elseif (Test-Path -LiteralPath $AgentPath) {
                    Remove-Item -LiteralPath $AgentPath -Force -ErrorAction Stop
                }
            }
            if ($newServiceCreated) {
                Invoke-Nssm -NssmArgs @('remove', $ServiceName, 'confirm')
            } elseif ($serviceTouched) {
                if ($KomariArgs.Count -gt 0) {
                    Invoke-Nssm -NssmArgs @('set', $ServiceName, 'AppParameters', $oldArgs)
                }
                if ($wasRunning) { Start-Service -Name $ServiceName -ErrorAction Stop }
            }
        } catch {
            Log-Error "Automatic rollback failed: $_. Backup retained at $backupPath"
        }
        throw $installError
    } finally {
        if (Test-Path -LiteralPath $downloadPath) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }
}

try { Install-Agent } catch { Log-Error "Installation failed: $_"; exit 1 }
Log-Success "Service $ServiceName installed / upgraded and started."

Log-Success "Komari Agent installation completed!"
Log-Config "Service name: $ServiceName"
Log-Config "Existing configuration files were preserved. Windows login notifications are disabled by default."
