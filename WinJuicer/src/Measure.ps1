# Before and after: what the changes did to this PC, in numbers. The first
# measurement is kept as the starting point (taken on its own just before
# anything is applied for the first time) and every later one is compared
# with it. Boot time comes from Windows' own record of each boot, so it only
# changes after a restart; memory and processes depend on what is open, so
# they compare fairly only when both were measured the same way. On a laptop it
# also keeps the battery's health and the last resume from sleep, and every
# explicit measurement times how fast the desktop answers (a File Explorer window
# and Notepad, three runs each, the median): that one is only compared between
# measurements taken on the same power source, because a laptop on battery
# runs slower by design.

function Get-JuicerMetricsPath { Join-Path (Get-JuicerHome) 'medidas.json' }

# Windows times every boot (Diagnostics-Performance, event 100): to the
# desktop (Main) and then until startup programs settle (Post).
function Get-JuicerLastBoot {
    $e = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop)
    if ($e.Count -eq 0) { return $null }
    $data = @{}
    foreach ($d in ([xml]$e[0].ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
    @{ Total = [int]$data.BootTime; Main = [int]$data.MainPathBootTime; Post = [int]$data.BootPostBootTime; When = $e[0].TimeCreated }
}

# Responsiveness opens and closes real windows for a few seconds, so only the measurements the
# person asks for do it (not the one taken silently before the first change).
function Get-JuicerMetrics {
    param([string]$Label = 'Medida', [switch]$Responsiveness)
    $m = @{ Date = (Get-Date).ToString('s'); Label = $Label }
    if (-not (Test-JuicerWindows)) { return $m }
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
        $m.RamUsed = [int64]($os.TotalVisibleMemorySize - $os.FreePhysicalMemory) * 1KB
        $m.UptimeMin = [int]((Get-Date) - $os.LastBootUpTime).TotalMinutes
    } catch { Write-Verbose "Sin memoria: $_" }
    try {
        $b = Get-JuicerLastBoot
        if ($b) { $m.BootMs = $b.Total; $m.BootDate = $b.When.ToString('s') }
    } catch { Write-Verbose "Sin tiempo de arranque: $_" }
    # Event 100 does not say whether the boot was a full one or a Fast Startup (hybrid) one, so
    # what is kept is whether Fast Startup was on when measuring: it tells which kind of boot
    # a shutdown-and-start gives, and a change of it between two measurements changes the number.
    try {
        $hb = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled'
        if ($null -ne $hb -and $null -ne $hb.Value) { $m.FastStartup = ([int]$hb.Value -ne 0) }
    } catch { Write-Verbose "Sin inicio rápido: $_" }
    try { $m.PowerSource = Get-JuicerPowerSource } catch { Write-Verbose "Sin fuente de energía: $_" }
    $lap = Get-JuicerLaptopMetrics
    foreach ($k in @($lap.Keys)) { $m[$k] = $lap[$k] }
    if ($Responsiveness) {
        $resp = Invoke-JuicerResponsiveness
        if ($resp) {
            if ($null -ne $resp.ExplorerMs) { $m.ExplorerMs = [int]$resp.ExplorerMs }
            if ($null -ne $resp.NotepadMs) { $m.NotepadMs = [int]$resp.NotepadMs }
        }
    }
    $m.Processes = @(Get-Process -ErrorAction SilentlyContinue).Count
    $m.Services = @(Get-Service -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }).Count
    try { $m.Startup = @(Get-JuicerStartupItems | Where-Object { $_.Enabled }).Count } catch { Write-Verbose "Sin inicio: $_" }
    try {
        $d = [IO.DriveInfo]::new($env:SystemDrive)
        $m.DiskFree = [int64]$d.AvailableFreeSpace
    } catch { Write-Verbose "Sin espacio libre: $_" }
    $m
}

# Callers wrap it in @(): with one measurement it comes back as just that one.
function Read-JuicerMetrics {
    $path = Get-JuicerMetricsPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        $data = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
        @($data | Where-Object { $_ -is [hashtable] })
    } catch {
        Write-JuicerLog "medidas.json dañado, se ignora: $_"
    }
}

# The starting point and the last few: enough to compare, never a growing file.
function Save-JuicerMetrics {
    param([Parameter(Mandatory)][hashtable]$Metrics, [switch]$Reset)
    $list = @(if (-not $Reset) { Read-JuicerMetrics })
    $list += $Metrics
    if ($list.Count -gt 10) { $list = @($list[0]) + @($list | Select-Object -Last 9) }
    Write-JuicerTextAtomic (Get-JuicerMetricsPath) (ConvertTo-JuicerJson $list)
}

# Called before applying anything: the first time, that is the «before».
function Save-JuicerBaseline {
    if (@(Read-JuicerMetrics).Count -gt 0) { return }
    try { Save-JuicerMetrics (Get-JuicerMetrics 'Antes de aplicar ajustes') } catch { Write-JuicerLog "No se pudo medir antes de aplicar: $_" }
}

function Format-JuicerMetricValue {
    param([double]$Value, [string]$Unit)
    switch ($Unit) {
        's' { '{0:N1} s' -f ($Value / 1000) }
        'ms' { '{0:N0} ms' -f $Value }
        '%' { '{0:N0} %' -f $Value }
        'B' { Format-JuicerBytes ([int64][Math]::Abs($Value)) }
        default { '{0:N0}' -f $Value }
    }
}

function Format-JuicerMetricDelta {
    param([double]$Before, [double]$After, [string]$Unit)
    $d = $After - $Before
    $sign = if ($d -lt 0) { '−' } elseif ($d -gt 0) { '+' } else { '' }
    '{0} → {1} ({2}{3})' -f (Format-JuicerMetricValue $Before $Unit), (Format-JuicerMetricValue $After $Unit), $sign, (Format-JuicerMetricValue ([Math]::Abs($d)) $Unit)
}

# One finding per number that both measurements have. Lower is better for
# all of them except free disk space.
function Compare-JuicerMetrics {
    param([Parameter(Mandatory)][hashtable]$Before, [Parameter(Mandatory)][hashtable]$After)
    $area = 'Antes y después'
    $since = ([datetime]$Before.Date).ToString('g')
    $out = @(New-JuicerFinding $area 'Info' "Comparado con la medida del $since ($($Before.Label))")
    $rows = @(
        @{ Key = 'BootMs'; Name = 'Arranque completo'; Unit = 's'; Higher = $false; Noise = 0.05 }
        @{ Key = 'Startup'; Name = 'Programas, tareas y servicios de inicio'; Unit = ''; Higher = $false; Noise = 0 }
        @{ Key = 'Processes'; Name = 'Procesos en marcha'; Unit = ''; Higher = $false; Noise = 0.03 }
        @{ Key = 'Services'; Name = 'Servicios en marcha'; Unit = ''; Higher = $false; Noise = 0.02 }
        @{ Key = 'RamUsed'; Name = 'Memoria en uso'; Unit = 'B'; Higher = $false; Noise = 0.05 }
        @{ Key = 'DiskFree'; Name = "Espacio libre en $env:SystemDrive"; Unit = 'B'; Higher = $true; Noise = 0.01 }
        # Desktop responsiveness: only fair on the same power source (Power).
        @{ Key = 'ExplorerMs'; Name = 'Abrir una ventana del Explorador'; Unit = 'ms'; Higher = $false; Noise = 0.1; Power = $true }
        @{ Key = 'NotepadMs'; Name = 'Abrir el Bloc de notas'; Unit = 'ms'; Higher = $false; Noise = 0.1; Power = $true }
        # Laptop: how long the last resume from sleep took (a new event, not the same one) and how worn the battery is.
        @{ Key = 'ResumeMs'; Name = 'Última reanudación de la suspensión'; Unit = 's'; Higher = $false; Noise = 0.1; Date = 'ResumeDate' }
        @{ Key = 'BatteryPct'; Name = 'Salud de la batería'; Unit = '%'; Higher = $true; Noise = 0.01 }
    )
    $sources = @{ AC = 'enchufado'; DC = 'con batería' }
    $sameSource = $Before.PowerSource -and $After.PowerSource -and ([string]$Before.PowerSource -eq [string]$After.PowerSource)
    $skippedPower = $false
    foreach ($r in $rows) {
        if ($null -eq $Before[$r.Key] -or $null -eq $After[$r.Key]) { continue }
        if ($r.Power -and -not $sameSource) { $skippedPower = $true; continue }
        # The same event is not a new measurement.
        if ($r.Date -and $Before[$r.Date] -and $After[$r.Date] -and ([datetime]$After[$r.Date]) -eq ([datetime]$Before[$r.Date])) { continue }
        $b = [double]$Before[$r.Key]; $a = [double]$After[$r.Key]
        # PowerShell 7 reads the dates back from JSON as DateTime, 5.1 as text.
        if ($r.Key -eq 'BootMs' -and $Before.BootDate -and $After.BootDate -and ([datetime]$After.BootDate) -eq ([datetime]$Before.BootDate)) {
            $out += New-JuicerFinding $area 'Info' ('{0}: {1:N1} s, todavía el mismo arranque' -f $r.Name, ($a / 1000)) 'Reinicia el equipo, espera un par de minutos y vuelve a medir: Windows cronometra cada arranque.'
            continue
        }
        if ($r.Key -eq 'BootMs' -and $null -ne $Before.FastStartup -and $null -ne $After.FastStartup -and [bool]$Before.FastStartup -ne [bool]$After.FastStartup) {
            $kind = { param($on) if ($on) { 'con Inicio rápido (arranque híbrido tras apagar)' } else { 'sin Inicio rápido (arranque completo)' } }
            $out += New-JuicerFinding $area 'Info' 'Los dos arranques no son del mismo tipo: la comparación del arranque no es justa' "La medida inicial se tomó $(& $kind ([bool]$Before.FastStartup)) y esta $(& $kind ([bool]$After.FastStartup)). Un arranque híbrido es bastante más corto que uno completo. Reiniciar (no apagar) siempre hace un arranque completo: reinicia en las dos medidas para compararlas bien."
        }
        $change = if ($b -ne 0) { ($a - $b) / [Math]::Abs($b) } else { $a - $b }
        $better = if ($r.Higher) { $a -gt $b } else { $a -lt $b }
        $sev = if ([Math]::Abs($change) -le $r.Noise) { 'Info' } elseif ($better) { 'Ok' } else { 'Bajo' }
        $out += New-JuicerFinding $area $sev ('{0}: {1}' -f $r.Name, (Format-JuicerMetricDelta $b $a $r.Unit))
    }
    if ($skippedPower) {
        $was = if ($sources[[string]$Before.PowerSource]) { $sources[[string]$Before.PowerSource] } else { 'sin saber la fuente de energía' }
        $now = if ($sources[[string]$After.PowerSource]) { $sources[[string]$After.PowerSource] } else { 'sin saber la fuente de energía' }
        $out += New-JuicerFinding $area 'Info' 'La fluidez del escritorio no se compara: se midió con otra fuente de energía' "La medida inicial se tomó $was y esta $now. Con batería el portátil rinde menos a propósito, así que el resultado no sería justo. Vuelve a medir $was, o empieza una medida inicial nueva."
    } elseif ($null -eq $Before.ExplorerMs -and $null -eq $Before.NotepadMs -and ($null -ne $After.ExplorerMs -or $null -ne $After.NotepadMs)) {
        $out += New-JuicerFinding $area 'Info' 'La medida inicial no incluye la fluidez del escritorio' 'Pulsa «Nueva medida inicial» antes de aplicar ajustes y compárala después: la prueba abre y cierra una ventana del Explorador y el Bloc de notas tres veces cada uno, y guarda la mediana.'
    }
    # Memory and processes right after a boot and hours later are not the same
    # thing to compare.
    if ($null -ne $Before.UptimeMin -and $null -ne $After.UptimeMin) {
        $fresh = { param($u) [int]$u -le 30 }
        if ((& $fresh $Before.UptimeMin) -ne (& $fresh $After.UptimeMin)) {
            $out += New-JuicerFinding $area 'Info' 'Una medida se tomó recién encendido y la otra no' 'La memoria y los procesos dependen de lo que tengas abierto. Para compararlos bien, mide las dos veces recién reiniciado y con todo cerrado.'
        }
    }
    $out
}

# What the «Medir» buttons do: the first time, keep the starting point; after
# that, measure and compare with it. Callers wrap it in @().
function Invoke-JuicerMeasure {
    param([switch]$Reset)
    $list = @(Read-JuicerMetrics)
    $first = $Reset -or $list.Count -eq 0
    $now = Get-JuicerMetrics -Label $(if ($first) { 'Medida inicial' } else { 'Medida' }) -Responsiveness
    if ($first) {
        Save-JuicerMetrics $now -Reset:$Reset
        return (New-JuicerFinding 'Antes y después' 'Info' 'Medida inicial guardada' 'Aplica los ajustes, reinicia, espera un par de minutos y vuelve a medir: verás cuánto ha cambiado el arranque, los procesos y la memoria. En un portátil, mide siempre con la misma fuente de energía (enchufado o con batería).')
    }
    Save-JuicerMetrics $now
    Compare-JuicerMetrics $list[0] $now
}
