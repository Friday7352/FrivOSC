@echo off
rem ------------------------------------------------------------------
rem  FrivOSC — one-click installer build
rem ------------------------------------------------------------------
rem  Double-click this file from the project folder to create a fresh
rem  dist\FrivOSCSetup.exe. The PowerShell build script compiles
rem  FrivOSCHost.exe and FrivOSCSetupHost.exe — which is what picks up a
rem  changed FrivOSCIcon.ico, since the icon is compiled into the exe —
rem  and then runs Inno Setup.
rem ------------------------------------------------------------------

setlocal
cd /d "%~dp0"

where powershell >nul 2>&1
if errorlevel 1 (
  echo Windows PowerShell was not found on this system.
  echo FrivOSCSetup.exe could not be built.
  echo.
  pause
  exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build\Build-FrivOSCInstaller.ps1"
set "BUILD_EXIT=%ERRORLEVEL%"

echo.
if not "%BUILD_EXIT%"=="0" (
  echo The installer build did not complete. Review the message above and try again.
) else (
  echo Done. Your new installer is in the dist folder as FrivOSCSetup.exe.
)
echo.
pause
exit /b %BUILD_EXIT%
