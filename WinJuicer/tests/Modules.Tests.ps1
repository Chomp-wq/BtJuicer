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

    It 'reparte categorías en dos columnas parecidas' {
        $cols = Split-JuicerColumns @(@{ Items = 1..10 }, @{ Items = 1..3 }, @{ Items = 1..4 }, @{ Items = 1..2 })
        $cols.Count | Should -Be 2
        @($cols[0]).Count + @($cols[1]).Count | Should -Be 4
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
