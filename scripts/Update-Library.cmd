@echo off
rem Rescans the Jellyfin folders and writes ..\library.json
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Scan-Library.ps1"
echo.
echo Next: open the app, go to Settings, click "Import scan / backup..." and choose library.json.
echo New titles are added and owned seasons are updated; nothing you already have is lost.
pause
