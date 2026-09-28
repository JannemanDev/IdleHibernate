@echo off
setlocal EnableExtensions
cd /d "%~dp0"

if /I "%~1"=="" goto :usage
if /I "%~1"=="help" goto :usage
if /I "%~1"=="/?" goto :usage
if /I "%~1"=="-h" goto :usage
if /I "%~1"=="--help" goto :usage

if /I "%~1"=="start" goto :start
if /I "%~1"=="restart" goto :restart
if /I "%~1"=="stop" goto :stop
if /I "%~1"=="status" goto :status

echo Unknown command: %~1
echo.
goto :usage

:start
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrayControl.ps1" start
exit /b %ERRORLEVEL%

:restart
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrayControl.ps1" restart
exit /b %ERRORLEVEL%

:stop
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrayControl.ps1" stop
exit /b %ERRORLEVEL%

:status
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0TrayControl.ps1" status
exit /b %ERRORLEVEL%

:usage
echo IdleHibernate tray helper
echo.
echo Usage: Tray.cmd start ^| restart ^| stop ^| status
echo.
echo   start    Start the tray if it is not already running
echo   restart  Stop any running tray, then start it
echo   stop     Stop the tray
echo   status   Show whether the tray is running
echo.
echo Log: %%LOCALAPPDATA%%\IdleHibernate\start-tray.log
exit /b 1
