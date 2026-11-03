@echo off
REM start_app.cmd -- double-click or run from ANY directory.
REM It resolves its own folder, so the current directory does not matter.
REM
REM   start_app.cmd              -> auto-find port, serve on 8080
REM   start_app.cmd -Mock        -> no hardware, mock serial
REM   start_app.cmd -Port COM15  -> force a port
REM
REM Why this file exists: `powershell -File tools\start_app.ps1` only works if
REM your shell's current directory is the project root.  This wrapper does not
REM care where you are.

setlocal
set "HERE=%~dp0"
if "%HERE:~-1%"=="\" set "HERE=%HERE:~0,-1%"

powershell -NoProfile -ExecutionPolicy Bypass -File "%HERE%\tools\start_app.ps1" %*
set "RESULT=%ERRORLEVEL%"
if not "%RESULT%"=="0" (
  echo.
  echo Startup stopped. Read the error above. No second relay was started.
  pause
)
endlocal & exit /b %RESULT%
