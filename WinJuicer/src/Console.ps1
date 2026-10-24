# The console front end: menus, confirmations and result screens. Everything it
# does goes through the engine; nothing here changes the machine by itself.

# Interactive: prompts are allowed. Screen: the full-screen menu, which clears
# between screens and waits for a key; off when run with parameters.
$script:Interactive = $true
$script:Screen = $true

$script:StateMarks = @{
    Aplicado  = @('[x]', 'Green')
    Parcial   = @('[~]', 'Yellow')
    Pendiente = @('[ ]', 'Gray')
    NoAplica  = @('[-]', 'DarkGray')
    Error     = @('[!]', 'Red')
}
$script:SeverityColors = @{ Alto = 'Red'; Medio = 'Yellow'; Bajo = 'Cyan'; Info = 'Gray'; Ok = 'Green' }
$script:RebootLabels = @{
    Reinicio   = 'Reinicia el equipo para completar'
    Sesion     = 'Cierra sesión y vuelve a entrar para completar'
    Explorador = 'Hay que reiniciar el Explorador para'
}

# --- Primitives --------------------------------------------------------------

function Get-JuicerConsoleWidth {
    try { return [Math]::Max(60, [Math]::Min(110, $Host.UI.RawUI.WindowSize.Width - 2)) } catch { return 100 }
}

function Write-JuicerWrapped {
    param([string]$Text, [int]$Indent = 4, [string]$Color = 'Gray')
    $max = [Math]::Max(30, (Get-JuicerConsoleWidth) - $Indent)
    $pad = ' ' * $Indent
    foreach ($paragraph in ($Text -split "`n")) {
        $line = ''
        foreach ($w in ($paragraph -split '\s+' | Where-Object { $_ })) {
            if ($line -and ($line.Length + 1 + $w.Length) -gt $max) {
                Write-Host ($pad + $line) -ForegroundColor $Color
                $line = $w
            } elseif ($line) {
                $line = "$line $w"
            } else {
                $line = $w
            }
        }
        if ($line) { Write-Host ($pad + $line) -ForegroundColor $Color }
    }
}

function Write-JuicerHeader {
    param([string]$Section = '')
    if ($script:Screen) { try { [Console]::Clear() } catch { Write-Verbose 'Sin consola' } }
    Write-Host ''
    Write-Host '  WIN JUICER' -ForegroundColor Yellow -NoNewline
    Write-Host '  exprime Windows 11, sin humo' -ForegroundColor DarkGray
    Write-Host ('  ' + ('─' * 46)) -ForegroundColor DarkGray
    if ($Section) {
        Write-Host "  $Section" -ForegroundColor White
        Write-Host ''
    }
}

function Read-JuicerChoice {
    param([string]$Prompt = 'Elige')
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan -NoNewline
    $answer = Read-Host ' '
    if ($null -eq $answer) { return '' }
    $answer.Trim()
}

function Confirm-JuicerAction {
    param([string]$Prompt)
    if (-not $script:Interactive) { return $true }
    $a = Read-JuicerChoice "$Prompt (S/N)"
    $a -match '^(s|si|sí|y|yes)$'
}

# Level 3 asks for the word, not a keystroke: it should take a decision.
function Confirm-JuicerRisk {
    param([hashtable]$Tweak)
    Write-Host ''
    Write-Host "  EXTREMO: $($Tweak.Title)" -ForegroundColor Red
    Write-JuicerWrapped "Ganas: $($Tweak.Gain)" 4 'Gray'
    Write-JuicerWrapped "Pierdes: $($Tweak.Cost)" 4 'Yellow'
    $a = Read-JuicerChoice 'Escribe SI para aplicarlo, o Intro para saltarlo'
    $a -ceq 'SI' -or $a -ceq 'SÍ'
}

function Wait-JuicerKey {
    if (-not $script:Screen) { return }
    Write-Host ''
    Write-Host '  Pulsa Intro para volver' -ForegroundColor DarkGray -NoNewline
    [void](Read-Host ' ')
}

function Write-JuicerMenu {
    param([object[]]$Items)
    foreach ($i in $Items) {
        Write-Host ('  {0,2}  ' -f $i[0]) -ForegroundColor Yellow -NoNewline
        Write-Host ('{0,-24} ' -f $i[1]) -ForegroundColor White -NoNewline
        Write-Host $i[2] -ForegroundColor DarkGray
    }
}

function Get-JuicerNumbers {
    param([string]$Text, [int]$Max)
    $out = @()
    foreach ($part in ($Text -split '[,\s]+' | Where-Object { $_ })) {
        if ($part -match '^(\d+)-(\d+)$') { $out += ([int]$Matches[1])..([int]$Matches[2]) }
        elseif ($part -match '^\d+$') { $out += [int]$part }
    }
    @($out | Where-Object { $_ -ge 1 -and $_ -le $Max } | Select-Object -Unique)
}

# --- Tweaks and results ----------------------------------------------------

function Write-JuicerTweakLine {
    param([int]$Number, [hashtable]$Tweak, [hashtable]$State)
    $mark = $script:StateMarks[$State.State]
    Write-Host ('  {0} ' -f $mark[0]) -ForegroundColor $mark[1] -NoNewline
    Write-Host ('{0,3}  ' -f $Number) -ForegroundColor Yellow -NoNewline
    $title = $Tweak.Title
    $w = (Get-JuicerConsoleWidth) - 36
    if ($title.Length -gt $w) { $title = $title.Substring(0, $w - 1) + '…' }
    Write-Host ("{0,-$w}" -f $title) -NoNewline
    $levelColor = @{ 1 = 'Green'; 2 = 'Yellow'; 3 = 'Red' }[[int]$Tweak.Level]
    Write-Host (' {0,-12} ' -f $script:LevelNames[[int]$Tweak.Level]) -ForegroundColor $levelColor -NoNewline
    Write-Host ('impacto {0}' -f $Tweak.Impact.ToLowerInvariant()) -ForegroundColor DarkGray
}

function Write-JuicerLegend {
    Write-Host ''
    Write-Host '  [x] aplicado  [~] a medias  [ ] sin aplicar  [-] no aplica aquí  [!] no se pudo leer' -ForegroundColor DarkGray
}

function Show-JuicerTweakDetail {
    param([hashtable]$Tweak, [hashtable]$State)
    Write-Host "  $($Tweak.Title)" -ForegroundColor White
    $rb = @{ No = 'efecto inmediato'; Explorador = 'reinicia el Explorador'; Sesion = 'al volver a iniciar sesión'; Reinicio = 'tras reiniciar' }[$Tweak.Reboot]
    Write-Host ('  {0} · impacto {1} · {2}' -f $script:LevelNames[[int]$Tweak.Level], $Tweak.Impact.ToLowerInvariant(), $rb) -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  Qué hace' -ForegroundColor Cyan; Write-JuicerWrapped $Tweak.What
    Write-Host '  Qué ganas' -ForegroundColor Cyan; Write-JuicerWrapped $Tweak.Gain
    Write-Host '  Qué cuesta' -ForegroundColor Cyan; Write-JuicerWrapped $Tweak.Cost
    Write-Host ''
    $label = @{ Aplicado = 'Aplicado'; Parcial = 'Aplicado a medias'; Pendiente = 'Sin aplicar'; NoAplica = 'No aplica'; Error = 'Error al leer el estado' }[$State.State]
    Write-Host "  Estado: $label" -ForegroundColor $script:StateMarks[$State.State][1]
    if ($State.Reason) { Write-JuicerWrapped $State.Reason 4 'DarkGray' }
    if ($State.Pending.Count -gt 0 -and $State.State -ne 'NoAplica') {
        Write-Host '  Cambiaría:' -ForegroundColor DarkGray
        foreach ($a in $State.Pending) { Write-JuicerWrapped ('· ' + (Format-JuicerAction $a)) 6 'DarkGray' }
    }
    if ($State.Undoable) { Write-Host '  Win Juicer guarda cómo estaba antes: se puede deshacer.' -ForegroundColor DarkGray }
}

function Show-JuicerResults {
    param([object[]]$Results)
    Write-Host ''
    $marks = @{
        Aplicado = @('[ok]', 'Green'); Deshecho = @('[ok]', 'Green'); YaEstaba = @('[= ]', 'DarkGray'); Simulado = @('[..]', 'Cyan')
        NoAplica = @('[--]', 'DarkGray'); NadaQueDeshacer = @('[--]', 'DarkGray'); Error = @('[!!]', 'Red'); NoSeMantuvo = @('[~ ]', 'Yellow')
    }
    $notes = @{ YaEstaba = 'ya estaba así'; NoAplica = 'no aplica'; NadaQueDeshacer = 'nada que deshacer' }
    foreach ($r in $Results) {
        $m = $marks[$r.Outcome]
        Write-Host "  $($m[0]) " -ForegroundColor $m[1] -NoNewline
        Write-Host $r.Title -NoNewline
        if ($notes[$r.Outcome]) { Write-Host " — $($notes[$r.Outcome])" -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
        if ($r.Message) { Write-JuicerWrapped $r.Message 7 $(if ($r.Outcome -eq 'Error') { 'Red' } else { 'DarkGray' }) }
        if ($r.Outcome -eq 'Simulado') { foreach ($c in $r.Changes) { Write-JuicerWrapped "· $c" 7 'DarkGray' } }
    }
    $done = @($Results | Where-Object { $_.Outcome -in 'Aplicado', 'Deshecho', 'NoSeMantuvo' })
    foreach ($kind in 'Reinicio', 'Sesion', 'Explorador') {
        $need = @($done | Where-Object { $_.Reboot -eq $kind })
        if ($need.Count -gt 0) {
            Write-Host ''
            Write-JuicerWrapped ('{0}: {1}.' -f $script:RebootLabels[$kind], (($need | ForEach-Object { $_.Title }) -join ', ')) 2 'Yellow'
        }
    }
    if ($script:Interactive -and @($done | Where-Object { $_.Reboot -eq 'Explorador' }).Count -gt 0) {
        if (Confirm-JuicerAction '¿Reinicio el Explorador ahora? Se cerrarán las ventanas de carpetas') { Restart-JuicerExplorer }
    }
}

# Windows restarts the shell by itself, as the signed-in user; starting it from
# here would run it elevated.
function Restart-JuicerExplorer {
    Get-Process -Name explorer -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
    if (-not (Get-Process -Name explorer -ErrorAction SilentlyContinue)) {
        Write-JuicerWrapped 'El Explorador no ha vuelto solo: pulsa Ctrl+Mayús+Esc, «Ejecutar nueva tarea» y escribe explorer.' 2 'Yellow'
    }
}

# --- Applying many -----------------------------------------------------------

function Invoke-JuicerTweakSet {
    param([object[]]$Tweaks, [switch]$Simulate, [switch]$AcceptRisk, [switch]$NoRestorePoint)
    $results = @()
    $toApply = @()
    foreach ($t in $Tweaks) {
        if ($t.Level -ge 3 -and -not $Simulate -and -not $AcceptRisk) {
            if (-not $script:Interactive -or -not (Confirm-JuicerRisk $t)) {
                $results += New-JuicerResult $t 'NoAplica' 'Saltado: los ajustes Extremo se confirman uno a uno (o con -AceptoRiesgos).'
                continue
            }
        }
        $toApply += $t
    }
    if (-not $Simulate -and -not $NoRestorePoint -and $toApply.Count -gt 0) {
        Write-Host ''
        Write-Host '  Creando punto de restauración…' -ForegroundColor DarkGray
        $rp = New-JuicerRestorePoint
        Write-JuicerWrapped $rp.Message 2 $(if ($rp.Ok) { 'DarkGray' } else { 'Yellow' })
    }
    $i = 0
    foreach ($t in $toApply) {
        $i++
        Write-Progress -Activity 'Win Juicer' -Status $t.Title -PercentComplete (100 * $i / [Math]::Max(1, $toApply.Count))
        $results += Invoke-JuicerTweak $t -Simulate:$Simulate
    }
    Write-Progress -Activity 'Win Juicer' -Completed
    $results
}

# --- Screens -----------------------------------------------------------------

function Show-JuicerAudit {
    Write-JuicerHeader 'Diagnóstico — no cambia nada'
    if ($script:Screen) { Write-Host '  Revisando el equipo…' -ForegroundColor DarkGray }
    $findings = @(Get-JuicerAudit)
    if ($script:Screen) { Write-JuicerHeader 'Diagnóstico — no cambia nada' }
    $area = ''
    foreach ($f in $findings) {
        if ($f.Area -ne $area) { $area = $f.Area; Write-Host ''; Write-Host "  $area" -ForegroundColor White }
        $tag = @{ Alto = '!!'; Medio = ' !'; Bajo = ' ·'; Info = '  '; Ok = 'ok' }[$f.Severity]
        Write-Host "  $tag " -ForegroundColor $script:SeverityColors[$f.Severity] -NoNewline
        Write-Host $f.Title -ForegroundColor $(if ($f.Severity -in 'Info', 'Ok') { 'Gray' } else { 'White' })
        if ($f.Detail -and $f.Severity -ne 'Ok') { Write-JuicerWrapped $f.Detail 5 'DarkGray' }
    }
    $top = @($findings | Where-Object { $_.Severity -in 'Alto', 'Medio' } | Sort-Object { $script:SeverityOrder[$_.Severity] })
    Write-Host ''
    Write-Host ('  ' + ('─' * 46)) -ForegroundColor DarkGray
    if ($top.Count -eq 0) {
        Write-Host '  No hay nada grave. Los perfiles exprimen lo que queda.' -ForegroundColor Green
    } else {
        Write-Host "  Lo que más rinde arreglar, por orden:" -ForegroundColor White
        $n = 0
        foreach ($f in $top | Select-Object -First 6) {
            $n++
            Write-Host ('  {0}. ' -f $n) -ForegroundColor $script:SeverityColors[$f.Severity] -NoNewline
            Write-Host $f.Title
        }
        if (@($top | Where-Object { $_.Area -eq 'Reparación' }).Count -gt 0) {
            Write-JuicerWrapped 'Las reparaciones están en el perfil Seguro.' 2 'DarkGray'
        }
    }
    Wait-JuicerKey
}

function Show-JuicerProfiles {
    $descriptions = @{
        1 = 'Reparaciones y ajustes que no cuestan nada a nadie.'
        2 = 'Más: energía al máximo, sin animaciones, sin Game Bar, sin Widgets. Cuesta batería, estética o funciones que no todos usan.'
        3 = 'Todo, incluida la seguridad basada en virtualización. Cada ajuste de este nivel se confirma por separado.'
    }
    while ($true) {
        Write-JuicerHeader 'Perfiles'
        $journal = Read-JuicerJournal
        foreach ($lvl in 1, 2, 3) {
            $set = Get-JuicerProfile $lvl
            $pending = @($set | Where-Object { (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' }).Count
            Write-Host ('  {0}  ' -f $lvl) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-12}' -f $script:LevelNames[$lvl]) -ForegroundColor White -NoNewline
            Write-Host ('{0} ajustes, {1} por aplicar' -f $set.Count, $pending) -ForegroundColor DarkGray
            Write-JuicerWrapped $descriptions[$lvl] 5 'DarkGray'
        }
        Write-Host ''
        Write-Host '  Cada nivel incluye los anteriores. Todo se puede deshacer.' -ForegroundColor DarkGray
        $c = Read-JuicerChoice 'Perfil (1-3), S para simular uno, Intro para volver'
        if ($c -eq '') { return }
        $simulate = $false
        if ($c -match '^[sS]\s*(\d)?$') {
            $simulate = $true
            $c = if ($Matches[1]) { $Matches[1] } else { Read-JuicerChoice 'Qué perfil simular (1-3)' }
        }
        if ($c -notmatch '^[123]$') { continue }
        $lvl = [int]$c
        $journal = Read-JuicerJournal
        $todo = @(Get-JuicerProfile $lvl | Where-Object { (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' })
        Write-JuicerHeader "Perfil $($script:LevelNames[$lvl])"
        if ($todo.Count -eq 0) {
            Write-Host '  Ya está todo aplicado.' -ForegroundColor Green
            Wait-JuicerKey
            continue
        }
        Write-Host '  Se aplicará:' -ForegroundColor White
        foreach ($t in $todo) {
            $color = @{ 1 = 'Green'; 2 = 'Yellow'; 3 = 'Red' }[[int]$t.Level]
            Write-Host '  · ' -ForegroundColor $color -NoNewline
            Write-Host $t.Title -NoNewline
            Write-Host "  (impacto $($t.Impact.ToLowerInvariant()))" -ForegroundColor DarkGray
            if ($t.Level -ge 2) { Write-JuicerWrapped "Cuesta: $($t.Cost)" 6 'DarkGray' }
        }
        if ($simulate) {
            Show-JuicerResults (Invoke-JuicerTweakSet $todo -Simulate)
            Wait-JuicerKey
            continue
        }
        if (-not (Confirm-JuicerAction "¿Aplicar $($todo.Count) ajustes?")) { continue }
        Show-JuicerResults (Invoke-JuicerTweakSet $todo)
        Wait-JuicerKey
    }
}

function Show-JuicerTweakList {
    while ($true) {
        Write-JuicerHeader 'Ajustes uno a uno'
        $journal = Read-JuicerJournal
        $catalog = @(Get-JuicerCatalog)
        $states = @{}
        $n = 0
        $numbered = @()
        foreach ($cat in $script:CategoryOrder) {
            $inCat = @($catalog | Where-Object { $_.Category -eq $cat })
            if ($inCat.Count -eq 0) { continue }
            Write-Host "  $cat" -ForegroundColor White
            foreach ($t in $inCat) {
                $n++
                $numbered += $t
                $states[$t.Id] = Get-JuicerTweakState $t $journal
                Write-JuicerTweakLine $n $t $states[$t.Id]
            }
        }
        Write-JuicerLegend
        $c = Read-JuicerChoice 'Número para ver un ajuste, Intro para volver'
        if ($c -eq '') { return }
        $pick = Get-JuicerNumbers $c $numbered.Count
        if ($pick.Count -ne 1) { continue }
        $t = $numbered[$pick[0] - 1]
        while ($true) {
            Write-JuicerHeader $t.Category
            $s = Get-JuicerTweakState $t
            Show-JuicerTweakDetail $t $s
            $opts = @()
            if ($s.State -in 'Pendiente', 'Parcial') { $opts += 'A aplicar' }
            if ($s.Undoable) { $opts += 'D deshacer' }
            $c2 = Read-JuicerChoice (($opts + 'Intro volver') -join ' · ')
            if ($c2 -match '^[aA]$' -and $s.State -in 'Pendiente', 'Parcial') {
                if ($t.Level -ge 3 -and -not (Confirm-JuicerRisk $t)) { continue }
                Show-JuicerResults @(Invoke-JuicerTweak $t)
                Wait-JuicerKey
            } elseif ($c2 -match '^[dD]$' -and $s.Undoable) {
                Show-JuicerResults @(Undo-JuicerTweak $t.Id)
                Wait-JuicerKey
            } else {
                break
            }
        }
    }
}

function Show-JuicerStartup {
    while ($true) {
        Write-JuicerHeader 'Programas de inicio'
        Write-Host '  Leyendo…' -ForegroundColor DarkGray
        $items = @(Get-JuicerStartupItems | Sort-Object { -not $_.Enabled }, { $_.Name })
        Write-JuicerHeader 'Programas de inicio'
        if ($items.Count -eq 0) { Write-Host '  No hay nada configurado para arrancar al iniciar sesión.' -ForegroundColor Green }
        $n = 0
        $w = (Get-JuicerConsoleWidth) - 40
        foreach ($i in $items) {
            $n++
            $mark = if ($i.Enabled) { @('[x]', 'Green') } else { @('[ ]', 'DarkGray') }
            Write-Host ('  {0} ' -f $mark[0]) -ForegroundColor $mark[1] -NoNewline
            Write-Host ('{0,3}  ' -f $n) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-28} ' -f $(if ($i.Name.Length -gt 28) { $i.Name.Substring(0, 27) + '…' } else { $i.Name })) -NoNewline
            Write-Host $i.Source -ForegroundColor DarkGray
            $cmd = $i.Command
            if ($cmd.Length -gt $w + 30) { $cmd = $cmd.Substring(0, $w + 29) + '…' }
            Write-Host "            $cmd" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-JuicerWrapped 'Desactivar no borra nada: es el mismo interruptor del Administrador de tareas. Las apps de la Tienda que arrancan solas se gestionan en Configuración > Aplicaciones > Inicio.' 2 'DarkGray'
        $c = Read-JuicerChoice 'Números para activar o desactivar (ej. 2,5,7), Intro para volver'
        if ($c -eq '') { return }
        $results = @()
        foreach ($k in (Get-JuicerNumbers $c $items.Count)) {
            $i = $items[$k - 1]
            $results += Set-JuicerStartupItem $i (-not $i.Enabled)
        }
        if ($results.Count -gt 0) { Show-JuicerResults $results; Wait-JuicerKey }
    }
}

function Show-JuicerGames {
    while ($true) {
        Write-JuicerHeader 'Juegos'
        Write-JuicerMenu @(
            @('1', 'Exclusiones de Defender', 'cargas más rápidas en tus bibliotecas (Extremo)'),
            @('2', 'Configurar un juego', 'GPU potente y prioridad alta para un .exe'),
            @('3', 'Juegos configurados', 'ver y deshacer')
        )
        $c = Read-JuicerChoice 'Elige, Intro para volver'
        switch ($c) {
            '1' { Show-JuicerDefenderLibraries }
            '2' { Show-JuicerConfigureGame }
            '3' { Show-JuicerConfiguredGames }
            '' { return }
        }
    }
}

function Show-JuicerDefenderLibraries {
    Write-JuicerHeader 'Exclusiones de Defender'
    $libs = @(Get-JuicerGameLibraries)
    if ($libs.Count -eq 0) {
        Write-JuicerWrapped 'No he encontrado bibliotecas de Steam, Epic, GOG ni Xbox. Puedes excluir otra carpeta escribiendo su ruta.' 2
    }
    $tweaks = @($libs | ForEach-Object { New-JuicerDefenderTweak $_.Path $_.Launcher })
    $journal = Read-JuicerJournal
    $n = 0
    foreach ($t in $tweaks) {
        $n++
        Write-JuicerTweakLine $n $t (Get-JuicerTweakState $t $journal)
    }
    Write-Host ''
    Write-JuicerWrapped ('Qué ganas: ' + (New-JuicerDefenderTweak 'x').Gain) 2
    Write-JuicerWrapped ('Qué cuesta: ' + (New-JuicerDefenderTweak 'x').Cost) 2 'Yellow'
    $c = Read-JuicerChoice 'Números a excluir, o una ruta; Intro para volver'
    if ($c -eq '') { return }
    $chosen = @()
    if ($c -match '^[\d,\s-]+$') {
        foreach ($k in (Get-JuicerNumbers $c $tweaks.Count)) { $chosen += $tweaks[$k - 1] }
    } else {
        $path = $c.Trim('"', ' ')
        if (-not (Test-Path -LiteralPath $path -PathType Container)) { Write-Host '  Esa carpeta no existe.' -ForegroundColor Red; Wait-JuicerKey; return }
        $chosen += New-JuicerDefenderTweak $path
    }
    if ($chosen.Count -eq 0) { return }
    Write-Host ''
    Write-Host '  Esto desactiva el análisis al abrir archivos en:' -ForegroundColor Red
    foreach ($t in $chosen) { Write-Host "  · $($t.Actions[0].Path)" }
    $a = Read-JuicerChoice 'Escribe SI para continuar'
    if ($a -cne 'SI' -and $a -cne 'SÍ') { return }
    Show-JuicerResults @($chosen | ForEach-Object { Invoke-JuicerTweak $_ })
    Wait-JuicerKey
}

function Show-JuicerConfigureGame {
    Write-JuicerHeader 'Configurar un juego'
    Write-JuicerWrapped 'Arrastra aquí el .exe del juego (el que se ejecuta de verdad, no el lanzador) y pulsa Intro.' 2
    $exe = (Read-JuicerChoice 'Ruta').Trim('"', ' ')
    if ($exe -eq '') { return }
    if (-not (Test-Path -LiteralPath $exe -PathType Leaf) -or $exe -notlike '*.exe') {
        Write-Host '  Eso no es un .exe que exista.' -ForegroundColor Red
        Wait-JuicerKey
        return
    }
    $exe = (Resolve-Path -LiteralPath $exe).ProviderPath
    $results = @()
    foreach ($t in @((New-JuicerGpuTweak $exe), (New-JuicerPriorityTweak $exe))) {
        Write-JuicerHeader 'Configurar un juego'
        if ($t.Id -like 'juego:gpu:*' -and (Get-JuicerGpuCount) -lt 2) {
            Write-JuicerWrapped 'Sólo hay una tarjeta gráfica: elegir GPU no cambia nada aquí, así que lo salto.' 2 'DarkGray'
            continue
        }
        Show-JuicerTweakDetail $t (Get-JuicerTweakState $t)
        if (Confirm-JuicerAction '¿Aplicar?') { $results += Invoke-JuicerTweak $t }
    }
    if ($results.Count -gt 0) { Show-JuicerResults $results }
    Wait-JuicerKey
}

function Show-JuicerConfiguredGames {
    Write-JuicerHeader 'Juegos configurados'
    $entries = @(Get-JuicerConfiguredGames)
    if ($entries.Count -eq 0) { Write-Host '  Ninguno todavía.' -ForegroundColor DarkGray; Wait-JuicerKey; return }
    $n = 0
    foreach ($e in $entries) { $n++; Write-Host ('  {0,3}  {1}' -f $n, $e.Title) }
    $c = Read-JuicerChoice 'Números a deshacer, Intro para volver'
    if ($c -eq '') { return }
    Show-JuicerResults @(Get-JuicerNumbers $c $entries.Count | ForEach-Object { Undo-JuicerTweak $entries[$_ - 1].Id })
    Wait-JuicerKey
}

function Show-JuicerMaintenance {
    while ($true) {
        Write-JuicerHeader 'Mantenimiento'
        Write-JuicerMenu @(
            @('1', 'Limpieza', 'temporales, informes de errores, descargas de Windows Update'),
            @('2', 'Optimizar unidades', 'TRIM en SSD, desfragmentar en disco duro'),
            @('3', 'Limpiar componentes', 'versiones antiguas de Windows (WinSxS); tarda'),
            @('4', 'Reparar Windows', 'DISM y SFC; tarda bastante')
        )
        Write-Host ''
        Write-JuicerWrapped 'Nada de esto se puede deshacer, por eso sólo borra lo que Windows regenera o ya no usa. La caché de shaders y Prefetch no se tocan: vaciarlas hace que la próxima partida tenga tirones.' 2 'DarkGray'
        $c = Read-JuicerChoice 'Elige, Intro para volver'
        switch ($c) {
            '1' {
                Write-JuicerHeader 'Limpieza'
                $total = [int64]0
                foreach ($r in (Invoke-JuicerCleanup)) {
                    $what = if ($r.Freed -lt 0) { 'vaciada' } else { Format-JuicerBytes $r.Freed }
                    if ($r.Freed -gt 0) { $total += $r.Freed }
                    Write-Host ('  {0,-40} {1}' -f $r.Name, $what)
                    if ($r.Skipped -gt 0) { Write-Host "      $($r.Skipped) archivos en uso o recientes, sin tocar" -ForegroundColor DarkGray }
                }
                Write-Host ''
                Write-Host "  Liberado: $(Format-JuicerBytes $total)" -ForegroundColor Green
                Wait-JuicerKey
            }
            '2' {
                Write-JuicerHeader 'Optimizar unidades'
                foreach ($r in (Invoke-JuicerDriveOptimize)) {
                    $color = if ($r.Ok) { 'Green' } else { 'Red' }
                    Write-Host ('  {0} {1,-12} {2}' -f $r.Drive, $r.Media, $(if ($r.Ok) { 'hecho' } else { $r.Message })) -ForegroundColor $color
                }
                Wait-JuicerKey
            }
            '3' { Write-JuicerHeader 'Limpiar componentes'; [void](Invoke-JuicerComponentCleanup); Wait-JuicerKey }
            '4' { Write-JuicerHeader 'Reparar Windows'; [void](Invoke-JuicerSystemRepair); Wait-JuicerKey }
            '' { return }
        }
    }
}

function Show-JuicerUndo {
    while ($true) {
        Write-JuicerHeader 'Deshacer'
        $journal = Read-JuicerJournal
        if ($journal.Count -eq 0) {
            Write-Host '  No hay cambios de Win Juicer que deshacer.' -ForegroundColor Green
            Wait-JuicerKey
            return
        }
        $n = 0
        foreach ($e in $journal) {
            $n++
            $when = ''
            try { $when = ([datetime]$e.AppliedAt).ToString('g') } catch { $when = $e.AppliedAt }
            Write-Host ('  {0,3}  ' -f $n) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-60} ' -f $e.Title) -NoNewline
            Write-Host $when -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-JuicerWrapped "Deshacer devuelve cada ajuste a como estaba antes de que Win Juicer lo tocara por primera vez. El diario está en $(Get-JuicerJournalPath)." 2 'DarkGray'
        $c = Read-JuicerChoice 'Números a deshacer, T para todo, Intro para volver'
        if ($c -eq '') { return }
        if ($c -match '^[tT]$') {
            if (Confirm-JuicerAction "¿Deshacer los $($journal.Count) cambios?") { Show-JuicerResults @(Undo-JuicerAll); Wait-JuicerKey }
            continue
        }
        $ids = @(Get-JuicerNumbers $c $journal.Count | ForEach-Object { $journal[$_ - 1].Id })
        if ($ids.Count -gt 0) { Show-JuicerResults @($ids | ForEach-Object { Undo-JuicerTweak $_ }); Wait-JuicerKey }
    }
}

function Show-JuicerMyths {
    Write-JuicerHeader 'Lo que Win Juicer no hace, y por qué'
    foreach ($m in (Get-JuicerMyths)) {
        Write-Host "  × $($m.Title)" -ForegroundColor Yellow
        Write-JuicerWrapped $m.Why 4 'Gray'
        Write-Host ''
    }
    Wait-JuicerKey
}

function Show-JuicerMainMenu {
    while ($true) {
        Write-JuicerHeader
        Write-JuicerMenu @(
            @('1', 'Diagnóstico', 'qué frena a este equipo (no cambia nada)'),
            @('2', 'Perfiles', 'Seguro · Rendimiento · Extremo'),
            @('3', 'Ajustes uno a uno', 'estado, ganancia y coste de cada uno'),
            @('4', 'Programas de inicio', 'lo que arranca solo con Windows'),
            @('5', 'Juegos', 'GPU, prioridad y exclusiones de Defender'),
            @('6', 'Mantenimiento', 'limpieza, TRIM y reparación de Windows'),
            @('7', 'Deshacer', 'todo, o cambio a cambio'),
            @('8', 'Lo que no hacemos', 'los «trucos» que circulan, y por qué no'),
            @('0', 'Salir', '')
        )
        $c = Read-JuicerChoice
        switch ($c) {
            '1' { Show-JuicerAudit }
            '2' { Show-JuicerProfiles }
            '3' { Show-JuicerTweakList }
            '4' { Show-JuicerStartup }
            '5' { Show-JuicerGames }
            '6' { Show-JuicerMaintenance }
            '7' { Show-JuicerUndo }
            '8' { Show-JuicerMyths }
            '0' { return }
        }
    }
}

# --- Non-interactive entry points --------------------------------------------

function Show-JuicerList {
    $journal = Read-JuicerJournal
    $n = 0
    foreach ($cat in $script:CategoryOrder) {
        $inCat = @(Get-JuicerCatalog | Where-Object { $_.Category -eq $cat })
        if ($inCat.Count -eq 0) { continue }
        Write-Host ''
        Write-Host "  $cat" -ForegroundColor White
        foreach ($t in $inCat) {
            $n++
            $s = Get-JuicerTweakState $t $journal
            $m = $script:StateMarks[$s.State]
            Write-Host ('  {0} ' -f $m[0]) -ForegroundColor $m[1] -NoNewline
            Write-Host ('{0,-22} ' -f $t.Id) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-12} ' -f $script:LevelNames[[int]$t.Level]) -ForegroundColor DarkGray -NoNewline
            Write-Host $t.Title
        }
    }
    Write-JuicerLegend
}

# What WinJuicer.ps1 runs once elevated. Returns the process exit code: 0 when
# everything went through, 1 if anything failed, 2 for a bad argument.
function Start-Juicer {
    [CmdletBinding()]
    param(
        [switch]$Diagnostico,
        [switch]$Lista,
        [string]$Perfil,
        [string[]]$Aplicar = @(),
        [string[]]$Deshacer = @(),
        [switch]$DeshacerTodo,
        [switch]$Simular,
        [switch]$Si,
        [switch]$AceptoRiesgos,
        [switch]$SinPuntoDeRestauracion
    )
    # -File hands "a,b" over as a single string.
    $Aplicar = @($Aplicar | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $Deshacer = @($Deshacer | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $cli = $Diagnostico -or $Lista -or $Perfil -or $Aplicar.Count -gt 0 -or $Deshacer.Count -gt 0 -or $DeshacerTodo

    if (-not $cli) {
        $script:Screen = $true
        $script:Interactive = $true
        Show-JuicerMainMenu
        return 0
    }
    $script:Screen = $false
    $script:Interactive = -not $Si
    if ($Lista) { Show-JuicerList; return 0 }
    if ($Diagnostico) { Show-JuicerAudit; return 0 }

    $results = @()
    if ($DeshacerTodo) { $results += @(Undo-JuicerAll) }
    foreach ($id in $Deshacer) { $results += Undo-JuicerTweak $id }

    $tweaks = New-Object System.Collections.ArrayList
    if ($Perfil) {
        $lvl = @{ Seguro = 1; Rendimiento = 2; Extremo = 3 }[$Perfil]
        if (-not $lvl) { Write-Host "  Perfil desconocido: $Perfil. Usa Seguro, Rendimiento o Extremo." -ForegroundColor Red; return 2 }
        foreach ($t in (Get-JuicerProfile $lvl)) { [void]$tweaks.Add($t) }
    }
    foreach ($id in $Aplicar) {
        $t = Find-JuicerTweak $id
        if (-not $t) { Write-Host "  No existe el ajuste «$id». Usa -Lista para ver los nombres." -ForegroundColor Red; return 2 }
        if (-not ($tweaks | Where-Object { $_.Id -eq $id })) { [void]$tweaks.Add($t) }
    }
    if ($tweaks.Count -gt 0) {
        $journal = Read-JuicerJournal
        $todo = @($tweaks | Where-Object { (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' })
        if ($todo.Count -eq 0) {
            Write-Host '  Ya está todo aplicado.' -ForegroundColor Green
        } else {
            if ($script:Interactive -and -not $Simular) {
                Write-Host ''
                foreach ($t in $todo) { Write-Host "  · $($t.Title)" }
                if (-not (Confirm-JuicerAction "¿Aplicar $($todo.Count) ajustes?")) { return 0 }
            }
            $results += Invoke-JuicerTweakSet $todo -Simulate:$Simular -AcceptRisk:$AceptoRiesgos -NoRestorePoint:$SinPuntoDeRestauracion
        }
    }
    if ($results.Count -gt 0) { Show-JuicerResults $results }
    if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { return 1 }
    0
}
