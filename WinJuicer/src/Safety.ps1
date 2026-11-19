# Games that misbehave after being optimized. Win Juicer never writes a game's
# profile while it runs (see Assert-JuicerGameClosed and the frame pacer's
# Pending list), and its recipe leaves alone what NVIDIA set for each game.
# That still leaves the odd game that does not get on with something: its
# frame cap, VSync forced by the driver, RivaTuner's hook. So after a game is
# optimized, Windows' own record of programs that crashed («Application
# Error» 1000) or hung and were closed («Application Hang» 1002) is checked:
# a game that never failed before and fails since gets everything Win Juicer
# set on it taken away, prudent mode for next time, and a plain note saying
# what happened. A game that already failed before is only pointed out: the
# cause is not likely to be Win Juicer, and taking its pace away would not help.

# The day Win Juicer first changed something of this game, from the journal
# (null if it changed nothing).
function Get-JuicerGameSince {
    param([Parameter(Mandatory)][string]$Exe, [System.Collections.IList]$Journal)
    if ($null -eq $Journal) { $Journal = Read-JuicerJournal }
    $name = ConvertTo-JuicerExeName $Exe
    $dates = @(foreach ($e in $Journal) {
            $id = ([string]$e.Id).ToLowerInvariant()
            $mine = $id -eq "fps:$name" -or $id -eq "juego:prioridad:$name" -or ($id -like 'juego:gpu:*' -and (ConvertTo-JuicerExeName $id.Substring(10)) -eq $name)
            if ($mine -and $e.AppliedAt) { try { [datetime]$e.AppliedAt } catch { Write-Verbose "Fecha ilegible: $($e.AppliedAt)" } }
        })
    if ($dates.Count -eq 0) { return $null }
    ($dates | Sort-Object | Select-Object -First 1)
}

# The .exe names of every game Win Juicer has changed something on.
function Get-JuicerOptimizedGames {
    param([System.Collections.IList]$Journal)
    if ($null -eq $Journal) { $Journal = Read-JuicerJournal }
    @(foreach ($e in $Journal) {
            $id = ([string]$e.Id).ToLowerInvariant()
            if ($id -like 'fps:*') { $id.Substring(4) }
            elseif ($id -like 'juego:prioridad:*') { $id.Substring(16) }
            elseif ($id -like 'juego:gpu:*') { ConvertTo-JuicerExeName $id.Substring(10) }
        }) | Select-Object -Unique
}

# Of a list of incidents (@{ Exe; Kind; Time }), the ones of this game in a
# window of time, oldest first.
function Select-JuicerGameIncidents {
    param([object[]]$Incidents, [Parameter(Mandatory)][string]$Exe, [datetime]$From, [datetime]$To = [datetime]::MaxValue)
    $name = ConvertTo-JuicerExeName $Exe
    @($Incidents | Where-Object { $_ -and ([string]$_.Exe).ToLowerInvariant() -eq $name -and [datetime]$_.Time -ge $From -and [datetime]$_.Time -lt $To } | Sort-Object { [datetime]$_.Time })
}

# What to do about a game from its failures: After, all since Win Juicer
# touched it; Early, those in its first two weeks; Before, in the same length
# of time before (one to 30 days). Proteger: it fails right after being
# optimized and never did before, which is what a change that does not suit
# a game looks like. Avisar: anything else that failed: it failed before too,
# or only after weeks of working fine.
function Get-JuicerSafetyVerdict {
    param([int]$After, [int]$Before, [int]$Early = -1)
    if ($Early -lt 0) { $Early = $After }
    if ($After -le 0) { return '' }
    if ($Early -gt 0 -and $Before -eq 0) { return 'Proteger' }
    'Avisar'
}

function Get-JuicerGameSafe {
    param([string]$Exe)
    $g = (Read-JuicerPacer).Games[(ConvertTo-JuicerExeName $Exe)]
    if ($g -is [hashtable] -and $g.Safe -is [hashtable]) { $g.Safe } else { $null }
}

# The user wants it optimized again: the note goes, prudent mode stays (the
# game page can turn it off).
function Clear-JuicerGameSafe {
    param([Parameter(Mandatory)][string]$Exe)
    $exe = ConvertTo-JuicerExeName $Exe
    $state = Read-JuicerPacer
    Set-JuicerPacerGameField $state $exe 'Safe' $null
    Save-JuicerPacer $state
}

# Everything Win Juicer set on one game, taken away: the frame pacer (when it
# closes, if it is open), the graphics card choice and the priority.
function Remove-JuicerGameSetup {
    param([Parameter(Mandatory)][string]$Exe)
    $name = ConvertTo-JuicerExeName $Exe
    $out = @()
    $r = Remove-JuicerFpsLimit $name
    if ($r) { $out += $r }
    # Assigned first: Read-JuicerJournal hands the list over whole.
    $journal = Read-JuicerJournal
    foreach ($e in @($journal)) {
        $id = ([string]$e.Id).ToLowerInvariant()
        if ($id -eq "juego:prioridad:$name" -or ($id -like 'juego:gpu:*' -and (ConvertTo-JuicerExeName $id.Substring(10)) -eq $name)) { $out += Undo-JuicerTweak ([string]$e.Id) }
    }
    $out
}

# Looks at every optimized game. Games names the ones known (@{ ExeName;
# Name }) for the notes. Returns @{ Protected; Warned; Unread }: the games
# whose changes were taken away and the ones only pointed out, each
# @{ Exe; Name; Kind; Count; Before; Time; Module }; Unread when the log
# could not be read at all.
function Update-JuicerGameSafety {
    param([object[]]$Games = @())
    $res = @{ Protected = @(); Warned = @(); Unread = $false }
    $journal = Read-JuicerJournal
    $exes = @(Get-JuicerOptimizedGames $journal)
    if ($exes.Count -eq 0) { return $res }
    $since = @{}
    foreach ($exe in $exes) { $d = Get-JuicerGameSince $exe $journal; if ($d) { $since[$exe] = $d } }
    if ($since.Count -eq 0) { return $res }
    $oldest = ($since.Values | Sort-Object | Select-Object -First 1)
    $b = Get-JuicerBackend
    $all = $null
    try { if ($b.AppIncidents) { $all = & $b.AppIncidents ($oldest.AddDays(-30)) } } catch { Write-JuicerLog "No se pudo leer el registro de aplicaciones: $_" }
    if ($null -eq $all) { $res.Unread = $true; return $res }
    $names = @{}
    foreach ($g in $Games) { if ($g.ExeName) { $names[([string]$g.ExeName).ToLowerInvariant()] = [string]$g.Name } }
    foreach ($exe in $since.Keys) {
        $from = $since[$exe]
        $after = @(Select-JuicerGameIncidents $all $exe $from)
        if ($after.Count -eq 0) { continue }
        $window = [Math]::Min(30, [Math]::Max(1, ((Get-Date) - $from).TotalDays))
        $before = @(Select-JuicerGameIncidents $all $exe $from.AddDays(-$window) $from)
        $early = @($after | Where-Object { [datetime]$_.Time -lt $from.AddDays(14) })
        $last = $after[-1]
        $info = @{ Exe = $exe; Name = $(if ($names[$exe]) { $names[$exe] } else { $exe }); Kind = [string]$last.Kind; Count = $after.Count; Before = $before.Count; Time = [string]$last.Time; Module = [string]$last.Module }
        switch (Get-JuicerSafetyVerdict $after.Count $before.Count $early.Count) {
            'Proteger' {
                if (Get-JuicerGameSafe $exe) { continue }
                [void](Remove-JuicerGameSetup $exe)
                $state = Read-JuicerPacer
                Set-JuicerPacerGameField $state $exe 'Safe' @{ Date = (Get-Date).ToString('s'); Kind = $info.Kind; Time = $info.Time; Count = $info.Count; Module = $info.Module }
                Set-JuicerPacerGameField $state $exe 'Minimal' $true
                Save-JuicerPacer $state
                Write-JuicerLog "Protegido ${exe}: $($info.Count) incidentes ($($info.Kind)) desde que se optimizó, ninguno antes"
                $res.Protected += $info
            }
            'Avisar' { $res.Warned += $info }
        }
    }
    $res
}

# The note for a protected game, in plain words.
function Format-JuicerSafeNote {
    param([Parameter(Mandatory)][hashtable]$Safe, [string]$Name)
    $what = if ($Safe.Kind -eq 'Cuelgue') { 'se quedó colgado y Windows lo cerró' } else { 'se cerró con un error' }
    $when = ''
    try { $when = ' (' + ([datetime]$Safe.Time).ToString('g') + ')' } catch { Write-Verbose "Fecha ilegible: $($Safe.Time)" }
    $mod = if ($Safe.Module -and $Safe.Module -notmatch '(?i)^(unknown|desconocido)$') { " El fallo fue en $($Safe.Module)." } else { '' }
    "$Name $what$when después de optimizarlo, y antes no le pasaba. Win Juicer le ha quitado sus cambios por si eran la causa, y si lo vuelves a optimizar será en modo prudente: sólo el límite de FPS.$mod Si sigue fallando sin ellos, la causa es otra: drivers, un overclock o undervolt inestable, o el propio juego (verifica sus archivos en su tienda)."
}

# Once per recipe change, what earlier versions set and the current recipe
# would not: the driver's «prefer maximum performance», anything that went
# over a value NVIDIA set for the game itself, and high CPU priority (now
# above normal). Open games wait for the next time.
$script:GameRecipe = 2

function Repair-JuicerGameSetups {
    $state = Read-JuicerPacer
    if ([int]$state.Recipe -ge $script:GameRecipe) { return @() }
    $out = @()
    $later = $false
    $b = Get-JuicerBackend
    $journal = Read-JuicerJournal
    foreach ($e in @($journal)) {
        $id = [string]$e.Id
        try {
            if ($id -like 'juego:prioridad:*') {
                $r = Invoke-JuicerTweak (New-JuicerPriorityTweak $id.Substring(16))
                if ($r.Outcome -eq 'Aplicado') { $out += $r }
            } elseif ($id -like 'fps:*') {
                $exe = $id.Substring(4)
                # Without NVIDIA's driver there is nothing of it left to put back.
                if ($null -eq (& $b.NvRead $exe ([uint32]0x1057EB71))) { continue }
                if (Test-JuicerGameRunning $exe) { $later = $true; continue }
                foreach ($c in @($e.Actions | Where-Object { $_.Type -eq 'NvSetting' })) {
                    $drop = [uint32]$c.SettingId -eq [uint32]0x1057EB71
                    if (-not $drop) {
                        $info = & $b.NvRead $exe $c.SettingId
                        $drop = $info -and $null -ne $info.Predefined
                    }
                    if ($drop -and (Undo-JuicerCapture $id $c.Id)) {
                        $out += New-JuicerResult @{ Id = $id; Title = "Frame pacer de $exe"; Reboot = 'No' } 'Deshecho' $(if ([uint32]$c.SettingId -eq [uint32]0x1057EB71) { 'Ya sin «preferir rendimiento máximo» en el driver.' } else { 'Vuelve el valor que NVIDIA pone para este juego.' })
                    }
                }
            }
        } catch {
            $later = $true
            Write-JuicerLog "No se pudo poner al día ${id}: $_"
        }
    }
    if (-not $later) {
        $state = Read-JuicerPacer
        $state.Recipe = $script:GameRecipe
        Save-JuicerPacer $state
    }
    $out
}

# Anti-cheats a game ships in its own folder, or that its launcher installs
# for it. Only to say so where it matters: RivaTuner hooks into the game to
# pace it, and an anti-cheat treats a hook as a cheat's injection: some close
# the game or kick the player, a few ban. So a game with one is paced by the
# NVIDIA driver (nothing is injected) or by its own limit, never by RivaTuner
# (see Test-JuicerRtssBlocked). Only what is reliable is marked; each table
# says how sure the marker is.

# Folder names (one level under the game's) that only an anti-cheat ships.
# Reliable: they are the vendor's own install folders.
$script:AntiCheatMarks = [ordered]@{
    'EasyAntiCheat' = 'Easy Anti-Cheat'; 'EasyAntiCheat_EOS' = 'Easy Anti-Cheat'; 'BattlEye' = 'BattlEye'
    'EAAntiCheat' = 'EA Anti-Cheat (Javelin)'; 'GameGuard' = 'nProtect GameGuard'; 'XIGNCODE' = 'XIGNCODE3'
    'AntiCheatExpert' = 'Anti-Cheat Expert (Tencent ACE)'
}

# File names (the game's folder and one level under it), wildcards allowed.
# EAAntiCheat.GameServiceLauncher.exe is EA's Javelin: reliable. mhyprot2.sys is
# HoYoverse's driver, NeacSafe64.sys NetEase's, ACE-BASE.sys Tencent's ACE: all
# ship in the game's folder, but I know them from memory of installs, not a
# spec. atvi-randgrid_sy.sys is Call of Duty's Ricochet driver (same caveat).
# faceit* is a guess: FACEIT AC normally lives in Program Files, so this only
# catches a copy dropped next to the game; the service check below is the one
# that counts for it. RobloxPlayerBeta.exe is the client that embeds Hyperion
# (Byfron): reliable.
$script:AntiCheatFiles = [ordered]@{
    'EAAntiCheat*.exe' = 'EA Anti-Cheat (Javelin)'
    'mhyprot*' = 'mhyprot (HoYoverse)'
    'NeacSafe*' = 'NetEase Anti-Cheat'
    'ACE-*' = 'Anti-Cheat Expert (Tencent ACE)'
    'atvi-randgrid*' = 'Ricochet (Call of Duty)'
    'RobloxPlayerBeta.exe' = 'Hyperion (Roblox)'
    'faceit*' = 'FACEIT Anti-Cheat'
}

# Games whose anti-cheat is not in their folder, by .exe name (regex). Ricochet
# is built into Call of Duty's own executables (the names change with each
# release: uncertain, hence the driver file above as well). Vanguard comes with
# Riot's games (VALORANT, and League of Legends since 2024).
$script:AntiCheatExes = [ordered]@{
    '^(cod\d*(-cod)?|modernwarfare\d*|blackopscoldwar|blackops\d|warzone)\.exe$' = 'Ricochet (Call of Duty)'
    '^robloxplayerbeta\.exe$' = 'Hyperion (Roblox)'
}
$script:RiotExes = '^(valorant(-win64-shipping)?|league of legends)\.exe$'
# FACEIT's client matters for the games it covers (CS2/CS:GO); the service is
# «FACEIT» (reliable), but it exists for everything on the PC, so it only counts
# with those executables.
$script:FaceitExes = '^(cs2|csgo)\.exe$'

# The anti-cheat of a game, or ''. Dir is the game's folder; ExeName (optional)
# adds what its name says, and the services Windows has (Vanguard's «vgc»,
# FACEIT's) are looked at only for the games they belong to.
function Get-JuicerGameAntiCheat {
    param([string]$Dir, [string]$ExeName = '')
    $exe = if ($ExeName) { (ConvertTo-JuicerExeName $ExeName) } else { '' }
    if ($Dir -and (Test-Path -LiteralPath $Dir -PathType Container)) {
        $names = @(Get-ChildItem -LiteralPath $Dir -Directory -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object { $_.Name })
        foreach ($k in $script:AntiCheatMarks.Keys) { if ($names -contains $k) { return $script:AntiCheatMarks[$k] } }
        $files = @(Get-ChildItem -LiteralPath $Dir -File -Depth 1 -ErrorAction SilentlyContinue | Select-Object -First 5000 | ForEach-Object { $_.Name })
        foreach ($k in $script:AntiCheatFiles.Keys) { if (@($files | Where-Object { $_ -like $k }).Count -gt 0) { return $script:AntiCheatFiles[$k] } }
    }
    if ($exe) {
        foreach ($k in $script:AntiCheatExes.Keys) { if ($exe -match $k) { return $script:AntiCheatExes[$k] } }
        $b = Get-JuicerBackend
        # Vanguard: its service (vgc) is there once Riot's client installed it, and only Riot's games use it.
        $riot = $exe -match $script:RiotExes -or ($Dir -and $Dir -match '(?i)[\\/]Riot Games[\\/]')
        if ($riot -and ((& $b.SvcRead 'vgc') -or (& $b.SvcRead 'vgk'))) { return 'Riot Vanguard' }
        if ($exe -match $script:FaceitExes -and (& $b.SvcRead 'FACEIT')) { return 'FACEIT Anti-Cheat' }
    }
    ''
}

# Whether this game must not be paced by RivaTuner: an anti-cheat that treats
# its hook as an injection. The NVIDIA driver's limiter is never in question.
function Test-JuicerRtssBlocked {
    param([hashtable]$Game)
    if (-not $Game) { return '' }
    $dir = if ($Game.Dir) { [string]$Game.Dir } else { '' }
    $exe = if ($Game.ExeName) { [string]$Game.ExeName } elseif ($Game.Exe) { [string]$Game.Exe } else { '' }
    Get-JuicerGameAntiCheat $dir $exe
}

# What to tell the user about it (null when there is none, or when the engine is
# not RivaTuner and nothing is injected).
function Get-JuicerAntiCheatNote {
    param([string]$AntiCheat, [string]$Engine)
    if (-not $AntiCheat) { return $null }
    if ($Engine -eq 'rtss') { return "Este juego usa $AntiCheat. RivaTuner se inyecta en el juego para marcar el ritmo y un antitrampas puede tomarlo por un truco: el juego se cierra, te expulsa o, en el peor caso, te sanciona. Win Juicer no le pone el frame pacer con RivaTuner; usa el límite de FPS del propio juego (o, con una gráfica NVIDIA, el motor del driver)." }
    "Este juego usa $AntiCheat. El frame pacer va por el driver de NVIDIA, que no se inyecta en el juego: es la opción segura con un antitrampas."
}
