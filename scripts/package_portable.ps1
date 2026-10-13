# Builds the portable Windows zip: dist\AmarTv-portable-win64.zip
#   pub get -> analyze -> test -> build windows --release -> copy release folder
#   + VC++ runtime DLLs + config.example.json + "Start AmarTv.bat" -> zip.
# Stops on the first error. Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File scripts\package_portable.ps1

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step([string]$name, [scriptblock]$cmd) {
    Write-Host "==> $name" -ForegroundColor Cyan
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$name failed (exit code $LASTEXITCODE)" }
}

Step 'flutter pub get' { flutter pub get }
Step 'flutter analyze' { flutter analyze }
Step 'flutter test' { flutter test }
Step 'flutter build windows --release' { flutter build windows --release }

$release = Join-Path $root 'build\windows\x64\runner\Release'
$dist = Join-Path $root 'dist'
$app = Join-Path $dist 'AmarTv'
$zip = Join-Path $dist 'AmarTv-portable-win64.zip'

# Only replace this script's own outputs; other kits in dist are kept.
foreach ($old in @($app, $zip)) { if (Test-Path $old) { Remove-Item $old -Recurse -Force } }
New-Item -ItemType Directory -Path $app | Out-Null

Write-Host '==> Copying release folder' -ForegroundColor Cyan
# Top level: the exe and its DLLs only (no config.json, logs, debug symbols,
# or leftovers like an old renamed exe).
robocopy $release $app *.dll AmarTv.exe native_assets.json /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
# data\: ONLY Flutter's own files. data\amartv (database, settings, logs)
# holds your login inside channel URLs and must never be packaged.
New-Item -ItemType Directory -Path (Join-Path $app 'data') | Out-Null
Copy-Item (Join-Path $release 'data\app.so'), (Join-Path $release 'data\icudtl.dat') (Join-Path $app 'data')
robocopy (Join-Path $release 'data\flutter_assets') (Join-Path $app 'data\flutter_assets') /E /NFL /NDL /NJH /NJS /NP | Out-Null
if ($LASTEXITCODE -ge 8) { throw "robocopy failed ($LASTEXITCODE)" }
$global:LASTEXITCODE = 0

Write-Host '==> Adding VC++ runtime DLLs (app-local)' -ForegroundColor Cyan
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$vs = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw 'Visual Studio C++ tools not found (needed for the VC++ redistributable DLLs).' }
# Only the redistributable CRT folder (Microsoft.VC14x.CRT) - not debug DLLs.
$crt = Get-ChildItem (Join-Path $vs 'VC\Redist\MSVC') -Directory |
    Sort-Object Name -Descending |
    ForEach-Object { Get-ChildItem (Join-Path $_.FullName 'x64') -Directory -Filter 'Microsoft.VC14*.CRT' -ErrorAction SilentlyContinue } |
    Select-Object -First 1
if (-not $crt) { throw 'VC++ redistributable CRT folder not found.' }
Copy-Item (Join-Path $crt.FullName '*.dll') $app
Write-Host "    from $($crt.FullName)"

Copy-Item (Join-Path $root 'config.example.json') $app
Set-Content -Path (Join-Path $app 'Start AmarTv.bat') -Encoding ASCII -Value @(
    '@echo off',
    'rem Starts AmarTv from this folder (USB drive friendly).',
    'cd /d "%~dp0"',
    'start "" "%~dp0AmarTv.exe"'
)

Write-Host '==> Checking for secrets' -ForegroundColor Cyan
$bad = Get-ChildItem $app -Recurse -File | Where-Object {
    $_.Name -in @('config.json', 'key.properties', 'settings.json') -or
    $_.Extension -in @('.jks', '.keystore', '.log', '.sqlite', '.db', '.pdb') -or
    ($_.Extension -eq '.exe' -and $_.Name -ne 'AmarTv.exe') -or
    ($_.FullName -like '*\data\*' -and $_.FullName -notlike '*\data\flutter_assets\*' -and
        $_.Name -notin @('app.so', 'icudtl.dat'))
}
if ($bad) { throw "Refusing to package: $($bad.FullName -join ', ')" }
if (-not (Test-Path (Join-Path $app 'AmarTv.exe'))) { throw 'AmarTv.exe missing from the package.' }

Write-Host '==> Zipping' -ForegroundColor Cyan
Compress-Archive -Path $app -DestinationPath $zip -Force
$size = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "Done: $zip ($size MB)" -ForegroundColor Green
