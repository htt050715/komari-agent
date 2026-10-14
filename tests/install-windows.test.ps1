# Exercise the installer functions with fake downloads and services; never install a real service.
param([string]$ScratchRoot = (Join-Path $PSScriptRoot '../work/install-tests'))
$ErrorActionPreference = 'Stop'
$installer = Join-Path $PSScriptRoot '../install.ps1'
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count) { throw ($parseErrors | Out-String) }
foreach ($fn in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Read-Host { param($Prompt) return $script:Answer }
function Invoke-WebRequest {
    param($Uri, $OutFile, [switch]$UseBasicParsing, $ErrorAction)
    $script:Calls.Add('download')
    if ($script:FailDownload) { throw 'Simulated download failure' }
    [IO.File]::WriteAllText($OutFile, 'new-agent')
}
function Invoke-Nssm {
    param([string[]]$NssmArgs)
    $script:Calls.Add('nssm:' + $NssmArgs[0])
    if ($NssmArgs[0] -eq 'set' -and $NssmArgs[2] -eq 'AppParameters') {
        $script:ServiceArgs = $NssmArgs[3]
    }
}
function Stop-Service {
    param($Name, $ErrorAction)
    $script:Calls.Add('stop')
    $script:FakeService.Status = 'Stopped'
}
function Start-Service {
    param($Name, $ErrorAction)
    $script:Calls.Add('start')
    if ($script:FailStart) { $script:FailStart = $false; throw 'Simulated start failure' }
    $script:FakeService.Status = 'Running'
}
function Get-Service { param($Name) return $script:FakeService }
function Reset-Scenario([bool]$Existing = $true) {
    $script:InstallDir = Join-Path $ScratchRoot ([guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $script:InstallDir -Force | Out-Null
    $script:AgentPath = Join-Path $script:InstallDir 'komari-agent.exe'
    $script:ConfigPath = Join-Path $script:InstallDir 'config.json'
    [IO.File]::WriteAllText($script:ConfigPath, '{"token":"test-credential"}')
    $script:FakeService = [pscustomobject]@{ Status = 'Running' }
    $script:FakeService | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value {
        param($status, $timeout)
        if ($this.Status -ne $status) { throw 'Unexpected service status' }
    }
    $script:ExistingService = if ($Existing) { $script:FakeService } else { $null }
    $script:ExistingParameters = if ($Existing) { [pscustomobject]@{ AppParameters = '--token test-original' } } else { $null }
    $script:ServiceArgs = '--token test-original'
    $script:ServiceName = 'komari-test'
    $script:DownloadUrl = 'https://example.invalid/agent.exe'
    $script:KomariArgs = @()
    $script:Calls = [Collections.Generic.List[string]]::new()
    $script:FailDownload = $false
    $script:FailStart = $false
    if ($Existing) { [IO.File]::WriteAllText($script:AgentPath, 'old-agent') }
}

Assert (Confirm-ExistingInstall -Exists $false -Action '') 'Fresh install should proceed.'
$script:Answer = ''
Assert (-not (Confirm-ExistingInstall -Exists $true -Action '')) 'Empty choice must cancel.'
$script:Answer = '1'
Assert (Confirm-ExistingInstall -Exists $true -Action '') 'Choice 1 must overwrite.'
Assert (-not (Confirm-ExistingInstall -Exists $true -Action 'cancel')) 'Explicit cancellation failed.'
Assert (Confirm-ExistingInstall -Exists $true -Action 'overwrite') 'Explicit overwrite failed.'

Reset-Scenario
$script:FailDownload = $true
$failed = $false
try { Install-Agent } catch { $failed = $true }
Assert $failed 'Failed download must fail the installation.'
Assert ($script:Calls -notcontains 'stop') 'Download failure stopped the old service.'
Assert ([IO.File]::ReadAllText($AgentPath) -eq 'old-agent') 'Download failure replaced the old binary.'

Reset-Scenario
Install-Agent
Assert ([IO.File]::ReadAllText($AgentPath) -eq 'new-agent') 'Upgrade did not install the new binary.'
Assert ($ServiceArgs -eq '--token test-original') 'Upgrade lost the original service arguments.'
Assert ($Calls -notcontains 'nssm:remove' -and $Calls -notcontains 'nssm:install') 'Upgrade recreated the existing service.'
Assert ([IO.File]::ReadAllText($ConfigPath) -eq '{"token":"test-credential"}') 'Upgrade changed the config.'
$backups = @(Get-ChildItem -LiteralPath $InstallDir -Filter '*.backup-*')
Assert ($backups.Count -eq 1 -and [IO.File]::ReadAllText($backups[0].FullName) -eq 'old-agent') 'Old binary was not backed up.'

Reset-Scenario
$script:KomariArgs = @('--token', 'replacement with spaces')
$script:FailStart = $true
$failed = $false
try { Install-Agent } catch { $failed = $true }
Assert $failed 'Start failure must fail the installation.'
Assert ([IO.File]::ReadAllText($AgentPath) -eq 'old-agent') 'Rollback did not restore the binary.'
Assert ($ServiceArgs -eq '--token test-original') 'Rollback did not restore the arguments.'
Assert ($FakeService.Status -eq 'Running') 'Rollback did not restart the old service.'

Reset-Scenario -Existing $false
$script:KomariArgs = @('--token', 'new token with spaces')
Install-Agent
Assert ($Calls -contains 'nssm:install') 'Fresh install did not register a service.'
Assert ($ServiceArgs -eq '--token "new token with spaces"') 'Fresh install corrupted argument quoting.'

Reset-Scenario -Existing $false
$script:FailStart = $true
$failed = $false
try { Install-Agent } catch { $failed = $true }
Assert $failed 'Failed fresh start must fail the installation.'
Assert (-not (Test-Path -LiteralPath $AgentPath)) 'Failed fresh install left a binary behind.'
Assert ($Calls -contains 'nssm:remove') 'Failed fresh install left a service behind.'
Write-Host 'PASS: installer parsing, choices, download failure, upgrade, rollback and fresh installation.'
