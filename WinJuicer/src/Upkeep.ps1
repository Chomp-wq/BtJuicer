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
    [IO.File]::WriteAllText((Get-JuicerUpkeepPath), (ConvertTo-JuicerJson $State), (New-Object Text.UTF8Encoding $false))
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
    $state = Read-JuicerUpkeepState
    $games = @(Get-JuicerGames -KeepNew)
    $monitor = $null
    try { $monitor = Get-JuicerPrimaryMonitor } catch { Write-JuicerLog "Mantener: sin monitor: $_" }
    $sig = Get-JuicerLimitSignature $monitor
    $plan = Get-JuicerUpkeepPlan $games $state.Seen $sig $state.Signature (@(Get-JuicerFpsLimits).Count -gt 0)
    $results = @()
    if ($plan.Recalc) { $results += @(Update-JuicerFpsLimits $monitor) }
    if ($plan.New.Count -gt 0 -and (Get-JuicerFpsBackend)) { $results += @(Invoke-JuicerGameSetup $plan.New 'Recomendado' -Monitor $monitor) }
    $state.Seen = @($games | ForEach-Object { $_.Id })
    if ($sig) { $state.Signature = $sig }
    Save-JuicerUpkeepState $state
    $ok = @($results | Where-Object { $_.Outcome -eq 'Aplicado' })
    $msg = @()
    if ($plan.New.Count -gt 0) { $msg += 'Juegos nuevos optimizados: ' + (($plan.New | ForEach-Object { $_.Name }) -join ', ') + '.' }
    if ($plan.Recalc) { $msg += 'Ha cambiado tu monitor o cómo lo usas: frame pacer recalculado.' }
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
    New-Item -ItemType Directory -Path (Join-Path $dst 'src') -Force | Out-Null
    foreach ($f in 'WinJuicer.ps1', 'WinJuicer.psm1', 'WinJuicer.cmd', 'version.txt', 'README.md') {
        $p = Join-Path $src $f
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $dst -Force }
    }
    Remove-Item -Path (Join-Path $dst 'src\*.ps1') -Force -ErrorAction SilentlyContinue
    Copy-Item -Path (Join-Path $src 'src\*.ps1') -Destination (Join-Path $dst 'src') -Force
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
    # Only the copy this task used; nothing else lives there.
    if ($env:ProgramFiles -and (Test-Path -LiteralPath (Join-Path $dir 'WinJuicer.psm1'))) { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-Item -LiteralPath (Get-JuicerUpkeepPath) -Force -ErrorAction SilentlyContinue
}

# Called when Win Juicer opens elevated: the protected copy follows the
# version in use, so the task never runs an old one.
function Update-JuicerCopy {
    if (Test-JuicerUpkeep) {
        try { [void](Install-JuicerCopy) } catch { Write-JuicerLog "No se pudo actualizar la copia de Program Files: $_" }
    }
}
