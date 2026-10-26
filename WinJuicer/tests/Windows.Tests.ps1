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
        { & $b.FeatRead 'NetFx3' } | Should -Not -Throw
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
    Select-JuicerGuiTweaks 'Recomendado'
    `$script:Gui.C.SearchBox.Text = 'steam'
    `$r = @{
        Checks = `$script:Gui.Checks.Count; Apps = `$script:Gui.InstallChecks.Count; Cards = `$script:Gui.C.AuditPanel.Children.Count
        Missing = @(`$script:Gui.C.Keys | Where-Object { `$null -eq `$script:Gui.C[`$_] })
        Visible = @(`$script:Gui.InstallChecks.Values | Where-Object { `$_.Check.Visibility -eq 'Visible' }).Count
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
        } finally {
            $ps.Dispose()
            $rs.Dispose()
        }
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
