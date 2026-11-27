# Laptop diagnostics: battery health, resume time, what wakes the PC, sleep
# states, hibernate-after-hours, driver age, 8 GB of RAM, Storage Sense and
# the desktop-responsiveness measurement. Every test works on the in-memory
# machine; nothing here needs a laptop or the real Windows tools.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    $script:BatteryXml = @'
<?xml version="1.0" encoding="UTF-8"?>
<BatteryReport xmlns="http://schemas.microsoft.com/battery/2012">
  <ReportInformation>
    <ReportVersion>1.1</ReportVersion>
    <ComputerName>PORTATIL</ComputerName>
  </ReportInformation>
  <Batteries>
    <Battery>
      <Id>DELL 7FR9H55</Id>
      <Manufacturer>SMP</Manufacturer>
      <Chemistry>LION</Chemistry>
      <DesignCapacity>51000</DesignCapacity>
      <FullChargeCapacity>36200</FullChargeCapacity>
      <CycleCount>412</CycleCount>
    </Battery>
  </Batteries>
  <RecentUsage>
    <UsageEntry Timestamp="2026-11-20T10:00:00" Duration="PT10H" Ac="1" />
    <UsageEntry Timestamp="2026-11-20T20:00:00" Duration="PT2H" Ac="0" />
  </RecentUsage>
</BatteryReport>
'@

    # An event as Get-WinEvent hands it back: an id, a time and the XML of its data.
    function New-FakePerfEvent {
        param([int]$Id, [datetime]$Time, [hashtable]$Data)
        $xml = '<Event><EventData>' + ((@($Data.Keys | ForEach-Object { '<Data Name="{0}">{1}</Data>' -f $_, $Data[$_] })) -join '') + '</EventData></Event>'
        $e = [pscustomobject]@{ Id = $Id; TimeCreated = $Time }
        $e | Add-Member -MemberType ScriptMethod -Name ToXml -Value ({ $xml }.GetNewClosure())
        $e
    }

    # The in-memory machine with powercfg's other reports: each key is the first argument of
    # powercfg (/batteryreport writes the XML to the file it is given).
    function Set-FakePowercfg {
        param([hashtable]$Machine, [hashtable]$Reports)
        $orig = $Machine.Backend.State.Run
        $Machine.Backend.State.Run = {
            param($Tool, $Arguments)
            $a = @($Arguments)
            if ($Tool -eq 'powercfg.exe' -and $a.Count -gt 0 -and $Reports.ContainsKey([string]$a[0])) {
                if ($a[0] -eq '/batteryreport') {
                    [IO.File]::WriteAllText($a[-1], $Reports[$a[0]])
                    return [pscustomobject]@{ Code = 0; Output = '' }
                }
                return [pscustomobject]@{ Code = 0; Output = $Reports[$a[0]] }
            }
            & $orig $Tool $Arguments
        }.GetNewClosure()
    }

    $script:LastWakeEn = @'
Wake History Count - 1
Wake History [0]
  Wake Source Count - 1
  Wake Source [0]
    Type: Device
    Instance Path: PCI\VEN_8086&DEV_15BC&SUBSYS_0A171028&REV_21\3&11583659&0&FE
    Friendly Name: Intel(R) Ethernet Connection (4) I219-LM
    Description: Intel(R) Ethernet Connection (4) I219-LM
    Manufacturer: Intel
'@
    $script:LastWakeEs = @'
Recuento de historial de reactivación - 1
Historial de reactivación [0]
  Recuento de orígenes de reactivación - 1
  Origen de reactivación [0]
    Tipo: Dispositivo
    Ruta de acceso de instancia: PCI\VEN_8086&DEV_15BC&SUBSYS_0A171028&REV_21\3&11583659&0&FE
    Nombre descriptivo: Conexión Ethernet Intel(R) (4) I219-LM
    Descripción: Conexión Ethernet Intel(R) (4) I219-LM
    Fabricante: Intel
'@
    $script:TimersEn = @'
Timer set by [SERVICE] \Device\HarddiskVolume3\Windows\system32\svchost.exe (UsoSvc) expires at 3:00:05 AM on 11/27/2026.
  Reason: Windows will execute '\Microsoft\Windows\UpdateOrchestrator\Reboot' scheduled task that requested waking the computer.
'@
    $script:TimersEs = @'
El temporizador establecido por [SERVICE] \Device\HarddiskVolume3\Windows\system32\svchost.exe (UsoSvc) expira a las 3:00:05 el 27/11/2026.
  Motivo: Windows ejecutará la tarea programada '\Microsoft\Windows\UpdateOrchestrator\Reboot' que solicitó reactivar el equipo.
'@
    $script:RequestsEn = @'
DISPLAY:
None.
SYSTEM:
[PROCESS] \Device\HarddiskVolume3\Program Files\Mozilla Firefox\firefox.exe
Playing audio
AWAYMODE:
None.
EXECUTION:
[SERVICE] \Device\HarddiskVolume3\Windows\System32\svchost.exe (CDPSvc)
Una tarea en curso
PERFBOOST:
None.
ACTIVELOCKSCREEN:
None.
'@
    $script:RequestsEs = @'
PANTALLA:
[PROCESS] \Device\HarddiskVolume3\Windows\System32\vlc.exe
Reproduciendo vídeo
SISTEMA:
[PROCESS] \Device\HarddiskVolume3\Program Files\Mozilla Firefox\firefox.exe
Reproduciendo audio
MODO AUSENTE:
Ninguno.
EJECUCIÓN:
Ninguno.
RENDIMIENTO:
Ninguno.
'@
    $script:SleepEn = @'
The following sleep states are available on this system:
    Standby (S3)
    Hibernate
    Fast Startup
The following sleep states are not available on this system:
    Standby (S1)
        The system firmware does not support this standby state.
    Standby (S2)
        The system firmware does not support this standby state.
    Standby (S0 Low Power Idle)
        The system firmware does not support this standby state.
    Hybrid Sleep
        Standby (S3) is not available.
'@
    $script:SleepModernEs = @'
Los siguientes estados de suspensión están disponibles en este sistema:
    Espera (S0 de bajo consumo inactivo) Conectado a la red
    Hibernar
    Inicio rápido
Los siguientes estados de suspensión no están disponibles en este sistema:
    Espera (S1)
        El firmware del sistema no admite este estado de espera.
    Espera (S2)
        El firmware del sistema no admite este estado de espera.
    Espera (S3)
        El firmware del sistema no admite este estado de espera.
    Suspensión híbrida
        Espera (S3) no está disponible.
'@
}

Describe 'Salud de la batería' {
    It 'lee capacidad de diseño, carga completa y ciclos, con el espacio de nombres del informe' {
        $b = ConvertFrom-JuicerBatteryReport $BatteryXml
        $b.Design | Should -Be 51000
        $b.Full | Should -Be 36200
        $b.Cycles | Should -Be 412
        $b.Percent | Should -Be 71
        $b.Count | Should -Be 1
        $b.AcShare | Should -BeGreaterThan 0.83
        $b.AcShare | Should -BeLessThan 0.84
    }

    It 'sin espacio de nombres y sin ciclos también sirve' {
        $b = ConvertFrom-JuicerBatteryReport '<BatteryReport><Batteries><Battery><DesignCapacity>40000</DesignCapacity><FullChargeCapacity>30000</FullChargeCapacity></Battery></Batteries></BatteryReport>'
        $b.Percent | Should -Be 75
        $b.Cycles | Should -BeNullOrEmpty
        $b.AcShare | Should -BeNullOrEmpty
    }

    It 'una batería que no dice sus capacidades no se juzga, y un informe roto no da nada' {
        ConvertFrom-JuicerBatteryReport '<BatteryReport><Batteries><Battery><DesignCapacity>40000</DesignCapacity></Battery></Batteries></BatteryReport>' | Should -BeNullOrEmpty
        ConvertFrom-JuicerBatteryReport '<BatteryReport><Batteries><Battery><DesignCapacity>0</DesignCapacity><FullChargeCapacity>0</FullChargeCapacity></Battery></Batteries></BatteryReport>' | Should -BeNullOrEmpty
        ConvertFrom-JuicerBatteryReport 'esto no es xml <' | Should -BeNullOrEmpty
        ConvertFrom-JuicerBatteryReport '' | Should -BeNullOrEmpty
    }

    It 'suma las capacidades de dos baterías y toma los ciclos más altos' {
        $x = '<R xmlns="urn:x"><Batteries><Battery><DesignCapacity>30000</DesignCapacity><FullChargeCapacity>24000</FullChargeCapacity><CycleCount>100</CycleCount></Battery><Battery><DesignCapacity>20000</DesignCapacity><FullChargeCapacity>16000</FullChargeCapacity><CycleCount>150</CycleCount></Battery></Batteries></R>'
        $b = ConvertFrom-JuicerBatteryReport $x
        $b.Count | Should -Be 2
        $b.Design | Should -Be 50000
        $b.Percent | Should -Be 80
        $b.Cycles | Should -Be 150
    }

    It 'dice el porcentaje y los ciclos como en el ejemplo, en Info' {
        $f = @(Get-JuicerBatteryFindings (ConvertFrom-JuicerBatteryReport $BatteryXml))
        $f.Count | Should -Be 1
        $f[0].Title | Should -Be 'Tu batería conserva el 71 % de su capacidad original (412 ciclos)'
        $f[0].Severity | Should -Be 'Info'
        $f[0].Area | Should -Be 'Portátil'
    }

    It 'por debajo del 60 % es Medio, y sin ciclos no hay paréntesis' {
        $f = @(Get-JuicerBatteryFindings @{ Percent = 48; Cycles = $null; Design = 50000; Full = 24000; AcShare = 0.2 })
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -Be 'Tu batería conserva el 48 % de su capacidad original'
        @(Get-JuicerBatteryFindings @{ Percent = 60; Cycles = 10; Design = 50000; Full = 30000; AcShare = 0.2 })[0].Severity | Should -Be 'Info'
        @(Get-JuicerBatteryFindings $null).Count | Should -Be 0
    }

    It 'sugiere el límite de carga al 80 % sólo si vive enchufado (o si no se sabe), y sólo como texto' {
        $plugged = @(Get-JuicerBatteryFindings (ConvertFrom-JuicerBatteryReport $BatteryXml))[0]
        $plugged.Detail | Should -BeLike '*enchufado*80 %*'
        $unknown = @(Get-JuicerBatteryFindings @{ Percent = 70; Cycles = 1; Design = 1; Full = 1; AcShare = $null })[0]
        $unknown.Detail | Should -BeLike '*Si lo usas casi siempre enchufado*80 %*'
        $mobile = @(Get-JuicerBatteryFindings @{ Percent = 70; Cycles = 1; Design = 1; Full = 1; AcShare = 0.2 })[0]
        $mobile.Detail | Should -Not -BeLike '*80 %*'
        $plugged.Detail | Should -BeLike '*Win Juicer no toca ese ajuste*'
    }

    It 'pide el informe a powercfg dentro de su carpeta y lo borra' {
        $m = New-FakeMachine
        Set-FakePowercfg $m @{ '/batteryreport' = $BatteryXml }
        $b = Get-JuicerBatteryHealth
        $b.Percent | Should -Be 71
        $call = @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /batteryreport /xml /output *' })
        $call.Count | Should -Be 1
        $path = $call[0] -replace '^powercfg\.exe /batteryreport /xml /output ', ''
        $path.StartsWith((Get-JuicerHome)) | Should -BeTrue
        Test-Path -LiteralPath $path | Should -BeFalse
    }

    It 'sin informe (sin batería, o powercfg falla) no hay datos' {
        $m = New-FakeMachine
        Get-JuicerBatteryHealth | Should -BeNullOrEmpty
        $m.Backend.State.Run = { param($Tool, $Arguments) $null = $Tool, $Arguments; [pscustomobject]@{ Code = 1; Output = 'No hay baterías' } }
        Get-JuicerBatteryHealth | Should -BeNullOrEmpty
    }
}

Describe 'Reanudación de la suspensión' {
    It 'lee la duración del evento 300 en milisegundos' {
        $e = New-FakePerfEvent 300 ([datetime]'2026-11-25T08:00:00') @{ ResumeDuration = '3200'; SleepTime = '99' }
        $r = ConvertFrom-JuicerResumeEvent $e
        $r.Ms | Should -Be 3200
        $r.When | Should -Be ([datetime]'2026-11-25T08:00:00')
    }

    It 'con otros nombres de campo toma el que habla de reanudar, y si no hay nada creíble, nada' {
        (ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ ExitLatency = '1800' })).Ms | Should -Be 1800
        (ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ TotalResumeTimeMs = '2500' })).Ms | Should -Be 2500
        ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ Cosa = '5' }) | Should -BeNullOrEmpty
        ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ ResumeDuration = '0' }) | Should -BeNullOrEmpty
        ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ ResumeDuration = '99999999' }) | Should -BeNullOrEmpty
        ConvertFrom-JuicerResumeEvent (New-FakePerfEvent 300 (Get-Date) @{ ResumeDuration = 'abc' }) | Should -BeNullOrEmpty
        ConvertFrom-JuicerResumeEvent $null | Should -BeNullOrEmpty
    }

    It 'la última es la más reciente, y se pide el evento 300 del registro de rendimiento' {
        $now = Get-Date
        $script:Events = @(
            (New-FakePerfEvent 300 $now.AddDays(-9) @{ ResumeDuration = '14000' })
            (New-FakePerfEvent 300 $now.AddDays(-1) @{ ResumeDuration = '2100' })
        )
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @($script:Events) }
        (Get-JuicerLastResume).Ms | Should -Be 2100
        Should -Invoke -ModuleName WinJuicer Get-JuicerEvents -Times 1 -ParameterFilter {
            $Filter.LogName -eq 'Microsoft-Windows-Diagnostics-Performance/Operational' -and @($Filter.Id) -contains 300
        }
    }

    It 'si el registro no se puede leer o está vacío, no hay dato' {
        Mock -ModuleName WinJuicer Get-JuicerEvents { $null }
        Get-JuicerLastResume | Should -BeNullOrEmpty
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @() }
        Get-JuicerLastResume | Should -BeNullOrEmpty
    }

    It 'es Info hasta 10 s y Medio a partir de ahí' {
        $quick = @(Get-JuicerResumeFindings @{ Ms = 3200; When = [datetime]'2026-11-25T08:00:00' })[0]
        $quick.Severity | Should -Be 'Info'
        $quick.Title | Should -BeLike 'La última reanudación tardó 3?2 s*'
        $slow = @(Get-JuicerResumeFindings @{ Ms = 12400; When = [datetime]'2026-11-25T08:00:00' })[0]
        $slow.Severity | Should -Be 'Medio'
        $slow.Title | Should -BeLike 'La última reanudación tardó 12?4 s*'
        @(Get-JuicerResumeFindings $null).Count | Should -Be 0
    }
}

Describe 'Quién despierta al portátil y quién lo mantiene despierto' {
    It 'el último despertar sale igual en inglés y en español: el dispositivo por su nombre' {
        @(ConvertFrom-JuicerLastWake $LastWakeEn) | Should -Be @('Intel(R) Ethernet Connection (4) I219-LM')
        @(ConvertFrom-JuicerLastWake $LastWakeEs) | Should -Be @('Conexión Ethernet Intel(R) (4) I219-LM')
    }

    It 'sin despertares, o con un texto que no se entiende, no sale nada' {
        @(ConvertFrom-JuicerLastWake "Wake History Count - 0").Count | Should -Be 0
        @(ConvertFrom-JuicerLastWake '').Count | Should -Be 0
        @(ConvertFrom-JuicerLastWake 'Access denied.').Count | Should -Be 0
    }

    It 'un despertar por un programa se nombra por su ejecutable' {
        $t = "Wake History [0]`n  Wake Source [0]`n    Type: Wake Timer`n    Owner: [SERVICE] \Device\HarddiskVolume3\Windows\System32\svchost.exe (Schedule)"
        @(ConvertFrom-JuicerLastWake $t) | Should -Be @('svchost.exe')
    }

    It 'los temporizadores dicen la tarea, en los dos idiomas' {
        @(ConvertFrom-JuicerWakeTimers $TimersEn) | Should -Be @('Microsoft\Windows\UpdateOrchestrator\Reboot')
        @(ConvertFrom-JuicerWakeTimers $TimersEs) | Should -Be @('Microsoft\Windows\UpdateOrchestrator\Reboot')
        @(ConvertFrom-JuicerWakeTimers 'There are no active wake timers in the system.').Count | Should -Be 0
        @(ConvertFrom-JuicerWakeTimers 'Timer set by [SERVICE] \Device\HarddiskVolume3\Windows\system32\svchost.exe (UsoSvc) expires at 3:00:05 AM.') | Should -Be @('svchost.exe')
    }

    It 'los temporizadores con la tarea como la escriben Windows 10 y 11 («NT TASK\…») también dicen la tarea' {
        $t = "Timer set by [SERVICE] \Device\HarddiskVolume3\Windows\system32\svchost.exe (SystemEventsBroker) expires at 3:24:22 AM on 1/2/2026.`n  Reason: Windows will execute 'NT TASK\Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Start' scheduled task that requested waking the computer."
        @(ConvertFrom-JuicerWakeTimers $t) | Should -Be @('Microsoft\Windows\UpdateOrchestrator\Universal Orchestrator Start')
        $es = "El temporizador establecido por [SERVICE] \Device\HarddiskVolume3\Windows\system32\svchost.exe (SystemEventsBroker) expira a las 3:24:22 el 02/01/2026.`n  Motivo: Windows ejecutará la tarea programada 'NT TASK\Microsoft\Windows\UpdateOrchestrator\Reboot' que solicitó reactivar el equipo."
        @(ConvertFrom-JuicerWakeTimers $es) | Should -Be @('Microsoft\Windows\UpdateOrchestrator\Reboot')
    }

    It 'las peticiones que impiden suspender son las de Sistema y Ejecución, no las de Pantalla' {
        $en = @(ConvertFrom-JuicerPowerRequests $RequestsEn)
        $en.Count | Should -Be 2
        $en[0].Name | Should -Be 'firefox.exe'
        $en[0].Reason | Should -Be 'Playing audio'
        $en[1].Name | Should -Be 'svchost.exe'
        $es = @(ConvertFrom-JuicerPowerRequests $RequestsEs)
        $es.Count | Should -Be 1
        $es[0].Name | Should -Be 'firefox.exe'
        @($es | Where-Object { $_.Name -eq 'vlc.exe' }).Count | Should -Be 0
    }

    It 'con encabezados en otro idioma se guía por su posición' {
        $t = "AAA:`n[PROCESS] \Device\V\a.exe`nrazón`nBBB:`n[PROCESS] \Device\V\b.exe`nrazón`nCCC:`nNone.`nDDD:`n[PROCESS] \Device\V\d.exe`nrazón`nEEE:`nNone.`nFFF:`nNone."
        @(ConvertFrom-JuicerPowerRequests $t | ForEach-Object { $_.Name }) | Should -Be @('b.exe', 'd.exe')
        @(ConvertFrom-JuicerPowerRequests 'texto suelto sin estructura').Count | Should -Be 0
    }

    It 'lo pide a powercfg y lo enseña como hallazgos del portátil' {
        $m = New-FakeMachine
        Set-FakePowercfg $m @{ '/lastwake' = $LastWakeEn; '/waketimers' = $TimersEn; '/requests' = $RequestsEn }
        $f = @(Get-JuicerWakeFindings (Get-JuicerWakeInfo))
        @($f | Where-Object { $_.Title -eq 'Lo último que despertó al portátil: Intel(R) Ethernet Connection (4) I219-LM' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Un temporizador puede despertar al portátil: Microsoft\Windows\UpdateOrchestrator\Reboot' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -eq 'Impide la suspensión: firefox.exe' }).Count | Should -Be 1
        @($f | Where-Object { $_.Area -ne 'Portátil' }).Count | Should -Be 0
    }

    It 'si powercfg falla, no sale nada' {
        $m = New-FakeMachine
        $m.Backend.State.Run = { param($Tool, $Arguments) $null = $Tool, $Arguments; [pscustomobject]@{ Code = 1; Output = 'Acceso denegado' } }
        @(Get-JuicerWakeFindings (Get-JuicerWakeInfo)).Count | Should -Be 0
    }
}

Describe 'Estados de suspensión' {
    It 'S3 clásico: lo dice en inglés' {
        $s = ConvertFrom-JuicerSleepStates $SleepEn
        $s.S3 | Should -BeTrue
        $s.S0 | Should -BeFalse
    }

    It 'Modern Standby: lo dice en español, con S3 en la lista de los no disponibles' {
        $s = ConvertFrom-JuicerSleepStates $SleepModernEs
        $s.S0 | Should -BeTrue
        $s.S3 | Should -BeFalse
    }

    It 'sin las dos listas no se arriesga' {
        ConvertFrom-JuicerSleepStates 'Los siguientes estados de suspensión están disponibles:' | Should -BeNullOrEmpty
        ConvertFrom-JuicerSleepStates '' | Should -BeNullOrEmpty
    }

    It 'explica en llano lo que usa el portátil, y ofrece el ajuste de hibernar' {
        $modern = @(Get-JuicerSleepFindings (ConvertFrom-JuicerSleepStates $SleepModernEs) @{ Hibernate = $true; FastStartup = $true })[0]
        $modern.Title | Should -BeLike '*Modern Standby*'
        $modern.Severity | Should -Be 'Info'
        $modern.Fix | Should -Be 'energia.hibernar'
        $modern.Detail | Should -BeLike '*Hibernación: disponible*Inicio rápido: activado*'
        $classic = @(Get-JuicerSleepFindings (ConvertFrom-JuicerSleepStates $SleepEn) @{ Hibernate = $false; FastStartup = $false })[0]
        $classic.Title | Should -BeLike '*S3*'
        $classic.Detail | Should -BeLike '*Hibernación: desactivada*'
        @(Get-JuicerSleepFindings $null $null).Count | Should -Be 0
    }

    It 'la hibernación y el inicio rápido se leen del registro' {
        New-FakeMachine | Out-Null
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 1
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 'DWord' 1
        $h = Get-JuicerHibernateState
        $h.Hibernate | Should -BeTrue
        $h.FastStartup | Should -BeTrue
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 0
        (Get-JuicerHibernateState).FastStartup | Should -BeFalse
    }
}

Describe 'Hibernar tras 3 horas de suspensión' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 1
        $idleKey = '381b4222-f694-41f0-9685-ff5bb260df2e|9d7815a6-7ee4-497e-8888-515a05f02364'
        $never = "  Minimum Possible Setting: 0x00000000`n  Maximum Possible Setting: 0xffffffff`n  Current AC Power Setting Index: 0x00000000`n  Current DC Power Setting Index: 0x00000000"
    }

    It 'en un portátil con hibernación escribe 10800 s en el lado de la batería, y deshacer devuelve el valor' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        $m.Fake.Query['HIBERNATEIDLE'] = $never
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')).Outcome | Should -Be 'Aplicado'
        $m.Fake.Dc[$idleKey] | Should -Be '10800'
        $m.Fake.Ac.Count | Should -Be 0
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /setactive*' }).Count | Should -BeGreaterThan 0
        (Get-JuicerTweakState (Find-JuicerTweak 'energia.hibernar')).State | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'energia.hibernar').Outcome | Should -Be 'Deshecho'
        $m.Fake.Dc[$idleKey] | Should -Be '0'
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'si ya hibernaba antes, no hace nada; si lo tenía más largo, lo baja y luego lo devuelve' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        $m.Fake.Query['HIBERNATEIDLE'] = $never -replace '0x00000000$', '0x00001c20'
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')).Outcome | Should -Be 'YaEstaba'
        $m.Fake.Query['HIBERNATEIDLE'] = $never -replace '0x00000000$', '0x00005460'
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')).Outcome | Should -Be 'Aplicado'
        $m.Fake.Dc[$idleKey] | Should -Be '10800'
        [void](Undo-JuicerTweak 'energia.hibernar')
        $m.Fake.Dc[$idleKey] | Should -Be '21600'
    }

    It 'en un sobremesa no aplica y no escribe nada' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        $m.Fake.Query['HIBERNATEIDLE'] = $never
        $r = Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')
        $r.Outcome | Should -Be 'NoAplica'
        $r.Message | Should -BeLike '*portátiles*'
        $m.Fake.Dc.Count | Should -Be 0
    }

    It 'sin hibernación no aplica y explica cómo tenerla' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 0
        $m.Fake.Query['HIBERNATEIDLE'] = $never
        $r = Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')
        $r.Outcome | Should -Be 'NoAplica'
        $r.Message | Should -BeLike '*hibernación*Inicio rápido*'
        $m.Fake.Dc.Count | Should -Be 0
    }

    It 'si powercfg no dice el valor, no aplica' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        (Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar')).Outcome | Should -Be 'NoAplica'
        $m.Fake.Dc.Count | Should -Be 0
    }

    It 'si el plan ya no existe al deshacer, no falla' {
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        $m.Fake.Query['HIBERNATEIDLE'] = $never
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'energia.hibernar'))
        $m.Fake.Plans.Clear()
        (Undo-JuicerTweak 'energia.hibernar').Outcome | Should -Be 'Deshecho'
    }

    It 'es a la carta (nivel 0), reversible, y no toca la hibernación en sí' {
        $t = Find-JuicerTweak 'energia.hibernar'
        $t.Level | Should -Be 0
        $t.What | Should -BeLike '*No desactiva la hibernación*'
        @($m.Backend.State.Calls | Where-Object { $_ -like 'powercfg.exe /hibernate*' }).Count | Should -Be 0
    }
}

Describe 'Antigüedad de los drivers' {
    BeforeAll {
        $script:Today = [datetime]'2026-11-26'
        function New-FakeDriver {
            param([string]$Class, [string]$Name, [string]$Maker = 'Intel Corporation', [string]$Provider = 'Intel', $Date)
            @{ Class = $Class; Name = $Name; Manufacturer = $Maker; Provider = $Provider; Date = $Date; Version = '1.0' }
        }
    }

    It 'un Wi-Fi con más de 36 meses es Bajo, con el enlace de Intel' {
        $f = @(Get-JuicerDriverFindings @(New-FakeDriver 'NET' 'Intel(R) Wi-Fi 6 AX201 160MHz' -Date ([datetime]'2021-01-10')) $Today)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Bajo'
        $f[0].Title | Should -BeLike 'El driver del Wi-Fi*más de 5 años*'
        $f[0].Detail | Should -BeLike '*intel.com*'
    }

    It 'uno reciente, uno de Microsoft (la fecha del propio Windows) y los adaptadores virtuales o por cable no salen' {
        $drivers = @(
            (New-FakeDriver 'NET' 'Intel(R) Wi-Fi 6 AX201 160MHz' -Date ([datetime]'2025-06-01'))
            (New-FakeDriver 'NET' 'Realtek 8822CE Wireless LAN 802.11ac PCI-E NIC' -Maker 'Microsoft' -Provider 'Microsoft' -Date ([datetime]'2006-06-21'))
            (New-FakeDriver 'NET' 'Microsoft Wi-Fi Direct Virtual Adapter' -Date ([datetime]'2015-01-01'))
            (New-FakeDriver 'NET' 'Intel(R) Ethernet Connection I219-LM' -Date ([datetime]'2015-01-01'))
            (New-FakeDriver 'NET' 'WAN Miniport (IP)' -Date ([datetime]'2015-01-01'))
        )
        @(Get-JuicerDriverFindings $drivers $Today).Count | Should -Be 0
    }

    It 'un Wi-Fi que no es de Intel manda a la web del portátil' {
        $f = @(Get-JuicerDriverFindings @(New-FakeDriver 'NET' 'Realtek 8822CE Wireless LAN 802.11ac PCI-E NIC' -Maker 'Realtek' -Provider 'Realtek' -Date ([datetime]'2019-03-01')) $Today)
        $f.Count | Should -Be 1
        $f[0].Detail | Should -BeLike '*web de soporte de tu portátil*'
    }

    It 'el chipset se juzga por su driver más reciente: si ése es viejo, avisa' {
        $old = @(
            (New-FakeDriver 'SYSTEM' 'Intel(R) Management Engine Interface' -Date ([datetime]'2020-02-01'))
            (New-FakeDriver 'SYSTEM' 'Intel(R) Serial IO I2C Host Controller' -Date ([datetime]'2018-02-01'))
        )
        $f = @(Get-JuicerDriverFindings $old $Today)
        $f.Count | Should -Be 1
        $f[0].Title | Should -BeLike 'El driver del chipset*'
        $f[0].Severity | Should -Be 'Bajo'
        $mixed = $old + @(New-FakeDriver 'SYSTEM' 'Intel(R) PCI Express Root Port' -Date ([datetime]'2025-01-01'))
        @(Get-JuicerDriverFindings $mixed $Today).Count | Should -Be 0
    }

    It 'la gráfica no se repite aquí: tiene su propio aviso en Gráfica' {
        $gpu = @(
            (New-FakeDriver 'DISPLAY' 'Microsoft Basic Display Adapter' -Maker 'Microsoft' -Provider 'Microsoft' -Date ([datetime]'2006-06-21'))
            (New-FakeDriver 'DISPLAY' 'Intel(R) UHD Graphics 620' -Date ([datetime]'2018-01-01'))
        )
        @(Get-JuicerDriverFindings $gpu $Today).Count | Should -Be 0
    }

    It 'lee los drivers del backend, y sin lectura no rompe' {
        $m = New-FakeMachine
        [void]$m.Backend.State.Drivers.Add((New-FakeDriver 'NET' 'Intel(R) Wi-Fi 6 AX201 160MHz' -Date ([datetime]'2019-01-01')))
        @(Get-JuicerPnpDrivers).Count | Should -Be 1
        $m.Backend.Remove('Drivers')
        @(Get-JuicerPnpDrivers).Count | Should -Be 0
    }
}

Describe 'Portátiles con 8 GB de RAM' {
    It 'da consejos concretos y enlaza al arranque; la compresión activa se respeta' {
        $f = @(Get-JuicerLowRamFindings 8GB @{ Compression = $true; CommitPct = 60 } 9)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Info'
        $f[0].Detail | Should -BeLike '*Pestañas en suspensión*'
        $f[0].Detail | Should -BeLike '*Ahorro de memoria*'
        $f[0].Detail | Should -BeLike '*9 programas*Arranque*'
        $f[0].Detail | Should -BeLike '*Win Juicer no la apaga*'
    }

    It 'con la memoria comprometida por encima del 85 % es Medio' {
        $f = @(Get-JuicerLowRamFindings 8GB @{ Compression = $true; CommitPct = 91.4 } -1)
        @($f | Where-Object { $_.Severity -eq 'Medio' }).Count | Should -Be 1
        @($f | Where-Object { $_.Severity -eq 'Medio' })[0].Title | Should -BeLike 'La memoria comprometida está al 91*'
        @(Get-JuicerLowRamFindings 8GB @{ Compression = $true; CommitPct = 85 } -1 | Where-Object { $_.Severity -eq 'Medio' }).Count | Should -Be 0
    }

    It 'si la compresión está apagada lo dice, pero nunca la apaga' {
        $f = @(Get-JuicerLowRamFindings 8GB @{ Compression = $false; CommitPct = 50 } -1)
        @($f | Where-Object { $_.Title -like '*compresión de memoria está desactivada*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Detail -like '*Reactivar la compresión de memoria*' }).Count | Should -Be 1
    }

    It 'con más de 8 GB, o sin saber la RAM, no dice nada; lo desconocido no cuenta' {
        @(Get-JuicerLowRamFindings 16GB @{ Compression = $true; CommitPct = 99 } 3).Count | Should -Be 0
        @(Get-JuicerLowRamFindings 0 @{ Compression = $true; CommitPct = 99 } 3).Count | Should -Be 0
        @(Get-JuicerLowRamFindings 8GB $null -1).Count | Should -Be 1
        @(Get-JuicerLowRamFindings 8GB @{ Compression = $null; CommitPct = $null } -1).Count | Should -Be 1
    }

    It 'el estado sale del backend' {
        $m = New-FakeMachine
        $m.Backend.State.MemoryState = @{ Compression = $true; CommitPct = 40.0 }
        (Get-JuicerMemoryState).CommitPct | Should -Be 40
        $m.Backend.Remove('MemoryState')
        Get-JuicerMemoryState | Should -BeNullOrEmpty
    }
}

Describe 'Sensor de almacenamiento' {
    BeforeEach {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $policyPath = 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    }

    It 'lee el interruptor «01»; sin él, no sabe' {
        Get-JuicerStorageSenseState | Should -BeNullOrEmpty
        Write-JuicerReg $policyPath '01' 'DWord' 0
        Get-JuicerStorageSenseState | Should -BeFalse
        Write-JuicerReg $policyPath '01' 'DWord' 1
        Get-JuicerStorageSenseState | Should -BeTrue
    }

    It 'sugiere activarlo sólo con poco espacio y el interruptor apagado' {
        $f = @(Get-JuicerStorageSenseFinding -Low $true -State $false -Drive 'C:')
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Bajo'
        $f[0].Fix | Should -Be 'disco.sensor'
        @(Get-JuicerStorageSenseFinding -Low $false -State $false).Count | Should -Be 0
        @(Get-JuicerStorageSenseFinding -Low $true -State $true).Count | Should -Be 0
        @(Get-JuicerStorageSenseFinding -Low $true -State $null).Count | Should -Be 0
    }

    It 'el ajuste sólo pone el interruptor general, y deshacer lo quita' {
        $before = Get-MachineSnapshot $m
        (Invoke-JuicerTweak (Find-JuicerTweak 'disco.sensor')).Outcome | Should -Be 'Aplicado'
        (Read-JuicerReg $policyPath '01').Value | Should -Be 1
        $values = @(Get-JuicerRegValueNames $policyPath)
        $values | Should -Be @('01')
        (Undo-JuicerTweak 'disco.sensor').Outcome | Should -Be 'Deshecho'
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'si estaba apagado explícitamente, lo enciende y lo devuelve a apagado' {
        Write-JuicerReg $policyPath '01' 'DWord' 0
        (Invoke-JuicerTweak (Find-JuicerTweak 'disco.sensor')).Outcome | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'disco.sensor').Outcome | Should -Be 'Deshecho'
        (Read-JuicerReg $policyPath '01').Value | Should -Be 0
    }

    It 'si una directiva lo desactiva, no aplica' {
        Write-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Windows\StorageSense' 'AllowStorageSenseGlobal' 'DWord' 0
        $r = Invoke-JuicerTweak (Find-JuicerTweak 'disco.sensor')
        $r.Outcome | Should -Be 'NoAplica'
        Read-JuicerReg $policyPath '01' | Should -BeNullOrEmpty
    }

    It 'avisa de su relación con la fecha de último acceso' {
        (Find-JuicerTweak 'disco.sensor').Cost | Should -BeLike '*último acceso*'
    }
}

Describe 'Fluidez del escritorio y medidas de portátil' {
    BeforeEach { Remove-Item -LiteralPath (Get-JuicerMetricsPath) -ErrorAction SilentlyContinue }

    It 'la mediana de tres, de dos y de ninguna' {
        Get-JuicerMedian @(300, 100, 200) | Should -Be 200
        Get-JuicerMedian @(100, 300) | Should -Be 200
        Get-JuicerMedian @() | Should -BeNullOrEmpty
    }

    It 'compara la fluidez cuando la fuente de energía es la misma' {
        $b = @{ Date = '2026-11-01T10:00:00'; Label = 'Antes'; PowerSource = 'AC'; ExplorerMs = 900; NotepadMs = 400 }
        $a = @{ Date = '2026-11-02T10:00:00'; Label = 'Medida'; PowerSource = 'AC'; ExplorerMs = 700; NotepadMs = 420 }
        $f = @(Compare-JuicerMetrics $b $a)
        $ex = @($f | Where-Object { $_.Title -like 'Abrir una ventana del Explorador:*' })
        $ex.Count | Should -Be 1
        $ex[0].Title | Should -BeLike '*900 ms → 700 ms*200 ms)'
        $ex[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Title -like 'Abrir el Bloc de notas:*' })[0].Severity | Should -Be 'Info'
    }

    It 'no compara la fluidez entre fuentes de energía distintas, y lo dice' {
        $b = @{ Date = '2026-11-01T10:00:00'; Label = 'Antes'; PowerSource = 'AC'; ExplorerMs = 900; NotepadMs = 400 }
        $a = @{ Date = '2026-11-02T10:00:00'; Label = 'Medida'; PowerSource = 'DC'; ExplorerMs = 1500; NotepadMs = 700 }
        $f = @(Compare-JuicerMetrics $b $a)
        @($f | Where-Object { $_.Title -like 'Abrir*' }).Count | Should -Be 0
        $note = @($f | Where-Object { $_.Title -like '*otra fuente de energía*' })
        $note.Count | Should -Be 1
        $note[0].Detail | Should -BeLike '*enchufado*con batería*'
        # Without the source recorded, nothing guarantees it is fair either.
        $b.Remove('PowerSource')
        $a.PowerSource = 'AC'
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like 'Abrir*' }).Count | Should -Be 0
    }

    It 'si la medida inicial no tiene fluidez, lo dice una vez' {
        $b = @{ Date = '2026-11-01T10:00:00'; Label = 'Antes'; PowerSource = 'AC' }
        $a = @{ Date = '2026-11-02T10:00:00'; Label = 'Medida'; PowerSource = 'AC'; ExplorerMs = 700 }
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like '*no incluye la fluidez*' }).Count | Should -Be 1
        @(Compare-JuicerMetrics $b $b | Where-Object { $_.Title -like '*no incluye la fluidez*' }).Count | Should -Be 0
    }

    It 'compara la reanudación (sólo si es otro evento) y la salud de la batería' {
        $b = @{ Date = '2026-11-01T10:00:00'; Label = 'Antes'; ResumeMs = 4000; ResumeDate = '2026-10-30T08:00:00'; BatteryPct = 71 }
        $a = @{ Date = '2026-11-20T10:00:00'; Label = 'Medida'; ResumeMs = 2800; ResumeDate = '2026-11-19T08:00:00'; BatteryPct = 68 }
        $f = @(Compare-JuicerMetrics $b $a)
        @($f | Where-Object { $_.Title -like 'Última reanudación de la suspensión:*' })[0].Severity | Should -Be 'Ok'
        $bat = @($f | Where-Object { $_.Title -like 'Salud de la batería:*' })[0]
        $bat.Severity | Should -Be 'Bajo'
        $bat.Title | Should -BeLike '*71 % → 68 %*'
        $a.ResumeDate = '2026-10-30T08:00:00'
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like 'Última reanudación*' }).Count | Should -Be 0
    }

    It 'la medida de un portátil guarda la batería y la última reanudación' {
        $m = New-FakeMachine
        Set-FakePowercfg $m @{ '/batteryreport' = $BatteryXml }
        $script:Events = @(New-FakePerfEvent 300 ([datetime]'2026-11-25T08:00:00') @{ ResumeDuration = '3200' })
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @($script:Events) }
        $l = Get-JuicerLaptopMetrics
        $l.BatteryPct | Should -Be 71
        $l.ResumeMs | Should -Be 3200
        $l.ResumeDate | Should -BeLike '2026-11-25T08:00:00*'
    }

    It 'un sobremesa no guarda nada de portátil' {
        New-FakeMachine | Out-Null
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        (Get-JuicerLaptopMetrics).Count | Should -Be 0
    }

    It 'la fuente de energía sale del estado de la batería: AC o DC' {
        $m = New-FakeMachine
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 4 -Percent 20
        Get-JuicerPowerSource | Should -Be 'DC'
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 1 -BatteryFlag 8 -Percent 90
        Get-JuicerPowerSource | Should -Be 'AC'
    }

    It 'la prueba sale del backend y la medida la guarda con su fuente de energía' {
        if (-not (Test-JuicerWindows)) { Set-ItResult -Skipped -Because 'la medida sólo lee la máquina en Windows'; return }
        $m = New-FakeMachine
        $m.Backend.State.Power = ConvertFrom-JuicerPowerStatus -AcLine 0 -BatteryFlag 4 -Percent 55
        $m.Backend.State.Responsiveness = @{ ExplorerMs = 820; NotepadMs = 310 }
        Mock -ModuleName WinJuicer Get-JuicerEvents { $null }
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        @(Invoke-JuicerMeasure -Reset)[0].Title | Should -Be 'Medida inicial guardada'
        $saved = @(Read-JuicerMetrics)[0]
        $saved.ExplorerMs | Should -Be 820
        $saved.NotepadMs | Should -Be 310
        $saved.PowerSource | Should -Be 'DC'
    }

    It 'una medida sin la prueba (la que se hace sola antes del primer cambio) no abre ventanas' {
        if (-not (Test-JuicerWindows)) { Set-ItResult -Skipped -Because 'la medida sólo lee la máquina en Windows'; return }
        $m = New-FakeMachine
        $m.Backend.State.Responsiveness = @{ ExplorerMs = 820; NotepadMs = 310 }
        Mock -ModuleName WinJuicer Get-JuicerEvents { $null }
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        $x = Get-JuicerMetrics
        $x.ContainsKey('ExplorerMs') | Should -BeFalse
    }

    It 'el backend de Windows tiene todo lo nuevo, y el de memoria también' {
        $m = New-FakeMachine
        foreach ($k in 'Drivers', 'MemoryState', 'Responsiveness') {
            $m.Backend.ContainsKey($k) | Should -BeTrue -Because $k
            (New-JuicerWindowsBackend).ContainsKey($k) | Should -BeTrue -Because $k
        }
        Invoke-JuicerResponsiveness | Should -BeNullOrEmpty
    }
}

Describe 'La sección Portátil del diagnóstico' {
    It 'en un sobremesa no sale nada' {
        New-FakeMachine | Out-Null
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $false }
        @(Get-JuicerLaptopAudit).Count | Should -Be 0
    }

    It 'en un portátil junta batería, reanudación, despertares, suspensión, drivers y RAM' {
        $m = New-FakeMachine
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 'DWord' 1
        Set-FakePowercfg $m @{ '/batteryreport' = $BatteryXml; '/lastwake' = $LastWakeEn; '/waketimers' = $TimersEn; '/requests' = $RequestsEn; '/a' = $SleepEn }
        [void]$m.Backend.State.Drivers.Add(@{ Class = 'NET'; Name = 'Intel(R) Wi-Fi 6 AX201 160MHz'; Manufacturer = 'Intel Corporation'; Provider = 'Intel'; Version = '1'; Date = (Get-Date).AddYears(-5) })
        $m.Backend.State.MemoryState = @{ Compression = $true; CommitPct = 90 }
        $script:Events = @(New-FakePerfEvent 300 (Get-Date).AddDays(-1) @{ ResumeDuration = '12000' })
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @($script:Events) }
        Mock -ModuleName WinJuicer Get-JuicerHardwareProfile { @{ RamBytes = [int64]8GB } }
        Mock -ModuleName WinJuicer Get-JuicerStartupItems { @() }
        $f = @(Get-JuicerLaptopAudit)
        @($f | Where-Object { $_.Title -like 'Tu batería conserva el 71 %*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'La última reanudación tardó*' -and $_.Severity -eq 'Medio' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Lo último que despertó*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Impide la suspensión*' }).Count | Should -Be 2
        @($f | Where-Object { $_.Title -like '*S3*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'El driver del Wi-Fi*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'La memoria comprometida*' -and $_.Severity -eq 'Medio' }).Count | Should -Be 1
    }

    It 'si todo falla, no rompe y no inventa' {
        $m = New-FakeMachine
        $m.Backend.State.Run = { param($Tool, $Arguments) $null = $Tool, $Arguments; [pscustomobject]@{ Code = 1; Output = '' } }
        Mock -ModuleName WinJuicer Test-JuicerLaptop { $true }
        Mock -ModuleName WinJuicer Get-JuicerEvents { $null }
        Mock -ModuleName WinJuicer Get-JuicerHardwareProfile { @{ RamBytes = [int64]16GB } }
        { Get-JuicerLaptopAudit } | Should -Not -Throw
        @(Get-JuicerLaptopAudit).Count | Should -Be 0
    }

    It 'es una de las partes del diagnóstico' {
        $src = Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'src/Audit.ps1') -Raw
        $src | Should -BeLike "*@('Portátil', `${function:Get-JuicerLaptopAudit})*"
    }
}
