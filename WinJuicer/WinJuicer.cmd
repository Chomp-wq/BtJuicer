@echo off
rem Doble clic para abrir Win Juicer. El script pide permisos de administrador
rem por su cuenta; -ExecutionPolicy Bypass evita que la politica de ejecucion
rem de PowerShell lo bloquee.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0WinJuicer.ps1" %*
if errorlevel 1 pause
