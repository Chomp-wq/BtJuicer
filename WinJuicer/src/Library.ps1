# The games installed on this PC, each with the .exe that actually runs, so
# they can be listed and set up in one click. Every launcher keeps its own
# record of what it installed: Steam's app manifests, Epic's .item files,
# GOG's and the others' registry entries, Xbox's MicrosoftGame.config. Steam
# and the registry say where a game is but not which .exe it runs, so that
# is worked out from the files (Unreal's *-Win64-Shipping.exe, the biggest
# executable named like the game, never an uninstaller or a crash reporter)
# and remembered; the user can always pick another.

$script:NotGameNames = 'Redistributable|Redistributables|Soundtrack|\bOST\b|\bSDK\b|Dedicated Server|Proton|Steam Linux Runtime|SteamVR|Wallpaper Engine|Steamworks Common|DirectX|Visual C\+\+|\.NET|PhysX|Benchmark Tool|Demo$'
$script:NotGameExe = '^(unins|uninstall|setup|install|vc_?redist|vcredist|dxsetup|dxwebsetup|directx|crash|bugsplat|errorreport|report|dump|ue4prereq|ueprereq|prereq|dotnet|physx|easyanticheat|eac|beservice|battleye|start_protected_game|cefprocess|cef|webhelper|qtwebengine|overlay|notification|socialclub|launcherpatcher|updater|update|patcher|repair|cleanup|config|settings|unitycrashhandler|crs-|python|pythonw|7z|unrealcefsubprocess|epicwebhelper|vulkan|redist|server|dedicated|editor)'

# Steam's appmanifest_*.acf, Valve's KeyValues text.
function ConvertFrom-JuicerAcf {
    param([string]$Text)
    $v = @{}
    foreach ($k in 'appid', 'name', 'installdir') {
        $m = [regex]::Match($Text, '"' + $k + '"\s+"((?:[^"\\]|\\.)*)"', 'IgnoreCase')
        if ($m.Success) { $v[$k] = $m.Groups[1].Value -replace '\\\\', '\' }
    }
    if (-not $v.installdir) { return $null }
    @{ AppId = [string]$v.appid; Name = [string]$v.name; InstallDir = [string]$v.installdir }
}

function Test-JuicerNotAGame { param([string]$Name) [bool]($Name -match $script:NotGameNames) }

function ConvertTo-JuicerLooseName { param([string]$Text) ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '') }

# Files are @{ Path (relative to the game folder); Size }. The best guess at
# the game's own executable, or null.
function Select-JuicerGameExe {
    param([object[]]$Files, [string]$Name)
    $loose = ConvertTo-JuicerLooseName $Name
    $best = $null; $bestScore = [double]::MinValue
    foreach ($f in $Files) {
        $file = Split-Path -Leaf $f.Path
        $base = [IO.Path]::GetFileNameWithoutExtension($file)
        if ($base -match $script:NotGameExe) { continue }
        $score = 0.0
        if ($file -match '-Win64-Shipping\.exe$') { $score += 60 }
        $lb = ConvertTo-JuicerLooseName ($base -replace '-Win64-Shipping$', '')
        if ($lb -and $loose -and ($loose.Contains($lb) -or $lb.Contains($loose))) { $score += 35 }
        if ($f.Path -match '(?i)(^|\\)(Binaries\\Win64|bin\\x64|bin64|x64)\\') { $score += 15 }
        if ($base -match '(?i)launcher') { $score -= 25 }
        $score += [Math]::Min(25, [double]$f.Size / 20MB)
        $score -= 3 * ([regex]::Matches($f.Path, '\\').Count)
        if ($score -gt $bestScore) { $bestScore = $score; $best = $f.Path }
    }
    $best
}

# The executables of a game folder, four levels deep at most.
function Find-JuicerGameExe {
    param([string]$Dir, [string]$Name)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse -Depth 4 -ErrorAction SilentlyContinue | ForEach-Object {
            @{ Path = $_.FullName.Substring($root.Length + 1); Size = $_.Length }
        })
    $rel = Select-JuicerGameExe $files $Name
    if ($rel) { Join-Path $root $rel } else { $null }
}

function New-JuicerGame {
    param([string]$Launcher, [string]$Key, [string]$Name, [string]$Dir, [string]$Exe = '')
    @{ Id = ('{0}:{1}' -f $Launcher, $Key).ToLowerInvariant(); Name = $Name.Trim(); Launcher = $Launcher; Dir = $Dir; Exe = $Exe }
}

# --- Each launcher ---------------------------------------------------------------

function Get-JuicerSteamGames {
    foreach ($lib in @(Get-JuicerGameLibraries | Where-Object { $_.Launcher -eq 'Steam' })) {
        foreach ($acf in @(Get-ChildItem -LiteralPath $lib.Path -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
            $a = ConvertFrom-JuicerAcf ([IO.File]::ReadAllText($acf.FullName))
            if (-not $a -or (Test-JuicerNotAGame $a.Name)) { continue }
            $dir = Join-Path (Join-Path $lib.Path 'common') $a.InstallDir
            if (Test-Path -LiteralPath $dir) { New-JuicerGame 'Steam' $a.AppId $(if ($a.Name) { $a.Name } else { $a.InstallDir }) $dir }
        }
    }
}

function Get-JuicerEpicGames {
    if (-not $env:ProgramData) { return }
    $manifests = Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Manifests'
    foreach ($item in @(Get-ChildItem -LiteralPath $manifests -Filter '*.item' -ErrorAction SilentlyContinue)) {
        try {
            $m = [IO.File]::ReadAllText($item.FullName) | ConvertFrom-Json
        } catch {
            Write-Verbose "Manifiesto de Epic ilegible: $($item.FullName)"
            continue
        }
        if ($m.AppCategories -and @($m.AppCategories) -notcontains 'games') { continue }
        if (-not $m.InstallLocation -or (Test-JuicerNotAGame ([string]$m.DisplayName))) { continue }
        $exe = if ($m.LaunchExecutable) { Join-Path $m.InstallLocation $m.LaunchExecutable } else { '' }
        New-JuicerGame 'Epic Games' ([string]$m.AppName) ([string]$m.DisplayName) ([string]$m.InstallLocation) $exe
    }
}

function Get-JuicerGogGames {
    $gog = 'HKLM\SOFTWARE\WOW6432Node\GOG.com\Games'
    foreach ($id in (Get-JuicerRegChildren $gog)) {
        $name = Read-JuicerReg "$gog\$id" 'gameName'
        $path = Read-JuicerReg "$gog\$id" 'path'
        $exe = Read-JuicerReg "$gog\$id" 'exe'
        if (-not $path) { continue }
        New-JuicerGame 'GOG' $id $(if ($name) { [string]$name.Value } else { $id }) ([string]$path.Value) $(if ($exe) { [string]$exe.Value } else { '' })
    }
}

# MicrosoftGame.config: <Executable Name="Game.exe" .../> and the display name.
function ConvertFrom-JuicerXboxConfig {
    param([string]$Text)
    try { $x = [xml]$Text } catch { return $null }
    $exe = @($x.SelectNodes('//*[local-name()="Executable"]'))
    $name = $x.SelectSingleNode('//*[local-name()="ShellVisuals"]')
    @{
        Exe = $(if ($exe.Count -gt 0) { [string]$exe[0].GetAttribute('Name') } else { '' })
        Name = $(if ($name) { [string]$name.GetAttribute('DefaultDisplayName') } else { '' })
    }
}

function Get-JuicerXboxGames {
    foreach ($lib in @(Get-JuicerGameLibraries | Where-Object { $_.Launcher -like 'Xbox*' })) {
        foreach ($d in @(Get-ChildItem -LiteralPath $lib.Path -Directory -ErrorAction SilentlyContinue)) {
            $content = Join-Path $d.FullName 'Content'
            $cfg = Join-Path $content 'MicrosoftGame.config'
            if (-not (Test-Path -LiteralPath $cfg)) { continue }
            $c = ConvertFrom-JuicerXboxConfig ([IO.File]::ReadAllText($cfg))
            if (-not $c) { continue }
            $name = if ($c.Name -and $c.Name -notlike 'ms-resource*') { $c.Name } else { $d.Name }
            New-JuicerGame 'Xbox' $d.Name $name $content $(if ($c.Exe) { Join-Path $content $c.Exe } else { '' })
        }
    }
}

# EA, Ubisoft, Battle.net, Riot, Rockstar, HoYoverse…: their games register
# an uninstaller with a known publisher and their folder. Their launchers too,
# which are not games.
$script:GamePublishers = @(
    @{ P = '^Electronic Arts'; L = 'EA' }, @{ P = '^Ubisoft'; L = 'Ubisoft' }, @{ P = '^Blizzard'; L = 'Battle.net' }
    @{ P = '^Riot Games'; L = 'Riot' }, @{ P = '^Rockstar Games'; L = 'Rockstar' }, @{ P = 'HoYoverse|miHoYo|COGNOSPHERE'; L = 'HoYoverse' }
    @{ P = '^Activision'; L = 'Battle.net' }, @{ P = '^Bethesda'; L = 'Bethesda' }, @{ P = '^Wargaming'; L = 'Wargaming' }
)
$script:LauncherNames = '^(EA app|EA Desktop|Origin|Ubisoft (Connect|Game Launcher)|Uplay|Battle\.net|Riot Client|Rockstar Games (Launcher|Social Club)|HoYoPlay|Genshin Impact Launcher|Bethesda\.net Launcher|Wargaming\.net Game Center)\b'

function Get-JuicerPublisherGame {
    param([string]$Name, [string]$Publisher, [string]$Location)
    if (-not $Name -or -not $Location -or $Name -match $script:LauncherNames -or (Test-JuicerNotAGame $Name)) { return $null }
    foreach ($p in $script:GamePublishers) {
        if ($Publisher -match $p.P) { return (New-JuicerGame $p.L (ConvertTo-JuicerLooseName $Name) $Name $Location.Trim('"')) }
    }
    $null
}

function Get-JuicerPublisherGames {
    $roots = @('HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall', 'HKCU\Software\Microsoft\Windows\CurrentVersion\Uninstall')
    foreach ($root in $roots) {
        foreach ($k in (Get-JuicerRegChildren $root)) {
            $pub = Read-JuicerReg "$root\$k" 'Publisher'
            if (-not $pub) { continue }
            $name = Read-JuicerReg "$root\$k" 'DisplayName'
            $loc = Read-JuicerReg "$root\$k" 'InstallLocation'
            $g = Get-JuicerPublisherGame $(if ($name) { [string]$name.Value }) ([string]$pub.Value) $(if ($loc) { [string]$loc.Value })
            if ($g -and (Test-Path -LiteralPath $g.Dir)) { $g }
        }
    }
}

# --- All of them ------------------------------------------------------------------

function Get-JuicerLibraryPath { Join-Path (Get-JuicerHome) 'juegos.json' }

# Exe: the .exe worked out or chosen for each game id; Custom: games added by
# hand; Known: ids already seen, to mark the new ones.
function Read-JuicerLibraryState {
    $s = @{ Exe = @{}; Custom = @(); Known = @() }
    $p = Get-JuicerLibraryPath
    if (Test-Path -LiteralPath $p) {
        try {
            $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
            if ($d.Exe -is [hashtable]) { $s.Exe = $d.Exe }
            $s.Custom = @($d.Custom | Where-Object { $_ -is [hashtable] })
            $s.Known = @($d.Known | Where-Object { $_ })
        } catch {
            Write-JuicerLog "juegos.json dañado, se ignora: $_"
        }
    }
    $s
}

function Save-JuicerLibraryState {
    param([hashtable]$State)
    [IO.File]::WriteAllText((Get-JuicerLibraryPath), (ConvertTo-JuicerJson $State), (New-Object Text.UTF8Encoding $false))
}

# Every game found, with its .exe: the one chosen or remembered, the one the
# launcher declares, or the best guess from its folder. Collectors can be
# replaced (the tests); each launcher fails on its own.
function Get-JuicerGames {
    param([scriptblock[]]$Collectors, [scriptblock]$FindExe = ${function:Find-JuicerGameExe}, [switch]$KeepNew)
    if (-not $Collectors) {
        $Collectors = @(${function:Get-JuicerSteamGames}, ${function:Get-JuicerEpicGames}, ${function:Get-JuicerGogGames}, ${function:Get-JuicerXboxGames}, ${function:Get-JuicerPublisherGames})
    }
    $state = Read-JuicerLibraryState
    $found = New-Object System.Collections.ArrayList
    foreach ($c in $Collectors) {
        try { foreach ($g in @(& $c)) { if ($g) { [void]$found.Add($g) } } } catch { Write-JuicerLog "Una biblioteca de juegos no se pudo leer: $_" }
    }
    foreach ($g in $state.Custom) { [void]$found.Add($g) }
    $seen = @{}
    $out = @()
    # By name; for the same game in two launchers, the one already known (so
    # its id, and the .exe chosen for it, stay the same) and then always the
    # same one: Sort-Object is not stable on every PowerShell.
    $order = @(
        @{ Expression = { $_.Name } }
        @{ Expression = { if ($state.Known -contains $_.Id -or $state.Exe.ContainsKey($_.Id)) { 0 } else { 1 } } }
        @{ Expression = { $_.Id } }
    )
    foreach ($g in ($found | Sort-Object -Property $order)) {
        if ($seen.ContainsKey($g.Id)) { continue }
        $chosen = [string]$state.Exe[$g.Id]
        if ($chosen -and (Test-JuicerGameFile $chosen)) { $g.Exe = $chosen }
        elseif (-not $g.Exe -or -not (Test-JuicerGameFile $g.Exe)) { $g.Exe = [string](& $FindExe $g.Dir $g.Name) }
        if (-not $g.Exe) { continue }
        # Two launchers can list the same folder (a GOG game added to Steam).
        $key = $g.Exe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$g.Id] = 1; $seen[$key] = 1
        $state.Exe[$g.Id] = $g.Exe
        $g.ExeName = (Split-Path -Leaf $g.Exe).ToLowerInvariant()
        $g.New = $state.Known.Count -gt 0 -and $state.Known -notcontains $g.Id
        $out += $g
    }
    if (-not $KeepNew) { $state.Known = @($out | ForEach-Object { $_.Id }) }
    Save-JuicerLibraryState $state
    $out
}

function Test-JuicerGameFile { param([string]$Path) [bool]($Path -and (Test-Path -LiteralPath $Path -PathType Leaf)) }

# The user picked another .exe for a game, or added one by hand.
function Set-JuicerGameExe {
    param([Parameter(Mandatory)][string]$Id, [Parameter(Mandatory)][string]$Exe)
    $s = Read-JuicerLibraryState
    $s.Exe[$Id] = $Exe
    Save-JuicerLibraryState $s
}

function Add-JuicerCustomGame {
    param([Parameter(Mandatory)][string]$Exe)
    $s = Read-JuicerLibraryState
    $name = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $g = New-JuicerGame 'custom' (ConvertTo-JuicerLooseName $Exe) $name (Split-Path -Parent $Exe) $Exe
    if (@($s.Custom | Where-Object { $_.Id -eq $g.Id }).Count -eq 0) { $s.Custom = @($s.Custom) + $g }
    $s.Exe[$g.Id] = $Exe
    Save-JuicerLibraryState $s
    $g
}

# --- What each game has, and setting it up ---------------------------------------

# Status per game from the journal and the limiter: Fps (null if none), Gpu,
# Priority.
function Get-JuicerGameStatus {
    param([object[]]$Games)
    $journal = Read-JuicerJournal
    $ids = @{}
    foreach ($e in $journal) { $ids[([string]$e.Id).ToLowerInvariant()] = 1 }
    $fps = @{}
    foreach ($l in @(Get-JuicerFpsLimits)) { $fps[$l.Exe] = $l.Fps }
    foreach ($g in $Games) {
        $g.Fps = $fps[$g.ExeName]
        $g.Limited = $ids.ContainsKey("fps:$($g.ExeName)")
        $g.Gpu = $ids.ContainsKey('juego:gpu:' + $g.Exe.ToLowerInvariant())
        $g.Priority = $ids.ContainsKey("juego:prioridad:$($g.ExeName)")
        $g
    }
}

function Format-JuicerGameStatus {
    param([hashtable]$Game)
    $p = @()
    if ($Game.Fps) { $p += '{0} FPS ({1:N2} ms)' -f $Game.Fps, (1000 / $Game.Fps) } elseif ($Game.Limited) { $p += 'frame pacer quitado fuera de Win Juicer' }
    if ($Game.Gpu) { $p += 'GPU dedicada' }
    if ($Game.Priority) { $p += 'prioridad alta' }
    if ($p.Count -eq 0) { 'sin configurar' } else { $p -join ' · ' }
}

# What = Recomendado (FPS limit for this monitor and, with two graphics
# cards, the dedicated one), Fps, Gpu, Prioridad or Quitar (everything Win
# Juicer set on these games).
function Invoke-JuicerGameSetup {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Games, [ValidateSet('Recomendado', 'Fps', 'Gpu', 'Prioridad', 'Quitar')][string]$What, [int]$Fps, [int]$GpuCount = -1, [hashtable]$Monitor)
    if ($GpuCount -lt 0) { $GpuCount = Get-JuicerGpuCount }
    if (-not $Monitor -and $What -in 'Recomendado', 'Fps') { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $journal = Read-JuicerJournal
    foreach ($g in $Games) {
        # One game failing (no monitor to size the limit, a driver error)
        # does not stop the others.
        try {
            switch ($What) {
                'Recomendado' {
                    Add-JuicerFpsLimit $g.ExeName $Fps $Monitor
                    if ($GpuCount -ge 2 -and [IO.Path]::IsPathRooted($g.Exe)) { Invoke-JuicerTweak (New-JuicerGpuTweak $g.Exe) }
                }
                'Fps' { Add-JuicerFpsLimit $g.ExeName $Fps $Monitor }
                # Windows keys the GPU choice by full path: games known only by name have none.
                'Gpu' { if ([IO.Path]::IsPathRooted($g.Exe)) { Invoke-JuicerTweak (New-JuicerGpuTweak $g.Exe) } }
                'Prioridad' { Invoke-JuicerTweak (New-JuicerPriorityTweak $g.Exe) }
                'Quitar' {
                    foreach ($id in "fps:$($g.ExeName)", ('juego:gpu:' + $g.Exe.ToLowerInvariant()), "juego:prioridad:$($g.ExeName)") {
                        if (@($journal | Where-Object { ([string]$_.Id).ToLowerInvariant() -eq $id }).Count -gt 0) { Undo-JuicerTweak $id }
                    }
                }
            }
        } catch {
            New-JuicerResult @{ Id = "juego:$($g.ExeName)"; Title = $g.Name; Reboot = 'No' } 'Error' "$_"
        }
    }
}
