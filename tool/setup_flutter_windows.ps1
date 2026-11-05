# CI only: put Flutter on PATH for the following steps (GITHUB_PATH).
# -Ref: a branch of github.com/flutter/flutter (stable, beta) or a release
# tag (3.48.0-0.5.pre); default $env:FLUTTER_REF, else stable.
# -Dir: where the SDK lives; fast-forwarded to -Ref when it is already
# there, cloned otherwise. The default suits yuuka-windows (Gitea, host
# mode, runs as SYSTEM), which keeps it between jobs; GitHub's runners pass
# a folder that actions/cache restores (.github/actions/setup-flutter).
param(
  [string]$Ref = $(if ($env:FLUTTER_REF) { $env:FLUTTER_REF } else { 'stable' }),
  [string]$Dir = "$env:ProgramData\flutter-ci"
)
$ErrorActionPreference = 'Stop'
$F = $Dir
if (Test-Path "$F\.git") {
  git -C $F fetch -q --depth 1 origin $Ref; if ($LASTEXITCODE) { exit 1 }
  git -C $F reset -q --hard FETCH_HEAD; if ($LASTEXITCODE) { exit 1 }
} else {
  git clone -q https://github.com/flutter/flutter.git -b $Ref --depth 1 $F; if ($LASTEXITCODE) { exit 1 }
}
Add-Content $env:GITHUB_PATH "$F\bin"
& "$F\bin\flutter.bat" config --no-analytics | Out-Null
& "$F\bin\flutter.bat" --version
if ($LASTEXITCODE) { exit 1 }

# flutter_local_notifications_windows includes atlbase.h: the Build Tools
# need the C++ ATL component. Added once on yuuka-windows; GitHub's Windows
# images ship it (VC.ATL in their Visual Studio), so this does nothing there.
$Vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $Vswhere)) { Write-Warning "no vswhere: Visual Studio not checked for ATL"; exit 0 }
$Vs = & $Vswhere -products * -latest -property installationPath
if (-not (Get-ChildItem "$Vs\VC\Tools\MSVC\*\atlmfc\include\atlbase.h" -ErrorAction SilentlyContinue)) {
  Write-Host "adding the C++ ATL component to $Vs"
  $p = Start-Process -Wait -PassThru "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" `
    -ArgumentList "modify --installPath `"$Vs`" --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart --nocache"
  if ($p.ExitCode -notin 0, 3010) { Write-Host "ATL install failed: $($p.ExitCode)"; exit 1 }
}
