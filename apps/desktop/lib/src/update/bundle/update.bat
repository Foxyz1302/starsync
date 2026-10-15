@echo off
rem Update this install in place (same as clicking Update in the app).
rem The old server name is the fallback for installs from before the rename.
set "SERVER=%~dp0starsync-server.exe"
if not exist "%SERVER%" set "SERVER=%~dp0watch-together-server.exe"
"%SERVER%" --upgrade %*
pause
