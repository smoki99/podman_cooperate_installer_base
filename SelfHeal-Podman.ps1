<#
.SYNOPSIS
    Läuft als SYSTEM beim Booten oder bei Netzwerkwechseln.
    Repariert wslconfig (falls manipuliert) und resettet WSL-Dienste.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    $ConfigJsonPath = "C:\ProgramData\CorporateIT\Podman\podman-config.json"
    if (-not (Test-Path -Path $ConfigJsonPath)) { exit }
    $Config = Get-Content -Path $ConfigJsonPath -Raw | ConvertFrom-Json

    # 1. Die harte .wslconfig durchsetzen
    $WslConfigContent = @"
[wsl2]
memory=$($Config.CorporateSettings.MaxMemory)
processors=$($Config.CorporateSettings.Processors)
networkingMode=mirrored
dnsTunneling=true
firewall=true
autoMemoryReclaim=dropcache
"@
    $UserProfiles = Get-ChildItem -Path "C:\Users" -Directory | Where-Object { $_.Name -NotMatch "^(Public|Default.*|Administrator)$" }
    
    foreach ($Profile in $UserProfiles) {
        $ConfigTarget = Join-Path -Path $Profile.FullName -ChildPath ".wslconfig"
        Set-Content -Path $ConfigTarget -Value $WslConfigContent -Force -Encoding UTF8
    }

    # 2. Hängende Prozesse killen und WSL-Subsystem resetten
    $procs = Get-Process -Name "wslhost", "wsl" -ErrorAction SilentlyContinue
    if ($procs) { Stop-Process -InputObject $procs -Force }
    
    # 3. Systemweite Docker-Socket-Variable garantieren
    [Environment]::SetEnvironmentVariable("DOCKER_HOST", "npipe:////./pipe/podman-machine-default", "Machine")
    
    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Information -EventId 1002 -Message "Self-Healing erfolgreich ausgeführt. .wslconfig repariert." -ErrorAction SilentlyContinue
} catch {
    Write-EventLog -LogName Application -Source "PodmanHeal" -EntryType Error -EventId 1003 -Message "Fehler im Self-Healing: $_" -ErrorAction SilentlyContinue
}