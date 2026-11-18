# Keeping games optimized with Win Juicer closed. At every sign-in a task
# optimizes the games installed since the last time and, if the monitor, its
# refresh rate or how it is used changed, recalculates the frame pacer.
#
# Writing NVIDIA's driver profiles needs an administrator, so the task runs
# elevated. That is only safe if what it runs cannot be changed by anyone
# else: Win Juicer copies itself to Program Files, writable only by
# administrators, and the task runs that copy, never the one in %TEMP% that
# the one-line launcher uses.

$script:UpkeepTask = 'Win Juicer - mantener juegos'

function Get-JuicerInstallDir { Join-Path $env:ProgramFiles 'WinJuicer' }
function Get-JuicerUpkeepPath { Join-Path (Get-JuicerHome) 'mantener.json' }

function Read-JuicerUpkeepState {
    $p = Get-JuicerUpkeepPath
    $s = @{ Seen = @(); Signature = '' }
    if (Test-Path -LiteralPath $p) {
        try {
            $d = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($p) | ConvertFrom-Json)
            $s.Seen = @($d.Seen | Where-Object { $_ })
            $s.Signature = [string]$d.Signature
        } catch {
            Write-JuicerLog "mantener.json dañado, se ignora: $_"
        }
    }
    $s
}

function Save-JuicerUpkeepState {
    param([hashtable]$State)
    Write-JuicerTextAtomic (Get-JuicerUpkeepPath) (ConvertTo-JuicerJson $State)
}

# What the FPS limits depend on: change any of it and they are recalculated.
function Get-JuicerLimitSignature {
    param([hashtable]$Monitor)
    if (-not $Monitor) { return '' }
    '{0}|{1}|{2}' -f [int]$Monitor.Display.Hz, (Resolve-JuicerMonitorUse $Monitor), (Get-JuicerMonitorKey $Monitor)
}

# Which games are new to the upkeep and whether the limits need redoing.
function Get-JuicerUpkeepPlan {
    param([object[]]$Games, [string[]]$Seen, [string]$Signature, [string]$LastSignature, [bool]$HasLimits)
    @{
        New = @($Games | Where-Object { $Seen -notcontains $_.Id })
        Recalc = $HasLimits -and $Signature -and $LastSignature -and $Signature -ne $LastSignature
    }
}

# One run: what the sign-in task does, also -Mantener. Returns the results.
function Invoke-JuicerUpkeep {
    param([switch]$Quiet)
    # The content protection as well, its task included: one deleted by hand
    # comes back at the next sign-in.
    try { [void](Repair-JuicerShield) } catch { Write-JuicerLog "Mantener: no se pudo revisar la protección: $_" }
    # What Windows has undone since: only logged, never put back behind the user's back.
    try {
        $drift = @(Get-JuicerDrift)
        if ($drift.Count -gt 0) { Write-JuicerLog ('Mantener: {0}: {1}. Se vuelven a aplicar con -Revisar -Si.' -f (Format-JuicerDriftSummary $drift).Title, (($drift | ForEach-Object { $_.Id }) -join ', ')) }
    } catch { Write-JuicerLog "Mantener: no se pudo revisar lo que Windows ha deshecho: $_" }
    $state = Read-JuicerUpkeepState
    $games = @(Get-JuicerGames -KeepNew)
    $monitor = $null
    try { $monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Mantener: sin monitor: $_" }
    $sig = Get-JuicerLimitSignature $monitor
    $plan = Get-JuicerUpkeepPlan $games $state.Seen $sig $state.Signature (@(Get-JuicerFpsLimits).Count -gt 0)
    $results = @()
    # What waited for a game to close, and what an older recipe left behind.
    $results += @(Invoke-JuicerPacerPending $monitor)
    $results += @(Repair-JuicerGameSetups)
    if ($plan.Recalc) { $results += @(Update-JuicerFpsLimits $monitor) }
    $hasBackend = $false
    if ($plan.New.Count -gt 0 -and (Get-JuicerFpsBackend)) {
        $hasBackend = $true
        $results += @(Invoke-JuicerGameSetup $plan.New 'Recomendado' -Monitor $monitor)
    }
    # A new game stays unseen (so the next run retries it) when there was no FPS backend yet
    # or its setup errored; marking it seen would skip it for good.
    $failed = @($plan.New | Where-Object {
            $id = "juego:$($_.ExeName)"
            -not $hasBackend -or @($results | Where-Object { $_.Id -eq $id -and $_.Outcome -eq 'Error' }).Count -gt 0
        } | ForEach-Object { $_.Id })
    $state.Seen = @($games | Where-Object { $failed -notcontains $_.Id } | ForEach-Object { $_.Id })
    if ($sig) { $state.Signature = $sig }
    Save-JuicerUpkeepState $state
    # A game that started failing after it was optimized gets its changes taken away.
    $safety = Update-JuicerGameSafety $games
    $ok = @($results | Where-Object { $_.Outcome -eq 'Aplicado' })
    $msg = @()
    $done = @($plan.New | Where-Object { -not (Get-JuicerGameSafe $_.ExeName) })
    if ($done.Count -gt 0) { $msg += 'Juegos nuevos optimizados: ' + (($done | ForEach-Object { $_.Name }) -join ', ') + '.' }
    if ($plan.Recalc) { $msg += 'Ha cambiado tu monitor o cómo lo usas: frame pacer recalculado.' }
    foreach ($p in @($safety.Protected)) { $msg += "$($p.Name) falló después de optimizarlo: Win Juicer le ha quitado sus cambios por si eran la causa." }
    Write-JuicerLog ('Mantener: {0} nuevos, recalcular {1}, {2} cambios' -f $plan.New.Count, $plan.Recalc, $ok.Count)
    if ($msg.Count -gt 0 -and -not $Quiet) { Show-JuicerToast ($msg -join ' ') }
    $results
}

function Show-JuicerToast {
    param([string]$Text)
    try {
        $manager = 'Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime' -as [type]
        $xmlType = 'Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime' -as [type]
        $toastType = 'Windows.UI.Notifications.ToastNotification, Windows.UI.Notifications, ContentType = WindowsRuntime' -as [type]
        if (-not $manager -or -not $xmlType -or -not $toastType) { throw 'Sin notificaciones de Windows en esta PowerShell.' }
        $x = New-Object $xmlType
        $x.LoadXml('<toast><visual><binding template="ToastGeneric"><text>Win Juicer</text><text>' + [Security.SecurityElement]::Escape($Text) + '</text></binding></visual></toast>')
        $manager::CreateToastNotifier('{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe').Show($toastType::new($x))
    } catch {
        Write-JuicerLog "Aviso sin mostrar ($_): $Text"
    }
}

# --- The protected copy and the task ------------------------------------------------

# The tool's own files, from wherever it is running, into Program Files.
function Install-JuicerCopy {
    $src = $script:ModuleRoot
    $dst = Get-JuicerInstallDir
    if ((Resolve-Path -LiteralPath $src).ProviderPath.TrimEnd('\') -eq $dst.TrimEnd('\')) { return $dst }
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    # Stage the new src next to the old one and swap only after every copy worked: a failed
    # copy (file in use, disk full) must not leave the protected copy without its scripts.
    $stage = Join-Path $dst 'src.nuevo'
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction Stop }
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    try {
        Copy-Item -Path (Join-Path $src 'src\*.ps1') -Destination $stage -Force -ErrorAction Stop
        foreach ($f in 'WinJuicer.ps1', 'WinJuicer.psm1', 'WinJuicer.cmd', 'version.txt', 'README.md') {
            $p = Join-Path $src $f
            if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force -ErrorAction Stop }
        }
        $old = Join-Path $dst 'src'
        if (Test-Path -LiteralPath $old) { Remove-Item -Path (Join-Path $old '*.ps1') -Force -ErrorAction Stop } else { New-Item -ItemType Directory -Path $old -Force | Out-Null }
        Move-Item -Path (Join-Path $stage '*.ps1') -Destination $old -Force -ErrorAction Stop
    } finally {
        if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force -ErrorAction SilentlyContinue }
    }
    $dst
}

function Test-JuicerUpkeep {
    if (-not (Test-JuicerWindows)) { return $false }
    $null -ne (Get-ScheduledTask -TaskName $script:UpkeepTask -ErrorAction SilentlyContinue)
}

# Starting it marks the games there are now as seen: from here on, the new
# ones. «Optimizar los marcados» is for the ones already installed.
function Register-JuicerUpkeep {
    if (-not (Test-JuicerWindows)) { return }
    $dir = Install-JuicerCopy
    $state = Read-JuicerUpkeepState
    $state.Seen = @(Get-JuicerGames -KeepNew | ForEach-Object { $_.Id })
    $m = $null
    try { $m = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Sin monitor: $_" }
    $state.Signature = Get-JuicerLimitSignature $m
    Save-JuicerUpkeepState $state
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'WinJuicer.ps1')`" -Mantener"
    $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
    $trigger.Delay = 'PT2M'
    $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 10)
    Register-ScheduledTask -TaskName $script:UpkeepTask -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Optimiza los juegos nuevos y recalcula el frame pacer si cambia el monitor (Win Juicer).' -Force | Out-Null
    Write-JuicerLog "Mantenimiento de juegos activado: $dir"
}

function Unregister-JuicerUpkeep {
    if (Test-JuicerUpkeep) { Unregister-ScheduledTask -TaskName $script:UpkeepTask -Confirm:$false }
    $dir = Get-JuicerInstallDir
    # Only the copy this task used; nothing else lives there. The content
    # protection's task runs from it too: then it stays.
    if ($env:ProgramFiles -and -not (Test-JuicerShield) -and (Test-Path -LiteralPath (Join-Path $dir 'WinJuicer.psm1'))) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Get-JuicerUpkeepPath) -Force -ErrorAction SilentlyContinue
}

# Called when Win Juicer opens elevated: the protected copy follows the
# version in use, so the task never runs an old one. And the protection's task
# runs it now: what a new version fixes in the protection reaches the PC as
# soon as it opens, not at the next round of 15 minutes.
function Update-JuicerCopy {
    if ((Test-JuicerUpkeep) -or (Test-JuicerShield)) {
        try { [void](Install-JuicerCopy) } catch { Write-JuicerLog "No se pudo actualizar la copia de Program Files: $_"; return }
    }
    if ((Test-JuicerShield) -and (Test-JuicerShieldTask)) {
        try { Start-ScheduledTask -TaskName $script:ShieldTask -ErrorAction Stop } catch { Write-JuicerLog "Protección: su tarea no se pudo poner en marcha ahora: $_" }
    }
}
