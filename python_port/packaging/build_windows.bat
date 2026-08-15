@echo off
rem Double-click me. Runs the PowerShell build script with a permissive policy for this
rem process only, then keeps the window open so the result can be read.
setlocal
cd /d "%~dp0\.."
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_windows.ps1" %*
echo.
pause
