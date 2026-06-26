@echo off
color 0B
echo Fordere Administratorrechte an...
:: PowerShell-Trick, um sich selbst als Admin aufzurufen und das Master-Skript zu starten
powershell.exe -Command "Start-Process powershell.exe -ArgumentList '-NoProfile -ExecutionPolicy Bypass -File \"%~dp0Install-Master.ps1\"' -Verb RunAs"