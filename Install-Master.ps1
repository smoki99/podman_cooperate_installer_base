<#
.SYNOPSIS
    Haupt-Installer (Robust). Aktiviert WSL, installiert Podman, richtet Tasks ein.
    SAFE CODE: Validiert Installer-Pfad und Rechte. Idempotent - kann mehrfach ausgeführt werden.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function Write-InstallLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    switch ($Level) {
        'Info' { Write-Host "[$timestamp] INFO:  $Message" -ForegroundColor Cyan }
        'Warning' { Write-Host "[$timestamp] WARN:  $Message" -ForegroundColor Yellow }
        'Error' { Write-Host "[$timestamp] ERROR: $Message" -ForegroundColor Red }
    }
}

function Test-Administrator {
    return ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ============================================================================
# MAIN INSTALLATION LOGIC
# ============================================================================

$InstallDir  = $PSScriptRoot
$ExePath     = Join-Path -Path $InstallDir -ChildPath "podman-desktop-setup.exe"
$ConfigPath  = Join-Path -Path $InstallDir -ChildPath "podman-config.json"

# -----------------------------------------------------------------------------
# STEP 0: PRE-CHECKS
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Starte Install-Master.ps1..." -Level Info

if (-not (Test-Administrator)) {
    Write-InstallLog -Message "Fehler: Skript muss als Administrator ausgeführt werden!" -Level Error
    exit 1
}

if (-not (Test-Path -Path $ExePath)) {
    Write-InstallLog -Message "Fehler: Installer $ExePath nicht gefunden!" -Level Error
    exit 2
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-InstallLog -Message "Fehler: Konfigurationsdatei $ConfigPath nicht gefunden!" -Level Error
    exit 3
}

# SecureDir aus podman-config.json lesen
$Config    = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$SecureDir = $Config.Paths.SecureStorage

# -----------------------------------------------------------------------------
# STEP 1: CLEANUP - Entferne alte Scheduled Tasks (Idempotenz)
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Entferne existierende Podman-* Scheduled Tasks..." -Level Info
try {
    $oldTasks = Get-ScheduledTask | Where-Object {$_.TaskName -like "Podman-*"}
    foreach ($task in $oldTasks) {
        Write-InstallLog -Message "  Entferne Task: $($task.TaskName)" -Level Info
        Unregister-ScheduledTask -TaskName $task.TaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
} catch {
    Write-InstallLog -Message "Warnung beim Cleanup alter Tasks: $_" -Level Warning
}

# -----------------------------------------------------------------------------
# STEP 2: SECURE STORAGE SETUP
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Erstelle sicheres Verzeichnis '$SecureDir'..." -Level Info
try {
    if (-not (Test-Path -Path $SecureDir)) {
        New-Item -Path $SecureDir -ItemType Directory -Force | Out-Null
        Write-InstallLog -Message "  Verzeichnis erstellt." -Level Info
    } else {
        Write-InstallLog -Message "  Verzeichnis existiert bereits." -Level Info
    }
} catch {
    Write-InstallLog -Message "Fehler beim Erstellen von SecureStorage: $_" -Level Error
    exit 4
}

# Dateien kopieren mit Verifizierung
$filesToCopy = @(
    @{ Source = "podman-config.json" },
    @{ Source = "Init-PodmanUser.ps1" },
    @{ Source = "SelfHeal-Podman.ps1" }
)

foreach ($file in $filesToCopy) {
    $sourcePath = Join-Path -Path $InstallDir -ChildPath $file.Source
    if (Test-Path -Path $sourcePath) {
        Copy-Item -Path $sourcePath -Destination $SecureDir -Force
        Write-InstallLog -Message "  Kopiert: $($file.Source)" -Level Info
    }
}

# CorporateRootCA.cer optional kopieren
if (Test-Path -Path "$InstallDir\CorporateRootCA.cer") {
    Copy-Item -Path "$InstallDir\CorporateRootCA.cer" -Destination $SecureDir -Force
    Write-InstallLog -Message "  Kopiert: CorporateRootCA.cer" -Level Info
}

# -----------------------------------------------------------------------------
# STEP 3: NTFS ACL SETUP
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Erstelle lokale Gruppe 'podman-users'..." -Level Info
try {
    New-LocalGroup -Name "podman-users" `
        -Description "Autorisierte Podman-Entwickler (IT-verwaltet)" `
        -ErrorAction SilentlyContinue
} catch {
    Write-InstallLog -Message "Warnung: Gruppe 'podman-users' konnte nicht erstellt werden: $_" -Level Warning
}

Write-InstallLog -Message "Setze NTFS-ACLs auf '$SecureDir'..." -Level Info
try {
    & icacls $SecureDir /inheritance:r                          | Out-Null
    & icacls $SecureDir /grant "SYSTEM:(OI)(CI)F"              | Out-Null
    & icacls $SecureDir /grant "BUILTIN\Administrators:(OI)(CI)F" | Out-Null
    if (Get-LocalGroup -Name "podman-users" -ErrorAction SilentlyContinue) {
        & icacls $SecureDir /grant "podman-users:(OI)(CI)RX"   | Out-Null
    }
    & icacls $SecureDir /remove "BUILTIN\Users"                | Out-Null
    & icacls $SecureDir /remove "Everyone"                     | Out-Null
} catch {
    Write-InstallLog -Message "Warnung: ACLs konnten nicht vollständig gesetzt werden: $_" -Level Warning
}

# -----------------------------------------------------------------------------
# STEP 4: WSL FEATURES ACTIVATION
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Aktiviere WSL2 Features..." -Level Info
try {
    Enable-WindowsOptionalFeature -Online -FeatureName "VirtualMachinePlatform"             -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
    Enable-WindowsOptionalFeature -Online -FeatureName "Microsoft-Windows-Subsystem-Linux"  -All -NoRestart -ErrorAction SilentlyContinue | Out-Null
} catch {
    Write-InstallLog -Message "Warnung: WSL Features konnten nicht aktiviert werden: $_" -Level Warning
}

# -----------------------------------------------------------------------------
# STEP 5: PODMAN DESKTOP INSTALLATION
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Installiere Podman Desktop..." -Level Info
try {
    $installProc = Start-Process -FilePath $ExePath -ArgumentList "/S", "/allusers" -Wait -NoNewWindow -PassThru
    if ($installProc.ExitCode -ne 0) {
        Write-InstallLog -Message "Fehler bei der Installation (ExitCode: $($installProc.ExitCode))" -Level Error
        exit 5
    }
    Write-InstallLog -Message "Podman Desktop erfolgreich installiert." -Level Info
} catch {
    Write-InstallLog -Message "Fehler beim Starten des Installers: $_" -Level Error
    exit 6
}

# -----------------------------------------------------------------------------
# STEP 6: SCHEDULED TASKS REGISTRATION
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Registriere Scheduled Tasks..." -Level Info

$tasksRegistered = @()

try {
    # Task 1: User Init (läuft als Mitglied von 'podman-users' beim Login)
    $UserAction    = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SecureDir\Init-PodmanUser.ps1`""
    $UserTrigger   = New-ScheduledTaskTrigger -AtLogon
    
    # Prüfen ob Gruppe existiert, falls nicht: Fallback zu BUILTIN\Users
    if (Get-LocalGroup -Name "podman-users" -ErrorAction SilentlyContinue) {
        $UserPrincipal = New-ScheduledTaskPrincipal -GroupId "podman-users" -RunLevel Limited
    } else {
        Write-InstallLog -Message "Warnung: Gruppe 'podman-users' nicht gefunden, verwende BUILTIN\Users" -Level Warning
        $UserPrincipal = New-ScheduledTaskPrincipal -GroupId "BUILTIN\Users" -RunLevel Limited
    }
    
    Register-ScheduledTask -TaskName "Podman-User-Init" `
        -Action $UserAction -Trigger $UserTrigger -Principal $UserPrincipal -Force | Out-Null
    $tasksRegistered += "Podman-User-Init"
    Write-InstallLog -Message "  Task 'Podman-User-Init' registriert." -Level Info
} catch {
    Write-InstallLog -Message "Fehler beim Registrieren von Podman-User-Init: $_" -Level Error
}

try {
    # Task 2: Self Healing (läuft als SYSTEM bei Boot und bei VPN-Ereignissen)
    $HealAction      = New-ScheduledTaskAction -Execute "powershell.exe" `
        -Argument "-WindowStyle Hidden -ExecutionPolicy Bypass -File `"$SecureDir\SelfHeal-Podman.ps1`""
    $HealTriggerBoot = New-ScheduledTaskTrigger -AtStartup
    
    # Event-Trigger für Cisco AnyConnect VPN (nur wenn AnyConnect installiert ist)
    $HealTriggers = @($HealTriggerBoot)
    if (Get-EventLog -LogName Application -Source "acvpnagent" -ErrorAction SilentlyContinue) {
        try {
            $HealTriggerVPN = New-ScheduledTaskTrigger -OnEvent `
                -LogName "Application" `
                -Source "acvpnagent" `
                -Id 2039
            $HealTriggers += $HealTriggerVPN
        } catch {
            Write-InstallLog -Message "Warnung: Event-Trigger für AnyConnect konnte nicht erstellt werden: $_" -Level Warning
        }
    }
    
    Register-ScheduledTask -TaskName "Podman-SelfHeal" `
        -Action $HealAction `
        -Trigger $HealTriggers `
        -User "SYSTEM" -RunLevel Highest -Force | Out-Null
    $tasksRegistered += "Podman-SelfHeal"
    Write-InstallLog -Message "  Task 'Podman-SelfHeal' registriert." -Level Info
} catch {
    Write-InstallLog -Message "Fehler beim Registrieren von Podman-SelfHeal: $_" -Level Error
}

# -----------------------------------------------------------------------------
# STEP 7: VALIDATION
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Validiere Installation..." -Level Info
$expectedTasks = @("Podman-User-Init", "Podman-SelfHeal")
$missingTasks = @($expectedTasks | Where-Object { $_ -notin $tasksRegistered })

if ($missingTasks.Count -gt 0) {
    Write-InstallLog -Message "WARNUNG: Folgende Tasks wurden NICHT erstellt: $($missingTasks -join ', ')" -Level Warning
}

# -----------------------------------------------------------------------------
# STEP 8: COMPLETION
# -----------------------------------------------------------------------------
Write-InstallLog -Message "=== Installation abgeschlossen! ===" -Level Info
Write-InstallLog -Message "WICHTIG: Bitte starte den Computer jetzt neu, damit WSL aktiviert wird." -Level Warning

# Exit-Code 3010 signalisiert Intune/SCCM, dass ein Neustart erforderlich ist.
exit 3010
