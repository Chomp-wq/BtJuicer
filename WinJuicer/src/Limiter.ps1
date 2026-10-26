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
# What Win Juicer adds is the number. With variable refresh, Hz − Hz²/3600,
# the cap NVIDIA Reflex uses: just under the refresh, so frame-time jitter
# never pushes it out of the VRR range (138 at 144 Hz, 157 at 165, 224 at
# 240). Without VRR, the refresh rate. And when a measurement of that game
# showed it cannot hold that, the rate it holds 90 % of the time: an even
# cap below what the game can do is what flattens the frame times.

function Get-JuicerFpsBackend { [string](& (Get-JuicerBackend).FpsBackend) }

function Get-JuicerFpsCap {
    param([int]$Hz, [bool]$Vrr, [hashtable]$Measured, [int]$VrrMin = 0)
    if ($Hz -le 0) { return $null }
    if ($Vrr) {
        $fps = [int][Math]::Floor($Hz - $Hz * $Hz / 3600)
        $why = "Pantalla de $Hz Hz con frecuencia variable: $fps FPS ({0:N2} ms por fotograma) la mantiene siempre dentro del rango VRR, la misma cifra que usa NVIDIA Reflex." -f (1000 / $fps)
    } else {
        $fps = $Hz
        $why = "Pantalla de $Hz Hz sin frecuencia variable: más FPS que Hz no se ven enteros. Un objetivo de {0:N2} ms por fotograma evita la cola de VSync y los picos de carga." -f (1000 / $fps)
    }
    if ($Measured -and $Measured.Fps90 -gt 0 -and $Measured.AvgFps -gt 0 -and $Measured.Low1 / $Measured.AvgFps -lt 0.7) {
        $held = [int][Math]::Floor($Measured.Fps90)
        $floor = [Math]::Max(30, $(if ($Vrr -and $VrrMin -gt 0) { $VrrMin + 3 } else { 0 }))
        if ($held -lt $fps -and $held -ge $floor) {
            $fps = $held
            $why = "Este juego sostiene unos $held FPS el 90 % del tiempo y sus frametimes oscilan: un objetivo de {0:N2} ms por fotograma deja un ritmo constante, que se nota más fluido que una media más alta con tirones, y con la gráfica por debajo del 100 % no se forma cola de fotogramas, así que la latencia baja en vez de subir." -f (1000 / $held)
        }
    }
    @{ Fps = $fps; Why = $why }
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

function New-JuicerFpsLimitTweak {
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][int]$Fps, [string]$Why = '', [switch]$Vrr)
    $exe = ConvertTo-JuicerExeName $Exe
    # The NVIDIA parts do nothing (and count as done) without an NVIDIA driver.
    $actions = @(
        @{ Type = 'FpsLimit'; Exe = $exe; Fps = $Fps }
        @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x007BA09E; Value = [uint32]1; Label = 'Fotogramas pre-renderizados: 1 (modo de baja latencia activado)' }
    )
    if ($Vrr) { $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x47814940; Label = 'Sincronización vertical: forzada (con G-SYNC y el límite por debajo de los Hz)' } }
    @{
        Id = "fps:$exe"; Category = 'Juegos'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Límite de {0} FPS ({1:N2} ms): {2}' -f $Fps, (1000 / [Math]::Max(1, $Fps)), $exe
        What = "Limita $exe a $Fps FPS cada vez que se abra, desde el driver de NVIDIA o RivaTuner, sin inyectar nada en el juego. Con NVIDIA, además, sin cola de fotogramas" + $(if ($Vrr) { ' y con la sincronización vertical que G-SYNC necesita.' } else { '.' })
        Gain = $(if ($Why) { $Why } else { 'Frametimes constantes y menos latencia que dejar que la gráfica vaya al máximo.' })
        Cost = 'Si el juego podría ir más rápido, ese margen no se usa (se nota menos que los tirones que quita). Si el juego tiene NVIDIA Reflex, actívalo en sus opciones: el límite se aplica entonces a través de Reflex.'
        Skip = { if (-not (Get-JuicerFpsBackend)) { 'No hay limitador disponible: hace falta una gráfica NVIDIA o RivaTuner Statistics Server (pestaña Instalar).' } }
        Actions = $actions
    }
}

# The cap Win Juicer would set for this game on this screen.
function Get-JuicerRecommendedFps {
    param([string]$Exe, [hashtable]$Monitor)
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { return $null }
    $hz = [int]$Monitor.Display.Hz
    $vrr = $Monitor.Vrr
    $measured = Get-JuicerPreviousFrameResult (ConvertTo-JuicerExeName $Exe)
    Get-JuicerFpsCap $hz ([bool]$vrr) $measured $(if ($vrr) { [int]$vrr.Min } else { 0 })
}

function Add-JuicerFpsLimit {
    param([Parameter(Mandatory)][string]$Exe, [int]$Fps, [hashtable]$Monitor)
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $why = ''
    if ($Fps -le 0) {
        $cap = Get-JuicerRecommendedFps $Exe $Monitor
        if (-not $cap) { throw 'No se pudo leer la pantalla para calcular el límite: indícalo a mano.' }
        $Fps = $cap.Fps; $why = $cap.Why
    }
    Invoke-JuicerTweak (New-JuicerFpsLimitTweak $Exe $Fps $why -Vrr:([bool]($Monitor -and $Monitor.Vrr)))
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
