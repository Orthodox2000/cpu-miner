@echo off
setlocal
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Run.ps1" -Unattended %*
set "RC=%ERRORLEVEL%"
if "%RC%"=="0" goto :done
echo.
echo Unattended setup failed. Logs are in %ProgramData%\CpuMiner\logs
echo Press any key to close...
pause >nul
:done
endlocal & exit /b %RC%
