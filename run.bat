@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0deploy\windows\start.ps1" %*
if not errorlevel 1 exit /b 0
pause
exit /b 1
