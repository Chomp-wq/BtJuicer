# The hardware profile, the overclock and BIOS review and the advisor, with
# the strings real machines report. None of it needs Windows.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    function New-TestHw {
        param([hashtable]$Cpu = @{}, [object[]]$Gpus = @(), [int64]$Ram = 32GB, [bool]$Laptop = $false, [string]$Disk = 'SSD', [hashtable]$Extra = @{})
        $hw = @{
            Cpu = (Get-JuicerCpuTraits @Cpu); Gpus = @($Gpus | ForEach-Object { Get-JuicerGpuTraits $_ }); RamBytes = $Ram; Modules = @()
            Laptop = $Laptop; OnBattery = $false; ModernStandby = $false; SystemDisk = @{ Media = $Disk; Bus = 'NVMe'; Name = 'Disco' }
            Printers = @(); Adapters = @(); OneDrive = @{ Installed = $false; SignedIn = $false; Kfm = $false; Folders = @() }
            Edge = $true; Home = $false; Insider = $false; Build = 26100; Wsl = $false; Docker = $false; GamePass = $false; GameBar = $true
        }
        foreach ($k in $Extra.Keys) { $hw[$k] = $Extra[$k] }
        $hw
    }
}

Describe 'Procesador' {
    It 'lee familia, modelo y revisión' {
        $id = ConvertFrom-JuicerCpuIdentifier 'Intel64 Family 6 Model 183 Stepping 1'
        $id.Family | Should -Be 6
        $id.Model | Should -Be 183
        ConvertFrom-JuicerCpuIdentifier 'nada' | Should -BeNullOrEmpty
    }

    It 'saca el microcódigo de la mitad que toca según el fabricante' {
        ConvertFrom-JuicerMicrocode ([byte[]](0, 0, 0, 0, 0x2B, 0x01, 0, 0)) 'Intel' | Should -Be 0x12B
        ConvertFrom-JuicerMicrocode ([byte[]](0x0B, 0x12, 0x60, 0x0A, 0, 0, 0, 0)) 'AMD' | Should -Be 0x0A60120B
        ConvertFrom-JuicerMicrocode ([byte[]](0, 0, 0, 0, 0, 0, 0, 0)) 'Intel' | Should -BeNullOrEmpty
        ConvertFrom-JuicerMicrocode ([byte[]](1, 2)) 'Intel' | Should -BeNullOrEmpty
    }

    It 'reconoce los Ryzen X3D, y cuáles tienen la caché en un solo CCD' {
        $single = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7800X3D 8-Core Processor' -Vendor 'AuthenticAMD' -Cores 8 -Threads 16
        $single.X3D | Should -BeTrue
        $single.DualCcdX3D | Should -BeFalse
        $single.Am5 | Should -BeTrue
        foreach ($n in 'AMD Ryzen 9 7950X3D 16-Core Processor', 'AMD Ryzen 9 9900X3D 12-Core Processor', 'AMD Ryzen 9 7945HX3D with Radeon Graphics') {
            (Get-JuicerCpuTraits -Name $n -Vendor 'AuthenticAMD').DualCcdX3D | Should -BeTrue -Because $n
        }
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5800X3D 8-Core Processor' -Vendor 'AuthenticAMD').Am4 | Should -BeTrue
    }

    It 'distingue sobremesa de portátil en AM4 y AM5' {
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 5600X 6-Core Processor').Am4 | Should -BeTrue
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 8600G w/ Radeon 760M Graphics').Am5 | Should -BeTrue
        $m = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7840HS w/ Radeon 780M Graphics'
        $m.Mobile | Should -BeTrue
        $m.Am5 | Should -BeFalse
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 5500U with Radeon Graphics').Am4 | Should -BeFalse
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 9 7945HX3D with Radeon Graphics').Mobile | Should -BeTrue
        (Get-JuicerCpuTraits -Name 'Intel(R) Core(TM) i5-1035G1 CPU @ 1.00GHz').Mobile | Should -BeTrue
        (Get-JuicerCpuTraits -Name 'Intel(R) Core(TM) Ultra 7 155H').Mobile | Should -BeTrue
        (Get-JuicerCpuTraits -Name 'Intel(R) Core(TM) Ultra 9 285K').Mobile | Should -BeFalse
        (Get-JuicerCpuTraits -Name '14th Gen Intel(R) Core(TM) i7-14700KF').Mobile | Should -BeFalse
    }

    It 'marca como Raptor Lake sólo el silicio afectado de sobremesa' {
        $k = Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i9-13900K' -Vendor 'GenuineIntel' -Identifier 'Intel64 Family 6 Model 183 Stepping 1'
        $k.RaptorLake | Should -BeTrue
        (Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i9-13980HX' -Vendor 'GenuineIntel' -Identifier 'Intel64 Family 6 Model 183 Stepping 1').RaptorLake | Should -BeFalse
        (Get-JuicerCpuTraits -Name '12th Gen Intel(R) Core(TM) i5-12400F' -Vendor 'GenuineIntel' -Identifier 'Intel64 Family 6 Model 151 Stepping 5').RaptorLake | Should -BeFalse
    }

    It 'sabe si es híbrido, por la API o por los hilos' {
        (Get-JuicerCpuTraits -Name 'Intel(R) Core(TM) Ultra 9 285K' -Vendor 'GenuineIntel' -Cores 24 -Threads 24 -EfficiencyClasses @(1, 1, 0, 0)).Hybrid | Should -BeTrue
        (Get-JuicerCpuTraits -Name '12th Gen Intel(R) Core(TM) i5-12600K' -Vendor 'GenuineIntel' -Cores 10 -Threads 16).Hybrid | Should -BeTrue
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 9700X' -Vendor 'AuthenticAMD' -Cores 8 -Threads 16).Hybrid | Should -BeFalse
        (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 9700X' -Vendor 'AuthenticAMD' -EfficiencyClasses @(0, 0, 0, 0)).Hybrid | Should -BeFalse
    }
}

Describe 'Gráfica' {
    It 'reconoce fabricante, si es dedicada y qué admite' -ForEach @(
        @{ N = 'NVIDIA GeForce RTX 4070 Ti SUPER'; V = 'NVIDIA'; D = $true; H = $true; F = $true }
        @{ N = 'NVIDIA GeForce RTX 3060 Laptop GPU'; V = 'NVIDIA'; D = $true; H = $true; F = $false }
        @{ N = 'NVIDIA GeForce GTX 1660 SUPER'; V = 'NVIDIA'; D = $true; H = $true; F = $false }
        @{ N = 'NVIDIA GeForce GTX 980'; V = 'NVIDIA'; D = $true; H = $false; F = $false }
        @{ N = 'AMD Radeon RX 7800 XT'; V = 'AMD'; D = $true; H = $true; F = $false }
        @{ N = 'AMD Radeon RX 580 Series'; V = 'AMD'; D = $true; H = $false; F = $false }
        @{ N = 'AMD Radeon(TM) Graphics'; V = 'AMD'; D = $false; H = $null; F = $false }
        @{ N = 'Intel(R) Arc(TM) B580 Graphics'; V = 'Intel'; D = $true; H = $true; F = $false }
        @{ N = 'Intel(R) Arc(TM) Graphics'; V = 'Intel'; D = $false; H = $null; F = $false }
        @{ N = 'Intel(R) UHD Graphics 770'; V = 'Intel'; D = $false; H = $null; F = $false }
    ) {
        $g = Get-JuicerGpuTraits $N
        $g.Vendor | Should -Be $V
        $g.Discrete | Should -Be $D
        $g.Hags | Should -Be $H
        $g.FrameGen | Should -Be $F
    }

    It 'deduce Resizable BAR de los rangos de memoria' {
        Test-JuicerRebarRanges @([uint64]16MB, [uint64]256MB, [uint64]32MB) | Should -BeFalse
        Test-JuicerRebarRanges @([uint64]16MB, [uint64]16GB) | Should -BeTrue
        Test-JuicerRebarRanges @() | Should -BeNullOrEmpty
    }

    It 'lee la consulta de nvidia-smi y avisa de potencia y líneas PCIe' {
        $q = @(ConvertFrom-JuicerNvidiaQuery "NVIDIA GeForce RTX 4070, 160.00, 200.00, 8, 16")
        $q[0].Power | Should -Be 160
        $q[0].MaxWidth | Should -Be 16
        $f = @(Get-JuicerGpuTuningFindings -Nvidia $q)
        @($f | Where-Object { $_.Title -like '*al 80 %*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*x8 de x16*' }).Count | Should -Be 1
        @(Get-JuicerGpuTuningFindings -Nvidia @(ConvertFrom-JuicerNvidiaQuery 'Laptop, [N/A], [N/A], 8, 8')).Count | Should -Be 0
    }

    It 'sin ver Resizable BAR lo dice como sospecha, más fuerte en una Arc' {
        $f = @(Get-JuicerGpuTuningFindings -Rebar @(@{ Name = 'Arc B580'; Arc = $true; On = $false }, @{ Name = 'RX 7800 XT'; Arc = $false; On = $false }, @{ Name = 'X'; On = $null }))
        $f.Count | Should -Be 2
        $f[0].Severity | Should -Be 'Medio'
        $f[1].Severity | Should -Be 'Bajo'
        foreach ($x in $f) { $x.Detail | Should -BeLike '*Confírmalo*' }
    }

    It 'en portátiles no confunde el enlace estrecho en reposo con una ranura mala' {
        $q = @(ConvertFrom-JuicerNvidiaQuery 'RTX 4060 Laptop GPU, 80.00, 80.00, 4, 8')
        @(Get-JuicerGpuTuningFindings -Nvidia $q -Laptop $true).Count | Should -Be 0
        @(Get-JuicerGpuTuningFindings -Nvidia $q).Count | Should -Be 1
    }

    It 'un sobremesa con SAI no es un portátil' {
        Test-JuicerLaptopChassis @(3) $true | Should -BeFalse
        Test-JuicerLaptopChassis @(10) $false | Should -BeTrue
        Test-JuicerLaptopChassis @(2) $true | Should -BeTrue
        Test-JuicerLaptopChassis @() $false | Should -BeFalse
    }
}

Describe 'Memoria' {
    It 'saca la velocidad del kit de su referencia' -ForEach @(
        @{ P = 'F4-3600C16D-16GVKC'; S = 3600; X = $true }
        @{ P = 'F5-6000J3038F16GX2-TZ5RK'; S = 6000; X = $true }
        @{ P = 'CMK16GX4M2B3200C16'; S = 3200; X = $true }
        @{ P = 'CMH32GX5M2B6000C30'; S = 6000; X = $true }
        @{ P = 'KF436C17BBK2/16'; S = 3600; X = $true }
        @{ P = 'KF560C36BBEK2-32'; S = 6000; X = $true }
        @{ P = 'HX432C16FB3/16'; S = 3200; X = $true }
        @{ P = 'KVR32N22S8/8'; S = 3200; X = $false }
        @{ P = 'BL8G36C16U4B.M8FE1'; S = 3600; X = $true }
        @{ P = 'CP2K16G60C36U5B'; S = 6000; X = $true }
        @{ P = 'CT16G4DFRA32A.M16FR'; S = 3200; X = $false }
        @{ P = 'CT8G4DFS832A'; S = 3200; X = $false }
        @{ P = 'CT16G56C46U5.M8A1'; S = 5600; X = $false }
        @{ P = 'TF3D416G3600HC18J'; S = 3600; X = $true }
        @{ P = 'FF3D532G6000HC38ADC01'; S = 6000; X = $true }
        @{ P = 'AX4U360038G18A-DT60'; S = 3600; X = $true }
        @{ P = 'AX5U6000C3016G-DCLARBK'; S = 6000; X = $true }
        @{ P = 'PVS416G360C8K'; S = 3600; X = $true }
        @{ P = 'PVV532G600C30K'; S = 6000; X = $true }
    ) {
        $r = Get-JuicerRamRating $P
        $r.Speed | Should -Be $S
        $r.Xmp | Should -Be $X
    }

    It 'no se inventa velocidades de referencias que no conoce' {
        foreach ($p in 'M378A1K43EB2-CWE', 'HMA81GU6CJR8N-XN', '', '   ', 'Unknown') { Get-JuicerRamRating $p | Should -BeNullOrEmpty -Because $p }
    }

    It 'con la referencia del kit, el aviso de XMP es seguro y dice la cifra' {
        $kit = @(
            [pscustomobject]@{ Capacity = 16GB; Speed = 2133; ConfiguredClockSpeed = 2133; SMBIOSMemoryType = 26; DeviceLocator = 'DIMM_A2'; BankLabel = ''; PartNumber = 'F4-3600C16-16GVKC' }
            [pscustomobject]@{ Capacity = 16GB; Speed = 2133; ConfiguredClockSpeed = 2133; SMBIOSMemoryType = 26; DeviceLocator = 'DIMM_B2'; BankLabel = ''; PartNumber = 'F4-3600C16-16GVKC' }
        )
        $f = @(Get-JuicerRamFindings $kit $false | Where-Object { $_.Title -like '*certificado a 3600*' })
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Alto'
    }

    It 'avisa de kits mezclados y de cuatro módulos DDR5' {
        $mods = @(foreach ($i in 1..4) {
                [pscustomobject]@{ Capacity = 16GB; Speed = 4800; ConfiguredClockSpeed = 5200; SMBIOSMemoryType = 34; DeviceLocator = "DIMM$i"; BankLabel = ''; PartNumber = $(if ($i -le 2) { 'CMK32GX5M2B5200C40' } else { 'F5-6000J3038F16GX2-TZ5RK' }) }
            })
        $f = @(Get-JuicerRamFindings $mods $false)
        @($f | Where-Object { $_.Title -like 'Módulos de RAM distintos*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -eq 'Cuatro módulos DDR5' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'XMP/EXPO activo*' }).Count | Should -Be 1
    }
}

Describe 'Plan de energía y estabilidad' {
    It 'lee los valores de powercfg en cualquier idioma' {
        $en = @'
    Power Setting GUID: bc5038f7-23e0-4960-96da-33abaf5935ec  (Maximum processor state)
      Minimum Possible Setting: 0x00000000
      Maximum Possible Setting: 0x00000064
      Possible Settings increment: 0x00000001
      Possible Settings units: %
    Current AC Power Setting Index: 0x00000050
    Current DC Power Setting Index: 0x00000064
'@
        $es = @'
    GUID de configuración de energía: be337238-0d82-4146-a960-4f3749d470c7  (Modo de aumento de rendimiento del procesador)
      Índice de configuración posible: 000
      Nombre descriptivo de configuración posible: Deshabilitado
    Índice de configuración de corriente alterna actual: 0x00000000
    Índice de configuración de corriente continua actual: 0x00000002
'@
        $a = ConvertFrom-JuicerPowerSetting $en
        $a.AC | Should -Be 80
        $a.DC | Should -Be 100
        (ConvertFrom-JuicerPowerSetting $es).AC | Should -Be 0
        ConvertFrom-JuicerPowerSetting 'error' | Should -BeNullOrEmpty
    }

    It 'avisa del procesador limitado y del turbo apagado' {
        $f = @(Get-JuicerPowerCapFindings @{ AC = 80; DC = 100 } @{ AC = 0; DC = 2 } 'a1841308-3541-4fab-bc81-f71556f20b4a')
        $f.Count | Should -Be 3
        @($f | Where-Object { $_.Severity -eq 'Alto' }).Count | Should -Be 2
        @(Get-JuicerPowerCapFindings @{ AC = 100; DC = 100 } @{ AC = 2; DC = 2 } '381b4222-f694-41f0-9685-ff5bb260df2e')[0].Severity | Should -Be 'Ok'
    }

    It 'pone nombre y causa a los pantallazos' {
        (Get-JuicerBugcheckInfo 0x124).Name | Should -Be 'WHEA_UNCORRECTABLE_ERROR'
        (Get-JuicerBugcheckInfo 0x1000007E).Name | Should -Be 'SYSTEM_THREAD_EXCEPTION_NOT_HANDLED'
        (Get-JuicerBugcheckInfo 0x999).Name | Should -Be '0x999'
        ConvertFrom-JuicerBugcheckText 'The computer has rebooted from a bugcheck.  The bugcheck was: 0x00000101 (0x0000000000000018, ...)' | Should -Be 0x101
        ConvertFrom-JuicerBugcheckText 'sin código' | Should -BeNullOrEmpty
    }

    It 'resume WHEA, pantallazos, cuelgues de la gráfica y estrangulamiento' {
        $f = @(Get-JuicerStabilityFindings -Whea @{ 19 = 12; 17 = 1 } -Bugchecks @(0x124, 0x124, 0x101) -Unexpected 6 -Tdr 2 -Throttle 4)
        ($f | Where-Object { $_.Title -like '*WHEA 19*' }).Severity | Should -Be 'Alto'
        ($f | Where-Object { $_.Title -like '*pantallazos*' }).Detail | Should -BeLike 'WHEA_UNCORRECTABLE_ERROR ×2*CLOCK_WATCHDOG_TIMEOUT ×1*'
        @($f | Where-Object { $_.Title -like '3 apagados inesperados*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*gráfica se colgó*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*frenó el procesador 4 veces*' }).Count | Should -Be 1
        $ok = @(Get-JuicerStabilityFindings -MemoryOc $true)
        $ok[0].Severity | Should -Be 'Ok'
        $ok[0].Detail | Should -BeLike '*XMP/EXPO*'
    }
}

Describe 'BIOS y firmware' {
    It 'Raptor Lake: microcódigo viejo es grave, el corregido está bien' {
        $cpu = Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i7-13700K' -Vendor 'GenuineIntel' -Identifier 'Intel64 Family 6 Model 183 Stepping 1' -Microcode 0x119
        @(Get-JuicerFirmwareFindings -Cpu $cpu -BiosDate ([datetime]'2023-06-01') | Where-Object { $_.Severity -eq 'Alto' }).Count | Should -Be 1
        $cpu.Microcode = 0x12F
        @(Get-JuicerFirmwareFindings -Cpu $cpu -BiosDate ([datetime]'2025-06-01') | Where-Object { $_.Severity -eq 'Ok' }).Count | Should -Be 1
        $cpu.Microcode = $null
        @(Get-JuicerFirmwareFindings -Cpu $cpu -BiosDate ([datetime]'2024-02-01') | Where-Object { $_.Severity -eq 'Alto' }).Count | Should -Be 1
    }

    It 'AM5 con BIOS anterior a la corrección de voltaje SoC, y fTPM en AM4' {
        $am5 = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7800X3D 8-Core Processor' -Vendor 'AuthenticAMD'
        @(Get-JuicerFirmwareFindings -Cpu $am5 -BiosDate ([datetime]'2023-02-10') | Where-Object { $_.Title -like '*AM5*' }).Count | Should -Be 1
        @(Get-JuicerFirmwareFindings -Cpu $am5 -BiosDate ([datetime]'2024-02-10') | Where-Object { $_.Title -like '*AM5*' }).Count | Should -Be 0
        $am4 = Get-JuicerCpuTraits -Name 'AMD Ryzen 5 3600 6-Core Processor' -Vendor 'AuthenticAMD'
        @(Get-JuicerFirmwareFindings -Cpu $am4 -BiosDate ([datetime]'2021-03-01') -TpmVendor 'AMD' | Where-Object { $_.Title -like '*fTPM*' -or $_.Title -like '*TPM*' }).Count | Should -Be 1
        @(Get-JuicerFirmwareFindings -Cpu $am4 -BiosDate ([datetime]'2021-03-01') -TpmVendor 'INTC' | Where-Object { $_.Title -like '*TPM*' }).Count | Should -Be 0
    }

    It 'una BIOS de hace años, sin nada más grave, merece un aviso suave' {
        $f = @(Get-JuicerFirmwareFindings -Cpu @{} -BiosDate ([datetime]'2019-01-01') -BiosVersion 'F12' -Board 'Gigabyte B450' -Now ([datetime]'2026-10-01'))
        ($f | Where-Object { $_.Title -like 'La BIOS tiene*' }).Severity | Should -Be 'Bajo'
    }

    It 'X3D de dos CCD: driver, Game Bar, modo juego y plan Equilibrado' {
        $cpu = Get-JuicerCpuTraits -Name 'AMD Ryzen 9 9950X3D 16-Core Processor' -Vendor 'AuthenticAMD'
        $bad = @(Get-JuicerX3dFindings -Cpu $cpu -Driver $false -GameBar $false -ActivePlan '5f1c7a4e-3b2d-4e8a-9c61-7d0b2a9e4f13' -GameModeOff $true)
        $bad.Count | Should -Be 4
        $good = @(Get-JuicerX3dFindings -Cpu $cpu -Driver $true -GameBar $true -ActivePlan '381b4222-f694-41f0-9685-ff5bb260df2e' -GameModeOff $false)
        $good[0].Severity | Should -Be 'Ok'
        @(Get-JuicerX3dFindings -Cpu (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 9800X3D')).Count | Should -Be 0
    }
}

Describe 'Informe' {
    It 'lo grave primero, luego todo por área, y se guarda legible' {
        $f = @(
            @{ Area = 'Memoria'; Severity = 'Info'; Title = '32 GB'; Detail = '' }
            @{ Area = 'Memoria'; Severity = 'Alto'; Title = 'XMP apagado'; Detail = 'Actívalo.' }
            @{ Area = 'Disco'; Severity = 'Medio'; Title = 'Poco espacio'; Detail = '' }
        )
        $t = Format-JuicerAuditReport @('Procesador: X') $f ([datetime]'2026-10-26 10:00')
        $t | Should -BeLike '*Lo que más rinde arreglar*1. `[ALTO`] XMP apagado*2. `[MEDIO`] Poco espacio*'
        $t | Should -BeLike '*Memoria*`[INFO`] 32 GB*Actívalo.*Disco*'
        $p = Join-Path ([IO.Path]::GetTempPath()) ('wj-informe-' + [guid]::NewGuid().ToString('N') + '.txt')
        try {
            Save-JuicerAuditReport $p @('Procesador: X') $f | Should -Be $p
            $b = [IO.File]::ReadAllBytes($p)
            $b[0] | Should -Be 0xEF
            [IO.File]::ReadAllText($p) | Should -BeLike '*diagnóstico*'
        } finally {
            Remove-Item -LiteralPath $p -ErrorAction SilentlyContinue
        }
    }

    It 'el registro de cambios no crece sin límite' {
        $log = Join-Path (Get-JuicerHome) 'registro.log'
        [IO.File]::WriteAllText($log, ('x' * 1.1MB))
        Write-JuicerLog 'línea nueva'
        (Get-Item -LiteralPath $log).Length | Should -BeLessThan 1KB
        Test-Path -LiteralPath (Join-Path (Get-JuicerHome) 'registro.1.log') | Should -BeTrue
    }
}

Describe 'Programas y red' {
    It 'reconoce software de overclock y antivirus de terceros' {
        $f = @(Get-JuicerSoftwareFindings -Installed @('MSI Afterburner 4.6.6', 'Armoury Crate', '7-Zip') -Antivirus @('Windows Defender', 'McAfee LiveSafe'))
        @($f | ForEach-Object { $_.Title }) | Should -Be @('MSI Afterburner (overclock de GPU)', 'ASUS Armoury Crate', 'Antivirus de terceros: McAfee LiveSafe')
    }

    It 'wifi sin cable, y un cable que enlaza a 100 Mb/s' {
        @(Get-JuicerNetworkFindings @(@{ Name = 'Wi-Fi'; Wireless = $true; LinkSpeed = 866000000 }))[0].Title | Should -Be 'Conectado sólo por wifi'
        @(Get-JuicerNetworkFindings @(@{ Name = 'Ethernet'; Wireless = $false; LinkSpeed = 100000000 }))[0].Severity | Should -Be 'Medio'
        @(Get-JuicerNetworkFindings @(@{ Name = 'Ethernet'; Wireless = $false; LinkSpeed = 1000000000 }))[0].Severity | Should -Be 'Ok'
    }

    It 'distingue impresoras de verdad de las virtuales' {
        Test-JuicerVirtualPrinter 'Microsoft Print to PDF' 'PORTPROMPT:' | Should -BeTrue
        Test-JuicerVirtualPrinter 'OneNote (Desktop)' 'nul:' | Should -BeTrue
        Test-JuicerVirtualPrinter 'Fax' 'SHRFAX:' | Should -BeTrue
        Test-JuicerVirtualPrinter 'HP LaserJet M110we' 'USB001' | Should -BeFalse
        Test-JuicerVirtualPrinter 'EPSON ET-2810 Series' 'WSD-1234' | Should -BeFalse
    }

    It 'sabe si las carpetas del usuario viven en OneDrive' {
        $m = New-FakeMachine
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe' 'DisplayName' 'String' 'Microsoft OneDrive'
        Write-JuicerReg 'HKCU\Software\Microsoft\OneDrive\Accounts\Personal' 'UserFolder' 'String' 'C:\Users\ana\OneDrive'
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' 'Desktop' 'ExpandString' 'C:\Users\ana\OneDrive\Escritorio'
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders' 'Personal' 'ExpandString' '%USERPROFILE%\Documents'
        $s = Get-JuicerOneDriveState
        $s.Installed | Should -BeTrue
        $s.SignedIn | Should -BeTrue
        $s.Kfm | Should -BeTrue
        $s.Folders | Should -Be @('Desktop')
        (Get-JuicerTweakState (Find-JuicerTweak 'apps.onedrive')).State | Should -Be 'NoAplica'
    }
}

Describe 'Consejero' {
    It 'sobremesa Intel híbrido con RTX 40: plan de energía, HAGS y sin limitación' {
        $hw = New-TestHw -Cpu @{ Name = '14th Gen Intel(R) Core(TM) i7-14700K'; Vendor = 'GenuineIntel'; Cores = 20; Threads = 28 } -Gpus @('NVIDIA GeForce RTX 4070')
        $a = Get-JuicerAdvice $hw
        $a['energia.plan'].Verdict | Should -Be 'Recomendado'
        $a['juegos.hags'].Verdict | Should -Be 'Recomendado'
        $a['juegos.hags'].Reason | Should -BeLike '*DLSS*'
        $a['energia.limitacion'].Reason | Should -BeLike '*híbrido*'
        $a['update.drivers'].Verdict | Should -Be 'Recomendado'
        $a['fondo.indexado'].Verdict | Should -Be 'NoRecomendado'
        $a['seguridad.integridad'].Verdict | Should -Be 'Opcional'
    }

    It 'Ryzen X3D de dos CCD: nada de plan sin aparcar núcleos, y Game Bar se queda' {
        $hw = New-TestHw -Cpu @{ Name = 'AMD Ryzen 9 7950X3D 16-Core Processor'; Vendor = 'AuthenticAMD'; Cores = 16; Threads = 32 } -Gpus @('AMD Radeon RX 7900 XTX')
        $a = Get-JuicerAdvice $hw
        $a['energia.plan'].Verdict | Should -Be 'NoRecomendado'
        $a['juegos.modo'].Reason | Should -BeLike '*CCD*'
        @(Get-JuicerRecommendedTweaks $hw | Where-Object { $_.Id -eq 'energia.plan' }).Count | Should -Be 0
        (Get-JuicerAppxNeed (Find-JuicerDebloatApp 'Microsoft.XboxGamingOverlay') $hw) | Should -BeLike '*3D V-Cache*'
    }

    It 'portátil modesto con gráfica integrada y disco duro' {
        $hw = New-TestHw -Cpu @{ Name = 'Intel(R) Core(TM) i5-8250U CPU @ 1.60GHz'; Vendor = 'GenuineIntel'; Cores = 4; Threads = 8 } -Gpus @('Intel(R) UHD Graphics 620') -Ram 8GB -Laptop $true -Disk 'HDD'
        $a = Get-JuicerAdvice $hw
        $a['energia.plan'].Verdict | Should -Be 'NoRecomendado'
        $a['fondo.indexado'].Verdict | Should -Be 'Recomendado'
        $a['ui.transparencia'].Verdict | Should -Be 'Recomendado'
        $a['ui.widgets'].Verdict | Should -Be 'Recomendado'
        $a['juegos.hags'].Verdict | Should -Be 'Opcional'
        $a['privacidad.ubicacion'].Verdict | Should -Be 'Opcional'
        $a['seguridad.integridad'].Verdict | Should -Be 'NoRecomendado'
    }

    It 'impresoras, Insider, Home y WSL cambian el consejo' {
        $hw = New-TestHw -Extra @{ Printers = @('HP LaserJet'); Insider = $true; Home = $true; Wsl = $true }
        $a = Get-JuicerAdvice $hw
        $a['fondo.impresion'].Verdict | Should -Be 'NoRecomendado'
        $a['fondo.telemetria'].Verdict | Should -Be 'NoRecomendado'
        $a['update.diferir'].Verdict | Should -Be 'NoRecomendado'
        $a['seguridad.hipervisor'].Verdict | Should -Be 'NoRecomendado'
    }

    It 'cada ajuste del catálogo tiene un veredicto con su porqué' {
        $a = Get-JuicerAdvice (New-TestHw)
        foreach ($t in (Get-JuicerCatalog)) {
            $a[$t.Id].Verdict | Should -BeIn @('Recomendado', 'Opcional', 'NoRecomendado') -Because $t.Id
            $a[$t.Id].Reason | Should -Not -BeNullOrEmpty -Because $t.Id
        }
    }

    It 'nada de los niveles Rendimiento y Extremo se queda con un consejo genérico' {
        foreach ($hw in (New-TestHw -Gpus @('NVIDIA GeForce RTX 4070')), (New-TestHw -Laptop $true -Ram 8GB -Disk 'HDD')) {
            $a = Get-JuicerAdvice $hw
            foreach ($t in @(Get-JuicerCatalog | Where-Object { $_.Level -ge 2 })) {
                $a[$t.Id].Reason | Should -Not -BeLike 'Depende de cómo uses*' -Because $t.Id
            }
        }
    }

    It 'lo recomendado nunca incluye preferencias, componentes ni el nivel Extremo sin pedirlo' {
        $r = @(Get-JuicerRecommendedTweaks (New-TestHw))
        $r.Count | Should -BeGreaterThan 15
        @($r | Where-Object { $_.Level -eq 0 }).Count | Should -Be 0
        $od = New-TestHw -Extra @{ OneDrive = @{ Installed = $true; SignedIn = $false; Kfm = $false; Folders = @() } }
        (Get-JuicerAdvice $od)['apps.onedrive'].Verdict | Should -Be 'Recomendado'
        @(Get-JuicerRecommendedTweaks $od | Where-Object { $_.Id -eq 'apps.onedrive' }).Count | Should -Be 0
        @($r | Where-Object { $_.Level -eq 3 }).Count | Should -Be 0
    }
}

Describe 'Pantallas, discos y versión de Windows' {
    It 'lee la resolución nativa del EDID' {
        $e = [byte[]]::new(128)
        0..7 | ForEach-Object { $e[$_] = 0xFF }
        $e[0] = 0; $e[7] = 0
        $e[54] = 0x56; $e[55] = 0x5E; $e[56] = 0x00; $e[58] = 0xA0; $e[59] = 0xA0; $e[61] = 0x50
        $n = ConvertFrom-JuicerEdid $e
        $n.Width | Should -Be 2560
        $n.Height | Should -Be 1440
        ConvertFrom-JuicerEdid ([byte[]]::new(128)) | Should -BeNullOrEmpty
        ConvertFrom-JuicerEdid ([byte[]]@(1, 2, 3)) | Should -BeNullOrEmpty
        ConvertTo-JuicerEdidKey '\\?\DISPLAY#GSM5B7F#5&2d3b7a1f&0&UID4353#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}' |
            Should -Be 'HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\GSM5B7F\5&2d3b7a1f&0&UID4353\Device Parameters'
        ConvertTo-JuicerEdidKey '' | Should -BeNullOrEmpty
    }

    It 'avisa si la pantalla está por debajo de su resolución nativa' {
        $d = [pscustomobject]@{ Monitor = 'LG'; Width = 1920; Height = 1080; Hz = 144; MaxHz = 144; NativeWidth = 2560; NativeHeight = 1440; Resolutions = @('1920x1080', '2560x1440') }
        $f = @(Get-JuicerDisplayFindings @($d))
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -BeLike '*1920×1080*2560×1440*'
        # Without the native mode on offer (a cable that cannot carry it), nothing to say about it.
        $d.Resolutions = @('1920x1080')
        @(Get-JuicerDisplayFindings @($d))[0].Severity | Should -Be 'Ok'
    }

    It 'avisa si el monitor de un sobremesa está en la placa base' {
        $gpus = @((Get-JuicerGpuTraits 'NVIDIA GeForce RTX 4070'), (Get-JuicerGpuTraits 'Intel(R) UHD Graphics 770'))
        $main = [pscustomobject]@{ Monitor = 'Dell'; Adapter = 'Intel(R) UHD Graphics 770'; Primary = $true; Width = 1920; Height = 1080; Hz = 60; MaxHz = 60 }
        $side = [pscustomobject]@{ Monitor = 'AOC'; Adapter = 'Intel(R) UHD Graphics 770'; Primary = $false; Width = 1920; Height = 1080; Hz = 60; MaxHz = 60 }
        $good = [pscustomobject]@{ Monitor = 'LG'; Adapter = 'NVIDIA GeForce RTX 4070'; Primary = $true; Width = 1920; Height = 1080; Hz = 60; MaxHz = 60 }
        $f = @(Get-JuicerDisplayFindings @($main) $gpus $false)
        $f[0].Severity | Should -Be 'Alto'
        $f[0].Title | Should -BeLike '*placa base*RTX 4070*'
        @(Get-JuicerDisplayFindings @($side) $gpus $false)[0].Severity | Should -Be 'Info'
        @(Get-JuicerDisplayFindings @($good) $gpus $false | Where-Object { $_.Title -like '*placa base*' }).Count | Should -Be 0
        # A laptop with hybrid graphics draws the screen with the integrated one on purpose.
        @(Get-JuicerDisplayFindings @($main) $gpus $true | Where-Object { $_.Title -like '*placa base*' }).Count | Should -Be 0
        # Without a dedicated card there is nothing else to plug it into.
        @(Get-JuicerDisplayFindings @($main) @($gpus[1]) $false | Where-Object { $_.Title -like '*placa base*' }).Count | Should -Be 0
    }

    It 'revisa desgaste, temperatura y errores de los discos' {
        $f = @(Get-JuicerDiskHealthFindings @(
                @{ Name = 'Samsung 980'; Media = 'SSD'; Health = 'Healthy'; Wear = 93; Temperature = 45; ReadErrors = 0 }
                @{ Name = 'WD SN770'; Media = 'SSD'; Health = 'Healthy'; Wear = 3; Temperature = 78; ReadErrors = 0 }
                @{ Name = 'Seagate'; Media = 'HDD'; Health = 'Healthy'; Wear = 0; Temperature = 0; ReadErrors = 12 }
                @{ Name = 'Kingston'; Media = 'SSD'; Health = 'Warning'; Wear = 100; Temperature = 40; ReadErrors = 0 }
                @{ Name = 'Sin datos'; Media = 'Unspecified'; Health = 'Healthy'; Wear = 0; Temperature = 0; ReadErrors = $null }
            ))
        $f.Title | Should -Contain 'El SSD Samsung 980 ha gastado el 93 % de su vida útil'
        @($f | Where-Object { $_.Title -like '*WD SN770*78 °C*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*WD SN770*3 %*' })[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Title -like '*Seagate*12 lecturas*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*Seagate*vida*' }).Count | Should -Be 0
        @($f | Where-Object { $_.Title -like '*Kingston*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*Sin datos*' }).Count | Should -Be 0
    }

    It 'sabe hasta cuándo tiene parches cada versión y edición' {
        (Get-JuicerWindowsSupport 26100 'Professional').End | Should -Be ([datetime]'2026-10-13')
        (Get-JuicerWindowsSupport 26100 'Enterprise').End | Should -Be ([datetime]'2027-10-12')
        (Get-JuicerWindowsSupport 22631 'Core').Version | Should -Be '23H2'
        (Get-JuicerWindowsSupport 19045 'Professional').Windows10 | Should -BeTrue
        Get-JuicerWindowsSupport 19044 'EnterpriseS' | Should -BeNullOrEmpty
        Get-JuicerWindowsSupport 26100 'ServerStandard' | Should -BeNullOrEmpty
        Get-JuicerWindowsSupport 28000 'Professional' | Should -BeNullOrEmpty
    }

    It 'avisa del fin de soporte, de una versión fijada y del retraso' {
        $now = [datetime]'2026-10-26'
        $old = Get-JuicerWindowsSupport 26100 'Professional'
        $f = @(Get-JuicerSupportFindings $old -Now $now)
        $f[0].Severity | Should -Be 'Alto'
        $f[0].Title | Should -BeLike '*24H2 ya no recibe*'
        @(Get-JuicerSupportFindings $old -Now $now -Pinned '24H2')[0].Detail | Should -BeLike '*TargetReleaseVersion*'
        @(Get-JuicerSupportFindings $old -Now $now -Deferral 365)[0].Detail | Should -BeLike '*365 días*'
        @(Get-JuicerSupportFindings $old -Now ([datetime]'2026-09-01'))[0].Severity | Should -Be 'Medio'
        @(Get-JuicerSupportFindings (Get-JuicerWindowsSupport 26200 'Core') -Now $now)[0].Severity | Should -Be 'Ok'
        @(Get-JuicerSupportFindings (Get-JuicerWindowsSupport 19045 'Core') -Now $now)[0].Title | Should -BeLike 'Windows 10*'
        @(Get-JuicerSupportFindings $null).Count | Should -Be 0
    }

    It 'no aconseja retrasar versiones si la actual se acaba' {
        $hw = New-TestHw -Extra @{ Support = (Get-JuicerWindowsSupport 26100 'Professional') }
        $hw.Support.End = (Get-Date).AddDays(30)
        (Get-JuicerAdvice $hw)['update.diferir'].Verdict | Should -Be 'NoRecomendado'
        $hw.Support.End = (Get-Date).AddDays(500)
        (Get-JuicerAdvice $hw)['update.diferir'].Reason | Should -BeLike '*dos años*'
        $hw.Support.Business = $true
        (Get-JuicerAdvice $hw)['update.diferir'].Verdict | Should -Be 'Opcional'
        (Format-JuicerHardwareSummary $hw) -join "`n" | Should -BeLike '*Windows: 24H2, con parches*'
    }
}

Describe 'Frecuencia variable' {
    It 'la recomienda con pantallas de más de 60 Hz' {
        (Get-JuicerAdvice (New-TestHw -Extra @{ RefreshMax = 165 }))['juegos.vrr'].Verdict | Should -Be 'Recomendado'
        (Get-JuicerAdvice (New-TestHw -Extra @{ RefreshMax = 60 }))['juegos.vrr'].Verdict | Should -Be 'NoRecomendado'
        (Get-JuicerAdvice (New-TestHw))['juegos.vrr'].Verdict | Should -Be 'Opcional'
        # What the monitor's EDID says beats the refresh rate.
        $m = @{ Vrr = @{ Kind = 'FreeSync'; Min = 48; Max = 75 } }
        $a = (Get-JuicerAdvice (New-TestHw -Extra @{ RefreshMax = 75; Monitor = $m }))['juegos.vrr']
        $a.Verdict | Should -Be 'Recomendado'
        $a.Reason | Should -BeLike '*FreeSync*'
    }
}

Describe 'Procesador y memoria juntos' {
    BeforeAll {
        function New-Kit {
            param([string]$Part, [int]$At, [int]$Type = 26, [int]$Jedec = 2133)
            foreach ($slot in 'DIMM_A2', 'DIMM_B2') {
                [pscustomobject]@{ Capacity = 16GB; Speed = $Jedec; ConfiguredClockSpeed = $At; SMBIOSMemoryType = $Type; DeviceLocator = $slot; BankLabel = ''; PartNumber = $Part }
            }
        }
        $script:X3d = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700X3D 8-Core Processor' -Vendor 'AuthenticAMD' -Cores 8 -Threads 16
    }

    It 'un kit de 4000 a 3600 en un Ryzen 5000 está bien elegido, y no pide XMP' {
        $f = @(Get-JuicerRamFindings @(New-Kit 'F4-4000C18-16GVK' 3600) $false $X3d)
        $ok = @($f | Where-Object { $_.Title -like 'Bien elegido*' })
        $ok.Count | Should -Be 1
        $ok[0].Title | Should -BeLike '*kit es de 4000*3600-3800*'
        $ok[0].Detail | Should -BeLike '*FCLK*3D V-Cache*'
        @($f | Where-Object { $_.Title -like '*certificado*' -or $_.Severity -in 'Alto', 'Medio' }).Count | Should -Be 0
    }

    It 'el mismo kit a 4000 en ese Ryzen: que baje a 3600-3800' {
        $f = @(Get-JuicerRamFindings @(New-Kit 'F4-4000C18-16GVK' 4000) $false $X3d)
        $w = @($f | Where-Object { $_.Title -like 'La RAM va a 4000 MT/s: más de lo que rinde*' })
        $w.Count | Should -Be 1
        $w[0].Detail | Should -BeLike '*2:1*3600-3800*'
    }

    It 'sin XMP en ese Ryzen: 3600 a mano, no el XMP de 4000' {
        $w = @(Get-JuicerRamFindings @(New-Kit 'F4-4000C18-16GVK' 2133) $false $X3d | Where-Object { $_.Severity -eq 'Alto' })
        $w[0].Title | Should -BeLike '*lo óptimo es 3600-3800*'
        $w[0].Detail | Should -BeLike '*no actives su XMP tal cual*'
        # A 3600 kit: then XMP is right.
        @(Get-JuicerRamFindings @(New-Kit 'F4-3600C16-16GVKC' 2133) $false $X3d | Where-Object { $_.Title -like '*certificado a 3600*' }).Count | Should -Be 1
    }

    It 'conoce cada plataforma' {
        $am5 = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7800X3D 8-Core Processor' -Vendor 'AuthenticAMD'
        (Get-JuicerMemoryPlan $am5 'DDR5').Target | Should -Be 6000
        @(Get-JuicerRamFindings @(New-Kit 'F5-7200J3445G16GX2-TZ5RK' 7200 34 4800) $false $am5 | Where-Object { $_.Title -like '*7200 MT/s: más de lo que rinde*' }).Count | Should -Be 1
        $apu = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700G with Radeon Graphics' -Vendor 'AuthenticAMD'
        (Get-JuicerMemoryPlan $apu 'DDR4').Max | Should -Be 4400
        @(Get-JuicerRamFindings @(New-Kit 'F4-4000C18-16GVK' 4000) $false $apu | Where-Object { $_.Severity -in 'Alto', 'Medio' }).Count | Should -Be 0
        (Get-JuicerMemoryPlan (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 3600 6-Core Processor' -Vendor 'AuthenticAMD') 'DDR4').Max | Should -Be 3733
        (Get-JuicerMemoryPlan (Get-JuicerCpuTraits -Name '12th Gen Intel(R) Core(TM) i5-12600K' -Vendor 'GenuineIntel') 'DDR4').Why | Should -BeLike '*Gear 1*'
        Get-JuicerMemoryPlan (Get-JuicerCpuTraits -Name '12th Gen Intel(R) Core(TM) i5-12600K' -Vendor 'GenuineIntel') 'DDR5' | Should -BeNullOrEmpty
        Get-JuicerMemoryPlan (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7840HS w/ Radeon 780M Graphics' -Vendor 'AuthenticAMD') 'DDR5' | Should -BeNullOrEmpty
    }

    It 'dice qué ajuste fino admite cada Ryzen' {
        @(Get-JuicerCpuTuningFindings $X3d)[0].Title | Should -BeLike '*no admite overclock, pero sí Curve Optimizer'
        @(Get-JuicerCpuTuningFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7800X3D 8-Core Processor' -Vendor 'AuthenticAMD'))[0].Title | Should -BeLike '*Curve Optimizer, no overclock'
        @(Get-JuicerCpuTuningFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 9800X3D 8-Core Processor' -Vendor 'AuthenticAMD'))[0].Title | Should -BeLike '*PBO completo*'
        @(Get-JuicerCpuTuningFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 7600X 6-Core Processor' -Vendor 'AuthenticAMD'))[0].Title | Should -BeLike '*PBO y Curve Optimizer'
        @(Get-JuicerCpuTuningFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 3600 6-Core Processor' -Vendor 'AuthenticAMD')).Count | Should -Be 0
        @(Get-JuicerCpuTuningFindings (Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i7-13700K' -Vendor 'GenuineIntel')).Count | Should -Be 0
    }
}

Describe 'Combinaciones de hardware' {
    BeforeAll {
        function New-Gpu {
            param([string]$Name, [uint64]$Vram = 8GB)
            $g = Get-JuicerGpuTraits $Name
            $g.Vram = $Vram
            $g
        }
        function New-Cpu { param([string]$Name, [int]$Cores = 6) Get-JuicerCpuTraits -Name $Name -Vendor $(if ($Name -match 'Intel') { 'GenuineIntel' } else { 'AuthenticAMD' }) -Cores $Cores -Threads (2 * $Cores) }
    }

    It 'gráficas de 8 y 4 líneas en PCIe 3.0, por la CPU o por la placa' {
        Get-JuicerPcieLanes 'NVIDIA GeForce RTX 4060 Ti' | Should -Be 8
        Get-JuicerPcieLanes 'AMD Radeon RX 6500 XT' | Should -Be 4
        Get-JuicerPcieLanes 'NVIDIA GeForce RTX 4070' | Should -BeNullOrEmpty

        $apu = New-Cpu 'AMD Ryzen 5 5600G with Radeon Graphics'
        $f = @(Get-JuicerPcieFindings @((New-Gpu 'NVIDIA GeForce RTX 4060')) $apu 'ASUSTeK COMPUTER INC. TUF GAMING B550-PLUS')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -BeLike '*8 líneas*5600G*da como mucho PCIe 3.0'

        $vermeer = New-Cpu 'AMD Ryzen 7 5700X3D 8-Core Processor' 8
        @(Get-JuicerPcieFindings @((New-Gpu 'AMD Radeon RX 6500 XT' 4GB)) $vermeer 'Micro-Star International Co., Ltd. B450 TOMAHAWK MAX')[0].Severity | Should -Be 'Alto'
        # The same processor on a B550 board: PCIe 4.0, nothing to say.
        @(Get-JuicerPcieFindings @((New-Gpu 'NVIDIA GeForce RTX 4060')) $vermeer 'Micro-Star International Co., Ltd. MAG B550 TOMAHAWK').Count | Should -Be 0
        # A full x16 card on 3.0 loses next to nothing.
        @(Get-JuicerPcieFindings @((New-Gpu 'NVIDIA GeForce RTX 3070')) $apu '').Count | Should -Be 0
        # The 5700 and 5500 are APUs without graphics; the 5600 is not; the 8600G gives 4.0.
        Get-JuicerPcie3Reason (New-Cpu 'AMD Ryzen 7 5700 8-Core Processor') '' | Should -Not -BeNullOrEmpty
        Get-JuicerPcie3Reason (New-Cpu 'AMD Ryzen 5 5600 6-Core Processor') '' | Should -BeNullOrEmpty
        Get-JuicerPcie3Reason (New-Cpu 'AMD Ryzen 5 8600G w/ Radeon 760M Graphics') '' | Should -BeNullOrEmpty
        Get-JuicerPcie3Reason (New-Cpu 'Intel(R) Core(TM) i5-10400F CPU @ 2.90GHz') '' | Should -Not -BeNullOrEmpty
        Get-JuicerPcie3Reason (New-Cpu '11th Gen Intel(R) Core(TM) i5-11400F @ 2.60GHz') 'ASUSTeK COMPUTER INC. PRIME Z490-P' | Should -BeNullOrEmpty
        Get-JuicerPcie3Reason (New-Cpu '11th Gen Intel(R) Core(TM) i5-11400F @ 2.60GHz') 'Gigabyte Technology Co., Ltd. H510M H' | Should -Not -BeNullOrEmpty
        # Laptops wire their own lanes.
        @(Get-JuicerPcieFindings @((New-Gpu 'NVIDIA GeForce RTX 4060')) $apu '' $true).Count | Should -Be 0
    }

    It 'la VRAM frente a la resolución del monitor' {
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce RTX 4060 Ti' 8GB)) 3840 2160)[0].Severity | Should -Be 'Medio'
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce RTX 4060 Ti' 8GB)) 2560 1440)[0].Severity | Should -Be 'Info'
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce RTX 2060' 6GB)) 2560 1440)[0].Severity | Should -Be 'Medio'
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce RTX 4060 Ti' 8GB)) 1920 1080).Count | Should -Be 0
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce GTX 1650' 4GB)) 1920 1080)[0].Title | Should -Be 'Sólo 4 GB de VRAM'
        @(Get-JuicerVramFindings @((New-Gpu 'NVIDIA GeForce RTX 4090' 24GB)) 3840 2160).Count | Should -Be 0
        @(Get-JuicerVramFindings @((New-Gpu 'Intel(R) UHD Graphics 770' 128MB)) 3840 2160).Count | Should -Be 0
    }

    It 'APU sin gráfica dedicada: la memoria reservada en la BIOS' {
        $apu = New-Cpu 'AMD Ryzen 7 5700G with Radeon Graphics' 8
        $f = @(Get-JuicerApuFindings @((New-Gpu 'AMD Radeon(TM) Graphics' 512MB)) $apu 16GB)
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -BeLike '*512 MB*'
        $f[0].Detail | Should -BeLike '*UMA Frame Buffer Size*2 o 4 GB*'
        @(Get-JuicerApuFindings @((New-Gpu 'AMD Radeon(TM) Graphics' 4GB)) $apu 32GB)[0].Severity | Should -Be 'Info'
        @(Get-JuicerApuFindings @((New-Gpu 'AMD Radeon(TM) Graphics' 512MB), (New-Gpu 'NVIDIA GeForce RTX 3060')) $apu 16GB).Count | Should -Be 0
        @(Get-JuicerApuFindings @((New-Gpu 'AMD Radeon(TM) Graphics' 512MB)) (New-Cpu 'AMD Ryzen 7 7840HS w/ Radeon 780M Graphics' 8) 16GB).Count | Should -Be 0
    }

    It 'procesador y gráfica desequilibrados' {
        $old = New-Cpu 'Intel(R) Core(TM) i7-8700K CPU @ 3.70GHz'
        $f = @(Get-JuicerBalanceFindings @((New-Gpu 'NVIDIA GeForce RTX 4080 SUPER' 16GB)) $old)
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -BeLike '*4080 SUPER va sobrada para tu*8700K*'
        @(Get-JuicerBalanceFindings @((New-Gpu 'NVIDIA GeForce GTX 1650' 4GB)) (New-Cpu 'AMD Ryzen 7 7800X3D 8-Core Processor' 8))[0].Severity | Should -Be 'Info'
        @(Get-JuicerBalanceFindings @((New-Gpu 'NVIDIA GeForce RTX 4070' 12GB)) (New-Cpu 'AMD Ryzen 5 5600 6-Core Processor')).Count | Should -Be 0
        Get-JuicerGpuTier 'NVIDIA GeForce RTX 4070 Ti SUPER' | Should -Be 4
        Get-JuicerGpuTier 'AMD Radeon RX 6600' | Should -Be 2
        Get-JuicerCpuTier (New-Cpu 'AMD Ryzen 5 2600 Six-Core Processor') | Should -Be 1
    }

    It 'portátil en modo híbrido: dónde se cambia a sólo la dedicada' {
        $gpus = @((Get-JuicerGpuTraits 'NVIDIA GeForce RTX 4070 Laptop GPU'), (Get-JuicerGpuTraits 'AMD Radeon(TM) 780M'))
        $hybrid = @([pscustomobject]@{ Adapter = 'AMD Radeon(TM) 780M'; Primary = $true })
        $f = @(Get-JuicerOptimusFindings $gpus $hybrid $true 'ASUSTeK COMPUTER INC.')
        $f.Count | Should -Be 1
        $f[0].Detail | Should -BeLike '*Armoury Crate (Modo GPU: Ultimate)*'
        @(Get-JuicerOptimusFindings $gpus $hybrid $true 'Alienware')[0].Detail | Should -BeLike '*Alienware Command Center*'
        @(Get-JuicerOptimusFindings $gpus $hybrid $true 'Micro-Star International Co., Ltd.')[0].Detail | Should -BeLike '*MSI Center*'
        @(Get-JuicerOptimusFindings $gpus $hybrid $true 'Clevo')[0].Detail | Should -BeLike '*app de control del fabricante*'
        @(Get-JuicerOptimusFindings $gpus @([pscustomobject]@{ Adapter = 'NVIDIA GeForce RTX 4070 Laptop GPU'; Primary = $true }) $true 'ASUSTeK COMPUTER INC.').Count | Should -Be 0
        @(Get-JuicerOptimusFindings $gpus $hybrid $false 'ASUSTeK COMPUTER INC.').Count | Should -Be 0
    }
}

Describe 'Ajuste fino' {
    BeforeEach { Remove-JuicerTuneRecord }

    It 'da la receta de undervolt de cada procesador' {
        $x3d = Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700X3D 8-Core Processor' -Vendor 'AuthenticAMD'
        $g = Get-JuicerCpuTuneGuide $x3d
        $g.Key | Should -Be 'zen3x3d'
        $g.Steps | Should -BeLike '*-15*-30*-40 mV*'
        (Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7800X3D 8-Core Processor' -Vendor 'AuthenticAMD')).Key | Should -Be 'zen4x3d'
        (Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 9800X3D 8-Core Processor' -Vendor 'AuthenticAMD')).Key | Should -Be 'zen5x3d'
        (Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 7600X 6-Core Processor' -Vendor 'AuthenticAMD')).Key | Should -Be 'zen3plus'
        (Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name 'AMD Ryzen 5 3600 6-Core Processor' -Vendor 'AuthenticAMD')).Key | Should -Be 'zen2older'
        $rpl = Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i7-13700K' -Vendor 'GenuineIntel' -Identifier 'Intel64 Family 6 Model 183 Stepping 1'
        (Get-JuicerCpuTuneGuide $rpl).Steps | Should -BeLike '*0x12B*AC Load Line*'
        Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name '13th Gen Intel(R) Core(TM) i5-13400F' -Vendor 'GenuineIntel') | Should -BeNullOrEmpty
        Get-JuicerCpuTuneGuide (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 7840HS w/ Radeon 780M Graphics' -Vendor 'AuthenticAMD') | Should -BeNullOrEmpty
    }

    It 'y la de cada arquitectura de gráfica, con cómo se aplica en cada inicio' {
        @{ 'NVIDIA GeForce RTX 5070 Ti' = 'blackwell'; 'NVIDIA GeForce RTX 4070 SUPER' = 'ada'; 'NVIDIA GeForce RTX 3080' = 'ampere'
            'NVIDIA GeForce GTX 1660 SUPER' = 'turing'; 'NVIDIA GeForce GTX 1080 Ti' = 'pascal'; 'AMD Radeon RX 9070 XT' = 'rdna4'
            'AMD Radeon RX 7800 XT' = 'rdna3'; 'AMD Radeon RX 6700 XT' = 'rdna2'; 'Intel(R) Arc(TM) B580 Graphics' = 'arc' }.GetEnumerator() | ForEach-Object {
            Get-JuicerGpuArch $_.Key | Should -Be $_.Value -Because $_.Key
        }
        Get-JuicerGpuArch 'AMD Radeon(TM) Graphics' | Should -BeNullOrEmpty
        $a = Get-JuicerGpuTuneGuide 'NVIDIA GeForce RTX 3080'
        $a.Steps | Should -BeLike '*850-900 mV*GDDR6X*'
        $a.Persist | Should -BeLike '*Aplicar overclock al iniciar el sistema*'
        (Get-JuicerGpuTuneGuide 'AMD Radeon RX 7800 XT').Persist | Should -BeLike '*AMD Software*'
        $f = @(Get-JuicerTuneGuideFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700X3D 8-Core Processor' -Vendor 'AuthenticAMD') @((Get-JuicerGpuTraits 'NVIDIA GeForce RTX 4070'), (Get-JuicerGpuTraits 'AMD Radeon(TM) Graphics')) $false)
        $f.Count | Should -Be 3
        $f[0].Detail | Should -BeLike '*BIOS lo guarda y lo aplica en cada arranque*'
        $f[1].Title | Should -BeLike '*RTX 4070 (Ada Lovelace*'
        # On a laptop the BIOS rarely lets you: no CPU recipe.
        @(Get-JuicerTuneGuideFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700X3D 8-Core Processor' -Vendor 'AuthenticAMD') @() $true).Count | Should -Be 0
    }

    It 'recuerda lo aplicado y avisa si la BIOS o la RAM cambian o hay errores' {
        $r = Save-JuicerTuneRecord -Cpu 'Curve Optimizer -30' -Gpu 'curva 900 mV' -GpuTool 'Afterburner' -Bios 'F15 2024-05-01' -RamSpeed 3600
        (Read-JuicerTuneRecord).Cpu | Should -Be 'Curve Optimizer -30'
        $ok = @(Get-JuicerTuneCheckFindings $r 'F15 2024-05-01' 3600 0 0 $true)
        @($ok | Where-Object { $_.Severity -in 'Alto', 'Medio' }).Count | Should -Be 0
        @($ok | Where-Object { $_.Severity -eq 'Ok' }).Count | Should -Be 2
        $bad = @(Get-JuicerTuneCheckFindings $r 'F17 2025-02-10' 2133 3 2 $false)
        @($bad | Where-Object { $_.Title -like 'La BIOS ha cambiado*' })[0].Detail | Should -BeLike '*Curve Optimizer -30*'
        @($bad | Where-Object { $_.Title -like 'La RAM va a 2133*' }).Count | Should -Be 1
        @($bad | Where-Object { $_.Title -like '3 errores*' }).Count | Should -Be 1
        @($bad | Where-Object { $_.Title -like '*reiniciado 2 veces*' }).Count | Should -Be 1
        @($bad | Where-Object { $_.Title -like 'MSI Afterburner no arranca*' }).Count | Should -Be 1
        @(Get-JuicerTuneCheckFindings $null '' 0 0 0 $null).Count | Should -Be 0
        # Once recorded, the guide stops asking to record it.
        @(Get-JuicerTuneGuideFindings (Get-JuicerCpuTraits -Name 'AMD Ryzen 7 5700X3D 8-Core Processor' -Vendor 'AuthenticAMD') @() $false | Where-Object { $_.Title -like 'Apunta*' }).Count | Should -Be 0
    }

    It 'el script que vigila al iniciar sesión es PowerShell válido' {
        $text = Get-JuicerTuneWatchScript "C:\ProgramData\WinJuicer\ajuste-fino.json"
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text | Should -BeLike "*'C:\ProgramData\WinJuicer\ajuste-fino.json'*"
        (Get-JuicerTuneWatchScript "C:\Users\O'Brien\x.json") | Should -BeLike "*'C:\Users\O''Brien\x.json'*"
    }

    It 'desde la línea de órdenes' {
        @(Start-Juicer -ApuntarAjuste -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -ApuntarAjuste -AjusteCpu 'CO -25' -Si 6>$null)[-1] | Should -Be 0
        (Read-JuicerTuneRecord).Cpu | Should -Be 'CO -25'
        @(Start-Juicer -OlvidarAjuste -Si 6>$null)[-1] | Should -Be 0
        Read-JuicerTuneRecord | Should -BeNullOrEmpty
    }
}
