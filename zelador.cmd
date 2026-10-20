@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0zelador.ps1" %*
if "%~1"=="" pause
