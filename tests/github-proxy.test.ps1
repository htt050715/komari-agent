# Exercise both real download helpers with fake network responses; no installation.
$ErrorActionPreference = 'Stop'
$GitHubProxy = 'https://ghproxy.05160715.xyz'
function Assert($condition, $message) { if (-not $condition) { throw $message } }
function Log-Warning { param($Message) }
$root = Split-Path $PSScriptRoot -Parent
foreach ($file in @('install.ps1', 'install-one-click.ps1')) {
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file), [ref]$tokens, [ref]$errors)
    Assert ($errors.Count -eq 0) 'Script parse failure.'
    $name = if ($file -eq 'install.ps1') { 'Get-GitHubResource' } else { 'Get-WithRetry' }
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $false)
    . ([scriptblock]::Create($fn.Extent.Text))
    function Invoke-RestMethod {
        param($Uri, [switch]$UseBasicParsing, $TimeoutSec)
        $script:Urls.Add($Uri)
        if ($Uri.StartsWith($GitHubProxy)) {
            if ($script:Failure -eq 'invalid') { return '<html>bad gateway</html>' }
            if ($script:Failure -eq 'http') { throw '404' }
        }
        return [pscustomobject]@{ tag_name = '1.5.13' }
    }
    function Invoke-WebRequest {
        param($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec, $ErrorAction)
        $script:Urls.Add($Uri)
        $content = if ($Uri.StartsWith($GitHubProxy)) { 'bad' } else { 'good' }
        [IO.File]::WriteAllText($OutFile, $content)
    }
    foreach ($mode in @('none', 'http', 'invalid')) {
        $script:Failure = $mode
        $script:Urls = [Collections.Generic.List[string]]::new()
        $result = & $name -Url 'https://api.github.com/repos/htt050715/komari-agent/releases/latest'
        Assert ($result.tag_name -eq '1.5.13') 'Failed to resolve release.'
        $expectedCount = if ($mode -eq 'none') { 1 } else { 2 }
        Assert ($Urls.Count -eq $expectedCount -and $Urls[0].StartsWith($GitHubProxy)) 'Proxy-first or API fallback failed.'
    }
    $path = Join-Path $env:TEMP ('komari-proxy-test-' + [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($path, 'good')
        $digest = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash
        $script:Urls = [Collections.Generic.List[string]]::new()
        & $name -Url 'https://github.com/htt050715/komari-agent/releases/download/1.5.13/install.ps1' -Destination $path -ExpectedDigest $digest
        Assert ($Urls.Count -eq 2 -and [IO.File]::ReadAllText($path) -eq 'good') 'Checksum failure did not fall back to direct download.'
    } finally { Remove-Item -LiteralPath $path -Force }
}
Write-Host 'PASS: proxy-first, API error/invalid response fallback, and corrupt download fallback.'
