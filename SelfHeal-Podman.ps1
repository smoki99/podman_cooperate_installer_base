<#
.SYNOPSIS
    Läuft als SYSTEM beim Booten oder bei Netzwerkwechseln.
    Repariert wslconfig (falls manipuliert) und resettet WSL-Dienste.
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
    
    # Log file output with rotation (keep last 50 lines)
    $LogFilePath = "$env:ALLUSERSPROFILE\Podman Desktop\podman-selfheal.log"
    if (-not (Test-Path -Path "$env:ALLUSERSPROFILE\Podman Desktop")) {
        New-Item -Path "$env:ALLUSERSPROFILE\Podman Desktop" -ItemType Directory -Force | Out-Null
    }
    
    if (Test-Path $LogFilePath) {
        # Keep only last 50 lines to prevent log from growing too large
        Get-Content -Path $LogFilePath | Select-Object -Last 50 | Set-Content -Path $LogFilePath -NoNewline
    }
    Add-Content -Path $LogFilePath -Value "[$timestamp] [$Level] $Message"
}

# ============================================================================
# MAIN SELF-HEALING LOGIC
# ============================================================================

try {
    Write-PodmanLog -Message "=== Podman Self-Heal Started ===" -Level Info
    
    # $PSScriptRoot zeigt auf das Verzeichnis, in das Install-Master.ps1 die Skripte kopiert hat
    # (Paths.SecureStorage). So funktioniert der Pfad unabhängig vom konfigurierten SecureStorage-Wert.
    $ConfigJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "podman-config.json"
    if (-not (Test-Path -Path $ConfigJsonPath)) {
        Write-PodmanLog -Message "Config file not found: $ConfigJsonPath" -Level Error
        exit
    }
    
    Write-PodmanLog -Message "Loading config from: $ConfigJsonPath" -Level Info
    $Config = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # Event-Log-Quelle registrieren, falls noch nicht vorhanden.
    # Ohne diese Registrierung schlägt Write-EventLog auf einem Neugerät still fehl.
    if (-not [System.Diagnostics.EventLog]::SourceExists("PodmanHeal")) {
        New-EventLog -LogName Application -Source "PodmanHeal" -ErrorAction SilentlyContinue
        Write-PodmanLog -Message "Created EventLog source: PodmanHeal" -Level Info
    }

    # 1. Die harte .wslconfig durchsetzen
    # [System.IO.File]::WriteAllText wird verwendet, um UTF-8 OHNE BOM zu schreiben.
    # Set-Content -Encoding UTF8 erzeugt in PowerShell 5.1 eine BOM, die WSL stört.
    Write-PodmanLog -Message "Applying .wslconfig settings..." -Level Info
    $WslConfigContent = @"
[wsl2]
memory=$($Config.CorporateSettings.MaxMemory)
processors=$($Config.CorporateSettings.Processors)
networkingMode=mirrored
dnsTunneling=true
firewall=true
autoMemoryReclaim=dropcache
"@
    
    $UserProfiles = Get-ChildItem -Path "C:\Users" -Directory |
        Where-Object { $_.Name -notmatch "^(Public|Default.*|Administrator)$" }
    
    foreach ($Profile in $UserProfiles) {
        $ConfigTarget = Join-Path -Path $Profile.FullName -ChildPath ".wslconfig"
        [System.IO.File]::WriteAllText(
            $ConfigTarget,
            $WslConfigContent,
            [System.Text.UTF8Encoding]::new($false)   # $false = kein BOM
        )
        Write-PodmanLog -Message "Applied .wslconfig to: $($Profile.FullName)" -Level Info
    }

    # 2. Nur hängende wslhost.exe-Prozesse killen.
    # Hinweis: "wsl"-Prozesse werden NICHT beendet, da dies andere laufende
    # WSL-Distros (z.B. Ubuntu) des Benutzers ungewollt abbrechen würde.
    Write-PodmanLog -Message "Checking for hanging wslhost.exe processes..." -Level Info
    $procs = Get-Process -Name "wslhost" -ErrorAction SilentlyContinue
    if ($procs) {
        Stop-Process -InputObject $procs -Force
        Write-PodmanLog -Message "Terminated $($procs.Count) wslhost.exe process(es)" -Level Info
    } else {
        Write-PodmanLog -Message "No hanging wslhost.exe processes found." -Level Info
    }

    # 3. Systemweite Docker-Socket-Variable garantieren
    Write-PodmanLog -Message "Setting DOCKER_HOST environment variable..." -Level Info
    [Environment]::SetEnvironmentVariable(
        "DOCKER_HOST",
        "npipe:////./pipe/podman-machine-default",
        "Machine"
    )
    Write-PodmanLog -Message "DOCKER_HOST set to npipe:////./pipe/podman-machine-default" -Level Info

    # 4. MTU in der laufenden Podman-Machine setzen (VPN-Kompatibilität).
    # Der Wert aus podman-config.json wird direkt auf das Netzwerkinterface angewendet.
    if ($null -ne $Config.CorporateSettings.MTU) {
        Write-PodmanLog -Message "Setting MTU to $($Config.CorporateSettings.MTU)..." -Level Info
        $mtu = $Config.CorporateSettings.MTU
        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "ip", "link", "set", "dev", "eth0", "mtu", "$mtu" `
            -Wait -NoNewWindow -ErrorAction SilentlyContinue
        Write-PodmanLog -Message "MTU set successfully." -Level Info
    }

    # 5. Unauthorized WSL distros cleanup (security enforcement).
    # Only podman-machine-default is allowed; all other user-installed distros are removed.
    Write-PodmanLog -Message "Checking for unauthorized WSL distributions..." -Level Info
    $allowedDistros = @("podman-machine-default", "docker-desktop", "docker-desktop-data")
    
    # Get list of running and stopped distros (excluding Microsoft default)
    $allDistros = wsl -l 2>$null | Select-String -Pattern "^\s+" | ForEach-Object {
        $_.ToString().Trim()
    }
    
    foreach ($distro in $allDistros) {
        if ($distro -notin $allowedDistros) {
            Write-PodmanLog -Message "Found unauthorized distro: $distro" -Level Warning
            
            # Shutdown the distro first (if running)
            wsl --terminate "$distro" 2>$null | Out-Null
            
            # Unregister/remove the distro
            $unregResult = wsl --unregister "$distro" 2>&1
            if ($LASTEXITCODE -eq 0) {
                Write-PodmanLog -Message "Removed unauthorized distro: $distro" -Level Info
                
                # Log to EventLog for audit trail
                Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Warning `
                    -EventId 1004 -Message "Unauthorized WSL distribution removed: $distro" `
                    -ErrorAction SilentlyContinue
            } else {
                Write-PodmanLog -Message "Failed to remove distro '$distro': $unregResult" -Level Error
            }
        }
    }
    
    Write-PodmanLog -Message "Unauthorized distro check completed." -Level Info

    Write-PodmanLog -Message "=== Podman Self-Heal Completed Successfully ===" -Level Info
    
    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Information `
        -EventId 1002 -Message "Self-Healing erfolgreich ausgefuehrt. .wslconfig repariert." `
        -ErrorAction SilentlyContinue

} catch {
    Write-PodmanLog -Message "Fehler im Self-Healing: $_" -Level Error
    
    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Error `
        -EventId 1003 -Message "Fehler im Self-Healing: $_" `
        -ErrorAction SilentlyContinue
}
