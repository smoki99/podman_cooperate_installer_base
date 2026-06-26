<#
.SYNOPSIS
    User-Context Skript. Initialisiert Podman, erzwingt Registries und Zertifikate.
    SAFE CODE: Strict Mode und Fehlerbehandlung aktiviert.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# LOGGING FUNCTIONS WITH ROTATION
# ============================================================================

function Write-PodmanLog {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')] [string]$Level = 'Info'
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    
    # Console output with colors
    switch ($Level) {
        'Info' { Write-Host "[$timestamp] INFO:  $Message" -ForegroundColor Cyan }
        'Warning' { Write-Host "[$timestamp] WARN:  $Message" -ForegroundColor Yellow }
        'Error' { Write-Host "[$timestamp] ERROR: $Message" -ForegroundColor Red }
    }
    
    # Log file output with rotation (keep last 50 lines)
    $LogFilePath = "$env:APPDATA\Podman Desktop\podman-init.log"
    if (Test-Path $LogFilePath) {
        # Keep only last 50 lines to prevent log from growing too large
        Get-Content -Path $LogFilePath | Select-Object -Last 50 | Set-Content -Path $LogFilePath -NoNewline
    }
    Add-Content -Path $LogFilePath -Value "[$timestamp] [$Level] $Message"
}

# ============================================================================
# HELPER FUNCTIONS
# ============================================================================

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $drive = $WinPath[0].ToString().ToLower()
    $rest  = $WinPath.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

# ============================================================================
# MAIN INITIALIZATION LOGIC
# ============================================================================

$success = $false
try {
    Write-PodmanLog -Message "=== Podman User Init Started ===" -Level Info
    Write-PodmanLog -Message "User: $($env:USERNAME)" -Level Info
    
    # Note: PATH modification is handled by Install-Master.ps1 (admin context).
    # This script runs as limited user and cannot modify Machine PATH.
    
    $AppDataConfig  = "$env:APPDATA\Podman Desktop"
    $SettingsFile   = "$AppDataConfig\settings.json"
    # $PSScriptRoot zeigt auf das Verzeichnis, in das Install-Master.ps1 die Skripte kopiert hat
    # (Paths.SecureStorage). So funktioniert der Pfad unabhängig vom konfigurierten SecureStorage-Wert.
    $ConfigJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "podman-config.json"
    
    Write-PodmanLog -Message "Loading config from: $ConfigJsonPath" -Level Info
    if (-not (Test-Path -Path $ConfigJsonPath)) {
        throw "Konfigurationsdatei nicht gefunden: $ConfigJsonPath"
    }
    $Config         = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # 1. UI und Zertifikat-Sync vorkonfigurieren
    Write-PodmanLog -Message "Setting up Podman Desktop settings..." -Level Info
    if (-not (Test-Path -Path $AppDataConfig)) {
        New-Item -Path $AppDataConfig -ItemType Directory -Force | Out-Null
        Write-PodmanLog -Message "Created directory: $AppDataConfig" -Level Info
    }

    $SettingsJson = @{
        "telemetry.optIn"                                  = $false
        "preferences.UpdateDisabled"                       = $true
        "preferences.StartAutomatically"                   = $true
        "kubernetes.extensions.minikube"                   = $false
        "os.checkWsl"                                      = $false
        "engine.podman.machine.syncSystemCertificates"     = $true
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $SettingsFile -Value $SettingsJson -Force -Encoding UTF8
    Write-PodmanLog -Message "Settings written to: $SettingsFile" -Level Info

    # 2. Maschine initialisieren, falls noch nicht vorhanden.
    # @() erzwingt Array-Kontext, damit .Count bei einem einzelnen Objekt korrekt funktioniert.
    Write-PodmanLog -Message "Checking existing Podman machines..." -Level Info
    $machineStatus = @(podman machine ls --format json 2>&1 | ConvertFrom-Json)
    
    if ($machineStatus.Count -eq 0) {
        Write-PodmanLog -Message "No machines found. Initializing new Podman Machine..." -Level Info
        
        $initProcess = Start-Process -FilePath "podman" `
            -ArgumentList "machine", "init", "--rootful=false" `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\podman-init-output.txt"
        
        if ($initProcess.ExitCode -ne 0) {
            $output = Get-Content -Path "$env:TEMP\podman-init-output.txt" -Raw
            throw "Fehler bei podman machine init (ExitCode: $($initProcess.ExitCode)). Output: $output"
        }
        Write-PodmanLog -Message "Podman machine initialized successfully." -Level Info

        # 3. WSL-interne Härtung: /etc/wsl.conf konfigurieren
        # Setzt non-root Standard-User, sichere Automount-Optionen und sperrt Interop
        # (WSL-Prozesse dürfen keine Windows-Executables starten).
        Write-PodmanLog -Message "Configuring WSL hardening (/etc/wsl.conf)..." -Level Info
        $WslConfContent = @"
[user]
default=user

[automount]
enabled=true
options=metadata,umask=022,fmask=011

[interop]
enabled=false
appendWindowsPath=false
"@
        $TempWslConf    = "$env:TEMP\wsl.conf"
        # Write UTF8 without BOM using .NET encoding class
        $utf8NoBom = New-Object System.Text.UTF8Encoding $false
        [System.IO.File]::WriteAllText($TempWslConf, $WslConfContent, $utf8NoBom)
        $WslTempWslConf = ConvertTo-WslPath -WinPath $TempWslConf
        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "cp", $WslTempWslConf, "/etc/wsl.conf" `
            -Wait -NoNewWindow
        Remove-Item -Path $TempWslConf -Force -ErrorAction SilentlyContinue
        Write-PodmanLog -Message "WSL hardening configured." -Level Info

        # 4. Transparent Proxy: Root-CA-Zertifikat in Linux-Trust-Store injizieren
        $CertPath = Join-Path -Path $PSScriptRoot -ChildPath "CorporateRootCA.cer"
        if (Test-Path -Path $CertPath) {
            Write-PodmanLog -Message "Installing Corporate Root CA certificate..." -Level Info
            $WslCertPath = ConvertTo-WslPath -WinPath $CertPath
            Start-Process -FilePath "wsl" `
                -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
                "cp", $WslCertPath, "/etc/pki/ca-trust/source/anchors/" `
                -Wait -NoNewWindow
            Start-Process -FilePath "wsl" `
                -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
                "update-ca-trust" `
                -Wait -NoNewWindow
            Write-PodmanLog -Message "Corporate Root CA installed." -Level Info
        } else {
            Write-PodmanLog -Message "No CorporateRootCA.cer found, skipping certificate installation." -Level Warning
        }

        # 5. Zero-Trust Registry: Nur Firmen-Registry erlauben
        Write-PodmanLog -Message "Configuring registry policies..." -Level Info
        $PolicyJson = @"
{
  "default": [{"type": "reject"}],
  "transports": {
    "docker": {
      "$($Config.Registries.AllowedSearchRegistry)": [{"type": "insecureAcceptAnything"}],
      "mcr.microsoft.com": [{"type": "insecureAcceptAnything"}]
    }
  }
}
"@
        $RegistriesConf = "unqualified-search-registries = [""$($Config.Registries.AllowedSearchRegistry)""]"

        $TempPolicy = "$env:TEMP\policy.json"
        $TempReg    = "$env:TEMP\99-corp.conf"
        Set-Content -Path $TempPolicy -Value $PolicyJson   -Force -Encoding utf8NoBOM
        Set-Content -Path $TempReg    -Value $RegistriesConf -Force -Encoding utf8NoBOM

        $WslTempPolicy = ConvertTo-WslPath -WinPath $TempPolicy
        $WslTempReg    = ConvertTo-WslPath -WinPath $TempReg

        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "cp", $WslTempPolicy, "/etc/containers/policy.json" `
            -Wait -NoNewWindow
        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "mkdir", "-p", "/etc/containers/registries.conf.d" `
            -Wait -NoNewWindow
        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "cp", $WslTempReg, "/etc/containers/registries.conf.d/99-corp-registries.conf" `
            -Wait -NoNewWindow

        Remove-Item -Path $TempPolicy, $TempReg -Force -ErrorAction SilentlyContinue
        Write-PodmanLog -Message "Registry policies configured." -Level Info

        # 6. Maschine starten und ExitCode prüfen
        Write-PodmanLog -Message "Starting Podman machine..." -Level Info
        $startProcess = Start-Process -FilePath "podman" `
            -ArgumentList "machine", "start" `
            -Wait -NoNewWindow -PassThru -RedirectStandardOutput "$env:TEMP\podman-start-output.txt"
        if ($startProcess.ExitCode -ne 0) {
            $output = Get-Content -Path "$env:TEMP\podman-start-output.txt" -Raw
            throw "Fehler bei podman machine start (ExitCode: $($startProcess.ExitCode)). Output: $output"
        }
        Write-PodmanLog -Message "Podman machine started successfully." -Level Info
    } else {
        Write-PodmanLog -Message "Machine already exists, skipping initialization." -Level Info
    }

    $success = $true
    Write-PodmanLog -Message "=== Podman User Init Completed Successfully ===" -Level Info

} catch {
    Write-PodmanLog -Message "Fehler im User-Init: $_" -Level Error
}
finally {
    # Scheduled Task nur bei erfolgreichem Abschluss entfernen.
    # Bei Fehler bleibt der Task erhalten und wird beim nächsten Login erneut versucht.
    if ($success) {
        Write-PodmanLog -Message "Removing scheduled task Podman-User-Init..." -Level Info
        Unregister-ScheduledTask -TaskName "Podman-User-Init" -Confirm:$false -ErrorAction SilentlyContinue
    } else {
        Write-PodmanLog -Message "Initialization failed. Task will retry on next login." -Level Warning
    }
}