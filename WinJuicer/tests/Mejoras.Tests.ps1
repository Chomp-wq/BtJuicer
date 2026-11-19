# Confirmaciones con detalle, menús de consola, «Listo para jugar» (grabación y VBS),
# juegos ocultos, edad de la calibración y vista previa de la limpieza.
# Todo sobre la máquina en memoria y carpetas temporales propias.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Mod = Get-Module WinJuicer
}

Describe 'Confirmaciones con detalle' {
    It 'enseña los ocho primeros y «y N más»; marca reinicio y volver a entrar, y lo dice una vez' {
        $items = @(1..11 | ForEach-Object { @{ Title = "Ajuste $_"; Reboot = $(if ($_ -eq 2) { 'Reinicio' } elseif ($_ -eq 3) { 'Sesion' } else { 'No' }) } })
        $p = Format-JuicerPreviewLines $items
        @($p.Lines).Count | Should -Be 9
        $p.Lines[0] | Should -Be '· Ajuste 1'
        $p.Lines[1] | Should -BeLike '*Ajuste 2*reiniciar*'
        $p.Lines[2] | Should -BeLike '*Ajuste 3*volver a entrar*'
        $p.Lines[8] | Should -Be 'y 3 más'
        $p.Note | Should -BeLike '*reinicies Windows*'
        (Format-JuicerPreviewLines @(@{ Title = 'Uno'; Reboot = 'Explorador' })).Note | Should -BeNullOrEmpty
        @((Format-JuicerPreviewLines @(@{ Title = 'Uno'; Reboot = 'No' })).Lines).Count | Should -Be 1
    }

    It '«Optimizar Windows» lista los ajustes antes de preguntar' {
        $t = @(1..3 | ForEach-Object { @{ Title = "Ajuste $_"; Reboot = $(if ($_ -eq 1) { 'Reinicio' } else { 'No' }) } })
        $text = Format-JuicerApplyConfirm $t
        $text | Should -BeLike '*Se aplicarán 3 ajustes*· Ajuste 1*reiniciar*· Ajuste 2*punto de restauración*¿Seguir?'
        (Format-JuicerApplyConfirm $t -NoQuestion) | Should -Not -BeLike '*¿Seguir?*'
        (Format-JuicerApplyConfirm @($t[1])) | Should -BeLike '*Se aplicará 1 ajuste*'
    }

    It '«Deshacer todo» lista lo que se revierte y dice lo que se queda' {
        $j = @(1..10 | ForEach-Object { [pscustomobject]@{ Id = "x.$_"; Title = "Cambio $_"; Reboot = 'No' } })
        $text = Format-JuicerUndoAllConfirm $j
        # The most recent first, the way they are undone.
        $text | Should -BeLike '*Se deshacerán estos 10 cambios*· Cambio 10*· Cambio 3*y 2 más*'
        $text | Should -BeLike '*no puede deshacer*protección contra contenido adulto*Mantenimiento*winget*'
        $text | Should -Not -BeLike '*reinstalan desde Microsoft Store*' -Because 'sin apps quitadas no hay nada que reinstalar'
        $apps = @([pscustomobject]@{ Id = 'app:Microsoft.BingNews'; Title = 'Quitar Noticias'; Reboot = 'No' })
        (Format-JuicerUndoAllConfirm $apps) | Should -BeLike '*Se deshará este cambio*reinstalan desde Microsoft Store*'
    }
}

Describe 'Menús de consola' {
    BeforeEach {
        & $Mod { $script:Screen = $false; $script:InputClosed = $false; $script:MenuNotice = ''; $script:ReadCalls = 0 }
    }
    AfterEach {
        & $Mod { $script:Screen = $true; $script:InputClosed = $false; $script:MenuNotice = '' }
    }

    It 'una opción que no existe se dice, y la entrada vacía no' {
        Mock -ModuleName WinJuicer Read-Host { $script:ReadCalls++; if ($script:ReadCalls -eq 1) { 'zz' } elseif ($script:ReadCalls -eq 2) { '' } elseif ($script:ReadCalls -eq 3) { '0' } else { throw 'bucle' } }
        $out = & { Show-JuicerMeasure } *>&1 | Out-String
        $out | Should -BeLike '*Opción no válida: zz*'
        ([regex]::Matches($out, 'Opción no válida')).Count | Should -Be 1
    }

    It 'una opción larga se acorta' {
        & $Mod { Write-JuicerInvalidChoice ('x' * 50) }
        (& $Mod { $script:MenuNotice }).Length | Should -BeLessThan 50
        & $Mod { $script:MenuNotice = ''; Write-JuicerInvalidChoice '   ' }
        (& $Mod { $script:MenuNotice }) | Should -BeNullOrEmpty
    }

    It 'sin entrada (Read-Host devuelve null) los menús salen en vez de dar vueltas' {
        Mock -ModuleName WinJuicer Read-Host { $script:ReadCalls++; if ($script:ReadCalls -gt 20) { throw 'bucle' }; $null }
        { Show-JuicerMeasure 6>$null } | Should -Not -Throw
        & $Mod { $script:ReadCalls = 0; $script:InputClosed = $false }
        { Show-JuicerGames 6>$null } | Should -Not -Throw
        & $Mod { $script:ReadCalls = 0; $script:InputClosed = $false }
        Mock -ModuleName WinJuicer Get-JuicerUpdateNotice { $null }
        Mock -ModuleName WinJuicer Get-JuicerUserMismatch { $null }
        Mock -ModuleName WinJuicer Get-JuicerDrift { @() }
        { Show-JuicerMainMenu 6>$null } | Should -Not -Throw
        (& $Mod { $script:InputClosed }) | Should -BeTrue
    }
}

Describe 'Listo para jugar: grabación en segundo plano y VBS' {
    It 'la grabación activa avisa con su motivo y apunta al ajuste' {
        $r = @(Get-JuicerReadyStatus @{ GameDvr = $true })
        $r.Count | Should -Be 1
        $r[0].Key | Should -Be 'grabacion'
        $r[0].Ok | Should -BeFalse
        $r[0].Reason | Should -BeLike '*graba en segundo plano: cuesta FPS*juegos.grabacion*'
        $off = @(Get-JuicerReadyStatus @{ GameDvr = $false })
        $off[0].Ok | Should -BeTrue
        @(Get-JuicerReadyStatus @{ GameDvr = $null }).Count | Should -Be 0
    }

    It 'VBS en marcha es sólo informativo: nunca cuenta como «por mirar»' {
        $r = @(Get-JuicerReadyStatus @{ Vbs = $true; Hvci = $true })
        $r.Count | Should -Be 1
        $r[0].Key | Should -Be 'vbs'
        $r[0].Info | Should -BeTrue
        $r[0].Ok | Should -BeTrue
        $r[0].Title | Should -BeLike '*integridad de memoria (HVCI)*'
        $r[0].Reason | Should -BeLike '*Extremo*'
        (@(Get-JuicerReadyStatus @{ Vbs = $true; Hvci = $false })[0]).Title | Should -BeLike '*sin integridad de memoria*'
        # Not running, or unknown: nothing to say.
        @(Get-JuicerReadyStatus @{ Vbs = $false }).Count | Should -Be 0
        @(Get-JuicerReadyStatus @{ Vbs = $null }).Count | Should -Be 0
        @(Get-JuicerReadyStatus @{ Vbs = $true; GameMode = $true } | Where-Object { -not $_.Ok }).Count | Should -Be 0
    }

    It 'lee la grabación de los mismos valores que escribe el ajuste' {
        $m = New-FakeMachine
        Get-JuicerGameDvrState | Should -BeNullOrEmpty
        $gdvr = 'HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR'
        Write-JuicerReg $gdvr 'HistoricalCaptureEnabled' 'DWord' 1
        Get-JuicerGameDvrState | Should -BeTrue
        Write-JuicerReg $gdvr 'AppCaptureEnabled' 'DWord' 0
        Get-JuicerGameDvrState | Should -BeFalse
        # What the tweak writes reads as «off».
        Write-JuicerReg $gdvr 'AppCaptureEnabled' 'DWord' 1
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.grabacion'))
        Get-JuicerGameDvrState | Should -BeFalse
        # Without the background-recording value itself it cannot be said.
        Remove-JuicerReg $gdvr 'HistoricalCaptureEnabled'
        Remove-JuicerReg $gdvr 'AppCaptureEnabled'
        Remove-JuicerReg 'HKCU\System\GameConfigStore' 'GameDVR_Enabled'
        Write-JuicerReg 'HKCU\System\GameConfigStore' 'GameDVR_Enabled' 'DWord' 1
        Get-JuicerGameDvrState | Should -BeNullOrEmpty
    }
}

Describe 'Juegos ocultos' {
    BeforeEach {
        $script:M = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
        $script:HideDir = Join-Path ([IO.Path]::GetTempPath()) ('wj-hide-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $HideDir | Out-Null
        foreach ($f in 'A.exe', 'B.exe') { Set-Content -LiteralPath (Join-Path $HideDir $f) -Value 'x' }
    }
    AfterEach {
        Remove-Item -LiteralPath $HideDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
    }

    It 'ocultar saca el juego de la lista, y mostrarlo lo devuelve sin hacerlo «nuevo»' {
        $d = $HideDir
        $col = { @((New-JuicerGame 'Steam' '1' 'Uno' $d (Join-Path $d 'A.exe')), (New-JuicerGame 'Steam' '2' 'Dos' $d (Join-Path $d 'B.exe'))) }.GetNewClosure()
        $find = { param($Folder, $Name) '' }
        @(Get-JuicerGames -Collectors @($col) -FindExe $find).Count | Should -Be 2
        Set-JuicerGameHidden 'steam:1' $true
        Get-JuicerHiddenGameIds | Should -Be @('steam:1')
        $g = @(Get-JuicerGames -Collectors @($col) -FindExe $find)
        $g.Count | Should -Be 1
        $g[0].Name | Should -Be 'Dos'
        $all = @(Get-JuicerGames -Collectors @($col) -FindExe $find -IncludeHidden)
        $all.Count | Should -Be 2
        ($all | Where-Object { $_.Id -eq 'steam:1' }).Hidden | Should -BeTrue
        ($all | Where-Object { $_.Id -eq 'steam:2' }).Hidden | Should -BeFalse
        # Twice does not repeat it, and showing it again brings it back as a known game.
        Set-JuicerGameHidden 'steam:1' $true
        @(Get-JuicerHiddenGameIds).Count | Should -Be 1
        Set-JuicerGameHidden 'steam:1' $false
        @(Get-JuicerHiddenGameIds).Count | Should -Be 0
        $back = @(Get-JuicerGames -Collectors @($col) -FindExe $find)
        $back.Count | Should -Be 2
        @($back | Where-Object { $_.New }).Count | Should -Be 0
    }

    It 'queda en juegos.json y un archivo dañado no rompe nada' {
        Set-JuicerGameHidden 'gog:7' $true
        (Get-Content -LiteralPath (Get-JuicerLibraryPath) -Raw) | Should -BeLike '*gog:7*'
        (Read-JuicerLibraryState).Hidden | Should -Contain 'gog:7'
        Set-Content -LiteralPath (Get-JuicerLibraryPath) -Value '{ no es json'
        @((Read-JuicerLibraryState).Hidden).Count | Should -Be 0
        { Get-JuicerGames -Collectors @() } | Should -Not -Throw
    }

    It 'ocultar un juego no toca lo que Win Juicer le puso' {
        $d = $HideDir
        $col = { @(New-JuicerGame 'Steam' '1' 'Uno' $d (Join-Path $d 'A.exe')) }.GetNewClosure()
        $find = { param($Folder, $Name) '' }
        $g = @(Get-JuicerGames -Collectors @($col) -FindExe $find)
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $null }
        [void](Invoke-JuicerTweak (New-JuicerPriorityTweak $g[0].Exe))
        Set-JuicerGameHidden $g[0].Id $true
        @(Get-JuicerJournalEntry (Read-JuicerJournal) "juego:prioridad:$($g[0].ExeName)").Count | Should -BeGreaterThan 0
    }
}

Describe 'Edad de la calibración' {
    It 'dice cuánto hace y a cuántos FPS' {
        $now = [datetime]'2026-06-30T12:00:00'
        (Get-JuicerCalibrationAge '2026-06-18T12:00:00' 141 $now).Text | Should -Be 'calibrado hace 12 días a 141 FPS'
        (Get-JuicerCalibrationAge '2026-06-29T10:00:00' 141 $now).Text | Should -Be 'calibrado hace 1 día a 141 FPS'
        (Get-JuicerCalibrationAge '2026-06-30T08:00:00' 60 $now).Text | Should -Be 'calibrado hoy a 60 FPS'
        # A date in the future (the clock moved) is today, never negative.
        (Get-JuicerCalibrationAge '2026-07-05T12:00:00' 60 $now).Days | Should -Be 0
    }

    It 'sin pasar de 30 días no hay aviso; después, una pista apagada' {
        $now = [datetime]'2026-06-30T12:00:00'
        $young = Get-JuicerCalibrationAge '2026-06-05T12:00:00' 141 $now
        $young.Stale | Should -BeFalse
        $young.Hint | Should -BeNullOrEmpty
        $young.Sentence | Should -Be 'Calibrado hace 25 días a 141 FPS.'
        $old = Get-JuicerCalibrationAge '2026-04-01T12:00:00' 141 $now
        $old.Stale | Should -BeTrue
        $old.Hint | Should -Be 'puede haber cambiado (parche, ajustes): vuelve a calibrar'
        $old.Sentence | Should -BeLike 'Calibrado hace 90 días a 141 FPS. Puede haber cambiado*vuelve a calibrar.'
    }

    It 'sin fecha legible o sin FPS no dice nada' {
        Get-JuicerCalibrationAge '' 141 | Should -BeNullOrEmpty
        Get-JuicerCalibrationAge 'ayer más o menos' 141 | Should -BeNullOrEmpty
        Get-JuicerCalibrationAge '2026-06-05T12:00:00' 0 | Should -BeNullOrEmpty
    }

    It 'el estado del juego lo incluye cuando tiene frame pacer' {
        $when = (Get-Date).AddDays(-12).ToString('s')
        # The age is shown when the calibration is the one in force (see Pacer.Tests.ps1 for the rest).
        $g = @{ Fps = 118; CalFps = 118; CalDate = $when; CalState = 'Activa' }
        (Format-JuicerGameStatus $g) | Should -BeLike '*calibrado hace 12 días a 118 FPS*'
        (Format-JuicerGameStatus @{ Fps = 118; CalFps = 0; CalDate = '' }) | Should -Not -BeLike '*calibrado*'
        (Format-JuicerGameStatus @{ Fps = $null; CalFps = 118; CalDate = $when }) | Should -Not -BeLike '*calibrado*'
    }
}

Describe 'Limpieza: vista previa' {
    BeforeEach {
        $script:CleanRoot = Join-Path ([IO.Path]::GetTempPath()) ('wj-clean-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $CleanRoot 'temp\sub'), (Join-Path $CleanRoot 'wu') | Out-Null
        $old = (Get-Date).AddDays(-5)
        foreach ($f in 'temp\a.tmp', 'temp\sub\b.tmp', 'wu\dl.bin') {
            $p = Join-Path $CleanRoot $f
            [IO.File]::WriteAllBytes($p, (New-Object byte[] 1000))
            (Get-Item -LiteralPath $p).LastWriteTime = $old
        }
        # One recent file: it is not touched, so it is not counted.
        [IO.File]::WriteAllBytes((Join-Path $CleanRoot 'temp\nuevo.tmp'), (New-Object byte[] 500))
    }
    AfterEach { Remove-Item -LiteralPath $CleanRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'mide sin borrar nada, con la misma regla de edad' {
        $m = Measure-JuicerFolder -Path (Join-Path $CleanRoot 'temp') -OlderThanHours 24
        $m.Bytes | Should -Be 2000
        $m.Files | Should -Be 2
        $m.Skipped | Should -Be 1
        (Get-ChildItem -LiteralPath $CleanRoot -Recurse -File).Count | Should -Be 4
        (Measure-JuicerFolder -Path (Join-Path $CleanRoot 'temp') -OlderThanHours 0).Bytes | Should -Be 2500
        (Measure-JuicerFolder -Path (Join-Path $CleanRoot 'no-existe')).Bytes | Should -Be 0
    }

    It 'no mide lo que la guarda de rutas se niega a limpiar' {
        $root = [IO.Path]::GetPathRoot([IO.Path]::GetTempPath())
        $m = Measure-JuicerFolder -Path $root -OlderThanHours 0
        $m.Refused | Should -BeTrue
        $m.Bytes | Should -Be 0
    }

    It 'da el tamaño por carpeta y el total, y deja las descargas de Windows Update si hay un reinicio pendiente' {
        $targets = @(
            @{ Name = 'Temporales'; Path = (Join-Path $CleanRoot 'temp'); Hours = 24 }
            @{ Name = 'Descargas de Windows Update'; Path = (Join-Path $CleanRoot 'wu'); Hours = 0; Services = @('wuauserv', 'bits') }
        )
        $p = Get-JuicerCleanupPreview -Targets $targets -RebootPending $false
        $p.Items[0].Bytes | Should -Be 2000
        $p.Items[1].Bytes | Should -Be 1000
        $p.Total | Should -Be 3000
        $text = (Format-JuicerCleanupPreview $p) -join "`n"
        $text | Should -BeLike '*Temporales:*Descargas de Windows Update:*Total:*'
        $pending = Get-JuicerCleanupPreview -Targets $targets -RebootPending $true
        $pending.Items[1].Bytes | Should -Be 0
        $pending.Items[1].Note | Should -BeLike '*reinicio pendiente*'
        $pending.Total | Should -Be 2000
        ((Format-JuicerCleanupPreview $pending) -join "`n") | Should -BeLike '*Descargas de Windows Update: sin tocar*'
        (Get-ChildItem -LiteralPath $CleanRoot -Recurse -File).Count | Should -Be 4
    }

    It 'sabe cuándo Windows espera un reinicio' {
        $m = New-FakeMachine
        Test-JuicerRebootPending | Should -BeFalse
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired' 'x' 'DWord' 1
        Test-JuicerRebootPending | Should -BeTrue
    }
}

Describe 'Catálogo: impacto y red' {
    It 'quitar animaciones no da FPS, así que su impacto es bajo' {
        $t = Find-JuicerTweak 'ui.animaciones'
        $t.Impact | Should -Be 'Bajo'
        $t.Gain | Should -BeLike '*No da FPS*'
        foreach ($x in @(Get-JuicerCatalog | Where-Object { $_.Id -like 'ui.*' })) {
            # Nothing in the interface gives FPS: none claims more than «Medio».
            $x.Impact | Should -BeIn @('Bajo', 'Medio') -Because $x.Id
        }
    }

    It 'Nagle dice que sólo ayuda a los juegos TCP y que sólo cubre los adaptadores de ahora' {
        $t = Find-JuicerTweak 'red.nagle'
        $t.Gain | Should -BeLike '*sólo ayuda a los juegos que usan TCP*'
        $t.Gain | Should -BeLike '*UDP*'
        $t.What | Should -BeLike '*existen cuando lo aplicas*'
        $t.Level | Should -Be 2
    }
}
