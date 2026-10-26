# What the monitor is and what it can do, from the EDID it hands Windows:
# brand and model, variable refresh (FreeSync, HDMI 2.1 VRR) with its range,
# HDR and its brightness. What the EDID does not carry, such as whether
# backlight strobing (ELMB, DyAc…) exists or is on, is told by brand, as
# something to look for in the monitor's own menu.
#
# G-Sync with a module cannot be told apart from Windows; on NVIDIA, a
# FreeSync or Adaptive-Sync monitor is used as «G-Sync Compatible».

$script:PnpBrands = @{
    AUS = 'ASUS'; BNQ = 'BenQ'; GSM = 'LG'; SAM = 'Samsung'; SEC = 'Samsung'; ACR = 'Acer'; DEL = 'Dell'; AOC = 'AOC'; MSI = 'MSI'
    GBT = 'Gigabyte'; HPN = 'HP'; HWP = 'HP'; LEN = 'Lenovo'; VSC = 'ViewSonic'; PHL = 'Philips'; SNY = 'Sony'; XMI = 'Xiaomi'
    AOR = 'AORUS'; IVM = 'iiyama'; NEC = 'NEC'; EIZ = 'EIZO'; HKC = 'HKC'; KTC = 'KTC'; MSF = 'Microsoft'
}

# Backlight strobing by brand: what it is called in the monitor's menu.
$script:StrobeNames = @{
    ASUS = 'ELMB (o ELMB Sync, que funciona junto con la VRR)'; BenQ = 'DyAc'; LG = 'Motion Blur Reduction (1ms MBR)'
    Acer = 'VRB (Visual Response Boost)'; MSI = 'Anti Motion Blur (MPRT)'; Gigabyte = 'Aim Stabilizer (o Aim Stabilizer Sync)'
    AORUS = 'Aim Stabilizer (o Aim Stabilizer Sync)'; AOC = 'MBR (Motion Blur Reduction)'; ViewSonic = 'PureXP'; Dell = 'Motion Blur Reduction'
}

# Everything worth knowing in one EDID, or null if it is not one.
function ConvertFrom-JuicerEdidInfo {
    param([byte[]]$Edid)
    $native = ConvertFrom-JuicerEdid $Edid
    if (-not $native) { return $null }
    $w = ([int]$Edid[8] -shl 8) -bor $Edid[9]
    $vendor = -join @(([char](64 + (($w -shr 10) -band 31))), ([char](64 + (($w -shr 5) -band 31))), ([char](64 + ($w -band 31))))
    $info = @{
        Vendor = $vendor; Brand = $(if ($script:PnpBrands.Contains($vendor)) { $script:PnpBrands[$vendor] } else { $vendor })
        Name = ''; Width = $native.Width; Height = $native.Height; RangeMin = 0; RangeMax = 0
        FreeSync = $false; FreeSyncMin = 0; FreeSyncMax = 0; HdmiVrrMin = 0; HdmiVrrMax = 0; Hdr10 = $false; MaxNits = 0
    }
    foreach ($d in 54, 72, 90, 108) {
        if ($Edid[$d] -ne 0 -or $Edid[$d + 1] -ne 0) { continue }
        switch ($Edid[$d + 3]) {
            0xFC {
                $chars = foreach ($i in ($d + 5)..($d + 17)) { if ($Edid[$i] -eq 0x0A) { break }; [char]$Edid[$i] }
                $info.Name = (-join @($chars)).Trim()
            }
            0xFD {
                # EDID 1.4 adds 255 to the rates when the offset flags say so.
                $min = [int]$Edid[$d + 5]; $max = [int]$Edid[$d + 6]
                if ($Edid[$d + 4] -band 0x02) { $max += 255 }
                if (($Edid[$d + 4] -band 0x03) -eq 0x03) { $min += 255 }
                $info.RangeMin = $min; $info.RangeMax = $max
            }
        }
    }
    # CTA-861 extensions: their data blocks carry FreeSync, HDMI and HDR.
    for ($e = 1; $e -le $Edid[126] -and ($e + 1) * 128 -le $Edid.Count; $e++) {
        $b = 128 * $e
        if ($Edid[$b] -ne 0x02) { continue }
        $end = $b + [int]$Edid[$b + 2]
        $i = $b + 4
        while ($i -lt $end -and $i -lt $b + 127) {
            $tag = $Edid[$i] -shr 5; $len = $Edid[$i] -band 31
            $p = $i + 1
            if ($tag -eq 3 -and $len -ge 3) {
                $oui = [int]$Edid[$p] -bor ([int]$Edid[$p + 1] -shl 8) -bor ([int]$Edid[$p + 2] -shl 16)
                $x = $p + 3
                if ($oui -eq 0x00001A) {
                    # AMD's block: version, then minimum and maximum refresh.
                    $info.FreeSync = $true
                    if ($len -ge 7) { $info.FreeSyncMin = [int]$Edid[$x + 2]; $info.FreeSyncMax = [int]$Edid[$x + 3] }
                } elseif ($oui -eq 0xC45DD8 -and $len -ge 11) {
                    # HDMI Forum block: VRRmin in 6 bits, VRRmax in 10.
                    $info.HdmiVrrMin = $Edid[$x + 6] -band 0x3F
                    $info.HdmiVrrMax = (([int]$Edid[$x + 6] -band 0xC0) -shl 2) -bor $Edid[$x + 7]
                }
            } elseif ($tag -eq 7 -and $len -ge 2 -and $Edid[$p] -eq 6) {
                # HDR static metadata: bit 2 of the EOTFs is PQ, HDR10's.
                $info.Hdr10 = [bool]($Edid[$p + 1] -band 0x04)
                if ($len -ge 4 -and $Edid[$p + 3] -gt 0) { $info.MaxNits = [int][Math]::Round(50 * [Math]::Pow(2, $Edid[$p + 3] / 32)) }
            }
            $i += 1 + $len
        }
    }
    $info
}

# Variable refresh and its range, from whichever block announced it.
function Get-JuicerVrrRange {
    param([hashtable]$Info)
    if (-not $Info) { return $null }
    if ($Info.FreeSync -and $Info.FreeSyncMax -gt $Info.FreeSyncMin -and $Info.FreeSyncMin -gt 0) { return @{ Min = $Info.FreeSyncMin; Max = $Info.FreeSyncMax; Kind = 'FreeSync' } }
    if ($Info.HdmiVrrMax -gt $Info.HdmiVrrMin -and $Info.HdmiVrrMin -gt 0) { return @{ Min = $Info.HdmiVrrMin; Max = $Info.HdmiVrrMax; Kind = 'HDMI 2.1 VRR' } }
    if ($Info.FreeSync -and $Info.RangeMax -gt $Info.RangeMin) { return @{ Min = $Info.RangeMin; Max = $Info.RangeMax; Kind = 'FreeSync' } }
    if ($Info.FreeSync) { return @{ Min = 0; Max = 0; Kind = 'FreeSync' } }
    $null
}

# Each display with what its EDID says. Windows only.
function Get-JuicerMonitors {
    foreach ($d in @(Get-JuicerDisplays)) {
        $path = ConvertTo-JuicerEdidKey $d.MonitorId
        $edid = if ($path) { Read-JuicerReg $path 'EDID' }
        $info = if ($edid) { ConvertFrom-JuicerEdidInfo ([byte[]]$edid.Value) }
        @{ Display = $d; Info = $info; Vrr = (Get-JuicerVrrRange $info) }
    }
}

function Get-JuicerPrimaryMonitor {
    $all = @(Get-JuicerMonitors)
    $p = @($all | Where-Object { $_.Display.Primary })
    if ($p.Count -gt 0) { return $p[0] }
    if ($all.Count -gt 0) { return $all[0] }
    $null
}

function Format-JuicerMonitor {
    param([hashtable]$Monitor)
    $i = $Monitor.Info; $d = $Monitor.Display
    $name = if ($i -and $i.Name) { "$($i.Brand) $($i.Name)" } elseif ($i) { $i.Brand } elseif ($d.Monitor) { $d.Monitor } else { 'Pantalla' }
    $parts = @("$($d.MaxHz) Hz")
    if ($Monitor.Vrr) {
        $r = if ($Monitor.Vrr.Max -gt 0) { " $($Monitor.Vrr.Min)–$($Monitor.Vrr.Max) Hz" + $(if ($Monitor.Vrr.Max -ge 2 * $Monitor.Vrr.Min) { ' con LFC' } else { ' sin LFC' }) } else { '' }
        $parts += "$($Monitor.Vrr.Kind)$r"
    } else {
        $parts += 'sin VRR anunciada'
    }
    if ($i -and $i.Hdr10) { $parts += $(if ($i.MaxNits) { "HDR10 (~$($i.MaxNits) nits)" } else { 'HDR10' }) }
    '{0}: {1}' -f $name, ($parts -join ', ')
}

# What to do with this monitor and this graphics card. GpuVendor is NVIDIA,
# AMD or Intel; Games are measured games (Low1, AvgFps), to say whether
# strobing would hold.
function Get-JuicerMonitorFindings {
    param([object[]]$Monitors, [string]$GpuVendor, [object[]]$Games = @())
    $out = @()
    foreach ($m in $Monitors) {
        if (-not $m.Info) { continue }
        $i = $m.Info; $d = $m.Display
        $title = Format-JuicerMonitor $m
        $oled = $i.Name -match 'OLED|PG27AQDM|AW3423|AW2725|QD-?OLED'
        $hz = [int]$d.MaxHz
        $cap = Get-JuicerFpsCap $hz ([bool]$m.Vrr)
        if ($m.Vrr) {
            $how = switch ($GpuVendor) {
                'NVIDIA' { "En el Panel de control de NVIDIA > Configurar G-SYNC, actívalo «para pantalla completa y en ventana» (si sale «no validado», actívalo igualmente). Después, en Administrar la configuración 3D: Sincronización vertical «Activada» y, en los juegos, desactivada. En juegos con NVIDIA Reflex, actívalo (On; On + Boost si limita el procesador)." }
                'AMD' { 'En AMD Software > Juegos > Pantalla, activa AMD FreeSync; Enhanced Sync desactivado y la sincronización vertical de los juegos desactivada.' }
                'Intel' { 'En Intel Graphics Software > Pantalla, activa Adaptive Sync.' }
                default { 'Actívala en el panel de tu gráfica.' }
            }
            $out += New-JuicerFinding 'Monitor' 'Info' $title ("Tiene frecuencia variable: sin cortes ni tirones de VSync aunque los FPS no lleguen a los Hz. $how Comprueba también que FreeSync/Adaptive-Sync está activado en el menú del propio monitor: muchos vienen con ella apagada. Y un límite de $($cap.Fps) FPS para no salir nunca del rango (Juegos > Limitador de FPS lo pone por juego).")
            if ($m.Vrr.Min -gt 0 -and $m.Vrr.Max -lt 2 * $m.Vrr.Min) {
                $out += New-JuicerFinding 'Monitor' 'Bajo' "Por debajo de $($m.Vrr.Min) FPS se pierde la frecuencia variable" "Su rango ($($m.Vrr.Min)–$($m.Vrr.Max) Hz) no llega para duplicar fotogramas (LFC): si un juego baja de ahí vuelven los tirones. Ajusta la calidad para mantenerte por encima."
            }
        } else {
            $out += New-JuicerFinding 'Monitor' 'Info' $title "No anuncia FreeSync ni VRR de HDMI. Si su menú tiene «FreeSync» o «Adaptive-Sync», actívalo (por DisplayPort puede funcionar aunque no lo anuncie). Sin VRR hay dos opciones: sin VSync y sin límite (menos latencia, con cortes en la imagen) o VSync con un límite de $hz FPS (imagen limpia, algo más de latencia)."
        }

        if (-not $oled -and $hz -ge 120 -and $script:StrobeNames.Contains($i.Brand)) {
            $holds = @($Games | Where-Object { $_.Low1 -ge $hz })
            $tail = if ($holds.Count -gt 0) { " En tus medidas, $(($holds | ForEach-Object { $_.Application }) -join ', ') no baja de $hz FPS: ahí te serviría." } else { '' }
            $out += New-JuicerFinding 'Monitor' 'Info' "Nitidez en movimiento: busca «$($script:StrobeNames[$i.Brand])» en el menú del monitor" ("Si tu modelo la tiene, hace parpadear la retroiluminación y el movimiento se ve mucho más nítido, a cambio de brillo y, casi siempre, sin frecuencia variable. Vale la pena en shooters donde los FPS no bajan nunca de los Hz; si bajan, mejor la VRR.$tail")
        }
        if ($oled) {
            $out += New-JuicerFinding 'Monitor' 'Info' 'OLED: respuesta casi instantánea' 'No necesita overdrive ni estroboscopio. Con VRR puede parpadear el brillo en menús y pantallas de carga con FPS muy variables: un límite de FPS lo reduce.'
        } else {
            $out += New-JuicerFinding 'Monitor' 'Info' 'Overdrive en el nivel intermedio' 'En el menú del monitor (Overdrive, Trace Free, AMA, Response Time): el nivel máximo deja halos claros u oscuros detrás de lo que se mueve; el intermedio suele ser el mejor.'
        }
        if ($i.Hdr10) {
            if ($oled -or $i.MaxNits -ge 600) {
                $out += New-JuicerFinding 'Monitor' 'Info' 'HDR que merece la pena' 'Activa HDR en Configuración > Pantalla y calíbralo con la app «Calibración de HDR de Windows» (Microsoft Store). Auto HDR añade HDR a juegos que no lo tienen.'
            } elseif ($i.MaxNits -gt 0) {
                $out += New-JuicerFinding 'Monitor' 'Info' "HDR de entrada (~$($i.MaxNits) nits)" 'Con tan poco brillo y sin atenuación local, en juegos suele verse más apagado que en SDR. Déjalo desactivado salvo que te guste cómo queda.'
            }
        }
    }
    $out
}
