@echo off
REM 在 CMD 里可从工程根执行:  idf.cmd menuconfig
REM 在 PowerShell 里请用:    .\idf.cmd menuconfig   或先 . .\activate-idf.ps1 再 idf menuconfig
set "SCRIPT=%~dp0.vscode\esp-idf-manual.ps1"
powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
