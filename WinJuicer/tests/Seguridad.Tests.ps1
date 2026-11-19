# Frame pacer, safety and clarity: games with an anti-cheat stay out of RivaTuner, a pending change
# that fails is not lost, the Reflex note does not state what prudent mode does not set up, NVIDIA's
# profile store is copied before the first write (and restored on request), NVAPI failures are said in
# words and not remembered for ever, what holds a rate under what was asked, and what was put in a game.
# Every test works on the in-memory machine, the throwaway home of Initialize-JuicerTest and temp
# folders of its own.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest

    function New-SafeMonitor {
        param([int]$Hz = 180, [bool]$Vrr = $true, [int]$VrrMax = 0)
        $max = if ($VrrMax -gt 0) { $VrrMax } else { $Hz }
        @{
            Display = [pscustomobject]@{ Monitor = 'VG27AQ3A'; MonitorId = '\\?\DISPLAY#AUS27A3#5&1&0&UID1#{e6f07b5f}'; Hz = $Hz; MaxHz = $Hz; ExactHz = [double]$Hz; Primary = $true; RefreshRates = @(60, 144, $Hz) }
            Info = @{ Brand = 'ASUS'; Name = 'VG27AQ3A' }; Vrr = $(if ($Vrr) { @{ Min = 48; Max = $max; Kind = 'FreeSync'; Trusted = $true } } else { $null })
        }
    }

    function New-SafeDir {
        $d = Join-Path ([IO.Path]::GetTempPath()) ('wj-seg-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $d | Out-Null
        $d
    }

    function New-SafeGame {
        param([string]$Dir = '', [string]$Exe = 'testgame.exe')
        @{ Id = "steam:$Exe"; Name = 'Juego de prueba'; Launcher = 'steam'; ExeName = $Exe; Exe = $Exe; Dir = $Dir }
    }

    function Clear-SafeState {
        Remove-Item -LiteralPath (Get-JuicerPacerPath), (Get-JuicerJournalPath), (Get-JuicerMonitorModesPath) -ErrorAction SilentlyContinue
        $root = Join-Path (Get-JuicerHome) 'respaldo-nvidia'
        if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
    }

    $script:NoOthers = @{ RtssInstalled = $false; RtssRunning = $false; RtssGlobal = 0; RtssGames = @{}; NvGlobal = 0 }
}

Describe 'Antitrampas: qué se detecta' {
    BeforeEach {
        $script:M = New-FakeMachine
        $script:Dir = New-SafeDir
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 've las carpetas y los archivos de cada antitrampas' {
        $cases = @(
            @{ Make = 'EasyAntiCheat'; Dir = $true; Want = 'Easy Anti-Cheat' }
            @{ Make = 'BattlEye'; Dir = $true; Want = 'BattlEye' }
            @{ Make = 'AntiCheatExpert'; Dir = $true; Want = 'Anti-Cheat Expert (Tencent ACE)' }
            @{ Make = 'EAAntiCheat.GameServiceLauncher.exe'; Dir = $false; Want = 'EA Anti-Cheat (Javelin)' }
            @{ Make = 'mhyprot2.sys'; Dir = $false; Want = 'mhyprot (HoYoverse)' }
            @{ Make = 'NeacSafe64.sys'; Dir = $false; Want = 'NetEase Anti-Cheat' }
            @{ Make = 'ACE-BASE.sys'; Dir = $false; Want = 'Anti-Cheat Expert (Tencent ACE)' }
            @{ Make = 'atvi-randgrid_sy.sys'; Dir = $false; Want = 'Ricochet (Call of Duty)' }
            @{ Make = 'RobloxPlayerBeta.exe'; Dir = $false; Want = 'Hyperion (Roblox)' }
            @{ Make = 'faceitclient.dll'; Dir = $false; Want = 'FACEIT Anti-Cheat' }
        )
        foreach ($c in $cases) {
            $d = New-SafeDir
            try {
                if ($c.Dir) { New-Item -ItemType Directory -Path (Join-Path $d $c.Make) | Out-Null } else { [IO.File]::WriteAllText((Join-Path $d $c.Make), 'x') }
                Get-JuicerGameAntiCheat $d | Should -Be $c.Want -Because $c.Make
            } finally { Remove-Item -LiteralPath $d -Recurse -Force }
        }
    }

    It 'una carpeta limpia no tiene antitrampas' {
        [IO.File]::WriteAllText((Join-Path $script:Dir 'juego.exe'), 'x')
        Get-JuicerGameAntiCheat $script:Dir 'juego.exe' | Should -Be ''
        Get-JuicerGameAntiCheat '' '' | Should -Be ''
    }

    It 'Ricochet y Hyperion también por el nombre del .exe, aunque no haya carpeta' {
        Get-JuicerGameAntiCheat '' 'cod.exe' | Should -Be 'Ricochet (Call of Duty)'
        Get-JuicerGameAntiCheat '' 'cod24-cod.exe' | Should -Be 'Ricochet (Call of Duty)'
        Get-JuicerGameAntiCheat '' 'RobloxPlayerBeta.exe' | Should -Be 'Hyperion (Roblox)'
        Get-JuicerGameAntiCheat '' 'codex.exe' | Should -Be ''
    }

    It 'Vanguard sólo con su servicio y un juego de Riot' {
        Get-JuicerGameAntiCheat '' 'valorant-win64-shipping.exe' | Should -Be ''
        $M.Backend.State.Services['vgc'] = @{ Start = 'Manual'; Running = $true }
        Get-JuicerGameAntiCheat '' 'valorant-win64-shipping.exe' | Should -Be 'Riot Vanguard'
        Get-JuicerGameAntiCheat '' 'League of Legends.exe' | Should -Be 'Riot Vanguard'
        # Another game with Vanguard on the PC is not Vanguard's.
        Get-JuicerGameAntiCheat '' 'otro.exe' | Should -Be ''
        $riot = Join-Path (Join-Path $script:Dir 'Riot Games') 'Juego'
        New-Item -ItemType Directory -Path $riot | Out-Null
        Get-JuicerGameAntiCheat $riot 'nuevo.exe' | Should -Be 'Riot Vanguard'
    }

    It 'FACEIT sólo con su servicio y Counter-Strike' {
        Get-JuicerGameAntiCheat '' 'cs2.exe' | Should -Be ''
        $M.Backend.State.Services['FACEIT'] = @{ Start = 'Manual'; Running = $true }
        Get-JuicerGameAntiCheat '' 'cs2.exe' | Should -Be 'FACEIT Anti-Cheat'
        Get-JuicerGameAntiCheat '' 'otro.exe' | Should -Be ''
    }

    It 'la nota habla de RivaTuner sólo con RivaTuner' {
        Get-JuicerAntiCheatNote '' 'rtss' | Should -BeNullOrEmpty
        Get-JuicerAntiCheatNote 'BattlEye' 'rtss' | Should -BeLike '*BattlEye*RivaTuner se inyecta*límite de FPS del propio juego*'
        Get-JuicerAntiCheatNote 'BattlEye' 'nvidia' | Should -BeLike '*no se inyecta*'
    }
}

Describe 'Antitrampas: el frame pacer no usa RivaTuner con ellos' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $script:Dir = New-SafeDir
        New-Item -ItemType Directory -Path (Join-Path $script:Dir 'EasyAntiCheat') | Out-Null
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }
    AfterEach { Remove-Item -LiteralPath $script:Dir -Recurse -Force -ErrorAction SilentlyContinue }

    It 'sólo con RivaTuner de motor, Recomendado lo deja y dice por qué' {
        $M.Backend.State.FpsBackend = 'rtss'
        $r = @(Invoke-JuicerGameSetup @((New-SafeGame $Dir)) 'Recomendado' -GpuCount 1 -Monitor $Mon)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'NoAplica'
        $r[0].Message | Should -BeLike '*antitrampas (Easy Anti-Cheat)*RivaTuner se inyecta y podría dar problemas; usa el limitador del propio juego*'
        $M.Backend.State.FpsLimits.ContainsKey('testgame.exe') | Should -BeFalse
    }

    It 'con Force también, y lo mismo con un ritmo a mano' {
        $M.Backend.State.FpsBackend = 'rtss'
        $g = New-SafeGame $Dir
        @(Invoke-JuicerGameSetup @($g) 'Recomendado' -GpuCount 1 -Monitor $Mon -Force)[0].Outcome | Should -Be 'NoAplica'
        @(Invoke-JuicerGameSetup @($g) 'Fps' -Fps 120 -GpuCount 1 -Monitor $Mon)[0].Outcome | Should -Be 'NoAplica'
        $M.Backend.State.FpsLimits.Count | Should -Be 0
    }

    It 'con el driver de NVIDIA sí: no se inyecta nada' {
        $M.Backend.State.FpsBackend = 'nvidia'
        $r = @(Invoke-JuicerGameSetup @((New-SafeGame $Dir)) 'Recomendado' -GpuCount 1 -Monitor $Mon)
        @($r | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -BeGreaterThan 0
        $M.Backend.State.FpsLimits['testgame.exe'] | Should -Be 171
    }

    It 'un juego sin antitrampas sigue con RivaTuner' {
        $M.Backend.State.FpsBackend = 'rtss'
        $clean = New-SafeDir
        try {
            $r = @(Invoke-JuicerGameSetup @((New-SafeGame $clean)) 'Recomendado' -GpuCount 1 -Monitor $Mon)
            @($r | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -Be 1
            $M.Backend.State.FpsLimits['testgame.exe'] | Should -Be 171
        } finally { Remove-Item -LiteralPath $clean -Recurse -Force }
    }

    It 'la prioridad y Quitar no se ven afectados' {
        $M.Backend.State.FpsBackend = 'rtss'
        $g = New-SafeGame $Dir
        @(Invoke-JuicerGameSetup @($g) 'Quitar' -GpuCount 1) | Should -BeNullOrEmpty
    }

    It 'desde la consola, la información del juego trae la nota' {
        $M.Backend.State.FpsBackend = 'rtss'
        $out = (Write-JuicerGamePacerInfo (New-SafeGame $Dir) $Mon 6>&1 | Out-String)
        $out | Should -BeLike '*Easy Anti-Cheat*RivaTuner se inyecta*'
    }
}

Describe 'Cambios en espera que fallan' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $M.Backend.State.FpsBackend = 'nvidia'
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }

    It 'un fallo lo vuelve a poner con un intento más y lo dice' {
        [void]$M.Backend.State.Running.Add('g.exe')
        [void](Add-JuicerPacerPending 'g.exe' 'Set' 0)
        $M.Backend.State.Running.Clear()
        Mock -ModuleName WinJuicer Add-JuicerFpsLimit { throw 'el driver no contesta' }
        $r = @(Invoke-JuicerPacerPending $Mon)
        $r.Count | Should -Be 1
        $r[0].Outcome | Should -Be 'Pendiente'
        $r[0].Message | Should -BeLike '*intento 1 de 3*se reintentará*el driver no contesta*'
        $p = (Read-JuicerPacer).Pending['g.exe']
        $p.Op | Should -Be 'Set'
        $p.Attempts | Should -Be 1
    }

    It 'tras tres intentos se rinde, lo registra y lo enseña como error' {
        [void]$M.Backend.State.Running.Add('g.exe')
        [void](Add-JuicerPacerPending 'g.exe' 'Set' 0)
        $M.Backend.State.Running.Clear()
        Mock -ModuleName WinJuicer Add-JuicerFpsLimit { throw 'el driver no contesta' }
        $one = @(Invoke-JuicerPacerPending $Mon)
        $two = @(Invoke-JuicerPacerPending $Mon)
        (Read-JuicerPacer).Pending['g.exe'].Attempts | Should -Be 2
        $three = @(Invoke-JuicerPacerPending $Mon)
        $three[0].Outcome | Should -Be 'Error'
        $three[0].Message | Should -BeLike '*tras 3 intentos*deja de intentarlo*el driver no contesta*'
        (Read-JuicerPacer).Pending.ContainsKey('g.exe') | Should -BeFalse
        @(Invoke-JuicerPacerPending $Mon) | Should -BeNullOrEmpty
        Get-Content -LiteralPath (Join-Path (Get-JuicerHome) 'registro.log') -ErrorAction SilentlyContinue | Out-String | Should -BeLike '*se deja de intentar tras 3 intentos*'
    }

    It 'un cambio nuevo para el mismo juego manda sobre el que falló' {
        [void]$M.Backend.State.Running.Add('g.exe')
        [void](Add-JuicerPacerPending 'g.exe' 'Set' 0)
        $M.Backend.State.Running.Clear()
        Mock -ModuleName WinJuicer Add-JuicerFpsLimit {
            # While it fails, the person asks for something else for the same game.
            $s = Read-JuicerPacer
            $s.Pending['g.exe'] = @{ Op = 'Remove'; Fps = 0; Use = ''; Reset = $false; Since = '2026-01-01T00:00:00' }
            Save-JuicerPacer $s
            throw 'falla'
        }
        [void](Invoke-JuicerPacerPending $Mon)
        $p = (Read-JuicerPacer).Pending['g.exe']
        $p.Op | Should -Be 'Remove'
        $p.Attempts | Should -BeNullOrEmpty
    }

    It 'sin fallos se aplica y se quita de la lista, como siempre' {
        [void]$M.Backend.State.Running.Add('g.exe')
        [void](Add-JuicerPacerPending 'g.exe' 'Set' 0)
        $M.Backend.State.Running.Clear()
        $r = @(Invoke-JuicerPacerPending $Mon)
        @($r | Where-Object { $_.Outcome -eq 'Aplicado' }).Count | Should -BeGreaterThan 0
        (Read-JuicerPacer).Pending.ContainsKey('g.exe') | Should -BeFalse
        $M.Backend.State.FpsLimits['g.exe'] | Should -Be 171
    }
}

Describe 'Nota de Reflex y modo prudente' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $M.Backend.State.FpsBackend = 'nvidia'
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }

    It 'con V-Sync forzada la nota es la de siempre' {
        $n = Get-JuicerReflexCapNote 'cs2.exe' 178 180 'VRR' 'NVIDIA' $null
        $n | Should -BeLike '*Con NVIDIA Reflex activado en el juego y G-SYNC, el propio juego se queda en 171 FPS*'
        $n | Should -Not -BeLike '*si además tienes la V-Sync*'
    }

    It 'sin ella (modo prudente) lo condiciona a que tengas la V-Sync activada' {
        $n = Get-JuicerReflexCapNote 'cs2.exe' 178 180 'VRR' 'NVIDIA' $null $false
        $n | Should -BeLike '*si además tienes la V-Sync activada (en modo prudente Win Juicer no la fuerza)*171 FPS*'
        $n | Should -BeLike '*Sin V-Sync, ese tope no se aplica*'
    }

    It 'al poner el ritmo, el mensaje depende del modo prudente' {
        (Add-JuicerFpsLimit 'cs2.exe' 178 $Mon).Message | Should -BeLike '*Con NVIDIA Reflex activado en el juego y G-SYNC, el propio juego se queda en 171*'
        [void](Undo-JuicerTweak 'fps:cs2.exe')
        [void](Set-JuicerPacerMinimal 'cs2.exe' $true $Mon)
        $m = (Add-JuicerFpsLimit 'cs2.exe' 178 $Mon).Message
        $m | Should -BeLike '*si además tienes la V-Sync activada*'
    }

    It 'la nota de la página del juego (ritmo a mano) sigue el mismo modo' {
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { $script:Mon }
        $script:Mon = $Mon
        [void](Set-JuicerPacerFps 'cs2.exe' 178 $Mon)
        (Get-JuicerReflexCapNoteHere 'cs2.exe' $Mon) | Should -Not -BeLike '*si además tienes la V-Sync*'
        [void](Set-JuicerPacerMinimal 'cs2.exe' $true $Mon)
        (Get-JuicerReflexCapNoteHere 'cs2.exe' $Mon) | Should -BeLike '*si además tienes la V-Sync activada*'
    }
}

Describe 'Copia de los perfiles de NVIDIA' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $M.Backend.State.FpsBackend = 'nvidia'
        $M.Backend.State.NvDrsFiles['nvdrsdb0.bin'] = 'AAA'
        $M.Backend.State.NvDrsFiles['nvdrsdb1.bin'] = 'BBB'
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }

    It 'antes del primer cambio copia los dos archivos, y una sola vez' {
        Get-JuicerNvBackups | Should -BeNullOrEmpty
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        $b = @(Get-JuicerNvBackups)
        $b.Count | Should -Be 1
        $b[0].Files | Should -Contain 'nvdrsdb0.bin'
        [IO.File]::ReadAllText((Join-Path $b[0].Path 'nvdrsdb1.bin')) | Should -Be 'BBB'
        (Read-JuicerPacer).NvBackup.Date | Should -Not -BeNullOrEmpty
        # The driver's files change; the copy of the first time stays as it was.
        $M.Backend.State.NvDrsFiles['nvdrsdb0.bin'] = 'CAMBIADO'
        [void](Add-JuicerFpsLimit 'b.exe' 120 $Mon)
        @($M.Backend.State.Calls | Where-Object { $_ -like 'nv-backup*' }).Count | Should -Be 1
        @(Get-JuicerNvBackups).Count | Should -Be 1
        [IO.File]::ReadAllText((Join-Path $b[0].Path 'nvdrsdb0.bin')) | Should -Be 'AAA'
    }

    It 'sin archivos del driver todavía no deja marca ni carpeta, y lo intenta la próxima vez' {
        $M.Backend.State.NvDrsFiles.Clear()
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        Get-JuicerNvBackups | Should -BeNullOrEmpty
        (Read-JuicerPacer).NvBackup.Count | Should -Be 0
        $M.Backend.State.NvDrsFiles['nvdrsdb0.bin'] = 'AAA'
        [void](Add-JuicerFpsLimit 'b.exe' 120 $Mon)
        @(Get-JuicerNvBackups).Count | Should -Be 1
    }

    It 'si la copia falla, el cambio se hace igual' {
        Mock -ModuleName WinJuicer Backup-JuicerNvProfilesOnce { }
        $r = Add-JuicerFpsLimit 'a.exe' 120 $Mon
        $r.Outcome | Should -Be 'Aplicado'
        $M.Backend.State.FpsLimits['a.exe'] | Should -Be 120
    }

    It 'con RivaTuner no se toca el almacén de NVIDIA, así que no hay copia' {
        $M.Backend.State.FpsBackend = 'rtss'
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        Get-JuicerNvBackups | Should -BeNullOrEmpty
    }

    It 'restaurar devuelve los archivos de la copia y lo dice' {
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        $M.Backend.State.NvDrsFiles['nvdrsdb0.bin'] = 'ESTROPEADO'
        $r = Restore-JuicerNvProfiles
        $r.Ok | Should -BeTrue
        $r.Message | Should -BeLike '*Reinicia*'
        $M.Backend.State.NvDrsFiles['nvdrsdb0.bin'] | Should -Be 'AAA'
    }

    It 'sin copia, restaurar lo dice y no toca nada' {
        $r = Restore-JuicerNvProfiles
        $r.Ok | Should -BeFalse
        $r.Message | Should -BeLike '*No hay ninguna copia*'
        @($M.Backend.State.Calls | Where-Object { $_ -like 'nv-restore*' }).Count | Should -Be 0
    }

    It 'el aviso dice que se sustituye todo y que hay que reiniciar' {
        $w = Get-JuicerNvRestoreWarning
        $w | Should -BeLike '*TODOS los ajustes*'
        $w | Should -BeLike '*reiniciar*'
    }

    It '-RestaurarPerfilesNvidia pregunta, y con -Si restaura' {
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        $M.Backend.State.NvDrsFiles['nvdrsdb1.bin'] = 'ESTROPEADO'
        $out = @(Start-Juicer -RestaurarPerfilesNvidia -Si 6>&1)
        $out[-1] | Should -Be 0
        # The console wraps its lines: compare the words, not the line breaks.
        (($out | Out-String) -replace '\s+', ' ') | Should -BeLike '*TODOS los ajustes*'
        $M.Backend.State.NvDrsFiles['nvdrsdb1.bin'] | Should -Be 'BBB'
    }

    It '-RestaurarPerfilesNvidia sin copia termina con 1' {
        @(Start-Juicer -RestaurarPerfilesNvidia -Si 6>$null)[-1] | Should -Be 1
    }

    It '-Simular lo rechaza antes de tocar nada' {
        [void](Add-JuicerFpsLimit 'a.exe' 120 $Mon)
        $M.Backend.State.NvDrsFiles['nvdrsdb1.bin'] = 'ESTROPEADO'
        $out = @(Start-Juicer -RestaurarPerfilesNvidia -Simular -Si 6>&1)
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -BeLike '*-Simular no vale con -RestaurarPerfilesNvidia*'
        $M.Backend.State.NvDrsFiles['nvdrsdb1.bin'] | Should -Be 'ESTROPEADO'
    }
}

Describe 'NVAPI: mensajes y reintentos' {
    It 'traduce los códigos conocidos y conserva el número' {
        $cases = @(
            @{ Code = -4; Like = '*no responde*reinicia*' }
            @{ Code = -6; Like = '*no hay una gráfica NVIDIA*' }
            @{ Code = -1; Like = '*error sin más detalle*' }
            @{ Code = -137; Like = '*administrador*' }
            @{ Code = -160; Like = '*ese ajuste no existe*' }
            @{ Code = -163; Like = '*perfil del juego no existe*' }
            @{ Code = -167; Like = '*ya está en otro perfil*' }
        )
        foreach ($c in $cases) {
            $m = Convert-JuicerNvApiError "NVAPI SetSetting: código $($c.Code)"
            $m | Should -BeLike $c.Like -Because "$($c.Code)"
            $m | Should -BeLike "*NVAPI SetSetting, código $($c.Code))*" -Because "$($c.Code)"
        }
    }

    It 'lo que no conoce lo deja como estaba' {
        Convert-JuicerNvApiError 'NVAPI Initialize: código -9999' | Should -Be 'NVAPI Initialize: código -9999'
        Convert-JuicerNvApiError 'otra cosa' | Should -Be 'otra cosa'
        Convert-JuicerNvApiError '' | Should -Be ''
    }

    It 'el fallo capturado sale en palabras y deja el código en el registro' {
        $err = InModuleScope WinJuicer { try { throw 'NVAPI SetSetting: código -137' } catch { Get-WinNvApiFailure $_ } }
        $err | Should -BeLike '*administrador*'
        Get-Content -LiteralPath (Join-Path (Get-JuicerHome) 'registro.log') -ErrorAction SilentlyContinue | Out-String | Should -BeLike '*NVAPI: NVAPI SetSetting: código -137*'
        $other = InModuleScope WinJuicer { try { throw 'algo raro' } catch { Get-WinNvApiFailure $_ } }
        $other | Should -Be 'algo raro'
    }

    It 'un fallo se recuerda poco tiempo' {
        $now = Get-Date
        Test-JuicerFailureCached $now.AddSeconds(-10) $now | Should -BeTrue
        Test-JuicerFailureCached $now.AddSeconds(-31) $now | Should -BeFalse
        Test-JuicerFailureCached $null $now | Should -BeFalse
    }

    It 'Test-WinNvApi vuelve a mirar pasados 30 s, no antes' {
        InModuleScope WinJuicer { $script:NvApiOk = $null; $script:NvApiFailedAt = $null }
        Mock -ModuleName WinJuicer Initialize-JuicerNvApi { throw 'sin driver' }
        try {
            InModuleScope WinJuicer { Test-WinNvApi } | Should -BeFalse
            InModuleScope WinJuicer { Test-WinNvApi } | Should -BeFalse
            Should -Invoke -ModuleName WinJuicer Initialize-JuicerNvApi -Times 1 -Exactly
            InModuleScope WinJuicer { $script:NvApiFailedAt = (Get-Date).AddSeconds(-31) }
            InModuleScope WinJuicer { Test-WinNvApi } | Should -BeFalse
            Should -Invoke -ModuleName WinJuicer Initialize-JuicerNvApi -Times 2 -Exactly
        } finally {
            InModuleScope WinJuicer { $script:NvApiOk = $null; $script:NvApiFailedAt = $null }
        }
    }

    It 'el motor elegido sin NVAPI no se queda para siempre' {
        Mock -ModuleName WinJuicer Get-WinFpsEngines { @('nvidia', 'rtss') }
        try {
            InModuleScope WinJuicer { $script:NvApiOk = $false; $script:FpsBackendName = 'rtss'; $script:FpsBackendAt = Get-Date }
            InModuleScope WinJuicer { Get-WinFpsBackend } | Should -Be 'rtss'
            InModuleScope WinJuicer { $script:FpsBackendAt = (Get-Date).AddSeconds(-31) }
            InModuleScope WinJuicer { Get-WinFpsBackend } | Should -Be 'nvidia'
        } finally {
            InModuleScope WinJuicer { $script:NvApiOk = $null; $script:NvApiFailedAt = $null; $script:FpsBackendName = $null; $script:FpsBackendAt = $null }
        }
    }
}

Describe 'Pides y efectivo' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $M.Backend.State.FpsBackend = 'nvidia'
    }

    It 'con G-SYNC y Reflex, 178 se queda en 171 y dice quién' {
        $c = Get-JuicerEffectiveCap 'cs2.exe' -Requested 178 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal $null
        $c.Requested | Should -Be 178
        $c.Effective | Should -Be 171
        $c.Limiter.Source | Should -Be 'Reflex con G-SYNC'
        Format-JuicerEffectiveCap $c | Should -Be 'Pides 178 · efectivo ~171 (limita: Reflex con G-SYNC)'
    }

    It 'en modo prudente Reflex no cuenta' {
        [void](Set-JuicerPacerMinimal 'cs2.exe' $true $Mon)
        $c = Get-JuicerEffectiveCap 'cs2.exe' -Requested 178 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal $null
        $c.Effective | Should -Be 178
        $c.Limiter | Should -BeNullOrEmpty
    }

    It 'sin saber la marca de la gráfica no se adivina Reflex' {
        $c = Get-JuicerEffectiveCap 'cs2.exe' -Requested 178 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null
        $c.Effective | Should -Be 178
    }

    It 'un juego sin Reflex tampoco' {
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 178 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal $null
        $c.Effective | Should -Be 178
        Format-JuicerEffectiveCap $c | Should -BeLike 'Pides 178 · efectivo 178*nada que Win Juicer vea*'
    }

    It 'los archivos de Reflex en la carpeta también cuentan' {
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 178 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech @{ Reflex = $true } -Unreal $null
        $c.Effective | Should -Be 171
    }

    It 'el límite del propio juego (Unreal) y el perfil de NVIDIA' {
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 150 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal @{ Limit = 120.0 }
        $c.Effective | Should -Be 120
        $c.Limiter.Source | Should -Be 'El propio juego'
        $M.Backend.State.NvPredefined[('otro.exe|{0}' -f [uint32]0x10835002)] = 100
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 150 -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal @{ Limit = 120.0 }
        $c.Effective | Should -Be 100
        Format-JuicerEffectiveCap $c | Should -BeLike 'Pides 150 · efectivo ~100 (limita: NVIDIA (perfil del juego))'
    }

    It 'RivaTuner (el de su perfil o el global) sólo si está abierto, y NVIDIA global sólo si el motor no es el driver' {
        $rt = @{ RtssInstalled = $true; RtssRunning = $true; RtssGlobal = 100.0; RtssGames = @{ 'otro.exe' = 90.0 }; NvGlobal = 80 }
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 150 -Monitor $Mon -State $rt -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null
        $c.Effective | Should -Be 90
        $c.Limiter.Source | Should -Be 'RivaTuner (perfil del juego)'
        # Without a profile of its own, the global one; NVIDIA's global is not for the driver engine.
        $c = Get-JuicerEffectiveCap 'nuevo.exe' -Requested 150 -Monitor $Mon -State $rt -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null
        $c.Effective | Should -Be 100
        $c.Limiter.Source | Should -Be 'RivaTuner (global)'
        $off = $rt.Clone(); $off.RtssRunning = $false
        (Get-JuicerEffectiveCap 'nuevo.exe' -Requested 150 -Monitor $Mon -State $off -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null).Effective | Should -Be 150
        # With RivaTuner as the engine, NVIDIA's panel limit applies.
        $M.Backend.State.FpsBackend = 'rtss'
        $c = Get-JuicerEffectiveCap 'nuevo.exe' -Requested 150 -Monitor $Mon -State $off -Backend 'rtss' -GpuVendor '' -Tech $null -Unreal $null
        $c.Effective | Should -Be 80
        $c.Limiter.Source | Should -Be 'NVIDIA (global)'
    }

    It 'el tope del VRR avisa pero no recorta' {
        $mon = New-SafeMonitor -Hz 165 -VrrMax 144
        $c = Get-JuicerEffectiveCap 'otro.exe' -Requested 160 -Monitor $mon -State $NoOthers -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null
        $c.Effective | Should -Be 160
        @($c.By | Where-Object { $_.Source -eq 'Rango VRR de la pantalla' }).Count | Should -Be 1
        Format-JuicerEffectiveCap $c | Should -BeLike '*ojo: por encima de 144 Hz la frecuencia variable se apaga'
    }

    It 'sin pedir nada, usa lo que Win Juicer pondría, y sin ritmo posible no inventa' {
        $c = Get-JuicerEffectiveCap 'nuevo.exe' -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null
        $c.Requested | Should -Be 171
        Get-JuicerEffectiveCap 'nuevo.exe' -Monitor $null -State $NoOthers -Backend 'nvidia' -GpuVendor '' -Tech $null -Unreal $null | Should -BeNullOrEmpty
        Format-JuicerEffectiveCap $null | Should -Be ''
    }

    It 'lo que ya está puesto cuenta como lo pedido' {
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
        [void](Set-JuicerPacerFps 'cs2.exe' 178 $Mon)
        $c = Get-JuicerEffectiveCap 'cs2.exe' -Monitor $Mon -State $NoOthers -Backend 'nvidia' -GpuVendor 'NVIDIA' -Tech $null -Unreal $null
        $c.Requested | Should -Be 178
        $c.Effective | Should -Be 171
    }
}

Describe 'Qué se ha puesto' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $script:Mon = New-SafeMonitor
        $M.Backend.State.FpsBackend = 'nvidia'
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }

    It 'un juego sin nada puesto no dice nada' {
        Format-JuicerPacerApplied 'cs2.exe' | Should -Be ''
        @(Get-JuicerPacerAppliedLines 'cs2.exe') | Should -BeNullOrEmpty
    }

    It 'lista el límite, los fotogramas pre-renderizados, la V-Sync y cómo deshacerlo' {
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $t = Format-JuicerPacerApplied 'cs2.exe'
        $t | Should -BeLike 'Qué se ha puesto en cs2.exe:*'
        $t | Should -BeLike '*Límite de 171 FPS (5?85 ms por fotograma) con el driver de NVIDIA, sin inyectar nada en el juego*'
        $t | Should -BeLike '*Fotogramas pre-renderizados: 1*'
        $t | Should -BeLike '*V-Sync forzada*'
        $t | Should -BeLike '*«Quitar lo de Win Juicer»*'
        $t | Should -Not -BeLike '*«Q»*'
        (Format-JuicerPacerApplied 'cs2.exe' -Console) | Should -BeLike '*«Q»*'
    }

    It 'con RivaTuner dice RivaTuner' {
        $M.Backend.State.FpsBackend = 'rtss'
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        Format-JuicerPacerApplied 'cs2.exe' | Should -BeLike '*con RivaTuner, a través de su enganche*'
    }

    It 'lo que NVIDIA ya fija para el juego se deja y se dice' {
        $M.Backend.State.NvPredefined[('cs2.exe|{0}' -f [uint32]0x00A879CF)] = [uint32]0x60925292
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $t = Format-JuicerPacerApplied 'cs2.exe'
        $t | Should -BeLike '*La V-Sync: no se toca, porque NVIDIA ya lo fija así para este juego*'
        $t | Should -Not -BeLike '*V-Sync forzada*'
        $t | Should -BeLike '*Fotogramas pre-renderizados: 1*'
    }

    It 'en modo prudente, sólo el límite' {
        [void](Set-JuicerPacerMinimal 'cs2.exe' $true $Mon)
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        $t = Format-JuicerPacerApplied 'cs2.exe'
        $t | Should -BeLike '*Modo prudente: sólo el límite*'
        $t | Should -Not -BeLike '*pre-renderizados: 1*'
    }

    It 'un cambio en espera se dice' {
        [void](Add-JuicerFpsLimit 'cs2.exe' 0 $Mon)
        [void]$M.Backend.State.Running.Add('cs2.exe')
        [void](Add-JuicerFpsLimit 'cs2.exe' 120 $Mon)
        Format-JuicerPacerApplied 'cs2.exe' | Should -BeLike '*Hay un cambio en espera*en cuanto cierres cs2.exe*'
    }

    It 'con -LimitarFps, la consola lo cuenta después' {
        $out = @(Start-Juicer -LimitarFps 'cs2.exe' -Fps 120 -Si 6>&1)
        $out[-1] | Should -Be 0
        ($out | Out-String) | Should -BeLike '*Qué se ha puesto en cs2.exe*Límite de 120 FPS*'
    }
}

Describe 'Modo prudente desde la línea de órdenes' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-SafeState
        $M.Backend.State.FpsBackend = 'nvidia'
        Mock -ModuleName WinJuicer Get-JuicerMainGpuVendor { 'NVIDIA' }
    }

    It 'Activar y Desactivar por juego, y separados por comas' {
        @(Start-Juicer -ModoPrudente Activar -Juego 'a.exe,b.exe' -Si 6>$null)[-1] | Should -Be 0
        Test-JuicerPacerMinimal 'a.exe' | Should -BeTrue
        Test-JuicerPacerMinimal 'b.exe' | Should -BeTrue
        @(Start-Juicer -ModoPrudente Desactivar -Juego 'a.exe' -Si 6>$null)[-1] | Should -Be 0
        Test-JuicerPacerMinimal 'a.exe' | Should -BeFalse
        Test-JuicerPacerMinimal 'b.exe' | Should -BeTrue
    }

    It 'a un juego que ya tiene el frame pacer le quita la V-Sync forzada' {
        [void](Add-JuicerFpsLimit 'a.exe' 0 (New-SafeMonitor))
        $M.Backend.State.NvSettings.ContainsKey(('a.exe|{0}' -f [uint32]0x00A879CF)) | Should -BeTrue
        Mock -ModuleName WinJuicer Get-JuicerPrimaryMonitor { New-SafeMonitor }
        @(Start-Juicer -ModoPrudente Activar -Juego 'a.exe' -Si 6>$null)[-1] | Should -Be 0
        $M.Backend.State.NvSettings.ContainsKey(('a.exe|{0}' -f [uint32]0x00A879CF)) | Should -BeFalse
    }

    It 'sin -Juego no hace nada y termina con 2' {
        $out = @(Start-Juicer -ModoPrudente Activar -Si 6>&1)
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -BeLike '*-ModoPrudente va con -Juego*'
    }

    It '-Simular lo rechaza' {
        $out = @(Start-Juicer -ModoPrudente Activar -Juego 'a.exe' -Simular -Si 6>&1)
        $out[-1] | Should -Be 2
        ($out | Out-String) | Should -BeLike '*-Simular no vale con -ModoPrudente*'
        Test-JuicerPacerMinimal 'a.exe' | Should -BeFalse
    }
}
