# Debloat, DNS, winget, the new command line and the parts of the window that
# can be checked without a screen.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Root = Split-Path -Parent $PSScriptRoot

    function New-NetMachine {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $eth = '{11111111-AAAA-BBBB-CCCC-000000000001}'
        $wifi = '{11111111-AAAA-BBBB-CCCC-000000000002}'
        [void]$m.Backend.State.Adapters.Add(@{ Guid = $eth; Name = 'Ethernet'; Description = 'Realtek'; Wireless = $false; LinkSpeed = 1000000000 })
        [void]$m.Backend.State.Adapters.Add(@{ Guid = $wifi; Name = 'Wi-Fi'; Description = 'Intel'; Wireless = $true; LinkSpeed = 866000000 })
        # Ethernet by DHCP; the Wi-Fi with a DNS someone set by hand.
        foreach ($f in 'Tcpip', 'Tcpip6') {
            Write-JuicerReg "HKLM\SYSTEM\CurrentControlSet\Services\$f\Parameters\Interfaces\$eth" 'NameServer' 'String' ''
            Write-JuicerReg "HKLM\SYSTEM\CurrentControlSet\Services\$f\Parameters\Interfaces\$wifi" 'NameServer' 'String' ''
        }
        Write-JuicerReg "HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\$wifi" 'NameServer' 'String' '192.168.1.1,8.8.8.8'
        $m
    }
}

Describe 'Debloat' {
    It 'la lista está bien formada' {
        $apps = @(Get-JuicerDebloatApps)
        $apps.Count | Should -BeGreaterThan 25
        (@($apps | ForEach-Object { $_.Name }) | Select-Object -Unique).Count | Should -Be $apps.Count
        foreach ($a in $apps) {
            $a.Class | Should -BeIn @('Seguro', 'Opcional', 'Cuidado') -Because $a.Name
            $a.Title | Should -Not -BeNullOrEmpty
            $a.What | Should -Not -BeNullOrEmpty
            $a.StoreId | Should -Match '^(9[0-9A-Z]{11}|XP[0-9A-Z]{12})$' -Because $a.Name
        }
        # What would break Game Pass, Game Bar or Xbox sign-in is never «safe».
        foreach ($n in 'Microsoft.GamingApp', 'Microsoft.XboxGamingOverlay', 'Microsoft.XboxIdentityProvider') { (Find-JuicerDebloatApp $n).Class | Should -Be 'Cuidado' }
        foreach ($n in 'Microsoft.WindowsStore', 'Microsoft.WindowsCalculator', 'Microsoft.Windows.Photos', 'Microsoft.WindowsNotepad', 'Microsoft.DesktopAppInstaller') {
            Find-JuicerDebloatApp $n | Should -BeNullOrEmpty -Because "$n no se ofrece"
        }
    }

    It 'quitar y deshacer: la app vuelve desde la Tienda' {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $m.Backend.State.Appx['Microsoft.BingNews'] = @{ Installed = $true; Provisioned = $true }
        $m.Backend.State.Appx['Microsoft.XboxGamingOverlay'] = @{ Installed = $true; Provisioned = $true }
        $state = @(Get-JuicerDebloatState @{ Cpu = @{ DualCcdX3D = $true; Name = 'Ryzen 9 7950X3D' }; GamePass = $false })
        $state.Count | Should -Be 2
        ($state | Where-Object { $_.Name -eq 'Microsoft.XboxGamingOverlay' }).Need | Should -BeLike '*7950X3D*'
        ($state | Where-Object { $_.Name -eq 'Microsoft.BingNews' }).Recommended | Should -BeTrue

        $t = New-JuicerAppxTweak (Find-JuicerDebloatApp 'Microsoft.BingNews')
        $t.Level | Should -Be 1
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Backend.State.Appx.ContainsKey('Microsoft.BingNews') | Should -BeFalse
        @(Get-JuicerRemovedApps).Count | Should -Be 1
        (Undo-JuicerTweak $t.Id).Outcome | Should -Be 'Deshecho'
        $m.Backend.State.Appx['Microsoft.BingNews'].Installed | Should -BeTrue
        @($m.Backend.State.Calls) | Should -Contain 'winget install --id 9WZDNCRFHVFW --source msstore'
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'quitar una app que no está no hace nada' {
        $m = New-FakeMachine
        (Invoke-JuicerTweak (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Clipchamp.Clipchamp'))).Outcome | Should -Be 'YaEstaba'
    }

    It 'las apps «Cuidado» se confirman una a una, como el nivel Extremo' {
        (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Microsoft.GamingApp')).Level | Should -Be 3
    }
}

Describe 'Protección contra contenido adulto' {
    BeforeEach {
        $script:M = New-NetMachine
        $script:Strict = @('185.228.168.168', '185.228.169.168')
        $script:Adult = @('185.228.168.10', '185.228.169.11')
        $script:Chrome = 'HKLM\SOFTWARE\Policies\Google\Chrome'
    }

    It 'se activa en la estricta: DNS filtrado en cada adaptador, cortafuegos, navegadores, hosts y la búsqueda de Windows' {
        Write-JuicerReg 'HKU\S-1-5-21-1-2-3-1001\Software\Microsoft\Windows\CurrentVersion' 'ProgramFilesDir' 'String' 'x'
        Test-JuicerShield | Should -BeFalse
        $r = @(Enable-JuicerShield)
        Test-JuicerShield | Should -BeTrue
        (Get-JuicerShieldInfo).Level | Should -Be 2
        $r.Count | Should -BeGreaterThan 30
        foreach ($a in @(Get-JuicerShieldAdapters)) {
            $d = Get-JuicerDnsServers $a.Guid
            $d.V4 | Should -Be $Strict
            $d.V6 | Should -Be @('2a0d:2a00:1::', '2a0d:2a00:2::')
        }
        (Read-JuicerReg $Chrome 'DnsOverHttpsMode').Value | Should -Be 'off'
        (Read-JuicerReg $Chrome 'ForceGoogleSafeSearch').Value | Should -Be 1
        (Read-JuicerReg $Chrome 'ForceYouTubeRestrict').Value | Should -Be 2
        (Read-JuicerReg $Chrome 'IncognitoModeAvailability').Value | Should -Be 1
        (Read-JuicerReg $Chrome 'BrowserGuestModeEnabled').Value | Should -Be 0
        (Read-JuicerReg $Chrome 'ProxyMode').Value | Should -Be 'direct'
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'ForceBingSafeSearch').Value | Should -Be 2
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Microsoft\Edge' 'InPrivateModeAvailability').Value | Should -Be 1
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave' 'TorDisabled').Value | Should -Be 1
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Mozilla\Firefox\DNSOverHTTPS' 'Locked').Value | Should -Be 1
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Mozilla\Firefox' 'DisablePrivateBrowsing').Value | Should -Be 1
        (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Mozilla\Firefox\Proxy' 'Mode').Value | Should -Be 'none'
        (Read-JuicerReg 'HKU\S-1-5-21-1-2-3-1001\Software\Microsoft\Windows\CurrentVersion\SearchSettings' 'SafeSearchMode').Value | Should -Be 2
        # Six firewall rules, as they should be.
        $fw = $M.Backend.State.Firewall
        $fw.Count | Should -Be 6
        foreach ($rule in @(Get-JuicerShieldFwRules 2)) { Test-JuicerShieldFwRule $rule $fw[$rule.Name] | Should -BeTrue -Because $rule.Name }
        # Opera's VPN, out through the hosts file.
        $M.Backend.State.Hosts | Should -Match '(?m)^0\.0\.0\.0 api\.sec-tunnel\.com\r?$'
        $M.Backend.State.Hosts | Should -Match '(?m)^:: api\.sec-tunnel\.com\r?$'
        $i = Get-JuicerShieldInfo
        $i.Since | Should -Not -BeNullOrEmpty
        $i.Provider | Should -Be 'CleanBrowsingFamilia'
        $i.Phone | Should -Be 'family-filter-dns.cleanbrowsing.org'
        # Again, nothing to do: the task every 15 minutes costs nothing.
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        @(Enable-JuicerShield) | Should -BeNullOrEmpty
    }

    It 'en la estricta el DNS sólo puede ir al filtro; en la equilibrada, a todo menos a los públicos sin filtro' {
        $inside = {
            param($Rules, [string]$Ip)
            $n = & (Get-Module WinJuicer) { param($x) ConvertTo-JuicerAddressSet @($x) } $Ip
            $set = & (Get-Module WinJuicer) { param($x) ConvertTo-JuicerAddressSet $x } $Rules
            @($set | Where-Object { $_.F -eq $n[0].F -and $_.S -le $n[0].S -and $_.E -ge $n[0].E }).Count -gt 0
        }
        $strict = (@(Get-JuicerShieldFwRules 2) | Where-Object { $_.Name -eq 'WinJuicer-Proteccion-DNS-UDP' }).Remote
        foreach ($ip in '185.228.168.168', '185.228.169.168', '1.1.1.3', '1.0.0.3', '2a0d:2a00:1::', '2606:4700:4700::1113', '127.0.0.1', '::1') { & $inside $strict $ip | Should -BeFalse -Because "$ip es el filtro o este PC" }
        foreach ($ip in '8.8.8.8', '1.1.1.1', '192.168.1.1', '10.0.0.53', '185.228.168.10', '2001:4860:4860::8888', 'fe80::1') { & $inside $strict $ip | Should -BeTrue -Because "$ip no es el filtro" }
        $soft = (@(Get-JuicerShieldFwRules 1) | Where-Object { $_.Name -eq 'WinJuicer-Proteccion-DNS-TCP' }).Remote
        foreach ($ip in '8.8.8.8', '1.1.1.1', '9.9.9.9', '45.90.28.7', '2606:4700:4700::1111') { & $inside $soft $ip | Should -BeTrue -Because "$ip es un DNS público sin filtro" }
        foreach ($ip in '185.228.168.10', '1.1.1.3', '192.168.1.1', '10.0.0.53') { & $inside $soft $ip | Should -BeFalse -Because "$ip sigue funcionando en la equilibrada" }
        # DNS over TLS and QUIC, closed everywhere; DNS over HTTPS, to the public ones only.
        foreach ($l in 1, 2) {
            $rules = @(Get-JuicerShieldFwRules $l)
            $rules.Count | Should -Be 6
            @($rules | Where-Object { $_.Port -eq '853' } | ForEach-Object { $_.Remote -join ',' }) | Should -Be @('Any', 'Any')
            $doh = ($rules | Where-Object { $_.Name -eq 'WinJuicer-Proteccion-DoH-TCP' }).Remote
            & $inside $doh '8.8.8.8' | Should -BeTrue
            foreach ($ip in '185.228.168.168', '185.228.168.10', '1.1.1.3') { & $inside $doh $ip | Should -BeFalse }
        }
    }

    It 'las direcciones se leen como las devuelve Windows: máscaras, rangos e IPv6' {
        $m = Get-Module WinJuicer
        $a = & $m { ConvertTo-JuicerAddressSet @('45.90.28.0/255.255.255.0', '10.0.0.1-10.0.0.9', '10.0.0.5', '2001:db8::/126') }
        & $m { param($x) ConvertFrom-JuicerAddressSet $x } $a | Should -Be @('10.0.0.1-10.0.0.9', '45.90.28.0-45.90.28.255', '2001:db8::-2001:db8::3')
        & $m { $null -eq (ConvertTo-JuicerAddressSet @('LocalSubnet')) } | Should -BeTrue
        & $m { ConvertFrom-JuicerAddressSet (Get-JuicerAddressComplement (ConvertTo-JuicerAddressSet @('0.0.0.0', '127.0.0.0/8', '::', '::1'))) } |
            Should -Be @('0.0.0.1-126.255.255.255', '128.0.0.0-255.255.255.255', '::2-ffff:ffff:ffff:ffff:ffff:ffff:ffff:ffff')
        & $m { ConvertFrom-JuicerIpNumber (ConvertTo-JuicerIpNumber ([Net.IPAddress]::Parse('2001:db8:0:0:1:0:0:1').GetAddressBytes())) 6 } | Should -Be '2001:db8::1:0:0:1'
    }

    It 'se repone sola si algo la cambia, y nada de Win Juicer la quita' {
        [void](Enable-JuicerShield)
        $eth = $M.Backend.State.Adapters[0].Guid
        & (Get-JuicerBackend).DnsSet $eth @('8.8.8.8') @()
        Remove-JuicerReg $Chrome 'ForceGoogleSafeSearch'
        Write-JuicerReg $Chrome 'IncognitoModeAvailability' 'DWord' 0
        $fixed = @(Repair-JuicerShield)
        $fixed | Should -Contain 'Chrome: búsqueda segura de Google'
        $fixed | Should -Contain 'Chrome: sin ventanas privadas'
        @($fixed | Where-Object { $_ -like 'DNS filtrado*Ethernet' }).Count | Should -Be 1
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
        # Win Juicer's own DNS chooser cannot change it, and undoing everything leaves it.
        (Invoke-JuicerTweak (New-JuicerDnsTweak 'Google')).Outcome | Should -Be 'NoAplica'
        [void](Undo-JuicerAll)
        Test-JuicerShield | Should -BeTrue
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
        (Read-JuicerReg $Chrome 'ForceGoogleSafeSearch').Value | Should -Be 1
        $M.Backend.State.Firewall.Count | Should -Be 6
        # And no command turns it off, lowers it or unblocks a site.
        @(Get-Command -Module WinJuicer | Where-Object { $_.Name -like '*JuicerShield*' -and $_.Verb -in 'Disable', 'Remove', 'Unregister', 'Clear', 'Reset', 'Stop', 'Set' }) | Should -BeNullOrEmpty
    }

    It 'el cortafuegos: una regla apagada, estrechada o borrada vuelve; si algo insiste, no hay pelea' {
        [void](Enable-JuicerShield)
        $fw = $M.Backend.State.Firewall
        $fw['WinJuicer-Proteccion-DNS-UDP'].Enabled = $false
        $fw['WinJuicer-Proteccion-DoT'].Program = 'C:\Juego\juego.exe'
        $fw.Remove('WinJuicer-Proteccion-DoH-TCP')
        [void]$M.Backend.State.FwOff.Add('Public')
        $fixed = @(Repair-JuicerShield)
        @($fixed | Where-Object { $_ -like 'Cortafuegos:*' }).Count | Should -Be 3
        $fixed | Should -Contain 'Cortafuegos de Windows: encendido (lo necesitan sus bloqueos)'
        $fw['WinJuicer-Proteccion-DNS-UDP'].Enabled | Should -BeTrue
        $fw['WinJuicer-Proteccion-DoT'].Program | Should -Be 'Any'
        @($M.Backend.State.FwOff).Count | Should -Be 0
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        # Something keeps undoing the same rule: put back once, then it waits.
        $fw['WinJuicer-Proteccion-DNS-UDP'].Enabled = $false
        @(Repair-JuicerShield) | Should -Contain 'Cortafuegos: el DNS sólo va al filtro (UDP)'
        $fw['WinJuicer-Proteccion-DNS-UDP'].Enabled = $false
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        $fw['WinJuicer-Proteccion-DNS-UDP'].Enabled | Should -BeFalse
        # A few minutes later, put back.
        Write-JuicerReg 'HKLM\SOFTWARE\WinJuicer\Proteccion' 'CortafuegosEscrito' 'String' ((Get-Date).AddMinutes(-3).ToString('s') + '|2: WinJuicer-Proteccion-DNS-UDP')
        @(Repair-JuicerShield) | Should -Contain 'Cortafuegos: el DNS sólo va al filtro (UDP)'
        # Another program in charge of the firewall: Windows' stays off.
        $M.Backend.State.FwThirdParty = $true
        [void]$M.Backend.State.FwOff.Add('Domain')
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        (Get-JuicerShieldInfo).Firewall | Should -Be 'Otro'
    }

    It 'sube de la equilibrada a la estricta, y nunca baja' {
        [void](Enable-JuicerShield -Level 1)
        $eth = $M.Backend.State.Adapters[0].Guid
        (Get-JuicerShieldInfo).Level | Should -Be 1
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Adult
        (Read-JuicerReg $Chrome 'ForceYouTubeRestrict').Value | Should -Be 1
        Read-JuicerReg $Chrome 'IncognitoModeAvailability' | Should -BeNullOrEmpty
        (Get-JuicerShieldInfo).Phone | Should -Be 'adult-filter-dns.cleanbrowsing.org'
        @(Enable-JuicerShield -Level 1) | Should -BeNullOrEmpty
        $up = @(Enable-JuicerShield -Level 2)
        $up | Should -Contain 'Chrome: sin ventanas privadas'
        $up | Should -Contain 'Cortafuegos: el DNS sólo va al filtro (UDP)'
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
        (Read-JuicerReg $Chrome 'ForceYouTubeRestrict').Value | Should -Be 2
        @(Enable-JuicerShield -Level 1) | Should -BeNullOrEmpty
        (Get-JuicerShieldInfo).Level | Should -Be 2
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
    }

    It 'quien la activó antes de los niveles sigue en la equilibrada, y se completa sola' {
        Write-JuicerReg 'HKLM\SOFTWARE\WinJuicer\Proteccion' 'Activada' 'DWord' 1
        $fixed = @(Repair-JuicerShield)
        (Get-JuicerShieldInfo).Level | Should -Be 1
        (Get-JuicerDnsServers $M.Backend.State.Adapters[0].Guid).V4 | Should -Be $Adult
        @($fixed | Where-Object { $_ -like 'Cortafuegos:*' }).Count | Should -Be 6
        $fixed | Should -Contain 'Archivo hosts: Brave Search bloqueado hasta poder forzar su búsqueda segura, la VPN de Opera y las webs que bloqueas'
    }

    It 'deshacer un DNS de antes no quita el filtrado' {
        (Invoke-JuicerTweak (New-JuicerDnsTweak 'Google')).Outcome | Should -Be 'Aplicado'
        [void](Enable-JuicerShield)
        (Undo-JuicerTweak 'red.dns').Outcome | Should -Be 'Deshecho'
        foreach ($a in @(Get-JuicerShieldAdapters)) { (Get-JuicerDnsServers $a.Guid).V4 | Should -Be $Strict }
    }

    It 'si CleanBrowsing no responde, Cloudflare para familias; nunca un DNS sin filtro' {
        foreach ($ip in $Strict) { [void]$M.Backend.State.DnsDown.Add($ip) }
        [void](Enable-JuicerShield)
        $eth = $M.Backend.State.Adapters[0].Guid
        (Get-JuicerDnsServers $eth).V4 | Should -Be @('1.1.1.3', '1.0.0.3')
        (Get-JuicerShieldInfo).Provider | Should -Be 'Cloudflare'
        # Back to CleanBrowsing when it answers again.
        $M.Backend.State.DnsDown.Clear()
        @(Repair-JuicerShield).Count | Should -BeGreaterThan 0
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
        # With no answer from any (no network), it stays filtered as it is.
        foreach ($ip in @($Strict) + @('1.1.1.3', '1.0.0.3')) { [void]$M.Backend.State.DnsDown.Add($ip) }
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
    }

    It 'un adaptador sin IPv6 recibe sólo los de IPv4, y no se vuelve a tocar' {
        $M.Backend.State.Adapters[0].Ipv6 = $false
        [void](Enable-JuicerShield)
        $eth = $M.Backend.State.Adapters[0].Guid
        (Get-JuicerDnsServers $eth).V4 | Should -Be $Strict
        (Get-JuicerDnsServers $eth).V6 | Should -BeNullOrEmpty
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
    }

    It 'el archivo hosts: lo de antes se queda; lo que se añade para saltársela, no' {
        $M.Backend.State.Hosts += "93.184.216.34 antes.example`r`n192.168.1.10 nas.local`r`n"
        [void](Enable-JuicerShield)
        $h = $M.Backend.State.Hosts
        $h | Should -Match '(?m)^93\.184\.216\.34 antes\.example\r?$'
        $h | Should -Match '(?m)^192\.168\.1\.10 nas\.local\r?$'
        $h | Should -Match 'Copyright \(c\) 1993-2009'
        # Added later: a public address is switched off, a local one stays.
        $M.Backend.State.Hosts += "104.18.0.1 www.webporno.example # para saltar el filtro`r`n10.0.0.5 intranet`r`n2606:4700::1 otra.example`r`n"
        $fixed = @(Repair-JuicerShield)
        @($fixed | Where-Object { $_ -like 'Archivo hosts: desactivada*' }).Count | Should -Be 2
        $h = $M.Backend.State.Hosts
        $h | Should -Match '(?m)^# Win Juicer \(proteccion\) la desactivo: 104\.18\.0\.1 www\.webporno\.example'
        $h | Should -Match '(?m)^# Win Juicer \(proteccion\) la desactivo: 2606:4700::1 otra\.example'
        $h | Should -Match '(?m)^10\.0\.0\.5 intranet\r?$'
        # Taking the mark off brings it back to a comment; and the block, if deleted, comes back.
        $M.Backend.State.Hosts = $h.Replace('# Win Juicer (proteccion) la desactivo: 104.18.0.1', '104.18.0.1') -replace '(?m)^(0\.0\.0\.0|::) api\.sec-tunnel\.com\r?\n', ''
        $fixed = @(Repair-JuicerShield)
        $fixed | Should -Contain 'Archivo hosts: Brave Search bloqueado hasta poder forzar su búsqueda segura, la VPN de Opera y las webs que bloqueas'
        $M.Backend.State.Hosts | Should -Be $h
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
    }

    It 'bloquea webs para siempre: X, Reddit, Tumblr o la que se diga, y no se pueden quitar' {
        { Add-JuicerShieldBlock 'ejemplo.com' } | Should -Throw '*no está activada*'
        [void](Enable-JuicerShield)
        $M.Backend.State.Hosts += "151.101.1.140 www.reddit.com`r`n"
        $added = @(Add-JuicerShieldBlock @('Reddit', 'https://www.Ejemplo.com/ruta?x=1', 'bücher.de'))
        $added | Should -Contain 'old.reddit.com'
        $added | Should -Contain 'ejemplo.com'
        $added | Should -Contain 'www.ejemplo.com'
        $added | Should -Contain 'xn--bcher-kva.de'
        $h = $M.Backend.State.Hosts
        $h | Should -Match '(?m)^0\.0\.0\.0 old\.reddit\.com\r?$'
        $h | Should -Match '(?m)^:: ejemplo\.com\r?$'
        # A line that sent a blocked name somewhere public goes off too.
        $h | Should -Match '(?m)^# Win Juicer \(proteccion\) la desactivo: 151\.101\.1\.140 www\.reddit\.com'
        $s = Get-JuicerShieldBlockedSummary
        $s.Presets | Should -Be @('Reddit')
        $s.Sites | Should -Be @('ejemplo.com', 'xn--bcher-kva.de')
        @(Add-JuicerShieldBlock 'ejemplo.com') | Should -BeNullOrEmpty
        { Add-JuicerShieldBlock @('x.com', 'no es una web') } | Should -Throw '*no es una web*'
        { Add-JuicerShieldBlock @('localhost') } | Should -Throw
        { Add-JuicerShieldBlock @('8.8.8.8') } | Should -Throw
        @(Get-JuicerShieldBlocked) | Should -Not -Contain 'x.com'
        (Get-JuicerShieldInfo).Blocked.Presets | Should -Be @('Reddit')
        # A list deleted by hand comes back from the hosts file? No: from the
        # registry; and the hosts file follows the list.
        $before = @(Get-JuicerShieldBlocked).Count
        [void](Add-JuicerShieldBlock 'X')
        @(Get-JuicerShieldBlocked).Count | Should -BeGreaterThan $before
        @((Get-JuicerShieldInfo).Blocked.Presets) | Should -Be @('X', 'Reddit')
    }

    It 'desde la línea de órdenes: activar con nivel, subir, bloquear, el estado y mantenerla; desactivarla no existe' {
        @(Start-Juicer -ProteccionAdultos Estado 6>$null)[-1] | Should -Be 0
        Test-JuicerShield | Should -BeFalse
        @(Start-Juicer -ProteccionAdultos Bloquear -BloquearWeb ejemplo.com -Si 6>$null)[-1] | Should -Be 1
        @(Start-Juicer -ProteccionAdultos Activar -NivelProteccion Equilibrado -Si 6>$null)[-1] | Should -Be 0
        Test-JuicerShield | Should -BeTrue
        (Get-JuicerShieldInfo).Level | Should -Be 1
        @(Start-Juicer -ProteccionAdultos Subir -Si 6>$null)[-1] | Should -Be 0
        (Get-JuicerShieldInfo).Level | Should -Be 2
        @(Start-Juicer -BloquearWeb 'Tumblr,ejemplo.com' -Si 6>$null)[-1] | Should -Be 0
        @(Get-JuicerShieldBlocked) | Should -Contain '64.media.tumblr.com'
        @(Get-JuicerShieldBlocked) | Should -Contain 'www.ejemplo.com'
        @(Start-Juicer -ProteccionAdultos Bloquear -BloquearWeb 'no es una web' -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -ProteccionAdultos Mantener 6>$null)[-1] | Should -Be 0
        { Start-Juicer -ProteccionAdultos Desactivar } | Should -Throw
        { Start-Juicer -ProteccionAdultos Activar -NivelProteccion Ninguno } | Should -Throw
        [void](Start-Juicer -Dns Google -Si 6>$null)
        (Get-JuicerDnsServers $M.Backend.State.Adapters[0].Guid).V4 | Should -Be $Strict
        foreach ($l in 1, 2) {
            @(Get-JuicerShieldExplanation $l).Count | Should -Be 4
            (Get-JuicerShieldExplanation $l) -join ' ' | Should -BeLike '*para siempre*'
        }
    }
}

Describe 'DNS' {
    It 'los proveedores tienen direcciones válidas' {
        $p = Get-JuicerDnsProviders
        $p.Contains('Automatico') | Should -BeTrue
        foreach ($k in $p.Keys) {
            foreach ($ip in @($p[$k].V4)) { [Net.IPAddress]::Parse($ip).AddressFamily | Should -Be 'InterNetwork' -Because $k }
            foreach ($ip in @($p[$k].V6)) { [Net.IPAddress]::Parse($ip).AddressFamily | Should -Be 'InterNetworkV6' -Because $k }
            $p[$k].Title | Should -Not -BeNullOrEmpty
        }
    }

    It 'cambia el DNS de cada adaptador y deshacer devuelve lo de cada uno' {
        $m = New-NetMachine
        $before = Get-MachineSnapshot $m
        $t = New-JuicerDnsTweak 'Cloudflare'
        @($t.Actions).Count | Should -Be 2
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $cur = @(Get-JuicerCurrentDns)
        @($cur | ForEach-Object { $_.Provider }) | Should -Be @('Cloudflare', 'Cloudflare')
        # Switching provider keeps what was there before Win Juicer.
        (Invoke-JuicerTweak (New-JuicerDnsTweak 'Quad9')).Outcome | Should -Be 'Aplicado'
        (Read-JuicerJournal)[0].Title | Should -Be 'DNS: Quad9, bloquea malware'
        (Undo-JuicerTweak 'red.dns').Outcome | Should -Be 'Deshecho'
        Get-MachineSnapshot $m | Should -Be $before
        (@(Get-JuicerCurrentDns) | Where-Object { $_.Adapter -eq 'Wi-Fi' }).V4 | Should -Be @('192.168.1.1', '8.8.8.8')
    }

    It 'lee también el formato antiguo, separado por espacios' {
        $m = New-NetMachine
        Write-JuicerReg 'HKLM\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces\{X}' 'NameServer' 'String' '9.9.9.9 149.112.112.112'
        (Get-JuicerDnsServers '{X}').V4 | Should -Be @('9.9.9.9', '149.112.112.112')
        @((Get-JuicerDnsServers '{Y}').V4).Count | Should -Be 0
    }

    It 'automático es una opción más, y sin adaptadores no aplica' {
        $m = New-NetMachine
        $r = Invoke-JuicerTweak (New-JuicerDnsTweak 'Automatico')
        $r.Outcome | Should -Be 'Aplicado'
        $r.Changes | Should -Be @('DNS de Wi-Fi: automático (DHCP)')
        $m.Backend.State.Adapters.Clear()
        (Invoke-JuicerTweak (New-JuicerDnsTweak 'Google')).Outcome | Should -Be 'NoAplica'
        { New-JuicerDnsTweak 'NoExiste' } | Should -Throw '*desconocido*'
    }
}

Describe 'Características de Windows' {
    It 'se activan y se desactivan, y deshacer las deja como estaban' {
        $m = New-FakeMachine
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
        $m.Backend.State.Features['NetFx3'] = @{ Enabled = $false }
        $t = Find-JuicerTweak 'comp.netfx3'
        (Invoke-JuicerTweak $t).Outcome | Should -Be 'Aplicado'
        $m.Backend.State.Features['NetFx3'].Enabled | Should -BeTrue
        [void](Undo-JuicerTweak 'comp.netfx3')
        $m.Backend.State.Features['NetFx3'].Enabled | Should -BeFalse
        (Get-JuicerTweakState (Find-JuicerTweak 'comp.hyperv')).State | Should -Be 'NoAplica'
    }
}

Describe 'winget' {
    It 'la lista está bien formada y sin repetidos' {
        $apps = @(Get-JuicerWingetApps)
        (@($apps | ForEach-Object { $_.Id }) | Select-Object -Unique).Count | Should -Be $apps.Count
        $cats = & (Get-Module WinJuicer) { $script:WingetCategories }
        foreach ($a in $apps) {
            Test-JuicerWingetId $a.Id | Should -BeTrue -Because $a.Id
            $a.Category | Should -BeIn $cats
            $a.Name | Should -Not -BeNullOrEmpty
            $a.What | Should -Not -BeNullOrEmpty
        }
    }

    It 'lo sugerido existe en la lista' {
        $hw = @{ Gpus = @(@{ Vendor = 'NVIDIA'; Discrete = $true }); SystemDisk = @{ Media = 'SSD' }; Modules = @(1, 2); Laptop = $false }
        $ids = @(Get-JuicerWingetApps | ForEach-Object { $_.Id })
        foreach ($k in (Get-JuicerAppSuggestions $hw).Keys) { $ids | Should -Contain $k }
    }

    It 'el guion de la ventana es PowerShell válido y no acepta identificadores raros' {
        foreach ($case in @(@('install', @('Valve.Steam', 'Notepad++.Notepad++')), @('uninstall', @('Discord.Discord')), @('upgrade', @()))) {
            $text = New-JuicerWingetScript $case[0] $case[1]
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
            foreach ($id in $case[1]) { $text | Should -BeLike "*'$id'*" }
        }
        (New-JuicerWingetScript 'upgrade' @()) | Should -BeLike '*upgrade --all*'
        { New-JuicerWingetScript 'install' @('Valve.Steam; Remove-Item C:\') } | Should -Throw
        Test-JuicerWingetId 'msstore:9NKSQGP7F2NH' | Should -BeFalse
    }
}

Describe 'Exportar e importar' {
    It 'lo de un equipo se aplica en otro, y lo que es de este PC no viaja' {
        $m = New-NetMachine
        $m.Backend.State.Appx['Clipchamp.Clipchamp'] = @{ Installed = $true; Provisioned = $true }
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 0
        foreach ($t in (Find-JuicerTweak 'juegos.ventana'), (Find-JuicerTweak 'ui.menu'), (New-JuicerDnsTweak 'Quad9'),
            (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Clipchamp.Clipchamp')), (New-JuicerPriorityTweak 'C:\Juegos\x.exe')) {
            [void](Invoke-JuicerTweak $t)
        }
        [void](Set-JuicerToggle (Find-JuicerTweak 'pref.oscuro') $true)
        [void](Set-JuicerToggle (Find-JuicerTweak 'pref.extensiones') $false)
        $file = Join-Path (Get-JuicerHome) 'config.json'
        $cfg = Export-JuicerConfig $file
        @($cfg.Tweaks) | Should -Be @('juegos.ventana', 'ui.menu')
        $cfg.Toggles['pref.oscuro'] | Should -BeTrue
        $cfg.Toggles['pref.extensiones'] | Should -BeFalse
        $cfg.Dns | Should -Be 'Quad9'
        @($cfg.Apps) | Should -Be @('Clipchamp.Clipchamp')

        # The other PC.
        $m2 = New-NetMachine
        $m2.Backend.State.Appx['Clipchamp.Clipchamp'] = @{ Installed = $true; Provisioned = $false }
        Write-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt' 'DWord' 0
        @(Start-Juicer -Importar $file -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        foreach ($id in 'juegos.ventana', 'ui.menu', 'pref.oscuro') { (Get-JuicerTweakState (Find-JuicerTweak $id)).State | Should -Be 'Aplicado' -Because $id }
        (Read-JuicerReg 'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' 'HideFileExt').Value | Should -Be 1
        @(Get-JuicerCurrentDns)[0].Provider | Should -Be 'Quad9'
        $m2.Backend.State.Appx.ContainsKey('Clipchamp.Clipchamp') | Should -BeFalse
        Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\x.exe\PerfOptions' 'CpuPriorityClass' | Should -BeNullOrEmpty
        # And it all undoes like anything else.
        [void](Undo-JuicerAll)
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'simular no cambia nada, ni las preferencias' {
        $m = New-NetMachine
        $file = Join-Path (Get-JuicerHome) 'config-sim.json'
        [IO.File]::WriteAllText($file, '{ "Version": 1, "Tweaks": ["ui.menu"], "Toggles": { "pref.oscuro": true }, "Apps": [], "Dns": "Google" }')
        $before = Get-MachineSnapshot $m
        @(Start-Juicer -Importar $file -Simular -Si 6>$null)[-1] | Should -Be 0
        Get-MachineSnapshot $m | Should -Be $before
    }

    It 'lo desconocido se ignora con aviso, y un archivo que no es suyo se rechaza' {
        $m = New-NetMachine
        $file = Join-Path (Get-JuicerHome) 'config-raro.json'
        [IO.File]::WriteAllText($file, '{ "Version": 1, "Tweaks": ["ui.menu", "no.existe", "pref.oscuro"], "Toggles": { "ui.menu": true }, "Apps": ["Nada.Nada"], "Dns": "Raro" }')
        $cfg = Read-JuicerConfig $file
        @($cfg.Tweaks) | Should -Be @('ui.menu')
        $cfg.Toggles.Count | Should -Be 0
        @($cfg.Unknown) | Should -Be @('no.existe', 'pref.oscuro', 'ui.menu', 'app:Nada.Nada', 'dns:Raro')
        Format-JuicerConfigSummary $cfg | Should -BeLike '*Menú contextual clásico*no conoce*'
        [IO.File]::WriteAllText($file, '{ "otra": "cosa" }')
        { Read-JuicerConfig $file } | Should -Throw '*Win Juicer*'
        @(Start-Juicer -Importar $file -Si 6>$null)[-1] | Should -Be 2
    }
}

Describe 'Arranque en una línea' {
    It 'el zip lleva lo necesario, y el arrancador su huella, en ASCII y sin BOM' {
        $out = Join-Path ([IO.Path]::GetTempPath()) ('wj-dist-' + [guid]::NewGuid().ToString('N'))
        try {
            $r = & (Join-Path $Root 'build/Build-Release.ps1') -Out $out -Version 'abc1234'
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $z = [IO.Compression.ZipFile]::OpenRead($r.Zip)
            try { $names = @($z.Entries | ForEach-Object { $_.FullName }) } finally { $z.Dispose() }
            foreach ($n in 'WinJuicer.cmd', 'WinJuicer.ps1', 'WinJuicer.psm1', 'src/Gui.ps1', 'src/Engine.ps1', 'version.txt') { $names | Should -Contain $n }
            $z = [IO.Compression.ZipFile]::OpenRead($r.Zip)
            try {
                $sr = New-Object IO.StreamReader ($z.GetEntry('version.txt').Open())
                try { $sr.ReadToEnd() | Should -Be 'abc1234' } finally { $sr.Dispose() }
            } finally { $z.Dispose() }
            @($names | Where-Object { $_ -like 'tests*' -or $_ -like 'build*' -or $_ -match '\\' }).Count | Should -Be 0
            @($names | Where-Object { $_ -like 'src/*' }).Count | Should -Be @(Get-ChildItem (Join-Path $Root 'src') -Filter *.ps1).Count

            $bytes = [IO.File]::ReadAllBytes($r.Launcher)
            @($bytes | Where-Object { $_ -gt 127 }).Count | Should -Be 0
            $bytes[0] | Should -Not -Be 0xEF
            $text = [IO.File]::ReadAllText($r.Launcher)
            $text | Should -BeLike "*-Sha256 '$((Get-FileHash $r.Zip -Algorithm SHA256).Hash)' -Version 'abc1234'*"
            $text | Should -Not -BeLike '*__SHA256__*'
            ConvertFrom-JuicerLauncherVersion $text | Should -Be 'abc1234'
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $out -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Línea de órdenes' {
    It '-Equipo, -QuitarApps, -Dns y -Recomendado' {
        $m = New-NetMachine
        @(Start-Juicer -Equipo 6>$null)[-1] | Should -Be 0
        @(Start-Juicer -QuitarApps 'Microsoft.NoExiste' -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -Dns 'NoExiste' -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -Instalar 'mal id' -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -Recomendado -Simular -Si 6>$null)[-1] | Should -Be 0
        (Read-JuicerJournal).Count | Should -Be 0
        @(Start-Juicer -Dns 'Cloudflare' -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        @(Get-JuicerCurrentDns)[0].Provider | Should -Be 'Cloudflare'
        $m.Backend.State.Appx['Clipchamp.Clipchamp'] = @{ Installed = $true; Provisioned = $false }
        @(Start-Juicer -QuitarApps 'Clipchamp.Clipchamp' -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        $m.Backend.State.Appx.ContainsKey('Clipchamp.Clipchamp') | Should -BeFalse
    }
}

Describe 'Ventana (sin pantalla)' {
    It 'el XAML es XML válido y nombra cada control que el código usa' {
        $names = @(Get-JuicerGuiNames)
        $names.Count | Should -BeGreaterThan 40
        ($names | Select-Object -Unique).Count | Should -Be $names.Count
        $code = [IO.File]::ReadAllText((Join-Path $Root 'src/Gui.ps1'))
        $used = @([regex]::Matches($code, '(?:\$script:Gui\.C|\$c)\.([A-Z][A-Za-z]+)') | ForEach-Object { $_.Groups[1].Value } | Where-Object { $_ -notin 'Keys', 'Values' } | Select-Object -Unique)
        $used.Count | Should -BeGreaterThan 20
        foreach ($u in $used) { $names | Should -Contain $u -Because "el código usa $u" }
        $handlers = @([regex]::Matches($code, '(?m)^\s{8}(Btn[A-Za-z]+)\s+=\s+\{') | ForEach-Object { $_.Groups[1].Value })
        $handlers.Count | Should -BeGreaterThan 25
        foreach ($h in $handlers) { $names | Should -Contain $h }
        foreach ($b in @($names | Where-Object { $_ -like 'Btn*' })) { $handlers | Should -Contain $b -Because "$b necesita qué hacer" }
    }

    It 'modo avanzado: busca sin romperse, filtra por nivel y estado, y sabe qué cambia cada ajuste' {
        Test-JuicerContains 'Carpetas grandes' 'CARPETAS' | Should -BeTrue
        Test-JuicerContains 'Carpetas grandes' '[' | Should -BeFalse
        Test-JuicerContains 'abc' '' | Should -BeTrue
        Test-JuicerContains '' 'x' | Should -BeFalse
        $t = Find-JuicerTweak 'ui.carpetas'
        Test-JuicerTweakFilter $t 'carpetas' '' '' 'Pendiente' 'Opcional' $false | Should -BeTrue
        Test-JuicerTweakFilter $t 'ui.carp' '' '' 'Pendiente' 'Opcional' $false | Should -BeTrue
        Test-JuicerTweakFilter $t 'no-existe' '' '' 'Pendiente' 'Opcional' $false | Should -BeFalse
        Test-JuicerTweakFilter $t '' '2' '' 'Pendiente' 'Opcional' $false | Should -BeTrue
        Test-JuicerTweakFilter $t '' '3' '' 'Pendiente' 'Opcional' $false | Should -BeFalse
        Test-JuicerTweakFilter $t '' '' 'Pendiente' 'Parcial' 'Opcional' $false | Should -BeTrue
        Test-JuicerTweakFilter $t '' '' 'Aplicado' 'Pendiente' 'Opcional' $false | Should -BeFalse
        Test-JuicerTweakFilter $t '' '' 'Recomendado' 'Pendiente' 'Opcional' $false | Should -BeFalse
        Test-JuicerTweakFilter $t '' '' 'Marcado' 'Pendiente' 'Opcional' $true | Should -BeTrue
        $ch = Get-JuicerTweakChanges
        $ch.Count | Should -Be @(Get-JuicerCatalog).Count
        $ch['ui.carpetas'] | Should -BeLike '*\FolderType = "NotSpecified"'
        @($ch['pref.esteequipo'])[0] | Should -BeLike '*LaunchTo = 1*'
    }

    It 'guarda una selección como perfil, y la lee como una configuración más' {
        $file = Join-Path ([IO.Path]::GetTempPath()) ('wj-seleccion-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            $cfg = New-JuicerSelectionConfig @('ui.carpetas', 'juegos.raton', 'pref.oscuro', 'no.existe', 'ui.carpetas')
            @($cfg.Tweaks) | Should -Be @('ui.carpetas', 'juegos.raton')
            [IO.File]::WriteAllText($file, (ConvertTo-JuicerJson $cfg))
            $back = Read-JuicerConfig $file
            @($back.Tweaks) | Should -Be @('ui.carpetas', 'juegos.raton')
            $back.Toggles.Count | Should -Be 0
        } finally {
            Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue
        }
    }

    It 'la ventana cabe en pantallas pequeñas y vuelve a abrirse donde estaba' {
        $big = @{ Left = 0; Top = 0; Width = 1920; Height = 1040 }
        $screens = @{ Left = 0; Top = 0; Width = 1920; Height = 1080 }
        $p = Get-JuicerWindowPlacement $null $big $screens
        $p.Width | Should -Be 1220; $p.Height | Should -Be 800; $p.Manual | Should -BeFalse
        # A 1366x768 laptop at 125 %: 1093x614 of work area.
        $small = Get-JuicerWindowPlacement $null @{ Left = 0; Top = 0; Width = 1093; Height = 574 } @{ Left = 0; Top = 0; Width = 1093; Height = 614 }
        $small.Height | Should -Be 574
        $small.MinHeight | Should -Be 574
        $small.Width | Should -Be 1093
        $small.MinWidth | Should -Be 960
        # Where it was, if that is still on a screen; maximized, too.
        $back = Get-JuicerWindowPlacement @{ Left = 300; Top = 120; Width = 1400; Height = 900; Maximized = $true } $big $screens
        $back.Manual | Should -BeTrue
        $back.Left | Should -Be 300
        $back.Width | Should -Be 1400
        $back.Maximized | Should -BeTrue
        # A screen that is no longer there: centred instead.
        (Get-JuicerWindowPlacement @{ Left = 2500; Top = 100; Width = 1220; Height = 800 } $big $screens).Manual | Should -BeFalse
        (Get-JuicerWindowPlacement @{ Left = 100; Top = -500; Width = 1220; Height = 800 } $big $screens).Manual | Should -BeFalse
        # A size too small to be real is ignored.
        (Get-JuicerWindowPlacement @{ Width = 10; Height = 10 } $big $screens).Width | Should -Be 1220
    }

    It 'las preferencias de la ventana no se pisan entre sí' {
        Remove-Item -LiteralPath (Get-JuicerUiPrefsPath) -ErrorAction SilentlyContinue
        Save-JuicerUiPrefs @{ Advanced = $true }
        Save-JuicerUiPrefs @{ Window = @{ Left = 10; Top = 20; Width = 1300; Height = 850; Maximized = $false } }
        $p = Read-JuicerUiPrefs
        $p.Advanced | Should -BeTrue
        $p.Window.Width | Should -Be 1300
        Save-JuicerUiPrefs @{ Advanced = $false }
        (Read-JuicerUiPrefs).Window.Left | Should -Be 10
        Set-Content -LiteralPath (Get-JuicerUiPrefsPath) -Value 'no es json'
        (Read-JuicerUiPrefs).Advanced | Should -BeFalse
        Remove-Item -LiteralPath (Get-JuicerUiPrefsPath) -ErrorAction SilentlyContinue
    }

    It 'resume resultados con sus avisos de reinicio' {
        $text = Format-JuicerResultsText @(
            @{ Title = 'A'; Outcome = 'Aplicado'; Reboot = 'Reinicio' }
            @{ Title = 'B'; Outcome = 'YaEstaba'; Reboot = 'No' }
            @{ Title = 'C'; Outcome = 'Error'; Message = 'falló'; Reboot = 'No' }
            @{ Title = 'D'; Outcome = 'Simulado'; Reboot = 'Explorador'; Changes = @('x = 1') }
        )
        $text | Should -BeLike '*✓ A*'
        $text | Should -BeLike '*= B — ya estaba así*'
        $text | Should -BeLike '*✗ C*falló*'
        $text | Should -BeLike '*· x = 1*'
        $text | Should -BeLike '*Reinicia el equipo para completar: A.*'
        $text | Should -Not -BeLike '*Explorador para: D*'
    }

    It 'lee la lista que devuelve Windows PowerShell sin meterla en otra lista' {
        $l = ConvertFrom-JuicerWinPsJson '[{"Name":"a","Installed":true},{"Name":"b","Installed":false}]'
        $l.Count | Should -Be 2
        $l[0] | Should -BeOfType [hashtable]
        $l[1].Name | Should -Be 'b'
        $l[0].Installed | Should -BeTrue
        $one = ConvertFrom-JuicerWinPsJson '{"Name":"a"}'
        $one.Count | Should -Be 1
        $one[0].Name | Should -Be 'a'
        (ConvertFrom-JuicerWinPsJson '').Count | Should -Be 0
        (ConvertFrom-JuicerWinPsJson '[]').Count | Should -Be 0
    }

    It 'las cuentas concuerdan con el número' {
        Format-JuicerCount 1 'cambio' | Should -Be '1 cambio'
        Format-JuicerCount 0 'cambio' | Should -Be '0 cambios'
        Format-JuicerCount 3 'juego encontrado' 'juegos encontrados' | Should -Be '3 juegos encontrados'
        Format-JuicerCount 1 'juego encontrado' 'juegos encontrados' | Should -Be '1 juego encontrado'
        (Format-JuicerHardwareSummary @{ Cpu = @{}; Gpus = @(); RamBytes = 16GB; Modules = @(@{ Size = 16GB }) }) -join ' ' | Should -BeLike '*GB en 1 módulo *'
    }

    It 'resume el equipo en una línea, sin marcas registradas ni adaptadores virtuales' {
        $hw = @{
            Cpu = @{ Name = 'AMD Ryzen 7 7800X3D 8-Core Processor'; Cores = 8 }; RamBytes = 32GB
            Gpus = @(@{ Name = 'Microsoft Basic Display Adapter' }, @{ Name = 'Intel(R) UHD Graphics 770' }, @{ Name = 'NVIDIA GeForce RTX 4070'; Discrete = $true })
            Monitor = @{ Display = @{ MaxHz = 165 }; Vrr = @{ Kind = 'G-SYNC Compatible' } }
        }
        Format-JuicerHardwareShort $hw | Should -Be 'AMD Ryzen 7 7800X3D (8 núcleos) · 32 GB de RAM · NVIDIA GeForce RTX 4070 · pantalla de 165 Hz con VRR'
        Format-JuicerHardwareShort @{ Cpu = @{ Name = 'Intel(R) Core(TM) i7-8700 CPU @ 3.20GHz'; Cores = 6 }; Gpus = @(@{ Name = 'Intel(R) UHD Graphics 630' }) } | Should -Be 'Intel Core i7-8700 (6 núcleos) · Intel UHD Graphics 630'
        Format-JuicerHardwareShort @{ Cpu = @{ Name = 'AMD Ryzen 5 5600G with Radeon Graphics' }; Gpus = @() } | Should -Be 'AMD Ryzen 5 5600G'
        Format-JuicerHardwareShort @{ Cpu = @{}; Gpus = @() } | Should -Be ''
    }

    It 'Optimizar ahora aplica lo mismo que Empezar cuenta: lo recomendado sin el nivel Extremo' {
        $t = @(@{ Id = 'a'; Level = 1 }, @{ Id = 'b'; Level = 3 }, @{ Id = 'c'; Level = 2 }, @{ Id = 'd'; Level = 2 })
        $states = @{ a = @{ State = 'Pendiente' }; b = @{ State = 'Pendiente' }; c = @{ State = 'Parcial' }; d = @{ State = 'Aplicado' } }
        $advice = @{ a = @{ Verdict = 'Recomendado' }; b = @{ Verdict = 'Recomendado' }; c = @{ Verdict = 'Recomendado' }; d = @{ Verdict = 'Recomendado' } }
        @(Get-JuicerHomeSelection $t $states $advice) | Should -Be @('a', 'c')
    }

    It 'los botones de selección marcan lo que toca y sólo lo pendiente' {
        $t = @(
            @{ Id = 'a'; Level = 1 }, @{ Id = 'b'; Level = 2 }, @{ Id = 'c'; Level = 3 }, @{ Id = 'd'; Level = 0 }, @{ Id = 'e'; Level = 1 }
        )
        $states = @{ a = @{ State = 'Pendiente' }; b = @{ State = 'Parcial' }; c = @{ State = 'Pendiente' }; d = @{ State = 'Pendiente' }; e = @{ State = 'Aplicado' } }
        $advice = @{ a = @{ Verdict = 'Recomendado' }; b = @{ Verdict = 'Opcional' }; c = @{ Verdict = 'Recomendado' }; d = @{ Verdict = 'Recomendado' }; e = @{ Verdict = 'Recomendado' } }
        Get-JuicerSelection 'Seguro' $t $states $advice | Should -Be @('a')
        Get-JuicerSelection 'Rendimiento' $t $states $advice | Should -Be @('a', 'b')
        Get-JuicerSelection 'Extremo' $t $states $advice | Should -Be @('a', 'b', 'c')
        Get-JuicerSelection 'Recomendado' $t $states $advice | Should -Be @('a', 'c')
        @(Get-JuicerSelection 'Ninguno' $t $states $advice).Count | Should -Be 0
    }
}

Describe 'Versión nueva' {
    It 'avisa sólo si la copia publicada es otra' {
        Get-JuicerVersion | Should -BeNullOrEmpty
        Get-JuicerUpdateNotice -Local $null -Latest { 'abc1234' } | Should -BeNullOrEmpty
        Get-JuicerUpdateNotice -Local 'dev' -Latest { 'abc1234' } | Should -BeNullOrEmpty
        Get-JuicerUpdateNotice -Local 'abc1234' -Latest { 'abc1234' } | Should -BeNullOrEmpty
        Get-JuicerUpdateNotice -Local 'abc1234' -Latest { $null } | Should -BeNullOrEmpty
        $n = Get-JuicerUpdateNotice -Local 'abc1234' -Latest { 'def5678' }
        $n.Latest | Should -Be 'def5678'
        $n.Command | Should -BeLike 'irm https://github.com/*/winjuicer.ps1 | iex'
        ConvertFrom-JuicerLauncherVersion 'sin versión' | Should -BeNullOrEmpty
    }
}

Describe 'Servicios que arrancan con Windows' {
    It 'reconoce los conocidos y deja fuera el resto' {
        (Get-JuicerKnownService 'AdobeARMservice' 'Adobe Acrobat Update Service').V | Should -Be 'Prescindible'
        (Get-JuicerKnownService 'SystemUsageReportSvc_QUEENCREEK' 'Intel(R) System Usage Report Service SystemUsageReportSvc_QUEENCREEK').V | Should -Be 'Prescindible'
        (Get-JuicerKnownService 'NahimicService' 'Nahimic service').V | Should -Be 'Opcional'
        Get-JuicerKnownService 'NVDisplay.ContainerLocalSystem' 'NVIDIA Display Container LS' | Should -BeNullOrEmpty
        Get-JuicerKnownService 'edgeupdate' 'Microsoft Edge Update Service (edgeupdate)' | Should -BeNullOrEmpty
        Get-JuicerKnownService 'Audiosrv' 'Windows Audio' | Should -BeNullOrEmpty
    }

    It 'lo pasa a manual y lo deja como estaba' {
        $m = New-NetMachine
        $m.Backend.State.Services['AdobeARMservice'] = @{ Start = 'Automatic'; Running = $true }
        $item = New-JuicerServiceItem 'AdobeARMservice' 'Adobe Acrobat Update Service' 'Automatic' (Get-JuicerKnownService 'AdobeARMservice')
        $item.Enabled | Should -BeTrue
        $item.Verdict | Should -Be 'Prescindible'
        (Set-JuicerStartupItem $item $false).Outcome | Should -Be 'Aplicado'
        $m.Backend.State.Services['AdobeARMservice'].Start | Should -Be 'Manual'
        (Set-JuicerStartupItem $item $true).Outcome | Should -Be 'Deshecho'
        $m.Backend.State.Services['AdobeARMservice'].Start | Should -Be 'Automatic'
        (Read-JuicerJournal).Count | Should -Be 0
    }
}

Describe 'Antes y después' {
    BeforeEach { Remove-Item -LiteralPath (Get-JuicerMetricsPath) -ErrorAction SilentlyContinue }

    It 'compara cada número con la medida inicial' {
        $before = @{ Date = '2026-10-01T10:00:00'; Label = 'Antes de aplicar ajustes'; BootMs = 42000; BootDate = [datetime]'2026-10-01T09:58:00'; Startup = 14; Processes = 250; Services = 120; RamUsed = 6GB; DiskFree = 100GB; UptimeMin = 5 }
        $after = @{ Date = '2026-10-02T10:00:00'; Label = 'Medida'; BootMs = 30000; BootDate = '2026-10-02T09:58:00'; Startup = 8; Processes = 251; Services = 125; RamUsed = 5GB; DiskFree = 110GB; UptimeMin = 240 }
        $f = @(Compare-JuicerMetrics $before $after)
        $f[0].Title | Should -BeLike 'Comparado con la medida del*'
        @($f | Where-Object { $_.Title -like 'Arranque completo: 42,0 s → 30,0 s (−12,0 s)' -or $_.Title -like 'Arranque completo: 42.0 s → 30.0 s (−12.0 s)' })[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Title -like 'Programas, tareas*' })[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Title -like 'Procesos*' })[0].Severity | Should -Be 'Info'
        @($f | Where-Object { $_.Title -like 'Servicios*' })[0].Severity | Should -Be 'Bajo'
        @($f | Where-Object { $_.Title -like 'Espacio libre*' })[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Title -like '*recién encendido*' }).Count | Should -Be 1
        # Same boot on both sides: nothing to compare yet, whatever type the date came back as.
        $after.BootDate = '2026-10-01T09:58:00'
        @(Compare-JuicerMetrics $before $after | Where-Object { $_.Title -like '*mismo arranque*' }).Count | Should -Be 1
    }

    It 'la primera medida es el punto de partida y se guarda sólo una vez' {
        @(Invoke-JuicerMeasure)[0].Title | Should -Be 'Medida inicial guardada'
        Save-JuicerBaseline
        @(Read-JuicerMetrics).Count | Should -Be 1
        @(Invoke-JuicerMeasure)[0].Title | Should -BeLike 'Comparado con*'
        foreach ($i in 1..12) { Save-JuicerMetrics @{ Date = (Get-Date).ToString('s'); Label = "m$i" } }
        $all = @(Read-JuicerMetrics)
        $all.Count | Should -Be 10
        $all[0].Label | Should -Be 'Medida inicial'
        $all[-1].Label | Should -Be 'm12'
        @(Invoke-JuicerMeasure -Reset)[0].Title | Should -Be 'Medida inicial guardada'
        @(Read-JuicerMetrics).Count | Should -Be 1
        @(Start-Juicer -Medir 6>$null)[-1] | Should -Be 0
    }
}

Describe 'FPS y frametimes' {
    BeforeAll {
        # Rows like PresentMon's CSV. Times in milliseconds, as text.
        function New-FrameRows {
            param([string]$App = 'game.exe', [double[]]$Times, [double]$GpuShare = 0.95, [string]$Mode = 'Hardware: Independent Flip',
                [string]$Tearing = '1', [string]$Sync = '0', [string]$FtName = 'FrameTime', [string]$GpuName = 'GPUBusy')
            foreach ($t in $Times) {
                $o = [ordered]@{ Application = $App; ProcessID = '100'; SyncInterval = $Sync; AllowsTearing = $Tearing; PresentMode = $Mode }
                $o[$FtName] = $t.ToString([Globalization.CultureInfo]::InvariantCulture)
                $o[$GpuName] = ($t * $GpuShare).ToString([Globalization.CultureInfo]::InvariantCulture)
                $o.DisplayLatency = '12.5'
                [pscustomobject]$o
            }
        }
        # 1 % of the frames slow: the lows show it, and it is a lot of stutters for 7 seconds.
        $script:Spiky = [double[]](@(7.0) * 990 + @(30.0) * 10)
        # Two minutes with the odd hitch.
        $script:Steady = [double[]](@(7.0) * 17000 + @(30.0) * 4)
    }

    It 'elige el juego y no el escritorio ni el explorador' {
        $rows = @(New-FrameRows -Times $Spiky) + @(New-FrameRows 'dwm.exe' ([double[]](@(7.0) * 2000))) + @(New-FrameRows 'explorer.exe' ([double[]](@(16.0) * 1500)))
        $g = @(Select-JuicerGameRows $rows)
        $g.Count | Should -Be 1000
        $g[0].Application | Should -Be 'game.exe'
        @(Select-JuicerGameRows $rows 'explorer').Count | Should -Be 1500
        @(Select-JuicerGameRows @() $null).Count | Should -Be 0
    }

    It 'calcula media, 1 % y 0,1 % bajos y tirones' {
        $r = Measure-JuicerFrames @(New-FrameRows -Times $Spiky)
        $r.Frames | Should -Be 1000
        $r.AvgFps | Should -Be 138.3
        $r.Low1 | Should -Be 142.9
        $r.Low01 | Should -Be 33.3
        $r.Stutters | Should -Be 10
        $r.GpuBound | Should -Be 100
        $r.Latency | Should -Be 12.5
        $r.PresentMode | Should -Be 'Hardware: Independent Flip'
        Measure-JuicerFrames @(New-FrameRows -Times ([double[]](@(7.0) * 5))) | Should -BeNullOrEmpty
    }

    It 'lee también las columnas de PresentMon 2.4 en adelante' {
        $r = Measure-JuicerFrames @(New-FrameRows -Times $Spiky -FtName 'MsBetweenAppStart' -GpuName 'MsGPUBusy' -GpuShare 0.4)
        $r.AvgFps | Should -Be 138.3
        $r.GpuBound | Should -Be 0
    }

    It 'dice qué limita y cómo se muestra' {
        $gpu = Measure-JuicerFrames @(New-FrameRows -Times $Steady)
        $f = @(Get-JuicerFrameFindings $gpu $null 165)
        $f[0].Title | Should -BeLike 'Media 143 FPS*'
        @($f | Where-Object { $_.Title -like 'La gráfica es el límite*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Frametimes estables*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Presentación directa*' }).Count | Should -Be 1

        $cpu = Measure-JuicerFrames @(New-FrameRows -Times $Steady -GpuShare 0.5 -Mode 'Composed: Copy with GPU GDI')
        $f = @(Get-JuicerFrameFindings $cpu $null 60 @(@{ Name = 'chrome'; Pct = 9.5 }))
        $c = @($f | Where-Object { $_.Title -like 'El procesador es el límite*' })
        $c.Count | Should -Be 1
        $c[0].Detail | Should -BeLike '*chrome 9.5 %*'
        @($f | Where-Object { $_.Title -like '*copiando*' })[0].Severity | Should -Be 'Medio'
        @($f | Where-Object { $_.Title -like 'Pasa de los 60 Hz*' }).Count | Should -Be 1
        # Not twice: the background list is already in the processor finding.
        @($f | Where-Object { $_.Title -like 'En segundo plano*' }).Count | Should -Be 0
    }

    It 'reconoce la sincronización vertical y los tirones' {
        $v = Measure-JuicerFrames @(New-FrameRows -Times ([double[]](@(16.67) * 600)) -Sync '1' -Tearing '0' -GpuShare 0.3)
        @(Get-JuicerFrameFindings $v $null 60 | Where-Object { $_.Title -like '*sincronización vertical a 60 Hz' }).Count | Should -Be 1
        @(Get-JuicerFrameFindings $v $null 60 | Where-Object { $_.Title -like 'El procesador*' }).Count | Should -Be 0

        $bad = Measure-JuicerFrames @(New-FrameRows -Times ([double[]](@(8.0) * 900 + @(40.0) * 100)))
        @(Get-JuicerFrameFindings $bad $null 144 | Where-Object { $_.Title -like 'Frametimes irregulares*' })[0].Severity | Should -Be 'Alto'
    }

    It 'compara con la medida anterior del mismo juego' {
        Remove-Item -LiteralPath (Get-JuicerFrameHistoryPath) -ErrorAction SilentlyContinue
        $old = Measure-JuicerFrames @(New-FrameRows -Times ([double[]](@(10.0) * 1000)))
        $old.Date = '2026-10-01T20:00:00'
        Save-JuicerFrameResult $old
        Save-JuicerFrameResult @{ Application = 'otro.exe'; AvgFps = 50; Low1 = 40; Date = '2026-10-02T20:00:00' }
        $prev = Get-JuicerPreviousFrameResult 'game.exe'
        $prev.AvgFps | Should -Be 100
        $new = Measure-JuicerFrames @(New-FrameRows -Times $Steady)
        $cmp = @(Get-JuicerFrameFindings $new $prev 165 | Where-Object { $_.Title -like 'Respecto al*' })
        $cmp[0].Severity | Should -Be 'Ok'
        $cmp[0].Title | Should -BeLike '*100 → 143 FPS (+43 %)*'
        Get-JuicerPreviousFrameResult 'nunca.exe' | Should -BeNullOrEmpty
    }

    It 'calcula qué gastó CPU en segundo plano y lee la gráfica de NVIDIA' {
        $before = @(@{ Id = 1; Name = 'chrome'; Cpu = 10.0 }, @{ Id = 2; Name = 'game'; Cpu = 100.0 }, @{ Id = 3; Name = 'Idle'; Cpu = 0.0 }, @{ Id = 4; Name = 'notepad'; Cpu = 1.0 })
        $after = @(@{ Id = 1; Name = 'chrome'; Cpu = 22.0 }, @{ Id = 2; Name = 'game'; Cpu = 500.0 }, @{ Id = 3; Name = 'Idle'; Cpu = 900.0 }, @{ Id = 4; Name = 'notepad'; Cpu = 1.1 })
        $h = @(Get-JuicerCpuHogs $before $after 60 4 'game.exe')
        $h.Count | Should -Be 1
        $h[0].Name | Should -Be 'chrome'
        $h[0].Pct | Should -Be 5
        $g = ConvertFrom-JuicerGpuSamples @('70, 99, 2700', '84, 99, 2600', '88, 98, 1900', '86, 40, 1500')
        $g.MaxTemp | Should -Be 88
        $g.LowBusyClock | Should -Be 1900
        $f = @(Get-JuicerFrameFindings (Measure-JuicerFrames @(New-FrameRows -Times $Steady)) $null 0 @() $g)
        @($f | Where-Object { $_.Title -like '*88 °C' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*bajó a 1.900 MHz*' -or $_.Title -like '*bajó a 1,900 MHz*' }).Count | Should -Be 1
        ConvertFrom-JuicerGpuSamples @('basura') | Should -BeNullOrEmpty
    }
}

Describe 'Monitor' {
    BeforeAll {
        # An EDID like a real one: base block plus a CTA-861 extension.
        function New-TestEdid {
            param([string]$Vendor = 'AUS', [string]$Name = 'VG27AQ', [int]$RangeMin = 48, [int]$RangeMax = 165,
                [int[]]$AmdVsdb = @(48, 165), [int[]]$HdmiVrr = @(), [int]$HdrLum = 0, [switch]$NoCta)
            $e = [byte[]]::new($(if ($NoCta) { 128 } else { 256 }))
            1..6 | ForEach-Object { $e[$_] = 0xFF }
            $w = (([int][char]$Vendor[0] - 64) -shl 10) -bor (([int][char]$Vendor[1] - 64) -shl 5) -bor ([int][char]$Vendor[2] - 64)
            $e[8] = $w -shr 8; $e[9] = $w -band 0xFF
            # Preferred timing 2560×1440.
            $e[54] = 0x56; $e[55] = 0x5E; $e[56] = 0x00; $e[58] = 0xA0; $e[59] = 0xA0; $e[61] = 0x50
            # Range limits, then the name.
            $e[75] = 0xFD; $e[77] = $RangeMin; $e[78] = $RangeMax
            $e[93] = 0xFC
            $bytes = [Text.Encoding]::ASCII.GetBytes($Name + "`n")
            for ($i = 0; $i -lt $bytes.Count -and $i -lt 13; $i++) { $e[95 + $i] = $bytes[$i] }
            if ($NoCta) { return $e }
            $e[126] = 1
            $b = 128; $e[$b] = 0x02; $e[$b + 1] = 3
            $i = $b + 4
            if ($AmdVsdb.Count -eq 2) {
                $blk = @(0x1A, 0x00, 0x00, 0x02, 0x00, $AmdVsdb[0], $AmdVsdb[1], 0x00)
                $e[$i] = (3 -shl 5) -bor $blk.Count; for ($k = 0; $k -lt $blk.Count; $k++) { $e[$i + 1 + $k] = $blk[$k] }; $i += 1 + $blk.Count
            }
            if ($HdmiVrr.Count -eq 2) {
                $blk = @(0xD8, 0x5D, 0xC4, 0x01, 0x78, 0x80, 0x00, 0x30, 0x00, ((($HdmiVrr[1] -shr 8) -shl 6) -bor $HdmiVrr[0]), ($HdmiVrr[1] -band 0xFF))
                $e[$i] = (3 -shl 5) -bor $blk.Count; for ($k = 0; $k -lt $blk.Count; $k++) { $e[$i + 1 + $k] = $blk[$k] }; $i += 1 + $blk.Count
            }
            if ($HdrLum -gt 0) {
                $blk = @(0x06, 0x05, 0x01, $HdrLum)
                $e[$i] = (7 -shl 5) -bor $blk.Count; for ($k = 0; $k -lt $blk.Count; $k++) { $e[$i + 1 + $k] = $blk[$k] }; $i += 1 + $blk.Count
            }
            $e[$b + 2] = $i - $b
            $e
        }
        function New-TestMonitor {
            param([byte[]]$Edid, [int]$Hz = 165, [int[]]$Rates = @(60, $Hz), [string]$Id = 'AUS27B1')
            $info = ConvertFrom-JuicerEdidInfo $Edid
            $d = [pscustomobject]@{ Monitor = 'Monitor genérico PnP'; Hz = $Hz; MaxHz = $Hz; Primary = $true; RefreshRates = $Rates; MonitorId = "\\?\DISPLAY#$Id#5&1&0&UID1#{e6f07b5f-ee97-4a90-b076-33f57bf4eaa7}" }
            @{ Display = $d; Info = $info; Vrr = (Get-JuicerVrrRange $info) }
        }
    }

    BeforeEach { Remove-Item -LiteralPath (Get-JuicerMonitorModesPath) -ErrorAction SilentlyContinue }

    It 'lee marca, modelo, FreeSync, VRR de HDMI y HDR del EDID' {
        $i = ConvertFrom-JuicerEdidInfo (New-TestEdid -HdrLum 80)
        $i.Vendor | Should -Be 'AUS'
        $i.Brand | Should -Be 'ASUS'
        $i.Name | Should -Be 'VG27AQ'
        $i.RangeMin | Should -Be 48
        $i.FreeSync | Should -BeTrue
        $i.FreeSyncMax | Should -Be 165
        $i.Hdr10 | Should -BeTrue
        $i.MaxNits | Should -Be 283
        $v = Get-JuicerVrrRange $i
        "$($v.Kind) $($v.Min)-$($v.Max)" | Should -Be 'FreeSync 48-165'

        $h = ConvertFrom-JuicerEdidInfo (New-TestEdid -Vendor 'GSM' -Name 'OLED48C1' -AmdVsdb @() -HdmiVrr @(40, 300))
        $h.HdmiVrrMin | Should -Be 40
        $h.HdmiVrrMax | Should -Be 300
        (Get-JuicerVrrRange $h).Kind | Should -Be 'HDMI 2.1 VRR'

        Get-JuicerVrrRange (ConvertFrom-JuicerEdidInfo (New-TestEdid -NoCta)) | Should -BeNullOrEmpty
        ConvertFrom-JuicerEdidInfo ([byte[]]::new(128)) | Should -BeNullOrEmpty
    }

    It 'da los pasos según la gráfica y lo que tiene el monitor' {
        $m = New-TestMonitor (New-TestEdid -HdrLum 80)
        (Format-JuicerMonitor $m) | Should -Be 'ASUS VG27AQ: 165 Hz, FreeSync 48–165 Hz con LFC, HDR10 (~283 nits)'
        $f = @(Get-JuicerMonitorFindings @($m) 'NVIDIA' @(@{ Application = 'cs2.exe'; Low1 = 200; AvgFps = 300 }))
        $f[0].Detail | Should -BeLike '*G-SYNC*Reflex*157 FPS*'
        $strobe = @($f | Where-Object { $_.Title -like '*ELMB*' })
        $strobe.Count | Should -Be 1
        $strobe[0].Detail | Should -BeLike '*cs2.exe*'
        @($f | Where-Object { $_.Title -like 'HDR de entrada*' }).Count | Should -Be 1
        @(Get-JuicerMonitorFindings @($m) 'AMD')[0].Detail | Should -BeLike '*AMD FreeSync*'

        $narrow = New-TestMonitor (New-TestEdid -Vendor 'SAM' -Name 'S24' -RangeMin 48 -RangeMax 75 -AmdVsdb @(48, 75)) 75
        @(Get-JuicerMonitorFindings @($narrow) 'NVIDIA' | Where-Object { $_.Title -like 'Por debajo de 48 FPS*' }).Count | Should -Be 1

        $plain = New-TestMonitor (New-TestEdid -Vendor 'DEL' -Name 'P2422H' -NoCta) 60
        $p = @(Get-JuicerMonitorFindings @($plain) 'Intel')
        $p[0].Detail | Should -BeLike 'No anuncia FreeSync*'
        @($p | Where-Object { $_.Title -like 'Nitidez*' }).Count | Should -Be 0

        $oled = New-TestMonitor (New-TestEdid -Vendor 'GSM' -Name 'OLED48C1' -AmdVsdb @() -HdmiVrr @(40, 120)) 120
        @(Get-JuicerMonitorFindings @($oled) 'NVIDIA' | Where-Object { $_.Title -like 'OLED*' }).Count | Should -Be 1
    }

    It 'guarda cómo usas cada monitor, que el EDID no dice' {
        $m = New-TestMonitor (New-TestEdid -Name 'VG27AQ3A' -RangeMax 180 -AmdVsdb @(48, 180)) 180
        Get-JuicerMonitorKey $m | Should -Be 'AUS27B1|VG27AQ3A'
        Get-JuicerMonitorMode $m | Should -Be 'Automatico'
        Resolve-JuicerMonitorUse $m | Should -Be 'VRR'
        Set-JuicerMonitorMode $m 'estrobo' | Should -Be 'Estrobo'
        $m.Use | Should -Be 'Estrobo'
        # Saved: a fresh reading of the same monitor finds it.
        $again = New-TestMonitor (New-TestEdid -Name 'VG27AQ3A' -RangeMax 180 -AmdVsdb @(48, 180)) 180
        Get-JuicerMonitorMode $again | Should -Be 'Estrobo'
        Get-JuicerMonitorMode (New-TestMonitor (New-TestEdid -Name 'Otro') 144 -Id 'AUS2000') | Should -Be 'Automatico'
        { Set-JuicerMonitorMode $m 'Parpadeo' } | Should -Throw '*Estrobo*'
        Resolve-JuicerMonitorUse (New-TestMonitor (New-TestEdid -Vendor 'DEL' -Name 'P2422H' -NoCta) 60 -Id 'DELA1') | Should -Be 'Fijo'
        Resolve-JuicerMonitorUse $null | Should -Be 'Fijo'
    }

    It 'con ELMB a 180 Hz: límite a los Hz y qué hacer si un juego no llega' {
        $m = New-TestMonitor (New-TestEdid -Name 'VG27AQ3A' -RangeMax 180 -AmdVsdb @(48, 180)) 180 @(60, 100, 120, 144, 165, 180)
        $m.Mode = 'Estrobo'
        (Format-JuicerMonitor $m) | Should -BeLike '*180 Hz*usado con ELMB, sin VRR'
        $games = @(@{ Application = 'cs2.exe'; Low1 = 240; AvgFps = 400; Fps90 = 330 }, @{ Application = 'cyberpunk2077.exe'; Low1 = 151; AvgFps = 170; Fps90 = 160 })
        $f = @(Get-JuicerMonitorFindings @($m) 'NVIDIA' $games)
        $f[0].Detail | Should -BeLike '*ELMB*exacto a los Hz (180 FPS)*'
        @($f | Where-Object { $_.Title -like 'Cómo sacarle partido a ELMB' }).Count | Should -Be 1
        $low = @($f | Where-Object { $_.Title -like 'cyberpunk2077.exe no sostiene 180 FPS*' })
        $low.Count | Should -Be 1
        $low[0].Detail | Should -BeLike '*a 144 Hz*'
        @($f | Where-Object { $_.Title -like 'cs2.exe*' }).Count | Should -Be 0
        @($f | Where-Object { $_.Title -like 'Nitidez*' -or $_.Title -like 'Overdrive*' }).Count | Should -Be 0

        $m.Mode = 'EstroboSync'
        @(Get-JuicerMonitorFindings @($m) 'NVIDIA')[0].Detail | Should -BeLike '*ELMB*frecuencia variable*171 FPS*'
        $m.Mode = 'Fijo'
        @(Get-JuicerMonitorFindings @($m) 'NVIDIA')[0].Detail | Should -BeLike '*lo usas a frecuencia fija*'
    }

    It 'con el estrobo a menos Hz que el máximo, los consejos usan los Hz a los que va, como el frame pacer' {
        # A 180 Hz monitor run at 120 Hz with ELMB (strobing often only works under the top rate).
        $m = New-TestMonitor (New-TestEdid -Name 'VG27AQ3A' -RangeMax 180 -AmdVsdb @(48, 180)) 120 @(60, 100, 120, 144, 165, 180)
        $m.Display.MaxHz = 180
        $m.Mode = 'Estrobo'
        $games = @(@{ Application = 'cyberpunk2077.exe'; Low1 = 151; AvgFps = 170; Fps90 = 160 })
        $f = @(Get-JuicerMonitorFindings @($m) 'NVIDIA' $games)
        $f[0].Detail | Should -BeLike '*exacto a los Hz (120 FPS)*'
        @($f | Where-Object { $_.Title -like '*no sostiene*' }).Count | Should -Be 0
    }
}

Describe 'Frame pacer' {
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath) -ErrorAction SilentlyContinue
    }

    It 'calcula el límite por frametime: debajo de los Hz con VRR, lo que sostiene si oscila' {
        (Get-JuicerFpsCap 144 'VRR').Fps | Should -Be 138
        (Get-JuicerFpsCap 165 'VRR').Fps | Should -Be 157
        (Get-JuicerFpsCap 240 'VRR').Fps | Should -Be 224
        (Get-JuicerFpsCap 180 'VRR').VSync | Should -BeTrue
        (Get-JuicerFpsCap 60 'Fijo').Fps | Should -Be 60
        (Get-JuicerFpsCap 60 'Fijo').VSync | Should -BeFalse
        $shaky = @{ AvgFps = 140; Low1 = 70; Fps90 = 118.6 }
        $c = Get-JuicerFpsCap 165 'VRR' $shaky 48
        $c.Fps | Should -Be 118
        $c.Why | Should -BeLike '*8?47 ms por fotograma*'
        (Get-JuicerFpsCap 165 'VRR' @{ AvgFps = 140; Low1 = 120; Fps90 = 130 } 48).Fps | Should -Be 157
        (Get-JuicerFpsCap 165 'VRR' @{ AvgFps = 60; Low1 = 20; Fps90 = 40 } 48).Fps | Should -Be 157
        Get-JuicerFpsCap 0 'VRR' | Should -BeNullOrEmpty
    }

    It 'con estroboscopio: exacto a los Hz, nunca por debajo, y avisa si el juego no llega' {
        $c = Get-JuicerFpsCap 180 'Estrobo'
        $c.Fps | Should -Be 180
        $c.VSync | Should -BeTrue
        $c.Why | Should -BeLike '*5?56 ms*un fotograma por destello*'
        $c.Warn | Should -BeNullOrEmpty
        # A shaky game does not lower it: under strobing that is judder.
        $s = Get-JuicerFpsCap 180 'Estrobo' @{ AvgFps = 170; Low1 = 110; Fps90 = 150 } 0 @(60, 100, 120, 144, 165, 180)
        $s.Fps | Should -Be 180
        $s.Warn | Should -BeLike '*110 FPS*a 100 Hz*'
        (Get-JuicerFpsCap 180 'Estrobo' @{ AvgFps = 70; Low1 = 50; Fps90 = 60 } 0 @(60, 180)).Warn | Should -BeLike '*mejor VRR sin estrobo*'
        $sync = Get-JuicerFpsCap 180 'EstroboSync'
        $sync.Fps | Should -Be 171
        $sync.VSync | Should -BeTrue
    }

    It 'el frame pacer sigue al modo del monitor y recalcula al cambiarlo' {
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; Hz = 180; MaxHz = 180; Primary = $true; RefreshRates = @(60, 144, 180) }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        (Add-JuicerFpsLimit 'cs2.exe' 0 $mon).Title | Should -BeLike 'Frame pacer a 171 FPS*'
        [void](Set-JuicerMonitorMode $mon 'Estrobo')
        $r = @(Update-JuicerFpsLimits $mon)
        $r[0].Outcome | Should -Be 'Aplicado'
        $r[0].Title | Should -BeLike 'Frame pacer a 180 FPS (5?56 ms): cs2.exe'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 180
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        # The journal still holds what there was before the first limit.
        Undo-JuicerTweak 'fps:cs2.exe' | Out-Null
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.NvSettings.Count | Should -Be 0

        [void](Set-JuicerMonitorMode $mon 'Fijo')
        Add-JuicerFpsLimit 'cs2.exe' 0 $mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 180
        # At a fixed refresh, VSync is the game's (VSYNCMODE_PASSIVE), never a leftover.
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x60925292
    }

    It 'edita perfiles de RTSS sin tocar el resto' {
        $lines = @('[OSD]', 'EnableOSD=1', '[Framerate]', 'Limit=0', 'LimitDenominator=1')
        $new = Set-JuicerIniValue $lines 'Framerate' 'Limit' '157'
        $new | Should -Be @('[OSD]', 'EnableOSD=1', '[Framerate]', 'Limit=157', 'LimitDenominator=1')
        Get-JuicerIniValue $new 'Framerate' 'Limit' | Should -Be '157'
        Set-JuicerIniValue @('[OSD]', 'EnableOSD=1') 'Framerate' 'Limit' '60' | Should -Be @('[OSD]', 'EnableOSD=1', '[Framerate]', 'Limit=60')
        Set-JuicerIniValue @('[Framerate]', 'LimitDenominator=1', '[OSD]') 'Framerate' 'Limit' '60' | Should -Be @('[Framerate]', 'LimitDenominator=1', 'Limit=60', '[OSD]')
        Get-JuicerIniValue @('[OSD]', 'Limit=5') 'Framerate' 'Limit' | Should -BeNullOrEmpty
        ConvertTo-JuicerExeName 'C:\Juegos\CS2\cs2.EXE' | Should -Be 'cs2.exe'
        ConvertTo-JuicerExeName 'eldenring' | Should -Be 'eldenring.exe'
    }

    It 'con NVIDIA pone límite y receta de baja latencia, y lo deshace todo' {
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        $r = Add-JuicerFpsLimit 'C:\Juegos\cs2.exe' 0 $vrr
        $r.Outcome | Should -Be 'Aplicado'
        $r.Title | Should -BeLike 'Frame pacer a 157 FPS (6?37 ms): cs2.exe'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        $M.Backend.State.NvSettings['cs2.exe|8102046'] | Should -Be 1
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        # No «prefer maximum performance» any more (PREFERRED_PSTATE).
        $M.Backend.State.NvSettings.ContainsKey('cs2.exe|274197361') | Should -BeFalse
        @(Get-JuicerFpsLimits)[0].Fps | Should -Be 157
        (Undo-JuicerTweak 'fps:cs2.exe').Outcome | Should -Be 'Deshecho'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.NvSettings.Count | Should -Be 0
    }

    It 'respeta el límite que ya tenías y lo devuelve al deshacer' {
        $M.Backend.State.FpsLimits['game.exe'] = 100
        $fixed = @{ Display = [pscustomobject]@{ Hz = 60; MaxHz = 60; Primary = $true }; Info = @{}; Vrr = $null }
        (Add-JuicerFpsLimit 'game.exe' 0 $fixed).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['game.exe'] | Should -Be 60
        $M.Backend.State.NvSettings['game.exe|11041231'] | Should -Be 0x60925292
        Undo-JuicerTweak 'fps:game.exe' | Out-Null
        $M.Backend.State.FpsLimits['game.exe'] | Should -Be 100
    }

    It 'no toca el perfil de un juego abierto: espera a que se cierre y entonces lo aplica' {
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        [void]$M.Backend.State.Running.Add('cs2.exe')
        $r = Add-JuicerFpsLimit 'C:\Juegos\cs2.exe' 0 $vrr
        $r.Outcome | Should -Be 'Pendiente'
        $r.Message | Should -BeLike '*cs2.exe está abierto*'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.NvSettings.Count | Should -Be 0
        @(Get-JuicerPacerPending) | Should -Be @('cs2.exe')
        # The engine refuses on its own too, before writing anything.
        (Invoke-JuicerTweak (New-JuicerFpsLimitTweak 'cs2.exe' 100)).Outcome | Should -Be 'Error'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        Get-JuicerJournalEntry (Read-JuicerJournal) 'fps:cs2.exe' | Should -BeNullOrEmpty
        # Still open: nothing yet. Closed: applied, and off the list.
        @(Invoke-JuicerPacerPending $vrr) | Should -BeNullOrEmpty
        $M.Backend.State.Running.Clear()
        $done = @(Invoke-JuicerPacerPending $vrr)
        $done[0].Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        @(Get-JuicerPacerPending) | Should -BeNullOrEmpty
        # Taking it away while it runs waits too; undoing it by hand is refused.
        [void]$M.Backend.State.Running.Add('cs2.exe')
        (Remove-JuicerFpsLimit 'cs2.exe').Outcome | Should -Be 'Pendiente'
        (Undo-JuicerTweak 'fps:cs2.exe').Outcome | Should -Be 'Error'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        $M.Backend.State.Running.Clear()
        [void](Invoke-JuicerPacerPending $vrr)
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.NvSettings.Count | Should -Be 0
        Get-JuicerJournalEntry (Read-JuicerJournal) 'fps:cs2.exe' | Should -BeNullOrEmpty
    }

    It 'respeta lo que NVIDIA pone en el perfil de cada juego y no sube su propio límite' {
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        $M.Backend.State.NvPredefined['cs2.exe|11041231'] = 0x60925292
        $M.Backend.State.NvPredefined[('old.exe|{0}' -f [uint32]0x10835002)] = 60
        (Add-JuicerFpsLimit 'cs2.exe' 0 $vrr).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.NvSettings.ContainsKey('cs2.exe|11041231') | Should -BeFalse
        $M.Backend.State.NvSettings['cs2.exe|8102046'] | Should -Be 1
        $r = Add-JuicerFpsLimit 'old.exe' 0 $vrr
        $r.Title | Should -BeLike 'Frame pacer a 60 FPS*'
        $M.Backend.State.FpsLimits['old.exe'] | Should -Be 60
    }

    It 'pone al día lo que aplicó una versión anterior, una sola vez' {
        $old = New-JuicerFpsLimitTweak 'cs2.exe' 157 -VSync -Use 'VRR'
        $old.Actions += @{ Type = 'NvSetting'; Exe = 'cs2.exe'; Id = [uint32]0x1057EB71; Value = [uint32]1; Label = 'Modo de energía: preferir rendimiento máximo' }
        (Invoke-JuicerTweak $old).Outcome | Should -Be 'Aplicado'
        $prio = New-JuicerPriorityTweak 'C:\Juegos\cs2.exe'
        $prio.Actions[0].Value = 3
        (Invoke-JuicerTweak $prio).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.NvSettings['cs2.exe|274197361'] | Should -Be 1
        $fixed = @(Repair-JuicerGameSetups)
        $fixed.Count | Should -Be 2
        $M.Backend.State.NvSettings.ContainsKey('cs2.exe|274197361') | Should -BeFalse
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        (Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\cs2.exe\PerfOptions' 'CpuPriorityClass').Value | Should -Be 6
        @(Repair-JuicerGameSetups) | Should -BeNullOrEmpty
        # Undoing still leaves everything as it was before Win Juicer.
        [void](Undo-JuicerAll)
        $M.Backend.State.NvSettings.Count | Should -Be 0
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        Read-JuicerReg 'HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options\cs2.exe\PerfOptions' 'CpuPriorityClass' | Should -BeNullOrEmpty
    }

    It 'el modo prudente deja sólo el límite y devuelve lo demás como estaba' {
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        (Add-JuicerFpsLimit 'cs2.exe' 0 $vrr).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.NvSettings.Count | Should -Be 2
        [void](Set-JuicerPacerMinimal 'cs2.exe' $true $vrr)
        $M.Backend.State.NvSettings.Count | Should -Be 0
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        (Get-JuicerJournalEntry (Read-JuicerJournal) 'fps:cs2.exe').Actions.Count | Should -Be 1
        [void](Set-JuicerPacerMinimal 'cs2.exe' $false $vrr)
        $M.Backend.State.NvSettings.Count | Should -Be 2
        Undo-JuicerTweak 'fps:cs2.exe' | Out-Null
        $M.Backend.State.NvSettings.Count | Should -Be 0
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
    }

    It 'si un juego empieza a fallar después de optimizarlo, le quita los cambios' {
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        (Add-JuicerFpsLimit 'cs2.exe' 0 $vrr).Outcome | Should -Be 'Aplicado'
        (Add-JuicerFpsLimit 'eldenring.exe' 0 $vrr).Outcome | Should -Be 'Aplicado'
        # Optimized two hours ago.
        $j = Read-JuicerJournal
        foreach ($e in $j) { $e.AppliedAt = (Get-Date).AddHours(-2).ToString('s') }
        Save-JuicerJournal $j
        # cs2 never failed before and fails since; Elden Ring already failed before.
        [void]$M.Backend.State.Incidents.Add(@{ Exe = 'cs2.exe'; Kind = 'Cierre'; Time = (Get-Date).AddHours(-1).ToString('s'); Module = 'nvwgf2umx.dll' })
        [void]$M.Backend.State.Incidents.Add(@{ Exe = 'eldenring.exe'; Kind = 'Cuelgue'; Time = (Get-Date).AddHours(-1).ToString('s'); Module = '' })
        [void]$M.Backend.State.Incidents.Add(@{ Exe = 'eldenring.exe'; Kind = 'Cierre'; Time = (Get-Date).AddHours(-10).ToString('s'); Module = '' })
        $s = Update-JuicerGameSafety @(@{ ExeName = 'cs2.exe'; Name = 'Counter-Strike 2' })
        @($s.Protected).Count | Should -Be 1
        $s.Protected[0].Name | Should -Be 'Counter-Strike 2'
        @($s.Warned).Count | Should -Be 1
        $s.Warned[0].Exe | Should -Be 'eldenring.exe'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.FpsLimits['eldenring.exe'] | Should -Be 157
        Get-JuicerGameSafe 'cs2.exe' | Should -Not -BeNullOrEmpty
        Test-JuicerPacerMinimal 'cs2.exe' | Should -BeTrue
        Format-JuicerSafeNote (Get-JuicerGameSafe 'cs2.exe') 'Counter-Strike 2' | Should -BeLike '*se cerró con un error*nvwgf2umx.dll*'
        # «Optimizar todos» leaves it alone; asked for that game, prudent mode.
        $g = @{ Id = 'steam:1'; Name = 'Counter-Strike 2'; Exe = 'cs2.exe'; ExeName = 'cs2.exe' }
        (@(Invoke-JuicerGameSetup @($g) 'Recomendado' -GpuCount 1 -Monitor $vrr))[0].Outcome | Should -Be 'NoAplica'
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        [void](Invoke-JuicerGameSetup @($g) 'Recomendado' -GpuCount 1 -Monitor $vrr -Force)
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        $M.Backend.State.NvSettings.ContainsKey('cs2.exe|11041231') | Should -BeFalse
        Get-JuicerGameSafe 'cs2.exe' | Should -BeNullOrEmpty
        # The same failure, from before optimizing it again, does not count twice.
        @((Update-JuicerGameSafety).Protected).Count | Should -Be 0
    }

    It 'decide por los fallos de antes y de después, y ve los anti-trampas' {
        Get-JuicerSafetyVerdict 0 0 | Should -Be ''
        Get-JuicerSafetyVerdict 1 0 | Should -Be 'Proteger'
        Get-JuicerSafetyVerdict 2 1 | Should -Be 'Avisar'
        # A first failure after weeks of working fine: only pointed out.
        Get-JuicerSafetyVerdict 1 0 0 | Should -Be 'Avisar'
        $inc = @(@{ Exe = 'A.exe'; Time = '2026-01-02T10:00:00' }, @{ Exe = 'a.exe'; Time = '2026-01-01T10:00:00' }, @{ Exe = 'b.exe'; Time = '2026-01-02T11:00:00' })
        $sel = @(Select-JuicerGameIncidents $inc 'a' ([datetime]'2026-01-01'))
        $sel.Count | Should -Be 2
        $sel[0].Time | Should -Be '2026-01-01T10:00:00'
        @(Select-JuicerGameIncidents $inc 'a.exe' ([datetime]'2026-01-01T12:00:00')).Count | Should -Be 1
        Format-JuicerSafeNote @{ Kind = 'Cuelgue'; Time = '2026-01-02T10:00:00' } 'Juego' | Should -BeLike 'Juego se quedó colgado y Windows lo cerró*'
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('wj-ac-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $dir 'EasyAntiCheat') -Force | Out-Null
        try {
            Get-JuicerGameAntiCheat $dir | Should -Be 'Easy Anti-Cheat'
            Get-JuicerGameAntiCheat (Join-Path $dir 'EasyAntiCheat') | Should -Be ''
        } finally {
            Remove-Item -LiteralPath $dir -Recurse -Force
        }
    }

    It 'con RivaTuner sólo pone el límite, y sin motor lo dice' {
        $M.Backend.State.FpsBackend = 'rtss'
        (Add-JuicerFpsLimit 'game.exe' 90).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['game.exe'] | Should -Be 90
        $M.Backend.State.NvSettings.Count | Should -Be 0
        $M.Backend.State.FpsBackend = ''
        (Add-JuicerFpsLimit 'otro.exe' 90).Outcome | Should -Be 'NoAplica'
    }

    It 'desde la línea de órdenes' {
        @(Start-Juicer -LimitarFps 'a.exe,b.exe' -Fps 120 -Si 6>$null)[-1] | Should -Be 0
        $M.Backend.State.FpsLimits['b.exe'] | Should -Be 120
        @(Start-Juicer -LimitarFps 'a.exe' -Fps 5 -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -ModoMonitor 'Parpadeo' -Si 6>$null)[-1] | Should -Be 2
        # The mode decides this limit, with or without a monitor to read (CI
        # runners have one): under any refresh, so VSync is forced.
        @(Start-Juicer -LimitarFps 'c.exe' -Fps 30 -ModoMonitor 'Estrobo' -Si 6>$null)[-1] | Should -Be 0
        $M.Backend.State.NvSettings['c.exe|11041231'] | Should -Be 0x47814940
        # Alone it needs a monitor to save it for: there is one on a real Windows.
        @(Start-Juicer -ModoMonitor 'Estrobo' -Si 6>$null)[-1] | Should -Be $(if (Get-JuicerPrimaryMonitor) { 0 } else { 1 })
    }
}

Describe 'Frame pacer: ritmo, calibración y conflictos' {
    BeforeAll {
        # PresentMon rows with what the pacing numbers need: frame time,
        # processor and graphics card busy time, and animation error.
        # GpuLat, when given, adds GPULatency (CPU busy + that wait) and
        # input latency on one frame in ten, as PresentMon writes them.
        function New-PacedRows {
            param([double[]]$Times, [double]$Work, [string]$App = 'cs2.exe', [double]$Wait = -1, [string]$Sync = '1')
            $inv = [Globalization.CultureInfo]::InvariantCulture
            $i = 0
            foreach ($t in $Times) {
                $o = [ordered]@{
                    Application = $App; ProcessID = '100'; SyncInterval = $Sync; AllowsTearing = $(if ($Sync -eq '0') { '1' } else { '0' }); PresentMode = 'Hardware: Independent Flip'
                    FrameTime = $t.ToString($inv); CPUBusy = ($Work * 0.8).ToString($inv); GPUBusy = $Work.ToString($inv); AnimationError = '0.05'
                }
                if ($Wait -ge 0) {
                    $o.GPULatency = ($Work * 0.8 + $Wait).ToString($inv)
                    $o.AllInputToPhotonLatency = $(if ($i % 10 -eq 0) { (2 * $t + $Wait).ToString($inv) } else { 'NA' })
                }
                $i++
                [pscustomobject]$o
            }
        }
    }
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath), (Get-JuicerFrameHistoryPath) -ErrorAction SilentlyContinue
        $script:Mon = @{
            Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; MonitorId = '\\?\DISPLAY#AUS27A3#5&1&0&UID1#{e6f07b5f}'; Hz = 180; MaxHz = 180; ExactHz = 179.963; Primary = $true; RefreshRates = @(60, 144, 180) }
            Info = @{ Brand = 'ASUS'; Name = 'VG27AQ3A' }; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' }
        }
    }

    It 'mide lo parejo del ritmo: fotogramas en su sitio, variación y margen' {
        $r = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        $r.Steady | Should -Be 100
        $r.JitterMs | Should -Be 0
        $r.WorkMs95 | Should -Be 3
        $r.AnimErrorMs | Should -Be 0.05
        $r.Fps95 | Should -BeGreaterThan 170
        # Alternating 5 and 8 ms: half the frames off the median, 3 ms jumps.
        $z = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.0, 8.0) * 200)) 4.5)
        $z.Steady | Should -BeLessOrEqual 50
        $z.JitterMs | Should -Be 3
        $z.Fps95 | Should -Be 125
    }

    It 'dice si el ritmo se cumple, si no actúa y si hay margen' {
        $ok = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        $f = @(Get-JuicerPacerFindings $ok 171)
        $f[0].Severity | Should -Be 'Ok'
        $f[0].Title | Should -Be 'Ritmo clavado a 171 FPS'
        @($f | Where-Object { $_.Title -like 'Hay margen*' }).Count | Should -Be 1
        $slow = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        $s = @(Get-JuicerPacerFindings $slow 171)
        $s[0].Severity | Should -Be 'Medio'
        $s[0].Title | Should -BeLike 'No sostiene 171 FPS*'
        @($s | Where-Object { $_.Title -like 'Hay margen*' }).Count | Should -Be 0
        $fast = Measure-JuicerFrames @(New-PacedRows ([double[]](@(4.0) * 400)) 3.0)
        (Get-JuicerPacerFindings $fast 171).Title | Should -BeLike 'No está actuando*'
    }

    It 'calibra: baja a lo que sostiene, sube si sobra, nunca por debajo del VRR ni con estrobo' {
        $slow = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        $c = Get-JuicerPacerCalibration $slow 171 171 'VRR' 48
        $c.Action | Should -Be 'Bajar'
        $c.Fps | Should -Be 127
        # A margin under what it managed, not right at it, and the text does not promise more than that.
        $c.Fps | Should -BeLessThan $slow.Fps95
        $c.Why | Should -BeLike '*3 % por debajo*debería sostenerlos*'
        # Never under the bottom of the VRR range.
        $awful = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(25.0) * 40)) 20.0)
        (Get-JuicerPacerCalibration $awful 171 171 'VRR' 48).Fps | Should -Be 51
        # Room to spare, under a cap lowered before: back up, to the max at most.
        $easy = Measure-JuicerFrames @(New-PacedRows ([double[]](@(7.7) * 400)) 4.0)
        $u = Get-JuicerPacerCalibration $easy 130 171 'VRR' 48
        $u.Action | Should -Be 'Subir'
        $u.Fps | Should -Be 171
        # At the max already, the room left is what keeps latency low.
        $held = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0)
        (Get-JuicerPacerCalibration $held 171 171 'VRR' 48).Action | Should -Be 'Mantener'
        $fast = Measure-JuicerFrames @(New-PacedRows ([double[]](@(4.0) * 400)) 3.0)
        (Get-JuicerPacerCalibration $fast 171 171 'VRR' 48).Action | Should -Be 'NoActua'
        # Strobing: never lower; the advice is a lower refresh rate.
        $e = Get-JuicerPacerCalibration $slow 180 180 'Estrobo' 0 @(60, 120, 144, 180)
        $e.Action | Should -Be 'Estrobo'
        $e.Fps | Should -Be 180
        $e.Why | Should -BeLike '*a 120 Hz*'
    }

    It 'mide la latencia: de la entrada a la pantalla y la cola delante de la gráfica' {
        $r = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 5.7 -Wait 4.0)
        $r.QueueMs | Should -Be 4
        $r.GpuMs95 | Should -Be 5.7
        $r.InputLatency | Should -Be 15.7
        $f = @(Get-JuicerPacerFindings $r 171)
        $q = @($f | Where-Object { $_.Title -like 'La gráfica va al límite*' })
        $q.Count | Should -Be 1
        $q[0].Severity | Should -Be 'Medio'
        $q[0].Detail | Should -BeLike '*4?0 ms en cola*15?7 ms (mediana)*'
        $calm = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 3.0 -Wait 0.2)
        @(@(Get-JuicerPacerFindings $calm 171) | Where-Object { $_.Title -like 'Sin cola*' }).Count | Should -Be 1
        # Without GPULatency, a graphics card busy all of every frame means a queue.
        Test-JuicerPacerQueue @{ GpuMs95 = 5.7 } 5.85 | Should -BeTrue
        Test-JuicerPacerQueue @{ GpuMs95 = 4.0 } 5.85 | Should -BeFalse
        Test-JuicerPacerQueue @{} 5.85 | Should -BeFalse
    }

    It 'calibra por latencia: deja margen a la gráfica, y sin VRR ni VSync sube a un múltiplo de los Hz' {
        $q = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 5.7 -Wait 4.0)
        $c = Get-JuicerPacerCalibration $q 171 171 'VRR' 48
        $c.Action | Should -Be 'Bajar'
        $c.Fps | Should -Be 154
        $c.Why | Should -BeLike 'Calibrado por latencia*'
        # Strobing does not go under the refresh, even for latency.
        $e = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.55) * 400)) 5.4 -Wait 4.0)
        (Get-JuicerPacerCalibration $e 180 180 'Estrobo').Action | Should -Be 'Estrobo'
        # Fixed refresh, no VSync, lots of room: up to a multiple of the refresh.
        $fx = Measure-JuicerFrames @(New-PacedRows ([double[]](@(16.67) * 400)) 4.0 -Wait 0.1 -Sync '0')
        $u = Get-JuicerPacerCalibration $fx 60 60 'Fijo' 0 @() 60
        $u.Action | Should -Be 'Subir'
        $u.Fps | Should -Be 180
        # With VSync on, more frames than Hz would only queue: it stays.
        $vs = Measure-JuicerFrames @(New-PacedRows ([double[]](@(16.67) * 400)) 4.0 -Wait 0.1)
        (Get-JuicerPacerCalibration $vs 60 60 'Fijo' 0 @() 60).Action | Should -Be 'Mantener'
    }

    It 'a frecuencia fija, lo calibrado puede pasar de los Hz' {
        $fixed = @{ Display = [pscustomobject]@{ Monitor = 'X'; MonitorId = 'm#X#1'; Hz = 60; MaxHz = 60; Primary = $true }; Info = @{}; Vrr = $null }
        $state = Read-JuicerPacer
        $state.Calibrated['game.exe'] = @{ Fps = 180; Why = 'x'; Signature = (Get-JuicerLimitSignature $fixed) }
        Save-JuicerPacer $state
        (Get-JuicerRecommendedFps 'game.exe' $fixed).Fps | Should -Be 180
    }

    It 'un ritmo por encima de los Hz nunca fuerza la sincronización vertical' {
        Add-JuicerFpsLimit 'cs2.exe' 400 $Mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 400
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x08416747
        Add-JuicerFpsLimit 'cs2.exe' 0 $Mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
    }

    It 'prioridad latencia: al calibrar sube a un múltiplo de los Hz sin VSync, también con estrobo' {
        $light = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 1.2 -Wait 0.1)
        # Smoothness first: at its max already, it stays.
        (Get-JuicerPacerCalibration $light 171 171 'VRR' 48 @() 180).Action | Should -Be 'Mantener'
        $c = Get-JuicerPacerCalibration $light 171 171 'VRR' 48 @() 180 'Latencia'
        $c.Action | Should -Be 'Subir'
        $c.Fps | Should -Be 720
        $c.Why | Should -BeLike '*desactívala también en el juego*'
        $strobe = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.55) * 400)) 1.2 -Wait 0.1)
        (Get-JuicerPacerCalibration $strobe 180 180 'Estrobo' 0 @() 180).Action | Should -Be 'Mantener'
        (Get-JuicerPacerCalibration $strobe 180 180 'Estrobo' 0 @() 180 'Latencia').Fps | Should -Be 720
        # Saved for the game, and what calibrating finds is used up to 1000 FPS.
        Add-JuicerFpsLimit 'cs2.exe' 0 $Mon | Out-Null
        Set-JuicerPacerPriority 'cs2.exe' 'Latencia' $Mon | Out-Null
        Get-JuicerPacerPriority 'CS2.EXE' | Should -Be 'Latencia'
        $state = Read-JuicerPacer
        $state.Calibrated['cs2.exe'] = @{ Fps = 720; Why = 'x'; Signature = (Get-JuicerLimitSignature $Mon) }
        Save-JuicerPacer $state
        @(Update-JuicerFpsLimits $Mon) | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 720
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x08416747
        # Back to smoothness: the calibration is forgotten, and VSync forced again.
        Set-JuicerPacerPriority 'cs2.exe' 'Fluidez' $Mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        (Read-JuicerPacer).Calibrated.ContainsKey('cs2.exe') | Should -BeFalse
    }

    It 'con generación de fotogramas no sube ni baja por cola, y con RivaTuner lo avisa' {
        $fg = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 400)) 5.7 -Wait 4.0)
        $fg.Generated = 50
        (Get-JuicerPacerCalibration $fg 171 171 'VRR' 48).Action | Should -Be 'Mantener'
        (Get-JuicerPacerFindings $fg 171 0 'rtss' | Where-Object { $_.Title -like 'Generación de fotogramas con RivaTuner*' }).Severity | Should -Be 'Medio'
        @(Get-JuicerPacerFindings $fg 171 | Where-Object { $_.Title -like 'La gráfica va al límite*' }).Count | Should -Be 0
    }

    It 'dibuja los frametimes: la serie conserva los picos y la consola los muestra' {
        $r = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 999 + @(40.0))) 3.0)
        $r.Series.Count | Should -Be 240
        ($r.Series | Measure-Object -Maximum).Maximum | Should -Be 40
        $f = New-JuicerFrameChartFinding $r $r.Series 5.85
        $f.Chart.TargetMs | Should -Be 5.85
        $line = Format-JuicerSparkline $r.Series 5.85 60
        $line.Length | Should -Be 60
        $line | Should -Match ([char]0x2588)
        Format-JuicerSparkline @() | Should -Be ''
        # The comparison with the last measurement includes the pace.
        $prev = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.0, 8.0) * 200)) 3.0)
        $prev.Date = (Get-Date).AddDays(-1).ToString('s')
        $cmp = @(Get-JuicerFrameFindings $r $prev 180) | Where-Object { $_.Title -like 'Respecto al*' }
        $cmp.Detail | Should -BeLike '*Ritmo: * → 100 % de los fotogramas en su sitio*'
    }

    It 'avisa de G-SYNC sólo en pantalla completa y de la caché de sombreadores' {
        $s = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0; NvVrrMode = 1; NvShaderCache = 0; NvShaderCacheMb = -1 }
        $t = @(Get-JuicerPacerConflicts $s 'nvidia' @() $Mon | ForEach-Object { $_.Title })
        $t | Should -Contain 'G-SYNC sólo en pantalla completa'
        $t | Should -Contain 'La caché de sombreadores de NVIDIA está desactivada'
        $s.NvVrrMode = 2; $s.NvShaderCache = -1; $s.NvShaderCacheMb = 512
        $t = @(Get-JuicerPacerConflicts $s 'nvidia' @() $Mon | ForEach-Object { $_.Title })
        $t | Should -Contain 'Caché de sombreadores de NVIDIA de sólo 512 MB'
        @($t | Where-Object { $_ -like 'G-SYNC*' }).Count | Should -Be 0
    }

    It 'calibrar un juego mide, ajusta, lo recuerda para ese monitor y se puede olvidar' {
        $slow = Measure-JuicerFrames @(New-PacedRows ([double[]](@(5.85) * 360 + @(7.6) * 40)) 7.0)
        $slow.Date = (Get-Date).ToString('s')
        Mock -ModuleName WinJuicer Invoke-JuicerFrameCapture { New-JuicerFinding 'Juego: cs2.exe' 'Info' 'medida' }
        Mock -ModuleName WinJuicer Get-JuicerPreviousFrameResult { $slow }.GetNewClosure()
        $f = @(Invoke-JuicerPacerCalibration 'cs2.exe' -Monitor $Mon)
        # It proposes, and nothing has changed yet.
        $f[-1].Title | Should -Be 'Propuesta: de 171 a 127 FPS'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 171
        (Read-JuicerPacer).Calibrated.ContainsKey('cs2.exe') | Should -BeFalse
        $p = Get-JuicerCalibrationProposal $f
        $p.Old | Should -Be 171
        $p.New | Should -Be 127
        $r = @(Save-JuicerPacerCalibration $p $Mon)
        $r[-1].Title | Should -Be 'Calibrado: de 171 a 127 FPS'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        (Read-JuicerPacer).Calibrated['cs2.exe'][(Get-JuicerLimitSignature $Mon)].Fps | Should -Be 127
        # Recalculating keeps it while the monitor is the same...
        @(Update-JuicerFpsLimits $Mon) | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 127
        # ...but not on another refresh rate.
        $other = @{ Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; MonitorId = $Mon.Display.MonitorId; Hz = 144; MaxHz = 180; Primary = $true }; Info = $Mon.Info; Vrr = $Mon.Vrr }
        (Get-JuicerRecommendedFps 'cs2.exe' $other).Fps | Should -Be 138
        Clear-JuicerPacerCalibration 'cs2.exe'
        (Get-JuicerRecommendedFps 'cs2.exe' $Mon).Fps | Should -Be 171
    }

    It 'con estrobo y RivaTuner, el ritmo va justo por debajo del refresco real, en décimas' {
        [void](Set-JuicerMonitorMode $Mon 'Estrobo')
        $c = Get-JuicerFpsCap 180 'Estrobo' $null 0 @() 179.963
        $c.Fps | Should -Be 180
        $c.Exact | Should -Be 179.953
        (Get-JuicerFpsCap 180 'VRR' $null 48 @() 179.963).Exact | Should -Be 0
        $M.Backend.State.FpsBackend = 'rtss'
        (Add-JuicerFpsLimit 'cs2.exe' 0 $Mon).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsExact['cs2.exe'] | Should -Be 179.953
        @(Get-JuicerFpsLimits)[0].Exact | Should -Be 179.953
        (Add-JuicerFpsLimit 'cs2.exe' 0 $Mon).Outcome | Should -Be 'YaEstaba'
        Undo-JuicerTweak 'fps:cs2.exe' | Out-Null
        $M.Backend.State.FpsExact.ContainsKey('cs2.exe') | Should -BeFalse
        # The profile file: Limit over LimitDenominator.
        $l = Set-JuicerRtssLimit @('[Framerate]', 'Limit=0') 180 179.953
        $l | Should -Be @('[Framerate]', 'Limit=179953', 'LimitDenominator=1000')
        Get-JuicerRtssLimit $l | Should -Be 179.953
        $w = Set-JuicerRtssLimit $l 171
        $w | Should -Be @('[Framerate]', 'Limit=171', 'LimitDenominator=1')
        Get-JuicerRtssLimit $w | Should -Be 171
        Get-JuicerRtssLimit @('[Framerate]', 'Limit=60000', 'LimitDenominator=1001') | Should -Be 59.94
        Get-JuicerRtssLimit @('[OSD]') | Should -Be 0
    }

    It 'cambia de motor moviendo cada juego, sin dejar dos limitadores' {
        $M.Backend.State.FpsEngines = @('nvidia', 'rtss')
        Add-JuicerFpsLimit 'cs2.exe' 0 $Mon | Out-Null
        $M.Backend.State.NvSettings['cs2.exe|8102046'] | Should -Be 1
        @(Set-JuicerPacerEngine 'rtss' $Mon)[0].Outcome | Should -Be 'Aplicado'
        Get-JuicerFpsBackend | Should -Be 'rtss'
        $l = @(Get-JuicerFpsLimits)
        $l.Count | Should -Be 1
        $l[0].Backend | Should -Be 'rtss'
        $l[0].Fps | Should -Be 171
        # The low-latency recipe stays in the NVIDIA profile.
        $M.Backend.State.NvSettings['cs2.exe|8102046'] | Should -Be 1
        @(Set-JuicerPacerEngine 'rtss' $Mon).Count | Should -Be 0
        $M.Backend.State.FpsEngines = @('nvidia')
        { Set-JuicerPacerEngine 'rtss' } | Should -Throw '*RivaTuner*'
        Set-JuicerPacerEngine 'Auto' $Mon | Out-Null
        Get-JuicerFpsBackend | Should -Be 'nvidia'
    }

    It 'avisa de otros limitadores y de lo que el motor no puede hacer con tu monitor' {
        $limits = @(@{ Exe = 'cs2.exe'; Fps = 171 })
        $none = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0 }
        @(Get-JuicerPacerConflicts $none 'nvidia' $limits $Mon).Count | Should -Be 0
        $both = @{ RtssInstalled = $true; RtssRunning = $true; RtssGlobal = 144; RtssGames = @{ 'cs2.exe' = 200 }; NvGlobal = 120 }
        $t = @(Get-JuicerPacerConflicts $both 'nvidia' $limits $Mon | ForEach-Object { $_.Title })
        $t | Should -Contain 'RivaTuner tiene un límite global de 144 FPS'
        $t | Should -Contain 'Con dos limitadores a la vez: cs2.exe'
        $t | Should -Contain 'El panel de NVIDIA tiene un límite global de 120 FPS'
        $closed = @{ RtssInstalled = $true; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0 }
        (Get-JuicerPacerConflicts $closed 'rtss' $limits $Mon).Severity | Should -Be 'Alto'
        [void](Set-JuicerMonitorMode $Mon 'Estrobo')
        $Mon.Mode = 'Estrobo'
        # Under strobing the pace is the refresh rate now: the 171 set before is a rate left behind, said on its own.
        @(Get-JuicerPacerConflicts $none 'nvidia' $limits $Mon | Where-Object { $_.Title -like 'Hay 1 juego con un ritmo*' }).Count | Should -Be 1
        $now = @(@{ Exe = 'cs2.exe'; Fps = 180 })
        (Get-JuicerPacerConflicts $none 'nvidia' $now $Mon).Title | Should -BeLike '*179?963 Hz*sólo limita en enteros'
        (Get-JuicerPacerConflicts $closed 'rtss' @() $Mon).Title | Should -BeLike 'Ritmo al Hz exacto: 179?95 FPS*'
        @(Get-JuicerPacerConflictsHere).Count | Should -Be 0
    }

    It 'desde la línea de órdenes: motor y calibración' {
        $M.Backend.State.FpsEngines = @('nvidia', 'rtss')
        @(Start-Juicer -MotorPacer 'rtss' -Si 6>$null)[-1] | Should -Be 0
        Get-JuicerPacerEngine | Should -Be 'rtss'
        $M.Backend.State.FpsEngines = @('nvidia')
        @(Start-Juicer -MotorPacer 'rtss' -Si 6>$null)[-1] | Should -Be 1
    }
}

Describe 'Galería de juegos' {
    BeforeAll {
        # The first bytes of a PNG or a JPEG of a given size: enough for
        # reading the size, which is all the cover choice needs.
        function New-TestPng {
            param([string]$Path, [int]$W, [int]$H)
            $b = New-Object byte[] 64
            [byte[]](0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52) | ForEach-Object -Begin { $i = 0 } -Process { $b[$i++] = $_ }
            $b[16] = ($W -shr 24) -band 255; $b[17] = ($W -shr 16) -band 255; $b[18] = ($W -shr 8) -band 255; $b[19] = $W -band 255
            $b[20] = ($H -shr 24) -band 255; $b[21] = ($H -shr 16) -band 255; $b[22] = ($H -shr 8) -band 255; $b[23] = $H -band 255
            [IO.File]::WriteAllBytes($Path, $b)
        }
        function New-TestJpg {
            param([string]$Path, [int]$W, [int]$H)
            # SOI, an APP0 of 16 bytes, then the frame header.
            $b = [byte[]](@(0xFF, 0xD8, 0xFF, 0xE0, 0, 16) + @(0) * 14 + @(0xFF, 0xC0, 0, 17, 8, (($H -shr 8) -band 255), ($H -band 255), (($W -shr 8) -band 255), ($W -band 255), 3) + @(0) * 30)
            [IO.File]::WriteAllBytes($Path, $b)
        }
    }
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('wj-portadas-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        Remove-Item -LiteralPath (Get-JuicerCoverDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JuicerPacerPath), (Get-JuicerUiPrefsPath), (Get-JuicerFrameChartPath) -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It 'lee el tamaño de un JPEG o un PNG sin decodificarlo' {
        New-TestPng (Join-Path $Dir 'a.png') 600 900
        New-TestJpg (Join-Path $Dir 'b.jpg') 460 215
        $p = Read-JuicerImageSize (Join-Path $Dir 'a.png')
        $p.Width | Should -Be 600; $p.Height | Should -Be 900; $p.Kind | Should -Be 'png'
        $j = Read-JuicerImageSize (Join-Path $Dir 'b.jpg')
        $j.Width | Should -Be 460; $j.Height | Should -Be 215; $j.Kind | Should -Be 'jpg'
        Set-Content -LiteralPath (Join-Path $Dir 'c.txt') -Value 'no soy una imagen'
        Read-JuicerImageSize (Join-Path $Dir 'c.txt') | Should -BeNullOrEmpty
        Read-JuicerImageSize (Join-Path $Dir 'no-existe.png') | Should -BeNullOrEmpty
    }

    It 'sólo descarga por HTTPS y de las tiendas' {
        Test-JuicerCoverUrl 'https://shared.cloudflare.steamstatic.com/store_item_assets/steam/apps/730/header.jpg' | Should -BeTrue
        Test-JuicerCoverUrl 'https://cdn1.epicgames.com/x.jpg' | Should -BeTrue
        Test-JuicerCoverUrl 'https://images.gog-statics.com/x.jpg' | Should -BeTrue
        Test-JuicerCoverUrl 'http://cdn1.epicgames.com/x.jpg' | Should -BeFalse
        Test-JuicerCoverUrl 'https://evilsteamstatic.com/x.jpg' | Should -BeFalse
        Test-JuicerCoverUrl 'https://example.com/x.jpg' | Should -BeFalse
        Test-JuicerCoverUrl 'no es una url' | Should -BeFalse
    }

    It 'de la caché de Steam elige la portada vertical, también con los nombres nuevos' {
        $cache = Join-Path $Dir 'appcache\librarycache'
        New-Item -ItemType Directory -Path (Join-Path $cache '730\abcd') -Force | Out-Null
        New-TestJpg (Join-Path $cache '730\abcd\1a2b.jpg') 460 215
        New-TestJpg (Join-Path $cache '730\3c4d.jpg') 600 900
        New-TestPng (Join-Path $cache '730\logo.png') 640 360
        Find-JuicerSteamCover $Dir '730' | Should -Be (Join-Path $cache '730\3c4d.jpg')
        # The old flat name wins when it is there.
        New-TestJpg (Join-Path $cache '570_library_600x900.jpg') 600 900
        Find-JuicerSteamCover $Dir '570' | Should -Be (Join-Path $cache '570_library_600x900.jpg')
        Find-JuicerSteamCover $Dir '999' | Should -BeNullOrEmpty
        Find-JuicerSteamCover '' '730' | Should -BeNullOrEmpty
    }

    It 'saca del catálogo de Epic la portada alta de cada juego' {
        $json = '[{"keyImages":[{"type":"DieselGameBox","url":"https://cdn1.epicgames.com/wide.jpg"},{"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/tall.jpg"}],"releaseInfo":[{"appId":"Fortnite"}]},' +
            '{"keyImages":[{"type":"DieselGameBoxTall","url":"https://malo.example.com/x.jpg"}],"releaseInfo":[{"appId":"Otro"}]}]'
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json))
        $map = ConvertFrom-JuicerEpicCatalog $b64
        $map['fortnite'] | Should -Be 'https://cdn1.epicgames.com/tall.jpg'
        $map.ContainsKey('otro') | Should -BeFalse
        (ConvertFrom-JuicerEpicCatalog $json)['fortnite'] | Should -Be 'https://cdn1.epicgames.com/tall.jpg'
        (ConvertFrom-JuicerEpicCatalog 'basura').Count | Should -Be 0
    }

    It 'en un juego de Xbox usa su logo, aunque lleve la escala en el nombre' {
        Set-Content -LiteralPath (Join-Path $Dir 'MicrosoftGame.config') -Value '<Game><ShellVisuals DefaultDisplayName="Juego" Square150x150Logo="Assets\Logo.png" StoreLogo="Assets\Store.png"/></Game>'
        New-Item -ItemType Directory -Path (Join-Path $Dir 'Assets') | Out-Null
        New-TestPng (Join-Path $Dir 'Assets\Logo.scale-200.png') 300 300
        New-TestPng (Join-Path $Dir 'Assets\Store.png') 50 50
        Find-JuicerXboxCover $Dir | Should -Be (Join-Path $Dir 'Assets\Logo.scale-200.png')
        Find-JuicerXboxCover (Join-Path $Dir 'nada') | Should -BeNullOrEmpty
    }

    It 'descarga una vez, guarda la portada y no vuelve a intentar lo que falló' {
        Mock -ModuleName WinJuicer Save-JuicerCoverDownload {
            param($Url, $Target)
            if ($Url -like '*/730/library_600x900.jpg') { [IO.File]::WriteAllBytes($Target, [byte[]](0xFF, 0xD8, 0xFF, 0xD9)); return $true }
            $false
        }
        $g = @{ Id = 'steam:730'; Name = 'Counter-Strike 2'; Dir = ''; Exe = '' }
        Get-JuicerCover $g -NoDownload | Should -BeNullOrEmpty
        $c = Get-JuicerCover $g
        $c.Kind | Should -Be 'cover'
        $c.Path | Should -BeLike '*steam_730.jpg'
        Should -Invoke -ModuleName WinJuicer Save-JuicerCoverDownload -Times 2 -Exactly
        (Get-JuicerCover $g -NoDownload).Path | Should -Be $c.Path
        Should -Invoke -ModuleName WinJuicer Save-JuicerCoverDownload -Times 2 -Exactly
        # A game with no cover anywhere: tried once, then left alone for a week.
        $none = @{ Id = 'steam:1'; Name = 'Sin portada'; Dir = ''; Exe = '' }
        Get-JuicerCover $none | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinJuicer Save-JuicerCoverDownload -Times 8 -Exactly
        Get-JuicerCover $none | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinJuicer Save-JuicerCoverDownload -Times 8 -Exactly
        Test-Path -LiteralPath (Join-Path (Get-JuicerCoverDir) 'steam_1.none') | Should -BeTrue
    }

    It 'agrupa la galería por tienda: las grandes primero y lo añadido a mano al final' {
        $games = @(
            @{ Id = 'custom:a'; Name = 'Zeta'; Launcher = 'custom' }
            @{ Id = 'medido:b.exe'; Name = 'b'; Launcher = 'Medido o limitado' }
            @{ Id = 'battle.net:d'; Name = 'Diablo IV'; Launcher = 'Battle.net' }
            @{ Id = 'gog:1'; Name = 'Witcher'; Launcher = 'GOG' }
            @{ Id = 'steam:2'; Name = 'Portal 2'; Launcher = 'Steam' }
            @{ Id = 'steam:1'; Name = 'Counter-Strike 2'; Launcher = 'Steam' }
            @{ Id = 'hoyoverse:g'; Name = 'Genshin'; Launcher = 'HoYoverse' }
        )
        $groups = @(Get-JuicerGuiGameGroups $games)
        @($groups | ForEach-Object { $_.Name }) | Should -Be @('Steam', 'GOG', 'Battle.net', 'HoYoverse', 'Añadidos por ti', 'Otros')
        @($groups[0].Games | ForEach-Object { $_.Name }) | Should -Be @('Counter-Strike 2', 'Portal 2')
        @(Get-JuicerGuiGameGroups @()).Count | Should -Be 0
    }

    It 'un ritmo elegido a mano se queda al recalcular, y Automático lo devuelve al recomendado' {
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'X'; MonitorId = 'm#X#1'; Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' } }
        Set-JuicerPacerFps 'cs2.exe' 237 $mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 237
        Get-JuicerPacerFps 'CS2.EXE' | Should -Be 237
        (Get-JuicerRecommendedFps 'cs2.exe' $mon).Manual | Should -BeTrue
        (Get-JuicerRecommendedFps 'cs2.exe' $mon -Automatic).Fps | Should -Be 157
        @(Update-JuicerFpsLimits $mon) | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 237
        # The priority is another field of the same entry: one does not erase the other.
        Set-JuicerPacerPriority 'cs2.exe' 'Latencia' $mon | Out-Null
        Set-JuicerPacerPriority 'cs2.exe' 'Fluidez' $mon | Out-Null
        Get-JuicerPacerFps 'cs2.exe' | Should -Be 237
        Set-JuicerPacerFps 'cs2.exe' 0 $mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        (Read-JuicerPacer).Games.ContainsKey('cs2.exe') | Should -BeFalse
        # From the command line too.
        @(Start-Juicer -LimitarFps 'b.exe' -Fps 120 -Si 6>$null)[-1] | Should -Be 0
        Get-JuicerPacerFps 'b.exe' | Should -Be 120
    }

    It 'un ritmo a mano puesto desde la galería o la línea de comandos tampoco se pierde al recalcular' {
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'X'; MonitorId = 'm#X#1'; Hz = 180; MaxHz = 180; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        $game = @{ Id = 'custom:a'; Name = 'A'; Exe = 'a.exe'; ExeName = 'a.exe' }
        (Invoke-JuicerGameSetup @($game) 'Fps' 178 -Monitor $mon -GpuCount 1).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['a.exe'] | Should -Be 178
        Get-JuicerPacerFps 'a.exe' | Should -Be 178
        @(Update-JuicerFpsLimits $mon) | Out-Null
        $M.Backend.State.FpsLimits['a.exe'] | Should -Be 178
        # «Recomendado» with a rate is the same request (-OptimizarJuegos -Fps).
        $game2 = @{ Id = 'custom:b'; Name = 'B'; Exe = 'b.exe'; ExeName = 'b.exe' }
        @(Invoke-JuicerGameSetup @($game2) 'Recomendado' 178 -Monitor $mon -GpuCount 1) | Out-Null
        Get-JuicerPacerFps 'b.exe' | Should -Be 178
        @(Update-JuicerFpsLimits $mon) | Out-Null
        $M.Backend.State.FpsLimits['b.exe'] | Should -Be 178
        # Without a rate («Fps» with Intro) it is automatic again.
        @(Invoke-JuicerGameSetup @($game) 'Fps' 0 -Monitor $mon -GpuCount 1) | Out-Null
        Get-JuicerPacerFps 'a.exe' | Should -Be 0
        $M.Backend.State.FpsLimits['a.exe'] | Should -Be 171
    }

    It 'un ritmo a mano se aplica aunque no se pueda leer la pantalla, y avisa si algo lo limita o no se mantiene' {
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'X'; MonitorId = 'm#X#1'; Hz = 180; MaxHz = 180; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        Set-JuicerPacerFps 'cs2.exe' 178 $mon | Out-Null
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $null }
        # The manual rate needs no screen to be applied again.
        $M.Backend.State.FpsLimits['cs2.exe'] = 100
        (Add-JuicerFpsLimit 'cs2.exe' 0).Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 178
        # NVIDIA's own cap for the game wins, and the result says so.
        $M.Backend.State.NvPredefined[('old.exe|{0}' -f [uint32]0x10835002)] = 60
        $r = Set-JuicerPacerFps 'old.exe' 178 $mon
        $M.Backend.State.FpsLimits['old.exe'] | Should -Be 60
        $r.Message | Should -BeLike '*178*60*'
    }

    It 'la página de un juego reúne lo que hace falta para dibujarla' {
        # The priority first: changing it recalculates the rate with the
        # screen of this PC, and CI runners have one.
        Set-JuicerPacerPriority 'cs2.exe' 'Latencia' | Out-Null
        Add-JuicerFpsLimit 'cs2.exe' 200 | Out-Null
        $p = Get-JuicerGuiGamePage @{ Id = 'steam:730'; Name = 'Counter-Strike 2'; Launcher = 'Steam'; Dir = ''; Exe = 'C:\Juegos\cs2.exe'; ExeName = 'cs2.exe' }
        $p.Game.Fps | Should -Be 200
        $p.Priority | Should -Be 'Latencia'
        $p.Competitive | Should -BeTrue
        $p.Engine | Should -Be 'nvidia'
        $p.Manual | Should -Be 0
        $p.TwoGpus | Should -BeFalse
        @($p.Tips).Count | Should -BeGreaterThan 0
        Test-JuicerCompetitiveGame 'cyberpunk2077.exe' | Should -BeFalse
    }

    It 'recuerda la gráfica de cada juego y la preferencia de la ventana' {
        $chart = @{ Series = [double[]](5.8, 6.0, 5.9, 12.0); TargetMs = 5.85; MaxMs = 12.0 }
        Save-JuicerFrameChart 'CS2.exe' $chart
        $c = Get-JuicerFrameChart 'cs2.exe'
        @($c.Series).Count | Should -Be 4
        $c.TargetMs | Should -Be 5.85
        Get-JuicerFrameChart 'otro.exe' | Should -BeNullOrEmpty
        for ($i = 0; $i -lt 45; $i++) { Save-JuicerFrameChart "j$i.exe" $chart }
        (Read-JuicerFrameCharts).Count | Should -Be 40
        (Read-JuicerUiPrefs).Advanced | Should -BeFalse
        Save-JuicerUiPrefs @{ Advanced = $true }
        (Read-JuicerUiPrefs).Advanced | Should -BeTrue
    }
}

Describe 'Tus juegos' {
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
        $script:Dir = Join-Path ([IO.Path]::GetTempPath()) ('wj-games-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Dir | Out-Null
        foreach ($f in 'Cyberpunk2077.exe', 'Other.exe', 'EldenRing.exe') { Set-Content -LiteralPath (Join-Path $Dir $f) -Value 'x' }
    }
    AfterEach { Remove-Item -LiteralPath $Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'lee los manifiestos de Steam y la configuración de Xbox' {
        $a = ConvertFrom-JuicerAcf "`"AppState`"`n{`n`t`"appid`"`t`t`"1091500`"`n`t`"name`"`t`t`"Cyberpunk 2077`"`n`t`"installdir`"`t`t`"Cyberpunk 2077`"`n}"
        $a.AppId | Should -Be '1091500'
        $a.Name | Should -Be 'Cyberpunk 2077'
        $a.InstallDir | Should -Be 'Cyberpunk 2077'
        ConvertFrom-JuicerAcf 'nada' | Should -BeNullOrEmpty
        Test-JuicerNotAGame 'Steamworks Common Redistributables' | Should -BeTrue
        Test-JuicerNotAGame 'Proton 9.0' | Should -BeTrue
        Test-JuicerNotAGame 'Counter-Strike 2' | Should -BeFalse
        $x = ConvertFrom-JuicerXboxConfig '<Game configVersion="1"><Executables><Executable Name="Forza.exe" Id="Game"/></Executables><ShellVisuals DefaultDisplayName="Forza Horizon 5"/></Game>'
        $x.Exe | Should -Be 'Forza.exe'
        $x.Name | Should -Be 'Forza Horizon 5'
    }

    It 'elige el .exe que de verdad ejecuta el juego' {
        $files = @(
            @{ Path = 'Cyberpunk 2077\unins000.exe'; Size = 3MB }
            @{ Path = 'REDprelauncher.exe'; Size = 5MB }
            @{ Path = 'bin\x64\Cyberpunk2077.exe'; Size = 60MB }
            @{ Path = 'bin\x64\CrashReporter\CrashReporter.exe'; Size = 2MB }
        )
        Select-JuicerGameExe $files 'Cyberpunk 2077' | Should -Be 'bin\x64\Cyberpunk2077.exe'
        $unreal = @(
            @{ Path = 'VALORANT.exe'; Size = 1MB }
            @{ Path = 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe'; Size = 90MB }
            @{ Path = 'Engine\Binaries\ThirdParty\CEF3\Win64\UnrealCEFSubProcess.exe'; Size = 1MB }
        )
        Select-JuicerGameExe $unreal 'VALORANT' | Should -Be 'ShooterGame\Binaries\Win64\VALORANT-Win64-Shipping.exe'
        Select-JuicerGameExe @() 'Juego' | Should -BeNullOrEmpty
    }

    It 'no confunde juegos con herramientas por el principio del nombre' {
        foreach ($n in 'CrashBandicoot', 'ServerSim', 'UpdateQuest', 'ConfigurationQuest', 'EditorsChoice', 'InstallationHorror', 'ReportCard') {
            Select-JuicerGameExe @(@{ Path = "$n.exe"; Size = 1MB }, @{ Path = 'unins000.exe'; Size = 50MB }) 'Zzz' | Should -Be "$n.exe" -Because $n
        }
        foreach ($n in 'UnityCrashHandler64', 'CrashReportClient', 'crashpad_handler', 'Game_uninstall', 'unins000', 'vc_redist.x64', 'dxsetup', 'EasyAntiCheat_Setup', 'UE4PrereqSetup_x64', 'CefSharp.BrowserSubprocess', 'steamwebhelper') {
            Select-JuicerGameExe @(@{ Path = "$n.exe"; Size = 50MB }, @{ Path = 'Juego.exe'; Size = 1MB }) 'Zzz' | Should -Be 'Juego.exe' -Because $n
        }
    }

    It 'si todos los .exe parecen herramientas, elige el mayor en vez de perder el juego' {
        Select-JuicerGameExe @(@{ Path = 'unins000.exe'; Size = 1MB }, @{ Path = 'vc_redist.x64.exe'; Size = 20MB }) 'Juego' | Should -Be 'vc_redist.x64.exe'
    }

    It 'la biblioteca de una carpeta de juego nunca es una unidad ni una carpeta del sistema' {
        $prot = @('C:\Windows', 'C:\Program Files', 'C:\Program Files (x86)', 'C:\ProgramData', 'C:\Users\yo')
        Get-JuicerGameLibraryFolder 'D:\Cyberpunk' $prot | Should -Be 'D:\Cyberpunk'
        Get-JuicerGameLibraryFolder 'C:\Program Files (x86)\Foo' $prot | Should -Be 'C:\Program Files (x86)\Foo'
        Get-JuicerGameLibraryFolder 'D:\Epic\Games\Fortnite' $prot | Should -Be 'D:\Epic\Games'
        Get-JuicerGameLibraryFolder 'D:\Epic\Games\Fortnite\' $prot | Should -Be 'D:\Epic\Games'
        Get-JuicerGameLibraryFolder 'C:\Users\yo\Games\Foo' $prot | Should -Be 'C:\Users\yo\Games'
        Get-JuicerGameLibraryFolder 'C:\Users\yo' $prot | Should -BeNullOrEmpty
        Test-JuicerBroadFolder 'D:\' $prot | Should -BeTrue
        Test-JuicerBroadFolder 'D:' $prot | Should -BeTrue
        Test-JuicerBroadFolder 'c:\users' $prot | Should -BeTrue
        Test-JuicerBroadFolder 'C:\' $prot | Should -BeTrue
        Test-JuicerBroadFolder 'C:\windows\system32' $prot | Should -BeFalse
        Test-JuicerBroadFolder 'D:\SteamLibrary\steamapps' $prot | Should -BeFalse
    }

    It 'la exclusión de Defender rechaza una unidad entera' {
        { New-JuicerDefenderTweak 'D:\' 'Epic Games' } | Should -Throw
        { New-JuicerDefenderTweak 'D:\SteamLibrary\steamapps' 'Steam' } | Should -Not -Throw
    }

    It 'un manifiesto ilegible no tumba el recolector de Steam' {
        $lib = Join-Path ([IO.Path]::GetTempPath()) ('wj-steam-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $lib 'common\Bueno') -Force | Out-Null
        try {
            Set-Content -LiteralPath (Join-Path $lib 'appmanifest_1.acf') -Value '"AppState" { "appid" "1" "name" "Bueno" "installdir" "Bueno" }'
            New-Item -ItemType Directory -Path (Join-Path $lib 'appmanifest_2.acf') | Out-Null
            $env:WJ_TEST_LIB = $lib
            Mock -ModuleName WinJuicer Get-JuicerGameLibraries { @(@{ Launcher = 'Steam'; Path = $env:WJ_TEST_LIB }) }
            $g = @(Get-JuicerSteamGames)
            $g.Count | Should -Be 1
            $g[0].Name | Should -Be 'Bueno'
        } finally {
            Remove-Item Env:\WJ_TEST_LIB -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $lib -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'un recolector que falla no hace «nuevos» sus juegos la próxima vez' {
        # A folder of its own, named apart from the Describe's $Dir (variables are
        # case-insensitive, and AfterEach deletes $Dir recursively).
        $root = Join-Path ([IO.Path]::GetTempPath()) ('wj-exe-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root | Out-Null
        $exe = Join-Path $root 'juego.exe'
        Set-Content -LiteralPath $exe -Value 'x'
        try {
            $gameDir = Split-Path -Parent $exe
            $ok7 = { New-JuicerGame 'Steam' '7' 'Siete' $gameDir $exe }.GetNewClosure()
            $ok8 = { New-JuicerGame 'Steam' '8' 'Ocho' $gameDir $exe }.GetNewClosure()
            $bad = { throw 'roto' }
            $find = { param($d, $n) $exe }.GetNewClosure()
            # Both games share the .exe, so only the first listed survives; use two files.
            $exe2 = $exe -replace '\.exe$', '2.exe'
            Set-Content -LiteralPath $exe2 -Value 'y'
            $ok8 = { New-JuicerGame 'GOG' '8' 'Ocho' $gameDir $exe2 }.GetNewClosure()
            $find = { param($d, $n) '' }
            @(Get-JuicerGames -Collectors @($ok7, $ok8) -FindExe $find) | Out-Null
            @(Get-JuicerGames -Collectors @($ok7, $bad) -FindExe $find) | Out-Null
            @(Get-JuicerGames -Collectors @($ok7, $ok8) -FindExe $find | Where-Object { $_.Id -eq 'gog:8' })[0].New | Should -BeFalse
        } finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'reconoce juegos de EA, Ubisoft, Battle.net y Riot, y no sus lanzadores' {
        (Get-JuicerPublisherGame 'Battlefield 2042' 'Electronic Arts' 'C:\EA Games\Battlefield 2042').Launcher | Should -Be 'EA'
        (Get-JuicerPublisherGame 'VALORANT' 'Riot Games, Inc' 'C:\Riot Games\VALORANT\live').Launcher | Should -Be 'Riot'
        (Get-JuicerPublisherGame 'Overwatch' 'Blizzard Entertainment' 'C:\Overwatch').Launcher | Should -Be 'Battle.net'
        Get-JuicerPublisherGame 'EA app' 'Electronic Arts' 'C:\EA app' | Should -BeNullOrEmpty
        Get-JuicerPublisherGame 'Ubisoft Connect' 'Ubisoft' 'C:\Ubisoft' | Should -BeNullOrEmpty
        Get-JuicerPublisherGame 'Notepad++' 'Notepad++ Team' 'C:\npp' | Should -BeNullOrEmpty
    }

    It 'junta los juegos de todas las tiendas, sin repetir, y marca los nuevos' {
        $d = $Dir
        $one = { @((New-JuicerGame 'Steam' '1091500' 'Cyberpunk 2077' $d), (New-JuicerGame 'GOG' '1' 'Elden Ring' $d (Join-Path $d 'EldenRing.exe'))) }.GetNewClosure()
        $find = { param($Folder, $Name) Join-Path $Folder 'Cyberpunk2077.exe' }
        $g = @(Get-JuicerGames -Collectors @($one) -FindExe $find)
        $g.Count | Should -Be 2
        ($g | Where-Object { $_.Name -eq 'Cyberpunk 2077' }).ExeName | Should -Be 'cyberpunk2077.exe'
        @($g | Where-Object { $_.New }).Count | Should -Be 0 -Because 'la primera vez no hay nada «nuevo»'
        # The same .exe listed by two launchers is one game.
        $two = { @((New-JuicerGame 'Steam' '1091500' 'Cyberpunk 2077' $d), (New-JuicerGame 'Epic Games' 'cp' 'Cyberpunk 2077' $d (Join-Path $d 'Cyberpunk2077.exe')), (New-JuicerGame 'Steam' '9' 'Otro juego' $d (Join-Path $d 'Other.exe'))) }.GetNewClosure()
        $g = @(Get-JuicerGames -Collectors @($two) -FindExe $find)
        $g.Count | Should -Be 2
        @($g | Where-Object { $_.New })[0].Name | Should -Be 'Otro juego'
        # The game already known keeps its id, whichever launcher lists it first.
        @($g | Where-Object { $_.Name -eq 'Cyberpunk 2077' })[0].Id | Should -Be 'steam:1091500'
        $rev = { @((New-JuicerGame 'Epic Games' 'cp' 'Cyberpunk 2077' $d (Join-Path $d 'Cyberpunk2077.exe')), (New-JuicerGame 'Steam' '1091500' 'Cyberpunk 2077' $d)) }.GetNewClosure()
        @(Get-JuicerGames -Collectors @($rev) -FindExe $find -KeepNew | Where-Object { $_.Name -eq 'Cyberpunk 2077' })[0].Id | Should -Be 'steam:1091500'
        # Picking another .exe sticks.
        Set-JuicerGameExe 'steam:1091500' (Join-Path $d 'Other.exe')
        @(Get-JuicerGames -Collectors @($one) -FindExe $find | Where-Object { $_.Id -eq 'steam:1091500' })[0].ExeName | Should -Be 'other.exe'
        $c = Add-JuicerCustomGame (Join-Path $d 'EldenRing.exe')
        @(Get-JuicerGames -Collectors @() -FindExe $find | Where-Object { $_.Id -eq $c.Id }).Count | Should -Be 1
    }

    It 'optimiza los marcados en un paso y lo quita igual' {
        $d = $Dir
        $g = @(Get-JuicerGames -Collectors @({ New-JuicerGame 'Steam' '1' 'Cyberpunk 2077' $d (Join-Path $d 'Cyberpunk2077.exe') }.GetNewClosure()))
        $g.Count | Should -Be 1
        # Without a screen to size the limit, it says so for that game and goes on.
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $null }
        $r = @(Invoke-JuicerGameSetup $g 'Recomendado' 0 -GpuCount 2)
        $r[0].Outcome | Should -Be 'Error'
        $r[0].Message | Should -BeLike '*pantalla*'
        Undo-JuicerTweak ('juego:gpu:' + $g[0].Exe.ToLowerInvariant()) | Out-Null
        $vrr = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true }; Info = @{}; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' }; Mode = 'Automatico' }
        $r = @(Invoke-JuicerGameSetup $g 'Recomendado' 0 -GpuCount 2 -Monitor $vrr)
        @($r | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -Be 2
        $M.Backend.State.FpsLimits['cyberpunk2077.exe'] | Should -BeGreaterThan 0
        $s = @(Get-JuicerGameStatus $g)[0]
        $s.Gpu | Should -BeTrue
        (Format-JuicerGameStatus $s) | Should -BeLike '* FPS (*ms) · GPU dedicada'
        @(Invoke-JuicerGameSetup $g 'Quitar').Count | Should -Be 2
        $M.Backend.State.FpsLimits.ContainsKey('cyberpunk2077.exe') | Should -BeFalse
        Format-JuicerGameStatus @(Get-JuicerGameStatus $g)[0] | Should -Be 'sin configurar'
        # With one graphics card there is no GPU to choose.
        @(Invoke-JuicerGameSetup $g 'Recomendado' 120 -GpuCount 1).Count | Should -Be 1
        $M.Backend.State.FpsLimits['cyberpunk2077.exe'] | Should -Be 120
    }

    It 'desde la línea de órdenes' {
        @(Start-Juicer -Juegos 6>$null)[-1] | Should -Be 0
        @(Start-Juicer -OptimizarJuegos -Si 6>$null)[-1] | Should -Be 0
    }
}

Describe 'Diario con varias entradas' {
    It 'los límites de FPS y las apps quitadas se leen bien con más cosas en el diario' {
        $m = New-NetMachine
        $m.Backend.State.FpsBackend = 'nvidia'
        $m.Backend.State.Appx['Microsoft.BingNews'] = @{ Installed = $true; Provisioned = $false }
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        [void](Invoke-JuicerTweak (New-JuicerFpsLimitTweak 'a.exe' 100))
        [void](Invoke-JuicerTweak (New-JuicerAppxTweak (Find-JuicerDebloatApp 'Microsoft.BingNews')))
        [void](Invoke-JuicerTweak (New-JuicerFpsLimitTweak 'b.exe' 120))
        $l = @(Get-JuicerFpsLimits)
        $l.Count | Should -Be 2
        ($l | Where-Object { $_.Exe -eq 'b.exe' }).Fps | Should -Be 120
        $a = @(Get-JuicerRemovedApps)
        $a.Count | Should -Be 1
        $a[0].Id | Should -Be 'app:Microsoft.BingNews'
    }
}

Describe 'Consejos por juego' {
    It 'CS2 con NVIDIA, VRR y el procesador limitando: Reflex con Boost y qué bajar' {
        $f = @(Get-JuicerGameTips -ExeName 'cs2.exe' -GpuVendor 'NVIDIA' -Use 'VRR' -Measured @{ GpuBound = 30; AvgFps = 300; Low1 = 200 } -Hz 165)
        $f[0].Area | Should -Be 'Consejos: Counter-Strike 2'
        @($f | Where-Object { $_.Title -eq 'NVIDIA Reflex: actívalo' })[0].Detail | Should -BeLike '*Activado + Boost*procesador limita*'
        @($f | Where-Object { $_.Title -like 'Sincronización vertical del juego: desactivada' })[0].Detail | Should -BeLike '*perfil de NVIDIA*'
        @($f | Where-Object { $_.Title -like 'El limitador de FPS del juego: desactivado' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like '*el procesador limita*' })[0].Severity | Should -Be 'Medio'
    }

    It 'CS2 con AMD: Anti-Lag 2 del propio juego; otro juego: el del panel' {
        @(Get-JuicerGameTips -ExeName 'cs2.exe' -GpuVendor 'AMD' | Where-Object { $_.Title -like 'AMD Anti-Lag 2*' }).Count | Should -Be 1
        @(Get-JuicerGameTips -ExeName 'r5apex.exe' -GpuVendor 'AMD' | Where-Object { $_.Title -like 'Radeon Anti-Lag*' }).Count | Should -Be 1
    }

    It 'con ELMB, VSync del driver y aviso si el juego no sostiene los Hz' {
        $f = @(Get-JuicerGameTips -ExeName 'valorant-win64-shipping.exe' -GpuVendor 'NVIDIA' -Use 'Estrobo' -Measured @{ GpuBound = 90; AvgFps = 190; Low1 = 150 } -Hz 180)
        @($f | Where-Object { $_.Title -like 'Sincronización vertical: la del driver*' }).Count | Should -Be 1
        @($f | Where-Object { $_.Title -like 'Con el estroboscopio no sostiene 180 FPS*' })[0].Severity | Should -Be 'Medio'
        @($f | Where-Object { $_.Title -like '*la gráfica limita*' }).Count | Should -Be 1
    }

    It 'conoce lo particular de algunos juegos y da lo general a los demás' {
        @(Get-JuicerGameTips -ExeName 'eldenring.exe' -GpuVendor 'NVIDIA' | Where-Object { $_.Title -like '*limitado a 60 FPS' }).Count | Should -Be 1
        $u = @(Get-JuicerGameTips -ExeName 'otro.exe' -Title 'Otro juego' -GpuVendor 'NVIDIA' -Use 'Fijo')
        $u[0].Area | Should -Be 'Consejos: Otro juego'
        @($u | Where-Object { $_.Title -eq 'Si tiene NVIDIA Reflex, actívalo' }).Count | Should -Be 1
        @($u | Where-Object { $_.Title -like 'Mídelo*' }).Count | Should -Be 1
        (Find-JuicerGameTip 'FortniteClient-Win64-Shipping.exe').Name | Should -Be 'Fortnite'
        Find-JuicerGameTip 'notepad.exe' | Should -BeNullOrEmpty
    }
}

Describe 'Mantener los juegos optimizados' {
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerUpkeepPath) -ErrorAction SilentlyContinue
        $script:Mon = @{ Display = [pscustomobject]@{ Hz = 165; MaxHz = 165; Primary = $true; MonitorId = '\\?\DISPLAY#AUS27B1#x#{y}'; Monitor = 'VG27AQ' }; Info = @{ Name = 'VG27AQ' }; Vrr = @{ Min = 48; Max = 165; Kind = 'FreeSync' }; Mode = 'Automatico' }
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        Mock -ModuleName WinJuicer Get-JuicerGames {
            @((New-JuicerGame 'Steam' '1' 'Viejo' 'C:\J\Viejo' 'C:\J\Viejo\viejo.exe'), (New-JuicerGame 'Steam' '2' 'Nuevo' 'C:\J\Nuevo' 'C:\J\Nuevo\nuevo.exe')) |
                ForEach-Object { $_.ExeName = (Split-Path -Leaf $_.Exe).ToLowerInvariant(); $_ }
        }
    }

    It 'sabe qué es nuevo y cuándo recalcular' {
        $g = @(@{ Id = 'a' }, @{ Id = 'b' })
        @((Get-JuicerUpkeepPlan $g @('a') 'x' 'x' $true).New).Count | Should -Be 1
        (Get-JuicerUpkeepPlan $g @('a', 'b') '165|VRR|m' '144|VRR|m' $true).Recalc | Should -BeTrue
        (Get-JuicerUpkeepPlan $g @('a', 'b') '165|VRR|m' '144|VRR|m' $false).Recalc | Should -BeFalse
        (Get-JuicerUpkeepPlan $g @('a', 'b') '165|VRR|m' '' $true).Recalc | Should -BeFalse
        Get-JuicerLimitSignature $Mon | Should -Be '165|VRR|AUS27B1|VG27AQ'
    }

    It 'optimiza sólo los juegos nuevos y sigue al monitor' {
        Save-JuicerUpkeepState @{ Seen = @('steam:1'); Signature = (Get-JuicerLimitSignature $Mon) }
        @(Invoke-JuicerUpkeep -Quiet | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -BeGreaterThan 0
        $M.Backend.State.FpsLimits['nuevo.exe'] | Should -Be 157
        $M.Backend.State.FpsLimits.ContainsKey('viejo.exe') | Should -BeFalse
        # Nothing new and the same monitor: nothing to do.
        @(Invoke-JuicerUpkeep -Quiet).Count | Should -Be 0
        # The monitor goes to 240 Hz: the limit follows.
        $script:Mon.Display.Hz = 240
        $script:Mon.Vrr = @{ Min = 48; Max = 240; Kind = 'FreeSync' }
        [void](Invoke-JuicerUpkeep -Quiet)
        $M.Backend.State.FpsLimits['nuevo.exe'] | Should -Be 224
        (Read-JuicerUpkeepState).Signature | Should -BeLike '240|*'
    }

    It 'un juego nuevo sin frame pacer disponible no se da por visto' {
        Save-JuicerUpkeepState @{ Seen = @('steam:1'); Signature = (Get-JuicerLimitSignature $Mon) }
        $M.Backend.State.FpsBackend = $null
        [void](Invoke-JuicerUpkeep -Quiet)
        (Read-JuicerUpkeepState).Seen | Should -Not -Contain 'steam:2'
        (Read-JuicerUpkeepState).Seen | Should -Contain 'steam:1'
    }

    It 'un juego oculto entra en lo ya visto sin optimizarse, y al mostrarlo no es nuevo' {
        Save-JuicerUpkeepState @{ Seen = @('steam:1'); Signature = (Get-JuicerLimitSignature $Mon) }
        Mock -ModuleName WinJuicer Get-JuicerGames {
            param([switch]$KeepNew, [switch]$IncludeHidden)
            $all = @((New-JuicerGame 'Steam' '1' 'Viejo' 'C:\J\Viejo' 'C:\J\Viejo\viejo.exe'), (New-JuicerGame 'Steam' '2' 'Herramienta' 'C:\J\H' 'C:\J\H\herramienta.exe')) |
                ForEach-Object { $_.ExeName = (Split-Path -Leaf $_.Exe).ToLowerInvariant(); $_.Hidden = ($_.Id -eq 'steam:2'); $_ }
            if ($IncludeHidden) { $all } else { @($all | Where-Object { -not $_.Hidden }) }
        }
        [void](Invoke-JuicerUpkeep -Quiet)
        $M.Backend.State.FpsLimits.ContainsKey('herramienta.exe') | Should -BeFalse
        (Read-JuicerUpkeepState).Seen | Should -Contain 'steam:2'
        # Shown again: not new, so the next sign-in leaves it alone.
        $plan = Get-JuicerUpkeepPlan @(@{ Id = 'steam:1' }, @{ Id = 'steam:2' }) @((Read-JuicerUpkeepState).Seen) 'x' 'x' $true
        @($plan.New).Count | Should -Be 0
    }

    It 'desde la línea de órdenes' {
        @(Start-Juicer -Mantener -Si 6>$null)[-1] | Should -Be 0
    }
}

Describe 'Protección y Brave' {
    BeforeEach {
        $script:M = New-NetMachine
        $script:Brave = 'HKLM\SOFTWARE\Policies\BraveSoftware\Brave'
    }

    It 'en los dos niveles: sin Tor, Brave Search con búsqueda segura y sin quedarse en segundo plano' {
        foreach ($level in 1, 2) {
            $script:M = New-NetMachine
            $M.Backend.State.Resolve['forcesafe.search.brave.com|'] = @('203.0.113.10', '203.0.113.11')
            [void](Enable-JuicerShield -Level $level)
            (Read-JuicerReg $Brave 'TorDisabled').Value | Should -Be 1 -Because "nivel $level"
            (Read-JuicerReg $Brave 'BackgroundModeEnabled').Value | Should -Be 0
            (Read-JuicerReg 'HKLM\SOFTWARE\Policies\Google\Chrome' 'BackgroundModeEnabled').Value | Should -Be 0
            # Brave blocks the default-search policies: none is set.
            Read-JuicerReg $Brave 'DefaultSearchProviderEnabled' | Should -BeNullOrEmpty
            # search.brave.com answered as forcesafe.search.brave.com; its
            # other names, as they are.
            $M.Backend.State.Hosts | Should -Match '(?m)^203\.0\.113\.10 search\.brave\.com\r?$'
            $M.Backend.State.Hosts | Should -Match '(?m)^203\.0\.113\.11 search\.brave\.com\r?$'
            $M.Backend.State.Hosts | Should -Not -Match '0\.0\.0\.0 search\.brave\.com'
            $M.Backend.State.Hosts | Should -Not -Match 'imgs\.search\.brave\.com'
            # Its VPN only goes at the strict level, as before.
            [bool](Read-JuicerReg $Brave 'BraveVPNDisabled') | Should -Be ($level -eq 2)
        }
    }

    It 'Brave Search: bloqueado sin conexión, con búsqueda segura en cuanto se puede, y nadie lo desvía' {
        # No answer yet: blocked, so that nothing unfiltered gets through.
        [void](Enable-JuicerShield -Level 1)
        $M.Backend.State.Hosts | Should -Match '(?m)^0\.0\.0\.0 search\.brave\.com\r?$'
        ($(Get-JuicerShieldCheck) | Where-Object { $_.Title -like 'Brave Search*' }).Ok | Should -BeNullOrEmpty
        # It answers: its addresses instead of the block.
        $M.Backend.State.Resolve['forcesafe.search.brave.com|'] = @('203.0.113.10')
        @(Repair-JuicerShield) | Should -Contain 'Archivo hosts: Brave Search con su búsqueda segura obligatoria, la VPN de Opera y las webs que bloqueas'
        $M.Backend.State.Hosts | Should -Match '(?m)^203\.0\.113\.10 search\.brave\.com\r?$'
        $M.Backend.State.Hosts | Should -Not -Match '0\.0\.0\.0 search\.brave\.com'
        ($(Get-JuicerShieldCheck) | Where-Object { $_.Title -like 'Brave Search*' }).Ok | Should -BeTrue
        # Without an answer again, the last addresses stay.
        $M.Backend.State.Resolve.Remove('forcesafe.search.brave.com|')
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        $M.Backend.State.Hosts | Should -Match '(?m)^203\.0\.113\.10 search\.brave\.com\r?$'
        # The addresses move: the block follows, and the old line goes.
        $M.Backend.State.Resolve['forcesafe.search.brave.com|'] = @('203.0.113.20')
        [void](Repair-JuicerShield)
        $M.Backend.State.Hosts | Should -Match '(?m)^203\.0\.113\.20 search\.brave\.com\r?$'
        $M.Backend.State.Hosts | Should -Not -Match '203\.0\.113\.10'
        # Someone points it elsewhere, outside the block: it is turned off.
        $M.Backend.State.Hosts += "198.51.100.7 search.brave.com`r`n"
        @(Repair-JuicerShield) | Should -Contain 'Archivo hosts: desactivada «198.51.100.7 search.brave.com», que saltaba el filtro'
    }

    It 'lo que bloqueaba la versión anterior (imágenes y cdn de Brave Search) vuelve a funcionar' {
        [void](Enable-JuicerShield -Level 1)
        $M.Backend.State.Hosts = $M.Backend.State.Hosts.Replace('# <<< Win Juicer', "0.0.0.0 imgs.search.brave.com`r`n:: imgs.search.brave.com`r`n0.0.0.0 cdn.search.brave.com`r`n# <<< Win Juicer")
        $M.Backend.State.Resolve['forcesafe.search.brave.com|'] = @('203.0.113.10')
        [void](Repair-JuicerShield)
        $M.Backend.State.Hosts | Should -Not -Match 'imgs\.search\.brave\.com'
        $M.Backend.State.Hosts | Should -Not -Match 'cdn\.search\.brave\.com'
    }

    It 'quita las reglas de buscador que Brave rechaza, si una versión anterior las puso' {
        [void](Enable-JuicerShield -Level 1)
        Write-JuicerReg $Brave 'DefaultSearchProviderEnabled' 'DWord' 1
        Write-JuicerReg $Brave 'DefaultSearchProviderSearchURL' 'String' 'x'
        [void](Repair-JuicerShield)
        Read-JuicerReg $Brave 'DefaultSearchProviderEnabled' | Should -BeNullOrEmpty
        Read-JuicerReg $Brave 'DefaultSearchProviderSearchURL' | Should -BeNullOrEmpty
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
    }

    It 'avisa a los navegadores abiertos y vacía la caché de DNS, sólo cuando cambia algo' {
        [void](Enable-JuicerShield -Level 1)
        @($M.Backend.State.Calls | Where-Object { $_ -eq 'RefreshPolicyEx' }).Count | Should -Be 1
        @($M.Backend.State.Calls | Where-Object { $_ -eq 'Clear-DnsClientCache' }).Count | Should -Be 1
        @(Repair-JuicerShield) | Should -BeNullOrEmpty
        @($M.Backend.State.Calls | Where-Object { $_ -eq 'RefreshPolicyEx' }).Count | Should -Be 1
        Read-JuicerReg 'HKLM\SOFTWARE\WinJuicer\Proteccion' 'Navegadores' | Should -Not -BeNullOrEmpty
    }

    It 'la comprobación: todo bien' {
        [void](Enable-JuicerShield)
        $M.Backend.State.Route = @{ Name = 'Ethernet'; Description = 'Realtek'; Virtual = $false; Servers = @('185.228.168.168', '2a0d:2a00:1::') }
        $M.Backend.State.Resolve['pornhub.com|185.228.168.168'] = @('0.0.0.0')
        $M.Backend.State.Resolve['pornhub.com|'] = @('0.0.0.0')
        $M.Backend.State.Resolve['forcesafe.search.brave.com|'] = @('203.0.113.10')
        [void](Repair-JuicerShield)
        [void]$M.Backend.State.Browsers.Add(@{ Name = 'brave'; Started = (Get-Date).AddMinutes(5) })
        $c = @(Get-JuicerShieldCheck)
        @($c | Where-Object { $_.Ok -ne $true }) | Should -BeNullOrEmpty
        $c.Count | Should -Be 4
    }

    It 'la comprobación: Brave abierto desde antes, que es lo que pasa al activarla con él abierto' {
        [void]$M.Backend.State.Browsers.Add(@{ Name = 'brave'; Started = (Get-Date).AddHours(-2) })
        [void](Enable-JuicerShield)
        $bad = @(Get-JuicerShieldCheck | Where-Object { $_.Ok -eq $false })
        $bad.Count | Should -Be 1
        $bad[0].Title | Should -Be 'Brave está abierto desde antes de la protección'
        $bad[0].Detail | Should -BeLike '*junto al reloj*'
    }

    It 'la comprobación: una VPN se lleva el tráfico, y Windows abre la web sin filtrar' {
        [void](Enable-JuicerShield)
        $M.Backend.State.Route = @{ Name = 'ProtonVPN'; Description = 'Wintun Userspace Tunnel'; Virtual = $true; Servers = @('10.2.0.1') }
        $M.Backend.State.Resolve['pornhub.com|185.228.168.168'] = @('0.0.0.0')
        $M.Backend.State.Resolve['pornhub.com|'] = @('66.254.114.41')
        $bad = @(Get-JuicerShieldCheck | Where-Object { $_.Ok -eq $false })
        $bad.Count | Should -Be 2
        $bad[0].Title | Should -BeLike '*ProtonVPN*adaptador virtual*'
        $bad[1].Title | Should -Be 'Windows todavía abre pornhub.com (66.254.114.41)'
    }

    It 'la comprobación: «no existe» es el bloqueo del filtro, no un fallo' {
        [void](Enable-JuicerShield)
        $M.Backend.State.Resolve['pornhub.com|185.228.168.168'] = 'NXDOMAIN'
        $M.Backend.State.Resolve['pornhub.com|'] = 'NXDOMAIN'
        (@(Get-JuicerShieldCheck) | Where-Object { $_.Title -like '*pornhub*' }).Ok | Should -BeTrue
    }

    It 'la comprobación: sin conexión no da nada por bueno ni por malo' {
        [void](Enable-JuicerShield)
        $c = @(Get-JuicerShieldCheck)
        ($c | Where-Object { $_.Title -like 'Sin conexión*' }).Ok | Should -BeNullOrEmpty
        @($c | Where-Object { $_.Ok -eq $false }) | Should -BeNullOrEmpty
    }

    It 'por línea de órdenes: 0 si funciona, 1 si no' {
        [void](Enable-JuicerShield)
        [void]$M.Backend.State.Browsers.Add(@{ Name = 'chrome'; Started = (Get-Date).AddDays(-1) })
        @(Start-Juicer -ProteccionAdultos Comprobar 6>$null)[-1] | Should -Be 1
        $M.Backend.State.Browsers.Clear()
        @(Start-Juicer -ProteccionAdultos Comprobar 6>$null)[-1] | Should -Be 0
    }

    # What a new version fixes reaches the PC when Win Juicer opens, not 15
    # minutes later: the task runs the copy just updated.
    Context 'al abrir Win Juicer' {
        BeforeAll {
            # Start-ScheduledTask only exists on Windows; to mock it, it has to exist.
            $script:Stub = -not (Get-Command Start-ScheduledTask -ErrorAction SilentlyContinue)
            if ($script:Stub) { function global:Start-ScheduledTask { param([string]$TaskName) } }
        }
        AfterAll {
            if ($script:Stub) { Remove-Item function:global:Start-ScheduledTask -ErrorAction SilentlyContinue }
        }
        BeforeEach {
            $script:On = $true
            Mock -ModuleName WinJuicer Test-JuicerShield { $script:On }
            Mock -ModuleName WinJuicer Test-JuicerShieldTask { $true }
            Mock -ModuleName WinJuicer Test-JuicerUpkeep { -not $script:On }
            Mock -ModuleName WinJuicer Install-JuicerCopy { 'C:\Program Files\WinJuicer' }
            Mock -ModuleName WinJuicer Start-ScheduledTask { }
        }

        It 'con la protección activada, su tarea corre ya con la copia nueva' {
            Update-JuicerCopy
            Should -Invoke -ModuleName WinJuicer Install-JuicerCopy -Times 1 -Exactly
            Should -Invoke -ModuleName WinJuicer Start-ScheduledTask -Times 1 -Exactly -ParameterFilter { $TaskName -eq 'Win Juicer - Protección contra contenido adulto' }
        }

        It 'si la copia no se pudo poner al día, no la corre: sería la vieja' {
            Mock -ModuleName WinJuicer Install-JuicerCopy { throw 'Acceso denegado' }
            Update-JuicerCopy
            Should -Invoke -ModuleName WinJuicer Start-ScheduledTask -Times 0 -Exactly
        }

        It 'sin la protección, sólo la copia del mantenimiento de los juegos' {
            $script:On = $false
            Update-JuicerCopy
            Should -Invoke -ModuleName WinJuicer Install-JuicerCopy -Times 1 -Exactly
            Should -Invoke -ModuleName WinJuicer Start-ScheduledTask -Times 0 -Exactly
        }
    }
}

Describe 'Revisión: arrancador, importar, vigilancia, monitor, inicio y medidas' {
    It 'el arrancador instala una copia propia, la vuelve a comprobar y su orden elevada cabe en una línea' {
        $wjOut = Join-Path ([IO.Path]::GetTempPath()) ('wj-launch-' + [guid]::NewGuid().ToString('N'))
        try {
            $rel = & (Join-Path $Root 'build/Build-Release.ps1') -Out (Join-Path $wjOut 'dist') -Version 'abc1234'
            $lines = [IO.File]::ReadAllLines($rel.Launcher)
            Invoke-Expression (($lines | Where-Object { $_ -notlike 'Start-WinJuicerOneLine *' }) -join "`n")
            $wjRoot = Join-Path $wjOut 'instalado'
            # A swapped zip (another hash) stops the installation and leaves nothing behind.
            $wjBad = Join-Path $wjOut 'mala.zip'
            Copy-Item -LiteralPath $rel.Zip -Destination $wjBad
            { Install-WinJuicerPackage -Zip $wjBad -Sha256 ('0' * 64) -Version 'abc1234' -Root $wjRoot } | Should -Throw '*no coincide*'
            @(Get-ChildItem -LiteralPath $wjRoot -Directory).Count | Should -Be 0
            # The right one is copied into the root, extracted there, and the source zip is gone.
            $wjGood = Join-Path $wjOut 'buena.zip'
            Copy-Item -LiteralPath $rel.Zip -Destination $wjGood
            $main = Install-WinJuicerPackage -Zip $wjGood -Sha256 $rel.Sha256 -Version 'abc1234' -Root $wjRoot
            $main | Should -BeLike "$wjRoot*WinJuicer.ps1"
            Test-Path -LiteralPath $main | Should -BeTrue
            Test-Path -LiteralPath $wjGood | Should -BeFalse
            # The command of the elevated process: one line, no double quotes, short, valid, with the hash in it.
            $cmd = Get-WinJuicerElevatedCommand -Zip "C:\Temp\it's.zip" -Sha256 $rel.Sha256 -Version 'abc1234' -Root 'C:\Program Files\WinJuicer-descarga'
            $cmd | Should -Not -Match "[`r`n`"]"
            $cmd.Length | Should -BeLessThan 2000
            $cmd | Should -BeLike "*$($rel.Sha256)*"
            $cmd | Should -BeLike "*C:\Temp\it''s.zip*"
            $errors = $null
            [void][System.Management.Automation.Language.Parser]::ParseInput($cmd, [ref]$null, [ref]$errors)
            $errors | Should -BeNullOrEmpty
        } finally {
            Remove-Item -LiteralPath $wjOut -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'el arrancador pide el permiso con tiempo máximo de descarga y avisa si se cancela el UAC' {
        $text = [IO.File]::ReadAllText((Join-Path $Root 'build/winjuicer.ps1.in'))
        $text | Should -BeLike '*-TimeoutSec*'
        $text | Should -BeLike '*1223*'
        $text | Should -BeLike '*-Verb RunAs*'
    }

    It 'la vigilancia del ajuste fino sólo cuenta los eventos WHEA 18, 19 y 47' {
        (Get-JuicerTuneWatchScript 'C:\x\ajuste.json') | Should -BeLike '*WHEA-Logger*Id = 18, 19, 47*'
        Mock -ModuleName WinJuicer Test-JuicerWindows { $true }
        Mock -ModuleName WinJuicer Read-JuicerTuneRecord { @{ Date = '2026-01-01T00:00:00'; Cpu = 'x'; Gpu = ''; GpuTool = ''; Bios = ''; RamSpeed = 0 } }
        Mock -ModuleName WinJuicer Get-JuicerBiosVersion { '' }
        Mock -ModuleName WinJuicer Get-JuicerRamSpeed { 0 }
        Mock -ModuleName WinJuicer Get-JuicerEventCount { 0 }
        [void](Get-JuicerTuneCheck)
        Should -Invoke -ModuleName WinJuicer Get-JuicerEventCount -Times 1 -Exactly -ParameterFilter { $Filter.ProviderName -like '*WHEA*' -and ($Filter.Id -join ',') -eq '18,19,47' }
    }

    It 'cada marca de monitor tiene un nombre corto entero, no cortado en el primer espacio' {
        Get-JuicerStrobeShortName 'LG' | Should -Be 'Motion Blur Reduction'
        Get-JuicerStrobeShortName 'MSI' | Should -Be 'Anti Motion Blur'
        Get-JuicerStrobeShortName 'Gigabyte' | Should -Be 'Aim Stabilizer'
        Get-JuicerStrobeShortName 'AOC' | Should -Be 'MBR'
        Get-JuicerStrobeShortName 'Desconocida' | Should -Be 'estroboscopio'
        Get-JuicerStrobeShortName $null | Should -Be 'estroboscopio'
        foreach ($b in $script:StrobeNames.Keys) { $script:StrobeShortNames.Contains($b) | Should -BeTrue -Because $b }
        $m = @{ Info = @{ Brand = 'MSI'; Name = 'MAG'; Hdr10 = $false }; Display = @{ MaxHz = 240; Hz = 240; ExactHz = 0 }; Vrr = $null; Mode = 'Estrobo' }
        Format-JuicerMonitor $m | Should -BeLike '*usado con Anti Motion Blur, sin VRR*'
    }

    It 'el veredicto de inicio mira el programa, no la carpeta donde está' {
        Get-JuicerCommandProgram '"C:\Program Files (x86)\Steam\tools\mio.exe" -a' | Should -Be 'mio.exe -a'
        Get-JuicerCommandProgram 'C:\Razer Cosas\x.exe /y' | Should -Be 'x.exe /y'
        Get-JuicerCommandProgram 'cmd /c algo' | Should -Be 'cmd /c algo'
        Get-JuicerStartupVerdict 'Mi herramienta' '"C:\Program Files (x86)\Steam\tools\mio.exe"' | Should -BeNullOrEmpty
        Get-JuicerStartupVerdict 'Mi herramienta' 'C:\Users\x\Discord\mio.exe' | Should -BeNullOrEmpty
        (Get-JuicerStartupVerdict 'Steam' '"C:\Archivos\Juegos\steam.exe" -silent').Verdict | Should -Be 'Prescindible'
        (Get-JuicerStartupVerdict 'Cliente' 'C:\Juegos\EpicGamesLauncher.exe').Verdict | Should -Be 'Prescindible'
    }

    It 'una exportación con Version que no es número se rechaza con un mensaje claro' {
        $f = Join-Path (Get-JuicerHome) 'config-version.json'
        foreach ($raw in '{ "Version": "abc", "Tweaks": [] }', '{ "Version": [1], "Tweaks": [] }', '[1,2]') {
            [IO.File]::WriteAllText($f, $raw)
            { Read-JuicerConfig $f } | Should -Throw 'Este archivo no es una exportación de Win Juicer válida.'
        }
        [IO.File]::WriteAllText($f, '{ "Version": 2, "Tweaks": [] }')
        { Read-JuicerConfig $f } | Should -Throw '*versión 1*'
    }

    It 'exportar escribe el archivo entero, sin dejar el temporal' {
        $f = Join-Path (Get-JuicerHome) 'exportada.json'
        [void](Export-JuicerConfig $f)
        Test-Path -LiteralPath "$f.tmp" | Should -BeFalse
        (Read-JuicerConfig $f) | Should -BeOfType [hashtable]
    }

    It 'importar salta las apps que este equipo usa, con el mismo texto que Debloat' {
        $hw = @{ Cpu = @{ DualCcdX3D = $false; Name = 'x' }; GamePass = $true }
        $s = Split-JuicerImportApps @('Microsoft.GamingApp', 'Microsoft.BingNews', 'Microsoft.NoExiste') $hw
        @($s.Keep) | Should -Be @('Microsoft.BingNews')
        @($s.Needed).Count | Should -Be 1
        $s.Needed[0] | Should -Be "· App Xbox: $(Get-JuicerAppxNeed (Find-JuicerDebloatApp 'Microsoft.GamingApp') $hw)"
        $s = Split-JuicerImportApps @('Microsoft.GamingApp') @{ Cpu = @{}; GamePass = $false }
        @($s.Keep) | Should -Be @('Microsoft.GamingApp')
        @($s.Needed).Count | Should -Be 0
    }

    It 'importar pregunta una a una por lo Extremo y lo que pide cuidado' {
        $extreme = @(Get-JuicerCatalog | Where-Object { $_.Level -ge 3 } | Select-Object -First 2)
        $safe = @(Get-JuicerCatalog | Where-Object { $_.Level -lt 3 } | Select-Object -First 1)
        $extreme.Count | Should -Be 2
        # The mock runs in the module's scope: what it must refuse travels in an environment variable.
        $env:WJ_TEST_REFUSE = $extreme[0].Title
        try {
            Mock -ModuleName WinJuicer Confirm-JuicerGui { -not $Text.Contains($env:WJ_TEST_REFUSE) }
            $kept = @(Select-JuicerGuiExtreme @($extreme + $safe))
            Should -Invoke -ModuleName WinJuicer Confirm-JuicerGui -Times 2 -Exactly
            @($kept | ForEach-Object { $_.Id }) | Should -Not -Contain $extreme[0].Id
            @($kept | ForEach-Object { $_.Id }) | Should -Contain $extreme[1].Id
            @($kept | ForEach-Object { $_.Id }) | Should -Contain $safe[0].Id
        } finally {
            Remove-Item Env:WJ_TEST_REFUSE -ErrorAction SilentlyContinue
        }
        Mock -ModuleName WinJuicer Confirm-JuicerGui { $false }
        @(Select-JuicerGuiCarefulApps @('Microsoft.GamingApp', 'Microsoft.BingNews')) | Should -Be @('Microsoft.BingNews')
        Mock -ModuleName WinJuicer Confirm-JuicerGui { $true }
        @(Select-JuicerGuiCarefulApps @('Microsoft.GamingApp', 'Microsoft.BingNews')) | Should -Be @('Microsoft.GamingApp', 'Microsoft.BingNews')
    }

    It 'el aviso de versión no salta por una publicada más antigua cuando son números' {
        Get-JuicerUpdateNotice -Local '1.2.0' -Latest { '1.1.0' } | Should -BeNullOrEmpty
        (Get-JuicerUpdateNotice -Local '1.2.0' -Latest { '1.10.0' }).Latest | Should -Be '1.10.0'
        (Get-JuicerUpdateNotice -Local 'abc1234' -Latest { 'def5678' }).Latest | Should -Be 'def5678'
    }

    It 'la medida de arranque avisa si un arranque fue con Inicio rápido y el otro no' {
        $b = @{ Date = '2026-10-01T10:00:00'; Label = 'Antes'; BootMs = 40000; BootDate = '2026-10-01T09:58:00'; FastStartup = $true }
        $a = @{ Date = '2026-10-02T10:00:00'; Label = 'Medida'; BootMs = 60000; BootDate = '2026-10-02T09:58:00'; FastStartup = $false }
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like '*no son del mismo tipo*' }).Count | Should -Be 1
        $a.FastStartup = $true
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like '*no son del mismo tipo*' }).Count | Should -Be 0
        $a.Remove('FastStartup')
        @(Compare-JuicerMetrics $b $a | Where-Object { $_.Title -like '*no son del mismo tipo*' }).Count | Should -Be 0
    }
}

Describe 'Correcciones: juegos, portadas, monitor y catálogo' {
    BeforeAll {
        function New-TestJpgFile {
            param([string]$Path, [int]$W, [int]$H)
            # SOI, APP0, frame header, padded past the 1 KB the downloader asks for.
            $b = [byte[]](@(0xFF, 0xD8, 0xFF, 0xE0, 0, 16) + @(0) * 14 + @(0xFF, 0xC0, 0, 17, 8, (($H -shr 8) -band 255), ($H -band 255), (($W -shr 8) -band 255), ($W -band 255), 3) + @(0) * 1100)
            [IO.File]::WriteAllBytes($Path, $b)
        }
        $script:TestMon = {
            param([string]$Name)
            @{ Display = [pscustomobject]@{ Monitor = $Name; MonitorId = "\\?\DISPLAY#TST1234#5&abc&0&UID1"; Hz = 240; MaxHz = 240; Primary = $true }; Info = @{ Name = $Name; Brand = 'Marca' }; Vrr = $null }
        }
    }
    BeforeEach {
        $script:M = New-FakeMachine
        $script:Tmp = Join-Path ([IO.Path]::GetTempPath()) ('wj-corr-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $Tmp | Out-Null
        Remove-Item -LiteralPath (Get-JuicerCoverDir) -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath) -ErrorAction SilentlyContinue
    }
    AfterEach {
        Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath) -ErrorAction SilentlyContinue
    }

    It 'la telemetría del servicio también se salta en Windows Insider' {
        $t = @(Get-JuicerCatalog | Where-Object { $_.Id -eq 'fondo.telemetria' })[0]
        $t.Skip | Should -Not -BeNullOrEmpty
        Mock -ModuleName WinJuicer Test-JuicerInsider { $true }
        (& $t.Skip) | Should -BeLike '*Insider*'
        Mock -ModuleName WinJuicer Test-JuicerInsider { $false }
        (& $t.Skip) | Should -BeNullOrEmpty
    }

    It 'los juegos configurados incluyen los frame pacers, y la consola los quita por Remove-JuicerFpsLimit' {
        Mock -ModuleName WinJuicer Read-JuicerJournal { @(@{ Id = 'fps:cs2.exe'; Title = 'Frame pacer' }, @{ Id = 'juego:gpu:a.exe'; Title = 'GPU' }, @{ Id = 'privacidad.x'; Title = 'Otro' }) }
        @(Get-JuicerConfiguredGames | ForEach-Object { $_.Id }) | Should -Be @('fps:cs2.exe', 'juego:gpu:a.exe')
        Mock -ModuleName WinJuicer Write-JuicerHeader {}
        Mock -ModuleName WinJuicer Wait-JuicerKey {}
        Mock -ModuleName WinJuicer Show-JuicerResults {}
        Mock -ModuleName WinJuicer Read-JuicerChoice { '1,2' }
        Mock -ModuleName WinJuicer Remove-JuicerFpsLimit { $null }
        Mock -ModuleName WinJuicer Undo-JuicerTweak { $null }
        Show-JuicerConfiguredGames 6>$null
        Should -Invoke -ModuleName WinJuicer Remove-JuicerFpsLimit -Times 1 -Exactly -ParameterFilter { $Exe -eq 'cs2.exe' }
        Should -Invoke -ModuleName WinJuicer Undo-JuicerTweak -Times 1 -Exactly -ParameterFilter { $Id -eq 'juego:gpu:a.exe' }
    }

    It 'las bibliotecas incluyen las carpetas de los juegos de EA, Ubisoft, Battle.net y Riot, sin repetir' {
        $games = Join-Path $Tmp 'EA Games'
        foreach ($n in 'Uno', 'Dos') { New-Item -ItemType Directory -Path (Join-Path $games $n) -Force | Out-Null }
        $one = @{ Launcher = 'EA'; Dir = (Join-Path $games 'Uno') }
        $two = @{ Launcher = 'EA'; Dir = (Join-Path $games 'Dos') }
        $env:WJ_TEST_PUB = ($one.Dir, $two.Dir) -join '|'
        try {
            Mock -ModuleName WinJuicer Get-JuicerPublisherGames { foreach ($d in ($env:WJ_TEST_PUB -split '\|')) { @{ Launcher = 'EA'; Dir = $d } } }
            $libs = @(Get-JuicerGameLibraries | Where-Object { $_.Launcher -eq 'EA' })
            $libs.Count | Should -Be 1
            $libs[0].Path | Should -Be $games
        } finally {
            Remove-Item Env:\WJ_TEST_PUB -ErrorAction SilentlyContinue
        }
    }

    It 'los agentes de anti-trampas y actualización no son juegos, pero un juego llamado «Launcher» sí' {
        foreach ($n in 'Riot Vanguard', 'Battle.net Update Agent', 'Easy Anti-Cheat', 'EasyAntiCheat', 'BattlEye Service', 'Anti-Cheat Client', 'Crash Reporter', 'Crash Handler') {
            Test-JuicerNotAGame $n | Should -BeTrue -Because $n
        }
        foreach ($n in 'Call of Duty: Vanguard', 'Rocket Launcher Simulator', 'Space Launcher', 'The Cheat') {
            Test-JuicerNotAGame $n | Should -BeFalse -Because $n
        }
        Select-JuicerGameExe @(@{ Path = 'GameLaunchHelper.exe'; Size = 50MB }, @{ Path = 'Juego.exe'; Size = 1MB }) 'Zzz' | Should -Be 'Juego.exe'
    }

    It 'en Xbox no toma a ciegas el primer ejecutable' {
        $cfg = '<Game><Executables><Executable Name="GameLaunchHelper.exe" Id="Helper"/><Executable Name="Juego.exe" Id="Game"/></Executables></Game>'
        (ConvertFrom-JuicerXboxConfig $cfg).Exe | Should -Be 'Juego.exe'
        $noId = '<Game><Executables><Executable Name="GameLaunchHelper.exe"/><Executable Name="Real.exe"/></Executables></Game>'
        (ConvertFrom-JuicerXboxConfig $noId).Exe | Should -Be 'Real.exe'
        $only = '<Game><Executables><Executable Name="GameLaunchHelper.exe"/></Executables></Game>'
        (ConvertFrom-JuicerXboxConfig $only).Exe | Should -Be 'GameLaunchHelper.exe'
        (ConvertFrom-JuicerXboxConfig '<Game/>').Exe | Should -Be ''
    }

    It 'Epic: una instalación incompleta no es un juego' {
        $prog = Join-Path $Tmp 'pd'
        $man = Join-Path $prog 'Epic\EpicGamesLauncher\Data\Manifests'
        New-Item -ItemType Directory -Path $man -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Tmp 'g\Bueno'), (Join-Path $Tmp 'g\Medio') -Force | Out-Null
        foreach ($x in @(@('b', 'Bueno', 'false'), @('m', 'Medio', 'true'))) {
            Set-Content -LiteralPath (Join-Path $man "$($x[0]).item") -Value ('{"AppName":"' + $x[0] + '","DisplayName":"' + $x[1] + '","InstallLocation":"' + ((Join-Path $Tmp "g\$($x[1])") -replace '\\', '\\') + '","bIsIncompleteInstall":' + $x[2] + '}')
        }
        $old = $env:ProgramData
        $env:ProgramData = $prog
        try {
            @(Get-JuicerEpicGames | ForEach-Object { $_.Name }) | Should -Be @('Bueno')
        } finally {
            $env:ProgramData = $old
        }
    }

    It 'la portada ancha de Steam es sólo un recurso: una vertical local la sustituye' {
        Mock -ModuleName WinJuicer Save-JuicerCoverDownload {
            param($Url, $Target)
            if ($Url -like '*/header.jpg') { [IO.File]::WriteAllBytes($Target, [byte[]](@(0xFF, 0xD8, 0xFF, 0xE0, 0, 16) + @(0) * 14 + @(0xFF, 0xC0, 0, 17, 8, 0, 215, 1, 204, 3) + @(0) * 1100)); return $true }
            $false
        }
        $g = @{ Id = 'steam:731'; Name = 'Juego'; Dir = ''; Exe = '' }
        $c = Get-JuicerCover $g
        $c.Kind | Should -Be 'cover'
        $c.Path | Should -BeLike '*steam_731.wide.jpg'
        Test-Path -LiteralPath (Join-Path (Get-JuicerCoverDir) 'steam_731.jpg') | Should -BeFalse
        # Still there, and without downloading again.
        (Get-JuicerCover $g -NoDownload).Path | Should -BeLike '*steam_731.wide.jpg'
        # Steam's own library cache fills in later: the portrait wins and the fallback goes.
        $cache = Join-Path $Tmp 'appcache\librarycache'
        New-Item -ItemType Directory -Path $cache -Force | Out-Null
        New-TestJpgFile (Join-Path $cache '731_library_600x900.jpg') 600 900
        $env:WJ_TEST_STEAM = $Tmp
        try {
            Mock -ModuleName WinJuicer Get-JuicerSteamDir { $env:WJ_TEST_STEAM }
            (Get-JuicerCover $g -NoDownload).Path | Should -Be (Join-Path $cache '731_library_600x900.jpg')
            Test-Path -LiteralPath (Join-Path (Get-JuicerCoverDir) 'steam_731.wide.jpg') | Should -BeFalse
            # A wide cover cached as the main one by an older version is replaced the same way...
            New-TestJpgFile (Join-Path (Get-JuicerCoverDir) 'steam_732.jpg') 460 215
            New-TestJpgFile (Join-Path $cache '732_library_600x900.jpg') 600 900
            $old = Get-JuicerCover @{ Id = 'steam:732'; Name = 'Viejo'; Dir = ''; Exe = '' } -NoDownload
            $old.Path | Should -Be (Join-Path $cache '732_library_600x900.jpg')
            # ...and with no portrait anywhere it is still shown (as the fallback).
            New-TestJpgFile (Join-Path (Get-JuicerCoverDir) 'steam_733.jpg') 460 215
            $w = Get-JuicerCover @{ Id = 'steam:733'; Name = 'Sin vertical'; Dir = ''; Exe = '' } -NoDownload
            $w.Kind | Should -Be 'cover'
            $w.Path | Should -BeLike '*steam_733.wide.jpg'
        } finally {
            Remove-Item Env:\WJ_TEST_STEAM -ErrorAction SilentlyContinue
        }
    }

    It 'Epic sin catálogo o sin ese juego no deja la marca de «sin portada» de una semana' {
        Mock -ModuleName WinJuicer Get-JuicerEpicCoverUrl { $null }
        Mock -ModuleName WinJuicer Save-JuicerExeIcon { $false }
        Get-JuicerCover @{ Id = 'epic games:abc'; Name = 'X'; Dir = ''; Exe = '' } | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path (Get-JuicerCoverDir) 'epic games_abc.none') | Should -BeFalse
        @(Get-ChildItem -LiteralPath (Get-JuicerCoverDir) -Filter '*.none').Count | Should -Be 0
        # Steam, where a miss is definite, keeps it.
        Mock -ModuleName WinJuicer Save-JuicerCoverDownload { $false }
        Get-JuicerCover @{ Id = 'steam:9'; Name = 'Y'; Dir = ''; Exe = '' } | Should -BeNullOrEmpty
        Test-Path -LiteralPath (Join-Path (Get-JuicerCoverDir) 'steam_9.none') | Should -BeTrue
    }

    It 'sin catcache.bin no se recuerda el catálogo vacío' {
        $prog = Join-Path $Tmp 'pd'
        New-Item -ItemType Directory -Path $prog | Out-Null
        $old = $env:ProgramData
        $env:ProgramData = $prog
        try {
            & (Get-Module WinJuicer) { $script:EpicCovers = $null }
            Get-JuicerEpicCoverUrl 'abc' | Should -BeNullOrEmpty
            & (Get-Module WinJuicer) { $null -eq $script:EpicCovers } | Should -BeTrue
            $cat = Join-Path $prog 'Epic\EpicGamesLauncher\Data\Catalog'
            New-Item -ItemType Directory -Path $cat -Force | Out-Null
            Set-Content -LiteralPath (Join-Path $cat 'catcache.bin') -Value '[{"keyImages":[{"type":"DieselGameBoxTall","url":"https://cdn1.epicgames.com/t.jpg"}],"releaseInfo":[{"appId":"abc"}]}]'
            Get-JuicerEpicCoverUrl 'ABC' | Should -Be 'https://cdn1.epicgames.com/t.jpg'
        } finally {
            $env:ProgramData = $old
            & (Get-Module WinJuicer) { $script:EpicCovers = $null }
        }
    }

    It 'una descarga que redirige fuera de las tiendas se descarta; dentro, se sigue hasta tres veces' {
        $target = Join-Path $Tmp 'cubierta.jpg'
        $env:WJ_TEST_TMP = $Tmp
        try {
            Mock -ModuleName WinJuicer Invoke-JuicerCoverRequest {
                param($Url, $OutFile)
                switch -Wildcard ($Url) {
                    '*/a.jpg' { return @{ Status = 302; Location = 'https://evil.example.com/x.jpg' } }
                    '*/b.jpg' { return @{ Status = 301; Location = '/c.jpg' } }
                    '*/c.jpg' {
                        $img = [byte[]](@(0xFF, 0xD8, 0xFF, 0xE0, 0, 16) + @(0) * 14 + @(0xFF, 0xC0, 0, 17, 8, 3, 132, 2, 88, 3) + @(0) * 1100)
                        [IO.File]::WriteAllBytes($OutFile, $img)
                        return @{ Status = 200; Location = '' }
                    }
                    '*/loop.jpg' { return @{ Status = 302; Location = 'https://cdn.cloudflare.steamstatic.com/loop.jpg' } }
                }
                throw "inesperada: $Url"
            }
            Save-JuicerCoverDownload 'https://cdn.cloudflare.steamstatic.com/a.jpg' $target | Should -BeFalse
            Should -Invoke -ModuleName WinJuicer Invoke-JuicerCoverRequest -Times 1 -Exactly
            Test-Path -LiteralPath $target | Should -BeFalse
            Save-JuicerCoverDownload 'https://cdn.cloudflare.steamstatic.com/b.jpg' $target | Should -BeTrue
            Test-Path -LiteralPath $target | Should -BeTrue
            Test-Path -LiteralPath "$target.descarga" | Should -BeFalse
            Remove-Item -LiteralPath $target
            Save-JuicerCoverDownload 'https://cdn.cloudflare.steamstatic.com/loop.jpg' $target | Should -BeFalse
            # The first request plus three hops, and no more.
            Should -Invoke -ModuleName WinJuicer Invoke-JuicerCoverRequest -Times 7 -Exactly
        } finally {
            Remove-Item Env:\WJ_TEST_TMP -ErrorAction SilentlyContinue
        }
    }

    It 'lee a dónde redirige una respuesta, en Windows PowerShell y en PowerShell 7' {
        Get-JuicerRedirectLocation ([pscustomobject]@{ Headers = @{ Location = 'https://x.example.com/a' } }) | Should -Be 'https://x.example.com/a'
        $h = New-Object Net.WebHeaderCollection
        $h['Location'] = 'https://y.example.com/b'
        Get-JuicerRedirectLocation ([pscustomobject]@{ Headers = $h }) | Should -Be 'https://y.example.com/b'
        Get-JuicerRedirectLocation $null | Should -Be ''
        # The request itself: a 3xx that is returned, not followed.
        Mock -ModuleName WinJuicer Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 302; BaseResponse = [pscustomobject]@{ Headers = @{ Location = 'https://evil.example.com/z' } } }
        }
        $r = Invoke-JuicerCoverRequest 'https://cdn.cloudflare.steamstatic.com/a.jpg' (Join-Path $Tmp 'x')
        $r.Status | Should -Be 302
        $r.Location | Should -Be 'https://evil.example.com/z'
        Should -Invoke -ModuleName WinJuicer Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $MaximumRedirection -eq 0 }
    }

    It 'PowerShell 7: un 3xx que lanza HttpResponseException también se entiende como redirección' -Skip:($PSVersionTable.PSEdition -ne 'Core') {
        Mock -ModuleName WinJuicer Invoke-WebRequest {
            $resp = [Net.Http.HttpResponseMessage]::new(302)
            $resp.Headers.Location = [uri]'https://evil.example.com/z'
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('redirect', $resp)
        }
        $r = Invoke-JuicerCoverRequest 'https://cdn.cloudflare.steamstatic.com/a.jpg' (Join-Path $Tmp 'x')
        $r.Status | Should -Be 302
        $r.Location | Should -Be 'https://evil.example.com/z'
        # A real error still throws, for Get-JuicerWebFailureKind to classify.
        Mock -ModuleName WinJuicer Invoke-WebRequest { throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('nada', [Net.Http.HttpResponseMessage]::new(404)) }
        { Invoke-JuicerCoverRequest 'https://cdn.cloudflare.steamstatic.com/a.jpg' (Join-Path $Tmp 'x') } | Should -Throw
    }

    It 'reconoce muchos más monitores OLED por su nombre' {
        foreach ($n in 'PG32UCDM', 'PG27AQDP', 'PG27UCDM', 'PG34WCDM', 'XG27AQDMG', '27GR95QE', '27GS95QE', '32GS95UE', '45GR95QE', 'LS32DG802 G80SD', 'G60SD', 'G85SD', 'G95SC', 'AW2725DF', 'AW3225QF', 'AW3423DWF', 'MAG 271QPX', 'MPG 321URX', '271QRX', 'FO27Q3', 'FO32U2', 'MSI QD-OLED', 'Algo WOLED', 'OLED48C1') {
            Test-JuicerOledName $n | Should -BeTrue -Because $n
        }
        foreach ($n in 'VG27AQ3A', 'XG27AQ', 'LG 27GP850', 'U2723QE', '') {
            Test-JuicerOledName $n | Should -BeFalse -Because $n
        }
    }

    It 'lo que dice el dueño sobre OLED manda sobre el nombre, y el modo no lo pisa' {
        $m = & $TestMon 'PG32UCDM'
        Test-JuicerMonitorOled $m | Should -BeTrue
        Set-JuicerMonitorOled $m $false | Should -BeFalse
        Test-JuicerMonitorOled $m | Should -BeFalse
        Get-JuicerMonitorOledOverride $m | Should -Be $false
        # Another monitor with a name that does not say OLED, but is.
        $o = & $TestMon 'Raro 27'
        Test-JuicerMonitorOled $o | Should -BeFalse
        (Get-JuicerMonitorOledOverride $o) | Should -BeNullOrEmpty
        Set-JuicerMonitorOled $o $true | Should -BeTrue
        # Changing the use of the monitor keeps it.
        [void](Set-JuicerMonitorMode $o 'Fijo')
        Get-JuicerMonitorOledOverride $o | Should -Be $true
        Get-JuicerMonitorMode $o | Should -Be 'Fijo'
        # The findings follow it.
        $o.Info.Brand = 'ASUS'
        $o.Info.MaxNits = 0
        @(Get-JuicerMonitorFindings @($o) 'NVIDIA' | Where-Object { $_.Title -like 'OLED*' }).Count | Should -Be 1
        # Back to the name's guess; with the mode left alone.
        Set-JuicerMonitorOled $o $null | Should -BeFalse
        Get-JuicerMonitorMode $o | Should -Be 'Fijo'
        @(Get-JuicerMonitorFindings @($o) 'NVIDIA' | Where-Object { $_.Title -like 'OLED*' }).Count | Should -Be 0
        # Said and then unsaid, with no mode, leaves no trace in the file.
        $x = & $TestMon 'Otro'
        [void](Set-JuicerMonitorOled $x $true)
        [void](Set-JuicerMonitorOled $x $null)
        (Read-JuicerMonitorModes).ContainsKey((Get-JuicerMonitorKey $x)) | Should -BeFalse
    }

    It 'desde la línea de órdenes, -PantallaOled' {
        $env:WJ_TEST_OLEDMON = 'Raro 27'
        $mon = & $TestMon 'Raro 27'
        try {
            Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { @{ Display = [pscustomobject]@{ Monitor = $env:WJ_TEST_OLEDMON; MonitorId = '\\?\DISPLAY#TST1234#5&abc&0&UID1'; Hz = 240; MaxHz = 240; Primary = $true }; Info = @{ Name = $env:WJ_TEST_OLEDMON; Brand = 'Marca' }; Vrr = $null } }
            @(Start-Juicer -PantallaOled 'Si' -Si 6>$null)[-1] | Should -Be 0
            Test-JuicerMonitorOled $mon | Should -BeTrue
            @(Start-Juicer -PantallaOled 'No' -Si 6>$null)[-1] | Should -Be 0
            Test-JuicerMonitorOled $mon | Should -BeFalse
            @(Start-Juicer -PantallaOled 'Auto' -Si 6>$null)[-1] | Should -Be 0
            Get-JuicerMonitorOledOverride $mon | Should -BeNullOrEmpty
        } finally {
            Remove-Item Env:\WJ_TEST_OLEDMON -ErrorAction SilentlyContinue
        }
    }
}

Describe 'Reflex y tope manual' {
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath), (Get-JuicerPacerPath) -ErrorAction SilentlyContinue
    }

    It 'avisa sólo con NVIDIA, VRR, Reflex conocido y un ritmo entre el tope de Reflex y los Hz' {
        $n = Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 178 180 'VRR' 'NVIDIA'
        $n | Should -BeLike '*se queda en 171 FPS*tus 180 Hz*apagar Reflex*'
        (Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 140 144 'EstroboSync' 'NVIDIA') | Should -BeLike '*138 FPS*144 Hz*'
        (Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 230 240 'VRR' 'NVIDIA') | Should -BeLike '*224 FPS*'
        # At or below the cap, above the refresh, another GPU, no VRR or no Reflex in the table: no note.
        Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 171 180 'VRR' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 181 180 'VRR' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 178 180 'VRR' 'AMD' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 178 180 'Fijo' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'marvel-win64-shipping.exe' 178 180 'Estrobo' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'desconocido.exe' 178 180 'VRR' 'NVIDIA' | Should -BeNullOrEmpty
        Get-JuicerReflexCapNote 'league of legends.exe' 178 180 'VRR' 'NVIDIA' | Should -BeNullOrEmpty
    }

    It 'el resultado de aplicar 178 FPS lleva la nota y el valor se aplica igualmente' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; Hz = 180; MaxHz = 180; Primary = $true; RefreshRates = @(60, 144, 180) }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        $r = Set-JuicerPacerFps 'Marvel-Win64-Shipping.exe' 178 $mon
        $r.Outcome | Should -Be 'Aplicado'
        $r.Title | Should -BeLike 'Frame pacer a 178 FPS*'
        $r.Message | Should -BeLike '*se queda en 171 FPS*'
        (Get-JuicerReflexCapNoteHere 'marvel-win64-shipping.exe' $mon) | Should -BeLike '*171 FPS*'
        # At the Reflex cap itself, or for a game not in the table, nothing to say.
        (Set-JuicerPacerFps 'Marvel-Win64-Shipping.exe' 171 $mon).Message | Should -Not -BeLike '*Reflex*'
        (Get-JuicerReflexCapNoteHere 'marvel-win64-shipping.exe' $mon) | Should -BeNullOrEmpty
        (Set-JuicerPacerFps 'otrojuego.exe' 178 $mon).Message | Should -Not -BeLike '*Reflex*'
        (Get-JuicerReflexCapNoteHere 'otrojuego.exe' $mon) | Should -BeNullOrEmpty
    }

    It 'sin NVIDIA el resultado no lleva la nota' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'AMD' }
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; Hz = 180; MaxHz = 180; Primary = $true; RefreshRates = @(60, 144, 180) }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        (Set-JuicerPacerFps 'Marvel-Win64-Shipping.exe' 178 $mon).Message | Should -Not -BeLike '*Reflex*'
    }
}

Describe 'Juegos repetidos en la galería' {
    BeforeEach {
        $script:M = New-NetMachine
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
        $script:RivDir = Join-Path ([IO.Path]::GetTempPath()) ('wj-dedup-' + [guid]::NewGuid().ToString('N'))
        $script:RivRoot = Join-Path $RivDir 'MarvelRivals'
        $script:RivBin = Join-Path $RivRoot 'MarvelGame\Marvel\Binaries\Win64'
        New-Item -ItemType Directory -Path $RivBin | Out-Null
        Set-Content -LiteralPath (Join-Path $RivRoot 'MarvelRivals_Launcher.exe') -Value 'x'
        Set-Content -LiteralPath (Join-Path $RivBin 'Marvel-Win64-Shipping.exe') -Value 'x'
    }
    AfterEach {
        Remove-Item -LiteralPath $RivDir -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath (Get-JuicerLibraryPath) -ErrorAction SilentlyContinue
    }

    It 'un lanzador nunca gana al *-Win64-Shipping.exe, y lo encuentra a cuatro niveles' {
        $files = @(@{ Path = 'MarvelRivals_Launcher.exe'; Size = 90MB }, @{ Path = 'MarvelGame\Marvel\Binaries\Win64\Marvel-Win64-Shipping.exe'; Size = 1MB })
        Select-JuicerGameExe $files 'Marvel Rivals' | Should -Be 'MarvelGame\Marvel\Binaries\Win64\Marvel-Win64-Shipping.exe'
        (Find-JuicerGameExe $RivRoot 'Marvel Rivals') | Should -BeLike '*Marvel-Win64-Shipping.exe'
    }

    It 'tres entradas solapadas (Steam, registro en la misma carpeta y en una subcarpeta) son un juego' {
        $root = $RivRoot; $bin = $RivBin
        $col = { @(
                (New-JuicerGame 'EA' 'marvelrivals' 'Marvel Rivals' $bin),
                (New-JuicerGame 'Steam' '2767030' 'Marvel Rivals' $root),
                (New-JuicerGame 'Riot' 'marvelrivals2' 'Marvel Rivals (NetEase)' $root)
            ) }.GetNewClosure()
        $g = @(Get-JuicerGames -Collectors @($col))
        $g.Count | Should -Be 1
        $g[0].Id | Should -Be 'steam:2767030'
        $g[0].ExeName | Should -Be 'marvel-win64-shipping.exe'
        # Same result with the collectors in another order, and a second run changes nothing.
        $rev = { @((New-JuicerGame 'Riot' 'marvelrivals2' 'Marvel Rivals (NetEase)' $root), (New-JuicerGame 'EA' 'marvelrivals' 'Marvel Rivals' $bin), (New-JuicerGame 'Steam' '2767030' 'Marvel Rivals' $root)) }.GetNewClosure()
        @(Get-JuicerGames -Collectors @($rev)).Id | Should -Be 'steam:2767030'
        @(Get-JuicerGames -Collectors @($col)).Count | Should -Be 1
    }

    It 'si sólo había una entrada de registro con ajustes, la elegida no se pierde y no sale como nueva' {
        $root = $RivRoot; $bin = $RivBin
        $only = { @(New-JuicerGame 'EA' 'marvelrivals' 'Marvel Rivals' $root) }.GetNewClosure()
        $other = Join-Path $RivRoot 'Otro.exe'
        Set-Content -LiteralPath $other -Value 'x'
        [void](Get-JuicerGames -Collectors @($only))
        Set-JuicerGameExe 'ea:marvelrivals' $other
        $both = { @((New-JuicerGame 'EA' 'marvelrivals' 'Marvel Rivals' $bin), (New-JuicerGame 'Steam' '2767030' 'Marvel Rivals' $root)) }.GetNewClosure()
        $g = @(Get-JuicerGames -Collectors @($both))
        $g.Count | Should -Be 1
        $g[0].Id | Should -Be 'steam:2767030'
        $g[0].ExeName | Should -Be 'otro.exe' -Because 'el .exe elegido bajo el id absorbido pasa al que queda'
        $g[0].New | Should -BeFalse
    }

    It 'juegos distintos de una misma tienda o con carpetas hermanas no se juntan' {
        $a = Join-Path $RivDir 'A'; $b = Join-Path $RivDir 'A2'
        foreach ($d in $a, $b) { New-Item -ItemType Directory -Path $d | Out-Null; Set-Content -LiteralPath (Join-Path $d 'g.exe') -Value 'x' }
        $col = { @((New-JuicerGame 'Steam' '1' 'Uno' $a), (New-JuicerGame 'EA' 'dos' 'Dos' $b)) }.GetNewClosure()
        @(Get-JuicerGames -Collectors @($col)).Count | Should -Be 2
    }
}

Describe 'Cierres de juegos en el registro de aplicaciones' {
    It 'lee cierres y cuelgues con su programa, su hora y su módulo' {
        Mock -ModuleName WinJuicer Get-JuicerEvents {
            param($Filter, $Max)
            $props = if ($Filter.Id -eq 1000) { @('Juego.exe', '1.0', 'x', 'd3d11.dll') } else { @('Juego.exe', '1.0') }
            , @([pscustomobject]@{ Properties = @($props | ForEach-Object { [pscustomobject]@{ Value = $_ } }); TimeCreated = [datetime]'2026-11-20T10:00:00' })
        }
        $r = & (Get-Module WinJuicer) { Read-WinAppIncidents ([datetime]'2026-10-01') }
        $r.Count | Should -Be 2
        $r[0].Exe | Should -Be 'juego.exe'
        $r[0].Kind | Should -Be 'Cierre'
        $r[0].Module | Should -Be 'd3d11.dll'
        $r[1].Kind | Should -Be 'Cuelgue'
    }

    It 'si hay más cierres de los que se pueden leer hasta esa fecha, no adivina: no se puede leer' {
        # One program crashing in a loop fills the newest events; a game's older crashes would
        # be cut off and «antes no le pasaba» would be a guess.
        Mock -ModuleName WinJuicer Get-JuicerEvents {
            param($Filter, $Max)
            $one = [pscustomobject]@{ Properties = @([pscustomobject]@{ Value = 'otro.exe' }); TimeCreated = Get-Date }
            , @(1..$Max | ForEach-Object { $one })
        }
        & (Get-Module WinJuicer) { Read-WinAppIncidents ([datetime]'2026-10-01') } | Should -BeNullOrEmpty
        Should -Invoke -ModuleName WinJuicer Get-JuicerEvents -ParameterFilter { $Max -eq 5000 }
    }
}

Describe 'Revisión: mantenimiento, importar y Epic' {
    BeforeEach {
        $script:M = New-NetMachine
        Remove-Item -LiteralPath (Get-JuicerUpkeepPath) -ErrorAction SilentlyContinue
    }

    It 'sin motor de FPS, el aviso no dice que se optimizaron juegos que esperan a la siguiente vez' {
        $M.Backend.State.FpsBackend = ''
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $null }
        Mock -ModuleName WinJuicer Get-JuicerGames { @((New-JuicerGame 'Steam' '1' 'Nuevo' 'C:\J\Nuevo' 'C:\J\Nuevo\nuevo.exe')) | ForEach-Object { $_.ExeName = 'nuevo.exe'; $_ } }
        $script:Toasts = New-Object System.Collections.ArrayList
        Mock -ModuleName WinJuicer Show-JuicerToast { param($Text) [void]$script:Toasts.Add($Text) }
        Save-JuicerUpkeepState @{ Seen = @(); Signature = '' }
        [void](Invoke-JuicerUpkeep)
        @($script:Toasts | Where-Object { $_ -like '*Juegos nuevos optimizados*' }).Count | Should -Be 0
        (Read-JuicerUpkeepState).Seen | Should -Not -Contain 'steam:1'
    }

    It '-Importar por línea de órdenes no quita una app que este equipo necesita' {
        Write-JuicerReg 'HKLM\SOFTWARE\Microsoft\WindowsSelfHost\Applicability' 'BranchName' 'String' 'Canary'
        # The hardware profile is cached across tests: this PC is an Insider one.
        Mock -ModuleName WinJuicer Get-JuicerHardwareProfile { @{ Cpu = @{}; GamePass = $false; Insider = $true; Gpus = @(); Modules = @() } }
        $M.Backend.State.Appx['Microsoft.WindowsFeedbackHub'] = @{ Installed = $true; Provisioned = $false }
        $file = Join-Path (Get-JuicerHome) 'otro-pc.json'
        Set-Content -LiteralPath $file -Value (ConvertTo-JuicerJson @{ Version = 1; Creado = '2026-11-01T10:00:00'; Tweaks = @(); Toggles = @{}; Dns = $null; Apps = @('Microsoft.WindowsFeedbackHub') }) -Encoding UTF8
        @(Start-Juicer -Importar $file -Si -SinPuntoDeRestauracion 6>$null)[-1] | Should -Be 0
        $M.Backend.State.Appx.ContainsKey('Microsoft.WindowsFeedbackHub') | Should -BeTrue
    }

    It 'si Epic declara un lanzador, se busca el .exe del juego' {
        $root = Join-Path ([IO.Path]::GetTempPath()) ('wjepic-' + [guid]::NewGuid().ToString('N'))
        $game = Join-Path $root 'Fortnite'
        New-Item -ItemType Directory -Path (Join-Path $game 'FortniteGame\Binaries\Win64') -Force | Out-Null
        foreach ($f in 'FortniteLauncher.exe', 'FortniteClient-Win64-Shipping.exe') { [IO.File]::WriteAllBytes((Join-Path $game "FortniteGame\Binaries\Win64\$f"), (New-Object byte[] 4096)) }
        $manifests = Join-Path $root 'Epic\EpicGamesLauncher\Data\Manifests'
        New-Item -ItemType Directory -Path $manifests -Force | Out-Null
        $savedPd = $env:ProgramData
        $env:ProgramData = $root
        Set-Content -LiteralPath (Join-Path $manifests 'f.item') -Value (@{ AppName = 'Fortnite'; DisplayName = 'Fortnite'; InstallLocation = $game; LaunchExecutable = 'FortniteGame/Binaries/Win64/FortniteLauncher.exe'; AppCategories = @('games') } | ConvertTo-Json) -Encoding UTF8
        try {
            $g = @(Get-JuicerEpicGames)
            $g.Count | Should -Be 1
            $g[0].Exe | Should -Be ''
        } finally {
            $env:ProgramData = $savedPd
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}
