# The analysis every recommendation rests on: what this machine has and how it
# is set up, collected once into a plain hashtable. Collecting talks to Windows;
# turning raw data into traits ("hybrid CPU", "two CCDs with 3D V-Cache",
# "integrated GPU", "plays WoW") is done by pure functions, so the advice can be
# tested against made-up machines.

$script:LaptopChassis = @(8, 9, 10, 11, 12, 14, 18, 21, 30, 31, 32)
# Display adapters that are not a graphics card: remote sessions, VMs, capture
# and streaming drivers.
$script:VirtualGpuPattern = 'Microsoft (Basic|Remote)|Hyper-V|Virtual|VMware|Parsec|Citrix|Mirage|DisplayLink|Spacedesk'
$script:BalancedPlan = '381b4222-f694-41f0-9685-ff5bb260df2e'

# --- Pure classifiers --------------------------------------------------------

function Get-JuicerCpuTraits {
    param([string]$Name, [object[]]$CpuSets = @())
    $n = ($Name -replace '\s+', ' ').Trim()
    $t = @{
        Name = $n; Vendor = 'Otro'; Generation = $null; Mbec = $null
        X3D = $false; DualCcdX3D = $false; Hybrid = $false; PCores = $null; ECores = $null; CacheGroups = $null
    }
    if ($n -match 'Intel') { $t.Vendor = 'Intel' }
    elseif ($n -match 'AMD|Ryzen|Athlon|EPYC|Threadripper') { $t.Vendor = 'AMD' }
    elseif ($n -match 'Snapdragon|Qualcomm') { $t.Vendor = 'Qualcomm' }

    # MBEC (Intel, from Kaby Lake) and GMET (AMD, from Zen 2) let the hardware do
    # what memory integrity otherwise emulates in software.
    if ($t.Vendor -eq 'Intel') {
        if ($n -match 'Core\(TM\) Ultra|Core Ultra') {
            $t.Mbec = $true
        } elseif ($n -match '\bi[3579]-(\d{4,5})') {
            $d = $Matches[1]
            # i7-8700K is 8th, i7-10700K 10th, and laptop i7-1165G7 11th.
            $t.Generation = if ($d.Length -eq 5 -or $d[0] -eq '1') { [int]$d.Substring(0, 2) } else { [int][string]$d[0] }
            $t.Mbec = $t.Generation -ge 7
        }
    } elseif ($t.Vendor -eq 'AMD') {
        if ($n -match 'Ryzen AI') {
            $t.Mbec = $true
        } elseif ($n -match 'Ryzen \d (PRO )?(\d)(\d{3})([A-Z0-9]*)') {
            $series = [int]$Matches[2]
            $suffix = $Matches[4]
            $t.Generation = $series
            # 3000-series APUs (3200G, 3400G) and laptop chips (3500U) are still Zen+.
            $t.Mbec = $series -ge 4 -or ($series -eq 3 -and $suffix -notmatch '^(G|GE|U|H)')
        }
        $t.X3D = $n -match 'X3D'
    }

    if ($CpuSets -and @($CpuSets).Count -gt 0) {
        $cores = @{}
        foreach ($c in $CpuSets) { $cores["$($c.Group)/$($c.Core)"] = [int]$c.Efficiency }
        $classes = @($cores.Values | Sort-Object -Unique)
        if ($classes.Count -ge 2) {
            $t.Hybrid = $true
            $top = $classes[-1]
            $t.PCores = @($cores.Values | Where-Object { $_ -eq $top }).Count
            $t.ECores = $cores.Count - $t.PCores
        }
        $t.CacheGroups = @($CpuSets | ForEach-Object { "$($_.Group)/$($_.Cache)" } | Sort-Object -Unique).Count
    }
    # Only one of the two CCDs carries the stacked cache on these models.
    $t.DualCcdX3D = $t.X3D -and (($t.CacheGroups -ge 2) -or $n -match '(7900|7950|9900|9950)X3D')
    $t
}

function Get-JuicerGpuTraits {
    param([string]$Name)
    $t = @{ Name = $Name; Vendor = 'Otro'; Kind = 'Dedicada'; HagsSupported = $null; FrameGen = $false }
    if ($Name -match 'NVIDIA|GeForce|Quadro|RTX') {
        $t.Vendor = 'NVIDIA'
        if ($Name -match 'RTX|GTX 1[06]\d\d') { $t.HagsSupported = $true }
        elseif ($Name -match 'GTX [4-9]\d\d\b|GT \d{3}\b') { $t.HagsSupported = $false }
        # DLSS frame generation: RTX 40 and 50 series, and it needs HAGS.
        $t.FrameGen = $Name -match 'RTX (40|50)\d\d'
    } elseif ($Name -match 'AMD|Radeon|ATI') {
        $t.Vendor = 'AMD'
        if ($Name -match 'Radeon.*\b(RX|Pro|VII)\b|\bRX \d') {
            if ($Name -match 'RX [5-9]\d{3}') { $t.HagsSupported = $true }
            elseif ($Name -match 'RX [4-5]\d{2}\b|Vega') { $t.HagsSupported = $false }
        } else {
            $t.Kind = 'Integrada'
        }
    } elseif ($Name -match 'Intel') {
        $t.Vendor = 'Intel'
        # A plain "Arc Graphics" is the integrated one in Core Ultra chips.
        if ($Name -match 'Arc.*\b[AB]\d{3}') { $t.HagsSupported = $true } else { $t.Kind = 'Integrada' }
    } elseif ($Name -match 'Adreno|Qualcomm') {
        $t.Vendor = 'Qualcomm'
        $t.Kind = 'Integrada'
    }
    $t
}

# Boards name slots every way imaginable: "ChannelA-DIMM0", "DIMM_A1",
# "P0 CHANNEL A", "Controller0-ChannelB-DIMM1". All carry a channel letter.
function Get-JuicerMemoryChannel {
    param([string]$Locator)
    if ($Locator -match '(?i)channel\s*([A-H])(?![A-Z])') { return $Matches[1].ToUpperInvariant() }
    if ($Locator -match '(?i)\bDIMM[_\s-]?([A-H])\d') { return $Matches[1].ToUpperInvariant() }
    $null
}

function Get-JuicerMemoryTraits {
    param([object[]]$Modules, [bool]$Laptop)
    $t = @{ TotalBytes = 0; ModuleCount = 0; Speed = 0; Type = 0; TypeName = 'RAM'; Channels = @(); SingleChannel = $false; SameChannel = $false; XmpLikelyOff = $false }
    if (-not $Modules -or @($Modules).Count -eq 0) { return $t }
    $t.ModuleCount = @($Modules).Count
    $t.TotalBytes = [int64](($Modules | Measure-Object -Property Capacity -Sum).Sum)
    $speeds = @($Modules | ForEach-Object { if ($_.ConfiguredClockSpeed) { $_.ConfiguredClockSpeed } else { $_.Speed } } | Where-Object { $_ -gt 0 })
    if ($speeds.Count -gt 0) { $t.Speed = [int](($speeds | Measure-Object -Minimum).Minimum) }
    $t.Type = [int](@($Modules)[0].SMBIOSMemoryType)
    $t.TypeName = switch ($t.Type) { 26 { 'DDR4' } 34 { 'DDR5' } 24 { 'DDR3' } 30 { 'LPDDR4' } 35 { 'LPDDR5' } default { 'RAM' } }
    $t.Channels = @($Modules | ForEach-Object { Get-JuicerMemoryChannel ("$($_.DeviceLocator) $($_.BankLabel)") } | Where-Object { $_ })
    $t.SingleChannel = $t.ModuleCount -eq 1
    $t.SameChannel = $t.ModuleCount -eq 2 -and $t.Channels.Count -eq 2 -and $t.Channels[0] -eq $t.Channels[1]
    # JEDEC baselines: a desktop kit sitting exactly there almost always has an
    # XMP/EXPO profile nobody turned on. Laptops rarely offer one.
    $jedec = if ($t.Type -eq 26) { 2666 } elseif ($t.Type -eq 34) { 4800 } else { 0 }
    $t.XmpLikelyOff = -not $Laptop -and $jedec -gt 0 -and $t.Speed -gt 0 -and $t.Speed -le $jedec
    $t
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

# `bcdedit /enum firmware` lists every boot entry the UEFI knows, Linux ones
# included, whatever the language.
function Get-JuicerOtherSystems {
    param([string]$FirmwareText)
    $names = foreach ($line in ($FirmwareText -split "`r?`n")) {
        if ($line -match '^\s*description\s+(.+?)\s*$') {
            $d = $Matches[1]
            if ($d -match '(?i)ubuntu|fedora|debian|linux|grub|arch|manjaro|mint|opensuse|suse|pop!?_?os|elementary|zorin|kali|systemd|nixos|gentoo|endeavour|cachyos|bazzite|steamos') { $d }
        }
    }
    @($names | Select-Object -Unique)
}

$script:SoftwareRules = @{
    Launchers = [ordered]@{ 'Steam' = '^Steam$'; 'Epic Games' = '^Epic Games Launcher'; 'GOG Galaxy' = '^GOG GALAXY'; 'EA app' = '^EA app$|^EA$'; 'Ubisoft Connect' = '^Ubisoft Connect'; 'Battle.net' = '^Battle\.net'; 'Riot' = '^Riot Client|^VALORANT|^League of Legends'; 'Rockstar' = '^Rockstar Games Launcher' }
    Capture   = [ordered]@{ 'OBS Studio' = '^OBS Studio'; 'Streamlabs' = '^Streamlabs'; 'NVIDIA App' = '^NVIDIA App'; 'GeForce Experience' = 'GeForce Experience'; 'AMD Software' = '^AMD Software'; 'XSplit' = '^XSplit'; 'Medal' = '^Medal' }
    Chat      = [ordered]@{ 'Discord' = '^Discord$'; 'TeamSpeak' = '^TeamSpeak' }
    # Games known to talk to their servers over TCP, where Nagle's batching adds delay.
    TcpGames  = [ordered]@{ 'World of Warcraft' = 'World of Warcraft'; 'Final Fantasy XIV' = 'FINAL FANTASY XIV'; 'Guild Wars 2' = 'Guild Wars 2'; 'RuneScape' = 'RuneScape' }
    Vm        = [ordered]@{ 'Docker Desktop' = '^Docker Desktop'; 'VMware Workstation' = '^VMware (Workstation|Player)'; 'VirtualBox' = 'VirtualBox'; 'BlueStacks' = '^BlueStacks' }
}

# Store apps that only notify while they can run in the background.
$script:BackgroundPackages = [ordered]@{
    'Microsoft.YourPhone' = 'Enlace Móvil'; '5319275A.WhatsAppDesktop' = 'WhatsApp'; 'MSTeams' = 'Teams'
    'Microsoft.OutlookForWindows' = 'Outlook (nuevo)'; 'microsoft.windowscommunicationsapps' = 'Correo y Calendario'
    'TelegramMessengerLLP.TelegramDesktop' = 'Telegram'; 'FACEBOOK.317180B0BB486' = 'Messenger'
}

$script:AntiCheatServices = [ordered]@{ 'vgk' = 'Riot Vanguard'; 'EasyAntiCheat' = 'Easy Anti-Cheat'; 'EasyAntiCheat_EOS' = 'Easy Anti-Cheat'; 'BEService' = 'BattlEye'; 'FACEIT' = 'FACEIT'; 'ESEADriver2' = 'ESEA' }

function Find-JuicerNamed {
    param([string[]]$Names, [System.Collections.IDictionary]$Rules)
    $found = foreach ($label in $Rules.Keys) {
        foreach ($n in $Names) { if ($n -match $Rules[$label]) { $label; break } }
    }
    @($found | Select-Object -Unique)
}

function Get-JuicerSoftwareTraits {
    param([string[]]$Programs = @(), [string[]]$Packages = @(), [string[]]$Services = @(), [string[]]$Games = @())
    $all = @($Programs) + @($Games)
    $t = @{
        Launchers  = Find-JuicerNamed $Programs $script:SoftwareRules.Launchers
        Capture    = Find-JuicerNamed $Programs $script:SoftwareRules.Capture
        Chat       = Find-JuicerNamed $Programs $script:SoftwareRules.Chat
        TcpGames   = Find-JuicerNamed $all $script:SoftwareRules.TcpGames
        Vm         = Find-JuicerNamed $Programs $script:SoftwareRules.Vm
        Background = @()
        AntiCheat  = @()
        XboxApp    = $false
        GameBar    = $false
        Wsa        = $false
        VCacheDriver = $false
    }
    foreach ($prefix in $script:BackgroundPackages.Keys) {
        if (@($Packages | Where-Object { $_ -like "${prefix}_*" -or $_ -eq $prefix }).Count -gt 0) { $t.Background += $script:BackgroundPackages[$prefix] }
    }
    $t.XboxApp = @($Packages | Where-Object { $_ -like 'Microsoft.GamingApp_*' }).Count -gt 0
    $t.GameBar = @($Packages | Where-Object { $_ -like 'Microsoft.XboxGamingOverlay_*' }).Count -gt 0
    $t.Wsa = @($Packages | Where-Object { $_ -like 'MicrosoftCorporationII.WindowsSubsystemForAndroid_*' }).Count -gt 0
    if ($t.XboxApp) { $t.Launchers = @($t.Launchers) + 'Xbox' }
    foreach ($svc in $script:AntiCheatServices.Keys) { if ($Services -contains $svc) { $t.AntiCheat += $script:AntiCheatServices[$svc] } }
    $t.AntiCheat = @($t.AntiCheat | Select-Object -Unique)
    # AMD's 3D V-Cache Performance Optimizer ships with the chipset driver.
    $t.VCacheDriver = @($Services | Where-Object { $_ -match '(?i)3d ?v-?cache' }).Count -gt 0
    $t
}

# What to do with each program that starts with Windows. Launchers, chat and
# music open in seconds when you want them; drivers' helpers, security and
# sync should stay.
$script:StartupKeep = '(?i)SecurityHealth|Defender|Realtek|RtkAud|RAVCpl|Nahimic|Dolby|Waves|MaxxAudio|nvcpl|NvBackend|NVIDIA|Radeon|AMD|igfx|Intel|Synaptics|ELAN|Logitech|LGHUB|Razer|Synapse|Corsair|iCUE|SteelSeries|HyperX|Armoury|ASUS|MSI|Dragon Center|Lenovo|Vantage|Legion|OMEN|HP |Dell|Alienware|NitroSense|PredatorSense|OneDrive|vgtray|Bluetooth|ctfmon|Dropbox|GoogleDrive|iCloud|Backup|Antivirus|Avast|AVG|Kaspersky|ESET|Bitdefender|Norton|McAfee|Malwarebytes'
$script:StartupSuggest = [ordered]@{
    '(?i)steam(webhelper)?\.exe|^Steam$'              = 'Steam se abre en segundos cuando vas a jugar; arrancando con Windows suma tiempo al inicio y memoria todo el día.'
    '(?i)EpicGamesLauncher|Epic Games'                = 'El lanzador de Epic se puede abrir al jugar; en segundo plano gasta memoria y CPU.'
    '(?i)GalaxyClient|GOG Galaxy'                     = 'GOG Galaxy se puede abrir al jugar.'
    '(?i)EADesktop|EA Desktop|\bEA app\b|Origin'      = 'La app de EA se puede abrir al jugar.'
    '(?i)UbisoftConnect|upc\.exe|Ubisoft'             = 'Ubisoft Connect se puede abrir al jugar.'
    '(?i)Battle\.net'                                 = 'Battle.net se puede abrir al jugar.'
    '(?i)RiotClient'                                  = 'El cliente de Riot se puede abrir al jugar (Vanguard funciona aparte).'
    '(?i)Discord'                                     = 'Discord se abre en un momento cuando lo necesitas.'
    '(?i)Spotify'                                     = 'Spotify se abre en un momento cuando quieras música.'
    '(?i)\bTeams\b|ms-teams'                          = 'Teams es pesado al arrancar; ábrelo cuando trabajes.'
    '(?i)Skype|Zoom|Telegram|WhatsApp|Messenger'      = 'Una app de mensajería que puedes abrir cuando la uses.'
    '(?i)MicrosoftEdgeAutoLaunch|msedge.*no-startup'  = 'Edge se precarga al iniciar sesión aunque no lo uses.'
    '(?i)CCleaner'                                    = 'CCleaner no necesita vigilar en segundo plano.'
    '(?i)Adobe|CCXProcess|Creative Cloud|AdobeGC'     = 'Los procesos de Adobe arrancan solos aunque no abras ningún programa de Adobe.'
    '(?i)uTorrent|qbittorrent|BitTorrent'             = 'Un cliente de torrents descargando en segundo plano compite por la red mientras juegas.'
    '(?i)iTunesHelper|iTunes'                         = 'El ayudante de iTunes sólo sirve con un iPhone conectado.'
    '(?i)Overwolf|Medal|Outplayed'                    = 'Superpone ventanas y graba: ábrelo sólo si lo usas.'
    '(?i)Opera.*(launcher|assistant|autoupdate)'      = 'Opera se precarga al iniciar sesión aunque no lo uses.'
    '(?i)Wallpaper ?Engine'                           = 'Un fondo animado consume GPU todo el tiempo, también mientras juegas.'
}

function Get-JuicerStartupAdvice {
    param([hashtable]$Item)
    $text = "$($Item.Name) $($Item.Command)"
    if ($text -match $script:StartupKeep) { return @{ Suggest = $false; Keep = $true; Why = '' } }
    foreach ($p in $script:StartupSuggest.Keys) {
        if ($text -match $p) { return @{ Suggest = $true; Keep = $false; Why = $script:StartupSuggest[$p] } }
    }
    @{ Suggest = $false; Keep = $false; Why = '' }
}

function Get-JuicerPathDrive {
    param([string]$Path)
    if ($Path -match '^([A-Za-z]):') { return $Matches[1].ToUpperInvariant() }
    $null
}

function Find-JuicerVolume {
    param([object[]]$Volumes, [string]$Path)
    $letter = Get-JuicerPathDrive $Path
    foreach ($v in $Volumes) { if ($v.Letter -eq $letter) { return $v } }
    $null
}

# --- Collection ----------------------------------------------------------------

function ConvertTo-JuicerDate {
    param($Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }
    try { return [Management.ManagementDateTimeConverter]::ToDateTime([string]$Value) } catch { return $null }
}

function Get-JuicerRegValue {
    param([string]$Path, [string]$Name, $Default = $null)
    $v = Read-JuicerReg $Path $Name
    if ($null -eq $v) { return $Default }
    $v.Value
}

function Get-JuicerInvOs {
    $cv = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    $build = Get-JuicerWindowsBuild
    $name = [string](Get-JuicerRegValue $cv 'ProductName' 'Windows')
    # ProductName still says "Windows 10" on Windows 11; the build is what tells.
    if ($build -ge 22000) { $name = $name -replace '^Windows 10', 'Windows 11' }
    $o = @{
        Name = $name; Edition = [string](Get-JuicerRegValue $cv 'EditionID' '')
        Version = [string](Get-JuicerRegValue $cv 'DisplayVersion' ''); Build = $build; Ubr = [int](Get-JuicerRegValue $cv 'UBR' 0)
        IsServer = ([string](Get-JuicerRegValue $cv 'InstallationType' '')) -eq 'Server'
        IsWin11 = $build -ge 22000
        Insider = [bool]((Get-JuicerRegValue 'HKLM\SOFTWARE\Microsoft\WindowsSelfHost\UI\Selection' 'UIBranch') -or (Get-JuicerRegValue 'HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' 'BranchName'))
        PendingReboot = (Test-JuicerRegKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
            (Test-JuicerRegKey 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
        UptimeDays = $null; ElevatedAs = $null; SessionUser = $null
    }
    if (Test-JuicerWindows) {
        try {
            $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
            $boot = ConvertTo-JuicerDate $os.LastBootUpTime
            if ($boot) { $o.UptimeDays = [Math]::Round(((Get-Date) - $boot).TotalDays, 1) }
        } catch {
            Write-Verbose "Sin datos de arranque: $_"
        }
        try {
            $o.ElevatedAs = [Security.Principal.WindowsIdentity]::GetCurrent().Name
            $owner = Get-CimInstance Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop | Select-Object -First 1 |
                Invoke-CimMethod -MethodName GetOwner -ErrorAction Stop
            if ($owner -and $owner.User) { $o.SessionUser = "$($owner.Domain)\$($owner.User)" }
        } catch {
            Write-Verbose "No se pudo comparar usuarios: $_"
        }
    }
    $o
}

function Get-JuicerInvDevice {
    $d = @{ Manufacturer = ''; Model = ''; Board = ''; Bios = ''; BiosDate = $null; Laptop = $false; Battery = $false; OnBattery = $false
        BatteryHealth = $null; ModernStandby = $false; HibernateSupported = $null; HypervisorPresent = $false }
    if (-not (Test-JuicerWindows)) { return $d }
    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
    if ($cs) { $d.Manufacturer = [string]$cs.Manufacturer; $d.Model = [string]$cs.Model; $d.HypervisorPresent = [bool]$cs.HypervisorPresent }
    $bb = Get-CimInstance Win32_BaseBoard -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bb) { $d.Board = ('{0} {1}' -f $bb.Manufacturer, $bb.Product).Trim() }
    $bios = Get-CimInstance Win32_BIOS -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($bios) { $d.Bios = [string]$bios.SMBIOSBIOSVersion; $d.BiosDate = ConvertTo-JuicerDate $bios.ReleaseDate }
    $d.Battery = @(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0
    $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
    $d.Laptop = $d.Battery -or @($types | Where-Object { $script:LaptopChassis -contains [int]$_ }).Count -gt 0
    if ($d.Battery) {
        $d.OnBattery = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue | Where-Object { $_.PowerOnline -eq $false }).Count -gt 0
        $design = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryStaticData -ErrorAction SilentlyContinue)[0]
        $full = @(Get-CimInstance -Namespace root/wmi -ClassName BatteryFullChargedCapacity -ErrorAction SilentlyContinue)[0]
        if ($design -and $full -and $design.DesignedCapacity -gt 0) { $d.BatteryHealth = [int](100 * $full.FullChargedCapacity / $design.DesignedCapacity) }
    }
    $caps = Get-JuicerPowerCapabilities
    if ($caps) { $d.ModernStandby = $caps.ModernStandby; $d.HibernateSupported = $caps.Hibernate }
    $d
}

function Get-JuicerInvCpu {
    $name = [string](Get-JuicerRegValue 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' 'ProcessorNameString' '')
    $cores = $null; $threads = $null; $clock = $null; $virt = $null
    if (Test-JuicerWindows) {
        $p = @(Get-CimInstance Win32_Processor -ErrorAction SilentlyContinue)
        if ($p.Count -gt 0) {
            if (-not $name) { $name = [string]$p[0].Name }
            $cores = [int](($p | Measure-Object -Property NumberOfCores -Sum).Sum)
            $threads = [int](($p | Measure-Object -Property NumberOfLogicalProcessors -Sum).Sum)
            $clock = [int]$p[0].MaxClockSpeed
            $virt = [bool]$p[0].VirtualizationFirmwareEnabled
        }
    }
    $sets = @()
    try { $sets = @(Get-JuicerCpuSets) } catch { Write-Verbose "Sin CPU sets: $_" }
    $t = Get-JuicerCpuTraits $name $sets
    $t.Cores = $cores; $t.Threads = $threads; $t.MaxMHz = $clock; $t.Virtualization = $virt
    $t
}

function Get-JuicerInvMemory {
    param([hashtable]$Sys)
    $modules = @()
    if (Test-JuicerWindows) {
        $modules = @(Get-CimInstance Win32_PhysicalMemory -ErrorAction SilentlyContinue | ForEach-Object {
                @{ Capacity = [int64]$_.Capacity; Speed = [int]$_.Speed; ConfiguredClockSpeed = [int]$_.ConfiguredClockSpeed
                    SMBIOSMemoryType = [int]$_.SMBIOSMemoryType; DeviceLocator = [string]$_.DeviceLocator; BankLabel = [string]$_.BankLabel
                    Manufacturer = ([string]$_.Manufacturer).Trim(); PartNumber = ([string]$_.PartNumber).Trim() }
            })
    }
    $m = Get-JuicerMemoryTraits $modules $Sys.Device.Laptop
    $m.Modules = $modules
    $m.Slots = $null; $m.PageFiles = @(); $m.PageFileAuto = $null; $m.Compression = $null
    if (Test-JuicerWindows) {
        $arr = Get-CimInstance Win32_PhysicalMemoryArray -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($arr) { $m.Slots = [int]$arr.MemoryDevices }
        $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue
        if ($cs) { $m.PageFileAuto = [bool]$cs.AutomaticManagedPagefile }
        $m.PageFiles = @(Get-CimInstance Win32_PageFileUsage -ErrorAction SilentlyContinue | ForEach-Object { @{ Path = [string]$_.Name; SizeMB = [int]$_.AllocatedBaseSize } })
        try { $m.Compression = [bool](Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { Write-Verbose "Sin MMAgent: $_" }
    }
    $m
}

function Get-JuicerInvGraphics {
    $g = @{ Gpus = @(); Hybrid = $false; VirtualOnly = $false; Displays = @(); Rebar = $null; Hags = $null }
    $hw = Get-JuicerRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' 'HwSchMode'
    if ($null -ne $hw) { $g.Hags = [int]$hw -eq 2 }
    if (-not (Test-JuicerWindows)) { return $g }

    # Win32_VideoController caps memory at 4 GB; the driver's own key does not.
    $vram = @{}
    $class = 'HKLM\SYSTEM\CurrentControlSet\Control\Class\{4d36e968-e325-11ce-bfc1-08002be10318}'
    foreach ($k in (Get-JuicerRegChildren $class)) {
        if ($k -notmatch '^\d{4}$') { continue }
        $desc = Get-JuicerRegValue "$class\$k" 'DriverDesc'
        $size = Get-JuicerRegValue "$class\$k" 'HardwareInformation.qwMemorySize'
        if ($desc -and $size) { $vram[[string]$desc] = [int64]$size }
    }
    $all = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue)
    foreach ($c in $all) {
        if ($c.Name -match $script:VirtualGpuPattern) { continue }
        $t = Get-JuicerGpuTraits ([string]$c.Name)
        $t.DriverVersion = [string]$c.DriverVersion
        $t.DriverDate = ConvertTo-JuicerDate $c.DriverDate
        $t.DriverAgeDays = if ($t.DriverDate) { [int]((Get-Date) - $t.DriverDate).TotalDays } else { $null }
        $t.VramBytes = if ($vram.ContainsKey([string]$c.Name)) { $vram[[string]$c.Name] } else { [int64]$c.AdapterRAM }
        $g.Gpus += $t
    }
    $g.VirtualOnly = $all.Count -gt 0 -and $g.Gpus.Count -eq 0
    $g.Hybrid = @($g.Gpus | Where-Object { $_.Kind -eq 'Integrada' }).Count -gt 0 -and @($g.Gpus | Where-Object { $_.Kind -eq 'Dedicada' }).Count -gt 0
    try {
        $g.Displays = @(Get-JuicerDisplays | ForEach-Object { @{ Monitor = $_.Monitor; Adapter = $_.Adapter; Width = $_.Width; Height = $_.Height; Hz = $_.Hz; MaxHz = $_.MaxHz } })
    } catch {
        Write-Verbose "Sin modos de pantalla: $_"
    }
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path -LiteralPath $smi) {
        $bar = ConvertFrom-JuicerNvidiaSmi (Invoke-JuicerNative $smi @('-q', '-d', 'MEMORY')).Output
        if ($bar) { $g.Rebar = $bar.Rebar }
    }
    $g
}

function Get-JuicerInvStorage {
    $s = @{ Disks = @(); Volumes = @(); SystemDrive = $null; Trim = $true; BitLocker = $null }
    $dd = Get-JuicerRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\FileSystem' 'DisableDeleteNotification' 0
    $s.Trim = [int]$dd -eq 0
    if (-not (Test-JuicerWindows)) { return $s }
    $disks = @{}
    foreach ($p in @(Get-PhysicalDisk -ErrorAction SilentlyContinue)) {
        $disks[[string]$p.DeviceId] = @{ Name = [string]$p.FriendlyName; Media = [string]$p.MediaType; Bus = [string]$p.BusType; SizeBytes = [int64]$p.Size; Health = [string]$p.HealthStatus }
    }
    $s.Disks = @($disks.Values)
    foreach ($v in @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveType -eq 'Fixed' -and $_.DriveLetter })) {
        $letter = ([string]$v.DriveLetter).ToUpperInvariant()
        $vol = @{ Letter = $letter; Label = [string]$v.FileSystemLabel; FileSystem = [string]$v.FileSystem; SizeBytes = [int64]$v.Size; FreeBytes = [int64]$v.SizeRemaining
            Disk = ''; Media = ''; Bus = '' }
        try {
            $part = Get-Partition -DriveLetter $letter -ErrorAction Stop
            $disk = $disks[[string]$part.DiskNumber]
            if ($disk) { $vol.Disk = $disk.Name; $vol.Media = $disk.Media; $vol.Bus = $disk.Bus }
        } catch {
            Write-Verbose "Sin partición para ${letter}: $_"
        }
        $s.Volumes += $vol
    }
    $sysLetter = Get-JuicerPathDrive $env:SystemDrive
    $s.SystemDrive = Find-JuicerVolume $s.Volumes "${sysLetter}:"
    try {
        $ev = Get-CimInstance -Namespace 'root/cimv2/Security/MicrosoftVolumeEncryption' -ClassName Win32_EncryptableVolume -Filter "DriveLetter='$env:SystemDrive'" -ErrorAction Stop
        if ($ev) { $s.BitLocker = (Invoke-CimMethod -InputObject $ev -MethodName GetProtectionStatus).ProtectionStatus -eq 1 }
    } catch {
        Write-Verbose "Sin estado de BitLocker: $_"
    }
    $s
}

function Get-JuicerInvGames {
    param([hashtable]$Sys)
    $games = @{ Libraries = @(); Installed = @() }
    foreach ($lib in (Get-JuicerGameLibraries)) {
        $v = Find-JuicerVolume $Sys.Storage.Volumes $lib.Path
        $games.Libraries += @{ Launcher = $lib.Launcher; Path = $lib.Path; Media = $(if ($v) { $v.Media } else { '' }); Bus = $(if ($v) { $v.Bus } else { '' }) }
        if ($lib.Launcher -eq 'Steam') {
            $common = Join-Path $lib.Path 'common'
            if (Test-Path -LiteralPath $common) { $games.Installed += @(Get-ChildItem -LiteralPath $common -Directory -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }) }
        }
    }
    $games
}

function Get-JuicerInvPower {
    $p = @{ Plan = $null; PlanName = ''; FastStartup = $false; Hibernate = $false; ThrottlingOff = $false }
    $p.FastStartup = [int](Get-JuicerRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Session Manager\Power' 'HiberbootEnabled' 0) -eq 1
    $p.Hibernate = [int](Get-JuicerRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Power' 'HibernateEnabled' 0) -eq 1
    $p.ThrottlingOff = [int](Get-JuicerRegValue 'HKLM\SYSTEM\CurrentControlSet\Control\Power\PowerThrottling' 'PowerThrottlingOff' 0) -eq 1
    $r = Invoke-JuicerNative 'powercfg.exe' @('/getactivescheme')
    if ($r.Code -eq 0 -and $r.Output -match "($script:GuidPattern)\s*\((.+)\)") {
        $p.Plan = $Matches[1].ToLowerInvariant()
        $p.PlanName = $Matches[2].Trim()
    }
    $p
}

function Get-JuicerInvSecurity {
    $s = @{ Vbs = $null; Hvci = $null; CredentialGuard = $null; HvciPolicy = $false; SecureBoot = $null
        DefenderActive = $null; DefenderRealtime = $null; OtherAv = @() }
    $pol = Get-JuicerRegValue 'HKLM\SOFTWARE\Policies\Microsoft\Windows\DeviceGuard' 'HypervisorEnforcedCodeIntegrity'
    $s.HvciPolicy = $null -ne $pol -and [int]$pol -ne 0
    if (-not (Test-JuicerWindows)) { return $s }
    try {
        $dg = Get-CimInstance -Namespace root/Microsoft/Windows/DeviceGuard -ClassName Win32_DeviceGuard -ErrorAction Stop
        $s.Vbs = $dg.VirtualizationBasedSecurityStatus -eq 2
        $s.Hvci = @($dg.SecurityServicesRunning) -contains 2
        $s.CredentialGuard = @($dg.SecurityServicesRunning) -contains 1
    } catch {
        Write-Verbose "Sin estado de VBS: $_"
    }
    try { $s.SecureBoot = [bool](Confirm-SecureBootUEFI -ErrorAction Stop) } catch { Write-Verbose "Sin Secure Boot: $_" }
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $s.DefenderActive = [string]$mp.AMRunningMode -eq 'Normal'
        $s.DefenderRealtime = [bool]$mp.RealTimeProtectionEnabled
    } catch {
        $s.DefenderActive = $false
    }
    try {
        $s.OtherAv = @(Get-CimInstance -Namespace root/SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop |
                ForEach-Object { [string]$_.displayName } | Where-Object { $_ -notmatch 'Windows Defender|Microsoft Defender' } | Select-Object -Unique)
    } catch {
        Write-Verbose "Sin Centro de seguridad: $_"
    }
    $s
}

function Get-JuicerInstalledPrograms {
    $roots = @(
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall'
        'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall'
    )
    $names = foreach ($root in $roots) {
        foreach ($k in (Get-JuicerRegChildren $root)) {
            $n = Get-JuicerRegValue "$root\$k" 'DisplayName'
            if ($n) { ([string]$n).Trim() }
        }
    }
    @($names | Sort-Object -Unique)
}

function Get-JuicerInvSoftware {
    param([hashtable]$Sys)
    $programs = Get-JuicerInstalledPrograms
    $packages = @(Get-JuicerRegChildren 'HKCU\Software\Classes\Local Settings\Software\Microsoft\Windows\CurrentVersion\AppModel\Repository\Packages')
    $services = @()
    if (Test-JuicerWindows) { $services = @(Get-Service -ErrorAction SilentlyContinue | ForEach-Object { $_.Name; $_.DisplayName }) }
    $t = Get-JuicerSoftwareTraits -Programs $programs -Packages $packages -Services $services -Games @($Sys.Games.Installed)
    $t.Programs = $programs
    $t.Outlook = Test-JuicerRegKey 'HKLM\SOFTWARE\Clients\Mail\Microsoft Outlook'
    $t.Wsl = @(Get-JuicerRegChildren 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss').Count -gt 0
    $t.HyperV = $services -contains 'vmms'
    $t.Sandbox = (Test-JuicerWindows) -and (Test-Path -LiteralPath (Join-Path $env:SystemRoot 'System32\WindowsSandbox.exe'))
    $t.OtherSystems = @()
    if (Test-JuicerWindows) {
        $r = Invoke-JuicerNative 'bcdedit.exe' @('/enum', 'firmware')
        if ($r.Code -eq 0) { $t.OtherSystems = Get-JuicerOtherSystems $r.Output }
    }
    $t
}

function Get-JuicerInvSettings {
    $mouse = [string](Get-JuicerRegValue 'HKCU\Control Panel\Mouse' 'MouseSpeed' '1')
    $sticky = [string](Get-JuicerRegValue 'HKCU\Control Panel\Accessibility\StickyKeys' 'Flags' '510')
    $sticky = if ($sticky -match '^\d+$') { [int]$sticky } else { 510 }
    $policy = 'HKCU\Software\Microsoft\Windows\CurrentVersion\StorageSense\Parameters\StoragePolicy'
    @{
        GameMode            = [int](Get-JuicerRegValue 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 1) -eq 1
        BackgroundRecording = [int](Get-JuicerRegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'HistoricalCaptureEnabled' 0) -eq 1
        GameCapture         = [int](Get-JuicerRegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR' 'AppCaptureEnabled' 1) -eq 1
        MouseAcceleration   = $mouse -ne '0'
        StickyKeysOn        = ($sticky -band 1) -eq 1
        Transparency        = [int](Get-JuicerRegValue 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' 'EnableTransparency' 1) -eq 1
        StorageSenseCleansDownloads = ([int](Get-JuicerRegValue $policy '01' 0) -eq 1) -and ([int](Get-JuicerRegValue $policy '512' 0) -gt 0)
    }
}

function Get-JuicerInvNetwork {
    $n = @{ Adapters = @(); Primary = $null }
    if (-not (Test-JuicerWindows)) { return $n }
    $up = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Up' })
    foreach ($a in $up) {
        $wifi = "$($a.PhysicalMediaType) $($a.InterfaceDescription)" -match '802\.11|Wireless|Wi-?Fi|WLAN'
        $n.Adapters += @{ Index = [int]$a.ifIndex; Name = [string]$a.Name; Description = [string]$a.InterfaceDescription; Type = $(if ($wifi) { 'Wi-Fi' } else { 'Ethernet' }); SpeedBps = [int64]$a.Speed }
    }
    try {
        $route = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1
        foreach ($a in $n.Adapters) { if ($a.Index -eq $route.ifIndex) { $n.Primary = $a } }
    } catch {
        Write-Verbose "Sin ruta por defecto: $_"
    }
    if (-not $n.Primary -and $n.Adapters.Count -gt 0) { $n.Primary = $n.Adapters[0] }
    $n
}

function Get-JuicerInvStartup {
    @(Get-JuicerStartupItems | ForEach-Object {
            $_.Advice = Get-JuicerStartupAdvice $_
            $_
        })
}

function Get-JuicerInvBoot {
    $b = @{ LastMs = $null; MainMs = $null; PostMs = $null; When = $null }
    if (-not (Test-JuicerWindows)) { return $b }
    try {
        $e = Get-WinEvent -FilterHashtable @{ LogName = 'Microsoft-Windows-Diagnostics-Performance/Operational'; Id = 100 } -MaxEvents 1 -ErrorAction Stop
        $data = @{}
        foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[$d.Name] = $d.'#text' }
        $b.LastMs = [int]$data.BootTime; $b.MainMs = [int]$data.MainPathBootTime; $b.PostMs = [int]$data.BootPostBootTime; $b.When = $e.TimeCreated
    } catch {
        Write-Verbose "Sin tiempos de arranque: $_"
    }
    $b
}

# Order matters: later sections read earlier ones (memory needs to know if it
# is a laptop, games need the volumes, software needs the games).
function Get-JuicerInventorySections {
    # Leading commas keep each row an array instead of flattening them all.
    @(
        , @('Os', 'Windows', { Get-JuicerInvOs })
        , @('Device', 'Equipo', { Get-JuicerInvDevice })
        , @('Cpu', 'Procesador', { Get-JuicerInvCpu })
        , @('Memory', 'Memoria', { param($s) Get-JuicerInvMemory $s })
        , @('Graphics', 'Gráfica y pantallas', { Get-JuicerInvGraphics })
        , @('Storage', 'Discos', { Get-JuicerInvStorage })
        , @('Games', 'Bibliotecas de juegos', { param($s) Get-JuicerInvGames $s })
        , @('Power', 'Energía', { Get-JuicerInvPower })
        , @('Security', 'Seguridad', { Get-JuicerInvSecurity })
        , @('Software', 'Programas instalados', { param($s) Get-JuicerInvSoftware $s })
        , @('Settings', 'Configuración actual', { Get-JuicerInvSettings })
        , @('Network', 'Red', { Get-JuicerInvNetwork })
        , @('Startup', 'Programas de inicio', { Get-JuicerInvStartup })
        , @('Boot', 'Tiempos de arranque', { Get-JuicerInvBoot })
    )
}

function Get-JuicerSystemProfile {
    param([scriptblock]$OnProgress)
    $sys = @{ Collected = (Get-Date); Errors = @() }
    $sections = Get-JuicerInventorySections
    $i = 0
    foreach ($sec in $sections) {
        $i++
        if ($OnProgress) { & $OnProgress $i $sections.Count $sec[1] }
        try {
            $sys[$sec[0]] = & $sec[2] $sys
        } catch {
            $sys[$sec[0]] = @{}
            $sys.Errors += "$($sec[1]): $_"
        }
    }
    $sys
}

$script:System = $null

# The analysis of this run, made once and reused by every screen.
function Get-JuicerSystem {
    param([switch]$Refresh, [scriptblock]$OnProgress)
    if ($Refresh -or $null -eq $script:System) { $script:System = Get-JuicerSystemProfile -OnProgress $OnProgress }
    $script:System
}

function Set-JuicerSystem {
    param([hashtable]$System)
    $script:System = $System
}

# Live checks for tweaks' Skip blocks: the analysis when there is one,
# otherwise a quick look at the machine.
function Test-JuicerDualCcdX3D {
    if ($script:System -and $script:System.Cpu -and $null -ne $script:System.Cpu.DualCcdX3D) { return [bool]$script:System.Cpu.DualCcdX3D }
    $name = [string](Get-JuicerRegValue 'HKLM\HARDWARE\DESCRIPTION\System\CentralProcessor\0' 'ProcessorNameString' '')
    (Get-JuicerCpuTraits $name).DualCcdX3D
}

function Test-JuicerIsLaptop {
    if ($script:System -and $script:System.Device -and $script:System.Device.ContainsKey('Laptop')) { return [bool]$script:System.Device.Laptop }
    if (-not (Test-JuicerWindows)) { return $false }
    if (@(Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue).Count -gt 0) { return $true }
    $types = @((Get-CimInstance Win32_SystemEnclosure -ErrorAction SilentlyContinue).ChassisTypes)
    @($types | Where-Object { $script:LaptopChassis -contains [int]$_ }).Count -gt 0
}
