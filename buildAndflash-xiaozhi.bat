@echo off
setlocal EnableExtensions EnableDelayedExpansion
rem =========================================================================
rem  buildAndflash-xiaozhi.bat - 星星机器人 (xiaozhi-esp32-2.2.4)
rem  Board: Xingzhi CUBE 1.54 TFT WiFi (SPI ST7789 240x240, NOT 1.47B LCD_TEST)
rem
rem  Usage (from ADHD_Monitor repo root):
rem    buildAndflash-xiaozhi.bat
rem    buildAndflash-xiaozhi.bat -p COM5
rem    buildAndflash-xiaozhi.bat monitor
rem    buildAndflash-xiaozhi.bat monitor -p COM5
rem
rem  All paths are relative to this script (ADHD_Monitor repo root).
rem  Optional: esp_idf_path.txt (relative or absolute path to export.bat)
rem =========================================================================

set "REPO_ROOT=%~dp0"
if "%REPO_ROOT:~-1%"=="\" set "REPO_ROOT=%REPO_ROOT:~0,-1%"
set "PROJECT_REL=xiaozhi-esp32-2.2.4"
set "PROJECT_DIR=%REPO_ROOT%\%PROJECT_REL%"
set "SCRIPT_NAME=buildAndflash-xiaozhi"

if not exist "%PROJECT_DIR%\CMakeLists.txt" (
  echo [%SCRIPT_NAME%] ERROR: project not found:
  echo   %PROJECT_REL%  ^(from repo root^)
  echo   %PROJECT_DIR%
  exit /b 1
)

echo.
echo ============================================
echo   XIAOZHI star robot firmware
echo   Project: %PROJECT_REL%
echo   Board:  Xingzhi CUBE 1.54 TFT WiFi
echo   Log tag: XINGZHI_CUBE / Application (NOT LCD_TEST)
echo ============================================
echo.

set "MODE=build"
if /i "%~1"=="monitor" (
  set "MODE=monitor"
  shift
)

cd /d "%PROJECT_DIR%"
if errorlevel 1 exit /b 1

call "%REPO_ROOT%\_idf_export.bat"
if errorlevel 1 exit /b 1

echo [%SCRIPT_NAME%] PROJECT_DIR=%CD%
echo [%SCRIPT_NAME%] IDF_PATH=%IDF_PATH%
echo [%SCRIPT_NAME%] Mode=%MODE%  Extra args: %*
echo.

if /i "%MODE%"=="monitor" (
  echo [%SCRIPT_NAME%] Starting serial monitor...
  echo [%SCRIPT_NAME%] Expect log: SKU=xingzhi-cube-1.54tft-wifi
  idf.py monitor %*
  exit /b %ERRORLEVEL%
)

set "EXPECTED_BOARD=CONFIG_BOARD_TYPE_XINGZHI_CUBE_1_54TFT_WIFI=y"

if not exist "%CD%\sdkconfig" (
  echo [%SCRIPT_NAME%] sdkconfig missing, running set-target esp32s3...
  idf.py set-target esp32s3
  if errorlevel 1 exit /b 1
  echo.
)

findstr /x /c:"%EXPECTED_BOARD%" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] ERROR: Wrong board in sdkconfig.
  echo [%SCRIPT_NAME%] Required: %EXPECTED_BOARD%
  echo.
  echo [%SCRIPT_NAME%] Fix once ^(from repo root^):
  echo   cd %PROJECT_REL%
  echo   idf.py fullclean
  echo   del sdkconfig
  echo   idf.py set-target esp32s3
  echo   idf.py reconfigure
  echo   cd ..
  echo   buildAndflash-xiaozhi.bat -p COM5
  echo.
  exit /b 1
)

findstr /x /c:"CONFIG_ADHD_KIDS_UI=y" "%CD%\sdkconfig" >nul 2>&1
if errorlevel 1 (
  echo [%SCRIPT_NAME%] WARNING: CONFIG_ADHD_KIDS_UI is not enabled in sdkconfig.
  echo [%SCRIPT_NAME%] Run: idf.py reconfigure   or add CONFIG_ADHD_KIDS_UI=y
  echo.
)

echo [%SCRIPT_NAME%] Running: idf.py %* build flash
idf.py %* build flash
if errorlevel 1 exit /b 1

echo.
echo [%SCRIPT_NAME%] SUCCESS: xiaozhi build and flash done.
echo [%SCRIPT_NAME%] Monitor: buildAndflash-xiaozhi.bat monitor %*
echo [%SCRIPT_NAME%] Do NOT use buildAndflash-lcd147.bat on the star robot board.
echo.

endlocal
exit /b 0
