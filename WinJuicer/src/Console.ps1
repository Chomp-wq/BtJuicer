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
    Write-Host '  exprime Windows 10 y 11, sin humo' -ForegroundColor DarkGray
    Write-Host ('  ' + ('─' * 46)) -ForegroundColor DarkGray
    if ($script:MenuNotice) {
        Write-Host "  $($script:MenuNotice)" -ForegroundColor Yellow
        $script:MenuNotice = ''
    }
    if ($Section) {
        Write-Host "  $Section" -ForegroundColor White
        Write-Host ''
    }
}

# Set when Read-Host returned $null: standard input is closed (a pipe that ended, Ctrl+Z), so
# nobody can answer any more. Menus that would loop on an empty answer leave instead.
$script:InputClosed = $false
# What the last wrong choice said: the next screen prints it under its header (a menu clears
# the screen, so saying it right away would be erased before it could be read).
$script:MenuNotice = ''

function Read-JuicerChoice {
    param([string]$Prompt = 'Elige')
    Write-Host ''
    Write-Host "  $Prompt" -ForegroundColor Cyan -NoNewline
    $answer = Read-Host ' '
    if ($null -eq $answer) { $script:InputClosed = $true; return '' }
    $answer.Trim()
}

# For the default branch of a menu: brief, and nothing for an empty answer (Intro just redraws).
function Write-JuicerInvalidChoice {
    param([string]$Choice)
    $c = ([string]$Choice).Trim()
    if (-not $c) { return }
    if ($c.Length -gt 20) { $c = $c.Substring(0, 19) + '…' }
    $script:MenuNotice = "Opción no válida: $c"
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

# An FPS typed by hand: 0 for Intro (the recommended one), a whole number from 20 to 1000
# (178.5 and 178,5 are rounded); anything else is said and asked again, never silently
# turned into the recommended value.
function Read-JuicerFpsInput {
    while ($true) {
        $f = (Read-JuicerChoice 'FPS (Intro: el recomendado)').Trim()
        if (-not $f) { return 0 }
        $n = 0.0
        if ($f -match '^\d+([.,]\d+)?$' -and [double]::TryParse($f.Replace(',', '.'), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$n)) {
            $r = [Math]::Round($n, [MidpointRounding]::AwayFromZero)
            if ($r -ge 20 -and $r -le 1000) { return [int]$r }
        }
        Write-JuicerWrapped 'FPS no válido: escribe un número entero de 20 a 1000.' 2 'Yellow'
    }
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
        # [long] with TryParse: a huge number is ignored instead of throwing, and a range is
        # clamped to 1..Max before it is expanded so «1-2000000000» cannot build a giant array.
        [long]$a = 0
        [long]$b = 0
        if ($part -match '^(\d+)-(\d+)$') {
            if ([long]::TryParse($Matches[1], [ref]$a) -and [long]::TryParse($Matches[2], [ref]$b)) {
                $lo = [Math]::Max(1L, [Math]::Min($a, $b))
                $hi = [Math]::Min([long]$Max, [Math]::Max($a, $b))
                if ($lo -le $hi) { $out += [int]$lo..[int]$hi }
            }
        } elseif ($part -match '^\d+$') {
            if ([long]::TryParse($part, [ref]$a) -and $a -ge 1 -and $a -le $Max) { $out += [int]$a }
        }
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
        Pendiente = @('[>>]', 'Yellow')
    }
    $notes = @{ YaEstaba = 'ya estaba así'; NoAplica = 'no aplica'; NadaQueDeshacer = 'nada que deshacer'; Pendiente = 'al cerrar el juego' }
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
        if ($f.Chart) { Write-Host ('     ' + (Format-JuicerSparkline $f.Chart.Series $f.Chart.TargetMs)) -ForegroundColor Cyan }
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
            default { Write-JuicerInvalidChoice $_ }
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
            # Intro alone just redraws, but a closed input can never answer: leave.
            default { if ($script:InputClosed) { return }; Write-JuicerInvalidChoice $_ }
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
            Write-Host ('{0}, {1} por aplicar' -f (Format-JuicerCount $set.Count 'ajuste'), $pending) -ForegroundColor DarkGray
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
        if (-not (Confirm-JuicerAction "¿Aplicar $(Format-JuicerCount $todo.Count 'ajuste')?")) { continue }
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
        # On first, then the ones Windows measured slowing the boot (slowest first).
        $items = @(Get-JuicerStartupReview | Sort-Object { -not $_.Enabled }, { -[double]$_.BootDelay }, { $_.Name })
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
            Write-Host ('{0,-14}' -f $(if ($i.Verdict) { $i.Verdict.ToLowerInvariant() } else { '' })) -ForegroundColor $(if ($i.Verdict) { $script:StartupVerdictColors[$i.Verdict] } else { 'Gray' }) -NoNewline
            # What Windows measured (Diagnostics-Performance); nothing when it has no data.
            Write-Host (Format-JuicerBootDelay $i.BootDelay) -ForegroundColor $(if (Test-JuicerBootDelaySlow $i.BootDelay) { 'Yellow' } else { 'DarkGray' })
            if ($i.Why) { Write-JuicerWrapped $i.Why 12 'Gray' }
            $cmd = $i.Command
            if ($cmd.Length -gt $w + 30) { $cmd = $cmd.Substring(0, $w + 29) + '…' }
            Write-Host "            $cmd" -ForegroundColor DarkGray
        }
        Write-Host ''
        if (@($items | Where-Object { $_.BootDelay }).Count -gt 0) { Write-JuicerWrapped '«+N s»: lo que Windows midió que ese programa retrasó el arranque en los últimos 30 días. Sin cifra, Windows no ha registrado retraso.' 2 'DarkGray' }
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
            @('0', 'Tus juegos', 'los encuentra solos: frame pacer y GPU en un paso'),
            @('1', 'Exclusiones de Defender', 'cargas más rápidas en tus bibliotecas (Extremo)'),
            @('2', 'Configurar un juego', 'GPU potente y prioridad por encima de lo normal para un .exe'),
            @('3', 'Juegos configurados', 'ver y deshacer'),
            @('4', 'Medir FPS y frametimes', 'media, 1 % bajo, tirones y qué limita, con PresentMon'),
            @('5', 'Frame pacer', 'un ritmo por juego que se aplica solo, según tu monitor, y se calibra')
        )
        $c = Read-JuicerChoice 'Elige, Intro para volver'
        switch ($c) {
            '0' { Show-JuicerGameList }
            '1' { Show-JuicerDefenderLibraries }
            '2' { Show-JuicerConfigureGame }
            '3' { Show-JuicerConfiguredGames }
            '4' { Show-JuicerFrameMeasure }
            '5' { Show-JuicerLimiter }
            '' { return }
            default { Write-JuicerInvalidChoice $_ }
        }
    }
}

function Write-JuicerGameList {
    param([object[]]$Games)
    $n = 0
    foreach ($g in $Games) {
        $n++
        Write-Host ('  {0,3}. ' -f $n) -NoNewline
        Write-Host ('{0,-34} ' -f $(if ($g.Name.Length -gt 34) { $g.Name.Substring(0, 33) + '…' } else { $g.Name })) -ForegroundColor White -NoNewline
        Write-Host ('{0,-12} ' -f $g.Launcher) -ForegroundColor DarkGray -NoNewline
        $st = Format-JuicerGameStatus $g
        Write-Host $st -ForegroundColor $(if ($st -eq 'sin configurar') { 'DarkGray' } else { 'Green' }) -NoNewline
        if ($g.New) { Write-Host '  nuevo' -ForegroundColor Yellow -NoNewline }
        if ($g.Hidden) { Write-Host '  oculto' -ForegroundColor DarkGray -NoNewline }
        Write-Host ''
    }
}

function Show-JuicerGameList {
    $showHidden = $false
    while ($true) {
        Write-JuicerHeader 'Tus juegos'
        Write-Host '  Buscando juegos…' -ForegroundColor DarkGray
        $all = @(Get-JuicerGameStatus @(Get-JuicerGames -IncludeHidden))
        $hiddenCount = @($all | Where-Object { $_.Hidden }).Count
        if ($hiddenCount -eq 0) { $showHidden = $false }
        # Hidden ones («no es un juego») only show when asked, so the numbers are of what is listed.
        $games = @($all | Where-Object { $showHidden -or -not $_.Hidden })
        Write-JuicerHeader 'Tus juegos'
        if ($games.Count -eq 0 -and $hiddenCount -eq 0) { Write-JuicerWrapped 'No he encontrado juegos de Steam, Epic, GOG, Xbox, EA, Ubisoft, Battle.net ni Riot.' 2 'Yellow'; Wait-JuicerKey; return }
        if ($games.Count -eq 0) { Write-JuicerWrapped 'Todos tus juegos están ocultos.' 2 'Yellow' }
        Write-JuicerGameList $games
        Write-Host ''
        Write-JuicerWrapped 'Elige juegos por número (1,3,5-8, o «t» para todos) y luego qué hacer. «Optimizar» pone el límite de FPS para tu monitor y, con dos gráficas, la dedicada; se aplica solo cada vez que los abras.' 2 'Gray'
        if ($hiddenCount -gt 0) { Write-JuicerWrapped $(if ($showHidden) { 'O: volver a ocultar los ocultos.' } else { "O: mostrar los $hiddenCount ocultos." }) 2 'DarkGray' }
        $pick = Read-JuicerChoice 'Juegos (Intro para volver)'
        if (-not $pick) { return }
        if ($pick -match '^[oO]$' -and $hiddenCount -gt 0) { $showHidden = -not $showHidden; continue }
        if ($games.Count -eq 0) { continue }
        $nums = if ($pick -match '^[tT]') { 1..$games.Count } else { Get-JuicerNumbers $pick $games.Count }
        if (@($nums).Count -eq 0) { continue }
        # «t» is every game that counts: the hidden ones stay out even when they are shown.
        $sel = if ($pick -match '^[tT]') { @($games | Where-Object { -not $_.Hidden }) } else { @($nums | ForEach-Object { $games[$_ - 1] }) }
        if ($sel.Count -eq 0) { continue }
        Write-JuicerMenu @(
            @('H', 'No es un juego: ocultar', 'lo saca de esta lista y de «Optimizar todos»; no borra nada'),
            @('M', 'Volver a mostrar', 'los que ocultaste'),
            @('O', 'Optimizar', 'límite de FPS recomendado y GPU dedicada si hay dos'),
            @('F', 'Sólo límite de FPS', 'el recomendado o el que digas'),
            @('P', 'Prioridad por encima de lo normal', 'no «alta»: con alta, el equipo se puede congelar'),
            @('Q', 'Quitar lo de Win Juicer', 'límite, GPU y prioridad'),
            @('C', 'Consejos', 'qué poner dentro de cada juego para tu gráfica y tu monitor')
        )
        $key = (Read-JuicerChoice).ToUpperInvariant()
        if ($key -eq 'C') {
            foreach ($g in $sel) {
                Write-Host ''
                Write-JuicerFindings @(Get-JuicerGameTipsHere $g)
                # The pacer's side of it: anti-cheat, why the rate, what holds it down (Reflex included), what was put in.
                Write-JuicerGamePacerInfo $g
            }
            Wait-JuicerKey
            continue
        }
        if ($key -in 'H', 'M') {
            foreach ($g in $sel) { Set-JuicerGameHidden $g.Id ($key -eq 'H') }
            Write-JuicerWrapped $(if ($key -eq 'H') { "Oculto$(if ($sel.Count -ne 1) { 's' }): $(($sel | ForEach-Object { $_.Name }) -join ', '). Ya no salen en la lista ni en «Optimizar todos»." } else { "Vuelve$(if ($sel.Count -ne 1) { 'n' }) a mostrarse: $(($sel | ForEach-Object { $_.Name }) -join ', ')." }) 2 'Green'
            Wait-JuicerKey
            continue
        }
        $what = @{ O = 'Recomendado'; F = 'Fps'; P = 'Prioridad'; Q = 'Quitar' }[$key]
        if (-not $what) { Write-JuicerInvalidChoice $key; continue }
        $fps = 0
        if ($what -eq 'Fps') { $fps = Read-JuicerFpsInput }
        # Games picked one by one are what the user asked for, even one Win
        # Juicer protected after it failed; «t» (all of them) leaves those alone.
        Show-JuicerResults @(Invoke-JuicerGameSetup $sel $what $fps -Force:($pick -notmatch '^[tT]'))
    }
}

# Everything the pacer knows about one game, for the console: the anti-cheat
# note, the automatic rate and why that number, what holds it down, what was put
# in the game, and an offer to measure it when it never was. Game is the
# gallery's (ExeName, Name, Dir, Exe); a game known only by its .exe name works.
function Write-JuicerGamePacerInfo {
    param([Parameter(Mandatory)][hashtable]$Game, [hashtable]$Monitor)
    $exe = ConvertTo-JuicerExeName ([string]$(if ($Game.ExeName) { $Game.ExeName } else { $Game.Exe }))
    if (-not $Monitor) { try { $Monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" } }
    $name = if ($Game.Name) { [string]$Game.Name } else { $exe }
    Write-Host ''
    Write-Host "  $name ($exe)" -ForegroundColor White
    $backend = Get-JuicerFpsBackend
    $ac = ''
    try { $ac = Get-JuicerGameAntiCheat $(if ($Game.Dir) { [string]$Game.Dir } else { '' }) $exe } catch { Write-JuicerLog "Sin antitrampas de ${exe}: $_" }
    $note = Get-JuicerAntiCheatNote $ac $backend
    if ($note) { Write-JuicerWrapped $note 4 $(if ($backend -eq 'rtss') { 'Yellow' } else { 'Gray' }) }
    $auto = $null
    try { $auto = Get-JuicerRecommendedFps $exe $Monitor -Automatic } catch { Write-JuicerLog "Sin ritmo recomendado para ${exe}: $_" }
    if ($auto) {
        Write-JuicerWrapped ('Ritmo automático: {0} FPS{1}.' -f $auto.Fps, $(if ($auto.Calibrated) { ' (calibrado para tu PC)' } else { ' (para tu pantalla)' })) 4 'Gray'
        # Under the rate: why that number.
        Write-JuicerWrapped "¿Por qué este número? $($auto.Why)" 6 'DarkGray'
    }
    $manual = Get-JuicerPacerFps $exe
    if ($manual -gt 0) { Write-JuicerWrapped "Ritmo elegido por ti: $manual FPS." 4 'Gray' }
    $pacerState = $null
    try { $pacerState = & (Get-JuicerBackend).PacerState } catch { Write-JuicerLog "Sin el estado de otros limitadores: $_" }
    $cap = $null
    try { $cap = Get-JuicerEffectiveCap $exe -Monitor $Monitor -State $pacerState } catch { Write-JuicerLog "Sin ritmo efectivo de ${exe}: $_" }
    if ($cap) { Write-JuicerWrapped (Format-JuicerEffectiveCap $cap) 4 $(if ($cap.Effective -lt $cap.Requested) { 'Yellow' } else { 'Gray' }) }
    $reflex = $null
    try { $reflex = Get-JuicerReflexCapNoteHere $exe $Monitor } catch { Write-JuicerLog "Sin nota de Reflex: $_" }
    if ($reflex) { Write-JuicerWrapped $reflex 4 'Yellow' }
    $applied = Format-JuicerPacerApplied $exe -Console
    if ($applied) { Write-Host ''; Write-JuicerWrapped $applied 4 'Gray' }
    if (Test-JuicerPacerMinimal $exe) { Write-JuicerWrapped 'Modo prudente activado: sólo el límite de FPS.' 4 'Gray' }
    # Never measured: say how, and offer it.
    if (-not (Get-JuicerPreviousFrameResult $exe)) {
        Write-JuicerWrapped 'Todavía no has medido este juego: medirlo dice si tu PC sostiene el ritmo y qué lo limita.' 4 'DarkGray'
        if ($script:Interactive -and (Confirm-JuicerAction '¿Medir este juego ahora?')) {
            Write-JuicerWrapped $script:CalibrateAdvice 2 'Gray'
            try {
                $f = @(Invoke-JuicerFrameCapture -Seconds 60 -Delay 10 -Process $exe -OnStatus ${function:Write-JuicerStatusLine})
                Write-Host ''
                Write-JuicerFindings $f
            } catch {
                Write-Host ''
                Write-JuicerWrapped "No se pudo medir: $_" 2 'Yellow'
            }
        }
    }
}

# Restores the newest copy of NVIDIA's profile store, after saying what it does.
# The CLI and the pacer menu share it. Returns the exit code.
function Invoke-JuicerNvRestoreCli {
    $backups = @(Get-JuicerNvBackups)
    if ($backups.Count -eq 0) {
        Write-JuicerWrapped 'No hay ninguna copia de los perfiles de NVIDIA: Win Juicer la hace sola antes de su primer cambio en ellos, y todavía no ha hecho ninguno.' 2 'Yellow'
        return 1
    }
    Write-JuicerWrapped ('Copia de ' + $backups[0].Date + ': ' + ($backups[0].Files -join ', ') + '.') 2 'Gray'
    Write-JuicerWrapped (Get-JuicerNvRestoreWarning) 2 'Yellow'
    if (-not (Confirm-JuicerAction '¿Restaurar los perfiles de NVIDIA desde esa copia?')) { Write-JuicerWrapped 'No se ha cambiado nada.' 2 'Gray'; return 0 }
    $r = Restore-JuicerNvProfiles $backups[0].Path
    Write-JuicerWrapped $r.Message 2 $(if ($r.Ok) { 'Green' } else { 'Yellow' })
    if ($r.Ok) { 0 } else { 1 }
}

function Show-JuicerLimiter {
    # What waited for a game to close, what an older recipe left behind, and
    # a game that started failing after it was optimized.
    $fixes = @(@(Invoke-JuicerPacerPending) + @(Repair-JuicerGameSetups) | Where-Object { $_.Outcome -in 'Aplicado', 'Deshecho', 'Error' })
    $safety = Update-JuicerGameSafety
    while ($true) {
        Write-JuicerHeader 'Frame pacer'
        if ($fixes.Count -gt 0) { Show-JuicerResults $fixes; $fixes = @() }
        foreach ($p in @($safety.Protected)) { Write-JuicerWrapped (Format-JuicerSafeNote (Get-JuicerGameSafe $p.Exe) $p.Name) 2 'Yellow'; Write-Host '' }
        $safety = @{ Protected = @() }
        $waiting = @(Get-JuicerPacerPending)
        if ($waiting.Count -gt 0) { Write-JuicerWrapped "Esperando a que cierres $($waiting -join ', '): Win Juicer no toca el perfil de un juego abierto. Se aplicará la próxima vez que abras este menú con el juego cerrado." 2 'Yellow' }
        $m = $null
        try { $m = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
        $pacer = Read-JuicerPacer
        $backend = Get-JuicerFpsBackend
        Write-JuicerWrapped ('Marca el ritmo con: ' + (Format-JuicerFpsBackend $backend) + '.' + $(if (-not $backend) { ' Instálalo desde «Instalar programas» (9) del menú principal.' } else { '' })) 2 'Gray'
        if ($m) {
            $cap = Get-JuicerFpsCap ([int]$m.Display.Hz) (Resolve-JuicerMonitorUse $m) $null $(if ($m.Vrr) { [int]$m.Vrr.Min } else { 0 }) @() ([double]$m.Display.ExactHz) (Get-JuicerVrrTop $m)
            Write-JuicerWrapped ('Tu pantalla: ' + (Format-JuicerMonitor $m) + '. Cómo la usas: ' + (Get-JuicerMonitorModes)[$m.Mode] + ". Ritmo recomendado: $($cap.Fps) FPS. $($cap.Why)") 2 'Gray'
        }
        $limits = @(Get-JuicerFpsLimits)
        # Read once for the whole list: the other limiters, and the card's maker.
        $otherLimiters = $null
        try { $otherLimiters = & (Get-JuicerBackend).PacerState } catch { Write-JuicerLog "Sin el estado de otros limitadores: $_" }
        $gpuVendor = Get-JuicerMainGpuVendor
        Write-Host ''
        $n = 0
        foreach ($g in $limits) {
            $n++
            $fps = if ($g.Exact -gt 0 -and $g.Backend -eq 'rtss') { '{0:N2} FPS' -f $g.Exact } elseif ($g.Fps) { "$($g.Fps) FPS" } else { 'sin ritmo ahora' }
            # The one for this monitor setup (else the latest of another, which is not used).
            $cal = Select-JuicerCalibration $pacer.Calibrated[$g.Exe] $m
            # Its age only when it is the calibration in force on this monitor, used this way, with no rate of yours over it.
            $calState = Get-JuicerCalibrationState $g.Exe $cal $m $pacer
            $changes = @()
            if ($calState -eq 'Activa' -and $cal.Fingerprint -is [hashtable]) { try { $changes = @(Get-JuicerCalibrationChanges $cal.Fingerprint (Get-JuicerCalibrationFingerprint $g.Exe)) } catch { Write-JuicerLog "Sin huella de $($g.Exe): $_" } }
            $age = $(if ($calState -eq 'Activa') { Get-JuicerCalibrationAge ([string]$cal.Date) ([int]$cal.Fps) -Changes $changes } else { $null })
            $calText = if ($age) { " ($($age.Text))" } elseif ($calState -eq 'OtroMonitor') { ' (calibración de otro monitor o modo)' } elseif ($calState -eq 'Activa') { ' (calibrado)' } else { '' }
            Write-Host ('  {0,2}. {1}: {2}{3}{4}' -f $n, $g.Exe, $fps, $calText, $(if ((Get-JuicerPacerPriority $g.Exe) -eq 'Latencia') { ' [latencia]' } else { '' }))
            if ($age -and $age.Stale) { Write-JuicerWrapped $age.Hint 6 'DarkGray' }
            # What the game really gets, when something sits under what is asked.
            if ($g.Fps) {
                $eff = $null
                try { $eff = Get-JuicerEffectiveCap $g.Exe -Requested ([int]$g.Fps) -Monitor $m -State $otherLimiters -Backend $backend -GpuVendor $gpuVendor } catch { Write-JuicerLog "Sin ritmo efectivo de $($g.Exe): $_" }
                if ($eff -and $eff.Effective -lt $eff.Requested) { Write-JuicerWrapped (Format-JuicerEffectiveCap $eff) 6 'Yellow' }
            }
        }
        if ($n -eq 0) { Write-Host '  Ningún juego con frame pacer todavía.' -ForegroundColor DarkGray }
        $allMonitors = @()
        try { $allMonitors = @(Get-JuicerMonitors) } catch { Write-JuicerLog "Sin monitores: $_" }
        $conflicts = @(Get-JuicerPacerConflicts $otherLimiters (Get-JuicerFpsBackend) $limits $m $gpuVendor $allMonitors)
        if ($conflicts.Count -gt 0) { Write-Host ''; Write-JuicerFindings $conflicts }
        Write-Host ''
        Write-JuicerMenu @(
            @('A', 'Añadir un juego', 'por nombre del .exe, con el ritmo recomendado o el tuyo'),
            @('M', 'Añadir los juegos medidos', (@(Get-JuicerUnlimitedGames) -join ', ')),
            @('C', 'Calibrar un juego', 'lo mide 60, 90 o 120 s con su ritmo, te propone otro y, si aceptas, lo ajusta'),
            @('P', 'Prioridad de un juego', 'fluidez, o latencia mínima (por encima de los Hz al calibrar)'),
            @('Q', 'Quitar el frame pacer a un juego', 'por número'),
            @('U', 'Cómo usas tu monitor', 'VRR, ELMB/DyAc u otro estroboscopio, o frecuencia fija'),
            @('D', 'Tu monitor es OLED', $(if ($m) { $o = Get-JuicerMonitorOledOverride $m; 'ahora: ' + $(if ($null -eq $o) { 'según su nombre (' + $(if (Test-JuicerMonitorOled $m) { 'OLED' } else { 'no OLED' }) + ')' } elseif ($o) { 'sí, lo dices tú' } else { 'no, lo dices tú' }) } else { 'si el nombre no lo delata' })),
            @('E', 'Motor', "ahora: $($pacer.Engine); con estrobo, RivaTuner admite décimas"),
            @('O', 'Olvidar las calibraciones', 'volver al ritmo recomendado'),
            @('R', 'Recalcular los ritmos', 'con el modo y la frecuencia de ahora'),
            @('G', 'Ver un juego', 'qué se ha puesto, por qué ese ritmo, qué lo limita y si tiene antitrampas'),
            @('T', 'Modo prudente de un juego', 'sólo el límite, sin tocar la V-Sync ni la cola de fotogramas'),
            @('N', 'Restaurar los perfiles de NVIDIA', 'la copia que se hizo antes del primer cambio (sustituye todos los perfiles)')
        )
        switch ((Read-JuicerChoice 'Elige, Intro para volver').ToUpperInvariant()) {
            'A' {
                $exe = Read-JuicerChoice 'Nombre del .exe (por ejemplo cs2.exe)'
                if (-not $exe) { continue }
                $fps = Read-JuicerFpsInput
                Show-JuicerResults @(if ($fps -gt 0) { Set-JuicerPacerFps $exe $fps $m } else { Add-JuicerFpsLimit $exe 0 $m })
            }
            'M' { Show-JuicerResults @(foreach ($g in @(Get-JuicerUnlimitedGames)) { Add-JuicerFpsLimit $g }) }
            'C' {
                $q = Read-JuicerChoice 'Número del juego'
                if (-not ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $limits.Count)) { continue }
                $calExe = $limits[[int]$q - 1].Exe
                Write-JuicerWrapped $script:CalibrateAdvice 2 'Gray'
                $secs = Read-JuicerCalibrateSeconds
                try {
                    $f = @(Invoke-JuicerPacerCalibration -Exe $calExe -Seconds $secs -OnStatus ${function:Write-JuicerStatusLine} -Monitor $m)
                    Write-Host ''
                    Write-JuicerFindings $f
                    $proposal = Get-JuicerCalibrationProposal $f
                    if ($proposal) { Invoke-JuicerConsoleCalibration $proposal $m }
                } catch {
                    Write-Host ''
                    Write-JuicerWrapped "No se pudo calibrar: $_" 2 'Yellow'
                }
                Wait-JuicerKey
            }
            'P' {
                $q = Read-JuicerChoice 'Número del juego'
                if (-not ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $limits.Count)) { continue }
                Write-JuicerWrapped 'Fluidez: el ritmo más estable dentro de lo que el monitor enseña entero. Latencia: al calibrar, si el juego da para el doble de los Hz o más, sube ahí sin sincronización vertical (con cortes de imagen); para juegos competitivos.' 2 'Gray'
                $p = @{ 'F' = 'Fluidez'; 'L' = 'Latencia' }[(Read-JuicerChoice 'F = fluidez, L = latencia').ToUpperInvariant()]
                if ($p) { Show-JuicerResults @(Set-JuicerPacerPriority $limits[[int]$q - 1].Exe $p $m) }
            }
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
                    if ($limits.Count -gt 0 -and (Confirm-JuicerAction '¿Recalcular con este modo el ritmo de los juegos que ya lo tienen?')) { Show-JuicerResults @(Update-JuicerFpsLimits $m) }
                }
            }
            'D' {
                if (-not $m) { Write-JuicerWrapped 'No se pudo leer el monitor.' 2 'Yellow'; Wait-JuicerKey; continue }
                Write-Host ''
                Write-Host '  1. Según su nombre (automático)'
                Write-Host '  2. Sí, es OLED'
                Write-Host '  3. No, no es OLED'
                $q = Read-JuicerChoice 'Número'
                if ($q -in '1', '2', '3') { [void](Set-JuicerMonitorOled $m $(switch ($q) { '2' { $true } '3' { $false } default { $null } })) }
            }
            'E' {
                $engines = @(Get-JuicerPacerEngines)
                Write-Host ''
                Write-Host '  1. Automático (el driver si hay NVIDIA)'
                Write-Host ('  2. Driver de NVIDIA{0}' -f $(if ($engines -notcontains 'nvidia') { ' (no disponible)' } else { '' }))
                Write-Host ('  3. RivaTuner, admite décimas{0}' -f $(if ($engines -notcontains 'rtss') { ' (no instalado)' } else { '' }))
                $q = Read-JuicerChoice 'Número'
                $e = @{ '1' = 'Auto'; '2' = 'nvidia'; '3' = 'rtss' }[$q]
                if (-not $e) { continue }
                try { Show-JuicerResults @(Set-JuicerPacerEngine $e $m) } catch { Write-JuicerWrapped "$_" 2 'Yellow'; Wait-JuicerKey }
            }
            'G' {
                $q = Read-JuicerChoice 'Número del juego'
                if (-not ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $limits.Count)) { continue }
                $one = $limits[[int]$q - 1]
                # The gallery knows its folder (anti-cheat); a game added by name only has none.
                $game = @(Get-JuicerGames -IncludeHidden | Where-Object { $_.ExeName -eq $one.Exe }) | Select-Object -First 1
                if (-not $game) { $game = @{ ExeName = $one.Exe; Name = $one.Exe; Dir = ''; Exe = $one.Exe } }
                Write-JuicerGamePacerInfo $game $m
                Wait-JuicerKey
            }
            'T' {
                $q = Read-JuicerChoice 'Número del juego'
                if (-not ($q -match '^\d+$' -and [int]$q -ge 1 -and [int]$q -le $limits.Count)) { continue }
                $one = $limits[[int]$q - 1].Exe
                $on = -not (Test-JuicerPacerMinimal $one)
                Write-JuicerWrapped 'Modo prudente: el frame pacer pone sólo el límite de FPS y deja la V-Sync y la cola de fotogramas como las ponga el juego. Para un juego que se congela o se cierra con la receta completa.' 2 'Gray'
                if (Confirm-JuicerAction "¿$(if ($on) { 'Activar' } else { 'Quitar' }) el modo prudente de ${one}?") {
                    Show-JuicerResults @(Set-JuicerPacerMinimal $one $on $m)
                    Write-JuicerWrapped "Modo prudente de ${one}: $(if ($on) { 'activado' } else { 'desactivado' })." 2 'Green'
                    Wait-JuicerKey
                }
            }
            'N' { [void](Invoke-JuicerNvRestoreCli); Wait-JuicerKey }
            'O' { Clear-JuicerPacerCalibration; Show-JuicerResults @(Update-JuicerFpsLimits $m) }
            'R' { Show-JuicerResults @(Update-JuicerFpsLimits $m) }
            '' { return }
            default { Write-JuicerInvalidChoice $_ }
        }
    }
}

# What to do before a calibration or a measurement starts, said wherever one starts.
$script:CalibrateAdvice = 'Abre el juego y elige tu escena más exigente y habitual (no un menú), sin Alt-Tab, durante toda la medida. Tienes 10 segundos para volver al juego; juega con normalidad hasta que acabe.'

# 60, 90 or 120 seconds: more is steadier (a longer scene, more spikes seen).
function Read-JuicerCalibrateSeconds {
    $s = Read-JuicerChoice 'Duración de la medida: 1 = 60 s, 2 = 90 s, 3 = 120 s (Intro = 60)'
    switch ($s) { '2' { 90 } '3' { 120 } default { 60 } }
}

# What follows a calibration that proposes a new rate: nothing is changed until it is accepted; then
# the person may verify it (45 s at the new rate), and if it still misses a lower one is proposed,
# to accept the same way. At most four rounds.
function Invoke-JuicerConsoleCalibration {
    param([hashtable]$Proposal, [hashtable]$Monitor)
    $p = $Proposal
    for ($round = 0; $round -lt 4 -and $p; $round++) {
        Write-Host ''
        Write-JuicerWrapped ('Propuesta: {0} → {1} FPS. Hasta que aceptes, no se cambia nada.' -f $p.Old, $p.New) 2 'Cyan'
        if (-not (Confirm-JuicerAction "¿Aplicar $($p.New) FPS a $($p.Exe)?")) { Write-JuicerWrapped 'No se ha cambiado nada.' 2 'Gray'; return }
        $applied = @(Save-JuicerPacerCalibration $p $Monitor)
        Write-Host ''
        Write-JuicerFindings $applied
        if (-not $script:Interactive) { return }
        $a = Read-JuicerChoice 'Verificar (45 s): con el juego ya arrancado con el ritmo nuevo (si estaba abierto, ciérralo y ábrelo), escribe V; Intro para dejarlo así'
        if ($a.ToUpperInvariant() -ne 'V') { return }
        $v = Invoke-JuicerPacerVerify $p -OnStatus ${function:Write-JuicerStatusLine} -Monitor $Monitor
        Write-Host ''
        Write-JuicerFindings @($v.Findings)
        $p = $v.NextProposal
    }
}

# One line that rewrites itself: a countdown, not a scrolling list.
function Write-JuicerStatusLine {
    param([string]$Text)
    Write-Host ("`r  " + $Text).PadRight(76) -NoNewline -ForegroundColor DarkGray
}

function Show-JuicerFrameMeasure {
    Write-JuicerHeader 'Medir FPS y frametimes'
    Write-JuicerWrapped ($script:CalibrateAdvice + ' La primera vez descarga PresentMon, de Intel.') 2 'Gray'
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
        Write-JuicerWrapped 'No he encontrado bibliotecas de Steam, Epic, GOG, Xbox, EA, Ubisoft, Battle.net ni Riot. Puedes excluir otra carpeta escribiendo su ruta.' 2
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
        try { $chosen += New-JuicerDefenderTweak $path } catch { Write-Host "  $($_.Exception.Message)" -ForegroundColor Red; Wait-JuicerKey; return }
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
    # A frame pacer goes through Remove-JuicerFpsLimit (as in the window): it also clears its
    # pending state and waits for the game to close if it is open; a plain Undo would not.
    $results = @(Get-JuicerNumbers $c $entries.Count | ForEach-Object {
            $id = [string]$entries[$_ - 1].Id
            if ($id -like 'fps:*') { Remove-JuicerFpsLimit $id.Substring(4) } else { Undo-JuicerTweak $id }
        })
    Show-JuicerResults $results
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
                Write-Host '  Calculando cuánto se liberaría (no borra nada todavía)…' -ForegroundColor DarkGray
                $preview = Get-JuicerCleanupPreview
                foreach ($l in (Format-JuicerCleanupPreview $preview)) { Write-JuicerWrapped $l 2 'Gray' }
                if (-not (Confirm-JuicerAction '¿Limpiar esto? No se puede deshacer')) { continue }
                Write-Host ''
                $total = [int64]0
                foreach ($r in (Invoke-JuicerCleanup)) {
                    $what = if ($r.Note) { $r.Note } elseif ($r.Freed -lt 0) { 'vaciada' } else { Format-JuicerBytes $r.Freed }
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
                $warn = Get-JuicerOptimizeWarning
                if ($warn -and -not (Confirm-JuicerAction "$warn ¿Seguir")) { continue }
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
                Write-JuicerWrapped 'Las carpetas antiguas quedan renombradas como .old-fecha: sólo se guarda la última copia, la anterior se borra.' 2 'DarkGray'
                Wait-JuicerKey
            }
            '' { return }
            default { Write-JuicerInvalidChoice $_ }
        }
    }
}

# Restores the previous journal (diario.1.json) after setting the current one aside. Prints
# what happened; returns whether it was restored. A readable current journal is only
# replaced after a question (-Si answers it): the copy is one step older and loses the last changes.
function Invoke-JuicerJournalRestore {
    $backup = Get-JuicerJournalBackupPath
    if (-not (Test-JuicerJournalFile $backup)) {
        Write-JuicerWrapped 'No hay una copia utilizable del diario (diario.1.json): no hay nada que restaurar.' 2 'Yellow'
        return $false
    }
    $readable = $true
    try { [void](Read-JuicerJournal) } catch { $readable = $false }
    if ($readable -and (Test-Path -LiteralPath (Get-JuicerJournalPath))) {
        Write-JuicerWrapped 'El diario actual se lee bien. La copia anterior es un paso más antigua: restaurarla olvida el último cambio guardado (el actual queda aparte como diario.dañado.json).' 2 'Yellow'
        if (-not (Confirm-JuicerAction '¿Restaurar la copia anterior de todos modos?')) { return $false }
    }
    $r = Restore-JuicerJournal
    Write-JuicerWrapped $r.Message 2 $(if ($r.Ok) { 'Green' } else { 'Yellow' })
    [bool]$r.Ok
}

# What Windows has undone, for the screens: the count, the list and how to put it back.
function Write-JuicerDrift {
    param([object[]]$Drift)
    $sum = Format-JuicerDriftSummary $Drift
    if (-not $sum.Title) { return }
    Write-Host "  $($sum.Title)" -ForegroundColor Yellow
    foreach ($l in $sum.Lines) { Write-JuicerWrapped $l 4 'Gray' }
}

# Puts back what Windows undid, the same way as anything else that is applied: the Extremo
# ones asked one by one, a restore point first.
function Invoke-JuicerDriftReapply {
    param([object[]]$Drift, [switch]$Simulate, [switch]$AcceptRisk, [switch]$NoRestorePoint)
    # A game's cap the driver wiped is not a catalog tweak: it goes back through the limiter
    # (a game that is open waits for it to close), and has nothing to restore a point for.
    $fps = @($Drift | Where-Object { $_.Kind -eq 'Fps' })
    $tweaks = @($Drift | Where-Object { $_.Kind -ne 'Fps' } | ForEach-Object { $_.Tweak })
    $results = @()
    if ($tweaks.Count -gt 0) { $results += @(Invoke-JuicerTweakSet $tweaks -Simulate:$Simulate -AcceptRisk:$AcceptRisk -NoRestorePoint:$NoRestorePoint) }
    if ($fps.Count -gt 0) {
        if ($Simulate) {
            foreach ($f in $fps) { $results += New-JuicerResult @{ Id = $f.Id; Title = $f.Title; Reboot = 'No' } 'Simulado' 'Se volvería a poner el límite de FPS que el driver borró.' }
        } else {
            $results += @(Restore-JuicerWipedFpsLimits -Exe @($fps | ForEach-Object { [string]$_.Exe }))
        }
    }
    $results
}

# -Revisar: what Windows has undone since it was applied. With -Si, applies it again.
function Invoke-JuicerDriftCli {
    param([switch]$Apply, [switch]$Simulate, [switch]$AcceptRisk, [switch]$NoRestorePoint)
    $drift = @()
    try { $drift = @(Get-JuicerDrift) } catch { Write-Host "  $_" -ForegroundColor Red; return 1 }
    if ($drift.Count -eq 0) {
        Write-Host '  Todo lo que aplicó Win Juicer sigue en su sitio.' -ForegroundColor Green
        return 0
    }
    Write-Host ''
    Write-JuicerDrift $drift
    if (-not $Apply -and -not $Simulate) {
        Write-Host ''
        Write-JuicerWrapped 'Para volver a aplicarlos: WinJuicer.cmd -Revisar -Si (los Extremo, además, con -AceptoRiesgos). Con -Simular, qué cambiaría.' 2 'DarkGray'
        return 0
    }
    $results = @(Invoke-JuicerDriftReapply $drift -Simulate:$Simulate -AcceptRisk:$AcceptRisk -NoRestorePoint:$NoRestorePoint)
    Show-JuicerResults $results
    if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { return 1 }
    0
}

function Show-JuicerUndo {
    while ($true) {
        Write-JuicerHeader 'Deshacer'
        $journal = $null
        try {
            $journal = Read-JuicerJournal
        } catch {
            Write-JuicerWrapped "$_" 2 'Red'
            if (Test-JuicerJournalFile (Get-JuicerJournalBackupPath)) {
                if (Confirm-JuicerAction '¿Restauro la copia anterior del diario? El dañado queda aparte, sin borrarlo') {
                    if (Invoke-JuicerJournalRestore) { Wait-JuicerKey; continue }
                }
            }
            Wait-JuicerKey
            return
        }
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
        $drift = @()
        try { $drift = @(Get-JuicerDrift $journal) } catch { Write-JuicerLog "No se pudo revisar lo que Windows ha deshecho: $_" }
        if ($drift.Count -gt 0) { Write-JuicerDrift $drift; Write-Host '' }
        Write-JuicerWrapped "Deshacer devuelve cada ajuste a como estaba antes de que Win Juicer lo tocara por primera vez. El diario está en $(Get-JuicerJournalPath)." 2 'DarkGray'
        $prompt = 'Números a deshacer, T para todo, '
        if ($drift.Count -gt 0) { $prompt += "V para volver a aplicar $(Format-JuicerCount $drift.Count 'cambio' 'cambios') que Windows deshizo, " }
        $c = Read-JuicerChoice ($prompt + 'Intro para volver')
        if ($c -eq '') { return }
        if ($c -match '^[vV]$' -and $drift.Count -gt 0) {
            if (Confirm-JuicerAction "¿Volver a aplicar $(Format-JuicerCount $drift.Count 'ajuste')?") { Show-JuicerResults @(Invoke-JuicerDriftReapply $drift); Wait-JuicerKey }
            continue
        }
        if ($c -match '^[tT]$') {
            Write-Host ''
            Write-JuicerWrapped (Format-JuicerUndoAllConfirm $journal -NoQuestion) 2 'Gray'
            if (Confirm-JuicerAction $(if ($journal.Count -eq 1) { '¿Deshacer el cambio?' } else { "¿Deshacer los $($journal.Count) cambios?" })) { Show-JuicerResults @(Undo-JuicerAll); Wait-JuicerKey }
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
    $c = Read-JuicerChoice "¿Aplicar $(Format-JuicerCount $todo.Count 'ajuste')? S para aplicar, V para simular, Intro para volver"
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
                if ($a.Retired) { Write-JuicerWrapped "$($a.Retired): puede que no se pueda volver a instalar." 8 'Yellow' }
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
        if (-not (Confirm-JuicerAction "¿Quitar $(Format-JuicerCount $tweaks.Count 'app')?")) { continue }
        Show-JuicerResults (Invoke-JuicerTweakSet $tweaks)
        Wait-JuicerKey
    }
}

function Show-JuicerReinstallApps {
    Write-JuicerHeader 'Reinstalar apps quitadas'
    $journal = Read-JuicerJournal
    $removed = @(Get-JuicerRemovedApps) + @($journal | Where-Object { $_.Id -eq 'apps.onedrive' })
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

# --- Protección contra contenido adulto ---------------------------------------

function Write-JuicerShieldState {
    $i = Get-JuicerShieldInfo
    if (-not $i.Active) {
        Write-JuicerWrapped 'Protección contra contenido adulto: no activada.' 2 'Gray'
        return
    }
    $since = ''
    try { $since = ' desde el ' + ([datetime]$i.Since).ToString('d') } catch { Write-Verbose "Fecha ilegible: $($i.Since)" }
    Write-JuicerWrapped "Protección contra contenido adulto: ACTIVA$since, $($i.LevelTitle.ToLowerInvariant()), con $($i.ProviderTitle). No se puede desactivar." 2 'Green'
    $blocked = @(Format-JuicerShieldBlocked $i.Blocked)
    if ($blocked.Count -gt 0) { Write-JuicerWrapped ('Bloqueadas para siempre: ' + ($blocked -join ', ') + '.') 2 'Gray' }
    if ($i.Firewall -eq 'Otro') { Write-JuicerWrapped 'El cortafuegos lo lleva otro programa: los bloqueos del de Windows no se aplican, el filtro sí.' 2 'Yellow' }
}

# The list of blocked sites, said briefly: X, Reddit and Tumblr by name.
function Format-JuicerShieldBlocked {
    param($Blocked)
    if (-not $Blocked) { return }
    foreach ($p in @($Blocked.Presets)) { $script:ShieldPresets[$p].Title }
    @($Blocked.Sites)
}

# The check, line by line: what works, what does not and why, and a last word.
function Write-JuicerShieldCheck {
    Write-Host ''
    Write-Host '  Comprobando que la protección funciona…' -ForegroundColor DarkGray
    $checks = @(Get-JuicerShieldCheck)
    foreach ($c in $checks) {
        $mark = if ($c.Ok -eq $true) { @('[ok]', 'Green') } elseif ($c.Ok -eq $false) { @('[!!]', 'Red') } else { @('[??]', 'Yellow') }
        Write-Host "  $($mark[0]) " -ForegroundColor $mark[1] -NoNewline
        Write-Host $c.Title
        if ($c.Detail) { Write-JuicerWrapped $c.Detail 7 'Gray' }
    }
    $bad = @($checks | Where-Object { $_.Ok -eq $false })
    Write-Host ''
    if ($bad.Count -eq 0) { Write-JuicerWrapped 'Funciona. Si aun así una web carga, ciérrala, cierra el navegador del todo y vuelve a abrirlo.' 2 'Green' }
    else { Write-JuicerWrapped 'Corrige lo marcado con [!!] y vuelve a comprobarlo.' 2 'Yellow' }
    $bad.Count
}

function Write-JuicerShieldFixed {
    param($Fixed)
    foreach ($x in @($Fixed)) { Write-Host "  [ok] $x" -ForegroundColor Green }
}

# -ProteccionAdultos: Activar (at -NivelProteccion Estricto, the default, or
# Equilibrado; the user types ACTIVAR, or -Si), Subir (to estricta), Bloquear
# (-BloquearWeb, for good), Mantener (what its task runs) or Estado. There is
# no way to turn it off or lower it.
function Invoke-JuicerShieldCli {
    param([string]$What, [switch]$Yes, [string]$Level = '', [string[]]$Sites = @())
    switch ($What) {
        'Mantener' { [void](Repair-JuicerShield); return 0 }
        'Estado' { Write-JuicerShieldState; return 0 }
        'Comprobar' {
            if (-not (Test-JuicerShield)) { Write-JuicerWrapped 'La protección no está activada: -ProteccionAdultos Activar.' 2 'Yellow'; return 1 }
            if ((Write-JuicerShieldCheck) -gt 0) { return 1 }
            return 0
        }
        'Activar' {
            if (Test-JuicerShield) {
                Write-JuicerShieldState
                if ($Level -eq 'Estricto' -and (Get-JuicerShieldLevel) -lt 2) { Write-JuicerWrapped 'Para pasar a la estricta: -ProteccionAdultos Subir.' 2 'Gray' }
                return 0
            }
            $n = 2
            if ($Level -eq 'Equilibrado') { $n = 1 }
            elseif (-not $Level -and -not $Yes) {
                Write-JuicerWrapped 'Dos niveles. Estricta (la recomendada si es para dejar el porno): además de las webs para adultos cierra proxies, VPN y Reddit, quita las ventanas privadas y deja el DNS sólo al filtro. Equilibrada: las webs para adultos y los atajos más comunes; Reddit, las VPN y las ventanas privadas siguen. Se puede subir de equilibrada a estricta, nunca bajar.' 2 'Gray'
                $c = Read-JuicerChoice 'E = estricta (recomendada), Q = equilibrada, Intro para no activarla'
                if ($c -eq 'Q' -or $c -eq 'q') { $n = 1 } elseif ($c -ne 'E' -and $c -ne 'e') { Write-Host '  No se ha activado.'; return 0 }
            }
            Write-Host ''
            foreach ($l in (Get-JuicerShieldExplanation $n)) { Write-JuicerWrapped $l 2 'Gray'; Write-Host '' }
            # Typed, not a key that slips.
            if (-not $Yes -and (Read-JuicerChoice 'Escribe ACTIVAR para activarla para siempre (Intro para no hacerlo)') -cne 'ACTIVAR') {
                Write-Host '  No se ha activado.'
                return 0
            }
            Write-JuicerShieldFixed @(Enable-JuicerShield -Level $n)
            Write-JuicerShieldState
            Write-JuicerWrapped 'Cierra del todo los navegadores abiertos (Brave, Chrome y Edge siguen en segundo plano al cerrar la ventana: icono junto al reloj, «Salir»), o reinicia el PC.' 2 'Yellow'
            [void](Write-JuicerShieldCheck)
            return 0
        }
        'Subir' {
            if (-not (Test-JuicerShield)) { Write-JuicerWrapped 'La protección no está activada: -ProteccionAdultos Activar.' 2 'Yellow'; return 1 }
            if ((Get-JuicerShieldLevel) -ge 2) { Write-JuicerShieldState; return 0 }
            foreach ($l in (Get-JuicerShieldExplanation 2)) { Write-JuicerWrapped $l 2 'Gray'; Write-Host '' }
            if (-not $Yes -and (Read-JuicerChoice 'Escribe SUBIR para pasar a la estricta para siempre (Intro para no hacerlo)') -cne 'SUBIR') {
                Write-Host '  Sigue en la equilibrada.'
                return 0
            }
            Write-JuicerShieldFixed @(Enable-JuicerShield -Level 2)
            Write-JuicerShieldState
            return 0
        }
        'Bloquear' {
            if (-not (Test-JuicerShield)) { Write-JuicerWrapped 'La protección no está activada: -ProteccionAdultos Activar.' 2 'Yellow'; return 1 }
            $list = @($Sites | Where-Object { $_ })
            if ($list.Count -eq 0) {
                if ($Yes) { Write-JuicerWrapped 'Di qué webs con -BloquearWeb: X, Reddit, Tumblr o ejemplo.com, separadas por comas.' 2 'Yellow'; return 2 }
                $list = @((Read-JuicerChoice 'Web que bloquear (ejemplo.com), o X, Reddit o Tumblr; Intro para volver') -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
                if ($list.Count -eq 0) { return 0 }
            }
            $bad = @($list | Where-Object { $s = $_; -not @($script:ShieldPresets.Keys | Where-Object { $_ -eq $s }) -and @(ConvertTo-JuicerBlockHosts $s).Count -eq 0 })
            if ($bad.Count -gt 0) { Write-JuicerWrapped ('No parece una web: ' + ($bad -join ', ') + '. Escríbela como ejemplo.com.') 2 'Yellow'; return 2 }
            Write-JuicerWrapped ('Se bloquearán para siempre en todo el equipo: ' + ($list -join ', ') + '. No se podrán desbloquear desde Win Juicer.') 2 'Gray'
            if (-not $Yes -and (Read-JuicerChoice 'Escribe BLOQUEAR para hacerlo (Intro para no hacerlo)') -cne 'BLOQUEAR') {
                Write-Host '  No se ha bloqueado nada.'
                return 0
            }
            $added = @(Add-JuicerShieldBlock $list)
            if ($added.Count -eq 0) { Write-Host '  Ya estaban bloqueadas.' } else { Write-Host "  [ok] Bloqueadas para siempre ($($added.Count) nombres)." -ForegroundColor Green }
            Write-JuicerShieldState
            return 0
        }
    }
    2
}

function Show-JuicerShield {
    while ($true) {
        Write-JuicerHeader 'Protección contra contenido adulto'
        if (-not (Test-JuicerShield)) {
            [void](Invoke-JuicerShieldCli 'Activar')
            Wait-JuicerKey
            return
        }
        Write-JuicerShieldState
        $up = (Get-JuicerShieldLevel) -lt 2
        Write-Host ''
        if ($up) { Write-Host '  [1] Pasar a la estricta (para siempre)' }
        Write-Host '  [2] Bloquear una web para siempre: X, Reddit, Tumblr o la que digas'
        Write-Host '  [3] Comprobar que funciona en este PC'
        Write-Host '  [0] Volver'
        switch (Read-JuicerChoice) {
            '1' { if ($up) { [void](Invoke-JuicerShieldCli 'Subir'); Wait-JuicerKey } }
            '2' {
                try { [void](Invoke-JuicerShieldCli 'Bloquear') } catch { Write-Host "  $_" -ForegroundColor Yellow }
                Wait-JuicerKey
            }
            '3' { [void](Write-JuicerShieldCheck); Wait-JuicerKey }
            '0' { return }
            '' { return }
            default { Write-JuicerInvalidChoice $_ }
        }
    }
}

# «Listo para jugar»: a tick or a warning per thing, from what this PC reports.
function Show-JuicerReady {
    Write-JuicerHeader 'Listo para jugar — no cambia nada'
    if ($script:Screen) { Write-Host '  Mirando el equipo…' -ForegroundColor DarkGray }
    $lines = @(Get-JuicerReady)
    if ($script:Screen) { Write-JuicerHeader 'Listo para jugar — no cambia nada' }
    if ($lines.Count -eq 0) {
        Write-Host '  No se ha podido leer nada de este equipo.' -ForegroundColor Yellow
    }
    foreach ($l in $lines) {
        $mark = $(if ($l.Info) { '[ i]' } elseif ($l.Ok) { '[ok]' } else { '[ !]' })
        Write-Host ('  {0} ' -f $mark) -ForegroundColor $(if ($l.Info) { 'DarkGray' } elseif ($l.Ok) { 'Green' } else { 'Yellow' }) -NoNewline
        Write-Host $l.Title
        if ($l.Reason) { Write-JuicerWrapped $l.Reason 7 'DarkGray' }
    }
    Write-Host ''
    Write-JuicerWrapped 'Lo que no se ha podido leer no aparece: no se da por bueno ni por malo.' 2 'DarkGray'
    Wait-JuicerKey
}

function Show-JuicerMainMenu {
    $script:UpdateNotice = Get-JuicerUpdateNotice
    # Said once, before the first menu: it does not change while the program runs.
    $mismatch = $null
    try { $mismatch = Get-JuicerUserMismatch } catch { Write-JuicerLog "No se pudo comparar usuarios: $_" }
    $warnedUser = $false
    while ($true) {
        Write-JuicerHeader
        if ($mismatch -and -not $warnedUser) {
            $warnedUser = $true
            Write-JuicerWrapped (Get-JuicerUserMismatchText $mismatch) 2 'Yellow'
            Write-Host ''
        }
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
            @('15', 'Protección contra contenido adulto', 'opcional y para siempre: bloquea el porno y sus atajos'),
            @('16', 'Listo para jugar', 'Modo juego, HAGS, Resizable BAR, energía, monitor: de un vistazo'),
            @('0', 'Salir', '')
        )
        # What Windows has undone since: only when something has been (and the journal reads).
        try {
            $drift = @(Get-JuicerDrift)
            if ($drift.Count -gt 0) {
                Write-JuicerWrapped "$((Format-JuicerDriftSummary $drift).Title): míralos y vuelve a aplicarlos en Deshacer (11), o con -Revisar -Si." 2 'Yellow'
                Write-Host ''
            }
        } catch {
            Write-JuicerWrapped 'El diario de cambios no se puede leer: entra en Deshacer (11), que ofrece restaurar la copia anterior.' 2 'Red'
            Write-Host ''
        }
        if ($script:UpdateNotice) {
            Write-JuicerWrapped "Hay otra versión publicada de Win Juicer ($($script:UpdateNotice.Latest); tienes la $($script:UpdateNotice.Local)). A: actualizar ahora (abre PowerShell con la orden publicada, que comprueba su SHA256, y cierra Win Juicer). O, en PowerShell: $($script:UpdateNotice.Command)" 2 'Yellow'
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
            '15' { Show-JuicerShield }
            '16' { Show-JuicerReady }
            'A' {
                if ($script:UpdateNotice -and (Confirm-JuicerAction '¿Actualizar ahora? Se abre PowerShell con la orden publicada y Win Juicer se cierra')) {
                    try { Start-JuicerUpdate $script:UpdateNotice; return } catch { Write-JuicerWrapped "$_" 2 'Red'; Wait-JuicerKey }
                }
            }
            '0' { return }
            default { if ($script:InputClosed) { return }; Write-JuicerInvalidChoice $c }
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
        [string]$CalibrarJuego,
        [ValidateSet('', 'Fluidez', 'Latencia')][string]$Prioridad = '',
        [ValidateSet('', 'Auto', 'nvidia', 'rtss')][string]$MotorPacer = '',
        [ValidateSet('', 'Activar', 'Desactivar')][string]$ModoPrudente = '',
        [switch]$RestaurarPerfilesNvidia,
        [switch]$Juegos,
        [switch]$OptimizarJuegos,
        [switch]$Mantener,
        [ValidateSet('', 'Activar', 'Desactivar')][string]$MantenerJuegos = '',
        [ValidateSet('', 'Activar', 'Subir', 'Bloquear', 'Mantener', 'Estado', 'Comprobar')][string]$ProteccionAdultos = '',
        [ValidateSet('', 'Equilibrado', 'Estricto')][string]$NivelProteccion = '',
        [string[]]$BloquearWeb = @(),
        [int]$Fps,
        [string]$ModoMonitor,
        [ValidateSet('', 'Auto', 'Si', 'No')][string]$PantallaOled = '',
        [switch]$Lista,
        [switch]$Revisar,
        [switch]$RestaurarDiario,
        [switch]$Estado,
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
    $Juego = (& $split $Juego) -join ','
    $BloquearWeb = & $split $BloquearWeb
    if ($BloquearWeb.Count -gt 0 -and -not $ProteccionAdultos) { $ProteccionAdultos = 'Bloquear' }
    $cli = $Diagnostico -or $Informe -or $Exportar -or $Importar -or $Equipo -or $Juegos -or $OptimizarJuegos -or $Mantener -or $MantenerJuegos -or $ProteccionAdultos -or $Medir -or $NuevaMedida -or $ApuntarAjuste -or $OlvidarAjuste -or $MedirJuego -or $CalibrarJuego -or $MotorPacer -or $ModoPrudente -or $RestaurarPerfilesNvidia -or $LimitarFps.Count -gt 0 -or $ModoMonitor -or $PantallaOled -or $Lista -or $Revisar -or $RestaurarDiario -or $Estado -or $Recomendado -or $Perfil -or $Dns -or $DeshacerTodo -or
    $Aplicar.Count -gt 0 -or $Deshacer.Count -gt 0 -or $QuitarApps.Count -gt 0 -or $Instalar.Count -gt 0

    # -Simular promises «sin cambiar nada». Only the actions that can show what they would do
    # (the tweak sets, -Revisar and the undo actions) honour it; every other mutating action
    # would just run, so it is refused up front, before anything (even the copy below) happens.
    if ($Simular -and $cli) {
        $noSim = [ordered]@{
            Informe = [bool]$Informe; Exportar = [bool]$Exportar; Medir = [bool]$Medir; NuevaMedida = [bool]$NuevaMedida
            MedirJuego = [bool]$MedirJuego; CalibrarJuego = [bool]$CalibrarJuego; ApuntarAjuste = [bool]$ApuntarAjuste
            OlvidarAjuste = [bool]$OlvidarAjuste; LimitarFps = ($LimitarFps.Count -gt 0); MotorPacer = [bool]$MotorPacer
            ModoMonitor = [bool]$ModoMonitor; PantallaOled = [bool]$PantallaOled; OptimizarJuegos = [bool]$OptimizarJuegos
            Mantener = [bool]$Mantener; MantenerJuegos = [bool]$MantenerJuegos; BloquearWeb = ($PSBoundParameters.ContainsKey('BloquearWeb') -and $BloquearWeb.Count -gt 0)
            ProteccionAdultos = [bool]$ProteccionAdultos; Instalar = ($Instalar.Count -gt 0); RestaurarDiario = [bool]$RestaurarDiario
            ModoPrudente = [bool]$ModoPrudente; RestaurarPerfilesNvidia = [bool]$RestaurarPerfilesNvidia
        }
        $blocked = @($noSim.Keys | Where-Object { $noSim[$_] }) | Select-Object -First 1
        if ($blocked) {
            Write-Host "  -Simular no vale con -${blocked}: no puede enseñarse sin hacerlo." -ForegroundColor Yellow
            return 2
        }
    }
    # The protected copy the sign-in task runs follows this version.
    if ((Test-JuicerWindows) -and -not $Mantener -and -not $ProteccionAdultos -and -not $Simular) { Update-JuicerCopy }
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
    # Before anything reads the journal: a corrupt one is what this is for.
    if ($RestaurarDiario) { return $(if (Invoke-JuicerJournalRestore) { 0 } else { 1 }) }
    if ($RestaurarPerfilesNvidia) { return (Invoke-JuicerNvRestoreCli) }
    if ($Lista) { Show-JuicerList; return 0 }
    if ($Revisar) { return (Invoke-JuicerDriftCli -Apply:$Si -Simulate:$Simular -AcceptRisk:$AceptoRiesgos -NoRestorePoint:$SinPuntoDeRestauracion) }
    if ($Estado) { Show-JuicerReady; return 0 }
    if ($Informe) {
        $f = @(Get-JuicerAudit)
        $p = Save-JuicerAuditReport $Informe (Format-JuicerHardwareSummary (Get-JuicerHardwareProfile)) $f
        Write-Host "  Informe guardado en $p"
        return 0
    }
    if ($Diagnostico) { Show-JuicerAudit; return 0 }
    $monitor = $null
    if ($PantallaOled) {
        try { $monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
        if (-not $monitor) { Write-Host '  No se pudo leer el monitor para guardar si es OLED.' -ForegroundColor Yellow; return 1 }
        $now = Set-JuicerMonitorOled $monitor $(switch ($PantallaOled) { 'Si' { $true } 'No' { $false } default { $null } })
        Write-Host ('  ' + (Format-JuicerMonitor $monitor) + ': ' + $(if ($now) { 'OLED' } else { 'no OLED' }) + $(if ($PantallaOled -eq 'Auto') { ' (según su nombre)' } else { ' (lo dices tú)' }))
        if (-not $ModoMonitor -and $LimitarFps.Count -eq 0 -and -not $CalibrarJuego -and -not $MotorPacer) { return 0 }
    }
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
        if ($LimitarFps.Count -eq 0 -and -not $CalibrarJuego -and -not $MotorPacer) { return 0 }
    }
    if ($ProteccionAdultos) { return (Invoke-JuicerShieldCli $ProteccionAdultos -Yes:$Si -Level $NivelProteccion -Sites $BloquearWeb) }
    if ($Mantener) {
        $r = @(Invoke-JuicerUpkeep)
        return $(if (@($r | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 1 } else { 0 })
    }
    if ($MantenerJuegos -eq 'Activar') { Register-JuicerUpkeep; Write-Host '  Activado: al iniciar sesión, los juegos nuevos se optimizan solos y los límites siguen a tu monitor.'; return 0 }
    if ($MantenerJuegos -eq 'Desactivar') { Unregister-JuicerUpkeep; Write-Host '  Desactivado.'; return 0 }
    if ($Juegos -or $OptimizarJuegos) {
        $games = @(Get-JuicerGameStatus @(Get-JuicerGames))
        if ($OptimizarJuegos) {
            $results = @(Invoke-JuicerGameSetup $games 'Recomendado' $Fps)
            Show-JuicerResults $results
            return $(if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 1 } else { 0 })
        }
        Write-JuicerGameList $games
        return 0
    }
    if ($MotorPacer) {
        try {
            $results = @(Set-JuicerPacerEngine $MotorPacer $monitor)
        } catch {
            Write-Host "  $_" -ForegroundColor Yellow
            return 1
        }
        Write-Host "  Motor del frame pacer: $(Format-JuicerFpsBackend (Get-JuicerFpsBackend))."
        if ($results.Count -gt 0) { Show-JuicerResults $results }
        if ($LimitarFps.Count -eq 0 -and -not $CalibrarJuego) { return 0 }
    }
    if ($ModoPrudente) {
        # Per game, like -Prioridad: -Juego names them (several with commas).
        $games = @($Juego -split ',' | Where-Object { $_ })
        if ($games.Count -eq 0) { Write-Host '  -ModoPrudente va con -Juego (el .exe del juego, por ejemplo cs2.exe).' -ForegroundColor Yellow; return 2 }
        $results = @(foreach ($exe in $games) { Set-JuicerPacerMinimal $exe ($ModoPrudente -eq 'Activar') $monitor })
        Write-Host "  Modo prudente $(if ($ModoPrudente -eq 'Activar') { 'activado' } else { 'desactivado' }) ($($games -join ', '))."
        if ($results.Count -gt 0) { Show-JuicerResults $results }
        return $(if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 1 } else { 0 })
    }
    if ($Prioridad) {
        $targets = @($LimitarFps) + @(if ($CalibrarJuego) { $CalibrarJuego })
        if ($targets.Count -eq 0) { Write-Host '  -Prioridad va con -LimitarFps o -CalibrarJuego.' -ForegroundColor Yellow; return 2 }
        foreach ($exe in $targets) { [void](Set-JuicerPacerPriority $exe $Prioridad $monitor) }
        Write-Host "  Prioridad del frame pacer: $Prioridad ($($targets -join ', '))."
    }
    if ($CalibrarJuego) {
        try {
            $fgWarn = Get-JuicerFrameGenMeasureWarning (ConvertTo-JuicerExeName $CalibrarJuego)
            if ($fgWarn) { Write-JuicerWrapped $fgWarn 2 'Yellow'; Write-Host '' }
            Write-JuicerWrapped $script:CalibrateAdvice 2 'Gray'
            $f = @(Invoke-JuicerPacerCalibration -Exe $CalibrarJuego -Seconds $(if ($MedirJuego) { $MedirJuego } else { 60 }) -OnStatus ${function:Write-JuicerStatusLine} -Monitor $monitor -NoFrameGenWarning)
            Write-Host ''
            Write-JuicerFindings $f
            # It proposes; it changes the rate only with -Si, or when it is accepted (a closed input is a no).
            $proposal = Get-JuicerCalibrationProposal $f
            if ($proposal) {
                if (Confirm-JuicerAction ('¿Aplicar {0} → {1} FPS a {2}?' -f $proposal.Old, $proposal.New, $proposal.Exe)) {
                    Write-JuicerFindings @(Save-JuicerPacerCalibration $proposal $monitor)
                } else {
                    Write-Host '  No se ha cambiado nada. Con -Si se aplica sin preguntar.'
                }
            }
            return 0
        } catch {
            Write-Host "  No se pudo calibrar: $_" -ForegroundColor Yellow
            return 1
        }
    }
    if ($LimitarFps.Count -gt 0) {
        if ($Fps -and ($Fps -lt 20 -or $Fps -gt 1000)) { Write-Host '  -Fps va de 20 a 1000.' -ForegroundColor Yellow; return 2 }
        # A rate given by hand is kept when the rates are recalculated.
        $results = @(foreach ($exe in $LimitarFps) { if ($Fps) { Set-JuicerPacerFps $exe $Fps $monitor $ModoMonitor } else { Add-JuicerFpsLimit $exe 0 $monitor $ModoMonitor } })
        Show-JuicerResults $results
        # What was put in each game, in plain words.
        foreach ($exe in $LimitarFps) {
            $applied = Format-JuicerPacerApplied $exe -Console
            if ($applied) { Write-Host ''; Write-JuicerWrapped $applied 2 'Gray' }
        }
        return $(if (@($results | Where-Object { $_.Outcome -eq 'Error' }).Count -gt 0) { 1 } else { 0 })
    }
    if ($MedirJuego) {
        if ($MedirJuego -lt 10 -or $MedirJuego -gt 600) { Write-Host '  -MedirJuego va de 10 a 600 segundos.' -ForegroundColor Yellow; return 2 }
        try {
            $fgWarn = if ($Juego) { Get-JuicerFrameGenMeasureWarning (ConvertTo-JuicerExeName $Juego) } else { $null }
            if ($fgWarn) { Write-JuicerWrapped $fgWarn 2 'Yellow'; Write-Host '' }
            $f = @(Invoke-JuicerFrameCapture -Seconds $MedirJuego -Delay 10 -Process $Juego -OnStatus ${function:Write-JuicerStatusLine} -NoFrameGenWarning)
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
        Write-Host ('  Configuración guardada en {0}: {1}, {2}, {3}{4}.' -f $Exportar, (Format-JuicerCount @($cfg.Tweaks).Count 'ajuste'), (Format-JuicerCount $cfg.Toggles.Count 'preferencia'), (Format-JuicerCount @($cfg.Apps).Count 'app'), $(if ($cfg.Dns) { ", DNS $($cfg.Dns)" } else { '' }))
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
    if ($Simular -and ($DeshacerTodo -or $Deshacer.Count -gt 0)) {
        # Only say what would go back; the journal and the machine stay as they are.
        # Assigned as it comes: the journal is returned as one list, and @() would wrap it.
        $journal = Read-JuicerJournal
        if ($DeshacerTodo) {
            if ($journal.Count -eq 0) { Write-Host '  No hay cambios de Win Juicer que deshacer.' }
            else { Write-JuicerWrapped (Format-JuicerUndoAllConfirm $journal -NoQuestion) 2 'Gray' }
        }
        $picked = @()
        foreach ($id in $Deshacer) {
            $e = Get-JuicerJournalEntry $journal $id
            if ($e) { $picked += $e } else { Write-Host "  ${id}: no hay cambios de Win Juicer guardados para este ajuste." }
        }
        if ($picked.Count -gt 0 -and -not $DeshacerTodo) { Write-JuicerWrapped (Format-JuicerUndoAllConfirm $picked -NoQuestion) 2 'Gray' }
    } else {
        if ($DeshacerTodo) { $results += @(Undo-JuicerAll) }
        foreach ($id in $Deshacer) { $results += Undo-JuicerTweak $id }
    }

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
                if (-not (Confirm-JuicerAction "¿Aplicar $(Format-JuicerCount $todo.Count 'ajuste')?")) { return 0 }
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
