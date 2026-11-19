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
# spike. «Ultra» has no public setting id, so it is left to the user. The
# driver's «prefer maximum performance» is not part of it any more: it held
# the card at its top clocks through menus and loading screens, which is
# where a borderline overclock or undervolt, or a laptop's cooling, gives
# way, and the cap already keeps frame times even. Whatever NVIDIA set in a
# game's own profile stays as it is: it is there because that game needs it.
#
# Never under a running game: the driver hands an open game the new values
# at once, and switching its sync or its frame queue under it can freeze it.
# A change for a game that is open waits for it to close
# (Add-JuicerPacerPending).
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

# The cap NVIDIA Reflex, and the low latency mode «Ultra», put on a game under
# G-SYNC with VSync: Hz - Hz^2/3600, rounded down (171 at 180 Hz). One place
# for the formula the frame pacer, the notes and the measurement all share.
function Get-JuicerVrrCap {
    param([int]$Hz)
    if ($Hz -le 0) { return 0 }
    [int][Math]::Floor($Hz - $Hz * $Hz / 3600)
}

# --- What the frame pacer remembers ------------------------------------------
# Engine: Auto, nvidia or rtss. Calibrated: exe -> signature -> @{ Fps; Why;
# Signature; Date; Fingerprint }: one calibration per monitor setup (refresh
# rate, use and monitor, see Get-JuicerLimitSignature), so going back to the
# other screen finds its own again. Fingerprint is what the PC was running
# when it was made (graphics card, its driver, the game's build, Windows),
# to say when it is worth doing again. Files from before this kept one entry
# per exe, flat: Read-JuicerPacer turns it into a signature of its own.
# Games: exe -> @{ Priority = Fluidez | Latencia; Fps = a rate chosen by hand;
# Minimal = prudent mode, the cap alone; Safe = why Win Juicer took its
# changes away (see Update-JuicerGameSafety) }.
# Pending: exe -> what waits for that game to close (Add-JuicerPacerPending).
# Recipe: the version of the game recipe already brought up to date
# (Repair-JuicerGameSetups).

function Get-JuicerPacerPath { Join-Path (Get-JuicerHome) 'frame-pacer.json' }

# Calibrated as the file has it, in the current shape (exe -> signature -> entry). An old flat entry
# (Fps at the top) goes under the signature it carries; '?' when it carries none. Whatever is not an
# entry is dropped.
function ConvertTo-JuicerCalibrationMap {
    param($Value)
    $map = @{}
    if ($Value -isnot [hashtable]) { return $map }
    foreach ($exe in @($Value.Keys)) {
        $v = $Value[$exe]
        if ($v -isnot [hashtable]) { continue }
        $per = @{}
        if ($v.ContainsKey('Fps')) {
            $sig = if ($v.Signature) { [string]$v.Signature } else { '?' }
            if ([int]$v.Fps -gt 0) { $per[$sig] = $v }
        } else {
            foreach ($sig in @($v.Keys)) {
                $e = $v[$sig]
                if ($e -is [hashtable] -and [int]$e.Fps -gt 0) { if (-not $e.Signature -and $sig -ne '?') { $e.Signature = [string]$sig }; $per[[string]$sig] = $e }
            }
        }
        if ($per.Count -gt 0) { $map[[string]$exe] = $per }
    }
    $map
}

# The calibration of a game for this signature (null if there is none).
function Get-JuicerCalibrationEntry {
    param([hashtable]$Pacer, [string]$Exe, [string]$Signature)
    $per = $Pacer.Calibrated[(ConvertTo-JuicerExeName $Exe)]
    if ($per -is [hashtable] -and $Signature -and $per[$Signature] -is [hashtable]) { return $per[$Signature] }
    $null
}

# Saves one (or, with a null Entry, removes it) in a pacer state, keeping the four most recent per game.
function Set-JuicerCalibrationEntry {
    param([hashtable]$Pacer, [string]$Exe, [string]$Signature, $Entry)
    $key = ConvertTo-JuicerExeName $Exe
    $per = if ($Pacer.Calibrated[$key] -is [hashtable]) { $Pacer.Calibrated[$key] } else { @{} }
    if ($Entry -is [hashtable]) { $per[$Signature] = $Entry } else { $per.Remove($Signature) }
    if ($per.Count -gt 4) {
        foreach ($k in @($per.Keys | Sort-Object { [string]$per[$_].Date } | Select-Object -First ($per.Count - 4))) { $per.Remove($k) }
    }
    if ($per.Count -gt 0) { $Pacer.Calibrated[$key] = $per } else { $Pacer.Calibrated.Remove($key) }
}

# Which of a game's calibrations to show for this monitor: the one in force, else the latest of another
# setup (Get-JuicerCalibrationState then says it is not used). Null if there is none.
function Select-JuicerCalibration {
    param($PerSignature, [hashtable]$Monitor)
    if ($PerSignature -isnot [hashtable] -or $PerSignature.Count -eq 0) { return $null }
    if ($Monitor) { $e = $PerSignature[(Get-JuicerLimitSignature $Monitor)]; if ($e -is [hashtable]) { return $e } }
    @($PerSignature.Values | Where-Object { $_ -is [hashtable] } | Sort-Object { [string]$_.Date } -Descending)[0]
}

function Read-JuicerPacer {
    $p = Get-JuicerPacerPath
    $s = @{ Engine = 'Auto'; Calibrated = @{}; Games = @{}; Pending = @{}; Recipe = 0 }
    if (Test-Path -LiteralPath $p) {
        try {
            $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
            if ($d.Engine -in 'Auto', 'nvidia', 'rtss') { $s.Engine = [string]$d.Engine }
            if ($d.Calibrated -is [hashtable]) { $s.Calibrated = ConvertTo-JuicerCalibrationMap $d.Calibrated }
            if ($d.Games -is [hashtable]) { $s.Games = $d.Games }
            if ($d.Pending -is [hashtable]) { $s.Pending = $d.Pending }
            if ($d.Recipe) { $s.Recipe = [int]$d.Recipe }
        } catch {
            Write-JuicerLog "frame-pacer.json dañado, se aparta como .dañado y se empieza de cero: $_"
            # Keep the bad file: the next save would overwrite it with defaults and lose any chance to recover it.
            try { Move-Item -LiteralPath $p -Destination "$p.dañado" -Force -ErrorAction Stop } catch { Write-JuicerLog "No se pudo apartar frame-pacer.json: $_" }
        }
    }
    $s
}

function Save-JuicerPacer {
    param([hashtable]$State)
    Write-JuicerTextAtomic (Get-JuicerPacerPath) (ConvertTo-JuicerJson $State)
}

function Get-JuicerPacerEngine { [string](Read-JuicerPacer).Engine }

# What a game's frame pacer puts first. Fluidez: the steadiest pace that
# stays inside what the monitor shows whole (under the refresh with VRR,
# exactly the refresh with strobing). Latencia: the same until it is
# calibrated; then, if the game has room, a multiple of the refresh (two
# times or more, up to 1000 FPS) with VSync forced off: every frame more
# reaches the screen sooner, at the price of tearing. For competitive games.
function Get-JuicerPacerPriority {
    param([string]$Exe)
    $g = (Read-JuicerPacer).Games[(ConvertTo-JuicerExeName $Exe)]
    if ($g -and [string]$g.Priority -eq 'Latencia') { 'Latencia' } else { 'Fluidez' }
}

# Saves it and, if the game already has the frame pacer, sets it again.
function Set-JuicerPacerPriority {
    param([Parameter(Mandatory)][string]$Exe, [ValidateSet('Fluidez', 'Latencia')][string]$Priority, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName $Exe
    $state = Read-JuicerPacer
    Set-JuicerPacerGameField $state $exe 'Priority' $(if ($Priority -eq 'Latencia') { 'Latencia' } else { $null })
    # A calibration made for the other priority does not hold for this one.
    $state.Calibrated.Remove($exe)
    Save-JuicerPacer $state
    if (@(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe }).Count -gt 0) {
        # Without a screen to read, it is saved and applies at the next recalculation.
        try { Add-JuicerFpsLimit $exe 0 $Monitor } catch { Write-JuicerLog "Prioridad de $exe guardada; el ritmo se recalculará cuando se pueda leer la pantalla: $_" }
    }
}

# One field of a game's entry; null removes it, and an empty entry goes.
function Set-JuicerPacerGameField {
    param([hashtable]$State, [string]$Exe, [string]$Name, $Value)
    $g = $State.Games[$Exe]
    if ($g -isnot [hashtable]) { $g = @{} }
    if ($null -eq $Value) { $g.Remove($Name) } else { $g[$Name] = $Value }
    if ($g.Count -gt 0) { $State.Games[$Exe] = $g } else { $State.Games.Remove($Exe) }
}

# A rate chosen by hand for a game, kept when the rates are recalculated
# (a new monitor mode, the sign-in upkeep). 0 goes back to the automatic one.
function Set-JuicerPacerFps {
    param([Parameter(Mandatory)][string]$Exe, [int]$Fps, [hashtable]$Monitor, [string]$Use)
    $exe = ConvertTo-JuicerExeName $Exe
    $state = Read-JuicerPacer
    Set-JuicerPacerGameField $state $exe 'Fps' $(if ($Fps -gt 0) { $Fps } else { $null })
    Save-JuicerPacer $state
    Add-JuicerFpsLimit $exe $Fps $Monitor $Use
}

function Get-JuicerPacerFps {
    param([string]$Exe)
    $g = (Read-JuicerPacer).Games[(ConvertTo-JuicerExeName $Exe)]
    if ($g -is [hashtable] -and [int]$g.Fps -gt 0) { [int]$g.Fps } else { 0 }
}

# Which engines this PC has: nvidia, rtss, both or none.
function Get-JuicerPacerEngines { @(& (Get-JuicerBackend).FpsEngines) }

# Moving every limited game to the other engine: each one is undone (which
# puts back what the old engine had) and set again with the new one, so no
# game is left with two limiters.
function Set-JuicerPacerEngine {
    param([ValidateSet('Auto', 'nvidia', 'rtss')][string]$Engine, [hashtable]$Monitor)
    if ($Engine -ne 'Auto' -and (Get-JuicerPacerEngines) -notcontains $Engine) {
        throw $(if ($Engine -eq 'rtss') { 'RivaTuner Statistics Server no está instalado. Es gratis: Win Juicer lo instala (Instalar programas) o se descarga de guru3d.com.' } else { 'No hay una gráfica NVIDIA con su driver.' })
    }
    $before = Get-JuicerFpsBackend
    $state = Read-JuicerPacer
    $state.Engine = $Engine
    Save-JuicerPacer $state
    & (Get-JuicerBackend).FpsReset
    if ((Get-JuicerFpsBackend) -eq $before) { return @() }
    $games = @(Get-JuicerFpsLimits)
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    foreach ($g in $games) {
        # An open game moves when it closes.
        if (Test-JuicerGameRunning $g.Exe) { Add-JuicerPacerPending $g.Exe 'Set' -Reset; continue }
        [void](Undo-JuicerTweak $g.Id)
        Add-JuicerFpsLimit $g.Exe 0 $Monitor
    }
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
# monitor offers, to suggest one a game can hold under strobing. VrrMax is the
# top of the monitor's variable refresh range: some run a refresh rate
# the VRR does not reach (165 Hz with a 48-144 Hz range), and above that range
# VRR switches off, so the cap goes under the range's top, not under the Hz.
# Returns Fps, Why, VSync (whether to force it in the driver) and Warn.
function Get-JuicerFpsCap {
    param([int]$Hz, [string]$Use = 'Fijo', [hashtable]$Measured, [int]$VrrMin = 0, [int[]]$Rates = @(), [double]$ExactHz = 0, [int]$VrrMax = 0)
    if ($Hz -le 0) { return $null }
    $warn = $null
    # The refresh rate the variable refresh reaches, and the note when it is less than the monitor's.
    $vrrTop = $Hz
    $vrrNote = ''
    if ($Use -in 'VRR', 'EstroboSync' -and $VrrMax -gt 0 -and $VrrMax -lt $Hz) {
        $vrrTop = $VrrMax
        $vrrNote = " Ojo: tu pantalla va a $Hz Hz pero su VRR llega a $VrrMax Hz: por encima de eso la frecuencia variable se apaga, así que el ritmo se calcula con $VrrMax Hz."
    }
    $exact = 0
    $lowered = $true
    switch ($Use) {
        'VRR' {
            $fps = Get-JuicerVrrCap $vrrTop
            $vsync = $true
            $why = "Pantalla de $Hz Hz con frecuencia variable: $fps FPS ({0:N2} ms por fotograma) la mantiene siempre dentro del rango VRR, la misma cifra que usa NVIDIA Reflex. Con la sincronización vertical forzada en el driver y el límite por debajo de los Hz, VSync no llega a esperar nunca: sólo tapa un corte si un fotograma llega antes de tiempo, sin sumar latencia.$vrrNote" -f (1000 / $fps)
        }
        'EstroboSync' {
            $fps = Get-JuicerVrrCap $vrrTop
            $vsync = $true
            $why = "Pantalla de $Hz Hz con estroboscopio y frecuencia variable: el mismo objetivo que con VRR, $fps FPS ({0:N2} ms por fotograma), para no salir nunca del rango. El destello sigue a cada fotograma: cuanto más estable el frametime, más uniforme el parpadeo.$vrrNote" -f (1000 / $fps)
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
    param([Parameter(Mandatory)][string]$Exe, [Parameter(Mandatory)][int]$Fps, [string]$Why = '', [switch]$VSync, [string]$Use = 'Fijo', [double]$Exact = 0, [switch]$NoVSync, [switch]$Minimal)
    $exe = ConvertTo-JuicerExeName $Exe
    # The NVIDIA parts do nothing (and count as done) without an NVIDIA driver.
    # Exact only reaches RivaTuner; the driver keeps Fps.
    $limit = @{ Type = 'FpsLimit'; Exe = $exe; Fps = $Fps }
    if ($Exact -gt 0) { $limit.Exact = $Exact }
    $actions = @($limit)
    # Prudent mode: the cap alone, with VSync and the frame queue as the game leaves them.
    if (-not $Minimal) {
        $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x007BA09E; Value = [uint32]1; Label = 'Fotogramas pre-renderizados: 1 (modo de baja latencia activado)' }
        # Always one of the three, so that changing the mode or the priority
        # never leaves behind the VSync of the previous one (VSYNCMODE_*).
        if ($NoVSync) {
            $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x08416747; Label = 'Sincronización vertical: desactivada (el ritmo pasa de los Hz: sin la espera ni la cola de VSync)' }
        } elseif ($VSync) {
            $label = if ($Use -eq 'Estrobo') { 'Sincronización vertical: forzada (un fotograma por destello del estroboscopio)' } else { 'Sincronización vertical: forzada (con G-SYNC y el límite por debajo de los Hz)' }
            $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x47814940; Label = $label }
        } else {
            $actions += @{ Type = 'NvSetting'; Exe = $exe; Id = [uint32]0x00A879CF; Value = [uint32]0x60925292; Label = 'Sincronización vertical: la que diga el juego' }
        }
    }
    $sync = if ($Minimal) { '. Modo prudente: sólo el límite; la sincronización vertical y la cola de fotogramas, como las deje el juego.' } elseif ($NoVSync) { ' y sin sincronización vertical, que con un ritmo por encima de los Hz sólo añadiría espera.' } elseif (-not $VSync) { '.' } elseif ($Use -eq 'Estrobo') { ' y con la sincronización vertical que el estroboscopio necesita.' } else { ' y con la sincronización vertical que G-SYNC necesita.' }
    @{
        Id = "fps:$exe"; Category = 'Juegos'; Level = 1; Impact = 'Medio'; Reboot = 'No'
        Title = 'Frame pacer a {0} FPS ({1:N2} ms): {2}' -f $Fps, (1000 / [Math]::Max(1, $Fps)), $exe
        What = "Marca a $exe un ritmo de $Fps FPS cada vez que se abra: con el driver de NVIDIA, sin inyectar nada en el juego; con RivaTuner, a través de su enganche, el mismo de su contador de FPS. Nunca con el juego abierto$(if (-not $Minimal) { '. Con NVIDIA, además, sin cola de fotogramas' })$sync"
        Gain = $(if ($Why) { $Why } else { 'Frametimes constantes y menos latencia que dejar que la gráfica vaya al máximo.' })
        Cost = 'Si el juego podría ir más rápido, ese margen no se usa (se nota menos que los tirones que quita). Si el juego tiene NVIDIA Reflex, actívalo en sus opciones: el límite se aplica entonces a través de Reflex.'
        Skip = { if (-not (Get-JuicerFpsBackend)) { 'El frame pacer necesita una gráfica NVIDIA o RivaTuner Statistics Server, que es gratis y Win Juicer instala.' } }
        Actions = $actions
    }
}

# The cap Win Juicer would set for this game on this screen, used the way
# its owner uses it. A warning, if any, goes at the end of Why. A rate chosen
# by hand wins, unless Automatic asks for what Win Juicer would choose.
function Get-JuicerRecommendedFps {
    param([string]$Exe, [hashtable]$Monitor, [switch]$Automatic)
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { return $null }
    $hz = [int]$Monitor.Display.Hz
    $vrr = $Monitor.Vrr
    $exe = ConvertTo-JuicerExeName $Exe
    $use = Resolve-JuicerMonitorUse $Monitor
    $vrrMin = if ($vrr) { [int]$vrr.Min } else { 0 }
    $vrrMax = Get-JuicerVrrTop $Monitor
    $sig = Get-JuicerLimitSignature $Monitor
    # A measurement from another screen or refresh rate, over 60 days old or with the card throttled
    # says nothing about this one.
    $measured = Get-JuicerUsableFrameResult $exe $sig $hz
    $cap = Get-JuicerFpsCap $hz $use $measured $vrrMin @($Monitor.Display.RefreshRates | Where-Object { $_ }) ([double]$Monitor.Display.ExactHz) $vrrMax
    # A calibration on this same screen, used the same way, knows better
    # than one measurement: it was taken under the cap.
    $cal = Get-JuicerCalibrationEntry (Read-JuicerPacer) $exe $sig
    $latency = (Get-JuicerPacerPriority $exe) -eq 'Latencia'
    if ($cap) { $cap.Priority = $(if ($latency) { 'Latencia' } else { 'Fluidez' }) }
    if ($cap -and $cal -and ($use -ne 'Estrobo' -or $latency) -and [int]$cal.Fps -gt 0) {
        # At a fixed refresh, calibrating may go up to four times the refresh;
        # putting latency first, up to the driver's 1000.
        $max = if ($latency) { 1000 } elseif ($use -eq 'Fijo') { 4 * $hz } else { (Get-JuicerFpsCap $hz $use $null $vrrMin @() 0 $vrrMax).Fps }
        $cap.Fps = [Math]::Min($max, [int]$cal.Fps)
        $cap.Why = [string]$cal.Why
        $cap.Calibrated = $true
        # The fraction under the refresh is only for a pace at the refresh.
        if ($cap.Fps -ne $hz) { $cap.Exact = 0 }
    }
    $manual = Get-JuicerPacerFps $exe
    if ($cap -and $manual -gt 0 -and -not $Automatic) {
        $cap.Fps = $manual
        $cap.Why = 'Ritmo elegido por ti: {0} FPS ({1:N2} ms por fotograma).' -f $manual, (1000 / $manual)
        $cap.Manual = $true
        $cap.Warn = $null
        if ($manual -ne $hz) { $cap.Exact = 0 }
    }
    if ($cap -and $cap.Warn) { $cap.Why = "$($cap.Why) $($cap.Warn)" }
    $cap
}

# Use overrides how the monitor is used, for when it cannot be read. A game
# that is open gets it when it closes: the result says so (Pendiente).
function Add-JuicerFpsLimit {
    param([Parameter(Mandatory)][string]$Exe, [int]$Fps, [hashtable]$Monitor, [string]$Use)
    $exeName = ConvertTo-JuicerExeName $Exe
    if (Test-JuicerGameRunning $exeName) { return (Add-JuicerPacerPending $exeName 'Set' $Fps $Use) }
    Clear-JuicerPacerPending $exeName
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $use = if ($Use -and $Use -ne 'Automatico') { $Use } else { Resolve-JuicerMonitorUse $Monitor }
    $why = ''
    $exact = 0
    $asked = 0
    if ($Fps -le 0) {
        $cap = Get-JuicerRecommendedFps $Exe $Monitor
        if ($cap) {
            $Fps = $cap.Fps; $why = $cap.Why; $exact = [double]$cap.Exact
        } else {
            # A rate chosen by hand needs no screen to be read.
            $Fps = Get-JuicerPacerFps $exeName
            if ($Fps -le 0) { throw 'No se pudo leer la pantalla para calcular el ritmo: indícalo a mano.' }
            $why = 'Ritmo elegido por ti: {0} FPS ({1:N2} ms por fotograma).' -f $Fps, (1000 / $Fps)
        }
    }
    $asked = $Fps
    $b = Get-JuicerBackend
    # NVIDIA caps a few games in their own profile because they break above
    # it (physics, timers): the frame pacer never goes higher than that.
    $frl = & $b.NvRead $exeName ([uint32]0x10835002)
    if ($frl -and $null -ne $frl.Predefined -and [int]$frl.Predefined -gt 0 -and [int]$frl.Predefined -lt $Fps) {
        $Fps = [int]$frl.Predefined
        $exact = 0
        $why = ("NVIDIA limita este juego a $Fps FPS en su propio perfil porque por encima no funciona bien: el frame pacer no pasa de ahí. " + $why).Trim()
    }
    # Above the refresh, forcing VSync would hold every frame for the next
    # refresh: what the pace saved, the wait gives back, with a queue.
    $hz = if ($Monitor -and $Monitor.Display) { [int]$Monitor.Display.Hz } else { 0 }
    $over = $hz -gt 0 -and $Fps -gt $hz
    $t = New-JuicerFpsLimitTweak $Exe $Fps $why -VSync:(-not $over -and $use -in 'VRR', 'EstroboSync', 'Estrobo') -NoVSync:$over -Use $use -Exact $(if ($over) { 0 } else { $exact }) -Minimal:(Test-JuicerPacerMinimal $exeName)
    # What NVIDIA set in this game's own profile stays: it is there so that
    # the game runs right, and overriding it is how a game breaks.
    $t.Actions = @($t.Actions | Where-Object {
            if ($_.Type -ne 'NvSetting') { return $true }
            $info = & $b.NvRead $_.Exe $_.Id
            -not ($info -and $null -ne $info.Predefined)
        })
    # What an earlier recipe set and this one no longer does goes back first.
    [void](Remove-JuicerStaleCaptures $t)
    $r = Invoke-JuicerTweak $t
    # What was asked is not what was set: say so instead of leaving it to the title.
    if ($Fps -lt $asked -and $r.Outcome -in 'Aplicado', 'YaEstaba') {
        $r.Message = "NVIDIA limita $exeName a $Fps FPS en su propio perfil (por encima no funciona bien): pediste $asked FPS y el frame pacer no pasa de $Fps."
    }
    # The rate is applied as asked, but Reflex in the game may cap it lower: say so.
    if ($r.Outcome -in 'Aplicado', 'YaEstaba') {
        $reflex = Get-JuicerReflexCapNote $exeName $Fps $hz $use (Get-JuicerMainGpuVendor) (Get-JuicerGameTech $exeName)
        if ($reflex) { $r.Message = ("$($r.Message) $reflex").Trim() }
        # Forced VSync a hair under the refresh can make frames wait.
        $edge = Get-JuicerVsyncEdgeNote $Fps $hz $use (-not $over -and -not (Test-JuicerPacerMinimal $exeName))
        if ($edge) { $r.Message = ("$($r.Message) $edge").Trim() }
    }
    $r
}

# A cap less than 3 FPS under the refresh, with VSync forced by the driver
# under variable refresh: a frame that arrives a hair early waits for the
# next refresh, and the wait is latency. Only where VSync is forced (Forced);
# the safe side is the Reflex rate, or 3 under the refresh if that is lower.
# Null when it does not apply.
function Get-JuicerVsyncEdgeNote {
    param([int]$Fps, [int]$Hz, [string]$Use, [bool]$Forced = $true)
    if (-not $Forced -or $Hz -le 0 -or $Use -notin 'VRR', 'EstroboSync' -or $Fps -le $Hz - 3 -or $Fps -gt $Hz) { return $null }
    $safe = [Math]::Min((Get-JuicerVrrCap $Hz), $Hz - 3)
    "A menos de 3 FPS de tus $Hz Hz, la V-Sync forzada puede hacer esperar fotogramas: mejor ≤ $safe."
}

# Takes a game's frame pacer away; if the game is open, when it closes.
function Remove-JuicerFpsLimit {
    param([Parameter(Mandatory)][string]$Exe)
    $exe = ConvertTo-JuicerExeName $Exe
    $has = $null -ne (Get-JuicerJournalEntry (Read-JuicerJournal) "fps:$exe")
    if ($has -and (Test-JuicerGameRunning $exe)) { return (Add-JuicerPacerPending $exe 'Remove') }
    Clear-JuicerPacerPending $exe
    if ($has) { Undo-JuicerTweak "fps:$exe" }
}

# Prudent mode for one game: the cap alone, with VSync and the frame queue
# as the game leaves them. For a game that misbehaved with the whole recipe,
# and what a game gets after Win Juicer took its changes away.
function Test-JuicerPacerMinimal {
    param([string]$Exe)
    $g = (Read-JuicerPacer).Games[(ConvertTo-JuicerExeName $Exe)]
    [bool]($g -is [hashtable] -and $g.Minimal)
}

function Set-JuicerPacerMinimal {
    param([Parameter(Mandatory)][string]$Exe, [bool]$On, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName $Exe
    $state = Read-JuicerPacer
    Set-JuicerPacerGameField $state $exe 'Minimal' $(if ($On) { $true } else { $null })
    Save-JuicerPacer $state
    if (@(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe }).Count -gt 0) { Add-JuicerFpsLimit $exe 0 $Monitor }
}

# --- While a game is open ------------------------------------------------------
# Its frame pacer waits for it to close. Pending, exe -> @{ Op = Set | Remove;
# Fps (0: the recommended one); Use; Reset (undo first: a change of engine);
# Since }. The window applies it as soon as the game closes; failing that,
# the next time Win Juicer opens or the sign-in upkeep runs.

function Add-JuicerPacerPending {
    param([Parameter(Mandatory)][string]$Exe, [ValidateSet('Set', 'Remove')][string]$Op, [int]$Fps = 0, [string]$Use = '', [switch]$Reset)
    $exe = ConvertTo-JuicerExeName $Exe
    $state = Read-JuicerPacer
    $old = $state.Pending[$exe]
    $state.Pending[$exe] = @{ Op = $Op; Fps = $Fps; Use = $Use; Reset = ([bool]$Reset -or ($old -is [hashtable] -and [bool]$old.Reset)); Since = (Get-Date).ToString('s') }
    Save-JuicerPacer $state
    Write-JuicerLog "Frame pacer de $exe en espera ($Op): el juego está abierto."
    $what = if ($Op -eq 'Remove') { 'se quitará' } else { 'se aplicará' }
    New-JuicerResult @{ Id = "fps:$exe"; Title = "Frame pacer: $exe"; Reboot = 'No' } 'Pendiente' "$exe está abierto: el cambio $what en cuanto lo cierres. Win Juicer no toca un juego en marcha, para que no se congele."
}

function Clear-JuicerPacerPending {
    param([string]$Exe)
    $state = Read-JuicerPacer
    if ($state.Pending.ContainsKey($Exe)) { $state.Pending.Remove($Exe); Save-JuicerPacer $state }
}

function Get-JuicerPacerPending { @((Read-JuicerPacer).Pending.Keys) }

# What waited for its game, for the games that are closed now.
function Invoke-JuicerPacerPending {
    param([hashtable]$Monitor)
    $out = @()
    foreach ($exe in @((Read-JuicerPacer).Pending.Keys)) {
        if (Test-JuicerGameRunning $exe) { continue }
        $state = Read-JuicerPacer
        $p = $state.Pending[$exe]
        # Off the list first: if the game opens again meanwhile, it goes back on.
        $state.Pending.Remove($exe)
        Save-JuicerPacer $state
        try {
            if ($p.Op -eq 'Remove' -or $p.Reset) {
                if (Get-JuicerJournalEntry (Read-JuicerJournal) "fps:$exe") { $out += Undo-JuicerTweak "fps:$exe" }
            }
            if ($p.Op -eq 'Set') { $out += Add-JuicerFpsLimit $exe ([int]$p.Fps) $Monitor ([string]$p.Use) }
        } catch {
            $out += New-JuicerResult @{ Id = "fps:$exe"; Title = "Frame pacer: $exe"; Reboot = 'No' } 'Error' "$_"
        }
    }
    $out
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
    param([System.Collections.IList]$Journal)
    $b = Get-JuicerBackend
    # Assigned first: Read-JuicerJournal hands the list over whole, and piping
    # the call itself would filter one object, the list.
    $journal = if ($null -ne $Journal) { $Journal } else { Read-JuicerJournal }
    foreach ($e in @($journal | Where-Object { ([string]$_.Id) -like 'fps:*' })) {
        $exe = ([string]$e.Id).Substring(4)
        $cur = $null
        $unreadable = $false
        # Read where it was set, even if the engine changed since.
        $by = @($e.Actions | Where-Object { $_.Type -eq 'FpsLimit' } | ForEach-Object { [string]$_.Backend }) | Select-Object -First 1
        try { $cur = & $b.FpsRead $exe $by } catch { $unreadable = $true; Write-JuicerLog "No se pudo leer el ritmo de ${exe}: $_" }
        @{ Id = [string]$e.Id; Exe = $exe; Fps = $(if ($cur) { $cur.Fps } else { $null }); Exact = $(if ($cur) { [double]$cur.Exact } else { 0 }); Backend = $(if ($cur) { $cur.Backend } else { '' }); Unreadable = $unreadable }
    }
}

# Games Win Juicer limited whose cap is gone from the driver: a clean driver
# install, a profile reset, another tool. They are in the journal, but there is
# nothing live. A cap that could not be read does not count, and neither does
# any of it without an engine to set it again (the card was taken out).
function Get-JuicerWipedFpsLimits {
    param([System.Collections.IList]$Journal)
    if (-not (Get-JuicerFpsBackend)) { return }
    foreach ($l in @(Get-JuicerFpsLimits -Journal $Journal)) {
        if (-not $l.Fps -and -not $l.Unreadable) { $l }
    }
}

# Puts those caps back (all of them, or only the Exe given): the same way as
# any other cap, so a game that is open waits for it to close (Pendiente).
# Games already waiting for that are left to it. Returns the results.
function Restore-JuicerWipedFpsLimits {
    param([hashtable]$Monitor, [string[]]$Exe = @())
    $wiped = @(Get-JuicerWipedFpsLimits)
    if ($Exe.Count -gt 0) { $wiped = @($wiped | Where-Object { $Exe -contains $_.Exe }) }
    $waiting = @((Read-JuicerPacer).Pending.Keys)
    $wiped = @($wiped | Where-Object { $waiting -notcontains $_.Exe })
    if ($wiped.Count -eq 0) { return }
    Write-JuicerLog ('Frame pacer: el driver borró el límite de {0}: se vuelve a poner.' -f (($wiped | ForEach-Object { $_.Exe }) -join ', '))
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    foreach ($w in $wiped) {
        try {
            Add-JuicerFpsLimit $w.Exe 0 $Monitor
        } catch {
            New-JuicerResult @{ Id = $w.Id; Title = "Frame pacer: $($w.Exe)"; Reboot = 'No' } 'Error' "$_"
        }
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
        default { 'ninguno todavía: con NVIDIA lo hace el driver; con AMD o Intel hace falta RivaTuner Statistics Server, que es gratis' }
    }
}

# --- How well it paces --------------------------------------------------------

# Whether frames waited in front of the graphics card: the render queue,
# which adds its length to every frame's latency. Measured directly when
# PresentMon has GPULatency; otherwise inferred from a GPU busy nearly all of
# every frame time (then there is always a frame waiting).
function Test-JuicerPacerQueue {
    param([hashtable]$Result, [double]$FrameMs)
    if ($null -ne $Result.QueueMs) { return ($Result.QueueMs -ge [Math]::Max(1.0, 0.25 * $FrameMs)) }
    ($null -ne $Result.GpuMs95 -and $Result.GpuMs95 -ge 0.95 * $FrameMs)
}

# Whether the PC had time to spare in a measurement: the busier of the
# processor and the graphics card, on 95 % of the frames, well under the frame
# time (the 15 % margin calibrating leaves), and no queue in front of the card.
# With generated frames those numbers are not the game's: no.
function Test-JuicerPacerHeadroom {
    param([hashtable]$Result, [double]$FrameMs)
    if ($FrameMs -le 0 -or $Result.Generated -ge 30 -or $null -eq $Result.WorkMs95 -or $Result.WorkMs95 -le 0) { return $false }
    if (Test-JuicerPacerQueue $Result $FrameMs) { return $false }
    $Result.WorkMs95 * 1.15 -lt $FrameMs
}

# A game asked for more than the Reflex cap (it is under it and up to the
# refresh) that sits on that cap, with even frames and a PC with room to spare:
# what holds it is Reflex or the low latency mode Ultra with G-SYNC, which put
# that very cap on it, not the PC. Returns the cap, or 0 when it does not apply.
# Only with NVIDIA (or a card not known): they are NVIDIA's.
function Test-JuicerReflexCapMatch {
    param([hashtable]$Result, [int]$Cap, [int]$Hz, [string]$Use, [string]$GpuVendor = '')
    if ($Hz -le 0 -or $Use -notin 'VRR', 'EstroboSync' -or $GpuVendor -notin '', 'NVIDIA') { return 0 }
    $refl = Get-JuicerVrrCap $Hz
    if ($Cap -le $refl -or $Cap -gt $Hz -or [Math]::Abs($Result.AvgFps - $refl) -gt 1.5) { return 0 }
    if ($Result.P95Ms -gt (1000 / $refl) * 1.03) { return 0 }
    if (-not (Test-JuicerPacerHeadroom $Result (1000 / [Math]::Max(1, $Result.AvgFps)))) { return 0 }
    $refl
}

# Even frames well under the cap and a PC with room to spare: neither the PC
# nor the pace is what holds the game; something else puts that ceiling.
function Test-JuicerExternalLimit {
    param([hashtable]$Result, [double]$Target)
    if ($Target -le 0 -or $Result.AvgFps -ge $Target * 0.97 -or $Result.Steady -lt 85) { return $false }
    if ($Result.P95Ms -gt (1000 / [Math]::Max(1, $Result.AvgFps)) * 1.1) { return $false }
    Test-JuicerPacerHeadroom $Result (1000 / [Math]::Max(1, $Result.AvgFps))
}

# A measurement of a game under its frame pacer, against its target. Cap is
# the FPS set; Exact, the fractional one RivaTuner uses, if any. Hz, Use and
# GpuVendor let it tell what is holding the game under its cap when it is
# not the PC (Reflex, Radeon Chill, the game's own limiter).
function Get-JuicerPacerFindings {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][int]$Cap, [double]$Exact = 0, [string]$Backend = '', [int]$Hz = 0, [string]$Use = '', [string]$GpuVendor = '')
    $area = "Frame pacer: $($Result.Application)"
    $target = if ($Exact -gt 0) { $Exact } else { $Cap }
    $ms = 1000 / $target
    if ($Result.AvgFps -gt $target * 1.04) {
        return (New-JuicerFinding $area 'Medio' ('No está actuando: {0:N0} FPS con un ritmo de {1} FPS' -f $Result.AvgFps, $target) 'El juego va por encima del objetivo. Con RivaTuner, tiene que estar abierto (en la bandeja); si el juego se lanza con otro .exe que el que tiene el ritmo, cámbialo en «Tus juegos» > «Cambiar .exe…». Si el juego tiene un limitador propio más alto, no importa: el más bajo manda.')
    }
    $detail = '{0} % de los fotogramas a {1:N2} ms ±{2:N1}; de un fotograma al siguiente cambian {3:N2} ms de media.' -f $Result.Steady, $ms, [Math]::Max(0.3, 0.04 * $ms), $Result.JitterMs
    if ($null -ne $Result.AnimErrorMs) { $detail += ' Error de animación: {0:N2} ms de media (lo que el movimiento se desvía del tiempo real; cuanto más cerca de 0, más fluido).' -f $Result.AnimErrorMs }
    $holds = $Result.P95Ms -le $ms * 1.03
    $reflexCap = Test-JuicerReflexCapMatch $Result $Cap $Hz $Use $GpuVendor
    if ($reflexCap -gt 0) {
        # It is what the measurement shows, so it is said as that: the same figure, not a diagnosis of the settings.
        $out = @(New-JuicerFinding $area 'Info' ('Se queda en {0:N0} FPS con el ritmo en {1}: es el tope de Reflex o del modo de baja latencia Ultra' -f $Result.AvgFps, $target) ("La medida coincide con $reflexCap FPS, que es lo que NVIDIA Reflex y el modo de baja latencia «Ultra» ponen por su cuenta con G-SYNC y V-Sync en una pantalla de $Hz Hz (Hz − Hz²/3600). Tu procesador y tu gráfica tienen margen (su trabajo llega a {0:N2} ms de los {1:N2} ms de cada fotograma), así que no es tu PC. Pon el ritmo de este juego en $reflexCap FPS en Win Juicer y queda igual, sin un tope escondido; para pasar de ahí tendrías que apagar Reflex (o Ultra) en el juego o en el panel de NVIDIA, y se pierde latencia. $detail" -f $Result.WorkMs95, (1000 / $Result.AvgFps)))
    } elseif ($Hz -gt 0 -and (Test-JuicerExternalLimit $Result $target)) {
        $who = switch ($GpuVendor) {
            'AMD' { 'el límite de FPS del propio juego, Radeon Chill o Frame Rate Target Control (FRTC) en AMD Software (global o de este juego), un límite de RivaTuner, o la V-Sync contra otra pantalla de menos Hz' }
            'NVIDIA' { 'el límite de FPS del propio juego, un límite global o de este juego en el panel de NVIDIA o en RivaTuner, el modo de baja latencia Ultra o Reflex (que ponen su propio tope), o la V-Sync contra otra pantalla de menos Hz' }
            default { 'el límite de FPS del propio juego, Radeon Chill o FRTC (AMD), un límite del panel de la gráfica o de RivaTuner, o la V-Sync contra otra pantalla de menos Hz' }
        }
        $out = @(New-JuicerFinding $area 'Medio' ('Algo externo limita el juego a {0:N0} FPS, con el ritmo en {1}' -f $Result.AvgFps, $target) ("Es lo que muestra la medida: los fotogramas llegan parejos a {0:N0} FPS y tu procesador y tu gráfica tienen margen (su trabajo llega a {1:N2} ms de los {2:N2} ms de cada fotograma), así que ni es tu PC ni es el ritmo de Win Juicer. Win Juicer no puede saber qué lo pone; los sospechosos habituales: $who. Revisa esos y mide otra vez. $detail" -f $Result.AvgFps, $Result.WorkMs95, (1000 / $Result.AvgFps)))
    } elseif ($holds -and $Result.Steady -ge 90) {
        $out = @(New-JuicerFinding $area 'Ok' ('Ritmo clavado a {0} FPS' -f $target) $detail)
    } elseif (-not $holds) {
        $out = @(New-JuicerFinding $area 'Medio' ('No sostiene {0} FPS: el 5 % más lento va a {1:N0}' -f $target, $Result.Fps95) "$detail Cada vez que no llega, el frametime salta. «Calibrar» baja el ritmo a lo que sí sostiene, que se nota más fluido que un objetivo alto con altibajos.")
    } else {
        $out = @(New-JuicerFinding $area 'Bajo' ('Llega a {0} FPS, pero con el ritmo irregular' -f $target) "$detail Suele ser el propio juego (carga de zonas, shaders) o algo en segundo plano; repite la medida en otra escena antes de cambiar nada.")
    }
    # Latency: a cap only lowers it if the graphics card is left some room.
    $lat = @()
    if ($null -ne $Result.InputLatency) { $lat += 'De ratón o teclado a pantalla: {0:N1} ms (mediana).' -f $Result.InputLatency }
    if ($null -ne $Result.Latency) { $lat += 'Del inicio del fotograma a pantalla: {0:N1} ms de media{1}.' -f $Result.Latency, $(if ($null -ne $Result.LatencyP95) { ', {0:N1} ms en el 5 % peor' -f $Result.LatencyP95 } else { '' }) }
    if ($Result.Generated -lt 30 -and (Test-JuicerPacerQueue $Result $ms)) {
        $wait = if ($null -ne $Result.QueueMs) { '; cada fotograma espera {0:N1} ms en cola antes de que la gráfica empiece con él' -f $Result.QueueMs } else { '' }
        $out += New-JuicerFinding $area 'Medio' 'La gráfica va al límite incluso con el ritmo: hay cola de fotogramas' (('Su trabajo llega a {0:N2} ms de los {1:N2} ms de cada fotograma{2}. Esa cola es latencia pura. «Calibrar» baja el ritmo hasta dejarle un 12 % de margen y la cola desaparece. Si el juego tiene NVIDIA Reflex o AMD Anti-Lag 2, actívalo: vacía la cola sin bajar el ritmo; si no, con NVIDIA, «Modo de baja latencia: Ultra» para este juego en el panel. ' -f $Result.GpuMs95, $ms, $wait) + ($lat -join ' '))
    } elseif ($lat.Count -gt 0) {
        $out += New-JuicerFinding $area 'Ok' 'Sin cola delante de la gráfica: la latencia es la mínima para este ritmo' ($lat -join ' ')
    }
    if ($Result.Generated -ge 30) {
        $fg = 'Con generación de fotogramas (el {0} % son generados), el ritmo cuenta también los generados: el juego calcula la mitad, y el ratón responde a ese ritmo. Calibrar sólo baja el ritmo si no se cumple; la cola y el margen no se pueden leer bien con fotogramas generados.' -f $Result.Generated
        if ($Backend -eq 'rtss') { $out += New-JuicerFinding $area 'Medio' 'Generación de fotogramas con RivaTuner como motor' "$fg RivaTuner limita los fotogramas que el juego presenta y se pelea con la generación (tirones): para este juego, mejor el driver de NVIDIA como motor, o el limitador del propio juego." }
        else { $out += New-JuicerFinding $area 'Info' 'Generación de fotogramas activa' $fg }
    }
    if ($Result.Generated -lt 30 -and $null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.WorkMs95 * 1.15 -lt 1000 / ($target + 3)) {
        $out += New-JuicerFinding $area 'Info' ('Hay margen: el trabajo de cada fotograma da para unos {0:N0} FPS' -f (1000 / ($Result.WorkMs95 * 1.15))) 'Si el ritmo está por debajo de lo que el monitor permite, «Calibrar» lo sube. Si ya está en su máximo, ese margen es lo que mantiene la latencia baja: la gráfica nunca llega al 100 %.'
    }
    $out
}

# A multiple of the refresh, two times or more, if the game holds it with
# room: at a fixed refresh without VSync (measured), or putting latency
# first (VSync is then forced off). Null when it does not apply. BestUnpaced,
# the best average FPS this game reached with no limiter (0 if unknown), caps
# the multiple at a tenth over it: a scene that looks light but whose game never
# once ran at that rate is a menu, or a limit the PC does not show.
function Get-JuicerPacerMultiple {
    param([hashtable]$Result, [int]$Cap, [int]$Hz, [string]$Use, [bool]$Latency, [bool]$Unreadable, [double]$BestUnpaced = 0)
    if ($Unreadable -or $Hz -le 0 -or $null -eq $Result.WorkMs95 -or $Result.WorkMs95 -le 0 -or $Result.Steady -lt 85) { return $null }
    if (-not ($Latency -or ($Use -eq 'Fijo' -and $Result.VSync -lt 50))) { return $null }
    $kMax = if ($Latency) { [int][Math]::Floor(1000 / $Hz) } else { 4 }
    $k = [Math]::Min($kMax, [int][Math]::Floor(1000 / ($Result.WorkMs95 * 1.15) / $Hz))
    if ($BestUnpaced -gt 0) { $k = [Math]::Min($k, [int][Math]::Floor(1.1 * $BestUnpaced / $Hz)) }
    if ($k -lt 2 -or $k * $Hz -le $Cap) { return $null }
    $tail = if ($Latency) { ' Prioridad latencia: la sincronización vertical va desactivada; desactívala también en el juego.' } else { '' }
    @{ Fps = $k * $Hz; Action = 'Subir'; Why = ('Calibrado por latencia: por encima de los Hz y sin sincronización vertical, cada fotograma de más llega antes a la pantalla. Sostiene {0} FPS con margen ({1} veces tus {2} Hz, para que los cortes de imagen se queden quietos en vez de recorrer la pantalla): {3:N2} ms por fotograma.{4}' -f ($k * $Hz), $k, $Hz, (1000 / ($k * $Hz)), $tail) }
}

# What a measurement under the cap says the cap should be. Max is the
# highest the monitor allows (Get-JuicerFpsCap without a measurement).
# Action: Bajar, Subir, Mantener, NoActua or Estrobo (which never lowers:
# the advice is a lower refresh rate). Returns @{ Fps; Action; Why }.
#
# Down when the game misses the cap, and also when it holds it with the
# graphics card flat out: then frames queue in front of it, and the queue is
# latency. The new cap leaves the card 12 % of every frame. Up when there is
# room to spare. At a fixed refresh without VSync, latency falls with every
# frame more, so up to a multiple of the refresh (two to four times: the
# tear lines stay put) when the game holds it with room.
function Get-JuicerPacerCalibration {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][int]$Cap, [int]$Max = 0, [string]$Use = 'Fijo', [int]$VrrMin = 0, [int[]]$Rates = @(), [int]$Hz = 0, [string]$Priority = 'Fluidez', [string]$GpuVendor = '', [double]$BestUnpaced = 0)
    if ($Max -le 0) { $Max = $Cap }
    $ms = 1000 / $Cap
    if ($Result.AvgFps -gt $Cap * 1.04) {
        return @{ Fps = $Cap; Action = 'NoActua'; Why = ('El juego iba a {0:N0} FPS, por encima del ritmo: el frame pacer no estaba actuando, así que esta medida no sirve para calibrar.' -f $Result.AvgFps) }
    }
    # A cap above the Reflex one that measures just at the Reflex one, with the
    # PC at ease, is not the PC missing frames: Reflex (or the low latency mode
    # Ultra) holds it there. Lowering the pace to what it «held» would only
    # throw away the rate the person chose, so it stays.
    $reflexCap = Test-JuicerReflexCapMatch $Result $Cap $Hz $Use $GpuVendor
    if ($reflexCap -gt 0) {
        return @{ Fps = $Cap; Action = 'Reflex'; Suggest = $reflexCap; Why = ('Mide {0:N0} FPS con el ritmo en {1}, y tu PC va sobrado: lo limita Reflex o el modo de baja latencia Ultra con G-SYNC (tope {2}), no tu PC. Por eso no se baja el ritmo. Si quieres que coincida, ponlo en {2} FPS; para pasar de ahí tendrías que apagar Reflex (o Ultra), y se pierde latencia.' -f $Result.AvgFps, $Cap, $reflexCap) }
    }
    $misses = $Result.P95Ms -gt $ms * 1.03
    # With generated frames, busy times and the queue are not the game's.
    $generated = $Result.Generated -ge 30
    $queued = -not $generated -and (Test-JuicerPacerQueue $Result $ms)
    $latency = $Priority -eq 'Latencia'
    if ($Use -eq 'Estrobo') {
        if (-not $misses -and $latency) { $m = Get-JuicerPacerMultiple $Result $Cap $Hz $Use $latency ($generated -or $queued) $BestUnpaced; if ($m) { return $m } }
        if (-not $misses -and $queued) { return @{ Fps = $Cap; Action = 'Estrobo'; Why = "Sostiene $Cap FPS, pero con la gráfica al límite y fotogramas en cola, que es latencia. Con estrobo el ritmo no baja de los Hz: baja algo la calidad gráfica para dejarle margen, o activa Reflex o Anti-Lag 2 si el juego lo tiene." } }
        if (-not $misses) { return @{ Fps = $Cap; Action = 'Mantener'; Why = "Sostiene $Cap FPS: un fotograma nuevo en cada destello del estroboscopio." } }
        $c = Get-JuicerFpsCap $Cap 'Estrobo' @{ Low1 = $Result.Fps95; AvgFps = $Result.AvgFps } 0 $Rates
        return @{ Fps = $Cap; Action = 'Estrobo'; Why = $(if ($c.Warn) { $c.Warn } else { "No sostiene $Cap FPS, y con estrobo el ritmo no baja de los Hz." }) }
    }
    $floor = [Math]::Max(30, $(if ($Use -in 'VRR', 'EstroboSync' -and $VrrMin -gt 0) { $VrrMin + 3 } else { 0 }))
    if ($misses) {
        # Fps95 is what the game just managed on 95 % of its frames: a cap right at it would miss
        # again half the time, so 3 % under it, and never under the floor.
        $new = [int][Math]::Floor($Result.Fps95 * 0.97)
        if ($new -lt $floor) { $new = $floor }
        if ($new -lt $Cap) {
            return @{ Fps = $new; Action = 'Bajar'; Why = ('Calibrado: con {0} FPS el 5 % de los fotogramas llegaba tarde; a {1} FPS ({2:N2} ms), un 3 % por debajo de lo que alcanzaba, debería sostenerlos, y un ritmo que se cumple siempre se nota más fluido que uno más alto que se rompe.' -f $Cap, $new, (1000 / $new)) }
        }
        return @{ Fps = $Cap; Action = 'Mantener'; Why = "No sostiene $Cap FPS, pero bajar más saldría del rango de frecuencia variable: mejor bajar la calidad gráfica." }
    }
    if ($queued -and $null -ne $Result.GpuMs95 -and $Result.GpuMs95 -gt 0) {
        $new = [Math]::Max($floor, [int][Math]::Floor(1000 * 0.88 / $Result.GpuMs95))
        if ($new -lt $Cap) {
            $wait = if ($null -ne $Result.QueueMs) { ' y cada fotograma esperaba {0:N1} ms en cola' -f $Result.QueueMs } else { '' }
            return @{ Fps = $new; Action = 'Bajar'; Why = ('Calibrado por latencia: a {0} FPS la gráfica trabajaba {1:N2} ms de cada {2:N2}{3}. A {4} FPS le queda un 12 % de margen, la cola desaparece y cada fotograma llega antes a la pantalla, aunque haya menos.' -f $Cap, $Result.GpuMs95, $ms, $wait, $new) }
        }
    }
    $m = Get-JuicerPacerMultiple $Result $Cap $Hz $Use $latency ($generated -or $queued) $BestUnpaced
    if ($m) { return $m }
    if ($generated) { return @{ Fps = $Cap; Action = 'Mantener'; Why = "Sostiene $Cap FPS. Con generación de fotogramas no se sube el ritmo: el margen de cada fotograma no se puede leer bien." } }
    if ($Cap -lt $Max -and -not $queued -and $null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.Steady -ge 85) {
        $can = [int][Math]::Floor(1000 / ($Result.WorkMs95 * 1.15))
        $new = [Math]::Min($Max, $can)
        if ($new -ge $Cap + 3) {
            return @{ Fps = $new; Action = 'Subir'; Why = ('Calibrado: a {0} FPS sobraba tiempo en cada fotograma; a {1} FPS ({2:N2} ms) aún queda un 15 % de margen para los picos.' -f $Cap, $new, (1000 / $new)) }
        }
    }
    @{ Fps = $Cap; Action = 'Mantener'; Why = "Sostiene $Cap FPS con el ritmo estable: está en su sitio." }
}

# --- Is the measurement fit to calibrate with? -----------------------------------

# Why a measurement of a game under its cap should not be used to calibrate
# (or ''): the scene was a menu or a loading screen (the PC hardly worked: under a
# quarter of the frame time and under 2 ms), or the average fell under 55 % of
# the game's last measurement with the same or a lower cap (another scene, a
# menu, a load). Previous is that last measurement, only if it is comparable
# (same screen, recent, not throttled): a run above the cap says nothing about
# what a capped one should reach.
function Get-JuicerCalibrationSceneProblem {
    param([hashtable]$Result, [int]$Cap, $Previous)
    $ft = if ($Result.MedianMs -gt 0) { [double]$Result.MedianMs } elseif ($Cap -gt 0) { 1000.0 / $Cap } else { 0.0 }
    if ($Result.Generated -lt 30 -and $ft -gt 0 -and $null -ne $Result.WorkMs95 -and $Result.WorkMs95 -gt 0 -and $Result.WorkMs95 -lt 0.25 * $ft -and $Result.WorkMs95 -lt 2) {
        return ('Parece un menú o una pantalla de carga: repite en partida. El trabajo de cada fotograma llegó a {0:N2} ms de los {1:N2} ms que dura, tan poco que el PC apenas hacía nada.' -f $Result.WorkMs95, $ft)
    }
    if ($Previous -is [hashtable] -and [double]$Previous.AvgFps -gt 0 -and [double]$Previous.AvgFps -le 1.04 * $Cap -and -not $Previous.Throttled -and $Result.AvgFps -lt 0.55 * [double]$Previous.AvgFps) {
        return ('La media ({0:N0} FPS) es menos de la mitad de la medida anterior de este juego ({1:N0} FPS): parece un menú o una pantalla de carga, o no es la misma escena. Repite en partida, en la escena más exigente de siempre.' -f $Result.AvgFps, $Previous.AvgFps)
    }
    ''
}

# What in the PC while it was measured could make the game look slower than it is
# (or ''): the graphics card throttled or hot (85 °C), or another process using
# 12 % of the processor or more (Defender's MsMpEng scanning, a browser). Lowering
# the pace for that is lowering it for nothing.
function Get-JuicerMeasureNoise {
    param([hashtable]$Result, [double]$HogPct = 12)
    if ($Result.Throttled) { return ('la gráfica se frenó{0}' -f $(if ($Result.ThrottleReason) { " ($($Result.ThrottleReason))" } else { '' })) }
    if ($null -ne $Result.MaxTemp -and $Result.MaxTemp -ge 85) { return ('la gráfica llegó a {0:N0} °C' -f $Result.MaxTemp) }
    $hog = @($Result.Hogs | Where-Object { $_ -and $_.Pct -ge $HogPct }) | Select-Object -First 1
    if ($hog) { return ('{0} usaba el {1:N0} % del procesador en segundo plano' -f $hog.Name, $hog.Pct) }
    ''
}

# What calibrating decides from a measurement, with the guards on top of
# Get-JuicerPacerCalibration: a menu or loading screen is not a scene to calibrate
# on, and neither is a measurement taken while the PC was throttled or busy with
# something else (those cannot lower the pace). Action Repetir means: no change,
# measure again; Why says why. Everything else is Get-JuicerPacerCalibration's.
function Get-JuicerCalibrationPlan {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][int]$Cap, [int]$Max = 0, [string]$Use = 'Fijo', [int]$VrrMin = 0, [int[]]$Rates = @(), [int]$Hz = 0, [string]$Priority = 'Fluidez', [string]$GpuVendor = '', $Previous, [double]$BestUnpaced = 0)
    $c = Get-JuicerPacerCalibration $Result $Cap $Max $Use $VrrMin $Rates $Hz $Priority $GpuVendor $BestUnpaced
    if ($c.Action -eq 'NoActua') { return $c }
    $scene = Get-JuicerCalibrationSceneProblem $Result $Cap $Previous
    if ($scene) { return @{ Fps = $Cap; Action = 'Repetir'; Kind = 'Escena'; Why = $scene } }
    if ($c.Action -eq 'Bajar') {
        $noise = Get-JuicerMeasureNoise $Result
        if ($noise) { return @{ Fps = $Cap; Action = 'Repetir'; Kind = 'Ruido'; Why = "Repite la medida: $noise. Bajar el ritmo por una medida así sería bajarlo sin motivo: vuelve a medir con el equipo en régimen y sin nada más gastando procesador." } }
    }
    $c
}

# --- What the PC was running -----------------------------------------------------

# What the PC was running when a calibration was made: the graphics card and its
# driver, the game's build (Steam's buildid, else the executable's version) and
# Windows' build. Each is '' when it cannot be read cheaply. Path is the game's
# executable, if known; else it is looked for among the running processes.
function Get-JuicerCalibrationFingerprint {
    param([string]$Exe, [string]$Path)
    $gpu = Get-JuicerMainGpu
    $build = ''
    try { $build = Get-JuicerGameBuild $Exe $Path } catch { Write-Verbose "Sin versión del juego: $_" }
    @{
        Gpu = $(if ($gpu) { [string]$gpu.Name } else { '' })
        GpuDriver = $(if ($gpu) { [string]$gpu.DriverVersion } else { '' })
        GameBuild = [string]$build
        Windows = [string](Get-JuicerWindowsBuild)
    }
}

# What differs between the PC of a calibration and the PC now, in words
# («el driver de la gráfica»): only what both knew counts. Empty when nothing did.
function Get-JuicerCalibrationChanges {
    param($Stored, $Current)
    if ($Stored -isnot [hashtable] -or $Current -isnot [hashtable]) { return @() }
    $names = [ordered]@{ Gpu = 'la gráfica'; GpuDriver = 'el driver de la gráfica'; GameBuild = 'el juego (versión nueva)'; Windows = 'la versión de Windows' }
    $out = @()
    foreach ($k in $names.Keys) {
        $a = [string]$Stored[$k]; $b = [string]$Current[$k]
        if ($a -and $b -and $a -ne $b) { $out += [string]$names[$k] }
    }
    $out
}

# --- Calibrating: propose, confirm, apply, verify -----------------------------

# Measures a game under its frame pacer (setting it first if it had none) and works
# out what its cap should be, without changing it: the finding that carries the
# proposal has a .Proposal (old cap, new cap, why, and what is needed to apply it
# with Save-JuicerPacerCalibration). The caller confirms with the person. With
# -Apply, a proposal is applied at once (the command line with -Si). Returns
# findings; callers wrap them in @().
function Invoke-JuicerPacerCalibration {
    param([Parameter(Mandatory)][string]$Exe, [int]$Seconds = 60, [int]$Delay = 10, [scriptblock]$OnStatus, [hashtable]$Monitor, [switch]$NoFrameGenWarning, [switch]$Apply)
    $exe = ConvertTo-JuicerExeName $Exe
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { throw 'No se pudo leer la pantalla.' }
    # A game without its pace gets it now if it is closed; if it is open (the
    # usual way to calibrate), it is measured as it is, and the pace waits for
    # it to close: its profile is not written under it.
    if (-not @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe -and $_.Fps })) { [void](Add-JuicerFpsLimit $exe 0 $Monitor) }
    $now = @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe -and $_.Fps })
    $unpaced = $now.Count -eq 0
    $cap = if (-not $unpaced) { [int]$now[0].Fps } else { $rec = Get-JuicerRecommendedFps $exe $Monitor; if ($rec) { [int]$rec.Fps } else { 0 } }
    if ($cap -le 0) { throw "No se pudo calcular el ritmo de $exe." }
    $hz = [int]$Monitor.Display.Hz
    $sig = Get-JuicerLimitSignature $Monitor
    # The game's last measurement, from before this one, for the guard against a menu.
    $prior = Get-JuicerUsableFrameResult $exe $sig $hz
    $started = Get-Date
    $out = @(Invoke-JuicerFrameCapture -Seconds $Seconds -Delay $Delay -Process $exe -OnStatus $OnStatus -NoFrameGenWarning:$NoFrameGenWarning)
    $result = Get-JuicerPreviousFrameResult $exe
    if (-not $result -or [datetime]$result.Date -lt $started.AddSeconds(-5)) { return $out }
    $use = Resolve-JuicerMonitorUse $Monitor
    $vrrMin = if ($Monitor.Vrr) { [int]$Monitor.Vrr.Min } else { 0 }
    $vrrMax = Get-JuicerVrrTop $Monitor
    $max = (Get-JuicerFpsCap $hz $use $null $vrrMin @() 0 $vrrMax).Fps
    $c = Get-JuicerCalibrationPlan $result $cap $max $use $vrrMin @($Monitor.Display.RefreshRates | Where-Object { $_ }) $hz (Get-JuicerPacerPriority $exe) (Get-JuicerMainGpuVendor) $prior (Get-JuicerBestUnpacedFps $exe $sig $hz)
    $area = "Frame pacer: $exe"
    if ($unpaced -and $c.Action -eq 'NoActua') {
        Write-JuicerLog "Calibración de ${exe}: medido sin ritmo (el juego estaba abierto)"
        $out += New-JuicerFinding $area 'Medio' 'Medido sin frame pacer todavía' "El juego estaba abierto antes de tener su ritmo, y Win Juicer no cambia el perfil de un juego en marcha. Se le pondrá ($cap FPS) en cuanto lo cierres; después, vuelve a calibrar con el ritmo ya puesto."
        return $out
    }
    if ($c.Action -eq 'Repetir') {
        Write-JuicerLog "Calibración de ${exe}: sin cambios ($($c.Kind))"
        $title = if ($c.Kind -eq 'Escena') { 'Sin cambios: parece un menú o una pantalla de carga, repite en partida' } else { 'Sin cambios: repite la medida' }
        $out += New-JuicerFinding $area 'Medio' $title "$($c.Why) No se ha cambiado nada. Elige tu escena más exigente y habitual (no un menú), sin Alt-Tab, durante toda la medida."
        return $out
    }
    if ($c.Action -in 'Bajar', 'Subir') {
        $proposal = @{
            Exe = $exe; Old = $cap; New = [int]$c.Fps; Action = $c.Action; Why = [string]$c.Why; Signature = $sig
            Fingerprint = (Get-JuicerCalibrationFingerprint $exe)
        }
        if ($Apply) { return @($out + @(Save-JuicerPacerCalibration $proposal $Monitor)) }
        $f = New-JuicerFinding $area 'Medio' ('Propuesta: de {0} a {1} FPS' -f $cap, $c.Fps) "$($c.Why) Todavía no se ha cambiado nada: confirma para aplicarlo."
        $f.Proposal = $proposal
        $out += $f
    } else {
        $sev = switch ($c.Action) { 'Mantener' { 'Ok' } 'Reflex' { 'Info' } default { 'Medio' } }
        $out += New-JuicerFinding $area $sev $(switch ($c.Action) { 'Mantener' { "Calibrado: se queda en $cap FPS" } 'Reflex' { "Lo limita Reflex a $($c.Suggest) FPS, no tu PC: el ritmo no se toca" } 'Estrobo' { 'Con estrobo no se baja el ritmo' } default { 'Sin calibrar' } }) $c.Why
    }
    Write-JuicerLog "Calibración de ${exe}: $($c.Action) $cap -> $($c.Fps)"
    $out
}

# The proposal a calibration's findings carry, or null.
function Get-JuicerCalibrationProposal {
    param([object[]]$Findings)
    $f = @($Findings | Where-Object { $_ -is [hashtable] -and $_.Proposal -is [hashtable] } | Select-Object -Last 1)
    if ($f.Count -gt 0) { $f[0].Proposal } else { $null }
}

# Applies a proposal: remembers it for this monitor (with what the PC was running) and sets
# the game's cap again; a game that is open gets it when it closes. Calibrating is choosing
# automatically again, so a rate set by hand goes (and is kept in the proposal, for
# Restore-JuicerPacerCalibration). Returns the findings.
function Save-JuicerPacerCalibration {
    param([Parameter(Mandatory)][hashtable]$Proposal, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName $Proposal.Exe
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { throw 'No se pudo leer la pantalla.' }
    $sig = if ($Proposal.Signature) { [string]$Proposal.Signature } else { Get-JuicerLimitSignature $Monitor }
    $state = Read-JuicerPacer
    # What was there, to put it back if the verification says no.
    $Proposal.Previous = Get-JuicerCalibrationEntry $state $exe $sig
    $Proposal.PreviousManual = Get-JuicerPacerFps $exe
    Set-JuicerCalibrationEntry $state $exe $sig @{ Fps = [int]$Proposal.New; Why = [string]$Proposal.Why; Signature = $sig; Date = (Get-Date).ToString('s'); Fingerprint = $Proposal.Fingerprint }
    Set-JuicerPacerGameField $state $exe 'Fps' $null
    Save-JuicerPacer $state
    $r = Add-JuicerFpsLimit $exe 0 $Monitor
    $sev = if ($r.Outcome -in 'Aplicado', 'YaEstaba', 'Pendiente') { 'Ok' } else { 'Medio' }
    $when = if ($r.Outcome -eq 'Pendiente') { ' Se aplicará en cuanto cierres el juego: Win Juicer no lo cambia con el juego abierto, para que no se congele. Para verificarlo, ábrelo de nuevo con el ritmo puesto.' } else { '' }
    Write-JuicerLog "Calibración de ${exe}: aplicada $($Proposal.Old) -> $($Proposal.New)"
    $f = New-JuicerFinding "Frame pacer: $exe" $sev ('Calibrado: de {0} a {1} FPS' -f $Proposal.Old, $Proposal.New) "$($Proposal.Why)$when"
    $f.Outcome = [string]$r.Outcome
    @($f)
}

# Puts back what a proposal replaced (the earlier calibration for this monitor, or none, and the
# rate chosen by hand), and sets the cap again.
function Restore-JuicerPacerCalibration {
    param([Parameter(Mandatory)][hashtable]$Proposal, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName $Proposal.Exe
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    $sig = if ($Proposal.Signature) { [string]$Proposal.Signature } elseif ($Monitor) { Get-JuicerLimitSignature $Monitor } else { '' }
    $state = Read-JuicerPacer
    Set-JuicerCalibrationEntry $state $exe $sig $Proposal.Previous
    if ([int]$Proposal.PreviousManual -gt 0) { Set-JuicerPacerGameField $state $exe 'Fps' ([int]$Proposal.PreviousManual) }
    Save-JuicerPacer $state
    if ($Monitor) { try { [void](Add-JuicerFpsLimit $exe 0 $Monitor) } catch { Write-JuicerLog "No se pudo volver a poner el ritmo de ${exe}: $_" } }
    Write-JuicerLog "Calibración de ${exe}: deshecha ($($Proposal.New) -> $($Proposal.Old))"
}

# What a verification run (the game measured at the new cap) says to do with a
# proposal that was applied. Action:
#   Confirmado  it holds: keep it
#   Bajar       it still misses: step down to Fps (to be confirmed like any other)
#   Revertir    a raise that did not hold within 3 %: put the old cap back
#   Repetir     the run is no good (a menu, the pace not acting, throttled): keep, measure again
# For a raise, the run has to agree with the new cap within 3 % before it stays.
function Get-JuicerPacerVerifyDecision {
    param([Parameter(Mandatory)][hashtable]$Result, [Parameter(Mandatory)][hashtable]$Proposal, [int]$Max = 0, [string]$Use = 'Fijo', [int]$VrrMin = 0, [int[]]$Rates = @(), [int]$Hz = 0, [string]$Priority = 'Fluidez', [string]$GpuVendor = '', $Previous)
    $new = [int]$Proposal.New
    $c = Get-JuicerPacerCalibration $Result $new $Max $Use $VrrMin $Rates $Hz $Priority $GpuVendor
    if ($c.Action -eq 'NoActua') { return @{ Action = 'Repetir'; Fps = $new; Why = ('El juego iba a {0:N0} FPS, por encima de los {1}: el frame pacer no estaba actuando, así que no se puede verificar.' -f $Result.AvgFps, $new) } }
    $scene = Get-JuicerCalibrationSceneProblem $Result $new $Previous
    if ($scene) { return @{ Action = 'Repetir'; Fps = $new; Why = $scene } }
    if ($Proposal.Action -eq 'Subir') {
        $agree = [Math]::Abs($Result.AvgFps - $new) -le 0.03 * $new
        if ($c.Action -eq 'Bajar' -or -not $agree) {
            # It held part of the way: stop there, if that is still above where it was.
            if ($c.Action -eq 'Bajar' -and [int]$c.Fps -ge [int]$Proposal.Old + 3) {
                return @{ Action = 'Bajar'; Fps = [int]$c.Fps; Why = ('Con {0} FPS no se sostiene del todo (media {1:N0} FPS); {2} FPS sí, y siguen siendo más que los {3} de antes.' -f $new, $Result.AvgFps, $c.Fps, $Proposal.Old) }
            }
            return @{ Action = 'Revertir'; Fps = [int]$Proposal.Old; Why = ('No se confirma la subida: a {0} FPS la media fue de {1:N0} FPS (tiene que quedar a menos de un 3 %) y el ritmo no se sostiene. Se vuelve a los {2} FPS de antes.' -f $new, $Result.AvgFps, $Proposal.Old) }
        }
        return @{ Action = 'Confirmado'; Fps = $new; Why = ('Confirmado: a {0} FPS la media fue de {1:N0} FPS y el ritmo se sostiene.' -f $new, $Result.AvgFps) }
    }
    if ($c.Action -eq 'Bajar') {
        $noise = Get-JuicerMeasureNoise $Result
        if ($noise) { return @{ Action = 'Repetir'; Fps = $new; Why = "Repite la medida: $noise." } }
        return @{ Action = 'Bajar'; Fps = [int]$c.Fps; Why = ('Aún no llega: con {0} FPS el 5 % de los fotogramas sigue tarde (el 5 % más lento va a {1:N0} FPS). {2}' -f $new, $Result.Fps95, $c.Why) }
    }
    @{ Action = 'Confirmado'; Fps = $new; Why = ('Confirmado: a {0} FPS la media fue de {1:N0} FPS y el 5 % más lento no se sale del ritmo.' -f $new, $Result.AvgFps) }
}

# Measures the game at the cap just applied (the game must have started with it: a profile
# is not changed under an open game), 45 s by default, and acts on the decision: a raise that
# does not hold goes back by itself; one that still misses comes back as a new proposal
# (NextProposal) to confirm like the first. Returns @{ Findings; Decision; NextProposal }.
function Invoke-JuicerPacerVerify {
    param([Parameter(Mandatory)][hashtable]$Proposal, [int]$Seconds = 45, [int]$Delay = 10, [scriptblock]$OnStatus, [hashtable]$Monitor, [switch]$NoFrameGenWarning)
    $exe = ConvertTo-JuicerExeName $Proposal.Exe
    if (-not $Monitor) { $Monitor = Get-JuicerPrimaryMonitor }
    if (-not $Monitor) { throw 'No se pudo leer la pantalla.' }
    $area = "Frame pacer: $exe"
    $live = @(Get-JuicerFpsLimits | Where-Object { $_.Exe -eq $exe -and $_.Fps })
    if ($live.Count -eq 0 -or [int]$live[0].Fps -ne [int]$Proposal.New) {
        $have = if ($live.Count -gt 0) { "tiene $([int]$live[0].Fps) FPS" } else { 'no tiene ritmo puesto' }
        $d = @{ Action = 'Repetir'; Fps = [int]$Proposal.New; Why = "El juego $have y no los $($Proposal.New) FPS de la calibración: si estaba abierto, ciérralo y ábrelo para que arranque con el ritmo nuevo (el perfil no se cambia con el juego en marcha), y verifica entonces." }
        return @{ Findings = @(New-JuicerFinding $area 'Medio' 'No se puede verificar todavía' $d.Why); Decision = $d; NextProposal = $null }
    }
    $hz = [int]$Monitor.Display.Hz
    $sig = Get-JuicerLimitSignature $Monitor
    $prior = Get-JuicerUsableFrameResult $exe $sig $hz
    $started = Get-Date
    $out = @(Invoke-JuicerFrameCapture -Seconds $Seconds -Delay $Delay -Process $exe -OnStatus $OnStatus -NoFrameGenWarning:$NoFrameGenWarning)
    $result = Get-JuicerPreviousFrameResult $exe
    if (-not $result -or [datetime]$result.Date -lt $started.AddSeconds(-5)) {
        return @{ Findings = $out; Decision = @{ Action = 'Repetir'; Fps = [int]$Proposal.New; Why = 'No se midió ningún juego.' }; NextProposal = $null }
    }
    $use = Resolve-JuicerMonitorUse $Monitor
    $vrrMin = if ($Monitor.Vrr) { [int]$Monitor.Vrr.Min } else { 0 }
    $vrrMax = Get-JuicerVrrTop $Monitor
    $max = (Get-JuicerFpsCap $hz $use $null $vrrMin @() 0 $vrrMax).Fps
    $d = Get-JuicerPacerVerifyDecision $result $Proposal $max $use $vrrMin @($Monitor.Display.RefreshRates | Where-Object { $_ }) $hz (Get-JuicerPacerPriority $exe) (Get-JuicerMainGpuVendor) $prior
    $next = $null
    switch ($d.Action) {
        'Confirmado' {
            $state = Read-JuicerPacer
            $e = Get-JuicerCalibrationEntry $state $exe $sig
            if ($e) { $e.Verified = (Get-Date).ToString('s'); Save-JuicerPacer $state }
            $out += New-JuicerFinding $area 'Ok' ('Verificado a {0} FPS' -f $Proposal.New) $d.Why
        }
        'Bajar' {
            $next = @{ Exe = $exe; Old = [int]$Proposal.New; New = [int]$d.Fps; Action = 'Bajar'; Why = [string]$d.Why; Signature = $sig; Fingerprint = $Proposal.Fingerprint; Previous = $Proposal.Previous; PreviousManual = $Proposal.PreviousManual }
            $f = New-JuicerFinding $area 'Medio' ('Propuesta: de {0} a {1} FPS' -f $Proposal.New, $d.Fps) "$($d.Why) Todavía no se ha cambiado nada: confirma para aplicarlo."
            $f.Proposal = $next
            $out += $f
        }
        'Revertir' {
            Restore-JuicerPacerCalibration $Proposal $Monitor
            $out += New-JuicerFinding $area 'Medio' ('Subida no confirmada: se vuelve a {0} FPS' -f $Proposal.Old) $d.Why
        }
        default {
            $out += New-JuicerFinding $area 'Medio' 'Verificación sin resultado: repite la medida' $d.Why
        }
    }
    Write-JuicerLog "Verificación de ${exe}: $($d.Action) ($($Proposal.Old) -> $($Proposal.New))"
    @{ Findings = $out; Decision = $d; NextProposal = $next }
}

# Whether a game's calibration is what is in force now: Activa (this
# monitor, used this way, and no rate chosen by hand over it), Manual (a rate
# the person chose wins), OtroMonitor (made for another monitor, refresh rate
# or mode, so it is not used) or '' (no calibration, or no screen to compare
# with). Only an Activa one is worth showing its age.
function Get-JuicerCalibrationState {
    param([string]$Exe, [hashtable]$Calibration, [hashtable]$Monitor, [hashtable]$Pacer)
    if ($Calibration -isnot [hashtable] -or [int]$Calibration.Fps -le 0) { return '' }
    if (-not $Pacer) { $Pacer = Read-JuicerPacer }
    $key = ConvertTo-JuicerExeName $Exe
    $g = $Pacer.Games[$key]
    if ($g -is [hashtable] -and [int]$g.Fps -gt 0) { return 'Manual' }
    if (-not $Monitor -or -not $Monitor.Display) { return '' }
    if ([string]$Calibration.Signature -ne (Get-JuicerLimitSignature $Monitor)) { return 'OtroMonitor' }
    $latency = $g -is [hashtable] -and [string]$g.Priority -eq 'Latencia'
    if ((Resolve-JuicerMonitorUse $Monitor) -eq 'Estrobo' -and -not $latency) { return 'OtroMonitor' }
    'Activa'
}

# How old a calibration is, in words: «calibrado hace 12 días a 141 FPS», and after 30 days
# a hint that it may no longer hold (a patch, other settings). Changes, what the PC runs
# now that it did not when it was calibrated (Get-JuicerCalibrationChanges: the driver, the
# game's build, the graphics card, Windows), also asks for a new one, whatever its age.
# Null when there is no date to count from. -Now only for the tests.
function Get-JuicerCalibrationAge {
    param([string]$Date, [int]$Fps, [datetime]$Now = (Get-Date), [string[]]$Changes = @())
    if (-not $Date -or $Fps -le 0) { return $null }
    $when = [datetime]::MinValue
    if (-not [datetime]::TryParse($Date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when)) { return $null }
    $days = [Math]::Max(0, [int][Math]::Floor(($Now - $when).TotalDays))
    $ago = if ($days -eq 0) { 'hoy' } elseif ($days -eq 1) { 'hace 1 día' } else { "hace $days días" }
    $changes = @($Changes | Where-Object { $_ })
    $stale = $days -ge 30 -or $changes.Count -gt 0
    $a = @{
        Days = $days; Stale = $stale; Changes = $changes
        Text = "calibrado $ago a $Fps FPS"
        Hint = $(if ($changes.Count -gt 0) { 'ha cambiado ' + ($changes -join ', ') + ' desde que se calibró: vuelve a calibrar' } elseif ($stale) { 'puede haber cambiado (parche, ajustes): vuelve a calibrar' } else { '' })
    }
    # The same, as a sentence for the game page.
    $a.Sentence = $a.Text.Substring(0, 1).ToUpperInvariant() + $a.Text.Substring(1) + '.' + $(if ($stale) { ' ' + $a.Hint.Substring(0, 1).ToUpperInvariant() + $a.Hint.Substring(1) + '.' } else { '' })
    $a
}

# Forgets what calibrating found, for one game or all.
function Clear-JuicerPacerCalibration {
    param([string]$Exe)
    $state = Read-JuicerPacer
    if ($Exe) { $state.Calibrated.Remove((ConvertTo-JuicerExeName $Exe)) } else { $state.Calibrated = @{} }
    Save-JuicerPacer $state
}

# --- Two limiters at once -----------------------------------------------------

# Whatever else limits frames and would fight the frame pacer, what the
# engine in use cannot do with this monitor, and what the setup says about the
# rates in force. State comes from the backend (RTSS's Global profile and
# games, NVIDIA's global limit); Limits, from Get-JuicerFpsLimits; GpuVendor
# is the main card's (NVIDIA, AMD…) and Monitors every active display.
function Get-JuicerPacerConflicts {
    param([hashtable]$State, [string]$Backend, [object[]]$Limits = @(), [hashtable]$Monitor, [string]$GpuVendor = '', [object[]]$Monitors = @())
    $out = @()
    if ($State) { $out += @(Get-JuicerPacerStateConflicts $State $Backend $Limits $Monitor) }
    $out += @(Get-JuicerPacerAdvice $Limits $Monitor $GpuVendor $Monitors)
    $out
}

# What the engine's own state says: other limiters, RivaTuner not open, G-SYNC
# off in the driver, the shader cache, and strobing with a driver that only
# takes whole numbers.
function Get-JuicerPacerStateConflicts {
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
    # G-SYNC as NVIDIA's panel has it, when the monitor is used with VRR.
    if ($Monitor -and (Resolve-JuicerMonitorUse $Monitor) -in 'VRR', 'EstroboSync') {
        if ($State.NvVrrMode -eq 0) {
            $out += New-JuicerFinding $area 'Medio' 'G-SYNC está desactivado en el panel de NVIDIA' 'Usas el monitor con frecuencia variable, pero el driver la tiene apagada: sin ella, el ritmo por debajo de los Hz da tirones de VSync. Panel de control de NVIDIA > Configurar G-SYNC > Activar G-SYNC, G-SYNC Compatible.'
        } elseif ($State.NvVrrMode -eq 1) {
            $out += New-JuicerFinding $area 'Bajo' 'G-SYNC sólo en pantalla completa' 'Los juegos en «ventana sin bordes» se quedan sin frecuencia variable. Panel de control de NVIDIA > Configurar G-SYNC > «Activar para el modo ventana y pantalla completa». Si ves parpadeos en algún programa de escritorio, se le quita en su perfil.'
        }
    }
    # Stutter no pace can fix: shaders compiled again every time.
    if ($State.NvShaderCache -eq 0) {
        $out += New-JuicerFinding $area 'Alto' 'La caché de sombreadores de NVIDIA está desactivada' 'Cada vez que juegas, el juego vuelve a compilar sus sombreadores y eso da tirones que ningún ritmo arregla. Suele ser cosa de otro «optimizador». Panel de control de NVIDIA > Administrar la configuración 3D > Tamaño de la caché del sombreador: «Predeterminado del controlador».'
    } elseif ($State.NvShaderCacheMb -gt 0 -and $State.NvShaderCacheMb -lt 4096) {
        $out += New-JuicerFinding $area 'Medio' ('Caché de sombreadores de NVIDIA de sólo {0} MB' -f $State.NvShaderCacheMb) 'Los juegos actuales llenan varios GB: con tan poca, se borran sombreadores y se vuelven a compilar en mitad de la partida (tirones). Panel de control de NVIDIA > Administrar la configuración 3D > Tamaño de la caché del sombreador: «Predeterminado del controlador» o 10 GB.'
    }
    if ($Monitor -and (Resolve-JuicerMonitorUse $Monitor) -eq 'Estrobo') {
        $hz = [int]$Monitor.Display.Hz
        $exact = [double]$Monitor.Display.ExactHz
        if ($Backend -eq 'nvidia' -and $exact -gt 0 -and $exact -lt $hz - 0.004) {
            $tail = if ($State.RtssInstalled) { 'Tienes RivaTuner: elige «RivaTuner» como motor del frame pacer y el ritmo irá a {0:N2} FPS, justo por debajo.' -f ($exact - 0.01) } else { 'RivaTuner admite décimas: instálalo (es gratis), elígelo como motor del frame pacer y el ritmo irá justo por debajo, a {0:N2} FPS.' -f ($exact - 0.01) }
            $out += New-JuicerFinding $area 'Medio' ('Tu pantalla va a {0:N3} Hz, y el driver de NVIDIA sólo limita en enteros' -f $exact) ("Con estrobo y sincronización vertical, $hz FPS es un pelo más rápido que la pantalla: la cola de la sincronización vertical se llena y vuelve un fotograma de latencia (unos {0:N1} ms). $tail" -f (1000 / $exact))
        } elseif ($Backend -eq 'rtss' -and $exact -gt 0) {
            $out += New-JuicerFinding $area 'Ok' ('Ritmo al Hz exacto: {0:N2} FPS para una pantalla a {1:N3} Hz' -f ($exact - 0.01), $exact) 'Justo por debajo del refresco real, con la sincronización vertical: un fotograma por destello y sin la cola que añade latencia («low-lag VSync»).'
        }
    }
    $out
}

# What the rates and the setup say, without the engine's state: rates left
# behind by a change of refresh, the AMD limiters, several monitors, a G-SYNC
# monitor Windows cannot tell from a fixed one.
function Get-JuicerPacerAdvice {
    param([object[]]$Limits = @(), [hashtable]$Monitor, [string]$GpuVendor = '', [object[]]$Monitors = @())
    $out = @()
    $area = 'Frame pacer'
    # Caps that no longer are what Recalcular would set: the refresh rate or
    # the monitor mode changed (or Win Juicer got a new way to work the rate
    # out) and the sign-in upkeep only recalculates when it is on. A rate
    # chosen by hand stays, a game waiting for its close is left to that, and
    # a game NVIDIA caps lower in its own profile is not a stale rate.
    if ($Monitor -and $Monitor.Display -and @($Limits).Count -gt 0) {
        $pacer = Read-JuicerPacer
        $stale = @()
        foreach ($l in @($Limits)) {
            if (-not $l.Fps -or $pacer.Pending.ContainsKey([string]$l.Exe)) { continue }
            $g = $pacer.Games[[string]$l.Exe]
            if ($g -is [hashtable] -and [int]$g.Fps -gt 0) { continue }
            try {
                $rec = Get-JuicerRecommendedFps ([string]$l.Exe) $Monitor
                if (-not $rec -or [int]$rec.Fps -eq [int]$l.Fps) { continue }
                $frl = & (Get-JuicerBackend).NvRead ([string]$l.Exe) ([uint32]0x10835002)
                if ($frl -and $null -ne $frl.Predefined -and [int]$frl.Predefined -gt 0 -and [int]$frl.Predefined -le [int]$l.Fps) { continue }
                $stale += @{ Exe = [string]$l.Exe; Now = [int]$l.Fps; Rec = [int]$rec.Fps }
            } catch {
                Write-JuicerLog "Sin ritmo recomendado para $($l.Exe): $_"
            }
        }
        if ($stale.Count -gt 0) {
            $hz = [int]$Monitor.Display.Hz
            $pairs = @($stale | ForEach-Object { "$($_.Now)>$($_.Rec)" } | Select-Object -Unique)
            $names = ($stale | Select-Object -First 5 | ForEach-Object { $_.Exe }) -join ', '
            if ($stale.Count -gt 5) { $names += " y $($stale.Count - 5) más" }
            $text = if ($pairs.Count -eq 1) {
                "tus juegos tienen $($stale[0].Now) FPS y para tus $hz Hz serían $($stale[0].Rec)"
            } else {
                'tus juegos tienen ritmos distintos de los que tocan para tus {0} Hz ({1})' -f $hz, (($stale | Select-Object -First 5 | ForEach-Object { '{0}: {1}, ahora serían {2}' -f $_.Exe, $_.Now, $_.Rec }) -join '; ')
            }
            $out += New-JuicerFinding $area 'Medio' ('Hay {0} con un ritmo que ya no es el recomendado' -f $(if ($stale.Count -eq 1) { '1 juego' } else { "$($stale.Count) juegos" })) ("$($text.Substring(0, 1).ToUpperInvariant())$($text.Substring(1)): pulsa «Recalcular los ritmos» (en la consola, R en este menú). Sale así cuando cambia tu monitor, su modo o los Hz, o Win Juicer calcula el ritmo de otra manera; el mantenimiento al iniciar sesión sólo lo recalcula si lo tienes activado. Afecta a: $names. Los ritmos que elegiste tú no se tocan.")
        }
    }
    if ($GpuVendor -eq 'AMD') {
        $out += New-JuicerFinding $area 'Info' 'AMD: Radeon Chill y Frame Rate Target Control' 'Si en AMD Software tienes Radeon Chill o Frame Rate Target Control (global o para el juego), manda el más bajo de los límites; Chill además baja los FPS por sí solo cuando no te mueves. Si un juego no llega al ritmo de Win Juicer y la gráfica va sobrada, es lo primero que hay que mirar.'
    }
    # Several screens: the pace is worked out for the main one.
    $active = @($Monitors | Where-Object { $_ -and $_.Display })
    if ($active.Count -gt 1) {
        $main = if ($Monitor) { $Monitor } else { $active[0] }
        $differs = @($active | Where-Object { $_ -ne $main -and ([int]$_.Display.Hz -ne [int]$main.Display.Hz -or [bool]$_.Vrr -ne [bool]$main.Vrr) })
        if ($differs.Count -gt 0) {
            $mainText = '{0} Hz{1}' -f [int]$main.Display.Hz, $(if ($main.Vrr) { ' con VRR' } else { ' sin VRR' })
            $others = ($differs | ForEach-Object { '{0} Hz{1}' -f [int]$_.Display.Hz, $(if ($_.Vrr) { ' con VRR' } else { ' sin VRR' }) }) -join ' y '
            $out += New-JuicerFinding $area 'Info' 'Tienes pantallas con distintos Hz o VRR' "Calculado para tu pantalla principal ($mainText); la otra va a $others. Si juegas en otra, cámbiala a principal (Configuración > Sistema > Pantalla > «Convertir en pantalla principal») o ajusta el modo del monitor aquí, y recalcula los ritmos."
        }
    }
    # Windows cannot tell a G-SYNC module monitor from a fixed one: it has no
    # FreeSync or HDMI VRR block in its EDID.
    if ($GpuVendor -eq 'NVIDIA' -and $Monitor -and -not $Monitor.Vrr) {
        $mode = if ($Monitor.Mode) { [string]$Monitor.Mode } else { Get-JuicerMonitorMode $Monitor }
        if ($mode -eq 'Automatico' -and (Resolve-JuicerMonitorUse $Monitor) -eq 'Fijo') {
            $out += New-JuicerFinding $area 'Info' 'Tu monitor sale como de frecuencia fija' 'Si tu monitor es G-SYNC (con módulo), Windows no lo distingue de uno fijo: elige «Frecuencia variable» en el modo del monitor y el ritmo irá justo debajo de los Hz, con la V-Sync que G-SYNC necesita.'
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
    $all = @()
    try { $all = @(Get-JuicerMonitors) } catch { Write-JuicerLog "Sin monitores: $_" }
    Get-JuicerPacerConflicts $state (Get-JuicerFpsBackend) @(Get-JuicerFpsLimits) $m (Get-JuicerMainGpuVendor) $all
}
