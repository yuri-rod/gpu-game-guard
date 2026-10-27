# GPU Game Guard

A PowerShell watcher that stops unprotected GPU processes while a Steam session or a configured game process is running on Windows.

Use it on a PC shared between gaming and restartable background work, such as local model servers. It reads dedicated GPU memory counters and terminates selected processes to release their allocations. Save work and preview the selection before enabling enforcement.

## Preview before enabling

Requires Windows 10 or 11 and Windows PowerShell 5.1 or later. GPU discovery uses DXGI; allocation reporting uses Windows GPU performance counters. No vendor CLI is required.

```powershell
git clone https://github.com/yuri-rod/gpu-game-guard.git C:\GpuGameGuard
Set-Location C:\GpuGameGuard
powershell.exe -NoProfile -File .\GpuGameGuard.ps1 -Version
# GpuGameGuard v1.1.1

notepad .\config.json
```

In [config.json](config.json), add each game's exact process name, without `.exe`, to `custom_games`. Names in this list both trigger enforcement and receive protection. Add other processes you need to keep, including game helpers, to `extra_protected_processes`. Use exact names, not wildcard patterns.

For example, these entries protect a game called `mygame.exe` and every process named `ffmpeg.exe`:

```json
"custom_games": ["mygame"],
"extra_protected_processes": ["discord", "spotify", "ffmpeg"]
```

Keep the other fields in the existing JSON object. Steam detection reads `RunningAppID` from the current user's registry; it does **not** identify or automatically protect the game's executables. Configure those names even for Steam games. Games from other launchers require `custom_games` entries.

Then inspect the current machine:

```powershell
powershell.exe -NoProfile -File .\GpuGameGuard.ps1 -ListGpus
powershell.exe -NoProfile -File .\GpuGameGuard.ps1 -Status
powershell.exe -NoProfile -File .\GpuGameGuard.ps1 -DryRun
```

`-DryRun` lists `PID`, `Name`, `VRAM_MB` and `Action` for a single enforcement pass without closing processes. It runs even when no game is active. Check the selected GPU and review the output with your game and background applications running. An empty table can also mean the memory counters were unavailable, so it is not proof that the configuration is safe.

After reviewing the selection and saving work, an elevated PowerShell prompt can run the watcher in the foreground:

```powershell
powershell.exe -NoProfile -File C:\GpuGameGuard\GpuGameGuard.ps1
```

Stop the foreground watcher with Ctrl+C. This stops future enforcement; it does not relaunch previously stopped applications. The script writes diagnostics to `guard.log` beside itself.

## Selection and termination rules

Enforcement checks two sets of processes:

1. Every process with a positive dedicated-memory allocation on the selected adapter.
2. Built-in and configured `extra_kill_targets`, even when they have no reported GPU allocation.

The built-in protected names, `extra_protected_processes` and `custom_games` take precedence over both sets. The built-in list includes Windows components, launchers, anti-cheat processes, driver utilities, terminals, `jellyfin` and `caddy`. Inspect the actual lists in [GpuGameGuard.ps1](GpuGameGuard.ps1) for your applications.

The GPU-allocation pass sends browsers `CloseMainWindow()`, followed by a 200 ms wait and forced termination if they are still running. Other candidates, including browsers selected by explicit kill targets, are forcibly terminated. Open tabs, unsaved forms and session recovery depend on the browser; the script does not save them.

Protection matches process names. It does not follow parent processes, inspect executable paths or distinguish separate applications with the same name. For example, protecting `jellyfin` does not protect its `ffmpeg` transcode workers. Adding `ffmpeg` protects both media-server transcodes and unrelated batch encodes. [vramp](https://github.com/yuri-rod/vramp) is a separate project to inspect if you need more specific process policies.

## Configuration and restoration

| Field | Behavior |
| --- | --- |
| `idle_interval_seconds` | Poll interval without a detected game; default 3 seconds. |
| `ingame_interval_seconds` | Enforcement interval while a game is detected; default 2 seconds. |
| `gpu_pattern` | Adapter-description regular expression. The default matches `NVIDIA`, `Radeon` or `Arc`. |
| `custom_games` | Exact process names that trigger enforcement and receive protection. |
| `extra_protected_processes` | Additional process names excluded from both enforcement passes. |
| `extra_kill_targets` | Additional process names selected even without reported GPU memory, unless protected. |
| `auto_restore` | Relaunch captured executable paths after the watcher observes the game session ending; default `false`. |

If several adapters match, the script selects the one with the most dedicated memory. If none match, it falls back to the adapter with the most dedicated memory. A pattern mismatch does not disable enforcement. Use `-ListGpus` and `-Status` to check the choice.

Restoration stores unique executable paths in memory and calls `Start-Process` for those paths. It does not preserve arguments, working directories, service configuration, job progress or application state. It applies to captured candidates, including browsers, rather than only AI servers. Stopping the watcher loses that list. `-PurgeNow` does not run the watcher transition that restores applications.

Configuration is loaded at startup. Restart the watcher after editing it. The full file is validated before settings are applied: intervals must be positive whole numbers, `auto_restore` must be a JSON boolean, process lists must be arrays of nonempty strings and `gpu_pattern` must be a valid regular expression. Unknown fields are rejected so a misspelled protection setting cannot be silently ignored.

An unreadable or invalid file stops startup before process inspection or enforcement. A missing optional `config.json` uses built-in defaults; an explicitly selected `-Config <path>` must exist. Review `-DryRun` after changing settings. `-Config` selects a file for a manual invocation, and `-GpuPattern <regex>` overrides adapter selection for that invocation.

## Background task and commands

Only install after checking the foreground workflow. In an elevated PowerShell prompt:

```powershell
powershell.exe -NoProfile -File C:\GpuGameGuard\GpuGameGuard.ps1 -Install
```

This registers and immediately starts the `GpuGameGuard` scheduled task, with startup and logon triggers and highest privileges for the installing user. Keep the script directory writable only by people you trust. The task loads `config.json` beside the script; installation does not persist `-Config` or `-GpuPattern` overrides. Windows session behavior and GPU access need checking on the target machine.

| Command | Effect |
| --- | --- |
| `-Version` | Prints the script version without starting the watcher. |
| `-ListGpus` | Lists DXGI adapters and dedicated memory capacity. |
| `-Status` | Prints the selected adapter, detected game state and reported allocations. |
| `-DryRun` | Previews an immediate pass without terminating processes. |
| `-PurgeNow` | Immediately terminates selected processes, whether or not a game is running. Save work and preview first. |
| `-Uninstall` | Stops and removes the scheduled task. Requires elevation; leaves files and logs in place. |

`-Pause` and `-Resume` are declared parameters without implemented handlers. Do not use them to control an existing watcher. Use Ctrl+C for a foreground run or `-Uninstall` for the scheduled task.

## Implementation and tests

[GpuGameGuard.ps1](GpuGameGuard.ps1) contains the DXGI interop, counter aggregation, Steam/custom detection, enforcement and restoration logic. Dot-sourcing imports those definitions without starting the watcher. This synthetic adapter example needs no GPU access:

```powershell
. .\GpuGameGuard.ps1
$adapters = @(
    [pscustomobject]@{ Description = 'Sample integrated'; DedicatedVideoMemory = 512MB; Luid = 'integrated' }
    [pscustomobject]@{ Description = 'Sample discrete'; DedicatedVideoMemory = 8GB; Luid = 'discrete' }
)
(Resolve-GamingAdapter -Adapters $adapters -Pattern 'Sample').Description
# Sample discrete
```

Run the [Pester tests](tests/GpuGameGuard.Tests.ps1) in PowerShell:

```powershell
Install-Module Pester -MinimumVersion 6.0.0 -MaximumVersion 6.999.999 -Scope CurrentUser
Invoke-Pester -Path .\tests\GpuGameGuard.Tests.ps1 -Output Detailed -CI
```

The tests cover version reporting, adapter selection, protection precedence, custom-game protection and simulated enforcement with mocked process operations. They do not validate live DXGI counters, browser recovery, scheduled-task sessions or actual GPU memory release. [CI](.github/workflows/ci.yml) runs Pester, parsing checks and PSScriptAnalyzer on Windows; analyzer errors fail the job and warnings are reported.

For changes, include a focused regression test and distinguish mocked checks from Windows hardware validation in the pull request.

## License and support

[MIT License](LICENSE), copyright (c) 2026 Yuri Barreira. [Support the project](https://buymeacoffee.com/yurirod).
