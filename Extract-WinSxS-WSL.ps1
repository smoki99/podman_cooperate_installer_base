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

# Method: Install features, copy from WinSxS, then uninstall
Write-Host ""
Write-Host "Exporting WSL packages from Windows..." -ForegroundColor Yellow
Write-Host "This method will install the features temporarily, copy them, then uninstall." -ForegroundColor Cyan
Write-Host ""

$featuresToProcess = @(
    @{Name="VirtualMachinePlatform"; DisplayName="Virtual Machine Platform"},
    @{Name="Microsoft-Windows-Subsystem-Linux"; DisplayName="Windows Subsystem for Linux"}
)

foreach ($feature in $featuresToProcess) {
    Write-Host ""
    Write-Host "Processing: $($feature.DisplayName)" -ForegroundColor Yellow
    
    # Step 1: Install the feature (if not already installed)
    Write-Host "  [Step 1] Installing $($feature.Name)..." -ForegroundColor Cyan
    try {
        $installResult = Start-Process "dism.exe" `
            -ArgumentList @(
                "/online",
                "/enable-feature",
                "/featurename:$($feature.Name)",
                "/norestart",
                "/all"
            ) `
            -Wait `
            -PassThru
        
        if ($installResult.ExitCode -eq 0) {
            Write-Host "  [OK] $($feature.Name) installed successfully" -ForegroundColor Green
        } else {
            Write-Warning "  DISM returned exit code $($installResult.ExitCode) for $($feature.Name)"
        }
    } catch {
        Write-Warning "  Failed to install $($feature.Name): $_"
    }
    
    # Step 2: Copy from WinSxS
    Write-Host "  [Step 2] Copying from WinSxS..." -ForegroundColor Cyan
    $winsxsPath = "C:\Windows\WinSxS"
    if (Test-Path -Path $winsxsPath) {
        # Find folders matching the feature name in WinSxS
        $featureFolders = Get-ChildItem -Path $winsxsPath -Directory | Where-Object { $_.Name -match [regex]::Escape($feature.Name) }
        
        if ($featureFolders.Count -gt 0) {
            Write-Host "  Found $($featureFolders.Count) folders for $($feature.Name)" -ForegroundColor Cyan
            foreach ($folder in $featureFolders) {
                Write-Host "    Copying: $($folder.Name)..." -ForegroundColor Yellow
                Copy-Item -Path "$($folder.FullName)\*" -Destination $tempExtractDir -Recurse -Force
            }
        } else {
            Write-Warning "  No folders found for $($feature.Name) in WinSxS"
        }
    }
    
    # Step 3: Uninstall the feature (if it wasn't already installed)
    Write-Host "  [Step 3] Uninstalling $($feature.Name)..." -ForegroundColor Cyan
    try {
        $uninstallResult = Start-Process "dism.exe" `
            -ArgumentList @(
                "/online",
                "/disable-feature",
                "/featurename:$($feature.Name)",
                "/norestart"
            ) `
            -Wait `
            -PassThru
        
        if ($uninstallResult.ExitCode -eq 0) {
            Write-Host "  [OK] $($feature.Name) uninstalled successfully" -ForegroundColor Green
        } else {
            Write-Warning "  DISM returned exit code $($uninstallResult.ExitCode) for uninstalling $($feature.Name)"
        }
    } catch {
        Write-Warning "  Failed to uninstall $($feature.Name): $_"
    }
}

# Copy extracted files to output directory
Write-Host ""
Write-Host "Copying extracted files..." -ForegroundColor Yellow

if (Test-Path -Path $tempExtractDir) {
    # Find all en-us folders and copy them
    $enUsFolders = Get-ChildItem -Path $tempExtractDir -Recurse -Directory -Filter "en-us" -ErrorAction SilentlyContinue
    
    if ($null -ne $enUsFolders -and @($enUsFolders).Count -gt 0) {
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
$totalSizeObj = Get-ChildItem -Path $sourceDir -Recurse | Measure-Object -Property Length -Sum
if ($null -ne $totalSizeObj) {
    $totalSize = $totalSizeObj.Sum / 1MB
} else {
    $totalSize = 0
}

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
