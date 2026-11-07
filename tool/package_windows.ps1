# Package the Windows release bundle into a versioned zip.
# Usage: powershell -File tool/package_windows.ps1 [-SkipBuild]
# Output: dist/starsync-<version>-windows-x64.zip containing one
# top-level folder starsync-<version>/ with starsync.exe, its DLLs and
# data/ as built, plus update.bat (runs starsync-server.exe --upgrade),
# starsync-server.exe (dedicated server, `dart compile exe` of
# packages/server/bin/server.dart; both binaries stamped with APP_VERSION),
# LICENSE and THIRD_PARTY_LICENSES.txt (tool/third_party_licenses.dart, from
# the bundle's NOTICES.Z and libmpv-licenses.txt).
# Same layout as tool/package_linux.sh; the updater strips the top-level
# folder.
# Needs: flutter on PATH, tar.exe (ships with Windows 10+, writes zip).
param([switch]$SkipBuild)
$ErrorActionPreference = 'Stop'

$Root = Split-Path -Parent $PSScriptRoot
$App = Join-Path $Root 'apps/desktop'
$Name = 'starsync'
$Arch = 'x64'

$Version = (Select-String -Path "$App/pubspec.yaml" -Pattern '^version: ([0-9.]+)').Matches[0].Groups[1].Value
if (-not $Version) { throw "version not found in $App/pubspec.yaml" }
# VERSION in the environment overrides it (a test build's label, e.g. 1.5.0-dev.7).
if ($env:VERSION) { $Version = $env:VERSION }

function Invoke-Checked([string]$What, [scriptblock]$Cmd) {
  & $Cmd
  if ($LASTEXITCODE -ne 0) { throw "$What failed (exit $LASTEXITCODE)" }
}

if (-not $SkipBuild) {
  # The host runner keeps the pub cache between jobs; its clone of a git
  # dependency (fox_utils) went stale ("some refs were not updated") and
  # resolved the wrong revision. Git deps are tiny: always fetch them fresh.
  $PubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
  foreach ($d in @((Join-Path $PubCache 'git'), (Join-Path $PubCache 'git\cache'))) {
    Get-ChildItem -Path $d -Directory -Filter 'fox_utils*' -ErrorAction SilentlyContinue |
      Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
  }
  Push-Location $App
  try {
    Invoke-Checked 'flutter pub get' { flutter pub get }
  } finally { Pop-Location }
  Push-Location $App
  try {
    flutter build windows --release "--dart-define=APP_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) {
      # Flutter hides MSBuild's messages: rebuild verbosely and show only
      # the compiler/linker errors, so CI logs say what broke.
      # Through cmd and with 'Continue': under 'Stop' PowerShell aborts on
      # the first stderr line of a native command.
      $ErrorActionPreference = 'Continue'
      $log = cmd /c "flutter build windows --release -v --dart-define=APP_VERSION=$Version 2>&1"
      $ErrorActionPreference = 'Stop'
      Write-Host '--- error lines ---'
      $log | Select-String -Pattern 'error' | ForEach-Object { $_.Line } | Select-Object -Unique -First 60
      Write-Host '--- last lines ---'
      $log | Select-Object -Last 80
      throw 'flutter build windows failed'
    }
  } finally { Pop-Location }
}

$Bundle = Join-Path $App "build/windows/$Arch/runner/Release"
if (-not (Test-Path "$Bundle/starsync.exe")) { throw "bundle missing (build first): $Bundle" }

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
  Invoke-Checked 'dart compile exe' { dart compile exe "--define=APP_VERSION=$Version" bin/server.dart -o "$Stage/$Folder/starsync-server.exe" }
} finally { Pop-Location }

Copy-Item "$Root/LICENSE" "$Stage/$Folder/LICENSE"
Push-Location (Join-Path $Root 'tool')
try {
  Invoke-Checked 'dart pub get (tool)' { dart pub get | Out-Null }
  Invoke-Checked 'third-party licenses' { dart third_party_licenses.dart windows "$Stage/$Folder" "$Stage/$Folder/THIRD_PARTY_LICENSES.txt" }
} finally { Pop-Location }

if (Test-Path $Zip) { Remove-Item -Force $Zip }
# bsdtar writes forward-slash entry names (Compress-Archive on 5.1 doesn't).
Invoke-Checked 'tar' { tar.exe -a -c -f $Zip -C $Stage $Folder }
Remove-Item -Recurse -Force $Stage
Get-Item $Zip | Format-Table Name, Length
