# DNS servers and the network fixes. A DNS server does not lower ping (see
# «Lo que no hacemos»); what one buys is privacy from the operator, blocking
# of malware or ads, or simply working when the operator's does not. The
# change is per physical adapter, journalled, and undoing it puts back what
# each adapter had, DHCP or not.

$script:DnsProviders = [ordered]@{
    Automatico      = @{ Title = 'Automático (el de tu router u operador)'; V4 = @(); V6 = @(); What = 'Vuelve a los servidores que da el router por DHCP.' }
    Cloudflare      = @{ Title = 'Cloudflare'; V4 = @('1.1.1.1', '1.0.0.1'); V6 = @('2606:4700:4700::1111', '2606:4700:4700::1001'); What = 'Rápido y sin filtrar nada; no guarda tu IP más de 24 horas.' }
    CloudflareMalware = @{ Title = 'Cloudflare, bloquea malware'; V4 = @('1.1.1.2', '1.0.0.2'); V6 = @('2606:4700:4700::1112', '2606:4700:4700::1002'); What = 'Como Cloudflare, pero no resuelve dominios conocidos de malware y phishing.' }
    CloudflareFamilia = @{ Title = 'Cloudflare, bloquea malware y adultos'; V4 = @('1.1.1.3', '1.0.0.3'); V6 = @('2606:4700:4700::1113', '2606:4700:4700::1003'); What = 'Además bloquea contenido para adultos.' }
    Google          = @{ Title = 'Google'; V4 = @('8.8.8.8', '8.8.4.4'); V6 = @('2001:4860:4860::8888', '2001:4860:4860::8844'); What = 'Fiable y sin filtrar nada.' }
    Quad9           = @{ Title = 'Quad9, bloquea malware'; V4 = @('9.9.9.9', '149.112.112.112'); V6 = @('2620:fe::fe', '2620:fe::9'); What = 'Fundación sin ánimo de lucro con sede en Suiza; bloquea dominios maliciosos.' }
    AdGuard         = @{ Title = 'AdGuard, bloquea anuncios'; V4 = @('94.140.14.14', '94.140.15.15'); V6 = @('2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff'); What = 'Bloquea anuncios y rastreadores en todo el equipo, incluidos juegos y apps. Alguna web puede fallar.' }
    AdGuardFamilia  = @{ Title = 'AdGuard Familia'; V4 = @('94.140.14.15', '94.140.15.16'); V6 = @('2a10:50c0::bad1:ff', '2a10:50c0::bad2:ff'); What = 'Anuncios, rastreadores y contenido para adultos.' }
    OpenDNS         = @{ Title = 'OpenDNS (Cisco)'; V4 = @('208.67.222.222', '208.67.220.220'); V6 = @('2620:119:35::35', '2620:119:53::53'); What = 'De Cisco, con bloqueo de phishing.' }
}

function Get-JuicerDnsProviders { $script:DnsProviders }

function Get-JuicerNetAdapterList {
    $a = & (Get-JuicerBackend).NetAdapters
    @($a | Where-Object { $_ })
}

function New-JuicerDnsTweak {
    param([Parameter(Mandatory)][string]$Provider)
    $p = $script:DnsProviders[$Provider]
    if (-not $p) { throw "Proveedor de DNS desconocido: $Provider. Usa: $(@($script:DnsProviders.Keys) -join ', ')." }
    $adapters = Get-JuicerNetAdapterList
    @{
        Id = 'red.dns'; Category = 'Red'; Level = 1; Impact = 'Bajo'; Reboot = 'No'
        Title = "DNS: $($p.Title)"
        What = "$($p.What) Se aplica a los adaptadores de red físicos conectados: $(@($adapters | ForEach-Object { $_.Name }) -join ', ')."
        Gain = 'Privacidad frente a tu operador, filtrado de malware o anuncios, o simplemente un DNS que no falla. No baja el ping: el DNS sólo se consulta al conectar.'
        Cost = 'Las redes de empresa o de hotel con portal de acceso pueden necesitar el DNS automático: si una no conecta, deshazlo.'
        Actions = @(foreach ($a in $adapters) {
                @{ Type = 'Dns'; Interface = $a.Guid; Adapter = $a.Name; V4 = $p.V4; V6 = $p.V6 }
            })
    }
}

# Which provider each adapter is using now, by its servers.
function Get-JuicerCurrentDns {
    foreach ($a in (Get-JuicerNetAdapterList)) {
        $cur = Get-JuicerDnsServers $a.Guid
        $match = 'Otro'
        foreach ($k in $script:DnsProviders.Keys) {
            $p = $script:DnsProviders[$k]
            if ((Test-JuicerListEqual $cur.V4 $p.V4) -and ($cur.V6.Count -eq 0 -or (Test-JuicerListEqual $cur.V6 $p.V6))) { $match = $k; break }
        }
        @{ Adapter = $a.Name; V4 = $cur.V4; V6 = $cur.V6; Provider = $match }
    }
}

# --- Fixes: not reversible, and not needed to be ------------------------------

# What Settings > Network reset does, without removing the adapters: rebuilds
# Winsock and the TCP/IP stack. Cures «connected but no internet» left by
# VPNs and old firewalls.
function Invoke-JuicerNetworkReset {
    $out = @()
    foreach ($cmd in @(@('netsh.exe', @('winsock', 'reset')), @('netsh.exe', @('int', 'ip', 'reset')), @('ipconfig.exe', @('/flushdns')))) {
        $r = Invoke-JuicerNative $cmd[0] $cmd[1]
        $out += @{ Step = ($cmd[0] + ' ' + ($cmd[1] -join ' ')); Ok = ($r.Code -eq 0); Output = $r.Output }
    }
    Write-JuicerLog ('Red restablecida: ' + (($out | ForEach-Object { '{0} {1}' -f $_.Step, $_.Ok }) -join '; '))
    $out
}

# Windows Update stuck downloading or failing with the same error: stop its
# services, set aside its cache and signatures folder, start again. The old
# folders are renamed, not deleted.
function Invoke-JuicerUpdateReset {
    $services = 'wuauserv', 'bits', 'cryptsvc', 'msiserver'
    $out = @()
    foreach ($s in $services) {
        try { Stop-Service -Name $s -Force -ErrorAction Stop; $out += @{ Step = "Detener $s"; Ok = $true } } catch { $out += @{ Step = "Detener $s"; Ok = $false; Output = "$_" } }
    }
    $stamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
    foreach ($dir in @((Join-Path $env:SystemRoot 'SoftwareDistribution'), (Join-Path $env:SystemRoot 'System32\catroot2'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        try {
            Rename-Item -LiteralPath $dir -NewName ((Split-Path -Leaf $dir) + ".old-$stamp") -ErrorAction Stop
            $out += @{ Step = "Apartar $dir"; Ok = $true }
        } catch {
            $out += @{ Step = "Apartar $dir"; Ok = $false; Output = "$_" }
        }
    }
    foreach ($s in $services) {
        try { Start-Service -Name $s -ErrorAction Stop } catch { Write-JuicerLog "No se pudo arrancar ${s}: $_" }
    }
    Write-JuicerLog ('Windows Update restablecido: ' + (($out | ForEach-Object { '{0} {1}' -f $_.Step, $_.Ok }) -join '; '))
    $out
}
