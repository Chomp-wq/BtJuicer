BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    # A well set-up gaming desktop. Each scenario changes only what it is about.
    function New-TestSystem {
        param([hashtable]$Set = @{})
        $two = @(
            @{ Capacity = 16GB; Speed = 4800; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_A2'; BankLabel = '' }
            @{ Capacity = 16GB; Speed = 4800; ConfiguredClockSpeed = 6000; SMBIOSMemoryType = 34; DeviceLocator = 'DIMM_B2'; BankLabel = '' }
        )
        $memory = Get-JuicerMemoryTraits $two $false
        $memory.Modules = $two; $memory.PageFiles = @(); $memory.Compression = $true
        $cpu = Get-JuicerCpuTraits 'AMD Ryzen 7 7700X 8-Core Processor'
        $cpu.Cores = 8; $cpu.Threads = 16
        $gpu = Get-JuicerGpuTraits 'NVIDIA GeForce RTX 4070'
        $gpu.DriverVersion = '32.0.15.6614'; $gpu.DriverAgeDays = 40; $gpu.VramBytes = 12GB
        $c = @{ Letter = 'C'; Disk = 'Samsung SSD 990 PRO'; Media = 'SSD'; Bus = 'NVMe'; SizeBytes = 1TB; FreeBytes = 500GB }
        $sw = Get-JuicerSoftwareTraits -Programs @('Steam', 'Discord') -Packages @('Microsoft.XboxGamingOverlay_7.0_x64__8wekyb3d8bbwe')
        $sw.Outlook = $false; $sw.Wsl = $false; $sw.HyperV = $false; $sw.Sandbox = $false; $sw.OtherSystems = @(); $sw.Programs = @('Steam', 'Discord')
        $s = @{
            Collected = (Get-Date); Errors = @()
            Os        = @{ Name = 'Windows 11 Pro'; Version = '24H2'; Build = 26100; Ubr = 2605; IsServer = $false; IsWin11 = $true; Insider = $false; PendingReboot = $false; UptimeDays = 1; ElevatedAs = 'PC\ana'; SessionUser = 'PC\ana' }
            Device    = @{ Manufacturer = 'ASUS'; Model = 'ROG'; Board = 'ASUS B650'; BiosDate = (Get-Date); Laptop = $false; Battery = $false; OnBattery = $false; ModernStandby = $false; HibernateSupported = $true; HypervisorPresent = $true }
            Cpu       = $cpu
            Memory    = $memory
            Graphics  = @{ Gpus = @($gpu); Hybrid = $false; VirtualOnly = $false; Displays = @(@{ Monitor = 'LG'; Width = 2560; Height = 1440; Hz = 165; MaxHz = 165 }); Rebar = $true }
            Storage   = @{ Disks = @(); Volumes = @($c); SystemDrive = $c; Trim = $true }
            Games     = @{ Libraries = @(@{ Launcher = 'Steam'; Path = 'C:\Program Files (x86)\Steam\steamapps'; Media = 'SSD'; Bus = 'NVMe' }); Installed = @() }
            Power     = @{ Plan = '381b4222-f694-41f0-9685-ff5bb260df2e'; PlanName = 'Equilibrado'; FastStartup = $true; Hibernate = $true }
            Security  = @{ Vbs = $true; Hvci = $true; HvciPolicy = $false; DefenderActive = $true; OtherAv = @() }
            Software  = $sw
            Settings  = @{ GameMode = $true; BackgroundRecording = $false; GameCapture = $true; MouseAcceleration = $true; StickyKeysOn = $false; Transparency = $true; StorageSenseCleansDownloads = $false }
            Network   = @{ Adapters = @(); Primary = @{ Type = 'Ethernet'; SpeedBps = 1000000000; Description = 'Realtek 2.5GbE' } }
            Startup   = @()
            Boot      = @{}
        }
        foreach ($section in $Set.Keys) {
            if ($Set[$section] -is [hashtable] -and $s[$section] -is [hashtable]) {
                foreach ($k in $Set[$section].Keys) { $s[$section][$k] = $Set[$section][$k] }
            } else {
                $s[$section] = $Set[$section]
            }
        }
        $s
    }

    function Get-Verdict {
        param([string]$Id, [hashtable]$System)
        Get-JuicerTweakAdvice (Find-JuicerTweak $Id) $System
    }

    function Get-FindingTitles {
        param([hashtable]$System)
        @(Get-JuicerFindings $System | ForEach-Object { "[$($_.Severity)] $($_.Title)" })
    }
}

Describe 'Clasificar el hardware' {
    It 'saca generación y MBEC/GMET del nombre del procesador' {
        $cases = @(
            , @('Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz', 6, $false)
            , @('Intel(R) Core(TM) i7-8700K CPU @ 3.70GHz', 8, $true)
            , @('11th Gen Intel(R) Core(TM) i7-1165G7 @ 2.80GHz', 11, $true)
            , @('12th Gen Intel(R) Core(TM) i5-12600K', 12, $true)
            , @('AMD Ryzen 5 3400G with Radeon Vega Graphics', 3, $false)
            , @('AMD Ryzen 9 3900X 12-Core Processor', 3, $true)
            , @('AMD Ryzen 7 2700X Eight-Core Processor', 2, $false)
            , @('AMD Ryzen 5 7520U with Radeon Graphics', 7, $true)
        )
        foreach ($c in $cases) {
            $t = Get-JuicerCpuTraits $c[0]
            $t.Generation | Should -Be $c[1] -Because $c[0]
            $t.Mbec | Should -Be $c[2] -Because $c[0]
        }
        (Get-JuicerCpuTraits 'Intel(R) Core(TM) Ultra 7 155H').Mbec | Should -BeTrue
    }

    It 'distingue los X3D de uno y dos CCD' {
        (Get-JuicerCpuTraits 'AMD Ryzen 7 7800X3D 8-Core Processor').DualCcdX3D | Should -BeFalse
        (Get-JuicerCpuTraits 'AMD Ryzen 7 7800X3D 8-Core Processor').X3D | Should -BeTrue
        (Get-JuicerCpuTraits 'AMD Ryzen 9 7950X3D 16-Core Processor').DualCcdX3D | Should -BeTrue
        # By topology too: two last-level caches.
        $sets = @(0..15 | ForEach-Object { @{ Group = 0; Core = [int]($_ / 2); Cache = [int]($_ -ge 8); Efficiency = 0 } })
        (Get-JuicerCpuTraits 'AMD Ryzen 9 9950X3D 16-Core Processor' $sets).CacheGroups | Should -Be 2
        (Get-JuicerCpuTraits 'AMD Ryzen 9 9950X 16-Core Processor' $sets).DualCcdX3D | Should -BeFalse
    }

    It 'cuenta núcleos P y E de un procesador híbrido' {
        # i5-12600K: 6 P cores with two threads each, 4 E cores.
        $sets = @(0..11 | ForEach-Object { @{ Group = 0; Core = [int][Math]::Floor($_ / 2); Cache = 0; Efficiency = 1 } }) +
            @(0..3 | ForEach-Object { @{ Group = 0; Core = 6 + $_; Cache = 0; Efficiency = 0 } })
        $t = Get-JuicerCpuTraits '12th Gen Intel(R) Core(TM) i5-12600K' $sets
        $t.Hybrid | Should -BeTrue
        $t.PCores | Should -Be 6
        $t.ECores | Should -Be 4
    }

    It 'clasifica gráficas' {
        $g = Get-JuicerGpuTraits 'NVIDIA GeForce RTX 4070'
        $g.Kind | Should -Be 'Dedicada'; $g.FrameGen | Should -BeTrue; $g.HagsSupported | Should -BeTrue
        (Get-JuicerGpuTraits 'NVIDIA GeForce GTX 970').HagsSupported | Should -BeFalse
        (Get-JuicerGpuTraits 'AMD Radeon RX 6700 XT').HagsSupported | Should -BeTrue
        (Get-JuicerGpuTraits 'AMD Radeon(TM) Graphics').Kind | Should -Be 'Integrada'
        (Get-JuicerGpuTraits 'AMD Radeon 780M Graphics').Kind | Should -Be 'Integrada'
        (Get-JuicerGpuTraits 'Intel(R) UHD Graphics 770').Kind | Should -Be 'Integrada'
        (Get-JuicerGpuTraits 'Intel(R) Arc(TM) Graphics').Kind | Should -Be 'Integrada'
        (Get-JuicerGpuTraits 'Intel(R) Arc(TM) A770 Graphics').Kind | Should -Be 'Dedicada'
    }

    It 'reconoce programas, apps de la Tienda, anti-trampas y el driver de V-Cache' {
        $t = Get-JuicerSoftwareTraits -Programs @('Steam', 'OBS Studio', 'World of Warcraft', 'Docker Desktop') `
            -Packages @('5319275A.WhatsAppDesktop_2.2_x64__cv1g1gvanyjgm', 'Microsoft.GamingApp_1_x64__8wekyb3d8bbwe') `
            -Services @('vgk', 'Riot Vanguard', 'AMD 3D V-Cache Performance Optimizer Service')
        $t.Launchers | Should -Be @('Steam', 'Xbox')
        $t.Capture | Should -Be @('OBS Studio')
        $t.TcpGames | Should -Be @('World of Warcraft')
        $t.Vm | Should -Be @('Docker Desktop')
        $t.Background | Should -Be @('WhatsApp')
        $t.AntiCheat | Should -Be @('Riot Vanguard')
        $t.VCacheDriver | Should -BeTrue
        (Get-JuicerSoftwareTraits -Games @('FINAL FANTASY XIV Online')).TcpGames | Should -Be @('Final Fantasy XIV')
    }

    It 'encuentra otros sistemas en el arranque UEFI' {
        $fw = "Firmware Boot Manager`nidentifier {fwbootmgr}`n`nFirmware Application (101fffff)`ndescription             Windows Boot Manager`n`ndescription             ubuntu`n`ndescription             UEFI: Samsung SSD"
        Get-JuicerOtherSystems $fw | Should -Be @('ubuntu')
        @(Get-JuicerOtherSystems 'description  Windows Boot Manager').Count | Should -Be 0
    }

    It 'sabe qué programas de inicio sobran y cuáles no' {
        (Get-JuicerStartupAdvice @{ Name = 'Steam'; Command = '"C:\Program Files (x86)\Steam\steam.exe" -silent' }).Suggest | Should -BeTrue
        (Get-JuicerStartupAdvice @{ Name = 'Discord'; Command = 'Update.exe --processStart Discord.exe' }).Suggest | Should -BeTrue
        (Get-JuicerStartupAdvice @{ Name = 'RtkAudUService'; Command = 'RtkAudUService64.exe' }).Keep | Should -BeTrue
        (Get-JuicerStartupAdvice @{ Name = 'OneDrive'; Command = 'OneDrive.exe /background' }).Suggest | Should -BeFalse
        (Get-JuicerStartupAdvice @{ Name = 'Algo'; Command = 'algo.exe' }).Suggest | Should -BeFalse
    }
}

Describe 'Consejos según el equipo' {
    BeforeEach { $m = New-FakeMachine }

    It 'sobremesa normal: plan de energía sí, plan Equilibrado X3D no aplica' {
        $s = New-TestSystem
        (Get-Verdict 'energia.plan' $s).Verdict | Should -Be 'Recomendado'
        (Get-Verdict 'energia.equilibrado' $s).Verdict | Should -Be 'NoAplica'
        (Get-Verdict 'juegos.hags' $s).Verdict | Should -Be 'Recomendado'
        (Get-Verdict 'juegos.hags' $s).Why | Should -BeLike '*RTX 4070*DLSS*'
    }

    It 'Ryzen 9 7950X3D: Equilibrado, modo juego imprescindible, y avisa si falta el driver' {
        $cpu = Get-JuicerCpuTraits 'AMD Ryzen 9 7950X3D 16-Core Processor'
        $s = New-TestSystem @{ Cpu = $cpu }
        (Get-Verdict 'energia.plan' $s).Verdict | Should -Be 'NoRecomendado'
        (Get-Verdict 'energia.equilibrado' $s).Verdict | Should -Be 'Recomendado'
        $gm = Get-Verdict 'juegos.modo' $s
        $gm.Impact | Should -Be 'Alto'
        $gm.Why | Should -BeLike '*7950X3D*'
        Get-FindingTitles $s | Should -Contain '[Alto] Falta el driver 3D V-Cache de tu AMD Ryzen 9 7950X3D 16-Core Processor'
    }

    It 'portátil con Modern Standby, con batería, CPU híbrida y dos gráficas' {
        $cpu = Get-JuicerCpuTraits '12th Gen Intel(R) Core(TM) i7-12700H'
        $cpu.Hybrid = $true; $cpu.PCores = 6; $cpu.ECores = 8
        $igpu = Get-JuicerGpuTraits 'Intel(R) Iris(R) Xe Graphics'
        $dgpu = Get-JuicerGpuTraits 'NVIDIA GeForce RTX 3060 Laptop GPU'
        $s = New-TestSystem @{
            Cpu = $cpu
            Device = @{ Laptop = $true; Battery = $true; OnBattery = $true; ModernStandby = $true }
            Graphics = @{ Gpus = @($igpu, $dgpu); Hybrid = $true }
        }
        (Get-Verdict 'energia.plan' $s).Verdict | Should -Be 'NoAplica'
        (Get-Verdict 'energia.modo' $s).Verdict | Should -Be 'Opcional'
        (Get-Verdict 'energia.limitacion' $s).Verdict | Should -Be 'Opcional'
        $f = Get-FindingTitles $s
        $f | Should -Contain '[Alto] Estás funcionando con batería'
        @($f | Where-Object { $_.StartsWith('[Medio] Portátil con dos gráficas') }).Count | Should -Be 1
    }

    It 'sobremesa con CPU híbrida: la limitación de energía, recomendada' {
        $cpu = Get-JuicerCpuTraits '13th Gen Intel(R) Core(TM) i7-13700K'
        $cpu.Hybrid = $true; $cpu.PCores = 8; $cpu.ECores = 8
        $a = Get-Verdict 'energia.limitacion' (New-TestSystem @{ Cpu = $cpu })
        $a.Verdict | Should -Be 'Recomendado'
        $a.Why | Should -BeLike '*8 núcleos P y 8 E*'
    }

    It 'con WSL o Docker, no se toca el hipervisor' {
        $s = New-TestSystem
        $s.Software.Wsl = $true
        $s.Software.Vm = @('Docker Desktop')
        $a = Get-Verdict 'seguridad.hipervisor' $s
        $a.Verdict | Should -Be 'NoRecomendado'
        $a.Why | Should -BeLike '*WSL y Docker Desktop*'
    }

    It 'con arranque dual, nada de inicio rápido' {
        $s = New-TestSystem
        $s.Software.OtherSystems = @('ubuntu')
        (Get-Verdict 'energia.inicio' $s).Verdict | Should -Be 'NoRecomendado'
    }

    It 'disco duro y Outlook: SysMain importa más, el indexado se queda' {
        $hdd = @{ Letter = 'C'; Disk = 'WD Blue'; Media = 'HDD'; Bus = 'SATA'; SizeBytes = 1TB; FreeBytes = 400GB }
        $s = New-TestSystem @{ Storage = @{ Volumes = @($hdd); SystemDrive = $hdd } }
        (Get-Verdict 'reparar.sysmain' $s).Impact | Should -Be 'Alto'
        (Get-Verdict 'fondo.indexado' $s).Impact | Should -Be 'Medio'
        $s.Software.Outlook = $true
        (Get-Verdict 'fondo.indexado' $s).Verdict | Should -Be 'NoRecomendado'
        Get-FindingTitles $s | Should -Contain '[Alto] Windows está en un disco duro mecánico: WD Blue (HDD, SATA)'
    }

    It 'respeta Teclas especiales, Insider y el Sensor de almacenamiento' {
        (Get-Verdict 'juegos.teclas' (New-TestSystem @{ Settings = @{ StickyKeysOn = $true } })).Verdict | Should -Be 'NoRecomendado'
        (Get-Verdict 'fondo.telemetria' (New-TestSystem @{ Os = @{ Insider = $true } })).Verdict | Should -Be 'NoRecomendado'
        (Get-Verdict 'disco.ultimoacceso' (New-TestSystem @{ Settings = @{ StorageSenseCleansDownloads = $true } })).Verdict | Should -Be 'NoRecomendado'
    }

    It 'con poca RAM quita más cosas de fondo, salvo las apps que avisan' {
        $one = @(@{ Capacity = 8GB; Speed = 3200; ConfiguredClockSpeed = 3200; SMBIOSMemoryType = 26; DeviceLocator = 'DIMM_A2'; BankLabel = '' })
        $s = New-TestSystem @{ Memory = (Get-JuicerMemoryTraits $one $false) }
        (Get-Verdict 'ui.widgets' $s).Verdict | Should -Be 'Recomendado'
        (Get-Verdict 'fondo.apps' $s).Verdict | Should -Be 'Recomendado'
        Get-FindingTitles $s | Should -Contain '[Alto] Un solo módulo de RAM: canal simple'
        $s.Software.Background = @('WhatsApp')
        (Get-Verdict 'fondo.apps' $s).Verdict | Should -Be 'NoRecomendado'
    }

    It 'Nagle sólo si hay juegos TCP; la grabación, si ya grabas con otra cosa' {
        $s = New-TestSystem
        (Get-Verdict 'red.nagle' $s).Verdict | Should -Be 'Opcional'
        $s.Software.TcpGames = @('World of Warcraft')
        (Get-Verdict 'red.nagle' $s).Verdict | Should -Be 'Recomendado'
        (Get-Verdict 'juegos.grabacion' $s).Verdict | Should -Be 'Opcional'
        $s.Software.Capture = @('OBS Studio')
        (Get-Verdict 'juegos.grabacion' $s).Why | Should -BeLike '*OBS Studio*'
    }

    It 'la integridad de memoria pesa más sin MBEC, pero nunca se recomienda sola' {
        $old = Get-JuicerCpuTraits 'Intel(R) Core(TM) i7-6700K CPU @ 4.00GHz'
        $a = Get-Verdict 'seguridad.integridad' (New-TestSystem @{ Cpu = $old })
        $a.Verdict | Should -Be 'Opcional'
        $a.Impact | Should -Be 'Alto'
        (Get-Verdict 'seguridad.integridad' (New-TestSystem)).Impact | Should -Be 'Medio'
        (Get-Verdict 'seguridad.integridad' (New-TestSystem @{ Security = @{ Hvci = $false } })).Verdict | Should -Be 'NoAplica'
        foreach ($t in (Get-JuicerCatalog | Where-Object { $_.Level -eq 3 })) {
            foreach ($s in (New-TestSystem), (New-TestSystem @{ Cpu = $old })) {
                (Get-JuicerTweakAdvice $t $s).Verdict | Should -Not -Be 'Recomendado'
            }
        }
    }

    It 'gráfica sin HAGS, gráfica integrada y pantallas mal configuradas' {
        $s = New-TestSystem @{ Graphics = @{ Gpus = @(Get-JuicerGpuTraits 'NVIDIA GeForce GTX 970') } }
        (Get-Verdict 'juegos.hags' $s).Verdict | Should -Be 'NoAplica'
        $i = New-TestSystem @{ Graphics = @{ Gpus = @(Get-JuicerGpuTraits 'AMD Radeon(TM) Graphics') } }
        (Get-Verdict 'ui.transparencia' $i).Verdict | Should -Be 'Recomendado'
        $d = New-TestSystem @{ Graphics = @{ Displays = @(@{ Monitor = 'AOC'; Width = 1920; Height = 1080; Hz = 60; MaxHz = 144 }); Rebar = $false } }
        $f = Get-FindingTitles $d
        $f | Should -Contain '[Alto] AOC funciona a 60 Hz pero admite 144 Hz'
        $f | Should -Contain '[Medio] Resizable BAR desactivado'
    }

    It 'red por Wi-Fi o cable a 100 Mbps' {
        Get-FindingTitles (New-TestSystem @{ Network = @{ Primary = @{ Type = 'Wi-Fi'; SpeedBps = 866000000; Description = 'Intel Wi-Fi 6' } } }) |
            Should -Contain '[Medio] Te conectas por Wi-Fi (Intel Wi-Fi 6)'
        Get-FindingTitles (New-TestSystem @{ Network = @{ Primary = @{ Type = 'Ethernet'; SpeedBps = 100000000; Description = 'Realtek' } } }) |
            Should -Contain '[Medio] Tu conexión por cable va a 100 Mbps'
    }

    It 'un equipo bien montado no recibe avisos graves' {
        @(Get-JuicerFindings (New-TestSystem) | Where-Object { $_.Severity -in 'Alto', 'Medio' }) | Should -BeNullOrEmpty
    }

    It 'resume el equipo en una ficha' {
        $rows = @(Get-JuicerSystemSummary (New-TestSystem))
        ($rows | Where-Object { $_[0] -eq 'Memoria' })[1] | Should -Be '32.0 GB DDR5 a 6000 MT/s, 2 módulo(s) en doble canal'
        ($rows | Where-Object { $_[0] -eq 'Gráfica' })[1] | Should -BeLike 'NVIDIA GeForce RTX 4070 (12.0 GB), dedicada*'
    }
}

Describe 'El plan' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'reparte el catálogo según el equipo, sin dejar ninguno fuera' {
        $s = New-TestSystem
        Set-JuicerSystem $s
        $p = Get-JuicerPlan $s
        $all = @($p.Recommended) + @($p.Optional) + @($p.NotRecommended) + @($p.NotApplicable) + @($p.Done) + @($p.Revert)
        @($all | Where-Object { $_.Tweak.Id -notlike 'juego:*' }).Count | Should -Be @(Get-JuicerCatalog).Count
        @($p.Recommended | ForEach-Object { $_.Tweak.Id }) | Should -Contain 'energia.plan'
        @($p.Optional | ForEach-Object { $_.Tweak.Id }) | Should -Contain 'juego:defender:c:\program files (x86)\steam\steamapps'
        @($p.Recommended | Where-Object { $_.Tweak.Level -ge 3 }) | Should -BeNullOrEmpty
    }

    It 'propone deshacer lo que se aplicó antes y ya no conviene' {
        $s = New-TestSystem
        Set-JuicerSystem $s
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.plan')).Outcome | Should -Be 'Aplicado'
        $x3d = New-TestSystem @{ Cpu = (Get-JuicerCpuTraits 'AMD Ryzen 9 7950X3D 16-Core Processor') }
        Set-JuicerSystem $x3d
        $p = Get-JuicerPlan $x3d
        @($p.Revert | ForEach-Object { $_.Tweak.Id }) | Should -Be @('energia.plan')
        @($p.Recommended | ForEach-Object { $_.Tweak.Id }) | Should -Contain 'energia.equilibrado'
        $r = @(Invoke-JuicerPlan $p -NoRestorePoint)
        ($r | Where-Object { $_.Id -eq 'energia.plan' }).Outcome | Should -Be 'Deshecho'
        ($r | Where-Object { $_.Id -eq 'energia.equilibrado' }).Outcome | Should -Be 'YaEstaba'
        $m.Fake.Active | Should -Be '381b4222-f694-41f0-9685-ff5bb260df2e'
    }

    It 'quita del inicio lo sugerido sólo si se pide, y se puede deshacer' {
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' 'Steam' 'String' '"C:\Steam\steam.exe" -silent'
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run' 'RtkAudUService' 'String' 'RtkAudUService64.exe'
        $s = New-TestSystem @{ Startup = @(Get-JuicerInvStartup) }
        $p = Get-JuicerPlan $s
        @($p.Startup | ForEach-Object { $_.Name }) | Should -Be @('Steam')
        $before = Get-MachineSnapshot $m
        [void](Invoke-JuicerPlan $p -Startup -NoRestorePoint)
        (@(Get-JuicerStartupItems -NoTasks) | Where-Object { $_.Name -eq 'Steam' }).Enabled | Should -BeFalse
        [void](Undo-JuicerAll)
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'los perfiles fijos se ajustan al equipo' {
        $x3d = New-TestSystem @{ Cpu = (Get-JuicerCpuTraits 'AMD Ryzen 9 7950X3D 16-Core Processor') }
        @(Get-JuicerFittedProfile 2 $x3d | ForEach-Object { $_.Id }) | Should -Not -Contain 'energia.plan'
        @(Get-JuicerFittedProfile 2 (New-TestSystem) | ForEach-Object { $_.Id }) | Should -Contain 'energia.plan'
    }
}

Describe 'El análisis en una máquina simulada' {
    It 'recorre todas las secciones sin errores y deja el informe' {
        $m = New-FakeMachine
        Write-JuicerReg 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' 'ProcessorNameString' 'String' 'AMD Ryzen 7 7800X3D 8-Core Processor'
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\Steam' 'DisplayName' 'String' 'Steam'
        $s = Get-JuicerSystemProfile
        $s.Errors | Should -BeNullOrEmpty
        $s.Os.Build | Should -Be 26100
        $s.Cpu.X3D | Should -BeTrue
        $s.Power.Plan | Should -Be '381b4222-f694-41f0-9685-ff5bb260df2e'
        $s.Software.Launchers | Should -Be @('Steam')
        $txt = Save-JuicerReport $s
        Get-Content -LiteralPath $txt -Raw | Should -Match 'TU EQUIPO'
        (Get-Content -LiteralPath (Join-Path (Get-JuicerHome) 'equipo.json') -Raw | ConvertFrom-Json).Cpu.Name | Should -BeLike '*7800X3D*'
    }
}
