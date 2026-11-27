# Frame pacer, second round: what holds a game under its cap when it is not the PC
# (Reflex, Ultra, Radeon Chill), what a game's folder and its own settings say
# (Reflex and frame generation files, Unreal's limit), rates left behind, caps the
# driver wiped, and the calibration only when it is in force.
# Every test works on the in-memory machine, the throwaway home of Initialize-JuicerTest
# and temp folders of its own.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    # PresentMon rows: frame time, processor and graphics card busy time.
    function New-PacedRows {
        param([double[]]$Times, [double]$Work, [string]$App = 'marvel-win64-shipping.exe')
        $inv = [Globalization.CultureInfo]::InvariantCulture
        foreach ($t in $Times) {
            [pscustomobject][ordered]@{
                Application = $App; ProcessID = '100'; SyncInterval = '1'; AllowsTearing = '0'; PresentMode = 'Hardware: Independent Flip'
                FrameTime = $t.ToString($inv); CPUBusy = ($Work * 0.8).ToString($inv); GPUBusy = $Work.ToString($inv); AnimationError = '0.05'
            }
        }
    }

    function New-TestMonitor {
        param([int]$Hz = 180, [bool]$Vrr = $true, [string]$Id = 'AUS27A3')
        @{
            Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; MonitorId = "\\?\DISPLAY#$Id#5&1&0&UID1#{e6f07b5f}"; Hz = $Hz; MaxHz = $Hz; ExactHz = [double]$Hz; Primary = $true; RefreshRates = @(60, 144, $Hz) }
            Info = @{ Brand = 'ASUS'; Name = 'VG27AQ3A' }; Vrr = $(if ($Vrr) { @{ Min = 48; Max = $Hz; Kind = 'FreeSync' } } else { $null })
        }
    }

    function New-TestTempDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ('wj-pacer-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        $d
    }

    function New-TestFile {
        param([string]$Path, [string]$Text = 'x')
        New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
        [IO.File]::WriteAllText($Path, $Text)
    }

    $script:NoConflictState = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0 }
}

Describe 'Calibrar con el tope de Reflex (178 a 180 Hz)' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
        # 5.85 ms a cada fotograma: 171 FPS parejos, con la gráfica y el procesador sobrados.
        $script:AtReflex = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
    }

    It 'con 178 puestos y una media de 171 sobrada, no baja y dice que lo limita Reflex' {
        $c = Get-JuicerPacerCalibration $AtReflex 178 171 'VRR' 48 @(60, 144, 180) 180 'Fluidez' 'NVIDIA'
        $c.Action | Should -Be 'Reflex'
        $c.Fps | Should -Be 178
        $c.Suggest | Should -Be 171
        $c.Why | Should -BeLike '*lo limita Reflex o el modo de baja latencia Ultra con G-SYNC (tope 171), no tu PC*'
        # With the card unknown it still reads the same: the figures are what shows it.
        (Get-JuicerPacerCalibration $AtReflex 178 171 'VRR' 48 @() 180).Action | Should -Be 'Reflex'
        (Get-JuicerPacerCalibration $AtReflex 178 171 'EstroboSync' 48 @() 180 'Fluidez' 'NVIDIA').Action | Should -Be 'Reflex'
    }

    It 'no lo confunde: sin margen, con otra gráfica, sin VRR, con el ritmo ya en 171 o por encima de los Hz' {
        # A graphics card flat out is a PC that cannot: the old path lowers it.
        $busy = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 5.7)
        (Get-JuicerPacerCalibration $busy 178 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA').Action | Should -Not -Be 'Reflex'
        (Get-JuicerPacerCalibration $AtReflex 178 171 'VRR' 48 @() 180 'Fluidez' 'AMD').Action | Should -Not -Be 'Reflex'
        (Get-JuicerPacerCalibration $AtReflex 178 171 'Fijo' 0 @() 180 'Fluidez' 'NVIDIA').Action | Should -Not -Be 'Reflex'
        # At the cap itself, that is just holding it.
        (Get-JuicerPacerCalibration $AtReflex 171 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA').Action | Should -Be 'Mantener'
        # A game that really misses (uneven, slower than the Reflex cap) still goes down.
        $slow = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        (Get-JuicerPacerCalibration $slow 178 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA').Action | Should -Be 'Bajar'
    }

    It 'al calibrar el juego, el ritmo de 178 que elegiste se queda y no se guarda ninguna calibración' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
        $r = Set-JuicerPacerFps 'Marvel-Win64-Shipping.exe' 178 $Mon
        $r.Outcome | Should -Be 'Aplicado'
        $AtReflex.Date = (Get-Date).ToString('s')
        $res = $AtReflex
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: marvel' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $res }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'marvel-win64-shipping.exe' -Monitor $Mon)
        $f[-1].Title | Should -BeLike 'Lo limita Reflex a 171 FPS, no tu PC*'
        $f[-1].Severity | Should -Be 'Info'
        $f[-1].Detail | Should -BeLike '*lo limita Reflex o el modo de baja latencia Ultra con G-SYNC (tope 171), no tu PC*'
        Get-JuicerPacerFps 'marvel-win64-shipping.exe' | Should -Be 178
        $M.Backend.State.FpsLimits['marvel-win64-shipping.exe'] | Should -Be 178
        (Read-JuicerPacer).Calibrated.ContainsKey('marvel-win64-shipping.exe') | Should -BeFalse
    }
}

Describe 'Qué limita al juego, según la medida' {
    BeforeAll {
        $script:Even = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        $script:Slow = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.0) * 400)) 3.0)
    }

    It 'una media justo en el tope de Reflex, con margen, lo nombra y propone ese ritmo' {
        $f = @(Get-JuicerPacerFindings $Even 178 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'NVIDIA')
        $f[0].Severity | Should -Be 'Info'
        $f[0].Title | Should -BeLike 'Se queda en 171 FPS con el ritmo en 178*Reflex*Ultra*'
        $f[0].Detail | Should -BeLike '*171 FPS*Reflex*Ultra*G-SYNC*no es tu PC*Pon el ritmo de este juego en 171 FPS*'
        @($f | Where-Object { $_.Title -like 'No sostiene*' }).Count | Should -Be 0
        # Without the screen's data, the old reading: it does not hold 178.
        @(Get-JuicerPacerFindings $Even 178)[0].Title | Should -BeLike 'No sostiene 178 FPS*'
        # AMD has no Reflex: the cap it sits on is something else's.
        @(Get-JuicerPacerFindings $Even 178 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'AMD')[0].Title | Should -Not -BeLike 'Se queda en 171*'
        # At or below the Reflex cap, or without VRR, it is not this.
        @(Get-JuicerPacerFindings $Even 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'NVIDIA')[0].Title | Should -Be 'Ritmo clavado a 171 FPS'
        # Without VRR there is no Reflex cap to blame: something else holds it.
        @(Get-JuicerPacerFindings $Even 178 0 'nvidia' -Hz 180 -Use 'Fijo' -GpuVendor 'NVIDIA')[0].Title | Should -BeLike 'Algo externo limita*'
    }

    It 'una media por debajo del ritmo, pareja y con margen, y que no es la fórmula, dice «algo externo limita» y lista por marca' {
        $nv = @(Get-JuicerPacerFindings $Slow 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'NVIDIA')
        $nv[0].Severity | Should -Be 'Medio'
        $nv[0].Title | Should -BeLike 'Algo externo limita el juego a 143 FPS*'
        $nv[0].Detail | Should -BeLike '*Es lo que muestra la medida*ni es tu PC ni es el ritmo*panel de NVIDIA*Ultra o Reflex*'
        $nv[0].Detail | Should -Not -BeLike '*Radeon Chill*'
        $amd = @(Get-JuicerPacerFindings $Slow 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'AMD')
        $amd[0].Title | Should -BeLike 'Algo externo limita*'
        $amd[0].Detail | Should -BeLike '*límite de FPS del propio juego, Radeon Chill o Frame Rate Target Control (FRTC)*V-Sync contra otra pantalla*'
        @(@(Get-JuicerPacerFindings $Slow 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor '')[0].Detail) | Should -BeLike '*Radeon Chill o FRTC (AMD)*'
    }

    It 'sin margen en el PC, o con fotogramas irregulares, no culpa a nada de fuera' {
        $busy = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.0) * 400)) 6.9)
        @(Get-JuicerPacerFindings $busy 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'NVIDIA')[0].Title | Should -BeLike 'No sostiene*'
        $uneven = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.0, 9.0) * 200)) 3.0)
        @(Get-JuicerPacerFindings $uneven 171 0 'nvidia' -Hz 180 -Use 'VRR' -GpuVendor 'NVIDIA')[0].Title | Should -Not -BeLike 'Algo externo*'
    }
}

Describe 'Reflex y generación de fotogramas desde la carpeta del juego' {
    BeforeEach {
        $script:M = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
        $script:TechRoot = New-TestTempDir
    }
    AfterEach { Remove-Item -LiteralPath $TechRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'encuentra los archivos por nombre hasta tres niveles, y la carpeta del .exe aunque esté más abajo' {
        $game = Join-Path $TechRoot 'Juego'
        New-TestFile (Join-Path $game 'a\b\c\SL.Reflex.dll')
        New-TestFile (Join-Path $game 'ffx_frameinterpolation_x64.dll')
        New-TestFile (Join-Path $game 'a\b\c\d\e\nvngx_dlssg.dll')
        $t = Find-JuicerGameTech $game
        $t.Reflex | Should -BeTrue
        $t.Fsr3FG | Should -BeTrue
        $t.DlssFG | Should -BeFalse -Because 'está a cinco niveles'
        $t.Files | Should -Contain 'sl.reflex.dll'
        # The .exe's own folder is looked at too.
        (Find-JuicerGameTech $game (Join-Path $game 'a\b\c\d\e')).DlssFG | Should -BeTrue
        (Find-JuicerGameTech (Join-Path $TechRoot 'noexiste')).Reflex | Should -BeFalse
        Get-JuicerFrameGenName @{ DlssFG = $true; Fsr3FG = $true } | Should -Be 'DLSS Frame Generation y FSR 3 Frame Generation'
        Get-JuicerFrameGenName @{ DlssFG = $false; Fsr3FG = $false } | Should -Be ''
        Get-JuicerFrameGenName $null | Should -Be ''
    }

    It 'cuenta como máximo los archivos que se le dicen y no revienta con una carpeta enorme' {
        $game = Join-Path $TechRoot 'Grande'
        1..40 | ForEach-Object { New-TestFile (Join-Path $game "relleno$_.bin") }
        New-TestFile (Join-Path $game 'sub\sl.reflex.dll')
        (Find-JuicerGameTech $game '' 10).Reflex | Should -BeFalse
        (Find-JuicerGameTech $game).Reflex | Should -BeTrue
    }

    It 'lo guarda en juegos.json con la fecha de la carpeta y lo busca otra vez sólo si cambia' {
        $game = Join-Path $TechRoot 'Juego2'
        New-TestFile (Join-Path $game 'bin\sl.reflex.dll')
        New-TestFile (Join-Path $game 'bin\juego2.exe')
        $g = @{ ExeName = 'juego2.exe'; Dir = $game; Exe = (Join-Path $game 'bin\juego2.exe') }
        Get-JuicerGameTech 'juego2.exe' | Should -BeNullOrEmpty
        (Update-JuicerGameTech $g).Reflex | Should -BeTrue
        $saved = (Read-JuicerLibraryState).Tech['juego2.exe']
        $saved.Reflex | Should -BeTrue
        $saved.Stamp | Should -Not -BeNullOrEmpty
        $saved.Files | Should -Contain 'sl.reflex.dll'
        (Get-JuicerGameTech 'JUEGO2.EXE').Reflex | Should -BeTrue
        # Same folder, same stamp: what is kept is used, even if it was edited by hand (proves it is not read again).
        $s = Read-JuicerLibraryState
        $s.Tech['juego2.exe'].Reflex = $false
        Save-JuicerLibraryState $s
        (Update-JuicerGameTech $g).Reflex | Should -BeFalse
        # The folder changed: looked at again.
        (Get-Item -LiteralPath $game).LastWriteTime = (Get-Date).AddMinutes(-7)
        (Update-JuicerGameTech $g).Reflex | Should -BeTrue
        # A game with no folder on this PC: nothing to say, no error.
        Update-JuicerGameTech @{ ExeName = 'otro.exe'; Dir = (Join-Path $TechRoot 'nada'); Exe = '' } | Should -BeNullOrEmpty
    }

    It 'la nota del tope de Reflex vale con la tabla o con los archivos, y sin ninguno no dice nada' {
        $file = @{ Reflex = $true; DlssFG = $false; Fsr3FG = $false }
        $n = Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'NVIDIA' $file
        $n | Should -BeLike '*trae los archivos de NVIDIA Reflex*se queda en 171 FPS*tus 180 Hz*apagar Reflex*'
        (Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'NVIDIA' @{ Reflex = $false; DlssFG = $true }) | Should -BeLike '*se queda en 171 FPS*'
        Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'NVIDIA' @{ Reflex = $false; DlssFG = $false; Fsr3FG = $true } | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'AMD' $file | Should -BeNullOrEmpty
        # In the table, the wording that was there stays.
        (Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 178 180 'VRR' 'NVIDIA') | Should -BeLike 'Con NVIDIA Reflex activado en el juego y G-SYNC*'
    }

    It 'el resultado de aplicar el ritmo usa los archivos que ya se vieron' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerPacerPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $game = Join-Path $TechRoot 'Juego3'
        New-TestFile (Join-Path $game 'sl.reflex.dll')
        [void](Update-JuicerGameTech @{ ExeName = 'juego3.exe'; Dir = $game; Exe = (Join-Path $game 'juego3.exe') })
        $r = Set-JuicerPacerFps 'juego3.exe' 178 (New-TestMonitor)
        $r.Message | Should -BeLike '*trae los archivos de NVIDIA Reflex*se queda en 171 FPS*'
    }

    It 'los consejos hablan de la generación de fotogramas: el límite cuenta los generados' {
        $tech = @{ Reflex = $false; DlssFG = $true; Fsr3FG = $false; Files = @('nvngx_dlssg.dll') }
        $tips = @(Get-JuicerGameTips -ExeName 'desconocido.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -Tech $tech -WjFps 171)
        $fg = @($tips | Where-Object { $_.Title -like 'Generación de fotogramas*' })
        $fg.Count | Should -Be 1
        $fg[0].Detail | Should -BeLike '*DLSS Frame Generation*puede usarla*su ausencia no prueba*171 FPS son unos 85 reales*fuerza NVIDIA Reflex*'
        # Frame generation forces Reflex: it is offered even for a game the table does not know.
        @($tips | Where-Object { $_.Title -eq 'NVIDIA Reflex: actívalo' }).Count | Should -Be 1
        # FSR 3 does not force Reflex, and a game with no such files has no such tip.
        $fsr = @(Get-JuicerGameTips -ExeName 'desconocido.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -Tech @{ Fsr3FG = $true; DlssFG = $false; Reflex = $false })
        @($fsr | Where-Object { $_.Title -like 'Generación de fotogramas*' })[0].Detail | Should -Not -BeLike '*fuerza NVIDIA Reflex*'
        @($fsr | Where-Object { $_.Title -eq 'NVIDIA Reflex: actívalo' }).Count | Should -Be 0
        @(Get-JuicerGameTips -ExeName 'desconocido.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 | Where-Object { $_.Title -like 'Generación de fotogramas*' }).Count | Should -Be 0
        # A game with Reflex files and no table entry gets the Reflex tip with where it came from.
        $rx = @(Get-JuicerGameTips -ExeName 'desconocido.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -Tech @{ Reflex = $true; DlssFG = $false; Fsr3FG = $false })
        @($rx | Where-Object { $_.Title -eq 'NVIDIA Reflex: actívalo' })[0].Detail | Should -BeLike '*sl.reflex.dll*'
    }

    It 'avisa antes de medir con RivaTuner si el juego trae generación de fotogramas' {
        $game = Join-Path $TechRoot 'Juego4'
        New-TestFile (Join-Path $game 'nvngx_dlssg.dll')
        [void](Update-JuicerGameTech @{ ExeName = 'juego4.exe'; Dir = $game; Exe = (Join-Path $game 'juego4.exe') })
        $w = Get-JuicerFrameGenMeasureWarning 'juego4.exe' 'rtss'
        $w | Should -BeLike '*DLSS Frame Generation*RivaTuner es el motor*la medida puede salir con tirones que no son del juego*'
        Get-JuicerFrameGenMeasureWarning 'Juego4' 'rtss' | Should -Not -BeNullOrEmpty
        Get-JuicerFrameGenMeasureWarning 'juego4.exe' 'nvidia' | Should -BeNullOrEmpty
        Get-JuicerFrameGenMeasureWarning 'juego5.exe' 'rtss' | Should -BeNullOrEmpty
    }
}

Describe 'El límite propio de los juegos de Unreal' {
    BeforeEach {
        $script:LocalRoot = New-TestTempDir
    }
    AfterEach { Remove-Item -LiteralPath $LocalRoot -Recurse -Force -ErrorAction SilentlyContinue }

    It 'lee el límite y la V-Sync del GameUserSettings.ini del proyecto, sea cual sea su variante' {
        $ini = "[/Script/Engine.GameUserSettings]`nbUseVSync=True`nFrameRateLimit=144.000000`n"
        New-TestFile (Join-Path $LocalRoot 'Marvel\Saved\Config\Windows\GameUserSettings.ini') $ini
        $u = Get-JuicerUnrealLimit 'marvel-win64-shipping.exe' $LocalRoot
        $u.Project | Should -Be 'Marvel'
        $u.Limit | Should -Be 144
        $u.VSync | Should -BeTrue
        # The other folders the same file lives in.
        foreach ($v in 'WindowsNoEditor', 'WinGDK') {
            $root = New-TestTempDir
            try {
                New-TestFile (Join-Path $root "Otro\Saved\Config\$v\GameUserSettings.ini") "FrameRateLimit=60.000000`nbUseVSync=False`n"
                $o = Get-JuicerUnrealLimit 'Otro-Win64-Shipping.exe' $root
                $o.Limit | Should -Be 60
                $o.VSync | Should -BeFalse
            } finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
        }
        # Unlimited is 0.
        New-TestFile (Join-Path $LocalRoot 'Libre\Saved\Config\Windows\GameUserSettings.ini') "FrameRateLimit=0.000000`n"
        (Get-JuicerUnrealLimit 'libre-win64-shipping.exe' $LocalRoot).Limit | Should -Be 0
    }

    It 'sin archivo, sin la clave, sin carpeta o con un .exe que no es de Unreal, no hay nada' {
        Get-JuicerUnrealLimit 'marvel-win64-shipping.exe' $LocalRoot | Should -BeNullOrEmpty
        New-TestFile (Join-Path $LocalRoot 'Marvel\Saved\Config\Windows\GameUserSettings.ini') "[/Script/Engine.GameUserSettings]`nbUseVSync=True`n"
        Get-JuicerUnrealLimit 'marvel-win64-shipping.exe' $LocalRoot | Should -BeNullOrEmpty
        Get-JuicerUnrealLimit 'cs2.exe' $LocalRoot | Should -BeNullOrEmpty
        Get-JuicerUnrealLimit 'marvel-win64-shipping.exe' (Join-Path $LocalRoot 'noexiste') | Should -BeNullOrEmpty
        Get-JuicerUnrealLimit 'marvel-win64-shipping.exe' '' | Should -BeNullOrEmpty
    }

    It 'el consejo dice el límite del juego frente al de Win Juicer, o que está en ilimitado' {
        $limit = @{ Project = 'Marvel'; Path = 'x'; Limit = 144.0; VSync = $true }
        $tips = @(Get-JuicerGameTips -ExeName 'marvel-win64-shipping.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -UnrealLimit $limit -WjFps 171)
        $t = @($tips | Where-Object { $_.Title -like 'El juego tiene su propio límite*' })
        $t.Count | Should -Be 1
        $t[0].Severity | Should -Be 'Medio'
        $t[0].Detail | Should -Be 'El juego tiene su propio límite a 144 FPS (y V-Sync activado): con el de Win Juicer a 171 manda el menor. Ponlo en ilimitado en el juego.'
        # Higher than Win Juicer's: still worth saying, without the alarm.
        $hi = @(Get-JuicerGameTips -ExeName 'marvel-win64-shipping.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -UnrealLimit @{ Limit = 240.0; VSync = $false } -WjFps 171 | Where-Object { $_.Title -like 'El juego tiene su propio límite*' })
        $hi[0].Severity | Should -Be 'Info'
        $hi[0].Detail | Should -BeLike 'El juego tiene su propio límite a 240 FPS: con el de Win Juicer a 171 manda el menor*'
        $free = @(Get-JuicerGameTips -ExeName 'marvel-win64-shipping.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 -UnrealLimit @{ Limit = 0.0; VSync = $true } -WjFps 171 | Where-Object { $_.Title -like '*ilimitado*' })
        $free.Count | Should -Be 1
        $free[0].Detail | Should -BeLike 'El límite propio del juego está en ilimitado: bien*desactívala en el juego*'
        # No file found: nothing about it.
        @(Get-JuicerGameTips -ExeName 'marvel-win64-shipping.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180 | Where-Object { $_.Title -like '*límite*propio*' -or $_.Title -like '*ilimitado*' }).Count | Should -Be 0
    }
}

Describe 'Ritmos que se han quedado atrás, y avisos del montaje' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
    }

    It 'dice que los ritmos automáticos no son los de ahora y manda a Recalcular' {
        $f = @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 57 }, @{ Exe = 'valorant-win64-shipping.exe'; Fps = 57 }) $Mon)
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Medio'
        $f[0].Title | Should -Be 'Hay 2 juegos con un ritmo que ya no es el recomendado'
        $f[0].Detail | Should -BeLike 'Tus juegos tienen 57 FPS y para tus 180 Hz serían 171: pulsa «Recalcular los ritmos»*cs2.exe, valorant-win64-shipping.exe*'
        # Without the engine's state (it could not be read) the rates are still checked.
        @(Get-JuicerPacerConflicts $null 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 57 }) $Mon).Count | Should -Be 1
        # The same rate that would be set today: nothing.
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 171 }) $Mon).Count | Should -Be 0
    }

    It 'no toca lo que elegiste tú, lo que espera a que cierres el juego ni lo que NVIDIA limita en su perfil' {
        $s = Read-JuicerPacer
        $s.Games['cs2.exe'] = @{ Fps = 57 }
        Save-JuicerPacer $s
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 57 }) $Mon).Count | Should -Be 0
        $s = Read-JuicerPacer
        $s.Games.Remove('cs2.exe')
        $s.Pending['cs2.exe'] = @{ Op = 'Set'; Fps = 0; Use = '' }
        Save-JuicerPacer $s
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 57 }) $Mon).Count | Should -Be 0
        Clear-JuicerPacerPending 'cs2.exe'
        $M.Backend.State.NvPredefined['cs2.exe|' + [uint32]0x10835002] = 57
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = 57 }) $Mon).Count | Should -Be 0
        $M.Backend.State.NvPredefined.Clear()
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @(@{ Exe = 'cs2.exe'; Fps = $null }) $Mon).Count | Should -Be 0
    }

    It 'con una gráfica AMD recuerda Radeon Chill y Frame Rate Target Control' {
        $f = @(Get-JuicerPacerConflicts $NoConflictState 'rtss' @() $Mon 'AMD' @())
        $f.Count | Should -Be 1
        $f[0].Severity | Should -Be 'Info'
        $f[0].Detail | Should -BeLike '*Radeon Chill o Frame Rate Target Control*manda el más bajo*Chill además baja los FPS por sí solo*'
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon 'NVIDIA' @()).Count | Should -Be 0
    }

    It 'con varias pantallas distintas dice para cuál está calculado' {
        $other = New-TestMonitor -Hz 60 -Vrr $false -Id 'DEL1234'
        $other.Display.Primary = $false
        $f = @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon '' @($Mon, $other))
        $f.Count | Should -Be 1
        $f[0].Detail | Should -BeLike 'Calculado para tu pantalla principal (180 Hz con VRR); la otra va a 60 Hz sin VRR*cámbiala a principal*ajusta el modo*'
        # The same Hz and the same VRR: nothing to say; one screen: nothing.
        $twin = New-TestMonitor -Hz 180 -Vrr $true -Id 'GSM0001'
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon '' @($Mon, $twin)).Count | Should -Be 0
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon '' @($Mon)).Count | Should -Be 0
        # Different Hz alone is enough.
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon '' @($Mon, (New-TestMonitor -Hz 144 -Vrr $true -Id 'X1'))).Count | Should -Be 1
    }

    It 'con NVIDIA y un monitor que sale fijo sin que lo hayas dicho, sugiere que sea G-SYNC' {
        $fixed = New-TestMonitor -Hz 144 -Vrr $false
        $fixed.Mode = 'Automatico'
        $f = @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $fixed 'NVIDIA' @())
        $f.Count | Should -Be 1
        $f[0].Detail | Should -BeLike '*Si tu monitor es G-SYNC*«Frecuencia variable»*'
        # Said to be fixed on purpose, AMD, or with VRR announced: nothing.
        $chosen = New-TestMonitor -Hz 144 -Vrr $false
        $chosen.Mode = 'Fijo'
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $chosen 'NVIDIA' @()).Count | Should -Be 0
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $fixed 'AMD' @() | Where-Object { $_.Title -like 'Tu monitor*' }).Count | Should -Be 0
        @(Get-JuicerPacerConflicts $NoConflictState 'nvidia' @() $Mon 'NVIDIA' @()).Count | Should -Be 0
    }
}

Describe 'Un ritmo a menos de 3 FPS de los Hz con la V-Sync forzada' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
    }

    It 'avisa de 178 a 180 con VRR, y de nada más' {
        Get-JuicerVsyncEdgeNote 178 180 'VRR' | Should -BeLike 'A menos de 3 FPS de tus 180 Hz, la V-Sync forzada puede hacer esperar fotogramas: mejor ≤ 171.'
        Get-JuicerVsyncEdgeNote 180 180 'EstroboSync' | Should -BeLike '*mejor ≤ 171*'
        Get-JuicerVsyncEdgeNote 59 60 'VRR' | Should -BeLike '*mejor ≤ 57*'
        Get-JuicerVsyncEdgeNote 177 180 'VRR' | Should -BeNullOrEmpty
        Get-JuicerVsyncEdgeNote 171 180 'VRR' | Should -BeNullOrEmpty
        Get-JuicerVsyncEdgeNote 181 180 'VRR' | Should -BeNullOrEmpty
        Get-JuicerVsyncEdgeNote 178 180 'Fijo' | Should -BeNullOrEmpty
        Get-JuicerVsyncEdgeNote 178 180 'Estrobo' | Should -BeNullOrEmpty
        Get-JuicerVsyncEdgeNote 178 180 'VRR' $false | Should -BeNullOrEmpty
    }

    It 'sale en el resultado de aplicar el ritmo, también sin Reflex, salvo en modo prudente' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'AMD' }
        $r = Set-JuicerPacerFps 'cs2.exe' 179 $Mon
        $r.Outcome | Should -Be 'Aplicado'
        $r.Message | Should -BeLike '*A menos de 3 FPS de tus 180 Hz*mejor ≤ 171*'
        (Set-JuicerPacerFps 'cs2.exe' 171 $Mon).Message | Should -Not -BeLike '*V-Sync forzada*'
        # Prudent mode leaves VSync as the game has it: nothing is forced.
        Set-JuicerPacerMinimal 'cs2.exe' $true $Mon
        (Set-JuicerPacerFps 'cs2.exe' 179 $Mon).Message | Should -Not -BeLike '*V-Sync forzada*'
        # Above the refresh VSync is forced off.
        Set-JuicerPacerMinimal 'cs2.exe' $false $Mon
        (Set-JuicerPacerFps 'cs2.exe' 400 $Mon).Message | Should -Not -BeLike '*V-Sync forzada*'
    }
}

Describe 'Límites que el driver ha borrado' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerJournalPath), (Get-JuicerUpkeepPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        [void](Add-JuicerFpsLimit 'valorant-win64-shipping.exe' 0 $Mon)
        # A clean driver install takes the profiles: the journal still has them.
        $M.Backend.State.FpsLimits.Remove('cs2.exe')
        $M.Backend.State.FpsLimits.Remove('valorant-win64-shipping.exe')
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        Mock -ModuleName WinJuicer Get-JuicerGames { @() }
    }

    It 'los distingue de un límite que no se pudo leer o de no tener motor' {
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 2
        @(Get-JuicerWipedFpsLimits | ForEach-Object { $_.Exe } | Sort-Object) | Should -Be @('cs2.exe', 'valorant-win64-shipping.exe')
        Mock -ModuleName WinJuicer Get-JuicerFpsLimits { @(@{ Id = 'fps:a.exe'; Exe = 'a.exe'; Fps = $null; Unreadable = $true }) }
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 0
    }

    It 'sin motor de frame pacer no hay nada que volver a poner' {
        $M.Backend.State.FpsBackend = $null
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 0
    }

    It 'sale en lo que Windows ha deshecho, con su aviso, y no duplica el de un juego abierto' {
        $d = @(Get-JuicerDrift)
        @($d | Where-Object { $_.Kind -eq 'Fps' }).Count | Should -Be 2
        $sum = Format-JuicerDriftSummary $d
        $sum.Title | Should -Be 'El driver borró el límite de 2 juegos'
        $sum.Lines | Should -Contain '· cs2.exe'
        (Format-JuicerDriftSummary @($d[0])).Title | Should -Be 'El driver borró el límite de 1 juego'
        # Mixed with something Windows undid: one line for the driver.
        $mixed = Format-JuicerDriftSummary @(@{ Title = 'Modo juego'; State = 'Pendiente' }, $d[0], $d[1])
        $mixed.Title | Should -Be 'Windows ha deshecho 1 cambio tuyo'
        $mixed.Lines[-1] | Should -BeLike '· el driver borró el límite de 2 juegos: *'
        [void]$M.Backend.State.Running.Add('cs2.exe')
        @(Get-JuicerDrift | Where-Object { $_.Kind -eq 'Fps' }).Count | Should -Be 1
    }

    It 'se vuelven a poner, y el de un juego abierto espera a que lo cierres' {
        [void]$M.Backend.State.Running.Add('cs2.exe')
        $r = @(Restore-JuicerWipedFpsLimits)
        @($r | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -Be 1
        @($r | Where-Object { $_.Outcome -eq 'Pendiente' }).Count | Should -Be 1
        $M.Backend.State.FpsLimits['valorant-win64-shipping.exe'] | Should -Be 171
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        (Read-JuicerPacer).Pending.ContainsKey('cs2.exe') | Should -BeTrue
        # Already waiting: not queued again. Closed: the pending work puts it back.
        @(Restore-JuicerWipedFpsLimits).Count | Should -Be 0
        $M.Backend.State.Running.Remove('cs2.exe')
        [void]@(Invoke-JuicerPacerPending $Mon)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 0
        # Only the one asked for.
        $M.Backend.State.FpsLimits.Remove('cs2.exe')
        $M.Backend.State.FpsLimits.Remove('valorant-win64-shipping.exe')
        @(Restore-JuicerWipedFpsLimits -Exe 'cs2.exe').Count | Should -Be 1
        $M.Backend.State.FpsLimits.ContainsKey('valorant-win64-shipping.exe') | Should -BeFalse
    }

    It 'el mantenimiento al iniciar sesión los vuelve a poner y lo apunta' {
        $log = Join-Path (Get-JuicerHome) 'registro.log'
        $before = if (Test-Path -LiteralPath $log) { [IO.File]::ReadAllText($log).Length } else { 0 }
        $res = @(Invoke-JuicerUpkeep -Quiet)
        @($res | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -Be 2
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        $M.Backend.State.FpsLimits['valorant-win64-shipping.exe'] | Should -Be 171
        [IO.File]::ReadAllText($log).Substring($before) | Should -BeLike '*el driver borró el límite de cs2.exe, valorant-win64-shipping.exe*'
        # Once back, nothing more to do.
        @(Invoke-JuicerUpkeep -Quiet).Count | Should -Be 0
    }

    It '-Revisar los lista y, con -Si, los vuelve a poner' {
        $text = (@(Start-Juicer -Revisar 6>&1) | Out-String)
        $text | Should -BeLike '*El driver borró el límite de 2 juegos*cs2.exe*'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        @(Start-Juicer -Revisar -Si -Simular 6>$null)[-1] | Should -Be 0
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        @(Start-Juicer -Revisar -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        $M.Backend.State.FpsLimits['valorant-win64-shipping.exe'] | Should -Be 171
        (Start-Juicer -Revisar 6>&1 | Out-String) | Should -BeLike '*Todo lo que aplicó Win Juicer sigue en su sitio*'
    }
}

Describe 'La edad de la calibración sólo si está en vigor' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
    }

    It 'distingue en vigor, de otro monitor o modo, con un ritmo tuyo encima, y sin calibrar' {
        $when = (Get-Date).AddDays(-12).ToString('s')
        $cal = @{ Fps = 127; Why = 'x'; Signature = (Get-JuicerLimitSignature $Mon); Date = $when }
        $pacer = @{ Games = @{} }
        Get-JuicerCalibrationState 'cs2.exe' $cal $Mon $pacer | Should -Be 'Activa'
        # Another refresh rate, another monitor or another mode: it is not in force.
        Get-JuicerCalibrationState 'cs2.exe' $cal (New-TestMonitor -Hz 144) $pacer | Should -Be 'OtroMonitor'
        Get-JuicerCalibrationState 'cs2.exe' $cal (New-TestMonitor -Id 'GSM9999') $pacer | Should -Be 'OtroMonitor'
        $fixedMon = New-TestMonitor
        $fixedMon.Mode = 'Fijo'
        Get-JuicerCalibrationState 'cs2.exe' $cal $fixedMon $pacer | Should -Be 'OtroMonitor'
        # A rate of yours wins over it.
        Get-JuicerCalibrationState 'cs2.exe' $cal $Mon @{ Games = @{ 'cs2.exe' = @{ Fps = 100 } } } | Should -Be 'Manual'
        Get-JuicerCalibrationState 'cs2.exe' $null $Mon $pacer | Should -Be ''
        Get-JuicerCalibrationState 'cs2.exe' @{ Fps = 0 } $Mon $pacer | Should -Be ''
        # No screen to compare with: it says nothing rather than something false.
        Get-JuicerCalibrationState 'cs2.exe' $cal $null $pacer | Should -Be ''
    }

    It 'el estado del juego enseña la edad sólo cuando está en vigor' {
        $when = (Get-Date).AddDays(-12).ToString('s')
        (Format-JuicerGameStatus @{ Fps = 118; CalFps = 118; CalDate = $when; CalState = 'Activa' }) | Should -BeLike '*calibrado hace 12 días a 118 FPS*'
        $other = Format-JuicerGameStatus @{ Fps = 118; CalFps = 118; CalDate = $when; CalState = 'OtroMonitor' }
        $other | Should -BeLike '*calibración de otro monitor o modo*'
        $other | Should -Not -BeLike '*hace 12 días*'
        $manual = Format-JuicerGameStatus @{ Fps = 118; CalFps = 118; CalDate = $when; CalState = 'Manual' }
        $manual | Should -Not -BeLike '*calibra*'
        (Format-JuicerGameStatus @{ Fps = 118; CalFps = 118; CalDate = $when; CalState = '' }) | Should -Not -BeLike '*calibra*'
    }

    It 'Get-JuicerGameStatus lo calcula con el monitor de ahora' {
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $state = Read-JuicerPacer
        $state.Calibrated['cs2.exe'] = @{ Fps = 171; Why = 'x'; Signature = (Get-JuicerLimitSignature $Mon); Date = (Get-Date).AddDays(-3).ToString('s') }
        Save-JuicerPacer $state
        $g = @(Get-JuicerGameStatus @(@{ ExeName = 'cs2.exe'; Exe = 'C:\Juegos\cs2.exe' }))[0]
        $g.CalState | Should -Be 'Activa'
        (Format-JuicerGameStatus $g) | Should -BeLike '*calibrado hace 3 días a 171 FPS*'
        # The monitor goes to another refresh rate: the calibration is no longer the one in force.
        $script:Mon = New-TestMonitor -Hz 144
        $g = @(Get-JuicerGameStatus @(@{ ExeName = 'cs2.exe'; Exe = 'C:\Juegos\cs2.exe' }))[0]
        $g.CalState | Should -Be 'OtroMonitor'
        (Format-JuicerGameStatus $g) | Should -BeLike '*calibración de otro monitor o modo*'
        (Format-JuicerGameStatus $g) | Should -Not -BeLike '*hace 3 días*'
    }
}

# --- Frame pacer, third round: who limits under a cap, calibration guards and proposals, throttling,
# --- verification, the history, one calibration per monitor, and the VRR range -------------------------

Describe 'Qué limita bajo un tope, y a quién se echa la culpa' {
    BeforeAll {
        # Rows where the processor and the card are told apart: Cpu and Gpu are what each was busy per frame.
        function New-BoundRows {
            param([double]$Frame = 7.0, [double]$Cpu, [double]$Gpu, [int]$Count = 400)
            New-PacedRows ([double[]](@($Frame) * $Count)) $Gpu | ForEach-Object { $_.CPUBusy = $Cpu.ToString([Globalization.CultureInfo]::InvariantCulture); $_ }
        }
    }

    It 'con un tope, la gráfica descansa y no es culpa del procesador: «limitado por el ritmo»' {
        $r = Measure-JuicerFrames @(New-BoundRows -Cpu 2.4 -Gpu 3.0)
        $r.GpuBound | Should -Be 0
        $r.Limit | Should -Be 'Ritmo'
        $f = @(Get-JuicerFrameFindings $r $null 165)
        @($f | Where-Object { $_.Title -like 'Limitado por el ritmo, hay margen*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'El procesador es el límite*' }).Count | Should -Be 0
        @($f | Where-Object { $_.Title -like 'La gráfica es el límite*' }).Count | Should -Be 0
    }

    It 'sin tope, con el procesador al límite o con la gráfica al límite, lo dice' {
        $cpu = Measure-JuicerFrames @(New-BoundRows -Cpu 6.5 -Gpu 3.0)
        $cpu.Limit | Should -Be 'CPU'
        @(Get-JuicerFrameFindings $cpu $null 165 | Where-Object { $_.Title -like 'El procesador es el límite*' }).Count | Should -Be 1
        $gpu = Measure-JuicerFrames @(New-BoundRows -Cpu 3.0 -Gpu 6.5)
        $gpu.Limit | Should -Be 'GPU'
        @(Get-JuicerFrameFindings $gpu $null 165 | Where-Object { $_.Title -like 'La gráfica es el límite*' }).Count | Should -Be 1
    }

    It 'sin las columnas de trabajo, sigue la cuenta de fotogramas con la gráfica ocupada, como antes' {
        Get-JuicerFrameLimit @{ GpuBound = 30; AvgFps = 300 } | Should -Be 'CPU'
        Get-JuicerFrameLimit @{ GpuBound = 90; AvgFps = 300 } | Should -Be 'GPU'
        Get-JuicerFrameLimit @{ GpuBound = 65; AvgFps = 300 } | Should -Be ''
        Get-JuicerFrameLimit @{ AvgFps = 300 } | Should -Be ''
        Get-JuicerFrameLimit $null | Should -Be ''
    }

    It 'los consejos no mandan Boost ni bajar la CPU a quien está bajo un tope' {
        $r = Measure-JuicerFrames @(New-BoundRows -Cpu 2.4 -Gpu 3.0)
        $tips = @(Get-JuicerGameTips -ExeName 'cs2.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Measured $r -Hz 144)
        @($tips | Where-Object { $_.Title -like '*el procesador limita*' }).Count | Should -Be 0
        @($tips | Where-Object { $_.Title -like 'Tu última medida: limitado por el ritmo*' }).Count | Should -Be 1
        @($tips | Where-Object { $_.Title -eq 'NVIDIA Reflex: actívalo' })[0].Detail | Should -Not -BeLike '*«Activado + Boost»: tu medida dice*'
        $legacy = @(Get-JuicerGameTips -ExeName 'cs2.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Measured @{ GpuBound = 30; AvgFps = 300; Low1 = 200 } -Hz 165)
        @($legacy | Where-Object { $_.Title -like '*el procesador limita*' }).Count | Should -Be 1
    }
}

Describe 'Elegir los fotogramas del juego por cadena de intercambio' {
    BeforeAll {
        function New-ChainRows {
            param([string]$App, [string]$ProcId, [string]$Chain, [int]$Count)
            1..$Count | ForEach-Object { [pscustomobject][ordered]@{ Application = $App; ProcessID = $ProcId; SwapChainAddress = $Chain; FrameTime = '6.9' } }
        }
    }

    It 'dentro del mismo .exe se queda con la cadena que más fotogramas presentó' {
        $rows = @(New-ChainRows 'game.exe' '100' '0xAAA' 700) + @(New-ChainRows 'game.exe' '100' '0xBBB' 300) + @(New-ChainRows 'game.exe' '200' '0xCCC' 400)
        $g = @(Select-JuicerGameRows $rows)
        $g.Count | Should -Be 700
        $g[0].SwapChainAddress | Should -Be '0xAAA'
        # Asking for it by name picks the same one.
        @(Select-JuicerGameRows $rows 'game').Count | Should -Be 700
    }

    It 'una cadena grande de un programa de Windows no le gana al juego, y sin esas columnas agrupa por programa' {
        $rows = @(New-ChainRows 'dwm.exe' '4' '0x1' 2000) + @(New-ChainRows 'game.exe' '100' '0xAAA' 500)
        @(Select-JuicerGameRows $rows).Count | Should -Be 500
        $plain = @(1..50 | ForEach-Object { [pscustomobject]@{ Application = 'a.exe'; FrameTime = '7' } }) + @(1..80 | ForEach-Object { [pscustomobject]@{ Application = 'b.exe'; FrameTime = '7' } })
        @(Select-JuicerGameRows $plain).Count | Should -Be 80
        @(Select-JuicerGameRows $plain 'a.exe').Count | Should -Be 50
    }
}

Describe 'Calibrar: la escena, el equipo y las propuestas' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
        # A game that misses 171 on one frame in ten: it would go down.
        $script:Misses = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        $script:Misses.Date = (Get-Date).ToString('s')
    }

    It 'un menú o una pantalla de carga no calibra nada' {
        # 1 ms of work in frames of 5.85: the PC hardly did anything.
        $menu = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 1.0)
        $why = Get-JuicerCalibrationSceneProblem $menu 171 $null
        $why | Should -BeLike '*parece un menú o una pantalla de carga: repite en partida*'
        (Get-JuicerCalibrationSceneProblem $Misses 171 $null) | Should -Be ''
        # Little work, but not under a quarter of the frame: a light game, not a menu.
        (Get-JuicerCalibrationSceneProblem (Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 2.0)) 171 $null) | Should -Be ''
        $plan = Get-JuicerCalibrationPlan $menu 171 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA' $null
        $plan.Action | Should -Be 'Repetir'
        $plan.Kind | Should -Be 'Escena'
    }

    It 'una media por debajo del 55 % de la medida anterior del juego no vale, salvo si la anterior iba por encima del tope' {
        $prev = @{ AvgFps = 170.0; Date = (Get-Date).ToString('s'); Cap = 171 }
        $now = Measure-JuicerFrames @(New-PacedRows ([double[]](@(12.0) * 400)) 9.0)
        $now.AvgFps | Should -BeLessThan 93.5
        (Get-JuicerCalibrationSceneProblem $now 171 $prev) | Should -BeLike '*menos de la mitad de la medida anterior*repite en partida*'
        # Within the 55 %: it is what the game does.
        (Get-JuicerCalibrationSceneProblem (Measure-JuicerFrames @(New-PacedRows ([double[]](@(8.0) * 400)) 6.0)) 171 $prev) | Should -Be ''
        # A previous run far above the cap (no limiter then) is not a reference for a capped one.
        (Get-JuicerCalibrationSceneProblem $now 171 @{ AvgFps = 600.0 }) | Should -Be ''
    }

    It 'un múltiplo de los Hz de latencia nunca pasa de 1,1 veces lo mejor que se vio sin límite' {
        $light = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 1.2 -Wait 0.1)
        (Get-JuicerPacerCalibration $light 171 171 'VRR' 48 @() 180 'Latencia').Fps | Should -Be 720
        # Never above 1.1 x 400 FPS: two times the refresh (360), not four (720).
        $c = Get-JuicerPacerCalibration $light 171 171 'VRR' 48 @() 180 'Latencia' '' 400
        $c.Fps | Should -Be 360
        $c.Action | Should -Be 'Subir'
        # Seen only at 150 FPS: not even two times the refresh.
        (Get-JuicerPacerCalibration $light 171 171 'VRR' 48 @() 180 'Latencia' '' 150).Action | Should -Be 'Mantener'
    }

    It 'lo mejor sin límite sale del historial, de esta pantalla, sin contar lo frenado ni lo viejo' {
        $sig = Get-JuicerLimitSignature $Mon
        $now = Get-Date
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 300.0; Cap = 0; Signature = $sig; Date = $now.AddDays(-2).ToString('s') }
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 520.0; Cap = 0; Signature = $sig; Date = $now.AddDays(-1).ToString('s'); Throttled = $true }
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 700.0; Cap = 0; Signature = $sig; Date = $now.AddDays(-90).ToString('s') }
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 800.0; Cap = 0; Signature = '144|VRR|otro'; Date = $now.AddDays(-1).ToString('s') }
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 171.0; Cap = 171; Signature = $sig; Date = $now.ToString('s') }
        Get-JuicerBestUnpacedFps 'cs2.exe' $sig 180 | Should -Be 300
        Get-JuicerBestUnpacedFps 'otro.exe' $sig 180 | Should -Be 0
    }

    It 'si la gráfica se frenó, llegó a 85 °C o algo gastaba el 12 % del procesador, no se baja el ritmo' {
        $base = Get-JuicerCalibrationPlan $Misses 171 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA' $null
        $base.Action | Should -Be 'Bajar'
        foreach ($noisy in @(
                @{ Throttled = $true; ThrottleReason = 'límite de temperatura'; Why = '*repite la medida: la gráfica se frenó (límite de temperatura)*' }
                @{ MaxTemp = 86.0; Why = '*repite la medida: la gráfica llegó a 86 °C*' }
                @{ Hogs = @(@{ Name = 'MsMpEng'; Pct = 14.0 }); Why = '*repite la medida: MsMpEng usaba el 14 % del procesador*' })) {
            $r = $Misses.Clone()
            foreach ($k in $noisy.Keys) { if ($k -ne 'Why') { $r[$k] = $noisy[$k] } }
            $plan = Get-JuicerCalibrationPlan $r 171 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA' $null
            $plan.Action | Should -Be 'Repetir'
            $plan.Why | Should -BeLike $noisy.Why
        }
        # A small process is not a reason; and noise never stops a raise (a throttled card only under-reports).
        $small = $Misses.Clone(); $small.Hogs = @(@{ Name = 'chrome'; Pct = 4.0 })
        (Get-JuicerCalibrationPlan $small 171 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA' $null).Action | Should -Be 'Bajar'
        $easy = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.7) * 400)) 3.0)
        $easy.Throttled = $true
        (Get-JuicerCalibrationPlan $easy 130 171 'VRR' 48 @() 180 'Fluidez' 'NVIDIA' $null).Action | Should -Be 'Subir'
    }

    It 'Invoke-JuicerPacerCalibration propone sin aplicar, y con -Apply aplica' {
        $res = $Misses
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $res }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $Mon)
        $p = Get-JuicerCalibrationProposal $f
        $p.Old | Should -Be 171
        $p.New | Should -Be 127
        $p.Action | Should -Be 'Bajar'
        $p.Why | Should -BeLike 'Calibrado: con 171 FPS*'
        $f[-1].Title | Should -Be 'Propuesta: de 171 a 127 FPS'
        $f[-1].Detail | Should -BeLike '*Todavía no se ha cambiado nada*'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        (Read-JuicerPacer).Calibrated.Count | Should -Be 0
        # Applied on request.
        $a = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $Mon -Apply)
        $a[-1].Title | Should -Be 'Calibrado: de 171 a 127 FPS'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        $entry = (Read-JuicerPacer).Calibrated['cs2.exe'][(Get-JuicerLimitSignature $Mon)]
        $entry.Fps | Should -Be 127
        $entry.Fingerprint | Should -BeOfType [hashtable]
    }

    It 'si la escena es un menú, Invoke-JuicerPacerCalibration no propone ni cambia nada y lo dice' {
        $menu = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 1.0)
        $menu.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $menu }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $Mon -Apply)
        Get-JuicerCalibrationProposal $f | Should -BeNullOrEmpty
        $f[-1].Title | Should -BeLike 'Sin cambios: parece un menú o una pantalla de carga*'
        $f[-1].Detail | Should -BeLike '*parece un menú o una pantalla de carga: repite en partida*escena más exigente y habitual (no un menú), sin Alt-Tab*'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        (Read-JuicerPacer).Calibrated.Count | Should -Be 0
    }

    It 'si la gráfica estaba frenada, dice «repite la medida» y no guarda nada' {
        $hot = $Misses.Clone(); $hot.Throttled = $true; $hot.ThrottleReason = 'límite de temperatura'; $hot.MaxTemp = 88.0
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $hot }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $Mon -Apply)
        $f[-1].Title | Should -Be 'Sin cambios: repite la medida'
        $f[-1].Detail | Should -BeLike 'Repite la medida: la gráfica se frenó (límite de temperatura)*'
        (Read-JuicerPacer).Calibrated.Count | Should -Be 0
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
    }
}

Describe 'La consola propone y pregunta' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $script:Prop = @{ Exe = 'cs2.exe'; Old = 171; New = 127; Action = 'Bajar'; Why = 'porque sí'; Signature = (Get-JuicerLimitSignature $Mon); Fingerprint = @{ Gpu = 'x' } }
        Mock -ModuleName WinJuicer Write-Host { }
        Mock -ModuleName WinJuicer Write-JuicerWrapped { }
    }

    It 'si dices que no, no se cambia nada' {
        Mock -ModuleName WinJuicer Confirm-JuicerAction { $false }
        InModuleScope WinJuicer -Parameters @{ P = $Prop; Mo = $Mon } { param($P, $Mo) Invoke-JuicerConsoleCalibration $P $Mo }
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        (Read-JuicerPacer).Calibrated.Count | Should -Be 0
    }

    It 'si dices que sí, se aplica; sin verificar, se acaba ahí' {
        Mock -ModuleName WinJuicer Confirm-JuicerAction { $true }
        Mock -ModuleName WinJuicer Read-JuicerChoice { '' }
        InModuleScope WinJuicer -Parameters @{ P = $Prop; Mo = $Mon } { param($P, $Mo) $script:Interactive = $true; Invoke-JuicerConsoleCalibration $P $Mo }
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        (Read-JuicerPacer).Calibrated['cs2.exe'].Count | Should -Be 1
    }

    It 'con -Si (sin preguntar) aplica; sin -Si y sin respuesta no cambia nada' {
        $res = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        $res.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $res }.GetNewClosure()
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        Mock -ModuleName WinJuicer Write-JuicerFindings { }
        Mock -ModuleName WinJuicer Update-JuicerCopy { }
        # A closed input answers nothing: that is a no.
        Mock -ModuleName WinJuicer Read-Host { $null }
        @(Start-Juicer -CalibrarJuego 'cs2.exe' 6>$null)[-1] | Should -Be 0
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        @(Start-Juicer -CalibrarJuego 'cs2.exe' -Si 6>$null)[-1] | Should -Be 0
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
    }
}

Describe 'La gráfica frenada, la VRAM llena y lo que quedó en la medida' {
    It 'lee los campos nuevos de nvidia-smi, también con «[N/A]»' {
        $lines = @(
            '70, 99, 2700, 7000, 8192, 190.5, 0x0000000000000000'
            '84, 99, 2600, 7900, 8192, 200.1, 0x0000000000000004'
            '88, 98, 1900, 7950, 8192, 201.0, 0x0000000000000024'
            '86, 97, 1800, 7960, 8192, 199.0, 0x0000000000000020')
        $g = ConvertFrom-JuicerGpuSamples $lines
        $g.MaxTemp | Should -Be 88
        $g.VramUsedPct | Should -Be 97.2
        $g.MaxPowerW | Should -Be 201
        $g.Throttled | Should -BeTrue
        $g.ThrottleReason | Should -Be 'límite de temperatura'
        $g.PowerLimited | Should -BeTrue
        $na = ConvertFrom-JuicerGpuSamples @('70, 99, 2700, [N/A], [N/A], [N/A], [N/A]', '71, 99, 2700, [N/A], [N/A], [N/A], [N/A]', '72, 99, 2700, [Not Supported], 8192, 180, [N/A]')
        $na.Throttled | Should -BeFalse
        $na.VramUsedPct | Should -BeNullOrEmpty
        $na.MaxPowerW | Should -Be 180
        # The old three columns still read; the power cap alone is not «throttled».
        $old = ConvertFrom-JuicerGpuSamples @('70, 99, 2700', '71, 99, 2700', '72, 99, 2700')
        $old.Throttled | Should -BeFalse
        $old.VramUsedPct | Should -BeNullOrEmpty
        (ConvertFrom-JuicerGpuSamples @('70, 99, 2700, 100, 200, 100, 0x4', '70, 99, 2700, 100, 200, 100, 0x4', '70, 99, 2700, 100, 200, 100, 0x4')).Throttled | Should -BeFalse
    }

    It 'lo que se midió se guarda con la medida: freno, temperatura, VRAM, procesos, ritmo, pantalla y versiones' {
        $r = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        $mon = New-TestMonitor
        $gpu = @{ Throttled = $true; ThrottleReason = 'freno de energía'; MaxTemp = 87.0; VramUsedPct = 96.5 }
        Set-JuicerFrameContext $r @(@{ Exe = 'game.exe'; Fps = 171; Backend = 'nvidia' }) $mon 180 @(@{ Name = 'MsMpEng'; Pct = 14.0 }) $gpu
        $r.Cap | Should -Be 171
        $r.Backend | Should -Be 'nvidia'
        $r.Hz | Should -Be 180
        $r.Use | Should -Be 'VRR'
        $r.Signature | Should -Be (Get-JuicerLimitSignature $mon)
        $r.Priority | Should -Be 'Fluidez'
        $r.PresentMonVersion | Should -Be '2.3.1'
        $r.Throttled | Should -BeTrue
        $r.ThrottleReason | Should -Be 'freno de energía'
        $r.MaxTemp | Should -Be 87
        $r.VramUsedPct | Should -Be 96.5
        $r.Hogs[0].Name | Should -Be 'MsMpEng'
        # Without the card's samples: not throttled, nothing known. Without a limit: Cap 0.
        $bare = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        Set-JuicerFrameContext $bare @() $mon 180 @() $null
        $bare.Cap | Should -Be 0
        $bare.Throttled | Should -BeFalse
        $bare.VramUsedPct | Should -BeNullOrEmpty
        # And it goes through the history file and back.
        Remove-Item -LiteralPath (Get-JuicerFrameHistoryPath) -ErrorAction SilentlyContinue
        $r.Remove('Series')
        $r.Date = (Get-Date).ToString('s')
        Save-JuicerFrameResult $r
        $back = Get-JuicerPreviousFrameResult 'marvel-win64-shipping.exe'
        $back.Throttled | Should -BeTrue
        $back.Hogs[0].Pct | Should -Be 14
        $back.Cap | Should -Be 171
    }

    It 'dice «VRAM llena» a partir del 95 %, y que la gráfica se frenó' {
        $r = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.0) * 400)) 6.5)
        $f = @(Get-JuicerFrameFindings $r $null 144 @() @{ VramUsedPct = 97.0; MaxTemp = 70.0; Throttled = $true; ThrottleReason = 'límite de temperatura' })
        @($f | Where-Object { $_.Title -like 'VRAM llena*97 %*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'La gráfica se frenó durante la medida: límite de temperatura' }).Count | Should -Be 1
        $ok = @(Get-JuicerFrameFindings $r $null 144 @() @{ VramUsedPct = 80.0; MaxTemp = 70.0; Throttled = $false })
        @($ok | Where-Object { $_.Title -like 'VRAM llena*' -or $_.Title -like 'La gráfica se frenó*' }).Count | Should -Be 0
        # From what was saved with the measurement, too.
        $r.VramUsedPct = 99.0
        @(Get-JuicerFrameFindings $r $null 144 | Where-Object { $_.Title -like 'VRAM llena*' }).Count | Should -Be 1
    }
}

Describe 'Verificar una calibración' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
        $script:Down = @{ Exe = 'cs2.exe'; Old = 171; New = 127; Action = 'Bajar'; Why = 'x' }
        $script:Up = @{ Exe = 'cs2.exe'; Old = 130; New = 171; Action = 'Subir'; Why = 'x' }
    }

    It 'una bajada que ya se sostiene se confirma' {
        $held = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 400)) 5.0)
        $d = Get-JuicerPacerVerifyDecision $held $Down 171 'VRR' 48 @() 180
        $d.Action | Should -Be 'Confirmado'
        $d.Fps | Should -Be 127
    }

    It 'una bajada que sigue sin llegar propone bajar otra vez' {
        $still = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 360 + @(10.0) * 40)) 9.0)
        $d = Get-JuicerPacerVerifyDecision $still $Down 171 'VRR' 48 @() 180
        $d.Action | Should -Be 'Bajar'
        $d.Fps | Should -BeLessThan 127
        $d.Fps | Should -BeGreaterThan 60
        $d.Why | Should -BeLike 'Aún no llega*'
    }

    It 'una subida sólo se queda si la media coincide con el ritmo nuevo (3 %) y se sostiene' {
        $agree = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 4.0)
        (Get-JuicerPacerVerifyDecision $agree $Up 171 'VRR' 48 @() 180).Action | Should -Be 'Confirmado'
        # 100 FPS against 171: not within 3 %, and not even above where it was.
        $off = Measure-JuicerFrames @(New-PacedRows ([double[]](@(10.0) * 400)) 8.0)
        $d = Get-JuicerPacerVerifyDecision $off $Up 171 'VRR' 48 @() 180
        $d.Action | Should -Be 'Revertir'
        $d.Fps | Should -Be 130
        $d.Why | Should -BeLike '*menos de un 3 %*'
        # It misses by a lot but would hold something above where it was: a step down, not all the way back.
        $part = Measure-JuicerFrames @(New-PacedRows ([double[]](@(6.25) * 400)) 4.0)
        $s = Get-JuicerPacerVerifyDecision $part $Up 171 'VRR' 48 @() 180
        $s.Action | Should -Be 'Bajar'
        $s.Fps | Should -BeGreaterThan 133
        $s.Fps | Should -BeLessThan 171
    }

    It 'una medida inservible (un menú, el ritmo sin actuar) no confirma ni deshace' {
        $menu = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 400)) 1.0)
        (Get-JuicerPacerVerifyDecision $menu $Down 171 'VRR' 48 @() 180).Action | Should -Be 'Repetir'
        $free = Measure-JuicerFrames @(New-PacedRows ([double[]](@(2.0) * 400)) 1.9)
        (Get-JuicerPacerVerifyDecision $free $Down 171 'VRR' 48 @() 180).Action | Should -Be 'Repetir'
        (Get-JuicerPacerVerifyDecision $free $Up 171 'VRR' 48 @() 180).Why | Should -BeLike '*no estaba actuando*'
        # Noise stops a step down too.
        $still = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 360 + @(10.0) * 40)) 9.0)
        $still.Throttled = $true; $still.ThrottleReason = 'límite de temperatura'
        (Get-JuicerPacerVerifyDecision $still $Down 171 'VRR' 48 @() 180).Action | Should -Be 'Repetir'
    }

    It 'no mide si el juego no tiene el ritmo nuevo puesto: pide cerrarlo y abrirlo' {
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { throw 'no debería medir' }
        $v = Invoke-JuicerPacerVerify $Down -Monitor $Mon
        $v.Decision.Action | Should -Be 'Repetir'
        $v.Findings[0].Detail | Should -BeLike '*171 FPS y no los 127*ciérralo y ábrelo*'
    }

    It 'una subida que no se confirma vuelve a la calibración de antes' {
        $sig = Get-JuicerLimitSignature $Mon
        $state = Read-JuicerPacer
        Set-JuicerCalibrationEntry $state 'cs2.exe' $sig @{ Fps = 130; Why = 'antes'; Signature = $sig; Date = (Get-Date).AddDays(-5).ToString('s') }
        Save-JuicerPacer $state
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 130
        $prop = @{ Exe = 'cs2.exe'; Old = 130; New = 171; Action = 'Subir'; Why = 'sube'; Signature = $sig; Fingerprint = @{} }
        [void](Save-JuicerPacerCalibration $prop $Mon)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        $off = Measure-JuicerFrames @(New-PacedRows ([double[]](@(10.0) * 400)) 8.0)
        $off.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $off }.GetNewClosure()
        $v = Invoke-JuicerPacerVerify $prop -Monitor $Mon
        $v.Decision.Action | Should -Be 'Revertir'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 130
        (Get-JuicerCalibrationEntry (Read-JuicerPacer) 'cs2.exe' $sig).Fps | Should -Be 130
        $v.Findings[-1].Title | Should -Be 'Subida no confirmada: se vuelve a 130 FPS'
    }

    It 'una bajada que sigue sin llegar vuelve como propuesta, y confirmada queda marcada como verificada' {
        $sig = Get-JuicerLimitSignature $Mon
        $prop = @{ Exe = 'cs2.exe'; Old = 171; New = 127; Action = 'Bajar'; Why = 'baja'; Signature = $sig; Fingerprint = @{} }
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        [void](Save-JuicerPacerCalibration $prop $Mon)
        $still = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 360 + @(10.0) * 40)) 9.0)
        $still.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $still }.GetNewClosure()
        $v = Invoke-JuicerPacerVerify $prop -Monitor $Mon
        $v.Decision.Action | Should -Be 'Bajar'
        $v.NextProposal.Old | Should -Be 127
        $v.NextProposal.New | Should -BeLessThan 127
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        # Nothing changed until that is accepted.
        (Get-JuicerCalibrationEntry (Read-JuicerPacer) 'cs2.exe' $sig).Fps | Should -Be 127
        $held = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.87) * 400)) 5.0)
        $held.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $held }.GetNewClosure()
        $ok = Invoke-JuicerPacerVerify $prop -Monitor $Mon
        $ok.Decision.Action | Should -Be 'Confirmado'
        (Get-JuicerCalibrationEntry (Read-JuicerPacer) 'cs2.exe' $sig).Verified | Should -Not -BeNullOrEmpty
    }
}

Describe 'Dónde actúa el VRR y la V-Sync del propio juego' {
    BeforeAll {
        function New-ModeRows {
            param([string]$Mode, [string]$Sync = '0', [string]$Tearing = '1', [double]$Frame = 7.0, [int]$Count = 400, [string]$Mode2 = '', [int]$Count2 = 0)
            $rows = New-PacedRows ([double[]](@($Frame) * $Count)) 3.0 | ForEach-Object { $_.PresentMode = $Mode; $_.SyncInterval = $Sync; $_.AllowsTearing = $Tearing; $_ }
            if ($Count2 -gt 0) { $rows = @($rows) + @(New-PacedRows ([double[]](@($Frame) * $Count2)) 3.0 | ForEach-Object { $_.PresentMode = $Mode2; $_.SyncInterval = $Sync; $_.AllowsTearing = $Tearing; $_ }) }
            $rows
        }
    }

    It 'mide cuántos fotogramas pasan por el escritorio y cuántos van directos' {
        $r = Measure-JuicerFrames @(New-ModeRows 'Composed: Flip' -Mode2 'Hardware: Independent Flip' -Count 300 -Count2 100)
        $r.ComposedPct | Should -Be 75
        $r.DirectPct | Should -Be 25
        $r.Tearing | Should -Be 100
        $r.VSync | Should -Be 0
        (Measure-JuicerFrames @(New-ModeRows 'Hardware: Independent Flip')).DirectPct | Should -Be 100
    }

    It 'con VRR y casi todo compuesto, dice que el VRR no actúa y cómo arreglarlo' {
        $r = Measure-JuicerFrames @(New-ModeRows 'Composed: Flip')
        foreach ($use in 'VRR', 'EstroboSync') {
            $f = @(Get-JuicerFrameFindings $r $null 144 @() $null $use)
            $v = @($f | Where-Object { $_.Title -like 'El VRR no está actuando en este juego*' })
            $v.Count | Should -Be 1
            $v[0].Severity | Should -Be 'Medio'
            $v[0].Detail | Should -BeLike '*pantalla completa exclusiva*G-SYNC para ventana (NvVrrMode*'
        }
        # Without VRR, or with the frames going straight to the screen, it says nothing.
        @(Get-JuicerFrameFindings $r $null 144 @() $null 'Fijo' | Where-Object { $_.Title -like 'El VRR no está actuando*' }).Count | Should -Be 0
        @(Get-JuicerFrameFindings $r $null 144 | Where-Object { $_.Title -like 'El VRR no está actuando*' }).Count | Should -Be 0
        $direct = Measure-JuicerFrames @(New-ModeRows 'Hardware: Independent Flip')
        @(Get-JuicerFrameFindings $direct $null 144 @() $null 'VRR' | Where-Object { $_.Title -like 'El VRR no está actuando*' }).Count | Should -Be 0
        # Exclusive fullscreen (Legacy Flip) is direct too.
        @(Get-JuicerFrameFindings (Measure-JuicerFrames @(New-ModeRows 'Hardware: Legacy Flip')) $null 144 @() $null 'VRR' | Where-Object { $_.Title -like 'El VRR no está actuando*' }).Count | Should -Be 0
    }

    It 'con VRR, V-Sync del juego en la mitad de los fotogramas y por debajo de los Hz, manda desactivarla' {
        $r = Measure-JuicerFrames @(New-ModeRows 'Hardware: Independent Flip' -Sync '1' -Tearing '0' -Frame 8.0)
        $f = @(Get-JuicerFrameFindings $r $null 165 @() $null 'VRR')
        $v = @($f | Where-Object { $_.Title -like 'La V-Sync del propio juego está activa con VRR*' })
        $v.Count | Should -Be 1
        $v[0].Detail | Should -BeLike 'Desactiva la V-Sync del propio juego*'
        # At the refresh rate it is the sync that limits it (said already), without VRR it is not this advice, and a few frames do not count.
        $atHz = Measure-JuicerFrames @(New-ModeRows 'Hardware: Independent Flip' -Sync '1' -Tearing '0' -Frame 6.06)
        @(Get-JuicerFrameFindings $atHz $null 165 @() $null 'VRR' | Where-Object { $_.Title -like 'La V-Sync del propio juego*' }).Count | Should -Be 0
        @(Get-JuicerFrameFindings $r $null 165 @() $null 'Fijo' | Where-Object { $_.Title -like 'La V-Sync del propio juego*' }).Count | Should -Be 0
        $rare = Measure-JuicerFrames @(New-ModeRows 'Hardware: Independent Flip' -Sync '1' -Tearing '0' -Frame 8.0 -Count 100 -Mode2 'Hardware: Independent Flip' -Count2 300 | ForEach-Object { $_ })
        $rare.VSync | Should -Be 100
    }
}

Describe 'El historial de medidas y lo que vale para recomendar' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
    }

    It 'guarda las últimas 10 de cada juego, no las últimas 50 de todos' {
        1..14 | ForEach-Object { Save-JuicerFrameResult @{ Application = 'a.exe'; AvgFps = [double]$_; Date = (Get-Date).AddMinutes($_).ToString('s') } }
        1..3 | ForEach-Object { Save-JuicerFrameResult @{ Application = 'b.exe'; AvgFps = [double](100 + $_); Date = (Get-Date).AddMinutes(20 + $_).ToString('s') } }
        $h = @(Read-JuicerFrameHistory)
        @($h | Where-Object { $_.Application -eq 'a.exe' }).Count | Should -Be 10
        @($h | Where-Object { $_.Application -eq 'b.exe' }).Count | Should -Be 3
        (@($h | Where-Object { $_.Application -eq 'a.exe' })[0]).AvgFps | Should -Be 5
        (Get-JuicerPreviousFrameResult 'a.exe').AvgFps | Should -Be 14
        # A busy game used to push the others out of the shared 50.
        1..60 | ForEach-Object { Save-JuicerFrameResult @{ Application = 'c.exe'; AvgFps = 1.0 } }
        @(Read-JuicerFrameHistory | Where-Object { $_.Application -eq 'b.exe' }).Count | Should -Be 3
    }

    It 'un archivo de antes (50 en total, sin los campos nuevos) se lee y se recorta al guardar' {
        $old = @(1..50 | ForEach-Object { @{ Application = 'viejo.exe'; AvgFps = [double]$_; Low1 = 30.0; Date = '2026-01-01T10:00:00' } })
        [IO.File]::WriteAllText((Get-JuicerFrameHistoryPath), (ConvertTo-JuicerJson $old))
        (Get-JuicerPreviousFrameResult 'viejo.exe').AvgFps | Should -Be 50
        Save-JuicerFrameResult @{ Application = 'viejo.exe'; AvgFps = 99.0 }
        @(Read-JuicerFrameHistory).Count | Should -Be 10
    }

    It 'la comparación dice con o sin frame pacer en las dos medidas' {
        Format-JuicerPacerState @{ Cap = 171 } | Should -Be 'con frame pacer a 171 FPS'
        Format-JuicerPacerState @{ Cap = 0 } | Should -Be 'sin frame pacer'
        Format-JuicerPacerState @{ AvgFps = 100 } | Should -Be 'sin saber si había frame pacer'
        $prev = Measure-JuicerFrames @(New-PacedRows ([double[]](@(2.0) * 400)) 1.9)
        $prev.Cap = 0; $prev.Date = (Get-Date).AddDays(-1).ToString('s')
        $now = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        $now.Cap = 171
        $cmp = @(Get-JuicerFrameFindings $now $prev 180 | Where-Object { $_.Title -like 'Respecto al*' })
        $cmp[0].Detail | Should -BeLike '*Antes, sin frame pacer; ahora, con frame pacer a 171 FPS.*'
        $prev.Remove('Cap')
        (@(Get-JuicerFrameFindings $now $prev 180 | Where-Object { $_.Title -like 'Respecto al*' })[0]).Detail | Should -BeLike '*Antes, sin saber si había frame pacer; ahora, con frame pacer a 171 FPS.*'
    }

    It 'una medida de otra pantalla, de hace más de 60 días o con la gráfica frenada no vale para recomendar' {
        $sig = Get-JuicerLimitSignature $Mon
        $now = Get-Date
        $res = @{ Application = 'cs2.exe'; Date = $now.ToString('s') }
        Test-JuicerFrameResultUsable (@{ Signature = $sig } + $res) $sig 180 $now | Should -BeTrue
        Test-JuicerFrameResultUsable (@{ Signature = '144|VRR|otro' } + $res) $sig 180 $now | Should -BeFalse
        Test-JuicerFrameResultUsable (@{ Hz = 144 } + $res) $sig 180 $now | Should -BeFalse
        Test-JuicerFrameResultUsable (@{ Hz = 180 } + $res) $sig 180 $now | Should -BeTrue
        Test-JuicerFrameResultUsable @{ Application = 'cs2.exe'; Date = $now.AddDays(-61).ToString('s') } $sig 180 $now | Should -BeFalse
        Test-JuicerFrameResultUsable @{ Application = 'cs2.exe'; Date = $now.AddDays(-59).ToString('s') } $sig 180 $now | Should -BeTrue
        Test-JuicerFrameResultUsable (@{ Throttled = $true } + $res) $sig 180 $now | Should -BeFalse
        # Old measurements, with no signature or date, still count: nothing is known against them.
        Test-JuicerFrameResultUsable @{ Application = 'cs2.exe'; AvgFps = 100 } $sig 180 $now | Should -BeTrue
        Test-JuicerFrameResultUsable $null $sig 180 $now | Should -BeFalse
    }

    It 'el ritmo recomendado usa la última medida que vale, no la última a secas' {
        $sig = Get-JuicerLimitSignature $Mon
        # A game that holds 120 on 90 % of frames, uneven: recommended goes under the 171.
        $uneven = @{ Application = 'cs2.exe'; AvgFps = 140.0; Low1 = 60.0; Fps90 = 120.0; Signature = $sig; Date = (Get-Date).ToString('s') }
        Save-JuicerFrameResult $uneven
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 120
        # The latest is from another screen: it is ignored, and the one before it counts.
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 40.0; Low1 = 10.0; Fps90 = 35.0; Signature = '60|Fijo|otra'; Date = (Get-Date).ToString('s') }
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 120
        # Throttled: ignored too, so the card's bad day does not set the pace.
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 50.0; Low1 = 20.0; Fps90 = 45.0; Signature = $sig; Date = (Get-Date).ToString('s'); Throttled = $true }
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 120
        # Nothing usable left: the plain cap for the screen.
        Remove-Item -LiteralPath (Get-JuicerFrameHistoryPath)
        Save-JuicerFrameResult @{ Application = 'cs2.exe'; AvgFps = 40.0; Low1 = 10.0; Fps90 = 35.0; Date = (Get-Date).AddDays(-100).ToString('s') }
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 171
    }
}

Describe 'Una calibración por monitor, y cuándo conviene repetirla' {
    BeforeEach {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $script:Mon = New-TestMonitor
    }

    It 'una calibración de antes (una sola por juego) pasa a su firma al leerla' {
        $sig = Get-JuicerLimitSignature $Mon
        $json = '{"Engine":"Auto","Calibrated":{"cs2.exe":{"Fps":127,"Why":"x","Signature":"' + $sig + '","Date":"2026-06-01T10:00:00"},"sin.exe":{"Fps":90,"Why":"y"},"rota.exe":{"Fps":0},"basura.exe":3},"Games":{},"Pending":{},"Recipe":0}'
        [IO.File]::WriteAllText((Get-JuicerPacerPath), $json)
        $c = (Read-JuicerPacer).Calibrated
        $c['cs2.exe'][$sig].Fps | Should -Be 127
        $c['cs2.exe'][$sig].Signature | Should -Be $sig
        $c['sin.exe']['?'].Fps | Should -Be 90
        $c.ContainsKey('rota.exe') | Should -BeFalse
        $c.ContainsKey('basura.exe') | Should -BeFalse
        # In force on this monitor, as before.
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        # Saved again, it stays in the new shape.
        Save-JuicerPacer (Read-JuicerPacer)
        (Read-JuicerPacer).Calibrated['cs2.exe'][$sig].Fps | Should -Be 127
    }

    It 'cada monitor tiene la suya: volver al otro encuentra la que hizo allí' {
        $other = New-TestMonitor -Hz 144 -Id 'GSM9999'
        $sigA = Get-JuicerLimitSignature $Mon
        $sigB = Get-JuicerLimitSignature $other
        $sigA | Should -Not -Be $sigB
        $state = Read-JuicerPacer
        Set-JuicerCalibrationEntry $state 'cs2.exe' $sigA @{ Fps = 127; Why = 'a'; Signature = $sigA; Date = '2026-06-01T10:00:00' }
        Set-JuicerCalibrationEntry $state 'cs2.exe' $sigB @{ Fps = 100; Why = 'b'; Signature = $sigB; Date = '2026-06-02T10:00:00' }
        Save-JuicerPacer $state
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 127
        (Get-JuicerRecommendedFps 'cs2.exe' $other).Fps | Should -Be 100
        # With a third one, neither is used; the screen shown is the latest of the others.
        $third = New-TestMonitor -Hz 240 -Id 'DEL1234'
        (Get-JuicerRecommendedFps 'cs2.exe' $third).Calibrated | Should -BeNullOrEmpty
        (Select-JuicerCalibration (Read-JuicerPacer).Calibrated['cs2.exe'] $third).Fps | Should -Be 100
        (Select-JuicerCalibration (Read-JuicerPacer).Calibrated['cs2.exe'] $Mon).Fps | Should -Be 127
        Select-JuicerCalibration $null $Mon | Should -BeNullOrEmpty
        # Forgetting a game forgets all its screens; the four most recent are kept.
        Clear-JuicerPacerCalibration 'cs2.exe'
        (Read-JuicerPacer).Calibrated.ContainsKey('cs2.exe') | Should -BeFalse
        1..6 | ForEach-Object { Set-JuicerCalibrationEntry $state 'z.exe' "sig$_" @{ Fps = 100; Signature = "sig$_"; Date = "2026-06-0${_}T10:00:00" } }
        @($state.Calibrated['z.exe'].Keys).Count | Should -Be 4
        $state.Calibrated['z.exe'].ContainsKey('sig6') | Should -BeTrue
        $state.Calibrated['z.exe'].ContainsKey('sig1') | Should -BeFalse
    }

    It 'dice qué ha cambiado en el PC desde que se calibró, sólo de lo que se sabía' {
        $then = @{ Gpu = 'NVIDIA GeForce RTX 4070'; GpuDriver = '31.0.15.5222'; GameBuild = 'steam:1000'; Windows = '26100' }
        Get-JuicerCalibrationChanges $then $then | Should -BeNullOrEmpty
        $now = $then.Clone(); $now.GpuDriver = '32.0.15.6094'; $now.GameBuild = 'steam:1042'
        @(Get-JuicerCalibrationChanges $then $now) | Should -Be @('el driver de la gráfica', 'el juego (versión nueva)')
        # What could not be read then or now says nothing.
        $now2 = @{ Gpu = ''; GpuDriver = ''; GameBuild = ''; Windows = '26200' }
        @(Get-JuicerCalibrationChanges $then $now2) | Should -Be @('la versión de Windows')
        Get-JuicerCalibrationChanges $null $now | Should -BeNullOrEmpty
        # The age asks for a new one, young as it is.
        $age = Get-JuicerCalibrationAge '2026-06-18T12:00:00' 141 ([datetime]'2026-06-30T12:00:00') -Changes @('el driver de la gráfica')
        $age.Stale | Should -BeTrue
        $age.Text | Should -Be 'calibrado hace 12 días a 141 FPS'
        $age.Hint | Should -Be 'ha cambiado el driver de la gráfica desde que se calibró: vuelve a calibrar'
        $age.Sentence | Should -BeLike 'Calibrado hace 12 días a 141 FPS. Ha cambiado el driver*vuelve a calibrar.'
        (Get-JuicerCalibrationAge '2026-06-18T12:00:00' 141 ([datetime]'2026-06-30T12:00:00')).Stale | Should -BeFalse
        # The state of a game shows it.
        $g = @{ Fps = 118; CalFps = 118; CalDate = (Get-Date).AddDays(-2).ToString('s'); CalState = 'Activa'; CalChanges = @('el juego (versión nueva)') }
        Format-JuicerGameStatus $g | Should -BeLike '*calibrado hace 2 días a 118 FPS*ha cambiado el juego (versión nueva)*vuelve a calibrar*'
    }

    It 'la calibración guarda con qué PC se hizo, y Get-JuicerGameStatus avisa si ha cambiado' {
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $sig = Get-JuicerLimitSignature $Mon
        $state = Read-JuicerPacer
        Set-JuicerCalibrationEntry $state 'cs2.exe' $sig @{ Fps = 171; Why = 'x'; Signature = $sig; Date = (Get-Date).AddDays(-3).ToString('s'); Fingerprint = @{ Gpu = 'otra gráfica'; GpuDriver = ''; GameBuild = ''; Windows = '26100' } }
        Save-JuicerPacer $state
        Mock -ModuleName WinJuicer Get-JuicerCalibrationFingerprint { @{ Gpu = 'NVIDIA GeForce RTX 4070'; GpuDriver = ''; GameBuild = ''; Windows = '26100' } }
        $g = @(Get-JuicerGameStatus @(@{ ExeName = 'cs2.exe'; Exe = 'C:\Juegos\cs2.exe' }))[0]
        $g.CalState | Should -Be 'Activa'
        @($g.CalChanges) | Should -Be @('la gráfica')
        Format-JuicerGameStatus $g | Should -BeLike '*ha cambiado la gráfica*vuelve a calibrar*'
    }
}

Describe 'La versión del juego' {
    BeforeAll {
        $script:Lib = New-TestTempDir
        $apps = Join-Path $Lib 'steamapps'
        New-TestFile (Join-Path $apps 'appmanifest_730.acf') "`"AppState`"`n{`n`t`"appid`"`t`t`"730`"`n`t`"name`"`t`t`"Counter-Strike 2`"`n`t`"installdir`"`t`t`"Counter-Strike Global Offensive`"`n`t`"buildid`"`t`t`"15712498`"`n`t`"TargetBuildID`"`t`t`"99`"`n}"
        New-TestFile (Join-Path $apps 'common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe') 'MZ'
        New-TestFile (Join-Path $Lib 'suelto/otro.exe') 'MZ'
    }
    AfterAll { Remove-Item -LiteralPath $Lib -Recurse -Force -ErrorAction SilentlyContinue }

    It 'el manifiesto de Steam da el buildid' {
        $a = ConvertFrom-JuicerAcf ([IO.File]::ReadAllText((Join-Path $Lib 'steamapps/appmanifest_730.acf')))
        $a.BuildId | Should -Be '15712498'
        $a.AppId | Should -Be '730'
        (ConvertFrom-JuicerAcf "`"AppState`"`n{`n`t`"appid`"`t`"1`"`n`t`"installdir`"`t`"X`"`n}").BuildId | Should -BeNullOrEmpty
    }

    It 'un juego dentro de una biblioteca de Steam sale como steam:<buildid>, también desde su carpeta' {
        Get-JuicerGameBuild 'cs2.exe' (Join-Path $Lib 'steamapps/common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe') | Should -Be 'steam:15712498'
        Get-JuicerGameBuild '' (Join-Path $Lib 'steamapps/common/Counter-Strike Global Offensive') | Should -Be 'steam:15712498'
    }

    It 'fuera de Steam cae a la versión del ejecutable, y sin nada que leer no inventa' {
        # No version resource in these files: nothing to read.
        Get-JuicerGameBuild 'otro.exe' (Join-Path $Lib 'suelto/otro.exe') | Should -Not -BeLike 'steam:*'
        Get-JuicerGameBuild 'nunca-abierto-xyz.exe' | Should -Be ''
        Get-JuicerGameBuild '' (Join-Path $Lib 'no-existe/x.exe') | Should -Be ''
    }

    It 'la huella junta la gráfica, el driver, el juego y Windows' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpu { @{ Name = 'NVIDIA GeForce RTX 4070'; DriverVersion = '31.0.15.5222' } }
        $fp = Get-JuicerCalibrationFingerprint 'cs2.exe' (Join-Path $Lib 'steamapps/common/Counter-Strike Global Offensive/game/bin/win64/cs2.exe')
        $fp.Gpu | Should -Be 'NVIDIA GeForce RTX 4070'
        $fp.GpuDriver | Should -Be '31.0.15.5222'
        $fp.GameBuild | Should -Be 'steam:15712498'
        $fp.Windows | Should -Not -BeNullOrEmpty
    }
}

Describe 'El VRR no llega a los Hz del monitor' {
    BeforeAll {
        function New-RangeMonitor {
            param([int]$Hz = 165, [int]$Max = 144)
            $m = New-TestMonitor -Hz $Hz
            $m.Vrr = @{ Min = 48; Max = $Max; Kind = 'FreeSync'; Trusted = $true }
            $m
        }
    }

    It 'a 165 Hz con un rango VRR hasta 144, el ritmo se calcula con 144 y se avisa' {
        $c = Get-JuicerFpsCap 165 'VRR' $null 48 @() 0 144
        $c.Fps | Should -Be (Get-JuicerVrrCap 144)
        $c.Fps | Should -Be 138
        $c.Why | Should -BeLike '*tu pantalla va a 165 Hz pero su VRR llega a 144*'
        $c.VSync | Should -BeTrue
        (Get-JuicerFpsCap 165 'EstroboSync' $null 48 @() 0 144).Fps | Should -Be 138
        (Get-JuicerFpsCap 165 'EstroboSync' $null 48 @() 0 144).Why | Should -BeLike '*su VRR llega a 144*'
    }

    It 'si el rango llega a los Hz (o no se sabe), todo como antes' {
        (Get-JuicerFpsCap 165 'VRR' $null 48 @() 0 165).Fps | Should -Be 157
        (Get-JuicerFpsCap 165 'VRR' $null 48 @() 0 0).Fps | Should -Be 157
        (Get-JuicerFpsCap 165 'VRR' $null 48 @() 0 200).Fps | Should -Be 157
        (Get-JuicerFpsCap 165 'VRR' $null 48 @() 0 165).Why | Should -Not -BeLike '*VRR llega a*'
        # Not VRR: the range does not matter.
        (Get-JuicerFpsCap 165 'Fijo' $null 0 @() 0 144).Fps | Should -Be 165
        (Get-JuicerFpsCap 165 'Estrobo' $null 0 @() 0 144).Fps | Should -Be 165
    }

    It 'sólo el rango del bloque FreeSync de AMD baja el ritmo: el de HDMI o uno absurdo, no' {
        $m = New-RangeMonitor
        Get-JuicerVrrTop $m | Should -Be 144
        $hdmi = New-RangeMonitor
        $hdmi.Vrr = @{ Min = 48; Max = 144; Kind = 'HDMI 2.1 VRR' }
        Get-JuicerVrrTop $hdmi | Should -Be 0
        (Get-JuicerRecommendedFps 'cs2.exe' $hdmi).Fps | Should -Be 157
        $odd = New-RangeMonitor -Max 40
        Get-JuicerVrrTop $odd | Should -Be 0
        Get-JuicerVrrTop @{ Vrr = $null } | Should -Be 0
    }

    It 'el ritmo recomendado, el máximo al calibrar y el aviso del monitor van con el rango' {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $mon = New-RangeMonitor
        (Get-JuicerRecommendedFps 'cs2.exe' $mon).Fps | Should -Be 138
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $mon)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 138
        # A game that has room to spare does not go up past the range.
        $easy = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.25) * 400)) 2.0)
        $easy.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $easy }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $mon)
        Get-JuicerCalibrationProposal $f | Should -BeNullOrEmpty
        $f[-1].Title | Should -Be 'Calibrado: se queda en 138 FPS'
        # The Reflex note and the edge note do not fire at the rate under the range's top.
        Get-JuicerVsyncEdgeNote 138 165 'VRR' | Should -BeNullOrEmpty
        # The monitor's page says it.
        $t = @(Get-JuicerMonitorFindings @($mon) 'NVIDIA' | ForEach-Object { $_.Title })
        $t | Should -Contain 'Tu pantalla va a 165 Hz pero su VRR llega a 144'
        @(Get-JuicerMonitorFindings @(New-RangeMonitor -Max 165) 'NVIDIA' | Where-Object { $_.Title -like '*su VRR llega a*' }).Count | Should -Be 0
    }

    It 'un ritmo al que el rango ya no llega se marca como que no es el recomendado, y recalcular lo arregla' {
        $script:M = New-FakeMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $full = New-TestMonitor -Hz 165
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $full)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        $short = New-RangeMonitor
        $adv = @(Get-JuicerPacerAdvice @(Get-JuicerFpsLimits) $short)
        @($adv | Where-Object { $_.Title -like 'Hay 1 juego con un ritmo que ya no es el recomendado' }).Count | Should -Be 1
        @(Update-JuicerFpsLimits $short) | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 138
    }
}

Describe 'Frame pacer: correcciones de la revisión' {
    BeforeEach {
        $script:M = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'con VRR a 60 y 75 Hz el ritmo queda 3 por debajo, y no se avisa contra el propio ritmo' {
        foreach ($c in @(@{ Hz = 60; Fps = 57 }, @{ Hz = 75; Fps = 72 }, @{ Hz = 144; Fps = 138 }, @{ Hz = 180; Fps = 171 })) {
            $cap = Get-JuicerFpsCap $c.Hz 'VRR'
            $cap.Fps | Should -Be $c.Fps -Because "$($c.Hz) Hz"
            Get-JuicerVsyncEdgeNote $cap.Fps $c.Hz 'VRR' | Should -BeNullOrEmpty -Because "$($c.Hz) Hz"
            (Get-JuicerFpsCap $c.Hz 'EstroboSync').Fps | Should -Be $c.Fps -Because "$($c.Hz) Hz"
        }
        (Get-JuicerFpsCap 60 'VRR').Why | Should -BeLike '*3 por debajo de los Hz*59*'
        (Get-JuicerFpsCap 144 'VRR').Why | Should -BeLike '*la misma cifra que usa NVIDIA Reflex*'
        # The Reflex formula itself, which the Reflex detection needs, does not change.
        Get-JuicerVrrCap 60 | Should -Be 59
    }

    It 'las fechas guardadas se ordenan como fechas, también cuando PowerShell 7 las lee como DateTime' {
        $per = @{
            sigA = @{ Fps = 100; Date = [datetime]'2025-12-20T10:00:00' }
            sigB = @{ Fps = 141; Date = [datetime]'2026-11-05T10:00:00' }
        }
        (Select-JuicerCalibration $per $null).Fps | Should -Be 141
        $per.sigB.Date = '2026-11-05T10:00:00'
        (Select-JuicerCalibration $per $null).Fps | Should -Be 141
        $pacer = @{ Calibrated = @{ 'juego.exe' = @{} } }
        foreach ($e in @(@{ S = 'a'; D = [datetime]'2025-12-20' }, @{ S = 'b'; D = [datetime]'2026-11-05' }, @{ S = 'c'; D = [datetime]'2026-01-10' }, @{ S = 'd'; D = [datetime]'2026-02-10' }, @{ S = 'e'; D = [datetime]'2026-03-10' })) {
            Set-JuicerCalibrationEntry $pacer 'juego.exe' $e.S @{ Fps = 100; Date = $e.D }
        }
        @($pacer.Calibrated['juego.exe'].Keys | Sort-Object) | Should -Be @('b', 'c', 'd', 'e')
        ConvertTo-JuicerSortDate 'no es una fecha' | Should -Be ([datetime]::MinValue)
    }

    It 'un ritmo de NVIDIA que no se puede leer ahora no cuenta como borrado, aunque haya RivaTuner' {
        $M.Backend.State.FpsEngines = @('nvidia', 'rtss')
        $M.Backend.State.FpsBackend = 'nvidia'
        [void](Add-JuicerFpsLimit 'cs2.exe' 141)
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 0
        # NVAPI down for a moment (a driver restart): only RivaTuner answers.
        $M.Backend.State.FpsEngines = @('rtss')
        $M.Backend.State.FpsBackend = 'rtss'
        $l = @(Get-JuicerFpsLimits)
        $l[0].Unreadable | Should -BeTrue
        @(Get-JuicerWipedFpsLimits).Count | Should -Be 0
        @(Restore-JuicerWipedFpsLimits).Count | Should -Be 0
    }

    It 'la latencia de las columnas por defecto de PresentMon va del inicio del fotograma, no desde Present()' {
        $inv = [Globalization.CultureInfo]::InvariantCulture
        $rows = foreach ($i in 1..200) {
            [pscustomobject][ordered]@{
                Application = 'juego.exe'; ProcessID = '1'; SyncInterval = '0'; AllowsTearing = '1'; PresentMode = 'Hardware: Independent Flip'
                MsBetweenAppStart = '8.0'; MsCPUBusy = (5.0).ToString($inv); MsGPUBusy = '6.0'; MsUntilDisplayed = (3.0).ToString($inv)
            }
        }
        (Measure-JuicerFrames @($rows)).Latency | Should -Be 8
    }

    It 'el detalle del ritmo dice el frametime donde están los fotogramas, no el del objetivo' {
        $r = @{ Application = 'juego.exe'; AvgFps = 99.5; Steady = 100; MedianMs = 10.05; JitterMs = 0.1; P95Ms = 10.2; Frames = 3000; Seconds = 30 }
        $f = @(Get-JuicerPacerFindings $r 141)
        ($f.Detail -join ' ') | Should -BeLike '*100 % de los fotogramas a 10*05 ms*'
        ($f.Detail -join ' ') | Should -Not -BeLike '*a 7*09 ms*'
    }
}

