@echo off
setlocal

REM Sicherstellen, dass das Script mit Admin-Rechten laeuft
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo Starte mit Administratorrechten neu...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SCRIPT_DIR=%~dp0"
set "PS_SCRIPT=%SCRIPT_DIR%Vmware-ManageSecureBoot.ps1"

if not exist "%PS_SCRIPT%" (
    echo Fehler: %PS_SCRIPT% wurde nicht gefunden.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"

if not "%EXIT_CODE%"=="0" (
    echo.
    echo Vmware-ManageSecureBoot.ps1 wurde mit Exit-Code %EXIT_CODE% beendet.
    pause
)

exit /b %EXIT_CODE%
