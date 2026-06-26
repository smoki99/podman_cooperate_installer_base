<#
.SYNOPSIS
    User-Context Skript. Initialisiert Podman, erzwingt Registries und Zertifikate.
    SAFE CODE: Strict Mode und Fehlerbehandlung aktiviert.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $AppDataConfig = "$env:APPDATA\Podman Desktop"
    $SettingsFile = "$AppDataConfig\settings.json"
    $ConfigJsonPath = "C:\ProgramData\CorporateIT\Podman\podman-config.json"
    $Config = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # 1. UI und Zertifikat-Sync vorkonfigurieren
    if (-not (Test-Path -Path $AppDataConfig)) { New-Item -Path $AppDataConfig -ItemType Directory -Force | Out-Null }
    
    $SettingsJson = @{
        "telemetry.optIn" = $false
        "preferences.UpdateDisabled" = $true
        "preferences.StartAutomatically" = $true
        "kubernetes.extensions.minikube" = $false
        "os.checkWsl" = $false
        "engine.podman.machine.syncSystemCertificates" = $true
    } | ConvertTo-Json -Depth 5
    Set-Content -Path $SettingsFile -Value $SettingsJson -Force -Encoding UTF8

    # 2. Maschine initialisieren, falls nicht existent
    $machineStatus = (podman machine ls --format json | ConvertFrom-Json)
    if ($null -eq $machineStatus -or $machineStatus.Count -eq 0) {
        Write-Output "Initialisiere Podman Machine..."
        $initProcess = Start-Process -FilePath "podman" -ArgumentList "machine", "init", "--rootful=false" -Wait -NoNewWindow -PassThru
        if ($initProcess.ExitCode -ne 0) { throw "Fehler bei podman machine init" }

        # 3. Transparent Proxy: Zertifikat injizieren
        $CertPath = "C:\ProgramData\CorporateIT\Podman\CorporateRootCA.cer"
        if (Test-Path -Path $CertPath) {
            Start-Process -FilePath "wsl" -ArgumentList "-d", "podman-machine-default", "-u", "root", "cp", "$(wslpath $CertPath)", "/etc/pki/ca-trust/source/anchors/" -Wait -NoNewWindow
            Start-Process -FilePath "wsl" -ArgumentList "-d", "podman-machine-default", "-u", "root", "update-ca-trust" -Wait -NoNewWindow
        }

        # 4. Zero-Trust Registry (Nur Firmen-Registry erlauben)
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
        $TempReg = "$env:TEMP\99-corp.conf"
        Set-Content -Path $TempPolicy -Value $PolicyJson -Force -Encoding utf8NoBOM
        Set-Content -Path $TempReg -Value $RegistriesConf -Force -Encoding utf8NoBOM

        Start-Process -FilePath "wsl" -ArgumentList "-d", "podman-machine-default", "-u", "root", "cp", "$(wslpath $TempPolicy)", "/etc/containers/policy.json" -Wait -NoNewWindow
        Start-Process -FilePath "wsl" -ArgumentList "-d", "podman-machine-default", "-u", "root", "mkdir", "-p", "/etc/containers/registries.conf.d" -Wait -NoNewWindow
        Start-Process -FilePath "wsl" -ArgumentList "-d", "podman-machine-default", "-u", "root", "cp", "$(wslpath $TempReg)", "/etc/containers/registries.conf.d/99-corp-registries.conf" -Wait -NoNewWindow
        
        Remove-Item -Path $TempPolicy, $TempReg -Force -ErrorAction SilentlyContinue

        # 5. Maschine starten
        Start-Process -FilePath "podman" -ArgumentList "machine", "start" -Wait -NoNewWindow
    }
} catch {
    Write-Error "Fehler im User-Init: $_"
} finally {
    # Task nach Erfolg entfernen
    Unregister-ScheduledTask -TaskName "Podman-User-Init" -Confirm:$false -ErrorAction SilentlyContinue
}