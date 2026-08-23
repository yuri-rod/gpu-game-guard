# GPU Game Guard 🎮⚡

```
   ██████╗ ██████╗ ██╗   ██╗     ██████╗  █████╗ ███╗   ███╗███████╗
  ██╔════╝ ██╔══██╗██║   ██║    ██╔════╝ ██╔══██╗████╗ ████║██╔════╝
  ██║  ███╗██████╔╝██║   ██║    ██║  ███╗███████║██╔████╔██║█████╗  
  ██║   ██║██╔═══╝ ██║   ██║    ██║   ██║██╔══██║██║╚██╔╝██║██╔══╝  
  ╚██████╔╝██║     ╚██████╔╝    ╚██████╔╝██║  ██║██║ ╚═╝ ██║███████╗
   ╚═════╝ ╚═╝      ╚═════╝      ╚═════╝ ╚═╝  ╚═╝╚═╝     ╚═╝╚══════╝
```

**Dynamic GPU and VRAM guardian for PC gaming workstations.**  
*Automatically frees dedicated GPU memory from background AI models, browsers, and worker processes when a game launches.*

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-blue.svg)]()
[![PowerShell: 5.1+](https://img.shields.io/badge/powershell-5.1%2B-blue.svg)]()
[![GPU: NVIDIA | AMD | Intel](https://img.shields.io/badge/GPU-NVIDIA%20%7C%20AMD%20%7C%20Intel-green.svg)]()
[![Buy Me A Coffee](https://img.shields.io/badge/Buy%20Me%20A%20Coffee-Donate-yellow.svg?style=flat&logo=buy-me-a-coffee)](https://buymeacoffee.com/yurirod)

---

## Why GPU Game Guard?

If you use your Windows PC for both local AI development (Ollama, ComfyUI, PyTorch, Whisper) and PC gaming, you have likely encountered sudden frame drops, micro-stutters, or Direct3D Out-of-Memory (OOM) crashes because a background process was silently holding 4GB to 8GB of VRAM.

**GPU Game Guard** runs silently in the background as a lightweight, zero-overhead Windows daemon. It detects when a Steam or PC game launches, instantly sweeps unneeded GPU allocations, and releases enforcement when you stop playing.

---

## Key Capabilities

* **Hardware-Level DXGI & VRAM Inspection:** Queries exact per-process dedicated GPU memory using Windows DXGI adapters and performance counters.
* **Smart Steam & Game Detection:** Tracks active game sessions with zero polling lag.
* **Whitelisted Infrastructure:** Never interrupts GPU drivers, anti-cheats (Vanguard, EasyAntiCheat, BattlEye), fan curves (FanControl, MSI Afterburner), or active Jellyfin hardware transcodes.
* **Graceful Browser Handling:** Sends `CloseMainWindow` to browsers first so your open tabs and sessions are preserved.
* **Zero Overhead:** Consumes less than 15MB of RAM while idling.

---

## Quick Install

Open an elevated PowerShell prompt (Run as Administrator) and run:

```powershell
# Clone and register the background task in one step
git clone https://github.com/yuri-rod/gpu-game-guard.git C:\GpuGameGuard
powershell.exe -ExecutionPolicy Bypass -File C:\GpuGameGuard\GpuGameGuard.ps1 -Install
```

---

## Command Reference

```powershell
# Check active gaming GPU, active game status, and live VRAM allocations
powershell.exe -File GpuGameGuard.ps1 -Status

# Run a simulation pass without closing any processes
powershell.exe -File GpuGameGuard.ps1 -DryRun

# Execute an immediate one-off GPU memory sweep
powershell.exe -File GpuGameGuard.ps1 -PurgeNow

# Uninstall and stop the background scheduled task
powershell.exe -File GpuGameGuard.ps1 -Uninstall
```

---

## Protected vs. Enforced Processes

| Category | Policy | Examples |
| :--- | :--- | :--- |
| **System & Shell** | **Protected** | `dwm.exe`, `explorer.exe`, `csrss.exe`, `taskhostw.exe`, `wt.exe`, `powershell.exe` |
| **GPU Drivers** | **Protected** | `nvdisplay.container.exe`, `nvcontainer.exe`, `amdrsserv.exe` |
| **Hardware & Fans** | **Protected** | `FanControl.exe`, `MSIAfterburner.exe`, `RTSS.exe`, `HWiNFO64.exe` |
| **Launchers & DRM** | **Protected** | `steam.exe`, `steamwebhelper.exe`, `EpicGamesLauncher.exe`, `EADesktop.exe` |
| **Anti-Cheats** | **Protected** | `EasyAntiCheat.exe`, `BEService.exe`, `vgc.exe` (Vanguard), `faceit.exe` |
| **Media Server** | **Protected** | `jellyfin.exe`, `caddy.exe` (Remote hardware transcodes continue smoothly) |
| **Background AI** | **Terminated** | `ollama.exe`, `ollama_llama_server.exe`, `comfyui` worker processes |
| **Web Browsers** | **Graceful Close** | `chrome.exe`, `msedge.exe`, `firefox.exe`, `brave.exe`, `opera.exe`, `vivaldi.exe` |

---

## Architecture

```
                          +-------------------------+
                          |   Steam / Game Engine   |
                          +------------+------------+
                                       |
                               (Game Started)
                                       v
+------------------+      +-------------------------+      +-------------------+
|  Local AI & LLMs | <--- |   GPU Game Guard Daemon | ---> | Web Browsers      |
|  (Ollama, Comfy) |      |   (DXGI / Performance)  |      | (Chrome, Edge...) |
|  [TERMINATED]    |      +-------------------------+      | [GRACEFUL CLOSE]  |
+------------------+                   |                   +-------------------+
                                       |
                             (Game Exited / Idle)
                                       v
                          +-------------------------+
                          |  Enforcement Released   |
                          |  GPU Returned to Dev    |
                          +-------------------------+
```

---

## Support & Sponsorship

If GPU Game Guard helped keep your gaming sessions smooth and stutter-free, consider buying me a coffee:

<a href="https://buymeacoffee.com/yurirod"><img src="https://img.buymeacoffee.com/button-api/?text=Buy%20me%20a%20coffee&emoji=☕&slug=yurirod&button_colour=FFDD00&font_colour=000000&font_family=Inter&outline_colour=000000&coffee_colour=ffffff" /></a>

---

## License

MIT License (c) 2026 Yuri Barreira
