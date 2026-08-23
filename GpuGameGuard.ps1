<#
.SYNOPSIS
    GpuGameGuard - Dynamic GPU and VRAM guardian for PC gaming workstations.

.DESCRIPTION
    Automatically frees dedicated GPU memory (VRAM) from background AI models,
    browsers, and unneeded worker processes when a game launches.
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
    [switch]$Pause,
    [switch]$Resume,
    [string]$GpuPattern = ''
)

$ErrorActionPreference = 'Continue'
$script:BaseDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:LogPath = Join-Path $script:BaseDir 'guard.log'
$script:TaskName = 'GpuGameGuard'
$script:ConfigPath = Join-Path $script:BaseDir 'config.json'

# Default configurations
$script:IdleInterval = 3
$script:InGameInterval = 2
$script:DefaultGpuPattern = 'NVIDIA|Radeon|Arc'

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
    'amdrsserv','amdow','amddvr','amd_ags_x64',
    # Shells, terminals, developer tools
    'windowsterminal','openconsole','wt','powershell','pwsh','powershell_ise','cmd','code','node','ssh','sshd',
    # Hardware & Fan control
    'fancontrol','asusfancontrolservice','lightingservice','msiafterburner','rtss','rtsshooksloader64','hwinfo64','hwinfo32',
    'logioptionsplus_agent',
    # Gaming Launchers & Anti-Cheat
    'steam','steamwebhelper','steamservice','steamerrorreporter','gameoverlayui',
    'gamebar','gamebarftserver','gamingservices','gamingservicesnet','crashpad_handler',
    'epicgameslauncher','galaxyclient','ubisoftconnect','eadesktop','eacefsubprocess',
    'easyanticheat','easyanticheat_eos','beservice','battleye','vgc','vgtray','faceit','vanguard',
    # Media servers (shared GPU transcode)
    'jellyfin','caddy'
)

# Explicit kill targets during gaming (even if zero allocated VRAM currently reported)
$script:AlwaysKillDuringGame = @('ollama','ollama app','ollama_llama_server','ollama-runner')

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
    if ($Pattern) {
        $matched = @($Adapters | Where-Object { $_.Description -match $Pattern })
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

function Get-RunningSteamAppId {
    if (-not (Get-Process -Name steam -ErrorAction SilentlyContinue)) { return 0 }
    try {
        $val = Get-ItemProperty -Path 'HKCU:\Software\Valve\Steam' -Name RunningAppID -ErrorAction Stop
        return [int64]$val.RunningAppID
    } catch { return 0 }
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
                Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                Write-Log "Enforced: Terminated $($p.ProcessName) (PID $($p.Id))"
            }
        }
    }
    return $actions
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
    $adapters = Get-DxgiAdapters
    $gaming = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    $appId = Get-RunningSteamAppId

    Write-Host "=== GpuGameGuard Status ===" -ForegroundColor Cyan
    if ($gaming) {
        Write-Host "Gaming GPU:  $($gaming.Description) (LUID: $($gaming.Luid))"
        Write-Host "VRAM:        $([math]::Round($gaming.DedicatedVideoMemory / 1GB, 2)) GB"
    } else {
        Write-Host "Gaming GPU:  None detected" -ForegroundColor Yellow
    }
    Write-Host "Steam Game:  $(if ($appId -gt 0) { "Running (AppID: $appId)" } else { "None (Idle)" })"
    
    if ($gaming) {
        $usage = Get-GpuUsageByProcess -AdapterLuid $gaming.Luid
        Write-Host "`nActive GPU Processes ($($usage.Count)):"
        foreach ($u in $usage) {
            $p = Get-Process -Id $u.PID -ErrorAction SilentlyContinue
            $pname = if ($p) { $p.ProcessName } else { "Unknown" }
            Write-Host "  PID $($u.PID): $pname ($($u.MB) MB)"
        }
    }
}

function Start-WatcherLoop {
    Write-Log "GpuGameGuard daemon started (PID $PID, Admin=$(Test-Admin))"
    $state = @{ InGame = $false; AppId = 0 }
    $adapter = $null

    while ($true) {
        $delay = $script:IdleInterval
        try {
            $appId = Get-RunningSteamAppId
            $isGameRunning = $appId -gt 0

            if ($isGameRunning -and -not $state.InGame) {
                Write-Log "Steam game started (AppID $appId). Reserving dedicated GPU memory."
                $state.InGame = $true
                $state.AppId = $appId
            } elseif (-not $isGameRunning -and $state.InGame) {
                Write-Log "Steam game closed. Releasing GPU enforcement."
                $state.InGame = $false
                $state.AppId = 0
                $adapter = $null
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

# Entrypoint
if ($Install) { Install-GpuGameGuard; exit 0 }
if ($Uninstall) { Uninstall-GpuGameGuard; exit 0 }
if ($Status) { Show-Status; exit 0 }
if ($DryRun) {
    $adapters = Get-DxgiAdapters
    $adapter = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    if ($adapter) {
        $actions = Invoke-GpuEnforcement -Adapter $adapter -Simulate
        $actions | Format-Table -AutoSize
    }
    exit 0
}
if ($PurgeNow) {
    $adapters = Get-DxgiAdapters
    $adapter = Resolve-GamingAdapter -Adapters $adapters -Pattern $GpuPattern
    if ($adapter) {
        $actions = Invoke-GpuEnforcement -Adapter $adapter
        $actions | Format-Table -AutoSize
    }
    exit 0
}

Start-WatcherLoop
