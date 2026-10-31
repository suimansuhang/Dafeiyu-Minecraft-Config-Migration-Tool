@echo off
rem ==========================================================
rem  Minecraft modpack config migrator - GUI launcher
rem  Double-click this file. No Python/.NET install needed.
rem ==========================================================
setlocal
cd /d "%~dp0"

if not exist "%~dp0mc-migrate.ps1" (
    echo [ERROR] mc-migrate.ps1 not found next to this file.
    pause
    exit /b 1
)

start "" powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0mc-migrate.ps1"
exit /b 0
