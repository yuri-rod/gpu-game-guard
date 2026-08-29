$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$scriptPath = Join-Path (Split-Path -Parent $here) 'GpuGameGuard.ps1'

function New-TestProcess {
    param(
        [int]$Id,
        [int]$ParentId = 1,
        [string]$Name = 'app.exe',
        [string]$Path = 'C:\Apps\app.exe',
        [string]$Created = '20260805120000.000000-180'
    )
    [pscustomobject]@{
        ProcessId = $Id
        ParentProcessId = $ParentId
        Name = $Name
        ExecutablePath = $Path
        CreationDate = $Created
    }
}

Describe 'GpuGameGuard Version & Config' {
    It 'reports valid semver version' {
        $v = & powershell.exe -NoProfile -File $scriptPath -Version
        $v | Should Match 'GpuGameGuard v1\.\d+\.\d+'
    }
}

Describe 'Resolve-GamingAdapter' {
    $rtx = [pscustomobject]@{
        Description = 'NVIDIA GeForce RTX 3060'
        VendorId = 0x10DE
        DeviceId = 0x2504
        DedicatedVideoMemory = 12884901888
        Luid = '0x00000000_0x00014800'
    }
    $amd = [pscustomobject]@{
        Description = 'AMD Radeon(TM) Graphics'
        VendorId = 0x1002
        DeviceId = 0x13C0
        DedicatedVideoMemory = 536870912
        Luid = '0x00000000_0x00015c17'
    }

    It 'selects discrete GPU with highest VRAM when pattern matches' {
        . $scriptPath -Version > $null
        $actual = Resolve-GamingAdapter -Adapters @($amd, $rtx) -Pattern 'NVIDIA'
        $actual.Luid | Should Be '0x00000000_0x00014800'
    }

    It 'falls back to highest dedicated VRAM when no pattern provided' {
        $actual = Resolve-GamingAdapter -Adapters @($amd, $rtx)
        $actual.Luid | Should Be '0x00000000_0x00014800'
    }
}
