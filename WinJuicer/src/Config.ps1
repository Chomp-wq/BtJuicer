# Exporting and importing a configuration, as WinUtil does: what Win Juicer
# changed on this PC, in a JSON file, to apply the same on another one.
#
# It comes from the journal, so it holds what Win Juicer applied, not what
# was already set before. What only makes sense on this PC is left out:
# startup entries and per-game settings name programs and paths of this
# machine. On the other PC each tweak goes through the same engine, so what
# does not apply there (a plan on a dual-CCD X3D, Hyper-V on Home) says so
# and is skipped.

function Get-JuicerConfig {
    $journal = Read-JuicerJournal
    $tweaks = @()
    $toggles = @{}
    $apps = @()
    foreach ($e in $journal) {
        $id = [string]$e.Id
        if ($id -like 'app:*') { $apps += $id.Substring(4); continue }
        if ($id -eq 'red.dns') { continue }
        if ($id.EndsWith('!')) {
            $base = $id.TrimEnd('!')
            if (Find-JuicerTweak $base) { $toggles[$base] = $false }
            continue
        }
        $t = Find-JuicerTweak $id
        if (-not $t) { continue }
        if ($t.Off) { $toggles[$id] = $true } else { $tweaks += $id }
    }
    $dns = $null
    if (Get-JuicerJournalEntry $journal 'red.dns') {
        $cur = @(Get-JuicerCurrentDns | Where-Object { $_.Provider -ne 'Otro' })
        if ($cur.Count -gt 0) { $dns = $cur[0].Provider }
    }
    @{ Version = 1; Creado = (Get-Date).ToString('s'); Tweaks = $tweaks; Toggles = $toggles; Dns = $dns; Apps = $apps }
}

function Export-JuicerConfig {
    param([Parameter(Mandatory)][string]$Path)
    $cfg = Get-JuicerConfig
    [IO.File]::WriteAllText($Path, (ConvertTo-JuicerJson $cfg), (New-Object Text.UTF8Encoding $false))
    $cfg
}

# Reads and checks a configuration. Whatever this version of Win Juicer does
# not know goes to Unknown instead of failing the whole file.
function Read-JuicerConfig {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $raw = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($Path) | ConvertFrom-Json)
    } catch {
        throw "No es un archivo de configuración de Win Juicer: $_"
    }
    if ($raw -isnot [hashtable] -or [int]$raw.Version -ne 1) { throw 'No es un archivo de configuración de Win Juicer (versión 1).' }
    $cfg = @{ Tweaks = @(); Toggles = @{}; Dns = $null; Apps = @(); Unknown = @() }
    foreach ($id in @($raw.Tweaks | Where-Object { $_ })) {
        $t = Find-JuicerTweak $id
        if ($t -and -not $t.Off) { $cfg.Tweaks += [string]$id } else { $cfg.Unknown += [string]$id }
    }
    if ($raw.Toggles -is [hashtable]) {
        foreach ($k in $raw.Toggles.Keys) {
            $t = Find-JuicerTweak $k
            if ($t -and $t.Off) { $cfg.Toggles[$k] = [bool]$raw.Toggles[$k] } else { $cfg.Unknown += [string]$k }
        }
    }
    foreach ($n in @($raw.Apps | Where-Object { $_ })) {
        if (Find-JuicerDebloatApp $n) { $cfg.Apps += [string]$n } else { $cfg.Unknown += "app:$n" }
    }
    if ($raw.Dns) {
        if ((Get-JuicerDnsProviders).Contains([string]$raw.Dns)) { $cfg.Dns = [string]$raw.Dns } else { $cfg.Unknown += "dns:$($raw.Dns)" }
    }
    $cfg
}

# The tweaks an imported configuration means, in the order they would run.
# Toggles stay apart: they go through Set-JuicerToggle.
function Get-JuicerConfigTweaks {
    param([Parameter(Mandatory)][hashtable]$Config)
    @(foreach ($id in $Config.Tweaks) { Find-JuicerTweak $id })
    @(foreach ($n in $Config.Apps) { New-JuicerAppxTweak (Find-JuicerDebloatApp $n) })
    if ($Config.Dns) { New-JuicerDnsTweak $Config.Dns }
}

function Format-JuicerConfigSummary {
    param([Parameter(Mandatory)][hashtable]$Config)
    $l = @()
    foreach ($id in $Config.Tweaks) { $l += '· ' + (Find-JuicerTweak $id).Title }
    foreach ($k in ($Config.Toggles.Keys | Sort-Object)) { $l += '· {0}: {1}' -f (Find-JuicerTweak $k).Title, $(if ($Config.Toggles[$k]) { 'sí' } else { 'no' }) }
    foreach ($n in $Config.Apps) { $l += '· Quitar ' + (Find-JuicerDebloatApp $n).Title }
    if ($Config.Dns) { $l += '· DNS: ' + (Get-JuicerDnsProviders)[$Config.Dns].Title }
    if ($Config.Unknown.Count -gt 0) { $l += ''; $l += 'Esta versión no conoce, y se ignora: ' + ($Config.Unknown -join ', ') }
    $l -join "`n"
}
