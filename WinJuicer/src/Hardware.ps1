# What this PC is made of, read once per session. The advisor decides from it
# which tweaks suit this machine, and the hardware review looks for what is
# set wrong in it. Reading and understanding are kept apart: everything that
# interprets a name, a part number or a register value is a pure function, so
# it is tested on any OS with the strings real machines report.

# --- Processor ---------------------------------------------------------------

# "Intel64 Family 6 Model 183 Stepping 1", "AMD64 Family 25 Model 97 Stepping 2"
function ConvertFrom-JuicerCpuIdentifier {
    param([string]$Identifier)
    if ($Identifier -match 'Family\s+(\d+)\s+Model\s+(\d+)\s+Stepping\s+(\d+)') {
        return @{ Family = [int]$Matches[1]; Model = [int]$Matches[2]; Stepping = [int]$Matches[3] }
    }
    $null
}

# «Update Revision» holds the raw microcode MSR: Intel keeps the revision in
# the high half, AMD in the low one.
function ConvertFrom-JuicerMicrocode {
    param($Bytes, [string]$Vendor)
    $b = [byte[]]@($Bytes | ForEach-Object { [byte]$_ })
    if ($b.Count -lt 8) { return $null }
    $rev = if ($Vendor -eq 'AMD') { [BitConverter]::ToUInt32($b, 0) } else { [BitConverter]::ToUInt32($b, 4) }
    if ($rev -eq 0) { return $null }
    [int64]$rev
}

function Get-JuicerCpuTraits {
    param(
        [string]$Name = '', [string]$Vendor = '', [int]$Cores = 0, [int]$Threads = 0,
        [string]$Identifier = '', [int[]]$EfficiencyClasses = @(), $Microcode = $null
    )
    $v = if ($Vendor -match 'Intel' -or $Name -match 'Intel') { 'Intel' } elseif ($Vendor -match 'AMD' -or $Name -match 'AMD|Ryzen') { 'AMD' } else { 'Otro' }
    $id = ConvertFrom-JuicerCpuIdentifier $Identifier
    # Mobile parts end the model number in a letter the desktop ones never
    # use. Only the model number: «Radeon 760M» in an 8600G is the iGPU.
    $mobile = $Name -match 'Ryzen [3579] (?:PRO )?\d{4}(?:HX3D|HX|HS|H|U)\b' -or $Name -match 'Ryzen AI' -or
    $Name -match 'i[3579]-\d{4,5}(?:HX|HK|HS|H|U|P|Y|G\d)\b' -or $Name -match '(?:Ultra|Core(?:\(TM\))?) [3579] \d{3}[HUVP]\b'
    $classes = @($EfficiencyClasses | Select-Object -Unique)
    $hybrid = if ($classes.Count -gt 0) { $classes.Count -gt 1 } else {
        # Without the API: 12th-14th gen Core have threads only on P-cores.
        $v -eq 'Intel' -and $Threads -gt $Cores -and $Threads -lt 2 * $Cores
    }
    $x3d = $Name -match 'X3D'
    $t = @{
        Name = $Name.Trim(); Vendor = $v; Cores = $Cores; Threads = $Threads; Mobile = [bool]$mobile; Hybrid = [bool]$hybrid
        Family = $(if ($id) { $id.Family }); Model = $(if ($id) { $id.Model }); Stepping = $(if ($id) { $id.Stepping })
        Microcode = $Microcode
        X3D = [bool]$x3d
        # The 7900X3D, 7950X3D, 9900X3D, 9950X3D and 7945HX3D carry the
        # cache on one of their two CCDs only.
        DualCcdX3D = [bool]($Name -match 'Ryzen 9 \d{4}H?X3D')
        # Raptor Lake die (CPUID model 183): the 13th/14th gen desktop chips
        # that degrade without microcode 0x12B.
        RaptorLake = [bool]($v -eq 'Intel' -and $id -and $id.Family -eq 6 -and $id.Model -eq 183 -and -not $mobile)
        Am5 = [bool]($v -eq 'AMD' -and -not $mobile -and $Name -match 'Ryzen [3579] (?:7\d{3}|8\d{3}(?=[GF])|9\d{3})(?:X3D|XT|X|F|GT|G|E)?\b')
        Am4 = [bool]($v -eq 'AMD' -and -not $mobile -and $Name -match 'Ryzen [3579] [1-5]\d{3}(?:X3D|XT|X|GE|G|F|E|AF)?\b')
    }
    $t
}

# --- Processor and memory together ----------------------------------------

# The memory speed each platform runs best at, which is not always the
# fastest the kit is sold at. On AM4 the Infinity Fabric (FCLK) has to run at
# half the memory's transfer rate to stay 1:1; most Zen 3 chips top out at
# FCLK 1800-1900, so DDR4-4000 drops to 2:1 and its extra bandwidth comes with
# more latency than it gains. AM5 keeps the controller 1:1 up to about 6400;
# beyond that it goes 1:2. Intel 12th-14th gen run DDR4 in Gear 1 up to about
# 3600-3733 and DDR5 always in Gear 2, where speed is speed. APUs have a
# stronger fabric and their integrated graphics want every MT/s. Null when
# the platform has no such ceiling or is not recognised: then the kit's
# rating is the target.
function Get-JuicerMemoryPlan {
    param([hashtable]$Cpu, [string]$Ddr)
    if (-not $Cpu -or -not $Cpu.Name -or $Cpu.Mobile) { return $null }
    $n = $Cpu.Name
    $plan = $null
    if ($Cpu.Vendor -eq 'AMD' -and $Ddr -eq 'DDR4') {
        if ($n -match 'Ryzen [3579] (?:[12]\d{3}|3\d{3}G)') {
            $plan = @{ Target = 3200; Max = 3466; Platform = 'Ryzen de primera o segunda generación (Zen/Zen+)'; Why = 'Su Infinity Fabric ronda los 1600-1733 MHz: por encima de 3200-3466 MT/s la memoria deja de ir sincronizada con él.' }
        } elseif ($n -match 'Ryzen [3579] [45]\d{3}G') {
            $plan = @{ Target = 4000; Max = 4400; Platform = 'APU Ryzen (Renoir/Cezanne)'; Apu = $true; Why = 'Las APU sostienen un Infinity Fabric de 2000-2200 MHz: hasta 4000-4400 MT/s en 1:1, y su gráfica integrada aprovecha cada MT/s.' }
        } elseif ($n -match 'Ryzen [3579] 3\d{3}') {
            $plan = @{ Target = 3600; Max = 3733; Platform = 'Ryzen 3000 (Zen 2)'; Why = 'Su Infinity Fabric llega a 1800-1866 MHz: 3600-3733 MT/s en 1:1. Más arriba pasa a 2:1 y la latencia sube más de lo que gana el ancho de banda.' }
        } elseif ($n -match 'Ryzen [3579] 5\d{3}') {
            $plan = @{ Target = 3600; Max = 3800; Platform = 'Ryzen 5000 (Zen 3)'; Why = 'Su Infinity Fabric (FCLK) llega casi siempre a 1800 MHz y a veces a 1900: 3600 MT/s en 1:1, o 3800 si tu FCLK aguanta 1900 sin errores WHEA. A 4000 haría falta FCLK 2000, que casi ningún Zen 3 sostiene: pasa a 2:1 y rinde menos.' }
        }
    } elseif ($Cpu.Vendor -eq 'AMD' -and $Ddr -eq 'DDR5') {
        if ($n -match 'Ryzen [3579] 8\d{3}G') {
            $plan = @{ Target = 6400; Max = 8000; Platform = 'APU Ryzen 8000G'; Apu = $true; Why = 'Las APU de AM5 sostienen más velocidad en 1:1 y su gráfica integrada la aprovecha: cuanto más rápida, mejor.' }
        } elseif ($n -match 'Ryzen [3579] [79]\d{3}') {
            $plan = @{ Target = 6000; Max = 6400; Platform = 'Ryzen de AM5 (Zen 4/Zen 5)'; Why = 'El controlador va 1:1 con la memoria hasta unos 6000-6400 MT/s; por encima pasa a 1:2 y la latencia sube. DDR5-6000 CL30 es el punto dulce; 8000 en 1:2 sólo compensa con placas de dos ranuras y mucho ajuste.' }
        }
    } elseif ($Cpu.Vendor -eq 'Intel' -and $Ddr -eq 'DDR4') {
        if ($n -match 'i[3579]-1[1-4]\d{3}') {
            $plan = @{ Target = 3600; Max = 3733; Platform = 'Intel de 11.ª a 14.ª generación con DDR4'; Why = 'Con DDR4 el controlador va en Gear 1 hasta unos 3600-3733 MT/s; por encima pasa a Gear 2, con bastante más latencia.' }
        }
    }
    if ($plan -and $Cpu.X3D) { $plan.X3d = $true }
    $plan
}

# --- Graphics --------------------------------------------------------------

function Get-JuicerGpuTraits {
    param([string]$Name = '')
    $g = @{ Name = $Name.Trim(); Vendor = 'Otro'; Discrete = $false; Series = $null; Rtx = $false; FrameGen = $false; Hags = $null; Arc = $false }
    if ($Name -match 'NVIDIA|GeForce|Quadro|RTX|Tesla') {
        $g.Vendor = 'NVIDIA'; $g.Discrete = $true
        $g.Rtx = $Name -match 'RTX'
        if ($Name -match '(?:RTX|GTX|GT|MX)\s*(\d{1,2})(\d{2})\b') { $g.Series = [int]$Matches[1] }
        # Hardware scheduling: GTX 10 and later. Frame generation: RTX 40 and later.
        if ($null -ne $g.Series) { $g.Hags = $g.Series -ge 10 -and $Name -notmatch '\bMX\s*\d'; $g.FrameGen = $g.Rtx -and $g.Series -ge 40 }
    } elseif ($Name -match 'AMD|Radeon|ATI') {
        $g.Vendor = 'AMD'
        if ($Name -match 'Radeon(?:\(TM\))?\s*(?:RX|Pro|VII)') { $g.Discrete = $true }
        if ($Name -match '\bRX\s*(\d)(\d{2,3})\b') {
            # RX 5700 is gen 5; RX 580, three digits, is older than all of them.
            $g.Series = if ($Matches[2].Length -eq 3) { [int]$Matches[1] } else { 0 }
            $g.Hags = if ($g.Series -ge 7) { $true } elseif ($g.Series -ge 5) { $null } else { $false }
        }
    } elseif ($Name -match 'Intel') {
        $g.Vendor = 'Intel'
        if ($Name -match 'Arc(?:\(TM\))?\s*[AB]\d{3}') { $g.Discrete = $true; $g.Arc = $true; $g.Hags = $true }
    }
    $g
}

# Device memory ranges of a graphics card: with Resizable BAR one of them
# spans the whole VRAM; without it, the CPU sees it through a 256 MB window.
function Test-JuicerRebarRanges {
    param([uint64[]]$Sizes)
    $s = @($Sizes | Where-Object { $_ -gt 0 })
    if ($s.Count -eq 0) { return $null }
    (($s | Measure-Object -Maximum).Maximum -gt 384MB)
}

# --- Memory ----------------------------------------------------------------

# The part number on the label says what speed the kit is sold at. Windows
# only knows the JEDEC speed in its SPD, which is why «2133 MT/s» on a
# 3600 kit goes unnoticed. Xmp: the speed needs XMP/EXPO; false for JEDEC
# modules, which already run at their rated speed.
function Get-JuicerRamRating {
    param([string]$PartNumber)
    $p = ([string]$PartNumber).Trim().ToUpperInvariant()
    if (-not $p) { return $null }
    # Pattern, multiplier for the captured digits, whether it needs XMP, brand.
    $rules = @(
        @{ P = '^F[345]-(\d{4})[A-Z]\d'; M = 1; X = $true; B = 'G.Skill' }
        @{ P = '^CM\w*?X[345]M\d[A-Z](\d{4})C\d'; M = 1; X = $true; B = 'Corsair' }
        @{ P = '^(?:KF|HX)[345](\d{2})C\d{2}'; M = 100; X = $true; B = 'Kingston FURY' }
        @{ P = '^KVR(\d{2})'; M = 100; X = $false; B = 'Kingston ValueRAM' }
        @{ P = '^(?:BL|CP)\d*K?\d+G(\d{2})C\d{2}'; M = 100; X = $true; B = 'Crucial' }
        @{ P = '^CT\d+G4[A-Z0-9]*?(\d{2})A(?:[.\s]|$)'; M = 100; X = $false; B = 'Crucial' }
        @{ P = '^CT\d+G(\d{2})C\d{2}'; M = 100; X = $false; B = 'Crucial' }
        @{ P = '^TED\d+G(\d{4})C'; M = 1; X = $false; B = 'TeamGroup' }
        @{ P = '^(?:T|FF)\w*?(\d{4})HC\d{2}'; M = 1; X = $true; B = 'TeamGroup' }
        @{ P = '^AX[45]U(\d{4})'; M = 1; X = $true; B = 'ADATA XPG' }
        @{ P = '^AD[45]U(\d{4})'; M = 1; X = $false; B = 'ADATA' }
        @{ P = '^PV\w*?[345]\d{1,2}G(\d{3})C\d'; M = 10; X = $true; B = 'Patriot' }
    )
    foreach ($r in $rules) {
        if ($p -match $r.P) {
            $speed = [int]$Matches[1] * $r.M
            if ($speed -ge 1066 -and $speed -le 12000) { return @{ Speed = $speed; Xmp = $r.X; Brand = $r.B; PartNumber = $p } }
        }
    }
    $null
}

# --- Peripherals and the rest ----------------------------------------------

# PDF and XPS writers, OneNote and fax are printers only in name.
function Test-JuicerVirtualPrinter {
    param([string]$Name = '', [string]$PortName = '')
    $Name -match 'PDF|XPS|OneNote|Fax|Send To|Enviar a|Microsoft Print' -or
    $PortName -match '^(PORTPROMPT:|nul:|SHRFAX:|FILE:|XPSPort:|PDF|Microsoft\.Office|OneNote)'
}

function Get-JuicerPhysicalPrinters {
    if (-not (Test-JuicerWindows)) { return @() }
    @(Get-CimInstance Win32_Printer -ErrorAction SilentlyContinue | Where-Object {
            -not (Test-JuicerVirtualPrinter $_.Name $_.PortName)
        } | ForEach-Object { [string]$_.Name })
}

# Packages installed for the signed-in user, from the registry: instant,
# unlike asking the Appx cmdlets.
function Test-JuicerUserPackage {
    param([string]$Name)
    $repo = 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages'
    foreach ($k in (Get-JuicerRegChildren $repo)) { if ($k -like "${Name}_*") { return $true } }
    $false
}

function Get-JuicerOneDriveState {
    $s = @{ Installed = $false; SignedIn = $false; Kfm = $false; Folders = @() }
    foreach ($k in 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe',
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\OneDriveSetup.exe') {
        if (Test-JuicerRegKey $k) { $s.Installed = $true }
    }
    $roots = @()
    foreach ($acc in (Get-JuicerRegChildren 'HKCU\Software\Microsoft\OneDrive\Accounts')) {
        $f = Read-JuicerReg "HKCU\Software\Microsoft\OneDrive\Accounts\$acc" 'UserFolder'
        if ($f -and [string]$f.Value) { $roots += [string]$f.Value }
    }
    $s.SignedIn = $roots.Count -gt 0
    # Known Folder Move: Desktop, Documents or Pictures living inside OneDrive.
    $usf = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    foreach ($n in 'Desktop', 'Personal', 'My Pictures') {
        $v = Get-JuicerRegString (Read-JuicerReg $usf $n)
        foreach ($r in $roots) { if ($v -and $v.StartsWith($r, [StringComparison]::OrdinalIgnoreCase)) { $s.Folders += $n } }
        if ($v -match '\\OneDrive( - [^\\]+)?\\') { $s.Folders += $n }
    }
    $s.Folders = @($s.Folders | Select-Object -Unique)
    $s.Kfm = $s.Folders.Count -gt 0
    $s
}

# --- Reading the machine -----------------------------------------------------

$script:CpuInfo = $null

function Get-JuicerCpuInfo {
    if ($null -ne $script:CpuInfo) { return $script:CpuInfo }
    $cpu = @{ Name = ''; Vendor = ''; Cores = 0; Threads = 0 }
    $reg = 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0'
    $ident = Get-JuicerRegString (Read-JuicerReg $reg 'Identifier')
    $vendor = Get-JuicerRegString (Read-JuicerReg $reg 'VendorIdentifier')
    $name = Get-JuicerRegString (Read-JuicerReg $reg 'ProcessorNameString')
    $classes = @()
    if (Test-JuicerWindows) {
        try {
            $p = @(Get-CimInstance Win32_Processor -ErrorAction Stop)
            $name = $p[0].Name
            $vendor = $p[0].Manufacturer
            $cpu.Cores = [int](($p | Measure-Object -Property NumberOfCores -Sum).Sum)
            $cpu.Threads = [int](($p | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
        } catch {
            Write-Verbose "No se pudo leer el procesador: $_"
        }
        try { Initialize-JuicerNative; $classes = @([WinJuicer.Native]::GetEfficiencyClasses()) } catch { Write-Verbose "Sin clases de eficiencia: $_" }
    }
    $vend = if ($vendor -match 'AMD') { 'AMD' } else { 'Intel' }
    $mc = $null
    $rev = Read-JuicerReg $reg 'Update Revision'
    if ($rev -and $rev.Kind -eq 'Binary') { $mc = ConvertFrom-JuicerMicrocode $rev.Value $vend }
    $script:CpuInfo = Get-JuicerCpuTraits -Name $name -Vendor $vendor -Cores $cpu.Cores -Threads $cpu.Threads -Identifier $ident -EfficiencyClasses $classes -Microcode $mc
    $script:CpuInfo
}

# Win32_VideoController stops counting VRAM at 4 GB; the driver's own key
# has the real figure.
function Get-JuicerGpuVram {
    $class = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    $vram = @{}
    foreach ($k in (Get-JuicerRegChildren $class)) {
        if ($k -notmatch '^\d{4}$') { continue }
        $desc = Get-JuicerRegString (Read-JuicerReg "$class\$k" 'DriverDesc')
        $q = Read-JuicerReg "$class\$k" 'HardwareInformation.qwMemorySize'
        if (-not $desc -or -not $q) { continue }
        # QWORD on most drivers, eight raw bytes on some.
        $v = ConvertTo-JuicerRegValue $q.Kind $q.Value
        if ($q.Kind -in 'QWord', 'DWord') { $vram[$desc] = [uint64]$v }
        elseif ($q.Kind -eq 'Binary' -and $v.Count -ge 8) { $vram[$desc] = [BitConverter]::ToUInt64([byte[]]$v, 0) }
    }
    $vram
}

function Get-JuicerGpuInfo {
    if (-not (Test-JuicerWindows)) { return @() }
    $vram = Get-JuicerGpuVram
    @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object { $_.Name -notmatch $script:VirtualGpuPattern } | ForEach-Object {
            $g = Get-JuicerGpuTraits $_.Name
            $g.DriverVersion = [string]$_.DriverVersion
            $g.DriverDate = $_.DriverDate
            $g.PnpId = [string]$_.PNPDeviceID
            $g.Vram = if ($vram.ContainsKey($_.Name)) { $vram[$_.Name] } else { [uint64]$_.AdapterRAM }
            $g
        })
}

function Get-JuicerGpuMemoryRanges {
    param([string]$PnpId)
    $sizes = @()
    try {
        $mem = @{}
        foreach ($m in @(Get-CimInstance Win32_DeviceMemoryAddress -ErrorAction Stop)) { $mem[[string]$m.StartingAddress] = $m }
        foreach ($r in @(Get-CimInstance Win32_PNPAllocatedResource -ErrorAction Stop)) {
            if ([string]$r.Dependent.DeviceID -ne $PnpId) { continue }
            $m = $mem[[string]$r.Antecedent.StartingAddress]
            if ($m) { $sizes += [uint64]([uint64]$m.EndingAddress - [uint64]$m.StartingAddress + 1) }
        }
    } catch {
        Write-Verbose "Sin rangos de memoria de ${PnpId}: $_"
    }
    , [uint64[]]$sizes
}

$script:HardwareProfile = $null

# Everything the advisor and the review need, gathered in one go. Each part
# fails on its own: a machine without WMI still gets a profile.
function Get-JuicerHardwareProfile {
    param([switch]$Refresh)
    if ($script:HardwareProfile -and -not $Refresh) { return $script:HardwareProfile }
    $hw = @{
        Cpu = Get-JuicerCpuInfo; Gpus = @(); RamBytes = [int64]0; Modules = @(); Laptop = $false; OnBattery = $false
        ModernStandby = (Test-JuicerModernStandby); SystemDisk = $null; Printers = @(); Adapters = @(); RefreshMax = 0; Monitor = $null
        OneDrive = (Get-JuicerOneDriveState); Edge = (Test-JuicerEdgeInstalled); Home = (Test-JuicerHomeEdition)
        Insider = (Test-JuicerInsider); Build = (Get-JuicerWindowsBuild); Support = (Get-JuicerWindowsSupportInfo)
        Wsl = (Test-JuicerRegKey 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss')
        Docker = (Test-JuicerRegKey 'HKLM\SOFTWARE\Docker Inc.\Docker Desktop')
        # The Xbox app comes with Windows; Gaming Services only arrives with
        # the first Game Pass or Xbox PC game.
        GamePass = (Test-JuicerUserPackage 'Microsoft.GamingServices')
        GameBar = (Test-JuicerUserPackage 'Microsoft.XboxGamingOverlay')
    }
    if (Test-JuicerWindows) {
        $hw.Gpus = @(Get-JuicerGpuInfo)
        $hw.Laptop = Test-JuicerLaptop
        try {
            $hw.Modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction Stop)
            $hw.RamBytes = [int64](($hw.Modules | Measure-Object -Property Capacity -Sum).Sum)
        } catch {
            Write-Verbose "Sin memoria: $_"
        }
        if ($hw.Laptop) {
            try { $hw.OnBattery = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction Stop | Where-Object { $_.PowerOnline -eq $false }).Count -gt 0 } catch { Write-Verbose "Sin batería: $_" }
        }
        $hw.SystemDisk = Get-JuicerDriveMedia $env:SystemDrive
        $hw.Printers = @(Get-JuicerPhysicalPrinters)
        try { $hw.RefreshMax = [int](@(Get-JuicerDisplays | ForEach-Object { $_.MaxHz }) | Measure-Object -Maximum).Maximum } catch { Write-Verbose "Sin pantallas: $_" }
        try { $hw.Monitor = Get-JuicerPrimaryMonitor } catch { Write-Verbose "Sin monitor: $_" }
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq 'Fixed' -and (Test-Path -LiteralPath (Join-Path $d.RootDirectory.FullName 'XboxGames'))) { $hw.GamePass = $true }
        }
    }
    try {
        $a = & (Get-JuicerBackend).NetAdapters
        $hw.Adapters = @($a | Where-Object { $_ })
    } catch {
        Write-Verbose "Sin adaptadores de red: $_"
    }
    $script:HardwareProfile = $hw
    $hw
}

function Format-JuicerHardwareSummary {
    param([hashtable]$Hw)
    $lines = @()
    $c = $Hw.Cpu
    if ($c.Name) {
        $tags = @()
        if ($c.Hybrid) { $tags += 'híbrido (núcleos P y E)' }
        if ($c.DualCcdX3D) { $tags += '3D V-Cache en un CCD' } elseif ($c.X3D) { $tags += '3D V-Cache' }
        if ($c.Microcode) { $tags += ('microcódigo 0x{0:X}' -f $c.Microcode) }
        $lines += ('Procesador: {0} — {1} núcleos, {2} hilos{3}' -f $c.Name, $c.Cores, $c.Threads, $(if ($tags) { '; ' + ($tags -join ', ') } else { '' }))
    }
    foreach ($g in $Hw.Gpus) {
        $mem = if ($g.Vram -gt 0) { ', ' + (Format-JuicerBytes $g.Vram) } else { '' }
        $lines += ('Gráfica: {0} ({1}{2})' -f $g.Name, $(if ($g.Discrete) { 'dedicada' } else { 'integrada' }), $mem)
    }
    if ($Hw.RamBytes -gt 0) { $lines += ('Memoria: {0} en {1} módulo(s)' -f (Format-JuicerBytes $Hw.RamBytes), @($Hw.Modules).Count) }
    if ($Hw.Monitor) { $lines += 'Monitor: ' + (Format-JuicerMonitor $Hw.Monitor) }
    if ($Hw.SystemDisk) { $lines += ('Disco de Windows: {0} ({1}, {2})' -f $Hw.SystemDisk.Name, $Hw.SystemDisk.Media, $Hw.SystemDisk.Bus) }
    if ($Hw.Support) {
        $state = if ($Hw.Support.End -lt (Get-Date)) { 'sin parches de seguridad desde el' } else { 'con parches de seguridad hasta el' }
        $lines += ('Windows: {0}, {1} {2}' -f $Hw.Support.Version, $state, $Hw.Support.End.ToString('d'))
    }
    $kind = if ($Hw.Laptop) { 'Portátil' + $(if ($Hw.OnBattery) { ', con batería' } else { ', enchufado' }) } else { 'Sobremesa' }
    if ($Hw.ModernStandby) { $kind += ', Modern Standby' }
    $lines += "Equipo: $kind"
    $lines
}
