# Pre-Reboot Checklist für Podman Installation

Diese Checkliste sollte **nach** `Install-Master.ps1` und **vor dem Reboot** ausgeführt werden.

## Automatisierte Prüfung (PowerShell)

```powershell
# Speichere dies als PreReboot-Check.ps1 und führe es aus:

$checks = @()
$allPassed = $true

# 1. WSL2 Features aktiviert?
Write-Host "[1/10] Prüfe WSL2 Features..." -ForegroundColor Cyan
$wslFeature = Get-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"
$vmpFeature = Get-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"
if ($wslFeature.State -eq 'Enabled' -and $vmpFeature.State -eq 'Enabled') {
    Write-Host "  ✓ WSL2 und VirtualMachinePlatform aktiviert" -ForegroundColor Green
} else {
    Write-Host "  ✗ WSL2 Features NICHT aktiviert (benötigt Neustart)" -ForegroundColor Yellow
    $allPassed = $false
}

# 2. Podman Desktop installiert?
Write-Host "[2/10] Prüfe Podman Desktop Installation..." -ForegroundColor Cyan
$podmanExe = "C:\Program Files\Podman Desktop\Podman Desktop.exe"
if (Test-Path $podmanExe) {
    Write-Host "  ✓ Podman Desktop installiert: C:\Program Files\Podman Desktop" -ForegroundColor Green
} else {
    # Fallback: AppX Package prüfen
    $podmanAppx = Get-AppxPackage *podman* -ErrorAction SilentlyContinue
    if ($podmanAppx) {
        Write-Host "  ✓ Podman Desktop installiert (AppX Version: $($podmanAppx.Version))" -ForegroundColor Green
    } else {
        Write-Host "  ✗ Podman Desktop NICHT gefunden" -ForegroundColor Red
        $allPassed = $false
    }
}

# 3. Scheduled Tasks existieren?
Write-Host "[3/10] Prüfe Scheduled Tasks..." -ForegroundColor Cyan
$tasks = Get-ScheduledTask -TaskName "Podman-*" -ErrorAction SilentlyContinue
if ($tasks.Count -ge 2) {
    Write-Host "  ✓ $($tasks.Count) Podman-Tasks gefunden:" -ForegroundColor Green
    foreach ($task in $tasks) { Write-Host "    - $($task.TaskName)" }
} else {
    Write-Host "  ✗ Scheduled Tasks fehlen (erwartet: 2, gefunden: $($tasks.Count))" -ForegroundColor Red
    $allPassed = $false
}

# 4. SecureStorage Verzeichnis existiert?
Write-Host "[4/10] Prüfe SecureStorage Verzeichnis..." -ForegroundColor Cyan
try {
    # Lese den Pfad aus podman-config.json (gleicher Pfad wie Install-Master.ps1)
    $configPath = "$PSScriptRoot\podman-config.json"
    if (Test-Path $configPath) {
        $config = Get-Content -Path $configPath -Raw | ConvertFrom-Json
        $secureDir = $config.Paths.SecureStorage
    } else {
        # Fallback: Standardpfad aus README.md
        $secureDir = "C:\\ProgramData\\CorporateIT\\Podman"
    }
    
    if (Test-Path $secureDir) {
        Write-Host "  ✓ SecureStorage existiert: $secureDir" -ForegroundColor Green
    } else {
        Write-Host "  ✗ SecureStorage NICHT gefunden ($secureDir)" -ForegroundColor Red
        $allPassed = $false
    }
} catch {
    Write-Host "  ✗ Fehler beim Lesen von podman-config.json: $_" -ForegroundColor Red
    $allPassed = $false
}

# 5. Gruppe 'podman-users' existiert?
Write-Host "[5/10] Prüfe podman-users Gruppe..." -ForegroundColor Cyan
try {
    $group = Get-LocalGroup -Name "podman-users"
    Write-Host "  ✓ Gruppe 'podman-users' existiert" -ForegroundColor Green
} catch {
    Write-Host "  ✗ Gruppe 'podman-users' NICHT gefunden" -ForegroundColor Yellow
}

# 6. podman-config.json kopiert?
Write-Host "[6/10] Prüfe podman-config.json..." -ForegroundColor Cyan
if (Test-Path "$secureDir\podman-config.json") {
    Write-Host "  ✓ podman-config.json vorhanden" -ForegroundColor Green
} else {
    Write-Host "  ✗ podman-config.json NICHT gefunden" -ForegroundColor Red
    $allPassed = $false
}

# 7. PowerShell Skripte kopiert?
Write-Host "[7/10] Prüfe PowerShell Skripte..." -ForegroundColor Cyan
$scripts = @("Init-PodmanUser.ps1", "SelfHeal-Podman.ps1")
foreach ($script in $scripts) {
    if (Test-Path "$secureDir\$script") {
        Write-Host "  ✓ $script vorhanden" -ForegroundColor Green
    } else {
        Write-Host "  ✗ $script NICHT gefunden" -ForegroundColor Red
        $allPassed = $false
    }
}

# 8. EventLog Quelle 'PodmanHeal' registriert?
Write-Host "[8/10] Prüfe EventLog Quelle..." -ForegroundColor Cyan
if ([System.Diagnostics.EventLog]::SourceExists("PodmanHeal")) {
    Write-Host "  ✓ EventLog Quelle 'PodmanHeal' existiert" -ForegroundColor Green
} else {
    Write-Host "  ✗ EventLog Quelle 'PodmanHeal' NICHT registriert" -ForegroundColor Yellow
}

# 9. WSL Distribution existiert?
Write-Host "[9/10] Prüfe Podman Machine..." -ForegroundColor Cyan
try {
    $machines = podman machine ls --format json | ConvertFrom-Json
    if ($machines) {
        Write-Host "  ✓ $($machines.Count) Podman Machine(n) gefunden:" -ForegroundColor Green
        foreach ($m in $machines) { Write-Host "    - $($m.Name)" }
    } else {
        Write-Host "  ⚠ Keine Podman Machines (wird beim ersten Login erstellt)" -ForegroundColor Yellow
    }
} catch {
    Write-Host "  ✗ podman machine ls fehlgeschlagen: $_" -ForegroundColor Red
}

# 10. Docker Host Variable gesetzt?
Write-Host "[10/10] Prüfe DOCKER_HOST Variable..." -ForegroundColor Cyan
$dockerHost = [Environment]::GetEnvironmentVariable("DOCKER_HOST", "Machine")
if ($dockerHost) {
    Write-Host "  ✓ DOCKER_HOST gesetzt: $dockerHost" -ForegroundColor Green
} else {
    Write-Host "  ✗ DOCKER_HOST NICHT gesetzt" -ForegroundColor Red
    $allPassed = $false
}

# Zusammenfassung
Write-Host "`n=========================================" -ForegroundColor Cyan
if ($allPassed) {
    Write-Host "✓ ALLE CHECKS BESTANDEN!" -ForegroundColor Green
    Write-Host "Du kannst jetzt sicher neu starten." -ForegroundColor Green
} else {
    Write-Host "⚠ EINIGE CHECKS SIND GEFEHLSCHLAGEN" -ForegroundColor Yellow
    Write-Host "Überprüfe die obigen Fehlermeldungen vor dem Neustart." -ForegroundColor Yellow
}
Write-Host "=========================================" -ForegroundColor Cyan
```

## Manuelles Prüfen (falls PowerShell nicht verfügbar)

```cmd
:: 1. WSL Features prüfen
DISM /Online /Get-Features | findstr /i "Subsystem-Linux VirtualMachinePlatform"

:: 2. Scheduled Tasks auflisten
schtasks /query /FO LIST /TN "Podman-*"

:: 3. Verzeichnis prüfen
dir "%ALLUSERSPROFILE%\podman-storage"

:: 4. Gruppe prüfen
net localgroup podman-users
```

## Nach dem Reboot: Validierung

```powershell
# Prüfe ob SelfHeal beim Boot lief
Get-EventLog -LogName Application -Source "PodmanHeal" -Newest 5

# Prüfe ob Podman Machine läuft
podman machine ls --format json | ConvertFrom-Json | Select-Object Name, Running
```
