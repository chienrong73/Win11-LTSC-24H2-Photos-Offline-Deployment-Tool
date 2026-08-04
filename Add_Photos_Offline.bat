@echo off
setlocal
set "SCRIPT_DIR=%~dp0"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File ""%SCRIPT_DIR%Add_Photos.ps1""'"
    exit /b %errorlevel%
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Add_Photos.ps1" %*
set "EXIT_CODE=%errorlevel%"
if not "%EXIT_CODE%"=="0" echo Deployment failed with exit code %EXIT_CODE%.
exit /b %EXIT_CODE%
