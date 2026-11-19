# The games installed on this PC, each with the .exe that actually runs, so
# they can be listed and set up in one click. Every launcher keeps its own
# record of what it installed: Steam's app manifests, Epic's .item files,
# GOG's and the others' registry entries, Xbox's MicrosoftGame.config. Steam
# and the registry say where a game is but not which .exe it runs, so that
# is worked out from the files (Unreal's *-Win64-Shipping.exe, the biggest
# executable named like the game, never an uninstaller or a crash reporter)
# and remembered; the user can always pick another.

$script:NotGameNames = 'Redistributable|Redistributables|Soundtrack|\bOST\b|\bSDK\b|Dedicated Server|Proton|Steam Linux Runtime|SteamVR|Wallpaper Engine|Steamworks Common|DirectX|Visual C\+\+|\.NET|PhysX|Benchmark Tool|Demo$|Riot Vanguard|Anti-?Cheat|Easy ?Anti|BattlEye|Update Agent|Crash ?(Reporter|Handler)'
# Anti-cheat and updater agents register like games (Riot Vanguard, Battle.net Update Agent,
# EA helpers). «Vanguard» alone is not listed on purpose (Call of Duty: Vanguard is a game),
# and neither is a name merely ending in «Launcher»: a real game can be called that.
# Whole executable names (without .exe), never prefixes: a game called
# CrashBandicoot, ServerSim or ConfigurationQuest must not be taken for a tool.
$script:NotGameExe = '^(' + (@(
        'unins\d*', 'uninstall(er)?', '.+[_ -]uninstall(er)?', 'setup', 'setup[_ -].+', '.+[_ -]setup', 'install(er)?', 'install[_ -].+', '.+[_ -]installer',
        'vc_?redist.*', 'vcredist.*', 'redist', 'dxsetup', 'dxwebsetup', 'dotnet[_-].*', 'dotnetfx.*', 'physx(setup|legacy|_?installer).*',
        '(ue4?|ue5)?prereq.*', 'ue4prereqsetup.*',
        '.*crash(handler|report(er|client)?|pad_handler|sender|_?dump)\d*', 'bugsplat.*', 'errorreport.*', 'report(er)?', 'dump(er)?', 'minidump.*', 'crs-.+',
        'gamelaunchhelper', 'easyanticheat.*', 'eac_?(launcher|setup|server|bootstrapper)', 'beservice.*', 'battleye.*', 'start_protected_game',
        'cefprocess', 'cef_?subprocess', 'cefsharp.*', 'unrealcefsubprocess', 'epicwebhelper', '.*webhelper(_.*)?', 'qtwebengineprocess',
        '(game)?overlay(ui|renderer|helper|process)?(_?(x64|x86|64|32))?', 'notification(helper|service)?', 'socialclub(helper)?',
        'launcherpatcher', '.*updater', 'update(r)?', '.+[_ -]update', '.*patcher', 'repair', 'cleanup', 'config(tool|urator)?', 'configure', '.+[_ -]config(tool)?', 'settings',
        'python(w)?', '7z', 'vulkan(info|install).*',
        'server', '.+[_-]server', 'dedicated(_?server)?', '.*dedicatedserver', '(unreal)?editor', '.+[_-]editor'
    ) -join '|') + ')$'

# Steam's appmanifest_*.acf, Valve's KeyValues text.
function ConvertFrom-JuicerAcf {
    param([string]$Text)
    $v = @{}
    foreach ($k in 'appid', 'name', 'installdir', 'buildid') {
        $m = [regex]::Match($Text, '"' + $k + '"\s+"((?:[^"\\]|\\.)*)"', 'IgnoreCase')
        if ($m.Success) { $v[$k] = $m.Groups[1].Value -replace '\\\\', '\' }
    }
    if (-not $v.installdir) { return $null }
    @{ AppId = [string]$v.appid; Name = [string]$v.name; InstallDir = [string]$v.installdir; BuildId = [string]$v.buildid }
}

# The build of a game, to tell when an update has made an old calibration stale: «steam:<buildid>» from
# the library's appmanifest when the game sits in a Steam library (steamapps\common\<dir>), else
# «exe:<file version>» of its executable, else ''. Path is the executable (or the game's folder);
# without it, the running process of that name is looked at.
function Get-JuicerGameBuild {
    param([string]$Exe, [string]$Path)
    if (-not $Path -and $Exe) {
        try {
            $p = @(Get-Process -Name ([IO.Path]::GetFileNameWithoutExtension($Exe)) -ErrorAction Stop | Where-Object { $_.Path } | Select-Object -First 1)
            if ($p.Count -gt 0) { $Path = [string]$p[0].Path }
        } catch { Write-Verbose "Sin proceso de ${Exe}: $_" }
    }
    if (-not $Path) { return '' }
    # Up the folders until one is steamapps\common\<installdir>.
    $dir = if (Test-Path -LiteralPath $Path -PathType Leaf) { Split-Path -Parent $Path } else { $Path }
    for ($i = 0; $dir -and $i -lt 8; $i++) {
        $common = Split-Path -Parent $dir
        if ($common -and (Split-Path -Leaf $common) -eq 'common') {
            $lib = Split-Path -Parent $common
            foreach ($acf in @(Get-ChildItem -LiteralPath $lib -Filter 'appmanifest_*.acf' -ErrorAction SilentlyContinue)) {
                try { $a = ConvertFrom-JuicerAcf ([IO.File]::ReadAllText($acf.FullName)) } catch { continue }
                if ($a -and $a.BuildId -and [string]$a.InstallDir -eq (Split-Path -Leaf $dir)) { return "steam:$($a.BuildId)" }
            }
            break
        }
        $dir = $common
    }
    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        try {
            $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
            $ver = if ($v.FileVersion) { [string]$v.FileVersion } else { [string]$v.ProductVersion }
            if ($ver) { return "exe:$ver" }
        } catch { Write-Verbose "Sin versión de ${Path}: $_" }
    }
    ''
}

function Test-JuicerNotAGame { param([string]$Name) [bool]($Name -match $script:NotGameNames) }

function ConvertTo-JuicerLooseName { param([string]$Text) ($Text.ToLowerInvariant() -replace '[^a-z0-9]', '') }

# Files are @{ Path (relative to the game folder); Size }. The best guess at
# the game's own executable, or null.
function Select-JuicerGameExe {
    param([object[]]$Files, [string]$Name)
    $loose = ConvertTo-JuicerLooseName $Name
    $best = $null; $bestScore = [double]::MinValue
    $biggest = $null; $biggestSize = -1.0
    # Unreal's own *-Win64-Shipping.exe, when the tree has one, is the game: a
    # launcher next to it (MarvelRivals_Launcher.exe) is never the answer.
    $hasShipping = [bool](@($Files | Where-Object { $_.Path -match '-Win64-Shipping\.exe$' -and (Split-Path -Leaf $_.Path) -notmatch '(?i)launcher' }).Count -gt 0)
    foreach ($f in $Files) {
        $file = Split-Path -Leaf $f.Path
        $base = [IO.Path]::GetFileNameWithoutExtension($file)
        # Last resort when every exe looks like a tool: better a wrong guess
        # the user can change than a game that silently disappears.
        if ([double]$f.Size -gt $biggestSize) { $biggestSize = [double]$f.Size; $biggest = $f.Path }
        if ($base -match $script:NotGameExe) { continue }
        $score = 0.0
        if ($file -match '-Win64-Shipping\.exe$') { $score += 60 }
        $lb = ConvertTo-JuicerLooseName ($base -replace '-Win64-Shipping$', '')
        if ($lb -and $loose -and ($loose.Contains($lb) -or $lb.Contains($loose))) { $score += 35 }
        if ($f.Path -match '(?i)(^|\\)(Binaries\\Win64|bin\\x64|bin64|x64)\\') { $score += 15 }
        # A launcher never wins over the game itself: with any other candidate it is out.
        if ($base -match '(?i)launcher') { if ($hasShipping) { continue }; $score -= 25 }
        $score += [Math]::Min(25, [double]$f.Size / 20MB)
        $score -= 3 * ([regex]::Matches($f.Path, '\\').Count)
        if ($score -gt $bestScore) { $bestScore = $score; $best = $f.Path }
    }
    if ($best) { $best } else { $biggest }
}

# The executables of a game folder, five levels deep at most (-Depth 0 is the
# folder's own children, so Unreal's Game\Binaries\Win64\x.exe, four levels
# down, is in range in PowerShell 5.1 and 7 alike, with one level to spare).
function Find-JuicerGameExe {
    param([string]$Dir, [string]$Name)
    if (-not $Dir -or -not (Test-Path -LiteralPath $Dir)) { return $null }
    $root = (Resolve-Path -LiteralPath $Dir).ProviderPath.TrimEnd('\')
    $files = @(Get-ChildItem -LiteralPath $root -Filter '*.exe' -File -Recurse -Depth 5 -ErrorAction SilentlyContinue | ForEach-Object {
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
            # One unreadable manifest (locked, half-written) must not hide the rest of the library.
            try { $a = ConvertFrom-JuicerAcf ([IO.File]::ReadAllText($acf.FullName)) } catch { Write-Verbose "Manifiesto de Steam ilegible: $($acf.FullName)"; continue }
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
        # A half-finished install (or a pending update that left the manifest) is not a playable game yet.
        if ($m.bIsIncompleteInstall -eq $true) { continue }
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
    # The first one is not always the game: some packages list a launch helper first.
    $pick = $null
    foreach ($e in $exe) { if ([string]$e.GetAttribute('Id') -eq 'Game') { $pick = $e; break } }
    if (-not $pick) {
        foreach ($e in $exe) {
            $base = [IO.Path]::GetFileNameWithoutExtension(([string]$e.GetAttribute('Name') -split '[\\/]')[-1])
            if ($base -and $base -notmatch $script:NotGameExe) { $pick = $e; break }
        }
    }
    if (-not $pick -and $exe.Count -gt 0) { $pick = $exe[0] }
    $name = $x.SelectSingleNode('//*[local-name()="ShellVisuals"]')
    @{
        Exe = $(if ($pick) { [string]$pick.GetAttribute('Name') } else { '' })
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
# hand; Known: ids already seen, to mark the new ones; Hidden: ids the person
# said are not games (a tool, a benchmark), kept out of the gallery and of the
# automatic optimizing but still known, so showing them again is not «new»;
# Tech: what each game's folder says it can do (see Update-JuicerGameTech).
function Read-JuicerLibraryState {
    $s = @{ Exe = @{}; Custom = @(); Known = @(); Hidden = @(); Tech = @{} }
    $p = Get-JuicerLibraryPath
    if (Test-Path -LiteralPath $p) {
        try {
            $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
            if ($d.Exe -is [hashtable]) { $s.Exe = $d.Exe }
            if ($d.Tech -is [hashtable]) { $s.Tech = $d.Tech }
            $s.Custom = @($d.Custom | Where-Object { $_ -is [hashtable] })
            $s.Known = @($d.Known | Where-Object { $_ })
            $s.Hidden = @($d.Hidden | Where-Object { $_ })
        } catch {
            Write-JuicerLog "juegos.json dañado, se ignora: $_"
        }
    }
    $s
}

function Save-JuicerLibraryState {
    param([hashtable]$State)
    Write-JuicerTextAtomic (Get-JuicerLibraryPath) (ConvertTo-JuicerJson $State)
}

function ConvertTo-JuicerGameFolderKey {
    param([string]$Path)
    if (-not $Path) { return '' }
    ($Path -replace '/', '\').Trim().Trim('"').TrimEnd('\').ToLowerInvariant()
}

# The same installed game can be listed by its store and again by the
# uninstall registry (a publisher's own launcher), with the same folder or
# one inside the other, and each entry then works out a different .exe
# (the launcher at the root, the Shipping one deeper): three gallery entries
# for one game. Entries collapse when their folders are the same or nested,
# the store one (Steam, Epic, GOG, Xbox: it has the name and the id the rest
# of Win Juicer keys on) winning over the registry one, and then the one
# already known, so ids and chosen .exe files stay. Two store entries never
# collapse by folder (the .exe check in Get-JuicerGames still joins them), and
# nor do two that declare different .exe files. The winner lists the ids it
# absorbed in Merged, so what was set under them is not lost.
function Merge-JuicerGameDuplicates {
    param([object[]]$Games, [hashtable]$State)
    $rank = { param($g) if ($g.Launcher -eq 'custom') { 2 } elseif ($script:StoreLaunchers -contains $g.Launcher -or $g.Launcher -like 'Xbox*') { 0 } else { 1 } }
    $knownIds = if ($State) { @($State.Known) + @($State.Exe.Keys) } else { @() }
    $known = { param($g) if ($knownIds -contains $g.Id) { 0 } else { 1 } }.GetNewClosure()
    $depth = { param($k) ($k -split '\\').Count }
    $order = @(
        @{ Expression = { & $rank $_ } }
        @{ Expression = { & $known $_ } }
        @{ Expression = { - (& $depth (ConvertTo-JuicerGameFolderKey $_.Dir)) } }
        @{ Expression = { $_.Id } }
    )
    $kept = New-Object System.Collections.ArrayList
    foreach ($g in @($Games | Sort-Object -Property $order)) {
        $k = ConvertTo-JuicerGameFolderKey $g.Dir
        $rg = & $rank $g
        $into = $null
        if ($k -and $rg -eq 1) {
            foreach ($w in $kept) {
                $wk = ConvertTo-JuicerGameFolderKey $w.Dir
                if (-not $wk -or (& $rank $w) -eq 2) { continue }
                if ($k -ne $wk -and -not $k.StartsWith($wk + '\') -and -not $wk.StartsWith($k + '\')) { continue }
                if ($g.Exe -and $w.Exe -and $g.Exe -ne $w.Exe) { continue }
                $into = $w; break
            }
        }
        if ($into) { $into.Merged = @(@($into.Merged) + $g.Id + @($g.Merged) | Where-Object { $_ }) } else { [void]$kept.Add($g) }
    }
    $kept.ToArray()
}
$script:StoreLaunchers = @('Steam', 'Epic Games', 'GOG', 'Xbox')

# Every game found, with its .exe: the one chosen or remembered, the one the
# launcher declares, or the best guess from its folder. Collectors can be
# replaced (the tests); each launcher fails on its own.
function Get-JuicerGames {
    param([scriptblock[]]$Collectors, [scriptblock]$FindExe = ${function:Find-JuicerGameExe}, [switch]$KeepNew, [switch]$IncludeHidden)
    if (-not $Collectors) {
        $Collectors = @(${function:Get-JuicerSteamGames}, ${function:Get-JuicerEpicGames}, ${function:Get-JuicerGogGames}, ${function:Get-JuicerXboxGames}, ${function:Get-JuicerPublisherGames})
    }
    $state = Read-JuicerLibraryState
    $found = New-Object System.Collections.ArrayList
    $failed = $false
    foreach ($c in $Collectors) {
        try { foreach ($g in @(& $c)) { if ($g) { [void]$found.Add($g) } } } catch { $failed = $true; Write-JuicerLog "Una biblioteca de juegos no se pudo leer: $_" }
    }
    foreach ($g in $state.Custom) { [void]$found.Add($g) }
    $found = New-Object System.Collections.ArrayList (, @(Merge-JuicerGameDuplicates @($found) $state))
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
        # What was chosen under an id that collapsed into this one carries over.
        if (-not $chosen) { foreach ($m in @($g.Merged | Where-Object { $_ })) { if ($state.Exe[$m]) { $chosen = [string]$state.Exe[$m]; break } } }
        if ($chosen -and (Test-JuicerGameFile $chosen)) { $g.Exe = $chosen }
        elseif (-not $g.Exe -or -not (Test-JuicerGameFile $g.Exe)) { $g.Exe = [string](& $FindExe $g.Dir $g.Name) }
        if (-not $g.Exe) { continue }
        # Two launchers can list the same folder (a GOG game added to Steam).
        $key = $g.Exe.ToLowerInvariant()
        if ($seen.ContainsKey($key)) { continue }
        $seen[$g.Id] = 1; $seen[$key] = 1
        $state.Exe[$g.Id] = $g.Exe
        $g.ExeName = (Split-Path -Leaf $g.Exe).ToLowerInvariant()
        $wasKnown = $state.Known -contains $g.Id -or @($g.Merged | Where-Object { $state.Known -contains $_ }).Count -gt 0
        $g.New = $state.Known.Count -gt 0 -and -not $wasKnown
        # Hidden carries over from the ids this one absorbed: hiding the registry entry of a
        # game that later merged into its store entry must not bring it back to the gallery.
        $g.Hidden = [bool]($state.Hidden -contains $g.Id) -or @($g.Merged | Where-Object { $_ -and $state.Hidden -contains $_ }).Count -gt 0
        $out += $g
    }
    # A collector that threw found nothing this run; forgetting its ids would
    # make all its games look new the next time it works.
    if (-not $KeepNew) {
        $ids = @($out | ForEach-Object { $_.Id })
        if ($failed) { $ids = @($ids + @($state.Known) | Select-Object -Unique) }
        $state.Known = $ids
    }
    Save-JuicerLibraryState $state
    # Hidden after the ids are remembered: what is hidden is not new when it comes back.
    if (-not $IncludeHidden) { $out = @($out | Where-Object { -not $_.Hidden }) }
    $out
}

# The ids hidden from the gallery (they stay on disk in juegos.json).
function Get-JuicerHiddenGameIds { @((Read-JuicerLibraryState).Hidden) }

# «No es un juego»: out of the gallery and of the automatic optimizing, or back in.
# Nothing is deleted and nothing Win Juicer set on the game is touched.
function Set-JuicerGameHidden {
    param([Parameter(Mandatory)][string]$Id, [bool]$Hidden = $true)
    $s = Read-JuicerLibraryState
    $rest = @($s.Hidden | Where-Object { $_ -ne $Id })
    $s.Hidden = $(if ($Hidden) { @($rest) + $Id } else { $rest })
    Save-JuicerLibraryState $s
}

# --- What a game's folder says it can do -------------------------------------------
# The files of the technologies that matter for latency, by name only (nothing
# is opened or read): NVIDIA Reflex (Streamline's sl.reflex.dll, or the Vulkan
# layer), DLSS Frame Generation and FSR 3 frame generation. They say the game
# is capable: a game can ship the DLL and have the option off, and a game
# without it may still have the technology built in, so their absence proves
# nothing.
$script:TechFiles = @{
    Reflex = '^(sl\.reflex\.dll|nvlowlatencyvk\.dll)$'
    DlssFG = '^(nvngx_dlssg\.dll|sl\.dlss_g\.dll)$'
    Fsr3FG = '^ffx_frameinterpolation'
}

# The game folder to three levels down, and the .exe's own folder to one
# (Unreal keeps them at Game\Binaries\Win64, deeper than that), counting at
# most MaxFiles files so that a huge install is not walked for long. Returns
# @{ Reflex; DlssFG; Fsr3FG; Files }.
function Find-JuicerGameTech {
    param([string]$Dir, [string]$ExeDir = '', [int]$MaxFiles = 20000)
    $any = '(' + (($script:TechFiles.Values) -join '|') + ')'
    $found = @{}
    $seen = 0
    $roots = @(@{ Path = $Dir; Depth = 3 })
    if ($ExeDir -and $ExeDir.TrimEnd('\') -ne ([string]$Dir).TrimEnd('\')) { $roots += @{ Path = $ExeDir; Depth = 1 } }
    foreach ($root in $roots) {
        if (-not $root.Path -or -not (Test-Path -LiteralPath $root.Path -PathType Container)) { continue }
        $queue = New-Object System.Collections.Queue
        $queue.Enqueue(@{ P = [string]$root.Path; D = 0 })
        while ($queue.Count -gt 0 -and $seen -lt $MaxFiles) {
            $item = $queue.Dequeue()
            try {
                foreach ($f in [IO.Directory]::EnumerateFiles($item.P)) {
                    $seen++
                    $leaf = [IO.Path]::GetFileName($f).ToLowerInvariant()
                    if ($leaf -match $any) { $found[$leaf] = $true }
                    if ($seen -ge $MaxFiles) { break }
                }
                if ($item.D -lt $root.Depth) { foreach ($d in [IO.Directory]::EnumerateDirectories($item.P)) { $queue.Enqueue(@{ P = $d; D = ($item.D + 1) }) } }
            } catch {
                Write-Verbose "Carpeta sin leer: $($item.P)"
            }
        }
    }
    $names = @($found.Keys | Sort-Object)
    @{
        Reflex = [bool](@($names | Where-Object { $_ -match $script:TechFiles.Reflex }).Count -gt 0)
        DlssFG = [bool](@($names | Where-Object { $_ -match $script:TechFiles.DlssFG }).Count -gt 0)
        Fsr3FG = [bool](@($names | Where-Object { $_ -match $script:TechFiles.Fsr3FG }).Count -gt 0)
        Files = $names
    }
}

# What was found for a game the last time (null if never looked). Reads only.
function Get-JuicerGameTech {
    param([string]$ExeName)
    if (-not $ExeName) { return $null }
    $t = (Read-JuicerLibraryState).Tech[([string]$ExeName).ToLowerInvariant()]
    if ($t -is [hashtable]) { $t } else { $null }
}

# Looks at the game's folder, or uses what was found before: the answer is kept
# in juegos.json with the folder's last write time and the date, and is looked
# for again when either changes (or after 30 days: a patch rewrites files
# without touching the folder). Game is the gallery's (Dir, Exe, ExeName).
# Never throws.
function Update-JuicerGameTech {
    param([Parameter(Mandatory)][hashtable]$Game, [switch]$Force)
    $exe = ([string]$Game.ExeName).ToLowerInvariant()
    if (-not $exe) { return $null }
    $dir = [string]$Game.Dir
    try {
        if (-not $dir -or -not (Test-Path -LiteralPath $dir -PathType Container)) { return (Get-JuicerGameTech $exe) }
        $stamp = [string](Get-Item -LiteralPath $dir -ErrorAction Stop).LastWriteTimeUtc.Ticks
        $state = Read-JuicerLibraryState
        $c = $state.Tech[$exe]
        if ($c -is [hashtable] -and -not $Force -and [string]$c.Stamp -eq $stamp -and [string]$c.Dir -eq $dir) {
            $when = [datetime]::MinValue
            if ([datetime]::TryParse([string]$c.Date, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when) -and ((Get-Date) - $when).TotalDays -lt 30) { return $c }
        }
        $exeDir = if ([IO.Path]::IsPathRooted([string]$Game.Exe)) { [IO.Path]::GetDirectoryName([string]$Game.Exe) } else { '' }
        $t = Find-JuicerGameTech $dir $exeDir
        $entry = @{ Dir = $dir; Stamp = $stamp; Date = (Get-Date).ToString('s'); Reflex = $t.Reflex; DlssFG = $t.DlssFG; Fsr3FG = $t.Fsr3FG; Files = @($t.Files) }
        $state.Tech[$exe] = $entry
        Save-JuicerLibraryState $state
        $entry
    } catch {
        Write-JuicerLog "No se pudo mirar la carpeta de ${exe}: $_"
        Get-JuicerGameTech $exe
    }
}

# «DLSS Frame Generation», «FSR 3 Frame Generation» or both, or '' when the
# folder shows none.
function Get-JuicerFrameGenName {
    param([hashtable]$Tech)
    if (-not $Tech) { return '' }
    $n = @()
    if ($Tech.DlssFG) { $n += 'DLSS Frame Generation' }
    if ($Tech.Fsr3FG) { $n += 'FSR 3 Frame Generation' }
    $n -join ' y '
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
    $pacer = Read-JuicerPacer
    # The monitor is read only if some game has a calibration to compare with.
    $calMonitor = $null
    $calRead = $false
    foreach ($g in $Games) {
        $g.Fps = $fps[$g.ExeName]
        $g.Limited = $ids.ContainsKey("fps:$($g.ExeName)")
        $g.Gpu = $ids.ContainsKey('juego:gpu:' + $g.Exe.ToLowerInvariant())
        $g.Priority = $ids.ContainsKey("juego:prioridad:$($g.ExeName)")
        $p = $pacer.Games[[string]$g.ExeName]
        $g.Safe = [bool]($p -is [hashtable] -and $p.Safe)
        $g.Minimal = [bool]($p -is [hashtable] -and $p.Minimal)
        $g.Waiting = $pacer.Pending.ContainsKey([string]$g.ExeName)
        $per = $pacer.Calibrated[[string]$g.ExeName]
        $cal = $null
        if ($per -is [hashtable] -and $per.Count -gt 0) {
            if (-not $calRead) {
                $calRead = $true
                try { $calMonitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
            }
            # The one for this monitor setup, else the latest of another (which is not used, and says so).
            $cal = Select-JuicerCalibration $per $calMonitor
        }
        $g.CalFps = $(if ($cal -is [hashtable] -and [int]$cal.Fps -gt 0) { [int]$cal.Fps } else { 0 })
        $g.CalDate = $(if ($cal -is [hashtable]) { [string]$cal.Date } else { '' })
        # Whether it is in force on this monitor: its age says nothing otherwise.
        $g.CalState = ''
        $g.CalChanges = @()
        if ($g.CalFps) {
            $g.CalState = Get-JuicerCalibrationState ([string]$g.ExeName) $cal $calMonitor $pacer
            # What the PC runs now that it did not when it was calibrated (driver, game build, card, Windows).
            if ($g.CalState -eq 'Activa' -and $cal.Fingerprint -is [hashtable]) {
                try { $g.CalChanges = @(Get-JuicerCalibrationChanges $cal.Fingerprint (Get-JuicerCalibrationFingerprint ([string]$g.ExeName) ([string]$g.Exe))) } catch { Write-JuicerLog "Sin huella de $($g.ExeName): $_" }
            }
        }
        $g
    }
}

function Format-JuicerGameStatus {
    param([hashtable]$Game)
    $p = @()
    if ($Game.Fps) { $p += '{0} FPS ({1:N2} ms)' -f $Game.Fps, (1000 / $Game.Fps) } elseif ($Game.Limited) { $p += 'frame pacer quitado fuera de Win Juicer' }
    # The age of a calibration only when it is the one in force; made for another screen it says so.
    if ($Game.Fps -and $Game.CalFps) {
        if ($Game.CalState -eq 'Activa') { $age = Get-JuicerCalibrationAge $Game.CalDate $Game.CalFps -Changes @($Game.CalChanges); if ($age) { $p += $age.Text; if ($age.Changes.Count -gt 0) { $p += $age.Hint } } }
        elseif ($Game.CalState -eq 'OtroMonitor') { $p += 'calibración de otro monitor o modo' }
    }
    if ($Game.Gpu) { $p += 'GPU dedicada' }
    if ($Game.Priority) { $p += 'prioridad por encima de lo normal' }
    if ($Game.Minimal -and $Game.Fps) { $p += 'modo prudente' }
    if ($Game.Waiting) { $p += 'cambio en espera hasta que lo cierres' }
    if ($Game.Safe) { $p += 'sin tocar: falló después de optimizarlo' }
    if ($p.Count -eq 0) { 'sin configurar' } else { $p -join ' · ' }
}

# What = Recomendado (FPS limit for this monitor and, with two graphics
# cards, the dedicated one), Fps, Gpu, Prioridad or Quitar (everything Win
# Juicer set on these games). A game Win Juicer protected after it failed
# (Update-JuicerGameSafety) is left alone unless Force: the user asked for
# that very game.
function Invoke-JuicerGameSetup {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Games, [ValidateSet('Recomendado', 'Fps', 'Gpu', 'Prioridad', 'Quitar')][string]$What, [int]$Fps, [int]$GpuCount = -1, [hashtable]$Monitor, [switch]$Force)
    if ($GpuCount -lt 0) { $GpuCount = Get-JuicerGpuCount }
    if (-not $Monitor -and $What -in 'Recomendado', 'Fps') { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $journal = Read-JuicerJournal
    foreach ($g in $Games) {
        # One game failing (no monitor to size the limit, a driver error)
        # does not stop the others.
        try {
            if ($What -ne 'Quitar' -and (Get-JuicerGameSafe $g.ExeName)) {
                if (-not $Force) {
                    New-JuicerResult @{ Id = "juego:$($g.ExeName)"; Title = $g.Name; Reboot = 'No' } 'NoAplica' 'Sin tocar: falló después de optimizarlo. Ábrelo en la galería y pulsa «Optimizar este juego» si quieres volver a intentarlo, en modo prudente.'
                    continue
                }
                Clear-JuicerGameSafe $g.ExeName
            }
            switch ($What) {
                'Recomendado' {
                    # What its folder shows (Reflex, frame generation) is kept first, for the note on the rate set.
                    try { [void](Update-JuicerGameTech $g) } catch { Write-JuicerLog "Sin carpeta de $($g.ExeName): $_" }
                    # A rate given by hand is kept, so recalculating does not undo it.
                    if ($Fps -gt 0) { Set-JuicerPacerFps $g.ExeName $Fps $Monitor } else { Add-JuicerFpsLimit $g.ExeName 0 $Monitor }
                    if ($GpuCount -ge 2 -and [IO.Path]::IsPathRooted($g.Exe)) { Invoke-JuicerTweak (New-JuicerGpuTweak $g.Exe) }
                }
                # 0 is automatic again.
                'Fps' {
                    try { [void](Update-JuicerGameTech $g) } catch { Write-JuicerLog "Sin carpeta de $($g.ExeName): $_" }
                    Set-JuicerPacerFps $g.ExeName $Fps $Monitor
                }
                # Windows keys the GPU choice by full path: games known only by name have none.
                'Gpu' { if ([IO.Path]::IsPathRooted($g.Exe)) { Invoke-JuicerTweak (New-JuicerGpuTweak $g.Exe) } }
                'Prioridad' { Invoke-JuicerTweak (New-JuicerPriorityTweak $g.Exe) }
                'Quitar' {
                    # The frame pacer of an open game goes when it closes.
                    Remove-JuicerFpsLimit $g.ExeName
                    foreach ($id in ('juego:gpu:' + $g.Exe.ToLowerInvariant()), "juego:prioridad:$($g.ExeName)") {
                        if (@($journal | Where-Object { ([string]$_.Id).ToLowerInvariant() -eq $id }).Count -gt 0) { Undo-JuicerTweak $id }
                    }
                }
            }
        } catch {
            New-JuicerResult @{ Id = "juego:$($g.ExeName)"; Title = $g.Name; Reboot = 'No' } 'Error' "$_"
        }
    }
}
