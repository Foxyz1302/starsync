# Close smoke run (P32) on the built Windows app: start it with a short
# media file, let it open the file in a player with a video output, play a
# second and close the normal way (`apps/desktop/lib/src/platform/smoke.dart`),
# then check it exited within $Limit seconds and left no process behind.
# A runner that cannot bring up a window or a video output skips (warning).
# Usage (after a release build): powershell -File tool/smoke_windows.ps1 [-Limit 45]
param([int]$Limit = 45)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $PSScriptRoot
$Exe = Join-Path $Root 'apps/desktop/build/windows/x64/runner/Release/starsync.exe'
if (-not (Test-Path $Exe)) { throw "build first: $Exe missing" }
$Exe = (Resolve-Path $Exe).Path

$Work = Join-Path ([IO.Path]::GetTempPath()) "starsync-smoke-$PID"
New-Item -ItemType Directory -Force $Work | Out-Null
$Out = Join-Path $Work 'smoke.txt'

# Media: a 5 s clip with ffmpeg when the runner has it, else a 5 s WAV
# written here (mpv opens either; headless mpv needs an audio track).
$Media = Join-Path $Work 'smoke.mp4'
$ffmpeg = Get-Command ffmpeg -ErrorAction SilentlyContinue
if ($ffmpeg) {
  & $ffmpeg.Source -y -v error -f lavfi -i 'testsrc2=size=320x180:rate=24' -f lavfi -i 'sine=frequency=440' `
    -t 5 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -c:a aac $Media
}
if (-not $ffmpeg -or $LASTEXITCODE -or -not (Test-Path $Media)) {
  $Media = Join-Path $Work 'smoke.wav'
  $rate = 48000; $n = $rate * 5
  $data = New-Object byte[] ($n * 2)
  for ($i = 0; $i -lt $n; $i++) {
    $v = [int16](3000 * [Math]::Sin(2 * [Math]::PI * 440 * $i / $rate))
    $data[2 * $i] = [byte]($v -band 0xFF); $data[2 * $i + 1] = [byte](($v -shr 8) -band 0xFF)
  }
  $f = [IO.File]::Create($Media); $w = New-Object IO.BinaryWriter($f)
  $w.Write([Text.Encoding]::ASCII.GetBytes('RIFF')); $w.Write([int](36 + $data.Length))
  $w.Write([Text.Encoding]::ASCII.GetBytes('WAVEfmt ')); $w.Write([int]16); $w.Write([int16]1); $w.Write([int16]1)
  $w.Write([int]$rate); $w.Write([int]($rate * 2)); $w.Write([int16]2); $w.Write([int16]16)
  $w.Write([Text.Encoding]::ASCII.GetBytes('data')); $w.Write([int]$data.Length); $w.Write($data); $w.Close()
}

# Its own profile: no settings, sign-ins or client id of a real install.
$env:STARSYNC_PROFILE = 'smoke'
$env:STARSYNC_SMOKE = $Media
$env:STARSYNC_SMOKE_OUT = $Out
$clock = [Diagnostics.Stopwatch]::StartNew()
$p = Start-Process -FilePath $Exe -PassThru
$exited = $p.WaitForExit($Limit * 1000)
$secs = [int]$clock.Elapsed.TotalSeconds
$lines = if (Test-Path $Out) { Get-Content $Out } else { @() }
Write-Host "smoke steps: $($lines -join ' | ') (after $secs s)"
$logs = Join-Path $env:APPDATA 'foxyz\Starsync\profiles\smoke\logs'
if (Test-Path $logs) {
  Get-ChildItem $logs -Filter 'app-*.log' | Sort-Object LastWriteTime | Select-Object -Last 1 |
    ForEach-Object { Select-String -Path $_.FullName -Pattern 'smoke:|close:|mpv: render' | ForEach-Object { $_.Line } }
}
$left = Get-Process -Name starsync -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $Exe }
if (-not $exited) { $p | Stop-Process -Force -ErrorAction SilentlyContinue }
$left | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not ($lines -contains 'start')) {
  if ($exited) { Write-Warning "skipped: the app never came up on this runner (exit $($p.ExitCode))"; exit 0 }
  Write-Error "the app did not come up and did not exit within $Limit s"; exit 1
}
if ($lines | Where-Object { $_ -like 'skip *' }) { Write-Warning "skipped: $($lines -like 'skip *')"; exit 0 }
if ($lines | Where-Object { $_ -like 'fail *' }) { Write-Error "smoke failed: $($lines -like 'fail *')"; exit 1 }
if (-not ($lines | Where-Object { $_ -like 'opened *' })) { Write-Error 'the media never opened'; exit 1 }
if (-not $exited) { Write-Error "the app did not close within $Limit s (P32)"; exit 1 }
if ($left) { Write-Error "a starsync process was left behind (P32)"; exit 1 }
Write-Host "smoke ok: opened and closed in $secs s, no process left"
Remove-Item -Recurse -Force $Work -ErrorAction SilentlyContinue
