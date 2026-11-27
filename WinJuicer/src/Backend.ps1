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

# One argument as CreateProcess wants it: .NET Framework (Windows PowerShell
# 5.1) has no ProcessStartInfo.ArgumentList, so quote by hand.
function ConvertTo-JuicerArgumentString {
    param([string[]]$Arguments = @())
    $parts = foreach ($a in @($Arguments)) {
        if ($null -eq $a) { $a = '' }
        if ($a -ne '' -and $a -notmatch '[\s"]') { $a; continue }
        # Backslashes only matter in front of a quote; double them, escape the quote.
        $q = $a -replace '(\\*)"', '$1$1\"'
        $q = $q -replace '(\\+)$', '$1$1'
        '"' + $q + '"'
    }
    $parts -join ' '
}

# Runs a program and returns @{ Code; Output } (stdout then stderr, blank lines
# dropped). A tool that hangs (nvidia-smi on a broken driver, winget waiting on
# a source) must not freeze Win Juicer forever, so it is killed after
# -TimeoutSec and reported as Code -1. 0 means no limit: for dism, winget
# installs and other tools that legitimately take minutes.
function Invoke-WinNative {
    param([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 30)
    $cmd = Get-Command -Name $File -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    $path = if ($cmd) { $cmd.Source } else { $File }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $path
    $psi.Arguments = ConvertTo-JuicerArgumentString $Arguments
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    # Closed at once: a tool that asks a question gets end-of-input instead of
    # waiting for a keyboard nobody is watching.
    $psi.RedirectStandardInput = $true
    # Same decoding PowerShell applies to native output (the OEM code page).
    try {
        $enc = [Console]::OutputEncoding
        if ($enc) { $psi.StandardOutputEncoding = $enc; $psi.StandardErrorEncoding = $enc }
    } catch { Write-Verbose "Sin codificación de consola: $_" }
    $p = New-Object System.Diagnostics.Process
    $p.StartInfo = $psi
    [void]$p.Start()
    try { $p.StandardInput.Close() } catch { Write-Verbose "stdin ya cerrada: $_" }
    # Read both pipes on their own so a full buffer cannot block the child.
    $outTask = $p.StandardOutput.ReadToEndAsync()
    $errTask = $p.StandardError.ReadToEndAsync()
    $exited = if ($TimeoutSec -gt 0) { $p.WaitForExit($TimeoutSec * 1000) } else { $p.WaitForExit(); $true }
    if (-not $exited) {
        try { $p.Kill($true) } catch { try { $p.Kill() } catch { Write-Verbose "No se pudo cerrar ${File}: $_" } }
        [void]$p.WaitForExit(3000)
        $p.Dispose()
        return [pscustomobject]@{ Code = -1; Output = "Se agotó el tiempo de espera ($TimeoutSec s) y Win Juicer cerró «$File»." }
    }
    # Pipes can stay open if the tool left a child behind: do not wait forever.
    [void]$outTask.Wait(5000)
    [void]$errTask.Wait(5000)
    $text = ''
    if ($outTask.IsCompleted) { $text += $outTask.Result }
    if ($errTask.IsCompleted -and $errTask.Result) { $text += "`n" + $errTask.Result }
    $code = $p.ExitCode
    $p.Dispose()
    $lines = @($text -split "`r?`n" | Where-Object { $_ -match '\S' })
    [pscustomobject]@{ Code = $code; Output = ($lines -join "`n") }
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

# The Appx cmdlets are a Windows PowerShell module that PowerShell 7 can only
# reach through a compatibility session, which loses errors on the way.
# Running the script in powershell.exe and reading JSON back behaves the same
# from both.
function Invoke-WinPowerShell {
    param([Parameter(Mandatory)][string]$Script)
    $prefix = "`$ProgressPreference = 'SilentlyContinue'; `$ErrorActionPreference = 'Stop'`n"
    if ($PSVersionTable.PSEdition -ne 'Core') {
        return , @(& ([scriptblock]::Create($prefix + $Script)) | ForEach-Object { ConvertTo-JuicerHashtable $_ })
    }
    $full = $prefix + "@(`n$Script`n) | ConvertTo-Json -Depth 4 -Compress"
    $exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $r = Invoke-WinNative $exe @('-NoProfile', '-NonInteractive', '-EncodedCommand', [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($full))) -TimeoutSec 300
    if ($r.Code -ne 0) { throw "Windows PowerShell: $($r.Output)" }
    $json = @($r.Output -split "`n" | Where-Object { $_ -match '^\s*[\[{]' })[-1]
    ConvertFrom-JuicerWinPsJson $json
}

# What the Windows PowerShell child printed, as one flat list of hashtables.
# ConvertFrom-Json hands a JSON array over item by item in PowerShell 7 and
# whole in 5.1 and 6; read as one array, the list came back inside another
# list, and every Store app read as not installed.
function ConvertFrom-JuicerWinPsJson {
    param([string]$Json)
    if (-not $Json) { return , @() }
    , @($Json | ConvertFrom-Json | ForEach-Object { $_ } | ForEach-Object { ConvertTo-JuicerHashtable $_ })
}

function ConvertTo-WinPsLiteral {
    param([string]$Text)
    "'" + ($Text -replace "'", "''") + "'"
}

# Listing every package for every user takes seconds; the engine asks about
# one package at a time, so the list is read once and dropped after a change.
$script:AppxCache = $null

function Read-WinAppx {
    param([string]$Name)
    if ($null -eq $script:AppxCache) {
        $list = Invoke-WinPowerShell @'
$p = @{}
foreach ($a in @(Get-AppxPackage -AllUsers)) {
    $p[$a.Name] = [pscustomobject]@{ Name = $a.Name; Installed = $true; Provisioned = $false }
}
foreach ($v in @(Get-AppxProvisionedPackage -Online)) {
    if ($p.ContainsKey($v.DisplayName)) { $p[$v.DisplayName].Provisioned = $true }
    else { $p[$v.DisplayName] = [pscustomobject]@{ Name = $v.DisplayName; Installed = $false; Provisioned = $true } }
}
$p.Values
'@
        $script:AppxCache = @{}
        foreach ($a in $list) { if ($a.Name) { $script:AppxCache[[string]$a.Name] = $a } }
    }
    $hit = $script:AppxCache[$Name]
    if ($null -eq $hit) { return $null }
    @{ Installed = [bool]$hit.Installed; Provisioned = [bool]$hit.Provisioned }
}

function Remove-WinAppx {
    param([string]$Name)
    $n = ConvertTo-WinPsLiteral $Name
    $script:AppxCache = $null
    [void](Invoke-WinPowerShell @"
Get-AppxPackage -AllUsers -Name $n | Remove-AppxPackage -AllUsers
Get-AppxProvisionedPackage -Online | Where-Object { `$_.DisplayName -eq $n } | Remove-AppxProvisionedPackage -Online | Out-Null
"@)
}

# Store apps come back from the Store itself; winget is how to ask it without
# opening a window.
function Add-WinAppx {
    param([string]$Name, [string]$StoreId)
    if (-not $StoreId) { throw "$Name no tiene identificador de Microsoft Store: reinstálala desde la Tienda." }
    if (-not (Get-Command winget.exe -ErrorAction SilentlyContinue)) { throw 'winget no está disponible: instala «Instalador de aplicación» desde Microsoft Store.' }
    $script:AppxCache = $null
    $r = Invoke-WinNative 'winget.exe' @('install', '--id', $StoreId, '--source', 'msstore', '--accept-package-agreements', '--accept-source-agreements', '--silent', '--disable-interactivity') -TimeoutSec 0
    if ($r.Code -ne 0) { throw "winget no pudo reinstalar $Name ($($r.Code)); si Microsoft la retiró de la Tienda, ya no hay de dónde: $($r.Output)" }
}

# Physical adapters that are connected. Virtual ones (VPN, Hyper-V) keep
# whatever DNS their software gave them.
function Get-WinNetAdapters {
    , @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -eq 'Up' } | ForEach-Object {
            @{
                Guid = [string]$_.InterfaceGuid; Name = [string]$_.Name; Description = [string]$_.InterfaceDescription
                Wireless = ([int]$_.NdisPhysicalMedium -eq 9); LinkSpeed = [int64]$_.ReceiveLinkSpeed
            }
        })
}

# Every physical adapter that can carry traffic, connected or not, and
# whether IPv6 is on in it: the content protection covers them all, so that
# a Wi-Fi that connects later is already filtered.
# GetSystemPowerStatus through the native helper, as ConvertFrom-JuicerPowerStatus shapes it.
# Null when it cannot be read (not Windows, or the call failed): callers fall back to WMI.
function Get-WinPowerStatus {
    if ([Environment]::OSVersion.Platform -ne 'Win32NT') { return $null }
    try {
        Initialize-JuicerNative
        $r = [WinJuicer.Native]::GetPowerStatus()
        ConvertFrom-JuicerPowerStatus -AcLine $r[0] -BatteryFlag $r[1] -Percent $r[2] -SystemFlag $r[3] -SecondsLeft $r[4]
    } catch {
        Write-Verbose "GetSystemPowerStatus falló: $_"
        $null
    }
}

function Get-WinNetAdaptersAll {
    , @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -in 'Up', 'Disconnected' } | ForEach-Object {
            $v6 = $true
            try { $v6 = [bool](Get-NetAdapterBinding -Name $_.Name -ComponentID 'ms_tcpip6' -ErrorAction Stop).Enabled } catch { Write-Verbose "Sin datos de IPv6 de $($_.Name)" }
            @{ Guid = [string]$_.InterfaceGuid; Name = [string]$_.Name; Description = [string]$_.InterfaceDescription; Ipv6 = $v6 }
        })
}

# Whether a DNS server answers now: one quick question, from no cache.
function Test-WinDnsServer {
    param([string]$Server)
    try {
        $null = Resolve-DnsName -Name 'www.msftconnecttest.com' -Server $Server -Type A -DnsOnly -NoHostsFile -QuickTimeout -ErrorAction Stop
        $true
    } catch {
        $false
    }
}

# Clearing first and then setting is the only way to bring back exactly what
# was there: Set-DnsClientServerAddress leaves alone a family it is not given.
function Set-WinDns {
    param([string]$Interface, [string[]]$V4, [string[]]$V6)
    $a = Get-NetAdapter -ErrorAction Stop | Where-Object { [string]$_.InterfaceGuid -eq $Interface } | Select-Object -First 1
    if (-not $a) { throw "No encuentro el adaptador $Interface." }
    Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ResetServerAddresses -ErrorAction Stop
    $all = @(@($V4) + @($V6) | Where-Object { $_ })
    if ($all.Count -gt 0) { Set-DnsClientServerAddress -InterfaceIndex $a.ifIndex -ServerAddresses $all -ErrorAction Stop }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

# --- Checking that the content protection works ----------------------------

# The adapter the traffic actually leaves by (the default route with the
# lowest metric), whether it is a physical one, and the DNS servers Windows
# uses on it, from DHCP or set by hand.
function Get-WinDnsRoute {
    $r = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue) + @(Get-NetRoute -DestinationPrefix '::/0' -ErrorAction SilentlyContinue) |
        Where-Object { $_ } | Sort-Object RouteMetric | Select-Object -First 1
    if (-not $r) { return $null }
    $idx = [int]$r.ifIndex
    $a = Get-NetAdapter -InterfaceIndex $idx -ErrorAction SilentlyContinue
    $physical = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue | Where-Object { [int]$_.ifIndex -eq $idx }).Count -gt 0
    $servers = @(Get-DnsClientServerAddress -InterfaceIndex $idx -ErrorAction SilentlyContinue | ForEach-Object { $_.ServerAddresses } | Where-Object { $_ })
    @{
        Name = $(if ($a) { [string]$a.Name } else { [string]$r.InterfaceAlias }); Description = $(if ($a) { [string]$a.InterfaceDescription } else { '' })
        Virtual = -not $physical; Servers = $servers
    }
}

# The A records a name resolves to, through Windows (as a browser would) or
# straight from one server. @{ Ips; Error; NxDomain }: NxDomain when the answer
# is that the name does not exist, which is how a filter blocks it and is not
# a failure.
function Resolve-WinName {
    param([string]$Name, [string]$Server = '')
    $p = @{ Name = $Name; Type = 'A'; DnsOnly = $true; QuickTimeout = $true; ErrorAction = 'Stop' }
    if ($Server) { $p.Server = $Server }
    try {
        @{ Ips = @(Resolve-DnsName @p | Where-Object { $_.Type -eq 'A' } | ForEach-Object { [string]$_.IPAddress }); Error = ''; NxDomain = $false }
    } catch {
        # DNS_ERROR_RCODE_NAME_ERROR, in any language.
        $code = $_.Exception.NativeErrorCode
        if ($null -eq $code -and $_.Exception.InnerException) { $code = $_.Exception.InnerException.NativeErrorCode }
        @{ Ips = @(); Error = "$($_.Exception.Message)"; NxDomain = ([int]$code -eq 9003) }
    }
}

# The browsers running now, each with when its oldest process started: one
# opened before the protection still has the old DNS answers and rules.
function Get-WinBrowserProcesses {
    $out = @()
    foreach ($g in @(Get-Process -Name brave, chrome, msedge, firefox -ErrorAction SilentlyContinue | Group-Object ProcessName)) {
        $starts = @($g.Group | ForEach-Object { try { $_.StartTime } catch { $null } } | Where-Object { $_ } | Sort-Object)
        $out += @{ Name = [string]$g.Name; Started = $(if ($starts.Count -gt 0) { $starts[0] } else { $null }) }
    }
    , $out
}

# Chromium-based browsers reread their policies when told group policy
# changed; written straight to the registry, they would wait hours.
function Invoke-WinPolicyRefresh {
    if (-not ('WinJuicer.Gp' -as [type])) {
        Add-Type -Namespace WinJuicer -Name Gp -MemberDefinition '[DllImport("userenv.dll", SetLastError = true)] public static extern bool RefreshPolicyEx(bool isMachine, uint options);'
    }
    [void][WinJuicer.Gp]::RefreshPolicyEx($true, 1)
    [void][WinJuicer.Gp]::RefreshPolicyEx($false, 1)
}

# --- Firewall and hosts file, for the content protection ---------------------

# The rules with these names as Windows applies them (the active store: a rule
# there is one that works), with every condition that could narrow them.
function Get-WinFwRules {
    param([string[]]$Names)
    $out = @()
    foreach ($r in @(Get-NetFirewallRule -PolicyStore ActiveStore -Name $Names -ErrorAction SilentlyContinue)) {
        $port = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $r
        $addr = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $r
        $app = Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $r
        $svc = Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $r
        $nic = Get-NetFirewallInterfaceTypeFilter -AssociatedNetFirewallRule $r
        $out += @{
            Name = [string]$r.Name; Enabled = ([string]$r.Enabled -eq 'True'); Action = [string]$r.Action; Direction = [string]$r.Direction; Profile = [string]$r.Profile
            Protocol = [string]$port.Protocol; RemotePort = @($port.RemotePort | ForEach-Object { [string]$_ }); LocalPort = @($port.LocalPort | ForEach-Object { [string]$_ })
            RemoteAddress = @($addr.RemoteAddress | ForEach-Object { [string]$_ }); LocalAddress = @($addr.LocalAddress | ForEach-Object { [string]$_ })
            Program = [string]$app.Program; Service = [string]$svc.Service; InterfaceType = [string]$nic.InterfaceType
        }
    }
    , $out
}

# A block rule, outbound, for every profile, written anew: a rule someone
# narrowed is easier to replace than to put back field by field.
function Set-WinFwRule {
    param([hashtable]$Rule, [string]$Group, [switch]$Disabled)
    Remove-NetFirewallRule -Name $Rule.Name -ErrorAction SilentlyContinue
    $p = @{
        Name = $Rule.Name; DisplayName = $Rule.Title; Description = $Rule.Description; Group = $Group
        Direction = 'Outbound'; Action = 'Block'; Protocol = $Rule.Protocol; RemotePort = $Rule.Port; RemoteAddress = @($Rule.Remote)
        Profile = 'Any'; Enabled = $(if ($Disabled) { 'False' } else { 'True' })
    }
    New-NetFirewallRule @p -ErrorAction Stop | Out-Null
}

# Which profiles of Windows' firewall are off, and whether another program
# registered as the firewall (it turns Windows' off, and is left in charge).
function Get-WinFwState {
    $off = @(Get-NetFirewallProfile -PolicyStore ActiveStore -ErrorAction Stop | Where-Object { [string]$_.Enabled -eq 'False' } | ForEach-Object { [string]$_.Name })
    $third = $false
    try { $third = @(Get-CimInstance -Namespace 'root/SecurityCenter2' -ClassName FirewallProduct -ErrorAction Stop).Count -gt 0 } catch { Write-Verbose "Sin Centro de seguridad (Windows Server): $_" }
    @{ Off = $off; ThirdParty = $third }
}

function Get-WinHostsPath { Join-Path $env:SystemRoot 'System32\drivers\etc\hosts' }

# Read and written byte for byte (Latin-1 maps each byte to one character and
# back), so whatever encoding the file had, the lines it already had stay
# exactly as they were.
function Read-WinHosts {
    $p = Get-WinHostsPath
    if (-not (Test-Path -LiteralPath $p)) { return $null }
    [Text.Encoding]::GetEncoding(28591).GetString([IO.File]::ReadAllBytes($p))
}

function Write-WinHosts {
    param([string]$Text)
    $p = Get-WinHostsPath
    $attr = $null
    if (Test-Path -LiteralPath $p) {
        $item = Get-Item -LiteralPath $p -Force
        $attr = $item.Attributes
        # Read-only on purpose, often: it is put back after.
        if ($attr -band [IO.FileAttributes]::ReadOnly) { $item.Attributes = $attr -band (-bnot [IO.FileAttributes]::ReadOnly) }
    }
    try {
        [IO.File]::WriteAllBytes($p, [Text.Encoding]::GetEncoding(28591).GetBytes($Text))
    } finally {
        if ($null -ne $attr) { (Get-Item -LiteralPath $p -Force).Attributes = $attr }
    }
    Clear-DnsClientCache -ErrorAction SilentlyContinue
}

# Reading goes through WMI: «dism /Get-Features» takes up to a minute, and
# the window asks for every component when it opens. Changing goes through
# dism, which also brings in what a feature depends on.
# InstallState: 1 enabled, 2 disabled, 3 not on disk (Windows Update brings
# it), 4 unknown.
#
# WMI keeps reporting the old state of a feature changed with /NoRestart until
# the reboot; dism answers 3010 then. What was changed is remembered, tied to
# this boot, so that verifying, undoing and rolling back see the new state.
$script:FeatureCache = $null

function Get-WinBootId {
    try { return (Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime.ToString('s') } catch { return '' }
}

function Get-WinPendingFeatures {
    $path = Join-Path (Get-JuicerHome) 'componentes-pendientes.json'
    $p = @{ Boot = (Get-WinBootId); Features = @{} }
    if (Test-Path -LiteralPath $path) {
        try {
            $saved = ConvertTo-JuicerHashtable ([IO.File]::ReadAllText($path) | ConvertFrom-Json)
            if ($saved.Boot -eq $p.Boot -and $saved.Features) { $p.Features = $saved.Features }
        } catch {
            Write-JuicerLog "Componentes pendientes ilegibles: $_"
        }
    }
    $p
}

function Read-WinFeature {
    param([string]$Name)
    if ($null -eq $script:FeatureCache) {
        $cache = @{}
        foreach ($f in @(Get-CimInstance Win32_OptionalFeature -ErrorAction Stop)) { $cache[[string]$f.Name] = [int]$f.InstallState }
        $script:FeatureCache = $cache
    }
    $state = $script:FeatureCache[$Name]
    if ($null -eq $state -or $state -notin 1, 2, 3) { return $null }
    $pending = (Get-WinPendingFeatures).Features
    if ($pending.ContainsKey($Name)) { return @{ Enabled = [bool]$pending[$Name] } }
    @{ Enabled = ($state -eq 1) }
}

function Set-WinFeature {
    param([string]$Name, [bool]$Enabled)
    $script:FeatureCache = $null
    $arguments = if ($Enabled) { @('/Online', '/English', '/Enable-Feature', "/FeatureName:$Name", '/All', '/NoRestart') } else { @('/Online', '/English', '/Disable-Feature', "/FeatureName:$Name", '/NoRestart') }
    # DISM can take many minutes: no limit.
    $r = Invoke-WinNative 'dism.exe' $arguments -TimeoutSec 0
    # 3010: done, a restart finishes it.
    if ($r.Code -notin 0, 3010) { throw "dism no pudo cambiar ${Name} ($($r.Code)): $($r.Output)" }
    $p = Get-WinPendingFeatures
    if ($r.Code -eq 3010) { $p.Features[$Name] = $Enabled } else { $p.Features.Remove($Name) }
    [IO.File]::WriteAllText((Join-Path (Get-JuicerHome) 'componentes-pendientes.json'), (ConvertTo-JuicerJson $p), (New-Object Text.UTF8Encoding $false))
}

# Frame limits per program: the NVIDIA driver's when there is one, RTSS's
# profiles otherwise. Read returns @{ Backend; Fps (null = none); Existed }.
$script:FpsBackendName = $null

function Get-WinRtssDir {
    foreach ($d in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if (-not $d) { continue }
        $dir = Join-Path $d 'RivaTuner Statistics Server'
        if (Test-Path -LiteralPath (Join-Path $dir 'RTSS.exe')) { return $dir }
    }
    $null
}

$script:NvApiOk = $null
$script:NvApiFailedAt = $null
$script:FpsBackendAt = $null

# How long a failure is remembered before trying again: NVAPI can fail for a
# moment (the driver restarting, a display mode change, the PC just resumed),
# and remembering that for the whole life of the process would leave the frame
# pacer without its NVIDIA engine until Win Juicer is reopened.
$script:NvApiRetrySeconds = 30

# Whether a failure noted At is still recent enough not to look again.
function Test-JuicerFailureCached {
    param($At, [datetime]$Now = (Get-Date), [int]$Seconds = $script:NvApiRetrySeconds)
    if ($null -eq $At) { return $false }
    ($Now - [datetime]$At).TotalSeconds -lt $Seconds
}

function Test-WinNvApi {
    # A success is kept; a failure only for a short while.
    if ($script:NvApiOk -eq $true) { return $true }
    if ($null -ne $script:NvApiOk -and (Test-JuicerFailureCached $script:NvApiFailedAt)) { return $false }
    $script:NvApiOk = $false
    try {
        Initialize-JuicerNvApi
        $script:NvApiOk = [WinJuicer.NvDrs]::Available()
    } catch {
        Write-JuicerLog "NVAPI no disponible: $_"
    }
    if (-not $script:NvApiOk) { $script:NvApiFailedAt = Get-Date }
    $script:NvApiOk
}

function Get-WinFpsEngines {
    @(if (Test-WinNvApi) { 'nvidia' }; if (Get-WinRtssDir) { 'rtss' })
}

# The driver's when there is one, RivaTuner otherwise, unless the frame
# pacer was told to use one of them (and it is there). The choice is kept,
# except while NVAPI is failing: then whatever was picked without it (RivaTuner,
# or nothing) is only kept for a moment, so the driver comes back when it answers.
function Get-WinFpsBackend {
    $name = $script:FpsBackendName
    if ($null -ne $name -and ($script:NvApiOk -eq $true -or (Test-JuicerFailureCached $script:FpsBackendAt))) { return $name }
    $engines = @(Get-WinFpsEngines)
    $want = Get-JuicerPacerEngine
    $script:FpsBackendName = if ($engines -contains $want) { $want } elseif ($engines.Count -gt 0) { $engines[0] } else { '' }
    $script:FpsBackendAt = Get-Date
    $script:FpsBackendName
}

# NVAPI's status codes (nvapi_lite_common.h and nvapi.h), the ones that show up
# with the driver's profile store, in words. -160, -163, -166 and -167 are the
# ones Native.ps1 already tests for. Anything else keeps its number only.
$script:NvApiErrors = @{
    -1 = 'el driver de NVIDIA devolvió un error sin más detalle: reinicia el equipo o actualiza el driver'
    -2 = 'no se encuentra la biblioteca del driver de NVIDIA (nvapi64.dll): instala o repara el driver'
    -3 = 'este driver de NVIDIA no tiene la función que hace falta: actualízalo'
    -4 = 'el driver de NVIDIA no responde: reinicia el equipo o actualiza el driver'
    -5 = 'el driver de NVIDIA rechazó el valor que se le pasó: actualiza el driver'
    -6 = 'no hay una gráfica NVIDIA activa con su driver: comprueba que esté instalado y que el equipo no la tenga desactivada'
    -9 = 'la versión del driver de NVIDIA no encaja con la de Win Juicer: actualiza el driver y Win Juicer'
    -137 = 'hace falta ejecutar Win Juicer como administrador para cambiar los perfiles de NVIDIA'
    -160 = 'ese ajuste no existe en este driver de NVIDIA: actualízalo'
    -163 = 'el perfil del juego no existe en el driver de NVIDIA'
    -166 = 'el juego no está en ningún perfil del driver de NVIDIA'
    -167 = 'el juego ya está en otro perfil del driver de NVIDIA'
}

# The message of an NVAPI failure («NVAPI Initialize: código -4») in Spanish,
# with the code kept at the end so the log and a bug report still have it. A
# message with no code, or one that is not known, goes back as it came.
function Convert-JuicerNvApiError {
    param([string]$Message)
    if ($Message -notmatch 'NVAPI\s+(?<what>[^:]+):\s*código\s+(?<code>-?\d+)') { return $Message }
    $code = [int]$Matches.code
    $text = $script:NvApiErrors[$code]
    if (-not $text) { return $Message }
    $out = $text.Substring(0, 1).ToUpperInvariant() + $text.Substring(1)
    "$out (NVAPI $($Matches.what.Trim()), código $code)."
}

# The text to throw for an NVAPI failure caught: in words, with the original
# (and its code) in the log. A message that is not NVAPI's goes back as it came.
function Get-WinNvApiFailure {
    param($ErrorRecord)
    $raw = "$($ErrorRecord.Exception.Message)"
    $nice = Convert-JuicerNvApiError $raw
    if ($nice -ne $raw) { Write-JuicerLog "NVAPI: $raw" }
    $nice
}

function Get-WinRtssProfile { param([string]$Exe) Join-Path (Join-Path (Get-WinRtssDir) 'Profiles') "$Exe.cfg" }

function Read-WinFpsLimit {
    param([string]$Exe, [string]$Backend)
    switch ($(if ($Backend) { $Backend } else { Get-WinFpsBackend })) {
        'nvidia' {
            if (-not (Test-WinNvApi)) { return $null }
            try { $v = [WinJuicer.NvDrs]::GetDword($Exe, [WinJuicer.NvDrs]::FrameRateLimiterId) } catch { throw (Get-WinNvApiFailure $_) }
            return @{ Backend = 'nvidia'; Fps = $(if ($v -gt 0) { $v } else { $null }); Existed = ($v -ge 0) }
        }
        'rtss' {
            if (-not (Get-WinRtssDir)) { return $null }
            $f = Get-WinRtssProfile $Exe
            if (-not (Test-Path -LiteralPath $f)) { return @{ Backend = 'rtss'; Fps = $null; Existed = $false } }
            $v = Get-JuicerRtssLimit ([IO.File]::ReadAllLines($f))
            return @{ Backend = 'rtss'; Fps = $(if ($v -gt 0) { [int][Math]::Round($v) } else { $null }); Exact = $v; Existed = $true }
        }
    }
    $null
}

# Fps 0 or null takes the limit away. For RTSS, a new profile starts as a
# copy of the Global one, as RTSS itself does; Remove deletes it again.
# Exact, RTSS only: a fractional cap (179.95), for which the driver's
# whole numbers are not enough.
function Set-WinFpsLimit {
    param([string]$Exe, $Fps, [string]$Backend, [switch]$Remove, [double]$Exact = 0)
    $n = if ($Fps) { [int]$Fps } else { 0 }
    switch ($Backend) {
        'nvidia' {
            Initialize-JuicerNvApi
            try { [WinJuicer.NvDrs]::SetDword($Exe, [WinJuicer.NvDrs]::FrameRateLimiterId, $(if ($n -gt 0) { $n } else { -1 })) } catch { throw (Get-WinNvApiFailure $_) }
        }
        'rtss' {
            $f = Get-WinRtssProfile $Exe
            if ($Remove) { Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue; Update-WinRtssProfiles; return }
            $lines = if (Test-Path -LiteralPath $f) { [IO.File]::ReadAllLines($f) } else {
                $global = Join-Path (Split-Path -Parent $f) 'Global'
                if (Test-Path -LiteralPath $global) { [IO.File]::ReadAllLines($global) } else { @() }
            }
            [IO.File]::WriteAllLines($f, [string[]](Set-JuicerRtssLimit $lines $n $Exact), (New-Object Text.ASCIIEncoding))
            Update-WinRtssProfiles
        }
        default { throw 'El frame pacer necesita una gráfica NVIDIA o RivaTuner Statistics Server.' }
    }
}

# Whatever else limits frames on this PC, for the frame pacer to warn of
# two limiters at once: RTSS's Global profile and the games it limits, and
# the global frame limit of NVIDIA's control panel.
function Get-WinPacerState {
    # Nv*: the user values of NVIDIA's global profile, -1 when there is none.
    $s = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0; NvVrrMode = -1; NvShaderCache = -1; NvShaderCacheMb = -1 }
    $dir = Get-WinRtssDir
    if ($dir) {
        $s.RtssInstalled = $true
        $s.RtssRunning = $null -ne (Get-Process -Name 'RTSS' -ErrorAction SilentlyContinue)
        $profiles = Join-Path $dir 'Profiles'
        $global = Join-Path $profiles 'Global'
        if (Test-Path -LiteralPath $global) { $s.RtssGlobal = Get-JuicerRtssLimit ([IO.File]::ReadAllLines($global)) }
        foreach ($f in @(Get-ChildItem -LiteralPath $profiles -Filter '*.exe.cfg' -File -ErrorAction SilentlyContinue)) {
            $v = Get-JuicerRtssLimit ([IO.File]::ReadAllLines($f.FullName))
            if ($v -gt 0) { $s.RtssGames[$f.Name.Substring(0, $f.Name.Length - 4).ToLowerInvariant()] = $v }
        }
    }
    if (Test-WinNvApi) {
        try {
            $v = [WinJuicer.NvDrs]::GetGlobalDword([WinJuicer.NvDrs]::FrameRateLimiterId)
            if ($v -gt 0) { $s.NvGlobal = [int]$v }
            # VRR_MODE_ID, PS_SHADERDISKCACHE_ID, PS_SHADERDISKCACHE_MAX_SIZE_ID (MB).
            $s.NvVrrMode = [WinJuicer.NvDrs]::GetGlobalDword([uint32]0x1194F158)
            $s.NvShaderCache = [WinJuicer.NvDrs]::GetGlobalDword([uint32]0x00198FFF)
            $s.NvShaderCacheMb = [WinJuicer.NvDrs]::GetGlobalDword([uint32]0x00AC8497)
        } catch {
            Write-JuicerLog "No se pudo leer el perfil global de NVIDIA: $_"
        }
    }
    $s
}

# A RivaTuner that is running reads its profiles when it starts: after
# writing one, it is told to read them again, through UpdateProfiles in its
# own RTSSHooks64.dll (RTSS 7.3.7 and later; with an older one, or if it is
# not running, the profile applies the next time it starts).
function Update-WinRtssProfiles {
    $dir = Get-WinRtssDir
    if (-not $dir -or [IntPtr]::Size -ne 8 -or -not (Get-Process -Name 'RTSS' -ErrorAction SilentlyContinue)) { return }
    $dll = Join-Path $dir 'RTSSHooks64.dll'
    if (-not (Test-Path -LiteralPath $dll)) { return }
    try {
        if (-not ('WinJuicer.Rtss' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace WinJuicer {
    public static class Rtss {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] static extern IntPtr LoadLibraryW(string path);
        [DllImport("kernel32.dll", CharSet = CharSet.Ansi)] static extern IntPtr GetProcAddress(IntPtr module, string name);
        [UnmanagedFunctionPointer(CallingConvention.StdCall)] delegate void NoArgs();
        // False when this RTSS has no UpdateProfiles.
        public static bool UpdateProfiles(string dll) {
            IntPtr m = LoadLibraryW(dll);
            if (m == IntPtr.Zero) return false;
            IntPtr f = GetProcAddress(m, "UpdateProfiles");
            if (f == IntPtr.Zero) return false;
            ((NoArgs)Marshal.GetDelegateForFunctionPointer(f, typeof(NoArgs)))();
            return true;
        }
    }
}
'@
        }
        if (-not [WinJuicer.Rtss]::UpdateProfiles($dll)) { Write-JuicerLog 'Este RivaTuner no tiene UpdateProfiles: el perfil se aplicará al reiniciarlo.' }
    } catch {
        Write-JuicerLog "No se pudo pedir a RivaTuner que relea sus perfiles: $_"
    }
}

# Any other DWORD of a program's NVIDIA profile: @{ Value; Predefined },
# the user's value and the one NVIDIA ships for that game, null for none.
function Read-WinNvSetting {
    param([string]$Exe, [uint32]$Id)
    if (-not (Test-WinNvApi)) { return $null }
    try { $v = [WinJuicer.NvDrs]::GetInfo($Exe, $Id) } catch { throw (Get-WinNvApiFailure $_) }
    @{ Value = $(if ($v[0] -ge 0) { [uint32]$v[0] } else { $null }); Predefined = $(if ($v[1] -ge 0) { [uint32]$v[1] } else { $null }) }
}

# Whether a program with this .exe name is running now. A game's profile is
# never written while it runs: the driver hands a running game the new
# values, and changing its sync or its queue under it can freeze it.
function Test-WinProcessRunning {
    param([string]$Exe)
    $name = [IO.Path]::GetFileNameWithoutExtension(([string]$Exe).Trim().Trim('"'))
    if (-not $name) { return $false }
    $null -ne (Get-Process -Name ([WildcardPattern]::Escape($name)) -ErrorAction SilentlyContinue | Select-Object -First 1)
}

# Programs that closed with an error or stopped responding since a date,
# from the Application log: «Application Error» 1000 (it crashed) and
# «Application Hang» 1002 (it hung and was closed). @{ Exe; Kind; Time;
# Module } each; null when the log cannot be read, or when it holds more than
# can be read back to that date: one program crashing in a loop would push a
# game's older crashes out, and «it never crashed before» would be a guess.
function Read-WinAppIncidents {
    param([datetime]$Since)
    $out = @()
    $max = 5000
    foreach ($f in @(@{ Provider = 'Application Error'; Id = 1000; Kind = 'Cierre' }, @{ Provider = 'Application Hang'; Id = 1002; Kind = 'Cuelgue' })) {
        $ev = Get-JuicerEvents @{ LogName = 'Application'; ProviderName = $f.Provider; Id = $f.Id; StartTime = $Since } -Max $max
        if ($null -eq $ev -or $ev.Count -ge $max) { return $null }
        foreach ($e in $ev) {
            $p = @($e.Properties | ForEach-Object { $_.Value })
            if ($p.Count -eq 0 -or -not $p[0]) { continue }
            $out += @{ Exe = ([string]$p[0]).ToLowerInvariant(); Kind = $f.Kind; Time = $e.TimeCreated.ToString('s'); Module = $(if ($f.Id -eq 1000 -and $p.Count -gt 3) { [string]$p[3] } else { '' }) }
        }
    }
    , $out
}

# NVIDIA keeps every profile (its own, the games', the user's) in a pair of
# files, nvdrsdb0.bin and nvdrsdb1.bin, in ProgramData. Win Juicer writes to
# them through the driver; these two copy the files out and back, so that a
# profile store a change left in a bad state can be put back whole. Both take
# the folder to use and return the file names copied (callers wrap them in @()).
function Get-WinNvDrsDir {
    if (-not $env:ProgramData) { return $null }
    Join-Path $env:ProgramData 'NVIDIA Corporation\Drs'
}

function Backup-WinNvProfiles {
    param([string]$Dest)
    $src = Get-WinNvDrsDir
    if (-not $src -or -not (Test-Path -LiteralPath $src -PathType Container)) { return @() }
    $names = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $src -Filter 'nvdrsdb*.bin' -File -ErrorAction Stop)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $Dest $f.Name) -Force -ErrorAction Stop
        $names += $f.Name
    }
    $names
}

# The driver reads these files when it starts and writes them as it saves: a
# restore only takes hold after its service restarts, which in practice means
# restarting the PC.
function Restore-WinNvProfiles {
    param([string]$Source)
    $dst = Get-WinNvDrsDir
    if (-not $dst) { throw 'No se encuentra la carpeta de perfiles de NVIDIA.' }
    if (-not (Test-Path -LiteralPath $dst -PathType Container)) { New-Item -ItemType Directory -Path $dst -Force | Out-Null }
    $names = @()
    foreach ($f in @(Get-ChildItem -LiteralPath $Source -Filter 'nvdrsdb*.bin' -File -ErrorAction Stop)) {
        Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dst $f.Name) -Force -ErrorAction Stop
        $names += $f.Name
    }
    $names
}

function Set-WinNvSetting {
    param([string]$Exe, [uint32]$Id, $Value)
    Initialize-JuicerNvApi
    try { [WinJuicer.NvDrs]::SetDword($Exe, $Id, $(if ($null -ne $Value) { [long]$Value } else { -1 })) } catch { throw (Get-WinNvApiFailure $_) }
}

# The drivers Laptop.ps1 judges by age: display, network and system devices, with the date
# Windows has on record for each (Win32_PnPSignedDriver). Slow (a few seconds), so only the
# diagnosis asks. Date is $null when Windows has none.
function Get-WinPnpDrivers {
    , @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object { $_.DeviceClass -in 'DISPLAY', 'NET', 'SYSTEM' } | ForEach-Object {
            @{
                Class = [string]$_.DeviceClass; Name = [string]$_.DeviceName; Manufacturer = [string]$_.Manufacturer
                Provider = [string]$_.DriverProviderName; Version = [string]$_.DriverVersion
                Date = $(if ($_.DriverDate) { [datetime]$_.DriverDate } else { $null })
            }
        })
}

# Memory compression (Get-MMAgent) and how much of the commit limit (RAM plus paging file) is
# promised, in %: the «% Committed Bytes In Use» counter, read from its WMI class so that it
# does not depend on the language of Windows (the counter path is translated). Each part is
# $null when it cannot be read.
function Get-WinMemoryState {
    $s = @{ Compression = $null; CommitPct = $null }
    try { $s.Compression = [bool](Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { Write-Verbose "Sin compresión de memoria: $_" }
    try {
        $p = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory -ErrorAction Stop | Select-Object -First 1
        if ($p) { $s.CommitPct = [double]$p.PercentCommittedBytesInUse }
    } catch { Write-Verbose "Sin memoria comprometida: $_" }
    $s
}

# Milliseconds from asking for a new File Explorer window on a throwaway folder until the
# window exists (found through Shell.Application by that folder's unique name), then the
# window is closed. $null when it never showed up.
function Measure-WinExplorerWindow {
    $dir = Join-Path ([IO.Path]::GetTempPath()) ('wjmedida-' + [guid]::NewGuid().ToString('N'))
    $leaf = Split-Path -Leaf $dir
    $shell = $null
    try {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $shell = New-Object -ComObject Shell.Application
        $found = $null
        $sw = [Diagnostics.Stopwatch]::StartNew()
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('/n,"{0}"' -f $dir)
        while (-not $found -and $sw.ElapsedMilliseconds -lt 10000) {
            foreach ($w in @($shell.Windows())) {
                try { if ([string]$w.LocationURL -like "*$leaf*") { $found = $w; break } } catch { Write-Verbose "Ventana ilegible: $_" }
            }
            if (-not $found) { Start-Sleep -Milliseconds 20 }
        }
        $sw.Stop()
        if (-not $found) { return $null }
        $ms = [int]$sw.ElapsedMilliseconds
        try { $found.Quit() } catch { Write-Verbose "No se pudo cerrar la ventana: $_" }
        $ms
    } catch {
        Write-Verbose "Sin medida del Explorador: $_"
        $null
    } finally {
        if ($shell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell) }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Milliseconds from starting notepad.exe until it has a window, which is then closed. $null
# when it never got one (the new Notepad of Windows 11 hands over to another process).
function Measure-WinNotepadWindow {
    $p = $null
    try {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $p = Start-Process -FilePath 'notepad.exe' -PassThru
        while ($sw.ElapsedMilliseconds -lt 10000) {
            $p.Refresh()
            if ($p.HasExited) { return $null }
            if ($p.MainWindowHandle -ne [IntPtr]::Zero) { break }
            Start-Sleep -Milliseconds 10
        }
        $sw.Stop()
        if ($p.MainWindowHandle -eq [IntPtr]::Zero) { return $null }
        [int]$sw.ElapsedMilliseconds
    } catch {
        Write-Verbose "Sin medida del Bloc de notas: $_"
        $null
    } finally {
        if ($p) {
            try {
                if (-not $p.HasExited) {
                    [void]$p.CloseMainWindow()
                    if (-not $p.WaitForExit(3000)) { $p.Kill() }
                }
            } catch { Write-Verbose "No se pudo cerrar el Bloc de notas: $_" }
            $p.Dispose()
        }
    }
}

# The small repeatable test of Antes y después: three runs of each, the median of what came
# out (two good runs at least). @{ ExplorerMs; NotepadMs }, each $null when not measured.
# It opens and closes real windows for a few seconds, so only a session with a desktop does it.
function Measure-WinResponsiveness {
    $result = @{ ExplorerMs = $null; NotepadMs = $null }
    if (-not [Environment]::UserInteractive) { return $result }
    $explorer = @(); $notepad = @()
    foreach ($i in 1..3) {
        $ms = Measure-WinExplorerWindow
        if ($null -ne $ms) { $explorer += $ms }
        $ms = Measure-WinNotepadWindow
        if ($null -ne $ms) { $notepad += $ms }
    }
    if ($explorer.Count -ge 2) { $result.ExplorerMs = Get-JuicerMedian $explorer }
    if ($notepad.Count -ge 2) { $result.NotepadMs = Get-JuicerMedian $notepad }
    $result
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
        AppxRead     = ${function:Read-WinAppx}
        AppxRemove   = ${function:Remove-WinAppx}
        AppxAdd      = ${function:Add-WinAppx}
        NetAdapters  = ${function:Get-WinNetAdapters}
        PowerStatus  = ${function:Get-WinPowerStatus}
        Drivers      = ${function:Get-WinPnpDrivers}
        MemoryState  = ${function:Get-WinMemoryState}
        MemCompressionGet = { try { [bool](Get-MMAgent -ErrorAction Stop).MemoryCompression } catch { $null } }
        MemCompressionSet = { param([bool]$On) if ($On) { Enable-MMAgent -MemoryCompression -ErrorAction Stop } else { Disable-MMAgent -MemoryCompression -ErrorAction Stop } }
        Responsiveness = ${function:Measure-WinResponsiveness}
        PowerModeGet = { Initialize-JuicerNative; [WinJuicer.Native]::GetPowerMode() }
        PowerModeSet = { param([string]$Scheme) Initialize-JuicerNative; [WinJuicer.Native]::SetPowerMode($Scheme) }
        DnsSet       = ${function:Set-WinDns}
        NetAdaptersAll = ${function:Get-WinNetAdaptersAll}
        DnsProbe     = ${function:Test-WinDnsServer}
        FwRules      = ${function:Get-WinFwRules}
        FwSet        = ${function:Set-WinFwRule}
        FwState      = ${function:Get-WinFwState}
        FwOn         = { param([string[]]$Profiles) Set-NetFirewallProfile -Name $Profiles -Enabled True -ErrorAction Stop }
        HostsRead    = ${function:Read-WinHosts}
        HostsWrite   = ${function:Write-WinHosts}
        DnsRoute     = ${function:Get-WinDnsRoute}
        ResolveName  = ${function:Resolve-WinName}
        Browsers     = ${function:Get-WinBrowserProcesses}
        PolicyRefresh = ${function:Invoke-WinPolicyRefresh}
        DnsFlush     = { Clear-DnsClientCache -ErrorAction SilentlyContinue }
        FeatRead     = ${function:Read-WinFeature}
        FeatSet      = ${function:Set-WinFeature}
        FpsBackend   = ${function:Get-WinFpsBackend}
        FpsEngines   = ${function:Get-WinFpsEngines}
        FpsReset     = { $script:FpsBackendName = $null }
        FpsRead      = ${function:Read-WinFpsLimit}
        FpsWrite     = ${function:Set-WinFpsLimit}
        NvRead       = ${function:Read-WinNvSetting}
        NvWrite      = ${function:Set-WinNvSetting}
        NvBackup     = ${function:Backup-WinNvProfiles}
        NvRestore    = ${function:Restore-WinNvProfiles}
        ProcRunning  = ${function:Test-WinProcessRunning}
        AppIncidents = ${function:Read-WinAppIncidents}
        PacerState   = ${function:Get-WinPacerState}
        AudioInfo    = ${function:Get-WinAudioInfo}
        AudioHelperState   = ${function:Get-WinAudioHelperState}
        AudioHelperInstall = ${function:Install-WinAudioHelper}
        AudioHelperRemove  = ${function:Remove-WinAudioHelper}
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
        Appx     = @{}   # name -> @{ Installed; Provisioned }
        Adapters = New-Object System.Collections.ArrayList   # @{ Guid; Name; Description; Wireless; LinkSpeed }
        Features = @{}   # name -> @{ Enabled }
        FpsBackend = ''   # 'nvidia', 'rtss' or '' for none
        FpsLimits = @{}   # exe -> fps; an entry with 0 is a profile without a limit
        NvSettings = @{}  # 'exe|id' -> value, the user values of NVIDIA profiles
        NvPredefined = @{}  # 'exe|id' -> value NVIDIA ships for that game
        NvDrsFiles = @{}    # nvdrsdb*.bin name -> content: the driver's profile store, for the backup
        Running  = New-Object System.Collections.ArrayList   # .exe names open now
        Incidents = New-Object System.Collections.ArrayList  # @{ Exe; Kind; Time; Module }
        DnsDown  = New-Object System.Collections.ArrayList   # DNS servers that do not answer
        Firewall = @{}    # rule name -> the rule, as FwRules gives it
        FwOff    = New-Object System.Collections.ArrayList   # firewall profiles turned off
        Route    = $null                                     # @{ Name; Description; Virtual; Servers }: where traffic leaves
        Resolve  = @{}                                       # 'name|server' ('' for Windows) -> IPs
        Browsers = New-Object System.Collections.ArrayList   # @{ Name; Started }
        FwThirdParty = $false   # another program is the firewall
        Hosts    = ((@('# Copyright (c) 1993-2009 Microsoft Corp.', '#', '# This is a sample HOSTS file used by Microsoft TCP/IP for Windows.', '#', "#`t127.0.0.1       localhost", "#`t::1             localhost") -join "`r`n") + "`r`n")
        FpsExact = @{}    # exe -> fractional cap (RTSS)
        FpsEngines = $null  # engines the PC has; null = just FpsBackend
        Pacer = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0; NvVrrMode = -1; NvShaderCache = -1; NvShaderCacheMb = -1 }
        PowerMode = '00000000-0000-0000-0000-000000000000'   # the «Power mode» overlay (all zeros = none, i.e. Balanced)
        Drivers  = New-Object System.Collections.ArrayList   # @{ Class; Name; Manufacturer; Provider; Version; Date }
        MemoryState = @{ Compression = $null; CommitPct = $null }   # what MemoryState answers
        Compression = $true   # memory compression (Get-MMAgent), on as Windows ships; $null = unreadable
        Responsiveness = $null   # what Responsiveness answers: @{ ExplorerMs; NotepadMs }, null = not measured
        Power    = $null   # what PowerStatus answers (see ConvertFrom-JuicerPowerStatus); null = unreadable, the WMI fallback applies
        Audio    = $null   # the default output, as ConvertTo-JuicerAudioInfo gives it; null = no device
        AudioHelper = @{ Installed = $false; Running = $false }   # the low-latency task and its script
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
            # The timeout is for the real backend; a fake run never hangs.
            param($File, $Arguments, $TimeoutSec)
            $null = $TimeoutSec
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
        AppxRead    = {
            param($Name)
            $a = $script:Mem.Appx[$Name]
            if ($null -eq $a) { return $null }
            @{ Installed = $a.Installed; Provisioned = $a.Provisioned }
        }
        AppxRemove  = { param($Name) $script:Mem.Appx.Remove($Name) }
        # Like the Store: it comes back for the user, not as a provisioned package.
        AppxAdd     = {
            param($Name, $StoreId)
            if (-not $StoreId) { throw "$Name no tiene identificador de Microsoft Store." }
            [void]$script:Mem.Calls.Add("winget install --id $StoreId --source msstore")
            $script:Mem.Appx[$Name] = @{ Installed = $true; Provisioned = $false }
        }
        NetAdapters = { , @($script:Mem.Adapters) }
        NetAdaptersAll = { , @($script:Mem.Adapters) }
        DnsProbe    = { param($Server) $script:Mem.DnsDown -notcontains $Server }
        FwRules     = { param($Names) , @($Names | ForEach-Object { $script:Mem.Firewall[$_] } | Where-Object { $_ }) }
        FwSet       = {
            param($Rule, $Group, [switch]$Disabled)
            $script:Mem.Firewall[$Rule.Name] = @{
                Name = $Rule.Name; Group = $Group; Title = $Rule.Title; Enabled = -not $Disabled; Action = 'Block'; Direction = 'Outbound'; Profile = 'Any'
                Protocol = $Rule.Protocol; RemotePort = @($Rule.Port); LocalPort = @('Any'); RemoteAddress = @($Rule.Remote); LocalAddress = @('Any')
                Program = 'Any'; Service = 'Any'; InterfaceType = 'Any'
            }
        }
        FwState     = { @{ Off = @($script:Mem.FwOff); ThirdParty = [bool]$script:Mem.FwThirdParty } }
        FwOn        = { param($Profiles) foreach ($p in @($Profiles)) { $script:Mem.FwOff.Remove($p) } }
        HostsRead   = { $script:Mem.Hosts }
        HostsWrite  = { param($Text) $script:Mem.Hosts = $Text }
        DnsRoute    = { $script:Mem.Route }
        ResolveName = {
            param($Name, $Server)
            $k = "$Name|$Server"
            if (-not $script:Mem.Resolve.ContainsKey($k)) { return @{ Ips = @(); Error = 'sin respuesta'; NxDomain = $false } }
            $v = $script:Mem.Resolve[$k]
            if ($v -eq 'NXDOMAIN') { return @{ Ips = @(); Error = 'no existe'; NxDomain = $true } }
            @{ Ips = @($v); Error = ''; NxDomain = $false }
        }
        Browsers    = { , @($script:Mem.Browsers) }
        PolicyRefresh = { [void]$script:Mem.Calls.Add('RefreshPolicyEx') }
        DnsFlush    = { [void]$script:Mem.Calls.Add('Clear-DnsClientCache') }
        # What Windows does: the static servers live in NameServer, empty when
        # they come from DHCP.
        DnsSet      = {
            param($Interface, $V4, $V6)
            Write-MemRegValue "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$Interface" 'NameServer' 'String' (@($V4) -join ',')
            Write-MemRegValue "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip6\Parameters\Interfaces\$Interface" 'NameServer' 'String' (@($V6) -join ',')
        }
        FeatRead    = {
            param($Name)
            $f = $script:Mem.Features[$Name]
            if ($null -eq $f) { return $null }
            @{ Enabled = $f.Enabled }
        }
        FeatSet     = { param($Name, $Enabled) $script:Mem.Features[$Name].Enabled = [bool]$Enabled }
        # FpsBackend is the engine in use; FpsEngines, what the PC has
        # (by default just that one), to switch between them.
        FpsBackend  = {
            $all = @(if ($null -ne $script:Mem.FpsEngines) { $script:Mem.FpsEngines } elseif ($script:Mem.FpsBackend) { $script:Mem.FpsBackend })
            $want = Get-JuicerPacerEngine
            if ($all -contains $want) { $want } else { $script:Mem.FpsBackend }
        }
        FpsEngines  = { @(if ($null -ne $script:Mem.FpsEngines) { $script:Mem.FpsEngines } elseif ($script:Mem.FpsBackend) { $script:Mem.FpsBackend }) }
        FpsReset    = { }
        FpsRead     = {
            param($Exe, $Backend)
            $by = if ($Backend) { $Backend } else { & (Get-JuicerBackend).FpsBackend }
            if (-not $by -or @(& (Get-JuicerBackend).FpsEngines) -notcontains $by) { return $null }
            $has = $script:Mem.FpsLimits.ContainsKey($Exe)
            $v = if ($has) { [int]$script:Mem.FpsLimits[$Exe] } else { 0 }
            @{ Backend = $by; Fps = $(if ($v -gt 0) { $v } else { $null }); Exact = [double]$script:Mem.FpsExact[$Exe]; Existed = $has }
        }
        FpsWrite    = {
            param($Exe, $Fps, $Backend, [switch]$Remove, [double]$Exact = 0)
            if (@(& (Get-JuicerBackend).FpsEngines) -notcontains $Backend) { throw "Motor del frame pacer $Backend no disponible" }
            if ($Remove) { $script:Mem.FpsLimits.Remove($Exe) } else { $script:Mem.FpsLimits[$Exe] = $(if ($Fps) { [int]$Fps } else { 0 }) }
            if ($Exact -gt 0 -and $Backend -eq 'rtss' -and -not $Remove) { $script:Mem.FpsExact[$Exe] = $Exact } else { $script:Mem.FpsExact.Remove($Exe) }
        }
        NvRead      = {
            param($Exe, $Id)
            if (@(& (Get-JuicerBackend).FpsEngines) -notcontains 'nvidia') { return $null }
            $k = '{0}|{1}' -f $Exe, [uint32]$Id
            @{
                Value = $(if ($script:Mem.NvSettings.ContainsKey($k)) { [uint32]$script:Mem.NvSettings[$k] } else { $null })
                Predefined = $(if ($script:Mem.NvPredefined.ContainsKey($k)) { [uint32]$script:Mem.NvPredefined[$k] } else { $null })
            }
        }
        NvWrite     = {
            param($Exe, $Id, $Value)
            $k = '{0}|{1}' -f $Exe, [uint32]$Id
            if ($null -eq $Value) { $script:Mem.NvSettings.Remove($k) } else { $script:Mem.NvSettings[$k] = [uint32]$Value }
        }
        NvBackup    = {
            param($Dest)
            [void]$script:Mem.Calls.Add("nv-backup $Dest")
            $names = @()
            foreach ($n in @($script:Mem.NvDrsFiles.Keys | Sort-Object)) {
                [IO.File]::WriteAllText((Join-Path $Dest $n), [string]$script:Mem.NvDrsFiles[$n])
                $names += $n
            }
            $names
        }
        NvRestore   = {
            param($Source)
            [void]$script:Mem.Calls.Add("nv-restore $Source")
            $names = @()
            foreach ($f in @(Get-ChildItem -LiteralPath $Source -Filter 'nvdrsdb*.bin' -File)) {
                $script:Mem.NvDrsFiles[$f.Name] = [IO.File]::ReadAllText($f.FullName)
                $names += $f.Name
            }
            $names
        }
        PacerState  = { $script:Mem.Pacer }
        ProcRunning = { param($Exe) $script:Mem.Running -contains (ConvertTo-JuicerExeName $Exe) }
        AppIncidents = { param($Since) , @($script:Mem.Incidents | Where-Object { [datetime]$_.Time -ge $Since }) }
        PowerStatus = { $script:Mem.Power }
        Drivers     = { , @($script:Mem.Drivers) }
        MemoryState = { $script:Mem.MemoryState }
        MemCompressionGet = { $script:Mem.Compression }
        MemCompressionSet = { param([bool]$On) $script:Mem.Compression = $On }
        Responsiveness = { $script:Mem.Responsiveness }
        PowerModeGet = { $script:Mem.PowerMode }
        PowerModeSet = { param([string]$Scheme) [void]$script:Mem.Calls.Add("powermode $Scheme"); $script:Mem.PowerMode = $Scheme }
        AudioInfo   = { $script:Mem.Audio }
        AudioHelperState = { @{ Installed = [bool]$script:Mem.AudioHelper.Installed; Running = [bool]$script:Mem.AudioHelper.Running } }
        AudioHelperInstall = {
            [void]$script:Mem.Calls.Add('audio-helper install')
            $script:Mem.AudioHelper.Installed = $true
            $script:Mem.AudioHelper.Running = $true
        }
        AudioHelperRemove = {
            [void]$script:Mem.Calls.Add('audio-helper remove')
            $script:Mem.AudioHelper.Installed = $false
            $script:Mem.AudioHelper.Running = $false
        }
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
# -TimeoutSec: seconds before the tool is killed (default 30, 0 = no limit).
function Invoke-JuicerNative { param([string]$File, [string[]]$Arguments = @(), [int]$TimeoutSec = 30) & (Get-JuicerBackend).Run $File $Arguments $TimeoutSec }
