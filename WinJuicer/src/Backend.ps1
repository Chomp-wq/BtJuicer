# Everything that reads or changes the machine goes through a backend: a
# hashtable of scriptblocks. The real one talks to the registry, the service
# manager and native tools; the in-memory one lets the engine be exercised on
# any OS. Nothing outside this file touches the registry directly.

$script:Backend = $null

function Use-JuicerBackend {
    param([Parameter(Mandatory)][hashtable]$Backend)
    $script:Backend = $Backend
}

function Get-JuicerBackend {
    if ($null -eq $script:Backend) { $script:Backend = New-JuicerWindowsBackend }
    $script:Backend
}

# --- Value normalisation ---------------------------------------------------
#
# Registry values are carried around as @{ Kind = '<RegistryValueKind>'; Value }
# with Value in a canonical type, so the same value compares equal whether it
# came from the registry, the catalog or a JSON round trip. DWORDs are the
# reason this exists: PowerShell reads 0xFFFFFFFF as -1, .NET returns REG_DWORD
# as Int32 and JSON brings numbers back as Int64.

$script:RegKinds = @('String', 'ExpandString', 'MultiString', 'DWord', 'QWord', 'Binary', 'None')

function ConvertTo-JuicerRegValue {
    param([Parameter(Mandatory)][string]$Kind, $Value)
    if ($script:RegKinds -notcontains $Kind) { throw "Tipo de valor de registro no admitido: $Kind" }
    switch ($Kind) {
        'DWord' {
            $n = [int64]$Value
            if ($n -lt 0) { $n += 4294967296 }
            if ($n -lt 0 -or $n -gt 4294967295) { throw "Valor DWORD fuera de rango: $Value" }
            return [uint32]$n
        }
        'QWord' {
            if ($Value -is [uint64]) { return $Value }
            $n = [int64]$Value
            if ($n -lt 0) { return [BitConverter]::ToUInt64([BitConverter]::GetBytes($n), 0) }
            return [uint64]$n
        }
        'MultiString' { return , ([string[]]@($Value | ForEach-Object { [string]$_ })) }
        { $_ -in 'Binary', 'None' } {
            if ($null -eq $Value) { return , ([byte[]]@()) }
            if ($Value -is [string]) { return , ([Convert]::FromBase64String($Value)) }
            return , ([byte[]]@($Value | ForEach-Object { [byte]$_ }))
        }
        default { return [string]$Value }
    }
}

# What .NET's RegistryKey.SetValue wants for each kind.
function ConvertTo-JuicerNativeRegValue {
    param([Parameter(Mandatory)][string]$Kind, $Value)
    $v = ConvertTo-JuicerRegValue $Kind $Value
    switch ($Kind) {
        'DWord' { return [BitConverter]::ToInt32([BitConverter]::GetBytes([uint32]$v), 0) }
        'QWord' { return [BitConverter]::ToInt64([BitConverter]::GetBytes([uint64]$v), 0) }
        default { return , $v }
    }
}

function Test-JuicerRegValueEqual {
    param($A, $B)
    if ($null -eq $A -or $null -eq $B) { return ($null -eq $A -and $null -eq $B) }
    if ($A.Kind -ne $B.Kind) { return $false }
    $x = ConvertTo-JuicerRegValue $A.Kind $A.Value
    $y = ConvertTo-JuicerRegValue $B.Kind $B.Value
    if ($A.Kind -in 'MultiString', 'Binary', 'None') {
        if ($x.Count -ne $y.Count) { return $false }
        for ($i = 0; $i -lt $x.Count; $i++) { if ($x[$i] -cne $y[$i]) { return $false } }
        return $true
    }
    return ($x -ceq $y)
}

# JSON-safe form of a value, for the journal.
function ConvertTo-JuicerStoredRegValue {
    param($Reg)
    if ($null -eq $Reg) { return $null }
    $v = ConvertTo-JuicerRegValue $Reg.Kind $Reg.Value
    if ($Reg.Kind -in 'Binary', 'None') { $v = [Convert]::ToBase64String($v) }
    @{ Kind = $Reg.Kind; Value = $v }
}

# --- Paths -----------------------------------------------------------------

function Split-JuicerRegPath {
    param([Parameter(Mandatory)][string]$Path)
    $i = $Path.IndexOf('\')
    if ($i -lt 0) { $root = $Path; $sub = '' } else { $root = $Path.Substring(0, $i); $sub = $Path.Substring($i + 1).TrimEnd('\') }
    if (@('HKLM', 'HKCU', 'HKU', 'HKCR') -notcontains $root.ToUpperInvariant()) {
        throw "Ruta de registro no válida: $Path"
    }
    [pscustomobject]@{ Root = $root.ToUpperInvariant(); SubKey = $sub }
}

function Get-JuicerRegParent {
    param([Parameter(Mandatory)][string]$Path)
    $i = $Path.TrimEnd('\').LastIndexOf('\')
    if ($i -lt 0) { return $null }
    $Path.Substring(0, $i)
}

# --- Real backend ----------------------------------------------------------

function Open-WinRegKey {
    param([string]$Path, [switch]$Writable, [switch]$Create)
    $p = Split-JuicerRegPath $Path
    $hive = switch ($p.Root) {
        'HKLM' { [Microsoft.Win32.RegistryHive]::LocalMachine }
        'HKCU' { [Microsoft.Win32.RegistryHive]::CurrentUser }
        'HKU' { [Microsoft.Win32.RegistryHive]::Users }
        'HKCR' { [Microsoft.Win32.RegistryHive]::ClassesRoot }
    }
    # Always the 64-bit view, even from a 32-bit host, or HKLM\SOFTWARE writes
    # would land silently in WOW6432Node.
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
    if ($p.SubKey -eq '') { return $base }
    try {
        if ($Create) { return $base.CreateSubKey($p.SubKey) }
        return $base.OpenSubKey($p.SubKey, [bool]$Writable)
    } finally {
        $base.Dispose()
    }
}

function Read-WinRegValue {
    param([string]$Path, [string]$Name)
    $k = Open-WinRegKey $Path
    if ($null -eq $k) { return $null }
    try {
        if (-not ($k.GetValueNames() -contains $Name)) { return $null }
        $kind = $k.GetValueKind($Name).ToString()
        if ($kind -eq 'Unknown') { $kind = 'None' }
        $raw = $k.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        @{ Kind = $kind; Value = (ConvertTo-JuicerRegValue $kind $raw) }
    } finally {
        $k.Dispose()
    }
}

function Write-WinRegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    $k = Open-WinRegKey $Path -Create
    try {
        $k.SetValue($Name, (ConvertTo-JuicerNativeRegValue $Kind $Value), [Microsoft.Win32.RegistryValueKind]$Kind)
    } finally {
        $k.Dispose()
    }
}

function Remove-WinRegValue {
    param([string]$Path, [string]$Name)
    $k = Open-WinRegKey $Path -Writable
    if ($null -eq $k) { return }
    try { $k.DeleteValue($Name, $false) } finally { $k.Dispose() }
}

function Test-WinRegKey {
    param([string]$Path)
    $k = Open-WinRegKey $Path
    if ($null -eq $k) { return $false }
    $k.Dispose()
    $true
}

function New-WinRegKey {
    param([string]$Path)
    (Open-WinRegKey $Path -Create).Dispose()
}

function Get-WinRegChildren {
    param([string]$Path)
    $k = Open-WinRegKey $Path
    if ($null -eq $k) { return , @() }
    try { return , ([string[]]$k.GetSubKeyNames()) } finally { $k.Dispose() }
}

function Get-WinRegValueNames {
    param([string]$Path)
    $k = Open-WinRegKey $Path
    if ($null -eq $k) { return , @() }
    try { return , ([string[]]$k.GetValueNames()) } finally { $k.Dispose() }
}

# Deletes a key only when it holds nothing, so restoring never takes along
# values someone else put there afterwards.
function Remove-WinRegKeyIfEmpty {
    param([string]$Path)
    $k = Open-WinRegKey $Path
    if ($null -eq $k) { return $true }
    try {
        if ($k.ValueCount -gt 0 -or $k.SubKeyCount -gt 0) { return $false }
    } finally {
        $k.Dispose()
    }
    $parent = Get-JuicerRegParent $Path
    $leaf = $Path.Substring($parent.Length + 1)
    $pk = Open-WinRegKey $parent -Writable
    try { $pk.DeleteSubKey($leaf, $false) } finally { $pk.Dispose() }
    $true
}

$script:StartNames = @{ 0 = 'Boot'; 1 = 'System'; 2 = 'Automatic'; 3 = 'Manual'; 4 = 'Disabled' }
$script:ScStart = @{ Disabled = 'disabled'; Manual = 'demand'; Automatic = 'auto'; AutomaticDelayed = 'delayed-auto' }

function Read-WinService {
    param([string]$Name)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $svc) { return $null }
    # The registry is the only place PowerShell 5.1 can see delayed start.
    $key = "HKLM\SYSTEM\CurrentControlSet\Services\$Name"
    $start = Read-WinRegValue $key 'Start'
    $delayed = Read-WinRegValue $key 'DelayedAutostart'
    $type = if ($start) { $script:StartNames[[int]$start.Value] } else { 'Manual' }
    if ($type -eq 'Automatic' -and $delayed -and $delayed.Value -eq 1) { $type = 'AutomaticDelayed' }
    @{ Start = $type; Running = ($svc.Status -eq 'Running') }
}

function Set-WinServiceStart {
    param([string]$Name, [string]$Start)
    if (-not $script:ScStart.ContainsKey($Start)) { throw "Tipo de inicio no admitido: $Start" }
    $r = Invoke-WinNative 'sc.exe' @('config', $Name, 'start=', $script:ScStart[$Start])
    if ($r.Code -ne 0) { throw "sc.exe no pudo cambiar $Name ($($r.Code)): $($r.Output)" }
}

function Stop-WinService {
    param([string]$Name)
    Stop-Service -Name $Name -Force -ErrorAction Stop -WarningAction SilentlyContinue
}

function Start-WinService {
    param([string]$Name)
    Start-Service -Name $Name -ErrorAction Stop -WarningAction SilentlyContinue
}

function Invoke-WinNative {
    param([string]$File, [string[]]$Arguments = @())
    # Windows PowerShell turns native stderr into terminating errors under
    # 'Stop'; tools like bcdedit write warnings there.
    $ErrorActionPreference = 'Continue'
    # stderr lines arrive as ErrorRecords; an empty one would print as its type
    # name, so take the message and drop the blanks.
    $out = & $File @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
    } | Where-Object { $_ -match '\S' }
    [pscustomobject]@{ Code = $LASTEXITCODE; Output = (@($out) -join "`n") }
}

function Get-WinDefenderExclusions {
    $p = Get-MpPreference -ErrorAction Stop
    , ([string[]]@($p.ExclusionPath | Where-Object { $_ }))
}

function Read-WinTask {
    param([string]$Path, [string]$Name)
    $t = Get-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction SilentlyContinue
    if ($null -eq $t) { return $null }
    @{ Enabled = ($t.State -ne 'Disabled') }
}

function Set-WinTask {
    param([string]$Path, [string]$Name, [bool]$Enabled)
    if ($Enabled) {
        Enable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    } else {
        Disable-ScheduledTask -TaskPath $Path -TaskName $Name -ErrorAction Stop | Out-Null
    }
}

function New-JuicerWindowsBackend {
    @{
        Name         = 'Windows'
        RegRead      = ${function:Read-WinRegValue}
        RegWrite     = ${function:Write-WinRegValue}
        RegDelete    = ${function:Remove-WinRegValue}
        KeyExists    = ${function:Test-WinRegKey}
        KeyCreate    = ${function:New-WinRegKey}
        KeyChildren  = ${function:Get-WinRegChildren}
        KeyValues    = ${function:Get-WinRegValueNames}
        KeyDelete    = ${function:Remove-WinRegKeyIfEmpty}
        SvcRead      = ${function:Read-WinService}
        SvcWrite     = ${function:Set-WinServiceStart}
        SvcStop      = ${function:Stop-WinService}
        SvcStart     = ${function:Start-WinService}
        Run          = ${function:Invoke-WinNative}
        SpiGet       = { param([uint32]$Action) Initialize-JuicerNative; [WinJuicer.Native]::SpiGetBool($Action) }
        SpiSet       = { param([uint32]$Action, [bool]$Value) Initialize-JuicerNative; [WinJuicer.Native]::SpiSetBool($Action, $Value) }
        DefList      = ${function:Get-WinDefenderExclusions}
        DefAdd       = { param([string]$Path) Add-MpPreference -ExclusionPath $Path -ErrorAction Stop }
        DefRemove    = { param([string]$Path) Remove-MpPreference -ExclusionPath $Path -ErrorAction Stop }
        TaskRead     = ${function:Read-WinTask}
        TaskWrite    = ${function:Set-WinTask}
    }
}

# --- In-memory backend -----------------------------------------------------
#
# Behaves like the registry where the engine can tell the difference: keys are
# case-insensitive, writing a value creates its key and every missing parent,
# and a key can only be deleted when empty. One at a time: creating a new one
# replaces the state of the previous.

$script:Mem = $null

function New-JuicerMemoryBackend {
    param([scriptblock]$Run)
    if (-not $Run) { $Run = { [pscustomobject]@{ Code = 0; Output = '' } } }
    $script:Mem = @{
        Keys     = @{}   # lower-case path -> @{ Path; Values = @{ lower name -> @{ Name; Kind; Value } } }
        Services = @{}   # name -> @{ Start; Running }
        Spi      = @{}   # action -> bool
        Defender = New-Object System.Collections.ArrayList
        Tasks    = @{}   # 'path|name' -> @{ Enabled }
        Calls    = New-Object System.Collections.ArrayList
        Run      = $Run
    }
    @{
        Name        = 'Memoria'
        State       = $script:Mem
        RegRead     = ${function:Read-MemRegValue}
        RegWrite    = ${function:Write-MemRegValue}
        RegDelete   = { param($Path, $Name) $k = Get-MemKey $Path; if ($k) { $k.Values.Remove($Name.ToLowerInvariant()) } }
        KeyExists   = { param($Path) $null -ne (Get-MemKey $Path) }
        KeyCreate   = { param($Path) $null = New-MemKey $Path }
        KeyChildren = ${function:Get-MemRegChildren}
        KeyValues   = {
            param($Path)
            $k = Get-MemKey $Path
            if ($null -eq $k) { return , @() }
            , ([string[]]@($k.Values.Values | ForEach-Object { $_.Name }))
        }
        KeyDelete   = ${function:Remove-MemKeyIfEmpty}
        SvcRead     = {
            param($Name)
            $s = $script:Mem.Services[$Name]
            if ($null -eq $s) { return $null }
            @{ Start = $s.Start; Running = $s.Running }
        }
        SvcWrite    = { param($Name, $Start) $script:Mem.Services[$Name].Start = $Start }
        SvcStop     = { param($Name) $script:Mem.Services[$Name].Running = $false }
        SvcStart    = { param($Name) $script:Mem.Services[$Name].Running = $true }
        Run         = {
            param($File, $Arguments)
            [void]$script:Mem.Calls.Add(($File + ' ' + ($Arguments -join ' ')).Trim())
            & $script:Mem.Run $File $Arguments
        }
        SpiGet      = { param($Action) [bool]$script:Mem.Spi[[uint32]$Action] }
        # Every SPI_SETx used here is its SPI_GETx plus one.
        SpiSet      = { param($Action, $Value) $script:Mem.Spi[[uint32]$Action - 1] = [bool]$Value }
        DefList     = { , ([string[]]@($script:Mem.Defender)) }
        DefAdd      = { param($Path) [void]$script:Mem.Defender.Add($Path) }
        DefRemove   = { param($Path) $script:Mem.Defender.Remove($Path) }
        TaskRead    = {
            param($Path, $Name)
            $t = $script:Mem.Tasks["$Path|$Name"]
            if ($null -eq $t) { return $null }
            @{ Enabled = $t.Enabled }
        }
        TaskWrite   = { param($Path, $Name, $Enabled) $script:Mem.Tasks["$Path|$Name"].Enabled = [bool]$Enabled }
    }
}

function Get-MemKey {
    param([string]$Path)
    $script:Mem.Keys[$Path.TrimEnd('\').ToLowerInvariant()]
}

function New-MemKey {
    param([string]$Path)
    $null = Split-JuicerRegPath $Path
    $p = $Path.TrimEnd('\')
    $chain = New-Object System.Collections.ArrayList
    while ($p -and $p.Contains('\')) { [void]$chain.Insert(0, $p); $p = Get-JuicerRegParent $p }
    foreach ($k in $chain) {
        if (-not $script:Mem.Keys.ContainsKey($k.ToLowerInvariant())) {
            $script:Mem.Keys[$k.ToLowerInvariant()] = @{ Path = $k; Values = @{} }
        }
    }
    Get-MemKey $Path
}

function Read-MemRegValue {
    param([string]$Path, [string]$Name)
    $k = Get-MemKey $Path
    if ($null -eq $k) { return $null }
    $v = $k.Values[$Name.ToLowerInvariant()]
    if ($null -eq $v) { return $null }
    @{ Kind = $v.Kind; Value = (ConvertTo-JuicerRegValue $v.Kind $v.Value) }
}

function Write-MemRegValue {
    param([string]$Path, [string]$Name, [string]$Kind, $Value)
    $k = New-MemKey $Path
    $k.Values[$Name.ToLowerInvariant()] = @{ Name = $Name; Kind = $Kind; Value = (ConvertTo-JuicerRegValue $Kind $Value) }
}

function Get-MemRegChildren {
    param([string]$Path)
    $prefix = $Path.TrimEnd('\').ToLowerInvariant() + '\'
    , ([string[]]@($script:Mem.Keys.Values | Where-Object {
                $_.Path.ToLowerInvariant().StartsWith($prefix) -and -not $_.Path.Substring($prefix.Length).Contains('\')
            } | ForEach-Object { $_.Path.Substring($prefix.Length) } | Sort-Object))
}

function Remove-MemKeyIfEmpty {
    param([string]$Path)
    $lp = $Path.TrimEnd('\').ToLowerInvariant()
    $k = $script:Mem.Keys[$lp]
    if ($null -eq $k) { return $true }
    if ($k.Values.Count -gt 0) { return $false }
    if (@($script:Mem.Keys.Keys | Where-Object { $_.StartsWith($lp + '\') }).Count -gt 0) { return $false }
    $script:Mem.Keys.Remove($lp)
    $true
}

# --- Thin wrappers the rest of the code uses -------------------------------

function Read-JuicerReg { param([string]$Path, [string]$Name) & (Get-JuicerBackend).RegRead $Path $Name }
function Write-JuicerReg { param([string]$Path, [string]$Name, [string]$Kind, $Value) & (Get-JuicerBackend).RegWrite $Path $Name $Kind $Value }
function Remove-JuicerReg { param([string]$Path, [string]$Name) & (Get-JuicerBackend).RegDelete $Path $Name }
function Test-JuicerRegKey { param([string]$Path) & (Get-JuicerBackend).KeyExists $Path }
function Get-JuicerRegChildren { param([string]$Path) & (Get-JuicerBackend).KeyChildren $Path }
function Get-JuicerRegValueNames { param([string]$Path) & (Get-JuicerBackend).KeyValues $Path }
function Invoke-JuicerNative { param([string]$File, [string[]]$Arguments = @()) & (Get-JuicerBackend).Run $File $Arguments }
