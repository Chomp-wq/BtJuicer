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
}

Describe 'Limitador de FPS' {
    BeforeEach {
        $script:M = New-NetMachine
        $M.Backend.State.FpsBackend = 'nvidia'
        Remove-Item -LiteralPath (Get-JuicerMonitorModesPath) -ErrorAction SilentlyContinue
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

    It 'el limitador sigue al modo del monitor y recalcula al cambiarlo' {
        $mon = @{ Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; Hz = 180; MaxHz = 180; Primary = $true; RefreshRates = @(60, 144, 180) }; Info = @{}; Vrr = @{ Min = 48; Max = 180; Kind = 'FreeSync' } }
        (Add-JuicerFpsLimit 'cs2.exe' 0 $mon).Title | Should -BeLike 'Límite de 171 FPS*'
        [void](Set-JuicerMonitorMode $mon 'Estrobo')
        $r = @(Update-JuicerFpsLimits $mon)
        $r[0].Outcome | Should -Be 'Aplicado'
        $r[0].Title | Should -BeLike 'Límite de 180 FPS (5?56 ms): cs2.exe'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 180
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        # The journal still holds what there was before the first limit.
        Undo-JuicerTweak 'fps:cs2.exe' | Out-Null
        $M.Backend.State.FpsLimits.ContainsKey('cs2.exe') | Should -BeFalse
        $M.Backend.State.NvSettings.Count | Should -Be 0

        [void](Set-JuicerMonitorMode $mon 'Fijo')
        Add-JuicerFpsLimit 'cs2.exe' 0 $mon | Out-Null
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 180
        $M.Backend.State.NvSettings.ContainsKey('cs2.exe|11041231') | Should -BeFalse
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
        $r.Title | Should -BeLike 'Límite de 157 FPS (6?37 ms): cs2.exe'
        $M.Backend.State.FpsLimits['cs2.exe'] | Should -Be 157
        $M.Backend.State.NvSettings['cs2.exe|8102046'] | Should -Be 1
        $M.Backend.State.NvSettings['cs2.exe|11041231'] | Should -Be 0x47814940
        $M.Backend.State.NvSettings['cs2.exe|274197361'] | Should -Be 1
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
        $M.Backend.State.NvSettings.ContainsKey('game.exe|11041231') | Should -BeFalse
        Undo-JuicerTweak 'fps:game.exe' | Out-Null
        $M.Backend.State.FpsLimits['game.exe'] | Should -Be 100
    }

    It 'con RivaTuner sólo pone el límite, y sin limitador lo dice' {
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
        # Without a monitor to read (as here), the mode still decides this limit.
        @(Start-Juicer -LimitarFps 'c.exe' -Fps 144 -ModoMonitor 'Estrobo' -Si 6>$null)[-1] | Should -Be 0
        $M.Backend.State.NvSettings['c.exe|11041231'] | Should -Be 0x47814940
        # Alone it needs a monitor to save it for: there is one on a real Windows.
        @(Start-Juicer -ModoMonitor 'Estrobo' -Si 6>$null)[-1] | Should -Be $(if (Get-JuicerPrimaryMonitor) { 0 } else { 1 })
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
        Select-JuicerGameExe @(@{ Path = 'unins000.exe'; Size = 1MB }, @{ Path = 'vc_redist.x64.exe'; Size = 20MB }) 'Juego' | Should -BeNullOrEmpty
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
        [void](Invoke-JuicerUpkeep -Quiet)
        $M.Backend.State.FpsLimits['nuevo.exe'] | Should -Be 224
        (Read-JuicerUpkeepState).Signature | Should -BeLike '240|*'
    }

    It 'desde la línea de órdenes' {
        @(Start-Juicer -Mantener -Si 6>$null)[-1] | Should -Be 0
    }
}
