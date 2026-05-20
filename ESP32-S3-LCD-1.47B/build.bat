@echo off
setlocal EnableDelayedExpansion

set IDF_PATH=C:\esp\v6.0.1\esp-idf
set IDF_TOOLS_PATH=C:\Espressif
set ESPPORT=COM4

echo ============================================
echo ESP-IDF Build Script
echo IDF_PATH = %IDF_PATH%
echo Port = %ESPPORT%
echo ============================================

:: Check if ESP-IDF tools are installed
set VENV_PYTHON=%IDF_TOOLS_PATH%\python_env\idf6.0_py3.13_env\Scripts\python.exe
if not exist "%VENV_PYTHON%" (
    echo.
    echo ESP-IDF tools not installed. Running install script...
    echo This may take a few minutes on first run.
    echo.
    call "%IDF_PATH%\install.bat" esp32s3
    if !ERRORLEVEL! NEQ 0 (
        echo ERROR: Failed to install ESP-IDF tools
        pause
        exit /b 1
    )
    echo.
    echo Install completed.
)

echo.
echo Setting up ESP-IDF environment...
call "%IDF_PATH%\export.bat"
if %ERRORLEVEL% NEQ 0 (
    echo ERROR: Failed to set up ESP-IDF environment
    pause
    exit /b 1
)

echo.
echo Building project...
idf.py set-target esp32s3
idf.py build

if %ERRORLEVEL% EQU 0 (
    echo.
    echo ============================================
    echo BUILD SUCCESSFUL!
    echo.
    echo To flash, run: idf.py -p %ESPPORT% flash
    echo To monitor, run: idf.py -p %ESPPORT% monitor
    echo ============================================
) else (
    echo.
    echo BUILD FAILED!
)

pause
