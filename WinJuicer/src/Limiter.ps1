# The FPS limiter: a frame-time target per game, set where it costs nothing
# and needs no injection. With an NVIDIA card, the driver's own limiter in
# that game's profile; otherwise, RivaTuner Statistics Server's profile for
# it. Either way it applies every time the game starts, with Win Juicer
# closed, and goes through the journal like any other change.
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
# can do is what flattens the frame times.

function Get-JuicerFpsBackend { [string](& (Get-JuicerBackend).FpsBackend) }

# Use is VRR, EstroboSync, Estrobo or Fijo; Rates, the refresh rates the
# monitor offers, to suggest one a game can hold under strobing. Returns
# Fps, Why, VSync (whether to force it in the driver) and Warn.
function Get-JuicerFpsCap {
    param([int]$Hz, [string]$Use = 'Fijo', [hashtable]$Measured, [int]$VrrMin = 0, [int[]]$Rates = @())
    if ($Hz -le 0) { return $null }
    $warn = $null
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
    @{ Fps = $fps; Why = $why; VSync = $vsync; Warn = $warn; Use = $Use }
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
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][int]$Fps, [string]$Why = '', [switch]$VSync, [string]$Use = 'Fijo')
    $exe = ConvertTo-JuicerExeName $Exe
    # The NVIDIA parts do nothing (and count as done) without an NVIDIA driver.
    $actions = @(
        @{ Type = 'FpsLimit'; Exe = $exe; Fps = $Fps }
        @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x007BA09E; Value = [uint32]1; Label = 'Fotogramas pre-renderizados: 1 (modo de baja latencia activado)' }
    )
    if ($VSync) {
        $label = if ($Use -eq 'Estrobo') { 'Sincronización vertical: forzada (un fotograma por destello del estroboscopio)' } else { 'Sincronización vertical: forzada (con G-SYNC y el límite por debajo de los Hz)' }
        $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x47814940; Label = $label }
    }
    $sync = if (-not $VSync) { '.' } elseif ($Use -eq 'Estrobo') { ' y con la sincronización vertical que el estroboscopio necesita.' } else { ' y con la sincronización vertical que G-SYNC necesita.' }
    @{
        Id = "fps:$exe"; Category = 'Juegos'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Límite de {0} FPS ({1:N2} ms): {2}' -f $Fps, (1000 / [Math]::Max(1, $Fps)), $exe
        What = "Limita $exe a $Fps FPS cada vez que se abra, desde el driver de NVIDIA o RivaTuner, sin inyectar nada en el juego. Con NVIDIA, además, sin cola de fotogramas$sync"
        Gain = $(if ($Why) { $Why } else { 'Frametimes constantes y menos latencia que dejar que la gráfica vaya al máximo.' })
        Cost = 'Si el juego podría ir más rápido, ese margen no se usa (se nota menos que los tirones que quita). Si el juego tiene NVIDIA Reflex, actívalo en sus opciones: el límite se aplica entonces a través de Reflex.'
        Skip = { if (-not (Get-JuicerFpsBackend)) { 'No hay limitador disponible: hace falta una gráfica NVIDIA o RivaTuner Statistics Server (pestaña Instalar).' } }
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
    $measured = Get-JuicerPreviousFrameResult (ConvertTo-JuicerExeName $Exe)
    $cap = Get-JuicerFpsCap $hz (Resolve-JuicerMonitorUse $Monitor) $measured $(if ($vrr) { [int]$vrr.Min } else { 0 }) @($Monitor.Display.RefreshRates | Where-Object { $_ })
    if ($cap -and $cap.Warn) { $cap.Why = "$($cap.Why) $($cap.Warn)" }
    $cap
}

# Use overrides how the monitor is used, for when it cannot be read.
function Add-JuicerFpsLimit {
    param([Parameter(Mandatory)][string]$Exe, [int]$Fps, [hashtable]$Monitor, [string]$Use)
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $use = if ($Use -and $Use -ne 'Automatico') { $Use } else { Resolve-JuicerMonitorUse $Monitor }
    $why = ''
    if ($Fps -le 0) {
        $cap = Get-JuicerRecommendedFps $Exe $Monitor
        if (-not $cap) { throw 'No se pudo leer la pantalla para calcular el límite: indícalo a mano.' }
        $Fps = $cap.Fps; $why = $cap.Why
    }
    Invoke-JuicerTweak (New-JuicerFpsLimitTweak $Exe $Fps $why -VSync:($use -in 'VRR', 'EstroboSync', 'Estrobo') -Use $use)
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
    foreach ($e in @(Read-JuicerJournal | Where-Object { ([string]$_.Id) -like 'fps:*' })) {
        $exe = ([string]$e.Id).Substring(4)
        $cur = $null
        try { $cur = & $b.FpsRead $exe } catch { Write-JuicerLog "No se pudo leer el límite de ${exe}: $_" }
        @{ Id = [string]$e.Id; Exe = $exe; Fps = $(if ($cur) { $cur.Fps } else { $null }); Backend = $(if ($cur) { $cur.Backend } else { '' }) }
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
        default { 'ninguno: con NVIDIA lo hace el driver; con AMD o Intel, instala RivaTuner Statistics Server desde la pestaña Instalar' }
    }
}
