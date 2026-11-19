# What to set inside each game, for this graphics card, this monitor and how
# it is used, and what the last measurement of that game said limits it.
# Win Juicer cannot change a game's own options, so these are the steps;
# they complete what it sets from outside (the FPS cap, the NVIDIA profile).
#
# The table only states what is known for sure of each game: whether it has
# NVIDIA Reflex or AMD Anti-Lag 2, whether it is played competitively, and
# the odd fact that changes the advice
# (Elden Ring is capped at 60 FPS by the game itself). The rest comes from
# the hardware and applies to any game.

$script:GameTips = @(
    @{ P = '^cs2\.exe$'; Competitive = $true; Name = 'Counter-Strike 2'; Reflex = $true; AntiLag2 = $true }
    @{ P = '^valorant-win64-shipping\.exe$'; Competitive = $true; Name = 'VALORANT'; Reflex = $true }
    @{ P = '^fortniteclient-win64-shipping'; Competitive = $true; Name = 'Fortnite'; Reflex = $true; Notes = 'Con un procesador o una gráfica modestos, el modo de renderizado «Rendimiento» da muchos más FPS a cambio de calidad; con hardware actual, DirectX 12.' }
    @{ P = '^r5apex(_dx12)?\.exe$'; Competitive = $true; Name = 'Apex Legends'; Reflex = $true }
    @{ P = '^overwatch\.exe$'; Competitive = $true; Name = 'Overwatch 2'; Reflex = $true }
    @{ P = '^(cod|modernwarfare|blackopscoldwar|vanguard)\.exe$'; Competitive = $true; Name = 'Call of Duty'; Reflex = $true }
    @{ P = '^rainbowsix(_vulkan|_dx12)?(_be)?\.exe$'; Competitive = $true; Name = 'Rainbow Six Siege'; Reflex = $true }
    @{ P = '^marvel-win64-shipping\.exe$'; Competitive = $true; Name = 'Marvel Rivals'; Reflex = $true }
    @{ P = '^discovery\.exe$'; Competitive = $true; Name = 'THE FINALS'; Reflex = $true }
    @{ P = '^tslgame\.exe$'; Competitive = $true; Name = 'PUBG: BATTLEGROUNDS'; Reflex = $true }
    @{ P = '^cyberpunk2077\.exe$'; Name = 'Cyberpunk 2077'; Reflex = $true }
    @{ P = '^ghostoftsushima\.exe$'; Name = 'Ghost of Tsushima'; Reflex = $true; AntiLag2 = $true }
    @{ P = '^eldenring\.exe$'; Name = 'Elden Ring'; Cap60 = $true; Notes = 'El propio juego no pasa de 60 FPS: con una pantalla de más Hz, la frecuencia variable es lo que evita los tirones.' }
    @{ P = '^league of legends\.exe$'; Competitive = $true; Name = 'League of Legends'; Notes = 'No tiene Reflex: su limitador de FPS propio, si lo usas, a la misma cifra que el frame pacer de Win Juicer.' }
    @{ P = '^rocketleague\.exe$'; Competitive = $true; Name = 'Rocket League' }
)

# Competitive games: where the frame pacer is best set for latency.
function Test-JuicerCompetitiveGame {
    param([string]$ExeName)
    $t = Find-JuicerGameTip $ExeName
    [bool]($t -and $t.Competitive)
}

function Find-JuicerGameTip {
    param([string]$ExeName)
    foreach ($t in $script:GameTips) { if ($ExeName -match $t.P) { return $t } }
    $null
}

# Unreal games keep the options the player chose in
# %LOCALAPPDATA%\<Project>\Saved\Config\Windows\GameUserSettings.ini (Windows,
# WindowsNoEditor or WinGDK, by build), and the project is the .exe's prefix:
# Marvel-Win64-Shipping.exe is «Marvel». The game's own FPS limit and VSync are
# there, and a limit lower than Win Juicer's wins. Read only; null if the
# game is not Unreal's or the file (or its FrameRateLimit) is not there.
# Returns @{ Project; Path; Limit (0 is unlimited); VSync (or $null) }.
function Get-JuicerUnrealLimit {
    param([string]$ExeName, [string]$LocalAppData = $env:LOCALAPPDATA)
    if (-not $LocalAppData -or -not (Test-Path -LiteralPath $LocalAppData -PathType Container)) { return $null }
    $leaf = Split-Path -Leaf ([string]$ExeName)
    if ($leaf -notmatch '^(?<p>.+)-(Win64|WinGDK)-Shipping\.exe$') { return $null }
    $project = $Matches['p']
    # By name without caring about case: the file system on Windows does not, and the .exe name may have been lowercased.
    $dir = @(Get-ChildItem -LiteralPath $LocalAppData -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -eq $project }) | Select-Object -First 1
    if (-not $dir) { return $null }
    foreach ($variant in 'Windows', 'WindowsNoEditor', 'WinGDK') {
        $path = Join-Path (Join-Path (Join-Path (Join-Path $dir.FullName 'Saved') 'Config') $variant) 'GameUserSettings.ini'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try { $lines = [IO.File]::ReadAllLines($path) } catch { Write-Verbose "Sin leer ${path}: $_"; continue }
        $limit = $null
        $vsync = $null
        foreach ($l in $lines) {
            if ($null -eq $limit -and $l -match '^\s*FrameRateLimit\s*=\s*(?<v>-?[0-9]+(?:\.[0-9]+)?)') { $limit = [double]::Parse($Matches['v'], [Globalization.CultureInfo]::InvariantCulture) }
            if ($null -eq $vsync -and $l -match '^\s*bUseVSync\s*=\s*(?<v>True|False)\s*$') { $vsync = $Matches['v'] -eq 'True' }
        }
        if ($null -ne $limit) { return @{ Project = $project; Path = $path; Limit = [Math]::Max(0.0, $limit); VSync = $vsync } }
    }
    $null
}

# Use is how the monitor is used (VRR, Estrobo, EstroboSync, Fijo);
# Measured, the last measurement of this game (GpuBound, AvgFps, Low1); Tech,
# what its folder shows it can do (Find-JuicerGameTech); UnrealLimit, the
# game's own limit (Get-JuicerUnrealLimit); WjFps, the cap Win Juicer has set
# or would set for it.
function Get-JuicerGameTips {
    param([Parameter(Mandatory)][string]$ExeName, [string]$Title = '', [string]$GpuVendor = '', [string]$Use = 'Fijo', [hashtable]$Measured, [int]$Hz, [hashtable]$Tech, [hashtable]$UnrealLimit, [int]$WjFps = 0)
    $tip = Find-JuicerGameTip $ExeName
    $name = if ($tip) { $tip.Name } elseif ($Title) { $Title } else { $ExeName }
    $area = "Consejos: $name"
    $out = @()
    $cpuBound = $Measured -and $null -ne $Measured.GpuBound -and $Measured.GpuBound -lt 50
    $gpuBound = $Measured -and $null -ne $Measured.GpuBound -and $Measured.GpuBound -ge 80

    # Latency: what the game offers for it.
    # Reflex by the table of known games, or because the folder has its files
    # (the game can: whether it is on is the person's). DLSS frame generation forces it.
    $reflexByFiles = [bool]($Tech -and ($Tech.Reflex -or $Tech.DlssFG))
    $hasReflex = [bool]($tip -and $tip.Reflex) -or $reflexByFiles
    if ($GpuVendor -eq 'NVIDIA') {
        if ($hasReflex) {
            $boost = if ($cpuBound) { '«Activado + Boost»: tu medida dice que el procesador limita, y Boost mantiene la gráfica a tope de frecuencia para que no pierda tiempo' } else { '«Activado» (o «Activado + Boost» si notas que el procesador limita)' }
            $how = if ($tip -and $tip.Reflex) { '' } else { ' La carpeta del juego trae sus archivos de Reflex (sl.reflex.dll): el juego puede usarlo, y que lo tenga activado lo decides tú en sus opciones.' }
            $out += New-JuicerFinding $area 'Info' 'NVIDIA Reflex: actívalo' "En las opciones de vídeo, NVIDIA Reflex Low Latency $boost. Con Reflex activo, el ritmo del frame pacer de Win Juicer (en el driver) se aplica a través de él, y el «Modo de baja latencia» del panel deja de importar.$how"
        } elseif (-not $tip) {
            $out += New-JuicerFinding $area 'Info' 'Si tiene NVIDIA Reflex, actívalo' 'Búscalo en las opciones de vídeo o gráficos: es la mayor reducción de latencia que hay. Si no lo tiene, el modo de baja latencia que Win Juicer pone en su perfil hace ese papel.'
        }
    } elseif ($GpuVendor -eq 'AMD') {
        if ($tip -and $tip.AntiLag2) {
            $out += New-JuicerFinding $area 'Info' 'AMD Anti-Lag 2: actívalo en el juego' 'Este juego lo integra: menos latencia que el Anti-Lag del panel, y sin riesgo con el anti-trampas porque lo activa el propio juego.'
        } else {
            $out += New-JuicerFinding $area 'Info' 'Radeon Anti-Lag en AMD Software' 'En AMD Software > Juegos > este juego (o en global), activa Radeon Anti-Lag: recorta la cola de fotogramas como el modo de baja latencia de NVIDIA.'
        }
    }

    # Sync and the game's own limiter, by how the monitor is used.
    $vsyncDriver = if ($GpuVendor -eq 'NVIDIA') { 'Win Juicer ya la fuerza en el perfil de NVIDIA de este juego' } else { 'actívala en el panel de tu gráfica' }
    switch ($Use) {
        { $_ -in 'VRR', 'EstroboSync' } {
            $out += New-JuicerFinding $area 'Info' 'Sincronización vertical del juego: desactivada' "Con G-SYNC/FreeSync, la del juego desactivada y la del driver activada ($vsyncDriver); con el límite por debajo de los Hz no añade latencia y tapa los cortes en los picos."
        }
        'Estrobo' {
            $out += New-JuicerFinding $area 'Info' 'Sincronización vertical: la del driver, no la del juego' "Con el estroboscopio cada destello necesita un fotograma completo: $vsyncDriver, junto con el límite exacto a los Hz. La del juego, desactivada para no sumar dos colas."
        }
        default {
            $out += New-JuicerFinding $area 'Info' 'Sincronización vertical: elige latencia o imagen' 'Sin VRR, desactivada da la menor latencia con cortes en la imagen; activada, imagen limpia con algo más de latencia. Con el límite de Win Juicer a los Hz, la cola de la sincronización vertical se mantiene corta.'
        }
    }
    if ($tip -and $tip.Cap60) {
        $out += New-JuicerFinding $area 'Info' 'El juego va limitado a 60 FPS' 'Un límite de Win Juicer por encima de 60 no llega a actuar; lo que importa aquí es la frecuencia variable, que hace que 60 FPS se vean fluidos en una pantalla de más Hz.'
    } elseif ($GpuVendor -eq 'NVIDIA' -and $hasReflex) {
        $out += New-JuicerFinding $area 'Info' 'El limitador de FPS del juego: desactivado' 'El del driver ya va a través de Reflex con la menor latencia; dos limitadores con cifras distintas sólo suman irregularidad.'
    } else {
        $out += New-JuicerFinding $area 'Info' 'El limitador de FPS del juego: el suyo o el de Win Juicer, no los dos' 'Si el juego tiene limitador propio, puedes usarlo a la misma cifra en lugar del frame pacer de Win Juicer: suele dar algo menos de latencia, y el frame pacer frametimes más planos. Nunca los dos con cifras distintas.'
    }
    # The game's own limit, read from its settings file (Unreal): the lower one wins.
    if ($UnrealLimit) {
        $limit = [int][Math]::Round([double]$UnrealLimit.Limit)
        $vs = if ($UnrealLimit.VSync) { ' (y V-Sync activado)' } else { '' }
        if ($limit -gt 0) {
            $with = if ($WjFps -gt 0) { "con el de Win Juicer a $WjFps" } else { 'con el de Win Juicer' }
            $out += New-JuicerFinding $area $(if ($WjFps -le 0 -or $limit -lt $WjFps) { 'Medio' } else { 'Info' }) "El juego tiene su propio límite a $limit FPS" "El juego tiene su propio límite a $limit FPS${vs}: $with manda el menor. Ponlo en ilimitado en el juego."
        } else {
            $vsTail = if ($UnrealLimit.VSync -and $Use -in 'VRR', 'EstroboSync', 'Estrobo') { ' Eso sí, tiene la V-Sync del juego activada: desactívala en el juego, que la del driver la fuerza Win Juicer.' } else { '' }
            $out += New-JuicerFinding $area 'Info' 'El límite de FPS del juego está en ilimitado' "El límite propio del juego está en ilimitado: bien, manda el de Win Juicer.$vsTail"
        }
    }
    # Frame generation: the cap counts the frames it makes.
    $fg = Get-JuicerFrameGenName $Tech
    if ($fg) {
        $capNow = if ($WjFps -gt 0) { $WjFps } elseif ($Hz -gt 0 -and $Use -in 'VRR', 'EstroboSync') { Get-JuicerVrrCap $Hz } elseif ($Hz -gt 0) { $Hz } else { 0 }
        $real = if ($capNow -gt 0) { " Por ejemplo, un límite de $capNow FPS son unos $([int][Math]::Floor($capNow / 2)) reales." } else { '' }
        $forces = if ($Tech.DlssFG) { ' La generación de DLSS fuerza NVIDIA Reflex, así que su tope con G-SYNC también cuenta.' } else { '' }
        $out += New-JuicerFinding $area 'Info' 'Generación de fotogramas: el límite cuenta los generados' "La carpeta del juego trae los archivos de ${fg}: el juego puede usarla (que esté activada lo decides tú, y su ausencia no prueba que no la tenga). Si la activas, el límite de FPS cuenta también los fotogramas generados: con la generación al doble, la mitad son reales y el ratón responde a ese ritmo.$real$forces"
    }
    $out += New-JuicerFinding $area 'Info' 'Pantalla completa, o sin bordes con la optimización de Windows' 'Pantalla completa, o «ventana sin bordes» con «Optimizaciones para juegos en ventana» (Win Juicer la activa en Ajustes): así el juego presenta directo a la pantalla, sin pasar por el escritorio.'

    # What the last measurement said.
    if ($cpuBound) {
        $out += New-JuicerFinding $area 'Medio' "Tu última medida: el procesador limita (la gráfica espera el $(100 - $Measured.GpuBound) % del tiempo)" 'Lo que más le quita trabajo: distancia de visión y de detalle, densidad de multitudes, vegetación u objetos, y físicas. Bajar texturas o resolución no ayuda; subirlas sale gratis.'
    } elseif ($gpuBound) {
        $out += New-JuicerFinding $area 'Info' "Tu última medida: la gráfica limita (al máximo el $($Measured.GpuBound) % del tiempo)" 'DLSS, FSR o XeSS en «Calidad» dan un 30-50 % más con poca pérdida de nitidez; después, sombras, reflejos e iluminación volumétrica son lo que más cuesta.'
    } elseif (-not $Measured) {
        $out += New-JuicerFinding $area 'Info' 'Mídelo para afinar más' 'Juegos > Medir FPS y frametimes: sabrás si limita el procesador o la gráfica, y estos consejos dirán qué bajar.'
    }
    if ($Hz -gt 0 -and $Measured -and $Measured.Low1 -gt 0 -and $Use -eq 'Estrobo' -and $Measured.Low1 -lt $Hz) {
        $out += New-JuicerFinding $area 'Medio' "Con el estroboscopio no sostiene $Hz FPS (1 % bajo: $([int]$Measured.Low1))" 'Cada fotograma que no llega se ve repetido. Baja la calidad hasta sostener los Hz, o baja los Hz del monitor a los que sí sostiene.'
    }
    if ($tip -and $tip.Notes) { $out += New-JuicerFinding $area 'Info' 'De este juego' $tip.Notes }
    $out
}

# The tips for one game on this machine: reads the graphics card, the
# monitor and the last measurement.
# The main graphics card's vendor (the dedicated one if there are two), or ''.
function Get-JuicerMainGpuVendor {
    try {
        $t = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { Get-JuicerGpuTraits $_.Name })
        $main = @($t | Where-Object { $_.Discrete }) + @($t) | Select-Object -First 1
        if ($main) { return [string]$main.Vendor }
    } catch {
        Write-Verbose "Sin gráfica: $_"
    }
    ''
}

# NVIDIA Reflex, when the game turns it on with G-SYNC and VSync, caps the
# game at about Hz - Hz^2/3600 (180 -> 171) by itself, and the lower of the
# two caps wins: a manual rate above that is never reached. Win Juicer
# forces VSync in the driver profile under VRR when the cap is below the
# refresh, so that is the case for any rate up to the refresh. Returns the
# note (Spanish, for the user) or $null when it does not apply. A game counts
# when the table knows it has Reflex, or when its folder has the files of
# Reflex or of DLSS frame generation (which forces it): Tech, as
# Update-JuicerGameTech keeps it. Files mean the game is capable, not that it
# is on, and without them nothing is known, so the note says so.
# The cap is rounded down, the same way Get-JuicerFpsCap does it.
function Get-JuicerReflexCapNote {
    param([string]$ExeName, [int]$Fps, [int]$Hz, [string]$Use, [string]$GpuVendor, [hashtable]$Tech)
    if ($GpuVendor -ne 'NVIDIA' -or $Use -notin 'VRR', 'EstroboSync' -or $Hz -le 0 -or $Fps -le 0) { return $null }
    $tip = Find-JuicerGameTip $ExeName
    $byTable = [bool]($tip -and $tip.Reflex)
    $byFiles = [bool]($Tech -and ($Tech.Reflex -or $Tech.DlssFG))
    if (-not ($byTable -or $byFiles)) { return $null }
    $cap = Get-JuicerVrrCap $Hz
    if ($Fps -le $cap -or $Fps -gt $Hz) { return $null }
    $lead = if ($byTable) { 'Con NVIDIA Reflex activado en el juego y G-SYNC' } else { 'La carpeta de este juego trae los archivos de NVIDIA Reflex (puede usarlo); si lo tienes activado en el juego y usas G-SYNC' }
    "$lead, el propio juego se queda en $cap FPS: es el tope de Reflex para tus $Hz Hz y manda el más bajo. Es también lo recomendado. Para pasar de ahí tendrías que apagar Reflex en el juego (pierdes latencia)."
}

# Measuring a game that has frame generation while RivaTuner paces it: RivaTuner
# limits the frames the game presents and fights the generation, so the numbers
# say little. Said before measuring, from what the folder shows (a game with
# the files may have it off, and one without them may have it built in, so it
# is worded as «may»). Null when it does not apply. Backend is the engine
# in use.
function Get-JuicerFrameGenMeasureWarning {
    param([string]$ExeName, [string]$Backend = (Get-JuicerFpsBackend))
    if ($Backend -ne 'rtss' -or -not $ExeName) { return $null }
    $fg = Get-JuicerFrameGenName (Get-JuicerGameTech (ConvertTo-JuicerExeName $ExeName))
    if (-not $fg) { return $null }
    "La carpeta de este juego trae los archivos de $fg y RivaTuner es el motor del frame pacer. Si usas la generación de fotogramas, RivaTuner limita los que el juego presenta y se pelea con ella: la medida puede salir con tirones que no son del juego. Para medir con fiabilidad, elige el driver de NVIDIA como motor, o usa el limitador del propio juego."
}

# The note for the rate stored by hand for this game, on this PC.
function Get-JuicerReflexCapNoteHere {
    param([Parameter(Mandatory)][string]$ExeName, [hashtable]$Monitor)
    $manual = Get-JuicerPacerFps $ExeName
    if ($manual -le 0) { return $null }
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-Verbose "Sin monitor: $_" } }
    if (-not $Monitor -or -not $Monitor.Display) { return $null }
    Get-JuicerReflexCapNote $ExeName $manual ([int]$Monitor.Display.Hz) (Resolve-JuicerMonitorUse $Monitor) (Get-JuicerMainGpuVendor) (Get-JuicerGameTech $ExeName)
}

function Get-JuicerGameTipsHere {
    param([Parameter(Mandatory)][hashtable]$Game)
    $vendor = Get-JuicerMainGpuVendor
    $m = $null
    try { $m = Get-JuicerPrimaryMonitor } catch { Write-Verbose "Sin monitor: $_" }
    # What the game's folder and its own settings say: looked at here, in the background, never on the screen's thread.
    $tech = $null
    try { $tech = Update-JuicerGameTech $Game } catch { Write-Verbose "Sin carpeta del juego: $_" }
    $unreal = $null
    try { $unreal = Get-JuicerUnrealLimit $(if ($Game.Exe) { [string]$Game.Exe } else { [string]$Game.ExeName }) } catch { Write-Verbose "Sin ajustes del juego: $_" }
    $wj = 0
    if ($Game.Fps) { $wj = [int]$Game.Fps } else { try { $r = Get-JuicerRecommendedFps ([string]$Game.ExeName) $m; if ($r) { $wj = [int]$r.Fps } } catch { Write-Verbose "Sin ritmo: $_" } }
    Get-JuicerGameTips -ExeName $Game.ExeName -Title $Game.Name -GpuVendor $vendor -Use (Resolve-JuicerMonitorUse $m) -Measured (Get-JuicerPreviousFrameResult $Game.ExeName) -Hz $(if ($m) { [int]$m.Display.Hz } else { 0 }) -Tech $tech -UnrealLimit $unreal -WjFps $wj
}
