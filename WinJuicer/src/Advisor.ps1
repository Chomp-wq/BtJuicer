# The advisor: which tweaks suit this machine, from what it is made of. A
# desktop has no battery to save, a laptop does; a dual-CCD X3D needs the
# Balanced plan that everyone else is better off without; with a hard disk
# the indexer competes with everything, with an SSD it does not matter. Each
# verdict comes with its reason, and none of them changes anything: they
# only decide what «Recomendado para este equipo» selects.
#
# Recomendado     worth applying here.
# Opcional        depends on how you use the PC; read the cost.
# NoRecomendado   on this machine it costs more than it gives, or does nothing.

function New-JuicerVerdict {
    param([string]$Verdict, [string]$Reason)
    @{ Verdict = $Verdict; Reason = $Reason }
}

function Test-JuicerAnyGpu {
    param([hashtable]$Hw, [scriptblock]$Where)
    @($Hw.Gpus | Where-Object $Where).Count -gt 0
}

# One rule per tweak that depends on the hardware. Tweaks without a rule
# follow their level: Seguro is recommended, the rest optional.
function Get-JuicerAdviceRule {
    param([string]$Id, [hashtable]$Hw)
    $c = $Hw.Cpu
    $ramGb = [Math]::Round($Hw.RamBytes / 1GB)
    $discrete = Test-JuicerAnyGpu $Hw { $_.Discrete }
    $hdd = $Hw.SystemDisk -and $Hw.SystemDisk.Media -eq 'HDD'
    $modest = -not $discrete -or ($c.Threads -gt 0 -and $c.Threads -le 4) -or ($ramGb -gt 0 -and $ramGb -le 8)
    switch ($Id) {
        'energia.plan' {
            if ($c.DualCcdX3D) { return New-JuicerVerdict 'NoRecomendado' "Tu $($c.Name) necesita el plan Equilibrado para aparcar el CCD sin 3D V-Cache." }
            if ($Hw.Laptop) { return New-JuicerVerdict 'NoRecomendado' 'En un portátil cuesta batería y temperatura; usa el modo de energía de Windows o el del fabricante.' }
            return New-JuicerVerdict 'Recomendado' 'Sobremesa: no hay batería que cuidar, y mejora los mínimos de FPS.'
        }
        'energia.modo' {
            if ($Hw.ModernStandby) { return New-JuicerVerdict 'Recomendado' 'Tu equipo usa Modern Standby: es el único control de rendimiento que Windows respeta. Aplícalo enchufado.' }
            return New-JuicerVerdict 'NoRecomendado' 'Sólo sirve en equipos con Modern Standby; en el tuyo manda el plan de energía.'
        }
        'energia.limitacion' {
            if ($Hw.Laptop) { return New-JuicerVerdict 'Opcional' 'En portátil cuesta batería: sólo si juegas enchufado con OBS o Discord a la vista.' }
            if ($c.Hybrid) { return New-JuicerVerdict 'Recomendado' 'Procesador híbrido: evita que OBS, Discord o el navegador acaben en los núcleos de eficiencia mientras juegas.' }
            return New-JuicerVerdict 'Recomendado' 'Sobremesa: no cuesta batería.'
        }
        'juegos.modo' {
            if ($c.DualCcdX3D) { return New-JuicerVerdict 'Recomendado' "Imprescindible en tu $($c.Name): el reparto entre CCD depende de él." }
        }
        'juegos.hags' {
            if (Test-JuicerAnyGpu $Hw { $_.FrameGen }) { return New-JuicerVerdict 'Recomendado' 'Tu gráfica RTX 40 o posterior lo necesita para la generación de fotogramas de DLSS.' }
            if (Test-JuicerAnyGpu $Hw { $_.Discrete -and $_.Hags -eq $true }) { return New-JuicerVerdict 'Recomendado' 'Tu gráfica lo admite: algo menos de carga en el procesador.' }
            if ($discrete -and -not (Test-JuicerAnyGpu $Hw { $_.Discrete -and $_.Hags -ne $false })) { return New-JuicerVerdict 'NoRecomendado' 'Tu gráfica no lo admite: Windows lo ignoraría.' }
            if (-not $discrete -and @($Hw.Gpus).Count -gt 0) { return New-JuicerVerdict 'Opcional' 'Con gráfica integrada apenas se nota.' }
        }
        'juegos.grabacion' {
            if (-not $Hw.Laptop -or $discrete) { return New-JuicerVerdict 'Recomendado' 'La grabación continua cuesta FPS aunque nunca guardes un clip; NVIDIA, AMD y OBS graban mejor.' }
            return New-JuicerVerdict 'Recomendado' 'Sin gráfica dedicada, codificar vídeo todo el rato pesa todavía más.'
        }
        'juegos.raton' {
            return New-JuicerVerdict 'Opcional' 'Si juegas a shooters o a cualquier cosa de puntería, sí: el mismo gesto, el mismo giro. En el escritorio quizá subas la velocidad del puntero.'
        }
        'juegos.teclas' {
            return New-JuicerVerdict 'Recomendado' 'Nada que perder: la accesibilidad sigue en Configuración; sólo desaparece el atajo que saca del juego al pulsar Mayús cinco veces.'
        }
        'ui.animaciones' {
            if ($modest) { return New-JuicerVerdict 'Recomendado' 'Equipo modesto: aquí se nota.' }
            return New-JuicerVerdict 'Opcional' 'Con tu equipo no da FPS: sólo hace que Windows responda antes. Cuestión de gusto.'
        }
        'ui.transparencia' {
            if (-not $discrete -and @($Hw.Gpus).Count -gt 0) { return New-JuicerVerdict 'Recomendado' 'Gráfica integrada: la transparencia le quita trabajo útil.' }
            return New-JuicerVerdict 'Opcional' 'Tu gráfica dedicada ni lo nota: es sólo estética.'
        }
        'ui.menu' {
            return New-JuicerVerdict 'Opcional' 'Cuestión de gusto. Si el clic derecho tarda en abrirse, el clásico es instantáneo.'
        }
        'ui.busqueda' {
            return New-JuicerVerdict 'Opcional' 'Si nunca buscas en la web desde Inicio, sólo ganas: la búsqueda deja de esperar a internet.'
        }
        'ui.widgets' {
            if ($ramGb -gt 0 -and $ramGb -le 16) { return New-JuicerVerdict 'Recomendado' "Con $ramGb GB de RAM, liberar 100-300 MB se nota." }
            return New-JuicerVerdict 'Opcional' "Con $ramGb GB de RAM no te falta memoria: quítalos si no los miras."
        }
        'fondo.apps' {
            if ($ramGb -gt 0 -and $ramGb -le 8) { return New-JuicerVerdict 'Recomendado' "Con $ramGb GB de RAM, cada proceso de fondo cuenta." }
            return New-JuicerVerdict 'Opcional' 'Con RAM de sobra sólo compensa si no usas apps de la Tienda que te avisan con la ventana cerrada (Enlace Móvil, WhatsApp, Correo).'
        }
        'fondo.recall' {
            return New-JuicerVerdict 'Opcional' 'Sólo hace algo en los PC Copilot+ con Recall activado; en el resto no cambia nada.'
        }
        'fondo.servicios' {
            if ($modest) { return New-JuicerVerdict 'Recomendado' 'Equipo modesto: dos procesos menos desde el arranque, sin romper nada habitual.' }
            return New-JuicerVerdict 'Opcional' 'Ganancia pequeña en tu equipo, aunque tampoco rompe nada habitual.'
        }
        'fondo.telemetria' {
            if ($Hw.Insider) { return New-JuicerVerdict 'NoRecomendado' 'Estás en Windows Insider, que lo necesita.' }
        }
        'fondo.indexado' {
            if ($hdd) { return New-JuicerVerdict 'Recomendado' 'Tu Windows está en un disco duro mecánico: el indexador compite con todo lo demás por el disco.' }
            return New-JuicerVerdict 'NoRecomendado' 'Con SSD el indexador apenas consume, y la búsqueda se volvería lenta.'
        }
        'fondo.impresion' {
            if (@($Hw.Printers).Count -eq 0) { return New-JuicerVerdict 'Recomendado' 'No tienes impresoras instaladas.' }
            return New-JuicerVerdict 'NoRecomendado' "Tienes impresora: $(@($Hw.Printers) -join ', ')."
        }
        'fondo.edge' {
            if ($Hw.Edge -and $ramGb -gt 0 -and $ramGb -le 16) { return New-JuicerVerdict 'Recomendado' "Con $ramGb GB de RAM, que Edge no esté cargado sin usarlo se nota." }
            return New-JuicerVerdict 'Opcional' 'Si no usas Edge, ganas memoria sin perder nada; si es tu navegador, abrirá un poco más despacio.'
        }
        'disco.ultimoacceso' {
            if ($hdd) { return New-JuicerVerdict 'Recomendado' 'Con disco duro mecánico, cada escritura de menos cuenta.' }
            return New-JuicerVerdict 'Opcional' 'Con SSD la diferencia es mínima.'
        }
        'disco.nombres83' {
            if ($hdd) { return New-JuicerVerdict 'Recomendado' 'Con disco duro mecánico, crear archivos sale más caro.' }
            return New-JuicerVerdict 'Opcional' 'Con SSD la diferencia es mínima; ayuda algo con juegos de miles de archivos pequeños.'
        }
        'red.nagle' {
            return New-JuicerVerdict 'Opcional' 'Sólo cambia algo en juegos que usan TCP, como los MMO (World of Warcraft, Final Fantasy XIV). Los shooters usan UDP.'
        }
        'privacidad.consumidor' {
            return New-JuicerVerdict 'Opcional' 'Si el software de tus periféricos lo instalas tú, no pierdes nada.'
        }
        'privacidad.copilot' {
            return New-JuicerVerdict 'Opcional' 'Si no usas Copilot, nada que perder. La app, si la tienes, se quita en Debloat.'
        }
        'update.reinicio' {
            if (-not $Hw.Laptop) { return New-JuicerVerdict 'Recomendado' 'En un sobremesa que se queda encendido, evita perder una descarga o una partida por un reinicio nocturno. Reinicia tú de vez en cuando.' }
            return New-JuicerVerdict 'Opcional' 'Evita reinicios con trabajo abierto; a cambio, acuérdate de reiniciar tú.'
        }
        'privacidad.ubicacion' {
            if ($Hw.Laptop) { return New-JuicerVerdict 'Opcional' 'En un portátil, «Buscar mi dispositivo» y la hora automática por ubicación pueden venirte bien.' }
            return New-JuicerVerdict 'Recomendado' 'Un sobremesa no se mueve: la ubicación no le sirve de nada.'
        }
        'privacidad.telemetria' {
            if ($Hw.Insider) { return New-JuicerVerdict 'NoRecomendado' 'Estás en Windows Insider, que necesita los datos de diagnóstico.' }
            return New-JuicerVerdict 'Recomendado' 'Quita los picos de disco y CPU de CompatTelRunner.'
        }
        'update.drivers' {
            if ($discrete) { return New-JuicerVerdict 'Recomendado' 'Tienes gráfica dedicada: que Windows Update no sustituya el driver que instalaste del fabricante.' }
            return New-JuicerVerdict 'Opcional' 'Con gráfica integrada, Windows Update suele traer el driver correcto: mejor dejarlo.'
        }
        'update.diferir' {
            if ($Hw.Home) { return New-JuicerVerdict 'NoRecomendado' 'Windows Home lo ignora.' }
            $s = $Hw.Support
            if ($s -and ($s.Windows10 -or ($s.End - (Get-Date)).TotalDays -lt 180)) {
                return New-JuicerVerdict 'NoRecomendado' ('Tu versión ({0}) deja de recibir parches el {1}: lo que toca es instalar la siguiente, no retrasarla.' -f $s.Version, $s.End.ToString('d'))
            }
            if ($s -and -not $s.Business) { return New-JuicerVerdict 'Opcional' 'Estabilidad a cambio de recibir las novedades un año más tarde. En Pro cada versión tiene dos años de parches, así que con el retraso llegas justo al final: la revisión avisa cuando queden menos de 90 días.' }
            return New-JuicerVerdict 'Opcional' 'Estabilidad a cambio de recibir las novedades de Windows un año más tarde. Los parches de seguridad siguen llegando.'
        }
        'seguridad.integridad' {
            if (-not $Hw.Laptop -and $discrete) { return New-JuicerVerdict 'Opcional' 'Equipo de juego: ganas rendimiento, pierdes una protección del núcleo. Decide tú.' }
            return New-JuicerVerdict 'NoRecomendado' 'En este equipo la seguridad pesa más que la ganancia.'
        }
        'seguridad.hipervisor' {
            if ($Hw.Wsl -or $Hw.Docker) { return New-JuicerVerdict 'NoRecomendado' 'Usas WSL o Docker, que lo necesitan.' }
            return New-JuicerVerdict 'Opcional' 'Sólo si no usas WSL 2, Hyper-V, Sandbox ni Docker.'
        }
        'apps.onedrive' {
            if ($Hw.OneDrive.Kfm) { return New-JuicerVerdict 'NoRecomendado' 'Tus carpetas están dentro de OneDrive.' }
            if ($Hw.OneDrive.SignedIn) { return New-JuicerVerdict 'Opcional' 'Tienes la sesión iniciada: si lo usas para copias, déjalo.' }
            if ($Hw.OneDrive.Installed) { return New-JuicerVerdict 'Recomendado' 'Está instalado pero sin cuenta: arranca con Windows para nada.' }
        }
    }
    $null
}

function Get-JuicerAdvice {
    param([Parameter(Mandatory)][hashtable]$Hw, [object[]]$Tweaks)
    if (-not $Tweaks) { $Tweaks = @(Get-JuicerCatalog) }
    $advice = @{}
    foreach ($t in $Tweaks) {
        $v = Get-JuicerAdviceRule $t.Id $Hw
        if (-not $v) {
            $v = switch ([int]$t.Level) {
                1 { New-JuicerVerdict 'Recomendado' 'No cuesta nada a nadie.' }
                3 { New-JuicerVerdict 'Opcional' 'Extremo: lee qué pierdes.' }
                0 { New-JuicerVerdict 'Opcional' 'A tu gusto.' }
                default { New-JuicerVerdict 'Opcional' 'Depende de cómo uses el equipo: lee qué cuesta.' }
            }
        }
        $advice[$t.Id] = $v
    }
    $advice
}

# What «Recomendado para este equipo» selects: catalog tweaks recommended
# here. Nothing à la carte: tastes, parts of Windows and uninstalling
# OneDrive are only done when picked one by one.
function Get-JuicerRecommendedTweaks {
    param([Parameter(Mandatory)][hashtable]$Hw)
    $advice = Get-JuicerAdvice $Hw
    @(Get-JuicerCatalog | Where-Object { $_.Level -ge 1 -and $advice[$_.Id].Verdict -eq 'Recomendado' })
}
