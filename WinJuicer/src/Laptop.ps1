# Laptop diagnostics: what the diagnosis can read about a portable PC that
# decides how it feels and how long it lasts. Battery wear, how long it took to
# wake from sleep, what wakes it or keeps it awake, which sleep states it has,
# old Wi-Fi and chipset drivers, and the few things that matter on 8 GB of RAM.
# Everything here only reads: the one change (hibernate after some hours) lives
# in the catalog, with its undo. Windows tools print in the language of the
# system, so the parsers look at structure (indentation, brackets, hexadecimal
# numbers, device paths), never at words; whatever cannot be parsed shows nothing
# rather than a wrong sentence.

$script:SubSleepGuid = '238c9fa8-0aad-41ed-83f4-97be242c8f20'
$script:HibernateIdleGuid = '9d7815a6-7ee4-497e-8888-515a05f02364'
# How long a suspended laptop on battery waits before it hibernates: 3 hours.
$script:HibernateIdleSeconds = 10800
$script:PerfLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'

# --- Small helpers -------------------------------------------------------------

function Get-JuicerMedian {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if ($v.Count -eq 0) { return $null }
    $mid = [int][Math]::Floor([double]$v.Count / 2)
    if ($v.Count % 2 -eq 1) { return [int][Math]::Round([double]$v[$mid]) }
    [int][Math]::Round(([double]$v[$mid - 1] + [double]$v[$mid]) / 2)
}

# A whole number from text, or $null: Windows prints numbers the way its language does, and a
# field that is not one must not turn into a zero.
function ConvertTo-JuicerLong {
    param([string]$Text)
    $v = [int64]0
    if ([int64]::TryParse(([string]$Text).Trim(), [Globalization.NumberStyles]::Integer, [Globalization.CultureInfo]::InvariantCulture, [ref]$v)) { return $v }
    $null
}

function Get-JuicerXmlText {
    param($Node, [string]$Name)
    if (-not $Node) { return '' }
    $n = $Node.SelectSingleNode("*[local-name()='$Name']")
    if ($n) { return [string]$n.InnerText }
    ''
}

function Get-JuicerXmlAttribute {
    param($Node, [string]$Name)
    foreach ($a in @($Node.Attributes)) {
        if ($a -and $a.LocalName -eq $Name) { return [string]$a.Value }
    }
    ''
}

# A native tool's text as lines, whatever its line endings.
function Split-JuicerLines {
    param([string]$Text)
    @(([string]$Text) -split "`r?`n")
}

# --- Battery health --------------------------------------------------------------

# Seconds of an ISO 8601 duration («PT1H2M3S») or of a plain number; $null when it is neither.
function ConvertFrom-JuicerDuration {
    param([string]$Text)
    if (-not $Text) { return $null }
    try { return [Xml.XmlConvert]::ToTimeSpan($Text).TotalSeconds } catch { Write-Verbose "Duración ilegible: $_" }
    $d = [double]0
    if ([double]::TryParse($Text, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    $null
}

# `powercfg /batteryreport /xml`: every <Battery> with DesignCapacity, FullChargeCapacity and
# CycleCount (mWh and count), whatever the XML namespace and with any of them missing. Returns
# one summary or $null: @{ Count; Design; Full; Cycles; Percent; AcShare }. Several batteries add
# their capacities; the cycles are the highest one. AcShare (0 to 1, or $null) is the share of
# the recent usage that was spent plugged in, when the report's usage entries say so.
function ConvertFrom-JuicerBatteryReport {
    param([string]$Xml)
    if (-not $Xml -or -not $Xml.Trim()) { return $null }
    try { $doc = [xml]$Xml } catch { Write-Verbose "Informe de batería ilegible: $_"; return $null }
    $design = [int64]0; $full = [int64]0; $count = 0; $cycles = $null
    foreach ($b in @($doc.SelectNodes("//*[local-name()='Batteries']/*[local-name()='Battery']"))) {
        $d = ConvertTo-JuicerLong (Get-JuicerXmlText $b 'DesignCapacity')
        $f = ConvertTo-JuicerLong (Get-JuicerXmlText $b 'FullChargeCapacity')
        # A battery that does not say both numbers (or says zero) cannot be judged.
        if ($null -eq $d -or $null -eq $f -or $d -le 0 -or $f -le 0) { continue }
        $design += $d; $full += $f; $count++
        $c = ConvertTo-JuicerLong (Get-JuicerXmlText $b 'CycleCount')
        if ($null -ne $c -and $c -ge 0 -and ($null -eq $cycles -or $c -gt $cycles)) { $cycles = $c }
    }
    if ($count -eq 0) { return $null }
    $ac = 0.0; $total = 0.0
    foreach ($u in @($doc.SelectNodes("//*[local-name()='RecentUsage']/*[local-name()='UsageEntry']"))) {
        $secs = ConvertFrom-JuicerDuration (Get-JuicerXmlAttribute $u 'Duration')
        $flag = (Get-JuicerXmlAttribute $u 'Ac').Trim().ToLowerInvariant()
        if ($null -eq $secs -or $secs -le 0 -or $flag -eq '') { continue }
        $total += $secs
        if ($flag -in '1', 'true') { $ac += $secs }
    }
    @{
        Count = $count; Design = $design; Full = $full; Cycles = $cycles
        Percent = [int][Math]::Min(100.0, [Math]::Round(100.0 * $full / $design))
        AcShare = $(if ($total -gt 0) { $ac / $total } else { $null })
    }
}

# Runs powercfg through the backend into a file of its own inside Win Juicer's folder (powercfg
# only writes reports to files), reads it and removes it. $null when there is no battery or the
# report could not be read.
function Get-JuicerBatteryHealth {
    $path = Join-Path (Get-JuicerHome) ('bateria-' + [guid]::NewGuid().ToString('N') + '.xml')
    try {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/batteryreport', '/xml', '/output', $path) -TimeoutSec 30
        if ($r.Code -ne 0 -or -not (Test-Path -LiteralPath $path)) { return $null }
        return (ConvertFrom-JuicerBatteryReport ([IO.File]::ReadAllText($path)))
    } catch {
        Write-Verbose "Sin informe de batería: $_"
        return $null
    } finally {
        Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
    }
}

function Get-JuicerBatteryFindings {
    param($Battery)
    if (-not $Battery) { return }
    $title = "Tu batería conserva el $($Battery.Percent) % de su capacidad original"
    if ($null -ne $Battery.Cycles -and [int64]$Battery.Cycles -gt 0) { $title += ' (' + (Format-JuicerCount ([int]$Battery.Cycles) 'ciclo') + ')' }
    $detail = 'Capacidad de diseño: {0:N0} mWh; hoy carga como máximo {1:N0} mWh. El desgaste de una batería es normal y no se arregla con ajustes de Windows.' -f $Battery.Design, $Battery.Full
    $sev = 'Info'
    if ($Battery.Percent -lt 60) {
        $sev = 'Medio'
        $detail += ' Por debajo del 60 % la autonomía se nota muy recortada: lo que la devuelve es cambiar la batería. Mientras tanto, menos brillo y menos programas abiertos alargan lo que queda.'
    }
    # The vendors' own software does this; Win Juicer never writes to it.
    $limit = 'Muchos fabricantes (Lenovo Vantage, Dell Power Manager, MyASUS, HP Support Assistant…) permiten limitar la carga al 80 %, y eso alarga la vida de la batería. Win Juicer no toca ese ajuste: está en el programa de tu fabricante.'
    if ($null -ne $Battery.AcShare -and [double]$Battery.AcShare -ge 0.7) {
        $detail += (' Pasa el {0:N0} % del tiempo enchufado: ' -f (100 * [double]$Battery.AcShare)) + $limit
    } elseif ($null -eq $Battery.AcShare) {
        $detail += ' Si lo usas casi siempre enchufado: ' + $limit
    }
    New-JuicerFinding 'Portátil' $sev $title $detail
}

# --- Resuming from sleep ------------------------------------------------------------

# Diagnostics-Performance writes event 100 for boots (Measure.ps1) and 300 for resuming from
# standby. Which data field holds the resume time is not documented the same way everywhere, so
# the known names come first and then any field with «Resume» and a time-like word in its name;
# the value is milliseconds, like the boot ones. Nothing plausible (zero, or over ten minutes)
# is no data.
$script:ResumeFieldNames = @('ResumeDuration', 'TotalResumeDuration', 'ResumeTime', 'ResumeLatency', 'ExitLatency')

function ConvertFrom-JuicerResumeEvent {
    param($EventRecord)
    if (-not $EventRecord) { return $null }
    $data = @{}
    try {
        foreach ($d in ([xml]$EventRecord.ToXml()).Event.EventData.Data) { $data[[string]$d.Name] = [string]$d.'#text' }
    } catch {
        Write-Verbose "Evento de reanudación ilegible: $_"
        return $null
    }
    $ms = $null
    $names = @($script:ResumeFieldNames) + @($data.Keys | Where-Object { $_ -match 'Resume' -and $_ -match 'Time|Duration|Latency' } | Sort-Object)
    foreach ($n in $names) {
        if (-not $data.ContainsKey($n)) { continue }
        $v = ConvertTo-JuicerLong $data[$n]
        if ($null -ne $v -and $v -gt 0 -and $v -le 600000) { $ms = [int]$v; break }
    }
    if ($null -eq $ms) { return $null }
    @{ Ms = $ms; When = $EventRecord.TimeCreated }
}

# The newest resume of the last two months Windows timed, or $null.
function Get-JuicerLastResume {
    param([int]$Days = 60)
    $events = Get-JuicerEvents @{ LogName = $script:PerfLog; Id = 300; StartTime = (Get-Date).AddDays(-$Days) }
    if ($null -eq $events) { return $null }
    foreach ($e in @($events | Sort-Object { $_.TimeCreated } -Descending)) {
        $r = ConvertFrom-JuicerResumeEvent $e
        if ($r) { return $r }
    }
    $null
}

function Get-JuicerResumeFindings {
    param($Resume)
    if (-not $Resume) { return }
    $s = [double]$Resume.Ms / 1000
    $sev = if ($s -gt 10) { 'Medio' } else { 'Info' }
    $detail = 'Es lo que Windows midió al volver de la suspensión.'
    if ($sev -eq 'Medio') { $detail += ' Más de 10 segundos puede deberse a un driver que tarda en despertar (red, gráficos, táctil) o a programas que se reactivan a la vez: actualiza los drivers del Wi-Fi y de la gráfica, y revisa la pestaña Arranque.' }
    New-JuicerFinding 'Portátil' $sev ('La última reanudación tardó {0:N1} s ({1})' -f $s, ([datetime]$Resume.When).ToString('g')) $detail
}

# --- What wakes the laptop and what keeps it awake -------------------------------------

# `powercfg /lastwake`: one record per «Wake Source [n]» (any text ending in [number]), each a
# list of «label: value» lines. A device is told by its instance path (PCI\VEN_…, ACPI\…, USB\…),
# and its friendly name is the value that follows the path. Records without a path give their
# second value (what a timer or a fixed button says after its type). Returns the names, once each.
function ConvertFrom-JuicerLastWake {
    param([string]$Text)
    $records = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in (Split-JuicerLines $Text)) {
        if ($line -match '\[\d+\]\s*$') {
            $cur = New-Object System.Collections.ArrayList
            [void]$records.Add($cur)
            continue
        }
        # $null, not falsy: a record that has just begun is an empty list, and
        # an empty list counts as false in PowerShell.
        if ($null -ne $cur -and $line -match '^\s*[^:]+?\s*:\s*(.*?)\s*$') { [void]$cur.Add([string]$Matches[1]) }
    }
    $names = @()
    foreach ($r in $records) {
        $values = @($r)
        $pathAt = -1
        for ($i = 0; $i -lt $values.Count; $i++) {
            if ($values[$i] -match '^[A-Za-z0-9_\-\.]+\\\S') { $pathAt = $i; break }
        }
        $name = ''
        if ($pathAt -ge 0) {
            for ($i = $pathAt + 1; $i -lt $values.Count; $i++) {
                if ($values[$i]) { $name = $values[$i]; break }
            }
            if (-not $name) { $name = $values[$pathAt] }
        } elseif ($values.Count -ge 2) {
            $name = $values[1]
        }
        # A timer or a driver says its program's path: the program is what matters.
        $exe = Get-JuicerExeName $name
        if ($exe) { $name = $exe }
        if ($name -and $names -notcontains $name) { $names += $name }
    }
    $names
}

# The last segment of a path (Windows or NT device path) that names a program, else $null.
function Get-JuicerExeName {
    param([string]$Text)
    $m = [regex]::Matches([string]$Text, '\\([^\\\r\n]+?\.exe)\b', 'IgnoreCase')
    if ($m.Count -gt 0) { return $m[$m.Count - 1].Groups[1].Value }
    $null
}

# `powercfg /waketimers`: each timer is a line with a [TAG] and the program's path, followed by
# an indented line that, for a scheduled task, quotes the task's path. Names the task when there
# is one, else the program. Nothing when there are no timers.
function ConvertFrom-JuicerWakeTimers {
    param([string]$Text)
    $lines = @(Split-JuicerLines $Text)
    $names = @()
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -notmatch '^\S.*\[[^\]\s]+\]\s*\S') { continue }
        $exe = Get-JuicerExeName $lines[$i]
        $task = $null
        if ($i + 1 -lt $lines.Count -and $lines[$i + 1] -match "'(\\[^']+)'") { $task = $Matches[1].TrimStart('\') }
        $name = if ($task) { $task } else { $exe }
        if ($name -and $names -notcontains $name) { $names += $name }
    }
    $names
}

# `powercfg /requests`: sections («DISPLAY:», «SYSTEM:»…) with entries «[PROCESS] path» and the
# reason on the line after. What keeps the laptop from sleeping is the system section and the
# execution one. Sections are known by their English or Spanish name or French; failing that,
# by their place in the list (display, system, away mode, execution, …). Returns
# @{ Name; Reason } per entry, once each.
function ConvertFrom-JuicerPowerRequests {
    param([string]$Text)
    $sections = New-Object System.Collections.ArrayList
    $cur = $null
    $last = $null
    foreach ($line in (Split-JuicerLines $Text)) {
        if (-not $line.Trim()) { continue }
        if ($line -match '^\S.*:\s*$' -and $line -notmatch '^\[') {
            $head = $line.Trim().TrimEnd(':').Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', ''
            $cur = @{ Head = $head.ToUpperInvariant(); Entries = (New-Object System.Collections.ArrayList) }
            [void]$sections.Add($cur)
            $last = $null
            continue
        }
        if (-not $cur) { continue }
        if ($line -match '^\s*\[[^\]]+\]\s*(.+?)\s*$') {
            $target = $Matches[1]
            $exe = Get-JuicerExeName $target
            $last = @{ Name = $(if ($exe) { $exe } else { $target }); Reason = '' }
            [void]$cur.Entries.Add($last)
        } elseif ($last -and -not $last.Reason) {
            $last.Reason = $line.Trim()
        }
    }
    $known = @($sections | Where-Object { $_.Head -match '^(SYSTEM|SISTEMA|SYSTEME|EXECUTION|EJECUCION)' }).Count -gt 0
    $out = @()
    for ($i = 0; $i -lt $sections.Count; $i++) {
        $s = $sections[$i]
        $keeps = if ($known) { $s.Head -match '^(SYSTEM|SISTEMA|SYSTEME|EXECUTION|EJECUCION)' } else { $sections.Count -ge 4 -and ($i -eq 1 -or $i -eq 3) }
        if (-not $keeps) { continue }
        foreach ($e in $s.Entries) {
            if (-not (@($out | Where-Object { $_.Name -eq $e.Name }).Count)) { $out += @{ Name = $e.Name; Reason = $e.Reason } }
        }
    }
    $out
}

# What the three powercfg reports say. Each part is empty when the tool fails or prints nothing
# understandable (it needs administrator rights for some of them).
function Get-JuicerWakeInfo {
    $info = @{ LastWake = @(); Timers = @(); Requests = @() }
    try {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/lastwake')
        if ($r.Code -eq 0) { $info.LastWake = @(ConvertFrom-JuicerLastWake $r.Output) }
    } catch { Write-Verbose "Sin /lastwake: $_" }
    try {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/waketimers')
        if ($r.Code -eq 0) { $info.Timers = @(ConvertFrom-JuicerWakeTimers $r.Output) }
    } catch { Write-Verbose "Sin /waketimers: $_" }
    try {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/requests')
        if ($r.Code -eq 0) { $info.Requests = @(ConvertFrom-JuicerPowerRequests $r.Output) }
    } catch { Write-Verbose "Sin /requests: $_" }
    $info
}

function Get-JuicerWakeFindings {
    param($Info)
    if (-not $Info) { return }
    $area = 'Portátil'
    foreach ($n in @($Info.LastWake | Select-Object -First 3)) {
        New-JuicerFinding $area 'Info' "Lo último que despertó al portátil: $n" 'Windows lo guarda de la última vez que salió de la suspensión. Si no tocaste el teclado, el ratón ni la tapa, es lo que lo despierta solo (en la mochila, gastando batería): en el Administrador de dispositivos, Propiedades > Administración de energía del adaptador de red o del dispositivo, quita «Permitir que este dispositivo reactive el equipo».'
    }
    foreach ($n in @($Info.Timers | Select-Object -First 3)) {
        New-JuicerFinding $area 'Info' "Un temporizador puede despertar al portátil: $n" 'Es una tarea programada con permiso para despertar el equipo (actualizaciones, mantenimiento…). Se cambia en Opciones de energía > Configuración avanzada > Suspender > «Permitir temporizadores de reactivación».'
    }
    foreach ($e in @($Info.Requests | Select-Object -First 5)) {
        $detail = 'Mientras siga así, Windows no suspende el equipo.'
        if ($e.Reason) { $detail = "$($e.Reason). $detail" }
        New-JuicerFinding $area 'Info' "Impide la suspensión: $($e.Name)" ($detail + ' Es normal si está reproduciendo o descargando; si no es el caso, ciérralo.')
    }
}

# --- Sleep states ---------------------------------------------------------------------

# `powercfg /a`: two lists, the states available and the ones not (each with its reasons). The
# headers are in the language of Windows, but their order is not: the first list is the
# available one. A state carries «(S3)» or «(S0 Low Power Idle)»; hibernation and fast startup
# have no such token and are read from the registry instead. $null when the two lists are not
# both there.
function ConvertFrom-JuicerSleepStates {
    param([string]$Text)
    $sections = New-Object System.Collections.ArrayList
    $cur = $null
    foreach ($line in (Split-JuicerLines $Text)) {
        if (-not $line.Trim()) { continue }
        if ($line -match '^\S.*:\s*$') {
            $cur = New-Object System.Collections.ArrayList
            [void]$sections.Add($cur)
            continue
        }
        if ($null -ne $cur) { [void]$cur.Add($line) }
    }
    if ($sections.Count -lt 2) { return $null }
    $tokens = {
        param($lines)
        @($lines | ForEach-Object { [regex]::Matches([string]$_, '\(S([0-9])') } | ForEach-Object { 'S' + $_.Groups[1].Value } | Select-Object -Unique)
    }
    $available = @(& $tokens $sections[0])
    @{ Available = $available; S3 = ($available -contains 'S3'); S0 = ($available -contains 'S0') }
}

function Get-JuicerSleepStates {
    try {
        $r = Invoke-JuicerNative 'powercfg.exe' @('/a')
        if ($r.Code -eq 0) { return (ConvertFrom-JuicerSleepStates $r.Output) }
    } catch { Write-Verbose "Sin /a: $_" }
    $null
}

# Hibernation: the file exists (HibernateEnabled), and fast startup is on and can work.
function Get-JuicerHibernateState {
    $o = @{ Hibernate = $false; FastStartup = $false }
    try {
        $h = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
        $o.Hibernate = [bool]($h -and $null -ne $h.Value -and [int]$h.Value -eq 1)
        $f = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
        $o.FastStartup = [bool]($o.Hibernate -and $f -and $null -ne $f.Value -and [int]$f.Value -ne 0)
    } catch { Write-Verbose "Sin estado de hibernación: $_" }
    $o
}

function Get-JuicerSleepFindings {
    param($States, $Hibernation)
    if (-not $States -or (-not $States.S3 -and -not $States.S0)) { return }
    $tail = ''
    if ($Hibernation) {
        $tail = ' Hibernación: ' + $(if ($Hibernation.Hibernate) { 'disponible' } else { 'desactivada' }) + '. Inicio rápido: ' + $(if ($Hibernation.FastStartup) { 'activado' } else { 'desactivado' }) + '.'
    }
    if ($States.S0) {
        New-JuicerFinding 'Portátil' 'Info' 'Tu portátil usa Modern Standby (S0) al suspenderse' ('Cuando lo suspendes (o cierras la tapa) sigue «medio despierto»: conectado a la red y recibiendo avisos, y por eso gasta más batería que una suspensión clásica y puede calentarse en la mochila. Es cosa del firmware: Windows no deja cambiarlo. Lo que sí puedes hacer es que, tras unas horas, pase a hibernación y no gaste nada (ajuste «Hibernar tras unas horas de suspensión»).' + $tail) 'energia.hibernar'
    } else {
        New-JuicerFinding 'Portátil' 'Info' 'Tu portátil se suspende de forma clásica (S3)' ('En suspensión S3 sólo la memoria sigue con corriente: gasta muy poco y se reanuda rápido. No hace falta cambiar nada; si lo dejas suspendido días sin cargador, la hibernación evita que la batería llegue a cero.' + $tail)
    }
}

# --- Hibernate after some hours (the tweak's reads) ---------------------------------------------

# The seconds the active plan waits, suspended on battery, before hibernating (0 = never);
# $null when powercfg does not say. The last two numbers of /qh are the plugged-in and battery values.
function Get-JuicerHibernateIdle {
    $r = Invoke-JuicerNative 'powercfg.exe' @('/qh', 'SCHEME_CURRENT', 'SUB_SLEEP', 'HIBERNATEIDLE')
    $v = ConvertFrom-JuicerPowerSetting $r.Output
    if ($v) { return [int64]$v.DC }
    $null
}

function Test-JuicerHibernateAvailable {
    $h = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled'
    [bool]($h -and $null -ne $h.Value -and [int]$h.Value -eq 1)
}

# --- Driver age ------------------------------------------------------------------------------

# Wi-Fi and chipset drivers by the date Windows has on record. The drivers that come inside
# Windows carry the date of the system (2006 for many) and say Microsoft: they are left out. The
# graphics driver has its own finding in Gráfica, which is stricter, so it is not repeated here.
# Drivers are @{ Class; Name; Manufacturer; Provider; Date }.
function Get-JuicerDriverFindings {
    param([object[]]$Drivers = @(), [datetime]$Now = (Get-Date))
    $area = 'Portátil'
    $months = { param($d, $when) [int][Math]::Floor(($when - [datetime]$d).TotalDays / 30.4375) }
    $notMicrosoft = { param($d) ([string]$d.Provider + ' ' + [string]$d.Manufacturer) -notmatch 'Microsoft' }
    $wifi = '(Wi-?Fi|Wireless|WLAN|802\.11|Centrino|\bAX\d{3}\b|\bAC ?\d{4}\b)'
    $virtual = 'Virtual|Miniport|Bluetooth|\bWAN\b|Hyper-V|VPN|TAP-|Wintun|Loopback|Ethernet|Gigabit|Direct'
    $seen = @()
    foreach ($d in @($Drivers | Where-Object { $_ -and $_.Class -eq 'NET' -and $_.Date -and $_.Name -match $wifi -and $_.Name -notmatch $virtual -and (& $notMicrosoft $_) })) {
        if ($seen -contains $d.Name) { continue }
        $seen += $d.Name
        $m = & $months $d.Date $Now
        if ($m -le 36) { continue }
        $where = if (([string]$d.Name + ' ' + [string]$d.Manufacturer) -match 'Intel') { 'la web de Intel: https://www.intel.com/content/www/us/en/support/detect.html' } else { 'la web de soporte de tu portátil o del fabricante del chip (Realtek, MediaTek, Qualcomm…)' }
        New-JuicerFinding $area 'Bajo' ('El driver del Wi-Fi ({0}) tiene más de {1} años (de {2})' -f $d.Name, [int][Math]::Floor([double]$m / 12), ([datetime]$d.Date).ToString('d')) "Los drivers nuevos corrigen desconexiones y reconexiones lentas tras suspender. Descarga el más reciente de $where."
    }
    $chip = @($Drivers | Where-Object { $_ -and $_.Class -eq 'SYSTEM' -and $_.Date -and ([string]$_.Manufacturer + ' ' + [string]$_.Provider) -match 'Intel|Advanced Micro Devices|AMD' -and (& $notMicrosoft $_) } | Sort-Object { [datetime]$_.Date } -Descending)
    # The newest of them: a chipset has dozens of small devices and some never change.
    if ($chip.Count -gt 0) {
        $m = & $months $chip[0].Date $Now
        if ($m -gt 36) {
            New-JuicerFinding $area 'Bajo' ('El driver del chipset tiene más de {0} años (de {1})' -f [int][Math]::Floor([double]$m / 12), ([datetime]$chip[0].Date).ToString('d')) 'El del chipset trae el control de energía de la placa (suspensión, ahorro de batería). Descárgalo de la web de soporte de tu portátil, que es donde está el que ha probado el fabricante.'
        }
    }
}

# --- 8 GB of RAM ---------------------------------------------------------------------------------

# State: @{ Compression; CommitPct }, each $null when unknown. Compression is never turned off
# by Win Juicer: compressing a page is far quicker than writing it to disk.
function Get-JuicerLowRamFindings {
    param([int64]$RamBytes, $State, [int]$StartupCount = -1)
    if ($RamBytes -le 0 -or $RamBytes -gt 8.5GB) { return }
    $area = 'Memoria'
    $gb = [int][Math]::Round($RamBytes / 1GB)
    $detail = "Con $gb GB lo que más se nota es abrir menos cosas a la vez. En Edge, activa «Pestañas en suspensión» (edge://settings/system): las pestañas sin uso se duermen y liberan su memoria. En Chrome, «Ahorro de memoria» (chrome://settings/performance)."
    if ($StartupCount -gt 0) { $detail += " Tienes $StartupCount programas, tareas y servicios arrancando con Windows: en la pestaña Arranque (Programas de inicio) desactiva los que no uses." }
    if ($State -and $State.Compression -eq $true) { $detail += ' La compresión de memoria está activada, que es lo que conviene; Win Juicer no la apaga.' }
    New-JuicerFinding $area 'Info' "Tu portátil tiene $gb GB de RAM: cómo sacarle partido" $detail
    if ($State -and $null -ne $State.CommitPct -and [double]$State.CommitPct -gt 85) {
        New-JuicerFinding $area 'Medio' ('La memoria comprometida está al {0:N0} %' -f [double]$State.CommitPct) 'Es la parte de lo que Windows puede prometer (RAM más archivo de paginación) que ya está prometida. Cerca del 100 % los programas empiezan a ir a tirones o a cerrarse. Cierra lo que no uses y no desactives el archivo de paginación: no ayuda.'
    }
    if ($State -and $State.Compression -eq $false) {
        New-JuicerFinding $area 'Bajo' 'La compresión de memoria está desactivada' 'Comprimir una página en RAM es mucho más rápido que escribirla a disco, y con poca RAM se nota. Reparación la vuelve a activar («Reactivar la compresión de memoria»), y después hay que reiniciar. Win Juicer nunca la apaga.'
    }
}

# --- Storage Sense -----------------------------------------------------------------------------------

# True or false when Windows has written the on/off switch of Storage Sense (value «01»); $null when it has not
# (the default depends on the Windows version, and a missing switch is not «off»).
function Get-JuicerStorageSenseState {
    $v = Read-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy' '01'
    if ($v -and $null -ne $v.Value) { return ([int]$v.Value -ne 0) }
    $null
}

# A hint, only when the disk is short of space and Windows has written the switch as off.
function Get-JuicerStorageSenseFinding {
    param([bool]$Low, $State, [string]$Drive = 'C:')
    if (-not $Low -or $State -ne $false) { return }
    New-JuicerFinding 'Disco' 'Bajo' "El Sensor de almacenamiento está apagado y ${Drive} va justo de espacio" 'Con el Sensor, Windows borra solo temporales y lo que lleve tiempo en la papelera cuando queda poco sitio, sin que tengas que acordarte. Es un ajuste a la carta: sólo enciende el interruptor, sin tocar el resto de sus opciones.' 'disco.sensor'
}

# --- Desktop responsiveness ------------------------------------------------------------------------------

# AC (plugged in or a desktop) or DC (on battery): comparing fluidity across the two is not fair.
function Get-JuicerPowerSource {
    if (Test-JuicerOnBattery) { return 'DC' }
    'AC'
}

# @{ ExplorerMs; NotepadMs } in milliseconds, or $null. Opens and closes real windows.
function Invoke-JuicerResponsiveness {
    try { return (& (Get-JuicerBackend).Responsiveness) } catch { Write-Verbose "Sin medida de fluidez: $_"; return $null }
}

function Get-JuicerPnpDrivers {
    try { return @(& (Get-JuicerBackend).Drivers) } catch { Write-Verbose "Sin drivers: $_"; return @() }
}

function Get-JuicerMemoryState {
    try { return (& (Get-JuicerBackend).MemoryState) } catch { Write-Verbose "Sin estado de memoria: $_"; return $null }
}

# What Antes y después keeps about a laptop in each snapshot: the battery's health, and how long the last resume
# took. Each only when readable; a desktop has neither.
function Get-JuicerLaptopMetrics {
    $m = @{}
    try {
        if (-not (Test-JuicerLaptop)) { return $m }
        $b = Get-JuicerBatteryHealth
        if ($b) { $m.BatteryPct = [int]$b.Percent }
        $r = Get-JuicerLastResume
        if ($r) { $m.ResumeMs = [int]$r.Ms; $m.ResumeDate = ([datetime]$r.When).ToString('s') }
    } catch { Write-Verbose "Sin medidas de portátil: $_" }
    $m
}

# --- The diagnosis section -------------------------------------------------------------------------------------

function Get-JuicerLaptopAudit {
    if (-not (Test-JuicerLaptop)) { return @() }
    $out = @()
    try { $out += @(Get-JuicerBatteryFindings (Get-JuicerBatteryHealth)) } catch { Write-Verbose "Sin batería: $_" }
    try { $out += @(Get-JuicerResumeFindings (Get-JuicerLastResume)) } catch { Write-Verbose "Sin reanudación: $_" }
    try { $out += @(Get-JuicerWakeFindings (Get-JuicerWakeInfo)) } catch { Write-Verbose "Sin despertares: $_" }
    try { $out += @(Get-JuicerSleepFindings (Get-JuicerSleepStates) (Get-JuicerHibernateState)) } catch { Write-Verbose "Sin estados de suspensión: $_" }
    try { $out += @(Get-JuicerDriverFindings (Get-JuicerPnpDrivers)) } catch { Write-Verbose "Sin drivers: $_" }
    try {
        $ram = [int64](Get-JuicerHardwareProfile).RamBytes
        $startup = -1
        try { $startup = @(Get-JuicerStartupItems | Where-Object { $_.Enabled }).Count } catch { Write-Verbose "Sin inicio: $_" }
        $out += @(Get-JuicerLowRamFindings $ram (Get-JuicerMemoryState) $startup)
    } catch { Write-Verbose "Sin memoria: $_" }
    $out
}
