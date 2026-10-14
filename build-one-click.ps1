# Package the PowerShell source as a single downloadable CMD file.
$ErrorActionPreference = 'Stop'
$header = @'
@echo off
chcp 65001 >nul
setlocal
set "KOMARI_LAUNCHER_PATH=%~f0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; $scriptPath=Join-Path $env:TEMP ('komari-bootstrap-'+[guid]::NewGuid().ToString('N')+'.ps1'); try { $content=Get-Content -LiteralPath $env:KOMARI_LAUNCHER_PATH -Raw -Encoding UTF8; $marker='# KOMARI_POWERSHELL_BEGIN'; $payload=$content.Substring($content.LastIndexOf($marker)+$marker.Length); [IO.File]::WriteAllText($scriptPath,$payload,[Text.UTF8Encoding]::new($true)); & $scriptPath; exit $LASTEXITCODE } catch { Write-Host $_ -ForegroundColor Red; Read-Host 'Press Enter to close'; exit 1 } finally { if (Test-Path -LiteralPath $scriptPath) { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue } }"
exit /b %errorlevel%
# KOMARI_POWERSHELL_BEGIN
'@
$source = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'install-one-click.ps1'))
$outputPath = Join-Path $PSScriptRoot 'install-komari.cmd'
$content = ($header.TrimEnd() + "`r`n" + $source).Replace("`r`n", "`n").Replace("`n", "`r`n")
[IO.File]::WriteAllText($outputPath, $content, [Text.UTF8Encoding]::new($false))
Write-Host "Created $outputPath"
