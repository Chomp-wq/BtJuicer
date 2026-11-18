# The diagnosis changes nothing. Its job is to find what costs the most, and
# much of that is out of any tool's reach: RAM running without its XMP profile,
# a 144 Hz monitor left at 60, the game library on a hard disk. Saying so is
# worth more than any registry key.

$script:SeverityOrder = @{ Alto = 0; Medio = 1; Bajo = 2; Info = 3; Ok = 4 }
$script:LaptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
$script:DesktopChassis = @(3, 4, 5, 6, 7, 13, 15, 16, 17, 23, 24, 34, 35, 36)
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

# «1 cambio», «3 cambios»: the words agree with the number. Many is One plus
# «s» unless given («1 juego encontrado», «2 juegos encontrados»).
function Format-JuicerCount {
    param([int]$Count, [string]$One, [string]$Many)
    if (-not $Many) { $Many = $One + 's' }
    '{0} {1}' -f $Count, $(if ($Count -eq 1) { $One } else { $Many })
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

# Cpu, when given, decides what speed is best: see Get-JuicerMemoryPlan.
function Get-JuicerRamFindings {
    param([object[]]$Modules, [bool]$Laptop, [hashtable]$Cpu)
    $area = 'Memoria'
    $out = @()
    if (-not $Modules -or $Modules.Count -eq 0) { return $out }
    $total = ($Modules | Measure-Object -Property Capacity -Sum).Sum
    $speed = ($Modules | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Measure-Object -Minimum).Minimum
    $type = @($Modules)[0].SMBIOSMemoryType
    $typeName = switch ($type) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } default { 'RAM' } }
    $at = if ($speed -gt 0) { ", a $speed MT/s" } else { '' }
    $out += New-JuicerFinding $area 'Info' ('{0} de {1} en {2}{3}' -f (Format-JuicerBytes $total), $typeName, (Format-JuicerCount $Modules.Count 'módulo'), $at)

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
        $plan = Get-JuicerMemoryPlan $Cpu $typeName
        # The speed to aim for: the kit's, unless the platform runs better slower.
        $best = if ($plan -and $rated -gt 0) { [Math]::Min($rated, $plan.Target) } elseif ($plan) { $plan.Target } else { $rated }
        $range = if ($plan) { if ($plan.Max -gt $plan.Target) { "$($plan.Target)-$($plan.Max)" } else { "$($plan.Target)" } } else { '' }
        if ($plan -and -not $plan.Apu -and $speed -gt $plan.Max + 50) {
            $out += New-JuicerFinding $area 'Medio' "La RAM va a $speed MT/s: más de lo que rinde en un $($plan.Platform)" ("$($plan.Why) Baja a $range MT/s en la BIOS y, con lo que sobra de margen, aprieta los timings: rinde más que la velocidad alta." + $(if ($plan.X3d) { ' Con 3D V-Cache, además, la velocidad de RAM importa poco.' } else { '' }))
        } elseif ($plan -and $rated -gt $plan.Max -and $speed -ge $plan.Target - 100 -and $speed -le $plan.Max + 50) {
            $out += New-JuicerFinding $area 'Ok' "Bien elegido: tu kit es de $rated, pero en tu $($plan.Platform) lo que rinde es $range, y está a $speed" ($plan.Why + $(if ($plan.X3d) { ' Con 3D V-Cache la RAM importa todavía menos: no merece la pena forzarla.' } else { '' }))
        } elseif ($xmpKit -and $speed -gt 0 -and $best -gt 0 -and $speed -lt $best - 100) {
            $sev = if ($speed -le 0.85 * $best) { 'Alto' } else { 'Medio' }
            if ($plan -and $rated -gt $plan.Max) {
                $out += New-JuicerFinding $area $sev "La RAM va a $speed MT/s; en tu $($plan.Platform) lo óptimo es $range" "Tu kit ($($ratings[0].Brand) $($ratings[0].PartNumber)) es de $rated, pero no actives su XMP tal cual: $($plan.Why) Pon $($plan.Target) MT/s a mano en la BIOS, con los timings del XMP o algo más ajustados."
            } else {
                $out += New-JuicerFinding $area $sev "La RAM va a $speed MT/s, pero tu kit está certificado a $rated" "Lo dice su referencia ($($ratings[0].Brand) $($ratings[0].PartNumber)). Activa $xmp en la BIOS: en juegos limitados por CPU suele ser la mejora gratuita más grande que queda."
            }
        } elseif ($rated -eq 0) {
            $jedec = if ($type -eq 26) { 2666 } elseif ($type -eq 34) { 4800 } else { 0 }
            if ($jedec -and $speed -gt 0 -and $speed -le $jedec) {
                $label = if ($plan) { "$typeName-$range" } elseif ($type -eq 34) { 'DDR5-6000 o 6400' } else { 'DDR4-3200 o 3600' }
                $out += New-JuicerFinding $area 'Medio' "La RAM va a $speed MT/s, la velocidad estándar" ("Si tu kit es más rápido (mira la etiqueta), activa $xmp en la BIOS. En juegos limitados por CPU suele ser la mejora gratuita más grande que queda." + $(if ($plan) { " En tu $($plan.Platform), apunta a $label MT/s aunque el kit dé más: $($plan.Why)" } else { " Lo habitual: $label." }))
            }
        }
        if ($spd -and $speed -gt $spd + 100) {
            $out += New-JuicerFinding $area 'Info' "XMP/EXPO activo: $speed MT/s (sin él, $spd)" 'Es un overclock de memoria, certificado por el fabricante del kit. Si aparecen errores WHEA o pantallazos MEMORY_MANAGEMENT, es lo primero que hay que revisar.'
        }
    }
    $out
}

# Gpus are the traits of the graphics cards. On a desktop with a dedicated
# card, a monitor on the motherboard's outputs is drawn by the integrated
# graphics; on a laptop that is how hybrid graphics work, and fine.
function Get-JuicerDisplayFindings {
    param([object[]]$Displays, [object[]]$Gpus = @(), [bool]$Laptop)
    $out = @()
    $n = 0
    $dedicated = @($Gpus | Where-Object { $_.Discrete } | Select-Object -First 1)
    foreach ($d in $Displays) {
        $n++
        $name = if ($d.Monitor) { $d.Monitor } else { "Pantalla $n" }
        if (-not $Laptop -and $dedicated.Count -gt 0 -and $d.Adapter) {
            $a = Get-JuicerGpuTraits $d.Adapter
            if (-not $a.Discrete -and $a.Vendor -in 'Intel', 'AMD') {
                if ($d.Primary) {
                    $out += New-JuicerFinding 'Pantalla' 'Alto' "$name está conectada a la placa base, no a la $($dedicated[0].Name)" "La dibuja la $($a.Name): los juegos rinden mucho menos o pasan cada fotograma por ella. Conecta el cable a las salidas de la tarjeta gráfica, las que están más abajo, en horizontal."
                } else {
                    $out += New-JuicerFinding 'Pantalla' 'Info' "$name (secundaria) está conectada a la placa base" "Lo que se vea en ella lo dibuja la $($a.Name). Para un navegador o un chat vale; para jugar en ella, conéctala a la $($dedicated[0].Name)."
                }
            }
        }
        $sizes = @($d.Resolutions)
        $native = '{0}x{1}' -f $d.NativeWidth, $d.NativeHeight
        $below = $d.NativeWidth -gt 0 -and $d.Width -lt $d.NativeWidth -and $d.Height -lt $d.NativeHeight -and $sizes -contains $native
        if ($below) {
            $out += New-JuicerFinding 'Pantalla' 'Medio' "$name está a $($d.Width)×$($d.Height), pero su resolución nativa es $($d.NativeWidth)×$($d.NativeHeight)" 'Fuera de la nativa todo se ve algo borroso. Elige la marcada como «(recomendado)» en Configuración > Sistema > Pantalla; si es para ganar FPS, baja la resolución dentro del juego, no la de Windows.'
        }
        if ($d.MaxHz -gt $d.Hz + 1) {
            $out += New-JuicerFinding 'Pantalla' 'Alto' "$name funciona a $($d.Hz) Hz pero admite $($d.MaxHz) Hz" 'Cámbialo en Configuración > Sistema > Pantalla > Pantalla avanzada > Frecuencia de actualización. Si no aparece, el cable o el puerto no dan para más (usa DisplayPort o HDMI 2.1).'
        } elseif (-not $below) {
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

# The chassis first: a desktop with a UPS on USB has a «battery» too. The
# battery only decides when the chassis says nothing useful.
function Test-JuicerLaptop {
    try {
        $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction Stop).ChassisTypes | ForEach-Object { [int]$_ })
        return (Test-JuicerLaptopChassis $types (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0))
    } catch {
        return $false
    }
}

function Test-JuicerLaptopChassis {
    param([int[]]$Types = @(), [bool]$Battery)
    if (@($Types | Where-Object { $script:LaptopChassis -contains $_ }).Count -gt 0) { return $true }
    if (@($Types | Where-Object { $script:DesktopChassis -contains $_ }).Count -gt 0) { return $false }
    $Battery
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

# --- Windows support -------------------------------------------------------

# Last month of security updates for each version of Windows 11, by build:
# Home and Pro get 24 months, Enterprise and Education 36. Windows 10 ended
# in October 2025 for everyone; the paid extension (ESU) for homes ran out a
# year later. LTSC editions and Windows Server have their own dates and are
# left out.
$script:WindowsSupport = @{
    22000 = @{ Version = '21H2'; Home = '2023-10-10'; Business = '2024-10-08' }
    22621 = @{ Version = '22H2'; Home = '2024-10-08'; Business = '2025-10-14' }
    22631 = @{ Version = '23H2'; Home = '2025-11-11'; Business = '2026-11-10' }
    26100 = @{ Version = '24H2'; Home = '2026-10-13'; Business = '2027-10-12' }
    26200 = @{ Version = '25H2'; Home = '2027-10-12'; Business = '2028-10-10' }
}

# Null when the dates are unknown: LTSC, Insider, or a build newer than the
# table, which is newer than anything about to expire.
function Get-JuicerWindowsSupport {
    param([int]$Build, [string]$Edition)
    if ($Edition -cmatch 'S$|SN$' -or ($Edition -like 'Server*' -and $Edition -ne 'ServerRdsh')) { return $null }
    $business = $Edition -match '^(Enterprise|Education|IoTEnterprise|ServerRdsh)'
    if ($Build -gt 0 -and $Build -lt 22000) {
        return @{ Version = 'Windows 10'; End = [datetime]'2025-10-14'; Business = $business; Windows10 = $true }
    }
    $row = $script:WindowsSupport[$Build]
    if (-not $row) { return $null }
    @{ Version = $row.Version; End = [datetime]$(if ($business) { $row.Business } else { $row.Home }); Business = $business; Windows10 = $false }
}

function Get-JuicerWindowsSupportInfo {
    if (Test-JuicerInsider) { return $null }
    $e = Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'EditionID'
    Get-JuicerWindowsSupport (Get-JuicerWindowsBuild) $(if ($e) { [string]$e.Value } else { '' })
}

# Pinned is the version a TargetReleaseVersion policy holds the PC at (some
# debloat tools set it to dodge a new version); Deferral, the days feature
# updates are held back.
function Get-JuicerSupportFindings {
    param([hashtable]$Support, [datetime]$Now = (Get-Date), [string]$Pinned, [int]$Deferral)
    $out = @()
    if (-not $Support) { return $out }
    $end = $Support.End.ToString('d')
    $days = ($Support.End - $Now).TotalDays
    if ($Support.Windows10) {
        $extra = if ($Support.Business) { ' Salvo que tu empresa pague las actualizaciones extendidas (ESU), ya no hay parches.' } else { ' La extensión ESU para hogares terminó en octubre de 2026.' }
        $out += New-JuicerFinding 'Sistema' 'Alto' 'Windows 10 ya no recibe actualizaciones de seguridad' ('Terminó el {0}.{1} Si el equipo lo admite, Windows 11 es gratis desde Windows Update; si no, cada fallo nuevo queda abierto.' -f $end, $extra)
        return $out
    }
    $how = 'Instala la versión siguiente desde Configuración > Windows Update; es gratis y conserva programas y archivos.'
    if ($Pinned) {
        $how = "Una directiva fija el equipo en la versión $Pinned (TargetReleaseVersion; la ponen algunas herramientas de «debloat»). Bórrala de HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate. $how"
    } elseif ($Deferral -gt 0) {
        $how += " Tienes las versiones nuevas retrasadas $Deferral días: quita ese retraso (ajuste «Versiones nuevas de Windows con un año de retraso») para que llegue antes."
    }
    if ($days -lt 0) {
        $out += New-JuicerFinding 'Sistema' 'Alto' "Windows 11 $($Support.Version) ya no recibe actualizaciones de seguridad" "Dejó de recibirlas el $end. $how"
    } elseif ($days -lt 90) {
        $out += New-JuicerFinding 'Sistema' 'Medio' "Windows 11 $($Support.Version) deja de recibir actualizaciones de seguridad el $end" $how
    } else {
        $out += New-JuicerFinding 'Sistema' 'Ok' "Windows 11 $($Support.Version) recibe actualizaciones de seguridad hasta el $end"
    }
    $out
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

    $wu = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
    $pin = Read-JuicerReg $wu 'TargetReleaseVersion'
    $pinInfo = Read-JuicerReg $wu 'TargetReleaseVersionInfo'
    $defer = Read-JuicerReg $wu 'DeferFeatureUpdatesPeriodInDays'
    $deferOn = Read-JuicerReg $wu 'DeferFeatureUpdates'
    $out += Get-JuicerSupportFindings (Get-JuicerWindowsSupportInfo) `
        -Pinned $(if ($pin -and [int]$pin.Value -eq 1 -and $pinInfo) { [string]$pinInfo.Value }) `
        -Deferral $(if ($deferOn -and [int]$deferOn.Value -eq 1 -and $defer) { [int]$defer.Value } else { 0 })

    try {
        $mm = Get-JuicerUserMismatch
        if ($mm) {
            $out += New-JuicerFinding 'Sistema' 'Alto' "Win Juicer corre como $($mm.Me), pero la sesión es de $($mm.Session)" 'Los ajustes de usuario (ratón, animaciones, Game Bar…) se aplicarían a la cuenta de administrador, no a la tuya. Inicia sesión con tu cuenta y dale permisos de administrador.'
        }
    } catch {
        Write-Verbose "No se pudo comparar usuarios: $_"
    }
    $out
}

# The account that owns this session's explorer.exe, as @{ Domain; User } (null if unknown).
function Get-JuicerSessionUser {
    if (-not (Test-JuicerWindows)) { return $null }
    # The explorer of this session: other sessions (fast user switching, RDP) belong to other people.
    $session = [Diagnostics.Process]::GetCurrentProcess().SessionId
    $owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe' AND SessionId=$([int]$session)" -ErrorAction Stop | Select-Object -First 1 |
        Invoke-CimMethod -MethodName GetOwner -ErrorAction Stop
    if ($owner -and $owner.User) { return @{ Domain = [string]$owner.Domain; User = [string]$owner.User } }
    $null
}

# When Win Juicer runs elevated as someone other than the person at the screen (a UAC prompt
# answered with another admin account), HKCU is the admin's hive: per-user settings would go to
# the wrong account. Returns @{ Me; Session } or null when it is the same user or unknown.
function Get-JuicerUserMismatch {
    param([string]$Me = '')
    if (-not (Test-JuicerWindows)) { return $null }
    $me = if ($Me) { $Me } else { [Security.Principal.WindowsIdentity]::GetCurrent().Name }
    $owner = Get-JuicerSessionUser
    if ($owner -and -not (Test-JuicerSameUser $me $owner.Domain $owner.User)) { return @{ Me = $me; Session = "$($owner.Domain)\$($owner.User)" } }
    $null
}

# The warning for Get-JuicerUserMismatch's result (GUI Home and console). Warning only.
function Get-JuicerUserMismatchText {
    param($Mismatch)
    "Atención: Win Juicer corre como $($Mismatch.Me), pero la sesión abierta es de $($Mismatch.Session). Los ajustes de usuario (ratón, animaciones, Game Bar…) se aplicarán a la cuenta $($Mismatch.Me), no a la tuya. Para evitarlo, inicia sesión con tu cuenta y dale permisos de administrador."
}

# Whether DOMAIN\user (as WindowsIdentity names it) is the account Domain and
# User name. -eq is case-insensitive and, unlike -like, takes no wildcards, so
# a user name with [ or * in it cannot match by accident.
function Test-JuicerSameUser {
    param([string]$Me, [string]$Domain, [string]$User)
    $name = ($Me -split '\\', 2)[-1]
    $dom = if ($Me.Contains('\')) { ($Me -split '\\', 2)[0] } else { '' }
    if ($name -ne $User) { return $false }
    -not ($dom -and $Domain -and $dom -ne $Domain)
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
        if ($cpu.Hybrid -and $cpu.Vendor -eq 'Intel' -and (Get-JuicerWindowsBuild) -lt 22000) {
            $out += New-JuicerFinding 'Procesador' 'Alto' 'Procesador híbrido de Intel con Windows 10' 'Windows 10 no entiende Thread Director: puede dejar el juego en los núcleos de eficiencia, con tirones y FPS bajos. Windows 11 es la mejora más grande para este procesador; mientras tanto, desactivar los núcleos E en la BIOS lo evita.'
        }
    } else {
        $out += New-JuicerFinding 'Procesador' 'Info' 'No se pudo leer el procesador.'
    }
    try {
        $out += Get-JuicerRamFindings @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop) $laptop $cpu
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

# How old a graphics driver may get before it is worth a warning, and where to get the
# new one. Dedicated cards (NVIDIA, AMD, Intel Arc) get the new games' fixes in driver
# releases every few weeks: half a year is already behind. An Intel or AMD integrated
# GPU changes much less: a year. Null when the driver is recent enough, its age is
# unknown (Age < 0) or the card is not one of these vendors.
function Get-JuicerDriverAgeFinding {
    param([string]$Name, [int]$Age)
    if ($Age -lt 0 -or -not $Name) { return $null }
    $t = Get-JuicerGpuTraits $Name
    $url = switch ($t.Vendor) {
        'NVIDIA' { 'https://www.nvidia.com/drivers' }
        'AMD' { 'https://www.amd.com/support' }
        'Intel' { 'https://www.intel.com/content/www/us/en/support/detect.html' }
        default { $null }
    }
    if (-not $url) { return $null }
    $limit = if ($t.Discrete) { 180 } else { 365 }
    if ($Age -le $limit) { return $null }
    if ($t.Legacy) {
        # Maxwell/Pascal and older, Polaris and Vega: the vendor moved them to a legacy
        # branch with no regular releases, so an old driver is probably the newest there is.
        return (New-JuicerFinding 'Gráfica' 'Info' "El driver de $Name tiene $Age días" "Para esta tarjeta el fabricante ya sólo publica drivers de mantenimiento: puede que el que tienes sea el último disponible. Si quieres comprobarlo: $url")
    }
    $span = if ($limit -eq 180) { 'más de seis meses' } else { 'más de un año' }
    New-JuicerFinding 'Gráfica' 'Medio' "El driver de $Name tiene $span ($Age días)" "Los drivers nuevos traen optimizaciones y arreglos para juegos recientes. Descárgalo de la web del fabricante: $url"
}

# Resizable BAR only exists on cards whose firmware and driver support it: NVIDIA
# RTX 30 and later, AMD RX 6000 and later, Intel Arc. On anything older it cannot be
# turned on, so judging it would flag a «problem» nobody can fix. Takes the traits of
# Get-JuicerGpuTraits; false for unknown cards.
function Test-JuicerRebarCapable {
    param($Traits)
    if (-not $Traits) { return $false }
    switch ($Traits.Vendor) {
        'NVIDIA' { return ($null -ne $Traits.Series -and [int]$Traits.Series -ge 30) }
        'AMD' { return ($Traits.Discrete -and $null -ne $Traits.Series -and [int]$Traits.Series -ge 6) }
        'Intel' { return [bool]$Traits.Arc }
        default { return $false }
    }
}

function Get-JuicerGraphicsAudit {
    $out = @()
    $real = @()
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
            $stale = Get-JuicerDriverAgeFinding $g.Name $age
            if ($stale) { $out += $stale }
        }
    } catch {
        $out += New-JuicerFinding 'Gráfica' 'Info' 'No se pudo leer la tarjeta gráfica.'
    }

    try {
        $out += Get-JuicerDisplayFindings (Get-JuicerDisplays) @($real | ForEach-Object { Get-JuicerGpuTraits $_.Name }) (Test-JuicerLaptop)
    } catch {
        $out += New-JuicerFinding 'Pantalla' 'Info' 'No se pudieron leer los modos de pantalla.'
    }

    try {
        $traits = @($real | ForEach-Object { Get-JuicerGpuTraits $_.Name })
        $main = @($traits | Where-Object { $_.Discrete }) + @($traits) | Select-Object -First 1
        $out += Get-JuicerMonitorFindings @(Get-JuicerMonitors) $(if ($main) { $main.Vendor } else { '' }) @(Read-JuicerFrameHistory)
    } catch {
        Write-Verbose "Sin datos del monitor: $_"
    }

    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    $barCapable = @($real | ForEach-Object { Get-JuicerGpuTraits $_.Name } | Where-Object { $_.Vendor -eq 'NVIDIA' -and (Test-JuicerRebarCapable $_) }).Count -gt 0
    if ($barCapable -and (Test-Path -LiteralPath $smi)) {
        $r = Invoke-JuicerNative $smi @('-q', '-d', 'MEMORY') -TimeoutSec 8
        $bar = ConvertFrom-JuicerNvidiaSmi $r.Output
        if ($bar -and -not $bar.Rebar) {
            $out += New-JuicerFinding 'Gráfica' 'Medio' 'Resizable BAR desactivado' 'Actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support»). NVIDIA lo usa juego a juego: según el título, de nada a un 10 %.'
        } elseif ($bar) {
            $out += New-JuicerFinding 'Gráfica' 'Ok' 'Resizable BAR activado'
        }
    }
    $out
}

# What each disk says about itself: Windows' health verdict and, from the
# SMART counters, how much of its rated life an SSD has used (Wear, in %),
# its temperature and the reads it could not recover.
function Get-JuicerDiskHealth {
    foreach ($d in @(Get-PhysicalDisk -ErrorAction Stop)) {
        $c = $null
        try { $c = $d | Get-StorageReliabilityCounter -ErrorAction Stop } catch { Write-Verbose "Sin contadores de $($d.FriendlyName): $_" }
        @{
            Name = [string]$d.FriendlyName; Media = [string]$d.MediaType; Health = [string]$d.HealthStatus
            Wear = $(if ($c) { $c.Wear }); Temperature = $(if ($c) { $c.Temperature }); ReadErrors = $(if ($c) { $c.ReadErrorsUncorrected })
        }
    }
}

function Get-JuicerDiskHealthFindings {
    param([object[]]$Disks)
    $out = @()
    foreach ($d in $Disks) {
        if ($d.Health -and $d.Health -ne 'Healthy') {
            $out += New-JuicerFinding 'Disco' 'Alto' "El disco $($d.Name) informa de un estado «$($d.Health)»" 'Haz copia de seguridad cuanto antes; un disco que falla también se vuelve lento.'
            continue
        }
        if ($d.ReadErrors -gt 0) {
            $out += New-JuicerFinding 'Disco' 'Alto' "El disco $($d.Name) tiene $($d.ReadErrors) lecturas que no pudo recuperar" 'Son datos que se han perdido o están a punto. Haz copia de seguridad y vigílalo con CrystalDiskInfo.'
        }
        # SSDs only: a hard disk reports no wear, or nonsense.
        if ($null -ne $d.Wear -and ($d.Media -eq 'SSD' -or ($d.Media -ne 'HDD' -and $d.Wear -gt 0))) {
            $w = [int]$d.Wear
            if ($w -ge 90) {
                $out += New-JuicerFinding 'Disco' 'Alto' "El SSD $($d.Name) ha gastado el $w % de su vida útil" 'Pasado el 100 % sigue funcionando, pero el fabricante ya no garantiza que guarde los datos. Haz copia de seguridad y planea cambiarlo.'
            } elseif ($w -ge 70) {
                $out += New-JuicerFinding 'Disco' 'Medio' "El SSD $($d.Name) ha gastado el $w % de su vida útil" 'Aún le queda, pero ten copia de seguridad de lo importante.'
            } else {
                $out += New-JuicerFinding 'Disco' 'Ok' "SSD $($d.Name): $w % de su vida útil gastada"
            }
        }
        # Outside 1–110 °C the sensor is not reporting.
        $t = [int]$d.Temperature
        if ($t -ge 70 -and $t -le 110) {
            $out += New-JuicerFinding 'Disco' 'Medio' "El disco $($d.Name) está a $t °C" 'A partir de unos 70 °C los NVMe bajan la velocidad para protegerse. Un disipador (muchas placas traen uno para el M.2) o más flujo de aire en la caja lo evita.'
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
        $out += Get-JuicerDiskHealthFindings (Get-JuicerDiskHealth)
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
        $last = Get-JuicerLastBoot
        if ($last) {
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
        $items = @(Get-JuicerStartupReview)
        $on = @($items | Where-Object { $_.Enabled })
        $junk = @($on | Where-Object { $_.Verdict -eq 'Prescindible' })
        $sev = if ($on.Count -gt 12 -or $junk.Count -ge 4) { 'Medio' } elseif ($on.Count -gt 6 -or $junk.Count -gt 0) { 'Bajo' } else { 'Ok' }
        $detail = 'Desactiva en Programas de inicio los que no necesites nada más encender.'
        if ($junk.Count -gt 0) { $detail = "$($junk.Count) son prescindibles: $(($junk | ForEach-Object { $_.Name }) -join ', '). Funcionan igual abriéndolos cuando los necesites. " + $detail }
        $out += New-JuicerFinding 'Arranque' $sev $(if ($on.Count -eq 1) { 'Un programa, tarea o servicio arranca con Windows' } else { "$($on.Count) programas, tareas y servicios arrancan con Windows" }) $detail
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
        $out += New-JuicerFinding 'Ajustes' 'Bajo' "$(Format-JuicerCount $pending.Count 'ajuste') del perfil Seguro sin aplicar" (($pending | ForEach-Object { $_.Title }) -join ', ')
    }
    $out
}

# The diagnosis as a text file, to keep or to paste in a forum when asking
# for help: the most important first, then everything by area.
function Format-JuicerAuditReport {
    param([string[]]$Summary = @(), [object[]]$Findings = @(), [datetime]$When = (Get-Date))
    $labels = @{ Alto = 'ALTO'; Medio = 'MEDIO'; Bajo = 'BAJO'; Info = 'INFO'; Ok = 'OK' }
    $l = New-Object System.Collections.ArrayList
    [void]$l.Add(('Win Juicer — diagnóstico del {0}' -f $When.ToString('g')))
    [void]$l.Add('')
    [void]$l.Add('Este equipo')
    foreach ($s in $Summary) { [void]$l.Add("  $s") }
    $top = @($Findings | Where-Object { $_.Severity -in 'Alto', 'Medio' } | Sort-Object { $script:SeverityOrder[$_.Severity] })
    if ($top.Count -gt 0) {
        [void]$l.Add('')
        [void]$l.Add('Lo que más rinde arreglar')
        $n = 0
        foreach ($f in $top) { $n++; [void]$l.Add(('  {0}. [{1}] {2}' -f $n, $labels[$f.Severity], $f.Title)) }
    }
    $area = ''
    foreach ($f in $Findings) {
        if ($f.Area -ne $area) { $area = $f.Area; [void]$l.Add(''); [void]$l.Add($area) }
        [void]$l.Add(('  [{0}] {1}' -f $labels[$f.Severity], $f.Title))
        if ($f.Detail) { [void]$l.Add("        $($f.Detail)") }
    }
    ($l -join [Environment]::NewLine) + [Environment]::NewLine
}

function Save-JuicerAuditReport {
    param([string]$Path, [string[]]$Summary, [object[]]$Findings)
    if (-not $Path) { $Path = Join-Path ([Environment]::GetFolderPath('Desktop')) ('WinJuicer-diagnostico-{0:yyyyMMdd-HHmm}.txt' -f (Get-Date)) }
    # With BOM, so the Notepad of any Windows reads the accents right.
    [IO.File]::WriteAllText($Path, (Format-JuicerAuditReport $Summary $Findings), (New-Object Text.UTF8Encoding $true))
    $Path
}

# OnSection, if given, is told the name of each part as it starts: the
# window shows it while the diagnosis runs.
# Undervolt and overclock: the recipe for this processor and card, and
# whether what was applied is still there and stable.
function Get-JuicerFineTuneAudit {
    $gpus = @()
    try { $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction Stop | ForEach-Object { Get-JuicerGpuTraits $_.Name }) } catch { Write-Verbose "Sin gráficas: $_" }
    $out = @(Get-JuicerTuneCheck)
    $out += Get-JuicerTuneGuideFindings (Get-JuicerCpuInfo) $gpus (Test-JuicerLaptop)
    $out
}

function Get-JuicerAudit {
    param([scriptblock]$OnSection)
    $sections = @(
        @('Sistema', ${function:Get-JuicerSystemAudit}), @('Procesador y memoria', ${function:Get-JuicerHardwareAudit}),
        @('Overclock y BIOS', ${function:Get-JuicerTuningAudit}), @('Estabilidad', ${function:Get-JuicerStabilityAudit}),
        @('Gráfica', ${function:Get-JuicerGraphicsAudit}), @('Gráfica', ${function:Get-JuicerGpuTuningAudit}), @('Combinaciones', ${function:Get-JuicerComboAudit}),
        @('Discos', ${function:Get-JuicerStorageAudit}), @('Red', ${function:Get-JuicerNetworkAudit}),
        @('Seguridad', ${function:Get-JuicerSecurityAudit}), @('Arranque', ${function:Get-JuicerBootAudit}),
        @('Programas', ${function:Get-JuicerSoftwareAudit}), @('Ajuste fino', ${function:Get-JuicerFineTuneAudit}),
        @('Ajustes', ${function:Get-JuicerCatalogAudit})
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

# --- Ready to play ------------------------------------------------------------------
#
# What matters for a game, in one glance, read-only. The builder is pure (fake inputs in the
# tests); Get-JuicerReadyInputs reads this PC. Anything that could not be read is null in the
# inputs and simply not in the list: «unknown» is never shown as good or as bad.

# The plan by its GUID: Rendimiento (Win Juicer's, Ultimate, High performance), Equilibrado,
# Economizador, or Otro.
function Get-JuicerPlanKind {
    param([string]$Guid)
    $g = ([string]$Guid).Trim().ToLowerInvariant()
    if (-not $g) { return $null }
    if ($g -in $script:JuicerPlan, $script:UltimatePlan, $script:HighPerfPlan) { return 'Rendimiento' }
    if ($g -eq $script:BalancedPlan) { return 'Equilibrado' }
    if ($g -eq $script:PowerSaverPlan) { return 'Economizador' }
    'Otro'
}

# In: GameMode, HagsConfigured, HagsRestart (configured after the last boot), Windowed, Rebar
# (booleans or null); GameDvr (Game Bar records in the background: true, false or null);
# PlanKind and CpuMax (the processor's maximum state plugged in, %);
# OnBattery (null on a desktop); MonitorHz and MonitorMaxHz (0 when unknown);
# Vbs and Hvci (virtualization-based security / memory integrity running, null unknown).
# Out: @{ Key; Ok; Info; Title; Reason } per thing known, always in the same order. Info lines
# are context, not a verdict: they carry Ok = true so nothing counts them as «por mirar».
function Get-JuicerReadyStatus {
    param([hashtable]$In)
    $out = New-Object System.Collections.ArrayList
    $add = { param($k, $ok, $t, $r) [void]$out.Add(@{ Key = $k; Ok = [bool]$ok; Title = $t; Reason = $r }) }
    if ($null -ne $In.GameMode) {
        if ($In.GameMode) { & $add 'modo' $true 'Modo juego activado' '' }
        else { & $add 'modo' $false 'Modo juego desactivado' 'Windows no prioriza el juego en primer plano. Actívalo en Configuración > Juegos > Modo de juego, o con el ajuste «juegos.modo».' }
    }
    if ($null -ne $In.HagsConfigured) {
        if (-not $In.HagsConfigured) {
            & $add 'hags' $false 'Programación de GPU acelerada por hardware desactivada' 'Baja algo la latencia y es obligatoria para la generación de fotogramas de DLSS. Ajuste «juegos.hags» (hace falta reiniciar).'
        } elseif ($In.HagsRestart) {
            & $add 'hags' $false 'Programación de GPU acelerada por hardware: configurada, pero aún no activa' 'Está puesta, pero Windows no la usa hasta reiniciar (Reiniciar, no Apagar: con el Inicio rápido apagar no cuenta).'
        } else {
            & $add 'hags' $true 'Programación de GPU acelerada por hardware activa' ''
        }
    }
    if ($null -ne $In.Windowed) {
        if ($In.Windowed) { & $add 'ventana' $true 'Optimizaciones para juegos en ventana activadas' '' }
        else { & $add 'ventana' $false 'Optimizaciones para juegos en ventana desactivadas' 'Los juegos DirectX 10 y 11 en ventana o sin bordes no usan el modelo de presentación moderno: más latencia, y sin VRR en ventana. Ajuste «juegos.ventana».' }
    }
    if ($null -ne $In.GameDvr) {
        if ($In.GameDvr) { & $add 'grabacion' $false 'Game Bar graba en segundo plano' 'Graba en segundo plano: cuesta FPS aunque nunca guardes un clip. Ajuste «juegos.grabacion» (no afecta a NVIDIA, AMD ni OBS).' }
        else { & $add 'grabacion' $true 'Sin grabación de Game Bar en segundo plano' '' }
    }
    if ($null -ne $In.Rebar) {
        if ($In.Rebar) { & $add 'rebar' $true 'Resizable BAR activado' '' }
        else { & $add 'rebar' $false 'Resizable BAR desactivado' 'Actívalo en la BIOS («Above 4G Decoding» y «Re-Size BAR Support»). Ningún programa puede hacerlo desde Windows.' }
    }
    if ($In.PlanKind) {
        $cap = $null -ne $In.CpuMax -and [int]$In.CpuMax -gt 0 -and [int]$In.CpuMax -lt 100
        if ($In.PlanKind -eq 'Economizador') {
            & $add 'energia' $false 'Plan de energía: Economizador' 'Limita el procesador para ahorrar energía, también enchufado. Elige «Equilibrado» o el plan de Win Juicer (ajuste «energia.plan»).'
        } elseif ($cap) {
            & $add 'energia' $false ('El plan de energía limita el procesador al {0} %' -f [int]$In.CpuMax) 'Alguien bajó el «Estado máximo del procesador»: nunca llega a su frecuencia máxima. Súbelo a 100 % en Opciones de energía, o aplica el plan de Win Juicer («energia.plan»).'
        } else {
            $name = switch ($In.PlanKind) { 'Rendimiento' { 'máximo rendimiento' } 'Equilibrado' { 'Equilibrado' } default { 'personalizado' } }
            & $add 'energia' $true "Plan de energía: $name" ''
        }
    }
    if ($null -ne $In.OnBattery) {
        if ($In.OnBattery) { & $add 'bateria' $false 'Funcionando con batería' 'El portátil limita procesador y gráfica aunque elijas el máximo rendimiento. Para jugar, conecta el cargador.' }
        else { & $add 'bateria' $true 'Enchufado a la corriente' '' }
    }
    $hz = [int]$In.MonitorHz
    $max = [int]$In.MonitorMaxHz
    if ($hz -gt 0 -and $max -gt 0) {
        if ($max -gt $hz + 1) { & $add 'monitor' $false "Monitor a $hz Hz, admite $max Hz" 'Cámbialo en Configuración > Sistema > Pantalla > Pantalla avanzada > Frecuencia de actualización. Si no aparece, el cable o el puerto no dan para más.' }
        else { & $add 'monitor' $true "Monitor a su frecuencia máxima ($hz Hz)" '' }
    }
    # Information only, never a warning: it protects the kernel and costs some FPS, and what to do
    # about it is a decision about security (disabling it is Extremo). Not running: nothing to say.
    if ($In.Vbs -eq $true) {
        $what = if ($In.Hvci -eq $true) { 'con integridad de memoria (HVCI)' } else { 'sin integridad de memoria' }
        [void]$out.Add(@{ Key = 'vbs'; Ok = $true; Info = $true; Title = "Seguridad basada en virtualización activa, $what"
                Reason = 'Protege el núcleo de Windows a cambio de algo de rendimiento en juegos. Sólo informativo: quitarla es del nivel Extremo («seguridad.integridad») y decides tú, sabiendo qué pierdes.' })
    }
    $out.ToArray()
}

# Whether a setting Win Juicer applied (the journal entry) was last written after the
# given boot, i.e. it still waits for a restart. The last write counts, not the first:
# a setting changed again after a reboot needs another one. Entries from before
# LastAppliedAt existed fall back to AppliedAt.
function Test-JuicerAppliedAfterBoot {
    param($Entry, $Boot)
    if (-not $Entry -or -not $Boot) { return $false }
    $when = if ($Entry.LastAppliedAt) { $Entry.LastAppliedAt } else { $Entry.AppliedAt }
    if (-not $when) { return $false }
    try { ([datetime]$when) -gt $Boot } catch { $false }
}

# Windowed-game optimizations as Windows has them: true or false only when the
# DirectXUserGlobalSettings string says so. Without the SwapEffectUpgradeEnable
# token Windows uses its own default for the build, which this cannot see: null (unknown),
# not «off».
function Get-JuicerWindowedState {
    $reg = Read-JuicerReg 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings'
    $v = Get-JuicerTokenValue (ConvertFrom-JuicerTokenString (Get-JuicerRegString $reg)) 'SwapEffectUpgradeEnable'
    if ($null -eq $v) { return $null }
    [string]$v -eq '1'
}

# Whether Game Bar records in the background, by the values the juegos.grabacion tweak writes:
# true only when background capture is switched on and nothing switches the capture off; false
# when one of the three says off; null when none can be read (an absent value is Windows's own
# default, which this cannot see).
function Get-JuicerGameDvrState {
    $vals = @{}
    foreach ($spec in @(
            @('HKCU\System\GameConfigStore', 'GameDVR_Enabled'),
            @('HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'AppCaptureEnabled'),
            @('HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR', 'HistoricalCaptureEnabled'))) {
        $v = Read-JuicerReg $spec[0] $spec[1]
        if ($v -and $null -ne $v.Value) { $vals[$spec[1]] = [int]$v.Value }
    }
    if ($vals.Count -eq 0) { return $null }
    foreach ($k in $vals.Keys) { if ($vals[$k] -eq 0) { return $false } }
    # Everything readable says on, but background recording itself must be said: otherwise unknown.
    if ($vals.ContainsKey('HistoricalCaptureEnabled')) { return $true }
    $null
}

# Reads this PC for Get-JuicerReadyStatus. Each part on its own: one that fails is unknown.
function Get-JuicerReadyInputs {
    $in = @{ GameMode = $null; HagsConfigured = $null; HagsRestart = $false; Windowed = $null; GameDvr = $null; Rebar = $null; PlanKind = $null; CpuMax = $null; OnBattery = $null; MonitorHz = 0; MonitorMaxHz = 0; Vbs = $null; Hvci = $null }
    if (-not (Test-JuicerWindows)) { return $in }
    try {
        # Windows 11 has it on until someone turns it off: a missing value is «on».
        $gm = Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled'
        $in.GameMode = -not ($gm -and $null -ne $gm.Value -and [int]$gm.Value -eq 0)
    } catch { Write-Verbose "Sin modo juego: $_" }

    $hw = $null
    try { $hw = Get-JuicerHardwareProfile } catch { Write-Verbose "Sin hardware: $_" }
    $main = $null
    if ($hw) { $main = @(@($hw.Gpus | Where-Object { $_.Discrete }) + @($hw.Gpus)) | Where-Object { $_ } | Select-Object -First 1 }
    try {
        # Unset means the driver decides, which this cannot see: unknown. And a card that has no
        # hardware scheduling has nothing to configure.
        $h = Read-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
        if ($h -and $null -ne $h.Value -and -not ($main -and $main.Hags -eq $false)) {
            $in.HagsConfigured = ([int]$h.Value -eq 2)
            if ($in.HagsConfigured) {
                # What takes effect at the next boot is only «active» once there has been one: if Win Juicer
                # set it after the last boot, it still waits.
                $e = Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.hags'
                $boot = (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime
                $in.HagsRestart = Test-JuicerAppliedAfterBoot $e $boot
            }
        }
    } catch { Write-Verbose "Sin HAGS: $_" }
    try { $in.Windowed = Get-JuicerWindowedState } catch { Write-Verbose "Sin optimizaciones de ventana: $_" }
    try { $in.GameDvr = Get-JuicerGameDvrState } catch { Write-Verbose "Sin grabación de Game Bar: $_" }
    try {
        # The same class the security audit reads: 2 is «running».
        $dg = Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $in.Vbs = ([int]$dg.VirtualizationBasedSecurityStatus -eq 2)
        $in.Hvci = $in.Vbs -and (@($dg.SecurityServicesRunning) -contains 2)
    } catch { Write-Verbose "Sin estado de VBS: $_" }
    try {
        # Only cards that support Resizable BAR are judged; on the rest it stays unknown.
        if ($main -and $main.Discrete -and (Test-JuicerRebarCapable $main)) {
            $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
            if ($main.Vendor -eq 'NVIDIA' -and (Test-Path -LiteralPath $smi)) {
                $bar = ConvertFrom-JuicerNvidiaSmi (Invoke-JuicerNative $smi @('-q', '-d', 'MEMORY') -TimeoutSec 8).Output
                if ($bar) { $in.Rebar = [bool]$bar.Rebar }
            } elseif ($main.Vendor -ne 'NVIDIA') {
                $in.Rebar = Test-JuicerRebarRanges (Get-JuicerGpuMemoryRanges $main.PnpId)
            }
        }
    } catch { Write-Verbose "Sin Resizable BAR: $_" }
    try {
        $plan = Get-JuicerActivePlan
        $in.PlanKind = Get-JuicerPlanKind $plan
        $max = ConvertFrom-JuicerPowerSetting (Invoke-JuicerNative 'powercfg.exe' @('/qh', 'SCHEME_CURRENT', 'SUB_PROCESSOR', 'PROCTHROTTLEMAX')).Output
        if ($max) { $in.CpuMax = [int]$max.AC }
    } catch { Write-Verbose "Sin plan de energía: $_" }
    if ($hw -and $hw.Laptop) {
        # Read again: the profile is from when Win Juicer opened, and the charger may have moved since.
        $in.OnBattery = [bool]$hw.OnBattery
        $in.OnBattery = Test-JuicerOnBattery
    }
    try {
        $m = Get-JuicerPrimaryMonitor
        if ($m) { $in.MonitorHz = [int]$m.Display.Hz; $in.MonitorMaxHz = [int]$m.Display.MaxHz }
    } catch { Write-Verbose "Sin monitor: $_" }
    $in
}

function Get-JuicerReady { Get-JuicerReadyStatus (Get-JuicerReadyInputs) }
