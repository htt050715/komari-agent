# Test the packaged launcher without elevation, networking, or real service changes.
$ErrorActionPreference = 'Stop'
$GitHubProxy = 'https://ghproxy.05160715.xyz'
$root = Split-Path $PSScriptRoot -Parent
& (Join-Path $root 'build-one-click.ps1')
$source = [IO.File]::ReadAllText((Join-Path $root 'install-one-click.ps1'))
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
$launcher = [IO.File]::ReadAllText((Join-Path $root 'install-komari.cmd'))
$marker = '# KOMARI_POWERSHELL_BEGIN'
$payload = $launcher.Substring($launcher.LastIndexOf($marker) + $marker.Length)
Assert ($payload.Replace("`r`n", "`n").Trim() -eq $source.Replace("`r`n", "`n").Trim()) 'Packaged PowerShell differs from source.'
[void][Management.Automation.Language.Parser]::ParseInput($payload, [ref]$tokens, [ref]$errors)
Assert ($errors.Count -eq 0) 'Packaged script does not parse.'
Assert ($launcher.Contains('set "KOMARI_LAUNCHER_PATH=%~f0"')) 'Launcher lost safe self-path handling.'
Assert ($launcher.Contains('[Text.UTF8Encoding]::new($true)')) 'Temporary PS1 must have a UTF-8 BOM for PowerShell 5.1.'

function Read-Host {
    param($Prompt, [switch]$AsSecureString)
    if ($AsSecureString) { return ConvertTo-SecureString 'test-token with spaces' -AsPlainText -Force }
    if ($script:Answers.Count -gt 0) { return $script:Answers.Dequeue() }
    return ''
}
function Answers([string[]]$values) { $script:Answers = [Collections.Generic.Queue[string]]::new(); foreach ($value in $values) { $script:Answers.Enqueue($value) } }
Answers @('')
Assert ((Get-InstallChoice $true) -eq 'cancel') 'Blank choice must cancel.'
Answers @('1')
Assert ((Get-InstallChoice $true) -eq 'overwrite') 'Choice 1 must overwrite.'
Assert ((Get-InstallChoice $false) -eq 'install') 'Fresh install must prompt for credentials.'
Answers @('not a URL', 'https://monitor.example.com')
$connection = Read-AgentConnection
Assert ($connection.Count -eq 4 -and $connection[1] -eq 'https://monitor.example.com' -and $connection[3] -eq 'test-token with spaces') 'Connection prompting or Token quoting failed.'

$initialInstallerSource = '$global:OneClickTestArgs = $args; exit 0'
$digest = [Security.Cryptography.SHA256]::Create()
try { $hash = [BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($initialInstallerSource))).Replace('-', '').ToLowerInvariant() }
finally { $digest.Dispose() }
$script:Release = [pscustomobject]@{
    tag_name = '1.5.12'; draft = $false; prerelease = $false
    assets = @([pscustomobject]@{
        name = 'install.ps1'; digest = "sha256:$hash"
        browser_download_url = 'https://github.com/htt050715/komari-agent/releases/download/1.5.12/install.ps1'
    })
}
Assert ((Get-InstallerAsset $Release).name -eq 'install.ps1') 'Valid installer was rejected.'
$Release.assets[0].browser_download_url = 'https://example.com/install.ps1'
$rejected = $false
try { Get-InstallerAsset $Release | Out-Null } catch { $rejected = $true }
Assert $rejected 'An unexpected download host was accepted.'
$Release.assets[0].browser_download_url = 'https://github.com/htt050715/komari-agent/releases/download/1.5.12/install.ps1'

function Get-Service { param($Name, $ErrorAction) return $script:ExistingService }
function Get-WithRetry {
    param($Url, $Destination, $ExpectedDigest)
    $script:DownloadCalls++
    if ($Destination) { [IO.File]::WriteAllText($Destination, $script:FakeInstaller, [Text.UTF8Encoding]::new($false)); return }
    return $script:Release
}
$script:FakeInstaller = $initialInstallerSource
$script:DownloadCalls = 0
$script:ExistingService = [pscustomobject]@{ Name = 'komari-agent' }
Answers @('2')
Assert ((Invoke-SelectedInstall) -eq 0) 'Cancellation returned failure.'
Assert ($DownloadCalls -eq 0) 'Cancellation downloaded files.'

Answers @('1')
$global:OneClickTestArgs = $null
Assert ((Invoke-SelectedInstall) -eq 0) 'Upgrade returned failure.'
Assert ($OneClickTestArgs -notcontains '--token') 'Upgrade should preserve existing parameters.'
Assert ($OneClickTestArgs -contains '--install-ghproxy' -and $OneClickTestArgs -contains $GitHubProxy) 'Upgrade did not pass the proxy to the installer.'
Assert ($OneClickTestArgs -contains 'overwrite' -and $OneClickTestArgs -contains '1.5.12') 'Upgrade lost overwrite choice or pinned release version.'

Answers @('1')
$Release.assets[0].digest = 'sha256:' + ('0' * 64)
$global:OneClickTestArgs = $null
$rejected = $false
try { Invoke-SelectedInstall | Out-Null } catch { $rejected = $true }
Assert ($rejected -and $null -eq $OneClickTestArgs) 'Digest mismatch executed the installer.'
$Release.assets[0].digest = "sha256:$hash"

Answers @('1')
$script:FakeInstaller = '$global:OneClickTestArgs = $args; exit 7'
$digest = [Security.Cryptography.SHA256]::Create()
try { $failedHash = [BitConverter]::ToString($digest.ComputeHash([Text.Encoding]::UTF8.GetBytes($script:FakeInstaller))).Replace('-', '').ToLowerInvariant() }
finally { $digest.Dispose() }
$Release.assets[0].digest = "sha256:$failedHash"
$rejected = $false
try { Invoke-SelectedInstall | Out-Null } catch { $rejected = $true }
Assert $rejected 'Installer failure was reported as success.'
$script:FakeInstaller = $initialInstallerSource
$Release.assets[0].digest = "sha256:$hash"

$script:ExistingService = $null
# Handle both a clean machine and one where the default directory already exists.
Answers @('1', 'https://monitor.example.com')
# Avoid depending on the real ProgramFiles directory in the fresh-install test.
function Read-AgentConnection { return @('--endpoint', 'https://monitor.example.com', '--token', 'test-token with spaces') }
$global:OneClickTestArgs = $null
Assert ((Invoke-SelectedInstall) -eq 0) 'Fresh installation returned failure.'
$tokenIndex = [Array]::IndexOf($OneClickTestArgs, '--token')
Assert ($tokenIndex -ge 0 -and $OneClickTestArgs[$tokenIndex + 1] -eq 'test-token with spaces') 'Fresh installation corrupted the Token.'
Remove-Variable -Name OneClickTestArgs -Scope Global -ErrorAction SilentlyContinue
Write-Host 'PASS: standalone packaging, choices, connection input, release validation, cancellation, upgrade, hash rejection and fresh install.'
