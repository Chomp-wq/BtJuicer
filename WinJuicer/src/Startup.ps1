# Programs that start with Windows. Disabling goes through StartupApproved, the
# same switch Task Manager flips: nothing is deleted, the entry stays where the
# program put it, and Task Manager shows the same state Win Juicer does.

$script:StartupApprovedBase = 'Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved'

function Get-JuicerStartupSources {
    @(
        @{ Key = 'hkcu-run'; Source = 'Registro (usuario)'; Path = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKCU\$script:StartupApprovedBase\Run" }
        @{ Key = 'hklm-run'; Source = 'Registro (equipo)'; Path = 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:StartupApprovedBase\Run" }
        @{ Key = 'hklm-run32'; Source = 'Registro (equipo, 32 bits)'; Path = 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run'; Approved = "HKLM\$script:StartupApprovedBase\Run32" }
    )
}

# Task Manager's format: 12 bytes, the first odd when disabled, then the
# FILETIME of when it was disabled.
function New-JuicerApprovedBytes {
    param([bool]$Enabled)
    $bytes = New-Object byte[] 12
    if ($Enabled) {
        $bytes[0] = 2
    } else {
        $bytes[0] = 3
        [Array]::Copy([BitConverter]::GetBytes((Get-Date).ToFileTimeUtc()), 0, $bytes, 4, 8)
    }
    , $bytes
}

function Test-JuicerApprovedEnabled {
    param($Reg)
    if ($null -eq $Reg -or $Reg.Kind -ne 'Binary' -or $Reg.Value.Count -eq 0) { return $true }
    ($Reg.Value[0] -band 1) -eq 0
}

function Get-JuicerShortcutTarget {
    param([string]$Path)
    if ($Path -notlike '*.lnk' -or -not (Test-JuicerWindows)) { return $Path }
    try {
        $s = (New-Object -ComObject WScript.Shell).CreateShortcut($Path)
        return (($s.TargetPath + ' ' + $s.Arguments).Trim())
    } catch {
        return $Path
    }
}

function Get-JuicerStartupItems {
    param([switch]$NoTasks)
    $items = New-Object System.Collections.ArrayList

    foreach ($src in (Get-JuicerStartupSources)) {
        foreach ($name in (Get-JuicerRegValueNames $src.Path)) {
            if ($name -eq '') { continue }
            $cmd = Read-JuicerReg $src.Path $name
            [void]$items.Add(@{
                    Id = "$($src.Key):$name"; Name = $name; Source = $src.Source; Kind = 'Registro'
                    Command = [string]$cmd.Value; ApprovedPath = $src.Approved; ApprovedName = $name
                    Enabled = (Test-JuicerApprovedEnabled (Read-JuicerReg $src.Approved $name))
                })
        }
    }

    if (Test-JuicerWindows) {
        $folders = @(
            @{ Key = 'carpeta-usuario'; Source = 'Carpeta Inicio (usuario)'; Dir = [Environment]::GetFolderPath('Startup'); Approved = "HKCU\$script:StartupApprovedBase\StartupFolder" }
            @{ Key = 'carpeta-comun'; Source = 'Carpeta Inicio (todos)'; Dir = [Environment]::GetFolderPath('CommonStartup'); Approved = "HKLM\$script:StartupApprovedBase\StartupFolder" }
        )
        foreach ($f in $folders) {
            if (-not $f.Dir -or -not (Test-Path -LiteralPath $f.Dir)) { continue }
            foreach ($file in (Get-ChildItem -LiteralPath $f.Dir -File -Force -ErrorAction SilentlyContinue)) {
                if ($file.Name -eq 'desktop.ini') { continue }
                [void]$items.Add(@{
                        Id = "$($f.Key):$($file.Name)"; Name = [IO.Path]::GetFileNameWithoutExtension($file.Name); Source = $f.Source; Kind = 'Carpeta'
                        Command = (Get-JuicerShortcutTarget $file.FullName); ApprovedPath = $f.Approved; ApprovedName = $file.Name
                        Enabled = (Test-JuicerApprovedEnabled (Read-JuicerReg $f.Approved $file.Name))
                    })
            }
        }

        if (-not $NoTasks) {
            # Updaters and launchers like to hide here instead of in Run.
            $tasks = @(Get-ScheduledTask -ErrorAction SilentlyContinue | Where-Object {
                    $_.TaskPath -notlike '\Microsoft\*' -and
                    @($_.Triggers | Where-Object { $_.CimClass.CimClassName -in 'MSFT_TaskLogonTrigger', 'MSFT_TaskBootTrigger' }).Count -gt 0
                })
            foreach ($t in $tasks) {
                $a = @($t.Actions)[0]
                $cmd = if ($a -and $a.Execute) { ($a.Execute + ' ' + $a.Arguments).Trim() } else { '' }
                [void]$items.Add(@{
                        Id = "tarea:$($t.TaskPath)$($t.TaskName)"; Name = $t.TaskName; Source = 'Tarea programada'; Kind = 'Tarea'
                        Command = $cmd; TaskPath = $t.TaskPath; TaskName = $t.TaskName; Enabled = ($t.State -ne 'Disabled')
                    })
            }
        }

        if (-not $NoTasks) {
            foreach ($svc in @(Get-Service -ErrorAction SilentlyContinue)) {
                $k = Get-JuicerKnownService $svc.Name $svc.DisplayName
                if (-not $k) { continue }
                $cur = Read-JuicerService $svc.Name
                if ($cur) { [void]$items.Add((New-JuicerServiceItem $svc.Name $svc.DisplayName $cur.Start $k)) }
            }
        }
    }
    $items.ToArray()
}

function Read-JuicerService { param([string]$Name) & (Get-JuicerBackend).SvcRead $Name }

# A service that starts with Windows. Only the known ones are listed: the rest
# of the third-party services are drivers, audio and antivirus, which a list
# of «things that start» invites to switch off.
function New-JuicerServiceItem {
    param([string]$Name, [string]$DisplayName, [string]$Start, [hashtable]$Known)
    @{
        Id = "servicio:$Name"; Name = $DisplayName; Source = 'Servicio'; Kind = 'Servicio'; Command = $Name
        ServiceName = $Name; Start = $Start; Enabled = ($Start -in 'Automatic', 'AutomaticDelayed')
        Verdict = $Known.V; Why = $Known.W
    }
}

function New-JuicerStartupTweak {
    param([Parameter(Mandatory)][hashtable]$Item, [Parameter(Mandatory)][bool]$Enable)
    $verb = if ($Enable) { 'inicio-on' } else { 'inicio-off' }
    $title = if ($Enable) { "Inicio: activar $($Item.Name)" } else { "Inicio: desactivar $($Item.Name)" }
    if ($Item.Kind -eq 'Tarea') {
        $action = @{ Type = 'Task'; Path = $Item.TaskPath; Name = $Item.TaskName; Enabled = $Enable }
    } elseif ($Item.Kind -eq 'Servicio') {
        # Manual, not disabled: the program can still start it when it needs it.
        if ($Enable) {
            $action = @{ Type = 'Service'; Name = $Item.ServiceName; Start = 'Automatic'; Ok = { param($c) $c.Start -in 'Automatic', 'AutomaticDelayed' } }
        } else {
            $action = @{ Type = 'Service'; Name = $Item.ServiceName; Start = 'Manual'; Ok = { param($c) $c.Start -in 'Manual', 'Disabled' } }
        }
    } else {
        $action = @{
            Type = 'Registry'; Path = $Item.ApprovedPath; Name = $Item.ApprovedName; Kind = 'Binary'
            Value = (New-JuicerApprovedBytes $Enable)
            Label = '{0} al iniciar Windows: {1}' -f $Item.Name, $(if ($Enable) { 'sí' } else { 'no' })
        }
        if ($Enable) { $action.Ok = { param($c) Test-JuicerApprovedEnabled $c } }
        else { $action.Ok = { param($c) -not (Test-JuicerApprovedEnabled $c) } }
    }
    @{
        Id = "${verb}:$($Item.Id)"; Title = $title; Category = 'Inicio'; Level = 1; Impact = 'Medio'; Reboot = 'Sesion'
        What = $title; Gain = ''; Cost = ''; Actions = @($action)
    }
}

# Turning an entry back to how it was undoes Win Juicer's own change instead of
# stacking a second one on top, so the journal only ever holds what is
# different from the original.
function Set-JuicerStartupItem {
    param([Parameter(Mandatory)][hashtable]$Item, [Parameter(Mandatory)][bool]$Enable)
    $opposite = if ($Enable) { "inicio-off:$($Item.Id)" } else { "inicio-on:$($Item.Id)" }
    if (Get-JuicerJournalEntry (Read-JuicerJournal) $opposite) { return (Undo-JuicerTweak $opposite) }
    Invoke-JuicerTweak (New-JuicerStartupTweak $Item $Enable)
}

# --- What each entry is ----------------------------------------------------------
#
# The usual suspects, by name or command. Prescindible: starting with Windows
# only makes it load sooner, it works the same when opened. Opcional: depends
# on what you use it for. Necesario: something stops working without it.
# Updaters of browsers and security software are left out on purpose: they
# are how patches arrive.

$script:StartupKnown = @(
    @{ P = 'SecurityHealth'; V = 'Necesario'; W = 'El icono de Seguridad de Windows: avisa si Defender o el firewall se apagan.' }
    @{ P = 'RtkAudUService|RTHDVCPL|Realtek ?HD ?Audio|RtkNGUI|WavesSvc|MaxxAudio'; V = 'Necesario'; W = 'El panel del audio: sin él pueden fallar los conectores de auriculares o micro.' }
    @{ P = 'SynTPEnh|ETDCtrl|ELAN ?Smart|Synaptics|PrecisionTouchpad'; V = 'Necesario'; W = 'Los gestos del touchpad.' }
    @{ P = 'steam\.exe|\bSteam\b'; V = 'Prescindible'; W = 'Steam se abre solo al lanzar un juego o desde su acceso directo. Arrancarlo con Windows sólo adelanta su carga y sus descargas.' }
    @{ P = 'EpicGamesLauncher'; V = 'Prescindible'; W = 'Se abre solo cuando lanzas un juego de Epic.' }
    @{ P = 'EADesktop|\bEA ?app\b|Origin\.exe'; V = 'Prescindible'; W = 'Se abre solo cuando lanzas un juego de EA.' }
    @{ P = 'UbisoftConnect|Ubisoft Connect|upc\.exe'; V = 'Prescindible'; W = 'Se abre solo cuando lanzas un juego de Ubisoft.' }
    @{ P = 'Battle\.net'; V = 'Prescindible'; W = 'Lo abres tú cuando vas a jugar.' }
    @{ P = 'GalaxyClient|GOG Galaxy'; V = 'Prescindible'; W = 'Lo abres tú cuando vas a jugar.' }
    @{ P = 'Overwolf'; V = 'Prescindible'; W = 'Plataforma de complementos con anuncios; arranca con los juegos que la usan.' }
    @{ P = 'Spotify'; V = 'Prescindible'; W = 'Abre en un segundo cuando quieres música.' }
    @{ P = 'Skype'; V = 'Prescindible'; W = 'Si no esperas llamadas de Skype, sobra.' }
    @{ P = 'Zoom'; V = 'Prescindible'; W = 'Las reuniones abren Zoom solas desde el enlace.' }
    @{ P = 'iTunesHelper'; V = 'Prescindible'; W = 'Sólo abre iTunes al conectar un iPhone.' }
    @{ P = 'jusched|Java Update'; V = 'Prescindible'; W = 'Comprobador de actualizaciones de Java que se queda residente.' }
    @{ P = 'CCleaner'; V = 'Prescindible'; W = 'Su «limpieza inteligente» y sus avisos no hacen falta; Windows ya se limpia solo.' }
    @{ P = 'MicrosoftEdgeAutoLaunch|GoogleChromeAutoLaunch|Opera ?(GX)? ?(Browser Assistant|Stable)|BraveSoftware.*--no-startup-window'; V = 'Prescindible'; W = 'Deja el navegador precargado al iniciar sesión, lo uses o no.' }
    @{ P = 'igfxTray|HotKeysCmds|igfxpers|Persistence Module'; V = 'Prescindible'; W = 'Icono y atajos de la gráfica Intel; el driver funciona igual sin él.' }
    @{ P = 'Cortana'; V = 'Prescindible'; W = 'Cortana está retirada.' }
    @{ P = 'Adobe ?ARM|AdobeAAMUpdater|AdobeGCInvoker|Adobe ?Updater|CCXProcess|Adobe Creative Cloud'; V = 'Prescindible'; W = 'Procesos de Adobe que se cargan siempre; Adobe comprueba sus actualizaciones al abrir sus programas.' }
    @{ P = 'Discord'; V = 'Opcional'; W = 'Si quieres estar disponible en cuanto enciendes, déjalo; si no, ábrelo al jugar.' }
    @{ P = '\bTeams\b|ms-teams|MSTeams'; V = 'Opcional'; W = 'Necesario si te llaman por Teams; si no, sobra.' }
    @{ P = 'OneDrive'; V = 'Opcional'; W = 'Si haces copias en OneDrive, déjalo; si no sincronizas nada, sobra.' }
    @{ P = 'Dropbox|GoogleDriveFS|Google Drive'; V = 'Opcional'; W = 'Si sincronizas carpetas con él, déjalo.' }
    @{ P = 'G ?HUB|LGHUB|Razer|Synapse|iCUE|Armoury|NZXT|SteelSeries|SignalRgb|OpenRGB'; V = 'Opcional'; W = 'Si los perfiles, macros y RGB están guardados en el propio periférico, no hace falta que arranque; si no, sin él los pierdes hasta abrirlo.' }
    @{ P = 'Afterburner|RTSS|RivaTuner'; V = 'Opcional'; W = 'Si aplica un overclock, una curva de ventiladores o un límite de FPS al arrancar, déjalo.' }
    @{ P = 'Wallpaper ?Engine|wallpaper32|wallpaper64'; V = 'Opcional'; W = 'Sin él, fondo de escritorio normal.' }
    @{ P = 'Docker'; V = 'Opcional'; W = 'Si no lo usas cada día, ábrelo cuando lo necesites: arrancado reserva memoria.' }
)

# Services that start with Windows for a program that does not need them
# running all the time. Matched by service name or display name. Updaters of
# browsers and antivirus are left out, as above.
$script:ServiceKnown = @(
    @{ P = '^AdobeARMservice$|^AdobeUpdateService$'; V = 'Prescindible'; W = 'Actualizador de Adobe siempre residente; Acrobat y Creative Cloud buscan actualizaciones al abrirse.' }
    @{ P = '^AGSService$|^AGMService$|Adobe Genuine'; V = 'Prescindible'; W = 'Comprobación de licencia de Adobe que vigila el equipo entero; las apps de Adobe funcionan sin ella.' }
    @{ P = '^Origin(Client|WebHelper)Service$'; V = 'Prescindible'; W = 'Restos de Origin, sustituido por la app de EA.' }
    @{ P = '^EABackgroundService$'; V = 'Opcional'; W = 'Actualiza los juegos de EA en segundo plano; en manual, la app de EA lo arranca al abrirse.' }
    @{ P = 'SystemUsageReportSvc_QUEENCREEK|Intel\(R\) SUR QC|^ESRV_SVC_QUEENCREEK$'; V = 'Prescindible'; W = 'Telemetría de Intel (informe de uso del sistema); no hace nada por el equipo.' }
    @{ P = '^DSAService$|^DSAUpdateService$|Intel\(R\) Driver & Support'; V = 'Opcional'; W = 'El asistente de drivers de Intel; en manual sigue funcionando cuando lo abres.' }
    @{ P = '^HpTouchpointAnalyticsService$|HP Insights Analytics|^HPDiagsCap$|^HPAppHelperCap$|^HPSysInfoCap$'; V = 'Prescindible'; W = 'Telemetría y diagnóstico de HP siempre residentes.' }
    @{ P = '^SupportAssistAgent$|^DellClientManagementService$|Dell SupportAssist'; V = 'Opcional'; W = 'SupportAssist de Dell: drivers y garantía. Si actualizas drivers tú, sobra que esté siempre en marcha.' }
    @{ P = 'Killer Analytics|^KAPSService$|^xTendSoftAPService$|^xTendUtilityService$'; V = 'Prescindible'; W = 'Analítica y «priorización» de las tarjetas Killer; la red funciona igual o mejor sin ellas.' }
    @{ P = '^Killer Network Service$|^KNDBWM$|^KillerNetworkService$'; V = 'Opcional'; W = 'La priorización de tráfico de Killer, que a veces añade latencia en vez de quitarla. Prueba sin ella.' }
    @{ P = '^NahimicService$|Nahimic'; V = 'Opcional'; W = 'Efectos de sonido de Nahimic (MSI, Alienware). Conocido por cuelgues y tirones en algunos juegos; si no usas sus efectos, sobra.' }
    @{ P = 'Razer|^RzActionSvc$'; V = 'Opcional'; W = 'Si los perfiles y el RGB están guardados en el periférico, no hace falta que arranque siempre.' }
    @{ P = '^Corsair|^CorsairLLAService$|iCUE'; V = 'Opcional'; W = 'Sin él, iCUE no controla el RGB ni los ventiladores hasta que lo abres.' }
    @{ P = '^LGHUBUpdaterService$'; V = 'Prescindible'; W = 'Actualizador de G HUB; G HUB se actualiza al abrirse.' }
    @{ P = '^ArmouryCrateService$|^AsusUpdateCheck$|^ASUSOptimization$|^ASUSSoftwareManager$|^ROG Live Service$'; V = 'Opcional'; W = 'Armoury Crate: RGB, ventiladores y perfiles de ASUS. En portátiles ROG/TUF controla los modos de rendimiento: ahí, déjalo.' }
    @{ P = '^TeamViewer$'; V = 'Opcional'; W = 'Arrancado siempre, el equipo acepta conexiones remotas. Si sólo lo usas para conectarte tú a otros, ponlo en manual.' }
    @{ P = '^AnyDesk$'; V = 'Opcional'; W = 'Arrancado siempre, el equipo acepta conexiones remotas. Si no te conectas a él desde fuera, ponlo en manual.' }
    @{ P = '^Apple Mobile Device Service$'; V = 'Opcional'; W = 'Sólo hace falta para conectar un iPhone o iPad al PC.' }
    @{ P = '^Bonjour Service$'; V = 'Prescindible'; W = 'Lo instala iTunes para descubrir dispositivos en la red; casi nadie lo necesita.' }
    @{ P = 'CCleaner'; V = 'Prescindible'; W = 'Su monitorización en segundo plano no hace falta; Windows ya se limpia solo.' }
    @{ P = '^SamsungMagicianSVC$'; V = 'Opcional'; W = 'Samsung Magician funciona igual abriéndolo cuando lo necesites.' }
)

function Get-JuicerKnownService {
    param([string]$Name, [string]$DisplayName = '')
    foreach ($k in $script:ServiceKnown) {
        if ($Name -match $k.P -or $DisplayName -match $k.P) { return $k }
    }
    $null
}

# A command line without the folders of its program: «"C:\Program Files\Steam\Tools\x.exe" -a»
# becomes «x.exe -a». The verdict looks at the program, not at where it lives: a tool
# under a folder called Steam, Discord or Razer is not Steam, Discord or Razer.
function Get-JuicerCommandProgram {
    param([string]$Command = '')
    if ($Command -match '^\s*"?(?<path>[^"]*?\.(?:exe|com|bat|cmd|lnk|msc|scr))"?(?<rest>.*)$') {
        # A regex, not Split-Path: the paths are Windows ones whatever runs this (the tests).
        return (($Matches.path -replace '^.*[\\/]', '') + $Matches.rest)
    }
    $Command
}

function Get-JuicerStartupVerdict {
    param([string]$Name = '', [string]$Command = '')
    $text = "$Name $(Get-JuicerCommandProgram $Command)"
    foreach ($k in $script:StartupKnown) {
        if ($text -match $k.P) { return @{ Verdict = $k.V; Why = $k.W } }
    }
    $null
}

# --- What Windows measured ------------------------------------------------------
#
# Windows times what slows each boot and logs it in Diagnostics-Performance: event 101 for
# an application, 102 for a driver, 103 for a service. DegradationTime is how long it held
# the boot back (TotalTime, how long it took to start, is the fallback). Windows only logs
# the ones that are slow, so most entries have nothing to say and show nothing.

$script:BootDelayLog = 'Microsoft-Windows-Diagnostics-Performance/Operational'
$script:BootDelayKinds = @{ 101 = 'app'; 102 = 'driver'; 103 = 'service' }

# One event's data into @{ Kind; Keys; Seconds }, or null when it says nothing usable. Keys
# are what an entry can be matched by, lower case: the file name (Name and FileName for an
# app or a driver, wherever they sit in the path) and, for a service, its name and its
# display name.
function ConvertFrom-JuicerBootEvent {
    param([int]$Id, [hashtable]$Data)
    $kind = $script:BootDelayKinds[$Id]
    if (-not $kind -or -not $Data) { return $null }
    $ms = 0.0
    foreach ($f in 'DegradationTime', 'TotalTime') {
        $v = 0.0
        if ($Data[$f] -and [double]::TryParse([string]$Data[$f], [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$v) -and $v -gt 0) { $ms = $v; break }
    }
    if ($ms -le 0) { return $null }
    $keys = New-Object System.Collections.ArrayList
    foreach ($f in 'Name', 'FileName', 'Path', 'FriendlyName') {
        $raw = [string]$Data[$f]
        if (-not $raw.Trim()) { continue }
        # A regex, not Split-Path: these are Windows paths whatever runs this (the tests).
        $leaf = ($raw.Trim().Trim('"') -replace '^.*[\\/]', '').ToLowerInvariant()
        if ($leaf -and $keys -notcontains $leaf) { [void]$keys.Add($leaf) }
    }
    if ($keys.Count -eq 0) { return $null }
    @{ Kind = $kind; Keys = $keys.ToArray(); Seconds = [Math]::Round($ms / 1000, 1) }
}

# Recent boot delays, newest event of each item winning: key (lower case) to seconds.
# Events is what Get-JuicerEvents hands back (newest first), so tests can pass their own.
function ConvertFrom-JuicerBootEvents {
    param([object[]]$Events)
    $delays = @{}
    foreach ($e in @($Events | Where-Object { $_ })) {
        $data = @{}
        try {
            foreach ($d in ([xml]$e.ToXml()).Event.EventData.Data) { $data[[string]$d.Name] = [string]$d.'#text' }
        } catch {
            Write-Verbose "Evento de arranque ilegible: $_"
            continue
        }
        $r = ConvertFrom-JuicerBootEvent ([int]$e.Id) $data
        if (-not $r) { continue }
        foreach ($k in $r.Keys) { if (-not $delays.ContainsKey($k)) { $delays[$k] = $r.Seconds } }
    }
    $delays
}

# The last 30 days of them. Empty when the log cannot be read (it may be off, or empty:
# most PCs only log what is slow).
function Get-JuicerBootDelays {
    param([int]$Days = 30)
    $events = Get-JuicerEvents @{ LogName = $script:BootDelayLog; Id = 101, 102, 103; StartTime = (Get-Date).AddDays(-$Days) }
    if ($null -eq $events) { return @{} }
    # Newest first, whatever order the log came in.
    ConvertFrom-JuicerBootEvents @($events | Sort-Object { $_.TimeCreated } -Descending)
}

# The seconds Windows measured for one startup entry, or $null. Matches by file name: the
# program of the command line («"C:\Games\Steam\steam.exe" -silent» is steam.exe), and for a
# service its name and display name. No match is no data, not a zero.
function Get-JuicerStartupDelay {
    param([hashtable]$Item, [hashtable]$Delays)
    if (-not $Item -or -not $Delays -or $Delays.Count -eq 0) { return $null }
    $keys = @()
    if ($Item.Kind -eq 'Servicio') {
        $keys += @([string]$Item.ServiceName, [string]$Item.Name)
    } else {
        $prog = ([string](Get-JuicerCommandProgram ([string]$Item.Command)).Trim()).Trim('"')
        if ($prog -match '^(?<exe>[^\s"]+?\.(?:exe|com|bat|cmd|scr|lnk))(?:\s|$)') { $keys += $Matches.exe }
    }
    $best = $null
    foreach ($k in $keys) {
        $key = ([string]$k -replace '^.*[\\/]', '').Trim().ToLowerInvariant()
        if ($key -and $Delays.ContainsKey($key) -and ($null -eq $best -or $Delays[$key] -gt $best)) { $best = $Delays[$key] }
    }
    $best
}

# Startup entries with their verdict, for the screens. BootDelay: seconds Windows measured
# for the entry in the last 30 days, absent when it has none.
function Get-JuicerStartupReview {
    $delays = @{}
    try { $delays = Get-JuicerBootDelays } catch { Write-JuicerLog "Sin tiempos de arranque de Windows: $_" }
    foreach ($i in @(Get-JuicerStartupItems)) {
        $d = Get-JuicerStartupDelay $i $delays
        if ($d -gt 0) { $i.BootDelay = [double]$d }
        if ($i.Kind -eq 'Servicio') { $i; continue }
        $v = Get-JuicerStartupVerdict $i.Name $i.Command
        $i.Verdict = if ($v) { $v.Verdict } else { $null }
        $i.Why = if ($v) { $v.Why } else { $null }
        $i
    }
}

# «+12 s», without the zero: what the screens show beside an entry. Empty when there is none.
function Format-JuicerBootDelay {
    param($Seconds)
    if ($null -eq $Seconds -or [double]$Seconds -le 0) { return '' }
    $s = [double]$Seconds
    if ($s -lt 10) { return ('+{0} s' -f $s.ToString('0.#', [Globalization.CultureInfo]::InvariantCulture)) }
    '+{0} s' -f [int][Math]::Round($s)
}

# Slow enough to point at: Windows itself calls a boot degraded at 2 s or more per item.
function Test-JuicerBootDelaySlow {
    param($Seconds)
    $null -ne $Seconds -and [double]$Seconds -ge 2
}
