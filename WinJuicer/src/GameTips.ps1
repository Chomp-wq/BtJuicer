# What to set inside each game, for this graphics card, this monitor and how
# it is used, and what the last measurement of that game said limits it.
# Win Juicer cannot change a game's own options, so these are the steps;
# they complete what it sets from outside (the FPS cap, the NVIDIA profile).
#
# The table only states what is known for sure of each game: whether it has
# NVIDIA Reflex or AMD Anti-Lag 2, and the odd fact that changes the advice
# (Elden Ring is capped at 60 FPS by the game itself). The rest comes from
# the hardware and applies to any game.

$script:GameTips = @(
    @{ P = '^cs2\.exe$'; Name = 'Counter-Strike 2'; Reflex = $true; AntiLag2 = $true }
    @{ P = '^valorant-win64-shipping\.exe$'; Name = 'VALORANT'; Reflex = $true }
    @{ P = '^fortniteclient-win64-shipping'; Name = 'Fortnite'; Reflex = $true; Notes = 'Con un procesador o una gráfica modestos, el modo de renderizado «Rendimiento» da muchos más FPS a cambio de calidad; con hardware actual, DirectX 12.' }
    @{ P = '^r5apex(_dx12)?\.exe$'; Name = 'Apex Legends'; Reflex = $true }
    @{ P = '^overwatch\.exe$'; Name = 'Overwatch 2'; Reflex = $true }
    @{ P = '^(cod|modernwarfare|blackopscoldwar|vanguard)\.exe$'; Name = 'Call of Duty'; Reflex = $true }
    @{ P = '^rainbowsix(_vulkan|_dx12)?(_be)?\.exe$'; Name = 'Rainbow Six Siege'; Reflex = $true }
    @{ P = '^marvel-win64-shipping\.exe$'; Name = 'Marvel Rivals'; Reflex = $true }
    @{ P = '^discovery\.exe$'; Name = 'THE FINALS'; Reflex = $true }
    @{ P = '^tslgame\.exe$'; Name = 'PUBG: BATTLEGROUNDS'; Reflex = $true }
    @{ P = '^cyberpunk2077\.exe$'; Name = 'Cyberpunk 2077'; Reflex = $true }
    @{ P = '^ghostoftsushima\.exe$'; Name = 'Ghost of Tsushima'; Reflex = $true; AntiLag2 = $true }
    @{ P = '^eldenring\.exe$'; Name = 'Elden Ring'; Cap60 = $true; Notes = 'El propio juego no pasa de 60 FPS: con una pantalla de más Hz, la frecuencia variable es lo que evita los tirones.' }
    @{ P = '^league of legends\.exe$'; Name = 'League of Legends'; Notes = 'No tiene Reflex: su limitador de FPS propio, si lo usas, a la misma cifra que el de Win Juicer.' }
    @{ P = '^rocketleague\.exe$'; Name = 'Rocket League' }
)

function Find-JuicerGameTip {
    param([string]$ExeName)
    foreach ($t in $script:GameTips) { if ($ExeName -match $t.P) { return $t } }
    $null
}

# Use is how the monitor is used (VRR, Estrobo, EstroboSync, Fijo);
# Measured, the last measurement of this game (GpuBound, AvgFps, Low1).
function Get-JuicerGameTips {
    param([Parameter(Mandatory)][string]$ExeName, [string]$Title = '', [string]$GpuVendor = '', [string]$Use = 'Fijo', [hashtable]$Measured, [int]$Hz)
    $tip = Find-JuicerGameTip $ExeName
    $name = if ($tip) { $tip.Name } elseif ($Title) { $Title } else { $ExeName }
    $area = "Consejos: $name"
    $out = @()
    $cpuBound = $Measured -and $null -ne $Measured.GpuBound -and $Measured.GpuBound -lt 50
    $gpuBound = $Measured -and $null -ne $Measured.GpuBound -and $Measured.GpuBound -ge 80

    # Latency: what the game offers for it.
    if ($GpuVendor -eq 'NVIDIA') {
        if ($tip -and $tip.Reflex) {
            $boost = if ($cpuBound) { '«Activado + Boost»: tu medida dice que el procesador limita, y Boost mantiene la gráfica a tope de frecuencia para que no pierda tiempo' } else { '«Activado» (o «Activado + Boost» si notas que el procesador limita)' }
            $out += New-JuicerFinding $area 'Info' 'NVIDIA Reflex: actívalo' "En las opciones de vídeo, NVIDIA Reflex Low Latency $boost. Con Reflex activo, el límite de FPS del driver que pone Win Juicer se aplica a través de él, y el «Modo de baja latencia» del panel deja de importar."
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
    } elseif ($GpuVendor -eq 'NVIDIA' -and $tip -and $tip.Reflex) {
        $out += New-JuicerFinding $area 'Info' 'El limitador de FPS del juego: desactivado' 'El del driver ya va a través de Reflex con la menor latencia; dos limitadores con cifras distintas sólo suman irregularidad.'
    } else {
        $out += New-JuicerFinding $area 'Info' 'El limitador de FPS del juego: el suyo o el de Win Juicer, no los dos' 'Si el juego tiene limitador propio, puedes usarlo a la misma cifra en lugar del de Win Juicer: suele dar algo menos de latencia, y el de Win Juicer frametimes más planos. Nunca los dos con cifras distintas.'
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
function Get-JuicerGameTipsHere {
    param([Parameter(Mandatory)][hashtable]$Game)
    $vendor = ''
    try {
        $t = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { Get-JuicerGpuTraits $_.Name })
        $main = @($t | Where-Object { $_.Discrete }) + @($t) | Select-Object -First 1
        if ($main) { $vendor = $main.Vendor }
    } catch {
        Write-Verbose "Sin gráfica: $_"
    }
    $m = $null
    try { $m = Get-JuicerPrimaryMonitor } catch { Write-Verbose "Sin monitor: $_" }
    Get-JuicerGameTips -ExeName $Game.ExeName -Title $Game.Name -GpuVendor $vendor -Use (Resolve-JuicerMonitorUse $m) -Measured (Get-JuicerPreviousFrameResult $Game.ExeName) -Hz $(if ($m) { [int]$m.Display.Hz } else { 0 })
}
