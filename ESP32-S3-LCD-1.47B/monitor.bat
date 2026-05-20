@echo off
setlocal EnableDelayedExpansion

set IDF_PATH=C:\esp\v6.0.1\esp-idf
set IDF_TOOLS_PATH=C:\Espressif
set ESPPORT=COM4

echo ============================================
echo ESP-IDF Monitor Script
echo IDF_PATH = %IDF_PATH%
echo Port = %ESPPORT%
echo ============================================

set VENV_PYTHON=%IDF_TOOLS_PATH%\python_env\idf6.0_py3.13_env\Scripts\python.exe
if not exist "%VENV_PYTHON%" (
    echo ESP-IDF tools not installed. Run build.bat first.
    pause
    exit /b 1
)

echo Setting up ESP-IDF environment...
call "%IDF_PATH%\export.bat"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to set up ESP-IDF environment
    pause
    exit /b 1
)

echo.
echo Starting serial monitor on %ESPPORT%...
echo Press Ctrl+] to exit.
echo.
idf.py -p %ESPPORT% monitor

pause
