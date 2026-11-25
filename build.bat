@echo off
rem Packages the plugin into dist\ as a zip ready to unpack into KOReader's
rem "plugins" folder. The version number comes from _meta.lua.
rem
rem   dist\focusline.koplugin.v<version>.zip
rem   dist\focusline.koplugin.zip            (same file, fixed name)
rem
rem Double-click this file, or run "build.bat" from a terminal.
rem "build.bat --no-pause" never waits for a key press (for scripts).
setlocal

set "PS=powershell"
where pwsh >nul 2>nul && set "PS=pwsh"

%PS% -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build-dist.ps1"
set "RC=%ERRORLEVEL%"

if not "%RC%"=="0" echo.& echo Build failed.

rem Started by double-click: keep the window open so the result can be read.
if /i "%~1"=="--no-pause" exit /b %RC%
echo %cmdcmdline% | findstr /i /c:"%~nx0" >nul && pause

exit /b %RC%
