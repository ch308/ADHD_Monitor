@echo off
setlocal EnableExtensions
rem =========================================================================
rem  cleanup_stale_builds.bat - Delete stale build directories
rem
rem  Run this from ADHD_Monitor repo root (C:\etc\adhd_monitor).
rem  It deletes the build directories so idf.py can regenerate them
rem  with the correct paths.
rem =========================================================================

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"

echo Cleaning stale build directories...

set "DIR1=%REPO_ROOT%\xiaozhi-esp32-2.2.4\build"
set "DIR2=%REPO_ROOT%\ESP32-S3-LCD-1.47B\build"

for %%D in ("%DIR1%" "%DIR2%") do (
    if exist %%D (
        echo Removing: %%D
        rmdir /s /q %%D 2>nul
        if exist %%D (
            echo WARNING: Could not fully remove %%D - close any programs using it
        ) else (
            echo Done: %%D removed
        )
    ) else (
        echo Already clean: %%D
    )
    echo.
)

echo All build directories cleaned. You can now re-run the build scripts.
echo.
pause
