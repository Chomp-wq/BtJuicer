# From the analysis to advice. Two kinds come out of here: findings, about what
# no tool can change (RAM without XMP, a monitor left at 60 Hz, a game library
# on a hard disk), and a verdict on every tweak for this particular machine.
# Everything here reads only the profile, never the machine, so any scenario can
# be tested with a made-up one.

$script:SeverityOrder = @{ Alto = 0; Medio = 1; Bajo = 2; Info = 3; Ok = 4 }
$script:VerdictOrder = @('Recomendado', 'Opcional', 'NoRecomendado', 'NoAplica')

function New-JuicerFinding {
    param([string]$Area, [string]$Severity, [string]$Title, [string]$Detail = '', [string]$Fix = '')
    @{ Area = $Area; Severity = $Severity; Title = $Title; Detail = $Detail; Fix = $Fix }
}

function New-JuicerAdvice {
    param([Parameter(Mandatory)][ValidateSet('Recomendado', 'Opcional', 'NoRecomendado', 'NoAplica')][string]$Verdict, [string]$Why = '', [string]$Impact = '')
    @{ Verdict = $Verdict; Why = $Why; Impact = $Impact }
}

function Format-JuicerBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

function Join-JuicerNames {
    param([object[]]$Names)
    $n = @($Names | Where-Object { $_ })
    if ($n.Count -le 1) { return ($n -join '') }
    (($n[0..($n.Count - 2)]) -join ', ') + ' y ' + $n[-1]
}

# --- Tweak verdicts ------------------------------------------------------------

# A tweak's Advice block looks at the profile and returns a verdict, or nothing
# to keep the default: level 1 recommended, everything else optional. Weakening
# security is never decided for anyone, so level 3 is at most optional.
function Get-JuicerTweakAdvice {
    param([Parameter(Mandatory)][hashtable]$Tweak, [hashtable]$System)
    $a = $null
    if ($Tweak.Advice -and $System) {
        try { $a = & $Tweak.Advice $System $Tweak } catch { Write-Verbose "Consejo de $($Tweak.Id) falló: $_"; $a = $null }
    }
    if (-not $a) { $a = New-JuicerAdvice $(if ($Tweak.Level -eq 1) { 'Recomendado' } else { 'Opcional' }) }
    if (-not $a.Why) { $a.Why = $Tweak.Gain }
    if (-not $a.Impact) { $a.Impact = $Tweak.Impact }
    if ($Tweak.Level -ge 3 -and $a.Verdict -eq 'Recomendado') { $a.Verdict = 'Opcional' }
    $a
}

# Tweaks that only exist because of what this machine has: one Defender
# exclusion per game library found.
function Get-JuicerSystemTweaks {
    param([hashtable]$System)
    if (-not $System -or -not $System.Games) { return @() }
    foreach ($lib in @($System.Games.Libraries)) { New-JuicerDefenderTweak $lib.Path $lib.Launcher }
}

function Get-JuicerPlan {
    param([Parameter(Mandatory)][hashtable]$System)
    $journal = Read-JuicerJournal
    $plan = @{ Recommended = @(); Optional = @(); NotRecommended = @(); NotApplicable = @(); Done = @(); Revert = @(); Startup = @() }
    $tweaks = @(Get-JuicerCatalog) + @(Get-JuicerSystemTweaks $System)
    foreach ($t in $tweaks) {
        $state = Get-JuicerTweakState $t $journal
        $advice = Get-JuicerTweakAdvice $t $System
        $e = @{ Tweak = $t; Advice = $advice; State = $state }
        if ($advice.Verdict -eq 'NoRecomendado' -and $state.Undoable) {
            # Something Win Juicer applied before that no longer suits this machine.
            $plan.Revert += $e
        } elseif ($state.State -in 'NoAplica', 'Error' -or $advice.Verdict -eq 'NoAplica') {
            if ($advice.Verdict -ne 'NoAplica' -and $state.Reason) { $advice.Why = $state.Reason }
            $plan.NotApplicable += $e
        } elseif ($advice.Verdict -eq 'NoRecomendado') {
            $plan.NotRecommended += $e
        } elseif ($state.State -eq 'Aplicado') {
            $plan.Done += $e
        } elseif ($advice.Verdict -eq 'Recomendado') {
            $plan.Recommended += $e
        } else {
            $plan.Optional += $e
        }
    }
    $plan.Startup = @($System.Startup | Where-Object { $_.Enabled -and $_.Advice -and $_.Advice.Suggest })
    $plan
}

# Fixed profiles, minus whatever the analysis says does not suit this machine.
function Get-JuicerFittedProfile {
    param([ValidateRange(1, 3)][int]$Level, [hashtable]$System)
    foreach ($t in (Get-JuicerProfile $Level)) {
        if ($System -and (Get-JuicerTweakAdvice $t $System).Verdict -in 'NoRecomendado', 'NoAplica') { continue }
        $t
    }
}

# --- Findings --------------------------------------------------------------------

function Get-JuicerRamFindings {
    param([hashtable]$Memory, [bool]$Laptop)
    $area = 'Memoria'
    $out = @()
    if (-not $Memory -or -not $Memory.ModuleCount) { return $out }
    if ($Memory.TotalBytes -gt 0 -and $Memory.TotalBytes -lt 15GB) {
        $out += New-JuicerFinding $area 'Bajo' 'Menos de 16 GB de RAM' 'Muchos juegos actuales piden 16 GB; con menos, Windows pagina a disco y aparecen tirones. Por eso el plan quita más cosas de segundo plano en este equipo.'
    }
    if ($Memory.SingleChannel) {
        if ($Laptop) {
            $out += New-JuicerFinding $area 'Medio' 'Un solo módulo de RAM: probablemente en canal simple' 'Con un solo canal la memoria tiene la mitad de ancho de banda; con gráfica integrada se nota mucho. Si tu portátil tiene una ranura libre, un segundo módulo igual lo arregla.'
        } else {
            $out += New-JuicerFinding $area 'Alto' 'Un solo módulo de RAM: canal simple' 'La memoria funciona con la mitad de ancho de banda. En juegos limitados por CPU, y sobre todo con gráfica integrada, es de las mayores pérdidas posibles. Añade un segundo módulo igual.'
        }
    } elseif ($Memory.SameChannel) {
        $out += New-JuicerFinding $area 'Alto' "Los dos módulos parecen estar en el mismo canal ($($Memory.Channels[0]))" 'Así trabajan como si fueran uno: mitad de ancho de banda. Muévelos a las ranuras que indica el manual de la placa, normalmente A2 y B2.'
    }
    if ($Memory.XmpLikelyOff) {
        $xmp = if ($Memory.Type -eq 34) { 'EXPO o XMP' } else { 'XMP (DOCP en ASUS con AMD)' }
        $label = if ($Memory.Type -eq 34) { 'DDR5-6000 o 6400' } else { 'DDR4-3200 o 3600' }
        $out += New-JuicerFinding $area 'Medio' "La RAM va a $($Memory.Speed) MT/s, la velocidad estándar" "Si tu kit es más rápido (mira la etiqueta: $label…), activa $xmp en la BIOS. En juegos limitados por CPU suele ser la mejora gratuita más grande que queda."
    }
    $out
}

function Get-JuicerDisplayFindings {
    param([object[]]$Displays)
    $out = @()
    $n = 0
    foreach ($d in $Displays) {
        $n++
        $name = if ($d.Monitor) { $d.Monitor } else { "Pantalla $n" }
        if ($d.MaxHz -gt $d.Hz + 1) {
            $out += New-JuicerFinding 'Pantalla' 'Alto' "$name funciona a $($d.Hz) Hz pero admite $($d.MaxHz) Hz" 'Cámbialo en Configuración > Sistema > Pantalla > Pantalla avanzada > Frecuencia de actualización. Si no aparece, el cable o el puerto no dan para más (usa DisplayPort o HDMI 2.1).'
        } else {
            $out += New-JuicerFinding 'Pantalla' 'Ok' "$name a $($d.Width)×$($d.Height) y $($d.Hz) Hz, el máximo disponible"
        }
    }
    $out
}

function Get-JuicerFindings {
    param([Parameter(Mandatory)][hashtable]$System)
    $s = $System
    $out = New-Object System.Collections.ArrayList
    $add = { param($Area, $Sev, $Title, $Detail) [void]$out.Add((New-JuicerFinding $Area $Sev $Title $Detail)) }

    # Windows and the session
    if ($s.Os) {
        if ($s.Os.ElevatedAs -and $s.Os.SessionUser -and $s.Os.ElevatedAs -ne $s.Os.SessionUser) {
            & $add 'Sistema' 'Alto' "Win Juicer corre como $($s.Os.ElevatedAs), pero la sesión es de $($s.Os.SessionUser)" 'Los ajustes de usuario (ratón, animaciones, Game Bar…) se aplicarían a la cuenta de administrador, no a la tuya. Inicia sesión con tu cuenta y dale permisos de administrador.'
        }
        if ($s.Os.PendingReboot) {
            & $add 'Sistema' 'Medio' 'Windows tiene una actualización a medias' 'Hasta que reinicies, parte del sistema trabaja con archivos viejos y nuevos a la vez. Reinicia antes de medir nada.'
        }
        if ($s.Os.UptimeDays -gt 7 -and $s.Power -and $s.Power.FastStartup) {
            & $add 'Sistema' 'Bajo' "Lleva $([int]$s.Os.UptimeDays) días sin reiniciar de verdad" 'Con el inicio rápido, «Apagar» no reinicia el núcleo: drivers con fugas de memoria siguen arrastrándolas. Usa «Reiniciar» de vez en cuando.'
        }
        if ($s.Os.Build -and -not $s.Os.IsWin11) {
            & $add 'Sistema' 'Info' 'Win Juicer está pensado para Windows 11' 'Casi todo funciona también en Windows 10; lo que no aplica aparece como «no aplica».'
        }
    }

    # Power and battery
    if ($s.Device -and $s.Device.OnBattery) {
        & $add 'Energía' 'Alto' 'Estás funcionando con batería' 'Con batería, el portátil limita procesador y gráfica aunque elijas el máximo rendimiento. Para jugar, conecta el cargador.'
    }
    if ($s.Device -and $s.Device.BatteryHealth -and $s.Device.BatteryHealth -lt 60) {
        & $add 'Energía' 'Bajo' "La batería retiene un $($s.Device.BatteryHealth) % de su capacidad original" 'Con una batería gastada, muchos portátiles bajan el rendimiento al desenchufarlos antes de tiempo.'
    }

    # Processor
    if ($s.Cpu -and $s.Cpu.Name) {
        if ($s.Cpu.DualCcdX3D) {
            if ($s.Software -and -not $s.Software.VCacheDriver) {
                & $add 'Procesador' 'Alto' "Falta el driver 3D V-Cache de tu $($s.Cpu.Name)" 'Sin él, Windows reparte los juegos entre los dos CCD y la mitad del tiempo corren en el que no tiene la caché 3D. Instala el driver de chipset de AMD más reciente.'
            }
            if ($s.Software -and -not $s.Software.GameBar) {
                & $add 'Procesador' 'Alto' 'Falta Xbox Game Bar' 'El driver de AMD la usa para saber qué es un juego y llevarlo al CCD con caché 3D. Reinstálala desde Microsoft Store, aunque no la abras nunca.'
            }
        }
        if ($s.Cpu.Hybrid -and $s.Os -and $s.Os.Build -and -not $s.Os.IsWin11) {
            & $add 'Procesador' 'Medio' "Tu $($s.Cpu.Name) tiene núcleos P y E, y Windows 10 no los distingue bien" 'Windows 11 usa Thread Director para mandar el juego a los núcleos de rendimiento; en Windows 10 a veces acaba en los de eficiencia.'
        }
    }

    # Memory
    if ($s.Memory) {
        foreach ($x in (Get-JuicerRamFindings $s.Memory ([bool]($s.Device -and $s.Device.Laptop)))) { [void]$out.Add($x) }
        if ($s.Storage -and $s.Storage.Volumes) {
            $ssd = @($s.Storage.Volumes | Where-Object { $_.Media -eq 'SSD' })
            foreach ($pf in @($s.Memory.PageFiles)) {
                $v = Find-JuicerVolume $s.Storage.Volumes $pf.Path
                if ($v -and $v.Media -eq 'HDD' -and $ssd.Count -gt 0) {
                    & $add 'Memoria' 'Medio' "El archivo de paginación está en un disco duro ($($v.Letter):)" "Cuando la RAM no llega, cada página va a ese disco. Muévelo a $($ssd[0].Letter): (SSD) en Sistema > Configuración avanzada > Rendimiento > Memoria virtual."
                }
            }
        }
    }

    # Graphics and displays
    if ($s.Graphics) {
        $g = $s.Graphics
        if ($g.VirtualOnly -and -not ($s.Os -and $s.Os.IsServer)) {
            & $add 'Gráfica' 'Alto' 'No hay driver de la tarjeta gráfica' 'Windows usa el adaptador básico, sin aceleración. Instala el driver de NVIDIA, AMD o Intel desde su web.'
        }
        foreach ($gpu in @($g.Gpus)) {
            if ($gpu.DriverAgeDays -gt 365 -and $gpu.Kind -eq 'Dedicada') {
                & $add 'Gráfica' 'Medio' "El driver de $($gpu.Name) tiene más de un año" 'Los drivers nuevos traen optimizaciones para juegos recientes. Descárgalo de la web del fabricante.'
            }
        }
        $integrated = @($g.Gpus | Where-Object { $_.Kind -eq 'Integrada' })
        $dedicated = @($g.Gpus | Where-Object { $_.Kind -eq 'Dedicada' })
        if ($g.Hybrid -and $s.Device -and $s.Device.Laptop) {
            & $add 'Gráfica' 'Medio' "Portátil con dos gráficas: $($integrated[0].Name) y $($dedicated[0].Name)" 'Windows decide en cada juego cuál usar y a veces elige la integrada. Fíjalo por juego en Juegos > Configurar un juego, o activa el modo «sólo GPU dedicada» (MUX) en la app de tu fabricante: Armoury Crate, Lenovo Vantage, Omen Gaming Hub…'
        } elseif ($g.Hybrid) {
            & $add 'Gráfica' 'Bajo' "La gráfica integrada está activa junto a la $($dedicated[0].Name)" 'Comprueba que el monitor está conectado a la tarjeta gráfica y no a la placa base: es un error muy común y lo cambia todo.'
        }
        if ($integrated.Count -gt 0 -and $dedicated.Count -eq 0 -and $integrated[0].Vendor -eq 'AMD' -and $s.Memory -and $s.Memory.TotalBytes -ge 15GB) {
            & $add 'Gráfica' 'Bajo' "Tu $($integrated[0].Name) toma la memoria de vídeo de la RAM" 'Si la BIOS lo permite, sube «UMA Frame Buffer Size» a 2–4 GB: hay juegos que rinden peor, o no arrancan, con la reserva mínima.'
        }
        if ($g.Rebar -eq $false) {
            $old = $s.Device -and $s.Device.BiosDate -and ((Get-Date) - $s.Device.BiosDate).TotalDays -gt 1095
            $extra = if ($old) { ' Tu BIOS tiene más de tres años: si no encuentras la opción, actualízala.' } else { '' }
            & $add 'Gráfica' 'Medio' 'Resizable BAR desactivado' ("Actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support»). NVIDIA lo usa juego a juego: según el título, de nada a un 10 %." + $extra)
        } elseif ($g.Rebar -eq $true) {
            & $add 'Gráfica' 'Ok' 'Resizable BAR activado'
        }
        foreach ($x in (Get-JuicerDisplayFindings @($g.Displays))) { [void]$out.Add($x) }
    }

    # Storage and game libraries
    if ($s.Storage) {
        $sd = $s.Storage.SystemDrive
        if ($sd) {
            $where = ('{0} ({1}, {2})' -f $sd.Disk, $sd.Media, $sd.Bus)
            if ($sd.Media -eq 'HDD') {
                & $add 'Disco' 'Alto' "Windows está en un disco duro mecánico: $where" 'Es el mayor freno posible para el arranque y las cargas, y ningún ajuste lo compensa. Un SSD, aunque sea SATA, lo cambia todo.'
            }
            if ($sd.SizeBytes -gt 0) {
                $pct = 100 * $sd.FreeBytes / $sd.SizeBytes
                $free = '{0} libres de {1} ({2:N0} %)' -f (Format-JuicerBytes $sd.FreeBytes), (Format-JuicerBytes $sd.SizeBytes), $pct
                if ($sd.FreeBytes -lt 20GB -or $pct -lt 10) {
                    & $add 'Disco' 'Alto' "Queda poco espacio en $($sd.Letter): $free" 'Un SSD casi lleno escribe mucho más lento, y Windows necesita sitio para la paginación y las actualizaciones. Usa Mantenimiento > Limpieza, o mueve juegos a otra unidad.'
                } elseif ($pct -lt 20) {
                    & $add 'Disco' 'Medio' "Espacio justo en $($sd.Letter): $free" 'Por debajo de un 20 % libre, los SSD empiezan a perder velocidad de escritura.'
                }
            }
        }
        foreach ($d in @($s.Storage.Disks | Where-Object { $_.Health -and $_.Health -ne 'Healthy' })) {
            & $add 'Disco' 'Alto' "El disco $($d.Name) informa de un estado «$($d.Health)»" 'Haz copia de seguridad cuanto antes; un disco que falla también se vuelve lento.'
        }
    }
    if ($s.Games) {
        foreach ($lib in @($s.Games.Libraries)) {
            if ($lib.Media -eq 'HDD') {
                & $add 'Disco' 'Alto' "Biblioteca de $($lib.Launcher) en disco duro mecánico: $($lib.Path)" 'Es lo que más alarga las pantallas de carga. Muévela a un SSD; Steam, Epic y Xbox permiten mover juegos sin volver a descargarlos.'
            } elseif ($lib.Bus -eq 'NVMe') {
                & $add 'Disco' 'Ok' "Biblioteca de $($lib.Launcher) en NVMe: $($lib.Path)" 'Lo mejor posible para cargas, y lo que necesitan los juegos con DirectStorage.'
            }
        }
    }

    # Network
    if ($s.Network -and $s.Network.Primary) {
        $p = $s.Network.Primary
        if ($p.Type -eq 'Wi-Fi') {
            & $add 'Red' 'Medio' "Te conectas por Wi-Fi ($($p.Description))" 'Para jugar online, un cable reduce la latencia y sobre todo los picos: el Wi-Fi tiene interferencias que se notan como tirones de red. Si no puedes cablear, usa la banda de 5 o 6 GHz.'
        } elseif ($p.SpeedBps -gt 0 -and $p.SpeedBps -le 100000000) {
            & $add 'Red' 'Medio' "Tu conexión por cable va a $([int]($p.SpeedBps / 1000000)) Mbps" 'Una tarjeta de 1 Gbps que negocia 100 Mbps casi siempre es un cable viejo o dañado (necesitas Cat5e o mejor) o un puerto del router. Las descargas de juegos van a ir lentas.'
        }
    }

    # Security software
    if ($s.Security) {
        if ($s.Security.DefenderActive -eq $false -and @($s.Security.OtherAv).Count -eq 0 -and -not ($s.Os -and $s.Os.IsServer)) {
            & $add 'Seguridad' 'Medio' 'No hay ningún antivirus activo' 'Win Juicer no quita protección para ganar rendimiento, y no conviene jugar sin ella: el coste de Defender en juegos se resuelve con exclusiones de la carpeta de juegos, no apagándolo.'
        } elseif (@($s.Security.OtherAv).Count -gt 0) {
            & $add 'Seguridad' 'Info' "Tu antivirus es $(Join-JuicerNames $s.Security.OtherAv)" 'Las exclusiones de Defender no aplican: si quieres cargas más rápidas, excluye la carpeta de juegos en tu antivirus.'
        }
    }

    # Boot and startup
    if ($s.Boot -and $s.Boot.LastMs) {
        $b = $s.Boot
        $sev = if ($b.LastMs -gt 90000) { 'Alto' } elseif ($b.LastMs -gt 45000) { 'Medio' } else { 'Ok' }
        & $add 'Arranque' $sev ('Último arranque completo: {0:N1} s' -f ($b.LastMs / 1000)) ('Hasta el escritorio {0:N1} s; después, {1:N1} s más cargando programas de inicio y servicios.' -f ($b.MainMs / 1000), ($b.PostMs / 1000))
        if ($b.PostMs -gt $b.MainMs -and $b.PostMs -gt 20000) {
            & $add 'Arranque' 'Medio' 'Lo que más tarda es lo que arranca después del escritorio' 'Cada programa que se abre solo alarga ese tramo: el plan propone cuáles quitar.'
        }
    }
    if ($s.Startup) {
        $on = @($s.Startup | Where-Object { $_.Enabled })
        $sev = if ($on.Count -gt 12) { 'Medio' } elseif ($on.Count -gt 6) { 'Bajo' } else { 'Ok' }
        & $add 'Arranque' $sev "$($on.Count) programas y tareas se abren al iniciar sesión" ''
    }
    if ($s.Software -and @($s.Software.AntiCheat).Count -gt 0) {
        & $add 'Juegos' 'Info' "Anti-trampas instalados: $(Join-JuicerNames $s.Software.AntiCheat)" 'Win Juicer no toca nada que les afecte, salvo los ajustes de seguridad del nivel Extremo: si un juego deja de abrir tras uno de ellos, deshazlo.'
    }
    $out.ToArray()
}

# --- The machine in a few lines ---------------------------------------------------

function Get-JuicerSystemSummary {
    param([Parameter(Mandatory)][hashtable]$System)
    $s = $System
    $rows = New-Object System.Collections.ArrayList
    $row = { param($Label, $Value) if ($Value) { [void]$rows.Add(@($Label, $Value)) } }

    if ($s.Device) {
        $kind = if ($s.Device.Laptop) { 'Portátil' } else { 'Sobremesa' }
        $what = @($s.Device.Manufacturer, $s.Device.Model) | Where-Object { $_ -and $_ -notmatch 'System (manufacturer|Product Name)|To Be Filled' }
        $extra = @()
        if ($s.Device.Board -and $s.Device.Board -notmatch 'To Be Filled') { $extra += "placa $($s.Device.Board)" }
        if ($s.Device.ModernStandby) { $extra += 'Modern Standby' }
        & $row 'Equipo' ((@($kind, ($what -join ' ')) + $extra | Where-Object { $_ }) -join ' · ')
    }
    if ($s.Os -and $s.Os.Name) {
        & $row 'Windows' ('{0} {1} (compilación {2}.{3})' -f $s.Os.Name, $s.Os.Version, $s.Os.Build, $s.Os.Ubr).Replace('  ', ' ')
    }
    if ($s.Cpu -and $s.Cpu.Name) {
        $c = $s.Cpu
        $bits = @()
        if ($c.Cores) { $bits += "$($c.Cores) núcleos, $($c.Threads) hilos" }
        if ($c.Hybrid) { $bits += "$($c.PCores) P + $($c.ECores) E" }
        if ($c.X3D) { $bits += $(if ($c.DualCcdX3D) { '3D V-Cache en uno de sus dos CCD' } else { '3D V-Cache' }) }
        & $row 'Procesador' ((@($c.Name) + $bits) -join ' — ')
    }
    if ($s.Memory -and $s.Memory.TotalBytes) {
        $m = $s.Memory
        $ch = if ($m.SingleChannel) { 'canal simple' } elseif ($m.SameChannel) { 'mismo canal' } elseif ($m.ModuleCount -ge 2) { 'doble canal' } else { '' }
        $speed = if ($m.Speed) { " a $($m.Speed) MT/s" } else { '' }
        & $row 'Memoria' (('{0} {1}{2}, {3} módulo(s){4}' -f (Format-JuicerBytes $m.TotalBytes), $m.TypeName, $speed, $m.ModuleCount, $(if ($ch) { " en $ch" } else { '' })))
    }
    if ($s.Graphics) {
        foreach ($g in @($s.Graphics.Gpus)) {
            $vram = if ($g.VramBytes -gt 0) { " ($(Format-JuicerBytes $g.VramBytes))" } else { '' }
            $drv = if ($g.DriverVersion) { " — driver $($g.DriverVersion)" } else { '' }
            if ($null -ne $g.DriverAgeDays) { $drv += " (hace $([Math]::Max(0, [int]($g.DriverAgeDays / 30))) meses)" }
            & $row 'Gráfica' ("$($g.Name)$vram, $($g.Kind.ToLowerInvariant())$drv")
        }
        foreach ($d in @($s.Graphics.Displays)) {
            & $row 'Pantalla' ('{0}×{1} a {2} Hz (máx. {3} Hz){4}' -f $d.Width, $d.Height, $d.Hz, $d.MaxHz, $(if ($d.Monitor) { " — $($d.Monitor)" } else { '' }))
        }
    }
    if ($s.Storage) {
        foreach ($v in @($s.Storage.Volumes)) {
            & $row 'Disco' ('{0}: {1} {2} {3} — {4} libres de {5}' -f $v.Letter, $v.Disk, $v.Media, $v.Bus, (Format-JuicerBytes $v.FreeBytes), (Format-JuicerBytes $v.SizeBytes)).Replace('  ', ' ')
        }
    }
    if ($s.Games) {
        foreach ($l in @($s.Games.Libraries)) { & $row 'Juegos' ('{0} en {1}{2}' -f $l.Launcher, $l.Path, $(if ($l.Media) { " ($($l.Media), $($l.Bus))" } else { '' })) }
    }
    if ($s.Network -and $s.Network.Primary) {
        $p = $s.Network.Primary
        & $row 'Red' ('{0}{1} — {2}' -f $p.Type, $(if ($p.SpeedBps -gt 0) { " a $([int]($p.SpeedBps / 1000000)) Mbps" } else { '' }), $p.Description)
    }
    if ($s.Security) {
        $sec = @()
        if ($s.Security.Vbs -eq $true) { $sec += $(if ($s.Security.Hvci) { 'VBS con integridad de memoria' } else { 'VBS sin integridad de memoria' }) }
        elseif ($s.Security.Vbs -eq $false) { $sec += 'VBS inactivo' }
        if ($s.Security.DefenderActive) { $sec += 'Microsoft Defender' }
        $sec += @($s.Security.OtherAv)
        if ($s.Storage -and $s.Storage.BitLocker) { $sec += 'BitLocker' }
        & $row 'Seguridad' ($sec -join ' · ')
    }
    if ($s.Power -and $s.Power.PlanName) { & $row 'Energía' "Plan $($s.Power.PlanName)" }
    if ($s.Software) {
        $sw = @($s.Software.Launchers) + @($s.Software.Capture) + @($s.Software.Chat)
        if ($s.Software.Wsl) { $sw += 'WSL' }
        if ($s.Software.HyperV) { $sw += 'Hyper-V' }
        $sw += @($s.Software.Vm)
        if (@($s.Software.OtherSystems).Count -gt 0) { $sw += 'arranque dual con ' + (Join-JuicerNames $s.Software.OtherSystems) }
        & $row 'Software' (Join-JuicerNames $sw)
    }
    $rows.ToArray()
}
