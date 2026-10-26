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
$script:LevelColors = @{ 0 = 'Cyan'; 1 = 'Green'; 2 = 'Yellow'; 3 = 'Red' }
$script:StartupVerdictColors = @{ Prescindible = 'Green'; Opcional = 'Yellow'; Necesario = 'Cyan' }
$script:VerdictMarks = @{ Recomendado = @('+', 'Green'); Opcional = @(' ', 'DarkGray'); NoRecomendado = @('-', 'DarkGray') }
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

# Verdicts for this machine. Reading the hardware takes a few seconds, so it
# happens once, the first time a screen needs it.
$script:ConsoleAdvice = $null

function Get-JuicerConsoleAdvice {
    if ($null -eq $script:ConsoleAdvice) {
        try {
            $script:ConsoleAdvice = Get-JuicerAdvice (Get-JuicerHardwareProfile)
        } catch {
            Write-JuicerLog "No se pudo leer el hardware para recomendar: $_"
            $script:ConsoleAdvice = @{}
        }
    }
    $script:ConsoleAdvice
}

function Write-JuicerTweakLine {
    param([int]$Number, [hashtable]$Tweak, [hashtable]$State, [hashtable]$Advice)
    $mark = $script:StateMarks[$State.State]
    Write-Host ('  {0} ' -f $mark[0]) -ForegroundColor $mark[1] -NoNewline
    $v = if ($Advice -and $Advice[$Tweak.Id]) { $script:VerdictMarks[$Advice[$Tweak.Id].Verdict] } else { @(' ', 'DarkGray') }
    Write-Host $v[0] -ForegroundColor $v[1] -NoNewline
    Write-Host ('{0,3}  ' -f $Number) -ForegroundColor Yellow -NoNewline
    $title = $Tweak.Title
    $w = (Get-JuicerConsoleWidth) - 37
    if ($title.Length -gt $w) { $title = $title.Substring(0, $w - 1) + '…' }
    Write-Host ("{0,-$w}" -f $title) -NoNewline
    Write-Host (' {0,-12} ' -f $script:LevelNames[[int]$Tweak.Level]) -ForegroundColor $script:LevelColors[[int]$Tweak.Level] -NoNewline
    Write-Host ('impacto {0}' -f $Tweak.Impact.ToLowerInvariant()) -ForegroundColor DarkGray
}

function Write-JuicerLegend {
    param([switch]$Advice)
    Write-Host ''
    Write-Host '  [x] aplicado  [~] a medias  [ ] sin aplicar  [-] no aplica aquí  [!] no se pudo leer' -ForegroundColor DarkGray
    if ($Advice) { Write-Host '  +  recomendado para este equipo    -  no recomendado aquí' -ForegroundColor DarkGray }
}

function Show-JuicerTweakDetail {
    param([hashtable]$Tweak, [hashtable]$State, [hashtable]$Advice)
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
    if ($Advice -and $Advice[$Tweak.Id]) {
        $a = $Advice[$Tweak.Id]
        $label = @{ Recomendado = 'Recomendado'; Opcional = 'Opcional'; NoRecomendado = 'No recomendado' }[$a.Verdict]
        Write-Host "  Para este equipo: $label" -ForegroundColor $(if ($a.Verdict -eq 'Recomendado') { 'Green' } else { 'Gray' })
        Write-JuicerWrapped $a.Reason 4 'DarkGray'
    }
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
    Write-Host '  Este equipo' -ForegroundColor White
    foreach ($l in (Format-JuicerHardwareSummary (Get-JuicerHardwareProfile))) { Write-JuicerWrapped $l 5 'Gray' }
    $area = ''
    foreach ($f in $findings) {
        if ($f.Area -ne $area) { $area = $f.Area; Write-Host ''; Write-Host "  $area" -ForegroundColor White }
        Write-JuicerFindings @($f)
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
            Write-JuicerWrapped 'Las reparaciones están en el perfil Seguro y en «Recomendado».' 2 'DarkGray'
        }
        if (@($top | Where-Object { $_.Area -in 'Overclock y BIOS', 'Estabilidad', 'Memoria', 'Gráfica', 'Pantalla' }).Count -gt 0) {
            Write-JuicerWrapped 'Lo de BIOS, overclock, memoria y pantalla no lo puede cambiar ningún programa: cada aviso dice dónde se arregla.' 2 'DarkGray'
        }
    }
    Wait-JuicerKey
}

function Write-JuicerFindings {
    param([object[]]$Findings)
    foreach ($f in $Findings) {
        $tag = @{ Alto = '!!'; Medio = ' !'; Bajo = ' ·'; Info = '  '; Ok = 'ok' }[$f.Severity]
        Write-Host "  $tag " -ForegroundColor $script:SeverityColors[$f.Severity] -NoNewline
        Write-Host $f.Title -ForegroundColor $(if ($f.Severity -in 'Info', 'Ok') { 'Gray' } else { 'White' })
        if ($f.Detail -and $f.Severity -ne 'Ok') { Write-JuicerWrapped $f.Detail 5 'DarkGray' }
    }
}

function Show-JuicerFineTune {
    while ($true) {
        Write-JuicerHeader 'Ajuste fino'
        Write-JuicerWrapped 'El undervolt del procesador va en la BIOS (la placa lo aplica en cada arranque, sin programas ni drivers de núcleo); el de la gráfica, en su herramienta. Valores de partida para tus componentes:' 2 'Gray'
        $gpus = @(Get-CimInstance Win32_VideoController -ErrorAction SilentlyContinue | ForEach-Object { Get-JuicerGpuTraits $_.Name })
        Write-JuicerFindings @(Get-JuicerTuneGuideFindings (Get-JuicerCpuInfo) $gpus (Test-JuicerLaptop))
        Write-Host ''
        Write-JuicerFindings @(Get-JuicerTuneCheck)
        Write-Host ''
        Write-JuicerMenu @(
            @('A', 'Apuntar lo que he aplicado', 'y comprobarlo en cada inicio de sesión'),
            @('O', 'Olvidarlo', 'y dejar de comprobarlo')
        )
        switch ((Read-JuicerChoice 'Elige, Intro para volver').ToUpperInvariant()) {
            'A' {
                $cpu = Read-JuicerChoice 'Procesador (por ejemplo «Curve Optimizer -30»; Intro si nada)'
                $gpu = Read-JuicerChoice 'Gráfica (por ejemplo «curva 900 mV a 1900 MHz, memoria +500»; Intro si nada)'
                $tool = ''
                if ($gpu) {
                    $t = Read-JuicerChoice 'La aplica: 1 Afterburner, 2 AMD Software, 3 Intel, Intro no lo sé'
                    $tool = @{ '1' = 'Afterburner'; '2' = 'Adrenalin'; '3' = 'Intel' }[$t]
                    if (-not $tool) { $tool = '' }
                }
                if ($cpu -or $gpu) {
                    [void](Save-JuicerTuneRecord -Cpu $cpu -Gpu $gpu -GpuTool $tool)
                    if (Confirm-JuicerAction '¿Comprobarlo cada vez que inicies sesión y avisarte si algo cambia?') { Register-JuicerTuneWatch }
                }
            }
            'O' { Remove-JuicerTuneRecord; Unregister-JuicerTuneWatch }
            '' { return }
        }
    }
}

function Show-JuicerMeasure {
    while ($true) {
        Write-JuicerHeader 'Antes y después'
        Write-JuicerWrapped 'La primera medida se toma sola justo antes de aplicar nada por primera vez. Para que la comparación sea justa, mide recién reiniciado y con todo cerrado; el arranque sólo cambia después de reiniciar.' 2 'DarkGray'
        Write-Host ''
        Write-JuicerMenu @(
            @('1', 'Medir ahora', 'y comparar con la medida inicial'),
            @('2', 'Nueva medida inicial', 'empezar a comparar desde ahora'),
            @('0', 'Volver', '')
        )
        switch (Read-JuicerChoice) {
            '1' { Write-Host '  Midiendo…' -ForegroundColor DarkGray; Write-JuicerFindings (Invoke-JuicerMeasure); Wait-JuicerKey }
            '2' {
                if (Confirm-JuicerAction '¿Descartar la medida inicial y empezar desde ahora?') {
                    Write-JuicerFindings (Invoke-JuicerMeasure -Reset); Wait-JuicerKey
                }
            }
            '0' { return }
        }
    }
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
            Write-Host '  · ' -ForegroundColor $script:LevelColors[[int]$t.Level] -NoNewline
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
    $advice = Get-JuicerConsoleAdvice
    while ($true) {
        Write-JuicerHeader 'Ajustes uno a uno'
        $journal = Read-JuicerJournal
        $catalog = @(Get-JuicerCatalog)
        $n = 0
        $numbered = @()
        foreach ($cat in $script:CategoryOrder) {
            $inCat = @($catalog | Where-Object { $_.Category -eq $cat })
            if ($inCat.Count -eq 0) { continue }
            Write-Host "  $cat" -ForegroundColor White
            foreach ($t in $inCat) {
                $n++
                $numbered += $t
                Write-JuicerTweakLine $n $t (Get-JuicerTweakState $t $journal) $advice
            }
        }
        Write-JuicerLegend -Advice
        $c = Read-JuicerChoice 'Número para ver un ajuste, Intro para volver'
        if ($c -eq '') { return }
        $pick = Get-JuicerNumbers $c $numbered.Count
        if ($pick.Count -ne 1) { continue }
        Show-JuicerTweakScreen $numbered[$pick[0] - 1] $advice
    }
}

# One tweak: what it does, its state, and what can be done with it from here.
# Toggles (preferences, components) can also be switched the other way.
function Show-JuicerTweakScreen {
    param([hashtable]$Tweak, [hashtable]$Advice)
    $t = $Tweak
    while ($true) {
        Write-JuicerHeader $t.Category
        $s = Get-JuicerTweakState $t
        Show-JuicerTweakDetail $t $s $Advice
        $inverse = $null
        if ($t.Off) { $inverse = Get-JuicerTweakState (Get-JuicerInverseTweak $t) }
        $opts = @()
        if ($s.State -in 'Pendiente', 'Parcial') { $opts += 'A aplicar' }
        if ($s.Undoable) { $opts += 'D deshacer' }
        if ($inverse -and $inverse.State -in 'Pendiente', 'Parcial') { $opts += 'X poner lo contrario' }
        $c2 = Read-JuicerChoice (($opts + 'Intro volver') -join ' · ')
        if ($c2 -match '^[aA]$' -and $s.State -in 'Pendiente', 'Parcial') {
            if ($t.Level -ge 3 -and -not (Confirm-JuicerRisk $t)) { continue }
            $r = if ($t.Off) { @(Set-JuicerToggle $t $true) } else { @(Invoke-JuicerTweak $t) }
            Show-JuicerResults $r
            Wait-JuicerKey
        } elseif ($c2 -match '^[dD]$' -and $s.Undoable) {
            Show-JuicerResults @(Undo-JuicerTweak $t.Id)
            Wait-JuicerKey
        } elseif ($c2 -match '^[xX]$' -and $inverse -and $inverse.State -in 'Pendiente', 'Parcial') {
            Show-JuicerResults @(Set-JuicerToggle $t $false)
            Wait-JuicerKey
        } else {
            return
        }
    }
}

function Show-JuicerStartup {
    while ($true) {
        Write-JuicerHeader 'Programas de inicio'
        Write-Host '  Leyendo…' -ForegroundColor DarkGray
        $items = @(Get-JuicerStartupReview | Sort-Object { -not $_.Enabled }, { $_.Name })
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
            Write-Host ('{0,-28} ' -f $i.Source) -ForegroundColor DarkGray -NoNewline
            if ($i.Verdict) { Write-Host $i.Verdict.ToLowerInvariant() -ForegroundColor $script:StartupVerdictColors[$i.Verdict] } else { Write-Host '' }
            if ($i.Why) { Write-JuicerWrapped $i.Why 12 'Gray' }
            $cmd = $i.Command
            if ($cmd.Length -gt $w + 30) { $cmd = $cmd.Substring(0, $w + 29) + '…' }
            Write-Host "            $cmd" -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-JuicerWrapped 'Desactivar no borra nada: es el mismo interruptor del Administrador de tareas. Las apps de la Tienda que arrancan solas se gestionan en Configuración > Aplicaciones > Inicio.' 2 'DarkGray'
        $junk = @($items | Where-Object { $_.Enabled -and $_.Verdict -eq 'Prescindible' })
        $prompt = if ($junk.Count -gt 0) { "Números para activar o desactivar (ej. 2,5,7), P para desactivar los $($junk.Count) prescindibles, Intro para volver" } else { 'Números para activar o desactivar (ej. 2,5,7), Intro para volver' }
        $c = Read-JuicerChoice $prompt
        if ($c -eq '') { return }
        $results = @()
        if ($c -match '^[pP]$' -and $junk.Count -gt 0) {
            foreach ($i in $junk) { $results += Set-JuicerStartupItem $i $false }
            Show-JuicerResults $results
            Wait-JuicerKey
            continue
        }
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
            @('3', 'Juegos configurados', 'ver y deshacer'),
            @('4', 'Medir FPS y frametimes', 'media, 1 % bajo, tirones y qué limita, con PresentMon'),
            @('5', 'Limitador de FPS', 'un límite por juego que se aplica solo, según tu monitor')
        )
        $c = Read-JuicerChoice 'Elige, Intro para volver'
        switch ($c) {
            '1' { Show-JuicerDefenderLibraries }
            '2' { Show-JuicerConfigureGame }
            '3' { Show-JuicerConfiguredGames }
            '4' { Show-JuicerFrameMeasure }
            '5' { Show-JuicerLimiter }
            '' { return }
        }
    }
}

function Show-JuicerLimiter {
    while ($true) {
        Write-JuicerHeader 'Limitador de FPS'
        $m = $null
        try { $m = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
        Write-JuicerWrapped ('Limita con: ' + (Format-JuicerFpsBackend (Get-JuicerFpsBackend)) + '.') 2 'Gray'
        if ($m) {
            $cap = Get-JuicerFpsCap ([int]$m.Display.Hz) (Resolve-JuicerMonitorUse $m) $null $(if ($m.Vrr) { [int]$m.Vrr.Min } else { 0 })
            Write-JuicerWrapped ('Tu pantalla: ' + (Format-JuicerMonitor $m) + '. Cómo la usas: ' + (Get-JuicerMonitorModes)[$m.Mode] + ". Límite recomendado: $($cap.Fps) FPS. $($cap.Why)") 2 'Gray'
        }
        $limits = @(Get-JuicerFpsLimits)
        Write-Host ''
        $n = 0
        foreach ($g in $limits) { $n++; Write-Host ('  {0,2}. {1}: {2}' -f $n, $g.Exe, $(if ($g.Fps) { "$($g.Fps) FPS" } else { 'sin límite ahora' })) }
        if ($n -eq 0) { Write-Host '  Ningún juego limitado todavía.' -ForegroundColor DarkGray }
        Write-Host ''
        Write-JuicerMenu @(
            @('A', 'Añadir un juego', 'por nombre del .exe, con el límite recomendado o el tuyo'),
            @('M', 'Añadir los juegos medidos', (@(Get-JuicerUnlimitedGames) -join ', ')),
            @('Q', 'Quitar un límite', 'por número'),
            @('U', 'Cómo usas tu monitor', 'VRR, ELMB/DyAc u otro estroboscopio, o frecuencia fija'),
            @('R', 'Recalcular los límites', 'con el modo y la frecuencia de ahora')
        )
        switch ((Read-JuicerChoice 'Elige, Intro para volver').ToUpperInvariant()) {
            'A' {
                $exe = Read-JuicerChoice 'Nombre del .exe (por ejemplo cs2.exe)'
                if (-not $exe) { continue }
                $f = Read-JuicerChoice 'FPS (Intro: el recomendado)'
                $fps = if ($f -match '^\d+$') { [int]$f } else { 0 }
                Show-JuicerResults @(Add-JuicerFpsLimit $exe $fps)
            }
            'M' { Show-JuicerResults @(foreach ($g in @(Get-JuicerUnlimitedGames)) { Add-JuicerFpsLimit $g }) }
            'Q' {
                $q = Read-JuicerChoice 'Número'
                if ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $limits.Count) { Show-JuicerResults @(Undo-JuicerTweak $limits[[int]$q - 1].Id) }
            }
            'U' {
                if (-not $m) { Write-JuicerWrapped 'No se pudo leer el monitor.' 2 'Yellow'; Wait-JuicerKey; continue }
                $modes = Get-JuicerMonitorModes
                $keys = @($modes.Keys)
                Write-Host ''
                for ($i = 0; $i -lt $keys.Count; $i++) { Write-Host ('  {0}. {1}' -f ($i + 1), $modes[$keys[$i]]) }
                $q = Read-JuicerChoice 'Número'
                if ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $keys.Count) {
                    [void](Set-JuicerMonitorMode $m $keys[[int]$q - 1])
                    if ($limits.Count -gt 0 -and (Confirm-JuicerAction '¿Recalcular con este modo los límites que ya tienes?')) { Show-JuicerResults @(Update-JuicerFpsLimits $m) }
                }
            }
            'R' { Show-JuicerResults @(Update-JuicerFpsLimits $m) }
            '' { return }
        }
    }
}

# One line that rewrites itself: a countdown, not a scrolling list.
function Write-JuicerStatusLine {
    param([string]$Text)
    Write-Host ("`r  " + $Text).PadRight(76) -NoNewline -ForegroundColor DarkGray
}

function Show-JuicerFrameMeasure {
    Write-JuicerHeader 'Medir FPS y frametimes'
    Write-JuicerWrapped 'Abre el juego y prepara una escena que puedas repetir. Al empezar tienes 10 segundos para volver al juego; juega con normalidad hasta que acabe. La primera vez descarga PresentMon, de Intel.' 2 'Gray'
    Write-Host ''
    $s = Read-JuicerChoice 'Segundos de medida (Intro = 60)'
    $secs = 60
    if ($s -match '^\d+$' -and [int]$s -ge 10 -and [int]$s -le 600) { $secs = [int]$s }
    try {
        $f = @(Invoke-JuicerFrameCapture -Seconds $secs -Delay 10 -OnStatus ${function:Write-JuicerStatusLine})
        Write-Host ''
        Write-JuicerFindings $f
    } catch {
        Write-Host ''
        Write-JuicerWrapped "No se pudo medir: $_" 2 'Yellow'
    }
    Wait-JuicerKey
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
            @('4', 'Reparar Windows', 'DISM y SFC; tarda bastante'),
            @('5', 'Restablecer la red', 'Winsock y TCP/IP: «conectado, sin internet»; pide reiniciar'),
            @('6', 'Restablecer Windows Update', 'cuando se atasca descargando o falla siempre igual')
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
            '5' {
                Write-JuicerHeader 'Restablecer la red'
                if (Confirm-JuicerAction 'Se perderán las configuraciones de Winsock de VPN y cortafuegos antiguos. ¿Seguir') {
                    foreach ($r in (Invoke-JuicerNetworkReset)) { Write-Host ('  {0} {1}' -f $(if ($r.Ok) { '[ok]' } else { '[!!]' }), $r.Step) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' }) }
                    Write-JuicerWrapped 'Reinicia el equipo para completar.' 2 'Yellow'
                }
                Wait-JuicerKey
            }
            '6' {
                Write-JuicerHeader 'Restablecer Windows Update'
                foreach ($r in (Invoke-JuicerUpdateReset)) { Write-Host ('  {0} {1}' -f $(if ($r.Ok) { '[ok]' } else { '[!!]' }), $r.Step) -ForegroundColor $(if ($r.Ok) { 'Green' } else { 'Red' }) }
                Write-JuicerWrapped 'Las carpetas antiguas quedan renombradas como .old: bórralas cuando Windows Update vuelva a funcionar.' 2 'DarkGray'
                Wait-JuicerKey
            }
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

function Show-JuicerRecommended {
    Write-JuicerHeader 'Recomendado para este equipo'
    Write-Host '  Leyendo el hardware…' -ForegroundColor DarkGray
    $hw = Get-JuicerHardwareProfile
    $advice = Get-JuicerConsoleAdvice
    Write-JuicerHeader 'Recomendado para este equipo'
    foreach ($l in (Format-JuicerHardwareSummary $hw)) { Write-JuicerWrapped $l 2 'Gray' }
    Write-Host ''
    $journal = Read-JuicerJournal
    $todo = @(Get-JuicerRecommendedTweaks $hw | Where-Object { (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' })
    $skipped = @(Get-JuicerCatalog | Where-Object { $_.Level -ge 1 -and $advice[$_.Id].Verdict -eq 'NoRecomendado' })
    if ($skipped.Count -gt 0) {
        Write-Host '  No conviene en este equipo:' -ForegroundColor White
        foreach ($t in $skipped) {
            Write-Host "  - $($t.Title)" -ForegroundColor DarkGray
            Write-JuicerWrapped $advice[$t.Id].Reason 6 'DarkGray'
        }
        Write-Host ''
    }
    if ($todo.Count -eq 0) {
        Write-Host '  Ya tienes aplicado todo lo recomendado para este equipo.' -ForegroundColor Green
        Wait-JuicerKey
        return
    }
    Write-Host '  Se aplicará:' -ForegroundColor White
    foreach ($t in $todo) {
        Write-Host '  + ' -ForegroundColor $script:LevelColors[[int]$t.Level] -NoNewline
        Write-Host $t.Title -NoNewline
        Write-Host "  (impacto $($t.Impact.ToLowerInvariant()))" -ForegroundColor DarkGray
        Write-JuicerWrapped $advice[$t.Id].Reason 6 'DarkGray'
    }
    $c = Read-JuicerChoice "¿Aplicar $($todo.Count) ajustes? S para aplicar, V para simular, Intro para volver"
    if ($c -match '^[vV]$') { Show-JuicerResults (Invoke-JuicerTweakSet $todo -Simulate) }
    elseif ($c -match '^(s|si|sí|y|yes)$') { Show-JuicerResults (Invoke-JuicerTweakSet $todo) }
    else { return }
    Wait-JuicerKey
}

function Show-JuicerDebloat {
    $headers = @{ Seguro = 'Seguras de quitar'; Opcional = 'Opcionales: léelas antes'; Cuidado = 'Con cuidado: algo depende de ellas' }
    while ($true) {
        Write-JuicerHeader 'Debloat: apps que vienen con Windows'
        Write-Host '  Leyendo las apps instaladas…' -ForegroundColor DarkGray
        $hw = Get-JuicerHardwareProfile
        try {
            $apps = @(Get-JuicerDebloatState $hw)
        } catch {
            Write-Host "  No se pudieron leer las apps instaladas: $_" -ForegroundColor Red
            Wait-JuicerKey
            return
        }
        $journal = Read-JuicerJournal
        $extras = @(Get-JuicerCatalog | Where-Object { $_.Category -eq 'Apps' -and (Get-JuicerTweakState $_ $journal).State -in 'Pendiente', 'Parcial' })
        Write-JuicerHeader 'Debloat: apps que vienen con Windows'
        $n = 0
        $numbered = @()
        foreach ($class in 'Seguro', 'Opcional', 'Cuidado') {
            $in = @($apps | Where-Object { $_.Class -eq $class })
            if ($in.Count -eq 0) { continue }
            Write-Host "  $($headers[$class])" -ForegroundColor White
            foreach ($a in $in) {
                $n++
                $numbered += , @{ App = $a }
                $mark = if ($a.Need) { @('!', 'Yellow') } elseif ($a.Recommended) { @('+', 'Green') } else { @(' ', 'Gray') }
                Write-Host ('  {0}{1,3}  ' -f $mark[0], $n) -ForegroundColor $mark[1] -NoNewline
                Write-Host $a.Title
                Write-JuicerWrapped $a.What 8 'DarkGray'
                if ($a.Need) { Write-JuicerWrapped "Necesaria aquí: $($a.Need)" 8 'Yellow' }
            }
        }
        foreach ($t in $extras) {
            $n++
            $numbered += , @{ Tweak = $t }
            Write-Host ('   {0,3}  ' -f $n) -ForegroundColor Yellow -NoNewline
            Write-Host $t.Title
            Write-JuicerWrapped $t.What 8 'DarkGray'
        }
        if ($n -eq 0) { Write-Host '  No queda instalada ninguna de las apps que Win Juicer sabe quitar.' -ForegroundColor Green }
        Write-Host ''
        Write-JuicerWrapped 'Quitar una app la desinstala para todos los usuarios. Deshacer la reinstala desde Microsoft Store con winget. Una app cerrada no cuesta FPS: esto es espacio, actualizaciones de fondo y un Inicio más limpio.' 2 'DarkGray'
        $c = Read-JuicerChoice 'Números a quitar (ej. 1,3-5), T todas las «+», R reinstalar, Intro volver'
        if ($c -eq '') { return }
        if ($c -match '^[rR]$') { Show-JuicerReinstallApps; continue }
        $picked = if ($c -match '^[tT]$') { @($numbered | Where-Object { $_.App -and $_.App.Recommended }) } else { @(Get-JuicerNumbers $c $n | ForEach-Object { $numbered[$_ - 1] }) }
        if ($picked.Count -eq 0) { continue }
        $tweaks = @(foreach ($p in $picked) { if ($p.App) { New-JuicerAppxTweak (Find-JuicerDebloatApp $p.App.Name) } else { $p.Tweak } })
        Write-Host ''
        foreach ($p in $picked) {
            if ($p.App -and $p.App.Need) { Write-JuicerWrapped "Atención: $($p.App.Title). $($p.App.Need)" 2 'Yellow' }
        }
        if (-not (Confirm-JuicerAction "¿Quitar $($tweaks.Count) apps?")) { continue }
        Show-JuicerResults (Invoke-JuicerTweakSet $tweaks)
        Wait-JuicerKey
    }
}

function Show-JuicerReinstallApps {
    Write-JuicerHeader 'Reinstalar apps quitadas'
    $removed = @(Get-JuicerRemovedApps) + @(Read-JuicerJournal | Where-Object { $_.Id -eq 'apps.onedrive' })
    if ($removed.Count -eq 0) { Write-Host '  Win Juicer no ha quitado ninguna app.' -ForegroundColor DarkGray; Wait-JuicerKey; return }
    $n = 0
    foreach ($e in $removed) { $n++; Write-Host ('  {0,3}  {1}' -f $n, ($e.Title -replace '^Quitar ', '')) }
    $c = Read-JuicerChoice 'Números a reinstalar, Intro para volver'
    if ($c -eq '') { return }
    Show-JuicerResults @(Get-JuicerNumbers $c $removed.Count | ForEach-Object { Undo-JuicerTweak $removed[$_ - 1].Id })
    Wait-JuicerKey
}

function Show-JuicerDns {
    while ($true) {
        Write-JuicerHeader 'Red: servidores DNS'
        $current = @(Get-JuicerCurrentDns)
        $providers = Get-JuicerDnsProviders
        if ($current.Count -eq 0) {
            Write-Host '  No hay ningún adaptador de red físico conectado.' -ForegroundColor Yellow
            Wait-JuicerKey
            return
        }
        foreach ($c in $current) {
            $what = if ($c.Provider -ne 'Otro') { $providers[$c.Provider].Title } else { (@($c.V4) + @($c.V6)) -join ', ' }
            Write-Host "  $($c.Adapter): " -NoNewline
            Write-Host $what -ForegroundColor Cyan
        }
        Write-Host ''
        $keys = @($providers.Keys)
        for ($i = 0; $i -lt $keys.Count; $i++) {
            $p = $providers[$keys[$i]]
            Write-Host ('  {0,2}  ' -f ($i + 1)) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-40} ' -f $p.Title) -NoNewline
            Write-Host $p.What -ForegroundColor DarkGray
        }
        Write-Host ''
        Write-JuicerWrapped 'El DNS no baja el ping: sólo se consulta al conectar. Sirve para privacidad, para filtrar malware o anuncios, o porque el de tu operador falle.' 2 'DarkGray'
        $undo = $null -ne (Get-JuicerJournalEntry (Read-JuicerJournal) 'red.dns')
        $c = Read-JuicerChoice $(if ($undo) { 'Número para cambiar, D para volver al que tenías, Intro para volver' } else { 'Número para cambiar, Intro para volver' })
        if ($c -eq '') { return }
        if ($c -match '^[dD]$' -and $undo) { Show-JuicerResults @(Undo-JuicerTweak 'red.dns'); Wait-JuicerKey; continue }
        $pick = @(Get-JuicerNumbers $c $keys.Count)
        if ($pick.Count -ne 1) { continue }
        Show-JuicerResults @(Invoke-JuicerTweak (New-JuicerDnsTweak $keys[$pick[0] - 1]))
        Wait-JuicerKey
    }
}

function Show-JuicerInstall {
    if (-not (Test-JuicerWinget)) {
        Write-JuicerHeader 'Instalar programas'
        Write-JuicerWrapped 'winget no está disponible. Instálalo o actualízalo desde Microsoft Store: «Instalador de aplicación».' 2 'Yellow'
        Wait-JuicerKey
        return
    }
    while ($true) {
        Write-JuicerHeader 'Instalar programas (winget)'
        Write-Host '  Leyendo lo que ya está instalado…' -ForegroundColor DarkGray
        $installed = Get-JuicerWingetInstalled
        $suggest = Get-JuicerAppSuggestions (Get-JuicerHardwareProfile)
        Write-JuicerHeader 'Instalar programas (winget)'
        $apps = @(Get-JuicerWingetApps)
        $n = 0
        $numbered = @()
        foreach ($cat in $script:WingetCategories) {
            $in = @($apps | Where-Object { $_.Category -eq $cat })
            if ($in.Count -eq 0) { continue }
            Write-Host "  $cat" -ForegroundColor White
            foreach ($a in $in) {
                $n++
                $numbered += $a
                $has = $installed.ContainsKey($a.Id.ToLowerInvariant())
                $mark = if ($has) { @('[x]', 'Green') } else { @('[ ]', 'Gray') }
                $sug = if ($suggest.Contains($a.Id) -and -not $has) { '+' } else { ' ' }
                Write-Host ('  {0}' -f $mark[0]) -ForegroundColor $mark[1] -NoNewline
                Write-Host $sug -ForegroundColor Green -NoNewline
                Write-Host ('{0,3}  ' -f $n) -ForegroundColor Yellow -NoNewline
                Write-Host ('{0,-30} ' -f $a.Name) -NoNewline
                Write-Host $(if ($sug -eq '+') { $suggest[$a.Id] } else { $a.What }) -ForegroundColor DarkGray
            }
        }
        Write-Host ''
        Write-Host '  [x] instalado   + sugerido para este equipo' -ForegroundColor DarkGray
        $c = Read-JuicerChoice 'Números a instalar; Q y números para desinstalar (Q 3,5); A para actualizar todo; Intro volver'
        if ($c -eq '') { return }
        try {
            if ($c -match '^[aA]$') {
                Start-JuicerWinget 'upgrade'
            } elseif ($c -match '^[qQ]\s*(.+)$') {
                $ids = @(Get-JuicerNumbers $Matches[1] $n | ForEach-Object { $numbered[$_ - 1].Id })
                if ($ids.Count -gt 0) { Start-JuicerWinget 'uninstall' $ids }
            } else {
                $ids = @(Get-JuicerNumbers $c $n | ForEach-Object { $numbered[$_ - 1].Id })
                if ($ids.Count -gt 0) { Start-JuicerWinget 'install' $ids }
            }
            Write-JuicerWrapped 'Se ha abierto una ventana con winget: ahí verás el progreso.' 2 'Green'
        } catch {
            Write-JuicerWrapped "$_" 2 'Red'
        }
        Wait-JuicerKey
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
    $script:UpdateNotice = Get-JuicerUpdateNotice
    while ($true) {
        Write-JuicerHeader
        Write-JuicerMenu @(
            @('1', 'Diagnóstico', 'hardware, overclock y BIOS: qué frena a este equipo'),
            @('2', 'Recomendado', 'lo que conviene a este equipo, según su hardware'),
            @('3', 'Perfiles', 'Seguro · Rendimiento · Extremo'),
            @('4', 'Ajustes uno a uno', 'estado, ganancia y coste; preferencias y componentes'),
            @('5', 'Debloat', 'las apps que vienen con Windows, una a una'),
            @('6', 'Programas de inicio', 'lo que arranca solo con Windows'),
            @('7', 'Juegos', 'GPU, prioridad y exclusiones de Defender'),
            @('8', 'Red y DNS', 'elegir servidor DNS'),
            @('9', 'Instalar programas', 'con winget: lanzadores, navegadores, herramientas'),
            @('10', 'Mantenimiento', 'limpieza, TRIM, reparar Windows, la red y Windows Update'),
            @('11', 'Deshacer', 'todo, o cambio a cambio'),
            @('12', 'Lo que no hacemos', 'los «trucos» que circulan, y por qué no'),
            @('13', 'Antes y después', 'arranque, procesos y memoria: qué han cambiado los ajustes'),
            @('14', 'Ajuste fino', 'undervolt de CPU y overclock de GPU para tus componentes, y vigilarlos'),
            @('0', 'Salir', '')
        )
        if ($script:UpdateNotice) {
            Write-JuicerWrapped "Hay una versión nueva de Win Juicer ($($script:UpdateNotice.Latest); tienes la $($script:UpdateNotice.Local)). Para usarla, sal y ejecuta en PowerShell: $($script:UpdateNotice.Command)" 2 'Yellow'
            Write-Host ''
        }
        $c = Read-JuicerChoice
        switch ($c) {
            '1' { Show-JuicerAudit }
            '2' { Show-JuicerRecommended }
            '3' { Show-JuicerProfiles }
            '4' { Show-JuicerTweakList }
            '5' { Show-JuicerDebloat }
            '6' { Show-JuicerStartup }
            '7' { Show-JuicerGames }
            '8' { Show-JuicerDns }
            '9' { Show-JuicerInstall }
            '10' { Show-JuicerMaintenance }
            '11' { Show-JuicerUndo }
            '12' { Show-JuicerMyths }
            '13' { Show-JuicerMeasure }
            '14' { Show-JuicerFineTune }
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

function Show-JuicerEquipo {
    $hw = Get-JuicerHardwareProfile
    Write-Host ''
    foreach ($l in (Format-JuicerHardwareSummary $hw)) { Write-Host "  $l" }
    $advice = Get-JuicerAdvice $hw
    $labels = @{ Recomendado = 'recomendado'; Opcional = 'opcional'; NoRecomendado = 'no recomendado' }
    foreach ($cat in $script:CategoryOrder) {
        $inCat = @(Get-JuicerCatalog | Where-Object { $_.Category -eq $cat })
        if ($inCat.Count -eq 0) { continue }
        Write-Host ''
        Write-Host "  $cat" -ForegroundColor White
        foreach ($t in $inCat) {
            $a = $advice[$t.Id]
            $m = $script:VerdictMarks[$a.Verdict]
            Write-Host ('  {0} ' -f $m[0]) -ForegroundColor $m[1] -NoNewline
            Write-Host ('{0,-22} ' -f $t.Id) -ForegroundColor Yellow -NoNewline
            Write-Host ('{0,-15} ' -f $labels[$a.Verdict]) -ForegroundColor $(if ($a.Verdict -eq 'Recomendado') { 'Green' } else { 'DarkGray' }) -NoNewline
            Write-Host $a.Reason -ForegroundColor Gray
        }
    }
}

# -QuitarApps takes package names (Microsoft.BingNews), what comes after
# «app:» in the journal, or a catalog id from Apps (apps.onedrive).
function Resolve-JuicerAppTweak {
    param([string]$Name)
    $n = $Name -replace '^app:', ''
    $app = Find-JuicerDebloatApp $n
    if ($app) { return (New-JuicerAppxTweak $app) }
    $t = Find-JuicerTweak $n
    if ($t -and $t.Category -eq 'Apps') { return $t }
    $null
}

# What WinJuicer.ps1 runs once elevated. Returns the process exit code: 0 when
# everything went through, 1 if anything failed, 2 for a bad argument.
function Start-Juicer {
    [CmdletBinding()]
    param(
        [switch]$Diagnostico,
        [string]$Informe,
        [switch]$Equipo,
        [switch]$Medir,
        [switch]$NuevaMedida,
        [switch]$ApuntarAjuste,
        [string]$AjusteCpu,
        [string]$AjusteGpu,
        [ValidateSet('', 'Afterburner', 'Adrenalin', 'Intel')][string]$HerramientaGpu = '',
        [switch]$OlvidarAjuste,
        [int]$MedirJuego,
        [string]$Juego,
        [string[]]$LimitarFps = @(),
        [int]$Fps,
        [string]$ModoMonitor,
        [switch]$Lista,
        [switch]$Recomendado,
        [string]$Perfil,
        [string[]]$Aplicar = @(),
        [string[]]$QuitarApps = @(),
        [string]$Dns,
        [string[]]$Instalar = @(),
        [string[]]$Deshacer = @(),
        [switch]$DeshacerTodo,
        [string]$Exportar,
        [string]$Importar,
        [switch]$Simular,
        [switch]$Si,
        [switch]$AceptoRiesgos,
        [switch]$SinPuntoDeRestauracion,
        [switch]$Consola
    )
    # -File hands "a,b" over as a single string.
    $split = { param($v) @($v | ForEach-Object { $_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
    $Aplicar = & $split $Aplicar
    $Deshacer = & $split $Deshacer
    $QuitarApps = & $split $QuitarApps
    $Instalar = & $split $Instalar
    $LimitarFps = & $split $LimitarFps
    $cli = $Diagnostico -or $Informe -or $Exportar -or $Importar -or $Equipo -or $Medir -or $NuevaMedida -or $ApuntarAjuste -or $OlvidarAjuste -or $MedirJuego -or $LimitarFps.Count -gt 0 -or $ModoMonitor -or $Lista -or $Recomendado -or $Perfil -or $Dns -or $DeshacerTodo -or
    $Aplicar.Count -gt 0 -or $Deshacer.Count -gt 0 -or $QuitarApps.Count -gt 0 -or $Instalar.Count -gt 0

    if (-not $cli) {
        $script:Screen = $true
        $script:Interactive = $true
        if (-not $Consola) {
            try {
                Show-JuicerGui
                return 0
            } catch {
                Write-JuicerLog "La ventana no pudo abrirse: $_"
                Write-Host "  No se pudo abrir la ventana ($_). Sigo en modo consola." -ForegroundColor Yellow
                Start-Sleep -Seconds 2
            }
        }
        Show-JuicerMainMenu
        return 0
    }
    $script:Screen = $false
    $script:Interactive = -not $Si
    if ($Lista) { Show-JuicerList; return 0 }
    if ($Informe) {
        $f = @(Get-JuicerAudit)
        $p = Save-JuicerAuditReport $Informe (Format-JuicerHardwareSummary (Get-JuicerHardwareProfile)) $f
        Write-Host "  Informe guardado en $p"
        return 0
    }
    if ($Diagnostico) { Show-JuicerAudit; return 0 }
    $monitor = $null
    if ($ModoMonitor) {
        $mode = @((Get-JuicerMonitorModes).Keys | Where-Object { $_ -eq $ModoMonitor })
        if ($mode.Count -eq 0) { Write-Host ('  -ModoMonitor admite: ' + (@((Get-JuicerMonitorModes).Keys) -join ', ') + '.') -ForegroundColor Yellow; return 2 }
        $ModoMonitor = $mode[0]
        try { $monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
        if ($monitor) {
            [void](Set-JuicerMonitorMode $monitor $ModoMonitor)
            Write-Host ('  ' + (Format-JuicerMonitor $monitor))
        } elseif ($LimitarFps.Count -eq 0) {
            Write-Host '  No se pudo leer el monitor para guardar cómo lo usas.' -ForegroundColor Yellow
            return 1
        }
        if ($LimitarFps.Count -eq 0) { return 0 }
    }
    if ($LimitarFps.Count -gt 0) {
        if ($Fps -and ($Fps -lt 20 -or $Fps -gt 1000)) { Write-Host '  -Fps va de 20 a 1000.' -ForegroundColor Yellow; return 2 }
        $results = @(foreach ($exe in $LimitarFps) { Add-JuicerFpsLimit $exe $Fps $monitor $ModoMonitor })
        Show-JuicerResults $results
        return $(if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 1 } else { 0 })
    }
    if ($MedirJuego) {
        if ($MedirJuego -lt 10 -or $MedirJuego -gt 600) { Write-Host '  -MedirJuego va de 10 a 600 segundos.' -ForegroundColor Yellow; return 2 }
        try {
            $f = @(Invoke-JuicerFrameCapture -Seconds $MedirJuego -Delay 10 -Process $Juego -OnStatus ${function:Write-JuicerStatusLine})
            Write-Host ''
            Write-JuicerFindings $f
            return 0
        } catch {
            Write-Host "  No se pudo medir: $_" -ForegroundColor Yellow
            return 1
        }
    }
    if ($OlvidarAjuste) { Remove-JuicerTuneRecord; Unregister-JuicerTuneWatch; Write-Host '  Ajuste fino olvidado.'; return 0 }
    if ($ApuntarAjuste) {
        if (-not $AjusteCpu -and -not $AjusteGpu) { Write-Host '  Indica -AjusteCpu, -AjusteGpu o los dos.' -ForegroundColor Yellow; return 2 }
        [void](Save-JuicerTuneRecord -Cpu $AjusteCpu -Gpu $AjusteGpu -GpuTool $HerramientaGpu)
        Register-JuicerTuneWatch
        Write-JuicerFindings @(Get-JuicerTuneCheck)
        return 0
    }
    if ($Medir -or $NuevaMedida) { Write-JuicerFindings (Invoke-JuicerMeasure -Reset:$NuevaMedida); return 0 }
    if ($Exportar) {
        $cfg = Export-JuicerConfig $Exportar
        Write-Host ('  Configuración guardada en {0}: {1} ajustes, {2} preferencias, {3} apps{4}.' -f $Exportar, @($cfg.Tweaks).Count, $cfg.Toggles.Count, @($cfg.Apps).Count, $(if ($cfg.Dns) { ", DNS $($cfg.Dns)" } else { '' }))
        return 0
    }
    $imported = $null
    if ($Importar) {
        try { $imported = Read-JuicerConfig $Importar } catch { Write-Host "  $_" -ForegroundColor Red; return 2 }
        if ($imported.Unknown.Count -gt 0) { Write-Host "  Se ignora lo que esta versión no conoce: $($imported.Unknown -join ', ')" -ForegroundColor Yellow }
    }
    if ($Equipo) { Show-JuicerEquipo; return 0 }
    if ($Instalar.Count -gt 0) {
        foreach ($id in $Instalar) { if (-not (Test-JuicerWingetId $id)) { Write-Host "  Identificador de winget no válido: $id" -ForegroundColor Red; return 2 } }
        try { Start-JuicerWinget 'install' $Instalar } catch { Write-Host "  $_" -ForegroundColor Red; return 1 }
        Write-Host '  winget sigue en su propia ventana.'
        return 0
    }

    $results = @()
    if ($DeshacerTodo) { $results += @(Undo-JuicerAll) }
    foreach ($id in $Deshacer) { $results += Undo-JuicerTweak $id }

    $tweaks = New-Object System.Collections.ArrayList
    $add = { param($t) if (-not ($tweaks | Where-Object { $_.Id -eq $t.Id })) { [void]$tweaks.Add($t) } }
    if ($Perfil) {
        $lvl = @{ Seguro = 1; Rendimiento = 2; Extremo = 3 }[$Perfil]
        if (-not $lvl) { Write-Host "  Perfil desconocido: $Perfil. Usa Seguro, Rendimiento o Extremo." -ForegroundColor Red; return 2 }
        foreach ($t in (Get-JuicerProfile $lvl)) { & $add $t }
    }
    if ($Recomendado) {
        foreach ($t in (Get-JuicerRecommendedTweaks (Get-JuicerHardwareProfile))) { & $add $t }
    }
    foreach ($id in $Aplicar) {
        $t = Find-JuicerTweak $id
        if (-not $t) { Write-Host "  No existe el ajuste «$id». Usa -Lista para ver los nombres." -ForegroundColor Red; return 2 }
        & $add $t
    }
    foreach ($name in $QuitarApps) {
        $t = Resolve-JuicerAppTweak $name
        if (-not $t) { Write-Host "  No sé quitar «$name». Los nombres están en el menú Debloat." -ForegroundColor Red; return 2 }
        & $add $t
    }
    if ($imported) { foreach ($t in @(Get-JuicerConfigTweaks $imported)) { & $add $t } }
    if ($Dns) {
        if (-not (Get-JuicerDnsProviders).Contains($Dns)) {
            Write-Host "  DNS desconocido: $Dns. Usa: $(@((Get-JuicerDnsProviders).Keys) -join ', ')." -ForegroundColor Red
            return 2
        }
        & $add (New-JuicerDnsTweak $Dns)
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
    if ($imported) {
        foreach ($k in $imported.Toggles.Keys) {
            $t = Find-JuicerTweak $k
            if ($Simular) {
                $target = if ($imported.Toggles[$k]) { $t } else { Get-JuicerInverseTweak $t }
                $results += Invoke-JuicerTweak $target -Simulate
            } else {
                $results += @(Set-JuicerToggle $t ([bool]$imported.Toggles[$k]))
            }
        }
    }
    if ($results.Count -gt 0) { Show-JuicerResults $results }
    if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { return 1 }
    0
}
