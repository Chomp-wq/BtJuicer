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
    # Releases are named after a git short SHA, which has no order: «different» is all that can be
    # said. Only when both are plain numbered versions (1.2.3) can an older published one be told apart.
    if ($Local -match '^\d+(\.\d+)*$' -and $new -match '^\d+(\.\d+)*$') {
        try { if ([version]$new -le [version]$Local) { return $null } } catch { Write-Verbose "Versiones no comparables: $_" }
    }
    @{ Local = $Local; Latest = $new; Command = $script:OneLineCommand }
}

# «Actualizar ahora»: a new PowerShell that runs exactly the published one-line command
# shown in the notice, i.e. the launcher that downloads the zip and checks its SHA256
# before anything runs. Nothing is fetched or run from here, and only that exact shape of
# command is accepted: what is handed to PowerShell must never be anything else.
# -NoExit keeps the window open, so a failed download or a cancelled UAC can be read.
function Get-JuicerUpdateInvocation {
    param([string]$Command = $script:OneLineCommand, [string]$HostPath)
    if ($Command -notmatch '^irm https://github\.com/[\w.\-]+/[\w.\-]+/releases/download/[\w.\-]+/[\w.\-]+\.ps1 \| iex$') {
        throw "La orden de actualización no es la publicada: no se ejecuta ($Command)."
    }
    if (-not $HostPath) {
        # The same PowerShell this runs in; the one Windows ships if it cannot be told.
        try { $HostPath = (Get-Process -Id $PID).Path } catch { Write-Verbose "Sin ruta de PowerShell: $_" }
        if (-not $HostPath) { $HostPath = 'powershell.exe' }
    }
    @{ FilePath = $HostPath; ArgumentList = "-NoProfile -ExecutionPolicy Bypass -NoExit -Command `"$Command`""; Command = $Command }
}

# Starts it. The caller asks first and closes Win Juicer afterwards: this never runs on its own.
function Start-JuicerUpdate {
    param([Parameter(Mandatory)][hashtable]$Notice)
    $inv = Get-JuicerUpdateInvocation $Notice.Command
    Write-JuicerLog "Actualizar ahora: $($inv.Command)"
    Start-Process -FilePath $inv.FilePath -ArgumentList $inv.ArgumentList | Out-Null
}
