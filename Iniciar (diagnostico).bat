@echo off
rem Igual que Iniciar.bat pero deja visible la consola para ver errores
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0OptimizadorPC.ps1" -Consola
pause
