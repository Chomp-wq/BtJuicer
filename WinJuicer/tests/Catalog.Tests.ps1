BeforeDiscovery {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Ids = @(Get-JuicerCatalog | ForEach-Object { @{ Id = $_.Id } })
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Catalog = @(Get-JuicerCatalog)
    $script:ActionTypes = @('Registry', 'RegistryToken', 'Service', 'Spi', 'Task', 'DefenderExclusion', 'Appx', 'Dns', 'Feature', 'Custom')
    # Keys a hashtable answers even when absent, because they are its own
    # members: $h.Remove is a method, and a method is truthy.
    $script:Reserved = @('Add', 'Clear', 'Clone', 'Contains', 'ContainsKey', 'ContainsValue', 'CopyTo', 'Count', 'Equals',
        'GetEnumerator', 'GetHashCode', 'GetType', 'IsFixedSize', 'IsReadOnly', 'IsSynchronized', 'Item', 'Keys',
        'Remove', 'SyncRoot', 'ToString', 'Values')

    # The state a machine messed up by other "optimizers" would be in, so the
    # repairs have something to repair.
    function Initialize-BrokenMachine {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $mm = 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Memory Management'
        Write-JuicerReg $mm 'PagingFiles' 'MultiString' @('')
        Write-JuicerReg $mm 'LargeSystemCache' 'DWord' 1
        Write-JuicerReg $mm 'ClearPageFileAtShutdown' 'DWord' 1
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification' 'DWord' 1
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\DeviceGuard\Scenarios\HypervisorEnforcedCodeIntegrity' 'Enabled' 'DWord' 1
        Write-JuicerReg 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'String' 'VRROptimizeEnable=0;'
        Write-JuicerReg 'HKCU\Control Panel\Mouse' 'MouseSpeed' 'String' '1'
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{11111111-2222-3333-4444-555555555555}' 'DhcpIPAddress' 'String' '192.168.1.20'
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{66666666-2222-3333-4444-555555555555}' 'DhcpIPAddress' 'String' '0.0.0.0'
        $m.Backend.State.Services['SysMain'] = @{ Start = 'Disabled'; Running = $false }
        $m.Backend.State.Services['wuauserv'] = @{ Start = 'Disabled'; Running = $false }
        $m.Backend.State.Services['DiagTrack'] = @{ Start = 'Automatic'; Running = $true }
        $m.Backend.State.Services['WSearch'] = @{ Start = 'AutomaticDelayed'; Running = $true }
        $m.Backend.State.Spi[[uint32]0x1042] = $true
        $m.Fake.Bcd['useplatformclock'] = 'Yes'
        $m.Backend.State.Services['MapsBroker'] = @{ Start = 'AutomaticDelayed'; Running = $true }
        $m.Backend.State.Services['TrkWks'] = @{ Start = 'Automatic'; Running = $true }
        $m.Backend.State.Services['Spooler'] = @{ Start = 'Automatic'; Running = $true }
        foreach ($t in 'Application Experience\|Microsoft Compatibility Appraiser', 'Application Experience\|ProgramDataUpdater',
            'Customer Experience Improvement Program\|Consolidator', 'Customer Experience Improvement Program\|UsbCeip',
            'DiskDiagnostic\|Microsoft-Windows-DiskDiagnosticDataCollector') {
            $m.Backend.State.Tasks["\Microsoft\Windows\$t"] = @{ Enabled = $true }
        }
        foreach ($f in 'NetFx3', 'DirectPlay', 'Microsoft-Windows-Subsystem-Linux', 'VirtualMachinePlatform', 'Containers-DisposableClientVM', 'Microsoft-Hyper-V-All') {
            $m.Backend.State.Features[$f] = @{ Enabled = $false }
        }
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\App Paths\msedge.exe' '' 'String' 'C:\Edge\msedge.exe'
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'AppsUseLightTheme' 'DWord' 1
        $m
    }
}

Describe 'Catálogo' {
    It 'cada ajuste tiene todo lo que la interfaz enseña' {
        foreach ($t in $Catalog) {
            foreach ($f in 'Id', 'Title', 'What', 'Gain', 'Cost', 'Category') {
                $t[$f] | Should -Not -BeNullOrEmpty -Because "$($t.Id) necesita $f"
            }
            $t.Level | Should -BeIn @(0, 1, 2, 3) -Because $t.Id
            $t.Impact | Should -BeIn @('Alto', 'Medio', 'Bajo') -Because $t.Id
            $t.Reboot | Should -BeIn @('No', 'Explorador', 'Sesion', 'Reinicio') -Because $t.Id
            $t.Category | Should -BeIn (& (Get-Module WinJuicer) { $script:CategoryOrder }) -Because $t.Id
        }
    }

    It 'los identificadores son únicos y con forma categoría.nombre' {
        $ids = @($Catalog | ForEach-Object { $_.Id })
        ($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        foreach ($id in $ids) { $id | Should -Match '^[a-z]+\.[a-z0-9]+$' }
    }

    It 'ningún campo choca con un miembro de Hashtable' {
        foreach ($t in $Catalog) {
            foreach ($k in $t.Keys) { $k | Should -Not -BeIn $Reserved -Because "$($t.Id).$k" }
            if ($t.Actions -is [scriptblock]) { continue }
            foreach ($a in $t.Actions) { foreach ($k in $a.Keys) { $k | Should -Not -BeIn $Reserved -Because "$($t.Id) acción $k" } }
        }
    }

    It 'las acciones están bien formadas' {
        foreach ($t in $Catalog) {
            if ($t.Actions -is [scriptblock]) { continue }
            @($t.Actions).Count | Should -BeGreaterThan 0 -Because $t.Id
            foreach ($a in @($t.Actions) + @($t.Off | Where-Object { $_ })) {
                $a.Type | Should -BeIn $ActionTypes -Because $t.Id
                switch ($a.Type) {
                    { $_ -in 'Registry', 'RegistryToken' } {
                        { Split-JuicerRegPath $a.Path } | Should -Not -Throw -Because $t.Id
                        $a.Path | Should -Not -Match '\\$' -Because $t.Id
                        $a.Contains('Name') | Should -BeTrue -Because $t.Id
                        if ($a.Kind) { $a.Kind | Should -BeIn @('String', 'ExpandString', 'MultiString', 'DWord', 'QWord', 'Binary') }
                        if (-not $a.Delete -and $a.Type -eq 'Registry') { { ConvertTo-JuicerRegValue (Get-JuicerDesiredReg $a).Kind $a.Value } | Should -Not -Throw -Because $t.Id }
                    }
                    'Service' { $a.Start | Should -BeIn @('Disabled', 'Manual', 'Automatic', 'AutomaticDelayed') }
                    'Feature' { $a.Name | Should -Not -BeNullOrEmpty; $a.Enabled | Should -BeOfType [bool] }
                    'Custom' {
                        $a.Key | Should -Not -BeNullOrEmpty -Because $t.Id
                        $a.Label | Should -Not -BeNullOrEmpty -Because $t.Id
                        foreach ($sb in 'Test', 'Capture', 'Apply', 'Restore') { $a[$sb] | Should -BeOfType [scriptblock] -Because "$($t.Id).$sb" }
                    }
                }
            }
        }
    }

    It 'dos ajustes nunca tocan el mismo valor' {
        $m = Initialize-BrokenMachine
        $seen = @{}
        foreach ($t in $Catalog) {
            foreach ($a in (Resolve-JuicerActions $t)) {
                $id = Get-JuicerActionId $a $t.Id
                $seen.ContainsKey($id) | Should -BeFalse -Because "$id lo usan $($seen[$id]) y $($t.Id)"
                $seen[$id] = $t.Id
            }
        }
    }

    It 'hay mitos explicados' {
        foreach ($m in (Get-JuicerMyths)) { $m.Title | Should -Not -BeNullOrEmpty; $m.Why | Should -Not -BeNullOrEmpty }
        @(Get-JuicerMyths).Count | Should -BeGreaterThan 10
    }

    It 'los perfiles se incluyen unos a otros, y lo «a la carta» no está en ninguno' {
        (Get-JuicerProfile 1).Count | Should -BeLessThan (Get-JuicerProfile 2).Count
        (Get-JuicerProfile 3).Count | Should -Be @($Catalog | Where-Object { $_.Level -ge 1 }).Count
        @(Get-JuicerProfile 1 | Where-Object { $_.Level -ne 1 }).Count | Should -Be 0
        @(Get-JuicerProfile 3 | Where-Object { $_.Level -eq 0 }).Count | Should -Be 0
    }

    It 'lo que va en los dos sentidos tiene su contrario, y el contrario se deshace sin el catálogo' {
        $toggles = @($Catalog | Where-Object { $_.Off })
        $toggles.Count | Should -BeGreaterThan 8
        foreach ($t in $toggles) {
            $t.Level | Should -Be 0 -Because $t.Id
            @($t.Off).Count | Should -Be @($t.Actions).Count -Because $t.Id
            foreach ($a in $t.Off) { $a.Type | Should -Not -Be 'Custom' -Because "$($t.Id): un contrario se deshace sin buscar en el catálogo" }
        }
        foreach ($t in @($Catalog | Where-Object { $_.Category -in 'Preferencias', 'Componentes' })) { $t.Off | Should -Not -BeNullOrEmpty -Because $t.Id }
    }
}

Describe 'Cada ajuste, ida y vuelta' {
    It '<Id> se aplica y se deshace sin dejar rastro' -ForEach $Ids {
        $m = Initialize-BrokenMachine
        $t = Find-JuicerTweak $Id
        $state = Get-JuicerTweakState $t
        if ($state.State -in 'NoAplica', 'Error') {
            Set-ItResult -Skipped -Because "aquí no aplica: $($state.Reason)"
            return
        }
        $before = Get-MachineSnapshot $m
        $r = Invoke-JuicerTweak $t
        $r.Outcome | Should -BeIn @('Aplicado', 'YaEstaba') -Because $r.Message
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        if ($r.Outcome -eq 'Aplicado') {
            (Undo-JuicerTweak $Id).Outcome | Should -Be 'Deshecho'
        }
        Get-MachineSnapshot $m | Should -Be $before
        (Read-JuicerJournal).Count | Should -Be 0
    }
}

Describe 'Interruptores, en los dos sentidos' {
    BeforeDiscovery {
        $script:ToggleIds = @(Get-JuicerCatalog | Where-Object { $_.Off } | ForEach-Object { @{ Id = $_.Id } })
    }

    It '<Id>: encender, apagar y volver, sin dejar rastro' -ForEach $ToggleIds {
        $m = Initialize-BrokenMachine
        $t = Find-JuicerTweak $Id
        if ((Get-JuicerTweakState $t).State -eq 'NoAplica') { Set-ItResult -Skipped -Because 'aquí no aplica'; return }
        $before = Get-MachineSnapshot $m
        [void](Set-JuicerToggle $t $true)
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        [void](Set-JuicerToggle $t $false)
        (Get-JuicerTweakState (Get-JuicerInverseTweak $t)).State | Should -Be 'Aplicado'
        [void](Set-JuicerToggle $t $true)
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        [void](Undo-JuicerAll)
        Get-MachineSnapshot $m | Should -Be $before
        (Read-JuicerJournal).Count | Should -Be 0
    }
}

Describe 'Todo el catálogo a la vez' {
    It 'aplicar los tres niveles y deshacerlo todo devuelve la máquina intacta' {
        $m = Initialize-BrokenMachine
        $before = Get-MachineSnapshot $m
        $results = @(foreach ($t in (Get-JuicerProfile 3)) { Invoke-JuicerTweak $t })
        @($results | Where-Object { $_.Outcome -in 'Error', 'NoSeMantuvo' -and $_.Id -ne 'reparar.tcp' }).Count | Should -Be 0
        @($results | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -BeGreaterThan 25
        [void](Undo-JuicerAll)
        Get-MachineSnapshot $m | Should -Be $before
    }
}
