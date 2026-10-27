BeforeAll {
    $script:scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'GpuGameGuard.ps1'

    # Dot-sourcing imports definitions without starting the watcher.
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
        $v = & (Get-Process -Id $PID).Path -NoProfile -File $script:scriptPath -Version
        $v | Should -Match 'GpuGameGuard v1\.\d+\.\d+'
    }

    It 'defines its functions when dot-sourced instead of running' {
        Get-Command Resolve-GamingAdapter -CommandType Function | Should -Not -BeNullOrEmpty
    }
}

Describe 'Invoke-GpuEnforcement protection' {
    BeforeEach {
        $script:DefaultProtected = @('protected-worker')
        $script:CustomGames = @('mygame')
        $script:AlwaysKillDuringGame = @('protected-worker', 'mygame')
        $script:TerminatedToRestore.Clear()

        Mock Get-GpuUsageByProcess {
            @(
                [pscustomobject]@{ PID = 101; MB = 128 }
                [pscustomobject]@{ PID = 102; MB = 256 }
            )
        }
        Mock Get-Process {
            param($Id, $Name)
            if ($Id -eq 101 -or $Name -eq 'protected-worker') {
                [pscustomobject]@{ Id = 101; ProcessName = 'protected-worker' }
            }
            if ($Id -eq 102 -or $Name -eq 'mygame') {
                [pscustomobject]@{ Id = 102; ProcessName = 'mygame' }
            }
        }
        Mock Stop-Process {}
        Mock Write-Log {}
    }

    It 'excludes protected processes and custom games from the preview' {
        $actions = @(Invoke-GpuEnforcement -Adapter $script:rtx -Simulate)
        $actions.Count | Should -Be 0
        Should -Invoke Stop-Process -Times 0 -Exactly
        $script:TerminatedToRestore.Count | Should -Be 0
    }

    It 'keeps protection when the same names are explicit kill targets' {
        $actions = @(Invoke-GpuEnforcement -Adapter $script:rtx)
        Should -Invoke Stop-Process -Times 0 -Exactly
        $actions.Count | Should -Be 0
    }

    It 'still selects an unprotected GPU process without stopping it in a preview' {
        $script:DefaultProtected = @()
        $script:AlwaysKillDuringGame = @()
        $actions = @(Invoke-GpuEnforcement -Adapter $script:rtx -Simulate)
        $actions.Count | Should -Be 1
        $actions[0].Name | Should -Be 'protected-worker'
        $actions[0].Action | Should -Be 'Terminate'
        Should -Invoke Stop-Process -Times 0 -Exactly
        $script:TerminatedToRestore.Count | Should -Be 0
    }

    It 'still stops an unprotected explicit target without GPU allocations' {
        $script:DefaultProtected = @()
        Mock Get-GpuUsageByProcess { @() }
        $actions = @(Invoke-GpuEnforcement -Adapter $script:rtx)
        $actions.Count | Should -Be 1
        $actions[0].Name | Should -Be 'protected-worker'
        $actions[0].Action | Should -Be 'TerminateAlways'
        Should -Invoke Stop-Process -Times 1 -Exactly -ParameterFilter { $Id -eq 101 }
        Should -Invoke Stop-Process -Times 0 -Exactly -ParameterFilter { $Id -eq 102 }
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
