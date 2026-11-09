# Game covers for the gallery. From what is already on this PC first: the
# Steam library cache, the logos inside an Xbox game's folder. Then, once,
# from the store's own image servers (Steam, Epic, GOG), and as a last
# resort the game's own icon. Everything ends up in ProgramData\WinJuicer\
# portadas, so the next time nothing is downloaded or extracted again.
#
# Only images, only over HTTPS, only from the stores' hosts, and only files
# that start like a JPEG or a PNG and are of a sensible size.

$script:CoverHosts = 'steamstatic.com', 'steampowered.com', 'epicgames.com', 'unrealengine.com', 'gog-statics.com', 'gog.com'
# A miss is not tried again for a week.
$script:CoverRetryDays = 7

function Get-JuicerCoverDir {
    $d = Join-Path (Get-JuicerHome) 'portadas'
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
    $d
}

function Get-JuicerCoverKey {
    param([string]$Id)
    ($Id.ToLowerInvariant() -replace '[^a-z0-9._-]', '_')
}

function Test-JuicerCoverUrl {
    param([string]$Url)
    $u = $null
    if (-not [Uri]::TryCreate($Url, 'Absolute', [ref]$u) -or $u.Scheme -ne 'https') { return $false }
    foreach ($h in $script:CoverHosts) { if ($u.Host -eq $h -or $u.Host.EndsWith(".$h")) { return $true } }
    $false
}

# Width and height from the first bytes of a JPEG or a PNG, without
# decoding it. Null for anything else.
function Get-JuicerImageSize {
    param([byte[]]$Bytes)
    $b = $Bytes
    if ($b.Count -ge 24 -and $b[0] -eq 0x89 -and $b[1] -eq 0x50 -and $b[2] -eq 0x4E -and $b[3] -eq 0x47) {
        $w = ([int]$b[16] -shl 24) -bor ([int]$b[17] -shl 16) -bor ([int]$b[18] -shl 8) -bor [int]$b[19]
        $h = ([int]$b[20] -shl 24) -bor ([int]$b[21] -shl 16) -bor ([int]$b[22] -shl 8) -bor [int]$b[23]
        return @{ Width = $w; Height = $h; Kind = 'png' }
    }
    if ($b.Count -lt 4 -or $b[0] -ne 0xFF -or $b[1] -ne 0xD8) { return $null }
    $i = 2
    while ($i + 9 -lt $b.Count) {
        if ($b[$i] -ne 0xFF) { return $null }
        $m = $b[$i + 1]
        if ($m -eq 0xFF) { $i++; continue }
        # Start of frame (not DHT C4, JPG C8 or DAC CC): height, then width.
        if ($m -ge 0xC0 -and $m -le 0xCF -and $m -notin 0xC4, 0xC8, 0xCC) {
            return @{ Width = ([int]$b[$i + 7] -shl 8) -bor $b[$i + 8]; Height = ([int]$b[$i + 5] -shl 8) -bor $b[$i + 6]; Kind = 'jpg' }
        }
        if ($m -in 0x01, 0xD8 -or ($m -ge 0xD0 -and $m -le 0xD7)) { $i += 2; continue }
        $i += 2 + (([int]$b[$i + 2] -shl 8) -bor $b[$i + 3])
    }
    $null
}

function Read-JuicerImageSize {
    param([string]$Path)
    try {
        $fs = [IO.File]::OpenRead($Path)
        try {
            $buf = New-Object byte[] ([Math]::Min(524288, $fs.Length))
            [void]$fs.Read($buf, 0, $buf.Length)
        } finally { $fs.Dispose() }
        Get-JuicerImageSize $buf
    } catch {
        $null
    }
}

# Of some images, the best cover: portrait (2:3, like a box) first, the
# biggest of them; else the biggest of the rest.
function Select-JuicerCoverImage {
    param([string[]]$Paths)
    $best = $null; $bestScore = -1
    foreach ($p in @($Paths)) {
        $s = Read-JuicerImageSize $p
        if (-not $s -or $s.Width -lt 64 -or $s.Height -lt 64) { continue }
        $ratio = $s.Width / $s.Height
        $score = $s.Width * $s.Height + $(if ($ratio -ge 0.6 -and $ratio -le 0.75) { 1e9 } else { 0 })
        if ($score -gt $bestScore) { $best = $p; $bestScore = $score }
    }
    $best
}

# --- Each store ------------------------------------------------------------------

function Get-JuicerSteamDir {
    $r = Read-JuicerReg 'HKCU\Software\Valve\Steam' 'SteamPath'
    if ($r -and $r.Value) { ([string]$r.Value) -replace '/', '\' } else { $null }
}

# Steam keeps the library's art in appcache\librarycache: once as
# «<appid>_library_600x900.jpg», now in a folder per game with names that
# change, so the portrait one is found by its size.
function Find-JuicerSteamCover {
    param([string]$SteamDir, [string]$AppId)
    if (-not $SteamDir -or -not $AppId) { return $null }
    $cache = Join-Path $SteamDir 'appcache\librarycache'
    foreach ($n in "${AppId}_library_600x900_2x.jpg", "${AppId}_library_600x900.jpg") {
        $p = Join-Path $cache $n
        if (Test-Path -LiteralPath $p) { return $p }
    }
    $dir = Join-Path $cache $AppId
    if (-not (Test-Path -LiteralPath $dir)) { return $null }
    $files = @(Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.jpg', '.jpeg', '.png' })
    $named = @($files | Where-Object { $_.Name -like 'library_600x900*' })
    if ($named.Count -gt 0) { return $named[0].FullName }
    Select-JuicerCoverImage @($files | ForEach-Object { $_.FullName })
}

function Get-JuicerSteamCoverUrls {
    param([string]$AppId)
    foreach ($h in 'https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps', 'https://cdn.cloudflare.steamstatic.com/steam/apps') {
        "$h/$AppId/library_600x900_2x.jpg"
        "$h/$AppId/library_600x900.jpg"
    }
    foreach ($h in 'https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps', 'https://cdn.cloudflare.steamstatic.com/steam/apps') { "$h/$AppId/header.jpg" }
}

# A value of a parsed JSON object, whether it came from ConvertFrom-Json or
# from the .NET serializer (a dictionary).
function Get-JuicerJsonField {
    param($Object, [string]$Name)
    if ($null -eq $Object) { return $null }
    if ($Object -is [Collections.IDictionary]) { return $Object[$Name] }
    $p = $Object.PSObject.Properties[$Name]
    if ($p) { $p.Value } else { $null }
}

# Epic's catalog cache (catcache.bin, base64 of a JSON list): which cover
# goes with each game's AppName, best first: the tall box art.
function ConvertFrom-JuicerEpicCatalog {
    param([string]$Text)
    $map = @{}
    $t = $Text.Trim()
    if (-not $t.StartsWith('[')) {
        try { $t = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($t)) } catch { return $map }
    }
    $items = $null
    try {
        if ($PSVersionTable.PSEdition -eq 'Core') {
            $items = $t | ConvertFrom-Json
        } else {
            # Windows PowerShell's ConvertFrom-Json gives up on a few MB.
            Add-Type -AssemblyName System.Web.Extensions
            $js = New-Object System.Web.Script.Serialization.JavaScriptSerializer
            $js.MaxJsonLength = [int]::MaxValue
            $items = $js.DeserializeObject($t)
        }
    } catch {
        Write-JuicerLog "Catálogo de Epic ilegible: $_"
        return $map
    }
    $rank = @{ DieselGameBoxTall = 0; OfferImageTall = 1; DieselGameBox = 2; OfferImageWide = 3; Thumbnail = 4 }
    foreach ($it in @($items)) {
        $best = $null; $bestRank = 99
        foreach ($k in @(Get-JuicerJsonField $it 'keyImages')) {
            $type = [string](Get-JuicerJsonField $k 'type'); $url = [string](Get-JuicerJsonField $k 'url')
            if ($rank.ContainsKey($type) -and $rank[$type] -lt $bestRank -and (Test-JuicerCoverUrl $url)) { $best = $url; $bestRank = $rank[$type] }
        }
        if (-not $best) { continue }
        foreach ($r in @(Get-JuicerJsonField $it 'releaseInfo')) {
            $app = [string](Get-JuicerJsonField $r 'appId')
            if ($app -and -not $map.ContainsKey($app.ToLowerInvariant())) { $map[$app.ToLowerInvariant()] = $best }
        }
    }
    $map
}

$script:EpicCovers = $null

function Get-JuicerEpicCoverUrl {
    param([string]$AppName)
    if ($null -eq $script:EpicCovers) {
        $script:EpicCovers = @{}
        $f = if ($env:ProgramData) { Join-Path $env:ProgramData 'Epic\EpicGamesLauncher\Data\Catalog\catcache.bin' }
        if ($f -and (Test-Path -LiteralPath $f)) { $script:EpicCovers = ConvertFrom-JuicerEpicCatalog ([IO.File]::ReadAllText($f)) }
    }
    $script:EpicCovers[$AppName.ToLowerInvariant()]
}

# GOG's public store API: the box art of a product id.
function Get-JuicerGogCoverUrl {
    param([string]$ProductId)
    if ($ProductId -notmatch '^\d+$') { return $null }
    try {
        $j = Invoke-RestMethod -Uri "https://api.gog.com/v2/games/$ProductId" -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
        $href = [string](Get-JuicerJsonField (Get-JuicerJsonField (Get-JuicerJsonField $j '_links') 'boxArtImage') 'href')
        if (Test-JuicerCoverUrl $href) { return $href }
    } catch {
        Write-JuicerLog "Sin portada de GOG para ${ProductId}: $_"
    }
    $null
}

# An Xbox (GDK) game names its logos in MicrosoftGame.config; the file may
# carry a scale in its name (Logo.scale-200.png).
function Find-JuicerXboxCover {
    param([string]$Dir)
    if (-not $Dir) { return $null }
    $cfg = Join-Path $Dir 'MicrosoftGame.config'
    if (-not (Test-Path -LiteralPath $cfg)) { return $null }
    try { $x = [xml][IO.File]::ReadAllText($cfg) } catch { return $null }
    $v = $x.SelectSingleNode('//*[local-name()="ShellVisuals"]')
    if (-not $v) { return $null }
    $found = @()
    foreach ($a in 'Square480x480Logo', 'Square310x310Logo', 'Square150x150Logo', 'StoreLogo', 'SplashScreenImage') {
        $rel = [string]$v.GetAttribute($a)
        if (-not $rel) { continue }
        $p = Join-Path $Dir $rel
        if (Test-Path -LiteralPath $p) { $found += $p; continue }
        $parent = Split-Path -Parent $p
        $base = [IO.Path]::GetFileNameWithoutExtension($p)
        $found += @(Get-ChildItem -LiteralPath $parent -Filter "$base.*" -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in '.png', '.jpg' } | ForEach-Object { $_.FullName })
    }
    if ($found.Count -eq 0) { return $null }
    Select-JuicerCoverImage $found
}

# --- Getting one -----------------------------------------------------------------

# Downloads one image into the cache; false if it is not a JPEG or PNG of a
# sensible size, or does not arrive.
function Save-JuicerCoverDownload {
    param([string]$Url, [string]$Target)
    if (-not (Test-JuicerCoverUrl $Url)) { return $false }
    $tmp = "$Target.descarga"
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $progress = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        try { Invoke-WebRequest -Uri $Url -OutFile $tmp -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop } finally { $ProgressPreference = $progress }
        $len = (Get-Item -LiteralPath $tmp).Length
        if ($len -lt 1024 -or $len -gt 8MB -or -not (Read-JuicerImageSize $tmp)) { return $false }
        Move-Item -LiteralPath $tmp -Destination $Target -Force
        return $true
    } catch {
        Write-Verbose "Sin portada en ${Url}: $_"
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# The program's own icon, 256 pixels if it has one that big, as a PNG.
function Save-JuicerExeIcon {
    param([string]$Exe, [string]$Target)
    if (-not (Test-JuicerWindows) -or -not $Exe -or -not (Test-Path -LiteralPath $Exe)) { return $false }
    try {
        if (-not ('WinJuicer.Icons' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinJuicer {
    public static class Icons {
        [DllImport("user32.dll", CharSet = CharSet.Unicode)]
        static extern uint PrivateExtractIcons(string file, int index, int cx, int cy, IntPtr[] icons, uint[] ids, uint count, uint flags);
        [DllImport("user32.dll")] public static extern bool DestroyIcon(IntPtr icon);
        // Zero when the file has no icon.
        public static IntPtr Extract(string file, int size) {
            var h = new IntPtr[1];
            var id = new uint[1];
            uint n = PrivateExtractIcons(file, 0, size, size, h, id, 1, 0);
            return (n == 0 || n == 0xFFFFFFFF) ? IntPtr.Zero : h[0];
        }
    }
}
'@
        }
        $h = [WinJuicer.Icons]::Extract($Exe, 256)
        if ($h -eq [IntPtr]::Zero) { return $false }
        try {
            Add-Type -AssemblyName PresentationCore, WindowsBase
            $src = ('System.Windows.Interop.Imaging' -as [type])::CreateBitmapSourceFromHIcon($h, ('System.Windows.Int32Rect' -as [type])::Empty, ('System.Windows.Media.Imaging.BitmapSizeOptions' -as [type])::FromEmptyOptions())
            $enc = New-Object System.Windows.Media.Imaging.PngBitmapEncoder
            $enc.Frames.Add(('System.Windows.Media.Imaging.BitmapFrame' -as [type])::Create($src))
            $fs = [IO.File]::Create($Target)
            try { $enc.Save($fs) } finally { $fs.Dispose() }
            return $true
        } finally {
            [void][WinJuicer.Icons]::DestroyIcon($h)
        }
    } catch {
        Write-JuicerLog "Sin icono de ${Exe}: $_"
        return $false
    }
}

# @{ Path; Kind = cover | icon }, or null. NoDownload: only what is already
# in the cache or on this PC, fast enough for drawing the gallery.
function Get-JuicerCover {
    param([Parameter(Mandatory)][hashtable]$Game, [switch]$NoDownload)
    $dir = Get-JuicerCoverDir
    $key = Get-JuicerCoverKey $Game.Id
    foreach ($ext in '.jpg', '.png') {
        $p = Join-Path $dir "$key$ext"
        if (Test-Path -LiteralPath $p) { return @{ Path = $p; Kind = 'cover' } }
    }
    $icon = Join-Path $dir "$key.icon.png"
    $miss = Join-Path $dir "$key.none"
    $parts = ([string]$Game.Id) -split ':', 2
    $store = $parts[0]; $storeKey = if ($parts.Count -gt 1) { $parts[1] } else { '' }

    # On this PC already.
    $local = switch ($store) {
        'steam' { Find-JuicerSteamCover (Get-JuicerSteamDir) $storeKey }
        'xbox' { Find-JuicerXboxCover $Game.Dir }
    }
    if ($local) { return @{ Path = $local; Kind = 'cover' } }

    $recent = (Test-Path -LiteralPath $miss) -and ((Get-Date) - (Get-Item -LiteralPath $miss).LastWriteTime).TotalDays -lt $script:CoverRetryDays
    if ($NoDownload -or $recent) {
        if (Test-Path -LiteralPath $icon) { return @{ Path = $icon; Kind = 'icon' } }
        if ($NoDownload) { return $null }
    } else {
        $urls = @(switch ($store) {
                'steam' { Get-JuicerSteamCoverUrls $storeKey }
                'epic games' { Get-JuicerEpicCoverUrl $storeKey }
                'gog' { Get-JuicerGogCoverUrl $storeKey }
            }) | Where-Object { $_ }
        foreach ($u in $urls) {
            $ext = if ($u -match '\.png($|\?)') { '.png' } else { '.jpg' }
            $target = Join-Path $dir "$key$ext"
            if (Save-JuicerCoverDownload $u $target) {
                Remove-Item -LiteralPath $icon, $miss -Force -ErrorAction SilentlyContinue
                return @{ Path = $target; Kind = 'cover' }
            }
        }
        Set-Content -LiteralPath $miss -Value (Get-Date).ToString('s')
    }
    if ((Test-Path -LiteralPath $icon) -or (Save-JuicerExeIcon $Game.Exe $icon)) { return @{ Path = $icon; Kind = 'icon' } }
    $null
}
