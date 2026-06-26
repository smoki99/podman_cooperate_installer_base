<#
.SYNOPSIS
    Haupt-Installer (Robust). Aktiviert WSL, installiert Podman Desktop & CLI, richtet Machine ein.
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
    # Also write to log file
    Add-Content -Path $LogFilePath -Value "[$timestamp] [$Level] $Message"
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
$MsiPath     = Join-Path -Path $InstallDir -ChildPath "podman-installer-windows-amd64.msi"
$ConfigPath  = Join-Path -Path $InstallDir -ChildPath "podman-config.json"

# Create log file in temp directory for admin review
$LogFilePath = "$env:TEMP\podman-install.log"

# -----------------------------------------------------------------------------
# STEP 0: PRE-CHECKS
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Starte Install-Master.ps1..." -Level Info
Write-InstallLog -Message "Installer Pfad: $ExePath" -Level Info
Write-InstallLog -Message "MSI Pfad: $MsiPath" -Level Info
Write-InstallLog -Message "Konfigurationsdatei: $ConfigPath" -Level Info

if (-not (Test-Administrator)) {
    Write-InstallLog -Message "Fehler: Skript muss als Administrator ausgeführt werden!" -Level Error
    exit 1
}

if (-not (Test-Path -Path $ExePath)) {
    Write-InstallLog -Message "Fehler: Installer $ExePath nicht gefunden!" -Level Error
    exit 2
}

if (-not (Test-Path -Path $MsiPath)) {
    Write-InstallLog -Message "Fehler: Podman MSI ($MsiPath) nicht gefunden!" -Level Error
    exit 40
}

if (-not (Test-Path -Path $ConfigPath)) {
    Write-InstallLog -Message "Fehler: Konfigurationsdatei $ConfigPath nicht gefunden!" -Level Error
    exit 3
}

# SecureDir aus podman-config.json lesen
$Config    = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
$SecureDir = $Config.Paths.SecureStorage
Write-InstallLog -Message "SecureStorage Pfad: $SecureDir" -Level Info

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
# STEP 4.1: SILENT WSL INSTALL/UPDATE (prevents Microsoft Store popup)
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Prüfe und installiere WSL (silent)..." -Level Info
try {
    # Check if wsl.exe exists and get its version
    $wslExe = "$env:SystemRoot\System32\wsl.exe"
    if (Test-Path $wslExe) {
        Write-InstallLog -Message "  WSL bereits installiert, prüfe auf Updates..." -Level Info
        # Run wsl --update silently to prevent popup prompts
        Start-Process -FilePath $wslExe -ArgumentList "--update", "--quiet" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\wsl-update.log" -RedirectStandardError "$env:TEMP\wsl-update-error.log" -ErrorAction SilentlyContinue | Out-Null
    } else {
        Write-InstallLog -Message "  WSL nicht installiert, installiere jetzt..." -Level Info
        # Download and install WSL silently from Microsoft Store (winget)
        Start-Process -FilePath "winget.exe" -ArgumentList "install", "Microsoft.Windows.Subsystem.Linux", "--silent", "--accept-package-agreements", "--accept-source-agreements" -Wait -NoNewWindow -RedirectStandardOutput "$env:TEMP\winget-wsl.log" -RedirectStandardError "$env:TEMP\winget-wsl-error.log" -ErrorAction SilentlyContinue | Out-Null
    }
} catch {
    Write-InstallLog -Message "Warnung: WSL Update/Installation konnte nicht durchgeführt werden: $_" -Level Warning
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
# STEP 5.1: PODMAN CLI INSTALLATION (via MSI)
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Installiere Podman CLI via MSI..." -Level Info
try {
    # Install podman-installer-windows-amd64.msi silently
    $msiProc = Start-Process -FilePath "msiexec.exe" `
        -ArgumentList "/i", "$MsiPath", "/qn", "/norestart" `
        -Wait -NoNewWindow -PassThru
    if ($msiProc.ExitCode -ne 0) {
        Write-InstallLog -Message "Fehler bei der MSI Installation (ExitCode: $($msiProc.ExitCode))" -Level Error
        exit 41
    }
    Write-InstallLog -Message "Podman CLI erfolgreich via MSI installiert." -Level Info
} catch {
    Write-InstallLog -Message "Fehler beim Starten der MSI Installation: $_" -Level Error
    exit 42
}

# -----------------------------------------------------------------------------
# STEP 5.2: PODMAN MACHINE INITIALIZATION (silent)
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Initialisiere Podman Machine..." -Level Info
try {
    $podmanExe = "$env:USERPROFILE\.local\bin\podman.exe"
    
    # Check if machine already exists
    $existingMachines = & $podmanExe machine list 2>$null | Select-String "Running|Stopped" -Context 0,1
    
    if ($existingMachines) {
        Write-InstallLog -Message "  Podman Machine existiert bereits, starte sie..." -Level Info
        & $podmanExe machine start --quiet 2>$null | Out-Null
    } else {
        Write-InstallLog -Message "  Erstelle neue Podman Machine (default)..." -Level Info
        # Initialize with default settings (silent, no interactive prompts)
        & $podmanExe machine init --quiet 2>$null | Out-Null
        & $podmanExe machine start --quiet 2>$null | Out-Null
    }
    
    Write-InstallLog -Message "  Podman Machine erfolgreich initialisiert." -Level Info
} catch {
    Write-InstallLog -Message "Warnung: Podman Machine Initialisierung fehlgeschlagen: $_" -Level Warning
}

# -----------------------------------------------------------------------------
# STEP 5.3: WINDOWS FIREWALL RULES (prevent interactive prompts)
# -----------------------------------------------------------------------------
Write-InstallLog -Message "Erstelle Windows Firewall Regeln..." -Level Info
try {
    # Podman Desktop application rule
    $podmanDesktopExe = "C:\Program Files\Podman Desktop\Podman Desktop.exe"
    if (Test-Path $podmanDesktopExe) {
        New-NetFirewallRule -DisplayName "Podman Desktop Outbound" `
            -Direction Outbound -Action Allow -Program $podmanDesktopExe `
            -Description "Erlaubt Podman Desktop ausgehende Verbindungen" | Out-Null
        Write-InstallLog -Message "  Firewall-Regel 'Podman Desktop Outbound' erstellt." -Level Info
    }
    
    # WSL2 network interface rule (allow all traffic on vEthernet adapter)
    $wslInterface = Get-NetAdapter | Where-Object {$_.Name -like "vEthernet*"} | Select-Object -First 1
    if ($wslInterface) {
        New-NetFirewallRule -DisplayName "WSL2 Network Interface" `
            -Direction Both -Action Allow -InterfaceAlias $wslInterface.Name `
            -Description "Erlaubt Netzwerkverkehr über WSL2 vEthernet Adapter" | Out-Null
        Write-InstallLog -Message "  Firewall-Regel 'WSL2 Network Interface' erstellt ($($wslInterface.Name))." -Level Info
    }
} catch {
    Write-InstallLog -Message "Warnung: Firewall-Regeln konnten nicht erstellt werden: $_" -Level Warning
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
        Write-InstallLog -Message "  Task Principal: podman-users group" -Level Info
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
Write-InstallLog -Message "Logfile gespeichert unter: $LogFilePath" -Level Info

# Exit-Code 3010 signalisiert Intune/SCCM, dass ein Neustart erforderlich ist.
exit 3010