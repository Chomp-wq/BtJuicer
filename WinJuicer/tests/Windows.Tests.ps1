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

    It 'lee los monitores y con qué marca el ritmo el frame pacer' {
        $m = @(Get-JuicerMonitors)
        foreach ($x in $m) { Write-Host "    $(if ($x.Info) { Format-JuicerMonitor $x } else { $x.Display.Monitor + ' (sin EDID)' })" }
        { Get-JuicerMonitorFindings $m 'NVIDIA' } | Should -Not -Throw
        Initialize-JuicerNvApi
        [WinJuicer.NvDrs]::SettingVersion | Should -Be 0x13020
        [WinJuicer.NvDrs]::ApplicationVersion | Should -Be 0x4500C
        # The runner has no NVIDIA driver: it must say so, not fail.
        { Get-JuicerFpsBackend } | Should -Not -Throw
        Write-Host "    Frame pacer: '$(Get-JuicerFpsBackend)'"
        # The real refresh rate, from QueryDisplayConfig, next to Windows' round one.
        foreach ($d in @(Get-JuicerDisplays)) {
            Write-Host "    $($d.Device): $($d.Hz) Hz, $($d.ExactHz) Hz reales"
            [Math]::Abs($d.ExactHz - $d.Hz) | Should -BeLessThan 1
        }
        { Get-JuicerPacerConflictsHere } | Should -Not -Throw
        $s = & (Get-JuicerBackend).PacerState
        $s.Keys | Should -Contain 'RtssGames'
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

    It 'activa el mantenimiento de juegos: copia protegida, tarea, y la copia funciona' {
        Register-JuicerUpkeep
        try {
            Test-JuicerUpkeep | Should -BeTrue
            $copy = Join-Path (Get-JuicerInstallDir) 'WinJuicer.ps1'
            Test-Path -LiteralPath $copy | Should -BeTrue
            Test-Path -LiteralPath (Join-Path (Get-JuicerInstallDir) 'src\Upkeep.ps1') | Should -BeTrue
            & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $copy -Mantener | Out-Null
            $LASTEXITCODE | Should -Be 0
        } finally {
            Unregister-JuicerUpkeep
        }
        Test-JuicerUpkeep | Should -BeFalse
        Test-Path -LiteralPath (Get-JuicerInstallDir) | Should -BeFalse
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
        # What powershell.exe prints comes back as a flat list, from 5.1 and from 7.
        $l = & (Get-Module WinJuicer) { Invoke-WinPowerShell "[pscustomobject]@{ Name = 'a' }; [pscustomobject]@{ Name = 'b' }" }
        $l.Count | Should -Be 2
        $l[1].Name | Should -Be 'b'
        # Every app is kept under its own name, not all of them under one.
        $cache = & (Get-Module WinJuicer) { $script:AppxCache = $null; [void](Read-WinAppx 'x'); $script:AppxCache }
        @($cache.Keys | Where-Object { $cache[$_].Name -ne $_ }) | Should -BeNullOrEmpty
        $b = Get-JuicerBackend
        # The window asks for every component when it opens: dism took about
        # a minute here, which is why reading goes through WMI.
        & (Get-Module WinJuicer) { $script:FeatureCache = $null }
        $t = Measure-Command { $f = & $b.FeatRead 'NetFx3' }
        Write-Host ('    características leídas en {0:N1} s; NetFx3: {1}' -f $t.TotalSeconds, $(if ($f) { $f.Enabled } else { 'no existe' }))
        { Get-JuicerCurrentDns } | Should -Not -Throw
    }

    It 've qué programas están abiertos y lee los cierres con error del registro' {
        $b = Get-JuicerBackend
        & $b.ProcRunning ((Get-Process -Id $PID).ProcessName + '.exe') | Should -BeTrue
        & $b.ProcRunning 'no-existe-de-verdad-123.exe' | Should -BeFalse
        & $b.ProcRunning 'raro[1].exe' | Should -BeFalse
        $inc = & $b.AppIncidents ((Get-Date).AddDays(-30))
        # A list, maybe empty, with the program and the time of each.
        $null -eq $inc | Should -BeFalse
        foreach ($i in @($inc)) {
            $i.Exe | Should -Not -BeNullOrEmpty
            { [datetime]$i.Time } | Should -Not -Throw
        }
        $nv = & $b.NvRead 'cs2.exe' ([uint32]0x00A879CF)
        if ($nv) { $nv.ContainsKey('Predefined') | Should -BeTrue }
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
    # The frametime chart: line, target, and both labels; and inside a card.
    `$chart = New-JuicerFrameChart @{ Series = [double[]](5.8, 6.1, 5.9, 40, 5.8); TargetMs = 5.85; MaxMs = 40 }
    `$card = New-JuicerFindingCard (New-JuicerFrameChartFinding @{ Application = 'cs2.exe'; MedianMs = 5.9 } ([double[]](5.8, 6.1, 5.9, 40, 5.8)) 5.85)
    # The gallery: a cover, an icon taken from a real .exe, and a game with
    # no image at all; searching; one game's page; the simple window.
    `$png = Join-Path ([IO.Path]::GetTempPath()) ('wj-icono-' + [guid]::NewGuid().ToString('N') + '.png')
    `$iconOk = Save-JuicerExeIcon (Join-Path `$env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') `$png
    `$iconSize = Read-JuicerImageSize `$png
    `$games = @(
        @{ Id = 'steam:1'; Name = 'Uno'; Launcher = 'Steam'; Dir = 'C:\x'; Exe = 'C:\x\uno.exe'; ExeName = 'uno.exe'; Fps = 171; Cover = @{ Path = `$png; Kind = 'cover' } }
        @{ Id = 'gog:2'; Name = 'Dos'; Launcher = 'GOG'; Dir = 'C:\y'; Exe = 'C:\y\dos.exe'; ExeName = 'dos.exe'; New = `$true; Cover = @{ Path = `$png; Kind = 'icon' } }
        @{ Id = 'custom:tres'; Name = 'Tres'; Launcher = 'custom'; Dir = ''; Exe = 'tres.exe'; ExeName = 'tres.exe' }
    )
    Show-JuicerGuiGallery `$games
    `$script:Gui.C.GameSearch.Text = 'dos'
    `$found = @(`$script:Gui.Sections | ForEach-Object { `$_.Tiles } | Where-Object { `$_.Button.Visibility -eq 'Visible' }).Count
    # Nothing found says so; Esc in the box clears it and everything is back.
    `$script:Gui.C.GameSearch.Text = 'no existe [x'
    `$none = `$script:Gui.C.GameSearchNone.Visibility -eq 'Visible'
    `$cleared = (Invoke-JuicerGuiKey 'Escape' `$false `$script:Gui.C.GameSearch) -and -not `$script:Gui.C.GameSearch.Text -and `$script:Gui.C.GameSearchNone.Visibility -ne 'Visible'
    `$script:Gui.C.GameSearch.Text = ''
    `$page = @{
        Game = `$games[0]; Engine = 'nvidia'; Priority = 'Latencia'; Manual = 0; Auto = @{ Fps = 171; Why = 'x'; Calibrated = `$false }; Competitive = `$true; TwoGpus = `$false
        Last = @{ Date = (Get-Date).ToString('s'); AvgFps = 170; Low1 = 150; Steady = 95; JitterMs = 0.2; InputLatency = 12.3 }
        Chart = @{ Series = [double[]](5.8, 6.1, 5.9, 40, 5.8); TargetMs = 5.85; MaxMs = 40 }
        Tips = @(Get-JuicerGameTips -ExeName 'uno.exe' -GpuVendor 'NVIDIA' -Use 'VRR'); Cover = `$null
    }
    Open-JuicerGuiGame 'steam:1'
    # Its page is read in the background: let it finish, as the window's timer would.
    `$limit = (Get-Date).AddMinutes(3)
    while ((`$script:Gui.Task -or `$script:Gui.Queue.Count -gt 0) -and (Get-Date) -lt `$limit) {
        if (`$script:Gui.Task -and `$script:Gui.Task.Handle.IsCompleted) { Complete-JuicerGuiTask } else { Start-Sleep -Milliseconds 200 }
    }
    `$pageErrors = @(`$script:Gui.Silent | Where-Object { `$_ -like '[[]Error[]]*' })
    `$realStatus = [string]`$script:Gui.C.GameStatus.Text
    Show-JuicerGuiGamePage `$page
    `$pageShown = `$script:Gui.C.GamePage.Visibility -eq 'Visible'
    # An open game, one Win Juicer protected after it failed: the page says so.
    `$page2 = `$page.Clone()
    `$page2.Running = `$true; `$page2.Minimal = `$true
    `$page2.Safe = @{ Kind = 'Cierre'; Time = (Get-Date).ToString('s'); Module = 'x.dll' }
    Show-JuicerGuiGamePage `$page2
    `$notice = (`$script:Gui.C.GameNotice.Visibility -eq 'Visible') -and ([string]`$script:Gui.C.GameNoticeText.Text -like '*está abierto*') -and [bool]`$script:Gui.C.GamePrudent.IsChecked
    Show-JuicerGuiSafety @{ Protected = @(@{ Exe = 'uno.exe'; Name = 'Uno'; Kind = 'Cuelgue'; Time = (Get-Date).ToString('s'); Module = '' }); Warned = @() }
    `$alerts = `$script:Gui.C.SafetyAlerts.Children.Count
    Close-JuicerGuiGame
    Set-JuicerGuiAdvanced `$false
    `$hidden = @(`$script:AdvancedTabs | Where-Object { `$script:Gui.C[`$_].Visibility -ne 'Visible' }).Count
    Set-JuicerGuiAdvanced `$true
    `$script:Gui.Ready = `$true
    Show-JuicerGuiHome
    # Advanced mode: one tweak's details, searching, a level, a whole category.
    Show-JuicerGuiTweakDetail 'ui.carpetas'
    `$detail = `$script:Gui.C.TweakDetail.Children.Count
    `$script:Gui.C.TweakSearch.Text = 'carpetas'
    `$searched = @(`$script:Gui.Checks.Values | Where-Object { `$_.Visibility -eq 'Visible' }).Count
    `$script:Gui.C.TweakSearch.Text = ''
    `$script:Gui.C.TweakLevel.SelectedIndex = 3
    `$extreme = @(`$script:Gui.Checks.Keys | Where-Object { `$script:Gui.Checks[`$_].Visibility -eq 'Visible' } | ForEach-Object { (Find-JuicerTweak `$_).Level } | Select-Object -Unique)
    `$script:Gui.C.TweakLevel.SelectedIndex = 0
    # A button off for what the window shows stays off when a task ends.
    Set-JuicerGuiButton 'BtnPacerForget' `$false
    Set-JuicerGuiBusy `$true
    Set-JuicerGuiBusy `$false
    `$offStays = -not `$script:Gui.C.BtnPacerForget.IsEnabled -and `$script:Gui.C.BtnApply.IsEnabled
    # A late page of a game no longer on screen does not paint over the gallery.
    `$c2 = `$script:Gui.C
    `$c2.GamePage.Visibility = 'Collapsed'; `$c2.GalleryPage.Visibility = 'Visible'; `$script:Gui.Game = `$null
    `$c2.GameTitle.Text = 'antes'
    Show-JuicerGuiGamePage `$page
    `$stale = (`$c2.GameTitle.Text -eq 'antes') -and (`$c2.GalleryPage.Visibility -eq 'Visible')
    # Keys: Esc from a game's page, Ctrl+F in the gallery. The gallery was
    # drawn by hand: going to its tab must not start looking for games.
    `$script:Gui.GamesLoaded = `$true
    `$c2.Tabs.SelectedItem = `$c2.TabJuegos
    `$c2.GalleryPage.Visibility = 'Collapsed'; `$c2.GamePage.Visibility = 'Visible'; `$script:Gui.Game = `$games[0]
    `$esc = (Invoke-JuicerGuiKey 'Escape' `$false) -and `$c2.GalleryPage.Visibility -eq 'Visible'
    `$find = Invoke-JuicerGuiKey 'F' `$true
    Select-JuicerGuiTweaks 'Ninguno'
    Set-JuicerGuiCategoryChecks 'Interfaz' `$true
    `$picked = @(Get-JuicerGuiCheckedTweaks).Count
    `$countText = [string]`$script:Gui.C.TweakCount.Text
    `$r = @{
        IconOk = `$iconOk; IconWidth = `$(if (`$iconSize) { `$iconSize.Width } else { 0 }); Sections = `$script:Gui.Sections.Count; Tiles = `$script:Gui.Tiles.Count; Found = `$found
        PageShown = `$pageShown; Latency = [bool]`$script:Gui.C.GameLatencia.IsChecked; Measure = `$script:Gui.C.GameMeasurePanel.Children.Count
        Tips = `$script:Gui.C.GameTipsPanel.Children.Count; Hidden = `$hidden; Back = (`$script:Gui.C.GalleryPage.Visibility -eq 'Visible'); Home = [string]`$script:Gui.C.HomeHw.Text
        PageErrors = `$pageErrors; RealStatus = `$realStatus; Pending = [bool]`$script:Gui.Task
        Detail = `$detail; Searched = `$searched; Extreme = `$extreme; Picked = `$picked; CountText = `$countText
        OffStays = `$offStays; Stale = `$stale; Esc = `$esc; Find = `$find; None = `$none; Cleared = `$cleared
        UndoNote = [string]`$script:Gui.C.HomeUndoNote.Text; Journal = (Read-JuicerJournal).Count; Notice = `$notice; Alerts = `$alerts
        Chart = `$chart.Children.Count; Card = [bool]`$card
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
            $r.Chart | Should -Be 4
            $r.Card | Should -BeTrue
            $r.IconOk | Should -BeTrue
            $r.IconWidth | Should -BeGreaterOrEqual 32
            $r.Sections | Should -Be 3
            $r.Tiles | Should -Be 3
            $r.Found | Should -Be 1
            $r.PageShown | Should -BeTrue
            $r.Latency | Should -BeTrue
            $r.Measure | Should -Be 1
            $r.Tips | Should -BeGreaterThan 0
            $r.Hidden | Should -Be 7
            $r.Back | Should -BeTrue
            $r.Home | Should -BeLike 'Tu equipo:*'
            $r.PageErrors | Should -BeNullOrEmpty
            $r.Pending | Should -BeFalse
            $r.RealStatus | Should -BeLike 'Steam · *'
            $r.Detail | Should -BeGreaterThan 8
            $r.Searched | Should -BeGreaterOrEqual 1
            $r.Searched | Should -BeLessThan 5
            @($r.Extreme) | Should -Be @(3)
            $r.Picked | Should -BeGreaterThan 0
            $r.CountText | Should -BeLike "$($r.Picked) seleccionado*"
            $r.OffStays | Should -BeTrue
            $r.Stale | Should -BeTrue
            $r.Esc | Should -BeTrue
            $r.Find | Should -BeTrue
            $r.None | Should -BeTrue
            $r.Cleared | Should -BeTrue
            $r.Notice | Should -BeTrue
            $r.Alerts | Should -Be 1
            # Empezar counts the changes the journal holds, not the journal itself.
            if ($r.Journal -eq 0) { $r.UndoNote | Should -BeLike 'Todavía no*' } else { $r.UndoNote | Should -BeLike "*ha hecho $($r.Journal) cambio*" }
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

    # Before the protection: once its task exists, a firewall change starts
    # it, and it would filter the runner's own DNS.
    It 'el cortafuegos: escribe una regla como las de la protección (apagada), la lee igual y la quita' {
        $b = Get-JuicerBackend
        $m = Get-Module WinJuicer
        $remote = @(& $m { ConvertFrom-JuicerAddressSet (Get-JuicerAddressComplement (ConvertTo-JuicerAddressSet @('0.0.0.0', '127.0.0.0/8', '::', '::1', '185.228.168.168', '2a0d:2a00:1::'))) })
        $rule = @{ Name = 'WinJuicer-Prueba-DNS'; Title = 'Win Juicer: prueba'; Description = 'Prueba de Win Juicer'; Protocol = 'UDP'; Port = '53'; Remote = $remote }
        try {
            & $b.FwSet $rule 'Win Juicer - Prueba' -Disabled
            $r = @(& $b.FwRules @('WinJuicer-Prueba-DNS', 'WinJuicer-No-Existe'))
            $r.Count | Should -Be 1
            foreach ($x in $r[0].RemoteAddress) { Write-Host "    $x" }
            $r[0].Enabled | Should -BeFalse
            & $m { param($w, $h) Test-JuicerShieldFwRule $w $h } $rule $r[0] | Should -BeFalse
            $on = $r[0].Clone()
            $on.Enabled = $true
            & $m { param($w, $h) Test-JuicerShieldFwRule $w $h } $rule $on | Should -BeTrue
            # Written again over itself: still one rule.
            & $b.FwSet $rule 'Win Juicer - Prueba' -Disabled
            @(Get-NetFirewallRule -Name 'WinJuicer-Prueba-DNS' -ErrorAction SilentlyContinue).Count | Should -Be 1
            $s = & $b.FwState
            Write-Host "    Perfiles apagados: $(@($s.Off) -join ', '); otro cortafuegos: $($s.ThirdParty)"
        } finally {
            Remove-NetFirewallRule -Name 'WinJuicer-Prueba-DNS' -ErrorAction SilentlyContinue
        }
        @(Get-NetFirewallRule -Name 'WinJuicer-Prueba-DNS' -ErrorAction SilentlyContinue).Count | Should -Be 0
    }

    # Last: it is for good, and the runner is thrown away after. The runner's
    # network stays as it is: its adapters and its firewall are pretend ones
    # here, and the task is stopped at the end, before anything can start it.
    It 'activa la protección contra contenido adulto: políticas, hosts, su tarea y su copia, sin tocar la red del runner' {
        $b = Get-JuicerBackend
        $saved = @{ DnsSet = $b.DnsSet; All = $b.NetAdaptersAll; FwSet = $b.FwSet; FwRules = $b.FwRules; FwOn = $b.FwOn }
        $calls = New-Object System.Collections.ArrayList
        $rules = @{}
        $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
        $before = [IO.File]::ReadAllText($hosts)
        try {
            $b.NetAdaptersAll = { , @(@{ Guid = '{0F0F0F0F-0000-0000-0000-000000000001}'; Name = 'Prueba'; Ipv6 = $true }) }
            $b.DnsSet = { param($i, $v4, $v6) [void]$calls.Add(@($i) + @($v4)) }.GetNewClosure()
            $b.FwSet = { param($Rule, $Group) $rules[$Rule.Name] = @{ Name = $Rule.Name; Enabled = $true; Action = 'Block'; Direction = 'Outbound'; Profile = 'Any'; Protocol = $Rule.Protocol; RemotePort = @($Rule.Port); RemoteAddress = @($Rule.Remote) } }.GetNewClosure()
            $b.FwRules = { param($Names) , @($Names | ForEach-Object { $rules[$_] } | Where-Object { $_ }) }.GetNewClosure()
            $b.FwOn = { param($Profiles) [void]$calls.Add('perfiles') }.GetNewClosure()
            $r = @(Enable-JuicerShield)
            foreach ($x in $r) { Write-Host "    $x" }
            Test-JuicerShield | Should -BeTrue
            (Get-JuicerShieldInfo).Level | Should -Be 2
            @($calls | Where-Object { $_ -ne 'perfiles' }).Count | Should -Be 1
            $rules.Count | Should -Be 6
            $chrome = Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Google\Chrome'
            $chrome.ForceGoogleSafeSearch | Should -Be 1
            $chrome.DnsOverHttpsMode | Should -Be 'off'
            $chrome.IncognitoModeAvailability | Should -Be 1
            $chrome.ProxyMode | Should -Be 'direct'
            (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Edge').InPrivateModeAvailability | Should -Be 1
            (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS').Locked | Should -Be 1
            (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Mozilla\Firefox').DisablePrivateBrowsing | Should -Be 1
            # The hosts file: what it had, and the protection's block; Windows reads it.
            $now = [IO.File]::ReadAllText($hosts)
            $now.StartsWith($before.TrimEnd()) | Should -BeTrue
            $now | Should -Match '(?m)^0\.0\.0\.0 api\.sec-tunnel\.com\r?$'
            @(Resolve-DnsName -Name 'api.sec-tunnel.com' -Type A -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -eq '0.0.0.0' }).Count | Should -BeGreaterThan 0
            @(Add-JuicerShieldBlock 'ejemplo.com') | Should -Be @('ejemplo.com', 'www.ejemplo.com')
            [IO.File]::ReadAllText($hosts) | Should -Match '(?m)^0\.0\.0\.0 www\.ejemplo\.com\r?$'
            $t = Get-ScheduledTask -TaskName 'Win Juicer - Protección contra contenido adulto' -ErrorAction Stop
            $t.Principal.UserId | Should -Be 'SYSTEM'
            @($t.Triggers).Count | Should -BeGreaterOrEqual 4
            $t.Actions[0].Arguments | Should -BeLike '*-ProteccionAdultos Mantener*'
            (Get-ItemProperty 'HKLM:\SOFTWARE\WinJuicer\Proteccion').Tarea | Should -Be 2
            # All in place: only the pretend adapter, which keeps nothing, is redone.
            @(Repair-JuicerShield | Where-Object { $_ -notlike 'DNS filtrado*' -and $_ -notlike 'Cortafuegos de Windows*' }) | Should -BeNullOrEmpty
            # The copy the task runs answers, from Windows PowerShell.
            $copy = Join-Path $env:ProgramFiles 'WinJuicer\WinJuicer.ps1'
            Test-Path -LiteralPath $copy | Should -BeTrue
            $out = & (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $copy -ProteccionAdultos Estado 2>&1
            $LASTEXITCODE | Should -Be 0
            ($out -join ' ') | Should -BeLike '*ACTIVA*'
            ($out -join ' ') | Should -BeLike '*ejemplo.com*'
        } finally {
            foreach ($k in 'DnsSet', 'FwSet', 'FwRules', 'FwOn') { $b[$k] = $saved[$k] }
            $b.NetAdaptersAll = $saved.All
            Disable-ScheduledTask -TaskName 'Win Juicer - Protección contra contenido adulto' -ErrorAction SilentlyContinue | Out-Null
        }
    }
}
