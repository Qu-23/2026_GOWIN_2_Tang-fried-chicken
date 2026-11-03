@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\diagnose_bluetooth.ps1"
set "RESULT=%ERRORLEVEL%"
pause
endlocal & exit /b %RESULT%
