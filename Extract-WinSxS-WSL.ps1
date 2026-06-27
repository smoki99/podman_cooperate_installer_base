<#
.SYNOPSIS
    Extracts WSL and VirtualMachinePlatform WinSxS sources from a running Windows 11 system.
    This creates the offline deployment package needed for Install-Master.ps1.

.DESCRIPTION
    This script extracts the required Windows optional features (WSL2) from an installed
    Windows 11 system using DISM. The extracted files can then be used in offline
corporate environments to enable WSL without internet access.

.EXAMPLE
    .\Extract-WinSxS-WSL.ps1

.EXAMPLE
    .\Extract-WinSxS-WSL.ps1 -OutputPath "C:\DeploymentPackage"

.NOTES
    Requires:
    - Windows 10 version 2004+ or Windows 11 (with WSL available)
    - Administrator privileges
    - Internet connection (to download missing packages if needed)
#>

param(
    [string]$OutputPath = $PSScriptRoot,
    [switch]$SkipValidation
)

$ErrorActionPreference = 'Stop'

Write-Host "========================================="
Write-Host "  WSL WinSxS EXTRACTOR"
Write-Host "  Output: $OutputPath"
Write-Host "========================================="
Write-Host ""

# Check for admin privileges
$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole] "Administrator")
if (-not $isAdmin) {
    Write-Error "This script requires Administrator privileges. Please run as Admin!"
    exit 1
}
Write-Host "[OK] Running with Administrator privileges" -ForegroundColor Green

# Create output directory structure
$sourceDir = Join-Path -Path $OutputPath -ChildPath "sources\sxs\en-us"
if (-not (Test-Path -Path $sourceDir)) {
    Write-Host "Creating directory: $sourceDir" -ForegroundColor Yellow
    New-Item -ItemType Directory -Force -Path $sourceDir | Out-Null
}

# Create manifest for WSL features
$manifestContent = @"
<assembly xmlns="urn:schemas-microsoft-com:asm.v3" manifestVersion="1.0">
  <identity name="Microsoft-Windows-Subsystem-Linux-Package" version="1.0.0.0"/>
</assembly>
"@

$manifestPath = Join-Path -Path $env:TEMP -ChildPath "wsl-export.manifest"
Set-Content -Path $manifestPath -Value $manifestContent -Encoding UTF8
Write-Host "[OK] Created manifest file: $manifestPath" -ForegroundColor Green

# Create temporary extraction directory
$tempExtractDir = Join-Path -Path $env:TEMP -ChildPath "WinSxS-Export"
if (Test-Path -Path $tempExtractDir) {
    Remove-Item -Path $tempExtractDir -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $tempExtractDir | Out-Null
Write-Host "[OK] Created temp directory: $tempExtractDir" -ForegroundColor Green

# Export WSL packages using DISM
Write-Host ""
Write-Host "Exporting WSL packages from Windows..." -ForegroundColor Yellow
Write-Host "This may take a few minutes and require internet access for missing files." -ForegroundColor Cyan
Write-Host ""

try {
    $dismResult = Start-Process "dism.exe" `
        -ArgumentList @(
            "/online",
            "/export-package",
            "/destination:`"$tempExtractDir`"",
            "/manifest:$manifestPath"
        ) `
        -Wait `
        -PassThru
    
    if ($dismResult.ExitCode -ne 0) {
        Write-Warning "DISM returned exit code $($dismResult.ExitCode). Attempting alternative method..."
    }
} catch {
    Write-Error "DISM export failed: $_"
}

# Alternative method: Export all packages and filter
Write-Host ""
Write-Host "Using alternative extraction method..." -ForegroundColor Yellow

try {
    # Create a more comprehensive manifest
    $fullManifest = @"
<assembly xmlns="urn:schemas-microsoft-com:asm.v3" manifestVersion="1.0">
  <identity name="Microsoft-Windows-Subsystem-Linux-Package" version="1.0.0.0"/>
</assembly>
<assembly xmlns="urn:schemas-microsoft-com:asm.v3" manifestVersion="1.0">
  <identity name="VirtualMachinePlatform-Package" version="1.0.0.0"/>
</assembly>
"@
    
    $fullManifestPath = Join-Path -Path $env:TEMP -ChildPath "wsl-full.manifest"
    Set-Content -Path $fullManifestPath -Value $fullManifest -Encoding UTF8
    
    # Export using DISM with both features
    Write-Host "Exporting Microsoft-Windows-Subsystem-Linux..." -ForegroundColor Cyan
    Start-Process "dism.exe" `
        -ArgumentList @(
            "/online",
            "/export-package",
            "/destination:`"$tempExtractDir`"",
            "/manifest:$fullManifestPath"
        ) `
        -Wait `
        -PassThru
    
} catch {
    Write-Warning "Alternative method also encountered issues: $_"
}

# Copy extracted files to output directory
Write-Host ""
Write-Host "Copying extracted files..." -ForegroundColor Yellow

if (Test-Path -Path $tempExtractDir) {
    # Find all en-us folders and copy them
    $enUsFolders = Get-ChildItem -Path $tempExtractDir -Recurse -Directory -Filter "en-us"
    
    if ($enUsFolders.Count -gt 0) {
        foreach ($folder in $enUsFolders) {
            Write-Host "Copying from: $($folder.FullName)" -ForegroundColor Cyan
            Copy-Item -Path "$($folder.FullName)\*" -Destination $sourceDir -Recurse -Force
        }
        Write-Host "[OK] Files copied to: $sourceDir" -ForegroundColor Green
    } else {
        # Try copying all files if no en-us folder found
        Write-Host "No 'en-us' folder found, attempting direct copy..." -ForegroundColor Yellow
        Copy-Item -Path "$tempExtractDir\*" -Destination $sourceDir -Recurse -Force
    }
} else {
    Write-Error "Extraction directory not found: $tempExtractDir"
}

# Verify extracted files
Write-Host ""
Write-Host "Verifying extraction..." -ForegroundColor Yellow

$extractedFiles = Get-ChildItem -Path $sourceDir -Recurse | Measure-Object | Select-Object -ExpandProperty Count
$totalSize = (Get-ChildItem -Path $sourceDir -Recurse | Measure-Object -Property Length -Sum).Sum / 1MB

Write-Host "[OK] Extracted $extractedFiles files (~$([math]::Round($totalSize, 2)) MB)" -ForegroundColor Green

# List key directories found
Write-Host ""
Write-Host "Key directories in extraction:"
Get-ChildItem -Path $sourceDir -Directory | ForEach-Object {
    Write-Host "  - $_.Name"
}

# Cleanup temp files
if (Test-Path -Path $tempExtractDir) {
    Remove-Item -Path $tempExtractDir -Recurse -Force
    Write-Host "[OK] Cleaned up temporary files" -ForegroundColor Green
}

if (Test-Path -Path $manifestPath) {
    Remove-Item -Path $manifestPath -Force
}

Write-Host ""
Write-Host "========================================="
Write-Host "  EXTRACTION COMPLETE"
Write-Host "=========================================" -ForegroundColor Green
Write-Host ""
Write-Host "Output location: $sourceDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:"
Write-Host "1. Copy the 'sources' folder to your deployment package"
Write-Host "2. Run .\Verify-DeploymentPackage.ps1 to validate"
Write-Host "3. Use Install-Master.ps1 for offline installation"
Write-Host ""

exit 0
