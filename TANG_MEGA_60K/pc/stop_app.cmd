@echo off
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\stop_app.ps1"
endlocal & exit /b %ERRORLEVEL%
