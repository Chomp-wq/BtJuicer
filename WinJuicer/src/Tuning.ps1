# The hardware review: what is set wrong below Windows, or right at its edge.
# A BIOS with a known flaw, an overclock that is already throwing errors, a
# power plan quietly capping the processor, a graphics card in the wrong
# slot. Win Juicer cannot change any of that from Windows, but Windows keeps
# the evidence: event logs, the power plan, the firmware date and the
# microcode revision. Like the rest of the diagnosis, this changes nothing.

$script:BalancedPlan = '381b4222-f694-41f0-9685-ff5bb260df2e'
$script:PowerSaverPlan = 'a1841308-3541-4fab-bc81-f71556f20b4a'

# --- Pure pieces -------------------------------------------------------------

# powercfg /qh for one setting. Whatever the language, the last two
# hexadecimal numbers are the plugged-in and on-battery values.
function ConvertFrom-JuicerPowerSetting {
    param([string]$Text)
    $hex = @([regex]::Matches([string]$Text, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    if ($hex.Count -lt 2) { return $null }
    @{ AC = $hex[-2]; DC = $hex[-1] }
}

function Get-JuicerPowerCapFindings {
    param($MaxState, $Boost, [string]$ActivePlan = '')
    $area = 'Overclock y BIOS'
    $out = @()
    if ($ActivePlan -eq $script:PowerSaverPlan) {
        $out += New-JuicerFinding $area 'Medio' 'El plan de energía activo es «Economizador»' 'Limita el procesador para ahorrar energía, también enchufado. Elige «Equilibrado» o el plan de Win Juicer.' 'energia.plan'
    }
    if ($MaxState -and $MaxState.AC -lt 100) {
        $out += New-JuicerFinding $area 'Alto' "El plan de energía limita el procesador al $($MaxState.AC) % enchufado" 'Alguien bajó el «Estado máximo del procesador», a veces para bajar temperaturas. El procesador nunca llega a su frecuencia máxima. Súbelo a 100 % en Opciones de energía > Configuración avanzada, o aplica el plan de Win Juicer.' 'energia.plan'
    }
    if ($Boost -and $Boost.AC -eq 0) {
        $out += New-JuicerFinding $area 'Alto' 'El turbo del procesador está desactivado en el plan de energía' 'El procesador se queda en su frecuencia base: en juegos, fácilmente un 20-40 % menos. Si se hizo para bajar temperatura o ruido, es mejor un límite de potencia en la BIOS o un undervolt, que cuestan mucho menos rendimiento.' 'energia.plan'
    }
    if ($out.Count -eq 0 -and ($MaxState -or $Boost)) {
        $out += New-JuicerFinding $area 'Ok' 'El plan de energía no limita el procesador'
    }
    $out
}

# The stop codes that point at hardware or an overclock, with the usual
# suspect in plain words. Codes with 0x10000000 set are the same stop.
$script:Bugchecks = @{
    0x0A  = @('IRQL_NOT_LESS_OR_EQUAL', 'un driver defectuoso o RAM inestable')
    0x19  = @('BAD_POOL_HEADER', 'un driver o RAM inestable')
    0x1A  = @('MEMORY_MANAGEMENT', 'RAM inestable (XMP/EXPO, timings) o un módulo defectuoso')
    0x1E  = @('KMODE_EXCEPTION_NOT_HANDLED', 'un driver o RAM inestable')
    0x3B  = @('SYSTEM_SERVICE_EXCEPTION', 'un driver o RAM inestable')
    0x50  = @('PAGE_FAULT_IN_NONPAGED_AREA', 'RAM inestable o un driver')
    0x7E  = @('SYSTEM_THREAD_EXCEPTION_NOT_HANDLED', 'un driver')
    0x7F  = @('UNEXPECTED_KERNEL_MODE_TRAP', 'overclock o hardware defectuoso')
    0x9F  = @('DRIVER_POWER_STATE_FAILURE', 'un driver al suspender o reanudar')
    0xC2  = @('BAD_POOL_CALLER', 'un driver')
    0xD1  = @('DRIVER_IRQL_NOT_LESS_OR_EQUAL', 'un driver, a menudo el de red o el de la gráfica')
    0xEF  = @('CRITICAL_PROCESS_DIED', 'archivos de sistema dañados (Mantenimiento > Reparar) o el disco')
    0x101 = @('CLOCK_WATCHDOG_TIMEOUT', 'un núcleo dejó de responder: overclock o undervolt del procesador inestable')
    0x109 = @('CRITICAL_STRUCTURE_CORRUPTION', 'RAM inestable o un programa que modifica el núcleo')
    0x116 = @('VIDEO_TDR_FAILURE', 'la gráfica dejó de responder: overclock de GPU, temperatura o driver')
    0x117 = @('VIDEO_TDR_TIMEOUT_DETECTED', 'la gráfica dejó de responder: overclock de GPU, temperatura o driver')
    0x124 = @('WHEA_UNCORRECTABLE_ERROR', 'error de hardware: overclock o undervolt inestable, voltajes o temperatura')
    0x133 = @('DPC_WATCHDOG_VIOLATION', 'un driver, o el firmware del SSD')
    0x139 = @('KERNEL_SECURITY_CHECK_FAILURE', 'un driver o RAM inestable')
    0x154 = @('UNEXPECTED_STORE_EXCEPTION', 'el disco o la RAM')
}

function Get-JuicerBugcheckInfo {
    param([int64]$Code)
    $c = $Code -band 0x0FFFFFFF
    $hit = $script:Bugchecks[[int]$c]
    if ($hit) { return @{ Code = $c; Name = $hit[0]; Cause = $hit[1] } }
    @{ Code = $c; Name = ('0x{0:X}' -f $c); Cause = 'causa variada' }
}

# The first stop code in a «The computer has rebooted from a bugcheck» event,
# in whatever language.
function ConvertFrom-JuicerBugcheckText {
    param([string]$Text)
    if ($Text -match '0x([0-9a-fA-F]{8})') { return [Convert]::ToInt64($Matches[1], 16) }
    $null
}

function Get-JuicerStabilityFindings {
    param([hashtable]$Whea = @{}, [object[]]$Bugchecks = @(), [int]$Unexpected = 0, [int]$Tdr = 0, [int]$Throttle = 0, [bool]$MemoryOc = $false)
    $area = 'Estabilidad'
    $out = @()
    $w = @{}
    foreach ($id in 17, 18, 19, 47) { $w[$id] = [int]$Whea[$id] }
    if ($w[18] -gt 0) {
        $out += New-JuicerFinding $area 'Alto' "$($w[18]) errores de hardware fatales (WHEA 18) en 30 días" 'Errores del procesador o de la memoria que Windows no pudo corregir: el equipo se reinició. Casi siempre es un overclock o undervolt inestable (PBO o Curve Optimizer, XMP/EXPO, voltajes bajados). Carga los valores por defecto de la BIOS y vuelve a aplicar tus ajustes uno a uno.'
    }
    if ($w[19] -gt 0) {
        $sev = if ($w[19] -ge 10) { 'Alto' } else { 'Medio' }
        $out += New-JuicerFinding $area $sev "$($w[19]) errores del procesador corregidos (WHEA 19) en 30 días" 'Windows los corrigió sin que lo notaras, pero son el aviso previo de una inestabilidad: Curve Optimizer o undervolt demasiado agresivo, o en Ryzen un Infinity Fabric (FCLK) demasiado alto.'
    }
    if ($w[47] -gt 0) {
        $out += New-JuicerFinding $area 'Alto' "$($w[47]) errores de memoria corregidos (WHEA 47) en 30 días" 'La RAM está trabajando al límite: baja un escalón el XMP/EXPO, relaja los timings o sube un poco el voltaje de la memoria.'
    }
    if ($w[17] -gt 0) {
        $out += New-JuicerFinding $area 'Medio' "$($w[17]) errores de PCIe corregidos (WHEA 17) en 30 días" 'Suelen venir de un cable riser de la gráfica, de la ranura, o del ahorro de energía del enlace. Si usas riser, fija esa ranura a PCIe 4.0 o 3.0 en la BIOS.'
    }

    $stops = @($Bugchecks | Where-Object { $null -ne $_ })
    if ($stops.Count -gt 0) {
        $kinds = @($stops | ForEach-Object { Get-JuicerBugcheckInfo $_ } | Group-Object { $_.Code } | Sort-Object Count -Descending | ForEach-Object {
                $i = $_.Group[0]
                '{0} ×{1}: {2}' -f $i.Name, $_.Count, $i.Cause
            })
        $out += New-JuicerFinding $area 'Alto' "$($stops.Count) pantallazos azules en 30 días" (($kinds -join '. ') + '. Si tienes overclock, undervolt o XMP/EXPO, es lo primero que hay que descartar.')
    }
    $silent = $Unexpected - $stops.Count
    if ($silent -ge 2) {
        $out += New-JuicerFinding $area 'Medio' "$silent apagados inesperados sin pantallazo en 30 días" 'Cortes de luz o el botón de encendido aparte, suele ser una fuente de alimentación al límite o un overclock de CPU o GPU tan inestable que no llega ni a escribir el volcado.'
    }
    if ($Tdr -gt 0) {
        $out += New-JuicerFinding $area 'Medio' "El driver de la gráfica se colgó y se recuperó $Tdr veces en 30 días" 'La pantalla se va a negro unos segundos y el juego se cierra. Suele ser un overclock de GPU inestable (Afterburner o el programa del fabricante), temperatura, o el driver: prueba sin overclock y, si sigue, reinstala el driver limpio con DDU.'
    }
    if ($Throttle -gt 0) {
        $out += New-JuicerFinding $area 'Medio' "El firmware frenó el procesador $Throttle veces en 7 días" 'Windows registra cada vez que la BIOS limita la velocidad del procesador: por temperatura o por límites de potencia. Revisa la refrigeración (polvo, pasta térmica, curva de ventiladores); en portátiles, el modo de rendimiento del programa del fabricante.'
    }
    if ($out.Count -eq 0) {
        $detail = if ($MemoryOc) { 'Tu XMP/EXPO y cualquier overclock que tengas parecen estables.' } else { '' }
        $out += New-JuicerFinding $area 'Ok' 'Sin errores de hardware, pantallazos ni cuelgues de la gráfica en 30 días' $detail
    }
    $out
}

function Get-JuicerFirmwareFindings {
    param([hashtable]$Cpu = @{}, $BiosDate = $null, [string]$BiosVersion = '', [string]$Board = '', [string]$TpmVendor = '', [bool]$Laptop = $false, [datetime]$Now = (Get-Date))
    $area = 'Overclock y BIOS'
    $out = @()
    $when = if ($BiosDate) { ' del ' + ([datetime]$BiosDate).ToString('d') } else { '' }
    if ($Board -or $BiosVersion) { $out += New-JuicerFinding $area 'Info' ("{0}BIOS {1}{2}" -f $(if ($Board) { "$Board, " } else { '' }), $BiosVersion, $when) }

    if ($Cpu.RaptorLake) {
        $fix = 'Los Core de 13.ª y 14.ª generación de sobremesa se degradan con el tiempo por voltajes demasiado altos: primero cuelgues en juegos y al descomprimir, luego daño permanente. Intel lo corrigió con el microcódigo 0x12B, que llega con las BIOS publicadas desde septiembre de 2024. Actualiza la BIOS y, al hacerlo, elige el perfil «Intel Default Settings».'
        if ($Cpu.Microcode) {
            if ($Cpu.Microcode -lt 0x12B) {
                $out += New-JuicerFinding $area 'Alto' ('Microcódigo 0x{0:X}: tu {1} necesita 0x12B o posterior' -f $Cpu.Microcode, $Cpu.Name) $fix
            } else {
                $out += New-JuicerFinding $area 'Ok' ('Microcódigo 0x{0:X}, con la corrección de Intel para los Core de 13.ª y 14.ª generación' -f $Cpu.Microcode)
            }
        } elseif ($BiosDate -and $BiosDate -lt [datetime]'2024-09-01') {
            $out += New-JuicerFinding $area 'Alto' "BIOS anterior a la corrección de Intel para tu $($Cpu.Name)" $fix
        }
    }
    if ($Cpu.Am5 -and $BiosDate -and $BiosDate -lt [datetime]'2023-05-01') {
        $out += New-JuicerFinding $area 'Alto' 'BIOS de AM5 anterior a mayo de 2023' 'Las BIOS de AM5 anteriores a AGESA 1.0.0.7b no limitaban el voltaje SoC con EXPO activo, y algunos procesadores (sobre todo 7800X3D) se dañaron. Actualiza la BIOS antes de volver a usar EXPO.'
    }
    if ($Cpu.Am4 -and $TpmVendor -match 'AMD' -and $BiosDate -and $BiosDate -lt [datetime]'2022-05-01') {
        $out += New-JuicerFinding $area 'Medio' 'TPM por firmware de AMD con una BIOS anterior a 2022' 'Con el fTPM de AMD y una BIOS anterior a AGESA 1.2.0.7, el equipo se congela una fracción de segundo de vez en cuando, audio incluido. Actualiza la BIOS.'
    }
    if ($BiosDate) {
        $years = [Math]::Floor(($Now - [datetime]$BiosDate).TotalDays / 365.25)
        if ($years -ge 3 -and $out.Count -le 1) {
            $where = if ($Laptop) { 'la web del fabricante del portátil' } else { 'la web del fabricante de la placa' }
            $out += New-JuicerFinding $area 'Bajo' "La BIOS tiene $years años" "Las actualizaciones de BIOS mejoran la compatibilidad y estabilidad de la memoria (XMP/EXPO), traen microcódigo con parches y a veces Resizable BAR. Búscala en $where; actualiza con el equipo enchufado y sin prisas."
        }
    }
    $out
}

function Get-JuicerX3dFindings {
    param([hashtable]$Cpu = @{}, [bool]$Driver, [bool]$GameBar, [string]$ActivePlan = '', [bool]$GameModeOff)
    if (-not $Cpu.DualCcdX3D) { return @() }
    $area = 'Overclock y BIOS'
    $out = @()
    if (-not $Driver) {
        $out += New-JuicerFinding $area 'Alto' 'Falta el «AMD 3D V-Cache Performance Optimizer»' "Tu $($Cpu.Name) sólo tiene la caché extra en uno de sus dos CCD. El driver de chipset de AMD trae el servicio que lleva los juegos a ese CCD; sin él, un juego puede acabar en el CCD sin caché y rendir como un procesador mucho más barato. Instala el último driver de chipset desde amd.com."
    }
    if (-not $GameBar) {
        $out += New-JuicerFinding $area 'Alto' 'Xbox Game Bar no está instalada' 'En los X3D de dos CCD es Game Bar quien le dice a Windows que lo que se ejecuta es un juego. Reinstálala desde Microsoft Store, o desde Deshacer si la quitó Win Juicer.'
    }
    if ($GameModeOff) {
        $out += New-JuicerFinding $area 'Medio' 'El modo juego está desactivado' 'El aparcado de núcleos de los X3D de dos CCD lo necesita.' 'juegos.modo'
    }
    if ($ActivePlan -and $ActivePlan -ne $script:BalancedPlan) {
        $out += New-JuicerFinding $area 'Medio' 'El plan de energía no es «Equilibrado»' 'AMD pide Equilibrado en los X3D de dos CCD: los planes de alto rendimiento no aparcan núcleos y el reparto entre los dos CCD deja de funcionar.'
    }
    if ($out.Count -eq 0) {
        $out += New-JuicerFinding $area 'Ok' "Tu $($Cpu.Name) está bien configurado: driver de V-Cache, Game Bar, modo juego y plan Equilibrado"
    }
    $out
}

# nvidia-smi --query-gpu=name,power.limit,power.default_limit,pcie.link.width.current,pcie.link.width.max --format=csv,noheader,nounits
function ConvertFrom-JuicerNvidiaQuery {
    param([string]$Text)
    $num = { param($s) $d = 0.0; if ([double]::TryParse(([string]$s).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { $d } else { $null } }
    foreach ($line in (([string]$Text) -split "`r?`n" | Where-Object { $_ -match ',' })) {
        $f = $line -split ','
        if ($f.Count -lt 5) { continue }
        @{ Name = $f[0].Trim(); Power = (& $num $f[1]); DefaultPower = (& $num $f[2]); Width = (& $num $f[3]); MaxWidth = (& $num $f[4]) }
    }
}

function Get-JuicerGpuTuningFindings {
    param([object[]]$Nvidia = @(), [object[]]$Rebar = @())
    $area = 'Gráfica'
    $out = @()
    foreach ($g in $Nvidia) {
        if ($g.Power -and $g.DefaultPower) {
            $pct = [Math]::Round(100 * $g.Power / $g.DefaultPower)
            if ($pct -lt 95) {
                $out += New-JuicerFinding $area 'Medio' "Límite de potencia de la $($g.Name) al $pct %" 'Lo bajó un programa como MSI Afterburner o el del fabricante. Si fue a propósito, por ruido o temperatura, bien; si no, devuélvelo al 100 % y recuperas rendimiento.'
            } elseif ($pct -gt 105) {
                $out += New-JuicerFinding $area 'Info' "Límite de potencia de la $($g.Name) subido al $pct %: overclock de GPU" 'Si ves cuelgues del driver de la gráfica, es lo primero que hay que deshacer.'
            }
        }
        if ($g.Width -and $g.MaxWidth -and $g.Width -lt $g.MaxWidth) {
            $out += New-JuicerFinding $area 'Medio' ('La {0} funciona con x{1} de x{2} líneas PCIe' -f $g.Name, $g.Width, $g.MaxWidth) 'Suele ser porque está en una ranura secundaria, o porque un SSD M.2 comparte líneas con la ranura. El manual de la placa dice cuál es la buena: normalmente la primera ranura larga.'
        }
    }
    foreach ($r in $Rebar) {
        if ($null -eq $r.On) { continue }
        if ($r.On) {
            $out += New-JuicerFinding $area 'Ok' "Resizable BAR activado en la $($r.Name)"
        } elseif ($r.Arc) {
            $out += New-JuicerFinding $area 'Alto' "Resizable BAR desactivado con una Intel Arc ($($r.Name))" 'Las Arc pierden muchísimo sin Resizable BAR, hasta un 40 % en algunos juegos: Intel lo considera imprescindible. Actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support») y desactiva CSM.'
        } else {
            $out += New-JuicerFinding $area 'Medio' "Resizable BAR (Smart Access Memory) desactivado en la $($r.Name)" 'Según el juego, de nada a un 10-15 % más. Actívalo en la BIOS: «Above 4G Decoding» y «Re-Size BAR Support».'
        }
    }
    $out
}

# What the vendor panels have that is worth touching. Advice, not changes:
# their settings live in each driver's own database.
function Get-JuicerDriverAdvice {
    param([object[]]$Gpus = @())
    $area = 'Gráfica'
    $vendors = @($Gpus | Where-Object { $_.Discrete } | ForEach-Object { $_.Vendor } | Select-Object -Unique)
    $out = @()
    if ($vendors -contains 'NVIDIA') {
        $out += New-JuicerFinding $area 'Info' 'En el Panel de control de NVIDIA, lo que sí merece la pena' 'Tamaño de la caché de sombreadores: 10 GB o Ilimitado (menos tirones tras cada actualización). Modo de baja latencia: Activado, o mejor NVIDIA Reflex en los juegos que lo traen. Con G-SYNC: activado, V-Sync activado en el panel y apagado en el juego, y un límite de FPS unos 3 por debajo de los Hz del monitor.'
    }
    if ($vendors -contains 'AMD') {
        $out += New-JuicerFinding $area 'Info' 'En AMD Software (Adrenalin), lo que sí merece la pena' 'Radeon Anti-Lag en juegos competitivos; FreeSync activado; Enhanced Sync y Radeon Chill desactivados si buscas la menor latencia. Con FreeSync, limita los FPS unos 3 por debajo de los Hz del monitor.'
    }
    if ($vendors -contains 'Intel') {
        $out += New-JuicerFinding $area 'Info' 'Con una Intel Arc, el driver al día importa más que en ninguna otra' 'Cada versión trae mejoras grandes en juegos concretos, sobre todo DirectX 11 y anteriores. Actualiza desde Intel Graphics Software.'
    }
    $out
}

# Software that sets clocks and voltages, or that is known for weighing
# on the system. Matched against the names in Programs and Features.
$script:KnownSoftware = @(
    @{ P = 'MSI Afterburner'; Sev = 'Info'; T = 'MSI Afterburner (overclock de GPU)'; D = 'Si tiene un perfil con «Aplicar al iniciar», tu gráfica arranca con overclock. Si ves cuelgues del driver, prueba sin él.' }
    @{ P = 'RivaTuner Statistics Server'; Sev = 'Info'; T = 'RivaTuner (limitador de FPS)'; D = 'Bien usado: limitar los FPS unos 3 por debajo de los Hz con G-SYNC/FreeSync da la mejor latencia sin tearing.' }
    @{ P = 'Ryzen Master'; Sev = 'Info'; T = 'AMD Ryzen Master (overclock de CPU)'; D = 'Lo que aplica se pierde al reiniciar salvo que lo guardes en la BIOS. Un Curve Optimizer demasiado agresivo se ve como errores WHEA 19.' }
    @{ P = 'Extreme Tuning Utility'; Sev = 'Info'; T = 'Intel XTU (overclock y undervolt)'; D = 'Su servicio reaplica el perfil en cada arranque. En equipos con la protección de undervolt de Intel, el undervolt no se aplica.' }
    @{ P = 'ThrottleStop'; Sev = 'Info'; T = 'ThrottleStop (límites y undervolt)'; D = 'Si arranca con Windows, sus límites mandan sobre los de la BIOS.' }
    @{ P = 'Armoury Crate'; Sev = 'Bajo'; T = 'ASUS Armoury Crate'; D = 'Conocido por su peso en segundo plano (varios servicios, CPU, latencia DPC). Si sólo lo usas para el RGB, OpenRGB o SignalRGB pesan menos; los ventiladores se controlan desde la BIOS.' }
    @{ P = 'iCUE'; Sev = 'Bajo'; T = 'Corsair iCUE'; D = 'Consume CPU en segundo plano, más con muchos efectos RGB. Guarda los perfiles en la memoria del dispositivo y ciérralo, o desactívalo en Programas de inicio.' }
    @{ P = 'NZXT CAM'; Sev = 'Bajo'; T = 'NZXT CAM'; D = 'Su monitorización continua tiene un coste en CPU; ciérralo si no lo necesitas mientras juegas.' }
    @{ P = 'Razer Synapse'; Sev = 'Bajo'; T = 'Razer Synapse'; D = 'Varios servicios residentes. Guarda la configuración en el ratón y quítalo de Programas de inicio si no la cambias.' }
    @{ P = 'MSI Center|Dragon Center'; Sev = 'Bajo'; T = 'MSI Center'; D = 'Instala módulos y servicios que no siempre necesitas. Quita los que no uses desde el propio programa.' }
    @{ P = 'Wallpaper Engine'; Sev = 'Info'; T = 'Wallpaper Engine'; D = 'Gasta GPU con el escritorio a la vista; configúralo para pausarse con una aplicación en pantalla completa.' }
)

function Get-JuicerSoftwareFindings {
    param([string[]]$Installed = @(), [string[]]$Antivirus = @())
    $area = 'Programas'
    $out = @()
    foreach ($k in $script:KnownSoftware) {
        if (@($Installed | Where-Object { $_ -match $k.P }).Count -gt 0) { $out += New-JuicerFinding $area $k.Sev $k.T $k.D }
    }
    foreach ($av in @($Antivirus | Where-Object { $_ -and $_ -notmatch 'Defender' })) {
        $out += New-JuicerFinding $area 'Bajo' "Antivirus de terceros: $av" 'Si no lo elegiste tú, suele ser una prueba preinstalada. Analiza cada archivo que abre un juego, igual que Defender, y Defender ya protege. Si lo quitas, Defender se activa solo.'
    }
    $out
}

function Get-JuicerNetworkFindings {
    param([object[]]$Adapters = @())
    $area = 'Red'
    $out = @()
    $wired = @($Adapters | Where-Object { -not $_.Wireless })
    $wifi = @($Adapters | Where-Object { $_.Wireless })
    foreach ($a in $wired) {
        if ($a.LinkSpeed -gt 0 -and $a.LinkSpeed -le 100000000) {
            $out += New-JuicerFinding $area 'Medio' "$($a.Name) está conectada a 100 Mb/s" 'Un puerto gigabit que enlaza a 100 Mb/s suele ser un cable dañado o de cuatro hilos: las descargas de Steam no pasan de unos 11 MB/s. Prueba otro cable (Cat 5e o mejor) u otro puerto del router.'
        } elseif ($a.LinkSpeed -gt 0) {
            $out += New-JuicerFinding $area 'Ok' ('{0}: por cable a {1:N1} Gb/s' -f $a.Name, ($a.LinkSpeed / 1e9))
        }
    }
    if ($wired.Count -eq 0 -and $wifi.Count -gt 0) {
        $out += New-JuicerFinding $area 'Bajo' 'Conectado sólo por wifi' 'Para jugar online, un cable quita los picos de latencia (jitter) y las pérdidas que ningún ajuste de Windows arregla. Si no puedes cablear, mejor wifi 6 en 5 o 6 GHz cerca del router que en 2,4 GHz.'
    }
    $out
}

# --- Reading the machine -----------------------------------------------------

# Events of one kind since a date. Null when the log cannot be read at all,
# so «no errors» never stands in for «could not look».
function Get-JuicerEvents {
    param([hashtable]$Filter)
    try {
        return , @(Get-WinEvent -FilterHashtable $Filter -MaxEvents 500 -ErrorAction Stop)
    } catch {
        if ("$($_.FullyQualifiedErrorId) $_" -match 'NoMatchingEventsFound|NoMatchingProvidersFound|No se encontraron|No events|not an event provider') { return , @() }
        Write-Verbose "No se pudo leer el registro de eventos: $_"
        return $null
    }
}

function Get-JuicerInstalledPrograms {
    $names = @()
    foreach ($root in 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall') {
        foreach ($k in (Get-JuicerRegChildren $root)) {
            $n = Get-JuicerRegString (Read-JuicerReg "$root\$k" 'DisplayName')
            if ($n) { $names += $n }
        }
    }
    @($names | Select-Object -Unique)
}

function Get-JuicerTuningAudit {
    $out = @()
    $hw = Get-JuicerHardwareProfile
    $cpu = $hw.Cpu
    $bios = $null; $board = ''; $tpm = ''
    try {
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        $bios = @{ Date = $b.ReleaseDate; Version = [string]$b.SMBIOSBIOSVersion }
        $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop
        $board = ('{0} {1}' -f $bb.Manufacturer, $bb.Product).Trim()
    } catch {
        Write-Verbose "Sin datos de BIOS: $_"
    }
    try { $tpm = [string](Get-CimInstance -Namespace root/cimv2/Security/MicrosoftTpm -ClassName Win32_Tpm -ErrorAction Stop).ManufacturerIdTxt } catch { Write-Verbose "Sin TPM: $_" }
    $out += Get-JuicerFirmwareFindings -Cpu $cpu -BiosDate $(if ($bios) { $bios.Date }) -BiosVersion $(if ($bios) { $bios.Version } else { '' }) -Board $board -TpmVendor $tpm -Laptop $hw.Laptop

    $plan = ''
    try { $plan = Get-JuicerActivePlan } catch { Write-Verbose "Sin plan activo: $_" }
    $max = ConvertFrom-JuicerPowerSetting (Invoke-JuicerNative 'powercfg.exe' @('/qh', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX')).Output
    $boost = ConvertFrom-JuicerPowerSetting (Invoke-JuicerNative 'powercfg.exe' @('/qh', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PERFBOOSTMODE')).Output
    $out += Get-JuicerPowerCapFindings $max $boost $plan

    if ($cpu.DualCcdX3D) {
        $driver = @(Get-CimInstance Win32_SystemDriver -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DisplayName)" -match 'V-?Cache' }).Count -gt 0 -or
        @(Get-Service -ErrorAction SilentlyContinue | Where-Object { "$($_.Name) $($_.DisplayName)" -match 'V-?Cache' }).Count -gt 0
        $gm = Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
        $out += Get-JuicerX3dFindings -Cpu $cpu -Driver $driver -GameBar $hw.GameBar -ActivePlan $plan -GameModeOff ($gm -and $gm.Value -eq 0)
    }
    $out
}

function Get-JuicerGpuTuningAudit {
    $hw = Get-JuicerHardwareProfile
    $nv = @()
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path -LiteralPath $smi) {
        $r = Invoke-JuicerNative $smi @('--query-gpu=name,power.limit,power.default_limit,pcie.link.width.current,pcie.link.width.max', '--format=csv,noheader,nounits')
        if ($r.Code -eq 0) { $nv = @(ConvertFrom-JuicerNvidiaQuery $r.Output) }
    }
    # NVIDIA's own check runs in Get-JuicerGraphicsAudit; the rest go by the
    # memory ranges Windows gave each card.
    $rebar = @(foreach ($g in @($hw.Gpus | Where-Object { $_.Discrete -and $_.Vendor -ne 'NVIDIA' })) {
            @{ Name = $g.Name; Arc = $g.Arc; On = (Test-JuicerRebarRanges (Get-JuicerGpuMemoryRanges $g.PnpId)) }
        })
    @(Get-JuicerGpuTuningFindings -Nvidia $nv -Rebar $rebar) + @(Get-JuicerDriverAdvice $hw.Gpus)
}

function Get-JuicerEventCount {
    param([hashtable]$Filter)
    $e = Get-JuicerEvents $Filter
    if ($null -eq $e) { return 0 }
    $e.Count
}

function Get-JuicerStabilityAudit {
    $since = (Get-Date).AddDays(-30)
    $whea = @{}
    $we = Get-JuicerEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
    if ($null -eq $we) { return @(New-JuicerFinding 'Estabilidad' 'Info' 'No se pudo leer el registro de eventos del sistema.') }
    foreach ($e in $we) { $whea[[int]$e.Id] = 1 + [int]$whea[[int]$e.Id] }
    $stops = Get-JuicerEvents @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = $since }
    $codes = @(foreach ($e in @($stops | Where-Object { $_ })) {
            ConvertFrom-JuicerBugcheckText ((@($e.Properties | ForEach-Object { $_.Value }) -join ' ') + ' ' + $e.Message)
        })
    $unexpected = Get-JuicerEventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Power'; Id = 41; StartTime = $since }
    $tdr = Get-JuicerEventCount @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since }
    $throttle = Get-JuicerEventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-Kernel-Processor-Power'; Id = 37; StartTime = (Get-Date).AddDays(-7) }
    $memOc = @((Get-JuicerHardwareProfile).Modules | Where-Object { $_.Speed -and $_.ConfiguredClockSpeed -gt $_.Speed + 100 }).Count -gt 0
    Get-JuicerStabilityFindings -Whea $whea -Bugchecks $codes -Unexpected $unexpected -Tdr $tdr -Throttle $throttle -MemoryOc $memOc
}

function Get-JuicerNetworkAudit {
    Get-JuicerNetworkFindings @((Get-JuicerHardwareProfile).Adapters)
}

function Get-JuicerSoftwareAudit {
    $av = @()
    try { $av = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop | ForEach-Object { [string]$_.displayName }) } catch { Write-Verbose "Sin Centro de seguridad: $_" }
    Get-JuicerSoftwareFindings -Installed (Get-JuicerInstalledPrograms) -Antivirus $av
}
