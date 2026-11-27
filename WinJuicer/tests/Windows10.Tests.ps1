# Windows 10 22H2 (build 19045) on a laptop: what has to be right there. The build is faked
# through the registry key Get-JuicerWindowsBuild reads, and the power source through the
# in-memory backend, so none of this needs a real machine.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Balanced = '381b4222-f694-41f0-9685-ff5bb260df2e'
    $script:HighPerf = '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c'
    $script:BestMode = 'ded574b5-45a0-4f42-8737-46345c09c238'
    $script:NoMode = '00000000-0000-0000-0000-000000000000'

    function Set-FakeBuild { param([int]$Build) Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' ([string]$Build) }

    function New-W10Hw {
        param([bool]$Laptop = $true, [int]$Build = 19045, [hashtable]$Extra = @{})
        $hw = @{
            Cpu = (Get-JuicerCpuTraits); Gpus = @(Get-JuicerGpuTraits 'Intel(R) UHD Graphics 620'); RamBytes = [int64]8GB; Modules = @()
            Laptop = $Laptop; OnBattery = $false; ModernStandby = $false; SystemDisk = @{ Media = 'SSD'; Bus = 'NVMe'; Name = 'Disco' }
            Printers = @(); Adapters = @(); OneDrive = @{ Installed = $false; SignedIn = $false; Kfm = $false; Folders = @() }
            Edge = $true; Home = $false; Insider = $false; Build = $Build; Wsl = $false; Docker = $false; GamePass = $false; GameBar = $true
        }
        foreach ($k in $Extra.Keys) { $hw[$k] = $Extra[$k] }
        $hw
    }
}

Describe 'Windows 10: ajustes que sólo existen en Windows 11' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Set-FakeBuild 19045
    }

    It 'el menú contextual clásico no aplica: Windows 10 ya lo tiene' {
        $s = Get-JuicerTweakState (Find-JuicerTweak 'ui.menu')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -Be 'Solo en Windows 11: Windows 10 ya tiene el menú clásico.'
        (Invoke-JuicerTweak (Find-JuicerTweak 'ui.menu')).Outcome | Should -Be 'NoAplica'
        Read-JuicerReg 'HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32' '' | Should -BeNullOrEmpty
        Set-FakeBuild 22631
        (Get-JuicerTweakState (Find-JuicerTweak 'ui.menu')).State | Should -Be 'Pendiente'
    }

    It 'HAGS necesita Windows 10 2004: en 19045 aplica, antes no' {
        (Get-JuicerTweakState (Find-JuicerTweak 'juegos.hags')).State | Should -Be 'Pendiente'
        Set-FakeBuild 18363
        $s = Get-JuicerTweakState (Find-JuicerTweak 'juegos.hags')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -BeLike '*2004*'
    }

    It 'lo propio de Windows 11 sigue marcado como no aplica en Windows 10' {
        foreach ($id in 'pref.barra', 'pref.finalizar', 'pref.galeria', 'privacidad.copilot', 'fondo.recall', 'juegos.ventana') {
            (Get-JuicerTweakState (Find-JuicerTweak $id)).State | Should -Be 'NoAplica' -Because $id
        }
    }
}

Describe 'Windows 10: textos que dependen de la versión' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Set-FakeBuild 19045
    }

    It '«Noticias e intereses» en Windows 10 y Widgets en Windows 11' {
        $t = Find-JuicerTweak 'ui.widgets'
        $t.Title | Should -BeLike '*Noticias e intereses*'
        $t.What | Should -BeLike '*Noticias e intereses*'
        $t.Gain | Should -BeLike '*batería*'
        $t.Cost | Should -BeLike '*barra de tareas*'
        # Not the same policy: Windows 10 reads Feeds.admx, «Allow widgets» (Dsh) is Windows 11's.
        $planned = Resolve-JuicerActions $t
        $planned.Count | Should -Be 1
        $planned[0].Path | Should -Be 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds'
        $planned[0].Name | Should -Be 'EnableFeeds'
        $planned[0].Value | Should -Be 0
        Set-FakeBuild 26100
        $t = Find-JuicerTweak 'ui.widgets'
        $t.Title | Should -Be 'Desactivar Widgets'
        $t.Gain | Should -BeLike '*100 y 300 MB*'
        $planned = Resolve-JuicerActions $t
        $planned.Count | Should -Be 1
        $planned[0].Path | Should -Be 'HKLM\SOFTWARE\Policies\Microsoft\Dsh'
        $planned[0].Name | Should -Be 'AllowNewsAndInterests'
    }

    It '«Noticias e intereses»: en Windows 10 se aplica la directiva que Windows 10 lee, y se deshace' {
        $t = Find-JuicerTweak 'ui.widgets'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds').Value | Should -Be 0
        Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Dsh' 'AllowNewsAndInterests' | Should -BeNullOrEmpty
        (Undo-JuicerTweak 'ui.widgets').Outcome | Should -Be 'Deshecho'
        Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Feeds' 'EnableFeeds' | Should -BeNullOrEmpty
    }

    It 'la Línea de tiempo de Windows 10 se pierde, y se dice' {
        (Find-JuicerTweak 'privacidad.actividad').Cost | Should -BeLike '*pierdes la Línea de tiempo*Win+Tab*'
        Set-FakeBuild 26100
        (Find-JuicerTweak 'privacidad.actividad').Cost | Should -BeLike 'Ninguno*'
    }

    It 'el consejero recomienda «Noticias e intereses» en Windows 10, también con RAM de sobra' {
        $a = Get-JuicerAdvice (New-W10Hw -Extra @{ RamBytes = [int64]32GB })
        $a['ui.widgets'].Verdict | Should -Be 'Recomendado'
        $a['ui.widgets'].Reason | Should -BeLike '*Noticias e intereses*'
        (Get-JuicerAdvice (New-W10Hw -Build 26100 -Extra @{ RamBytes = [int64]32GB }))['ui.widgets'].Verdict | Should -Be 'Opcional'
    }
}

Describe 'Windows 10: búsqueda de Inicio sin resultados web' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Set-FakeBuild 19045
        $searchKey = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Search'
    }

    It 'en Windows 10 quita BingSearchEnabled y CortanaConsent además de la directiva, y se deshace' {
        $before = Get-MachineSnapshot $m
        $t = Find-JuicerTweak 'ui.busqueda'
        $planned = Resolve-JuicerActions $t
        $planned.Count | Should -Be 4
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $bing = Read-JuicerReg $searchKey 'BingSearchEnabled'
        $bing.Kind | Should -Be 'DWord'
        $bing.Value | Should -Be 0
        (Read-JuicerReg $searchKey 'CortanaConsent').Value | Should -Be 0
        (Read-JuicerReg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions').Value | Should -Be 1
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Windows Search' 'EnableDynamicContentInWSB').Value | Should -Be 0
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'ui.busqueda').Outcome | Should -Be 'Deshecho'
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'en Windows 11 sólo las directivas: sin sugerencias web y sin destacados' {
        Set-FakeBuild 26100
        $acts = Resolve-JuicerActions (Find-JuicerTweak 'ui.busqueda')
        $acts.Count | Should -Be 2
        $acts[0].Name | Should -Be 'DisableSearchBoxSuggestions'
        $acts[1].Name | Should -Be 'EnableDynamicContentInWSB'
    }

    It 'con sólo la directiva (lo que había antes) queda a medias en Windows 10' {
        Write-JuicerReg 'HKCU\Software\Policies\Microsoft\Windows\Explorer' 'DisableSearchBoxSuggestions' 'DWord' 1
        (Get-JuicerTweakState (Find-JuicerTweak 'ui.busqueda')).State | Should -Be 'Parcial'
    }
}

Describe 'Modo de energía en cualquier equipo con el plan Equilibrado' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Set-FakeBuild 19045
    }

    It 'sin Modern Standby, con el plan Equilibrado: aplica el modo de la fuente actual y lo devuelve' {
        $m.Fake.Active = $script:Balanced
        $t = Find-JuicerTweak 'energia.modo'
        (Get-JuicerTweakState $t).State | Should -Be 'Pendiente'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Backend.State.PowerMode | Should -Be $script:BestMode
        (Get-JuicerTweakState $t).State | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'energia.modo').Outcome | Should -Be 'Deshecho'
        $m.Backend.State.PowerMode | Should -Be $script:NoMode
    }

    It 'con otro plan activo no aplica, y dice por qué' {
        $m.Fake.Active = $script:HighPerf
        $s = Get-JuicerTweakState (Find-JuicerTweak 'energia.modo')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -BeLike '*solo actúa con el plan Equilibrado*'
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.modo')).Outcome | Should -Be 'NoAplica'
        $m.Backend.State.PowerMode | Should -Be $script:NoMode
    }

    It 'dice que es por fuente de energía y que se aplique enchufado' {
        $t = Find-JuicerTweak 'energia.modo'
        $t.What | Should -BeLike '*fuente*'
        $t.What | Should -BeLike '*cargador conectado*'
    }

    It 'el consejero: en un portátil con Windows 10 es el ajuste de energía recomendado, no el plan' {
        $a = Get-JuicerAdvice (New-W10Hw)
        $a['energia.modo'].Verdict | Should -Be 'Recomendado'
        $a['energia.modo'].Reason | Should -BeLike '*enchufado*'
        $a['energia.plan'].Verdict | Should -Be 'NoRecomendado'
        $a['energia.plan'].Reason | Should -BeLike '*energia.modo*'
        @(Get-JuicerRecommendedTweaks (New-W10Hw) | Where-Object { $_.Id -eq 'energia.modo' }).Count | Should -Be 1
        @(Get-JuicerRecommendedTweaks (New-W10Hw) | Where-Object { $_.Id -eq 'energia.plan' }).Count | Should -Be 0
    }

    It 'el consejero: Windows 11 sin Modern Standby, opcional; sobremesa, no; Modern Standby, recomendado' {
        (Get-JuicerAdvice (New-W10Hw -Build 26100))['energia.modo'].Verdict | Should -Be 'Opcional'
        (Get-JuicerAdvice (New-W10Hw -Laptop $false))['energia.modo'].Verdict | Should -Be 'NoRecomendado'
        (Get-JuicerAdvice (New-W10Hw -Extra @{ ModernStandby = $true }))['energia.modo'].Verdict | Should -Be 'Recomendado'
    }

    It 'el modo en batería no cuenta como deshecho por Windows, el del cargador sí' {
        $t = Find-JuicerTweak 'energia.modo'
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 1 -BatteryFlag 8 -Percent 90
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        @(Get-JuicerDrift).Count | Should -Be 0
        # Windows keeps one mode per power source: the battery one reads as undone.
        $m.Backend.State.PowerMode = $script:NoMode
        @(Get-JuicerDrift).Count | Should -Be 1
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 8 -Percent 80
        @(Get-JuicerDrift).Count | Should -Be 0
    }
}

Describe 'Plan de energía «Win Juicer» en un portátil' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $planId = '5f1c7a4e-3b2d-4e8a-9c61-7d0b2a9e4f13'
    }

    It 'en un portátil escribe también los valores de batería, y deshacer borra el plan' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        $before = Get-MachineSnapshot $m
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.plan')).Outcome | Should -Be 'Aplicado'
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setacvalueindex*' }).Count | Should -Be 5
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setdcvalueindex*' }).Count | Should -Be 5
        # Plugged in: the maximum. On battery: moderate values.
        $m.Fake.Ac["$($planId)|893dee8e-2bef-41e0-89c6-b55d0929964c"] | Should -Be '100'
        $m.Fake.Dc["$($planId)|893dee8e-2bef-41e0-89c6-b55d0929964c"] | Should -Be '5'
        $m.Fake.Dc["$($planId)|0cc5b647-c1df-4637-891a-dec35c318583"] | Should -Be '10'
        $m.Fake.Dc["$($planId)|ee12f906-d277-404b-b6da-e5fa1a576df5"] | Should -Be '1'
        $m.Fake.Dc["$($planId)|48e6b7a6-50f5-4782-a5d4-53bb8f07e226"] | Should -Be '1'
        $m.Fake.Dc["$($planId)|6738e2c4-e8a5-4a42-b16a-e040e769756e"] | Should -Be '600'
        (Undo-JuicerTweak 'energia.plan').Outcome | Should -Be 'Deshecho'
        $m.Fake.Dc.Count | Should -Be 0
        $m.Fake.Ac.Count | Should -Be 0
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'en un sobremesa sólo escribe los de corriente' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.plan')).Outcome | Should -Be 'Aplicado'
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setacvalueindex*' }).Count | Should -Be 5
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setdcvalueindex*' }).Count | Should -Be 0
        $m.Fake.Dc.Count | Should -Be 0
    }
}

Describe 'Una sola lectura de la fuente de energía' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'traduce GetSystemPowerStatus' {
        $b = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 2 -Percent 35 -SystemFlag 1 -SecondsLeft 5400
        $b.HasBattery | Should -BeTrue
        $b.OnBattery | Should -BeTrue
        $b.BatterySaver | Should -BeTrue
        $b.Percent | Should -Be 35
        $b.SecondsLeft | Should -Be 5400
        $p = ConvertFrom-JuicerPowerStatus -AcLine 1 -BatteryFlag 9 -Percent 100
        $p.OnBattery | Should -BeFalse
        $p.BatterySaver | Should -BeFalse
        # Bit 128 of BatteryFlag: no battery. A desktop is never «on battery».
        $d = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 128 -Percent 255
        $d.HasBattery | Should -BeFalse
        $d.OnBattery | Should -BeFalse
        $d.Percent | Should -Be -1
        # Unknown charger state says nothing.
        (ConvertFrom-JuicerPowerStatus -AcLine 255 -BatteryFlag 1 -Percent 50).OnBattery | Should -BeFalse
    }

    It 'Test-JuicerOnBattery usa esa lectura' {
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 4 -Percent 20
        Test-JuicerOnBattery | Should -BeTrue
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 1 -BatteryFlag 8 -Percent 21
        Test-JuicerOnBattery | Should -BeFalse
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 128 -Percent 255
        Test-JuicerOnBattery | Should -BeFalse
    }

    It 'si la llamada falla, vuelve a WMI (fuera de Windows: no hay batería)' {
        $m.Backend.State.Power = $null
        Get-JuicerPowerStatus | Should -BeNullOrEmpty
        if (-not (Test-JuicerWindows)) { Test-JuicerOnBattery | Should -BeFalse }
    }

    It 'un backend sin la lectura no rompe nada' {
        $m.Backend.Remove('PowerStatus')
        { Get-JuicerPowerStatus } | Should -Not -Throw
        Get-JuicerPowerStatus | Should -BeNullOrEmpty
    }

    It 'el diagnóstico de hardware ya no repite el aviso de la batería' {
        $src = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Audit.ps1') -Raw
        ([regex]::Matches($src, 'Estás funcionando con batería')).Count | Should -Be 0
        ([regex]::Matches($src, 'BatteryStatus')).Count | Should -Be 0
        ([regex]::Matches($src, '\$in\.OnBattery\s*=')).Count | Should -Be 1
    }
}

Describe 'Ahorro de batería en «Listo para jugar»' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'lee el umbral del plan (lado batería) y si está activo' {
        $m.Fake.Query['ESBATTTHRESHOLD'] = "  Minimum Possible Setting: 0x00000000`n  Maximum Possible Setting: 0x00000064`n  Possible Settings increment: 0x00000001`n  Current AC Power Setting Index: 0x00000000`n  Current DC Power Setting Index: 0x00000014"
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 8 -Percent 50 -SystemFlag 1
        $s = Get-JuicerBatterySaverState
        $s.At | Should -Be 20
        $s.On | Should -BeTrue
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 1 -BatteryFlag 8 -Percent 50
        (Get-JuicerBatterySaverState).On | Should -BeFalse
    }

    It 'sin lectura, todo es desconocido' {
        $m.Backend.State.Power = $null
        $s = Get-JuicerBatterySaverState
        $s.On | Should -BeNullOrEmpty
        $s.At | Should -BeNullOrEmpty
    }

    It 'activo: lo dice con el nombre de la versión' {
        $l = @(Get-JuicerReadyStatus @{ OnBattery = $true; BatterySaver = $true; BatterySaverAt = 20; Build = 19045 } | Where-Object { $_.Key -eq 'ahorro' })
        $l.Count | Should -Be 1
        $l[0].Title | Should -Be 'Ahorro de batería activo: Windows limita apps en segundo plano y brillo'
        $l[0].Ok | Should -BeFalse
        $l[0].Reason | Should -Not -BeNullOrEmpty
        $n = @(Get-JuicerReadyStatus @{ OnBattery = $true; BatterySaver = $true; Build = 26100 } | Where-Object { $_.Key -eq 'ahorro' })
        $n[0].Title | Should -Be 'Ahorro de energía activo: Windows limita apps en segundo plano y brillo'
    }

    It 'apagado: dice a qué carga se activa, sin dar la alarma' {
        $l = @(Get-JuicerReadyStatus @{ OnBattery = $false; BatterySaver = $false; BatterySaverAt = 20; Build = 19045 } | Where-Object { $_.Key -eq 'ahorro' })
        $l.Count | Should -Be 1
        $l[0].Title | Should -Be 'Ahorro de batería: se activa al 20 %'
        $l[0].Ok | Should -BeTrue
        $l[0].Info | Should -BeTrue
        @(Get-JuicerReadyStatus @{ OnBattery = $false; BatterySaver = $false; BatterySaverAt = 30; Build = 26100 } | Where-Object { $_.Key -eq 'ahorro' })[0].Title | Should -Be 'Ahorro de energía: se activa al 30 %'
    }

    It 'umbral 0: no se activa solo' {
        $l = @(Get-JuicerReadyStatus @{ OnBattery = $false; BatterySaver = $false; BatterySaverAt = 0; Build = 19045 } | Where-Object { $_.Key -eq 'ahorro' })
        $l[0].Title | Should -Be 'Ahorro de batería: no se activa solo'
    }

    It 'sólo en portátiles y después de la línea de la batería; sin datos, nada' {
        @(Get-JuicerReadyStatus @{ OnBattery = $null; BatterySaver = $true; BatterySaverAt = 20; Build = 19045 } | Where-Object { $_.Key -eq 'ahorro' }).Count | Should -Be 0
        @(Get-JuicerReadyStatus @{ OnBattery = $false; BatterySaver = $null; BatterySaverAt = $null; Build = 19045 } | Where-Object { $_.Key -eq 'ahorro' }).Count | Should -Be 0
        $keys = @(Get-JuicerReadyStatus @{ PlanKind = 'Equilibrado'; CpuMax = 100; OnBattery = $false; BatterySaver = $false; BatterySaverAt = 20; MonitorHz = 60; MonitorMaxHz = 60 } | ForEach-Object { $_.Key })
        $keys | Should -Be @('energia', 'bateria', 'ahorro', 'monitor')
    }
}

Describe 'Debloat: apps de Windows 10' {
    It 'están en la lista con su clase' {
        $expected = [ordered]@{
            'Microsoft.Getstarted' = 'Seguro'; 'Microsoft.People' = 'Seguro'; 'Microsoft.MixedReality.Portal' = 'Seguro'
            'Microsoft.3DBuilder' = 'Seguro'; 'Microsoft.Microsoft3DViewer' = 'Seguro'; 'Microsoft.Print3D' = 'Seguro'
            'Microsoft.OneConnect' = 'Seguro'; 'Microsoft.SkypeApp' = 'Opcional'; 'Microsoft.MSPaint' = 'Cuidado'
            'microsoft.windowscommunicationsapps' = 'Cuidado'
        }
        foreach ($n in $expected.Keys) {
            $a = Find-JuicerDebloatApp $n
            $a | Should -Not -BeNullOrEmpty -Because $n
            $a.Class | Should -Be $expected[$n] -Because $n
            $a.What | Should -Not -BeNullOrEmpty -Because $n
            $a.StoreId | Should -Match '^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$' -Because $n
        }
        (Find-JuicerDebloatApp 'Microsoft.Getstarted').Title | Should -Be 'Consejos'
        (Find-JuicerDebloatApp 'microsoft.windowscommunicationsapps').Title | Should -Be 'Correo y Calendario'
    }

    It 'Paint 3D no se confunde con el Paint de siempre' {
        $a = Find-JuicerDebloatApp 'Microsoft.MSPaint'
        $a.Title | Should -Be 'Paint 3D'
        $a.What | Should -BeLike '*Paint 3D*'
        $a.What | Should -BeLike '*clásico*se queda*'
    }

    It 'las «Cuidado» se piden una a una (nivel 3) y las «Seguro» se recomiendan' {
        (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Microsoft.MSPaint')).Level | Should -Be 3
        (New-JuicerAppxTweak (Find-JuicerDebloatApp 'microsoft.windowscommunicationsapps')).Level | Should -Be 3
        (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Microsoft.People')).Level | Should -Be 1
        $m = New-FakeMachine
        $m.Backend.State.Appx['Microsoft.People'] = @{ Installed = $true; Provisioned = $false }
        $m.Backend.State.Appx['microsoft.windowscommunicationsapps'] = @{ Installed = $true; Provisioned = $false }
        $state = @(Get-JuicerDebloatState @{ Cpu = @{}; GamePass = $false })
        ($state | Where-Object { $_.Name -eq 'Microsoft.People' }).Recommended | Should -BeTrue
        ($state | Where-Object { $_.Name -eq 'microsoft.windowscommunicationsapps' }).Recommended | Should -BeFalse
    }
}

Describe 'Windows 10: fin de soporte y nombres' {
    It 'un solo aviso, Medio, con qué significa, qué ayuda y cómo ver si cabe Windows 11' {
        $f = @(Get-JuicerSupportFindings (Get-JuicerWindowsSupport 19045 'Core') -Now ([datetime]'2026-11-26'))
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -BeLike 'Windows 10*'
        $f[0].Detail | Should -BeLike 'Terminó el *'
        $f[0].Detail | Should -BeLike '*navegador*'
        $f[0].Detail | Should -BeLike '*cuenta estándar*'
        $f[0].Detail | Should -BeLike '*copias de seguridad*'
        $f[0].Detail | Should -BeLike '*Comprobación de estado del PC*'
        $f[0].Detail | Should -BeLike '*Get-Tpm*'
        $f[0].Detail | Should -BeLike '*Confirm-SecureBootUEFI*'
        $f[0].Detail | Should -BeLike '*13 de octubre de 2026*'
        $e = @(Get-JuicerSupportFindings (Get-JuicerWindowsSupport 19045 'Enterprise') -Now ([datetime]'2026-11-26'))
        $e.Count | Should -Be 1
        $e[0].Detail | Should -BeLike '*ESU*'
    }

    It 'la consola y el script dicen Windows 10 y 11' {
        $root = Split-Path -Parent $PSScriptRoot
        (Get-Content -LiteralPath (Join-Path $root 'src/Console.ps1') -Raw) | Should -BeLike '*exprime Windows 10 y 11, sin humo*'
        (Get-Content -LiteralPath (Join-Path $root 'WinJuicer.ps1') -Raw) | Should -BeLike '*exprime Windows 10 y 11*'
    }

    It 'los mitos incluyen Cortana por directiva y el 100 % mínimo con batería' {
        $titles = @(Get-JuicerMyths | ForEach-Object { $_.Title })
        @($titles | Where-Object { $_ -like '*Cortana por directiva en Windows 10 22H2*' }).Count | Should -Be 1
        @($titles | Where-Object { $_ -like '*100 % mínimo con batería*máximo rendimiento permanente en un portátil*' }).Count | Should -Be 1
    }
}
