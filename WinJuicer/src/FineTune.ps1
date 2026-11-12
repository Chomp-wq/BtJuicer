# Fine tuning: undervolting the processor and tuning the graphics card, the
# way that lasts and is safe.
#
# The processor's goes in the BIOS. Curve Optimizer or a voltage offset set
# there is applied at every boot by the board itself, before Windows, with
# no software running. The Windows tools that do it from the desktop need a
# kernel driver to reach the CPU (WinRing0 and the like), which Microsoft
# Defender flags as vulnerable since 2025 and anti-cheats watch for: Win
# Juicer does not install one.
#
# The graphics card's goes in its own tool (MSI Afterburner, AMD Software,
# Intel Graphics Software), which applies it at every boot. NVIDIA's public
# API can read clocks and voltages but not set them, so Win Juicer gives the
# recipe for each architecture and does not write it blind.
#
# What Win Juicer adds: the starting values for your exact chip, a record of
# what you applied, and a check at every sign-in that it is still there (a
# BIOS update wipes it) and stable (WHEA errors, driver crashes).

# --- Processor -----------------------------------------------------------------

$script:CpuTestHowTo = 'Prueba cada paso: OCCT (CPU, conjunto de datos variable) una hora y CoreCycler una noche para ir núcleo a núcleo. Si hay errores, cierres o pantallazos, sube el valor un escalón (menos negativo) en ese núcleo. Después, usa el equipo unos días: el diagnóstico de Win Juicer cuenta los errores WHEA desde que lo apuntaste.'

function Get-JuicerCpuTuneGuide {
    param([hashtable]$Cpu)
    if (-not $Cpu -or -not $Cpu.Name -or $Cpu.Mobile) { return $null }
    $n = $Cpu.Name
    $co = 'BIOS > Advanced > AMD Overclocking > Precision Boost Overdrive > Curve Optimizer (en algunas placas, en el menú de overclock del fabricante)'
    if ($n -match 'Ryzen [3579] 5\d{3}X3D') {
        return @{
            Key = 'zen3x3d'; Title = "Undervolt para tu $n"; Where = $co
            Steps = 'Curve Optimizer «All Cores», signo negativo: empieza en -15 y baja de 5 en 5 hasta -30. Si tu BIOS no lo tiene (AGESA anterior a 1.2.0.8), actualízala; la alternativa es un offset de voltaje negativo de -0,03 a -0,05 V (tus -40 mV están ahí), menos fino que Curve Optimizer.'
            Gain = 'No sube la frecuencia máxima (está bloqueada), pero con 5-10 °C menos el procesador la sostiene más tiempo bajo carga: más FPS en juegos largos y menos ruido.'
            Test = $script:CpuTestHowTo
        }
    }
    if ($n -match 'Ryzen [3579] 7\d{3}X3D') {
        return @{
            Key = 'zen4x3d'; Title = "Undervolt para tu $n"; Where = $co
            Steps = 'Curve Optimizer «All Cores», negativo, de -15 a -30. El multiplicador y los límites de potencia están bloqueados en los 7000X3D: no hace falta tocar más.'
            Gain = 'Menos temperatura y más tiempo a la frecuencia máxima; en un X3D es casi todo lo que se puede ganar.'
            Test = $script:CpuTestHowTo
        }
    }
    if ($n -match 'Ryzen [3579] 9\d{3}X3D') {
        return @{
            Key = 'zen5x3d'; Title = "Undervolt y PBO para tu $n"; Where = $co
            Steps = 'Primero Curve Optimizer negativo de -15 a -30. Con eso estable, PBO con límites «Motherboard» y Boost Override +100 a +200 MHz si la refrigeración aguanta (los 9000X3D, a diferencia de los anteriores, lo permiten).'
            Gain = 'Unos cientos de MHz más sostenidos, sobre todo en juegos que cargan varios núcleos.'
            Test = $script:CpuTestHowTo
        }
    }
    if ($n -match 'Ryzen [3579] [5789]\d{3}') {
        return @{
            Key = 'zen3plus'; Title = "Undervolt y PBO para tu $n"; Where = $co
            Steps = 'Curve Optimizer negativo: -10 a -20 en los dos núcleos mejores (los que Ryzen Master marca con estrella) y -15 a -30 en el resto. Con eso estable, opcional: PBO con límites «Motherboard» y Boost Override +100 a +200 MHz. Si tu disipador va justo, mejor modo Eco con el mismo Curve Optimizer.'
            Gain = 'Frecuencias sostenidas más altas con menos temperatura; en juegos limitados por el procesador, unos pocos por ciento.'
            Test = $script:CpuTestHowTo
        }
    }
    if ($n -match 'Ryzen [3579] [1-4]\d{3}') {
        return @{
            Key = 'zen2older'; Title = "Tu $n no tiene Curve Optimizer"; Where = 'BIOS > Precision Boost Overdrive'
            Steps = 'Curve Optimizer llegó con los Ryzen 5000. En Zen 2 y anteriores un offset de voltaje negativo suele bajar el boost en vez de mejorarlo: deja el voltaje en automático y, como mucho, PBO con límites de la placa.'
            Gain = 'Poco: estas generaciones ya van cerca de su límite de fábrica.'
            Test = $script:CpuTestHowTo
        }
    }
    if ($Cpu.Vendor -eq 'Intel' -and $n -match 'i[579]-1[234]\d{3}K') {
        return @{
            Key = 'intelk'; Title = "Undervolt para tu $n"; Where = 'BIOS > Overclocking > CPU Voltage (o «Advanced Voltage Offset» / «AC/DC Load Line»)'
            Steps = $(if ($Cpu.RaptorLake) { 'Antes que nada: BIOS con microcódigo 0x12B o posterior y el perfil «Intel Default Settings». ' } else { '' }) + 'Luego, el undervolt más limpio es bajar «AC Load Line» (por ejemplo, de 1,1 a 0,5-0,6 mΩ) o un offset de -0,050 a -0,100 V. Si la placa no deja bajar (opción «Undervolt Protection» activa), no se puede desde Windows tampoco.'
            Gain = 'Decenas de vatios y grados menos con el mismo rendimiento; en 13.ª y 14.ª generación, además, menos voltaje es menos desgaste.'
            Test = $script:CpuTestHowTo
        }
    }
    $null
}

# --- Graphics card -----------------------------------------------------------

function Get-JuicerGpuArch {
    param([string]$Name)
    if ($Name -match 'RTX\s*50\d{2}') { return 'blackwell' }
    if ($Name -match 'RTX\s*40\d{2}') { return 'ada' }
    if ($Name -match 'RTX\s*30\d{2}') { return 'ampere' }
    if ($Name -match 'RTX\s*20\d{2}|GTX\s*16\d{2}') { return 'turing' }
    if ($Name -match 'GTX\s*10\d{2}') { return 'pascal' }
    if ($Name -match '\bRX\s*9\d{3}') { return 'rdna4' }
    if ($Name -match '\bRX\s*7\d{3}') { return 'rdna3' }
    if ($Name -match '\bRX\s*6\d{3}') { return 'rdna2' }
    if ($Name -match 'Arc(?:\(TM\))?\s*[AB]\d{3}') { return 'arc' }
    $null
}

$script:GpuTuneGuides = @{
    blackwell = @{
        Arch = 'Blackwell (RTX 50)'; Tool = 'Afterburner'
        Steps = 'En MSI Afterburner: Core Clock +200 a +300 MHz (sube de 50 en 50) y Memory Clock +1000 a +2000 MHz (GDDR7 suele aguantar más, pero cada +1000 da muy poco). Para menos consumo con lo mismo, curva (Ctrl+F) plana a 0,90-0,95 V a la frecuencia que alcances.'
        Gain = 'Las RTX 50 traen margen: en pruebas de prensa, un 10-13 % más con la frecuencia al máximo estable; la memoria aporta poco porque casi nunca limita.'
    }
    ada = @{
        Arch = 'Ada Lovelace (RTX 40)'; Tool = 'Afterburner'
        Steps = 'En MSI Afterburner, curva (Ctrl+F): plana desde 0,95-1,00 V a 2700-2850 MHz (undervolt con el mismo rendimiento), o sin curva +100 a +150 MHz de núcleo. Memoria +500 a +1000 MHz. Si buscas silencio, el límite de potencia al 80 % apenas cuesta rendimiento en las 4080/4090.'
        Gain = 'Con la curva, el mismo rendimiento o un poco más con bastante menos consumo y temperatura; con memoria, unos pocos FPS.'
    }
    ampere = @{
        Arch = 'Ampere (RTX 30)'; Tool = 'Afterburner'
        Steps = 'En MSI Afterburner, curva (Ctrl+F) plana a 850-900 mV y 1850-1950 MHz. Memoria +250 a +500 MHz: la GDDR6X corrige sus propios errores, así que pasada la frecuencia buena no se cuelga, rinde menos; mide FPS en cada paso.'
        Gain = 'Es la generación que más gana con undervolt: el mismo rendimiento (o algo más, porque deja de tocar el límite de potencia) con un 20-25 % menos de consumo.'
    }
    turing = @{
        Arch = 'Turing (RTX 20 / GTX 16)'; Tool = 'Afterburner'
        Steps = 'En MSI Afterburner, curva plana a unos 900 mV y 1850-1900 MHz, o +75 a +125 MHz de núcleo. Memoria +500 a +800 MHz.'
        Gain = 'Un 3-6 % con el núcleo y la memoria, o lo mismo con menos ruido usando la curva.'
    }
    pascal = @{
        Arch = 'Pascal (GTX 10)'; Tool = 'Afterburner'
        Steps = 'En MSI Afterburner, límite de potencia al máximo, +75 a +150 MHz de núcleo y +300 a +500 MHz de memoria; o curva a unos 900 mV y 1850-1900 MHz para que no baje de frecuencia por temperatura.'
        Gain = 'Un 4-8 %, sobre todo si la tarjeta bajaba frecuencia por temperatura.'
    }
    rdna4 = @{
        Arch = 'RDNA 4 (RX 9000)'; Tool = 'Adrenalin'
        Steps = 'En AMD Software > Rendimiento > Ajuste: «Voltage Offset» de -30 a -80 mV (cada chip es distinto: algunos fallan ya a -40) y «Power Limit» +10 %. Memoria a 2700 MHz con «Fast Timing» al final, si sobra.'
        Gain = 'El límite de potencia es lo que sube la frecuencia; el undervolt la hace alcanzable sin subir consumo ni temperatura. En foros, un 5-10 % con chips buenos.'
    }
    rdna3 = @{
        Arch = 'RDNA 3 (RX 7000)'; Tool = 'Adrenalin'
        Steps = 'En AMD Software > Rendimiento > Ajuste: baja el voltaje máximo de 10 en 10 mV desde los ~1150 de fábrica (muchas se quedan en 1050-1080), y luego «Power Limit» +15 %. La memoria déjala para el final: suele tope en 2500-2600 MHz y «Fast Timing» da un par de FPS.'
        Gain = 'Menos consumo y temperatura con el mismo rendimiento, o algo más con el límite de potencia subido.'
    }
    rdna2 = @{
        Arch = 'RDNA 2 (RX 6000)'; Tool = 'Adrenalin'
        Steps = 'En AMD Software > Rendimiento > Ajuste: voltaje de 1150-1200 a 1075-1100 mV, «Power Limit» +15 % y memoria a 2100-2150 MHz con «Fast Timing».'
        Gain = 'Un 3-6 % con el límite de potencia y la memoria, con menos temperatura gracias al undervolt.'
    }
    arc = @{
        Arch = 'Intel Arc'; Tool = 'Intel'
        Steps = 'En Intel Graphics Software > Rendimiento: «Power Limit» al máximo y «GPU Performance Boost» de 10 en 10 hasta que falle, y vuelve dos pasos atrás. Comprueba antes que Resizable BAR está activo: en Arc es lo que más cuenta.'
        Gain = 'Un 5-10 % con el límite de potencia y la frecuencia; sin Resizable BAR, nada compensa.'
    }
}

$script:GpuToolNotes = @{
    Afterburner = 'Para que se aplique en cada inicio: en Afterburner, guarda el ajuste en un perfil, activa «Aplicar overclock al iniciar el sistema» y deja que arranque con Windows (Win Juicer lo marca como opcional en Programas de inicio por eso).'
    Adrenalin = 'AMD Software lo guarda y lo aplica en cada inicio por sí mismo; tras un cuelgue del driver vuelve a valores de fábrica y tienes que cargar el perfil de nuevo.'
    Intel = 'Intel Graphics Software lo vuelve a aplicar en cada inicio si está abierto en la bandeja.'
}

function Get-JuicerGpuTuneGuide {
    param([string]$Name)
    $arch = Get-JuicerGpuArch $Name
    if (-not $arch) { return $null }
    $g = $script:GpuTuneGuides[$arch].Clone()
    $g.Key = $arch
    $g.Persist = $script:GpuToolNotes[$g.Tool]
    $g
}

$script:GpuTestHowTo = 'Prueba con lo que juegas, no sólo con un benchmark: 3DMark Time Spy o Steel Nomad en bucle 20 minutos y una hora de tu juego más exigente. Mide FPS antes y después con Juegos > Medir. Si el driver se reinicia o el juego se cierra, vuelve un paso atrás: el diagnóstico cuenta esos cuelgues desde que apuntaste el ajuste.'

function Get-JuicerTuneGuideFindings {
    param([hashtable]$Cpu, [object[]]$Gpus = @(), [bool]$Laptop)
    $area = 'Ajuste fino'
    $out = @()
    $c = if (-not $Laptop) { Get-JuicerCpuTuneGuide $Cpu }
    if ($c) {
        $out += New-JuicerFinding $area 'Info' $c.Title ("Dónde: $($c.Where). $($c.Steps) $($c.Gain) La BIOS lo guarda y lo aplica en cada arranque sin ningún programa. $($c.Test)")
    }
    foreach ($g in @($Gpus | Where-Object { $_.Discrete })) {
        $guide = Get-JuicerGpuTuneGuide $g.Name
        if (-not $guide) { continue }
        $out += New-JuicerFinding $area 'Info' "Undervolt y overclock para tu $($g.Name) ($($guide.Arch))" ("$($guide.Steps) $($guide.Gain) $($guide.Persist) $script:GpuTestHowTo")
    }
    if ($out.Count -gt 0 -and -not (Read-JuicerTuneRecord)) {
        $out += New-JuicerFinding $area 'Info' 'Apunta en Win Juicer lo que apliques' 'En la pestaña Ajuste fino (o con -ApuntarAjuste): Win Juicer recordará tus valores y en cada inicio de sesión avisará si una actualización de BIOS los ha borrado, si la RAM ha vuelto a su velocidad de fábrica o si hay errores desde entonces.'
    }
    $out
}

# --- What you applied, and whether it is still there ---------------------------

function Get-JuicerTunePath { Join-Path (Get-JuicerHome) 'ajuste-fino.json' }

function Read-JuicerTuneRecord {
    $p = Get-JuicerTunePath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    try { ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json) } catch { Write-JuicerLog "ajuste-fino.json dañado: $_"; $null }
}

function Get-JuicerBiosVersion {
    if (-not (Test-JuicerWindows)) { return '' }
    try {
        $b = Get-CimInstance Win32_BIOS -ErrorAction Stop
        return ('{0} {1}' -f $b.SMBIOSBIOSVersion, $(if ($b.ReleaseDate) { ([datetime]$b.ReleaseDate).ToString('yyyy-MM-dd') })).Trim()
    } catch {
        return ''
    }
}

function Get-JuicerRamSpeed {
    if (-not (Test-JuicerWindows)) { return 0 }
    try { [int](@(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop | ForEach-Object { $_.ConfiguredClockSpeed }) | Measure-Object -Minimum).Minimum } catch { 0 }
}

# Cpu and Gpu are free text («Curve Optimizer -30», «curva 900 mV a 1900 MHz,
# memoria +500»); GpuTool says which program applies the card's. The BIOS
# version and the RAM speed are taken now, to compare later.
function Save-JuicerTuneRecord {
    param([string]$Cpu = '', [string]$Gpu = '', [ValidateSet('', 'Afterburner', 'Adrenalin', 'Intel')][string]$GpuTool = '', [string]$Bios, [int]$RamSpeed = -1)
    if (-not $PSBoundParameters.ContainsKey('Bios')) { $Bios = Get-JuicerBiosVersion }
    if ($RamSpeed -lt 0) { $RamSpeed = Get-JuicerRamSpeed }
    $r = @{ Date = (Get-Date).ToString('s'); Cpu = $Cpu; Gpu = $Gpu; GpuTool = $GpuTool; Bios = $Bios; RamSpeed = $RamSpeed }
    [IO.File]::WriteAllText((Get-JuicerTunePath), (ConvertTo-JuicerJson $r), (New-Object Text.UTF8Encoding $false))
    Write-JuicerLog "Ajuste fino apuntado: CPU «$Cpu», GPU «$Gpu» ($GpuTool), BIOS $Bios, RAM $RamSpeed"
    $r
}

function Remove-JuicerTuneRecord { Remove-Item -LiteralPath (Get-JuicerTunePath) -Force -ErrorAction SilentlyContinue }

# Whea and Tdr count since the record's date; ToolStarts is null when there
# is no GPU tool to check.
function Get-JuicerTuneCheckFindings {
    param([hashtable]$Record, [string]$Bios, [int]$RamSpeed, [int]$Whea, [int]$Tdr, $ToolStarts)
    $area = 'Ajuste fino'
    $out = @()
    if (-not $Record) { return $out }
    $since = ([datetime]$Record.Date).ToString('d')
    $what = @(@($Record.Cpu, $Record.Gpu) | Where-Object { $_ }) -join '; '
    $out += New-JuicerFinding $area 'Info' "Tu ajuste fino, apuntado el $since" $what
    if ($Record.Bios -and $Bios -and $Bios -ne $Record.Bios) {
        $out += New-JuicerFinding $area 'Alto' 'La BIOS ha cambiado desde que apuntaste tu ajuste' "Antes: $($Record.Bios); ahora: $Bios. Actualizar la BIOS (o borrar la CMOS) devuelve todo a fábrica: vuelve a poner $(if ($Record.Cpu) { "«$($Record.Cpu)»" } else { 'tu ajuste' }) y el XMP/EXPO, y apúntalo de nuevo."
    }
    if ($Record.RamSpeed -gt 0 -and $RamSpeed -gt 0 -and [Math]::Abs($RamSpeed - [int]$Record.RamSpeed) -gt 50) {
        $out += New-JuicerFinding $area 'Alto' "La RAM va a $RamSpeed MT/s; cuando apuntaste tu ajuste iba a $($Record.RamSpeed)" 'Suele ser una BIOS que se ha reiniciado sola tras un fallo de arranque por inestabilidad, o una actualización. Revisa el XMP/EXPO y, si se reinició sola, el ajuste estaba al límite: aflójalo un paso.'
    }
    if ($Record.Cpu) {
        if ($Whea -gt 0) {
            $out += New-JuicerFinding $area 'Alto' "$Whea errores de hardware (WHEA) desde que apuntaste tu ajuste" 'Con un undervolt, es la señal de que es demasiado: sube el Curve Optimizer 5 puntos (menos negativo) o el offset 10 mV, en todos los núcleos o en el que falle con CoreCycler.'
        } else {
            $out += New-JuicerFinding $area 'Ok' 'Sin errores WHEA desde que apuntaste tu ajuste'
        }
    }
    if ($Record.Gpu) {
        if ($Tdr -gt 0) {
            $out += New-JuicerFinding $area 'Alto' "El driver de la gráfica se ha reiniciado $Tdr veces desde que apuntaste tu ajuste" 'Es lo que pasa cuando el overclock o el undervolt de la gráfica es demasiado: vuelve un paso atrás (menos frecuencia o más voltaje en ese punto de la curva).'
        } else {
            $out += New-JuicerFinding $area 'Ok' 'Sin cuelgues del driver de la gráfica desde que apuntaste tu ajuste'
        }
        if ($Record.GpuTool -eq 'Afterburner' -and $ToolStarts -eq $false) {
            $out += New-JuicerFinding $area 'Medio' 'MSI Afterburner no arranca con Windows' 'Tu ajuste de la gráfica sólo se aplica si Afterburner se abre al iniciar: actívalo en Programas de inicio y, en Afterburner, «Aplicar overclock al iniciar el sistema».'
        }
    }
    $out
}

function Get-JuicerTuneCheck {
    $r = Read-JuicerTuneRecord
    if (-not $r) { return @() }
    $since = [datetime]$r.Date
    $whea = 0; $tdr = 0; $tool = $null
    if (Test-JuicerWindows) {
        $whea = Get-JuicerEventCount @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = $since }
        $tdr = Get-JuicerEventCount @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = $since }
        if ($r.GpuTool -eq 'Afterburner') {
            $tool = @(Get-JuicerStartupItems | Where-Object { $_.Enabled -and "$($_.Name) $($_.Command)" -match 'Afterburner' }).Count -gt 0
        }
    }
    Get-JuicerTuneCheckFindings $r (Get-JuicerBiosVersion) (Get-JuicerRamSpeed) $whea $tdr $tool
}

# --- Checking at every sign-in -------------------------------------------------
#
# A small script of its own, in the user's profile, run by a scheduled task
# at sign-in as that user (no elevation): it reads the record, compares and,
# only when something changed since its last look, shows a notification.

$script:TuneWatchTask = 'Win Juicer - vigilar ajuste fino'

function Get-JuicerTuneWatchScript {
    param([string]$RecordPath)
@"
# Win Juicer: comprueba al iniciar sesión que el ajuste fino sigue puesto y estable.
`$ErrorActionPreference = 'SilentlyContinue'
`$recordPath = '$($RecordPath -replace "'", "''")'
`$statePath = Join-Path `$PSScriptRoot 'vigilar-estado.json'
if (-not (Test-Path -LiteralPath `$recordPath)) { return }
`$r = Get-Content -Raw -LiteralPath `$recordPath | ConvertFrom-Json
`$state = if (Test-Path -LiteralPath `$statePath) { Get-Content -Raw -LiteralPath `$statePath | ConvertFrom-Json } else { `$null }
`$from = [datetime]`$r.Date
if (`$state -and `$state.Last -and [datetime]`$state.Last -gt `$from) { `$from = [datetime]`$state.Last }
`$msgs = @()
`$b = Get-CimInstance Win32_BIOS
`$bios = ('{0} {1}' -f `$b.SMBIOSBIOSVersion, `$(if (`$b.ReleaseDate) { ([datetime]`$b.ReleaseDate).ToString('yyyy-MM-dd') })).Trim()
if (`$r.Bios -and `$bios -ne `$r.Bios -and -not (`$state -and `$state.BiosWarned -eq `$bios)) { `$msgs += 'La BIOS ha cambiado: tu undervolt y el XMP/EXPO pueden haberse borrado.' }
`$ram = (@(Get-CimInstance Win32_PhysicalMemory | ForEach-Object { `$_.ConfiguredClockSpeed }) | Measure-Object -Minimum).Minimum
if (`$r.RamSpeed -gt 0 -and `$ram -gt 0 -and [Math]::Abs(`$ram - `$r.RamSpeed) -gt 50 -and -not (`$state -and `$state.RamWarned -eq `$ram)) { `$msgs += "La RAM va a `$ram MT/s y la dejaste a `$(`$r.RamSpeed)." }
`$whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = `$from } -MaxEvents 100).Count
if (`$r.Cpu -and `$whea -gt 0) { `$msgs += "`$whea errores WHEA: tu undervolt puede ser demasiado." }
`$tdr = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Display'; Id = 4101; StartTime = `$from } -MaxEvents 100).Count
if (`$r.Gpu -and `$tdr -gt 0) { `$msgs += "El driver de la gráfica se reinició `$tdr veces: tu ajuste de la gráfica puede ser demasiado." }
@{ Last = (Get-Date).ToString('s'); BiosWarned = `$(if (`$bios -ne `$r.Bios) { `$bios } else { '' }); RamWarned = `$(if (`$r.RamSpeed -gt 0 -and [Math]::Abs(`$ram - `$r.RamSpeed) -gt 50) { `$ram } else { 0 }) } | ConvertTo-Json | Set-Content -LiteralPath `$statePath -Encoding UTF8
if (`$msgs.Count -eq 0) { return }
`$text = (`$msgs -join ' ') + ' Abre Win Juicer > Equipo para ver qué hacer.'
try {
    [void][Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
    [void][Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
    `$x = New-Object Windows.Data.Xml.Dom.XmlDocument
    `$x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Win Juicer</text><text>' + [Security.SecurityElement]::Escape(`$text) + '</text></binding></visual></toast>')
    [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show([Windows.UI.Notifications.ToastNotification]::new(`$x))
} catch {
    [void](New-Object -ComObject WScript.Shell).Popup(`$text, 0, 'Win Juicer', 48)
}
"@
}

function Get-JuicerTuneWatchDir { Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'WinJuicer' }

function Test-JuicerTuneWatch {
    if (-not (Test-JuicerWindows)) { return $false }
    $null -ne (Get-ScheduledTask -TaskName $script:TuneWatchTask -ErrorAction SilentlyContinue)
}

function Register-JuicerTuneWatch {
    if (-not (Test-JuicerWindows)) { return }
    $dir = Get-JuicerTuneWatchDir
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $script = Join-Path $dir 'vigilar-ajuste-fino.ps1'
    [IO.File]::WriteAllText($script, (Get-JuicerTuneWatchScript (Get-JuicerTunePath)), (New-Object Text.UTF8Encoding $true))
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$script`""
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT1M'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $script:TuneWatchTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Comprueba al iniciar sesión que el ajuste fino de Win Juicer sigue puesto y estable.' -Force | Out-Null
    Write-JuicerLog "Vigilancia del ajuste fino registrada: $script"
}

function Unregister-JuicerTuneWatch {
    if (Test-JuicerTuneWatch) { Unregister-ScheduledTask -TaskName $script:TuneWatchTask -Confirm:$false }
    Remove-Item -LiteralPath (Join-Path (Get-JuicerTuneWatchDir) 'vigilar-ajuste-fino.ps1'), (Join-Path (Get-JuicerTuneWatchDir) 'vigilar-estado.json') -Force -ErrorAction SilentlyContinue
}
