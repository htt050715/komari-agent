# No service changes: exercise stderr handling with a child PowerShell process.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$tokens = $null; $errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'install.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw ($errors | Out-String) }
foreach ($fn in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
    . ([scriptblock]::Create($fn.Extent.Text))
}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
Assert ((ConvertTo-CommandLineArg '') -eq '""') 'Empty native arguments must be quoted.'
Assert ((Get-FileHash -LiteralPath (Join-Path $root 'vendor-tools/nssm-2.24-101-g897c7ad.zip') -Algorithm SHA256).Hash -eq '99f5045fffbffb745d67fe3a065a953c4a3d9c253b868892d9b685b0ee7d07b8') 'Vendored NSSM archive is not the verified official ZIP.'
Assert ((Get-InstallArchitecture -ProcessArchitecture 'x86' -NativeArchitecture 'AMD64') -eq 'amd64') '32-bit PowerShell selected a 32-bit agent on x64 Windows.'
Assert ((Get-InstallArchitecture -ProcessArchitecture 'x86' -NativeArchitecture 'ARM64') -eq 'arm64') 'Emulated PowerShell selected the wrong ARM64 agent.'
Assert ((Get-InstallArchitecture -ProcessArchitecture 'x86' -NativeArchitecture '') -eq '386') 'Native x86 detection failed.'
$scratch = Join-Path $env:TEMP ('komari-nssm-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $scratch | Out-Null
try {
    $fixture = Join-Path $scratch 'native fixture.ps1'
    [IO.File]::WriteAllText($fixture, 'param([string]$Value, [int]$Code) [Console]::Out.WriteLine($Value); [Console]::Error.WriteLine("NSSM: The non-sucking service manager"); exit $Code')
    $value = 'argument with spaces and "quotes"'
    $result = Invoke-NssmProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -NssmArgs @('-NoProfile', '-File', $fixture, $value, '0')
    Assert ($result.ExitCode -eq 0 -and $result.Output.Trim() -eq $value -and $result.ErrorOutput.Contains('NSSM:')) 'Native stderr or argument quoting caused failure.'
    $result = Invoke-NssmProcess -FilePath (Join-Path $PSHOME 'powershell.exe') -NssmArgs @('-NoProfile', '-File', $fixture, 'failure', '7')
    Assert ($result.ExitCode -eq 7) 'Nonzero native exit code was lost.'
    $failed = $false
    try { Invoke-NssmProcess -FilePath (Join-Path $scratch 'missing.exe') -NssmArgs @('version') | Out-Null } catch { $failed = $true }
    Assert $failed 'Missing executable was accepted.'

    function Invoke-NssmProcess { param($FilePath, $NssmArgs) return $script:NativeResult }
    $script:NativeResult = [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = 'NSSM 2.24-101-g897c7ad 32-bit' }
    Assert ((Get-NssmVersion -FilePath 'nssm.exe') -match '^NSSM') 'Successful stderr version output was rejected.'
    $script:NativeResult = [pscustomobject]@{ ExitCode = 1; Output = ''; ErrorOutput = "NSSM: The non-sucking service manager`r`nVersion 2.24 32-bit, 2014-08-31`r`nUsage: nssm <option>" }
    Assert ((Get-NssmVersion -FilePath 'nssm.exe') -match 'legacy') 'Stable NSSM legacy usage was rejected.'
    $script:NativeResult = [pscustomobject]@{ ExitCode = 1; Output = ''; ErrorOutput = 'Access denied' }
    $failed = $false
    try { Get-NssmVersion -FilePath 'nssm.exe' | Out-Null } catch { $failed = $true }
    Assert $failed 'Genuine version failure was accepted.'
    $script:nssmCmd = [pscustomobject]@{ Source = 'nssm.exe' }
    $script:NativeResult = [pscustomobject]@{ ExitCode = 0; Output = ''; ErrorOutput = 'Service configured successfully.' }
    Invoke-Nssm -NssmArgs @('set', 'test-service', 'AppParameters', 'test-secret')
    $script:NativeResult.ExitCode = 5
    $message = ''
    try { Invoke-Nssm -NssmArgs @('set', 'test-service', 'AppParameters', 'test-secret') } catch { $message = $_.ToString() }
    Assert ($message -match 'exit 5' -and $message -notmatch 'test-secret') 'Command failure or credential protection failed.'

    $script:GitHubProxy = 'https://ghproxy.05160715.xyz'
    $script:Urls = [Collections.Generic.List[string]]::new()
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
        $script:Urls.Add($Uri)
        if ($Uri.StartsWith($GitHubProxy)) { throw 'Simulated proxy error' }
        [IO.File]::WriteAllText($OutFile, 'test archive')
    }
    function Get-FileHash { param($LiteralPath, $Algorithm) return [pscustomobject]@{ Hash = $script:ArchiveHash } }
    $script:ArchiveHash = '99f5045fffbffb745d67fe3a065a953c4a3d9c253b868892d9b685b0ee7d07b8'
    Get-NssmArchive -Destination (Join-Path $scratch 'archive.zip')
    Assert ($Urls.Count -eq 2 -and $Urls[1].StartsWith('https://github.com/htt050715/')) 'NSSM proxy fallback failed.'
    $script:Urls.Clear()
    $script:ArchiveHash = '0' * 64
    $failed = $false
    try { Get-NssmArchive -Destination (Join-Path $scratch 'archive.zip') } catch { $failed = $true }
    Assert ($failed -and $Urls.Count -eq 3) 'Corrupt NSSM archive was accepted or official fallback skipped.'
} finally {
    # Scratch is a fresh GUID directory created under TEMP by this test.
    Remove-Item -LiteralPath $scratch -Recurse -Force
}
Write-Host 'PASS: native stderr, exit codes, quoting, legacy NSSM, command failures, verified archive fallback.'
