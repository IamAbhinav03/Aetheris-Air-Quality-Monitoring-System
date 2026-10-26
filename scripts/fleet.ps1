# =============================================================================
# Aetheris fleet firmware helper (Windows PowerShell 5.1+)
# =============================================================================
#   .\scripts\fleet.ps1 build
#   .\scripts\fleet.ps1 config
#   .\scripts\fleet.ps1 deploy -DevicesFile devices.csv
#   .\scripts\fleet.ps1 deploy -Device 192.168.1.50
#   .\scripts\fleet.ps1 flash -Port COM5
#
# The first USB flash must be done on a machine that can see the serial port.
# After that, `deploy` updates every node over Wi-Fi (OTA) using one compiled
# binary. Wi-Fi/MQTT credentials come from AetherisSensorV1\secrets.yaml
# (created by scripts\setup.ps1).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("build", "config", "deploy", "flash", "clean")]
    [string]$Command = "build",

    # Single node IP/hostname (for `deploy`).
    [string]$Device,

    # CSV with `name,ip` columns (for `deploy`).
    [string]$DevicesFile = "devices.csv",

    # Skip the compile step before deploying.
    [switch]$SkipBuild,

    # Serial port for the first USB flash, e.g. COM5.
    [string]$Port,

    [string]$EsphomeImage = "esphome/esphome:2026.10.0"
)

$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$SensorDir = Join-Path $Root "AetherisSensorV1"
$ConfigFile = "fleet.yaml"

function Test-LocalEsphome {
    return [bool](Get-Command esphome -ErrorAction SilentlyContinue)
}

function Invoke-Esphome {
    param([string[]]$EsphomeArgs)

    if (Test-LocalEsphome) {
        Push-Location $SensorDir
        try {
            & esphome @EsphomeArgs | Out-Host
            return $LASTEXITCODE
        }
        finally {
            Pop-Location
        }
    }

    Write-Host "    using Docker image $EsphomeImage" -ForegroundColor DarkGray
    $mount = "$SensorDir`:/config"
    & docker run --rm -v $mount -w /config $EsphomeImage @EsphomeArgs | Out-Host
    return $LASTEXITCODE
}

function Assert-Files {
    if (-not (Test-Path (Join-Path $SensorDir $ConfigFile))) {
        throw "Missing $ConfigFile in $SensorDir"
    }
    if (-not (Test-Path (Join-Path $SensorDir "secrets.yaml"))) {
        throw "Missing AetherisSensorV1\secrets.yaml. Run .\scripts\setup.ps1 first."
    }
}

Write-Host ""
Write-Host "==> Aetheris fleet: $Command" -ForegroundColor Cyan

switch ($Command) {
    "build" {
        Assert-Files
        $code = Invoke-Esphome @("compile", $ConfigFile)
        if ($code -ne 0) { throw "ESPHome build failed." }
    }

    "config" {
        Assert-Files
        $code = Invoke-Esphome @("config", $ConfigFile)
        if ($code -ne 0) { throw "ESPHome config validation failed." }
    }

    "flash" {
        Assert-Files
        if (-not $Port) { throw "Pass -Port COM5 (or /dev/ttyACM0 on Linux/macOS)." }
        if (-not (Test-LocalEsphome)) {
            throw "USB flashing needs a local ESPHome install (Docker cannot access serial ports). Install it with: pipx install esphome"
        }
        Write-Host "    flashing $ConfigFile to $Port" -ForegroundColor DarkGray
        $code = Invoke-Esphome @("run", $ConfigFile, "--device", $Port, "--no-logs")
        if ($code -ne 0) { throw "USB flash failed." }
    }

    "clean" {
        $buildDir = Join-Path $SensorDir ".esphome\build"
        if (Test-Path $buildDir) {
            Remove-Item -Recurse -Force $buildDir
            Write-Host "    removed $buildDir"
        }
        else {
            Write-Host "    nothing to clean"
        }
    }

    "deploy" {
        Assert-Files

        $targets = @()
        if ($Device) {
            $targets = @([pscustomobject]@{ name = "single"; ip = $Device })
        }
        else {
            $csvPath = if ([System.IO.Path]::IsPathRooted($DevicesFile)) { $DevicesFile }
                       else { Join-Path $Root $DevicesFile }
            if (-not (Test-Path $csvPath)) {
                throw "Devices file not found: $csvPath. Copy AetherisSensorV1\devices.example.csv and fill in your nodes."
            }
            $targets = @(Import-Csv $csvPath)
        }

        if ($targets.Count -eq 0) { throw "No devices to deploy to." }

        if (-not $SkipBuild) {
            Write-Host "    compiling once for the whole fleet..." -ForegroundColor DarkGray
            $code = Invoke-Esphome @("compile", $ConfigFile)
            if ($code -ne 0) { throw "ESPHome build failed." }
        }

        $failed = @()
        $index = 0
        foreach ($target in $targets) {
            $index++
            $ip = "$($target.ip)".Trim()
            $label = if ($target.name) { "$($target.name) ($ip)" } else { $ip }
            if (-not $ip) { continue }

            Write-Host ""
            Write-Host "[$index/$($targets.Count)] $label" -ForegroundColor Cyan

            $ok = $false
            for ($attempt = 1; $attempt -le 2 -and -not $ok; $attempt++) {
                if ($attempt -gt 1) {
                    Write-Host "    retrying (attempt $attempt)..." -ForegroundColor Yellow
                    Start-Sleep -Seconds 3
                }
                $code = Invoke-Esphome @("upload", $ConfigFile, "--device", $ip)
                if ($code -eq 0) { $ok = $true }
            }

            if (-not $ok) { $failed += $label }
        }

        Write-Host ""
        if ($failed.Count -gt 0) {
            Write-Host "==> $($failed.Count) device(s) failed:" -ForegroundColor Red
            $failed | ForEach-Object { Write-Host "    - $_" -ForegroundColor Red }
            exit 1
        }
        Write-Host "==> All $($targets.Count) device(s) updated" -ForegroundColor Green
    }
}
