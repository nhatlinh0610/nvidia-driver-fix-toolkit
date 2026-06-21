#Requires -Version 5.1
<#
.SYNOPSIS
    Read-only NVIDIA crash evidence collector.

.DESCRIPTION
    Collects a concise report from Windows Event Log, NVIDIA driver state,
    nvidia-smi, and common dump folders. It does not modify drivers, boot
    settings, services, registry, or network adapters.
#>

[CmdletBinding()]
param(
    [int]$SinceDays = 14,
    [string]$WorkDir = "C:\NvidiaFix",
    [int]$MaxEventsPerSection = 40
)

$ErrorActionPreference = "Continue"
$ReportDir = Join-Path $WorkDir "Reports"
$Stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$ReportPath = Join-Path $ReportDir "NvidiaCrashSummary_$Stamp.txt"
$CsvDir = Join-Path $ReportDir "Events_$Stamp"
$Since = (Get-Date).AddDays(-1 * [math]::Abs($SinceDays))

New-Item -ItemType Directory -Path $ReportDir -Force | Out-Null
New-Item -ItemType Directory -Path $CsvDir -Force | Out-Null

$script:Lines = New-Object System.Collections.Generic.List[string]

function Add-Line {
    param([string]$Text = "")
    $script:Lines.Add($Text) | Out-Null
}

function Shorten {
    param(
        [string]$Text,
        [int]$Max = 360
    )

    if ($null -eq $Text) {
        return ""
    }

    $oneLine = ($Text -replace "\s+", " ").Trim()
    if ($oneLine.Length -le $Max) {
        return $oneLine
    }

    return $oneLine.Substring(0, $Max) + "..."
}

function Get-EventSafe {
    param(
        [string]$LogName,
        [string]$ProviderName = "",
        [int[]]$Ids = @(),
        [string]$MessageRegex = ""
    )

    try {
        $filter = @{
            LogName = $LogName
            StartTime = $Since
        }

        if (-not [string]::IsNullOrWhiteSpace($ProviderName)) {
            $filter.ProviderName = $ProviderName
        }

        if ($Ids.Count -gt 0) {
            $filter.Id = $Ids
        }

        $events = Get-WinEvent -FilterHashtable $filter -ErrorAction Stop

        if (-not [string]::IsNullOrWhiteSpace($MessageRegex)) {
            $events = $events | Where-Object { $_.Message -match $MessageRegex }
        }

        return @($events | Sort-Object TimeCreated -Descending)
    } catch {
        return @()
    }
}

function Save-EventCsv {
    param(
        [string]$Name,
        [object[]]$Events
    )

    if ($Events.Count -eq 0) {
        return
    }

    $path = Join-Path $CsvDir "$Name.csv"
    $Events |
        Select-Object TimeCreated, ProviderName, Id, LevelDisplayName, Message |
        Export-Csv -LiteralPath $path -NoTypeInformation -Encoding UTF8
}

function Add-EventSection {
    param(
        [string]$Title,
        [object[]]$Events
    )

    Add-Line ""
    Add-Line "== $Title =="
    Add-Line "Count: $($Events.Count)"

    foreach ($event in @($Events | Select-Object -First $MaxEventsPerSection)) {
        Add-Line ("{0:yyyy-MM-dd HH:mm:ss} | {1} | ID {2} | {3} | {4}" -f `
            $event.TimeCreated, $event.ProviderName, $event.Id, $event.LevelDisplayName, (Shorten $event.Message))
    }
}

function Add-CommandOutput {
    param(
        [string]$Title,
        [scriptblock]$Command
    )

    Add-Line ""
    Add-Line "== $Title =="
    try {
        $output = & $Command 2>&1
        if ($null -eq $output) {
            Add-Line "(no output)"
        } else {
            foreach ($line in @($output)) {
                Add-Line ([string]$line)
            }
        }
    } catch {
        Add-Line "Command failed: $_"
    }
}

function Add-DumpListing {
    param(
        [string]$Title,
        [string]$Path,
        [string]$Filter = "*.dmp"
    )

    Add-Line ""
    Add-Line "== $Title =="
    if (-not (Test-Path -LiteralPath $Path)) {
        Add-Line "Missing: $Path"
        return
    }

    $files = Get-ChildItem -LiteralPath $Path -Filter $Filter -Recurse -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 40

    if (-not $files) {
        Add-Line "No files found in $Path"
        return
    }

    foreach ($file in $files) {
        Add-Line ("{0:yyyy-MM-dd HH:mm:ss} | {1:n1} MB | {2}" -f $file.LastWriteTime, ($file.Length / 1MB), $file.FullName)
    }
}

$bugChecks = Get-EventSafe -LogName "System" -Ids 1001 -MessageRegex "bugcheck|0x00000116|0x116"
$kernelPower = Get-EventSafe -LogName "System" -ProviderName "Microsoft-Windows-Kernel-Power" -Ids 41
$nvlddmkm = Get-EventSafe -LogName "System" -ProviderName "nvlddmkm"
$display4101 = Get-EventSafe -LogName "System" -ProviderName "Display" -Ids 4101
$whea = Get-EventSafe -LogName "System" -ProviderName "Microsoft-Windows-WHEA-Logger"
$nvidiaService = Get-EventSafe -LogName "System" -ProviderName "Service Control Manager" -Ids 7023,7031 -MessageRegex "NVIDIA LocalSystem Container"
$liveKernelRegex = "(?s)(Event Name:\s*LiveKernelEvent.*?(P1:\s*(117|141|1b8|1a8)\b|Parameter0>\s*(117|141|1b8|1a8)<)|WATCHDOG)"
$liveKernel = Get-EventSafe -LogName "Application" -Ids 1001 -MessageRegex $liveKernelRegex
$appErrors = Get-EventSafe -LogName "Application" -Ids 1000,1001 -MessageRegex "nvlddmkm|NVIDIA|cs2\.exe|LiveKernelEvent|WATCHDOG"

Save-EventCsv -Name "BugCheck" -Events $bugChecks
Save-EventCsv -Name "KernelPower41" -Events $kernelPower
Save-EventCsv -Name "Nvlddmkm" -Events $nvlddmkm
Save-EventCsv -Name "Display4101" -Events $display4101
Save-EventCsv -Name "WHEA" -Events $whea
Save-EventCsv -Name "NvidiaService" -Events $nvidiaService
Save-EventCsv -Name "LiveKernel" -Events $liveKernel
Save-EventCsv -Name "ApplicationErrors" -Events $appErrors

Add-Line "NVIDIA Crash Summary"
Add-Line "Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
Add-Line "Computer: $env:COMPUTERNAME"
Add-Line "Window: last $SinceDays day(s), since $($Since.ToString('yyyy-MM-dd HH:mm:ss'))"
Add-Line "Report: $ReportPath"
Add-Line "CSV folder: $CsvDir"

Add-Line ""
Add-Line "== System =="
try {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    Add-Line "OS: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
    Add-Line "Computer model: $($cs.Manufacturer) $($cs.Model)"
    Add-Line "BIOS: $($bios.SMBIOSBIOSVersion)"
    Add-Line "CPU: $($cpu.Name)"
    Add-Line ("RAM: {0:n1} GB" -f ($cs.TotalPhysicalMemory / 1GB))
} catch {
    Add-Line "System info failed: $_"
}

Add-Line ""
Add-Line "== Display Adapters =="
try {
    Get-CimInstance Win32_VideoController | ForEach-Object {
        Add-Line "GPU: $($_.Name)"
        Add-Line "  DriverVersion: $($_.DriverVersion)"
        Add-Line "  DriverDate: $($_.DriverDate)"
        Add-Line "  PNPDeviceID: $($_.PNPDeviceID)"
    }
} catch {
    Add-Line "GPU info failed: $_"
}

Add-CommandOutput -Title "nvidia-smi summary" -Command {
    $nvsmi = Get-Command nvidia-smi -ErrorAction SilentlyContinue
    if (-not $nvsmi) {
        "nvidia-smi not found"
    } else {
        & $nvsmi.Source --query-gpu=name,driver_version,vbios_version,memory.total,memory.used,temperature.gpu,power.draw --format=csv
    }
}

$bugCheck116 = @($bugChecks | Where-Object { $_.Message -match "0x00000116|0x116" }).Count
$liveKernel117141 = @($liveKernel | Where-Object { $_.Message -match "(?s)LiveKernelEvent.*?(P1:\s*(117|141)\b|Parameter0>\s*(117|141)<)" }).Count
$watchdogEvents = @($liveKernel | Where-Object { $_.Message -match "WATCHDOG" }).Count

Add-Line ""
Add-Line "== Signal Summary =="
Add-Line "BugCheck 0x116 / VIDEO_TDR_FAILURE signals: $bugCheck116"
Add-Line "LiveKernelEvent 117/141-like signals: $liveKernel117141"
Add-Line "WATCHDOG dump references: $watchdogEvents"
Add-Line "nvlddmkm events: $($nvlddmkm.Count)"
Add-Line "Display 4101 events: $($display4101.Count)"
Add-Line "NVIDIA LocalSystem Container crashes: $($nvidiaService.Count)"
Add-Line "WHEA events: $($whea.Count)"
Add-Line "Kernel-Power 41 events: $($kernelPower.Count)"

Add-Line ""
Add-Line "== Preliminary Read =="
if ($bugCheck116 -gt 0 -or $liveKernel117141 -gt 0 -or $nvlddmkm.Count -gt 0) {
    Add-Line "Likely path: NVIDIA display driver/GPU TDR or watchdog failure."
    Add-Line "Recommended next step: review the detailed event sections, then consider the safe DDU + known-good driver flow."
} elseif ($watchdogEvents -gt 0) {
    Add-Line "Possible path: GPU/kernel watchdog failure, but no direct 0x116/117/141/nvlddmkm signal was found."
    Add-Line "Recommended next step: inspect WATCHDOG dump context and other hardware signals before driver cleanup."
} elseif ($whea.Count -gt 0) {
    Add-Line "Likely path may include hardware/PCIe/CPU/RAM instability because WHEA events exist."
    Add-Line "Recommended next step: inspect WHEA details before doing driver cleanup."
} elseif ($kernelPower.Count -gt 0) {
    Add-Line "Kernel-Power 41 exists, but that is often a consequence of an unexpected shutdown, not a root cause by itself."
} else {
    Add-Line "No strong NVIDIA TDR signal found in the selected time window."
}

Add-EventSection -Title "BugCheck / SystemErrorReporting" -Events $bugChecks
Add-EventSection -Title "LiveKernel / WER" -Events $liveKernel
Add-EventSection -Title "nvlddmkm" -Events $nvlddmkm
Add-EventSection -Title "NVIDIA LocalSystem Container" -Events $nvidiaService
Add-EventSection -Title "Display 4101" -Events $display4101
Add-EventSection -Title "WHEA" -Events $whea
Add-EventSection -Title "Kernel-Power 41" -Events $kernelPower
Add-EventSection -Title "Application Errors" -Events $appErrors

Add-DumpListing -Title "Windows Minidumps" -Path (Join-Path $env:SystemRoot "Minidump")
Add-DumpListing -Title "Windows LiveKernelReports" -Path (Join-Path $env:SystemRoot "LiveKernelReports")
Add-DumpListing -Title "Steam dumps" -Path (Join-Path ${env:ProgramFiles(x86)} "Steam\dumps")

$script:Lines | Set-Content -LiteralPath $ReportPath -Encoding UTF8

Write-Host ""
Write-Host "NVIDIA crash summary written to:" -ForegroundColor Green
Write-Host "  $ReportPath"
Write-Host "Event CSVs written to:" -ForegroundColor Green
Write-Host "  $CsvDir"
Write-Host ""
Get-Content -LiteralPath $ReportPath -TotalCount 80
