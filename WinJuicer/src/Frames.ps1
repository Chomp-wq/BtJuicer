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
# presented the most frames and is not part of Windows or a launcher. Counted
# per swap chain (ProcessID + SwapChainAddress, when the CSV has them): a game
# often presents on more than one chain (an overlay, a launcher's web view, a
# loading video), and mixing them would blend two frame rates into one.
function Select-JuicerGameRows {
    param([object[]]$Rows, [string]$Process)
    if (@($Rows).Count -eq 0) { return @() }
    # A column the CSV lacks reads as empty, so without them this is the application alone.
    $groups = @($Rows | Group-Object { '{0}|{1}|{2}' -f $_.Application, $_.ProcessID, $_.SwapChainAddress })
    $app = { param($g) [string]$g.Group[0].Application }
    if ($Process) {
        $g = @($groups | Where-Object { $a = & $app $_; $a -eq $Process -or $a -eq "$Process.exe" } | Sort-Object Count -Descending)
    } else {
        $g = @($groups | Where-Object { $script:NotGames -notcontains (& $app $_) } | Sort-Object Count -Descending)
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
    $cpuMs = New-Object System.Collections.Generic.List[double]

    $ft = New-Object System.Collections.Generic.List[double]
    $gpuBound = 0; $gpuKnown = 0; $tearing = 0; $vsync = 0; $generated = 0; $composed = 0; $direct = 0; $modeKnown = 0
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
        if ($null -ne $c) { $cpuMs.Add($c) }
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
        if ($m) {
            $modes[$m] = 1 + [int]$modes[$m]
            $modeKnown++
            # Composed: the desktop puts the frame on screen itself, which is where VRR does not act.
            if ($m -like 'Composed*') { $composed++ } elseif ($m -like 'Hardware*') { $direct++ }
        }
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
    # For the chart: at most 240 points, each the slowest frame of its
    # stretch, so that no spike is averaged away.
    $buckets = [Math]::Min(240, $n)
    $series = New-Object 'double[]' $buckets
    for ($b = 0; $b -lt $buckets; $b++) {
        $from = [int][Math]::Floor($b * $n / $buckets); $to = [int][Math]::Floor(($b + 1) * $n / $buckets)
        $top = 0.0
        for ($i = $from; $i -lt [Math]::Max($to, $from + 1); $i++) { if ($ft[$i] -gt $top) { $top = $ft[$i] } }
        $series[$b] = [Math]::Round($top, 2)
    }
    $res = @{
        Series = $series
        Application = [string]$rows[0].Application; Frames = $n; Seconds = [Math]::Round($total / 1000, 1)
        AvgFps = [Math]::Round(1000 * $n / $total, 1); Low1 = [Math]::Round(1000 / $p99, 1); Low01 = [Math]::Round(1000 / $p999, 1); Fps90 = [Math]::Round(1000 / $p90, 1)
        MedianMs = [Math]::Round($median, 2); P95Ms = [Math]::Round($p95, 2); P99Ms = [Math]::Round($p99, 2); Stutters = $stutters
        Fps95 = [Math]::Round(1000 / $p95, 1); Steady = [Math]::Round(100 * $steady / $n); JitterMs = [Math]::Round($jitter / ($n - 1), 2)
        WorkMs95 = $(if ($null -ne $workP95) { [Math]::Round($workP95, 2) } else { $null })
        GpuMs95 = (& $pick $gpuMs 0.95); QueueMs = (& $pick $queue 0.5); InputLatency = (& $pick $inputLat 0.5 10); LatencyP95 = (& $pick $latency 0.95)
        AnimErrorMs = $(if ($anim.Count -gt 0) { $s = 0.0; foreach ($a in $anim) { $s += $a }; [Math]::Round($s / $anim.Count, 2) } else { $null })
        CpuMs95 = (& $pick $cpuMs 0.95)
        GpuBound = $(if ($gpuKnown -gt 0) { [Math]::Round(100 * $gpuBound / $gpuKnown) } else { $null })
        Latency = $(if ($latency.Count -gt 0) { $s = 0.0; foreach ($l in $latency) { $s += $l }; [Math]::Round($s / $latency.Count, 1) } else { $null })
        Tearing = [Math]::Round(100 * $tearing / $n); VSync = [Math]::Round(100 * $vsync / $n); Generated = [Math]::Round(100 * $generated / $n)
        PresentMode = $mode
        ComposedPct = $(if ($modeKnown -gt 0) { [Math]::Round(100 * $composed / $modeKnown) } else { $null })
        DirectPct = $(if ($modeKnown -gt 0) { [Math]::Round(100 * $direct / $modeKnown) } else { $null })
    }
    $res.Limit = Get-JuicerFrameLimit $res
    $res
}

# What sets the frame rate, from a measurement: CPU, GPU, Ritmo (the cap, or
# the game's own limiter, is what holds the frames and the PC has room to
# spare) or '' (mixed, or not enough data). A cap makes the card idle part of
# every frame, so «the GPU is not at its limit» says nothing about the
# processor: the busier of the two has to fill most of the frame time (85 %,
# the 95th percentile of frames) before either is called the limit.
# Without that figure (an old measurement, a CSV without both busy columns) it
# goes by the share of frames with the card busy, as before.
function Get-JuicerFrameLimit {
    param([hashtable]$Result)
    if (-not $Result) { return '' }
    $ft = if ($Result.MedianMs -gt 0) { [double]$Result.MedianMs } elseif ($Result.AvgFps -gt 0) { 1000 / [double]$Result.AvgFps } else { 0 }
    if ($ft -gt 0 -and $null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.Generated -lt 30 -and $Result.WorkMs95 -lt 0.85 * $ft) { return 'Ritmo' }
    if ($null -eq $Result.GpuBound) { return '' }
    if ($Result.GpuBound -ge 80) { return 'GPU' }
    if ($Result.GpuBound -lt 50) { return 'CPU' }
    ''
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

# What nvidia-smi is asked each second while the game runs: temperature,
# utilization, graphics clock, then memory used and total (MiB), power draw (W)
# and the bitmask of why the clocks are held down. The last four are newer
# columns; a line with only the first three still reads.
$script:GpuQuery = 'temperature.gpu,utilization.gpu,clocks.gr,memory.used,memory.total,power.draw,clocks_throttle_reasons.active'

# The bits of «clocks_throttle_reasons.active» that are a real slowdown, with
# what to call each (a list of pairs: an ordered table would take the number
# as a position). Idle (0x1), application clocks (0x2) and display clocks
# (0x100) are the card resting or set that way on purpose, not a limit; the
# software power cap (0x4) is a card at its power limit, which at full load is
# normal, so it is reported apart (PowerLimited) and does not count as throttled.
$script:ThrottleBits = @(@(0x8, 'freno por hardware'), @(0x20, 'límite de temperatura'), @(0x40, 'límite de temperatura del hardware'), @(0x80, 'freno de energía'))

# A number from nvidia-smi, which writes «[N/A]» or «[Not Supported]» for what the card does not report.
function ConvertFrom-JuicerSmiNumber {
    param([string]$Text)
    if ($null -eq $Text -or $Text -match '\[|N/A|Not') { return $null }
    $t = $Text.Trim()
    if ($t -match '^0x[0-9a-fA-F]+$') { try { return [double][Convert]::ToInt64($t.Substring(2), 16) } catch { return $null } }
    ConvertTo-JuicerNumber $t
}

# NVIDIA only: temperature, clocks, memory and throttling each second while the game runs.
# Throttled: a real slowdown reason (see ThrottleBits) in at least a fifth of the samples.
function ConvertFrom-JuicerGpuSamples {
    param([string[]]$Lines)
    $s = @(foreach ($l in $Lines) {
            $f = @($l -split ',' | ForEach-Object { $_.Trim() })
            if ($f.Count -lt 3) { continue }
            $t = ConvertFrom-JuicerSmiNumber $f[0]; $u = ConvertFrom-JuicerSmiNumber $f[1]; $c = ConvertFrom-JuicerSmiNumber $f[2]
            if ($null -eq $t -or $null -eq $c) { continue }
            $o = @{ Temp = $t; Util = $u; Clock = $c; VramPct = $null; Power = $null; Reasons = 0 }
            if ($f.Count -ge 5) {
                $used = ConvertFrom-JuicerSmiNumber $f[3]; $total = ConvertFrom-JuicerSmiNumber $f[4]
                if ($null -ne $used -and $null -ne $total -and $total -gt 0) { $o.VramPct = 100 * $used / $total }
            }
            if ($f.Count -ge 6) { $o.Power = ConvertFrom-JuicerSmiNumber $f[5] }
            if ($f.Count -ge 7) { $r = ConvertFrom-JuicerSmiNumber $f[6]; if ($null -ne $r) { $o.Reasons = [int64]$r } }
            $o
        })
    if ($s.Count -lt 3) { return $null }
    $busy = @($s | Where-Object { $_.Util -ge 90 } | ForEach-Object { $_.Clock })
    $vram = @($s | Where-Object { $null -ne $_.VramPct } | ForEach-Object { $_.VramPct })
    $power = @($s | Where-Object { $null -ne $_.Power } | ForEach-Object { $_.Power })
    $why = @()
    $fifth = [Math]::Max(1, [Math]::Ceiling(0.2 * $s.Count))
    foreach ($bit in $script:ThrottleBits) {
        $n = @($s | Where-Object { ($_.Reasons -band [int]$bit[0]) -ne 0 }).Count
        if ($n -ge $fifth) { $why += [string]$bit[1] }
    }
    @{
        MaxTemp = ($s | ForEach-Object { $_.Temp } | Measure-Object -Maximum).Maximum
        # Clocks while the card was flat out: a fall from its peak is a
        # thermal or power limit.
        PeakClock = $(if ($busy.Count -gt 0) { ($busy | Measure-Object -Maximum).Maximum } else { $null })
        LowBusyClock = $(if ($busy.Count -gt 0) { ($busy | Measure-Object -Minimum).Minimum } else { $null })
        VramUsedPct = $(if ($vram.Count -gt 0) { [Math]::Round(($vram | Measure-Object -Maximum).Maximum, 1) } else { $null })
        MaxPowerW = $(if ($power.Count -gt 0) { [Math]::Round(($power | Measure-Object -Maximum).Maximum, 1) } else { $null })
        Throttled = ($why.Count -gt 0)
        PowerLimited = (@($s | Where-Object { ($_.Reasons -band 4) -ne 0 }).Count -ge $fifth)
        ThrottleReason = ($why -join ', ')
    }
}

# --- What it means -----------------------------------------------------------

# «con frame pacer a 171 FPS» or «sin frame pacer» for a saved measurement: a
# comparison between a paced and an unpaced run is not a comparison of the PC.
# Measurements from before the cap was saved say so instead of guessing.
function Format-JuicerPacerState {
    param($Result)
    if ($Result -isnot [hashtable] -or $null -eq $Result.Cap) { return 'sin saber si había frame pacer' }
    if ([int]$Result.Cap -gt 0) { return "con frame pacer a $([int]$Result.Cap) FPS" }
    'sin frame pacer'
}

function Get-JuicerFrameFindings {
    param([Parameter(Mandatory)][hashtable]$Result, [hashtable]$Previous, [int]$RefreshHz, [object[]]$Hogs = @(), [hashtable]$Gpu, [string]$Use = '')
    $area = "Juego: $($Result.Application)"
    # What was measured under a cap says nothing about the PC's limit, and it was saved with the measurement.
    $limit = Get-JuicerFrameLimit $Result
    if (@($Hogs).Count -eq 0 -and $Result.Hogs) { $Hogs = @($Result.Hogs) }
    $out = @()
    $out += New-JuicerFinding $area 'Info' ('Media {0:N0} FPS · 1 % bajo {1:N0} · 0,1 % bajo {2:N0}' -f $Result.AvgFps, $Result.Low1, $Result.Low01) ('{0:N0} fotogramas en {1:N0} s. Frametime mediano {2:N1} ms; el 1 % más lento, {3:N1} ms o más.{4}' -f $Result.Frames, $Result.Seconds, $Result.MedianMs, $Result.P99Ms, ($(if ($null -ne $Result.Latency) { " Latencia hasta pantalla: $($Result.Latency) ms de media." } else { '' }) + $(if ($null -ne $Result.InputLatency) { " De ratón o teclado a pantalla: $($Result.InputLatency) ms (mediana)." } else { '' })))

    if ($Previous) {
        $d = if ($Previous.AvgFps -gt 0) { 100 * ($Result.AvgFps - $Previous.AvgFps) / $Previous.AvgFps } else { 0 }
        $dl = if ($Previous.Low1 -gt 0) { 100 * ($Result.Low1 - $Previous.Low1) / $Previous.Low1 } else { 0 }
        $sev = if ($d -ge 3 -or $dl -ge 5) { 'Ok' } elseif ($d -le -3 -or $dl -le -5) { 'Bajo' } else { 'Info' }
        $out += New-JuicerFinding $area $sev ('Respecto al {0}: media {1:N0} → {2:N0} FPS ({3:+0;-0} %), 1 % bajo {4:N0} → {5:N0} ({6:+0;-0} %)' -f ([datetime]$Previous.Date).ToString('d'), $Previous.AvgFps, $Result.AvgFps, $d, $Previous.Low1, $Result.Low1, $dl) ($(if ($Previous.Latency -and $Result.Latency) { 'Latencia hasta pantalla: {0} → {1} ms. ' -f $Previous.Latency, $Result.Latency } else { '' }) + $(if ($Previous.InputLatency -and $Result.InputLatency) { 'De ratón o teclado a pantalla: {0} → {1} ms. ' -f $Previous.InputLatency, $Result.InputLatency } else { '' }) + $(if ($null -ne $Previous.Steady -and $null -ne $Result.Steady) { 'Ritmo: {0} → {1} % de los fotogramas en su sitio; de un fotograma al siguiente, {2:N2} → {3:N2} ms. ' -f $Previous.Steady, $Result.Steady, $Previous.JitterMs, $Result.JitterMs } else { '' }) + $(if ($null -ne $Previous.QueueMs -and $null -ne $Result.QueueMs) { 'Cola delante de la gráfica: {0:N1} → {1:N1} ms. ' -f $Previous.QueueMs, $Result.QueueMs } else { '' }) + ('Antes, {0}; ahora, {1}. ' -f (Format-JuicerPacerState $Previous), (Format-JuicerPacerState $Result)) + 'Sólo vale si mediste la misma escena con los mismos ajustes del juego; menos de un 3 % es ruido.')
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
    } elseif ($limit -eq 'Ritmo') {
        $out += New-JuicerFinding $area 'Info' 'Limitado por el ritmo, hay margen: ni el procesador ni la gráfica van al límite' ('Lo que marca los fotogramas es el límite de FPS (el frame pacer o el del propio juego), no tu PC: en el 95 % de los fotogramas el trabajo más pesado llega a {0:N2} ms de los {1:N2} ms que dura cada uno. Con un límite puesto la gráfica descansa parte de cada fotograma, y eso no quiere decir que limite el procesador. Para más FPS, sube el límite o quítalo; calibrar el frame pacer lo ajusta a lo que tu PC da.' -f $Result.WorkMs95, $Result.MedianMs)
    } elseif ($limit -eq 'GPU') {
        $out += New-JuicerFinding $area 'Info' "La gráfica es el límite: va al máximo en el $($Result.GpuBound) % de los fotogramas" 'Para más FPS, la calidad gráfica o la resolución: DLSS, FSR o XeSS en modo calidad suelen dar un 30-50 % más. Ningún ajuste de Windows sube eso.'
    } elseif ($limit -eq 'CPU') {
        $names = if (@($Hogs).Count -gt 0) { ' Mientras jugabas, en segundo plano: ' + ((@($Hogs) | Select-Object -First 4 | ForEach-Object { '{0} {1} %' -f $_.Name, $_.Pct }) -join ', ') + '.' } else { '' }
        $out += New-JuicerFinding $area 'Medio' "El procesador es el límite: la gráfica espera en el $(100 - $Result.GpuBound) % de los fotogramas" ("Bajar gráficos no dará más FPS (subirlos sale gratis). Lo que ayuda: cerrar lo que gaste CPU, la RAM con su XMP/EXPO, el plan de energía y, si el juego lo tiene, un límite de FPS por debajo de lo que alcanza para que los frametimes no oscilen.$names")
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
    # Variable refresh only acts on frames that reach the screen without the desktop in between; and a
    # sync interval of 1 or more (the game's own V-Sync) holds each frame for the next refresh.
    if ($Use -in 'VRR', 'EstroboSync' -and $null -ne $Result.DirectPct -and $Result.DirectPct -lt 50) {
        $out += New-JuicerFinding $area 'Medio' ('El VRR no está actuando en este juego: el {0} % de los fotogramas pasa por el escritorio ({1})' -f (100 - $Result.DirectPct), $Result.PresentMode) 'Con G-SYNC o FreeSync, el VRR sólo actúa cuando el juego presenta directo a la pantalla. Pon pantalla completa exclusiva en el juego o activa G-SYNC para ventana (NvVrrMode: en el panel de NVIDIA, «Configurar G-SYNC» > «Activar para modo ventana y pantalla completa»; con AMD, FreeSync ya vale en ventana sin bordes si Windows la presenta directa). Mientras tanto verás cortes o tirones que el VRR evitaría.'
    }
    if ($Use -in 'VRR', 'EstroboSync' -and $RefreshHz -gt 0 -and -not $capped -and $Result.VSync -ge 50 -and $Result.AvgFps -lt $RefreshHz) {
        $out += New-JuicerFinding $area 'Medio' ('La V-Sync del propio juego está activa con VRR (el {0} % de los fotogramas) y vas por debajo de los {1} Hz' -f $Result.VSync, $RefreshHz) 'Desactiva la V-Sync del propio juego: con G-SYNC o FreeSync cada fotograma que no llega a tiempo se queda esperando al siguiente refresco, que es latencia y tirones; la sincronización vertical del driver, que Win Juicer fuerza en el perfil del juego, ya tapa los cortes sin esa espera.'
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
    $throttled = if ($Gpu -and $null -ne $Gpu.Throttled) { [bool]$Gpu.Throttled } else { [bool]$Result.Throttled }
    $throttleWhy = if ($Gpu -and $Gpu.ThrottleReason) { [string]$Gpu.ThrottleReason } else { [string]$Result.ThrottleReason }
    if ($throttled) {
        $out += New-JuicerFinding $area 'Medio' ('La gráfica se frenó durante la medida{0}' -f $(if ($throttleWhy) { ": $throttleWhy" } else { '' })) 'Mientras jugabas la gráfica bajó sus frecuencias para protegerse (temperatura o potencia). Esta medida no es de lo que tu PC da en frío: repítela con el equipo en régimen, y si vuelve a salir, limpia el polvo, mejora el flujo de aire o la curva de ventiladores. Mientras sea así, Win Juicer no guarda una calibración a la baja.'
    }
    $vram = if ($Gpu -and $null -ne $Gpu.VramUsedPct) { $Gpu.VramUsedPct } else { $Result.VramUsedPct }
    if ($null -ne $vram -and $vram -ge 95) {
        $out += New-JuicerFinding $area 'Medio' ('VRAM llena: la gráfica usó el {0:N0} % de su memoria' -f $vram) 'Con la memoria de vídeo al límite, Windows pasa texturas a la RAM del sistema y aparecen tirones y caídas de FPS que ningún límite arregla. Baja la calidad de texturas (o la resolución, o el modo de DLSS/FSR hacia más agresivo) hasta dejarle un 10 % libre.'
    }
    if (@($Hogs).Count -gt 0 -and $limit -ne 'CPU') {
        $out += New-JuicerFinding $area 'Bajo' ('En segundo plano mientras jugabas: ' + ((@($Hogs) | Select-Object -First 4 | ForEach-Object { '{0} {1} %' -f $_.Name, $_.Pct }) -join ', ')) 'Porcentaje de todo el procesador. Si es un navegador o un lanzador, ciérralo antes de jugar; si es MsMpEng (Defender) o TiWorker (Windows Update), estaban trabajando justo entonces.'
    }
    $out
}

# The frame times of a measurement as a chart: the GUI draws it, the console
# prints it as a line of blocks. TargetMs, the frame pacer's, if it has one.
function New-JuicerFrameChartFinding {
    param([hashtable]$Result, [double[]]$Series, [double]$TargetMs = 0)
    if (@($Series).Count -lt 2) { return }
    $max = ($Series | Measure-Object -Maximum).Maximum
    $what = if ($TargetMs -gt 0) { 'la línea discontinua es el objetivo del frame pacer ({0:N2} ms)' -f $TargetMs } else { 'la línea discontinua es el frametime mediano ({0:N2} ms)' -f $Result.MedianMs }
    $f = New-JuicerFinding "Juego: $($Result.Application)" 'Info' 'Frametimes de la medida' ('De izquierda a derecha, toda la medida; cada punto es el fotograma más lento de su tramo, para que ningún pico se pierda. Arriba, {0:N1} ms; {1}. Una línea plana pegada a ella es un ritmo clavado.' -f $max, $what)
    $f.Chart = @{ Series = [double[]]$Series; TargetMs = $(if ($TargetMs -gt 0) { [Math]::Round($TargetMs, 3) } else { [double]$Result.MedianMs }); MaxMs = $max }
    $f
}

# A line of block characters for the console: Width points, scaled from 0
# to the highest frame time (or 1.5 times the target, whichever is more).
function Format-JuicerSparkline {
    param([double[]]$Series, [double]$TargetMs = 0, [int]$Width = 60)
    $s = @($Series)
    if ($s.Count -eq 0) { return '' }
    $top = [Math]::Max(($s | Measure-Object -Maximum).Maximum, 1.5 * $TargetMs)
    if ($top -le 0) { return '' }
    $blocks = [char[]]@(0x2581, 0x2582, 0x2583, 0x2584, 0x2585, 0x2586, 0x2587, 0x2588)
    $w = [Math]::Min($Width, $s.Count)
    $sb = New-Object Text.StringBuilder
    for ($i = 0; $i -lt $w; $i++) {
        $from = [int][Math]::Floor($i * $s.Count / $w); $to = [Math]::Max($from + 1, [int][Math]::Floor(($i + 1) * $s.Count / $w))
        $v = 0.0
        for ($j = $from; $j -lt $to; $j++) { if ($s[$j] -gt $v) { $v = $s[$j] } }
        [void]$sb.Append($blocks[[Math]::Min(7, [int][Math]::Floor(8 * $v / $top - 0.0001))])
    }
    $sb.ToString()
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

# The last 10 measurements of each game (a busy game no longer pushes the
# others out of a shared list of 50), and at most 400 in all. Old files, which
# hold the last 50 overall and none of the newer fields, are trimmed the same
# way on the next save and read as they are.
function Limit-JuicerFrameHistory {
    param([object[]]$List, [int]$PerGame = 10, [int]$Total = 400)
    $items = @($List)
    $count = @{}
    $keep = New-Object System.Collections.ArrayList
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        $k = ([string]$items[$i].Application).ToLowerInvariant()
        $count[$k] = 1 + [int]$count[$k]
        if ($count[$k] -le $PerGame) { [void]$keep.Add($items[$i]) }
    }
    # Collected newest first: back to the order they were taken in.
    $keep.Reverse()
    if ($keep.Count -gt $Total) { return $keep.GetRange($keep.Count - $Total, $Total).ToArray() }
    $keep.ToArray()
}

function Save-JuicerFrameResult {
    param([Parameter(Mandatory)][hashtable]$Result)
    $list = @(Limit-JuicerFrameHistory (@(Read-JuicerFrameHistory) + $Result))
    Write-JuicerTextAtomic (Get-JuicerFrameHistoryPath) (ConvertTo-JuicerJson $list)
}

# Whether an old measurement still says something about this PC as it is
# now: made on the same monitor and refresh rate (Signature, or at least the
# Hz when it predates signatures), not more than 60 days ago, and with the
# graphics card not throttled. What cannot be told (no date, no signature) is
# taken as usable: it is only discarded for what is known against it.
function Test-JuicerFrameResultUsable {
    param($Result, [string]$Signature = '', [int]$Hz = 0, [datetime]$Now = (Get-Date), [int]$MaxDays = 60)
    if ($Result -isnot [hashtable]) { return $false }
    if ($Result.Throttled) { return $false }
    if ($Signature -and $Result.Signature -and [string]$Result.Signature -ne $Signature) { return $false }
    if (-not $Result.Signature -and $Hz -gt 0 -and [int]$Result.Hz -gt 0 -and [int]$Result.Hz -ne $Hz) { return $false }
    if ($Result.Date) {
        $when = [datetime]::MinValue
        if ([datetime]::TryParse([string]$Result.Date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when) -and ($Now - $when).TotalDays -gt $MaxDays) { return $false }
    }
    $true
}

# The most recent measurement of a game that is still usable (Test-JuicerFrameResultUsable).
function Get-JuicerUsableFrameResult {
    param([string]$Application, [string]$Signature = '', [int]$Hz = 0, [datetime]$Now = (Get-Date))
    $all = @(Read-JuicerFrameHistory | Where-Object { $_.Application -eq $Application })
    for ($i = $all.Count - 1; $i -ge 0; $i--) {
        if (Test-JuicerFrameResultUsable $all[$i] $Signature $Hz $Now) { return $all[$i] }
    }
    $null
}

# The best average FPS this game reached without a frame pacer (Cap saved as 0),
# on this monitor: what the PC can do, to keep a calibration from setting a
# multiple of the refresh rate nobody has seen it reach. 0 when unknown.
function Get-JuicerBestUnpacedFps {
    param([string]$Application, [string]$Signature = '', [int]$Hz = 0, [datetime]$Now = (Get-Date))
    $best = 0.0
    foreach ($r in @(Read-JuicerFrameHistory | Where-Object { $_.Application -eq $Application -and $null -ne $_.Cap -and [int]$_.Cap -eq 0 })) {
        if ($r.Generated -ge 30 -or -not (Test-JuicerFrameResultUsable $r $Signature $Hz $Now)) { continue }
        if ([double]$r.AvgFps -gt $best) { $best = [double]$r.AvgFps }
    }
    $best
}

# The last chart of each game (up to 40 games), for its page in the gallery.
function Get-JuicerFrameChartPath { Join-Path (Get-JuicerHome) 'graficas.json' }

function Read-JuicerFrameCharts {
    $p = Get-JuicerFrameChartPath
    if (-not (Test-Path -LiteralPath $p)) { return @{} }
    try {
        $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
        if ($d -is [hashtable]) { return $d }
    } catch {
        Write-JuicerLog "graficas.json dañado, se ignora: $_"
    }
    @{}
}

function Save-JuicerFrameChart {
    param([Parameter(Mandatory)][string]$Application, [Parameter(Mandatory)][hashtable]$Chart)
    $all = Read-JuicerFrameCharts
    $c = @{ Series = @($Chart.Series); TargetMs = $Chart.TargetMs; MaxMs = $Chart.MaxMs; Date = (Get-Date).ToString('s') }
    $all[$Application.ToLowerInvariant()] = $c
    if ($all.Count -gt 40) {
        foreach ($k in @($all.Keys | Sort-Object { [string]$all[$_].Date } | Select-Object -First ($all.Count - 40))) { $all.Remove($k) }
    }
    Write-JuicerTextAtomic (Get-JuicerFrameChartPath) (ConvertTo-JuicerJson $all)
}

function Get-JuicerFrameChart {
    param([string]$Application)
    $c = (Read-JuicerFrameCharts)[$Application.ToLowerInvariant()]
    if ($c -is [hashtable] -and @($c.Series).Count -ge 2) { $c.Series = [double[]]@($c.Series); return $c }
    $null
}

function Get-JuicerPreviousFrameResult {
    param([string]$Application)
    @(Read-JuicerFrameHistory | Where-Object { $_.Application -eq $Application }) | Select-Object -Last 1
}

# --- Capturing ---------------------------------------------------------------

# The main graphics card (the dedicated one if there are two), as the hardware profile has it, or null.
function Get-JuicerMainGpu {
    try {
        $g = @((Get-JuicerHardwareProfile).Gpus)
        $d = @($g | Where-Object { $_.Discrete })
        if ($d.Count -gt 0) { return $d[0] }
        if ($g.Count -gt 0) { return $g[0] }
    } catch {
        Write-Verbose "Sin gráfica: $_"
    }
    $null
}

# What a measurement was made with, kept in the result so that a later one is only compared with like
# for like: with or without the frame pacer (Cap, 0 = none), which engine, on which screen
# (Hz, Use, Signature), the card's driver, PresentMon's version, and whether the PC was in a state
# to be measured (the graphics card throttled or hot, its memory full, what else used the processor).
# Limits are the game's caps in force (Get-JuicerFpsLimits for it), Gpu what nvidia-smi sampled.
function Set-JuicerFrameContext {
    param([hashtable]$Result, [object[]]$Limits = @(), [hashtable]$Monitor, [int]$Hz = 0, [object[]]$Hogs = @(), [hashtable]$Gpu)
    $Result.Cap = $(if (@($Limits).Count -gt 0) { [int]@($Limits)[0].Fps } else { 0 })
    $Result.Backend = $(if (@($Limits).Count -gt 0) { [string]@($Limits)[0].Backend } else { '' })
    $Result.Hz = $Hz
    $Result.Use = Resolve-JuicerMonitorUse $Monitor
    $Result.Signature = $(if ($Monitor) { Get-JuicerLimitSignature $Monitor } else { '' })
    $Result.Priority = Get-JuicerPacerPriority $Result.Application
    $mainGpu = Get-JuicerMainGpu
    $Result.GpuDriver = $(if ($mainGpu) { [string]$mainGpu.DriverVersion } else { '' })
    $Result.PresentMonVersion = $script:PresentMonVersion
    $Result.Hogs = @(@($Hogs) | Select-Object -First 4)
    $Result.Throttled = [bool]($Gpu -and $Gpu.Throttled)
    $Result.ThrottleReason = $(if ($Gpu) { [string]$Gpu.ThrottleReason } else { '' })
    $Result.MaxTemp = $(if ($Gpu) { $Gpu.MaxTemp } else { $null })
    $Result.VramUsedPct = $(if ($Gpu) { $Gpu.VramUsedPct } else { $null })
}

# Records every application for Seconds after Delay, then works out which one
# was the game. OnStatus is told what is happening each second. Returns the
# findings; callers wrap them in @().
function Invoke-JuicerFrameCapture {
    param([int]$Seconds = 60, [int]$Delay = 10, [string]$Process, [scriptblock]$OnStatus, [switch]$NoFrameGenWarning)
    $say = if ($OnStatus) { $OnStatus } else { { param($t) Write-Verbose $t } }
    # Said before the countdown, not only after the numbers come out odd (a caller
    # that already said it on its own screen passes -NoFrameGenWarning).
    if ($Process -and -not $NoFrameGenWarning) {
        $fgWarn = $null
        try { $fgWarn = Get-JuicerFrameGenMeasureWarning $Process } catch { Write-JuicerLog "Sin aviso de generación de fotogramas: $_" }
        if ($fgWarn) { New-JuicerFinding "Juego: $Process" 'Medio' 'Antes de medir: generación de fotogramas con RivaTuner' $fgWarn }
    }
    & $say 'Preparando PresentMon…'
    $pm = Get-JuicerPresentMon
    $csv = Join-Path ([IO.Path]::GetTempPath()) ('wj-fps-' + [guid]::NewGuid().ToString('N') + '.csv')
    $argList = @('--output_file', "`"$csv`"", '--timed', $Seconds, '--terminate_after_timed', '--stop_existing_session',
        '--session_name', 'WinJuicer', '--no_console_stats', '--exclude', 'dwm.exe')
    if ($Delay -gt 0) { $argList += @('--delay', $Delay) }
    if ($Process) { $argList += @('--process_name', "`"$Process`"") }
    $p = $null
    $smiProc = $null
    try {
        $p = Start-Process -FilePath $pm -ArgumentList $argList -WindowStyle Hidden -PassThru

        $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
        $smiOut = "$csv.gpu"
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
                        $smiProc = Start-Process -FilePath $smi -ArgumentList @("--query-gpu=$script:GpuQuery", '--format=csv,noheader,nounits', '-l', '1', '-f', "`"$smiOut`"") -WindowStyle Hidden -PassThru
                    }
                }
                & $say ('Midiendo: quedan {0:N0} s.' -f [Math]::Max(0, $Delay + $Seconds - $elapsed))
            }
            Start-Sleep -Milliseconds 500
        }
        $exitedByItself = $p.HasExited
        if (-not $exitedByItself) { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        # PresentMon gone early with an error (no admin rights, say): no point sampling or waiting more.
        if ($exitedByItself -and $p.ExitCode -ne 0) { throw "PresentMon terminó con el código $($p.ExitCode). ¿Le falta permiso de administrador?" }
        $after = @(Get-JuicerProcessCpu)
        $sampled = if ($beforeAt) { ((Get-Date) - $beforeAt).TotalSeconds } else { 0 }
        if ($smiProc -and -not $smiProc.HasExited) { Stop-Process -Id $smiProc.Id -Force -ErrorAction SilentlyContinue }
        & $say 'Analizando los fotogramas…'
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
        # The chart is shown now, not kept: the history stays small.
        $series = $result.Series
        $result.Remove('Series')
        $now = @()
        try { $now = @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq ([string]$result.Application).ToLowerInvariant() -and $_.Fps }) } catch { Write-JuicerLog "Sin frame pacer: $_" }
        $mon = $null
        try { $mon = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
        Set-JuicerFrameContext $result $now $mon $refresh $hogs $gpu
        Save-JuicerFrameResult $result
        Write-JuicerLog ('FPS {0}: media {1}, 1 % {2}, 0,1 % {3}' -f $result.Application, $result.AvgFps, $result.Low1, $result.Low01)
        Get-JuicerFrameFindings $result $previous $refresh $hogs $gpu $result.Use
        $targetMs = if ($now.Count -gt 0) { 1000 / $(if ($now[0].Exact -gt 0 -and $now[0].Backend -eq 'rtss') { [double]$now[0].Exact } else { [double]$now[0].Fps }) } else { 0 }
        $chart = New-JuicerFrameChartFinding $result $series $targetMs
        if ($chart) {
            $chart
            try { Save-JuicerFrameChart $result.Application $chart.Chart } catch { Write-JuicerLog "Sin guardar la gráfica: $_" }
        }
        try {
            $cap = Get-JuicerRecommendedFps $result.Application $mon
            if ($cap) {
                if ($now.Count -gt 0) {
                    # Under the frame pacer: how well it holds the pace, and what holds it when it is not the PC.
                    Get-JuicerPacerFindings $result ([int]$now[0].Fps) ([double]$now[0].Exact) ([string]$now[0].Backend) -Hz ([int]$mon.Display.Hz) -Use (Resolve-JuicerMonitorUse $mon) -GpuVendor (Get-JuicerMainGpuVendor)
                } else {
                    New-JuicerFinding "Juego: $($result.Application)" 'Info' "Ritmo recomendado para este juego: $($cap.Fps) FPS" ($cap.Why + ' Añádelo en Juegos > Frame pacer y se aplicará solo cada vez que lo abras.')
                }
            }
        } catch {
            Write-JuicerLog "Sin límite recomendado: $_"
        }
    } finally {
        # Whatever happens (an error, the window closing and stopping the task): no process or temp file is left behind.
        foreach ($proc in $p, $smiProc) {
            if ($proc) {
                try { if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue } } catch { Write-Verbose "Sin parar el proceso: $_" }
            }
        }
        Remove-Item -LiteralPath $csv, $smiOut -Force -ErrorAction SilentlyContinue
    }
}
