# The frame pacer: a frame-time target per game, set where it costs nothing
# and needs no injection. With an NVIDIA card, the driver's own limiter in
# that game's profile; otherwise, or if its owner prefers it, RivaTuner
# Statistics Server's profile for it. Either way it applies every time the
# game starts, with Win Juicer closed, and goes through the journal like any
# other change.
#
# Latency first. A cap the game can hold keeps the GPU below 100 %, so no
# frames queue up in front of it: that queue, not the cap, is where latency
# comes from. On NVIDIA the game's profile gets the low-latency recipe with
# it: pre-rendered frames at 1 (the Control Panel's «Low Latency Mode: On»,
# which Reflex overrides in games that have it, and those games pace the cap
# through Reflex itself) and, with variable refresh, VSync forced on, which
# under a cap below the refresh never engages except to hide a tear on a
# spike. «Ultra» has no public setting id, so it is left to the user.
#
# What Win Juicer adds is the number, from how the monitor is used (see
# Resolve-JuicerMonitorUse):
#   VRR, EstroboSync  Hz − Hz²/3600, the cap NVIDIA Reflex uses: just under
#                     the refresh, so frame-time jitter never pushes it out of
#                     the VRR range (138 at 144 Hz, 157 at 165, 171 at 180).
#   Estrobo           exactly the refresh, with VSync: a strobed backlight
#                     flashes at a fixed rate and every flash needs a new
#                     frame. Never lower: a cap under the refresh repeats
#                     frames, which strobing shows as judder. If the game
#                     cannot hold it, the advice is a lower refresh instead.
#   Fijo              the refresh rate.
# And outside Estrobo, when a measurement of that game showed it cannot hold
# that, the rate it holds 90 % of the time: an even cap below what the game
# can do is what flattens the frame times. Calibrating a game measures it
# under its cap and moves the cap to what it really holds, down or back up
# (see Get-JuicerPacerCalibration), and that wins until the monitor changes.
#
# Under strobing, VSync waits for the display, whose real rate is a fraction
# (179.96 Hz): a cap of 180 is a hair faster, the VSync queue fills, and a
# frame of latency comes back. RivaTuner takes fractions, so there the cap
# goes 0.01 under the exact rate («low-lag VSync»); the driver only takes
# whole numbers, which the conflict check points out.

function Get-JuicerFpsBackend { [string](& (Get-JuicerBackend).FpsBackend) }

# --- What the frame pacer remembers ------------------------------------------
# Engine: Auto, nvidia or rtss. Calibrated: exe -> @{ Fps; Why; Signature; Date }.

function Get-JuicerPacerPath { Join-Path (Get-JuicerHome) 'frame-pacer.json' }

function Read-JuicerPacer {
    $p = Get-JuicerPacerPath
    $s = @{ Engine = 'Auto'; Calibrated = @{} }
    if (Test-Path -LiteralPath $p) {
        try {
            $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
            if ($d.Engine -in 'Auto', 'nvidia', 'rtss') { $s.Engine = [string]$d.Engine }
            if ($d.Calibrated -is [hashtable]) { $s.Calibrated = $d.Calibrated }
        } catch {
            Write-JuicerLog "frame-pacer.json dañado, se ignora: $_"
        }
    }
    $s
}

function Save-JuicerPacer {
    param([hashtable]$State)
    [IO.File]::WriteAllText((Get-JuicerPacerPath), (ConvertTo-JuicerJson $State), (New-Object Text.UTF8Encoding $false))
}

function Get-JuicerPacerEngine { [string](Read-JuicerPacer).Engine }

# Which engines this PC has: nvidia, rtss, both or none.
function Get-JuicerPacerEngines { @(& (Get-JuicerBackend).FpsEngines) }

# Moving every limited game to the other engine: each one is undone (which
# puts back what the old engine had) and set again with the new one, so no
# game is left with two limiters.
function Set-JuicerPacerEngine {
    param([ValidateSet('Auto', 'nvidia', 'rtss')][string]$Engine, [hashtable]$Monitor)
    if ($Engine -ne 'Auto' -and (Get-JuicerPacerEngines) -notcontains $Engine) {
        throw $(if ($Engine -eq 'rtss') { 'RivaTuner Statistics Server no está instalado (pestaña Instalar).' } else { 'No hay una gráfica NVIDIA con su driver.' })
    }
    $before = Get-JuicerFpsBackend
    $state = Read-JuicerPacer
    $state.Engine = $Engine
    Save-JuicerPacer $state
    & (Get-JuicerBackend).FpsReset
    if ((Get-JuicerFpsBackend) -eq $before) { return @() }
    $games = @(Get-JuicerFpsLimits)
    foreach ($g in $games) { [void](Undo-JuicerTweak $g.Id) }
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    foreach ($g in $games) { Add-JuicerFpsLimit $g.Exe 0 $Monitor }
}

# --- RTSS profiles -------------------------------------------------------------
# [Framerate] Limit, over LimitDenominator when there is one (RTSS 6.5.1+):
# Limit=179950 with LimitDenominator=1000 is 179.95 FPS.

function Get-JuicerRtssLimit {
    param([string[]]$Lines)
    $v = ConvertTo-JuicerNumber (Get-JuicerIniValue $Lines 'Framerate' 'Limit')
    if (-not $v -or $v -le 0) { return 0.0 }
    $d = ConvertTo-JuicerNumber (Get-JuicerIniValue $Lines 'Framerate' 'LimitDenominator')
    if (-not $d -or $d -le 0) { $d = 1 }
    [Math]::Round($v / $d, 3)
}

function Set-JuicerRtssLimit {
    param([string[]]$Lines, [int]$Fps, [double]$Exact = 0)
    if ($Exact -gt 0) {
        $l = Set-JuicerIniValue $Lines 'Framerate' 'Limit' ([string][int64][Math]::Round($Exact * 1000))
        return (Set-JuicerIniValue $l 'Framerate' 'LimitDenominator' '1000')
    }
    $l = Set-JuicerIniValue $Lines 'Framerate' 'Limit' "$Fps"
    if ($null -ne (Get-JuicerIniValue $l 'Framerate' 'LimitDenominator')) { $l = Set-JuicerIniValue $l 'Framerate' 'LimitDenominator' '1' }
    $l
}

# Use is VRR, EstroboSync, Estrobo or Fijo; Rates, the refresh rates the
# monitor offers, to suggest one a game can hold under strobing. Returns
# Fps, Why, VSync (whether to force it in the driver) and Warn.
function Get-JuicerFpsCap {
    param([int]$Hz, [string]$Use = 'Fijo', [hashtable]$Measured, [int]$VrrMin = 0, [int[]]$Rates = @(), [double]$ExactHz = 0)
    if ($Hz -le 0) { return $null }
    $warn = $null
    $exact = 0
    $lowered = $true
    switch ($Use) {
        'VRR' {
            $fps = [int][Math]::Floor($Hz - $Hz * $Hz / 3600)
            $vsync = $true
            $why = "Pantalla de $Hz Hz con frecuencia variable: $fps FPS ({0:N2} ms por fotograma) la mantiene siempre dentro del rango VRR, la misma cifra que usa NVIDIA Reflex. Con la sincronización vertical forzada en el driver y el límite por debajo de los Hz, VSync no llega a esperar nunca: sólo tapa un corte si un fotograma llega antes de tiempo, sin sumar latencia." -f (1000 / $fps)
        }
        'EstroboSync' {
            $fps = [int][Math]::Floor($Hz - $Hz * $Hz / 3600)
            $vsync = $true
            $why = "Pantalla de $Hz Hz con estroboscopio y frecuencia variable: el mismo objetivo que con VRR, $fps FPS ({0:N2} ms por fotograma), para no salir nunca del rango. El destello sigue a cada fotograma: cuanto más estable el frametime, más uniforme el parpadeo." -f (1000 / $fps)
        }
        'Estrobo' {
            $fps = $Hz
            $vsync = $true
            $lowered = $false
            # With VSync, a hair under the real refresh: the queue never fills.
            if ($ExactHz -gt 0 -and [Math]::Abs($ExactHz - $Hz) -lt 1) { $exact = [Math]::Round($ExactHz - 0.01, 3) }
            $why = "Pantalla a $Hz Hz con estroboscopio, sin VRR: la retroiluminación destella $Hz veces por segundo y cada destello tiene que mostrar un fotograma nuevo. Límite exacto a $Hz FPS ({0:N2} ms por fotograma) con la sincronización vertical forzada: un fotograma por destello y sin cortes, que con estrobo se ven el doble. Como el juego nunca produce más fotogramas de los que la pantalla enseña, no se forma cola: con pre-renderizados a 1, o con Reflex en los juegos que lo tienen, la latencia queda en lo mínimo que permite una frecuencia fija. Por debajo de los Hz no: se repetirían fotogramas, y el estrobo lo convierte en saltos." -f (1000 / $fps)
            if ($Measured -and $Measured.Low1 -gt 0 -and $Measured.Low1 -lt $Hz - 0.5) {
                $held = [int][Math]::Floor($Measured.Low1)
                $better = @($Rates | Where-Object { $_ -le $held -and $_ -ge 60 } | Sort-Object -Descending)
                $warn = if ($better.Count -gt 0) {
                    "Este juego baja a {0:N0} FPS (1 % bajo) y con estrobo cada fotograma que falta es un salto. Baja el monitor a $($better[0]) Hz para este juego (Configuración > Pantalla > Pantalla avanzada), usa el estrobo ahí si el monitor lo permite a esa frecuencia, y el límite irá a $($better[0]). O, para este juego, VRR sin estrobo." -f $Measured.Low1
                } else {
                    "Este juego baja a {0:N0} FPS (1 % bajo): con estrobo cada fotograma que falta es un salto, y ninguna frecuencia de tu monitor queda por debajo. Para este juego, mejor VRR sin estrobo." -f $Measured.Low1
                }
            }
        }
        default {
            $fps = $Hz
            $vsync = $false
            $why = "Pantalla de $Hz Hz a frecuencia fija: más FPS que Hz no se ven enteros. Un objetivo de {0:N2} ms por fotograma evita la cola de VSync y los picos de carga." -f (1000 / $fps)
        }
    }
    if ($lowered -and $Measured -and $Measured.Fps90 -gt 0 -and $Measured.AvgFps -gt 0 -and $Measured.Low1 / $Measured.AvgFps -lt 0.7) {
        $held = [int][Math]::Floor($Measured.Fps90)
        $floor = [Math]::Max(30, $(if ($Use -in 'VRR', 'EstroboSync' -and $VrrMin -gt 0) { $VrrMin + 3 } else { 0 }))
        if ($held -lt $fps -and $held -ge $floor) {
            $fps = $held
            $why = "Este juego sostiene unos $held FPS el 90 % del tiempo y sus frametimes oscilan: un objetivo de {0:N2} ms por fotograma deja un ritmo constante, que se nota más fluido que una media más alta con tirones, y con la gráfica por debajo del 100 % no se forma cola de fotogramas, así que la latencia baja en vez de subir." -f (1000 / $held)
        }
    }
    @{ Fps = $fps; Exact = $exact; Why = $why; VSync = $vsync; Warn = $warn; Use = $Use }
}

# --- INI files (RTSS profiles) ---------------------------------------------

function Get-JuicerIniValue {
    param([string[]]$Lines, [string]$Section, [string]$Key)
    $in = $false
    foreach ($l in $Lines) {
        $t = $l.Trim()
        if ($t -match '^\[(.+)\]$') { $in = $Matches[1] -eq $Section; continue }
        if ($in -and $t -match "^$([regex]::Escape($Key))\s*=(.*)$") { return $Matches[1].Trim() }
    }
    $null
}

# The lines with Key set in Section; the rest stays exactly as it was.
function Set-JuicerIniValue {
    param([string[]]$Lines, [string]$Section, [string]$Key, [string]$Value)
    $out = New-Object System.Collections.Generic.List[string]
    $in = $false; $done = $false; $seen = $false
    foreach ($l in @($Lines)) {
        $t = $l.Trim()
        if ($t -match '^\[(.+)\]$') {
            if ($in -and -not $done) { $out.Add("$Key=$Value"); $done = $true }
            $in = $Matches[1] -eq $Section
            if ($in) { $seen = $true }
            $out.Add($l); continue
        }
        if ($in -and -not $done -and $t -match "^$([regex]::Escape($Key))\s*=") { $out.Add("$Key=$Value"); $done = $true; continue }
        $out.Add($l)
    }
    if (-not $done) {
        if (-not $seen) { $out.Add("[$Section]") }
        $out.Add("$Key=$Value")
    }
    $out.ToArray()
}

# --- Per game ------------------------------------------------------------------

function ConvertTo-JuicerExeName {
    param([string]$Exe)
    $n = (Split-Path -Leaf $Exe.Trim().Trim('"')).ToLowerInvariant()
    if ($n -notlike '*.exe') { $n += '.exe' }
    $n
}

# VSync forces vertical sync in the game's NVIDIA profile; Use (from
# Resolve-JuicerMonitorUse) only words it.
function New-JuicerFpsLimitTweak {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][int]$Fps, [string]$Why = '', [switch]$VSync, [string]$Use = 'Fijo', [double]$Exact = 0)
    $exe = ConvertTo-JuicerExeName $Exe
    # The NVIDIA parts do nothing (and count as done) without an NVIDIA driver.
    # Exact only reaches RivaTuner; the driver keeps Fps.
    $limit = @{ Type = 'FpsLimit'; Exe = $exe; Fps = $Fps }
    if ($Exact -gt 0) { $limit.Exact = $Exact }
    $actions = @(
        $limit
        @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x007BA09E; Value = [uint32]1; Label = 'Fotogramas pre-renderizados: 1 (modo de baja latencia activado)' }
        # With a cap the card is not at 100 %, and the driver may drop its
        # clocks in light scenes: the next heavy frame then arrives late.
        # Only for this game, so the desktop still idles low (PREFERRED_PSTATE_PREFER_MAX).
        @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x1057EB71; Value = [uint32]1; Label = 'Modo de energía: preferir rendimiento máximo (sin bajadas de frecuencia que den picos de frametime)' }
    )
    if ($VSync) {
        $label = if ($Use -eq 'Estrobo') { 'Sincronización vertical: forzada (un fotograma por destello del estroboscopio)' } else { 'Sincronización vertical: forzada (con G-SYNC y el límite por debajo de los Hz)' }
        $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x47814940; Label = $label }
    }
    $sync = if (-not $VSync) { '.' } elseif ($Use -eq 'Estrobo') { ' y con la sincronización vertical que el estroboscopio necesita.' } else { ' y con la sincronización vertical que G-SYNC necesita.' }
    @{
        Id = "fps:$exe"; Category = 'Juegos'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Frame pacer a {0} FPS ({1:N2} ms): {2}' -f $Fps, (1000 / [Math]::Max(1, $Fps)), $exe
        What = "Marca a $exe un ritmo de $Fps FPS cada vez que se abra, desde el driver de NVIDIA o RivaTuner, sin inyectar nada en el juego. Con NVIDIA, además, sin cola de fotogramas$sync"
        Gain = $(if ($Why) { $Why } else { 'Frametimes constantes y menos latencia que dejar que la gráfica vaya al máximo.' })
        Cost = 'Si el juego podría ir más rápido, ese margen no se usa (se nota menos que los tirones que quita). Si el juego tiene NVIDIA Reflex, actívalo en sus opciones: el límite se aplica entonces a través de Reflex.'
        Skip = { if (-not (Get-JuicerFpsBackend)) { 'El frame pacer necesita una gráfica NVIDIA o RivaTuner Statistics Server (pestaña Instalar).' } }
        Actions = $actions
    }
}

# The cap Win Juicer would set for this game on this screen, used the way
# its owner uses it. A warning, if any, goes at the end of Why.
function Get-JuicerRecommendedFps {
    param([string]$Exe, [hashtable]$Monitor)
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { return $null }
    $hz = [int]$Monitor.Display.Hz
    $vrr = $Monitor.Vrr
    $exe = ConvertTo-JuicerExeName $Exe
    $use = Resolve-JuicerMonitorUse $Monitor
    $vrrMin = if ($vrr) { [int]$vrr.Min } else { 0 }
    $measured = Get-JuicerPreviousFrameResult $exe
    $cap = Get-JuicerFpsCap $hz $use $measured $vrrMin @($Monitor.Display.RefreshRates | Where-Object { $_ }) ([double]$Monitor.Display.ExactHz)
    # A calibration on this same screen, used the same way, knows better
    # than one measurement: it was taken under the cap.
    $cal = (Read-JuicerPacer).Calibrated[$exe]
    if ($cap -and $cal -and $use -ne 'Estrobo' -and [string]$cal.Signature -eq (Get-JuicerLimitSignature $Monitor) -and [int]$cal.Fps -gt 0) {
        $max = (Get-JuicerFpsCap $hz $use $null $vrrMin).Fps
        $cap.Fps = [Math]::Min($max, [int]$cal.Fps)
        $cap.Why = [string]$cal.Why
        $cap.Calibrated = $true
    }
    if ($cap -and $cap.Warn) { $cap.Why = "$($cap.Why) $($cap.Warn)" }
    $cap
}

# Use overrides how the monitor is used, for when it cannot be read.
function Add-JuicerFpsLimit {
    param([Parameter(Mandatory)][string]$Exe, [int]$Fps, [hashtable]$Monitor, [string]$Use)
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $use = if ($Use -and $Use -ne 'Automatico') { $Use } else { Resolve-JuicerMonitorUse $Monitor }
    $why = ''
    $exact = 0
    if ($Fps -le 0) {
        $cap = Get-JuicerRecommendedFps $Exe $Monitor
        if (-not $cap) { throw 'No se pudo leer la pantalla para calcular el ritmo: indícalo a mano.' }
        $Fps = $cap.Fps; $why = $cap.Why; $exact = [double]$cap.Exact
    }
    Invoke-JuicerTweak (New-JuicerFpsLimitTweak $Exe $Fps $why -VSync:($use -in 'VRR', 'EstroboSync', 'Estrobo') -Use $use -Exact $exact)
}

# Every game already limited, again with today's recommended cap: after
# changing how the monitor is used, or its refresh rate.
function Update-JuicerFpsLimits {
    param([hashtable]$Monitor)
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    foreach ($g in @(Get-JuicerFpsLimits)) { Add-JuicerFpsLimit $g.Exe 0 $Monitor }
}

# Games limited by Win Juicer, with the cap in force now.
function Get-JuicerFpsLimits {
    $b = Get-JuicerBackend
    # Assigned first: Read-JuicerJournal hands the list over whole, and piping
    # the call itself would filter one object, the list.
    $journal = Read-JuicerJournal
    foreach ($e in @($journal | Where-Object { ([string]$_.Id) -like 'fps:*' })) {
        $exe = ([string]$e.Id).Substring(4)
        $cur = $null
        # Read where it was set, even if the engine changed since.
        $by = @($e.Actions | Where-Object { $_.Type -eq 'FpsLimit' } | ForEach-Object { [string]$_.Backend }) | Select-Object -First 1
        try { $cur = & $b.FpsRead $exe $by } catch { Write-JuicerLog "No se pudo leer el ritmo de ${exe}: $_" }
        @{ Id = [string]$e.Id; Exe = $exe; Fps = $(if ($cur) { $cur.Fps } else { $null }); Exact = $(if ($cur) { [double]$cur.Exact } else { 0 }); Backend = $(if ($cur) { $cur.Backend } else { '' }) }
    }
}

# Measured games not limited yet: the obvious ones to add.
function Get-JuicerUnlimitedGames {
    $limited = @(Get-JuicerFpsLimits | ForEach-Object { $_.Exe })
    @(Read-JuicerFrameHistory | ForEach-Object { ([string]$_.Application).ToLowerInvariant() } | Where-Object { $_ -and $limited -notcontains $_ } | Select-Object -Unique)
}

function Format-JuicerFpsBackend {
    param([string]$Backend)
    switch ($Backend) {
        'nvidia' { 'el limitador del driver de NVIDIA (el de «Velocidad máxima de fotogramas»), por juego' }
        'rtss' { 'RivaTuner Statistics Server (tiene que estar abierto; se queda en la bandeja). En su Setup, «Framerate limiter»: «Front edge sync» da la menor latencia y «Back edge sync» los frametimes más planos' }
        default { 'ninguno todavía: con NVIDIA lo hace el driver; con AMD o Intel, instala RivaTuner Statistics Server desde la pestaña Instalar' }
    }
}

# --- How well it paces --------------------------------------------------------

# A measurement of a game under its frame pacer, against its target. Cap is
# the FPS set; Exact, the fractional one RivaTuner uses, if any.
function Get-JuicerPacerFindings {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][int]$Cap, [double]$Exact = 0)
    $area = "Frame pacer: $($Result.Application)"
    $target = if ($Exact -gt 0) { $Exact } else { $Cap }
    $ms = 1000 / $target
    if ($Result.AvgFps -gt $target * 1.04) {
        return (New-JuicerFinding $area 'Medio' ('No está actuando: {0:N0} FPS con un ritmo de {1} FPS' -f $Result.AvgFps, $target) 'El juego va por encima del objetivo. Con RivaTuner, tiene que estar abierto (en la bandeja); si el juego se lanza con otro .exe que el que tiene el ritmo, cámbialo en «Tus juegos» > «Cambiar .exe…». Si el juego tiene un limitador propio más alto, no importa: el más bajo manda.')
    }
    $detail = '{0} % de los fotogramas a {1:N2} ms ±{2:N1}; de un fotograma al siguiente cambian {3:N2} ms de media.' -f $Result.Steady, $ms, [Math]::Max(0.3, 0.04 * $ms), $Result.JitterMs
    if ($null -ne $Result.AnimErrorMs) { $detail += ' Error de animación: {0:N2} ms de media (lo que el movimiento se desvía del tiempo real; cuanto más cerca de 0, más fluido).' -f $Result.AnimErrorMs }
    $holds = $Result.P95Ms -le $ms * 1.03
    if ($holds -and $Result.Steady -ge 90) {
        $out = @(New-JuicerFinding $area 'Ok' ('Ritmo clavado a {0} FPS' -f $target) $detail)
    } elseif (-not $holds) {
        $out = @(New-JuicerFinding $area 'Medio' ('No sostiene {0} FPS: el 5 % más lento va a {1:N0}' -f $target, $Result.Fps95) "$detail Cada vez que no llega, el frametime salta. «Calibrar» baja el ritmo a lo que sí sostiene, que se nota más fluido que un objetivo alto con altibajos.")
    } else {
        $out = @(New-JuicerFinding $area 'Bajo' ('Llega a {0} FPS, pero con el ritmo irregular' -f $target) "$detail Suele ser el propio juego (carga de zonas, shaders) o algo en segundo plano; repite la medida en otra escena antes de cambiar nada.")
    }
    if ($null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.WorkMs95 * 1.15 -lt 1000 / ($target + 3)) {
        $out += New-JuicerFinding $area 'Info' ('Hay margen: el trabajo de cada fotograma da para unos {0:N0} FPS' -f (1000 / ($Result.WorkMs95 * 1.15))) 'Si el ritmo está por debajo de lo que el monitor permite, «Calibrar» lo sube. Si ya está en su máximo, ese margen es lo que mantiene la latencia baja: la gráfica nunca llega al 100 %.'
    }
    $out
}

# What a measurement under the cap says the cap should be. Max is the
# highest the monitor allows (Get-JuicerFpsCap without a measurement).
# Action: Bajar, Subir, Mantener, NoActua or Estrobo (which never lowers:
# the advice is a lower refresh rate). Returns @{ Fps; Action; Why }.
function Get-JuicerPacerCalibration {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][int]$Cap, [int]$Max = 0, [string]$Use = 'Fijo', [int]$VrrMin = 0, [int[]]$Rates = @())
    if ($Max -le 0) { $Max = $Cap }
    $ms = 1000 / $Cap
    if ($Result.AvgFps -gt $Cap * 1.04) {
        return @{ Fps = $Cap; Action = 'NoActua'; Why = ('El juego iba a {0:N0} FPS, por encima del ritmo: el frame pacer no estaba actuando, así que esta medida no sirve para calibrar.' -f $Result.AvgFps) }
    }
    $misses = $Result.P95Ms -gt $ms * 1.03
    if ($Use -eq 'Estrobo') {
        if (-not $misses) { return @{ Fps = $Cap; Action = 'Mantener'; Why = "Sostiene $Cap FPS: un fotograma nuevo en cada destello del estroboscopio." } }
        $c = Get-JuicerFpsCap $Cap 'Estrobo' @{ Low1 = $Result.Fps95; AvgFps = $Result.AvgFps } 0 $Rates
        return @{ Fps = $Cap; Action = 'Estrobo'; Why = $(if ($c.Warn) { $c.Warn } else { "No sostiene $Cap FPS, y con estrobo el ritmo no baja de los Hz." }) }
    }
    $floor = [Math]::Max(30, $(if ($Use -in 'VRR', 'EstroboSync' -and $VrrMin -gt 0) { $VrrMin + 3 } else { 0 }))
    if ($misses) {
        $new = [int][Math]::Floor($Result.Fps95)
        if ($new -lt $floor) { $new = $floor }
        if ($new -lt $Cap) {
            return @{ Fps = $new; Action = 'Bajar'; Why = ('Calibrado: con {0} FPS el 5 % de los fotogramas llegaba tarde; a {1} FPS ({2:N2} ms) los sostiene, y un ritmo que se cumple siempre se nota más fluido que uno más alto que se rompe.' -f $Cap, $new, (1000 / $new)) }
        }
        return @{ Fps = $Cap; Action = 'Mantener'; Why = "No sostiene $Cap FPS, pero bajar más saldría del rango de frecuencia variable: mejor bajar la calidad gráfica." }
    }
    if ($Cap -lt $Max -and $null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.Steady -ge 85) {
        $can = [int][Math]::Floor(1000 / ($Result.WorkMs95 * 1.15))
        $new = [Math]::Min($Max, $can)
        if ($new -ge $Cap + 3) {
            return @{ Fps = $new; Action = 'Subir'; Why = ('Calibrado: a {0} FPS sobraba tiempo en cada fotograma; a {1} FPS ({2:N2} ms) aún queda un 15 % de margen para los picos.' -f $Cap, $new, (1000 / $new)) }
        }
    }
    @{ Fps = $Cap; Action = 'Mantener'; Why = "Sostiene $Cap FPS con el ritmo estable: está en su sitio." }
}

# Measures a game under its frame pacer (setting it first if it had none),
# moves the cap to what it holds, and remembers it for this monitor. Returns
# findings; callers wrap them in @().
function Invoke-JuicerPacerCalibration {
    param([Parameter(Mandatory)][string]$Exe, [int]$Seconds = 60, [int]$Delay = 10, [scriptblock]$OnStatus, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName $Exe
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { throw 'No se pudo leer la pantalla.' }
    if (-not @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe -and $_.Fps })) { [void](Add-JuicerFpsLimit $exe 0 $Monitor) }
    $now = @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe })
    if ($now.Count -eq 0 -or -not $now[0].Fps) { throw "No se pudo poner el frame pacer a $exe." }
    $cap = [int]$now[0].Fps
    $started = Get-Date
    $out = @(Invoke-JuicerFrameCapture -Seconds $Seconds -Delay $Delay -Process $exe -OnStatus $OnStatus)
    $result = Get-JuicerPreviousFrameResult $exe
    if (-not $result -or [datetime]$result.Date -lt $started.AddSeconds(-5)) { return $out }
    $use = Resolve-JuicerMonitorUse $Monitor
    $vrrMin = if ($Monitor.Vrr) { [int]$Monitor.Vrr.Min } else { 0 }
    $max = (Get-JuicerFpsCap ([int]$Monitor.Display.Hz) $use $null $vrrMin).Fps
    $c = Get-JuicerPacerCalibration $result $cap $max $use $vrrMin @($Monitor.Display.RefreshRates | Where-Object { $_ })
    $area = "Frame pacer: $exe"
    if ($c.Action -in 'Bajar', 'Subir') {
        $state = Read-JuicerPacer
        $state.Calibrated[$exe] = @{ Fps = $c.Fps; Why = $c.Why; Signature = (Get-JuicerLimitSignature $Monitor); Date = (Get-Date).ToString('s') }
        Save-JuicerPacer $state
        $r = Add-JuicerFpsLimit $exe 0 $Monitor
        $sev = if ($r.Outcome -in 'Aplicado', 'YaEstaba') { 'Ok' } else { 'Medio' }
        $out += New-JuicerFinding $area $sev ('Calibrado: de {0} a {1} FPS' -f $cap, $c.Fps) $c.Why
    } else {
        $out += New-JuicerFinding $area $(if ($c.Action -eq 'Mantener') { 'Ok' } else { 'Medio' }) $(switch ($c.Action) { 'Mantener' { "Calibrado: se queda en $cap FPS" } 'Estrobo' { 'Con estrobo no se baja el ritmo' } default { 'Sin calibrar' } }) $c.Why
    }
    Write-JuicerLog "Calibración de ${exe}: $($c.Action) $cap -> $($c.Fps)"
    $out
}

# Forgets what calibrating found, for one game or all.
function Clear-JuicerPacerCalibration {
    param([string]$Exe)
    $state = Read-JuicerPacer
    if ($Exe) { $state.Calibrated.Remove((ConvertTo-JuicerExeName $Exe)) } else { $state.Calibrated = @{} }
    Save-JuicerPacer $state
}

# --- Two limiters at once -----------------------------------------------------

# Whatever else limits frames and would fight the frame pacer, and what the
# engine in use cannot do with this monitor. State comes from the backend
# (RTSS's Global profile and games, NVIDIA's global limit); Limits, from
# Get-JuicerFpsLimits.
function Get-JuicerPacerConflicts {
    param([hashtable]$State, [string]$Backend, [object[]]$Limits = @(), [hashtable]$Monitor)
    $out = @()
    $area = 'Frame pacer'
    if (-not $State) { return $out }
    $mine = @($Limits | ForEach-Object { $_.Exe })
    if ($Backend -eq 'rtss' -and $State.RtssInstalled -and -not $State.RtssRunning -and $mine.Count -gt 0) {
        $out += New-JuicerFinding $area 'Alto' 'RivaTuner no está abierto: el frame pacer no actúa' 'RivaTuner aplica el ritmo sólo mientras está abierto. Ábrelo y, en su ventana, deja activado «Start with Windows».'
    }
    if ($State.RtssGlobal -gt 0 -and ($Backend -eq 'nvidia' -or $State.RtssRunning)) {
        $out += New-JuicerFinding $area 'Medio' ('RivaTuner tiene un límite global de {0:N0} FPS' -f $State.RtssGlobal) $(if ($Backend -eq 'nvidia') { 'Se suma al del driver en todos los juegos: dos limitadores con cifras distintas dan un ritmo irregular. En RivaTuner, perfil «Global», deja «Framerate limit» en 0 y que el frame pacer marque el ritmo por juego.' } else { 'Cada juego sin perfil propio lo hereda. Si no lo pusiste a propósito, déjalo en 0 en el perfil «Global» de RivaTuner.' })
    }
    if ($Backend -eq 'nvidia') {
        $double = @($mine | Where-Object { $State.RtssGames.ContainsKey($_) })
        if ($double.Count -gt 0) {
            $out += New-JuicerFinding $area 'Medio' ('Con dos limitadores a la vez: ' + ($double -join ', ')) 'Tienen el ritmo del driver y además un límite en su perfil de RivaTuner. Quita el de RivaTuner (su perfil, «Framerate limit» a 0) o pasa el frame pacer a RivaTuner.'
        }
    }
    if ($Backend -eq 'nvidia' -and $State.NvGlobal -gt 0) {
        $low = @($Limits | Where-Object { $_.Fps -and $_.Fps -gt $State.NvGlobal })
        $out += New-JuicerFinding $area $(if ($low.Count -gt 0) { 'Medio' } else { 'Bajo' }) ('El panel de NVIDIA tiene un límite global de {0} FPS' -f $State.NvGlobal) ('Los juegos del frame pacer usan el suyo; el resto, ese. Si no lo pusiste a propósito, quítalo en Administrar la configuración 3D > Configuración global > Velocidad máxima de fotogramas.')
    }
    if ($Monitor -and (Resolve-JuicerMonitorUse $Monitor) -eq 'Estrobo') {
        $hz = [int]$Monitor.Display.Hz
        $exact = [double]$Monitor.Display.ExactHz
        if ($Backend -eq 'nvidia' -and $exact -gt 0 -and $exact -lt $hz - 0.004) {
            $tail = if ($State.RtssInstalled) { 'Tienes RivaTuner: elige «RivaTuner» como motor del frame pacer y el ritmo irá a {0:N2} FPS, justo por debajo.' -f ($exact - 0.01) } else { 'RivaTuner admite décimas: instálalo (pestaña Instalar), elígelo como motor del frame pacer y el ritmo irá justo por debajo, a {0:N2} FPS.' -f ($exact - 0.01) }
            $out += New-JuicerFinding $area 'Medio' ('Tu pantalla va a {0:N3} Hz, y el driver de NVIDIA sólo limita en enteros' -f $exact) ("Con estrobo y sincronización vertical, $hz FPS es un pelo más rápido que la pantalla: la cola de la sincronización vertical se llena y vuelve un fotograma de latencia (unos {0:N1} ms). $tail" -f (1000 / $exact))
        } elseif ($Backend -eq 'rtss' -and $exact -gt 0) {
            $out += New-JuicerFinding $area 'Ok' ('Ritmo al Hz exacto: {0:N2} FPS para una pantalla a {1:N3} Hz' -f ($exact - 0.01), $exact) 'Justo por debajo del refresco real, con la sincronización vertical: un fotograma por destello y sin la cola que añade latencia («low-lag VSync»).'
        }
    }
    $out
}

# The conflicts on this PC, now.
function Get-JuicerPacerConflictsHere {
    $state = $null
    try { $state = & (Get-JuicerBackend).PacerState } catch { Write-JuicerLog "Sin estado del frame pacer: $_" }
    $m = $null
    try { $m = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
    Get-JuicerPacerConflicts $state (Get-JuicerFpsBackend) @(Get-JuicerFpsLimits) $m
}
