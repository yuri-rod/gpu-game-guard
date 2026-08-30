BeforeAll {
    # $MyInvocation.MyCommand.Path is empty under Pester 5+, which silently left
    # $scriptPath blank and made every test here fail on a path error rather
    # than on anything it was meant to check. $PSScriptRoot is the replacement.
    $script:scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'GpuGameGuard.ps1'

    # Dot-sourcing returns early inside the script, so this only imports the
    # functions.
    . $script:scriptPath

    $script:rtx = [pscustomobject]@{
        Description = 'NVIDIA GeForce RTX 3060'
        VendorId = 0x10DE
        DeviceId = 0x2504
        DedicatedVideoMemory = 12884901888
        Luid = '0x00000000_0x00014800'
    }
    $script:amd = [pscustomobject]@{
        Description = 'AMD Radeon(TM) Graphics'
        VendorId = 0x1002
        DeviceId = 0x13C0
        DedicatedVideoMemory = 536870912
        Luid = '0x00000000_0x00015c17'
    }
}

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
        $v = & powershell.exe -NoProfile -File $script:scriptPath -Version
        $v | Should -Match 'GpuGameGuard v1\.\d+\.\d+'
    }

    It 'defines its functions when dot-sourced instead of running' {
        Get-Command Resolve-GamingAdapter -CommandType Function | Should -Not -BeNullOrEmpty
    }
}

Describe 'Resolve-GamingAdapter' {
    It 'selects discrete GPU with highest VRAM when pattern matches' {
        $actual = Resolve-GamingAdapter -Adapters @($script:amd, $script:rtx) -Pattern 'NVIDIA'
        $actual.Luid | Should -Be '0x00000000_0x00014800'
    }

    It 'falls back to highest dedicated VRAM when no pattern provided' {
        $actual = Resolve-GamingAdapter -Adapters @($script:amd, $script:rtx)
        $actual.Luid | Should -Be '0x00000000_0x00014800'
    }

    It 'returns nothing when handed no adapters' {
        Resolve-GamingAdapter -Adapters @() | Should -BeNullOrEmpty
    }
}
