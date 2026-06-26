<#
.SYNOPSIS
    User-Context Skript. Initialisiert Podman, erzwingt Registries und Zertifikate.
    SAFE CODE: Strict Mode und Fehlerbehandlung aktiviert.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Hilfsfunktion: Windows-Pfad in WSL-Pfad umwandeln.
# wslpath ist ein WSL-Binary und kann nicht direkt in PowerShell aufgerufen werden.
function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$WinPath)
    $drive = $WinPath[0].ToString().ToLower()
    $rest  = $WinPath.Substring(2).Replace('\', '/')
    return "/mnt/$drive$rest"
}

$success = $false
try {
    $AppDataConfig  = "$env:APPDATA\Podman Desktop"
    $SettingsFile   = "$AppDataConfig\settings.json"
    # $PSScriptRoot zeigt auf das Verzeichnis, in das Install-Master.ps1 die Skripte kopiert hat
    # (Paths.SecureStorage). So funktioniert der Pfad unabhängig vom konfigurierten SecureStorage-Wert.
    $ConfigJsonPath = Join-Path -Path $PSScriptRoot -ChildPath "podman-config.json"
    $Config         = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # 1. UI und Zertifikat-Sync vorkonfigurieren
    if (-not (Test-Path -Path $AppDataConfig)) {
        New-Item -Path $AppDataConfig -ItemType Directory -Force | Out-Null
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

    # 2. Maschine initialisieren, falls noch nicht vorhanden.
    # @() erzwingt Array-Kontext, damit .Count bei einem einzelnen Objekt korrekt funktioniert.
    $machineStatus = @(podman machine ls --format json | ConvertFrom-Json)
    if ($machineStatus.Count -eq 0) {
        Write-Output "Initialisiere Podman Machine..."
        $initProcess = Start-Process -FilePath "podman" `
            -ArgumentList "machine", "init", "--rootful=false" `
            -Wait -NoNewWindow -PassThru
        if ($initProcess.ExitCode -ne 0) {
            throw "Fehler bei podman machine init (ExitCode: $($initProcess.ExitCode))"
        }

        # 3. Transparent Proxy: Root-CA-Zertifikat in Linux-Trust-Store injizieren
        $CertPath = Join-Path -Path $PSScriptRoot -ChildPath "CorporateRootCA.cer"
        if (Test-Path -Path $CertPath) {
            $WslCertPath = ConvertTo-WslPath -WinPath $CertPath
            Start-Process -FilePath "wsl" `
                -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
                "cp", $WslCertPath, "/etc/pki/ca-trust/source/anchors/" `
                -Wait -NoNewWindow
            Start-Process -FilePath "wsl" `
                -ArgumentList "-d", "podman-machine-default", "-u", "root", "--", `
                "update-ca-trust" `
                -Wait -NoNewWindow
        }

        # 4. Zero-Trust Registry: Nur Firmen-Registry erlauben
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
        $RegistriesConf = "unqualified-search-registries = [`"$($Config.Registries.AllowedSearchRegistry)`"]"

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

        # 5. Maschine starten und ExitCode prüfen
        $startProcess = Start-Process -FilePath "podman" `
            -ArgumentList "machine", "start" `
            -Wait -NoNewWindow -PassThru
        if ($startProcess.ExitCode -ne 0) {
            throw "Fehler bei podman machine start (ExitCode: $($startProcess.ExitCode))"
        }
    }

    $success = $true

} catch {
    Write-Error "Fehler im User-Init: $_"
} finally {
    # Scheduled Task nur bei erfolgreichem Abschluss entfernen.
    # Bei Fehler bleibt der Task erhalten und wird beim nächsten Login erneut versucht.
    if ($success) {
        Unregister-ScheduledTask -TaskName "Podman-User-Init" -Confirm:$false -ErrorAction SilentlyContinue
    }
}