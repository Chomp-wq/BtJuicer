# Measuring a game: FPS, 1 % and 0.1 % lows, stutters, and what limits it
# (the processor or the graphics card), with PresentMon, Intel's open source
# tool that reviewers and CapFrameX use. The only way to know whether a change
# gave frames is to measure the same scene before and after; this is that
# measurement, kept per game so the next one is compared with it.
#
# PresentMon is downloaded the first time from its GitHub release and its
# Intel signature is checked every time before it runs: the folder it lives
# in is under ProgramData, and it runs as administrator.

$script:PresentMonVersion = '2.3.1'
$script:PresentMonUrl = "https://github.com/GameTechDev/PresentMon/releases/download/v$script:PresentMonVersion/PresentMon-$script:PresentMonVersion-x64.exe"

# What presents frames without being the game: the desktop, the shell,
# launchers and overlays. The game is the busiest of the rest.
$script:NotGames = @(
    'dwm.exe', 'explorer.exe', 'ShellExperienceHost.exe', 'StartMenuExperienceHost.exe', 'SearchHost.exe', 'TextInputHost.exe',
    'ApplicationFrameHost.exe', 'msedgewebview2.exe', 'steamwebhelper.exe', 'EpicWebHelper.exe', 'Overwolf.exe', 'GameBar.exe',
    'XboxGameBarWidgets.exe', 'NVIDIA Overlay.exe', 'RadeonSoftware.exe', 'Discord.exe', 'powershell.exe', 'pwsh.exe', 'WindowsTerminal.exe'
)

function Get-JuicerPresentMonPath { Join-Path (Join-Path (Get-JuicerHome) 'herramientas') "PresentMon-$script:PresentMonVersion-x64.exe" }

function Test-JuicerIntelSignature {
    param([string]$Path)
    $s = Get-AuthenticodeSignature -LiteralPath $Path -ErrorAction SilentlyContinue
    $s -and $s.Status -eq 'Valid' -and $s.SignerCertificate -and $s.SignerCertificate.Subject -match 'O="?Intel Corporation'
}

# The path to a PresentMon whose signature has just been checked.
function Get-JuicerPresentMon {
    $path = Get-JuicerPresentMonPath
    if ((Test-Path -LiteralPath $path) -and (Test-JuicerIntelSignature $path)) { return $path }
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $tmp = "$path.descarga"
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $progress = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    try {
        Invoke-WebRequest -Uri $script:PresentMonUrl -OutFile $tmp -UseBasicParsing -ErrorAction Stop
    } catch {
        throw "No se pudo descargar PresentMon de GitHub: $_"
    } finally {
        $ProgressPreference = $progress
    }
    if (-not (Test-JuicerIntelSignature $tmp)) {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        throw 'El PresentMon descargado no lleva una firma válida de Intel. No se ejecuta.'
    }
    Move-Item -LiteralPath $tmp -Destination $path -Force
    Write-JuicerLog "PresentMon $script:PresentMonVersion descargado en $path"
    $path
}

# --- Reading the frames ------------------------------------------------------

function ConvertTo-JuicerNumber {
    param($Value)
    $d = 0.0
    if ([double]::TryParse([string]$Value, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d }
    $null
}

# The first column of these that the CSV has: PresentMon 2.3 names them
# FrameTime, GPUBusy…; later versions MsBetweenAppStart, MsGPUBusy…
function Get-JuicerFrameColumn {
    param([string[]]$Columns, [string[]]$Names)
    foreach ($n in $Names) { if ($Columns -contains $n) { return $n } }
    $null
}

# Which application the capture is about: the one asked for, or the one that
# presented the most frames and is not part of Windows or a launcher.
function Select-JuicerGameRows {
    param([object[]]$Rows, [string]$Process)
    if (@($Rows).Count -eq 0) { return @() }
    $groups = @($Rows | Group-Object Application)
    if ($Process) {
        $g = @($groups | Where-Object { $_.Name -eq $Process -or $_.Name -eq "$Process.exe" })
    } else {
        $g = @($groups | Where-Object { $script:NotGames -notcontains $_.Name } | Sort-Object Count -Descending)
    }
    if ($g.Count -eq 0) { return @() }
    @($g[0].Group)
}

function Get-JuicerPercentile {
    param([double[]]$Sorted, [double]$Q)
    if ($Sorted.Count -eq 0) { return 0 }
    $Sorted[[Math]::Max(0, [Math]::Min($Sorted.Count - 1, [int][Math]::Ceiling($Q * $Sorted.Count) - 1))]
}

# Numbers for one game's frames. Lows are the FPS at the 99th and 99.9th
# percentile frame time: the slowest 1 % and 0.1 % of frames, which is what
# a stutter feels like. A stutter is a frame that takes twice the median and
# at least 8 ms more.
#
# And how even the pace is, which is what the frame pacer is judged by:
# Steady, the share of frames within 4 % (at least 0.3 ms) of the median;
# JitterMs, how much one frame time differs from the next, on average;
# WorkMs95, the 95th percentile of the time the processor or the graphics
# card was actually busy on a frame (the rest of the frame time is the cap
# waiting), so under a cap it tells how much faster the game could go; and
# AnimErrorMs, how far the motion shown strays from the time it took.
#
# And latency, which a cap can lower or raise: InputLatency, the median time
# from a keyboard or mouse event to the frame that shows it reaching the
# screen (PresentMon's AllInputToPhotonLatency, measured in software);
# LatencyP95, the slow end of start-of-frame-to-display; GpuMs95, the 95th
# percentile of GPU busy time; and QueueMs, how long a frame waited after the
# processor was done with it before the graphics card started on it, the
# median of GPULatency − CPUBusy: the render queue, which is pure latency.
function Measure-JuicerFrames {
    param([object[]]$Rows)
    $rows = @($Rows)
    if ($rows.Count -lt 20) { return $null }
    $cols = @($rows[0].PSObject.Properties | ForEach-Object { $_.Name })
    $ftCol = Get-JuicerFrameColumn $cols 'FrameTime', 'MsBetweenAppStart', 'MsBetweenPresents'
    if (-not $ftCol) { return $null }
    $gpuCol = Get-JuicerFrameColumn $cols 'GPUBusy', 'MsGPUBusy'
    $latCol = Get-JuicerFrameColumn $cols 'DisplayLatency', 'MsDisplayLatency', 'MsUntilDisplayed'
    $cpuCol = Get-JuicerFrameColumn $cols 'CPUBusy', 'MsCPUBusy'
    $animCol = Get-JuicerFrameColumn $cols 'AnimationError', 'MsAnimationError'
    $inputCol = Get-JuicerFrameColumn $cols 'AllInputToPhotonLatency', 'MsAllInputToPhotonLatency'
    $gpuLatCol = Get-JuicerFrameColumn $cols 'GPULatency', 'MsGPULatency'
    $work = New-Object System.Collections.Generic.List[double]
    $anim = New-Object System.Collections.Generic.List[double]
    $gpuMs = New-Object System.Collections.Generic.List[double]
    $inputLat = New-Object System.Collections.Generic.List[double]
    $queue = New-Object System.Collections.Generic.List[double]

    $ft = New-Object System.Collections.Generic.List[double]
    $gpuBound = 0; $gpuKnown = 0; $tearing = 0; $vsync = 0; $generated = 0
    $latency = New-Object System.Collections.Generic.List[double]
    $modes = @{}
    foreach ($r in $rows) {
        $t = ConvertTo-JuicerNumber $r.$ftCol
        if ($null -eq $t -or $t -le 0) { continue }
        $ft.Add($t)
        $g = $null
        if ($gpuCol) {
            $g = ConvertTo-JuicerNumber $r.$gpuCol
            if ($null -ne $g) { $gpuKnown++; $gpuMs.Add($g); if ($g -ge 0.85 * $t) { $gpuBound++ } }
        }
        $c = if ($cpuCol) { ConvertTo-JuicerNumber $r.$cpuCol }
        if ($null -ne $c -and $null -ne $g) { $work.Add([Math]::Max($c, $g)) }
        if ($gpuLatCol -and $null -ne $c) {
            $gl = ConvertTo-JuicerNumber $r.$gpuLatCol
            if ($null -ne $gl) { $queue.Add([Math]::Max(0, $gl - $c)) }
        }
        # NA on frames without input, which are most.
        if ($inputCol) { $il = ConvertTo-JuicerNumber $r.$inputCol; if ($null -ne $il -and $il -gt 0) { $inputLat.Add($il) } }
        if ($animCol) { $a = ConvertTo-JuicerNumber $r.$animCol; if ($null -ne $a) { $anim.Add([Math]::Abs($a)) } }
        if ($latCol) { $l = ConvertTo-JuicerNumber $r.$latCol; if ($null -ne $l -and $l -gt 0) { $latency.Add($l) } }

        if ([string]$r.AllowsTearing -eq '1') { $tearing++ }
        if ((ConvertTo-JuicerNumber $r.SyncInterval) -ge 1) { $vsync++ }
        if ($r.PSObject.Properties['FrameType'] -and $r.FrameType -and $r.FrameType -notin 'Application', 'NA', '') { $generated++ }
        $m = [string]$r.PresentMode
        if ($m) { $modes[$m] = 1 + [int]$modes[$m] }
    }
    $n = $ft.Count
    if ($n -lt 20) { return $null }
    $sorted = [double[]]($ft.ToArray() | Sort-Object)
    $total = 0.0; foreach ($t in $ft) { $total += $t }
    $median = Get-JuicerPercentile $sorted 0.5
    $stutters = 0
    foreach ($t in $ft) { if ($t -ge 2 * $median -and $t -ge $median + 8) { $stutters++ } }
    $p90 = Get-JuicerPercentile $sorted 0.9
    $p95 = Get-JuicerPercentile $sorted 0.95
    $tol = [Math]::Max(0.3, 0.04 * $median)
    $steady = 0; $jitter = 0.0
    for ($i = 0; $i -lt $n; $i++) {
        if ([Math]::Abs($ft[$i] - $median) -le $tol) { $steady++ }
        if ($i -gt 0) { $jitter += [Math]::Abs($ft[$i] - $ft[$i - 1]) }
    }
    $workP95 = if ($work.Count -ge 20) { Get-JuicerPercentile ([double[]]($work.ToArray() | Sort-Object)) 0.95 } else { $null }
    $pick = {
        param($List, [double]$Q, [int]$Min = 20)
        if ($List.Count -lt $Min) { return $null }
        [Math]::Round((Get-JuicerPercentile ([double[]]($List.ToArray() | Sort-Object)) $Q), 2)
    }
    $p99 = Get-JuicerPercentile $sorted 0.99
    $p999 = Get-JuicerPercentile $sorted 0.999
    $mode = if ($modes.Count -gt 0) { @($modes.GetEnumerator() | Sort-Object Value -Descending)[0].Key } else { '' }
    @{
        Application = [string]$rows[0].Application; Frames = $n; Seconds = [Math]::Round($total / 1000, 1)
        AvgFps = [Math]::Round(1000 * $n / $total, 1); Low1 = [Math]::Round(1000 / $p99, 1); Low01 = [Math]::Round(1000 / $p999, 1); Fps90 = [Math]::Round(1000 / $p90, 1)
        MedianMs = [Math]::Round($median, 2); P95Ms = [Math]::Round($p95, 2); P99Ms = [Math]::Round($p99, 2); Stutters = $stutters
        Fps95 = [Math]::Round(1000 / $p95, 1); Steady = [Math]::Round(100 * $steady / $n); JitterMs = [Math]::Round($jitter / ($n - 1), 2)
        WorkMs95 = $(if ($null -ne $workP95) { [Math]::Round($workP95, 2) } else { $null })
        GpuMs95 = (& $pick $gpuMs 0.95); QueueMs = (& $pick $queue 0.5); InputLatency = (& $pick $inputLat 0.5 10); LatencyP95 = (& $pick $latency 0.95)
        AnimErrorMs = $(if ($anim.Count -gt 0) { $s = 0.0; foreach ($a in $anim) { $s += $a }; [Math]::Round($s / $anim.Count, 2) } else { $null })
        GpuBound = $(if ($gpuKnown -gt 0) { [Math]::Round(100 * $gpuBound / $gpuKnown) } else { $null })
        Latency = $(if ($latency.Count -gt 0) { $s = 0.0; foreach ($l in $latency) { $s += $l }; [Math]::Round($s / $latency.Count, 1) } else { $null })
        Tearing = [Math]::Round(100 * $tearing / $n); VSync = [Math]::Round(100 * $vsync / $n); Generated = [Math]::Round(100 * $generated / $n)
        PresentMode = $mode
    }
}

# Processes, other than the game, that used CPU while it ran: two snapshots
# of total processor time, as a share of the whole processor.
function Get-JuicerProcessCpu {
    @(Get-Process -ErrorAction SilentlyContinue | ForEach-Object {
            $cpu = $null
            try { $cpu = $_.TotalProcessorTime.TotalSeconds } catch { Write-Verbose "Sin tiempo de CPU de $($_.Name)" }
            if ($null -ne $cpu) { @{ Id = $_.Id; Name = $_.Name; Cpu = $cpu } }
        })
}

function Get-JuicerCpuHogs {
    param([object[]]$Before, [object[]]$After, [double]$Seconds, [int]$Threads, [string]$Game = '', [double]$Min = 3)
    if ($Seconds -le 0 -or $Threads -le 0) { return @() }
    $was = @{}
    foreach ($p in $Before) { $was[[int]$p.Id] = $p }
    $skip = @('Idle', 'System', 'Registry', 'Memory Compression', 'dwm', 'audiodg', 'PresentMon', ($Game -replace '\.exe$', ''))
    $out = foreach ($p in $After) {
        $b = $was[[int]$p.Id]
        if (-not $b -or $b.Name -ne $p.Name -or $skip -contains $p.Name -or $p.Name -like 'PresentMon*') { continue }
        $pct = 100 * ($p.Cpu - $b.Cpu) / ($Seconds * $Threads)
        if ($pct -ge $Min) { @{ Name = $p.Name; Pct = [Math]::Round($pct, 1) } }
    }
    @($out | Sort-Object { $_.Pct } -Descending)
}

# NVIDIA only: temperature and clocks each second while the game runs.
function ConvertFrom-JuicerGpuSamples {
    param([string[]]$Lines)
    $s = @(foreach ($l in $Lines) {
            $f = @($l -split ',' | ForEach-Object { $_.Trim() })
            if ($f.Count -lt 3) { continue }
            $t = ConvertTo-JuicerNumber $f[0]; $u = ConvertTo-JuicerNumber $f[1]; $c = ConvertTo-JuicerNumber $f[2]
            if ($null -ne $t -and $null -ne $c) { @{ Temp = $t; Util = $u; Clock = $c } }
        })
    if ($s.Count -lt 3) { return $null }
    $busy = @($s | Where-Object { $_.Util -ge 90 } | ForEach-Object { $_.Clock })
    @{
        MaxTemp = ($s | ForEach-Object { $_.Temp } | Measure-Object -Maximum).Maximum
        # Clocks while the card was flat out: a fall from its peak is a
        # thermal or power limit.
        PeakClock = $(if ($busy.Count -gt 0) { ($busy | Measure-Object -Maximum).Maximum } else { $null })
        LowBusyClock = $(if ($busy.Count -gt 0) { ($busy | Measure-Object -Minimum).Minimum } else { $null })
    }
}

# --- What it means -----------------------------------------------------------

function Get-JuicerFrameFindings {
    param([Parameter(Mandatory)][hashtable]$Result, [hashtable]$Previous, [int]$RefreshHz, [object[]]$Hogs = @(), [hashtable]$Gpu)
    $area = "Juego: $($Result.Application)"
    $out = @()
    $out += New-JuicerFinding $area 'Info' ('Media {0:N0} FPS · 1 % bajo {1:N0} · 0,1 % bajo {2:N0}' -f $Result.AvgFps, $Result.Low1, $Result.Low01) ('{0:N0} fotogramas en {1:N0} s. Frametime mediano {2:N1} ms; el 1 % más lento, {3:N1} ms o más.{4}' -f $Result.Frames, $Result.Seconds, $Result.MedianMs, $Result.P99Ms, ($(if ($null -ne $Result.Latency) { " Latencia hasta pantalla: $($Result.Latency) ms de media." } else { '' }) + $(if ($null -ne $Result.InputLatency) { " De ratón o teclado a pantalla: $($Result.InputLatency) ms (mediana)." } else { '' })))

    if ($Previous) {
        $d = if ($Previous.AvgFps -gt 0) { 100 * ($Result.AvgFps - $Previous.AvgFps) / $Previous.AvgFps } else { 0 }
        $dl = if ($Previous.Low1 -gt 0) { 100 * ($Result.Low1 - $Previous.Low1) / $Previous.Low1 } else { 0 }
        $sev = if ($d -ge 3 -or $dl -ge 5) { 'Ok' } elseif ($d -le -3 -or $dl -le -5) { 'Bajo' } else { 'Info' }
        $out += New-JuicerFinding $area $sev ('Respecto al {0}: media {1:N0} → {2:N0} FPS ({3:+0;-0} %), 1 % bajo {4:N0} → {5:N0} ({6:+0;-0} %)' -f ([datetime]$Previous.Date).ToString('d'), $Previous.AvgFps, $Result.AvgFps, $d, $Previous.Low1, $Result.Low1, $dl) ($(if ($Previous.Latency -and $Result.Latency) { 'Latencia hasta pantalla: {0} → {1} ms. ' -f $Previous.Latency, $Result.Latency } else { '' }) + $(if ($Previous.InputLatency -and $Result.InputLatency) { 'De ratón o teclado a pantalla: {0} → {1} ms. ' -f $Previous.InputLatency, $Result.InputLatency } else { '' }) + 'Sólo vale si mediste la misma escena con los mismos ajustes del juego; menos de un 3 % es ruido.')
    }

    # Pacing: how far the slow frames are from the average.
    $ratio = if ($Result.AvgFps -gt 0) { $Result.Low1 / $Result.AvgFps } else { 1 }
    $perMin = if ($Result.Seconds -gt 0) { 60 * $Result.Stutters / $Result.Seconds } else { 0 }
    $why = 'Lo habitual: shaders que se compilan la primera vez que ves algo (repite la medida: si mejora, era eso), la VRAM llena (baja la calidad de texturas), el juego en un disco duro, o algo en segundo plano. La RAM sin XMP y un solo módulo también se notan aquí: míralo en el diagnóstico.'
    if ($ratio -lt 0.5 -or $perMin -gt 20) {
        $out += New-JuicerFinding $area 'Alto' ('Frametimes irregulares: {0:N0} tirones por minuto, y el 1 % bajo es el {1:N0} % de la media' -f $perMin, (100 * $ratio)) $why
    } elseif ($ratio -lt 0.65 -or $perMin -gt 5) {
        $out += New-JuicerFinding $area 'Medio' ('Algún tirón: {0:N0} por minuto; el 1 % bajo es el {1:N0} % de la media' -f $perMin, (100 * $ratio)) $why
    } else {
        $out += New-JuicerFinding $area 'Ok' ('Frametimes estables: el 1 % bajo es el {0:N0} % de la media' -f (100 * $ratio))
    }

    # What sets the frame rate.
    $capped = $RefreshHz -gt 0 -and $Result.VSync -ge 50 -and [Math]::Abs($Result.AvgFps - $RefreshHz) -le 0.03 * $RefreshHz
    if ($capped) {
        $out += New-JuicerFinding $area 'Info' "Limitado por la sincronización vertical a $RefreshHz Hz" 'Imagen sin cortes, con algo más de latencia. Con G-Sync o FreeSync, mejor VSync en el panel de la gráfica y un límite de FPS 3 por debajo de los Hz.'
    } elseif ($null -ne $Result.GpuBound) {
        if ($Result.GpuBound -ge 80) {
            $out += New-JuicerFinding $area 'Info' "La gráfica es el límite: va al máximo en el $($Result.GpuBound) % de los fotogramas" 'Para más FPS, la calidad gráfica o la resolución: DLSS, FSR o XeSS en modo calidad suelen dar un 30-50 % más. Ningún ajuste de Windows sube eso.'
        } elseif ($Result.GpuBound -lt 50) {
            $names = if (@($Hogs).Count -gt 0) { ' Mientras jugabas, en segundo plano: ' + ((@($Hogs) | Select-Object -First 4 | ForEach-Object { '{0} {1} %' -f $_.Name, $_.Pct }) -join ', ') + '.' } else { '' }
            $out += New-JuicerFinding $area 'Medio' "El procesador es el límite: la gráfica espera en el $(100 - $Result.GpuBound) % de los fotogramas" ("Bajar gráficos no dará más FPS (subirlos sale gratis). Lo que ayuda: cerrar lo que gaste CPU, la RAM con su XMP/EXPO, el plan de energía y, si el juego lo tiene, un límite de FPS por debajo de lo que alcanza para que los frametimes no oscilen.$names")
        }
    }

    switch -Wildcard ($Result.PresentMode) {
        'Composed: Copy*' {
            $out += New-JuicerFinding $area 'Medio' "El juego se muestra copiando a través del escritorio ($($Result.PresentMode))" 'Es el modo más lento y con más latencia. Activa «Optimizaciones para juegos en ventana» (Ajustes > Juegos) o pon el juego en pantalla completa.'
        }
        'Composed: Flip' {
            $out += New-JuicerFinding $area 'Bajo' 'El escritorio compone cada fotograma del juego' 'Suele ser una ventana normal o algo encima del juego (un overlay, otra ventana). En pantalla completa o ventana sin bordes a pantalla completa, sin superposiciones, pasa a «Independent Flip», con menos latencia.'
        }
        'Hardware*' {
            $out += New-JuicerFinding $area 'Ok' 'Presentación directa a la pantalla (sin pasar por el compositor)'
        }
    }

    if ($RefreshHz -gt 0 -and -not $capped -and $Result.AvgFps -gt 1.05 * $RefreshHz -and $Result.Tearing -ge 50) {
        $out += New-JuicerFinding $area 'Info' ('Pasa de los {0} Hz de tu pantalla ({1:N0} FPS)' -f $RefreshHz, $Result.AvgFps) ('Con G-Sync o FreeSync, un límite a {0} FPS (en el juego, en el panel de NVIDIA o AMD, o con RTSS) da frametimes más planos y menos latencia que dejarlo libre. Sin VRR, más FPS sí reduce la latencia, a costa de cortes en la imagen.' -f ($RefreshHz - 3))
    }
    if ($Result.Generated -ge 30) {
        $out += New-JuicerFinding $area 'Info' "Generación de fotogramas activa ($($Result.Generated) % de los fotogramas son generados)" 'Las cifras incluyen los fotogramas generados: la respuesta al ratón va al ritmo de la mitad.'
    }

    if ($Gpu) {
        if ($Gpu.MaxTemp -ge 85) {
            $out += New-JuicerFinding $area 'Medio' "La gráfica llegó a $($Gpu.MaxTemp) °C" 'A esas temperaturas baja frecuencia para protegerse. Limpia el polvo, revisa la curva de ventiladores o sube el flujo de aire de la caja.'
        }
        if ($Gpu.LowBusyClock -and $Gpu.PeakClock -gt 0 -and $Gpu.LowBusyClock -lt 0.8 * $Gpu.PeakClock) {
            $out += New-JuicerFinding $area 'Bajo' ('La gráfica bajó a {0:N0} MHz estando al máximo (llegó a {1:N0} MHz)' -f $Gpu.LowBusyClock, $Gpu.PeakClock) 'Es su límite de temperatura o de potencia. Si coincide con tirones, es por eso.'
        }
    }
    if (@($Hogs).Count -gt 0 -and -not ($null -ne $Result.GpuBound -and $Result.GpuBound -lt 50)) {
        $out += New-JuicerFinding $area 'Bajo' ('En segundo plano mientras jugabas: ' + ((@($Hogs) | Select-Object -First 4 | ForEach-Object { '{0} {1} %' -f $_.Name, $_.Pct }) -join ', ')) 'Porcentaje de todo el procesador. Si es un navegador o un lanzador, ciérralo antes de jugar; si es MsMpEng (Defender) o TiWorker (Windows Update), estaban trabajando justo entonces.'
    }
    $out
}

# --- History -----------------------------------------------------------------

function Get-JuicerFrameHistoryPath { Join-Path (Get-JuicerHome) 'juegos-fps.json' }

function Read-JuicerFrameHistory {
    $path = Get-JuicerFrameHistoryPath
    if (-not (Test-Path -LiteralPath $path)) { return }
    try {
        # Assigned first: with several entries it comes back as one list.
        $data = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
        @($data | Where-Object { $_ -is [hashtable] })
    } catch {
        Write-JuicerLog "juegos-fps.json dañado, se ignora: $_"
    }
}

function Save-JuicerFrameResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    $list = @(Read-JuicerFrameHistory) + $Result
    if ($list.Count -gt 50) { $list = @($list | Select-Object -Last 50) }
    [IO.File]::WriteAllText((Get-JuicerFrameHistoryPath), (ConvertTo-JuicerJson $list), (New-Object Text.UTF8Encoding $false))
}

function Get-JuicerPreviousFrameResult {
    param([string]$Application)
    @(Read-JuicerFrameHistory | Where-Object { $_.Application -eq $Application }) | Select-Object -Last 1
}

# --- Capturing ---------------------------------------------------------------

# Records every application for Seconds after Delay, then works out which one
# was the game. OnStatus is told what is happening each second. Returns the
# findings; callers wrap them in @().
function Invoke-JuicerFrameCapture {
    param([int]$Seconds = 60, [int]$Delay = 10, [string]$Process, [scriptblock]$OnStatus)
    $say = if ($OnStatus) { $OnStatus } else { { param($t) Write-Verbose $t } }
    & $say 'Preparando PresentMon…'
    $pm = Get-JuicerPresentMon
    $csv = Join-Path ([IO.Path]::GetTempPath()) ('wj-fps-' + [guid]::NewGuid().ToString('N') + '.csv')
    $argList = @('--output_file', "`"$csv`"", '--timed', $Seconds, '--terminate_after_timed', '--stop_existing_session',
        '--session_name', 'WinJuicer', '--no_console_stats', '--exclude', 'dwm.exe')
    if ($Delay -gt 0) { $argList += @('--delay', $Delay) }
    if ($Process) { $argList += @('--process_name', "`"$Process`"") }
    $p = Start-Process -FilePath $pm -ArgumentList $argList -WindowStyle Hidden -PassThru

    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    $smiOut = "$csv.gpu"
    $smiProc = $null
    $before = $null
    $beforeAt = $null
    $start = Get-Date
    $limit = $start.AddSeconds($Delay + $Seconds + 30)
    while (-not $p.HasExited -and (Get-Date) -lt $limit) {
        $elapsed = ((Get-Date) - $start).TotalSeconds
        if ($elapsed -lt $Delay) {
            & $say ('Empieza en {0:N0} s: vuelve al juego y juega con normalidad.' -f ($Delay - $elapsed))
        } else {
            if ($null -eq $before) {
                $before = @(Get-JuicerProcessCpu)
                $beforeAt = Get-Date
                if (Test-Path -LiteralPath $smi) {
                    $smiProc = Start-Process -FilePath $smi -ArgumentList @('--query-gpu=temperature.gpu,utilization.gpu,clocks.gr', '--format=csv,noheader,nounits', '-l', '1', '-f', "`"$smiOut`"") -WindowStyle Hidden -PassThru
                }
            }
            & $say ('Midiendo: quedan {0:N0} s.' -f [Math]::Max(0, $Delay + $Seconds - $elapsed))
        }
        Start-Sleep -Milliseconds 500
    }
    if (-not $p.HasExited) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
    $after = @(Get-JuicerProcessCpu)
    $sampled = if ($beforeAt) { ((Get-Date) - $beforeAt).TotalSeconds } else { 0 }
    if ($smiProc -and -not $smiProc.HasExited) { Stop-Process -Id $smiProc.Id -Force -ErrorAction SilentlyContinue }
    & $say 'Analizando los fotogramas…'

    try {
        [void]$p.WaitForExit(3000)
        if ($p.HasExited -and $p.ExitCode -ne 0) { throw "PresentMon terminó con el código $($p.ExitCode). ¿Le falta permiso de administrador?" }
        $rows = if (Test-Path -LiteralPath $csv) { @(Import-Csv -LiteralPath $csv) } else { @() }
        $game = Select-JuicerGameRows $rows $Process
        $result = Measure-JuicerFrames $game
        if (-not $result) {
            return (New-JuicerFinding 'Juego' 'Medio' 'No se ha detectado ningún juego en marcha' 'Empieza la medida y vuelve al juego antes de que acabe la cuenta atrás. Si el juego está abierto, ponlo en primer plano y que no esté en un menú en pausa.')
        }
        $result.Date = (Get-Date).ToString('s')
        $hw = Get-JuicerHardwareProfile
        $hz = @(Get-JuicerDisplays | Where-Object { $_.Primary } | Select-Object -First 1)
        $refresh = if ($hz.Count -gt 0) { [int]$hz[0].Hz } else { 0 }
        $hogs = if ($before) { @(Get-JuicerCpuHogs $before $after $sampled ([int]$hw.Cpu.Threads) $result.Application) } else { @() }
        $gpu = if (Test-Path -LiteralPath $smiOut) { ConvertFrom-JuicerGpuSamples ([IO.File]::ReadAllLines($smiOut)) } else { $null }
        $previous = Get-JuicerPreviousFrameResult $result.Application
        Save-JuicerFrameResult $result
        Write-JuicerLog ('FPS {0}: media {1}, 1 % {2}, 0,1 % {3}' -f $result.Application, $result.AvgFps, $result.Low1, $result.Low01)
        Get-JuicerFrameFindings $result $previous $refresh $hogs $gpu
        try {
            $cap = Get-JuicerRecommendedFps $result.Application
            if ($cap) {
                $now = @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq ([string]$result.Application).ToLowerInvariant() })
                if ($now.Count -gt 0 -and $now[0].Fps) {
                    # Under the frame pacer: how well it holds the pace.
                    Get-JuicerPacerFindings $result ([int]$now[0].Fps) ([double]$now[0].Exact)
                } else {
                    New-JuicerFinding "Juego: $($result.Application)" 'Info' "Ritmo recomendado para este juego: $($cap.Fps) FPS" ($cap.Why + ' Añádelo en Juegos > Frame pacer y se aplicará solo cada vez que lo abras.')
                }
            }
        } catch {
            Write-JuicerLog "Sin límite recomendado: $_"
        }
    } finally {
        Remove-Item -LiteralPath $csv, $smiOut -Force -ErrorAction SilentlyContinue
    }
}
