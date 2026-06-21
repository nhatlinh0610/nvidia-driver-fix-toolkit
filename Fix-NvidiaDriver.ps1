#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Safer NVIDIA driver cleanup helper for ASUS ROG G513QR / RTX 3070 Laptop.

.DESCRIPTION
    This script replaces the previous fully automatic version. It does not create
    startup tasks, does not disable Wi-Fi by default, does not download the latest
    NVIDIA driver automatically, and does not reboot unless you explicitly ask.

    Recommended flow:
      1. Download a known-good NVIDIA driver manually.
      2. Download DDU manually, or pass -AllowDownloadDDU explicitly.
      3. Run: .\Fix-NvidiaDriver.ps1 -Action Prepare -DduPath <DDU.zip/exe> -DriverPath <NVIDIA.exe>
      4. Run: .\Fix-NvidiaDriver.ps1 -Action EnableSafeMode
      5. Reboot into Safe Mode.
      6. Run: .\Fix-NvidiaDriver.ps1 -Action RunDdu
      7. Reboot into normal Windows.
      8. Run: .\Fix-NvidiaDriver.ps1 -Action InstallDriver
      9. Reboot once more.

    Emergency recovery if Windows keeps booting Safe Mode:
      bcdedit /deletevalue {current} safeboot

    Optional GitHub error reporting:
      1. Create a fine-grained GitHub token with Issues: Read/Write for your repo.
      2. Store it outside the script:
           setx GITHUB_TOKEN "github_pat_xxx"
      3. Enable reporting during Prepare:
           .\Fix-NvidiaDriver.ps1 -Action Prepare -DduPath <DDU.zip/exe> -DriverPath <NVIDIA.exe> -GitHubRepo owner/repo -ReportErrorsToGitHub
      4. Test once:
           .\Fix-NvidiaDriver.ps1 -Action TestGitHubReport
#>

[CmdletBinding()]
param(
    [ValidateSet("Status", "Prepare", "EnableSafeMode", "RunDdu", "InstallDriver", "Cleanup", "UndoSafeMode", "TestGitHubReport")]
    [string]$Action = "Status",

    [string]$DduPath = "",
    [string]$DriverPath = "",

    [string]$WorkDir = "C:\NvidiaFix",
    [string]$DriverArgs = "-s -noreboot -clean",

    [switch]$AllowDownloadDDU,
    [switch]$DisableNetwork,
    [switch]$NoRestorePoint,
    [switch]$RebootNow,
    [switch]$Force,

    [string]$GitHubRepo = "",
    [string]$GitHubTokenEnv = "",
    [switch]$ReportErrorsToGitHub,
    [int]$GitHubLogTailLines = 220
)

$ErrorActionPreference = "Stop"

$DDUZip = Join-Path $WorkDir "DDU.zip"
$DDUDir = Join-Path $WorkDir "DDU"
$StateFile = Join-Path $WorkDir "state.json"
$LogFile = Join-Path $WorkDir "fix_log.txt"

$OldTaskDdu = "NvidiaFix_DDU_SafeMode"
$OldTaskInstall = "NvidiaFix_Install_Normal"

function Ensure-WorkDir {
    if (-not (Test-Path -LiteralPath $WorkDir)) {
        New-Item -ItemType Directory -Path $WorkDir -Force | Out-Null
    }
}

function Write-Log {
    param(
        [string]$Message,
        [ValidateSet("INFO", "WARN", "ERROR")]
        [string]$Level = "INFO"
    )

    Ensure-WorkDir
    $ts = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $line = "[$ts] [$Level] $Message"
    $color = switch ($Level) {
        "ERROR" { "Red" }
        "WARN" { "Yellow" }
        default { "Cyan" }
    }

    Write-Host $line -ForegroundColor $color
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Confirm-Continue {
    param([string]$Message)

    if ($Force) {
        Write-Log "$Message (forced)"
        return
    }

    Write-Host ""
    Write-Host $Message -ForegroundColor Yellow
    $answer = Read-Host "Type YES to continue"
    if ($answer -cne "YES") {
        Write-Log "Cancelled by user." "WARN"
        exit 1
    }
}

function Load-State {
    if (-not (Test-Path -LiteralPath $StateFile)) {
        return @{}
    }

    try {
        $raw = Get-Content -LiteralPath $StateFile -Raw
        if ([string]::IsNullOrWhiteSpace($raw)) {
            return @{}
        }

        $json = $raw | ConvertFrom-Json
        $state = @{}
        foreach ($prop in $json.PSObject.Properties) {
            $state[$prop.Name] = $prop.Value
        }
        return $state
    } catch {
        Write-Log "Cannot read state file: $_" "WARN"
        return @{}
    }
}

function Save-State {
    param([hashtable]$State)

    Ensure-WorkDir
    $State.UpdatedAt = (Get-Date).ToString("o")
    $State | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

function Test-SafeMode {
    try {
        $safeBoot = Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\SafeBoot\Option" -ErrorAction Stop
        return $null -ne $safeBoot.OptionValue
    } catch {
        return $false
    }
}

function Show-FileSignature {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "File not found: $Path" "WARN"
        return
    }

    try {
        $sig = Get-AuthenticodeSignature -LiteralPath $Path
        $signer = if ($sig.SignerCertificate) { $sig.SignerCertificate.Subject } else { "(no signer)" }
        Write-Log "Signature: $($sig.Status) - $signer"
    } catch {
        Write-Log "Could not inspect signature for $Path : $_" "WARN"
    }
}

function Resolve-ExistingPath {
    param([string]$Path, [string]$Label)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label does not exist: $Path"
    }

    return (Resolve-Path -LiteralPath $Path).Path
}

function Download-DDU {
    Confirm-Continue "DDU will be downloaded from SourceForge into $DDUZip. Only continue if you trust this source."

    $url = "https://sourceforge.net/projects/display-driver-uninstaller/files/latest/download"
    Write-Log "Downloading DDU..."
    Write-Log "URL: $url"
    Write-Log "Destination: $DDUZip"

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64)")
    $wc.DownloadFile($url, $DDUZip)

    $sizeMB = [math]::Round((Get-Item -LiteralPath $DDUZip).Length / 1MB, 1)
    Write-Log "DDU downloaded: $sizeMB MB"
}

function Resolve-DduExe {
    param([string]$Path)

    $candidate = Resolve-ExistingPath -Path $Path -Label "DDU path"

    if ($candidate) {
        if ($candidate -like "*.zip") {
            if (Test-Path -LiteralPath $DDUDir) {
                Remove-Item -LiteralPath $DDUDir -Recurse -Force
            }
            Write-Log "Extracting DDU zip: $candidate"
            Expand-Archive -LiteralPath $candidate -DestinationPath $DDUDir -Force
        } elseif ($candidate -like "*.exe") {
            return $candidate
        } else {
            throw "DDU path must be a .zip or .exe: $candidate"
        }
    } elseif (Test-Path -LiteralPath $DDUDir) {
        Write-Log "Using existing DDU folder: $DDUDir"
    } elseif (Test-Path -LiteralPath $DDUZip) {
        Write-Log "Extracting existing DDU zip: $DDUZip"
        Expand-Archive -LiteralPath $DDUZip -DestinationPath $DDUDir -Force
    } elseif ($AllowDownloadDDU) {
        Download-DDU
        Expand-Archive -LiteralPath $DDUZip -DestinationPath $DDUDir -Force
    } else {
        throw "DDU not found. Pass -DduPath <DDU.zip/exe> or use -AllowDownloadDDU."
    }

    $dduExe = Get-ChildItem -LiteralPath $DDUDir -Recurse -Filter "Display Driver Uninstaller.exe" |
        Select-Object -First 1

    if (-not $dduExe) {
        throw "Could not find 'Display Driver Uninstaller.exe' under $DDUDir"
    }

    return $dduExe.FullName
}

function Resolve-DriverExe {
    param([string]$Path)

    $state = Load-State
    $candidate = Resolve-ExistingPath -Path $Path -Label "NVIDIA driver"

    if (-not $candidate -and $state.ContainsKey("DriverPath")) {
        $candidate = Resolve-ExistingPath -Path ([string]$state.DriverPath) -Label "NVIDIA driver from state"
    }

    if (-not $candidate) {
        $fallback = Join-Path $WorkDir "nvidia_driver.exe"
        if (Test-Path -LiteralPath $fallback) {
            $candidate = (Resolve-Path -LiteralPath $fallback).Path
        }
    }

    if (-not $candidate) {
        throw "NVIDIA driver not found. Pass -DriverPath <NVIDIA driver .exe>. Do not rely on latest auto-download."
    }

    if ($candidate -notlike "*.exe") {
        throw "NVIDIA driver must be an .exe: $candidate"
    }

    return $candidate
}

function Remove-OldScheduledTasks {
    foreach ($task in @($OldTaskDdu, $OldTaskInstall)) {
        $existing = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Removing old scheduled task: $task" "WARN"
            Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
}

function New-DriverRestorePoint {
    if ($NoRestorePoint) {
        Write-Log "Restore point skipped by -NoRestorePoint." "WARN"
        return
    }

    try {
        Write-Log "Creating restore point..."
        Checkpoint-Computer -Description "Before NVIDIA driver cleanup" -RestorePointType "MODIFY_SETTINGS"
        Write-Log "Restore point created."
    } catch {
        Write-Log "Restore point could not be created. System Restore may be disabled: $_" "WARN"
    }
}

function Disable-NetworkIfRequested {
    param([hashtable]$State)

    if (-not $DisableNetwork) {
        Write-Log "Network adapters are left untouched. Use -DisableNetwork if you really want to block Windows Update." "WARN"
        return
    }

    Confirm-Continue "Wi-Fi/wireless adapters will be disabled. Remote sessions over Wi-Fi may disconnect."

    $adapters = Get-NetAdapter |
        Where-Object { $_.InterfaceDescription -match "Wi-Fi|Wireless|802\.11" -or $_.Name -match "Wi-Fi|Wireless" }

    $disabled = @()
    foreach ($adapter in $adapters) {
        Write-Log "Disabling network adapter: $($adapter.Name)"
        Disable-NetAdapter -Name $adapter.Name -Confirm:$false -ErrorAction SilentlyContinue
        $disabled += $adapter.Name
    }

    $State.DisabledAdapters = $disabled
    Save-State -State $State
}

function Enable-PreviouslyDisabledNetwork {
    $state = Load-State
    if (-not $state.ContainsKey("DisabledAdapters")) {
        return
    }

    foreach ($name in @($state.DisabledAdapters)) {
        if ([string]::IsNullOrWhiteSpace($name)) {
            continue
        }
        Write-Log "Enabling network adapter: $name"
        Enable-NetAdapter -Name $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

function Get-EnvironmentValue {
    param([string]$Name)

    foreach ($scope in @("Process", "User", "Machine")) {
        $value = [Environment]::GetEnvironmentVariable($Name, $scope)
        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value
        }
    }

    return ""
}

function Get-GitHubConfig {
    $state = Load-State

    $repo = $GitHubRepo
    if ([string]::IsNullOrWhiteSpace($repo) -and $state.ContainsKey("GitHubRepo")) {
        $repo = [string]$state.GitHubRepo
    }

    $tokenEnv = $GitHubTokenEnv
    if ([string]::IsNullOrWhiteSpace($tokenEnv) -and $state.ContainsKey("GitHubTokenEnv")) {
        $tokenEnv = [string]$state.GitHubTokenEnv
    }
    if ([string]::IsNullOrWhiteSpace($tokenEnv)) {
        $tokenEnv = "GITHUB_TOKEN"
    }

    $enabled = $ReportErrorsToGitHub.IsPresent
    if (-not $enabled -and $state.ContainsKey("ReportErrorsToGitHub")) {
        try {
            $enabled = [System.Convert]::ToBoolean($state.ReportErrorsToGitHub)
        } catch {
            $enabled = $false
        }
    }

    return @{
        Enabled = $enabled
        Repo = $repo
        TokenEnv = $tokenEnv
    }
}

function Save-GitHubConfigIfRequested {
    param([hashtable]$State)

    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        if ($GitHubRepo -notmatch "^[^/\s]+/[^/\s]+$") {
            throw "GitHubRepo must be in owner/repo format."
        }

        $State.GitHubRepo = $GitHubRepo
        $State.GitHubTokenEnv = if ([string]::IsNullOrWhiteSpace($GitHubTokenEnv)) { "GITHUB_TOKEN" } else { $GitHubTokenEnv }
        $State.ReportErrorsToGitHub = $true
        Write-Log "GitHub error reporting enabled for repo: $GitHubRepo"
        return
    }

    if ($ReportErrorsToGitHub) {
        if (-not $State.ContainsKey("GitHubRepo") -or [string]::IsNullOrWhiteSpace([string]$State.GitHubRepo)) {
            throw "Pass -GitHubRepo owner/repo when enabling -ReportErrorsToGitHub."
        }

        $State.GitHubTokenEnv = if ([string]::IsNullOrWhiteSpace($GitHubTokenEnv)) { "GITHUB_TOKEN" } else { $GitHubTokenEnv }
        $State.ReportErrorsToGitHub = $true
        Write-Log "GitHub error reporting enabled for repo: $($State.GitHubRepo)"
    }
}

function Protect-ReportText {
    param(
        [string]$Text,
        [string]$Token
    )

    if ($null -eq $Text) {
        return ""
    }

    $safe = $Text
    if (-not [string]::IsNullOrWhiteSpace($Token)) {
        $safe = $safe.Replace($Token, "<redacted-token>")
    }

    $safe = $safe -replace "gh[pousr]_[A-Za-z0-9_]{20,}", "<redacted-github-token>"
    $safe = $safe -replace "github_pat_[A-Za-z0-9_]{20,}", "<redacted-github-token>"
    return $safe
}

function Get-ReportLogTail {
    if (-not (Test-Path -LiteralPath $LogFile)) {
        return "(no log file yet)"
    }

    try {
        return (Get-Content -LiteralPath $LogFile -Tail $GitHubLogTailLines -ErrorAction Stop) -join [Environment]::NewLine
    } catch {
        return "(could not read log tail: $_)"
    }
}

function Send-GitHubIssue {
    param(
        [string]$Title,
        [string]$Body,
        [switch]$RequireEnabled
    )

    $config = Get-GitHubConfig
    if ($RequireEnabled -and -not $config.Enabled) {
        Write-Log "GitHub error reporting is disabled. Use -GitHubRepo owner/repo -ReportErrorsToGitHub to enable it." "WARN"
        return $null
    }

    if ([string]::IsNullOrWhiteSpace([string]$config.Repo)) {
        Write-Log "GitHub repo is not configured; cannot create issue." "WARN"
        return $null
    }

    if ([string]$config.Repo -notmatch "^[^/\s]+/[^/\s]+$") {
        Write-Log "GitHub repo must be in owner/repo format: $($config.Repo)" "WARN"
        return $null
    }

    $token = Get-EnvironmentValue -Name ([string]$config.TokenEnv)
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Log "GitHub token not found in env var '$($config.TokenEnv)'." "WARN"
        return $null
    }

    $safeBody = Protect-ReportText -Text $Body -Token $token
    if ($safeBody.Length -gt 60000) {
        $safeBody = $safeBody.Substring(0, 60000) + [Environment]::NewLine + "... truncated ..."
    }

    $payload = @{
        title = $Title
        body = $safeBody
        labels = @("nvidia-fix", "auto-report")
    }

    $headers = @{
        Authorization = "Bearer $token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
        "User-Agent" = "NvidiaFixScript"
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    } catch {}

    $uri = "https://api.github.com/repos/$($config.Repo)/issues"
    try {
        Write-Log "Creating GitHub issue in $($config.Repo)..."
        $response = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -ContentType "application/json" -Body ($payload | ConvertTo-Json -Depth 6)
        Write-Log "GitHub issue created: $($response.html_url)"
        return $response
    } catch {
        Write-Log "Could not create GitHub issue: $_" "WARN"
        return $null
    }
}

function Send-GitHubErrorReport {
    param([System.Management.Automation.ErrorRecord]$ErrorRecord)

    $config = Get-GitHubConfig
    if (-not $config.Enabled) {
        return
    }

    $exceptionText = if ($ErrorRecord.Exception) { $ErrorRecord.Exception.ToString() } else { [string]$ErrorRecord }
    $positionText = if ($ErrorRecord.InvocationInfo) { $ErrorRecord.InvocationInfo.PositionMessage } else { "" }
    $logTail = Get-ReportLogTail
    $stateText = ""

    try {
        if (Test-Path -LiteralPath $StateFile) {
            $stateText = Get-Content -LiteralPath $StateFile -Raw
        } else {
            $stateText = "(no state file)"
        }
    } catch {
        $stateText = "(could not read state file: $_)"
    }

    $titleTime = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $title = "[NvidiaFix] $Action failed on $env:COMPUTERNAME at $titleTime"
    $body = @"
## NVIDIA Fix Error Report

- Computer: $env:COMPUTERNAME
- Action: $Action
- Time: $titleTime
- WorkDir: $WorkDir
- Safe Mode: $(Test-SafeMode)

### Error

~~~text
$exceptionText
~~~

### Position

~~~text
$positionText
~~~

### State

~~~json
$stateText
~~~

### Log Tail

~~~text
$logTail
~~~
"@

    Send-GitHubIssue -Title $title -Body $body -RequireEnabled | Out-Null
}

function Action-Status {
    Ensure-WorkDir
    $state = Load-State

    Write-Log "===== NVIDIA driver fix status ====="
    Write-Log "Action default is Status; no changes made."
    Write-Log "WorkDir: $WorkDir"
    Write-Log "LogFile: $LogFile"
    Write-Log "StateFile: $StateFile"
    Write-Log "Safe Mode currently detected: $(Test-SafeMode)"

    $gitHubConfig = Get-GitHubConfig
    Write-Log "GitHub reporting enabled: $($gitHubConfig.Enabled)"
    if (-not [string]::IsNullOrWhiteSpace([string]$gitHubConfig.Repo)) {
        Write-Log "GitHub repo: $($gitHubConfig.Repo)"
    }
    Write-Log "GitHub token env: $($gitHubConfig.TokenEnv)"

    $bootText = (& bcdedit /enum "{current}") 2>&1
    $safeBootLine = $bootText | Where-Object { $_ -match "safeboot" }
    if ($safeBootLine) {
        Write-Log "BCD safeboot setting exists: $safeBootLine" "WARN"
    } else {
        Write-Log "BCD safeboot setting: not set"
    }

    foreach ($task in @($OldTaskDdu, $OldTaskInstall)) {
        $existing = Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue
        if ($existing) {
            Write-Log "Old scheduled task still exists: $task" "WARN"
        }
    }

    if ($state.Count -gt 0) {
        Write-Log "Saved state:"
        $state.GetEnumerator() | Sort-Object Name | ForEach-Object {
            Write-Log "  $($_.Name): $($_.Value)"
        }
    } else {
        Write-Log "Saved state: empty"
    }

    Write-Host ""
    Write-Host "Suggested commands:" -ForegroundColor Green
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action Prepare -DduPath <DDU.zip/exe> -DriverPath <NVIDIA.exe>"
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action EnableSafeMode"
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action RunDdu"
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action InstallDriver"
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action Cleanup"
    Write-Host "  .\Fix-NvidiaDriver.ps1 -Action TestGitHubReport"
}

function Action-Prepare {
    Ensure-WorkDir
    Remove-OldScheduledTasks

    $dduExe = Resolve-DduExe -Path $DduPath
    $driverExe = Resolve-DriverExe -Path $DriverPath

    Write-Log "DDU executable: $dduExe"
    Show-FileSignature -Path $dduExe

    Write-Log "NVIDIA driver executable: $driverExe"
    Show-FileSignature -Path $driverExe

    $state = Load-State
    $state.DduExe = $dduExe
    $state.DriverPath = $driverExe
    $state.DriverArgs = $DriverArgs
    $state.Phase = "Prepared"
    Save-GitHubConfigIfRequested -State $state
    Save-State -State $state

    Write-Log "Prepare complete. Next: -Action EnableSafeMode"
}

function Action-TestGitHubReport {
    Ensure-WorkDir

    $config = Get-GitHubConfig
    if ([string]::IsNullOrWhiteSpace([string]$config.Repo) -and [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        throw "GitHub repo is not configured. Pass -GitHubRepo owner/repo first."
    }

    if (-not [string]::IsNullOrWhiteSpace($GitHubRepo)) {
        $state = Load-State
        Save-GitHubConfigIfRequested -State $state
        Save-State -State $state
    }

    Confirm-Continue "This will create a test issue in GitHub repo '$((Get-GitHubConfig).Repo)'."

    $now = (Get-Date).ToString("yyyy-MM-dd HH:mm:ss")
    $body = @"
## NVIDIA Fix Test Report

This is a manual test issue from `Fix-NvidiaDriver.ps1`.

- Computer: $env:COMPUTERNAME
- Time: $now
- WorkDir: $WorkDir
- LogFile: $LogFile

If you can read this, GitHub reporting is configured correctly.
"@

    Send-GitHubIssue -Title "[NvidiaFix] Test report from $env:COMPUTERNAME at $now" -Body $body | Out-Null
}

function Action-EnableSafeMode {
    Ensure-WorkDir
    Remove-OldScheduledTasks

    $state = Load-State
    if (-not $state.ContainsKey("DduExe")) {
        if (-not $Force) {
            throw "State has no DDU path. Run -Action Prepare first, or pass -Force if you will provide -DduPath in Safe Mode."
        }
        Write-Log "State has no DDU path. Continuing because -Force was supplied." "WARN"
    }

    New-DriverRestorePoint
    Disable-NetworkIfRequested -State $state

    Confirm-Continue "This will set the next boot to Safe Mode using bcdedit."
    & bcdedit /set "{current}" safeboot minimal | Out-Null

    $state = Load-State
    $state.Phase = "SafeModeRequested"
    Save-State -State $state

    Write-Log "Safe Mode boot has been enabled."
    if ($RebootNow) {
        Confirm-Continue "The computer will reboot now."
        shutdown /r /t 10 /c "NVIDIA fix: booting into Safe Mode for DDU"
    } else {
        Write-Log "Reboot manually when ready. Next command in Safe Mode: -Action RunDdu"
    }
}

function Action-RunDdu {
    Ensure-WorkDir
    Remove-OldScheduledTasks

    if (-not (Test-SafeMode) -and -not $Force) {
        throw "RunDdu is intended for Safe Mode. Boot Safe Mode first or pass -Force if you know exactly what you are doing."
    } elseif (-not (Test-SafeMode) -and $Force) {
        Write-Log "RunDdu is running outside Safe Mode because -Force was supplied." "WARN"
    }

    $state = Load-State
    $dduExe = ""
    if ($state.ContainsKey("DduExe")) {
        $dduExe = Resolve-ExistingPath -Path ([string]$state.DduExe) -Label "DDU executable from state"
    }
    if (-not $dduExe) {
        $dduExe = Resolve-DduExe -Path $DduPath
    }

    Confirm-Continue "DDU will remove NVIDIA GPU driver files. Screen may flicker and display driver will be removed."
    Write-Log "Running DDU: $dduExe"
    Start-Process -FilePath $dduExe -ArgumentList "-silent -cleannvidiagpu 1 -removenvidiagpu 1" -Wait

    Write-Log "DDU finished. Removing Safe Mode boot flag now."
    & bcdedit /deletevalue "{current}" safeboot 2>$null

    $state.Phase = "DduCompleted"
    Save-State -State $state

    if ($RebootNow) {
        Confirm-Continue "The computer will reboot back to normal Windows now."
        shutdown /r /t 10 /c "NVIDIA fix: DDU completed, rebooting to normal Windows"
    } else {
        Write-Log "Reboot manually into normal Windows. Next command: -Action InstallDriver"
    }
}

function Action-InstallDriver {
    Ensure-WorkDir
    Remove-OldScheduledTasks

    if (Test-SafeMode) {
        throw "InstallDriver should be run in normal Windows, not Safe Mode."
    }

    $driverExe = Resolve-DriverExe -Path $DriverPath
    $state = Load-State

    if ($state.ContainsKey("DriverArgs") -and -not [string]::IsNullOrWhiteSpace([string]$state.DriverArgs)) {
        $script:DriverArgs = [string]$state.DriverArgs
    }

    Write-Log "Installing NVIDIA driver: $driverExe"
    Write-Log "Driver arguments: $DriverArgs"
    Show-FileSignature -Path $driverExe

    Confirm-Continue "The NVIDIA driver installer will run silently. Close games and GPU tools before continuing."
    Start-Process -FilePath $driverExe -ArgumentList $DriverArgs -Wait

    $state.DriverPath = $driverExe
    $state.DriverArgs = $DriverArgs
    $state.Phase = "DriverInstalled"
    Save-State -State $state

    Enable-PreviouslyDisabledNetwork

    if ($RebootNow) {
        Confirm-Continue "The computer will reboot now to finish driver installation."
        shutdown /r /t 15 /c "NVIDIA driver installed, rebooting"
    } else {
        Write-Log "Driver installer finished. Reboot manually before testing games."
    }
}

function Action-UndoSafeMode {
    Ensure-WorkDir
    Confirm-Continue "This will remove the BCD Safe Mode boot flag."
    & bcdedit /deletevalue "{current}" safeboot 2>$null
    Write-Log "Safe Mode boot flag removed."
}

function Action-Cleanup {
    Ensure-WorkDir
    Remove-OldScheduledTasks
    Enable-PreviouslyDisabledNetwork

    Write-Log "Removing Safe Mode boot flag if present."
    & bcdedit /deletevalue "{current}" safeboot 2>$null

    $state = Load-State
    $state.Phase = "Cleaned"
    Save-State -State $state

    Write-Log "Cleanup complete. Work files are kept in $WorkDir for logs and reuse."
}

try {
    Ensure-WorkDir
    Write-Log "========================================================"
    Write-Log " Safer NVIDIA Driver Fix - ASUS ROG G513QR / RTX 3070"
    Write-Log " Action: $Action"
    Write-Log "========================================================"

    switch ($Action) {
        "Status" { Action-Status }
        "Prepare" { Action-Prepare }
        "EnableSafeMode" { Action-EnableSafeMode }
        "RunDdu" { Action-RunDdu }
        "InstallDriver" { Action-InstallDriver }
        "UndoSafeMode" { Action-UndoSafeMode }
        "Cleanup" { Action-Cleanup }
        "TestGitHubReport" { Action-TestGitHubReport }
    }
} catch {
    $caughtError = $_
    try {
        Write-Log "Fatal error: $($caughtError.Exception.Message)" "ERROR"
    } catch {
        Write-Host "Fatal error: $($caughtError.Exception.Message)" -ForegroundColor Red
    }

    try {
        Send-GitHubErrorReport -ErrorRecord $caughtError
    } catch {
        try {
            Write-Log "GitHub error reporting failed inside catch: $($_.Exception.Message)" "WARN"
        } catch {}
    }

    throw $caughtError
}
