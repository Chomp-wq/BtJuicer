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
            $summary = @(Format-JuicerHardwareSummary $hw)
            $script:Gui.C.HwLine.Text = (@($summary | Select-Object -First 2) -join '   ·   ')
            Show-JuicerGuiTweaks
            Show-JuicerGuiApps
            Show-JuicerGuiUndo
            $script:Gui.Findings = @(Get-JuicerAudit)
            Show-JuicerGuiAudit $script:Gui.Findings
            Show-JuicerGuiDebloat @(Get-JuicerDebloatState $hw)
            Show-JuicerGuiStartup @(Get-JuicerStartupReview)
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
                $games += @{ Id = ('{0}:{1}' -f $s[1], $i).ToLowerInvariant(); Name = $s[0]; Launcher = $s[1]; Dir = 'C:\Juegos'; Exe = "C:\Juegos\$($s[2])"; ExeName = $s[2]; Fps = $(if ($s[3]) { $s[3] } else { $null }); New = ($i -eq 4); Cover = @{ Path = $png; Kind = 'cover' } }
            }
            $icon = Join-Path $art 'icono.png'
            [void](Save-JuicerExeIcon (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') $icon)
            $games += @{ Id = 'custom:herramienta'; Name = 'Juego añadido a mano'; Launcher = 'custom'; Dir = 'C:\Juegos'; Exe = 'C:\Juegos\juego.exe'; ExeName = 'juego.exe'; Cover = @{ Path = $icon; Kind = 'icon' } }
            $games += @{ Id = 'medido:otro.exe'; Name = 'otro'; Launcher = 'Medido o limitado'; Dir = ''; Exe = 'otro.exe'; ExeName = 'otro.exe' }
            $script:Gui.GamesLoaded = $true
            Show-JuicerGuiGallery $games
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
                Competitive = $true; TwoGpus = $false
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
            & $shot '08-empezar-avanzado'
            $c.Tabs.SelectedItem = $c.TabAjustes
            Show-JuicerGuiTweakDetail 'ui.carpetas' -Focus
            & $shot '09-ajustes-detalles'
            $c.SideTabs.SelectedItem = $c.TabSidePrefs
            & $shot '10-ajustes-preferencias'
            & $shot '11-ajustes-pantalla-pequena' 960 620
            foreach ($t in @(@('TabDebloat', '12-debloat'), @('TabInstalar', '13-instalar'), @('TabInicio', '14-arranque'), @('TabAjusteFino', '15-ajuste-fino'), @('TabMantenimiento', '16-mantenimiento'), @('TabMitos', '17-no-hacemos'))) {
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
