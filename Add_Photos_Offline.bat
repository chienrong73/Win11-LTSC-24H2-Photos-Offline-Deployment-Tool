@echo off
setlocal
set "SCRIPT_DIR=%~dp0"
set "SCRIPT_PATH=%SCRIPT_DIR%Add_Photos.ps1"

fltmc >nul 2>&1
if errorlevel 1 (
    echo Requesting administrator privileges...
    set "ELEVATED_COMMAND=""%~f0"" %*"
    powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -Command "$process = Start-Process -FilePath 'cmd.exe' -Verb RunAs -Wait -PassThru -ArgumentList @('/d', '/c', $env:ELEVATED_COMMAND); exit $process.ExitCode"
    exit /b %errorlevel%
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_PATH%" %*
set "EXIT_CODE=%errorlevel%"
if not "%EXIT_CODE%"=="0" echo Deployment failed with exit code %EXIT_CODE%.
exit /b %EXIT_CODE%
