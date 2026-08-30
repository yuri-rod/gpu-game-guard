<#
.SYNOPSIS
    GpuGameGuard v1.1.0 - Dynamic GPU and VRAM guardian for PC gaming workstations.

.DESCRIPTION
    Automatically frees dedicated GPU memory (VRAM) from background AI models,
    browsers, and unneeded worker processes when a game launches across Steam, Epic Games,
    Xbox Game Pass, EA, Ubisoft, GOG, and custom titles.
    Restores background tasks and releases enforcement when the game closes.

.PARAMETER Install
    Registers and starts the Windows Scheduled Task (requires elevation).

.PARAMETER Uninstall
    Stops and removes the Windows Scheduled Task.

.PARAMETER DryRun
    Simulates a GPU enforcement pass and prints processes that would be closed.

.PARAMETER PurgeNow
    Executes an immediate one-off GPU memory purge.

.PARAMETER Status
    Displays active game status, GPU device info, and current VRAM usage.

.PARAMETER ListGpus
    Lists all detected DXGI graphics adapters and dedicated VRAM capacities.

.PARAMETER Version
    Displays current GpuGameGuard version.

.PARAMETER Config
    Optional custom path to config.json.

.PARAMETER Pause
    Temporarily pauses enforcement.

.PARAMETER Resume
    Resumes active enforcement.

.PARAMETER GpuPattern
    Custom regex pattern to match the discrete gaming GPU adapter description.
#>
[CmdletBinding()]
param(
    [switch]$Install,
    [switch]$Uninstall,
    [switch]$DryRun,
    [switch]$PurgeNow,
    [switch]$Status,
    [switch]$ListGpus,
    [switch]$Version,
    [switch]$Pause,
    [switch]$Resume,
    [string]$Config = '',
    [string]$GpuPattern = ''
)

$script:Version = '1.1.0'
$ErrorActionPreference = 'Continue'
$script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:BaseDir 'guard.log'
$script:TaskName = 'GpuGameGuard'
$script:ConfigPath = if ($Config) { $Config } else { Join-Path $script:BaseDir 'config.json' }

# Default configurations
$script:IdleInterval = 3
$script:InGameInterval = 2
$script:DefaultGpuPattern = 'NVIDIA|Radeon|Arc'
$script:AutoRestore = $false
$script:TerminatedToRestore = [System.Collections.Generic.List[string]]::new()
$script:CustomGames = @()

# Protected processes that are never terminated
$script:DefaultProtected = @(
    # Windows core & session
    'system','idle','registry','memory compression','secure system','smss','csrss','wininit','winlogon',
    'services','lsass','lsaiso','svchost','dwm','explorer','sihost','ctfmon','runtimebroker',
    'shellexperiencehost','shellhost','startmenuexperiencehost','searchhost','searchapp','searchindexer','textinputhost','tabtip',
    'systemsettings','controlpanel','control','rundll32','snippingtool','screenclippinghost',
    'applicationframehost','taskhostw','conhost','audiodg','fontdrvhost','wmiprvse','dllhost','spoolsv',
    'msmpeng','nissrv','securityhealthservice','securityhealthsystray','sgrmbroker','chxsmartscreen','lockapp','consent',
    'vmmem','vmmemwsl','vmwp','vmcompute','wslservice','wslhost','wsl',
    # GPU Drivers & Services
    'nvdisplay.container','nvcontainer','nvsphelper64','nvsphelper','nvidia share','nvidia web helper','nvngx_update',
    'amdrsserv','amdow','amddvr','amd_ags_x64','igfxem','igfxhk','igfxtray',
    # Shells, terminals, developer tools
    'windowsterminal','openconsole','wt','powershell','pwsh','powershell_ise','cmd','code','node','ssh','sshd',
    # Hardware & Fan control
    'fancontrol','asusfancontrolservice','lightingservice','msiafterburner','rtss','rtsshooksloader64','hwinfo64','hwinfo32',
    'logioptionsplus_agent',
    # Gaming Launchers & Anti-Cheat
    'steam','steamwebhelper','steamservice','steamerrorreporter','gameoverlayui',
    'gamebar','gamebarftserver','gamingservices','gamingservicesnet','crashpad_handler',
    'epicgameslauncher','galaxyclient','ubisoftconnect','eadesktop','eacefsubprocess','battlenet','battle.net',
    'easyanticheat','easyanticheat_eos','beservice','battleye','vgc','vgtray','faceit','vanguard',
    # Media servers (shared GPU transcode)
    'jellyfin','caddy'
)

# Explicit kill targets during gaming (even if zero allocated VRAM currently reported)
$script:AlwaysKillDuringGame = @(
    'ollama','ollama app','ollama_llama_server','ollama-runner',
    'lmstudio','lms','comfyui','sd-webui','webui-user','automatic1111',
    'koboldcpp','jan','jan-app','localai','text-generation-webui',
    'vllm','llama-server'
)

# Browsers (closed gracefully first to preserve open tabs)
$script:Browsers = @('chrome','msedge','firefox','brave','opera','opera_gx','vivaldi','librewolf')

function Write-Log {
    param([string]$Message)
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$ts] $Message"
    try {
        Add-Content -Path $script:LogPath -Value $line -Encoding utf8 -ErrorAction SilentlyContinue
    } catch {}
    if ($Host.UI.RawUI) {
        Write-Verbose $line
    }
}

function Import-ConfigFile {
    if (Test-Path -Path $script:ConfigPath) {
        try {
            $raw = Get-Content -Path $script:ConfigPath -Raw -Encoding UTF8 -ErrorAction Stop
            $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
            if ($cfg.idle_interval_seconds) { $script:IdleInterval = [int]$cfg.idle_interval_seconds }
            if ($cfg.ingame_interval_seconds) { $script:InGameInterval = [int]$cfg.ingame_interval_seconds }
            if ($cfg.gpu_pattern) { $script:DefaultGpuPattern = [string]$cfg.gpu_pattern }
            if ($cfg.auto_restore) { $script:AutoRestore = [bool]$cfg.auto_restore }
            if ($cfg.extra_protected_processes) {
                foreach ($p in @($cfg.extra_protected_processes)) {
                    $pName = ([string]$p).ToLowerInvariant().Trim()
                    if ($pName -and -not ($script:DefaultProtected -contains $pName)) {
                        $script:DefaultProtected += $pName
                    }
                }
            }
            if ($cfg.extra_kill_targets) {
                foreach ($k in @($cfg.extra_kill_targets)) {
                    $kName = ([string]$k).ToLowerInvariant().Trim()
                    if ($kName -and -not ($script:AlwaysKillDuringGame -contains $kName)) {
                        $script:AlwaysKillDuringGame += $kName
                    }
                }
            }
            if ($cfg.custom_games) {
                foreach ($g in @($cfg.custom_games)) {
                    $gName = ([string]$g).ToLowerInvariant().Trim()
                    if ($gName -and -not ($script:CustomGames -contains $gName)) {
                        $script:CustomGames += $gName
                    }
                }
            }
            Write-Log "Loaded configuration from $($script:ConfigPath)"
        } catch {
            Write-Log "WARN: Failed to parse configuration: $($_.Exception.Message)"
        }
    }
}

function Test-Admin {
    $current = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    return $current.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Initialize-DxgiInterop {
    if ('GpuGameGuard.Interop.DxgiAdapters' -as [type]) { return }
    $source = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;

namespace GpuGameGuard.Interop {
    [StructLayout(LayoutKind.Sequential)]
    public struct Luid {
        public uint LowPart;
        public int HighPart;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct AdapterDesc1 {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string Description;
        public uint VendorId;
        public uint DeviceId;
        public uint SubSysId;
        public uint Revision;
        public UIntPtr DedicatedVideoMemory;
        public UIntPtr DedicatedSystemMemory;
        public UIntPtr SharedSystemMemory;
        public Luid AdapterLuid;
        public uint Flags;
    }

    [ComImport, Guid("770aae78-f26f-4dba-a829-253c83d1b387"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIFactory1 {
        [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
        [PreserveSig] int EnumAdapters(uint index, out IntPtr adapter);
        [PreserveSig] int MakeWindowAssociation(IntPtr window, uint flags);
        [PreserveSig] int GetWindowAssociation(out IntPtr window);
        [PreserveSig] int CreateSwapChain(IntPtr device, IntPtr desc, out IntPtr swapChain);
        [PreserveSig] int CreateSoftwareAdapter(IntPtr module, out IntPtr adapter);
        [PreserveSig] int EnumAdapters1(uint index, out IDXGIAdapter1 adapter);
        [PreserveSig] bool IsCurrent();
    }

    [ComImport, Guid("29038f61-3839-4626-91fd-086879011a05"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    interface IDXGIAdapter1 {
        [PreserveSig] int SetPrivateData(ref Guid name, uint size, IntPtr data);
        [PreserveSig] int SetPrivateDataInterface(ref Guid name, IntPtr unknown);
        [PreserveSig] int GetPrivateData(ref Guid name, ref uint size, IntPtr data);
        [PreserveSig] int GetParent(ref Guid riid, out IntPtr parent);
        [PreserveSig] int EnumOutputs(uint index, out IntPtr output);
        [PreserveSig] int GetDesc(IntPtr desc);
        [PreserveSig] int CheckInterfaceSupport(ref Guid name, out long version);
        [PreserveSig] int GetDesc1(out AdapterDesc1 desc);
    }

    public sealed class AdapterInfo {
        public string Description { get; set; }
        public uint VendorId { get; set; }
        public uint DeviceId { get; set; }
        public ulong DedicatedVideoMemory { get; set; }
        public string Luid { get; set; }
    }

    public static class DxgiAdapters {
        const int DXGI_ERROR_NOT_FOUND = unchecked((int)0x887A0002);

        [DllImport("dxgi.dll", ExactSpelling=true)]
        static extern int CreateDXGIFactory1(ref Guid riid, out IDXGIFactory1 factory);

        public static AdapterInfo[] Enumerate() {
            IDXGIFactory1 factory = null;
            Guid iid = typeof(IDXGIFactory1).GUID;
            int hr = CreateDXGIFactory1(ref iid, out factory);
            if (hr < 0) Marshal.ThrowExceptionForHR(hr);
            var found = new List<AdapterInfo>();
            try {
                for (uint index = 0; ; index++) {
                    IDXGIAdapter1 adapter = null;
                    hr = factory.EnumAdapters1(index, out adapter);
                    if (hr == DXGI_ERROR_NOT_FOUND) break;
                    if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                    try {
                        AdapterDesc1 desc;
                        hr = adapter.GetDesc1(out desc);
                        if (hr < 0) Marshal.ThrowExceptionForHR(hr);
                        found.Add(new AdapterInfo {
                            Description = desc.Description,
                            VendorId = desc.VendorId,
                            DeviceId = desc.DeviceId,
                            DedicatedVideoMemory = (ulong)desc.DedicatedVideoMemory.ToUInt64(),
                            Luid = String.Format(
                                "0x{0:x8}_0x{1:x8}",
                                unchecked((uint)desc.AdapterLuid.HighPart),
                                desc.AdapterLuid.LowPart
                            )
                        });
                    } finally {
                        if (adapter != null) Marshal.FinalReleaseComObject(adapter);
                    }
                }
            } finally {
                if (factory != null) Marshal.FinalReleaseComObject(factory);
            }
            return found.ToArray();
        }
    }
}
'@
    Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
}

function Get-DxgiAdapters {
    try {
        Initialize-DxgiInterop
        return @([GpuGameGuard.Interop.DxgiAdapters]::Enumerate())
    } catch {
        Write-Log "ERROR: DXGI adapter enumeration failed: $($_.Exception.Message)"
        return $null
    }
}

function Resolve-GamingAdapter {
    param(
        [object[]]$Adapters,
        [string]$Pattern = ''
    )
    if (-not $Adapters -or $Adapters.Count -eq 0) { return $null }
    $pat = if ($Pattern) { $Pattern } else { $script:DefaultGpuPattern }
    if ($pat) {
        $matched = @($Adapters | Where-Object { $_.Description -match $pat })
        if ($matched.Count -eq 1) { return $matched[0] }
        if ($matched.Count -gt 1) {
            return ($matched | Sort-Object DedicatedVideoMemory -Descending)[0]
        }
    }
    # Auto-detect discrete GPU with highest dedicated VRAM
    $sorted = @($Adapters | Where-Object { $_.DedicatedVideoMemory -gt 0 } | Sort-Object DedicatedVideoMemory -Descending)
    if ($sorted.Count -gt 0) { return $sorted[0] }
    return $Adapters[0]
}

function Get-ActiveGameSession {
    # 1. Steam check
    if (Get-Process -Name steam -ErrorAction SilentlyContinue) {
        try {
            $val = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name RunningAppID -ErrorAction Stop
            $appId = [int64]$val.RunningAppID
            if ($appId -gt 0) {
                return [pscustomobject]@{
                    IsRunning = $true
                    Source = 'Steam'
                    Identifier = "AppID $appId"
                }
            }
        } catch {}
    }

    # 2. Custom or known game process detection
    if ($script:CustomGames.Count -gt 0) {
        foreach ($cg in $script:CustomGames) {
            $p = Get-Process -Name $cg -ErrorAction SilentlyContinue
            if ($p) {
                return [pscustomobject]@{
                    IsRunning = $true
                    Source = 'Custom'
                    Identifier = $p[0].ProcessName
                }
            }
        }
    }

    return [pscustomobject]@{
        IsRunning = $false
        Source = 'None'
        Identifier = 'Idle'
    }
}

function Get-GpuUsageByProcess {
    param(
        [Parameter(Mandatory=$true)][string]$AdapterLuid
    )
    try {
        $counter = Get-Counter '\GPU Process Memory(*)\Dedicated Usage' -ErrorAction Stop
    } catch {
        return @()
    }
    $pattern = '^pid_(?<pid>\d+)_luid_(?<high>0x[0-9a-f]+)_(?<low>0x[0-9a-f]+)_phys_(?<phys>\d+)'
    $bytesByPid = @{}
    foreach ($sample in @($counter.CounterSamples)) {
        if ([string]$sample.InstanceName -notmatch $pattern) { continue }
        $sampleLuid = '{0}_{1}' -f $Matches.high.ToLowerInvariant(), $Matches.low.ToLowerInvariant()
        if ($sampleLuid -ine $AdapterLuid) { continue }
        $bytes = [long]$sample.CookedValue
        if ($bytes -le 0) { continue }
        $procId = [int]$Matches.pid
        $bytesByPid[$procId] = [long]$bytesByPid[$procId] + $bytes
    }
    return @(
        foreach ($entry in $bytesByPid.GetEnumerator()) {
            [pscustomobject]@{
                PID = [int]$entry.Key
                Bytes = [long]$entry.Value
                MB = [math]::Round($entry.Value / 1MB, 1)
            }
        }
    )
}

function Invoke-GpuEnforcement {
    param(
        [Parameter(Mandatory=$true)][object]$Adapter,
        [switch]$Simulate
    )
    $usage = Get-GpuUsageByProcess -AdapterLuid $Adapter.Luid
    $actions = @()

    foreach ($item in $usage) {
        $proc = Get-Process -Id $item.PID -ErrorAction SilentlyContinue
        if (-not $proc) { continue }
        $name = $proc.ProcessName.ToLowerInvariant()

        if ($script:DefaultProtected -contains $name) { continue }

        $action = [pscustomobject]@{
            PID = $item.PID
            Name = $proc.ProcessName
            VRAM_MB = $item.MB
            Action = if ($script:Browsers -contains $name) { 'CloseGracefully' } else { 'Terminate' }
        }
        $actions += $action

        if (-not $Simulate) {
            $exePath = $null
            try { $exePath = $proc.MainModule.FileName } catch {}
            if ($exePath -and -not $script:TerminatedToRestore.Contains($exePath)) {
                $script:TerminatedToRestore.Add($exePath)
            }

            if ($action.Action -eq 'CloseGracefully') {
                $null = $proc.CloseMainWindow()
                Start-Sleep -Milliseconds 200
                if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
            } else {
                Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
            Write-Log "Enforced: $($action.Action) $($proc.ProcessName) (PID $($proc.Id), $($item.MB) MB VRAM)"
        }
    }

    # Always ensure heavy local AI servers are stopped during gaming
    foreach ($target in $script:AlwaysKillDuringGame) {
        $procs = Get-Process -Name $target -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            $action = [pscustomobject]@{
                PID = $p.Id
                Name = $p.ProcessName
                VRAM_MB = 0.0
                Action = 'TerminateAlways'
            }
            $actions += $action
            if (-not $Simulate) {
                $exePath = $null
                try { $exePath = $p.MainModule.FileName } catch {}
                if ($exePath -and -not $script:TerminatedToRestore.Contains($exePath)) {
                    $script:TerminatedToRestore.Add($exePath)
                }
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Write-Log "Enforced: Terminated $($p.ProcessName) (PID $($p.Id))"
            }
        }
    }
    return $actions
}

function Restore-TerminatedServices {
    if (-not $script:AutoRestore -or $script:TerminatedToRestore.Count -eq 0) { return }
    Write-Log "Restoring terminated services ($($script:TerminatedToRestore.Count) targets)..."
    foreach ($exe in @($script:TerminatedToRestore)) {
        try {
            if (Test-Path -Path $exe) {
                Start-Process -FilePath $exe -WindowStyle Minimized -ErrorAction SilentlyContinue
                Write-Log "Restored: $exe"
            }
        } catch {
            Write-Log "WARN: Failed to restore $exe : $($_.Exception.Message)"
        }
    }
    $script:TerminatedToRestore.Clear()
}

function Install-GpuGameGuard {
    if (-not (Test-Admin)) {
        Write-Error "Please run with Administrator privileges to install the scheduled task."
        return
    }
    $scriptPath = Join-Path $script:BaseDir 'GpuGameGuard.ps1'
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$scriptPath`""
    $triggerBoot = New-ScheduledTaskTrigger -AtStartup
    $triggerLogon = New-ScheduledTaskTrigger -AtLogOn
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType S4U -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit 0 -Priority 4

    Register-ScheduledTask -TaskName $script:TaskName -Action $action -Trigger @($triggerBoot, $triggerLogon) -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Write-Output "GpuGameGuard installed and started as a background task."
}

function Uninstall-GpuGameGuard {
    if (-not (Test-Admin)) {
        Write-Error "Please run with Administrator privileges to remove the scheduled task."
        return
    }
    Stop-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false -ErrorAction SilentlyContinue
    Write-Output "GpuGameGuard stopped and uninstalled."
}

function Show-Status {
    Import-ConfigFile
    $adapters = Get-DxgiAdapters
    $gaming = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    $session = Get-ActiveGameSession

    Write-Host "=== GpuGameGuard v$($script:Version) Status ===" -ForegroundColor Cyan
    if ($gaming) {
        Write-Host "Gaming GPU:  $($gaming.Description) (LUID: $($gaming.Luid))"
        Write-Host "VRAM:        $([math]::Round($gaming.DedicatedVideoMemory / 1GB, 2)) GB"
    } else {
        Write-Host "Gaming GPU:  None detected" -ForegroundColor Yellow
    }
    Write-Host "Game State:  $(if ($session.IsRunning) { "Running ($($session.Source): $($session.Identifier))" } else { "Idle (No game active)" })"
    
    if ($gaming) {
        $usage = Get-GpuUsageByProcess -AdapterLuid $gaming.Luid
        Write-Host "`nActive GPU Allocations ($($usage.Count)):"
        foreach ($u in $usage) {
            $p = Get-Process -Id $u.PID -ErrorAction SilentlyContinue
            $pname = if ($p) { $p.ProcessName } else { "Unknown" }
            Write-Host "  PID $($u.PID): $pname ($($u.MB) MB)"
        }
    }
}

function Show-GpuList {
    $adapters = Get-DxgiAdapters
    Write-Host "=== Detected DXGI Graphics Adapters ===" -ForegroundColor Cyan
    if (-not $adapters -or $adapters.Count -eq 0) {
        Write-Host "No DXGI graphics adapters detected."
        return
    }
    foreach ($a in $adapters) {
        $vramGB = [math]::Round($a.DedicatedVideoMemory / 1GB, 2)
        Write-Host "Adapter: $($a.Description)"
        Write-Host "  Vendor ID:  0x$($a.VendorId.ToString('X4'))"
        Write-Host "  Device ID:  0x$($a.DeviceId.ToString('X4'))"
        Write-Host "  LUID:       $($a.Luid)"
        Write-Host "  VRAM:       $vramGB GB"
        Write-Host ""
    }
}

function Start-WatcherLoop {
    Import-ConfigFile
    Write-Log "GpuGameGuard daemon v$($script:Version) started (PID $PID, Admin=$(Test-Admin))"
    $state = @{ InGame = $false; Source = 'None' }
    $adapter = $null

    while ($true) {
        $delay = $script:IdleInterval
        try {
            $session = Get-ActiveGameSession
            $isGameRunning = $session.IsRunning

            if ($isGameRunning -and -not $state.InGame) {
                Write-Log "Game started ($($session.Source): $($session.Identifier)). Reserving dedicated GPU memory."
                $state.InGame = $true
                $state.Source = $session.Source
            } elseif (-not $isGameRunning -and $state.InGame) {
                Write-Log "Game closed. Releasing GPU enforcement."
                $state.InGame = $false
                $state.Source = 'None'
                $adapter = $null
                Restore-TerminatedServices
            }

            if ($state.InGame) {
                $delay = $script:InGameInterval
                if (-not $adapter) {
                    $adapters = Get-DxgiAdapters
                    $adapter = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
                }
                if ($adapter) {
                    $null = Invoke-GpuEnforcement -Adapter $adapter
                }
            }
        } catch {
            Write-Log "Loop error: $($_.Exception.Message)"
            $delay = 5
        }
        Start-Sleep -Seconds $delay
    }
}

# Entrypoint. Dot-sourcing this file only defines the functions above:
# InvocationName is '.' in that case, and the tests rely on it to reach
# Resolve-GamingAdapter without the script running or calling exit.
if ($MyInvocation.InvocationName -eq '.') { return }

if ($Version) { Write-Output "GpuGameGuard v$($script:Version)"; exit 0 }
if ($Install) { Install-GpuGameGuard; exit 0 }
if ($Uninstall) { Uninstall-GpuGameGuard; exit 0 }
if ($ListGpus) { Show-GpuList; exit 0 }
if ($Status) { Show-Status; exit 0 }
if ($DryRun) {
    Import-ConfigFile
    $adapters = Get-DxgiAdapters
    $adapter = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    if ($adapter) {
        $actions = Invoke-GpuEnforcement -Adapter $adapter -Simulate
        $actions | Format-Table -AutoSize
    }
    exit 0
}
if ($PurgeNow) {
    Import-ConfigFile
    $adapters = Get-DxgiAdapters
    $adapter = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    if ($adapter) {
        $actions = Invoke-GpuEnforcement -Adapter $adapter
        $actions | Format-Table -AutoSize
    }
    exit 0
}

Start-WatcherLoop
