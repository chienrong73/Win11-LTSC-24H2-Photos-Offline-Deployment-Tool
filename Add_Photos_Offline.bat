@echo off
rem Delayed expansion must remain disabled while expanding paths and caller arguments.
setlocal DisableDelayedExpansion
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Add_Photos.ps1"

fltmc >nul 2>&1
if not errorlevel 1 goto :RunDeployment

echo Requesting administrator privileges...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Modules\Elevate-AddPhotos.ps1" -ScriptPath "%SCRIPT_PATH%" %*
rem This is intentionally outside a parenthesized block, so runtime errorlevel is safe to read.
set "ELEVATED_EXIT_CODE=%errorlevel%"
exit /b %ELEVATED_EXIT_CODE%

:RunDeployment
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
set "EXIT_CODE=%errorlevel%"
if not "%EXIT_CODE%"=="0" echo Deployment failed with exit code %EXIT_CODE%.
exit /b %EXIT_CODE%
