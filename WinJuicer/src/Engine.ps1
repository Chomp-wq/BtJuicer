# A tweak is a list of actions. Every action can say whether it is already in
# place, capture what is there now, apply itself, and put back what it
# captured. Tweaks apply all-or-nothing, and the journal keeps the state from
# before Win Juicer first touched each setting, so undoing returns the machine
# to how it was, not to how it was the last time the tool ran.

$script:StartLabels = @{
    Disabled         = 'Deshabilitado'
    Manual           = 'Manual'
    Automatic        = 'Automático'
    AutomaticDelayed = 'Automático (inicio retrasado)'
    Boot             = 'Arranque'
    System           = 'Sistema'
}

# --- Storage ---------------------------------------------------------------

function Get-JuicerHome {
    $h = $env:WINJUICER_HOME
    if (-not $h) { $h = Join-Path $env:ProgramData 'WinJuicer' }
    if (-not (Test-Path -LiteralPath $h)) { New-Item -ItemType Directory -Path $h -Force | Out-Null }
    $h
}

function Get-JuicerJournalPath { Join-Path (Get-JuicerHome) 'diario.json' }

function Write-JuicerLog {
    param([string]$Message)
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText((Join-Path (Get-JuicerHome) 'registro.log'), $line, (New-Object Text.UTF8Encoding $false))
    } catch {
        Write-Verbose "No se pudo escribir el registro: $_"
    }
}

# ConvertFrom-Json gives PSCustomObjects in Windows PowerShell 5.1, which has no
# -AsHashtable; the engine works on hashtables throughout.
function ConvertTo-JuicerHashtable {
    param($InputObject)
    if ($null -eq $InputObject) { return $null }
    if ($InputObject -is [System.Management.Automation.PSCustomObject]) {
        $h = @{}
        foreach ($p in $InputObject.PSObject.Properties) { $h[$p.Name] = ConvertTo-JuicerHashtable $p.Value }
        return $h
    }
    if ($InputObject -is [System.Collections.IList]) {
        $a = New-Object System.Collections.ArrayList
        foreach ($i in $InputObject) { [void]$a.Add((ConvertTo-JuicerHashtable $i)) }
        return , $a.ToArray()
    }
    $InputObject
}

function Read-JuicerJournal {
    $path = Get-JuicerJournalPath
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return , $list }
    try {
        $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    } catch {
        throw "El diario de cambios está dañado ($path). No lo borres: guarda el estado original de cada ajuste. Error: $_"
    }
    foreach ($e in @($data.Entries)) {
        $h = ConvertTo-JuicerHashtable $e
        $acts = New-Object System.Collections.ArrayList
        foreach ($a in @($h.Actions)) { [void]$acts.Add($a) }
        $h.Actions = $acts
        [void]$list.Add($h)
    }
    , $list
}

# Windows PowerShell 5.1's ConvertTo-Json writes an array that came out of a
# function as {"value": [...], "Count": n}, which would quietly corrupt every
# captured list. This writer only knows the shapes the journal uses, and sorts
# keys so the file diffs cleanly.
function ConvertTo-JuicerJson {
    param($Value)
    $sb = New-Object System.Text.StringBuilder
    Add-JuicerJsonValue $sb $Value 0
    $sb.ToString()
}

function ConvertTo-JuicerJsonString {
    param([string]$Text)
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('"')
    foreach ($ch in $Text.ToCharArray()) {
        switch ($ch) {
            '"' { [void]$sb.Append('\"') }
            '\' { [void]$sb.Append('\\') }
            default {
                if ([int]$ch -lt 0x20) { [void]$sb.AppendFormat('\u{0:x4}', [int]$ch) } else { [void]$sb.Append($ch) }
            }
        }
    }
    [void]$sb.Append('"')
    $sb.ToString()
}

function Add-JuicerJsonValue {
    param([System.Text.StringBuilder]$Sb, $Value, [int]$Depth)
    if ($Depth -gt 32) { throw 'Estructura demasiado profunda para el diario.' }
    $inner = '  ' * ($Depth + 1)
    $outer = '  ' * $Depth
    if ($null -eq $Value) { [void]$Sb.Append('null'); return }
    if ($Value -is [bool]) { [void]$Sb.Append($(if ($Value) { 'true' } else { 'false' })); return }
    if ($Value -is [string] -or $Value -is [char] -or $Value -is [guid] -or $Value -is [enum]) {
        [void]$Sb.Append((ConvertTo-JuicerJsonString ([string]$Value))); return
    }
    if ($Value -is [datetime]) { [void]$Sb.Append((ConvertTo-JuicerJsonString $Value.ToString('s'))); return }
    $code = [int][Type]::GetTypeCode($Value.GetType())
    if ($code -ge 5 -and $code -le 15) {
        [void]$Sb.Append(([IFormattable]$Value).ToString($null, [Globalization.CultureInfo]::InvariantCulture)); return
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $h = [ordered]@{}
        foreach ($p in $Value.PSObject.Properties) { $h[$p.Name] = $p.Value }
        $Value = $h
    }
    if ($Value -is [System.Collections.IDictionary]) {
        $keys = @($Value.Keys | Sort-Object)
        if ($keys.Count -eq 0) { [void]$Sb.Append('{}'); return }
        [void]$Sb.Append("{`n")
        for ($i = 0; $i -lt $keys.Count; $i++) {
            [void]$Sb.Append($inner).Append((ConvertTo-JuicerJsonString ([string]$keys[$i]))).Append(': ')
            Add-JuicerJsonValue $Sb $Value[$keys[$i]] ($Depth + 1)
            if ($i -lt $keys.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append("`n")
        }
        [void]$Sb.Append($outer).Append('}')
        return
    }
    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @(foreach ($x in $Value) { , $x })
        if ($items.Count -eq 0) { [void]$Sb.Append('[]'); return }
        [void]$Sb.Append("[`n")
        for ($i = 0; $i -lt $items.Count; $i++) {
            [void]$Sb.Append($inner)
            Add-JuicerJsonValue $Sb $items[$i] ($Depth + 1)
            if ($i -lt $items.Count - 1) { [void]$Sb.Append(',') }
            [void]$Sb.Append("`n")
        }
        [void]$Sb.Append($outer).Append(']')
        return
    }
    [void]$Sb.Append((ConvertTo-JuicerJsonString ([string]$Value)))
}

function Save-JuicerJournal {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Entries)
    $path = Get-JuicerJournalPath
    $json = ConvertTo-JuicerJson @{ Version = 1; Entries = $Entries }
    $tmp = "$path.tmp"
    [IO.File]::WriteAllText($tmp, $json, (New-Object Text.UTF8Encoding $false))
    # Write-then-swap: a power cut must never leave half a journal.
    # ([NullString] because PowerShell hands .NET an empty string for $null.)
    if (Test-Path -LiteralPath $path) { [IO.File]::Replace($tmp, $path, [NullString]::Value) } else { [IO.File]::Move($tmp, $path) }
}

function Get-JuicerJournalEntry {
    param([System.Collections.IList]$Journal, [string]$Id)
    foreach ($e in $Journal) { if ($e.Id -eq $Id) { return $e } }
    $null
}

# --- Actions ---------------------------------------------------------------

function Get-JuicerDesiredReg {
    param($Action)
    $kind = if ($Action.Kind) { $Action.Kind } else { 'DWord' }
    @{ Kind = $kind; Value = $Action.Value }
}

# "A=1;B=2;" strings, as used by DirectX per-app and global GPU preferences.
function ConvertFrom-JuicerTokenString {
    param([string]$Text)
    $d = [ordered]@{}
    if ($Text) {
        foreach ($part in $Text.Split(';')) {
            if ($part -match '^\s*([^=]+?)\s*=(.*)$') { $d[$Matches[1]] = $Matches[2] }
        }
    }
    $d
}

function ConvertTo-JuicerTokenString {
    param([System.Collections.IDictionary]$Tokens)
    -join @($Tokens.Keys | ForEach-Object { '{0}={1};' -f $_, $Tokens[$_] })
}

function Get-JuicerTokenValue {
    param([System.Collections.IDictionary]$Tokens, [string]$Token)
    foreach ($k in @($Tokens.Keys)) { if ($k -eq $Token) { return $Tokens[$k] } }
    $null
}

function Set-JuicerTokenValue {
    param([System.Collections.IDictionary]$Tokens, [string]$Token, $Value)
    foreach ($k in @($Tokens.Keys)) { if ($k -eq $Token) { $Tokens.Remove($k) } }
    if ($null -ne $Value) { $Tokens[$Token] = [string]$Value }
}

function Get-JuicerRegString {
    param($Reg)
    if ($null -eq $Reg -or $Reg.Kind -notin 'String', 'ExpandString') { return '' }
    [string]$Reg.Value
}

function Get-JuicerMissingKeys {
    param([string]$Path)
    $missing = New-Object System.Collections.ArrayList
    $p = $Path.TrimEnd('\')
    while ($p.Contains('\') -and -not (Test-JuicerRegKey $p)) {
        [void]$missing.Insert(0, $p)
        $p = Get-JuicerRegParent $p
    }
    , ([string[]]$missing.ToArray())
}

function Remove-JuicerCreatedKeys {
    param($Keys)
    $list = @($Keys | Where-Object { $_ })
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        [void](& (Get-JuicerBackend).KeyDelete $list[$i])
    }
}

function ConvertTo-JuicerExclusionPath {
    param([string]$Path)
    $Path.Trim().TrimEnd('\').ToLowerInvariant()
}

function Get-JuicerActionId {
    param([Parameter(Mandatory)]$Action, [string]$TweakId)
    switch ($Action.Type) {
        'Registry' { return ('Reg|{0}|{1}' -f $Action.Path, $Action.Name).ToLowerInvariant() }
        'RegistryToken' { return ('Tok|{0}|{1}|{2}' -f $Action.Path, $Action.Name, $Action.Token).ToLowerInvariant() }
        'Service' { return ('Svc|{0}' -f $Action.Name).ToLowerInvariant() }
        'Spi' { return ('Spi|{0}' -f [uint32]$Action.Set) }
        'Task' { return ('Task|{0}|{1}' -f $Action.Path, $Action.Name).ToLowerInvariant() }
        'DefenderExclusion' { return 'Def|' + (ConvertTo-JuicerExclusionPath $Action.Path) }
        'Custom' { return ('Custom|{0}|{1}' -f $TweakId, $Action.Key) }
    }
    throw "Tipo de acción desconocido: $($Action.Type)"
}

function Format-JuicerRegValue {
    param($Reg)
    if ($null -eq $Reg) { return '(no existe)' }
    $v = ConvertTo-JuicerRegValue $Reg.Kind $Reg.Value
    switch ($Reg.Kind) {
        'DWord' { if ($v -gt 255) { return ('{0} (0x{0:X})' -f $v) } else { return "$v" } }
        'MultiString' { return ('"' + ($v -join '", "') + '"') }
        { $_ -in 'Binary', 'None' } { return (($v | ForEach-Object { '{0:X2}' -f $_ }) -join ' ') }
        default { return ('"{0}"' -f $v) }
    }
}

function Format-JuicerAction {
    param([Parameter(Mandatory)]$Action)
    if ($Action.Label) { return $Action.Label }
    switch ($Action.Type) {
        'Registry' {
            $name = if ($Action.Name -eq '') { '(predeterminado)' } else { $Action.Name }
            if ($Action.Delete) { return "Borrar $($Action.Path)\$name" }
            return '{0}\{1} = {2}' -f $Action.Path, $name, (Format-JuicerRegValue (Get-JuicerDesiredReg $Action))
        }
        'RegistryToken' { return '{0}\{1}: {2}={3}' -f $Action.Path, $Action.Name, $Action.Token, $Action.Value }
        'Service' { return 'Servicio {0}: {1}' -f $Action.Name, $script:StartLabels[$Action.Start] }
        'Spi' { return 'SystemParametersInfo 0x{0:X}: {1}' -f [uint32]$Action.Set, $Action.Value }
        'Task' { return 'Tarea programada {0}{1}: {2}' -f $Action.Path, $Action.Name, $(if ($Action.Enabled) { 'habilitada' } else { 'deshabilitada' }) }
        'DefenderExclusion' { return "Exclusión de Microsoft Defender: $($Action.Path)" }
    }
    "$($Action.Type) $($Action.Key)"
}

function Test-JuicerAction {
    param([Parameter(Mandatory)]$Action)
    $b = Get-JuicerBackend
    switch ($Action.Type) {
        'Registry' {
            $cur = Read-JuicerReg $Action.Path $Action.Name
            if ($Action.Ok) { return [bool](& $Action.Ok $cur) }
            if ($Action.Delete) { return ($null -eq $cur) }
            return (Test-JuicerRegValueEqual $cur (Get-JuicerDesiredReg $Action))
        }
        'RegistryToken' {
            $tokens = ConvertFrom-JuicerTokenString (Get-JuicerRegString (Read-JuicerReg $Action.Path $Action.Name))
            return ((Get-JuicerTokenValue $tokens $Action.Token) -eq [string]$Action.Value)
        }
        'Service' {
            $cur = & $b.SvcRead $Action.Name
            if ($null -eq $cur) { return $true }
            if ($Action.Ok) { return [bool](& $Action.Ok $cur) }
            return ($cur.Start -eq $Action.Start)
        }
        'Spi' { return ([bool](& $b.SpiGet $Action.Get) -eq [bool]$Action.Value) }
        'Task' {
            $t = & $b.TaskRead $Action.Path $Action.Name
            if ($null -eq $t) { return $true }
            return ([bool]$t.Enabled -eq [bool]$Action.Enabled)
        }
        'DefenderExclusion' {
            $want = ConvertTo-JuicerExclusionPath $Action.Path
            foreach ($p in (& $b.DefList)) { if ((ConvertTo-JuicerExclusionPath $p) -eq $want) { return $true } }
            return $false
        }
        'Custom' { return [bool](& $Action.Test) }
    }
    throw "Tipo de acción desconocido: $($Action.Type)"
}

function Save-JuicerActionState {
    param([Parameter(Mandatory)]$Action, [string]$TweakId)
    $b = Get-JuicerBackend
    $c = @{ Type = $Action.Type; Id = (Get-JuicerActionId $Action $TweakId) }
    switch ($Action.Type) {
        'Registry' {
            $c.Path = $Action.Path; $c.Name = $Action.Name
            $c.Old = ConvertTo-JuicerStoredRegValue (Read-JuicerReg $Action.Path $Action.Name)
            $c.CreatedKeys = Get-JuicerMissingKeys $Action.Path
        }
        'RegistryToken' {
            $cur = Read-JuicerReg $Action.Path $Action.Name
            $c.Path = $Action.Path; $c.Name = $Action.Name; $c.Token = $Action.Token
            $c.ValueExisted = ($null -ne $cur)
            $c.OldToken = Get-JuicerTokenValue (ConvertFrom-JuicerTokenString (Get-JuicerRegString $cur)) $Action.Token
            $c.CreatedKeys = Get-JuicerMissingKeys $Action.Path
        }
        'Service' {
            $cur = & $b.SvcRead $Action.Name
            $c.Name = $Action.Name; $c.Exists = ($null -ne $cur)
            if ($cur) { $c.Start = $cur.Start; $c.Running = [bool]$cur.Running }
        }
        'Spi' {
            $c.Get = [uint32]$Action.Get; $c.Set = [uint32]$Action.Set
            $c.Old = [bool](& $b.SpiGet $Action.Get)
        }
        'Task' {
            $t = & $b.TaskRead $Action.Path $Action.Name
            $c.Path = $Action.Path; $c.Name = $Action.Name; $c.Exists = ($null -ne $t)
            if ($t) { $c.Enabled = [bool]$t.Enabled }
        }
        'DefenderExclusion' {
            $c.Path = $Action.Path
            $c.Existed = Test-JuicerAction $Action
        }
        'Custom' {
            $c.TweakId = $TweakId; $c.CustomKey = $Action.Key
            $c.State = & $Action.Capture
        }
    }
    $c
}

function Invoke-JuicerAction {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Capture)
    $b = Get-JuicerBackend
    switch ($Action.Type) {
        'Registry' {
            if ($Action.Delete) { Remove-JuicerReg $Action.Path $Action.Name; return }
            $d = Get-JuicerDesiredReg $Action
            Write-JuicerReg $Action.Path $Action.Name $d.Kind $d.Value
        }
        'RegistryToken' {
            $tokens = ConvertFrom-JuicerTokenString (Get-JuicerRegString (Read-JuicerReg $Action.Path $Action.Name))
            Set-JuicerTokenValue $tokens $Action.Token $Action.Value
            Write-JuicerReg $Action.Path $Action.Name 'String' (ConvertTo-JuicerTokenString $tokens)
        }
        'Service' {
            if (-not $Capture.Exists) { return }
            & $b.SvcWrite $Action.Name $Action.Start
            if ($Action.Start -eq 'Disabled' -and $Capture.Running) {
                # Best effort: the start type is what matters after a reboot.
                try { & $b.SvcStop $Action.Name } catch { Write-JuicerLog "No se pudo detener $($Action.Name): $_" }
            }
        }
        'Spi' { & $b.SpiSet $Action.Set ([bool]$Action.Value) }
        'Task' { if ($Capture.Exists) { & $b.TaskWrite $Action.Path $Action.Name ([bool]$Action.Enabled) } }
        'DefenderExclusion' { & $b.DefAdd $Action.Path }
        'Custom' { & $Action.Apply $Capture.State }
    }
}

function Restore-JuicerActionState {
    param([Parameter(Mandatory)]$Capture)
    $b = Get-JuicerBackend
    $c = $Capture
    switch ($c.Type) {
        'Registry' {
            if ($null -eq $c.Old) { Remove-JuicerReg $c.Path $c.Name } else { Write-JuicerReg $c.Path $c.Name $c.Old.Kind $c.Old.Value }
            Remove-JuicerCreatedKeys $c.CreatedKeys
        }
        'RegistryToken' {
            $cur = Read-JuicerReg $c.Path $c.Name
            $tokens = ConvertFrom-JuicerTokenString (Get-JuicerRegString $cur)
            Set-JuicerTokenValue $tokens $c.Token $c.OldToken
            $text = ConvertTo-JuicerTokenString $tokens
            if ($text -eq '' -and -not $c.ValueExisted) {
                Remove-JuicerReg $c.Path $c.Name
            } elseif ($null -ne $cur -or $text -ne '') {
                Write-JuicerReg $c.Path $c.Name 'String' $text
            }
            Remove-JuicerCreatedKeys $c.CreatedKeys
        }
        'Service' {
            if (-not $c.Exists) { return }
            $cur = & $b.SvcRead $c.Name
            if ($null -eq $cur) { return }
            if ($cur.Start -ne $c.Start) { & $b.SvcWrite $c.Name $c.Start }
            if ($c.Running -and -not $cur.Running) {
                try { & $b.SvcStart $c.Name } catch { Write-JuicerLog "No se pudo arrancar $($c.Name): $_" }
            }
        }
        'Spi' { & $b.SpiSet $c.Set ([bool]$c.Old) }
        'Task' { if ($c.Exists) { & $b.TaskWrite $c.Path $c.Name ([bool]$c.Enabled) } }
        'DefenderExclusion' { if (-not $c.Existed) { & $b.DefRemove $c.Path } }
        'Custom' {
            $tweak = Find-JuicerTweak $c.TweakId
            $action = $null
            if ($tweak) { $action = @($tweak.Actions) | Where-Object { $_.Type -eq 'Custom' -and $_.Key -eq $c.CustomKey } | Select-Object -First 1 }
            if (-not $action) { throw "No encuentro cómo deshacer '$($c.CustomKey)' de '$($c.TweakId)'." }
            & $action.Restore $c.State
        }
        default { throw "Tipo de acción desconocido en el diario: $($c.Type)" }
    }
}

# --- Tweaks ----------------------------------------------------------------

function Resolve-JuicerActions {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    if ($Tweak.Actions -is [scriptblock]) { return , @(& $Tweak.Actions) }
    , @($Tweak.Actions)
}

function Get-JuicerSkipReason {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    if ($Tweak.Skip) {
        $r = & $Tweak.Skip
        if ($r) { return [string]$r }
    }
    $null
}

function Get-JuicerTweakState {
    param([Parameter(Mandatory)][hashtable]$Tweak, [System.Collections.IList]$Journal)
    if ($null -eq $Journal) { $Journal = Read-JuicerJournal }
    $s = @{ State = 'Pendiente'; Reason = $null; Undoable = ($null -ne (Get-JuicerJournalEntry $Journal $Tweak.Id)); Pending = @() }
    try {
        $skip = Get-JuicerSkipReason $Tweak
        if ($skip) { $s.State = 'NoAplica'; $s.Reason = $skip; return $s }
        $actions = Resolve-JuicerActions $Tweak
        $pending = @($actions | Where-Object { -not (Test-JuicerAction $_) })
        $s.Pending = $pending
        if ($actions.Count -eq 0) { $s.State = 'NoAplica'; $s.Reason = 'No hay nada a lo que aplicarlo en este equipo.' }
        elseif ($pending.Count -eq 0) { $s.State = 'Aplicado' }
        elseif ($pending.Count -lt $actions.Count) { $s.State = 'Parcial' }
    } catch {
        $s.State = 'Error'; $s.Reason = "$_"
    }
    $s
}

function New-JuicerResult {
    param([hashtable]$Tweak, [string]$Outcome, [string]$Message = '')
    @{ Id = $Tweak.Id; Title = $Tweak.Title; Outcome = $Outcome; Message = $Message; Reboot = $Tweak.Reboot; Changes = @() }
}

function Invoke-JuicerTweak {
    param([Parameter(Mandatory)][hashtable]$Tweak, [switch]$Simulate)
    $skip = Get-JuicerSkipReason $Tweak
    if ($skip) { return (New-JuicerResult $Tweak 'NoAplica' $skip) }
    try {
        $actions = Resolve-JuicerActions $Tweak
        $pending = @($actions | Where-Object { -not (Test-JuicerAction $_) })
    } catch {
        return (New-JuicerResult $Tweak 'Error' "No se pudo leer el estado actual: $_")
    }
    if ($actions.Count -eq 0) { return (New-JuicerResult $Tweak 'NoAplica' 'No hay nada a lo que aplicarlo en este equipo.') }
    if ($pending.Count -eq 0) { return (New-JuicerResult $Tweak 'YaEstaba') }

    $result = New-JuicerResult $Tweak 'Aplicado'
    $result.Changes = @($pending | ForEach-Object { Format-JuicerAction $_ })
    if ($Simulate) { $result.Outcome = 'Simulado'; return $result }

    try {
        $captures = @(foreach ($a in $pending) { Save-JuicerActionState $a $Tweak.Id })
    } catch {
        return (New-JuicerResult $Tweak 'Error' "No se pudo guardar el estado actual: $_")
    }

    # Into the journal before touching anything, so that even a crash halfway
    # leaves a way back. Only the first capture of each setting is kept.
    $journal = Read-JuicerJournal
    $entry = Get-JuicerJournalEntry $journal $Tweak.Id
    if ($null -eq $entry) {
        $entry = @{
            Id = $Tweak.Id; Title = $Tweak.Title; Category = $Tweak.Category; Reboot = $Tweak.Reboot
            AppliedAt = (Get-Date).ToString('s'); Actions = (New-Object System.Collections.ArrayList)
        }
        [void]$journal.Add($entry)
    }
    $added = @()
    foreach ($c in $captures) {
        if (-not (@($entry.Actions) | Where-Object { $_.Id -eq $c.Id })) { [void]$entry.Actions.Add($c); $added += $c.Id }
    }
    Save-JuicerJournal $journal

    $i = 0
    try {
        for ($i = 0; $i -lt $pending.Count; $i++) { Invoke-JuicerAction $pending[$i] $captures[$i] }
    } catch {
        $err = "$_"
        $rollback = @()
        for ($j = [Math]::Min($i, $pending.Count - 1); $j -ge 0; $j--) {
            try { Restore-JuicerActionState $captures[$j] } catch { $rollback += "$_" }
        }
        $journal = Read-JuicerJournal
        $entry = Get-JuicerJournalEntry $journal $Tweak.Id
        if ($entry) {
            $keep = New-Object System.Collections.ArrayList
            foreach ($a in $entry.Actions) { if ($added -notcontains $a.Id) { [void]$keep.Add($a) } }
            $entry.Actions = $keep
            if ($keep.Count -eq 0) { $journal.Remove($entry) }
            Save-JuicerJournal $journal
        }
        $msg = $err
        if ($rollback.Count -gt 0) { $msg += ' — además, no se pudo deshacer del todo: ' + ($rollback -join '; ') }
        Write-JuicerLog "ERROR $($Tweak.Id): $msg"
        return (New-JuicerResult $Tweak 'Error' $msg)
    }

    $stuck = @($pending | Where-Object { -not (Test-JuicerAction $_) })
    if ($stuck.Count -gt 0) {
        $result.Outcome = 'NoSeMantuvo'
        $result.Message = 'Windows no conservó: ' + (($stuck | ForEach-Object { Format-JuicerAction $_ }) -join '; ')
    }
    Write-JuicerLog "$($result.Outcome) $($Tweak.Id): $($result.Changes -join '; ')"
    $result
}

function Undo-JuicerTweak {
    param([Parameter(Mandatory)][string]$Id)
    $journal = Read-JuicerJournal
    $entry = Get-JuicerJournalEntry $journal $Id
    $info = @{ Id = $Id; Title = $Id; Reboot = 'No' }
    if ($entry) { $info.Title = $entry.Title; if ($entry.Reboot) { $info.Reboot = $entry.Reboot } }
    if ($null -eq $entry) { return (New-JuicerResult $info 'NadaQueDeshacer' 'No hay cambios de Win Juicer guardados para este ajuste.') }

    $failed = New-Object System.Collections.ArrayList
    $errors = @()
    $acts = @($entry.Actions)
    for ($i = $acts.Count - 1; $i -ge 0; $i--) {
        try { Restore-JuicerActionState $acts[$i] } catch { [void]$failed.Insert(0, $acts[$i]); $errors += "$_" }
    }
    if ($failed.Count -eq 0) { $journal.Remove($entry) } else { $entry.Actions = $failed }
    Save-JuicerJournal $journal

    if ($errors.Count -gt 0) {
        Write-JuicerLog "ERROR deshacer ${Id}: $($errors -join '; ')"
        return (New-JuicerResult $info 'Error' ($errors -join '; '))
    }
    Write-JuicerLog "Deshecho $Id"
    New-JuicerResult $info 'Deshecho'
}

function Undo-JuicerAll {
    $journal = Read-JuicerJournal
    $ids = @($journal | ForEach-Object { $_.Id })
    [array]::Reverse($ids)
    foreach ($id in $ids) { Undo-JuicerTweak $id }
}

# --- Machine-level helpers -------------------------------------------------

function Test-JuicerAdmin {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return $false }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal $id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-JuicerWindowsBuild {
    $v = Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion' 'CurrentBuildNumber'
    if ($v) { return [int]$v.Value }
    [Environment]::OSVersion.Version.Build
}

# System Restore is the safety net for whatever the journal cannot see. Windows
# silently skips creating a point if another was made in the last 24 hours, so
# the result says what actually happened instead of assuming.
function New-JuicerRestorePoint {
    $before = $null
    try {
        $before = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction Stop | Sort-Object SequenceNumber)[-1]
    } catch {
        Write-Verbose "No se pudieron listar los puntos de restauración: $_"
    }
    try {
        $r = Invoke-CimMethod -Namespace root/default -ClassName SystemRestore -MethodName CreateRestorePoint -Arguments @{
            Description = 'Win Juicer'; RestorePointType = [uint32]12; EventType = [uint32]100
        } -ErrorAction Stop
    } catch {
        return @{ Ok = $false; Message = 'Restaurar sistema no está disponible o está desactivado en esta unidad.' }
    }
    if ($r.ReturnValue -ne 0) {
        return @{ Ok = $false; Message = "Windows no creó el punto de restauración (código $($r.ReturnValue)). ¿Está activada la protección del sistema en $env:SystemDrive?" }
    }
    $after = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore -ErrorAction SilentlyContinue | Sort-Object SequenceNumber)[-1]
    if ($after -and (-not $before -or $after.SequenceNumber -ne $before.SequenceNumber)) {
        return @{ Ok = $true; Message = 'Punto de restauración creado.' }
    }
    $when = ''
    if ($after) {
        $t = $after.CreationTime
        if ($t -isnot [datetime]) { $t = [Management.ManagementDateTimeConverter]::ToDateTime([string]$t) }
        $when = ' El más reciente es del ' + $t.ToString('g') + '.'
    }
    @{ Ok = $true; Message = "Windows no creó uno nuevo: sólo permite uno cada 24 horas.$when" }
}
