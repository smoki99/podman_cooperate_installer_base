<#
.SYNOPSIS
    Haupt-Installer. Aktiviert WSL, installiert Podman, richtet Tasks ein.
    SAFE CODE: Validiert Installer-Pfad und Rechte.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Sicherheits-Check: Ist Skript Admin?
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw "Dieses Skript muss als Administrator ausgefuehrt werden!"
}

$InstallDir = $PSScriptRoot
$SecureDir = "C:\ProgramData\CorporateIT\Podman"
$ExePath = Join-Path -Path $InstallDir -ChildPath "podman-desktop-setup.exe"

if (-not (Test-Path -Path $ExePath)) { throw "Installer $ExePath nicht gefunden!" }

Write-Host "[1/4] Erstelle sicheres Verzeichnis und kopiere Dateien..." -ForegroundColor Cyan
if (-not (Test-Path -Path $SecureDir)) { New-Item -Path $SecureDir -ItemType Directory -Force | Out-Null }

Copy-Item -Path "$InstallDir\podman-config.json" -Destination $SecureDir -Force
Copy-Item -Path "$InstallDir\Init-PodmanUser.ps1" -Destination $SecureDir -Force
Copy-Item -Path "$InstallDir\SelfHeal-Podman.ps1" -Destination $SecureDir -Force
if (Test-Path -Path "$InstallDir\CorporateRootCA.cer") {
    Copy-Item -Path "$InstallDir\CorporateRootCA.cer" -Destination $SecureDir -Force
}

Write-Host "[2/4] Aktiviere WSL2 Features (VirtualMachinePlatform)..." -ForegroundColor Cyan
Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform" -All -NoRestart -ErrorAction SilentlyContinue
Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux" -All -NoRestart -ErrorAction SilentlyContinue

Write-Host "[3/4] Installiere Podman Desktop..." -ForegroundColor Cyan
$installProc = Start-Process -FilePath $ExePath -ArgumentList "/S", "/allusers" -Wait -NoNewWindow -PassThru
if ($installProc.ExitCode -ne 0) { throw "Fehler bei der Installation der .exe (ExitCode: $($installProc.ExitCode))" }

Write-Host "[4/4] Registriere Scheduled Tasks (User-Init und Self-Healing)..." -ForegroundColor Cyan

# Task 1: User Init (Läuft als normaler User beim Login)
$UserAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SecureDir\Init-PodmanUser.ps1`""
$UserTrigger = New-ScheduledTaskTrigger -AtLogon
$UserPrincipal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
Register-ScheduledTask -TaskName "Podman-User-Init" -Action $UserAction -Trigger $UserTrigger -Principal $UserPrincipal -Force | Out-Null

# Task 2: Self Healing (Läuft als SYSTEM bei Boot & AnyConnect VPN Events)
$HealAction = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SecureDir\SelfHeal-Podman.ps1`""
$HealTriggerBoot = New-ScheduledTaskTrigger -AtStartup
Register-ScheduledTask -TaskName "Podman-SelfHeal" -Action $HealAction -Trigger $HealTriggerBoot -User "SYSTEM" -RunLevel Highest -Force | Out-Null

Write-Host "`n=== Installation abgeschlossen! ===" -ForegroundColor Green
Write-Host "WICHTIG: Bitte starte den Computer jetzt neu, damit WSL aktiviert wird." -ForegroundColor Yellow