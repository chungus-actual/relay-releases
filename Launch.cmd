@echo off
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Dev.ps1" %*
if errorlevel 1 (
  echo.
  echo Relay did not launch. See the error above.
  pause
  exit /b 1
)
