# Against the real registry, services, powercfg and bcdedit. Meant for a
# throwaway Windows machine such as a CI runner: it applies the whole catalog,
# Extremo included, and then checks that undoing leaves everything as it was.
# Being an administrator is not enough to run it: it also wants
# WINJUICER_PRUEBAS_REALES=1, so nobody runs it on their own PC by accident.

BeforeDiscovery {
    $script:OnWindows = [Environment]::OSVersion.Platform -eq 'Win32NT'
    $script:IsAdmin = $false
    if ($script:OnWindows) {
        $p = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
        $script:IsAdmin = $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
}

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    if ([Environment]::OSVersion.Platform -eq 'Win32NT') { Use-JuicerBackend (New-JuicerWindowsBackend) }

    # What every catalog action would capture right now: if two of these match,
    # the machine is in the same state as far as Win Juicer can tell.
    # Whether a service happens to be running is left out: Windows starts and
    # stops trigger-started ones like wuauserv on its own.
    function Get-RealSnapshot {
        $lines = foreach ($t in (Get-JuicerCatalog)) {
            if (Get-JuicerSkipReason $t) { continue }
            foreach ($a in (Resolve-JuicerActions $t)) {
                try {
                    $c = Save-JuicerActionState $a $t.Id
                    $c.Remove('Running')
                    '{0} {1}' -f $t.Id, ((ConvertTo-JuicerJson $c) -replace '\s+', ' ')
                } catch {
                    '{0} ERROR {1}' -f $t.Id, $_
                }
            }
        }
        $lines -join "`n"
    }
}

Describe 'Windows de verdad' -Tag 'Windows' -Skip:(-not ($OnWindows -and $IsAdmin -and $env:WINJUICER_PRUEBAS_REALES -eq '1')) {
    It 'el registro: todos los tipos de valor, ida y vuelta' {
        $base = 'HKCU\Software\WinJuicerPrueba\' + [guid]::NewGuid().ToString('N')
        $cases = @(
            @{ Name = 'd'; Kind = 'DWord'; Value = 4294967295 }
            @{ Name = 'q'; Kind = 'QWord'; Value = 1234567890123 }
            @{ Name = 's'; Kind = 'String'; Value = 'ñandú — «sí»' }
            @{ Name = 'e'; Kind = 'ExpandString'; Value = '%SystemRoot%\x' }
            @{ Name = 'm'; Kind = 'MultiString'; Value = @('uno') }
            @{ Name = 'b'; Kind = 'Binary'; Value = [byte[]](3, 0, 255) }
            @{ Name = ''; Kind = 'String'; Value = '' }
        )
        foreach ($c in $cases) {
            Write-JuicerReg "$base\k" $c.Name $c.Kind $c.Value
            $r = Read-JuicerReg "$base\k" $c.Name
            Test-JuicerRegValueEqual $r @{ Kind = $c.Kind; Value = $c.Value } | Should -BeTrue -Because "$($c.Kind) $($c.Name)"
        }
        @(Get-JuicerRegChildren $base) | Should -Be @('k')
        & (Get-JuicerBackend).KeyDelete "$base\k" | Should -BeFalse
        foreach ($c in $cases) { Remove-JuicerReg "$base\k" $c.Name }
        & (Get-JuicerBackend).KeyDelete "$base\k" | Should -BeTrue
        & (Get-JuicerBackend).KeyDelete $base | Should -BeTrue
        Test-JuicerRegKey $base | Should -BeFalse
    }

    It 'lee el tipo de inicio de un servicio' {
        $s = & (Get-JuicerBackend).SvcRead 'EventLog'
        $s.Start | Should -BeIn @('Automatic', 'AutomaticDelayed')
        $s.Running | Should -BeTrue
        & (Get-JuicerBackend).SvcRead 'NoExisteEsteServicio' | Should -BeNullOrEmpty
    }

    It 'el catálogo entero, aplicado y deshecho, deja Windows como estaba' {
        $before = Get-RealSnapshot
        $results = @(foreach ($t in (Get-JuicerProfile 3)) { Invoke-JuicerTweak $t })
        foreach ($r in $results) { Write-Host ('    {0,-22} {1,-12} {2}' -f $r.Id, $r.Outcome, $r.Message) }
        @($results | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -BeGreaterThan 15
        $undo = @(Undo-JuicerAll)
        foreach ($u in @($undo | Where-Object { $_.Outcome -ne 'Deshecho' })) { Write-Host ('    deshacer {0}: {1} {2}' -f $u.Id, $u.Outcome, $u.Message) }
        @($undo | Where-Object { $_.Outcome -ne 'Deshecho' }).Count | Should -Be 0
        (Read-JuicerJournal).Count | Should -Be 0
        $after = Get-RealSnapshot
        if ($after -ne $before) {
            $b = $before -split "`n"; $a = $after -split "`n"
            Compare-Object $b $a | ForEach-Object { Write-Host ('    {0} {1}' -f $_.SideIndicator, $_.InputObject) }
        }
        $after | Should -Be $before
    }

    It 'el diagnóstico completo no falla en ninguna parte' {
        $f = @(Get-JuicerAudit)
        foreach ($x in $f) { Write-Host ('    {0,-6} {1,-11} {2}' -f $x.Severity, $x.Area, $x.Title) }
        $f.Count | Should -BeGreaterThan 3
        @($f | Where-Object { $_.Area -eq 'Diagnóstico' }) | Should -BeNullOrEmpty
    }

    It 'lee programas de inicio, bibliotecas y pantallas' {
        { Get-JuicerStartupItems } | Should -Not -Throw
        { Get-JuicerGameLibraries } | Should -Not -Throw
        { Get-JuicerDisplays } | Should -Not -Throw
        { Test-JuicerModernStandby } | Should -Not -Throw
    }

    It 'lee la salud de los discos y la versión de Windows' {
        $disks = @(Get-JuicerDiskHealth)
        $disks.Count | Should -BeGreaterThan 0
        $disks[0].Name | Should -Not -BeNullOrEmpty
        { Get-JuicerDiskHealthFindings $disks } | Should -Not -Throw
        { Get-JuicerWindowsSupportInfo } | Should -Not -Throw
    }

    It 'descarga PresentMon con la firma de Intel y hace una captura' {
        $pm = Get-JuicerPresentMon
        Test-JuicerIntelSignature $pm | Should -BeTrue
        Write-Host "    PresentMon: $pm, SHA256 $((Get-FileHash $pm -Algorithm SHA256).Hash)"
        # Nothing is playing on the runner: the capture must still run and say so.
        $f = @(Invoke-JuicerFrameCapture -Seconds 5 -Delay 0)
        $f.Count | Should -BeGreaterThan 0
        Write-Host "    $($f[0].Title)"
    }

    It 'lee los monitores y sabe qué limitador de FPS hay' {
        $m = @(Get-JuicerMonitors)
        foreach ($x in $m) { Write-Host "    $(if ($x.Info) { Format-JuicerMonitor $x } else { $x.Display.Monitor + ' (sin EDID)' })" }
        { Get-JuicerMonitorFindings $m 'NVIDIA' } | Should -Not -Throw
        Initialize-JuicerNvApi
        [WinJuicer.NvDrs]::SettingVersion | Should -Be 0x13020
        [WinJuicer.NvDrs]::ApplicationVersion | Should -Be 0x4500C
        # The runner has no NVIDIA driver: it must say so, not fail.
        { Get-JuicerFpsBackend } | Should -Not -Throw
        Write-Host "    Limitador: '$(Get-JuicerFpsBackend)'"
    }

    It 'apunta el ajuste fino y crea y quita la tarea que lo vigila' {
        [void](Save-JuicerTuneRecord -Cpu 'Curve Optimizer -20')
        (Read-JuicerTuneRecord).Bios | Should -Not -BeNullOrEmpty
        { Get-JuicerTuneCheck } | Should -Not -Throw
        Register-JuicerTuneWatch
        try {
            Test-JuicerTuneWatch | Should -BeTrue
            Test-Path (Join-Path (Get-JuicerTuneWatchDir) 'vigilar-ajuste-fino.ps1') | Should -BeTrue
            # The watcher itself, run once: without changes it says nothing and leaves its state.
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path (Get-JuicerTuneWatchDir) 'vigilar-ajuste-fino.ps1')
            Test-Path (Join-Path (Get-JuicerTuneWatchDir) 'vigilar-estado.json') | Should -BeTrue
        } finally {
            Unregister-JuicerTuneWatch
            Remove-JuicerTuneRecord
        }
        Test-JuicerTuneWatch | Should -BeFalse
    }

    It 'busca los juegos instalados y el .exe de una carpeta de verdad' {
        $g = @(Get-JuicerGames)
        foreach ($x in $g) { Write-Host "    $($x.Launcher): $($x.Name) -> $($x.ExeName)" }
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('wj-juego-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'Binaries\Win64') -Force | Out-Null
        [IO.File]::WriteAllBytes((Join-Path $dir 'MiJuego.exe'), [byte[]]::new(1KB))
        [IO.File]::WriteAllBytes((Join-Path $dir 'unins000.exe'), [byte[]]::new(2MB))
        [IO.File]::WriteAllBytes((Join-Path $dir 'Binaries\Win64\MiJuego-Win64-Shipping.exe'), [byte[]]::new(4MB))
        try {
            Find-JuicerGameExe $dir 'Mi Juego' | Should -Be (Join-Path $dir 'Binaries\Win64\MiJuego-Win64-Shipping.exe')
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }

    It 'mide arranque, procesos, servicios, memoria y espacio' {
        $m = Get-JuicerMetrics
        $m.Processes | Should -BeGreaterThan 10
        $m.Services | Should -BeGreaterThan 10
        $m.RamUsed | Should -BeGreaterThan 0
        $m.DiskFree | Should -BeGreaterThan 0
        $m.Startup | Should -Not -BeNullOrEmpty
        @(Compare-JuicerMetrics $m $m).Count | Should -BeGreaterThan 3
    }

    It 'lee el hardware y hace la revisión de overclock, BIOS y estabilidad' {
        $hw = Get-JuicerHardwareProfile -Refresh
        foreach ($l in (Format-JuicerHardwareSummary $hw)) { Write-Host "    $l" }
        $hw.Cpu.Name | Should -Not -BeNullOrEmpty
        $hw.Cpu.Threads | Should -BeGreaterThan 0
        $f = @(Get-JuicerTuningAudit) + @(Get-JuicerStabilityAudit) + @(Get-JuicerGpuTuningAudit) + @(Get-JuicerNetworkAudit) + @(Get-JuicerSoftwareAudit)
        foreach ($x in $f) { Write-Host ('    {0,-6} {1,-17} {2}' -f $x.Severity, $x.Area, $x.Title) }
        @($f | Where-Object { $_.Title -like 'No se pudo leer el registro*' }) | Should -BeNullOrEmpty
        $a = Get-JuicerAdvice $hw
        @(Get-JuicerCatalog | Where-Object { -not $a[$_.Id] }) | Should -BeNullOrEmpty
    }

    It 'lista las apps de la Tienda y las características de Windows' {
        { @(Get-JuicerDebloatState (Get-JuicerHardwareProfile)) } | Should -Not -Throw
        $b = Get-JuicerBackend
        # The window asks for every component when it opens: dism took about
        # a minute here, which is why reading goes through WMI.
        & (Get-Module WinJuicer) { $script:FeatureCache = $null }
        $t = Measure-Command { $f = & $b.FeatRead 'NetFx3' }
        Write-Host ('    características leídas en {0:N1} s; NetFx3: {1}' -f $t.TotalSeconds, $(if ($f) { $f.Enabled } else { 'no existe' }))
        { Get-JuicerCurrentDns } | Should -Not -Throw
    }

    It 'la ventana se construye y dibuja cada pestaña' {
        # WPF needs a single-threaded apartment, whatever the test host uses.
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $psm = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1'
        [void]$ps.AddScript(@"
Import-Module '$psm' -Force
& (Get-Module WinJuicer) {
    `$null = Show-JuicerGui -NoShow
    `$hw = Get-JuicerHardwareProfile
    `$script:Gui.Hw = `$hw
    `$script:Gui.Advice = Get-JuicerAdvice `$hw
    `$script:Gui.Snapshot = Get-JuicerGuiSnapshot
    Show-JuicerGuiTweaks
    Show-JuicerGuiApps
    Show-JuicerGuiUndo
    Show-JuicerGuiAudit @(Get-JuicerAudit)
    Show-JuicerGuiDebloat @(Get-JuicerDebloatState `$hw)
    Show-JuicerGuiStartup @(Get-JuicerStartupItems)
    Show-JuicerGuiGames @(@{ Path = 'D:\SteamLibrary\steamapps'; Launcher = 'Steam'; State = 'Pendiente' }, @{ Path = 'E:\XboxGames'; Launcher = 'Xbox / Game Pass'; State = 'Aplicado' })
    `$script:Gui.Findings = @(Get-JuicerAudit)
    `$informe = Save-JuicerAuditReport (Join-Path ([IO.Path]::GetTempPath()) 'wj-informe.txt') (Format-JuicerHardwareSummary `$hw) `$script:Gui.Findings
    Select-JuicerGuiTweaks 'Recomendado'
    `$script:Gui.C.SearchBox.Text = 'steam'
    `$r = @{
        Checks = `$script:Gui.Checks.Count; Apps = `$script:Gui.InstallChecks.Count; Cards = `$script:Gui.C.AuditPanel.Children.Count
        Missing = @(`$script:Gui.C.Keys | Where-Object { `$null -eq `$script:Gui.C[`$_] })
        Visible = @(`$script:Gui.InstallChecks.Values | Where-Object { `$_.Check.Visibility -eq 'Visible' }).Count
        Libs = `$script:Gui.C.LibPanel.Children.Count; Report = (Get-Item -LiteralPath `$informe).Length
    }
    `$script:Gui.Window.Close()
    `$r
}
"@)
        try {
            $out = @($ps.Invoke())
            foreach ($e in $ps.Streams.Error) { Write-Host "    $e" }
            $ps.Streams.Error.Count | Should -Be 0
            $r = $out[-1]
            $r.Missing | Should -BeNullOrEmpty
            $r.Checks | Should -BeGreaterThan 30
            $r.Apps | Should -BeGreaterThan 40
            $r.Cards | Should -BeGreaterThan 5
            $r.Visible | Should -Be 1
            $r.Libs | Should -Be 2
            $r.Report | Should -BeGreaterThan 500
        } finally {
            $ps.Dispose()
            $rs.Dispose()
        }
    }

    It 'la ventana hace su trabajo en segundo plano: leer, diagnosticar, aplicar y deshacer' {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.ApartmentState = 'STA'
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        $psm = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1'
        [void]$ps.AddScript(@"
Import-Module '$psm' -Force
& (Get-Module WinJuicer) {
    # What the window's timer does, without a window loop to drive it.
    function Wait-Gui {
        `$limit = (Get-Date).AddMinutes(8)
        while ((`$script:Gui.Task -or `$script:Gui.Queue.Count -gt 0) -and (Get-Date) -lt `$limit) {
            if (`$script:Gui.Task -and `$script:Gui.Task.Handle.IsCompleted) { Complete-JuicerGuiTask } else { Start-Sleep -Milliseconds 200 }
        }
    }
    `$null = Show-JuicerGui -NoShow
    Start-JuicerGuiTask 'x' 'Init' @{} { param(`$r) Complete-JuicerGuiInit `$r }
    Wait-Gui
    `$init = @{ Checks = `$script:Gui.Checks.Count; Findings = @(`$script:Gui.Findings).Count; Cpu = `$script:Gui.Hw.Cpu.Name }
    `$on = (Get-JuicerTweakState (Find-JuicerTweak 'pref.extensiones')).State -eq 'Aplicado'
    Start-JuicerGuiTask 'x' 'Run' @{ Toggles = @(@{ Id = 'pref.extensiones'; On = (-not `$on) }) } { param(`$r) `$script:Gui.Last = `$r; Complete-JuicerGuiRun `$r }
    Wait-Gui
    `$flipped = (Get-JuicerTweakState (Find-JuicerTweak 'pref.extensiones')).State -eq 'Aplicado'
    `$ids = @(Read-JuicerJournal | ForEach-Object { `$_.Id })
    Start-JuicerGuiTask 'x' 'Run' @{ Undo = `$ids } { param(`$r) Complete-JuicerGuiRun `$r }
    Wait-Gui
    Start-JuicerGuiTask 'x' 'Debloat' @{} { param(`$r) Show-JuicerGuiDebloat `$r.Apps }
    Wait-Gui
    `$script:Gui.Window.Close()
    @{
        Init = `$init; Flipped = (`$flipped -ne `$on); Outcome = `$script:Gui.Last.Results[0].Outcome; Journal = (Read-JuicerJournal).Count
        Messages = @(`$script:Gui.Silent); Pending = [bool]`$script:Gui.Task
    }
}
"@)
        try {
            $out = @($ps.Invoke())
            foreach ($e in $ps.Streams.Error) { Write-Host "    $e" }
            $ps.Streams.Error.Count | Should -Be 0
            $r = $out[-1]
            foreach ($m in $r.Messages) { Write-Host "    mensaje: $m" }
            $r.Pending | Should -BeFalse
            $r.Init.Cpu | Should -Not -BeNullOrEmpty
            $r.Init.Checks | Should -BeGreaterThan 30
            $r.Init.Findings | Should -BeGreaterThan 5
            $r.Flipped | Should -BeTrue
            $r.Outcome | Should -BeIn @('Aplicado', 'Deshecho')
            $r.Journal | Should -Be 0
            @($r.Messages | Where-Object { $_ -like '`[Error`]*' }) | Should -BeNullOrEmpty
        } finally {
            $ps.Dispose()
            $rs.Dispose()
        }
    }

    It 'el arrancador en una línea comprueba la huella, descomprime y Win Juicer arranca' {
        $out = Join-Path ([IO.Path]::GetTempPath()) ('wj-dist-' + [guid]::NewGuid().ToString('N'))
        $r = & (Join-Path (Split-Path -Parent $PSScriptRoot) 'build/Build-Release.ps1') -Out $out -Version 'prueba'
        # Everything but the last line, which would download the real one.
        $lines = [IO.File]::ReadAllLines($r.Launcher)
        Invoke-Expression (($lines | Where-Object { $_ -notlike 'Start-WinJuicerOneLine *' }) -join "`n")
        { Start-WinJuicerOneLine -Source $r.Zip -Sha256 ('0' * 64) -Version 'prueba' -NoLaunch } | Should -Throw '*no coincide*'
        $main = Start-WinJuicerOneLine -Source $r.Zip -Sha256 $r.Sha256 -Version 'prueba' -NoLaunch
        Test-Path -LiteralPath $main | Should -BeTrue
        Test-Path -LiteralPath (Join-Path (Split-Path -Parent $main) 'src\Gui.ps1') | Should -BeTrue
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $main -Lista | Out-Null
        $LASTEXITCODE | Should -Be 0
        Remove-Item -LiteralPath (Split-Path -Parent $main), $out -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'añade y quita una exclusión de Defender' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('wj-def-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        try {
            $t = New-JuicerDefenderTweak $dir 'Prueba'
            $r = Invoke-JuicerTweak $t
            if ($r.Outcome -eq 'Error') { Set-ItResult -Skipped -Because "Defender no está disponible: $($r.Message)"; return }
            $r.Outcome | Should -Be 'Aplicado'
            (Undo-JuicerTweak $t.Id).Outcome | Should -Be 'Deshecho'
            (Get-JuicerTweakState $t).State | Should -Be 'Pendiente'
        } finally {
            Remove-Item -LiteralPath $dir -Force -ErrorAction SilentlyContinue
        }
    }

    It 'WinJuicer.ps1 arranca en Windows PowerShell 5.1 desde la línea de órdenes' {
        $script = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.ps1'
        $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Lista | Out-Host
        $LASTEXITCODE | Should -Be 0
        & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Perfil Extremo -Simular -Si | Out-Host
        $LASTEXITCODE | Should -Be 0
        & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Aplicar 'no.existe' -Si | Out-Host
        $LASTEXITCODE | Should -Be 2
        & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Equipo | Out-Host
        $LASTEXITCODE | Should -Be 0
        & $ps -NoProfile -ExecutionPolicy Bypass -File $script -Recomendado -Simular -Si | Out-Host
        $LASTEXITCODE | Should -Be 0
    }
}
