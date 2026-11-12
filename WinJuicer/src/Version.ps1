# Is there a newer Win Juicer? Whoever runs the one-line command always gets
# the latest; whoever downloaded the zip keeps that copy until told. The
# release's launcher carries the version it publishes, so reading those 3 KB
# is enough: no GitHub API, no account, nothing sent but the request.

$script:ReleaseLauncherUrl = 'https://github.com/Chomp-wq/BtJuicer/releases/download/winjuicer/winjuicer.ps1'
$script:OneLineCommand = "irm $script:ReleaseLauncherUrl | iex"

# version.txt only exists in what the release ships; a copy of the
# repository is a development version and checks nothing.
function Get-JuicerVersion {
    $f = Join-Path $script:ModuleRoot 'version.txt'
    if (-not (Test-Path -LiteralPath $f)) { return $null }
    $v = ([IO.File]::ReadAllText($f)).Trim()
    if ($v -match '^[\w\.\-]+$') { $v } else { $null }
}

function ConvertFrom-JuicerLauncherVersion {
    param([string]$Text)
    $m = [regex]::Matches($Text, "-Version '([\w\.\-]+)'")
    if ($m.Count -eq 0) { return $null }
    $m[$m.Count - 1].Groups[1].Value
}

function Get-JuicerLatestVersion {
    param([int]$TimeoutSec = 4)
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $r = Invoke-WebRequest -Uri $script:ReleaseLauncherUrl -UseBasicParsing -TimeoutSec $TimeoutSec -ErrorAction Stop
        $text = if ($r.Content -is [byte[]]) { [Text.Encoding]::ASCII.GetString($r.Content) } else { [string]$r.Content }
        ConvertFrom-JuicerLauncherVersion $text
    } catch {
        Write-JuicerLog "No se pudo comprobar si hay versión nueva: $_"
        $null
    }
}

# Null when there is nothing to say: up to date, a development copy, no
# connection, or WINJUICER_SIN_COMPROBAR set (the tests).
function Get-JuicerUpdateNotice {
    param([string]$Local = (Get-JuicerVersion), [scriptblock]$Latest = { Get-JuicerLatestVersion })
    if (-not $Local -or $Local -eq 'dev' -or $env:WINJUICER_SIN_COMPROBAR) { return $null }
    $new = & $Latest
    if (-not $new -or $new -eq $Local) { return $null }
    @{ Local = $Local; Latest = $new; Command = $script:OneLineCommand }
}
