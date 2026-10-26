# Installing programs with winget, as WinUtil's Install tab does. The list is
# short on purpose: what a gaming PC usually needs, and the tools the
# hardware review talks about. Installs run in their own console window, so
# winget's progress and questions are visible and the window stays usable.
# Not journalled: uninstalling is the undo.

$script:WingetApps = @(
    @{ Id = 'Google.Chrome'; Name = 'Google Chrome'; Category = 'Navegadores'; What = 'El navegador de Google.' }
    @{ Id = 'Mozilla.Firefox'; Name = 'Firefox'; Category = 'Navegadores'; What = 'Navegador de Mozilla, libre.' }
    @{ Id = 'Brave.Brave'; Name = 'Brave'; Category = 'Navegadores'; What = 'Basado en Chromium, con bloqueo de anuncios incluido.' }
    @{ Id = 'Vivaldi.Vivaldi'; Name = 'Vivaldi'; Category = 'Navegadores'; What = 'Basado en Chromium, muy configurable.' }

    @{ Id = 'Valve.Steam'; Name = 'Steam'; Category = 'Juegos'; What = 'La tienda y biblioteca de Valve.' }
    @{ Id = 'EpicGames.EpicGamesLauncher'; Name = 'Epic Games Launcher'; Category = 'Juegos'; What = 'Tienda de Epic, con juegos gratis cada semana.' }
    @{ Id = 'GOG.Galaxy'; Name = 'GOG Galaxy'; Category = 'Juegos'; What = 'Juegos sin DRM de GOG, y biblioteca unificada.' }
    @{ Id = 'Ubisoft.Connect'; Name = 'Ubisoft Connect'; Category = 'Juegos'; What = 'Lanzador de los juegos de Ubisoft.' }
    @{ Id = 'ElectronicArts.EADesktop'; Name = 'EA app'; Category = 'Juegos'; What = 'Lanzador de los juegos de EA.' }
    @{ Id = 'Blizzard.BattleNet'; Name = 'Battle.net'; Category = 'Juegos'; What = 'Lanzador de Blizzard y Activision (Call of Duty).' }
    @{ Id = 'Playnite.Playnite'; Name = 'Playnite'; Category = 'Juegos'; What = 'Todas tus bibliotecas en una sola, libre.' }
    @{ Id = 'HeroicGamesLauncher.HeroicGamesLauncher'; Name = 'Heroic Games Launcher'; Category = 'Juegos'; What = 'Epic, GOG y Amazon sin sus lanzadores oficiales.' }
    @{ Id = 'Nvidia.GeForceNow'; Name = 'GeForce NOW'; Category = 'Juegos'; What = 'Juego en la nube de NVIDIA.' }
    @{ Id = 'PrismLauncher.PrismLauncher'; Name = 'Prism Launcher'; Category = 'Juegos'; What = 'Minecraft Java con varias instancias y mods.' }

    @{ Id = 'Discord.Discord'; Name = 'Discord'; Category = 'Comunicación'; What = 'Voz y chat para jugar.' }
    @{ Id = 'TeamSpeakSystems.TeamSpeakClient'; Name = 'TeamSpeak 3'; Category = 'Comunicación'; What = 'Voz de baja latencia.' }
    @{ Id = 'Telegram.TelegramDesktop'; Name = 'Telegram'; Category = 'Comunicación'; What = 'Mensajería.' }
    @{ Id = 'Mozilla.Thunderbird'; Name = 'Thunderbird'; Category = 'Comunicación'; What = 'Correo de escritorio, libre.' }

    @{ Id = 'OBSProject.OBSStudio'; Name = 'OBS Studio'; Category = 'Multimedia'; What = 'Grabar y emitir, con el codificador de la gráfica.' }
    @{ Id = 'VideoLAN.VLC'; Name = 'VLC'; Category = 'Multimedia'; What = 'Reproduce cualquier vídeo o audio.' }
    @{ Id = 'ShareX.ShareX'; Name = 'ShareX'; Category = 'Multimedia'; What = 'Capturas y grabaciones de pantalla.' }
    @{ Id = 'HandBrake.HandBrake'; Name = 'HandBrake'; Category = 'Multimedia'; What = 'Convertir y comprimir vídeos.' }
    @{ Id = 'Audacity.Audacity'; Name = 'Audacity'; Category = 'Multimedia'; What = 'Editor de audio.' }
    @{ Id = 'dotPDN.PaintDotNet'; Name = 'Paint.NET'; Category = 'Multimedia'; What = 'Editor de imágenes sencillo.' }
    @{ Id = 'GIMP.GIMP.3'; Name = 'GIMP'; Category = 'Multimedia'; What = 'Editor de imágenes completo, libre.' }
    @{ Id = 'File-New-Project.EarTrumpet'; Name = 'EarTrumpet'; Category = 'Multimedia'; What = 'Volumen por aplicación desde la bandeja.' }

    @{ Id = '7zip.7zip'; Name = '7-Zip'; Category = 'Utilidades'; What = 'Comprimir y descomprimir de todo.' }
    @{ Id = 'voidtools.Everything'; Name = 'Everything'; Category = 'Utilidades'; What = 'Encuentra cualquier archivo al instante, sin indexador de Windows.' }
    @{ Id = 'Microsoft.PowerToys'; Name = 'PowerToys'; Category = 'Utilidades'; What = 'Utilidades de Microsoft: ventanas, atajos, selector de color…' }
    @{ Id = 'Notepad++.Notepad++'; Name = 'Notepad++'; Category = 'Utilidades'; What = 'Editor de texto para archivos de configuración.' }
    @{ Id = 'Bitwarden.Bitwarden'; Name = 'Bitwarden'; Category = 'Utilidades'; What = 'Gestor de contraseñas, libre.' }
    @{ Id = 'qBittorrent.qBittorrent'; Name = 'qBittorrent'; Category = 'Utilidades'; What = 'Cliente de torrent sin publicidad.' }
    @{ Id = 'AntibodySoftware.WizTree'; Name = 'WizTree'; Category = 'Utilidades'; What = 'Qué ocupa el disco, en segundos.' }
    @{ Id = 'Klocman.BulkCrapUninstaller'; Name = 'Bulk Crap Uninstaller'; Category = 'Utilidades'; What = 'Desinstalar muchos programas de una vez, con restos incluidos.' }
    @{ Id = 'Devolutions.UniGetUI'; Name = 'UniGetUI'; Category = 'Utilidades'; What = 'Interfaz para winget: ver y actualizar todo lo instalado.' }
    @{ Id = 'SumatraPDF.SumatraPDF'; Name = 'SumatraPDF'; Category = 'Utilidades'; What = 'Lector de PDF ligerísimo.' }
    @{ Id = 'TheDocumentFoundation.LibreOffice'; Name = 'LibreOffice'; Category = 'Utilidades'; What = 'Ofimática libre y gratuita.' }

    @{ Id = 'REALiX.HWiNFO'; Name = 'HWiNFO'; Category = 'Hardware'; What = 'Temperaturas, consumos, frecuencias y errores WHEA en tiempo real: lo que hay que vigilar al probar un overclock.' }
    @{ Id = 'CPUID.CPU-Z'; Name = 'CPU-Z'; Category = 'Hardware'; What = 'Velocidad y timings reales de la RAM, y del procesador.' }
    @{ Id = 'TechPowerUp.GPU-Z'; Name = 'GPU-Z'; Category = 'Hardware'; What = 'Datos de la gráfica: Resizable BAR, enlace PCIe, relojes.' }
    @{ Id = 'CPUID.HWMonitor'; Name = 'HWMonitor'; Category = 'Hardware'; What = 'Temperaturas y voltajes, más sencillo que HWiNFO.' }
    @{ Id = 'Guru3D.Afterburner'; Name = 'MSI Afterburner'; Category = 'Hardware'; What = 'Overclock, undervolt y curva de ventiladores de la gráfica; con RivaTuner, limitador de FPS y estadísticas en pantalla.' }
    @{ Id = 'CrystalDewWorld.CrystalDiskInfo'; Name = 'CrystalDiskInfo'; Category = 'Hardware'; What = 'Salud y temperatura de los discos y SSD.' }
    @{ Id = 'CrystalDewWorld.CrystalDiskMark'; Name = 'CrystalDiskMark'; Category = 'Hardware'; What = 'Mide la velocidad de los discos.' }
    @{ Id = 'Maxon.CinebenchR23'; Name = 'Cinebench R23'; Category = 'Hardware'; What = 'Prueba de estabilidad y rendimiento del procesador.' }
    @{ Id = 'Wagnardsoft.DisplayDriverUninstaller'; Name = 'Display Driver Uninstaller'; Category = 'Hardware'; What = 'Borra a fondo el driver de la gráfica antes de reinstalarlo o cambiar de marca.' }
    @{ Id = 'TechPowerUp.NVCleanstall'; Name = 'NVCleanstall'; Category = 'Hardware'; What = 'Instala el driver de NVIDIA sin telemetría ni componentes que no uses.' }
    @{ Id = 'OpenRGB.OpenRGB'; Name = 'OpenRGB'; Category = 'Hardware'; What = 'Controla el RGB de todas las marcas sin sus programas pesados.' }
    @{ Id = 'Microsoft.Sysinternals.Autoruns'; Name = 'Autoruns'; Category = 'Hardware'; What = 'Todo lo que arranca con Windows, hasta lo más escondido.' }
    @{ Id = 'Microsoft.Sysinternals.ProcessExplorer'; Name = 'Process Explorer'; Category = 'Hardware'; What = 'El Administrador de tareas a fondo.' }

    @{ Id = 'Microsoft.VCRedist.2015+.x64'; Name = 'Visual C++ 2015-2022 (64 bits)'; Category = 'Runtimes'; What = 'Casi todos los juegos lo necesitan: sin él, errores como «falta VCRUNTIME140.dll».' }
    @{ Id = 'Microsoft.VCRedist.2015+.x86'; Name = 'Visual C++ 2015-2022 (32 bits)'; Category = 'Runtimes'; What = 'Lo mismo para juegos y programas de 32 bits.' }
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.8'; Name = '.NET Desktop Runtime 8'; Category = 'Runtimes'; What = 'Muchos programas y lanzadores modernos lo piden.' }
    @{ Id = 'Microsoft.DotNet.DesktopRuntime.10'; Name = '.NET Desktop Runtime 10'; Category = 'Runtimes'; What = 'La versión más reciente, para los programas que ya la piden.' }

    @{ Id = 'Git.Git'; Name = 'Git'; Category = 'Desarrollo'; What = 'Control de versiones.' }
    @{ Id = 'Microsoft.VisualStudioCode'; Name = 'Visual Studio Code'; Category = 'Desarrollo'; What = 'Editor de código.' }
    @{ Id = 'Microsoft.WindowsTerminal'; Name = 'Terminal de Windows'; Category = 'Desarrollo'; What = 'La consola moderna, con pestañas.' }
    @{ Id = 'Microsoft.PowerShell'; Name = 'PowerShell 7'; Category = 'Desarrollo'; What = 'La versión actual de PowerShell.' }
    @{ Id = 'OpenJS.NodeJS.LTS'; Name = 'Node.js LTS'; Category = 'Desarrollo'; What = 'JavaScript fuera del navegador.' }
)

$script:WingetCategories = @('Navegadores', 'Juegos', 'Comunicación', 'Multimedia', 'Utilidades', 'Hardware', 'Runtimes', 'Desarrollo')

# winget's «nothing to update» when asked to install what is already there.
$script:WingetAlreadyInstalled = -1978335189

function Get-JuicerWingetApps { $script:WingetApps }

function Test-JuicerWinget {
    if (-not (Test-JuicerWindows)) { return $false }
    $null -ne (Get-Command winget.exe -ErrorAction SilentlyContinue)
}

# What winget would suggest for this machine, and why.
function Get-JuicerAppSuggestions {
    param([hashtable]$Hw)
    $s = [ordered]@{}
    $s['Microsoft.VCRedist.2015+.x64'] = 'Casi todos los juegos lo piden.'
    $s['REALiX.HWiNFO'] = 'Para comprobar temperaturas y errores WHEA de lo que señala la revisión de hardware.'
    if ($Hw) {
        if (@($Hw.Gpus | Where-Object { $_.Vendor -eq 'NVIDIA' }).Count -gt 0) { $s['TechPowerUp.NVCleanstall'] = 'Tienes NVIDIA: el driver sin telemetría ni extras.' }
        if (@($Hw.Gpus | Where-Object { $_.Discrete }).Count -gt 0) { $s['TechPowerUp.GPU-Z'] = 'Confirma Resizable BAR y las líneas PCIe de tu gráfica.' }
        if ($Hw.SystemDisk -and $Hw.SystemDisk.Media -ne 'HDD') { $s['CrystalDewWorld.CrystalDiskInfo'] = 'Vigila la salud de tu SSD.' }
        if (@($Hw.Modules).Count -gt 0 -and -not $Hw.Laptop) { $s['CPUID.CPU-Z'] = 'Comprueba la velocidad real de tu RAM tras activar XMP/EXPO.' }
    }
    $s
}

# Package ids winget knows as installed, from its own export: unlike
# «winget list», it is JSON and does not depend on the language.
function Get-JuicerWingetInstalled {
    $set = @{}
    if (-not (Test-JuicerWinget)) { return $set }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('wj-winget-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        [void](Invoke-JuicerNative 'winget.exe' @('export', '-o', $tmp, '--accept-source-agreements', '--disable-interactivity'))
        if (Test-Path -LiteralPath $tmp) {
            $data = [IO.File]::ReadAllText($tmp) | ConvertFrom-Json
            foreach ($src in @($data.Sources)) { foreach ($p in @($src.Packages)) { if ($p.PackageIdentifier) { $set[([string]$p.PackageIdentifier).ToLowerInvariant()] = $true } } }
        }
    } catch {
        Write-JuicerLog "winget export falló: $_"
    } finally {
        Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
    }
    $set
}

function Test-JuicerWingetId {
    param([string]$Id)
    $Id -match '^[A-Za-z0-9][\w\.\-\+]*\.[\w\.\-\+]+$'
}

# The script the install window runs. Ids are checked and quoted, never
# pasted raw into the command line.
function New-JuicerWingetScript {
    param([ValidateSet('install', 'uninstall', 'upgrade')][string]$Action, [string[]]$Ids = @())
    foreach ($id in $Ids) { if (-not (Test-JuicerWingetId $id)) { throw "Identificador de winget no válido: $id" } }
    $list = (@($Ids) | ForEach-Object { "'" + ($_ -replace "'", "''") + "'" }) -join ', '
    $common = "'--accept-source-agreements'"
    $per = switch ($Action) {
        'install' { "@('install', '--id', `$id, '-e', '--source', 'winget', '--accept-package-agreements', $common)" }
        'uninstall' { "@('uninstall', '--id', `$id, '-e', $common)" }
        'upgrade' { "@('upgrade', '--id', `$id, '-e', '--accept-package-agreements', $common)" }
    }
    $verb = @{ install = 'Instalando'; uninstall = 'Desinstalando'; upgrade = 'Actualizando' }[$Action]
    $body = if ($Action -eq 'upgrade' -and $Ids.Count -eq 0) {
        @"
Write-Host 'Actualizando todo lo que winget conoce…' -ForegroundColor Yellow
winget upgrade --all --accept-package-agreements --accept-source-agreements
"@
    } else {
        @"
`$ok = @(); `$bad = @()
foreach (`$id in @($list)) {
    Write-Host ''
    Write-Host "$verb `$id" -ForegroundColor Yellow
    & winget.exe $per
    if (`$LASTEXITCODE -eq 0 -or `$LASTEXITCODE -eq $script:WingetAlreadyInstalled) { `$ok += `$id } else { `$bad += ('{0} (código {1})' -f `$id, `$LASTEXITCODE) }
}
Write-Host ''
if (`$ok) { Write-Host ('Hecho: ' + (`$ok -join ', ')) -ForegroundColor Green }
if (`$bad) { Write-Host ('Falló: ' + (`$bad -join ', ')) -ForegroundColor Red }
"@
    }
    "`$Host.UI.RawUI.WindowTitle = 'Win Juicer: winget'`n" + $body + "`nWrite-Host ''`nRead-Host 'Pulsa Intro para cerrar esta ventana' | Out-Null`n"
}

function Start-JuicerWinget {
    param([ValidateSet('install', 'uninstall', 'upgrade')][string]$Action, [string[]]$Ids = @())
    if (-not (Test-JuicerWinget)) { throw 'winget no está disponible. Instala o actualiza «Instalador de aplicación» desde Microsoft Store.' }
    Start-JuicerConsoleWindow (New-JuicerWingetScript $Action $Ids)
    Write-JuicerLog "winget $Action $($Ids -join ', ')"
}

# A separate Windows PowerShell window for long jobs (winget, DISM, SFC), so
# their own progress shows and the main window stays usable.
function Start-JuicerConsoleWindow {
    param([Parameter(Mandatory)][string]$Script)
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $enc = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
    Start-Process -FilePath $exe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $enc) | Out-Null
}

# The same window, running one of Win Juicer's own maintenance functions.
function Start-JuicerModuleWindow {
    param([Parameter(Mandatory)][ValidateSet('Invoke-JuicerCleanup', 'Invoke-JuicerDriveOptimize', 'Invoke-JuicerComponentCleanup',
            'Invoke-JuicerSystemRepair', 'Invoke-JuicerNetworkReset', 'Invoke-JuicerUpdateReset')][string]$Command, [string]$Title = 'Win Juicer')
    $psm = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1'
    $script = @"
`$Host.UI.RawUI.WindowTitle = '$($Title -replace "'", "''")'
Import-Module '$($psm -replace "'", "''")' -Force
Write-Host '$($Title -replace "'", "''")' -ForegroundColor Yellow
`$r = $Command
`$r | ForEach-Object { if (`$_ -is [hashtable]) { [pscustomobject]`$_ } else { `$_ } } | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
Write-Host 'Terminado.' -ForegroundColor Green
Read-Host 'Pulsa Intro para cerrar esta ventana' | Out-Null
"@
    Start-JuicerConsoleWindow $script
}
