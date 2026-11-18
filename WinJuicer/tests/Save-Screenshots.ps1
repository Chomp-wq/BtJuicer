# Screenshots of the window, for reviewing how it looks without a screen:
# builds it with the runner's real hardware and diagnosis, a sample gallery
# and a game's page, and renders each tab to a PNG in Out. CI uploads them.
param([string]$Out = 'capturas')

$ErrorActionPreference = 'Stop'
$outDir = [IO.Path]::GetFullPath($Out)
New-Item -ItemType Directory -Path $outDir -Force | Out-Null
# Its own home: nothing the window remembers on this machine is touched.
$env:WINJUICER_HOME = Join-Path ([IO.Path]::GetTempPath()) ('wj-capturas-' + [guid]::NewGuid().ToString('N'))

# WPF needs a single-threaded apartment, whatever this host uses.
$rs = [runspacefactory]::CreateRunspace()
$rs.ApartmentState = 'STA'
$rs.Open()
$ps = [powershell]::Create()
$ps.Runspace = $rs
$psm = Join-Path (Split-Path -Parent $PSScriptRoot) 'WinJuicer.psm1'
[void]$ps.AddScript({
        param($Module, $Out)
        Import-Module $Module -Force
        & (Get-Module WinJuicer) {
            param($Out)
            Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase
            $null = Show-JuicerGui -NoShow
            $hw = Get-JuicerHardwareProfile
            $script:Gui.Hw = $hw
            $script:Gui.Advice = Get-JuicerAdvice $hw
            $script:Gui.Snapshot = Get-JuicerGuiSnapshot
            $script:Gui.Ready = $true
            Show-JuicerGuiTweaks
            Show-JuicerGuiApps
            Show-JuicerGuiUndo
            $script:Gui.Findings = @(Get-JuicerAudit)
            Show-JuicerGuiAudit $script:Gui.Findings
            Show-JuicerGuiDebloat @(Get-JuicerDebloatState $hw)
            # What Windows measured for the boot (Diagnostics-Performance), as it looks with data: the runner
            # has no slow boots to show, so two plausible entries are drawn in addition to what it has.
            $startup = @(Get-JuicerStartupReview)
            $startup += @{ Id = 'hkcu-run:Steam'; Name = 'Steam'; Source = 'Registro (usuario)'; Kind = 'Registro'; Command = '"C:\Program Files (x86)\Steam\steam.exe" -silent'; Enabled = $true; Verdict = 'Prescindible'; Why = 'Funciona igual abriéndolo cuando lo necesites.'; BootDelay = 14.2 }
            $startup += @{ Id = 'servicio:AdobeARMservice'; Name = 'Adobe Acrobat Update Service'; Source = 'Servicio'; Kind = 'Servicio'; Command = 'AdobeARMservice'; Enabled = $true; Verdict = 'Prescindible'; Why = 'Sólo busca actualizaciones.'; BootDelay = 4.6 }
            Show-JuicerGuiStartup $startup
            Show-JuicerGuiLimiter (Get-JuicerGuiLimiter)

            # A sample gallery: drawn covers, an icon and a game with nothing.
            $art = Join-Path ([IO.Path]::GetTempPath()) ('wj-portadas-' + [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $art | Out-Null
            $paint = {
                param([string]$Name, [string]$Path, [byte[]]$Rgb)
                $color = 'System.Windows.Media.Color' -as [type]
                $g = New-Object System.Windows.Controls.Grid
                $g.Width = 300; $g.Height = 450
                $g.Background = New-Object System.Windows.Media.LinearGradientBrush ($color::FromRgb($Rgb[0], $Rgb[1], $Rgb[2])), ($color::FromRgb(20, 20, 26)), 90
                $t = New-Object System.Windows.Controls.TextBlock
                $t.Text = $Name; $t.FontSize = 34; $t.FontWeight = 'Bold'; $t.Foreground = 'White'; $t.TextWrapping = 'Wrap'
                $t.Margin = '20'; $t.VerticalAlignment = 'Bottom'
                [void]$g.Children.Add($t)
                $g.Measure((New-Object System.Windows.Size 300, 450))
                $g.Arrange((New-Object System.Windows.Rect 0, 0, 300, 450))
                $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap 300, 450, 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($g)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add(('System.Windows.Media.Imaging.BitmapFrame' -as [type])::Create($bmp))
                $fs = [IO.File]::Create($Path)
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            }
            $samples = @(
                @('Counter-Strike 2', 'Steam', 'cs2.exe', 171, [byte[]](200, 120, 30)), @('Cyberpunk 2077', 'Steam', 'cyberpunk2077.exe', 0, [byte[]](190, 30, 60)),
                @('Elden Ring', 'Steam', 'eldenring.exe', 60, [byte[]](150, 120, 60)), @('Portal 2', 'Steam', 'portal2.exe', 0, [byte[]](40, 110, 170)),
                @('Fortnite', 'Epic Games', 'fortniteclient-win64-shipping.exe', 0, [byte[]](90, 50, 160)), @('The Witcher 3', 'GOG', 'witcher3.exe', 0, [byte[]](120, 20, 20)),
                @('Forza Horizon 5', 'Xbox', 'forzahorizon5.exe', 0, [byte[]](30, 140, 120))
            )
            $games = @()
            $i = 0
            foreach ($s in $samples) {
                $i++
                $png = Join-Path $art "$i.png"
                & $paint $s[0] $png $s[4]
                # One protected after it failed, one with a change waiting for it to close.
                $games += @{ Id = ('{0}:{1}' -f $s[1], $i).ToLowerInvariant(); Name = $s[0]; Launcher = $s[1]; Dir = 'C:\Juegos'; Exe = "C:\Juegos\$($s[2])"; ExeName = $s[2]; Fps = $(if ($s[3]) { $s[3] } else { $null }); New = ($i -eq 4); Safe = ($i -eq 2); Waiting = ($i -eq 6); Cover = @{ Path = $png; Kind = 'cover' } }
            }
            $icon = Join-Path $art 'icono.png'
            [void](Save-JuicerExeIcon (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $icon)
            $games += @{ Id = 'custom:herramienta'; Name = 'Juego añadido a mano'; Launcher = 'custom'; Dir = 'C:\Juegos'; Exe = 'C:\Juegos\juego.exe'; ExeName = 'juego.exe'; Cover = @{ Path = $icon; Kind = 'icon' } }
            $games += @{ Id = 'medido:otro.exe'; Name = 'otro'; Launcher = 'Medido o limitado'; Dir = ''; Exe = 'otro.exe'; ExeName = 'otro.exe' }
            # One hidden («no es un juego»): the gallery shows «Mostrar ocultos (1)» and leaves it out.
            $games += @{ Id = 'steam:benchmark'; Name = 'Benchmark de prueba'; Launcher = 'Steam'; Dir = 'C:\Juegos'; Exe = 'C:\Juegos\bench.exe'; ExeName = 'bench.exe'; Hidden = $true }
            $script:Gui.GamesLoaded = $true
            Show-JuicerGuiGallery $games
            Show-JuicerGuiSafety @{ Protected = @(@{ Exe = 'cyberpunk2077.exe'; Name = 'Cyberpunk 2077'; Kind = 'Cierre'; Time = (Get-Date).AddHours(-3).ToString('s'); Module = 'nvwgf2umx.dll' }); Warned = @() }
            # What Windows undid and how ready the PC is, with plausible data (the runner has neither):
            # drawn only, nothing is read or applied. And the update notice with its two buttons.
            $script:Gui.Snapshot.Drift = @(
                @{ Id = 'juegos.modo'; Title = 'Modo juego'; State = 'Parcial'; Level = 1 }
                @{ Id = 'juegos.hags'; Title = 'Programación de GPU acelerada por hardware'; State = 'Pendiente'; Level = 1 }
                @{ Id = 'privacidad.telemetria'; Title = 'Telemetría al mínimo y sin sus tareas programadas'; State = 'Pendiente'; Level = 2 }
            )
            $script:Gui.ReadyLines = @(Get-JuicerReadyStatus @{ GameMode = $true; HagsConfigured = $true; HagsRestart = $true; Windowed = $true; GameDvr = $true; Rebar = $true; PlanKind = 'Rendimiento'; CpuMax = 100; OnBattery = $false; MonitorHz = 60; MonitorMaxHz = 165; Vbs = $true; Hvci = $true })
            $c0 = $script:Gui.C
            $c0.UpdateNote.Text = 'Hay otra versión publicada (a1b2c3d); tienes la 9f8e7d6.'
            $c0.UpdatePanel.Visibility = 'Visible'
            Show-JuicerGuiHome

            $shot = {
                param([string]$Name, [double]$W = 1220, [double]$H = 800)
                $root = $script:Gui.Window.Content
                $root.Background = $script:Gui.Window.Background
                $root.Measure((New-Object System.Windows.Size $W, $H))
                $root.Arrange((New-Object System.Windows.Rect 0, 0, $W, $H))
                $root.UpdateLayout()
                $bmp = New-Object System.Windows.Media.Imaging.RenderTargetBitmap ([int]$W), ([int]$H), 96, 96, ([System.Windows.Media.PixelFormats]::Pbgra32)
                $bmp.Render($root)
                $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
                $enc.Frames.Add(('System.Windows.Media.Imaging.BitmapFrame' -as [type])::Create($bmp))
                $fs = [IO.File]::Create((Join-Path $Out "$Name.png"))
                try { $enc.Save($fs) } finally { $fs.Dispose() }
            }
            $c = $script:Gui.C
            Set-JuicerGuiAdvanced $false
            $c.Tabs.SelectedItem = $c.TabHome
            & $shot '01-empezar-sencillo'
            & $shot '02-empezar-pantalla-pequena' 960 620
            $c.Tabs.SelectedItem = $c.TabJuegos
            & $shot '03-juegos-galeria'
            $c.PacerOptions.Visibility = 'Visible'
            & $shot '04-juegos-pantalla-y-frame-pacer'
            $c.PacerOptions.Visibility = 'Collapsed'
            $page = @{
                Game = $games[0]; Engine = 'nvidia'; Priority = 'Latencia'; Manual = 0; Auto = @{ Fps = 171; Why = 'Pantalla de 180 Hz con frecuencia variable.'; Calibrated = $true }
                Competitive = $true; TwoGpus = $false; Running = $true
                CalAge = (Get-JuicerCalibrationAge (Get-Date).AddDays(-41).ToString('s') 171)
                Last = @{ Date = (Get-Date).ToString('s'); AvgFps = 170.2; Low1 = 151; Steady = 96; JitterMs = 0.21; InputLatency = 12.3 }
                Chart = @{ Series = [double[]](@(5.85) * 50 + @(9.5) + @(5.85) * 40 + @(7.1) + @(5.85) * 60); TargetMs = 5.85; MaxMs = 9.5 }
                Tips = @(Get-JuicerGameTips -ExeName 'cs2.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Hz 180); Cover = $games[0].Cover
            }
            $script:Gui.Game = $games[0]
            $c.GalleryPage.Visibility = 'Collapsed'
            $c.GamePage.Visibility = 'Visible'
            Show-JuicerGuiGamePage $page
            & $shot '05-juego-pagina'
            Close-JuicerGuiGame
            $c.Tabs.SelectedItem = $c.TabEquipo
            & $shot '06-equipo'
            $c.Tabs.SelectedItem = $c.TabDeshacer
            & $shot '07-deshacer'
            Set-JuicerGuiAdvanced $true
            $c.Tabs.SelectedItem = $c.TabHome
            # The content protection, as it looks once on (drawn only: the runner keeps its DNS).
            Show-JuicerGuiShield @{ Active = $true; Since = (Get-Date).ToString('s'); Level = 1; LevelTitle = 'Equilibrada'; Provider = 'CleanBrowsing'; ProviderTitle = 'CleanBrowsing, filtro de adultos'; Phone = 'adult-filter-dns.cleanbrowsing.org'; Firewall = ''; Blocked = @{ Presets = @('Reddit'); Sites = @('ejemplo.com'); Count = 27 } }
            & $shot '08-empezar-avanzado'
            $c.Tabs.SelectedItem = $c.TabAjustes
            Show-JuicerGuiTweakDetail 'ui.carpetas' -Focus
            & $shot '09-ajustes-detalles'
            $c.SideTabs.SelectedItem = $c.TabSidePrefs
            & $shot '10-ajustes-preferencias'
            $c.SideTabs.SelectedItem = $c.TabSideProfiles
            & $shot '11-ajustes-perfiles'
            $c.SideTabs.SelectedItem = $c.TabSideDetail
            & $shot '12-ajustes-pantalla-pequena' 960 620
            foreach ($t in @(@('TabDebloat', '13-debloat'), @('TabInstalar', '14-instalar'), @('TabInicio', '15-arranque'), @('TabAjusteFino', '16-ajuste-fino'), @('TabMantenimiento', '17-mantenimiento'), @('TabMitos', '18-no-hacemos'))) {
                $c.Tabs.SelectedItem = $c[$t[0]]
                & $shot $t[1]
            }
            $script:Gui.Window.Close()
            'ok'
        } $Out
    }).AddArgument($psm).AddArgument($outDir)
try {
    $r = $ps.Invoke()
    foreach ($e in $ps.Streams.Error) { Write-Host "Error: $e" }
    Write-Host "Resultado: $r"
    Get-ChildItem -LiteralPath $outDir -Filter '*.png' | ForEach-Object { Write-Host ('{0}  {1:N0} KB' -f $_.Name, ($_.Length / 1KB)) }
    if ($ps.Streams.Error.Count -gt 0) { exit 1 }
} finally {
    $ps.Dispose()
    $rs.Dispose()
}
