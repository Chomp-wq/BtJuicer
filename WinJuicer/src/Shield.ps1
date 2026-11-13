# Protección contra contenido adulto. A filter that, once its owner turns it
# on, Win Juicer does not turn off: a choice made once, on purpose and after
# two confirmations, to stay away from that content (an addiction, or a
# child's PC). There is no button and no function that undoes it or lowers its
# level, «Deshacer todo» leaves it alone, the DNS chooser is locked while it is
# on, and a task puts back whatever gets changed. It hides nothing: Win Juicer
# says it is on, at which level and since when. Whoever administers the PC can
# still take it apart by hand; no program can stop that, and Win Juicer does
# not try (no hiding, no fighting other software).
#
# Two levels, and it only goes up:
#   Equilibrada  CleanBrowsing's Adult Filter, and the usual ways around it
#                closed. Reddit, VPNs and private windows keep working.
#   Estricta     CleanBrowsing's Family Filter, which also blocks proxies,
#                VPNs and mixed sites such as Reddit; YouTube strict; no
#                private or guest windows and no browser proxy; and the DNS
#                can only go to the filter. The one for an addiction.
#
# Nothing filters on the PC itself, so nothing slows down:
#   DNS        The filter on every physical adapter, IPv4 and IPv6: adult
#              domains go nowhere, for every browser, app and game. If
#              CleanBrowsing does not answer, Cloudflare for Families until it
#              does: never an unfiltered one, and never no internet.
#   Firewall   Windows' own, so that changing the DNS is no way around it: DNS
#              to the public resolvers (at the strict level, to anything but
#              the filter), DNS over TLS and QUIC, and DNS over HTTPS to the
#              public resolvers, blocked. Six rules: free.
#   Browsers   Chrome, Edge, Brave and Firefox: their own DNS over HTTPS off
#              by policy, SafeSearch and YouTube's Restricted Mode forced, and
#              at the strict level no private or guest windows, no proxy, and
#              no Tor or VPN of their own. Windows' search: SafeSearch strict.
#   hosts      A block of lines: Opera's built-in VPN, and the sites the owner
#              blocks for good (X, Reddit, Tumblr or any other). A line added
#              later that points a name at a public address, the quickest way
#              around a DNS filter, is turned into a comment.
#   The task   As SYSTEM, at startup, at sign-in, when a network connects,
#              when the firewall changes and every 15 minutes, at low priority.
#              What is already in place is left as it is.

$script:ShieldKey = 'HKLM\SOFTWARE\WinJuicer\Proteccion'
$script:ShieldTask = 'Win Juicer - Protección contra contenido adulto'
# Raised when the task changes: an older one is registered again.
$script:ShieldTaskVersion = 2
$script:ShieldFwGroup = 'Win Juicer - Protección contra contenido adulto'

$script:ShieldDns = [ordered]@{
    CleanBrowsingFamilia = @{ Title = 'CleanBrowsing, filtro familiar'; V4 = @('185.228.168.168', '185.228.169.168'); V6 = @('2a0d:2a00:1::', '2a0d:2a00:2::'); Phone = 'family-filter-dns.cleanbrowsing.org' }
    CleanBrowsing        = @{ Title = 'CleanBrowsing, filtro de adultos'; V4 = @('185.228.168.10', '185.228.169.11'); V6 = @('2a0d:2a00:1::1', '2a0d:2a00:2::1'); Phone = 'adult-filter-dns.cleanbrowsing.org' }
    Cloudflare           = @{ Title = 'Cloudflare para familias'; V4 = @('1.1.1.3', '1.0.0.3'); V6 = @('2606:4700:4700::1113', '2606:4700:4700::1003'); Phone = 'family.cloudflare-dns.com' }
}

$script:ShieldLevels = @{
    1 = @{ Title = 'Equilibrada'; Dns = @('CleanBrowsing', 'Cloudflare') }
    2 = @{ Title = 'Estricta'; Dns = @('CleanBrowsingFamilia', 'Cloudflare') }
}

# Public resolvers that answer anything: setting one as the DNS, or asking one
# over HTTPS, is the quickest way around the filter. Only addresses that serve
# nothing but DNS, so closing them takes nothing else away. None of them
# filters adult content (the family ones are not here).
$script:ShieldOpenResolvers = @(
    # Google
    '8.8.8.8', '8.8.4.4', '2001:4860:4860::8888', '2001:4860:4860::8844'
    # Cloudflare, without a filter and malware only. Not the addresses its
    # DNS over HTTPS has had for browsers: they move, and may be serving
    # websites by now (the browsers' own is off by policy anyway).
    '1.1.1.1', '1.0.0.1', '1.1.1.2', '1.0.0.2'
    '2606:4700:4700::1111', '2606:4700:4700::1001', '2606:4700:4700::1112', '2606:4700:4700::1002'
    # Quad9
    '9.9.9.9', '149.112.112.112', '9.9.9.10', '149.112.112.10', '9.9.9.11', '149.112.112.11'
    '2620:fe::fe', '2620:fe::9', '2620:fe::10', '2620:fe::fe:10', '2620:fe::11', '2620:fe::fe:11'
    # OpenDNS, and its DNS over HTTPS
    '208.67.222.222', '208.67.220.220', '208.67.222.220', '208.67.220.222', '146.112.41.2'
    '2620:119:35::35', '2620:119:53::53', '2620:119:fc::2'
    # AdGuard, the default and the unfiltered one
    '94.140.14.14', '94.140.15.15', '94.140.14.140', '94.140.14.141'
    '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff', '2a10:50c0::1:ff', '2a10:50c0::2:ff'
    # NextDNS, Control D and Mullvad: any of their filters, none too
    '45.90.28.0/24', '45.90.30.0/24', '76.76.2.0/24', '76.76.10.0/24', '194.242.2.0/24'
    # Level 3, DNS.SB, Comodo, Yandex, UltraDNS, Hurricane Electric, AliDNS,
    # DNSPod, TWNIC and CIRA
    '4.2.2.1', '4.2.2.2', '4.2.2.3', '4.2.2.4', '4.2.2.5', '4.2.2.6'
    '185.222.222.222', '45.11.45.11', '8.26.56.26', '8.20.247.20', '77.88.8.8', '77.88.8.1'
    '64.6.64.6', '64.6.65.6', '74.82.42.42', '223.5.5.5', '223.6.6.6', '1.12.12.12', '120.53.53.53'
    '101.101.101.101', '149.112.121.10', '149.112.122.10'
)

# Opera's built-in VPN, one click away in its settings: without these names
# it does not connect.
$script:ShieldBypassHosts = @(
    'api.sec-tunnel.com', 'api2.sec-tunnel.com', 'api.surfeasy.com'
    'opera-proxy.net', 'de0.opera-proxy.net', 'eu0.opera-proxy.net', 'am0.opera-proxy.net', 'as0.opera-proxy.net'
)

# Brave Search, Brave's own default engine, serves result pictures from its
# own servers, where a DNS filter cannot see them; and Brave refuses any
# policy that changes its engine, so blocking it leaves Brave unable to search
# at all. Brave documents how a network forces its SafeSearch instead:
# search.brave.com answered as forcesafe.search.brave.com, leaving its other
# names (imgs., cdn.) alone. A hosts file cannot hold an alias, so it holds
# forcesafe's addresses, looked up again on every run; until they have been
# found once, search.brave.com is blocked.
$script:ShieldBraveSearchHost = 'search.brave.com'
$script:ShieldBraveSafeHost = 'forcesafe.search.brave.com'

# What an earlier version set to change Brave's engine. Brave blocks those
# policies and lists them as errors, so they go: nothing is lost by it.
$script:ShieldBraveIgnored = @('DefaultSearchProviderEnabled', 'DefaultSearchProviderName', 'DefaultSearchProviderKeyword', 'DefaultSearchProviderSearchURL', 'DefaultSearchProviderSuggestURL')

# A name every adult filter blocks, to see whether this PC is filtered.
$script:ShieldProbeName = 'pornhub.com'

# Sites that are not adult sites but carry a lot of it, blocked for good when
# the owner asks: each with the names its pages, pictures and videos use.
$script:ShieldPresets = [ordered]@{
    X      = @{ Title = 'X (Twitter)'; Hosts = @('x.com', 'www.x.com', 'mobile.x.com', 'api.x.com', 'pro.x.com', 'twitter.com', 'www.twitter.com', 'mobile.twitter.com', 'api.twitter.com', 'tweetdeck.twitter.com', 'pbs.twimg.com', 'video.twimg.com', 'abs.twimg.com') }
    Reddit = @{ Title = 'Reddit'; Hosts = @('reddit.com', 'www.reddit.com', 'old.reddit.com', 'new.reddit.com', 'np.reddit.com', 'm.reddit.com', 'i.reddit.com', 'sh.reddit.com', 'oauth.reddit.com', 'gateway.reddit.com', 'gql.reddit.com', 'gql-fed.reddit.com', 'redd.it', 'i.redd.it', 'v.redd.it', 'preview.redd.it', 'external-preview.redd.it', 'redditmedia.com', 'www.redditmedia.com', 'a.thumbs.redditmedia.com', 'b.thumbs.redditmedia.com', 'styles.redditmedia.com', 'emoji.redditmedia.com', 'redditstatic.com', 'www.redditstatic.com') }
    Tumblr = @{ Title = 'Tumblr'; Hosts = @('tumblr.com', 'www.tumblr.com', 'api.tumblr.com', 'assets.tumblr.com', 'static.tumblr.com', 'media.tumblr.com', '64.media.tumblr.com', 'va.media.tumblr.com', 'tumblr.co') }
}

$script:ShieldHostsBegin = '# >>> Win Juicer: proteccion contra contenido adulto (no editar)'
$script:ShieldHostsEnd = '# <<< Win Juicer: proteccion contra contenido adulto'
$script:ShieldHostsOff = '# Win Juicer (proteccion) la desactivo: '

$script:ShieldBrowsers = @(
    @{ Name = 'Chrome'; Path = 'HKLM\SOFTWARE\Policies\Google\Chrome'; Private = 'IncognitoModeAvailability' }
    @{ Name = 'Edge'; Path = 'HKLM\SOFTWARE\Policies\Microsoft\Edge'; Private = 'InPrivateModeAvailability'; Bing = $true }
    @{ Name = 'Brave'; Path = 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave'; Private = 'IncognitoModeAvailability'; Brave = $true }
)

# --- State -----------------------------------------------------------------

# Whether it is on: a mark in HKLM, which only an administrator can change.
function Test-JuicerShield {
    $v = Read-JuicerReg $script:ShieldKey 'Activada'
    [bool]($v -and [int]$v.Value -eq 1)
}

# 1 equilibrada, 2 estricta. Turned on before there were levels: equilibrada,
# which is what it was.
function Get-JuicerShieldLevel {
    $v = Read-JuicerReg $script:ShieldKey 'Nivel'
    if ($v -and [int]$v.Value -ge 2) { return 2 }
    1
}

function Get-JuicerShieldInfo {
    $level = Get-JuicerShieldLevel
    $active = Test-JuicerShield
    $since = Read-JuicerReg $script:ShieldKey 'Desde'
    $dns = Read-JuicerReg $script:ShieldKey 'Dns'
    $list = $script:ShieldLevels[$level].Dns
    $key = if ($dns -and $list -contains [string]$dns.Value) { [string]$dns.Value } else { $list[0] }
    # '' when the firewall does its part; Otro when another program has
    # turned Windows' off; Apagado until the task turns it back on.
    $fw = ''
    $b = Get-JuicerBackend
    if ($active -and $b.FwState) {
        try {
            $s = & $b.FwState
            if (@($s.Off).Count -gt 0) { $fw = $(if ($s.ThirdParty) { 'Otro' } else { 'Apagado' }) }
        } catch {
            Write-JuicerLog "Protección: sin el estado del cortafuegos: $_"
        }
    }
    @{
        Active = $active; Since = $(if ($since) { [string]$since.Value } else { '' })
        Level = $level; LevelTitle = $script:ShieldLevels[$level].Title
        Provider = $key; ProviderTitle = $script:ShieldDns[$key].Title; Phone = $script:ShieldDns[$key].Phone
        Blocked = (Get-JuicerShieldBlockedSummary); Firewall = $fw
    }
}

# The adapters it covers: every physical one, connected or not, so that a
# Wi-Fi that connects later is filtered from the start. Virtual ones (VPNs,
# virtual machines) are left alone: setting their DNS breaks them.
function Get-JuicerShieldAdapters {
    $b = Get-JuicerBackend
    $list = if ($b.NetAdaptersAll) { & $b.NetAdaptersAll } else { & $b.NetAdapters }
    @($list | Where-Object { $_ })
}

# The filtered DNS for now: the level's first while one of its servers
# answers; if none does and the next one does, that one; with no answer from
# any (no network yet), the first.
function Select-JuicerShieldDns {
    param([int]$Level = (Get-JuicerShieldLevel))
    $list = $script:ShieldLevels[$Level].Dns
    $b = Get-JuicerBackend
    if (-not $b.DnsProbe) { return $list[0] }
    foreach ($k in $list) {
        foreach ($ip in $script:ShieldDns[$k].V4) {
            $up = $false
            try { $up = [bool](& $b.DnsProbe $ip) } catch { Write-JuicerLog "Protección: $ip no responde: $_" }
            if ($up) { return $k }
        }
    }
    $list[0]
}

# The same addresses in the same order, however each is written (Windows may
# keep an IPv6 one in a form of its own): otherwise the task would set the
# DNS again on every run.
function Test-JuicerIpListEqual {
    param($A, $B)
    $x = @($A | Where-Object { $_ })
    $y = @($B | Where-Object { $_ })
    if ($x.Count -ne $y.Count) { return $false }
    for ($i = 0; $i -lt $x.Count; $i++) {
        $p = $null
        $q = $null
        if (-not [Net.IPAddress]::TryParse([string]$x[$i], [ref]$p) -or -not [Net.IPAddress]::TryParse([string]$y[$i], [ref]$q) -or -not $p.Equals($q)) { return $false }
    }
    $true
}

# --- Browsers and Windows' search ------------------------------------------------

# Edge's own VPN (Secure Network) has no policy of its own: Edge does not
# offer it once any policy manages it, as these do.

function Get-JuicerShieldPolicies {
    param([int]$Level = 2)
    $strict = $Level -ge 2
    foreach ($w in $script:ShieldBrowsers) {
        $n = $w.Name
        @{ Type = 'Registry'; Path = $w.Path; Name = 'DnsOverHttpsMode'; Kind = 'String'; Value = 'off'; Label = "${n}: sin DNS cifrado propio (usa el filtrado)" }
        @{ Type = 'Registry'; Path = $w.Path; Name = 'ForceGoogleSafeSearch'; Kind = 'DWord'; Value = 1; Label = "${n}: búsqueda segura de Google" }
        @{ Type = 'Registry'; Path = $w.Path; Name = 'ForceYouTubeRestrict'; Kind = 'DWord'; Value = $(if ($strict) { 2 } else { 1 }); Label = "${n}: modo restringido de YouTube ($(if ($strict) { 'estricto' } else { 'moderado' }))" }
        # Closing the window must close the browser: one left running in the
        # background keeps old DNS answers and old rules.
        @{ Type = 'Registry'; Path = $w.Path; Name = 'BackgroundModeEnabled'; Kind = 'DWord'; Value = 0; Label = "${n}: se cierra del todo al cerrarlo" }
        if ($w.Bing) { @{ Type = 'Registry'; Path = $w.Path; Name = 'ForceBingSafeSearch'; Kind = 'DWord'; Value = 2; Label = "${n}: búsqueda segura estricta de Bing" } }
        if ($w.Brave) {
            # A Tor window goes around any DNS filter, at either level.
            @{ Type = 'Registry'; Path = $w.Path; Name = 'TorDisabled'; Kind = 'DWord'; Value = 1; Label = "${n}: sin ventanas de Tor" }
        }
        if ($strict) {
            @{ Type = 'Registry'; Path = $w.Path; Name = $w.Private; Kind = 'DWord'; Value = 1; Label = "${n}: sin ventanas privadas" }
            @{ Type = 'Registry'; Path = $w.Path; Name = 'BrowserGuestModeEnabled'; Kind = 'DWord'; Value = 0; Label = "${n}: sin ventanas de invitado" }
            @{ Type = 'Registry'; Path = $w.Path; Name = 'ProxyMode'; Kind = 'String'; Value = 'direct'; Label = "${n}: sin proxy" }
            if ($w.Brave) {
                @{ Type = 'Registry'; Path = $w.Path; Name = 'BraveVPNDisabled'; Kind = 'DWord'; Value = 1; Label = "${n}: sin su VPN" }
            }
        }
    }
    $ff = 'HKLM\SOFTWARE\Policies\Mozilla\Firefox'
    @{ Type = 'Registry'; Path = "$ff\DNSOverHTTPS"; Name = 'Enabled'; Kind = 'DWord'; Value = 0; Label = 'Firefox: sin DNS cifrado propio (usa el filtrado)' }
    @{ Type = 'Registry'; Path = "$ff\DNSOverHTTPS"; Name = 'Locked'; Kind = 'DWord'; Value = 1; Label = 'Firefox: esa opción, bloqueada' }
    if ($strict) {
        @{ Type = 'Registry'; Path = $ff; Name = 'DisablePrivateBrowsing'; Kind = 'DWord'; Value = 1; Label = 'Firefox: sin ventanas privadas' }
        @{ Type = 'Registry'; Path = "$ff\Proxy"; Name = 'Mode'; Kind = 'String'; Value = 'none'; Label = 'Firefox: sin proxy' }
        @{ Type = 'Registry'; Path = "$ff\Proxy"; Name = 'Locked'; Kind = 'DWord'; Value = 1; Label = 'Firefox: el proxy, bloqueado' }
    }
}

# Windows' own search (the web results of the Start menu), for each user: the
# profiles loaded now, and the others when they sign in, since the task runs
# then.
function Get-JuicerShieldUserPolicies {
    foreach ($sid in (Get-JuicerRegChildren 'HKU')) {
        if ($sid -notmatch '^S-1-5-21-[\d-]+$') { continue }
        @{ Type = 'Registry'; Path = "HKU\$sid\Software\Microsoft\Windows\CurrentVersion\SearchSettings"; Name = 'SafeSearchMode'; Kind = 'DWord'; Value = 2; Label = 'Windows: búsqueda segura estricta en la búsqueda' }
    }
}

# --- Addresses ---------------------------------------------------------------------
#
# Firewall rules take addresses, ranges and subnets, and hand them back in a
# form of their own (a subnet as address/mask). Both sides become numbers to
# compare them: lists of { F = 4 or 6; S = first; E = last }, sorted and
# merged.

function ConvertTo-JuicerIpNumber {
    param([byte[]]$Bytes)
    # BigInteger wants little-endian, and a zero on top to stay positive.
    $le = New-Object byte[] ($Bytes.Length + 1)
    for ($i = 0; $i -lt $Bytes.Length; $i++) { $le[$i] = $Bytes[$Bytes.Length - 1 - $i] }
    New-Object System.Numerics.BigInteger (, $le)
}

function ConvertFrom-JuicerIpNumber {
    param([System.Numerics.BigInteger]$Number, [int]$Family)
    $size = if ($Family -eq 6) { 16 } else { 4 }
    $le = $Number.ToByteArray()
    $b = New-Object byte[] $size
    for ($i = 0; $i -lt [Math]::Min($size, $le.Length); $i++) { $b[$size - 1 - $i] = $le[$i] }
    if ($size -eq 4) { return (@($b | ForEach-Object { [string]$_ }) -join '.') }
    # RFC 5952, the same from every .NET: the longest run of zero groups (two
    # or more, the first if tied) becomes ::.
    $g = @(for ($i = 0; $i -lt 16; $i += 2) { ([int]$b[$i] * 256) + [int]$b[$i + 1] })
    $best = -1
    $bestLen = 1
    $i = 0
    while ($i -lt 8) {
        if ($g[$i] -ne 0) { $i++; continue }
        $j = $i
        while ($j -lt 8 -and $g[$j] -eq 0) { $j++ }
        if (($j - $i) -gt $bestLen) { $best = $i; $bestLen = $j - $i }
        $i = $j
    }
    $hex = @($g | ForEach-Object { '{0:x}' -f $_ })
    if ($best -lt 0) { return ($hex -join ':') }
    $left = if ($best -gt 0) { $hex[0..($best - 1)] -join ':' } else { '' }
    $end = $best + $bestLen
    $right = if ($end -lt 8) { $hex[$end..7] -join ':' } else { '' }
    "${left}::${right}"
}

# One address, range (a-b) or subnet (a/len or a/mask), or Any. Null for what
# is not one of those (LocalSubnet and the like).
function ConvertTo-JuicerAddressRange {
    param([string]$Text)
    $t = ([string]$Text).Trim()
    if ($t -eq 'Any' -or $t -eq '*') {
        return @(
            @{ F = 4; S = [bigint]0; E = [bigint]::Pow(2, 32) - 1 }
            @{ F = 6; S = [bigint]0; E = [bigint]::Pow(2, 128) - 1 }
        )
    }
    $parse = {
        param($s)
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($s.Trim(), [ref]$ip)) { return $null }
        @{ F = $(if ($ip.AddressFamily -eq 'InterNetworkV6') { 6 } else { 4 }); N = (ConvertTo-JuicerIpNumber $ip.GetAddressBytes()) }
    }
    if ($t.Contains('-')) {
        $p = $t.Split('-')
        if ($p.Count -ne 2) { return $null }
        $a = & $parse $p[0]
        $z = & $parse $p[1]
        if (-not $a -or -not $z -or $a.F -ne $z.F -or $a.N -gt $z.N) { return $null }
        return @(@{ F = $a.F; S = $a.N; E = $z.N })
    }
    if ($t.Contains('/')) {
        $p = $t.Split('/')
        if ($p.Count -ne 2) { return $null }
        $a = & $parse $p[0]
        if (-not $a) { return $null }
        $bits = if ($a.F -eq 6) { 128 } else { 32 }
        $len = 0
        if ($p[1].Contains('.')) {
            $m = & $parse $p[1]
            if (-not $m -or $m.F -ne 4) { return $null }
            $len = @([Convert]::ToString([int64]$m.N, 2).ToCharArray() | Where-Object { $_ -eq '1' }).Count
        } elseif (-not [int]::TryParse($p[1], [ref]$len)) {
            return $null
        }
        if ($len -lt 0 -or $len -gt $bits) { return $null }
        $span = [bigint]::Pow(2, $bits - $len)
        $first = [bigint]::Multiply([bigint]::Divide($a.N, $span), $span)
        return @(@{ F = $a.F; S = $first; E = $first + $span - 1 })
    }
    $a = & $parse $t
    if (-not $a) { return $null }
    @(@{ F = $a.F; S = $a.N; E = $a.N })
}

function ConvertTo-JuicerAddressSet {
    param([string[]]$Addresses)
    $all = @()
    foreach ($x in $Addresses) {
        $r = ConvertTo-JuicerAddressRange $x
        if ($null -eq $r) { return $null }
        $all += $r
    }
    $sorted = @($all | Sort-Object -Property @{ Expression = { $_.F } }, @{ Expression = { $_.S } })
    $out = New-Object System.Collections.ArrayList
    foreach ($r in $sorted) {
        $last = if ($out.Count -gt 0) { $out[$out.Count - 1] } else { $null }
        if ($last -and $last.F -eq $r.F -and $r.S -le ($last.E + 1)) {
            if ($r.E -gt $last.E) { $last.E = $r.E }
            continue
        }
        [void]$out.Add(@{ F = $r.F; S = $r.S; E = $r.E })
    }
    , $out.ToArray()
}

function Test-JuicerAddressSetEqual {
    param($A, $B)
    if (@($A).Count -ne @($B).Count) { return $false }
    for ($i = 0; $i -lt @($A).Count; $i++) {
        if ($A[$i].F -ne $B[$i].F -or $A[$i].S -ne $B[$i].S -or $A[$i].E -ne $B[$i].E) { return $false }
    }
    $true
}

# Everything but a set, family by family, as a set.
function Get-JuicerAddressComplement {
    param($Set)
    $out = @()
    foreach ($f in 4, 6) {
        $next = [bigint]0
        $top = [bigint]::Pow(2, $(if ($f -eq 6) { 128 } else { 32 })) - 1
        foreach ($r in @($Set | Where-Object { $_.F -eq $f })) {
            if ($r.S -gt $next) { $out += @{ F = $f; S = $next; E = $r.S - 1 } }
            if ($r.E + 1 -gt $next) { $next = $r.E + 1 }
        }
        if ($next -le $top) { $out += @{ F = $f; S = $next; E = $top } }
    }
    , $out
}

# A set back into what a firewall rule takes: addresses and ranges.
function ConvertFrom-JuicerAddressSet {
    param($Set)
    @($Set | ForEach-Object {
            $a = ConvertFrom-JuicerIpNumber $_.S $_.F
            if ($_.S -eq $_.E) { $a } else { $a + '-' + (ConvertFrom-JuicerIpNumber $_.E $_.F) }
        })
}

# --- Firewall ---------------------------------------------------------------------

# Where DNS may not go at a level. Equilibrada: the public resolvers, so that
# work VPNs and the network's own names keep working. Estricta: anywhere but
# the filter (both of the level's, for the fallback) and this PC.
function Get-JuicerShieldDnsBlock {
    param([int]$Level)
    if ($Level -lt 2) { return , @(ConvertFrom-JuicerAddressSet (ConvertTo-JuicerAddressSet $script:ShieldOpenResolvers)) }
    $allowed = @('0.0.0.0', '127.0.0.0/8', '::', '::1')
    foreach ($k in $script:ShieldLevels[$Level].Dns) { $allowed += @($script:ShieldDns[$k].V4) + @($script:ShieldDns[$k].V6) }
    , @(ConvertFrom-JuicerAddressSet (Get-JuicerAddressComplement (ConvertTo-JuicerAddressSet $allowed)))
}

function Get-JuicerShieldFwRules {
    param([int]$Level = 2)
    $dns = Get-JuicerShieldDnsBlock $Level
    $open = @(ConvertFrom-JuicerAddressSet (ConvertTo-JuicerAddressSet $script:ShieldOpenResolvers))
    $what = 'Protección contra contenido adulto de Win Juicer: se activa una vez y no se desactiva desde Win Juicer.'
    $dnsTitle = if ($Level -ge 2) { 'el DNS sólo va al filtro' } else { 'sin DNS públicos sin filtro' }
    @(
        @{ Name = 'WinJuicer-Proteccion-DNS-UDP'; Title = "Win Juicer: $dnsTitle (UDP)"; Protocol = 'UDP'; Port = '53'; Remote = $dns; Description = $what }
        @{ Name = 'WinJuicer-Proteccion-DNS-TCP'; Title = "Win Juicer: $dnsTitle (TCP)"; Protocol = 'TCP'; Port = '53'; Remote = $dns; Description = $what }
        @{ Name = 'WinJuicer-Proteccion-DoT'; Title = 'Win Juicer: sin DNS cifrado por TLS'; Protocol = 'TCP'; Port = '853'; Remote = @('Any'); Description = $what }
        @{ Name = 'WinJuicer-Proteccion-DoQ'; Title = 'Win Juicer: sin DNS cifrado por QUIC'; Protocol = 'UDP'; Port = '853'; Remote = @('Any'); Description = $what }
        @{ Name = 'WinJuicer-Proteccion-DoH-TCP'; Title = 'Win Juicer: sin DNS cifrado de servidores públicos (TCP)'; Protocol = 'TCP'; Port = '443'; Remote = $open; Description = $what }
        @{ Name = 'WinJuicer-Proteccion-DoH-UDP'; Title = 'Win Juicer: sin DNS cifrado de servidores públicos (UDP)'; Protocol = 'UDP'; Port = '443'; Remote = $open; Description = $what }
    )
}

# A rule as it should be: on, blocking, outbound, every profile, for every
# program and interface, and to exactly those addresses. Narrowing it to a
# program or an interface is as good as turning it off.
function Test-JuicerShieldFwRule {
    param($Want, $Have)
    if (-not $Have -or -not $Have.Enabled) { return $false }
    if ($Have.Action -ne 'Block' -or $Have.Direction -ne 'Outbound' -or $Have.Protocol -ne $Want.Protocol) { return $false }
    if ((@($Have.RemotePort) -join ',') -ne $Want.Port) { return $false }
    foreach ($k in 'Profile', 'LocalPort', 'LocalAddress', 'Program', 'Service', 'InterfaceType') {
        $v = @($Have[$k]) -join ','
        if ($v -and $v -ne 'Any') { return $false }
    }
    $a = ConvertTo-JuicerAddressSet $Want.Remote
    $h = ConvertTo-JuicerAddressSet $Have.RemoteAddress
    if ($null -eq $h) { return $false }
    Test-JuicerAddressSetEqual $a $h
}

# The rules in place and Windows' firewall on. When something keeps undoing
# them (another firewall, a group policy), they are written again at most
# every couple of minutes, not every time it does: that would be a fight.
# A third-party firewall that turned Windows' off is left in charge.
function Repair-JuicerShieldFirewall {
    param([int]$Level = (Get-JuicerShieldLevel))
    $b = Get-JuicerBackend
    $want = @(Get-JuicerShieldFwRules $Level)
    $have = @{}
    foreach ($r in (& $b.FwRules @($want | ForEach-Object { $_.Name }))) { if ($r) { $have[$r.Name] = $r } }
    $bad = @($want | Where-Object { -not (Test-JuicerShieldFwRule $_ $have[$_.Name]) })
    $state = $null
    try { $state = & $b.FwState } catch { Write-JuicerLog "Protección: sin el estado del cortafuegos: $_" }
    $off = @(if ($state -and -not $state.ThirdParty) { @($state.Off) | Where-Object { $_ } })
    $what = (@($bad | ForEach-Object { $_.Name }) + @($off | ForEach-Object { "perfil $_" })) -join ', '
    if (-not $what) { return }
    $sig = "${Level}: $what"
    $last = Read-JuicerReg $script:ShieldKey 'CortafuegosEscrito'
    if ($last) {
        $p = ([string]$last.Value).Split('|')
        $when = [datetime]::MinValue
        if ($p.Count -eq 2 -and $p[1] -eq $sig -and [datetime]::TryParse($p[0], [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$when) -and ((Get-Date) - $when).TotalMinutes -lt 2) {
            Write-JuicerLog "Protección: algo vuelve a cambiar el cortafuegos ($what); se repondrá en la próxima revisión"
            return
        }
    }
    Write-JuicerReg $script:ShieldKey 'CortafuegosEscrito' 'String' ((Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture) + '|' + $sig)
    foreach ($r in $bad) {
        try {
            & $b.FwSet $r $script:ShieldFwGroup
            "Cortafuegos: $($r.Title.Replace('Win Juicer: ', ''))"
        } catch {
            Write-JuicerLog "Protección: no se pudo poner la regla $($r.Name): $_"
        }
    }
    if ($off.Count -gt 0) {
        try {
            & $b.FwOn $off
            'Cortafuegos de Windows: encendido (lo necesitan sus bloqueos)'
        } catch {
            Write-JuicerLog "Protección: no se pudo encender el cortafuegos: $_"
        }
    }
}

# --- hosts ----------------------------------------------------------------------------

# Whether an address is out on the internet: not this PC, not the local
# network, not a placeholder such as 0.0.0.0.
function Test-JuicerPublicIp {
    param([string]$Ip)
    $a = $null
    if (-not [Net.IPAddress]::TryParse(([string]$Ip).Trim(), [ref]$a)) { return $false }
    if ($a.IsIPv4MappedToIPv6) { $a = $a.MapToIPv4() }
    $b = $a.GetAddressBytes()
    if ($b.Length -eq 4) {
        if ($b[0] -in 0, 10, 127 -or $b[0] -ge 224) { return $false }
        if ($b[0] -eq 100 -and $b[1] -ge 64 -and $b[1] -le 127) { return $false }
        if ($b[0] -eq 169 -and $b[1] -eq 254) { return $false }
        if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -le 31) { return $false }
        if ($b[0] -eq 192 -and $b[1] -eq 168) { return $false }
        return $true
    }
    if (@($b | Where-Object { $_ -ne 0 }).Count -eq 0) { return $false }
    if ($a.Equals([Net.IPAddress]::IPv6Loopback)) { return $false }
    if (($b[0] -band 0xfe) -eq 0xfc -or $b[0] -eq 0xff) { return $false }
    if ($b[0] -eq 0xfe -and ($b[1] -band 0xc0) -eq 0x80) { return $false }
    $true
}

# One line of the hosts file: @{ Ip; Names }, or null for a comment, a blank
# line or anything Windows would not read as an entry.
function ConvertFrom-JuicerHostsLine {
    param([string]$Line)
    $t = ([string]$Line -replace '#.*$', '').Trim()
    if (-not $t) { return $null }
    $p = @($t -split '\s+')
    $ip = $null
    if ($p.Count -lt 2 -or -not [Net.IPAddress]::TryParse($p[0], [ref]$ip)) { return $null }
    @{ Ip = $p[0].ToLowerInvariant(); Names = @($p[1..($p.Count - 1)] | ForEach-Object { $_.ToLowerInvariant() }) }
}

# «ip name» for every name the file sends to a public address: what was there
# before the protection, kept as it was.
function Get-JuicerHostsPublicEntries {
    param([string]$Text)
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        $e = ConvertFrom-JuicerHostsLine $line
        if (-not $e -or -not (Test-JuicerPublicIp $e.Ip)) { continue }
        foreach ($n in $e.Names) { "$($e.Ip) $n" }
    }
}

# The hosts file with the protection's part in it, as text: its block of lines
# at the end, rebuilt from the list; any other line that sends a name to a
# public address and was not there before the protection (or sends a blocked
# name anywhere public) turned into a comment. Lines pointing at this PC or
# the local network stay as they are. @{ Text; Disabled }.
function Update-JuicerShieldHosts {
    param([string]$Text, [string[]]$Previous = @(), [string[]]$Block = @(), [string[]]$Map = @())
    $prev = @{}
    foreach ($p in $Previous) { if ($p) { $prev[$p.ToLowerInvariant()] = $true } }
    $names = @($Block | Where-Object { $_ } | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)
    # «ip name» lines of its own, such as Brave Search's safe addresses.
    $maps = @($Map | Where-Object { $_ } | ForEach-Object { ($_.Trim() -replace '\s+', ' ').ToLowerInvariant() } | Select-Object -Unique)
    $mapped = @(@($maps | ForEach-Object { ($_ -split ' ')[1] }) + $script:ShieldBraveSearchHost | Select-Object -Unique)
    # Names that only its block may send anywhere.
    $guarded = @($names) + @($mapped)
    $ours = @{}
    foreach ($n in $names) { $ours["0.0.0.0 $n"] = $true; $ours[":: $n"] = $true }
    foreach ($m in $maps) { $ours[$m] = $true }
    $out = New-Object System.Collections.ArrayList
    $disabled = @()
    $inBlock = $false
    foreach ($line in @(([string]$Text) -split "`r?`n")) {
        $t = $line.Trim()
        if ($t -eq $script:ShieldHostsBegin) { $inBlock = $true; continue }
        if ($t -eq $script:ShieldHostsEnd) { $inBlock = $false; continue }
        $flat = ($t -replace '\s+', ' ').ToLowerInvariant()
        $e = ConvertFrom-JuicerHostsLine $line
        # Its own lines are rebuilt below, a mapped name's old addresses too.
        if ($inBlock -and ($t -eq '' -or $flat -match '^(0\.0\.0\.0|::) \S+$' -or ($e -and @($e.Names).Count -eq 1 -and $mapped -contains $e.Names[0]))) { continue }
        $inBlock = $false
        if ($ours.ContainsKey($flat)) { continue }
        if ($e -and (Test-JuicerPublicIp $e.Ip)) {
            $new = @($e.Names | Where-Object { $guarded -contains $_ -or -not $prev.ContainsKey("$($e.Ip) $_") })
            if ($new.Count -gt 0) {
                [void]$out.Add($script:ShieldHostsOff + $t)
                $disabled += $t
                continue
            }
        }
        [void]$out.Add($line)
    }
    while ($out.Count -gt 0 -and ([string]$out[$out.Count - 1]).Trim() -eq '') { $out.RemoveAt($out.Count - 1) }
    if ($out.Count -gt 0) { [void]$out.Add('') }
    [void]$out.Add($script:ShieldHostsBegin)
    foreach ($n in $names) { [void]$out.Add("0.0.0.0 $n"); [void]$out.Add(":: $n") }
    foreach ($m in $maps) { [void]$out.Add($m) }
    [void]$out.Add($script:ShieldHostsEnd)
    @{ Text = (($out -join "`r`n") + "`r`n"); Disabled = $disabled }
}

# forcesafe.search.brave.com's addresses now, as «ip search.brave.com» lines:
# the last ones found when it cannot be looked up, none if it never could.
function Get-JuicerBraveSafeMap {
    $b = Get-JuicerBackend
    $ips = @()
    if ($b.ResolveName) {
        try {
            $r = & $b.ResolveName $script:ShieldBraveSafeHost ''
            $ips = @($r.Ips | Where-Object { Test-JuicerPublicIp $_ } | Sort-Object -Unique)
        } catch {
            Write-JuicerLog "Protección: no se pudo buscar $($script:ShieldBraveSafeHost): $_"
        }
    }
    $saved = Read-JuicerReg $script:ShieldKey 'BraveSegura'
    if ($ips.Count -gt 0) {
        if (-not $saved -or (@($saved.Value) -join ',') -ne ($ips -join ',')) { Write-JuicerReg $script:ShieldKey 'BraveSegura' 'MultiString' $ips }
    } elseif ($saved) {
        $ips = @($saved.Value | Where-Object { $_ })
    }
    foreach ($ip in $ips) { "$ip $($script:ShieldBraveSearchHost)" }
}

function Repair-JuicerShieldHosts {
    $b = Get-JuicerBackend
    $text = & $b.HostsRead
    $prev = Read-JuicerReg $script:ShieldKey 'HostsPrevios'
    if ($null -eq $prev) {
        # The first time: what is there now stays.
        $list = @(Get-JuicerHostsPublicEntries $text)
        Write-JuicerReg $script:ShieldKey 'HostsPrevios' 'MultiString' $list
    } else {
        $list = @($prev.Value)
    }
    $map = @(Get-JuicerBraveSafeMap)
    $want = @($script:ShieldBypassHosts) + @(Get-JuicerShieldBlocked)
    if ($map.Count -eq 0) { $want += $script:ShieldBraveSearchHost }
    $r = Update-JuicerShieldHosts $text $list $want $map
    if ($r.Text -ceq [string]$text) { return }
    & $b.HostsWrite $r.Text
    foreach ($d in $r.Disabled) { "Archivo hosts: desactivada «$d», que saltaba el filtro" }
    # Its own block, when that is what was missing or changed (not just the
    # line endings of the rest).
    $block = (Update-JuicerShieldHosts '' @() $want $map).Text.TrimEnd()
    if (-not (([string]$text) -replace "`r?`n", "`r`n").Contains($block)) {
        if ($map.Count -gt 0) { 'Archivo hosts: Brave Search con su búsqueda segura obligatoria, la VPN de Opera y las webs que bloqueas' }
        else { 'Archivo hosts: Brave Search bloqueado hasta poder forzar su búsqueda segura, la VPN de Opera y las webs que bloqueas' }
    }
}

# --- Sites blocked for good ---------------------------------------------------------

function Get-JuicerShieldBlocked {
    $v = Read-JuicerReg $script:ShieldKey 'Bloqueadas'
    if ($v) { @($v.Value | Where-Object { $_ }) }
}

# What the list holds, said briefly: the presets in it whole, and the other
# sites without their www.
function Get-JuicerShieldBlockedSummary {
    $list = @(Get-JuicerShieldBlocked)
    $presets = @()
    $covered = @{}
    foreach ($k in $script:ShieldPresets.Keys) {
        $h = $script:ShieldPresets[$k].Hosts
        if (@($h | Where-Object { $list -notcontains $_ }).Count -eq 0) {
            $presets += $k
            foreach ($x in $h) { $covered[$x] = $true }
        }
    }
    $sites = @($list | Where-Object { -not $covered.ContainsKey($_) } | ForEach-Object { $_ -replace '^www\.', '' } | Select-Object -Unique)
    @{ Presets = $presets; Sites = $sites; Count = $list.Count }
}

# A site as typed or pasted (a name, an address, a link) into the names the
# hosts file needs: the site and its www, in ASCII. Nothing for what is not
# the name of a site.
function ConvertTo-JuicerBlockHosts {
    param([string]$Site)
    $s = ([string]$Site).Trim().ToLowerInvariant()
    $s = $s -replace '^[a-z][a-z0-9+.-]*://', ''
    $s = @($s -split '[/?#\\]')[0]
    $s = $s -replace '^[^@]*@', '' -replace ':\d*$', ''
    $s = $s.TrimEnd('.')
    if ($s.StartsWith('*.')) { $s = $s.Substring(2) }
    if (-not $s) { return }
    try { $s = (New-Object Globalization.IdnMapping).GetAscii($s) } catch { return }
    if ($s -notmatch '^(?=.{4,253}$)([a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z][a-z0-9-]{0,61}[a-z0-9]$') { return }
    $base = $s -replace '^www\.', ''
    $base
    "www.$base"
}

# Adds sites to what the protection blocks, for good: there is no function
# that takes one off. X, Reddit and Tumblr by name bring every name they use.
# Returns the names added.
function Add-JuicerShieldBlock {
    param([Parameter(Mandatory)][string[]]$Sites)
    if (-not (Test-JuicerShield)) { throw 'La protección contra contenido adulto no está activada.' }
    $have = @(Get-JuicerShieldBlocked)
    $add = New-Object System.Collections.ArrayList
    $bad = @()
    foreach ($s in @($Sites | Where-Object { $_ -and $_.Trim() })) {
        $preset = @($script:ShieldPresets.Keys | Where-Object { $_ -eq $s.Trim() })
        $names = if ($preset.Count -gt 0) { $script:ShieldPresets[$preset[0]].Hosts } else { @(ConvertTo-JuicerBlockHosts $s) }
        if (@($names).Count -eq 0) { $bad += $s.Trim(); continue }
        foreach ($n in $names) { if ($have -notcontains $n -and -not $add.Contains($n)) { [void]$add.Add($n) } }
    }
    if ($bad.Count -gt 0) { throw ('No parece una web: ' + ($bad -join ', ') + '. Escríbela como ejemplo.com.') }
    if ($add.Count -eq 0) { return }
    $all = @(@($have) + @($add) | Sort-Object -Unique)
    if ($all.Count -gt 3000) { throw 'La lista ya es muy larga: el filtro ya bloquea las webs para adultos sin ponerlas aquí.' }
    Write-JuicerReg $script:ShieldKey 'Bloqueadas' 'MultiString' $all
    Write-JuicerLog ('Protección: bloqueadas para siempre ' + ($add -join ', '))
    [void](Repair-JuicerShield)
    $add.ToArray()
}

# --- Putting it in place ----------------------------------------------------------------

# Every part in place; what already is stays as it is, so the task costs
# nothing when nothing changed. Returns what it had to put back, in words.
function Repair-JuicerShield {
    if (-not (Test-JuicerShield)) { return }
    $b = Get-JuicerBackend
    $level = Get-JuicerShieldLevel
    $fixed = New-Object System.Collections.ArrayList
    $key = Select-JuicerShieldDns $level
    $dns = $script:ShieldDns[$key]
    $was = Read-JuicerReg $script:ShieldKey 'Dns'
    if (-not $was -or [string]$was.Value -ne $key) { Write-JuicerReg $script:ShieldKey 'Dns' 'String' $key }
    foreach ($a in (Get-JuicerShieldAdapters)) {
        $has = Get-JuicerDnsServers $a.Guid
        $v6 = $a.Ipv6 -ne $false
        if ((Test-JuicerIpListEqual $has.V4 $dns.V4) -and (-not $v6 -or (Test-JuicerIpListEqual $has.V6 $dns.V6))) { continue }
        try {
            & $b.DnsSet $a.Guid $dns.V4 $(if ($v6) { $dns.V6 } else { @() })
        } catch {
            # An adapter that will not take the IPv6 ones gets the IPv4 ones.
            try { & $b.DnsSet $a.Guid $dns.V4 @() } catch { Write-JuicerLog "Protección: no se pudo poner el DNS en $($a.Name): $_"; continue }
        }
        [void]$fixed.Add("DNS filtrado ($($dns.Title)) en $($a.Name)")
    }
    # After the DNS: closing the old filter's address first would leave a
    # moment with none.
    if ($b.FwRules) {
        try { foreach ($x in @(Repair-JuicerShieldFirewall $level)) { [void]$fixed.Add($x) } } catch { Write-JuicerLog "Protección: cortafuegos: $_" }
    }
    $policies = 0
    foreach ($p in @(Get-JuicerShieldPolicies $level) + @(Get-JuicerShieldUserPolicies)) {
        try {
            if (Test-JuicerAction $p) { continue }
            Invoke-JuicerAction $p @{}
            [void]$fixed.Add($p.Label)
            $policies++
        } catch {
            Write-JuicerLog "Protección: no se pudo poner «$($p.Label)»: $_"
        }
    }
    foreach ($k in $script:ShieldBraveIgnored) {
        if (Read-JuicerReg 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' $k) { Remove-JuicerReg 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' $k; $policies++ }
    }
    if ($policies -gt 0) {
        # When the browsers' rules last changed: one open since before has
        # not got them yet.
        Write-JuicerReg $script:ShieldKey 'Navegadores' 'String' ((Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture))
        if ($b.PolicyRefresh) { try { & $b.PolicyRefresh } catch { Write-JuicerLog "Protección: no se pudo avisar a los navegadores: $_" } }
    }
    if ($b.HostsRead) {
        try { foreach ($x in @(Repair-JuicerShieldHosts)) { [void]$fixed.Add($x) } } catch { Write-JuicerLog "Protección: archivo hosts: $_" }
    }
    if ($b.Name -eq 'Windows') {
        try {
            $v = Read-JuicerReg $script:ShieldKey 'Tarea'
            if (-not (Test-JuicerShieldTask) -or -not $v -or [int]$v.Value -lt $script:ShieldTaskVersion) {
                Register-JuicerShieldTask
                Write-JuicerReg $script:ShieldKey 'Tarea' 'DWord' $script:ShieldTaskVersion
                [void]$fixed.Add('La tarea que la mantiene')
            }
        } catch {
            Write-JuicerLog "Protección: no se pudo crear su tarea: $_"
        }
    }
    $list = @($fixed | Select-Object -Unique)
    if ($list.Count -gt 0) {
        # Whatever was looked up before the filter is still in Windows' cache.
        if ($b.DnsFlush) { try { & $b.DnsFlush } catch { Write-JuicerLog "Protección: no se pudo vaciar la caché de DNS: $_" } }
        Write-JuicerLog ('Protección puesta al día: ' + ($list -join '; '))
    }
    $list
}

# --- Checking that it works ------------------------------------------------------------

# Whether the protection actually filters on this PC, as a list of
# @{ Ok; Title; Detail }: Ok is $true, $false (that is why it fails) or $null
# (could not tell). It looks at the way traffic really leaves, asks Windows for
# a name every filter blocks, and lists the browsers opened before the rules.
function Get-JuicerShieldCheck {
    $b = Get-JuicerBackend
    $out = New-Object System.Collections.ArrayList
    $add = { param($Ok, $Title, $Detail = '') [void]$out.Add(@{ Ok = $Ok; Title = $Title; Detail = $Detail }) }
    if (-not (Test-JuicerShield)) {
        & $add $false 'La protección no está activada' 'Actívala primero.'
        return $out.ToArray()
    }
    $filters = @($script:ShieldDns.Values | ForEach-Object { @($_.V4) + @($_.V6) })

    $route = $null
    if ($b.DnsRoute) { try { $route = & $b.DnsRoute } catch { Write-JuicerLog "Protección: sin la ruta de salida: $_" } }
    if (-not $route) {
        & $add $null 'Sin conexión a internet ahora mismo' 'Conéctate y vuelve a comprobarlo.'
    } else {
        $servers = @($route.Servers | Where-Object { $_ })
        $other = @($servers | Where-Object { $ip = $_; @($filters | Where-Object { Test-JuicerIpListEqual @($ip) @($_) }).Count -eq 0 })
        if ($servers.Count -gt 0 -and $other.Count -eq 0) {
            & $add $true "Tu conexión ($($route.Name)) usa el DNS filtrado"
        } elseif ($route.Virtual) {
            $dns = if ($other.Count -gt 0) { $other -join ', ' } else { 'su propio DNS' }
            $desc = if ($route.Description) { " ($($route.Description))" } else { '' }
            & $add $false "Tu conexión sale por «$($route.Name)», un adaptador virtual sin el DNS filtrado" "Es una VPN o un adaptador de Hyper-V$desc, y usa $dns. Mientras salgas por ahí, nada se filtra. Desconecta la VPN, o, si es Hyper-V, quita el conmutador virtual externo."
        } else {
            & $add $false "Tu conexión ($($route.Name)) no usa el DNS filtrado" ('Usa ' + ($other -join ', ') + '. La tarea de la protección lo corrige sola; si vuelve a pasar, otro programa está cambiando el DNS.')
        }
    }

    if ($b.ResolveName) {
        $probe = $script:ShieldProbeName
        $filter = $script:ShieldDns[(Select-JuicerShieldDns)].V4[0]
        $viaFilter = & $b.ResolveName $probe $filter
        $viaWindows = & $b.ResolveName $probe ''
        $filterBlocks = @($viaFilter.Ips | Where-Object { Test-JuicerPublicIp $_ }).Count -eq 0
        $leak = @($viaWindows.Ips | Where-Object { (Test-JuicerPublicIp $_) -and @($viaFilter.Ips) -notcontains $_ })
        if (($viaWindows.Error -and -not $viaWindows.NxDomain) -and ($viaFilter.Error -and -not $viaFilter.NxDomain)) {
            & $add $null 'No se pudo hacer la prueba con una web para adultos' 'Puede que ahora no haya conexión.'
        } elseif ($leak.Count -gt 0) {
            & $add $false "Windows todavía abre $probe ($($leak -join ', '))" 'El DNS de esta conexión no es el filtrado (mira el punto anterior), o algo responde por él.'
        } elseif (-not $filterBlocks) {
            & $add $null "El filtro no bloqueó $probe en esta prueba" 'No se puede saber si filtra: vuelve a comprobarlo en unos minutos.'
        } else {
            & $add $true "Prueba real: $probe está bloqueada en este PC"
        }
    }

    if ($b.HostsRead) {
        $hosts = [string](& $b.HostsRead)
        $safe = @(([regex]::Matches($hosts, '(?m)^[ \t]*(\S+)[ \t]+search\.brave\.com[ \t]*\r?$')) | ForEach-Object { $_.Groups[1].Value })
        if (@($safe | Where-Object { Test-JuicerPublicIp $_ }).Count -gt 0) {
            & $add $true 'Brave Search, con su búsqueda segura obligatoria'
        } elseif ($safe.Count -gt 0) {
            & $add $null 'Brave Search está bloqueado por ahora' 'Todavía no se ha podido forzar su búsqueda segura, porque hace falta conexión. La tarea lo hará sola en unos minutos; mientras, en Brave puedes elegir Google como buscador (Configuración, Motor de búsqueda).'
        }
    }

    if ($b.Browsers) {
        $mark = Read-JuicerReg $script:ShieldKey 'Navegadores'
        if (-not $mark) { $mark = Read-JuicerReg $script:ShieldKey 'Desde' }
        $since = [datetime]::MinValue
        if ($mark) { [void][datetime]::TryParse([string]$mark.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$since) }
        $names = @{ brave = 'Brave'; chrome = 'Chrome'; msedge = 'Edge'; firefox = 'Firefox' }
        $stale = @(& $b.Browsers | Where-Object { $_.Started -and $_.Started -lt $since } | ForEach-Object { $names[[string]$_.Name] })
        if ($stale.Count -gt 0) {
            $tip = if (@($stale | Where-Object { $_ -ne 'Firefox' }).Count -gt 0) { ' Cerrar la ventana no basta: siguen abiertos en segundo plano. Usa el icono junto al reloj, «Salir», o reinicia el PC. Desde ahora, cerrarlos los cierra del todo.' } else { '' }
            & $add $false "$($stale -join ', ') está abierto desde antes de la protección" "Todavía usa las respuestas de DNS y las reglas de antes, así que puede seguir cargando webs bloqueadas.$tip"
        } else {
            & $add $true 'Ningún navegador abierto desde antes de la protección'
        }
    }
    $out.ToArray()
}


# Turns it on, at a level (2, estricta, unless asked otherwise), or raises it:
# the marks first, so that even a start cut halfway is finished by the task or
# the next time Win Juicer opens; then every part. There is no function that
# turns it off or lowers it: that is the point of it.
function Enable-JuicerShield {
    param([ValidateSet(1, 2)][int]$Level = 2)
    if (-not (Test-JuicerShield)) {
        Write-JuicerReg $script:ShieldKey 'Nivel' 'DWord' $Level
        Write-JuicerReg $script:ShieldKey 'Activada' 'DWord' 1
        Write-JuicerReg $script:ShieldKey 'Desde' 'String' ((Get-Date).ToString('s', [Globalization.CultureInfo]::InvariantCulture))
        Write-JuicerLog "Protección contra contenido adulto activada ($($script:ShieldLevels[$Level].Title.ToLowerInvariant()))"
    } elseif ($Level -gt (Get-JuicerShieldLevel)) {
        Write-JuicerReg $script:ShieldKey 'Nivel' 'DWord' $Level
        Write-JuicerLog "Protección contra contenido adulto: ahora $($script:ShieldLevels[$Level].Title.ToLowerInvariant())"
    }
    @(Repair-JuicerShield)
}

function Test-JuicerShieldTask {
    if (-not (Test-JuicerWindows)) { return $false }
    $null -ne (Get-ScheduledTask -TaskName $script:ShieldTask -ErrorAction SilentlyContinue)
}

# As SYSTEM, from the copy in Program Files that only an administrator can
# change: at startup, at sign-in, when a network connects (a new Wi-Fi, a
# network reset), as soon as the firewall changes (a rule deleted, turned off
# or edited, the firewall itself turned off) and every 15 minutes, at the
# lowest priority a task gets.
function Register-JuicerShieldTask {
    $dir = Install-JuicerCopy
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $action = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $dir 'WinJuicer.ps1')`" -ProteccionAdultos Mantener"
    $triggers = @(
        (New-ScheduledTaskTrigger -AtStartup)
        (New-ScheduledTaskTrigger -AtLogOn)
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(15) -RepetitionInterval (New-TimeSpan -Minutes 15))
    )
    $events = @(
        @{ Log = 'Microsoft-Windows-NetworkProfile/Operational'; Ids = @(10000) }
        @{ Log = 'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall'; Ids = @(2003, 2004, 2005, 2006, 2033, 2052, 2071, 2097, 2099) }
    )
    foreach ($e in $events) {
        try {
            $cls = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace 'Root/Microsoft/Windows/TaskScheduler'
            $t = New-CimInstance -CimClass $cls -ClientOnly
            $t.Enabled = $true
            $ids = (@($e.Ids | ForEach-Object { "EventID=$_" }) -join ' or ')
            $t.Subscription = "<QueryList><Query Id=`"0`" Path=`"$($e.Log)`"><Select Path=`"$($e.Log)`">*[System[($ids)]]</Select></Query></QueryList>"
            $triggers += $t
        } catch {
            Write-JuicerLog "Protección: sin el aviso de $($e.Log) (quedan los 15 minutos): $_"
        }
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -Priority 7 -ExecutionTimeLimit (New-TimeSpan -Minutes 5)
    $about = 'Mantiene la protección contra contenido adulto activada en Win Juicer: DNS filtrado, cortafuegos, navegadores y archivo hosts. Se activa una vez y no se desactiva desde Win Juicer.'
    try {
        Register-ScheduledTask -TaskName $script:ShieldTask -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Description $about -Force -ErrorAction Stop | Out-Null
    } catch {
        # A Windows without one of those logs rejects the whole task: then
        # without the notices, and the 15 minutes do.
        Write-JuicerLog "Protección: la tarea no admite los avisos de eventos ($_); va sin ellos"
        Register-ScheduledTask -TaskName $script:ShieldTask -Action $action -Trigger $triggers[0..2] -Principal $principal -Settings $settings -Description $about -Force -ErrorAction Stop | Out-Null
    }
    Write-JuicerLog "Protección: tarea creada ($dir)"
}

# What it does and costs, said before turning it on or raising it, in the
# window and in the console.
function Get-JuicerShieldExplanation {
    param([int]$Level = 2)
    if ($Level -ge 2) {
        @(
            'Estricta, la recomendada si es para dejar el porno. Bloquea las webs para adultos en todo el equipo, en cualquier navegador, app o juego, con el filtro familiar de CleanBrowsing, que además cierra proxies y VPN, y Reddit y otras webs con contenido mixto. Obliga a la búsqueda segura de Google y Bing, pone YouTube en modo restringido estricto y quita las ventanas privadas y de invitado de Chrome, Edge, Brave y Firefox. En Brave también las de Tor, y su buscador, Brave Search, sólo funciona con la búsqueda segura.'
            'Y cierra los atajos: el DNS sólo puede ir al filtro (el cortafuegos de Windows bloquea cualquier otro, también el cifrado de Google, Cloudflare y compañía), los navegadores no usan ni su propio DNS ni un proxy, la VPN de Opera no conecta, y lo que se añada al archivo hosts para saltárselo se desactiva. Además puedes bloquear para siempre X, Reddit, Tumblr o la web que quieras. Nada filtra dentro de tu PC: las webs cargan igual de rápido.'
            'Es para siempre: una vez activada, Win Juicer no te deja desactivarla ni bajarla de nivel. No hay botón para quitarla, «Deshacer todo» no la toca y, si algo la cambia, una tarea la vuelve a poner sola, en segundos si es el cortafuegos.'
            'Lo que no puede: una VPN o Tor instalados como programa, ni apps que sirven ese contenido desde sus propios dominios. Una VPN que traiga su propio DNS, también la del trabajo, no resolverá nombres, y alguna Wi-Fi de hotel con página de acceso puede no abrirla. Chrome y Edge dirán que «los administra tu organización»: son estas reglas. Para el móvil, en Android: Ajustes, Red, DNS privado: family-filter-dns.cleanbrowsing.org.'
        )
    } else {
        @(
            'Equilibrada. Bloquea las webs para adultos en todo el equipo, en cualquier navegador, app o juego, con el filtro de adultos de CleanBrowsing, y obliga a la búsqueda segura de Google y Bing y al modo restringido de YouTube en Chrome, Edge y Brave. En Brave, además, quita las ventanas de Tor y obliga a la búsqueda segura de su buscador, Brave Search. Reddit, las VPN y las ventanas privadas normales siguen funcionando.'
            'Cierra los atajos más comunes: el DNS de Google, Cloudflare, Quad9 y otros públicos no responde (tampoco el cifrado), los navegadores no usan su propio DNS, la VPN de Opera no conecta, y lo que se añada al archivo hosts para saltárselo se desactiva. Puedes bloquear para siempre X, Reddit, Tumblr o la web que quieras. Nada filtra dentro de tu PC: las webs cargan igual de rápido.'
            'Es para siempre: una vez activada, Win Juicer no te deja desactivarla. No hay botón para quitarla, «Deshacer todo» no la toca y, si algo la cambia, una tarea la vuelve a poner sola. Más adelante puedes pasar a la estricta, pero no volver.'
            'Lo que no puede: una VPN, un proxy o Tor, ni apps que sirven ese contenido desde sus propios dominios. En Firefox bloquea las webs, pero no obliga a la búsqueda segura. Chrome y Edge dirán que «los administra tu organización»: son estas reglas. Para el móvil, en Android: Ajustes, Red, DNS privado: adult-filter-dns.cleanbrowsing.org.'
        )
    }
}
