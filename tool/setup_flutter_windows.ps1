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
