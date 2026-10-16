# CI only (yuuka-windows, host mode): put Flutter stable on PATH for the
# following steps. The SDK is cached on the host in
# %ProgramData%\flutter-ci and fast-forwarded each run; first run clones.
$ErrorActionPreference = 'Stop'
$F = "$env:ProgramData\flutter-ci"
if (Test-Path "$F\.git") {
  git -C $F fetch -q --depth 1 origin stable; if ($LASTEXITCODE) { exit 1 }
  git -C $F reset -q --hard FETCH_HEAD; if ($LASTEXITCODE) { exit 1 }
} else {
  git clone -q https://github.com/flutter/flutter.git -b stable --depth 1 $F; if ($LASTEXITCODE) { exit 1 }
}
Add-Content $env:GITHUB_PATH "$F\bin"
& "$F\bin\flutter.bat" config --no-analytics | Out-Null
& "$F\bin\flutter.bat" --version
if ($LASTEXITCODE) { exit 1 }

# flutter_local_notifications_windows includes atlbase.h: the Build Tools
# need the C++ ATL component. Added once on the host (runs as SYSTEM).
$Vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$Vs = & $Vswhere -products * -latest -property installationPath
if (-not (Get-ChildItem "$Vs\VC\Tools\MSVC\*\atlmfc\include\atlbase.h" -ErrorAction SilentlyContinue)) {
  Write-Host "adding the C++ ATL component to $Vs"
  $p = Start-Process -Wait -PassThru "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\setup.exe" `
    -ArgumentList "modify --installPath `"$Vs`" --add Microsoft.VisualStudio.Component.VC.ATL --quiet --norestart --nocache"
  if ($p.ExitCode -notin 0, 3010) { Write-Host "ATL install failed: $($p.ExitCode)"; exit 1 }
}
