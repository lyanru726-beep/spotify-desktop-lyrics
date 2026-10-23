@echo off
chcp 65001 >nul
echo Starting Spotify desktop lyrics (debug console)...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0src\SpotifyLyrics.ps1" -DebugMode
echo.
echo Exited. Press any key to close.
pause >nul
