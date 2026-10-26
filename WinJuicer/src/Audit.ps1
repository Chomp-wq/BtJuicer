# The diagnosis changes nothing. Its job is to find what costs the most, and
# much of that is out of any tool's reach: RAM running without its XMP profile,
# a 144 Hz monitor left at 60, the game library on a hard disk. Saying so is
# worth more than any registry key.

$script:SeverityOrder = @{ Alto = 0; Medio = 1; Bajo = 2; Info = 3; Ok = 4 }
$script:LaptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
# Display adapters that are not a graphics card: remote sessions, VMs, capture
# and streaming drivers.
$script:VirtualGpuPattern = 'Microsoft (Basic|Remote)|Hyper-V|Virtual|VMware|Parsec|Citrix|Mirage|DisplayLink|Spacedesk'

function New-JuicerFinding {
    param([string]$Area, [string]$Severity, [string]$Title, [string]$Detail = '', [string]$Fix = '')
    @{ Area = $Area; Severity = $Severity; Title = $Title; Detail = $Detail; Fix = $Fix }
}

function Format-JuicerBytes {
    param([double]$Bytes)
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    '{0:N0} KB' -f ($Bytes / 1KB)
}

# --- Pure pieces, testable without Windows ---------------------------------

# Boards name slots every way imaginable: "ChannelA-DIMM0", "DIMM_A1",
# "P0 CHANNEL A", "Controller0-ChannelB-DIMM1". All carry a channel letter.
function Get-JuicerMemoryChannel {
    param([string]$Locator)
    if ($Locator -match '(?i)channel\s*([A-H])(?![A-Z])') { return $Matches[1].ToUpperInvariant() }
    if ($Locator -match '(?i)\bDIMM[_\s-]?([A-H])\d') { return $Matches[1].ToUpperInvariant() }
    $null
}

function Get-JuicerRamFindings {
    param([object[]]$Modules, [bool]$Laptop)
    $area = 'Memoria'
    $out = @()
    if (-not $Modules -or $Modules.Count -eq 0) { return $out }
    $total = ($Modules | Measure-Object -Property Capacity -Sum).Sum
    $speed = ($Modules | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Measure-Object -Minimum).Minimum
    $type = @($Modules)[0].SMBIOSMemoryType
    $typeName = switch ($type) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { 'RAM' } }
    $at = if ($speed -gt 0) { ", a $speed MT/s" } else { '' }
    $out += New-JuicerFinding $area 'Info' ('{0} de {1} en {2} módulo(s){3}' -f (Format-JuicerBytes $total), $typeName, $Modules.Count, $at)

    if ($total -lt 15GB) {
        $out += New-JuicerFinding $area 'Bajo' 'Menos de 16 GB de RAM' 'Muchos juegos actuales piden 16 GB; con menos, Windows pagina a disco y aparecen tirones.'
    }

    if ($Modules.Count -eq 1) {
        if ($Laptop) {
            $out += New-JuicerFinding $area 'Medio' 'Un solo módulo de RAM: probablemente en canal simple' 'Con un solo canal la memoria tiene la mitad de ancho de banda; con gráfica integrada se nota mucho. Si tu portátil tiene una ranura libre, un segundo módulo igual lo arregla.'
        } else {
            $out += New-JuicerFinding $area 'Alto' 'Un solo módulo de RAM: canal simple' 'La memoria funciona con la mitad de ancho de banda. En juegos limitados por CPU, y sobre todo con gráfica integrada, es de las mayores pérdidas posibles. Añade un segundo módulo igual.'
        }
    } elseif ($Modules.Count -eq 2) {
        $channels = @($Modules | ForEach-Object { Get-JuicerMemoryChannel ("$($_.DeviceLocator) $($_.BankLabel)") })
        if ($channels.Count -eq 2 -and $channels[0] -and $channels[0] -eq $channels[1]) {
            $out += New-JuicerFinding $area 'Alto' "Los dos módulos parecen estar en el mismo canal ($($channels[0]))" 'Así trabajan como si fueran uno: mitad de ancho de banda. Muévelos a las ranuras que indica el manual de la placa, normalmente A2 y B2.'
        }
    }

    $parts = @($Modules | ForEach-Object { ([string]$_.PartNumber).Trim() } | Where-Object { $_ } | Select-Object -Unique)
    if ($parts.Count -gt 1) {
        $out += New-JuicerFinding $area 'Medio' "Módulos de RAM distintos: $($parts -join ', ')" 'Kits mezclados no siempre aguantan su XMP/EXPO juntos. Si hay pantallazos o errores WHEA, prueba a bajar la velocidad un escalón, o usa módulos de un mismo kit.'
    }
    if ($Modules.Count -ge 4 -and $type -eq 34) {
        $out += New-JuicerFinding $area 'Bajo' 'Cuatro módulos DDR5' 'Con cuatro módulos, las placas DDR5 rara vez sostienen 6000 MT/s o más: suelen bajar a 5200 o menos. Dos módulos de más capacidad rinden más.'
    }

    if (-not $Laptop) {
        $xmp = if ($type -eq 34) { 'EXPO o XMP' } else { 'XMP (DOCP en ASUS con AMD)' }
        $ratings = @($Modules | ForEach-Object { Get-JuicerRamRating $_.PartNumber } | Where-Object { $_ })
        $rated = if ($ratings.Count -eq $Modules.Count) { ($ratings | ForEach-Object { $_.Speed } | Measure-Object -Minimum).Minimum } else { 0 }
        $xmpKit = $rated -gt 0 -and @($ratings | Where-Object { -not $_.Xmp }).Count -eq 0
        $spd = ($Modules | ForEach-Object { $_.Speed } | Where-Object { $_ } | Measure-Object -Minimum).Minimum
        if ($xmpKit -and $speed -gt 0 -and $speed -lt $rated - 100) {
            $sev = if ($speed -le 0.85 * $rated) { 'Alto' } else { 'Medio' }
            $out += New-JuicerFinding $area $sev "La RAM va a $speed MT/s, pero tu kit está certificado a $rated" "Lo dice su referencia ($($ratings[0].Brand) $($ratings[0].PartNumber)). Activa $xmp en la BIOS: en juegos limitados por CPU suele ser la mejora gratuita más grande que queda."
        } elseif ($rated -eq 0) {
            $jedec = if ($type -eq 26) { 2666 } elseif ($type -eq 34) { 4800 } else { 0 }
            if ($jedec -and $speed -gt 0 -and $speed -le $jedec) {
                $label = if ($type -eq 34) { 'DDR5-6000 o 6400' } else { 'DDR4-3200 o 3600' }
                $out += New-JuicerFinding $area 'Medio' "La RAM va a $speed MT/s, la velocidad estándar" "Si tu kit es más rápido (mira la etiqueta: $label…), activa $xmp en la BIOS. En juegos limitados por CPU suele ser la mejora gratuita más grande que queda."
            }
        }
        if ($spd -and $speed -gt $spd + 100) {
            $out += New-JuicerFinding $area 'Info' "XMP/EXPO activo: $speed MT/s (sin él, $spd)" 'Es un overclock de memoria, certificado por el fabricante del kit. Si aparecen errores WHEA o pantallazos MEMORY_MANAGEMENT, es lo primero que hay que revisar.'
        }
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

# `nvidia-smi -q -d MEMORY`: with Resizable BAR on, BAR1 spans all the VRAM;
# off, it is a 256 MB window.
function ConvertFrom-JuicerNvidiaSmi {
    param([string]$Text)
    $fb = $null; $bar = $null; $section = ''
    foreach ($line in ($Text -split "`r?`n")) {
        if ($line -match '^\s*FB Memory Usage') { $section = 'fb' }
        elseif ($line -match '^\s*BAR1 Memory Usage') { $section = 'bar' }
        elseif ($line -match '^\s*Total\s*:\s*(\d+)\s*MiB') {
            if ($section -eq 'fb' -and $null -eq $fb) { $fb = [int]$Matches[1] }
            if ($section -eq 'bar' -and $null -eq $bar) { $bar = [int]$Matches[1] }
        }
    }
    if ($null -eq $fb -or $null -eq $bar) { return $null }
    @{ VramMiB = $fb; Bar1MiB = $bar; Rebar = ($bar -ge ($fb / 2)) }
}

# --- Sections --------------------------------------------------------------

function Test-JuicerLaptop {
    try {
        if (@(Get-CimInstance Win32_Battery -ErrorAction Stop).Count -gt 0) { return $true }
        $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes)
        return (@($types | Where-Object { $script:LaptopChassis -contains [int]$_ }).Count -gt 0)
    } catch {
        return $false
    }
}

function Get-JuicerDriveMedia {
    param([string]$Letter)
    try {
        $part = Get-Partition -DriveLetter $Letter.Substring(0, 1) -ErrorAction Stop
        $disk = Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.DeviceId -eq [string]$part.DiskNumber } | Select-Object -First 1
        if ($disk) { return @{ Media = [string]$disk.MediaType; Bus = [string]$disk.BusType; Name = $disk.FriendlyName } }
    } catch {
        Write-Verbose "No se pudo identificar el disco de ${Letter}: $_"
    }
    $null
}

function Get-JuicerSystemAudit {
    $out = @()
    $cv = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $name = Read-JuicerReg $cv 'ProductName'
    $ver = Read-JuicerReg $cv 'DisplayVersion'
    $ubr = Read-JuicerReg $cv 'UBR'
    $build = Get-JuicerWindowsBuild
    # ProductName still says "Windows 10" on Windows 11; the build is what tells.
    $product = if ($name) { ([string]$name.Value) -replace '^Windows 10', $(if ($build -ge 22000) { 'Windows 11' } else { 'Windows 10' }) } else { 'Windows' }
    $out += New-JuicerFinding 'Sistema' 'Info' ('{0} {1} (compilación {2}.{3})' -f $product, $(if ($ver) { $ver.Value }), $build, $(if ($ubr) { $ubr.Value } else { 0 }))
    if ($build -lt 22000) {
        $out += New-JuicerFinding 'Sistema' 'Info' 'Win Juicer está pensado para Windows 11' 'Casi todo funciona también en Windows 10; lo que no aplica aparece como «no aplica».'
    }

    try {
        $me = [Security.Principal.WindowsIdentity]::GetCurrent().Name
        $owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1 |
            Invoke-CimMethod -MethodName GetOwner -ErrorAction Stop
        if ($owner -and $owner.User -and ($me -notlike "*\$($owner.User)")) {
            $out += New-JuicerFinding 'Sistema' 'Alto' "Win Juicer corre como $me, pero la sesión es de $($owner.Domain)\$($owner.User)" 'Los ajustes de usuario (ratón, animaciones, Game Bar…) se aplicarían a la cuenta de administrador, no a la tuya. Inicia sesión con tu cuenta y dale permisos de administrador.'
        }
    } catch {
        Write-Verbose "No se pudo comparar usuarios: $_"
    }
    $out
}

function Get-JuicerHardwareAudit {
    $out = @()
    $laptop = Test-JuicerLaptop
    $cpu = Get-JuicerCpuInfo
    if ($cpu.Name) {
        $out += New-JuicerFinding 'Procesador' 'Info' ('{0} — {1} núcleos, {2} hilos' -f $cpu.Name, $cpu.Cores, $cpu.Threads)
        if ($cpu.Hybrid) {
            $out += New-JuicerFinding 'Procesador' 'Info' 'Procesador híbrido, con núcleos de rendimiento y de eficiencia' 'Windows 11 reparte el trabajo entre ellos según la prioridad y el foco. Por eso aquí cuentan dos ajustes: sin limitación de energía (lo de fondo no acaba en los núcleos lentos) y el modo juego.'
        }
    } else {
        $out += New-JuicerFinding 'Procesador' 'Info' 'No se pudo leer el procesador.'
    }
    try {
        $out += Get-JuicerRamFindings @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) $laptop
    } catch {
        $out += New-JuicerFinding 'Memoria' 'Info' 'No se pudo leer la memoria.'
    }

    if ($laptop) {
        try {
            $online = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Where-Object { $_.PowerOnline -eq $false })
            if ($online.Count -gt 0) {
                $out += New-JuicerFinding 'Energía' 'Alto' 'Estás funcionando con batería' 'Con batería, el portátil limita procesador y gráfica aunque elijas el máximo rendimiento. Para jugar, conecta el cargador.'
            }
        } catch {
            Write-Verbose "Sin estado de batería: $_"
        }
    }
    $out
}

function Get-JuicerGraphicsAudit {
    $out = @()
    try {
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop)
        $real = @($gpus | Where-Object { $_.Name -notmatch $script:VirtualGpuPattern })
        if ($real.Count -eq 0 -and $gpus.Count -gt 0) {
            $out += New-JuicerFinding 'Gráfica' 'Alto' 'No hay driver de la tarjeta gráfica' 'Windows usa el adaptador básico, sin aceleración. Instala el driver de NVIDIA, AMD o Intel desde su web.'
        }
        foreach ($g in $real) {
            $date = $g.DriverDate
            $age = if ($date) { [int]((Get-Date) - $date).TotalDays } else { -1 }
            $out += New-JuicerFinding 'Gráfica' 'Info' ('{0} — driver {1}{2}' -f $g.Name, $g.DriverVersion, $(if ($date) { ' del ' + $date.ToString('d') } else { '' }))
            if ($age -gt 365 -and $g.Name -match 'NVIDIA|AMD|Radeon|Arc') {
                $out += New-JuicerFinding 'Gráfica' 'Medio' "El driver de $($g.Name) tiene más de un año" 'Los drivers nuevos traen optimizaciones para juegos recientes. Descárgalo de la web del fabricante.'
            }
        }
    } catch {
        $out += New-JuicerFinding 'Gráfica' 'Info' 'No se pudo leer la tarjeta gráfica.'
    }

    try {
        $out += Get-JuicerDisplayFindings (Get-JuicerDisplays)
    } catch {
        $out += New-JuicerFinding 'Pantalla' 'Info' 'No se pudieron leer los modos de pantalla.'
    }

    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path -LiteralPath $smi) {
        $r = Invoke-JuicerNative $smi @('-q', '-d', 'MEMORY')
        $bar = ConvertFrom-JuicerNvidiaSmi $r.Output
        if ($bar -and -not $bar.Rebar) {
            $out += New-JuicerFinding 'Gráfica' 'Medio' 'Resizable BAR desactivado' 'Actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support»). NVIDIA lo usa juego a juego: según el título, de nada a un 10 %.'
        } elseif ($bar) {
            $out += New-JuicerFinding 'Gráfica' 'Ok' 'Resizable BAR activado'
        }
    }
    $out
}

function Get-JuicerStorageAudit {
    $out = @()
    $sys = $env:SystemDrive
    $media = Get-JuicerDriveMedia $sys
    if ($media) {
        $label = '{0} ({1}, {2})' -f $media.Name, $media.Media, $media.Bus
        if ($media.Media -eq 'HDD') {
            $out += New-JuicerFinding 'Disco' 'Alto' "Windows está en un disco duro mecánico: $label" 'Es el mayor freno posible para el arranque y las cargas, y ningún ajuste lo compensa. Un SSD, aunque sea SATA, lo cambia todo.'
        } else {
            $out += New-JuicerFinding 'Disco' 'Info' "Windows en $label"
        }
    }

    try {
        $c = Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$sys'" -ErrorAction Stop
        $pct = 100 * $c.FreeSpace / $c.Size
        $free = '{0} libres de {1} ({2:N0} %)' -f (Format-JuicerBytes $c.FreeSpace), (Format-JuicerBytes $c.Size), $pct
        if ($c.FreeSpace -lt 20GB -or $pct -lt 10) {
            $out += New-JuicerFinding 'Disco' 'Alto' "Queda poco espacio en ${sys} $free" 'Un SSD casi lleno escribe mucho más lento, y Windows necesita sitio para la paginación y las actualizaciones. Usa Mantenimiento > Limpieza, o mueve juegos a otra unidad.'
        } elseif ($pct -lt 20) {
            $out += New-JuicerFinding 'Disco' 'Medio' "Espacio justo en ${sys} $free" 'Por debajo de un 20 % libre, los SSD empiezan a perder velocidad de escritura.'
        } else {
            $out += New-JuicerFinding 'Disco' 'Ok' "${sys} $free"
        }
    } catch {
        Write-Verbose "Sin espacio libre de ${sys}: $_"
    }

    try {
        foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop | Where-Object { $_.HealthStatus -and $_.HealthStatus -ne 'Healthy' })) {
            $out += New-JuicerFinding 'Disco' 'Alto' "El disco $($d.FriendlyName) informa de un estado «$($d.HealthStatus)»" 'Haz copia de seguridad cuanto antes; un disco que falla también se vuelve lento.'
        }
    } catch {
        Write-Verbose "Sin estado de salud de discos: $_"
    }

    foreach ($lib in (Get-JuicerGameLibraries)) {
        $m = Get-JuicerDriveMedia $lib.Path
        if ($m -and $m.Media -eq 'HDD') {
            $out += New-JuicerFinding 'Disco' 'Alto' "Biblioteca de $($lib.Launcher) en disco duro mecánico: $($lib.Path)" 'Es lo que más alarga las pantallas de carga. Muévela a un SSD; Steam, Epic y Xbox permiten mover juegos sin volver a descargarlos.'
        } elseif ($m -and $m.Bus -eq 'NVMe') {
            $out += New-JuicerFinding 'Disco' 'Ok' "Biblioteca de $($lib.Launcher) en NVMe: $($lib.Path)" 'Lo mejor posible para cargas, y lo que necesitan los juegos con DirectStorage.'
        }
    }
    $out
}

function Get-JuicerSecurityAudit {
    $out = @()
    try {
        $dg = Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        if ($dg.VirtualizationBasedSecurityStatus -eq 2) {
            $hvci = @($dg.SecurityServicesRunning) -contains 2
            $what = if ($hvci) { 'con integridad de memoria (HVCI)' } else { 'sin integridad de memoria' }
            $out += New-JuicerFinding 'Seguridad' 'Medio' "Seguridad basada en virtualización activa, $what" 'Protege el núcleo de Windows a cambio de rendimiento en juegos. Win Juicer puede desactivarla en el nivel Extremo; lee antes qué pierdes.' 'seguridad.integridad'
        } else {
            $out += New-JuicerFinding 'Seguridad' 'Info' 'Seguridad basada en virtualización inactiva'
        }
    } catch {
        Write-Verbose "Sin estado de VBS: $_"
    }

    # Information only: whether to encrypt is a decision about the data, not
    # about frames.
    try {
        $vol = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume `
            -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($vol -and (Invoke-CimMethod -InputObject $vol -MethodName GetProtectionStatus).ProtectionStatus -eq 1) {
            $m = (Invoke-CimMethod -InputObject $vol -MethodName GetEncryptionMethod).EncryptionMethod
            # 5: the drive encrypts by itself (eDrive), at no cost to the CPU.
            if ($m -ne 5) {
                $out += New-JuicerFinding 'Seguridad' 'Info' "BitLocker activo en $env:SystemDrive, cifrando por software" 'Protege tus datos si te roban el equipo. En SSD NVMe muy rápidos cuesta algo en escrituras pequeñas y poco en juegos. Quitarlo es decisión tuya (Configuración > Privacidad y seguridad > Cifrado del dispositivo); Win Juicer no lo toca.'
            }
        }
    } catch {
        Write-Verbose "Sin estado de BitLocker: $_"
    }
    $out
}

function Get-JuicerBootAudit {
    $out = @()
    try {
        $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 5 -ErrorAction Stop)
        $boots = foreach ($e in $events) {
            $data = @{}
            foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
            @{ Total = [int]$data.BootTime; Main = [int]$data.MainPathBootTime; Post = [int]$data.BootPostBootTime; When = $e.TimeCreated }
        }
        if ($boots) {
            $last = @($boots)[0]
            $detail = 'Hasta el escritorio {0:N1} s; después, {1:N1} s más cargando programas de inicio y servicios.' -f ($last.Main / 1000), ($last.Post / 1000)
            $sev = if ($last.Total -gt 90000) { 'Alto' } elseif ($last.Total -gt 45000) { 'Medio' } else { 'Ok' }
            $out += New-JuicerFinding 'Arranque' $sev ('Último arranque completo: {0:N1} s ({1})' -f ($last.Total / 1000), $last.When.ToString('g')) $detail
            if ($last.Post -gt $last.Main -and $last.Post -gt 20000) {
                $out += New-JuicerFinding 'Arranque' 'Medio' 'Lo que más tarda es lo que arranca después del escritorio' 'Revisa Programas de inicio: cada programa que se abre solo alarga ese tramo.'
            }
        }
    } catch {
        $out += New-JuicerFinding 'Arranque' 'Info' 'Windows no tiene registros de tiempos de arranque' 'El registro de diagnóstico de rendimiento está vacío o desactivado en este equipo.'
    }

    try {
        $items = Get-JuicerStartupItems
        $on = @($items | Where-Object { $_.Enabled })
        $sev = if ($on.Count -gt 12) { 'Medio' } elseif ($on.Count -gt 6) { 'Bajo' } else { 'Ok' }
        $out += New-JuicerFinding 'Arranque' $sev "$($on.Count) programas y tareas se abren al iniciar sesión" 'Desactiva en Programas de inicio los que no necesites nada más encender.'
    } catch {
        Write-Verbose "Sin programas de inicio: $_"
    }
    $out
}

function Get-JuicerCatalogAudit {
    $out = @()
    $journal = Read-JuicerJournal
    foreach ($t in (Get-JuicerCatalog | Where-Object { $_.Category -eq 'Reparación' })) {
        $s = Get-JuicerTweakState $t $journal
        if ($s.State -in 'Pendiente', 'Parcial') {
            $sev = if ($t.Impact -eq 'Alto') { 'Alto' } else { 'Medio' }
            $out += New-JuicerFinding 'Reparación' $sev $t.Title $t.Gain $t.Id
        }
    }
    $pending = @(Get-JuicerProfile 1 | Where-Object { $_.Category -ne 'Reparación' -and (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' })
    if ($pending.Count -gt 0) {
        $out += New-JuicerFinding 'Ajustes' 'Bajo' "$($pending.Count) ajustes del perfil Seguro sin aplicar" (($pending | ForEach-Object { $_.Title }) -join ', ')
    }
    $out
}

# OnSection, if given, is told the name of each part as it starts: the
# window shows it while the diagnosis runs.
function Get-JuicerAudit {
    param([scriptblock]$OnSection)
    $sections = @(
        @('Sistema', ${function:Get-JuicerSystemAudit}), @('Procesador y memoria', ${function:Get-JuicerHardwareAudit}),
        @('Overclock y BIOS', ${function:Get-JuicerTuningAudit}), @('Estabilidad', ${function:Get-JuicerStabilityAudit}),
        @('Gráfica', ${function:Get-JuicerGraphicsAudit}), @('Gráfica', ${function:Get-JuicerGpuTuningAudit}),
        @('Discos', ${function:Get-JuicerStorageAudit}), @('Red', ${function:Get-JuicerNetworkAudit}),
        @('Seguridad', ${function:Get-JuicerSecurityAudit}), @('Arranque', ${function:Get-JuicerBootAudit}),
        @('Programas', ${function:Get-JuicerSoftwareAudit}), @('Ajustes', ${function:Get-JuicerCatalogAudit})
    )
    $all = @()
    foreach ($s in $sections) {
        if ($OnSection) { & $OnSection $s[0] }
        try {
            $all += @(& $s[1])
        } catch {
            $all += New-JuicerFinding 'Diagnóstico' 'Info' "Una parte del diagnóstico ($($s[0])) falló: $_"
        }
    }
    $all
}
