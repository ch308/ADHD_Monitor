@echo off
rem Legacy name: forwards to xiaozhi star robot monitor.
echo [monitor.bat] Use buildAndflash-xiaozhi.bat monitor  (star robot)
echo              or buildAndflash-lcd147.bat monitor     (1.47B ball)
echo.
call "%~dp0buildAndflash-xiaozhi.bat" monitor %*
