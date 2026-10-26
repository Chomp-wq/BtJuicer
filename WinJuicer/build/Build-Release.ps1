<#
.SYNOPSIS
    Builds what the one-line launcher downloads: WinJuicer.zip, and
    winjuicer.ps1 with that zip's SHA256 inside.
#>
param(
    [string]$Out = (Join-Path (Split-Path -Parent $PSScriptRoot) 'dist'),
    [string]$Version = 'dev'
)
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
if ($Version -notmatch '^[\w\.\-]+$') { throw "Versión no válida: $Version" }
if (-not (Test-Path -LiteralPath $Out)) { New-Item -ItemType Directory -Path $Out | Out-Null }
$Out = (Resolve-Path -LiteralPath $Out).ProviderPath

# What the tool needs to run, and nothing else: no tests, no build.
$files = @('WinJuicer.cmd', 'WinJuicer.ps1', 'WinJuicer.psm1', 'README.md') +
    @(Get-ChildItem -LiteralPath (Join-Path $root 'src') -Filter '*.ps1' -File | Sort-Object Name | ForEach-Object { 'src/' + $_.Name })

Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
$zip = Join-Path $Out 'WinJuicer.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
$archive = [IO.Compression.ZipFile]::Open($zip, [IO.Compression.ZipArchiveMode]::Create)
try {
    foreach ($f in $files) {
        # Forward slashes: what every unzipper, Expand-Archive in 5.1 included, expects.
        [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, (Join-Path $root $f), $f)
    }
} finally {
    $archive.Dispose()
}

$hash = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash
$template = [IO.File]::ReadAllText((Join-Path $PSScriptRoot 'winjuicer.ps1.in'))
$launcher = $template.Replace('__SHA256__', $hash).Replace('__VERSION__', $Version)
[IO.File]::WriteAllText((Join-Path $Out 'winjuicer.ps1'), $launcher, (New-Object Text.ASCIIEncoding))
[pscustomobject]@{ Zip = $zip; Launcher = (Join-Path $Out 'winjuicer.ps1'); Sha256 = $hash; Files = $files.Count }
