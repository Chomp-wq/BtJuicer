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
    param([object[]]$Nvidia = @(), [object[]]$Rebar = @(), [bool]$Laptop = $false)
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
        # Laptop GPUs narrow the link when idle; a desktop card does not.
        if (-not $Laptop -and $g.Width -and $g.MaxWidth -and $g.Width -lt $g.MaxWidth) {
            $out += New-JuicerFinding $area 'Medio' ('La {0} funciona con x{1} de x{2} líneas PCIe' -f $g.Name, $g.Width, $g.MaxWidth) 'Suele ser porque está en una ranura secundaria, o porque un SSD M.2 comparte líneas con la ranura. El manual de la placa dice cuál es la buena: normalmente la primera ranura larga.'
        }
    }
    foreach ($r in $Rebar) {
        if ($null -eq $r.On) { continue }
        if ($r.On) {
            $out += New-JuicerFinding $area 'Ok' "Resizable BAR activado en la $($r.Name)"
        } elseif ($r.Arc) {
            # Windows does not always list memory mapped above 4 GB, so «no
            # big window seen» is a strong hint, not proof: say how to confirm.
            $out += New-JuicerFinding $area 'Medio' "Resizable BAR parece desactivado en tu Intel Arc ($($r.Name))" 'Las Arc pierden muchísimo sin Resizable BAR, hasta un 40 % en algunos juegos: Intel lo considera imprescindible. Confírmalo en Intel Graphics Software o GPU-Z y, si está apagado, actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support») y desactiva CSM.'
        } else {
            $out += New-JuicerFinding $area 'Bajo' "Resizable BAR (Smart Access Memory) parece desactivado en la $($r.Name)" 'Según el juego, de nada a un 10-15 % más. Confírmalo en AMD Software o GPU-Z y, si está apagado, actívalo en la BIOS: «Above 4G Decoding» y «Re-Size BAR Support».'
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
    $out += Get-JuicerCpuTuningFindings $cpu
    $out
}

# What fine-tuning each Ryzen allows, and the one that pays off: a negative
# Curve Optimizer lowers voltage at each frequency, so the chip runs cooler
# and holds its boost longer. The X3D parts lock the multiplier, but from
# AGESA 1.2.0.8 (AM4) and on AM5 they accept Curve Optimizer.
function Get-JuicerCpuTuningFindings {
    param([hashtable]$Cpu)
    if (-not $Cpu -or $Cpu.Vendor -ne 'AMD' -or $Cpu.Mobile -or -not $Cpu.Name) { return @() }
    $area = 'Overclock y BIOS'
    $n = $Cpu.Name
    $test = ' Pruébalo con OCCT o CoreCycler durante horas: si aparecen errores WHEA o cierres, sube el valor (menos negativo) en ese núcleo.'
    if ($n -match 'Ryzen [3579] 5\d{3}X3D') {
        return (New-JuicerFinding $area 'Info' "Tu $n no admite overclock, pero sí Curve Optimizer" ("Con una BIOS de AGESA 1.2.0.8 o posterior (en PBO > Curve Optimizer), o con la herramienta PBO2 Tuner desde Windows: un valor negativo de -15 a -30 baja 5-10 °C y sostiene la frecuencia máxima más tiempo, que en un X3D es casi todo lo que se puede ganar." + $test))
    }
    if ($n -match 'Ryzen [3579] 7\d{3}X3D') {
        return (New-JuicerFinding $area 'Info' "Tu $n admite Curve Optimizer, no overclock" ("En la BIOS, PBO > Curve Optimizer, negativo de -15 a -30: menos temperatura y más tiempo a la frecuencia máxima. Subir la frecuencia o el PPT no está permitido en los 7000X3D." + $test))
    }
    if ($n -match 'Ryzen [3579] 9\d{3}X3D') {
        return (New-JuicerFinding $area 'Info' "Tu $n admite PBO completo y Curve Optimizer" ("A diferencia de los X3D anteriores, los 9000X3D dejan subir límites de potencia y frecuencia. Lo que más rinde por esfuerzo: Curve Optimizer negativo (-15 a -30) y, si la refrigeración aguanta, PBO con límites de placa." + $test))
    }
    if ($Cpu.Am4 -or $Cpu.Am5) {
        # Curve Optimizer arrived with Zen 3: the 1000 to 4000 series do not have it.
        if ($n -match 'Ryzen [3579] [1-4]\d{3}') { return @() }
        return (New-JuicerFinding $area 'Info' "Tu $n admite PBO y Curve Optimizer" ("Curve Optimizer negativo (de -10 a -30 por núcleo) en la BIOS suele dar más frecuencia sostenida con menos temperatura, sin tocar nada más. Si tu disipador va justo, el modo Eco (65 W o 105 W) pierde muy poco en juegos." + $test))
    }
    @()
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
    @(Get-JuicerGpuTuningFindings -Nvidia $nv -Rebar $rebar -Laptop $hw.Laptop) + @(Get-JuicerDriverAdvice $hw.Gpus)
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

# --- Combinations ------------------------------------------------------------
#
# Advice that only exists because of what goes with what: the same graphics
# card is fine on one board and short of bandwidth on another; 8 GB of VRAM
# is enough at 1080p and not at 4K; a top card on an old processor wants a
# different kind of setting than on a new one.

# Cards wired with fewer than 16 PCIe lanes. On a PCIe 3.0 slot they get half
# (or a quarter) of the bandwidth they were designed for, and that shows the
# moment the VRAM fills and textures stream over the bus.
function Get-JuicerPcieLanes {
    param([string]$Name)
    if ($Name -match 'RX\s*(?:6500|6400)\b') { return 4 }
    if ($Name -match 'RTX\s*(?:3050|4060|5060)|RX\s*(?:5500|6600|6650|7600)\b|Arc(?:\(TM\))?\s*(?:A310|A380|B570|B580)') { return 8 }
    $null
}

# Why the slot the card sits in is PCIe 3.0 at most, from the processor and
# the board's chipset. Null when it is newer or cannot be told.
function Get-JuicerPcie3Reason {
    param([hashtable]$Cpu, [string]$Board = '')
    $n = [string]$Cpu.Name
    if ($Cpu.Vendor -eq 'AMD' -and -not $Cpu.Mobile) {
        # APU dies (Cezanne, Renoir, Picasso, Raven) and Zen/Zen+ only speak
        # 3.0, including the 5500 and 5700 that are APUs without graphics.
        if ($n -match 'Ryzen [3579] (?:[12]\d{3}|[2-5]\d{3}GT?|5500|5700)\b') { return "tu $n da como mucho PCIe 3.0" }
        if ($Cpu.Am4 -and $Board -match '\b(?:A320|B350|X370|B450|X470|A520)') { return "la placa ($Board) da PCIe 3.0 a la gráfica" }
    }
    if ($Cpu.Vendor -eq 'Intel' -and -not $Cpu.Mobile) {
        if ($n -match 'i[3579]-(?:[2-9]\d{3}|10\d{3})(?!\d)') { return "tu $n da como mucho PCIe 3.0" }
        # With an 11th gen Core, Z490/H470/B560 give 4.0; H510 never does.
        if ($Board -match '\bH510') { return "la placa ($Board) da PCIe 3.0 a la gráfica" }
    }
    $null
}

function Get-JuicerPcieFindings {
    param([object[]]$Gpus = @(), [hashtable]$Cpu, [string]$Board = '', [bool]$Laptop)
    if ($Laptop -or -not $Cpu) { return @() }
    $why = Get-JuicerPcie3Reason $Cpu $Board
    if (-not $why) { return @() }
    $out = @()
    foreach ($g in @($Gpus | Where-Object { $_.Discrete })) {
        $lanes = Get-JuicerPcieLanes $g.Name
        if ($lanes -eq 4) {
            $out += New-JuicerFinding 'Gráfica' 'Alto' "Tu $($g.Name) usa 4 líneas PCIe, y $why" 'Con PCIe 3.0 x4 tiene un cuarto del ancho de banda para el que se diseñó: en cuanto la VRAM se llena, los FPS se hunden. Texturas en bajo o medio para que nunca se llene, y Resizable BAR activado.'
        } elseif ($lanes -eq 8) {
            $out += New-JuicerFinding 'Gráfica' 'Medio' "Tu $($g.Name) usa 8 líneas PCIe, y $why" 'En PCIe 3.0 x8 tiene la mitad del ancho de banda de diseño. Casi no se nota mientras la VRAM no se llene; cuando se llena, la pérdida es mayor que en una placa PCIe 4.0. Mantén las texturas un escalón por debajo del máximo y activa Resizable BAR.'
        }
    }
    $out
}

# VRAM against the resolution of the main screen, with what the driver
# reports for the card (not the old 4 GB-capped WMI figure).
function Get-JuicerVramFindings {
    param([object[]]$Gpus = @(), [int]$Width, [int]$Height)
    $g = @($Gpus | Where-Object { $_.Discrete -and $_.Vram -gt 0 } | Sort-Object { $_.Vram } -Descending) | Select-Object -First 1
    if (-not $g -or $Width -le 0) { return @() }
    $gb = [int][Math]::Round($g.Vram / 1GB)
    $px = $Width * $Height
    $res = "${Width}×${Height}"
    if ($px -ge 3840 * 2160 * 0.9 -and $gb -le 10) {
        return (New-JuicerFinding 'Gráfica' 'Medio' "$gb GB de VRAM para jugar a $res" 'En 4K los juegos actuales piden 12 GB o más con texturas altas. Usa DLSS, FSR o XeSS (renderizan por debajo y caben en menos VRAM) y texturas en medio o alto.')
    }
    if ($px -ge 2560 * 1440 * 0.9 -and $gb -le 8) {
        return (New-JuicerFinding 'Gráfica' $(if ($gb -le 6) { 'Medio' } else { 'Info' }) "$gb GB de VRAM a $res" 'Justo para 1440p en juegos recientes: texturas en alto, no en ultra, y sin trazado de rayos al máximo. Cuando la VRAM se llena no bajan los FPS medios sino los mínimos: tirones al girar la cámara.')
    }
    if ($gb -le 4) {
        return (New-JuicerFinding 'Gráfica' 'Medio' "Sólo $gb GB de VRAM" 'Incluso a 1080p muchos juegos recientes piden 6-8 GB: texturas en bajo o medio. Es lo primero que hay que bajar si hay tirones.')
    }
    @()
}

# AMD APUs playing on their integrated graphics: its VRAM is a slice of the
# system RAM set in the BIOS (UMA Frame Buffer Size).
function Get-JuicerApuFindings {
    param([object[]]$Gpus = @(), [hashtable]$Cpu, [int64]$RamBytes)
    if (-not $Cpu -or $Cpu.Vendor -ne 'AMD' -or $Cpu.Mobile -or [string]$Cpu.Name -notmatch 'Ryzen [3579] \d{4}GT?\b') { return @() }
    if (@($Gpus | Where-Object { $_.Discrete }).Count -gt 0) { return @() }
    $igpu = @($Gpus | Where-Object { $_.Vendor -eq 'AMD' }) | Select-Object -First 1
    $ramGb = [int][Math]::Round($RamBytes / 1GB)
    $uma = if ($igpu -and $igpu.Vram -gt 0) { [int][Math]::Round($igpu.Vram / 1MB) } else { 0 }
    $want = if ($ramGb -ge 32) { '4 GB' } elseif ($ramGb -ge 16) { '2 o 4 GB' } else { '1 o 2 GB' }
    if ($uma -gt 0 -and $uma -lt 1024) {
        return (New-JuicerFinding 'Gráfica' 'Medio' "La gráfica integrada sólo tiene $uma MB reservados" "En la BIOS, «UMA Frame Buffer Size» (a veces en AMD CBS > NBIO > GFX): con $ramGb GB de RAM, pon $want. Muchos juegos van a tirones o no arrancan con 512 MB. Y para esta gráfica la RAM es su VRAM: dos módulos y lo más rápida que sostenga tu APU.")
    }
    New-JuicerFinding 'Gráfica' 'Info' 'Juegas con la gráfica integrada de tu APU' "Su VRAM sale de la RAM: dos módulos (doble canal) y la mayor velocidad estable cuentan más que ningún ajuste de Windows. En la BIOS, «UMA Frame Buffer Size» de $want con $ramGb GB de RAM."
}

# A rough tier per card and per processor, to tell when one holds back the
# other. 4 is the top of the current generations.
function Get-JuicerGpuTier {
    param([string]$Name)
    if ($Name -match 'RTX\s*(?:4080|4090|5080|5090)|RX\s*(?:7900|9070\s*XT)|RTX\s*(?:4070|5070)\s*Ti') { return 4 }
    if ($Name -match 'RTX\s*(?:3080|3090|4070|5070)|RX\s*(?:6800|6900|6950|7800|9070)') { return 3 }
    if ($Name -match 'RTX\s*(?:2070|2080|3060|3070|4060|5060)|RX\s*(?:5700|6600|6650|6700|6750|7600|7700|9060)|Arc(?:\(TM\))?\s*(?:A750|A770|B570|B580)') { return 2 }
    if ($Name -match 'GTX|RTX\s*(?:2060|3050)|RX\s*(?:4\d0|5[0-6]0|5500|5600|6400|6500)\b|Arc') { return 1 }
    0
}

function Get-JuicerCpuTier {
    param([hashtable]$Cpu)
    $n = [string]$Cpu.Name
    if (-not $n) { return 0 }
    if ($Cpu.X3D -or $n -match 'Ryzen [579] (?:7\d{3}|9\d{3})|i[79]-1[34]\d{3}|Ultra [79] 2\d{2}') { return 3 }
    if (($Cpu.Cores -gt 0 -and $Cpu.Cores -le 4) -or $n -match 'Ryzen [3579] [12]\d{3}|Ryzen [3579] 3\d{3}G|i[3579]-[2-8]\d{3}(?!\d)') { return 1 }
    2
}

function Get-JuicerBalanceFindings {
    param([object[]]$Gpus = @(), [hashtable]$Cpu)
    $g = @($Gpus | Where-Object { $_.Discrete }) | Select-Object -First 1
    if (-not $g -or -not $Cpu -or $Cpu.Mobile) { return @() }
    $gt = Get-JuicerGpuTier $g.Name
    $ct = Get-JuicerCpuTier $Cpu
    if ($gt -ge 3 -and $ct -eq 1) {
        return (New-JuicerFinding 'Gráfica' 'Medio' "Tu $($g.Name) va sobrada para tu $($Cpu.Name)" 'En muchos juegos el procesador marcará los FPS, sobre todo a 1080p. Aprovecha la gráfica donde no cuesta CPU: más resolución (1440p/4K, DLDSR o VSR), DLAA o FSR nativo en vez de reescalar, calidad alta. Reescalar más no dará más FPS, y la generación de fotogramas suaviza pero no quita los tirones del procesador. Un límite de FPS a lo que tu CPU sostiene deja los frametimes planos.')
    }
    if ($gt -eq 1 -and $ct -eq 3) {
        return (New-JuicerFinding 'Gráfica' 'Info' "Tu $($Cpu.Name) va sobrado para tu $($g.Name)" 'Casi siempre limitará la gráfica: lo que da FPS es bajar la resolución interna (DLSS, FSR o XeSS en calidad o equilibrado), sombras y efectos. Lo que carga el procesador (distancia de dibujado, población, física) puedes subirlo casi gratis.')
    }
    @()
}

# Laptops whose internal screen is drawn by the integrated graphics while the
# dedicated card renders the game (Optimus, hybrid): every frame is copied
# across, which costs FPS and adds latency. Many gaming laptops have a MUX
# switch to wire the screen to the dedicated card.
$script:LaptopGpuApps = [ordered]@{
    Alienware = 'Alienware Command Center o la BIOS (desactivar Hybrid Graphics)'; ASUS = 'Armoury Crate (Modo GPU: Ultimate)'
    Lenovo = 'Legion Space o Lenovo Vantage (desactivar el modo híbrido)'; 'MSI|Micro-Star' = 'MSI Center (GPU Switch: Discrete Graphics Mode)'
    HP = 'OMEN Gaming Hub (modo de gráficos: Discreto)'; Acer = 'NitroSense o PredatorSense'
    Dell = 'la BIOS (desactivar Hybrid Graphics), si tu modelo lo permite'; Gigabyte = 'Gigabyte Control Center'; Razer = 'Razer Synapse (GPU Mode)'
}

function Get-JuicerOptimusFindings {
    param([object[]]$Gpus = @(), [object[]]$Displays = @(), [bool]$Laptop, [string]$Maker = '')
    if (-not $Laptop) { return @() }
    $dgpu = @($Gpus | Where-Object { $_.Discrete }) | Select-Object -First 1
    $panel = @($Displays | Where-Object { $_.Primary }) | Select-Object -First 1
    if (-not $dgpu -or -not $panel -or -not $panel.Adapter) { return @() }
    $a = Get-JuicerGpuTraits $panel.Adapter
    if ($a.Discrete -or $a.Vendor -notin 'Intel', 'AMD') { return @() }
    $brand = @($script:LaptopGpuApps.Keys | Where-Object { $Maker -match $_ }) | Select-Object -First 1
    $where = if ($brand) { " En tu portátil se cambia en $($script:LaptopGpuApps[$brand]); pide reiniciar." } else { ' Se cambia en la app de control del fabricante o en la BIOS; pide reiniciar.' }
    New-JuicerFinding 'Gráfica' 'Info' "La pantalla la dibuja la $($a.Name), no la $($dgpu.Name)" ("Es el modo híbrido (Optimus): la dedicada renderiza y cada fotograma se copia a la integrada, con algo menos de FPS y algo más de latencia. Si tu portátil tiene conmutador MUX o «Advanced Optimus», el modo de sólo la dedicada lo quita, a cambio de batería.$where Juega enchufado y con el modo de rendimiento del fabricante. Un monitor externo en un puerto conectado a la dedicada también lo evita.")
}

# Everything above, with what it needs read once.
function Get-JuicerComboAudit {
    $hw = Get-JuicerHardwareProfile
    $out = @()
    $board = ''; $maker = ''
    try { $bb = Get-CimInstance Win32_BaseBoard -ErrorAction Stop; $board = ('{0} {1}' -f $bb.Manufacturer, $bb.Product).Trim() } catch { Write-Verbose "Sin placa: $_" }
    try { $maker = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).Manufacturer } catch { Write-Verbose "Sin fabricante: $_" }
    $displays = @()
    try { $displays = @(Get-JuicerDisplays) } catch { Write-Verbose "Sin pantallas: $_" }
    $main = @($displays | Where-Object { $_.Primary }) | Select-Object -First 1
    $out += Get-JuicerPcieFindings $hw.Gpus $hw.Cpu $board $hw.Laptop
    if ($main) { $out += Get-JuicerVramFindings $hw.Gpus ([int]$main.Width) ([int]$main.Height) }
    $out += Get-JuicerApuFindings $hw.Gpus $hw.Cpu $hw.RamBytes
    $out += Get-JuicerBalanceFindings $hw.Gpus $hw.Cpu
    $out += Get-JuicerOptimusFindings $hw.Gpus $displays $hw.Laptop $maker
    $out
}
