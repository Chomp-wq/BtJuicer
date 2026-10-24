# Per-game settings and the game libraries on this machine. Everything here is
# a tweak built on the fly, so it lands in the same journal and undoes the same
# way as the catalog.

$script:GpuPrefKey = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences'
$script:IfeoKey = 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options'

# libraryfolders.vdf: Valve's KeyValues text. Only the "path" entries matter,
# with their backslashes escaped.
function ConvertFrom-JuicerSteamLibraries {
    param([string]$Text)
    foreach ($m in [regex]::Matches($Text, '"path"\s+"((?:[^"\\]|\\.)*)"')) {
        $m.Groups[1].Value -replace '\\\\', '\'
    }
}

function Get-JuicerGameLibraries {
    $libs = New-Object System.Collections.ArrayList
    $add = {
        param($Launcher, $Path)
        if (-not $Path) { return }
        $p = $Path.TrimEnd('\', '/')
        if (-not (Test-Path -LiteralPath $p)) { return }
        foreach ($l in $libs) { if ($l.Path -eq $p) { return } }
        [void]$libs.Add(@{ Launcher = $Launcher; Path = $p })
    }

    $steam = Read-JuicerReg 'HKCU\Software\Valve\Steam' 'SteamPath'
    if ($steam) {
        $root = ([string]$steam.Value) -replace '/', '\'
        $vdf = Join-Path $root 'steamapps\libraryfolders.vdf'
        $folders = @($root)
        if (Test-Path -LiteralPath $vdf) { $folders = @(ConvertFrom-JuicerSteamLibraries ([IO.File]::ReadAllText($vdf))) + $folders }
        foreach ($f in $folders) { & $add 'Steam' (Join-Path $f 'steamapps') }
    }

    if ($env:ProgramData) {
        $manifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
        if (Test-Path -LiteralPath $manifests) {
            foreach ($item in (Get-ChildItem -LiteralPath $manifests -Filter '*.item' -ErrorAction SilentlyContinue)) {
                try {
                    $loc = ([IO.File]::ReadAllText($item.FullName) | ConvertFrom-Json).InstallLocation
                    if ($loc) { & $add 'Epic Games' (Split-Path -Parent $loc) }
                } catch {
                    Write-Verbose "Manifiesto de Epic ilegible: $($item.FullName)"
                }
            }
        }
    }

    $gog = 'HKLM\SOFTWARE\WOW6432Node\GOG.com\Games'
    foreach ($id in (Get-JuicerRegChildren $gog)) {
        $p = Read-JuicerReg "$gog\$id" 'path'
        if ($p) { & $add 'GOG' (Split-Path -Parent ([string]$p.Value)) }
    }

    if (Test-JuicerWindows) {
        foreach ($d in [IO.DriveInfo]::GetDrives()) {
            if ($d.DriveType -eq 'Fixed') { & $add 'Xbox / Game Pass' (Join-Path $d.RootDirectory.FullName 'XboxGames') }
        }
    }
    $libs.ToArray()
}

function New-JuicerDefenderTweak {
    param([Parameter(Mandatory)][string]$Path, [string]$Launcher = '')
    $label = if ($Launcher) { "$Launcher ($Path)" } else { $Path }
    @{
        Id = 'juego:defender:' + (ConvertTo-JuicerExclusionPath $Path); Category = 'Juegos'; Level = 3; Impact = 'Medio'; Reboot = 'No'
        Title = "Exclusión de Defender: $label"
        What = 'Microsoft Defender deja de analizar los archivos de esta carpeta cuando un programa los abre.'
        Gain = 'Cargas y compilación de shaders más rápidas, sobre todo en juegos con miles de archivos pequeños.'
        Cost = 'Un archivo malicioso dentro de esa carpeta no se detectaría al abrirse. Las tiendas verifican lo que descargan; los mods y lo que copies a mano, no.'
        Actions = @(@{ Type = 'DefenderExclusion'; Path = $Path })
    }
}

function Split-JuicerFileName {
    param([string]$Path)
    ($Path -split '[\\/]')[-1]
}

function New-JuicerGpuTweak {
    param([Parameter(Mandatory)][string]$Exe)
    @{
        Id = 'juego:gpu:' + $Exe.ToLowerInvariant(); Category = 'Juegos'; Level = 1; Impact = 'Alto'; Reboot = 'No'
        Title = 'GPU de alto rendimiento: ' + (Split-JuicerFileName $Exe)
        What = 'Le dice a Windows que este juego use siempre la tarjeta gráfica potente.'
        Gain = 'En portátiles con gráfica integrada y dedicada, evita que el juego arranque en la integrada, que puede rendir varias veces menos.'
        Cost = 'Ninguno; con una sola GPU no cambia nada.'
        Actions = @(@{ Type = 'RegistryToken'; Path = $script:GpuPrefKey; Name = $Exe; Token = 'GpuPreference'; Value = '2' })
    }
}

function New-JuicerPriorityTweak {
    param([Parameter(Mandatory)][string]$Exe)
    $name = Split-JuicerFileName $Exe
    @{
        Id = 'juego:prioridad:' + $name.ToLowerInvariant(); Category = 'Juegos'; Level = 2; Impact = 'Bajo'; Reboot = 'No'
        Title = "Prioridad alta: $name"
        What = "Windows arranca $name siempre con prioridad de CPU alta (no tiempo real)."
        Gain = 'Ayuda cuando otros programas compiten por la CPU mientras juegas. Si el juego ya está limitado por la GPU, no cambia nada.'
        Cost = "Afecta a cualquier programa que se llame $name. Algunos anti-trampas fijan su propia prioridad y lo ignoran."
        Actions = @(@{ Type = 'Registry'; Path = "$script:IfeoKey\$name\PerfOptions"; Name = 'CpuPriorityClass'; Value = 3 })
    }
}

function Get-JuicerConfiguredGames {
    $journal = Read-JuicerJournal
    @($journal | Where-Object { $_.Id -like 'juego:*' })
}

function Get-JuicerGpuCount {
    if (-not (Test-JuicerWindows)) { return 0 }
    @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | Where-Object {
            $_.Name -notmatch $script:VirtualGpuPattern
        }).Count
}
