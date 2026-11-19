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
    $default = -not $h
    if ($default) { $h = Join-Path $env:ProgramData 'WinJuicer' }
    if (-not (Test-Path -LiteralPath $h)) { New-Item -ItemType Directory -Path $h -Force | Out-Null }
    # The journal, the metrics and the scripts the tool later runs as administrator live here, and
    # ProgramData lets any user create and change files: only the real folder is locked down, once.
    if ($default -and -not $script:HomeProtected -and (Test-JuicerWindows) -and (Test-JuicerAdmin)) {
        # Set first: the log below asks for the home again.
        $script:HomeProtected = $true
        Protect-JuicerHome $h
    }
    $h
}

# True when the folder's ACL is already what Protect-JuicerHome would set: no
# inheritance, owned by Administrators or SYSTEM, and nobody but them with a
# write permission (Users, Authenticated Users, Everyone). Setting the ACL on
# every start would rewrite security descriptors for no reason; it takes the
# ACL as a parameter so it can be tested without a Windows disk.
function Test-JuicerHomeAcl {
    param([Parameter(Mandatory)]$Acl)
    $sid = [Security.Principal.WellKnownSidType]
    $sidType = [Security.Principal.SecurityIdentifier]
    $admins = New-Object $sidType ($sid::BuiltinAdministratorsSid, $null)
    $system = New-Object $sidType ($sid::LocalSystemSid, $null)
    if (-not $Acl.AreAccessRulesProtected) { return $false }
    $owner = $Acl.GetOwner($sidType)
    if ($owner -ne $admins -and $owner -ne $system) { return $false }
    $rights = [Security.AccessControl.FileSystemRights]
    $write = $rights::Write -bor $rights::Delete -bor $rights::DeleteSubdirectoriesAndFiles -bor $rights::ChangePermissions -bor $rights::TakeOwnership
    $weak = @(
        (New-Object $sidType ($sid::BuiltinUsersSid, $null)),
        (New-Object $sidType ($sid::AuthenticatedUserSid, $null)),
        (New-Object $sidType ($sid::WorldSid, $null))
    )
    foreach ($rule in $Acl.GetAccessRules($true, $true, $sidType)) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
        if ($rule.IdentityReference -in $weak -and ($rule.FileSystemRights -band $write)) { return $false }
    }
    $true
}

# Administrators and SYSTEM full control, Users read-only, no inheritance from ProgramData.
# If the folder belongs to someone who is not an administrator, ownership is taken first: its
# owner could change the permissions back. Does nothing when the ACL is already right (this
# runs on every start). Never throws; a failure goes to the log.
function Protect-JuicerHome {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $sid = [Security.Principal.WellKnownSidType]
        $admins = New-Object Security.Principal.SecurityIdentifier ($sid::BuiltinAdministratorsSid, $null)
        $system = New-Object Security.Principal.SecurityIdentifier ($sid::LocalSystemSid, $null)
        $users = New-Object Security.Principal.SecurityIdentifier ($sid::BuiltinUsersSid, $null)
        $current = Get-Acl -LiteralPath $Path
        if (Test-JuicerHomeAcl $current) { return }
        $owner = $current.GetOwner([Security.Principal.SecurityIdentifier])
        if ($owner -ne $admins -and $owner -ne $system) {
            # icacls takes the group by SID, so it works in any Windows language
            # (takeown's /D answer is a localized letter); /T covers what is
            # already inside, /C keeps going past files it cannot change.
            [void](Invoke-JuicerNative 'icacls.exe' @($Path, '/setowner', '*S-1-5-32-544', '/T', '/C', '/Q'))
        }
        $rights = [Security.AccessControl.FileSystemRights]
        $inherit = [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
        $none = [Security.AccessControl.PropagationFlags]::None
        $allow = [Security.AccessControl.AccessControlType]::Allow
        $acl = New-Object Security.AccessControl.DirectorySecurity
        $acl.SetAccessRuleProtection($true, $false)
        $acl.SetOwner($admins)
        foreach ($full in $admins, $system) { $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ($full, $rights::FullControl, $inherit, $none, $allow))) }
        $acl.AddAccessRule((New-Object Security.AccessControl.FileSystemAccessRule ($users, $rights::ReadAndExecute, $inherit, $none, $allow)))
        Set-Acl -LiteralPath $Path -AclObject $acl -ErrorAction Stop
    } catch {
        Write-JuicerLog "No se pudieron fijar los permisos de $Path`: $_"
    }
}

function Get-JuicerJournalPath { Join-Path (Get-JuicerHome) 'diario.json' }

# One previous file is kept: past a megabyte the log becomes registro.1.log.
function Write-JuicerLog {
    param([string]$Message)
    try {
        $path = Join-Path (Get-JuicerHome) 'registro.log'
        if ((Test-Path -LiteralPath $path) -and (Get-Item -LiteralPath $path).Length -gt 1MB) {
            Move-Item -LiteralPath $path -Destination (Join-Path (Get-JuicerHome) 'registro.1.log') -Force
        }
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}{2}' -f (Get-Date), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($path, $line, (New-Object Text.UTF8Encoding $false))
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

# The previous good journal, kept by every save, and where a corrupt one is
# set aside when the copy is restored.
function Get-JuicerJournalBackupPath { Join-Path (Get-JuicerHome) 'diario.1.json' }
function Get-JuicerJournalAsidePath { Join-Path (Get-JuicerHome) 'diario.dañado.json' }

# Whether a file holds a journal that can be read. Never throws.
function Test-JuicerJournalFile {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        $d = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        return ($null -ne $d -and $null -ne $d.PSObject.Properties['Entries'])
    } catch {
        return $false
    }
}

function Read-JuicerJournal {
    $path = Get-JuicerJournalPath
    $list = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return , $list }
    try {
        $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    } catch {
        # The copy that every save leaves behind is the way out: say so, where it is, and how.
        $hint = if (Test-JuicerJournalFile (Get-JuicerJournalBackupPath)) { " Hay una copia del diario anterior (diario.1.json) y se puede restaurar. Ábrelo de nuevo: Win Juicer te ofrecerá recuperarlo (o usa Deshacer en el menú de la consola)." } else { '' }
        throw "El diario de cambios está dañado ($path). No lo borres: guarda el estado original de cada ajuste.$hint Error: $_"
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

# The journal for screens that must keep working when it is corrupt: an empty list, with the
# reason in $script:JournalReadError (null when it read fine). Never throws.
$script:JournalReadError = $null
function Read-JuicerJournalSafe {
    $script:JournalReadError = $null
    try {
        Read-JuicerJournal
    } catch {
        $script:JournalReadError = "$_"
        Write-JuicerLog "Diario ilegible: $_"
        , (New-Object System.Collections.ArrayList)
    }
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

# Write-then-swap: a power cut or a crash must never leave half a file.
# UTF-8 without BOM, the temp file next to the target so the swap is on one volume.
function Write-JuicerTextAtomic {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Text)
    $tmp = "$Path.tmp"
    try {
        [IO.File]::WriteAllText($tmp, $Text, (New-Object Text.UTF8Encoding $false))
        # ([NullString] because PowerShell hands .NET an empty string for $null.)
        if (Test-Path -LiteralPath $Path) { [IO.File]::Replace($tmp, $Path, [NullString]::Value) } else { [IO.File]::Move($tmp, $Path) }
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

# Before each save, the journal as it is now (if it reads fine) becomes diario.1.json, so
# a damaged file or a bad write always leaves one step back. A corrupt current file is
# never copied over the good backup.
function Save-JuicerJournal {
    param([Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IList]$Entries)
    $path = Get-JuicerJournalPath
    $text = ConvertTo-JuicerJson @{ Version = 1; Entries = $Entries }
    if (Test-JuicerJournalFile $path) {
        try {
            $current = [IO.File]::ReadAllText($path)
            if ($current -ne $text) { Write-JuicerTextAtomic (Get-JuicerJournalBackupPath) $current }
        } catch {
            Write-JuicerLog "No se pudo guardar la copia del diario: $_"
        }
    }
    Write-JuicerTextAtomic $path $text
}

# Puts diario.1.json back as the journal. The current file, if there is one, is moved
# aside as diario.dañado.json first (nothing is deleted). Ok is false, with the reason,
# when there is no usable copy.
function Restore-JuicerJournal {
    $backup = Get-JuicerJournalBackupPath
    if (-not (Test-JuicerJournalFile $backup)) {
        return @{ Ok = $false; Entries = 0; Message = 'No hay una copia utilizable del diario (diario.1.json).' }
    }
    $path = Get-JuicerJournalPath
    $aside = Get-JuicerJournalAsidePath
    try {
        $text = [IO.File]::ReadAllText($backup)
        if (Test-Path -LiteralPath $path) { Move-Item -LiteralPath $path -Destination $aside -Force -ErrorAction Stop }
        Write-JuicerTextAtomic $path $text
    } catch {
        Write-JuicerLog "No se pudo restaurar el diario: $_"
        return @{ Ok = $false; Entries = 0; Message = "No se pudo restaurar el diario: $_" }
    }
    # Not @(…): the journal comes back as one list, and @() would count it as one.
    $n = (Read-JuicerJournal).Count
    Write-JuicerLog "Diario restaurado desde diario.1.json ($n entradas); el anterior queda en diario.dañado.json."
    @{ Ok = $true; Entries = $n; Message = "Diario restaurado desde la copia anterior ($(Format-JuicerCount $n 'cambio guardado' 'cambios guardados')). El que estaba dañado queda aparte en $aside." }
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

# Static DNS servers of an interface, as Windows keeps them: a comma (older
# builds: space) separated list in NameServer, empty when they come from DHCP.
function Get-JuicerDnsServers {
    param([Parameter(Mandatory)][string]$Interface)
    $out = @{}
    foreach ($family in @(@('V4', 'Tcpip'), @('V6', 'Tcpip6'))) {
        $v = Read-JuicerReg "HKLM\SYSTEM\CurrentControlSet\Services\$($family[1])\Parameters\Interfaces\$Interface" 'NameServer'
        $out[$family[0]] = [string[]]@((Get-JuicerRegString $v) -split '[,\s]+' | Where-Object { $_ })
    }
    $out
}

function Test-JuicerListEqual {
    param($A, $B)
    $x = @($A | Where-Object { $_ })
    $y = @($B | Where-Object { $_ })
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) { if ([string]$x[$i] -ne [string]$y[$i]) { return $false } }
    $true
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
        'Appx' { return ('Appx|{0}' -f $Action.Name).ToLowerInvariant() }
        'Dns' { return ('Dns|{0}' -f $Action.Interface).ToLowerInvariant() }
        'Feature' { return ('Feat|{0}' -f $Action.Name).ToLowerInvariant() }
        'FpsLimit' { return ('Fps|{0}' -f $Action.Exe).ToLowerInvariant() }
        'NvSetting' { return ('Nv|{0}|{1:X8}' -f $Action.Exe, [uint32]$Action.Id).ToLowerInvariant() }
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
        'Appx' { return "Quitar la app $($Action.Name)" }
        'Dns' {
            $all = @(@($Action.V4) + @($Action.V6) | Where-Object { $_ })
            $what = if ($all.Count -eq 0) { 'automático (DHCP)' } else { $all -join ', ' }
            return "DNS de $($Action.Adapter): $what"
        }
        'Feature' { return 'Característica de Windows {0}: {1}' -f $Action.Name, $(if ($Action.Enabled) { 'activada' } else { 'desactivada' }) }
        'FpsLimit' {
            $by = @{ nvidia = 'driver de NVIDIA'; rtss = 'RivaTuner' }[[string](& (Get-JuicerBackend).FpsBackend)]
            $fps = if ($Action.Exact -gt 0 -and $by -eq 'RivaTuner') { $Action.Exact } else { $Action.Fps }
            return 'Frame pacer de {0}: {1} FPS ({2:N3} ms por fotograma){3}' -f $Action.Exe, $fps, (1000 / [Math]::Max(1, $fps)), $(if ($by) { ", $by" } else { '' })
        }
        'NvSetting' { return '{0}, perfil de NVIDIA de {1}' -f $Action.Label, $Action.Exe }
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
        'Appx' { return ($null -eq (& $b.AppxRead $Action.Name)) }
        'Dns' {
            $cur = Get-JuicerDnsServers $Action.Interface
            return ((Test-JuicerListEqual $cur.V4 $Action.V4) -and (Test-JuicerListEqual $cur.V6 $Action.V6))
        }
        'Feature' {
            $f = & $b.FeatRead $Action.Name
            if ($null -eq $f) { return $true }
            return ([bool]$f.Enabled -eq [bool]$Action.Enabled)
        }
        'FpsLimit' {
            $f = & $b.FpsRead $Action.Exe
            if ($null -eq $f) { return $true }
            if ($f.Backend -eq 'rtss' -and $Action.Exact -gt 0) { return ([Math]::Abs([double]$f.Exact - [double]$Action.Exact) -lt 0.005) }
            return ([int]$f.Fps -eq [int]$Action.Fps)
        }
        'NvSetting' {
            # Without an NVIDIA driver there is nothing to set: done.
            $f = & $b.NvRead $Action.Exe $Action.Id
            if ($null -eq $f) { return $true }
            return ($null -ne $f.Value -and [uint32]$f.Value -eq [uint32]$Action.Value)
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
        'Appx' {
            $a = & $b.AppxRead $Action.Name
            $c.Name = $Action.Name; $c.StoreId = [string]$Action.StoreId; $c.Exists = ($null -ne $a)
            if ($a) { $c.Installed = [bool]$a.Installed; $c.Provisioned = [bool]$a.Provisioned }
        }
        'Dns' {
            $cur = Get-JuicerDnsServers $Action.Interface
            $c.Interface = $Action.Interface; $c.Adapter = $Action.Adapter
            $c.V4 = $cur.V4; $c.V6 = $cur.V6
        }
        'Feature' {
            $f = & $b.FeatRead $Action.Name
            $c.Name = $Action.Name; $c.Exists = ($null -ne $f)
            if ($f) { $c.Enabled = [bool]$f.Enabled }
        }
        'FpsLimit' {
            $f = & $b.FpsRead $Action.Exe
            if ($null -eq $f) { throw 'No hay con qué aplicar el frame pacer en este equipo.' }
            $c.Exe = $Action.Exe; $c.Backend = $f.Backend; $c.Old = $f.Fps; $c.OldExact = [double]$f.Exact; $c.Existed = [bool]$f.Existed
        }
        'NvSetting' {
            $f = & $b.NvRead $Action.Exe $Action.Id
            $c.Exe = $Action.Exe; $c.SettingId = [uint32]$Action.Id; $c.Old = $(if ($f) { $f.Value } else { $null })
        }
        'Custom' {
            $c.TweakId = $TweakId; $c.CustomKey = $Action.Key
            $c.State = & $Action.Capture
        }
    }
    $c
}

# Whether a program with this .exe name is open now (false when the backend
# cannot tell).
function Test-JuicerGameRunning {
    param([string]$Exe)
    $b = Get-JuicerBackend
    if (-not $Exe -or -not $b.ProcRunning) { return $false }
    try { [bool](& $b.ProcRunning $Exe) } catch { Write-JuicerLog "No se pudo ver si $Exe está abierto: $_"; $false }
}

# The last line of defence: a game's frame pacer or driver profile is never
# written while that game runs. The driver hands a running game the new
# values at once, and changing its sync or its frame queue under it can
# freeze it or crash it. The frame pacer waits for the game to close (see
# Add-JuicerPacerPending); anything else that gets here stops with a reason.
function Assert-JuicerGameClosed {
    param($Action)
    if ($Action.Type -notin 'FpsLimit', 'NvSetting') { return }
    if (Test-JuicerGameRunning $Action.Exe) {
        throw "$($Action.Exe) está abierto: Win Juicer no toca el perfil de un juego en marcha, porque podría congelarlo. Ciérralo y vuelve a intentarlo."
    }
}

function Invoke-JuicerAction {
    param([Parameter(Mandatory)]$Action, [Parameter(Mandatory)]$Capture)
    $b = Get-JuicerBackend
    Assert-JuicerGameClosed $Action
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
        'Appx' { if ($Capture.Exists) { & $b.AppxRemove $Action.Name } }
        'Dns' {
            # With the content protection on, the DNS is its: nothing else changes it.
            if (Test-JuicerShield) { throw 'La protección contra contenido adulto fija el DNS de este equipo: no se puede cambiar.' }
            & $b.DnsSet $Action.Interface ([string[]]@($Action.V4)) ([string[]]@($Action.V6))
        }
        'Feature' { if ($Capture.Exists) { & $b.FeatSet $Action.Name ([bool]$Action.Enabled) } }
        'FpsLimit' {
            if ($Capture.Backend -eq 'nvidia') { Backup-JuicerNvProfilesOnce }
            & $b.FpsWrite $Action.Exe $Action.Fps $Capture.Backend -Exact ([double]$Action.Exact)
        }
        'NvSetting' { Backup-JuicerNvProfilesOnce; & $b.NvWrite $Action.Exe $Action.Id $Action.Value }
        'Custom' { & $Action.Apply $Capture.State }
    }
}

function Restore-JuicerActionState {
    param([Parameter(Mandatory)]$Capture)
    $b = Get-JuicerBackend
    $c = $Capture
    Assert-JuicerGameClosed $c
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
        'Appx' { if ($c.Exists -and $null -eq (& $b.AppxRead $c.Name)) { & $b.AppxAdd $c.Name $c.StoreId } }
        'Dns' {
            # Undoing an old DNS change does not undo the content protection's.
            if (Test-JuicerShield) { Write-JuicerLog "DNS de $($c.Adapter) sin tocar: lo fija la protección contra contenido adulto"; return }
            & $b.DnsSet $c.Interface ([string[]]@($c.V4 | Where-Object { $_ })) ([string[]]@($c.V6 | Where-Object { $_ }))
        }
        'Feature' {
            if (-not $c.Exists) { return }
            $f = & $b.FeatRead $c.Name
            if ($f -and [bool]$f.Enabled -ne [bool]$c.Enabled) { & $b.FeatSet $c.Name ([bool]$c.Enabled) }
        }
        'FpsLimit' {
            if ($c.Existed) { & $b.FpsWrite $c.Exe $c.Old $c.Backend -Exact ([double]$c.OldExact) } else { & $b.FpsWrite $c.Exe $null $c.Backend -Remove }
        }
        'NvSetting' { & $b.NvWrite $c.Exe $c.SettingId $c.Old }
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

# What Windows (a feature update, a driver installer, another tool) has undone since Win
# Juicer applied it: journaled tweaks whose live state is no longer in place. Left out on
# purpose: what the engine skips (NoAplica, a state it could not read) and a game's
# profile while the game runs, which is not touched then and would only look like drift.
# Returns @{ Id; Title; Tweak; State; Level; Pending } per tweak, in journal order (wrap the
# call in @(): none gives nothing).
function Get-JuicerDrift {
    # States: what Get-JuicerTweakState already gave for each tweak id (the window reads them
    # all anyway); only the ones missing from it are read again.
    param([System.Collections.IList]$Journal, [hashtable]$States)
    if ($null -eq $Journal) { $Journal = Read-JuicerJournal }
    $out = @()
    $onBattery = $null
    foreach ($e in $Journal) {
        $t = Resolve-JuicerJournalTweak ([string]$e.Id)
        if (-not $t) { continue }
        $s = if ($States -and $States.ContainsKey([string]$e.Id)) { $States[[string]$e.Id] } else { Get-JuicerTweakState $t $Journal }
        if ($s.State -notin 'Pendiente', 'Parcial') { continue }
        $open = @($s.Pending | Where-Object { $_.Type -in 'FpsLimit', 'NvSetting' -and (Test-JuicerGameRunning ([string]$_.Exe)) })
        if ($open.Count -gt 0) { continue }
        # The power mode overlay is stored per power source: the battery one reads as undone
        # while the charger one is what Win Juicer set. Not drift on a laptop unplugged.
        $pend = @($s.Pending)
        if ($pend.Count -gt 0 -and @($pend | Where-Object { $_.Type -eq 'Custom' -and $_.Key -eq 'overlay' }).Count -eq $pend.Count) {
            if ($null -eq $onBattery) { $onBattery = Test-JuicerOnBattery }
            if ($onBattery) { continue }
        }
        $out += @{ Id = [string]$e.Id; Title = [string]$t.Title; Tweak = $t; State = $s.State; Level = [int]$t.Level; Pending = @($s.Pending) }
    }
    # A game's frame pacer is not in the catalog, so the loop above never sees it.
    # What a clean driver install wipes is its cap: journaled, with nothing live.
    # Kind 'Fps' marks them: they go back through the limiter, not the catalog.
    try {
        foreach ($w in @(Get-JuicerWipedFpsLimits $Journal)) {
            if (@($out | Where-Object { $_.Id -eq $w.Id }).Count -gt 0) { continue }
            # An open game is not touched (its cap waits for it to close).
            if (Test-JuicerGameRunning $w.Exe) { continue }
            $out += @{ Id = [string]$w.Id; Title = "Frame pacer de $($w.Exe)"; Tweak = $null; Kind = 'Fps'; Exe = [string]$w.Exe; State = 'Pendiente'; Level = 1; Pending = @() }
        }
    } catch {
        Write-JuicerLog "No se pudo revisar si el driver borró algún límite de FPS: $_"
    }
    $out
}

# The words for a list of drifted tweaks (screens and CLI): a title with the count and one
# line per tweak, at most Max of them.
function Format-JuicerDriftSummary {
    param([object[]]$Drift, [int]$Max = 8)
    $all = @($Drift | Where-Object { $_ })
    if ($all.Count -eq 0) { return @{ Title = ''; Lines = @() } }
    # Frame pacer caps the driver wiped are told apart: it was the driver, not Windows, and one line is enough.
    $fps = @($all | Where-Object { $_.Kind -eq 'Fps' })
    $d = @($all | Where-Object { $_.Kind -ne 'Fps' })
    $fpsText = 'El driver borró el límite de {0}' -f $(if ($fps.Count -eq 1) { '1 juego' } else { "$($fps.Count) juegos" })
    if ($d.Count -eq 0) {
        $fpsLines = @($fps | Select-Object -First $Max | ForEach-Object { '· ' + $(if ($_.Exe) { $_.Exe } else { $_.Title }) })
        if ($fps.Count -gt $Max) { $fpsLines += "· y $($fps.Count - $Max) más" }
        return @{ Title = $fpsText; Lines = $fpsLines }
    }
    $title = if ($d.Count -eq 1) { 'Windows ha deshecho 1 cambio tuyo' } else { "Windows ha deshecho $($d.Count) cambios tuyos" }
    $lines = @($d | Select-Object -First $Max | ForEach-Object { '· ' + $_.Title + $(if ($_.State -eq 'Parcial') { ' (en parte)' } else { '' }) })
    if ($d.Count -gt $Max) { $lines += "· y $($d.Count - $Max) más" }
    if ($fps.Count -gt 0) { $lines += '· ' + $fpsText.Substring(0, 1).ToLowerInvariant() + $fpsText.Substring(1) + ': ' + (($fps | Select-Object -First 5 | ForEach-Object { $_.Exe }) -join ', ') }
    @{ Title = $title; Lines = $lines }
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
    # Checked before anything is written, so that nothing half-applied needs undoing.
    $open = @($pending | Where-Object { $_.Type -in 'FpsLimit', 'NvSetting' } | ForEach-Object { [string]$_.Exe } | Select-Object -Unique | Where-Object { Test-JuicerGameRunning $_ })
    if ($open.Count -gt 0) {
        return (New-JuicerResult $Tweak 'Error' "$($open -join ', ') está abierto: Win Juicer no toca el perfil de un juego en marcha, porque podría congelarlo. Ciérralo y vuelve a intentarlo.")
    }
    # The «before» of Antes y después, the first time anything changes.
    if ((Get-JuicerBackend).Name -eq 'Windows') { Save-JuicerBaseline }

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
    } else {
        # One id can take different values (the DNS provider): the title says
        # the latest, the captures keep the original.
        $entry.Title = $Tweak.Title
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
    if ($result.Outcome -eq 'Aplicado') {
        # AppliedAt is the first time (it never moves); what a restart check needs is the
        # last time the setting changed, which is what LastAppliedAt keeps.
        try {
            $journal = Read-JuicerJournal
            $entry = Get-JuicerJournalEntry $journal $Tweak.Id
            if ($entry) { $entry.LastAppliedAt = (Get-Date).ToString('s'); Save-JuicerJournal $journal }
        } catch { Write-JuicerLog "No se pudo anotar la fecha de $($Tweak.Id): $_" }
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

# One setting of a tweak back to how it was, and out of its journal entry
# (the entry goes when it was the last). False when there was none.
function Undo-JuicerCapture {
    param([Parameter(Mandatory)][string]$TweakId, [Parameter(Mandatory)][string]$CaptureId)
    $journal = Read-JuicerJournal
    $entry = Get-JuicerJournalEntry $journal $TweakId
    if ($null -eq $entry) { return $false }
    $c = @($entry.Actions | Where-Object { $_.Id -eq $CaptureId }) | Select-Object -First 1
    if ($null -eq $c) { return $false }
    Restore-JuicerActionState $c
    $keep = New-Object System.Collections.ArrayList
    foreach ($a in $entry.Actions) { if ($a.Id -ne $CaptureId) { [void]$keep.Add($a) } }
    $entry.Actions = $keep
    if ($keep.Count -eq 0) { $journal.Remove($entry) }
    Save-JuicerJournal $journal
    Write-JuicerLog "Devuelto $CaptureId de $TweakId"
    $true
}

# When a tweak's recipe changes (a setting no longer part of it), what Win
# Juicer set for the old recipe goes back to how it was, and out of the
# journal: re-applying alone would leave it in place. Returns what was
# restored.
function Remove-JuicerStaleCaptures {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    $journal = Read-JuicerJournal
    $entry = Get-JuicerJournalEntry $journal $Tweak.Id
    if ($null -eq $entry) { return @() }
    $want = @(foreach ($a in (Resolve-JuicerActions $Tweak)) { Get-JuicerActionId $a $Tweak.Id })
    $keep = New-Object System.Collections.ArrayList
    $gone = @()
    foreach ($c in @($entry.Actions)) {
        if ($want -contains $c.Id) { [void]$keep.Add($c); continue }
        try {
            Restore-JuicerActionState $c
            $gone += $c.Id
        } catch {
            Write-JuicerLog "No se pudo devolver $($c.Id) de $($Tweak.Id): $_"
            [void]$keep.Add($c)
        }
    }
    if ($gone.Count -eq 0) { return @() }
    $entry.Actions = $keep
    if ($keep.Count -eq 0) { $journal.Remove($entry) }
    Save-JuicerJournal $journal
    Write-JuicerLog "Devuelto de $($Tweak.Id), que ya no lo usa: $($gone -join ', ')"
    $gone
}

function Undo-JuicerAll {
    $journal = Read-JuicerJournal
    $ids = @($journal | ForEach-Object { $_.Id })
    [array]::Reverse($ids)
    foreach ($id in $ids) { Undo-JuicerTweak $id }
}

# --- What a confirmation shows before doing it -----------------------------------
#
# The first few titles, then «y N más»; those that only take effect after a restart or a new
# sign-in are marked, and said once at the end. Pure text, shared by the window and the console.

function Format-JuicerPreviewLines {
    param([object[]]$Items, [int]$Max = 8)
    $items = @($Items | Where-Object { $_ })
    $lines = @(foreach ($i in ($items | Select-Object -First $Max)) {
            $mark = switch ([string]$i.Reboot) { 'Reinicio' { ' (hay que reiniciar)' } 'Sesion' { ' (hay que volver a entrar)' } default { '' } }
            "· $($i.Title)$mark"
        })
    if ($items.Count -gt $Max) { $lines += "y $($items.Count - $Max) más" }
    $needs = @($items | Where-Object { [string]$_.Reboot -in 'Reinicio', 'Sesion' })
    $note = ''
    if ($needs.Count -gt 0) { $note = 'Los marcados no surten efecto hasta que reinicies Windows o vuelvas a iniciar sesión, como dice cada uno.' }
    @{ Lines = $lines; Note = $note }
}

# Text of the question before applying these tweaks (the «Optimizar Windows» button).
function Format-JuicerApplyConfirm {
    param([object[]]$Tweaks, [switch]$NoQuestion)
    $t = @($Tweaks | Where-Object { $_ })
    $p = Format-JuicerPreviewLines $t
    $head = if ($t.Count -eq 1) { 'Se aplicará 1 ajuste que conviene a tu equipo:' } else { "Se aplicarán $($t.Count) ajustes que convienen a tu equipo:" }
    $out = "$head`n`n" + ($p.Lines -join "`n")
    if ($p.Note) { $out += "`n`n$($p.Note)" }
    $out + "`n`nAntes se crea un punto de restauración de Windows, y cada cambio se puede deshacer desde Win Juicer (Deshacer).$(if (-not $NoQuestion) { "`n`n¿Seguir?" })"
}

# What «Deshacer todo» will and will not do, from what the journal really holds: each entry
# is put back as it was before Win Juicer first touched it (Undo-JuicerAll), most recent first.
function Format-JuicerUndoAllConfirm {
    param([object[]]$Journal, [switch]$NoQuestion)
    $j = @($Journal | Where-Object { $_ })
    $undo = @($j)
    [array]::Reverse($undo)
    $p = Format-JuicerPreviewLines $undo
    $head = if ($j.Count -eq 1) { 'Se deshará este cambio de Win Juicer:' } else { "Se deshacerán estos $($j.Count) cambios de Win Juicer, el más reciente primero:" }
    $out = "$head`n`n" + ($p.Lines -join "`n")
    if ($p.Note) { $out += "`n`n$($p.Note)" }
    $apps = @($j | Where-Object { [string]$_.Id -like 'app:*' })
    if ($apps.Count -gt 0) { $out += "`n`nLas apps quitadas se reinstalan desde Microsoft Store con winget (hace falta internet); si alguna no tiene identificador en la Tienda, tendrás que reinstalarla tú." }
    $out + "`n`nLo que Win Juicer no puede deshacer se queda como está: la protección contra contenido adulto (es para siempre), la limpieza y el resto de Mantenimiento (temporales borrados, restablecer la red o Windows Update) y los programas que instalaste con winget. Los puntos de restauración tampoco se borran.$(if (-not $NoQuestion) { "`n`n¿Seguir?" })"
}

# --- Toggles -----------------------------------------------------------------
#
# Preferences (dark theme, file extensions…) go both ways, and the way back
# is not always «as it was»: someone who already had dark mode and wants it
# off needs the opposite values written. Each toggle carries those in Off; the
# inverse tweak is «<id>!» and journals like any other.

function Get-JuicerInverseTweak {
    param([Parameter(Mandatory)][hashtable]$Tweak)
    if (-not $Tweak.Off) { throw "$($Tweak.Id) no se puede invertir." }
    @{
        Id = "$($Tweak.Id)!"; Title = "$($Tweak.Title): no"; Category = $Tweak.Category; Level = 0
        Impact = $Tweak.Impact; Reboot = $Tweak.Reboot; What = $Tweak.What; Gain = $Tweak.Gain; Cost = $Tweak.Cost
        Actions = $Tweak.Off
    }
}

# Like a startup entry: turning a toggle back undoes Win Juicer's own change
# first, so the journal only ever holds what differs from the original.
function Set-JuicerToggle {
    param([Parameter(Mandatory)][hashtable]$Tweak, [Parameter(Mandatory)][bool]$On)
    $target = if ($On) { $Tweak } else { Get-JuicerInverseTweak $Tweak }
    $opposite = if ($On) { "$($Tweak.Id)!" } else { $Tweak.Id }
    $results = @()
    if (Get-JuicerJournalEntry (Read-JuicerJournal) $opposite) { $results += Undo-JuicerTweak $opposite }
    $r = Invoke-JuicerTweak $target
    if ($r.Outcome -ne 'YaEstaba' -or $results.Count -eq 0) { $results += $r }
    $results
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
