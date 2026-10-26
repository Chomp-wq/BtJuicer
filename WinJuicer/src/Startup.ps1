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
    }
    $items.ToArray()
}

function New-JuicerStartupTweak {
    param([Parameter(Mandatory)][hashtable]$Item, [Parameter(Mandatory)][bool]$Enable)
    $verb = if ($Enable) { 'inicio-on' } else { 'inicio-off' }
    $title = if ($Enable) { "Inicio: activar $($Item.Name)" } else { "Inicio: desactivar $($Item.Name)" }
    if ($Item.Kind -eq 'Tarea') {
        $action = @{ Type = 'Task'; Path = $Item.TaskPath; Name = $Item.TaskName; Enabled = $Enable }
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

function Get-JuicerStartupVerdict {
    param([string]$Name = '', [string]$Command = '')
    $text = "$Name $Command"
    foreach ($k in $script:StartupKnown) {
        if ($text -match $k.P) { return @{ Verdict = $k.V; Why = $k.W } }
    }
    $null
}

# Startup entries with their verdict, for the screens.
function Get-JuicerStartupReview {
    foreach ($i in @(Get-JuicerStartupItems)) {
        $v = Get-JuicerStartupVerdict $i.Name $i.Command
        $i.Verdict = if ($v) { $v.Verdict } else { $null }
        $i.Why = if ($v) { $v.Why } else { $null }
        $i
    }
}
