# Package the Windows release bundle into a versioned zip.
# Usage: powershell -File tool/package_windows.ps1 [-SkipBuild]
# Output: dist/watch-together-<version>-windows-x64.zip containing one
# top-level folder with watch_together.exe, its DLLs and data/ as built,
# plus update.bat (runs watch-together-server.exe --upgrade) and
# watch-together-server.exe (dedicated server, `dart compile exe` of
# packages/server/bin/server.dart; both binaries stamped with APP_VERSION).
# Same layout as tool/package_linux.sh; the updater strips the top-level
# folder.
# Needs: flutter on PATH, tar.exe (ships with Windows 10+, writes zip).
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'apps/desktop'
$Name = 'watch-together'
$Arch = 'x64'

$Version = (Select-String -Path "$App/pubspec.yaml" -Pattern '^version: ([0-9.]+)').Matches[0].Groups[1].Value
if (-not $Version) { throw "version not found in $App/pubspec.yaml" }

function Invoke-Checked([string]$What, [scriptblock]$Cmd) {
  & $Cmd
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

if (-not $SkipBuild) {
  Push-Location $App
  try {
    Invoke-Checked 'flutter build windows' { flutter build windows --release "--dart-define=APP_VERSION=$Version" }
  } finally { Pop-Location }
}

$Bundle = Join-Path $App "build/windows/$Arch/runner/Release"
if (-not (Test-Path "$Bundle/watch_together.exe")) { throw "bundle missing (build first): $Bundle" }

$Stage = Join-Path $App 'build/package-stage'
$Dist = Join-Path $Root 'dist'
$Folder = "$Name-$Version"
$Zip = Join-Path $Dist "$Folder-windows-$Arch.zip"
if (Test-Path $Stage) { Remove-Item -Recurse -Force $Stage }
New-Item -ItemType Directory -Force "$Stage/$Folder", $Dist | Out-Null
Copy-Item -Recurse "$Bundle/*" "$Stage/$Folder/"
Copy-Item "$App/lib/src/update/bundle/update.bat" "$Stage/$Folder/update.bat"

Push-Location (Join-Path $Root 'packages/server')
try {
  Invoke-Checked 'dart pub get' { dart pub get | Out-Null }
  Invoke-Checked 'dart compile exe' { dart compile exe "--define=APP_VERSION=$Version" bin/server.dart -o "$Stage/$Folder/watch-together-server.exe" }
} finally { Pop-Location }

if (Test-Path $Zip) { Remove-Item -Force $Zip }
# bsdtar writes forward-slash entry names (Compress-Archive on 5.1 doesn't).
Invoke-Checked 'tar' { tar.exe -a -c -f $Zip -C $Stage $Folder }
Remove-Item -Recurse -Force $Stage
Get-Item $Zip | Format-Table Name, Length
