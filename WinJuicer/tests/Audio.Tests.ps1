BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Src = & (Get-Module WinJuicer) { $script:AudioCSharp }

    # The text of one interface in the C# source, to count its methods.
    function Get-InterfaceBody {
        param([string]$Name)
        $m = [regex]::Match($Src, "interface $Name \{(?<b>.*?)\n    \}", 'Singleline')
        $m.Groups['b'].Value
    }
}

Describe 'Audio: lo que dice la salida predeterminada' {
    It 'convierte los períodos a milisegundos con la frecuencia de la mezcla' {
        $i = New-FakeAudioInfo
        $i.DefaultMs | Should -Be 10
        $i.MinMs | Should -Be 2.67
        $i.CurrentMs | Should -Be 10
        $i.LowLatency | Should -BeTrue
        (Format-JuicerAudioMs 2.67) | Should -Be '2,7'
        (Format-JuicerAudioMs 10) | Should -Be '10'
    }

    It 'sin períodos, lo de baja latencia es desconocido y no inventa milisegundos' {
        $i = New-FakeAudioInfo @{ DefaultFrames = 0; MinFrames = 0; MaxFrames = 0; CurrentFrames = 0 }
        $i.LowLatency | Should -BeNullOrEmpty
        $i.DefaultMs | Should -Be 0
        $i.MinMs | Should -Be 0
    }

    It 'mínimo igual al período por defecto: no admite baja latencia' {
        (New-FakeAudioInfo @{ MinFrames = 480 }).LowLatency | Should -BeFalse
    }

    It 'las mejoras: 1 son desactivadas, 0 activadas, y sin dato es desconocido' {
        (New-FakeAudioInfo @{ DisableSysFx = 1 }).EnhancementsOff | Should -BeTrue
        (New-FakeAudioInfo @{ DisableSysFx = 0 }).EnhancementsOff | Should -BeFalse
        (New-FakeAudioInfo @{ DisableSysFx = -1 }).EnhancementsOff | Should -BeNullOrEmpty
        $raw = New-FakeAudioRaw
        $raw.Remove('DisableSysFx')
        (ConvertTo-JuicerAudioInfo $raw).EnhancementsOff | Should -BeNullOrEmpty
    }

    It 'sin dispositivo no hay información' {
        ConvertTo-JuicerAudioInfo $null | Should -BeNullOrEmpty
    }

    It 'Bluetooth: por el bus del adaptador, o por el nombre de Windows; cable, USB y HDMI no' {
        foreach ($c in @(
                @{ E = 'BTHENUM'; A = ''; N = 'Auriculares (WH-1000XM4)' }
                @{ E = 'BTHLEDevice'; A = ''; N = 'Auriculares' }
                @{ E = 'MMDEVAPI'; A = '{2}.\\?\bthenum#{0000110b-0000-1000-8000-00805f9b34fb}_vid&0001'; N = 'Auriculares' }
                @{ E = ''; A = ''; N = 'Auriculares (Galaxy Buds Hands-Free)' })) {
            (Test-JuicerBluetoothEndpoint $c.E $c.A $c.N) | Should -BeTrue -Because "$($c.E) $($c.A) $($c.N)"
        }
        foreach ($c in @(
                @{ E = 'HDAUDIO'; A = '{1}.HDAUDIO\FUNC_01&VEN_10EC'; N = 'Altavoces (Realtek(R) Audio)' }
                @{ E = 'USB'; A = ''; N = 'Auriculares (HyperX Cloud II)' }
                @{ E = 'HDAUDIO'; A = ''; N = 'LG ULTRAGEAR (NVIDIA High Definition Audio)' })) {
            (Test-JuicerBluetoothEndpoint $c.E $c.A $c.N) | Should -BeFalse -Because "$($c.E) $($c.A) $($c.N)"
        }
    }
}

Describe 'Audio: el diagnóstico' {
    It 'sin información no dice nada' {
        @(Get-JuicerAudioFindings $null).Count | Should -Be 0
    }

    It 'Bluetooth: aviso de 100 a 300 ms, y no habla del período del motor' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ Enumerator = 'BTHENUM' }))
        $bt = @($f | Where-Object { $_.Title -like '*Bluetooth*' })
        $bt.Count | Should -Be 1
        $bt[0].Severity | Should -Be 'Medio'
        $bt[0].Detail | Should -Match '100 y 300 ms'
        $bt[0].Detail | Should -Match '2,4 GHz'
        @($f | Where-Object { $_.Title -like '*ms ahora*' -or $_.Title -like '*baja latencia*' }).Count | Should -Be 0
    }

    It 'mejoras activadas: sugiere desactivarlas, con la ruta exacta de Configuración' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ DisableSysFx = 0 }))
        $e = @($f | Where-Object { $_.Title -like '*mejoras de audio*' })
        $e.Count | Should -Be 1
        $e[0].Severity | Should -Be 'Bajo'
        $e[0].Detail | Should -Match 'Configuración > Sistema > Sonido > tu dispositivo de salida > Mejoras de audio'
    }

    It 'con las mejoras desactivadas, o sin dato, no avisa de ellas' {
        @(Get-JuicerAudioFindings (New-FakeAudioInfo)) | Where-Object { $_.Title -like '*mejoras*' } | Should -BeNullOrEmpty
        @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ DisableSysFx = -1 })) | Where-Object { $_.Title -like '*mejoras*' } | Should -BeNullOrEmpty
    }

    It '44,1 kHz: sugerencia informativa; 48 kHz: nada' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ SampleRate = 44100; DefaultFrames = 441; MinFrames = 128; MaxFrames = 441; CurrentFrames = 441 }))
        $r = @($f | Where-Object { $_.Title -like '*no a 48000 Hz*' })
        $r.Count | Should -Be 1
        $r[0].Severity | Should -Be 'Info'
        $r[0].Detail | Should -Match 'Formato'
        @(Get-JuicerAudioFindings (New-FakeAudioInfo)) | Where-Object { $_.Title -like '*no a 48000*' } | Should -BeNullOrEmpty
    }

    It 'mínimo menor que el período por defecto: «10 ms ahora; tu driver permite 2,7 ms», con el ajuste a mano' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo))
        $l = @($f | Where-Object { $_.Title -like 'Audio: *' })
        $l.Count | Should -Be 1
        $l[0].Title | Should -Be 'Audio: 10 ms ahora; tu driver permite 2,7 ms'
        $l[0].Fix | Should -Be 'audio.latencia'
        $l[0].Severity | Should -Be 'Info'
        $l[0].Detail | Should -Match 'audio\.latencia'
    }

    It 'mínimo igual al período por defecto: dice que el driver no lo admite, sin ofrecer el ajuste' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ MinFrames = 480 }))
        $l = @($f | Where-Object { $_.Title -like '*no admite baja latencia*' })
        $l.Count | Should -Be 1
        $l[0].Title | Should -Match 'mínimo = por defecto'
        $l[0].Fix | Should -BeNullOrEmpty
        @($f | Where-Object { $_.Fix -eq 'audio.latencia' }).Count | Should -Be 0
    }

    It 'si el motor ya va a un período corto, lo dice como bueno' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ CurrentFrames = 128 }))
        $l = @($f | Where-Object { $_.Title -like 'El motor de audio ya va a*' })
        $l.Count | Should -Be 1
        $l[0].Title | Should -Be 'El motor de audio ya va a 2,7 ms (Windows usa 10 ms por defecto)'
        $l[0].Severity | Should -Be 'Ok'
        @($f | Where-Object { $_.Fix -eq 'audio.latencia' }).Count | Should -Be 0
    }

    It 'lo desconocido no aparece: sin períodos, ni suposiciones' {
        $f = @(Get-JuicerAudioFindings (New-FakeAudioInfo @{ DefaultFrames = 0; MinFrames = 0; MaxFrames = 0; CurrentFrames = 0; DisableSysFx = -1; SampleRate = 0; Bits = 0 }))
        $f.Count | Should -Be 1
        $f[0].Title | Should -BeLike 'Salida de audio predeterminada: Altavoces*'
    }

    It 'la sección de audio del diagnóstico lee la salida del backend' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo @{ DisableSysFx = 0 }
        $f = @(Get-JuicerAudioAudit)
        @($f | Where-Object { $_.Area -ne 'Audio' }).Count | Should -Be 0
        @($f | Where-Object { $_.Title -like '*mejoras de audio*' }).Count | Should -Be 1
        $m.Backend.State.Audio = $null
        @(Get-JuicerAudioAudit).Count | Should -Be 0
    }
}

Describe 'Audio: «Listo para jugar»' {
    It 'sin información no añade líneas' {
        @(Get-JuicerReadyStatus @{ Audio = $null }).Count | Should -Be 0
    }

    It 'una salida cableada, bien configurada: marcas verdes y la nota de baja latencia, neutra' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo) })
        ($r | ForEach-Object { $_.Key }) | Should -Be @('audio-bt', 'audio-mejoras', 'audio-frecuencia', 'audio-latencia')
        @($r | Where-Object { -not $_.Ok }).Count | Should -Be 0
        $l = $r | Where-Object { $_.Key -eq 'audio-latencia' }
        $l.Title | Should -Be 'Audio: 10 ms ahora; tu driver permite 2,7 ms'
        $l.Info | Should -BeTrue
        $l.Reason | Should -Match 'audio\.latencia'
    }

    It 'Bluetooth y mejoras activadas: dos ⚠, sin línea de latencia del motor' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo @{ Enumerator = 'BTHENUM'; DisableSysFx = 0 }) })
        @($r | Where-Object { -not $_.Ok }).Count | Should -Be 2
        ($r | Where-Object { $_.Key -eq 'audio-bt' }).Title | Should -Be 'El audio sale por Bluetooth'
        ($r | Where-Object { $_.Key -eq 'audio-bt' }).Reason | Should -Match '100 y 300 ms'
        ($r | Where-Object { $_.Key -eq 'audio-mejoras' }).Reason | Should -Match 'Mejoras de audio'
        @($r | Where-Object { $_.Key -eq 'audio-latencia' }).Count | Should -Be 0
    }

    It '44,1 kHz es información, no algo «por mirar»' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo @{ SampleRate = 44100; DefaultFrames = 441; MaxFrames = 441; CurrentFrames = 441 }) })
        $f = $r | Where-Object { $_.Key -eq 'audio-frecuencia' }
        $f.Ok | Should -BeTrue
        $f.Info | Should -BeTrue
        $f.Title | Should -Match '44100 Hz'
    }

    It 'sin baja latencia posible, lo dice como información' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo @{ MinFrames = 480 }) })
        $l = $r | Where-Object { $_.Key -eq 'audio-latencia' }
        $l.Title | Should -Match 'no admite baja latencia'
        $l.Info | Should -BeTrue
    }

    It 'con el modo en marcha, el motor a período corto es una marca verde' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo @{ CurrentFrames = 128 }) })
        $l = $r | Where-Object { $_.Key -eq 'audio-latencia' }
        $l.Ok | Should -BeTrue
        $l.Info | Should -BeFalse
        $l.Title | Should -Be 'Audio de baja latencia en marcha: 2,7 ms (por defecto 10 ms)'
    }

    It 'lo desconocido (mejoras sin dato, sin períodos) se omite' {
        $r = @(Get-JuicerReadyStatus @{ Audio = (New-FakeAudioInfo @{ DisableSysFx = -1; DefaultFrames = 0; MinFrames = 0; MaxFrames = 0; CurrentFrames = 0 }) })
        ($r | ForEach-Object { $_.Key }) | Should -Be @('audio-bt', 'audio-frecuencia')
    }
}

Describe 'Audio de baja latencia (ajuste)' {
    BeforeEach {
        Remove-Item -LiteralPath (Get-JuicerJournalPath) -ErrorAction SilentlyContinue
    }

    It 'está a la carta, en la categoría Audio, y en la lista de ajustes' {
        $t = Find-JuicerTweak 'audio.latencia'
        $t | Should -Not -BeNullOrEmpty
        $t.Level | Should -Be 0
        $t.Category | Should -Be 'Audio'
        (Get-JuicerProfile 3 | Where-Object { $_.Id -eq 'audio.latencia' }) | Should -BeNullOrEmpty
    }

    It 'sin dispositivo de audio: no aplica, con el motivo' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = $null
        $s = Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -Match 'salida de audio'
        (Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia')).Outcome | Should -Be 'NoAplica'
        $m.Backend.State.AudioHelper.Installed | Should -BeFalse
    }

    It 'el driver no admite períodos más cortos: no aplica, diciendo cuál es el mínimo' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo @{ MinFrames = 480 }
        $s = Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -Match 'no admite baja latencia'
        $s.Reason | Should -Match '10 ms'
    }

    It 'si Windows no informa de los períodos, no aplica: no puede saber si ganaría algo' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo @{ DefaultFrames = 0; MinFrames = 0; MaxFrames = 0; CurrentFrames = 0 }
        $s = Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')
        $s.State | Should -Be 'NoAplica'
        $s.Reason | Should -Match 'no ha dicho'
    }

    It 'con un driver que lo admite, está pendiente' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        (Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')).State | Should -Be 'Pendiente'
    }

    It 'simular no toca nada' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        $r = Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia') -Simulate
        $r.Outcome | Should -Be 'Simulado'
        $r.Changes[0] | Should -Match 'audio de baja latencia'
        $m.Backend.State.AudioHelper.Installed | Should -BeFalse
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'aplicar crea la tarea y arranca el flujo, lo anota en el diario, y deshacer lo quita todo' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        $before = Get-MachineSnapshot $m
        $r = Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia')
        $r.Outcome | Should -Be 'Aplicado'
        $m.Backend.State.AudioHelper.Installed | Should -BeTrue
        $m.Backend.State.AudioHelper.Running | Should -BeTrue
        @($m.Backend.State.Calls | Where-Object { $_ -eq 'audio-helper install' }).Count | Should -Be 1
        (Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')).State | Should -Be 'Aplicado'
        $j = Read-JuicerJournal
        $j.Count | Should -Be 1
        $j[0].Id | Should -Be 'audio.latencia'
        $j[0].Actions[0].Type | Should -Be 'Custom'
        $j[0].Actions[0].CustomKey | Should -Be 'audiolatencia'
        $j[0].Actions[0].State.Installed | Should -BeFalse

        (Undo-JuicerTweak 'audio.latencia').Outcome | Should -Be 'Deshecho'
        $m.Backend.State.AudioHelper.Installed | Should -BeFalse
        $m.Backend.State.AudioHelper.Running | Should -BeFalse
        @($m.Backend.State.Calls | Where-Object { $_ -eq 'audio-helper remove' }).Count | Should -Be 1
        Get-MachineSnapshot $m | Should -Be $before
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It '«Deshacer todo» también lo quita' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia'))
        [void](Undo-JuicerAll)
        $m.Backend.State.AudioHelper.Installed | Should -BeFalse
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It 'una vez puesto no se salta, aunque la salida pase a ser otra que no lo admite' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia'))
        $m.Backend.State.Audio = New-FakeAudioInfo @{ Enumerator = 'BTHENUM'; MinFrames = 480 }
        (Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')).State | Should -Be 'Aplicado'
        (Undo-JuicerTweak 'audio.latencia').Outcome | Should -Be 'Deshecho'
        $m.Backend.State.AudioHelper.Installed | Should -BeFalse
    }

    It 'si Windows borra la tarea, vuelve a estar pendiente (lo que Windows deshace)' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'audio.latencia'))
        $m.Backend.State.AudioHelper.Installed = $false
        (Get-JuicerTweakState (Find-JuicerTweak 'audio.latencia')).State | Should -Be 'Pendiente'
        @(Get-JuicerDrift | Where-Object { $_.Id -eq 'audio.latencia' }).Count | Should -Be 1
    }

    It 'si ya estaba puesta antes de que Win Juicer la anotara, deshacer no la quita' {
        $m = New-FakeMachine
        $m.Backend.State.Audio = New-FakeAudioInfo
        $m.Backend.State.AudioHelper.Installed = $true
        $t = Find-JuicerTweak 'audio.latencia'
        $c = Save-JuicerActionState $t.Actions[0] $t.Id
        $c.State.Installed | Should -BeTrue
        Restore-JuicerActionState $c
        $m.Backend.State.AudioHelper.Installed | Should -BeTrue
    }

    It 'el consejero no lo recomienda con Bluetooth y lo deja opcional con un driver bueno' {
        $m = New-FakeMachine
        $hw = @{ Cpu = @{ Threads = 16; Name = 'x' }; RamBytes = 16GB; Gpus = @(); Laptop = $false }
        $m.Backend.State.Audio = New-FakeAudioInfo @{ Enumerator = 'BTHENUM' }
        (Get-JuicerAdviceRule 'audio.latencia' $hw).Verdict | Should -Be 'NoRecomendado'
        $m.Backend.State.Audio = New-FakeAudioInfo
        (Get-JuicerAdviceRule 'audio.latencia' $hw).Verdict | Should -Be 'Opcional'
    }

    It 'los mitos de audio están en «lo que no hacemos»' {
        $titles = @(Get-JuicerMyths | ForEach-Object { $_.Title })
        @($titles | Where-Object { $_ -like '*audiodg*' }).Count | Should -Be 1
        @($titles | Where-Object { $_ -like '*HPET*' }).Count | Should -BeGreaterThan 1
    }
}

Describe 'Audio: el script del ayudante y la parte nativa' {
    It 'el script de la tarea se analiza sin errores, es un solo ejemplar y no toma el dispositivo en exclusiva' {
        $text = Get-JuicerAudioHelperScript
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
        $text | Should -Match 'Local\\WinJuicerAudioBajaLatencia'
        $text | Should -Match '\[WinJuicer\.AudioHold\]::Run'
        $text | Should -Match 'BelowNormal'
        $text | Should -Not -Match 'AUDCLNT_SHAREMODE_EXCLUSIVE'
    }

    It 'el C# sólo usa lo que entiende el compilador de Windows PowerShell 5.1 (C# 5)' {
        # The constructs that came after C# 5.
        $Src | Should -Not -Match '\?\.|\$"|=>|nameof\(|out var |\?\['
    }

    It 'cada interfaz COM lista todos sus métodos, en el orden de la tabla virtual' {
        # IAudioClient (12) + IAudioClient2 (3) + IAudioClient3 (3).
        ([regex]::Matches((Get-InterfaceBody 'IAudioClient3'), '\[PreserveSig\]')).Count | Should -Be 18
        ([regex]::Matches((Get-InterfaceBody 'IMMDeviceEnumerator'), '\[PreserveSig\]')).Count | Should -Be 5
        ([regex]::Matches((Get-InterfaceBody 'IMMDevice'), '\[PreserveSig\]')).Count | Should -Be 4
        ([regex]::Matches((Get-InterfaceBody 'IPropertyStore'), '\[PreserveSig\]')).Count | Should -Be 5
        ([regex]::Matches((Get-InterfaceBody 'IAudioRenderClient'), '\[PreserveSig\]')).Count | Should -Be 2
        $names = [regex]::Matches((Get-InterfaceBody 'IAudioClient3'), '\] int (\w+)\(') | ForEach-Object { $_.Groups[1].Value }
        $names | Should -Be @(
            'Initialize', 'GetBufferSize', 'GetStreamLatency', 'GetCurrentPadding', 'IsFormatSupported', 'GetMixFormat', 'GetDevicePeriod',
            'Start', 'Stop', 'Reset', 'SetEventHandle', 'GetService',
            'IsOffloadCapable', 'SetClientProperties', 'GetBufferSizeLimits',
            'GetSharedModeEnginePeriod', 'GetCurrentSharedModeEnginePeriod', 'InitializeSharedAudioStream')
        $names = [regex]::Matches((Get-InterfaceBody 'IMMDeviceEnumerator'), '\] int (\w+)\(') | ForEach-Object { $_.Groups[1].Value }
        $names | Should -Be @('EnumAudioEndpoints', 'GetDefaultAudioEndpoint', 'GetDevice', 'RegisterEndpointNotificationCallback', 'UnregisterEndpointNotificationCallback')
        $names = [regex]::Matches((Get-InterfaceBody 'IMMDevice'), '\] int (\w+)\(') | ForEach-Object { $_.Groups[1].Value }
        $names | Should -Be @('Activate', 'OpenPropertyStore', 'GetId', 'GetState')
    }

    It 'los GUID son los del SDK de Windows' {
        foreach ($g in 'A95664D2-9614-4F35-A746-DE8DB63617E6', 'BCDE0395-E52F-467C-8E3D-C4579291692E', '7ED4EE07-8E67-4CD4-8C1A-2B7A5987AD42',
            'F294ACFC-3146-4483-A7BF-ADDCA7C260E2', '886D8EEB-8CF2-4446-8D02-CDBA1DBDCF99', 'D666063F-1587-4E43-81F1-B948E807363F') {
            $Src | Should -Match ([regex]::Escape($g)) -Because $g
        }
        # The properties it reads: friendly name, enumerator, form factor, «Disable_SysFx».
        $Src | Should -Match 'A45C254E-DF1C-4EFD-8020-67D146A850E0'
        $Src | Should -Match '1DA5D803-D492-4EDD-8C23-E0C0FFEE7F0E'
    }

    It 'sin Windows, la lectura del equipo no hace nada' {
        if (Test-JuicerWindows) { Set-ItResult -Skipped -Because 'sólo sin Windows'; return }
        & (Get-Module WinJuicer) { Get-WinAudioInfo } | Should -BeNullOrEmpty
        (& (Get-Module WinJuicer) { Get-WinAudioHelperState }).Installed | Should -BeFalse
    }
}
