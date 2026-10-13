# Builds everything for the flash drive into dist\<KitName> (default USB-Kit):
#   AmarTv-Setup.exe     Windows installer (no admin rights needed)
#   AmarTv.apk           Android app
#   AmarTv-portable\     run-without-installing version
#   config.json          your playlist (only if config.json exists in the project root)
#   READ ME FIRST.txt    the steps
#
# With a config.json in the project root (git-ignored), the APK is a PERSONAL
# build with your playlist URL inside, so phones need no setup at all.
# Do not share a personal kit or APK: it contains your login.
#
#   powershell -ExecutionPolicy Bypass -File scripts\build_usb_kit.ps1 [-KitName USB-Kit-2]

param([string]$KitName = 'USB-Kit')

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Set-Location $root

function Step([string]$name, [scriptblock]$cmd) {
    Write-Host "==> $name" -ForegroundColor Cyan
    & $cmd
    if ($LASTEXITCODE -ne 0) { throw "$name failed (exit code $LASTEXITCODE)" }
}

# 1. Windows portable folder + zip (pub get, analyze, test, release build).
Step 'Portable Windows build' { powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot 'package_portable.ps1') }

# 2. Installer.
$iscc = @(
    (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
    (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe')
) | Where-Object { Test-Path $_ } | Select-Object -First 1
if (-not $iscc) { throw 'Inno Setup 6 not found. Install it: winget install JRSoftware.InnoSetup --scope user' }
$version = (Select-String -Path pubspec.yaml -Pattern '^version:\s*([0-9.]+)').Matches[0].Groups[1].Value
$env:AMARTV_VERSION = $version
# Antivirus scanning the new setup file can make Inno Setup fail
# ("EndUpdateResource failed"); a retry a few seconds later usually works.
for ($try = 1; $try -le 3; $try++) {
    Write-Host "==> Windows installer (try $try)" -ForegroundColor Cyan
    & $iscc /Q 'installer\amartv.iss'
    if ($LASTEXITCODE -eq 0) { break }
    if ($try -eq 3) { throw "Windows installer failed (exit code $LASTEXITCODE)" }
    Start-Sleep -Seconds 5
}

# 3. Android APK (personal when config.json exists).
$configFile = Join-Path $root 'config.json'
$url = ''
if (Test-Path $configFile) {
    $url = (Get-Content $configFile -Raw | ConvertFrom-Json).playlistUrl
    if ($url -like '*example.com*') { $url = '' }
}
if ($url) {
    Write-Host '    Personal APK: your playlist URL is built in.' -ForegroundColor Yellow
    # Passed via a file: flutter.bat would split the URL at '&' on the command line.
    $defines = Join-Path $root 'build\personal_defines.json'
    New-Item -ItemType Directory -Force -Path (Split-Path $defines) | Out-Null
    [IO.File]::WriteAllText($defines, (@{ AMARTV_URL = $url } | ConvertTo-Json))  # UTF-8 without BOM
    try {
        Step 'Android APK (personal)' { flutter build apk --release "--dart-define-from-file=$defines" }
    } finally {
        Remove-Item $defines -ErrorAction SilentlyContinue
    }
} else {
    Step 'Android APK' { flutter build apk --release }
}

# 4. Assemble the kit.
$kit = Join-Path $root (Join-Path 'dist' $KitName)
if (Test-Path $kit) { Remove-Item $kit -Recurse -Force }
New-Item -ItemType Directory -Path $kit | Out-Null
Copy-Item 'dist\AmarTv-Setup.exe' $kit
Copy-Item 'build\app\outputs\flutter-apk\app-release.apk' (Join-Path $kit 'AmarTv.apk')
Copy-Item 'dist\AmarTv' (Join-Path $kit 'AmarTv-portable') -Recurse
if ($url) {
    Copy-Item $configFile $kit
    Copy-Item $configFile (Join-Path $kit 'AmarTv-portable')
}
Copy-Item (Join-Path $PSScriptRoot 'READ ME FIRST.txt') $kit

$size = [math]::Round(((Get-ChildItem $kit -Recurse -File | Measure-Object Length -Sum).Sum) / 1MB, 0)
Write-Host "Done: $kit ($size MB) - copy this folder to the flash drive." -ForegroundColor Green
if ($url) { Write-Host 'This kit contains your playlist login. Keep it private.' -ForegroundColor Yellow }
