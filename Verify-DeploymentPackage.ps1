<#
.SYNOPSIS
    Verifiziert das Deployment-Paket für Offline-Betrieb.
    Prüft alle erforderlichen Dateien und zeigt Status an.

.DESCRIPTION
    Dieses Skript überprüft, ob alle notwendigen Dateien im Deployment-Paket vorhanden sind,
    bevor es an Corporate Endpoints verteilt wird. Es sollte auf einem System mit Internetzugang
    ausgeführt werden, um sicherzustellen, dass alle Komponenten korrekt vorbereitet wurden.

.EXAMPLE
    .\Verify-DeploymentPackage.ps1

.EXAMPLE
    .\Verify-DeploymentPackage.ps1 -Path "C:\Deployment\podman_cooperate_installer_base"
#>
param(
    [string]$Path
)

if ([string]::IsNullOrEmpty($Path)) {
    $Path = $PSScriptRoot
}

function Write-Status {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('OK', 'MISSING', 'WARNING', 'ERROR')] [string]$Status
    )
    
    switch ($Status) {
        'OK' { $color = "Green" }
        'MISSING' { $color = "Red" }
        'WARNING' { $color = "Yellow" }
        'ERROR' { $color = "DarkRed" }
    }
    
    Write-Host "$Message" -ForegroundColor $color
}

Write-Host "========================================="
Write-Host "  DEPLOYMENT PACKAGE VERIFICATION"
Write-Host "  Path: $Path"
Write-Host "========================================="
Write-Host ""

$allOk = $true
$warnings = @()

# Required files structure
$requiredFiles = @{
    "podman-desktop-setup.exe" = "Podman Desktop Installer"
    "podman-installer-windows-amd64.msi" = "Podman CLI MSI Installer"
    "sources\sxs\en-us" = "WinSxS Offline Sources (for WSL feature activation)"
    "podman-machine.x86_64.wsl.tar.zst" = "Podman Machine Image (Fedora-based, zstd compressed)"
}

$optionalFiles = @{
    "CorporateRootCA.cer" = "Corporate Root CA Certificate"
    "podman-config.json" = "Configuration File"
    "Init-PodmanUser.ps1" = "User Initialization Script"
    "SelfHeal-Podman.ps1" = "Self-Healing Script"
}

Write-Host "Checking REQUIRED files:"
Write-Host "-------------------------"
foreach ($file in $requiredFiles.Keys) {
    $fullPath = Join-Path -Path $Path -ChildPath $file
    if (Test-Path -Path $fullPath) {
        Write-Status "  [OK] $($requiredFiles[$file]): OK" -Status 'OK'
    } else {
        Write-Status "  [FAIL] $($requiredFiles[$file]): MISSING" -Status 'MISSING'
        $allOk = $false
    }
}

Write-Host ""
Write-Host "Checking OPTIONAL files:"
Write-Host "-------------------------"
foreach ($file in $optionalFiles.Keys) {
    $fullPath = Join-Path -Path $Path -ChildPath $file
    if (Test-Path -Path $fullPath) {
        Write-Status "  [OK] $($optionalFiles[$file]): OK" -Status 'OK'
    } else {
        Write-Status "  ! $($optionalFiles[$file]): MISSING (Optional)" -Status 'WARNING'
        $warnings += $optionalFiles[$file]
    }
}

Write-Host ""
Write-Host "Checking WinSxS structure:"
Write-Host "---------------------------"
$wslFeatures = @(
    "Microsoft-Windows-Subsystem-Linux",
    "VirtualMachinePlatform"
)

foreach ($feature in $wslFeatures) {
    $featurePath = Join-Path -Path "$Path\sources\sxs" -ChildPath $feature
    if (Test-Path -Path $featurePath) {
        Write-Status "  [OK] WSL Feature '$feature': OK" -Status 'OK'
    } else {
        Write-Status "  [FAIL] WSL Feature '$feature': MISSING" -Status 'MISSING'
        $allOk = $false
    }
}


Write-Host ""
Write-Host "========================================="
if ($allOk) {
    Write-Host "  [OK] DEPLOYMENT PACKAGE IS COMPLETE"
    Write-Host "=========================================" -ForegroundColor Green
} else {
    Write-Host "  [FAIL] DEPLOYMENT PACKAGE IS INCOMPLETE"
    Write-Host "=========================================" -ForegroundColor Red
}

if ($warnings.Count -gt 0) {
    Write-Host ""
    Write-Host "Warnings: $($warnings.Count) optional file(s) missing"
    foreach ($warning in $warnings) {
        Write-Host "  - $warning" -ForegroundColor Yellow
    }
}

Write-Host ""
if (-not $allOk) {
    exit 1
} else {
    exit 0
}
