# NVIDIA Driver Fix Toolkit

Small Windows toolkit for diagnosing and safely cleaning up NVIDIA display driver crash loops, especially `VIDEO_TDR_FAILURE`, `LiveKernelEvent 117/141`, `WATCHDOG*.dmp`, and repeated `nvlddmkm` errors.

This repo is designed for assisted troubleshooting with Codex, Gemini Antigravity, or a careful human operator.

## What It Includes

- `Collect-NvidiaCrashInfo.ps1`
  Read-only diagnostic collector. It summarizes Windows Event Log evidence, NVIDIA driver status, GPU info, and dump file locations.

- `Fix-NvidiaDriver.ps1`
  Step-by-step NVIDIA cleanup helper. It can prepare DDU, enable Safe Mode, run DDU, install a manually selected NVIDIA driver, and clean up state.

- `ANTIGRAVITY_PROMPT.md`
  A professional autonomous English prompt for another agent to download this repo, inspect crash evidence, repair when appropriate, and verify the result.

## Safety Notes

Driver cleanup is high-impact:

- Requires Administrator PowerShell.
- Can remove the active NVIDIA display driver.
- Can set the next boot to Safe Mode.
- Can require multiple reboots.
- Should not be run over an unstable remote session unless you have recovery access.

The fix script is intentionally not fully automatic. It does not create startup tasks, does not disable Wi-Fi by default, does not auto-download the latest NVIDIA driver, and does not reboot unless `-RebootNow` is explicitly supplied.

## Quick Start

Open PowerShell as Administrator:

```powershell
git clone https://github.com/nhatlinh0610/nvidia-driver-fix-toolkit.git
cd .\nvidia-driver-fix-toolkit

Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Collect-NvidiaCrashInfo.ps1
.\Fix-NvidiaDriver.ps1 -Action Status
```

If the diagnostic report points to NVIDIA TDR / watchdog failures, download these manually:

- Display Driver Uninstaller (DDU)
- A known-good NVIDIA driver for your exact laptop/GPU. Prefer OEM ASUS driver first for ASUS laptops, or a stable NVIDIA release instead of blindly picking the newest one.

Then run the safe flow:

```powershell
.\Fix-NvidiaDriver.ps1 -Action Prepare -DduPath "C:\Path\DDU.zip" -DriverPath "C:\Path\NVIDIA_driver.exe"
.\Fix-NvidiaDriver.ps1 -Action EnableSafeMode
```

Reboot into Safe Mode, then run:

```powershell
.\Fix-NvidiaDriver.ps1 -Action RunDdu
```

Reboot into normal Windows, then run:

```powershell
.\Fix-NvidiaDriver.ps1 -Action InstallDriver
.\Fix-NvidiaDriver.ps1 -Action Cleanup
```

## Emergency Recovery

If Windows keeps booting into Safe Mode:

```powershell
.\Fix-NvidiaDriver.ps1 -Action UndoSafeMode
```

Or manually:

```powershell
bcdedit /deletevalue {current} safeboot
```

## Optional GitHub Issue Reporting

The fix script can create a GitHub issue if a script action fails.

Create a fine-grained GitHub token with Issues read/write access for your repo, then store it outside the script:

```powershell
setx GITHUB_TOKEN "github_pat_xxx"
```

Open a new Administrator PowerShell window, then enable reporting during prepare:

```powershell
.\Fix-NvidiaDriver.ps1 -Action Prepare -DduPath "C:\Path\DDU.zip" -DriverPath "C:\Path\NVIDIA_driver.exe" -GitHubRepo "owner/repo" -ReportErrorsToGitHub
```

Test issue creation:

```powershell
.\Fix-NvidiaDriver.ps1 -Action TestGitHubReport
```

Do not commit your GitHub token. The script reads it from the environment and redacts common token patterns from reports.

## When Not To Use This

Do not run the fix flow just because a game crashed once. Run diagnostics first. If the evidence points to CPU, RAM, disk, overheating, or WHEA hardware errors instead of NVIDIA TDR/watchdog failures, investigate that path first.
