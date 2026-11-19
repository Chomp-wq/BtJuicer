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
