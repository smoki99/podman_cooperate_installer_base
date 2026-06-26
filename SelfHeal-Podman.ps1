<#
.SYNOPSIS
    Läuft als SYSTEM beim Booten oder bei Netzwerkwechseln.
    Repariert wslconfig (falls manipuliert) und resettet WSL-Dienste.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    # $PSScriptRoot zeigt auf das Verzeichnis, in das Install-Master.ps1 die Skripte kopiert hat
    # (Paths.SecureStorage). So funktioniert der Pfad unabhängig vom konfigurierten SecureStorage-Wert.
    $ConfigJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "podman-config.json"
    if (-not (Test-Path -Path $ConfigJsonPath)) { exit }
    $Config = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # Event-Log-Quelle registrieren, falls noch nicht vorhanden.
    # Ohne diese Registrierung schlägt Write-EventLog auf einem Neugerät still fehl.
    if (-not [System.Diagnostics.EventLog]::SourceExists("PodmanHeal")) {
        New-EventLog -LogName Application -Source "PodmanHeal" -ErrorAction SilentlyContinue
    }

    # 1. Die harte .wslconfig durchsetzen
    # [System.IO.File]::WriteAllText wird verwendet, um UTF-8 OHNE BOM zu schreiben.
    # Set-Content -Encoding UTF8 erzeugt in PowerShell 5.1 eine BOM, die WSL stört.
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
    }

    # 2. Nur hängende wslhost.exe-Prozesse killen.
    # Hinweis: "wsl"-Prozesse werden NICHT beendet, da dies andere laufende
    # WSL-Distros (z.B. Ubuntu) des Benutzers ungewollt abbrechen würde.
    $procs = Get-Process -Name "wslhost" -ErrorAction SilentlyContinue
    if ($procs) { Stop-Process -InputObject $procs -Force }

    # 3. Systemweite Docker-Socket-Variable garantieren
    [Environment]::SetEnvironmentVariable(
        "DOCKER_HOST",
        "npipe:////./pipe/podman-machine-default",
        "Machine"
    )

    # 4. MTU in der laufenden Podman-Machine setzen (VPN-Kompatibilität).
    # Der Wert aus podman-config.json wird direkt auf das Netzwerkinterface angewendet.
    if ($null -ne $Config.CorporateSettings.MTU) {
        $mtu = $Config.CorporateSettings.MTU
        Start-Process -FilePath "wsl" `
            -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
            "ip", "link", "set", "dev", "eth0", "mtu", "$mtu" `
            -Wait -NoNewWindow -ErrorAction SilentlyContinue
    }

    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Information `
        -EventId 1002 -Message "Self-Healing erfolgreich ausgefuehrt. .wslconfig repariert." `
        -ErrorAction SilentlyContinue

} catch {
    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Error `
        -EventId 1003 -Message "Fehler im Self-Healing: $_" `
        -ErrorAction SilentlyContinue
}