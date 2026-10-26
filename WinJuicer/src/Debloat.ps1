# Debloat: removing the apps that come with Windows, one by one and saying
# what each one is. An app nobody opens costs no frames, but it takes disk,
# updates itself in the background and clutters Start; the promoted ones
# install more of the same. Each removal is a tweak like any other: it goes
# into the journal, and undoing it reinstalls the app from Microsoft Store.
#
# Class: Seguro      nobody misses it (discontinued, ads, promoted installs).
#        Opcional    some people use it; read what it is.
#        Cuidado     something else depends on it; asked one by one.

$script:DebloatApps = @(
    # --- Seguro ---
    @{ Name = 'Microsoft.BingNews'; StoreId = '9WZDNCRFHVFW'; Title = 'Noticias'; Class = 'Seguro'; What = 'Noticias de MSN. Las mismas que en el panel de Widgets.' }
    @{ Name = 'Microsoft.BingWeather'; StoreId = '9WZDNCRFJ3Q2'; Title = 'El Tiempo'; Class = 'Seguro'; What = 'El tiempo de MSN, con anuncios.' }
    @{ Name = 'Microsoft.BingSearch'; StoreId = '9NZBF4GT040C'; Title = 'Búsqueda de Bing'; Class = 'Seguro'; What = 'La app de Bing que se integra en la búsqueda. La búsqueda de archivos de Windows sigue funcionando.' }
    @{ Name = 'Microsoft.GetHelp'; StoreId = '9PKDZBMV1H3T'; Title = 'Obtener ayuda'; Class = 'Seguro'; What = 'Chat de soporte de Microsoft. Si algún día lo necesitas, está en la web.' }
    @{ Name = 'Microsoft.WindowsFeedbackHub'; StoreId = '9NBLGGH4R32N'; Title = 'Centro de opiniones'; Class = 'Seguro'; What = 'Para enviar comentarios a Microsoft. Windows Insider lo necesita.' }
    @{ Name = 'Microsoft.MicrosoftOfficeHub'; StoreId = '9WZDNCRD29V9'; Title = 'Microsoft 365 (Office)'; Class = 'Seguro'; What = 'Un acceso a la web de Office y publicidad de la suscripción. No es Office: si lo tienes instalado, no se toca.' }
    @{ Name = 'Microsoft.MicrosoftSolitaireCollection'; StoreId = '9WZDNCRFHWD2'; Title = 'Microsoft Solitaire Collection'; Class = 'Seguro'; What = 'Solitarios con anuncios y suscripción.' }
    @{ Name = 'Clipchamp.Clipchamp'; StoreId = '9P1J8S7CCWWT'; Title = 'Clipchamp'; Class = 'Seguro'; What = 'Editor de vídeo en la web de Microsoft. Si editas vídeo con él, déjalo.' }
    @{ Name = 'Microsoft.PowerAutomateDesktop'; StoreId = '9NFTCH6J7FHV'; Title = 'Power Automate'; Class = 'Seguro'; What = 'Automatización de tareas para empresas.' }
    @{ Name = 'Microsoft.Windows.DevHome'; StoreId = '9N8MHTPHNGVV'; Title = 'Dev Home'; Class = 'Seguro'; What = 'Panel para programadores que Microsoft ya ha abandonado.' }
    @{ Name = 'Microsoft.StartExperiencesApp'; StoreId = '9PC1H9VN18CM'; Title = 'Experiencias de Inicio'; Class = 'Seguro'; What = 'Recomendaciones y paneles extra del menú Inicio.' }
    @{ Name = 'Microsoft.ZuneVideo'; StoreId = '9WZDNCRFJ3P2'; Title = 'Películas y TV'; Class = 'Seguro'; What = 'La tienda de vídeo de Microsoft, cerrada. Para reproducir vídeos está el Reproductor multimedia.' }
    @{ Name = 'Microsoft.WindowsMaps'; StoreId = '9WZDNCRDTBVB'; Title = 'Mapas'; Class = 'Seguro'; What = 'Mapas de Windows, retirados por Microsoft.' }
    @{ Name = 'Microsoft.549981C3F5F10'; StoreId = '9NFFX4SZZ23L'; Title = 'Cortana'; Class = 'Seguro'; What = 'El asistente de Microsoft, retirado.' }
    @{ Name = 'SpotifyAB.SpotifyMusic'; StoreId = '9NCBCSZSJRSB'; Title = 'Spotify (preinstalado)'; Class = 'Seguro'; What = 'Promoción preinstalada. Si usas Spotify, déjalo.' }
    @{ Name = '4DF9E0F8.Netflix'; StoreId = '9WZDNCRFJ3TJ'; Title = 'Netflix (preinstalado)'; Class = 'Seguro'; What = 'Promoción preinstalada.' }
    @{ Name = 'Disney.37853FC22B2CE'; StoreId = '9NXQXXLFST89'; Title = 'Disney+ (preinstalado)'; Class = 'Seguro'; What = 'Promoción preinstalada.' }
    @{ Name = 'AmazonVideo.PrimeVideo'; StoreId = '9P6RC76MSMMJ'; Title = 'Prime Video (preinstalado)'; Class = 'Seguro'; What = 'Promoción preinstalada.' }
    @{ Name = 'BytedancePte.Ltd.TikTok'; StoreId = '9NH2GPH4JZS4'; Title = 'TikTok (preinstalado)'; Class = 'Seguro'; What = 'Promoción preinstalada.' }
    @{ Name = 'king.com.CandyCrushSaga'; StoreId = '9NBLGGH18846'; Title = 'Candy Crush Saga'; Class = 'Seguro'; What = 'Promoción preinstalada.' }
    # --- Opcional ---
    @{ Name = 'Microsoft.Copilot'; StoreId = '9NHT9RB2F4HD'; Title = 'Copilot'; Class = 'Opcional'; What = 'El asistente de IA de Microsoft. Sigue disponible en la web.' }
    @{ Name = 'Microsoft.OutlookForWindows'; StoreId = '9NRX63209R7B'; Title = 'Outlook (nuevo)'; Class = 'Opcional'; What = 'El correo nuevo de Windows. Si lees el correo aquí, déjalo.' }
    @{ Name = 'MSTeams'; StoreId = 'XP8BT8DW290MPQ'; Title = 'Microsoft Teams'; Class = 'Opcional'; What = 'Videollamadas y chat. Si lo usas para el trabajo o los estudios, déjalo.' }
    @{ Name = 'Microsoft.Todos'; StoreId = '9NBLGGH5R558'; Title = 'Microsoft To Do'; Class = 'Opcional'; What = 'Listas de tareas sincronizadas con tu cuenta.' }
    @{ Name = 'Microsoft.YourPhone'; StoreId = '9NMPJ99VJBWV'; Title = 'Enlace Móvil'; Class = 'Opcional'; What = 'Mensajes, llamadas y fotos del móvil en el PC.' }
    @{ Name = 'MicrosoftWindows.CrossDevice'; StoreId = '9NTXGKQ8P7N0'; Title = 'Dispositivos móviles'; Class = 'Opcional'; What = 'Usar la cámara o el portapapeles del móvil desde el PC.' }
    @{ Name = 'MicrosoftCorporationII.QuickAssist'; StoreId = '9P7BP5VNWKX5'; Title = 'Asistencia rápida'; Class = 'Opcional'; What = 'Para que alguien te ayude conectándose a tu pantalla, o tú a la suya.' }
    @{ Name = 'Microsoft.MicrosoftStickyNotes'; StoreId = '9NBLGGH4QGHW'; Title = 'Notas rápidas'; Class = 'Opcional'; What = 'Notas adhesivas en el escritorio.' }
    @{ Name = 'Microsoft.WindowsSoundRecorder'; StoreId = '9WZDNCRFHWKN'; Title = 'Grabadora de sonido'; Class = 'Opcional'; What = 'Grabar audio del micrófono.' }
    @{ Name = 'Microsoft.WindowsAlarms'; StoreId = '9WZDNCRFJ3PR'; Title = 'Reloj y alarmas'; Class = 'Opcional'; What = 'Alarmas, temporizador y sesiones de concentración.' }
    @{ Name = 'Microsoft.WindowsCamera'; StoreId = '9WZDNCRFJBBG'; Title = 'Cámara'; Class = 'Opcional'; What = 'Para probar la webcam o hacer fotos con ella. Las videollamadas no la necesitan.' }
    @{ Name = 'Microsoft.ZuneMusic'; StoreId = '9WZDNCRFJ3PT'; Title = 'Reproductor multimedia'; Class = 'Opcional'; What = 'El reproductor de música y vídeo por defecto. Quítalo sólo si usas otro, como VLC.' }
    @{ Name = '5319275A.WhatsAppDesktop'; StoreId = '9NKSQGP7F2NH'; Title = 'WhatsApp'; Class = 'Opcional'; What = 'Si lo usas en el PC, déjalo.' }
    # --- Cuidado ---
    @{ Name = 'Microsoft.GamingApp'; StoreId = '9MV0B5HZVK9Z'; Title = 'App Xbox'; Class = 'Cuidado'; What = 'Game Pass para PC y la tienda de juegos de Xbox. Sin ella no puedes instalar ni actualizar esos juegos.' }
    @{ Name = 'Microsoft.XboxGamingOverlay'; StoreId = '9NZKPSTSNW4P'; Title = 'Xbox Game Bar'; Class = 'Cuidado'; What = 'La barra de Win+G. Además, es quien detecta qué es un juego para el modo juego y para repartir núcleos en los Ryzen X3D de dos CCD.' }
    @{ Name = 'Microsoft.XboxIdentityProvider'; StoreId = '9WZDNCRD1HKW'; Title = 'Proveedor de identidad de Xbox'; Class = 'Cuidado'; What = 'El inicio de sesión de Xbox dentro de juegos de PC (Forza, Halo, Minecraft, Sea of Thieves). Sin él, esos juegos no conectan.' }
)

$script:DebloatLevels = @{ Seguro = 1; Opcional = 2; Cuidado = 3 }

function Get-JuicerDebloatApps { $script:DebloatApps }

function Find-JuicerDebloatApp {
    param([string]$Name)
    foreach ($a in $script:DebloatApps) { if ($a.Name -eq $Name) { return $a } }
    $null
}

function New-JuicerAppxTweak {
    param([Parameter(Mandatory)][hashtable]$App)
    $restore = if ($App.StoreId) { 'Deshacer la reinstala desde Microsoft Store (necesita internet).' } else { 'Para recuperarla, búscala en Microsoft Store.' }
    @{
        Id = "app:$($App.Name)"; Category = 'Apps'; Level = $script:DebloatLevels[$App.Class]; Impact = 'Bajo'; Reboot = 'No'
        Title = "Quitar $($App.Title)"
        What = $App.What
        Gain = 'Menos espacio ocupado, menos actualizaciones en segundo plano y un menú Inicio más limpio. No da FPS: una app cerrada no consume.'
        Cost = "Desaparece para todos los usuarios del equipo. $restore"
        Actions = @(@{ Type = 'Appx'; Name = $App.Name; StoreId = $App.StoreId })
    }
}

# Apps this machine relies on, whatever their class says.
function Get-JuicerAppxNeed {
    param([hashtable]$App, [hashtable]$Hw)
    if (-not $Hw) { return $null }
    switch ($App.Name) {
        'Microsoft.XboxGamingOverlay' {
            if ($Hw.Cpu.DualCcdX3D) { return "Tu $($Hw.Cpu.Name) la necesita para llevar los juegos al CCD con 3D V-Cache." }
            if ($Hw.GamePass) { return 'Usas juegos de Xbox o Game Pass.' }
        }
        'Microsoft.GamingApp' { if ($Hw.GamePass) { return 'Tienes juegos de Xbox o Game Pass instalados.' } }
        'Microsoft.XboxIdentityProvider' { if ($Hw.GamePass) { return 'Tus juegos de Xbox la usan para iniciar sesión.' } }
        'Microsoft.WindowsFeedbackHub' { if ($Hw.Insider) { return 'Windows Insider la necesita.' } }
    }
    $null
}

# What is installed now, with the verdict for this machine. Only installed
# or provisioned apps are listed: there is nothing to remove otherwise.
function Get-JuicerDebloatState {
    param([hashtable]$Hw)
    $b = Get-JuicerBackend
    foreach ($app in $script:DebloatApps) {
        $cur = & $b.AppxRead $app.Name
        if ($null -eq $cur) { continue }
        $need = Get-JuicerAppxNeed $app $Hw
        @{
            Name = $app.Name; Title = $app.Title; Class = $app.Class; What = $app.What; StoreId = $app.StoreId
            Installed = [bool]$cur.Installed; Provisioned = [bool]$cur.Provisioned
            Need = $need; Recommended = ($app.Class -eq 'Seguro' -and -not $need)
        }
    }
}

function Get-JuicerRemovedApps {
    @(Read-JuicerJournal | Where-Object { $_.Id -like 'app:*' })
}

# --- OneDrive: not a Store app, but the most asked-for removal ---------------

function Get-JuicerOneDriveSetup {
    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\OneDriveSetup.exe'), (Join-Path $env:SystemRoot 'SysWOW64\OneDriveSetup.exe')
    )
    foreach ($base in @((Join-Path $env:LOCALAPPDATA 'Microsoft\OneDrive'), (Join-Path $env:ProgramFiles 'Microsoft OneDrive'))) {
        if ($base -and (Test-Path -LiteralPath $base)) {
            $candidates += @(Get-ChildItem -LiteralPath $base -Filter 'OneDriveSetup.exe' -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
        }
    }
    foreach ($c in $candidates) { if ($c -and (Test-Path -LiteralPath $c)) { return $c } }
    $null
}

function New-JuicerOneDriveTweak {
    @{
        Id = 'apps.onedrive'; Category = 'Apps'; Level = 0; Impact = 'Bajo'; Reboot = 'No'
        Title = 'Desinstalar OneDrive'
        What = 'Desinstala la aplicación de OneDrive. Tus archivos de la carpeta OneDrive se quedan en el disco y en la nube; sólo dejan de sincronizarse.'
        Gain = 'OneDrive arranca con Windows y sincroniza en segundo plano: menos CPU, disco y red al iniciar, y ninguna carpeta que se sube sola sin que lo sepas.'
        Cost = 'Nada se sincroniza ni se copia a la nube hasta que lo reinstales. Deshacer lo reinstala con winget.'
        Skip = {
            $s = Get-JuicerOneDriveState
            if ($s.Kfm) { return "Tus carpetas ($($s.Folders -join ', ')) están dentro de OneDrive: desinstalarlo las dejaría ahí sin copia. Desactiva antes la copia de seguridad de carpetas en la configuración de OneDrive." }
        }
        Actions = @(
            @{
                Type = 'Custom'; Key = 'onedrive'; Label = 'Desinstalar OneDrive'
                Test = { -not (Get-JuicerOneDriveState).Installed }
                Capture = { @{ Installed = (Get-JuicerOneDriveState).Installed } }
                Apply = {
                    Get-Process -Name OneDrive -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
                    $setup = Get-JuicerOneDriveSetup
                    if ($setup) {
                        $r = Invoke-JuicerNative $setup @('/uninstall')
                    } else {
                        $r = Invoke-JuicerNative 'winget.exe' @('uninstall', '--id', 'Microsoft.OneDrive', '-e', '--silent', '--accept-source-agreements', '--disable-interactivity')
                    }
                    if ($r.Code -ne 0) { throw "No se pudo desinstalar OneDrive ($($r.Code)): $($r.Output)" }
                }
                Restore = {
                    param($s)
                    if (-not $s.Installed -or (Get-JuicerOneDriveState).Installed) { return }
                    $r = Invoke-JuicerNative 'winget.exe' @('install', '--id', 'Microsoft.OneDrive', '-e', '--source', 'winget', '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                    if ($r.Code -ne 0) { throw "No se pudo reinstalar OneDrive ($($r.Code)); descárgalo de onedrive.com. $($r.Output)" }
                }
            }
        )
    }
}
