@echo off
rem Starsync crash report: put this file in the Starsync folder (next to
rem starsync.exe or watch_together.exe) and double-click it. It makes
rem starsync-report.zip on the Desktop and copies it: Ctrl+V in Discord.
set "STARSYNC_REPORT_DIR=%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -Command "$s = Get-Content -LiteralPath '%~f0' -Raw; iex $s.Substring($s.IndexOf('#STAR' + 'SYNC-PS'))"
echo.
pause
exit /b
#STARSYNC-PS
# Starsync crash report (run windows_report.cmd from the Starsync folder): collects logs, crash events and a test start, zips
# them to the Desktop and puts the zip on the clipboard (Ctrl+V in Discord).
$ErrorActionPreference = 'SilentlyContinue'
$o = Join-Path $env:TEMP 'starsync-report'
Remove-Item -Recurse -Force $o
New-Item -ItemType Directory $o | Out-Null
$info = Join-Path $o 'info.txt'
function Say($s) { Add-Content -Path $info -Value $s }

Say ('Report ' + (Get-Date -Format s))
Say ((Get-CimInstance Win32_OperatingSystem | Select-Object Caption, Version, OSArchitecture | Format-List | Out-String).Trim())
Say ((Get-CimInstance Win32_VideoController | Select-Object Name, DriverVersion | Format-List | Out-String).Trim())

# The app's logs (new and old data folders), newest first.
$logs = Get-ChildItem -Path "$env:APPDATA\*\*\logs\*" -Include 'app-*', 'diagnostics-*', 'session-*', 'server-*' |
  Sort-Object LastWriteTime -Descending | Select-Object -First 10
foreach ($l in $logs) {
  $dest = Join-Path $o ($l.Directory.Parent.Name + '_' + $l.Name)
  Copy-Item $l.FullName $dest
}
Say ''
Say 'Data folders:'
Get-ChildItem -Path "$env:APPDATA\*\*" -Directory | Where-Object { $_.Name -match 'starsync|watch' } |
  ForEach-Object { Say ('  ' + $_.FullName) }

# Windows' own crash records for the app.
Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1001, 1026; StartTime = (Get-Date).AddDays(-3) } |
  Where-Object { $_.Message -match 'starsync|watch_together' } |
  Format-List TimeCreated, Id, ProviderName, Message | Out-File (Join-Path $o 'crash-events.txt') -Width 300

# Every install found: its files, and one test start of starsync.exe.
$roots = @([Environment]::GetFolderPath('Desktop'), "$env:USERPROFILE\Downloads", "$env:USERPROFILE\Desktop", $env:LOCALAPPDATA, $env:ProgramFiles, "$env:USERPROFILE\Documents") | Select-Object -Unique
$exes = foreach ($r in $roots) { Get-ChildItem -Path $r -Recurse -Depth 3 -Include 'starsync.exe', 'watch_together.exe' -File }
# The folder this report was started from comes first.
$here = $env:STARSYNC_REPORT_DIR
if ($here) { $here = $here.TrimEnd('\') }
$dirs = @($here) + ($exes | ForEach-Object { $_.DirectoryName }) |
  Where-Object { $_ -and ((Test-Path (Join-Path $_ 'starsync.exe')) -or (Test-Path (Join-Path $_ 'watch_together.exe'))) } |
  Select-Object -Unique
foreach ($d in $dirs) {
  Say ''
  Say ('Install: ' + $d)
  Get-ChildItem -Path $d -Recurse -File | ForEach-Object {
    Say ('  ' + $_.FullName.Substring($d.Length) + '  ' + $_.Length + '  ' + $_.LastWriteTime.ToString('s'))
  }
  $exe = Join-Path $d 'starsync.exe'
  if (-not (Test-Path $exe)) { $exe = Join-Path $d 'watch_together.exe' }
  $p = Start-Process -FilePath $exe -WorkingDirectory $d -PassThru
  Start-Sleep -Seconds 20
  if ($p.HasExited) {
    Say ('Test start of ' + $exe + ': exited, code ' + $p.ExitCode + ' (0x' + ('{0:X8}' -f $p.ExitCode) + ')')
  } else {
    Say ('Test start of ' + $exe + ': still running after 20 s')
    Stop-Process -Id $p.Id -Force
  }
}
if (-not $dirs) { Say 'No starsync.exe or watch_together.exe found on Desktop, Downloads, Documents, AppData or Program Files.' }

# Logs written by the test start.
Get-ChildItem -Path "$env:APPDATA\*\*\logs\*" -Include 'app-*' | Where-Object { $_.LastWriteTime -gt (Get-Date).AddMinutes(-2) } |
  ForEach-Object { Copy-Item $_.FullName (Join-Path $o ('after-test_' + $_.Name)) }

$zip = Join-Path ([Environment]::GetFolderPath('Desktop')) 'starsync-report.zip'
Remove-Item -Force $zip
Compress-Archive -Path "$o\*" -DestinationPath $zip
Set-Clipboard -Path $zip
Start-Process explorer.exe -ArgumentList "/select,`"$zip`""
Write-Host ''
Write-Host 'Done: starsync-report.zip is on your Desktop and copied.' -ForegroundColor Green
Write-Host 'Open Discord and press Ctrl+V to send it.' -ForegroundColor Green
