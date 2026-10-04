# Builds the Windows release of the client and packs it into a zip in dist\.
#
# Usage (from the repo root, in PowerShell):  .\scripts\build-windows.ps1
#
# The zip contains the whole Release folder: the .exe, its DLLs and the "data" folder.
# Friends unzip it anywhere and run the .exe; no installation needed.
# Third-party licenses are inside the app (account menu > About & licenses).
$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

# Version from pubspec.yaml ("version: 0.1.0+1" -> "0.1.0").
$version = ((Select-String -Path pubspec.yaml -Pattern '^version:\s*(\S+)').Matches[0].Groups[1].Value -split '\+')[0]

Write-Host "Running tests..."
flutter test
if ($LASTEXITCODE -ne 0) { throw 'Tests failed: not building a release.' }

Write-Host "Building release $version..."
flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }

$release = 'build\windows\x64\runner\Release'
New-Item -ItemType Directory -Force dist | Out-Null
Copy-Item LICENSE $release -Force
$zip = "dist\vianden-client_${version}_windows_x64.zip"
if (Test-Path $zip) { Remove-Item $zip }
Compress-Archive -Path "$release\*" -DestinationPath $zip

$hash = (Get-FileHash $zip -Algorithm SHA256).Hash
Write-Host "Done: $zip"
Write-Host "SHA-256: $hash  (share it with the zip, so friends can check the download)"
