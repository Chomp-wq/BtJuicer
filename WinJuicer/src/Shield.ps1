# Protección contra contenido adulto. A filter that, once its owner turns it
# on, Win Juicer does not turn off: a choice made once, on purpose and after
# two confirmations, to stay away from that content (or for a child's PC).
# There is no button and no function that undoes it, «Deshacer todo» leaves
# it alone, the DNS chooser is locked while it is on, and a task puts back
# whatever gets changed. It hides nothing: Win Juicer says it is on and
# since when. Whoever administers the PC can still take it apart by hand; no
# program can stop that, and Win Juicer does not try (no hiding, no fighting
# the system).
#
# Nothing filters on the PC itself, so nothing slows down:
#   DNS        CleanBrowsing's Adult Filter on every physical adapter, IPv4
#              and IPv6: adult domains go nowhere, for every browser, app and
#              game, from lists they keep up to date; Reddit, YouTube and VPN
#              sites are left alone. A lookup costs what it costs with any
#              public DNS, and Windows keeps the answers. If CleanBrowsing
#              does not answer, Cloudflare for Families until it does: never
#              an unfiltered one, and never no internet.
#   Browsers   Chrome, Edge and Brave: their own DNS-over-HTTPS off by policy,
#              so they ask the filtered DNS, with Google SafeSearch and
#              YouTube's Restricted Mode (moderate) forced, and in Edge,
#              Bing's strict SafeSearch. Firefox: its own DNS off and locked.
#   The task   As SYSTEM, at startup, at sign-in, when a network connects and
#              every 30 minutes, at low priority. What is already in place is
#              left as it is, so it costs nothing.

$script:ShieldKey = 'HKLM\SOFTWARE\WinJuicer\Proteccion'
$script:ShieldTask = 'Win Juicer - Protección contra contenido adulto'

$script:ShieldDns = [ordered]@{
    CleanBrowsing = @{ Title = 'CleanBrowsing, filtro de adultos'; V4 = @('185.228.168.10', '185.228.169.11'); V6 = @('2a0d:2a00:1::1', '2a0d:2a00:2::1') }
    Cloudflare    = @{ Title = 'Cloudflare para familias'; V4 = @('1.1.1.3', '1.0.0.3'); V6 = @('2606:4700:4700::1113', '2606:4700:4700::1003') }
}

$script:ShieldPolicies = @(
    foreach ($browser in @(
            @{ Name = 'Chrome'; Path = 'HKLM\SOFTWARE\Policies\Google\Chrome' }
            @{ Name = 'Edge'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; Bing = $true }
            @{ Name = 'Brave'; Path = 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' }
        )) {
        @{ Type = 'Registry'; Path = $browser.Path; Name = 'DnsOverHttpsMode'; Kind = 'String'; Value = 'off'; Label = "$($browser.Name): sin DNS cifrado propio (usa el filtrado)" }
        @{ Type = 'Registry'; Path = $browser.Path; Name = 'ForceGoogleSafeSearch'; Kind = 'DWord'; Value = 1; Label = "$($browser.Name): búsqueda segura de Google" }
        @{ Type = 'Registry'; Path = $browser.Path; Name = 'ForceYouTubeRestrict'; Kind = 'DWord'; Value = 1; Label = "$($browser.Name): modo restringido de YouTube (moderado)" }
        if ($browser.Bing) { @{ Type = 'Registry'; Path = $browser.Path; Name = 'ForceBingSafeSearch'; Kind = 'DWord'; Value = 2; Label = "$($browser.Name): búsqueda segura estricta de Bing" } }
    }
    @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Enabled'; Kind = 'DWord'; Value = 0; Label = 'Firefox: sin DNS cifrado propio (usa el filtrado)' }
    @{ Type = 'Registry'; Path = 'HKLM\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS'; Name = 'Locked'; Kind = 'DWord'; Value = 1; Label = 'Firefox: esa opción, bloqueada' }
)

# Whether it is on: a mark in HKLM, which only an administrator can change.
function Test-JuicerShield {
    $v = Read-JuicerReg $script:ShieldKey 'Activada'
    [bool]($v -and [int]$v.Value -eq 1)
}

function Get-JuicerShieldInfo {
    $since = Read-JuicerReg $script:ShieldKey 'Desde'
    $dns = Read-JuicerReg $script:ShieldKey 'Dns'
    $key = if ($dns -and $script:ShieldDns.Contains([string]$dns.Value)) { [string]$dns.Value } else { 'CleanBrowsing' }
    @{ Active = (Test-JuicerShield); Since = $(if ($since) { [string]$since.Value } else { '' }); Provider = $key; ProviderTitle = $script:ShieldDns[$key].Title }
}

# The adapters it covers: every physical one, connected or not, so that a
# Wi-Fi that connects later is filtered from the start. Virtual ones (VPNs,
# virtual machines) are left alone: setting their DNS breaks them.
function Get-JuicerShieldAdapters {
    $b = Get-JuicerBackend
    $list = if ($b.NetAdaptersAll) { & $b.NetAdaptersAll } else { & $b.NetAdapters }
    @($list | Where-Object { $_ })
}

# The filtered DNS for now: CleanBrowsing while one of its servers answers;
# if none does and Cloudflare for Families does, that one; with no answer
# from any (no network yet), CleanBrowsing.
function Select-JuicerShieldDns {
    $b = Get-JuicerBackend
    if (-not $b.DnsProbe) { return 'CleanBrowsing' }
    foreach ($k in $script:ShieldDns.Keys) {
        foreach ($ip in $script:ShieldDns[$k].V4) {
            $up = $false
            try { $up = [bool](& $b.DnsProbe $ip) } catch { Write-JuicerLog "Protección: $ip no responde: $_" }
            if ($up) { return $k }
        }
    }
    'CleanBrowsing'
}

# Every part in place; what already is stays as it is, so the task running
# every half hour costs nothing. Returns what it had to put back, in words.
function Repair-JuicerShield {
    if (-not (Test-JuicerShield)) { return @() }
    $b = Get-JuicerBackend
    $fixed = @()
    $key = Select-JuicerShieldDns
    $dns = $script:ShieldDns[$key]
    $was = Read-JuicerReg $script:ShieldKey 'Dns'
    if (-not $was -or [string]$was.Value -ne $key) { Write-JuicerReg $script:ShieldKey 'Dns' 'String' $key }
    foreach ($a in (Get-JuicerShieldAdapters)) {
        $has = Get-JuicerDnsServers $a.Guid
        $v6 = $a.Ipv6 -ne $false
        if ((Test-JuicerListEqual $has.V4 $dns.V4) -and (-not $v6 -or (Test-JuicerListEqual $has.V6 $dns.V6))) { continue }
        try {
            & $b.DnsSet $a.Guid $dns.V4 $(if ($v6) { $dns.V6 } else { @() })
        } catch {
            # An adapter that will not take the IPv6 ones gets the IPv4 ones.
            try { & $b.DnsSet $a.Guid $dns.V4 @() } catch { Write-JuicerLog "Protección: no se pudo poner el DNS en $($a.Name): $_"; continue }
        }
        $fixed += "DNS filtrado ($($dns.Title)) en $($a.Name)"
    }
    foreach ($p in $script:ShieldPolicies) {
        if (Test-JuicerAction $p) { continue }
        Invoke-JuicerAction $p @{}
        $fixed += $p.Label
    }
    if ($b.Name -eq 'Windows') {
        try {
            if (-not (Test-JuicerShieldTask)) { Register-JuicerShieldTask; $fixed += 'La tarea que la mantiene' }
        } catch {
            Write-JuicerLog "Protección: no se pudo crear su tarea: $_"
        }
    }
    if ($fixed.Count -gt 0) { Write-JuicerLog ('Protección puesta al día: ' + ($fixed -join '; ')) }
    $fixed
}

# Turns it on: the mark first, so that even a start cut halfway is finished
# by the task or the next time Win Juicer opens; then every part. There is
# no function that turns it off: that is the point of it.
function Enable-JuicerShield {
    if (-not (Test-JuicerShield)) {
        Write-JuicerReg $script:ShieldKey 'Activada' 'DWord' 1
        Write-JuicerReg $script:ShieldKey 'Desde' 'String' ((Get-Date).ToString('s'))
        Write-JuicerLog 'Protección contra contenido adulto activada'
    }
    @(Repair-JuicerShield)
}

function Test-JuicerShieldTask {
    if (-not (Test-JuicerWindows)) { return $false }
    $null -ne (Get-ScheduledTask -TaskName $script:ShieldTask -ErrorAction SilentlyContinue)
}

# As SYSTEM, from the copy in Program Files that only an administrator can
# change: at startup, at sign-in, when a network connects (a new Wi-Fi, a
# network reset) and every 30 minutes, at the lowest priority a task gets.
function Register-JuicerShieldTask {
    $dir = Install-JuicerCopy
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'WinJuicer.ps1')`" -ProteccionAdultos Mantener"
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup)
        (New-ScheduledTaskTrigger -AtLogOn)
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(30) -RepetitionInterval (New-TimeSpan -Minutes 30))
    )
    try {
        $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
        $net = New-CimInstance -CimClass $cls -ClientOnly
        $net.Enabled = $true
        $net.Subscription = '<QueryList><Query Id="0" Path="Microsoft-Windows-NetworkProfile/Operational"><Select Path="Microsoft-Windows-NetworkProfile/Operational">*[System[(EventID=10000)]]</Select></Query></QueryList>'
        $triggers += $net
    } catch {
        Write-JuicerLog "Protección: sin el aviso de red conectada (queda la media hora): $_"
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 7 -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    Register-ScheduledTask -TaskName $script:ShieldTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description 'Mantiene la protección contra contenido adulto activada en Win Juicer: DNS filtrado y búsqueda segura. Se activa una vez y no se desactiva desde Win Juicer.' -Force | Out-Null
    Write-JuicerLog "Protección: tarea creada ($dir)"
}

# What it does and costs, said before turning it on, in the window and in the console.
function Get-JuicerShieldExplanation {
    @(
        'Bloquea las webs para adultos en todo el equipo, en cualquier navegador, app o juego, con el DNS filtrado de CleanBrowsing, y obliga a la búsqueda segura de Google y Bing y al modo restringido de YouTube en Chrome, Edge y Brave. No filtra nada en tu PC: las webs cargan igual de rápido, y Reddit, YouTube y las VPN siguen funcionando.'
        'Es para siempre: una vez activada, Win Juicer no te deja desactivarla. No hay botón para quitarla, «Deshacer todo» no la toca, el DNS queda fijo y, si algo la cambia, una tarea la vuelve a poner sola.'
        'Lo que no puede: ver dentro de redes sociales o apps que sirven ese contenido desde sus propios dominios, ni impedir una VPN. En Firefox bloquea las webs, pero no obliga a la búsqueda segura. Chrome y Edge dirán que «los administra tu organización»: son estas reglas.'
    )
}
