BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
}

Describe 'Valores de registro' {
    It 'normaliza un DWORD venga como venga' {
        foreach ($v in -1, 0xFFFFFFFFL, [uint32]::MaxValue, '4294967295', [int64]4294967295) {
            ConvertTo-JuicerRegValue 'DWord' $v | Should -Be ([uint32]::MaxValue)
        }
        ConvertTo-JuicerRegValue 'DWord' 0x80000001L | Should -Be ([uint32]2147483649)
    }

    It 'entrega a .NET el DWORD alto como Int32' {
        ConvertTo-JuicerNativeRegValue 'DWord' 4294967295 | Should -Be -1
        (ConvertTo-JuicerNativeRegValue 'DWord' 4294967295).GetType().Name | Should -Be 'Int32'
        ConvertTo-JuicerNativeRegValue 'DWord' 2147483649 | Should -Be -2147483647
    }

    It 'rechaza DWORD fuera de rango' {
        { ConvertTo-JuicerRegValue 'DWord' 4294967296 } | Should -Throw
    }

    It 'conserva el tipo de cadenas múltiples y binarios' {
        $m = ConvertTo-JuicerRegValue 'MultiString' @('a')
        , $m | Should -BeOfType [string[]]
        $m.Count | Should -Be 1
        $b = ConvertTo-JuicerRegValue 'Binary' 'AQID'
        , $b | Should -BeOfType [byte[]]
        $b.Count | Should -Be 3
        (ConvertTo-JuicerRegValue 'Binary' @(1, 2, 3))[2] | Should -Be 3
    }

    It 'compara por tipo y por valor' {
        Test-JuicerRegValueEqual @{ Kind = 'DWord'; Value = -1 } @{ Kind = 'DWord'; Value = 4294967295 } | Should -BeTrue
        Test-JuicerRegValueEqual @{ Kind = 'String'; Value = '0' } @{ Kind = 'DWord'; Value = 0 } | Should -BeFalse
        Test-JuicerRegValueEqual @{ Kind = 'MultiString'; Value = @('a', 'b') } @{ Kind = 'MultiString'; Value = @('a', 'b') } | Should -BeTrue
        Test-JuicerRegValueEqual @{ Kind = 'MultiString'; Value = @('a') } @{ Kind = 'MultiString'; Value = @('a', 'b') } | Should -BeFalse
        Test-JuicerRegValueEqual $null $null | Should -BeTrue
        Test-JuicerRegValueEqual $null @{ Kind = 'DWord'; Value = 0 } | Should -BeFalse
    }
}

Describe 'Diario en JSON' {
    It 'escribe los arrays que salen de una función como arrays, también en 5.1' {
        $m = New-FakeMachine
        $h = @{
            Created = (Get-JuicerMissingKeys 'HKCU\Software\No\Existe')
            Empty   = (Get-JuicerMissingKeys 'HKCU')
            Multi   = (ConvertTo-JuicerRegValue 'MultiString' @('a'))
            Text    = "comillas `" barra \ salto`n ñ"
            Big     = [uint32]::MaxValue
            Flag    = $true
            Nothing = $null
            Nested  = @(@{ X = 1 })
        }
        $back = ConvertTo-JuicerHashtable (ConvertTo-JuicerJson $h | ConvertFrom-Json)
        , $back.Created | Should -BeOfType [object[]]
        $back.Created | Should -Be @('HKCU\Software', 'HKCU\Software\No', 'HKCU\Software\No\Existe')
        @($back.Empty).Count | Should -Be 0
        $back.Multi | Should -Be @('a')
        $back.Text | Should -Be $h.Text
        $back.Big | Should -Be 4294967295
        $back.Flag | Should -BeTrue
        $back.Nothing | Should -BeNullOrEmpty
        $back.Nested[0].X | Should -Be 1
    }
}

Describe 'Cadenas de tokens de DirectX' {
    It 'respeta el orden y los demás tokens' {
        $t = ConvertFrom-JuicerTokenString 'VRROptimizeEnable=0;AutoHDREnable=1;'
        Set-JuicerTokenValue $t 'SwapEffectUpgradeEnable' 1
        ConvertTo-JuicerTokenString $t | Should -Be 'VRROptimizeEnable=0;AutoHDREnable=1;SwapEffectUpgradeEnable=1;'
        Set-JuicerTokenValue $t 'vrroptimizeenable' $null
        ConvertTo-JuicerTokenString $t | Should -Be 'AutoHDREnable=1;SwapEffectUpgradeEnable=1;'
    }

    It 'tolera cadenas vacías o sin punto y coma final' {
        (ConvertFrom-JuicerTokenString '').Count | Should -Be 0
        Get-JuicerTokenValue (ConvertFrom-JuicerTokenString 'GpuPreference=2') 'GpuPreference' | Should -Be '2'
    }
}

Describe 'Aplicar y deshacer' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'deja el registro exactamente como estaba, claves creadas incluidas' {
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 5
        Write-JuicerReg 'HKCU\Software\A' 'z' 'MultiString' @('uno', 'dos')
        $before = Get-MachineSnapshot $m
        $t = @{ Id = 'p1'; Title = 'P1'; Category = 'Prueba'; Reboot = 'No'; Actions = @(
                @{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'x'; Value = 0xFFFFFFFFL }
                @{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'z'; Delete = $true }
                @{ Type = 'Registry'; Path = 'HKCU\Software\Nueva\Honda'; Name = 'y'; Kind = 'String'; Value = 'hola' }
                @{ Type = 'Registry'; Path = 'HKCU\Software\Nueva\Honda'; Name = ''; Kind = 'String'; Value = '' }
                @{ Type = 'Registry'; Path = 'HKCU\Software\Bin'; Name = 'b'; Kind = 'Binary'; Value = [byte[]](3, 0, 0, 0, 255) }
            )
        }
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        (Read-JuicerReg 'HKCU\Software\A' 'x').Value | Should -Be ([uint32]::MaxValue)
        Read-JuicerReg 'HKCU\Software\A' 'z' | Should -BeNullOrEmpty
        (Read-JuicerReg 'HKCU\Software\Nueva\Honda' '').Value | Should -Be ''

        (Undo-JuicerTweak 'p1').Outcome | Should -Be 'Deshecho'
        Get-MachineSnapshot $m | Should -Be $before
        Test-JuicerRegKey 'HKCU\Software\Nueva' | Should -BeFalse
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'no borra una clave creada si otro programa escribió en ella después' {
        $t = @{ Id = 'p2'; Title = 'P2'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\Mia'; Name = 'v'; Value = 1 }) }
        [void](Invoke-JuicerTweak $t)
        Write-JuicerReg 'HKCU\Software\Mia' 'ajeno' 'DWord' 7
        [void](Undo-JuicerTweak 'p2')
        Read-JuicerReg 'HKCU\Software\Mia' 'v' | Should -BeNullOrEmpty
        (Read-JuicerReg 'HKCU\Software\Mia' 'ajeno').Value | Should -Be 7
    }

    It 'dice «ya estaba» y no anota nada si no hay nada que cambiar' {
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 1
        $t = @{ Id = 'p3'; Title = 'P3'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'x'; Value = 1 }) }
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'YaEstaba'
        (Read-JuicerJournal).Count | Should -Be 0
        (Undo-JuicerTweak 'p3').Outcome | Should -Be 'NadaQueDeshacer'
    }

    It 'al reaplicar conserva el estado original, no el intermedio' {
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 5
        $t = @{ Id = 'p4'; Title = 'P4'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'x'; Value = 0 }) }
        [void](Invoke-JuicerTweak $t)
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 9
        (Get-JuicerTweakState $t).State | Should -Be 'Pendiente'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        [void](Undo-JuicerTweak 'p4')
        (Read-JuicerReg 'HKCU\Software\A' 'x').Value | Should -Be 5
    }

    It 'si una acción falla, revierte las anteriores y no deja rastro en el diario' {
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 5
        $m.Backend.State.Services['Svc'] = @{ Start = 'Automatic'; Running = $true }
        $before = Get-MachineSnapshot $m
        $t = @{ Id = 'p5'; Title = 'P5'; Category = 'Prueba'; Reboot = 'No'; Actions = @(
                @{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'x'; Value = 0 }
                @{ Type = 'Service'; Name = 'Svc'; Start = 'Disabled' }
                @{ Type = 'Custom'; Key = 'roto'; Label = 'Falla'; Test = { $false }; Capture = { @{} }; Apply = { throw 'se rompió' }; Restore = { } }
            )
        }
        $r = Invoke-JuicerTweak $t
        $r.Outcome | Should -Be 'Error'
        $r.Message | Should -Match 'se rompió'
        Get-MachineSnapshot $m | Should -Be $before
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'avisa si Windows no conserva el cambio' {
        $real = $m.Backend.RegWrite
        $m.Backend.RegWrite = { param($Path, $Name, $Kind, $Value) if ($Path -notlike '*Terco*') { & $real $Path $Name $Kind $Value } }.GetNewClosure()
        $t = @{ Id = 'p6'; Title = 'P6'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\Terco'; Name = 'x'; Value = 1 }) }
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'NoSeMantuvo'
    }

    It 'simular no cambia nada y describe lo que haría' {
        $before = Get-MachineSnapshot $m
        $t = @{ Id = 'p7'; Title = 'P7'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\S'; Name = 'x'; Value = 300 }) }
        $r = Invoke-JuicerTweak $t -Simulate
        $r.Outcome | Should -Be 'Simulado'
        $r.Changes | Should -Be @('HKCU\Software\S\x = 300 (0x12C)')
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'en un token sólo deshace el suyo, aunque otros hayan cambiado después' {
        $p = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
        Write-JuicerReg $p 'DirectXUserGlobalSettings' 'String' 'VRROptimizeEnable=0;'
        $t = @{ Id = 'p8'; Title = 'P8'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'RegistryToken'; Path = $p; Name = 'DirectXUserGlobalSettings'; Token = 'SwapEffectUpgradeEnable'; Value = '1' }) }
        [void](Invoke-JuicerTweak $t)
        (Read-JuicerReg $p 'DirectXUserGlobalSettings').Value | Should -Be 'VRROptimizeEnable=0;SwapEffectUpgradeEnable=1;'
        Write-JuicerReg $p 'DirectXUserGlobalSettings' 'String' 'VRROptimizeEnable=0;SwapEffectUpgradeEnable=1;AutoHDREnable=1;'
        [void](Undo-JuicerTweak 'p8')
        (Read-JuicerReg $p 'DirectXUserGlobalSettings').Value | Should -Be 'VRROptimizeEnable=0;AutoHDREnable=1;'
    }

    It 'un token en un valor que no existía se borra entero al deshacer' {
        $p = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
        $before = Get-MachineSnapshot $m
        $t = @{ Id = 'p9'; Title = 'P9'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'RegistryToken'; Path = $p; Name = 'C:\Juegos\x.exe'; Token = 'GpuPreference'; Value = '2' }) }
        [void](Invoke-JuicerTweak $t)
        (Read-JuicerReg $p 'C:\Juegos\x.exe').Value | Should -Be 'GpuPreference=2;'
        [void](Undo-JuicerTweak 'p9')
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'servicios: tipo de inicio y estado, ida y vuelta' {
        $m.Backend.State.Services['DiagTrack'] = @{ Start = 'AutomaticDelayed'; Running = $true }
        $t = @{ Id = 'p10'; Title = 'P10'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Service'; Name = 'DiagTrack'; Start = 'Disabled' }) }
        [void](Invoke-JuicerTweak $t)
        $m.Backend.State.Services['DiagTrack'].Start | Should -Be 'Disabled'
        $m.Backend.State.Services['DiagTrack'].Running | Should -BeFalse
        [void](Undo-JuicerTweak 'p10')
        $m.Backend.State.Services['DiagTrack'].Start | Should -Be 'AutomaticDelayed'
        $m.Backend.State.Services['DiagTrack'].Running | Should -BeTrue
    }

    It 'un servicio que no existe no es un error' {
        $t = @{ Id = 'p11'; Title = 'P11'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Service'; Name = 'NoExiste'; Start = 'Disabled' }) }
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'YaEstaba'
    }

    It 'Defender: no quita al deshacer una exclusión que ya existía' {
        [void]$m.Backend.State.Defender.Add('D:\Juegos')
        $a = @{ Id = 'p12'; Title = 'P12'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'DefenderExclusion'; Path = 'd:\juegos\' }) }
        (Invoke-JuicerTweak $a).Outcome | Should -Be 'YaEstaba'
        $b = @{ Id = 'p13'; Title = 'P13'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'DefenderExclusion'; Path = 'E:\Steam\steamapps' }) }
        (Invoke-JuicerTweak $b).Outcome | Should -Be 'Aplicado'
        [void](Undo-JuicerTweak 'p13')
        @($m.Backend.State.Defender) | Should -Be @('D:\Juegos')
    }

    It 'tareas programadas' {
        $m.Backend.State.Tasks['\|Updater'] = @{ Enabled = $true }
        $t = @{ Id = 'p14'; Title = 'P14'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Task'; Path = '\'; Name = 'Updater'; Enabled = $false }) }
        [void](Invoke-JuicerTweak $t)
        $m.Backend.State.Tasks['\|Updater'].Enabled | Should -BeFalse
        [void](Undo-JuicerTweak 'p14')
        $m.Backend.State.Tasks['\|Updater'].Enabled | Should -BeTrue
    }

    It 'SystemParametersInfo' {
        $m.Backend.State.Spi[[uint32]0x1042] = $true
        $t = @{ Id = 'p15'; Title = 'P15'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Spi'; Get = 0x1042; Set = 0x1043; Value = $false }) }
        [void](Invoke-JuicerTweak $t)
        $m.Backend.State.Spi[[uint32]0x1042] | Should -BeFalse
        [void](Undo-JuicerTweak 'p15')
        $m.Backend.State.Spi[[uint32]0x1042] | Should -BeTrue
    }

    It 'deshacer todo va en orden inverso' {
        Write-JuicerReg 'HKCU\Software\A' 'x' 'DWord' 1
        $before = Get-MachineSnapshot $m
        $t1 = @{ Id = 'q1'; Title = 'Q1'; Category = 'Prueba'; Reboot = 'No'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\A'; Name = 'x'; Value = 2 }) }
        $t2 = @{ Id = 'q2'; Title = 'Q2'; Category = 'Prueba'; Reboot = 'Reinicio'; Actions = @(@{ Type = 'Registry'; Path = 'HKCU\Software\B'; Name = 'y'; Value = 3 }) }
        [void](Invoke-JuicerTweak $t1)
        [void](Invoke-JuicerTweak $t2)
        $r = @(Undo-JuicerAll)
        @($r | ForEach-Object { $_.Id }) | Should -Be @('q2', 'q1')
        $r[0].Reboot | Should -Be 'Reinicio'
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'un diario dañado se denuncia, no se pisa' {
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        { Read-JuicerJournal } | Should -Throw '*dañado*'
        Remove-Item -LiteralPath (Get-JuicerJournalPath)
    }
}

Describe 'Ajustes con powercfg y bcdedit' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'crea su plan una vez, lo activa y lo borra al deshacer' {
        $before = Get-MachineSnapshot $m
        $t = Find-JuicerTweak 'energia.plan'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Fake.Active | Should -Be '5f1c7a4e-3b2d-4e8a-9c61-7d0b2a9e4f13'
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setacvalueindex*' }).Count | Should -Be 5
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'energia.plan').Outcome | Should -Be 'Deshecho'
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'sin «Máximo rendimiento» parte de «Alto rendimiento»' {
        $m.Fake.Plans.Remove('8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c')
        [void]$m.Fake.Plans.Add('e9a42b02-d5df-448d-aa00-03f14749eb61')
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.plan')).Outcome | Should -Be 'Aplicado'
    }

    It 'inicio rápido: hibernación reducida y vuelta al estado original' {
        $before = Get-MachineSnapshot $m
        $t = Find-JuicerTweak 'energia.inicio'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Fake.Hibernate | Should -BeTrue
        $m.Fake.HibernateType | Should -Be 'reduced'
        (Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled').Value | Should -Be 1
        [void](Undo-JuicerTweak 'energia.inicio')
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'quita useplatformclock y lo devuelve al deshacer' {
        $m.Fake.Bcd['useplatformclock'] = 'Sí'
        $t = Find-JuicerTweak 'reparar.reloj'
        (Get-JuicerTweakState $t).State | Should -Be 'Pendiente'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Fake.Bcd.ContainsKey('useplatformclock') | Should -BeFalse
        [void](Undo-JuicerTweak 'reparar.reloj')
        $m.Fake.Bcd['useplatformclock'] | Should -Be 'yes'
    }

    It 'hipervisor: off, y al deshacer vuelve a no estar configurado' {
        $before = Get-MachineSnapshot $m
        $t = Find-JuicerTweak 'seguridad.hipervisor'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Fake.Bcd['hypervisorlaunchtype'] | Should -Be 'off'
        [void](Undo-JuicerTweak 'seguridad.hipervisor')
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'hipervisor: respeta un «Auto» explícito' {
        $m.Fake.Bcd['hypervisorlaunchtype'] = 'Auto'
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'seguridad.hipervisor'))
        [void](Undo-JuicerTweak 'seguridad.hipervisor')
        $m.Fake.Bcd['hypervisorlaunchtype'] | Should -Be 'auto'
    }
}

Describe 'Programas de inicio' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' 'Discord' 'String' '"C:\Discord\Update.exe" --processStart Discord.exe'
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run' 'Ya apagado' 'String' 'C:\x.exe'
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' 'Ya apagado' 'Binary' ([byte[]](3, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8))
    }

    It 'lee el estado igual que el Administrador de tareas' {
        $items = @(Get-JuicerStartupItems)
        $items.Count | Should -Be 2
        ($items | Where-Object { $_.Name -eq 'Discord' }).Enabled | Should -BeTrue
        ($items | Where-Object { $_.Name -eq 'Ya apagado' }).Enabled | Should -BeFalse
    }

    It 'desactivar y volver a activar no deja nada en el diario' {
        $before = Get-MachineSnapshot $m
        $d = @(Get-JuicerStartupItems) | Where-Object { $_.Name -eq 'Discord' }
        (Set-JuicerStartupItem $d $false).Outcome | Should -Be 'Aplicado'
        $d = @(Get-JuicerStartupItems) | Where-Object { $_.Name -eq 'Discord' }
        $d.Enabled | Should -BeFalse
        (Set-JuicerStartupItem $d $true).Outcome | Should -Be 'Deshecho'
        (Read-JuicerJournal).Count | Should -Be 0
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'activar algo que ya estaba apagado se puede deshacer' {
        $before = Get-MachineSnapshot $m
        $x = @(Get-JuicerStartupItems) | Where-Object { $_.Name -eq 'Ya apagado' }
        (Set-JuicerStartupItem $x $true).Outcome | Should -Be 'Aplicado'
        (@(Get-JuicerStartupItems) | Where-Object { $_.Name -eq 'Ya apagado' }).Enabled | Should -BeTrue
        [void](Undo-JuicerTweak "inicio-on:$($x.Id)")
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'el formato binario es el del Administrador de tareas' {
        $off = New-JuicerApprovedBytes $false
        $off.Count | Should -Be 12
        $off[0] | Should -Be 3
        [BitConverter]::ToInt64($off, 4) | Should -BeGreaterThan 0
        (New-JuicerApprovedBytes $true)[0] | Should -Be 2
        Test-JuicerApprovedEnabled @{ Kind = 'Binary'; Value = [byte[]](7, 0) } | Should -BeFalse
        Test-JuicerApprovedEnabled @{ Kind = 'Binary'; Value = [byte[]](6, 0) } | Should -BeTrue
        Test-JuicerApprovedEnabled $null | Should -BeTrue
    }
}

Describe 'Juegos' {
    It 'lee las bibliotecas de libraryfolders.vdf' {
        $vdf = @'
"libraryfolders"
{
    "0"
    {
        "path"      "C:\\Program Files (x86)\\Steam"
        "label"     ""
    }
    "1"
    {
        "path"      "D:\\SteamLibrary"
        "apps"      { "570" "123" }
    }
}
'@
        ConvertFrom-JuicerSteamLibraries $vdf | Should -Be @('C:\Program Files (x86)\Steam', 'D:\SteamLibrary')
    }

    It 'los ajustes por juego son reversibles' {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $before = Get-MachineSnapshot $m
        $exe = 'D:\SteamLibrary\steamapps\common\Juego\juego.exe'
        foreach ($t in (New-JuicerGpuTweak $exe), (New-JuicerPriorityTweak $exe), (New-JuicerDefenderTweak 'D:\SteamLibrary\steamapps' 'Steam')) {
            (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        }
        @(Get-JuicerConfiguredGames).Count | Should -Be 3
        (Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\juego.exe\PerfOptions' 'CpuPriorityClass').Value | Should -Be 3
        [void](Undo-JuicerAll)
        Get-MachineSnapshot $m | Should -Be $before
    }
}

Describe 'Diagnóstico (partes puras)' {
    It 'saca el canal de cualquier nombre de ranura' {
        Get-JuicerMemoryChannel 'ChannelA-DIMM0 BANK 0' | Should -Be 'A'
        Get-JuicerMemoryChannel 'DIMM_B2' | Should -Be 'B'
        Get-JuicerMemoryChannel 'P0 CHANNEL A' | Should -Be 'A'
        Get-JuicerMemoryChannel 'Controller1-ChannelB-DIMM1' | Should -Be 'B'
        Get-JuicerMemoryChannel 'BANK 0' | Should -BeNullOrEmpty
    }

    It 'detecta canal simple, mismo canal y XMP apagado' {
        $one = @([pscustomobject]@{ Capacity = 16GB; Speed = 3200; ConfiguredClockSpeed = 2133; SMBIOSMemoryType = 26; DeviceLocator = 'DIMM_A2'; BankLabel = '' })
        $f = Get-JuicerRamFindings $one $false
        @($f | Where-Object { $_.Severity -eq 'Alto' -and $_.Title -like '*canal simple*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*velocidad estándar*' }).Count | Should -Be 1

        $same = @(
            [pscustomobject]@{ Capacity = 8GB; Speed = 6000; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_A1'; BankLabel = '' }
            [pscustomobject]@{ Capacity = 8GB; Speed = 6000; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_A2'; BankLabel = '' }
        )
        $f = Get-JuicerRamFindings $same $false
        @($f | Where-Object { $_.Title -like '*mismo canal (A)*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*velocidad estándar*' }).Count | Should -Be 0

        $good = @(
            [pscustomobject]@{ Capacity = 16GB; Speed = 4800; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_A2'; BankLabel = '' }
            [pscustomobject]@{ Capacity = 16GB; Speed = 4800; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_B2'; BankLabel = '' }
        )
        @(Get-JuicerRamFindings $good $false | Where-Object { $_.Severity -ne 'Info' }).Count | Should -Be 0
    }

    It 'no pide XMP en portátiles' {
        $lap = @(
            [pscustomobject]@{ Capacity = 8GB; Speed = 3200; ConfiguredClockSpeed = 2666; SMBIOSMemoryType = 26; DeviceLocator = 'ChannelA-DIMM0'; BankLabel = '' }
            [pscustomobject]@{ Capacity = 8GB; Speed = 3200; ConfiguredClockSpeed = 2666; SMBIOSMemoryType = 26; DeviceLocator = 'ChannelB-DIMM0'; BankLabel = '' }
        )
        @(Get-JuicerRamFindings $lap $true | Where-Object { $_.Title -like '*velocidad estándar*' }).Count | Should -Be 0
    }

    It 'compara la frecuencia de cada pantalla con su máximo' {
        $f = @(Get-JuicerDisplayFindings @(
                [pscustomobject]@{ Monitor = 'LG'; Width = 2560; Height = 1440; Hz = 60; MaxHz = 165 }
                [pscustomobject]@{ Monitor = ''; Width = 1920; Height = 1080; Hz = 59; MaxHz = 60 }
            ))
        $f[0].Severity | Should -Be 'Alto'
        $f[0].Title | Should -BeLike '*60 Hz*165 Hz*'
        $f[1].Severity | Should -Be 'Ok'
    }

    It 'entiende la salida de nvidia-smi' {
        $on = "FB Memory Usage`n    Total : 12282 MiB`n    Used : 1 MiB`nBAR1 Memory Usage`n    Total : 16384 MiB"
        $off = "FB Memory Usage`n    Total : 8192 MiB`nBAR1 Memory Usage`n    Total : 256 MiB"
        (ConvertFrom-JuicerNvidiaSmi $on).Rebar | Should -BeTrue
        (ConvertFrom-JuicerNvidiaSmi $off).Rebar | Should -BeFalse
        ConvertFrom-JuicerNvidiaSmi 'nada' | Should -BeNullOrEmpty
    }
}

Describe 'Consola' {
    It 'interpreta listas y rangos de números' {
        Get-JuicerNumbers '1, 3 5-7 99' 10 | Should -Be @(1, 3, 5, 6, 7)
        @(Get-JuicerNumbers 'abc' 10).Count | Should -Be 0
    }

    It 'la línea de órdenes devuelve sólo el código de salida' {
        $m = New-FakeMachine
        $out = @(Start-Juicer -Lista 6>$null)
        $out.Count | Should -Be 1
        $out[0] | Should -Be 0
        $out = @(Start-Juicer -Perfil Rendimiento -Simular -Si 6>$null)
        $out.Count | Should -Be 1
        $out[0] | Should -Be 0
        @(Start-Juicer -Aplicar 'no.existe' -Si 6>$null)[-1] | Should -Be 2
    }

    It 'sin -AceptoRiesgos, el nivel Extremo no se aplica en modo no interactivo' {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $code = @(Start-Juicer -Aplicar 'seguridad.hipervisor' -Si -SinPuntoDeRestauracion 6>$null)[-1]
        $code | Should -Be 0
        $m.Fake.Bcd.ContainsKey('hypervisorlaunchtype') | Should -BeFalse
    }
}
