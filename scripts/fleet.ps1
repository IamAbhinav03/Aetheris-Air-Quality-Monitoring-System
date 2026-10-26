# =============================================================================
# Aetheris fleet firmware helper (Windows PowerShell 5.1+)
# =============================================================================
#   .\scripts\fleet.ps1 build
#   .\scripts\fleet.ps1 config
#   .\scripts\fleet.ps1 deploy -DevicesFile devices.csv
#   .\scripts\fleet.ps1 deploy -Device 192.168.1.50
#   .\scripts\fleet.ps1 flash -Port COM5
#   .\scripts\fleet.ps1 firmware
#
# The first USB flash must be done on a machine that can see the serial port.
# After that, `deploy` updates every node over Wi-Fi (OTA) using one compiled
# binary. Wi-Fi/MQTT credentials come from AetherisSensorV1\secrets.yaml
# (created by scripts\setup.ps1).
# =============================================================================
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet("build", "config", "deploy", "flash", "firmware", "clean")]
    [string]$Command = "build",

    # Single node IP/hostname (for `deploy`).
    [string]$Device,

    # CSV with `name,ip` columns (for `deploy`).
    [string]$DevicesFile = "devices.csv",

    # Skip the compile step before deploying.
    [switch]$SkipBuild,

    # Serial port for the first USB flash, e.g. COM5.
    [string]$Port,

    [string]$EsphomeImage = "esphome/esphome:2026.10.0",

    # Docker volume used for ESPHome's build cache/toolchain.
    [string]$CacheVolume = "aetheris-esphome-cache"
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
    # Keep the toolchain in a Docker volume: it survives between runs and is
    # much faster and more reliable than extracting it onto a bind mount.
    $cache = "${CacheVolume}:/config/.esphome"
    & docker run --rm -v $mount -v $cache -w /config $EsphomeImage @EsphomeArgs | Out-Host
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

    "firmware" {
        Assert-Files
        $firmwareDir = Join-Path $SensorDir "firmware"
        New-Item -ItemType Directory -Force -Path $firmwareDir | Out-Null

        $copied = 0
        if (Test-LocalEsphome) {
            $paths = @((Join-Path $SensorDir ".esphome\build"), (Join-Path $SensorDir "build"))
            foreach ($path in $paths) {
                if (Test-Path $path) {
                    Get-ChildItem $path -Recurse -Filter "firmware*.bin" -ErrorAction SilentlyContinue | ForEach-Object {
                        Copy-Item $_.FullName $firmwareDir -Force
                        $copied++
                    }
                }
            }
            if ($copied -eq 0) { throw "No firmware found. Run build first." }
        }
        else {
            & docker run --rm `
                -v "${CacheVolume}:/cache:ro" `
                -v "${firmwareDir}:/out" `
                --entrypoint /bin/sh `
                $EsphomeImage `
                -c 'find /cache/build -mindepth 3 -maxdepth 3 -type f -name "firmware*.bin" -exec cp {} /out/ \;' | Out-Host
            if ($LASTEXITCODE -ne 0) { throw "Copying firmware out of the build cache failed." }
        }

        Write-Host "    firmware copied to AetherisSensorV1\firmware" -ForegroundColor DarkGray
        $bins = @(Get-ChildItem $firmwareDir -Filter "firmware*.bin" -ErrorAction SilentlyContinue)
        if ($bins.Count -eq 0) { throw "No firmware found. Run build first." }
        $bins | ForEach-Object {
            Write-Host ("    {0}  {1:N2} MB" -f $_.Name, ($_.Length / 1MB))
        }
    }

    "clean" {
        $paths = @((Join-Path $SensorDir "build"), (Join-Path $SensorDir ".esphome\build"))
        $removed = $false
        foreach ($path in $paths) {
            if (Test-Path $path) {
                Remove-Item -Recurse -Force $path
                Write-Host "    removed $path"
                $removed = $true
            }
        }
        & docker volume rm $CacheVolume 2>$null | Out-Null
        if (-not $removed) { Write-Host "    removed the build cache (if present)" }
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
