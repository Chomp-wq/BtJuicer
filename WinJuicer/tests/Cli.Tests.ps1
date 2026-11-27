# The command line: what -Simular promises, and that WinJuicer.ps1, Start-Juicer and the
# README agree on the parameters. Every test works on the in-memory machine and the
# throwaway home of Initialize-JuicerTest.

BeforeAll {
    . (Join-Path $PSScriptRoot 'TestHelpers.ps1')
    Initialize-JuicerTest
    $script:Root = Split-Path -Parent $PSScriptRoot

    function Clear-CliJournal {
        foreach ($n in 'diario.json', 'diario.1.json', 'diario.dañado.json') { Remove-Item -LiteralPath (Join-Path (Get-JuicerHome) $n) -ErrorAction SilentlyContinue }
    }

    # The journal's text, or '' when there is none: a Simular must leave it as it was.
    function Get-CliJournalText {
        $p = Get-JuicerJournalPath
        if (Test-Path -LiteralPath $p) { [IO.File]::ReadAllText($p) } else { '' }
    }

    # The parameter names of a script's param block, from its syntax tree (nothing runs).
    function Get-CliScriptParams {
        param([string]$Path)
        $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$null, [ref]$null)
        @($ast.ParamBlock.Parameters | ForEach-Object { $_.Name.VariablePath.UserPath })
    }
}

Describe '-Simular no cambia nada' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-CliJournal
    }
    AfterEach { Clear-CliJournal }

    It '-DeshacerTodo -Simular dice qué se deshará y no deshace nada' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        $snap = Get-MachineSnapshot $M
        $journal = Get-CliJournalText
        $journal | Should -Not -BeNullOrEmpty
        $out = @(Start-Juicer -DeshacerTodo -Simular -Si 6>&1)
        $out[-1] | Should -Be 0
        ($out | Out-String) | Should -BeLike '*Se deshar*'
        Get-MachineSnapshot $M | Should -Be $snap
        Get-CliJournalText | Should -Be $journal
        Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.modo' | Should -Not -BeNullOrEmpty
    }

    It '-Deshacer X -Simular lo mismo, y un ajuste sin cambios se dice' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        $snap = Get-MachineSnapshot $M
        $journal = Get-CliJournalText
        $out = @(Start-Juicer -Deshacer 'juegos.modo', 'no.guardado' -Simular -Si 6>&1)
        $out[-1] | Should -Be 0
        $text = $out | Out-String
        $text | Should -BeLike '*Se deshar*'
        $text | Should -BeLike '*no.guardado: no hay cambios de Win Juicer guardados*'
        Get-MachineSnapshot $M | Should -Be $snap
        Get-CliJournalText | Should -Be $journal
    }

    It '-DeshacerTodo -Simular sin diario no inventa nada' {
        $out = @(Start-Juicer -DeshacerTodo -Simular -Si 6>&1)
        $out[-1] | Should -Be 0
        ($out | Out-String) | Should -BeLike '*No hay cambios de Win Juicer que deshacer*'
    }

    It 'sin -Simular, -DeshacerTodo sí deshace (la prueba de que la de arriba prueba algo)' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        @(Start-Juicer -DeshacerTodo -Si 6>$null)[-1] | Should -Be 0
        Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.modo' | Should -BeNullOrEmpty
    }

    It '-Importar -Simular enseña lo que haría sin hacerlo' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        $file = Join-Path (Get-JuicerHome) ('cli-export-' + [guid]::NewGuid().ToString('N') + '.json')
        try {
            [void](Export-JuicerConfig $file)
            [void](Undo-JuicerTweak 'juegos.modo')
            $snap = Get-MachineSnapshot $M
            $journal = Get-CliJournalText
            @(Start-Juicer -Importar $file -Simular -Si 6>$null)[-1] | Should -Be 0
            Get-MachineSnapshot $M | Should -Be $snap
            Get-CliJournalText | Should -Be $journal
        } finally { Remove-Item -LiteralPath $file -ErrorAction SilentlyContinue }
    }

    It 'las acciones que no se pueden enseñar sin hacerlas se niegan con 2 antes de tocar nada' {
        [void](Invoke-JuicerTweak (Find-JuicerTweak 'juegos.modo'))
        $snap = Get-MachineSnapshot $M
        $journal = Get-CliJournalText
        $report = Join-Path (Get-JuicerHome) ('cli-informe-' + [guid]::NewGuid().ToString('N') + '.txt')
        $cases = @(
            @{ Name = 'LimitarFps'; Args = @{ LimitarFps = 'cs2.exe' } }
            @{ Name = 'OptimizarJuegos'; Args = @{ OptimizarJuegos = $true } }
            @{ Name = 'Mantener'; Args = @{ Mantener = $true } }
            @{ Name = 'MantenerJuegos'; Args = @{ MantenerJuegos = 'Activar' } }
            @{ Name = 'ModoMonitor'; Args = @{ ModoMonitor = 'VRR' } }
            @{ Name = 'MotorPacer'; Args = @{ MotorPacer = 'rtss' } }
            @{ Name = 'CalibrarJuego'; Args = @{ CalibrarJuego = 'cs2.exe' } }
            @{ Name = 'PantallaOled'; Args = @{ PantallaOled = 'Si' } }
            @{ Name = 'ProteccionAdultos'; Args = @{ ProteccionAdultos = 'Activar' } }
            @{ Name = 'BloquearWeb'; Args = @{ BloquearWeb = 'ejemplo.com' } }
            @{ Name = 'Instalar'; Args = @{ Instalar = 'Valve.Steam' } }
            @{ Name = 'RestaurarDiario'; Args = @{ RestaurarDiario = $true } }
            @{ Name = 'Exportar'; Args = @{ Exportar = $report } }
            @{ Name = 'Informe'; Args = @{ Informe = $report } }
            @{ Name = 'NuevaMedida'; Args = @{ NuevaMedida = $true } }
            @{ Name = 'MedirJuego'; Args = @{ MedirJuego = 30 } }
            @{ Name = 'ApuntarAjuste'; Args = @{ ApuntarAjuste = $true; AjusteCpu = 'CO -25' } }
            @{ Name = 'OlvidarAjuste'; Args = @{ OlvidarAjuste = $true } }
            @{ Name = 'ModoPrudente'; Args = @{ ModoPrudente = 'Activar'; Juego = 'cs2.exe' } }
            @{ Name = 'RestaurarPerfilesNvidia'; Args = @{ RestaurarPerfilesNvidia = $true } }
        )
        foreach ($c in $cases) {
            $a = $c.Args
            $out = @(Start-Juicer @a -Simular -Si 6>&1)
            $out[-1] | Should -Be 2 -Because $c.Name
            ($out | Out-String) | Should -BeLike "*-Simular no vale con -$($c.Name): no puede enseñarse sin hacerlo*" -Because $c.Name
        }
        Get-MachineSnapshot $M | Should -Be $snap
        Get-CliJournalText | Should -Be $journal
        Test-Path -LiteralPath $report | Should -BeFalse
    }

    It 'con -Simular siguen valiendo las acciones que enseñan o simulan' {
        @(Start-Juicer -Lista -Simular 6>$null)[-1] | Should -Be 0
        @(Start-Juicer -Revisar -Simular 6>$null)[-1] | Should -Be 0
        @(Start-Juicer -Aplicar 'juegos.modo' -Simular -Si 6>$null)[-1] | Should -Be 0
        Get-JuicerJournalEntry (Read-JuicerJournal) 'juegos.modo' | Should -BeNullOrEmpty
    }
}

Describe 'Comillas de los argumentos al volver a abrir como administrador' {
    BeforeAll {
        # The function lives in WinJuicer.ps1 (the relaunch runs before the module loads): take
        # it from the syntax tree and define it here, so it is tested as the pure function it is.
        $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:Root 'WinJuicer.ps1'), [ref]$null, [ref]$null)
        $fn = $ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'ConvertTo-JuicerCommandLineArgument' }, $true)
        . ([scriptblock]::Create($fn.Extent.Text))

        # What CommandLineToArgvW (and so powershell.exe -File) makes of one quoted argument.
        function Read-CliQuoted {
            param([string]$Text)
            $sb = New-Object Text.StringBuilder
            $i = 1   # past the opening quote
            while ($i -lt $Text.Length) {
                $c = $Text[$i]
                if ($c -eq '\') {
                    $n = 0
                    while ($i -lt $Text.Length -and $Text[$i] -eq '\') { $n++; $i++ }
                    if ($i -lt $Text.Length -and $Text[$i] -eq '"') {
                        [void]$sb.Append('\', [int][math]::Floor($n / 2))
                        if ($n % 2 -eq 1) { [void]$sb.Append('"'); $i++ }
                    } else { [void]$sb.Append('\', $n) }
                } elseif ($c -eq '"') { return $sb.ToString() }
                else { [void]$sb.Append($c); $i++ }
            }
            throw 'Comilla sin cerrar'
        }
    }

    It 'un valor normal sólo se entrecomilla' {
        ConvertTo-JuicerCommandLineArgument 'C:\Archivos de programa\x.json' | Should -Be '"C:\Archivos de programa\x.json"'
        ConvertTo-JuicerCommandLineArgument '' | Should -Be '""'
    }

    It 'una barra final se duplica para no comerse la comilla de cierre' {
        ConvertTo-JuicerCommandLineArgument 'C:\Mi carpeta\' | Should -Be '"C:\Mi carpeta\\"'
        ConvertTo-JuicerCommandLineArgument 'C:\a\\' | Should -Be '"C:\a\\\\"'
    }

    It 'una comilla dentro se escapa, con sus barras anteriores duplicadas' {
        ConvertTo-JuicerCommandLineArgument 'dice "hola"' | Should -Be '"dice \"hola\""'
        ConvertTo-JuicerCommandLineArgument 'a\"b' | Should -Be '"a\\\"b"'
    }

    It 'lo que lee Windows es el valor de origen, sea el que sea' {
        foreach ($v in 'plano', 'C:\dir\', 'C:\dir\\', 'a"b', 'a\"b', 'a\\"b', '"', '\"', 'termina en comilla"', 'con espacios y \ sueltas\x') {
            Read-CliQuoted (ConvertTo-JuicerCommandLineArgument $v) | Should -Be $v -Because $v
        }
    }
}

Describe 'Parámetros: WinJuicer.ps1, Start-Juicer y el README no se separan' {
    BeforeAll {
        $script:ScriptParams = @(Get-CliScriptParams (Join-Path $script:Root 'WinJuicer.ps1'))
        $script:Readme = [IO.File]::ReadAllText((Join-Path $script:Root 'README.md'))
        $script:ScriptText = [IO.File]::ReadAllText((Join-Path $script:Root 'WinJuicer.ps1'))
        $i = $script:Readme.IndexOf('### Desde la línea de órdenes')
        $j = $script:Readme.IndexOf('## Recomendado para este equipo')
        $script:Cli = $script:Readme.Substring($i, $j - $i)
        $script:StartParams = @((Get-Command Start-Juicer).Parameters.Keys)
    }

    It 'WinJuicer.ps1 tiene parámetros' {
        $script:ScriptParams.Count | Should -BeGreaterThan 30
    }

    It 'cada parámetro de WinJuicer.ps1 lo tiene Start-Juicer (y al revés)' {
        $common = [System.Management.Automation.PSCmdlet]::CommonParameters + [System.Management.Automation.PSCmdlet]::OptionalCommonParameters
        $startOnly = @($script:StartParams | Where-Object { $_ -notin $common -and $_ -notin $script:ScriptParams })
        $startOnly | Should -BeNullOrEmpty
        $missing = @($script:ScriptParams | Where-Object { $_ -notin $script:StartParams })
        $missing | Should -BeNullOrEmpty
    }

    It 'cada parámetro de WinJuicer.ps1 tiene su .PARAMETER' {
        $help = @([regex]::Matches($script:ScriptText, '(?m)^\.PARAMETER (\w+)') | ForEach-Object { $_.Groups[1].Value })
        $missing = @($script:ScriptParams | Where-Object { $_ -notin $help })
        $missing | Should -BeNullOrEmpty
        $extra = @($help | Where-Object { $_ -notin $script:ScriptParams })
        $extra | Should -BeNullOrEmpty
    }

    It 'cada parámetro de WinJuicer.ps1 sale en la lista de la línea de órdenes del README' {
        $missing = @($script:ScriptParams | Where-Object { $script:Cli -notmatch ('(?<![\w-])-' + $_ + '(?!\w)') })
        $missing | Should -BeNullOrEmpty
    }

    It 'el README dice que los códigos de salida valen desde una consola de administrador' {
        $script:Cli | Should -BeLike '*desde una consola de administrador*'
    }
}

Describe 'Línea de órdenes: correcciones de la revisión' {
    BeforeEach {
        $script:M = New-FakeMachine
        Clear-CliJournal
    }

    It 'los colores de nivel de la consola siguen siendo de consola (la ventana tiene los suyos)' {
        & (Get-Module WinJuicer) { $script:LevelColors[1] } | Should -Be 'Green'
        & (Get-Module WinJuicer) { $script:GuiLevelColors[1] } | Should -Be '#4CC38A'
        $t = Find-JuicerTweak 'juegos.modo'
        $Error.Clear()
        Write-JuicerTweakLine 1 $t (Get-JuicerTweakState $t) $null 6>$null
        @($Error | Where-Object { "$_" -like '*ForegroundColor*' }).Count | Should -Be 0
    }

    It 'una ruta relativa de -Exportar es la de la carpeta de PowerShell, no la del proceso' {
        $dir = Join-Path ([IO.Path]::GetTempPath()) ('wjcli-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $dir | Out-Null
        Push-Location $dir
        try {
            @(Start-Juicer -Exportar 'config.json' 6>$null)[-1] | Should -Be 0
            Test-Path -LiteralPath (Join-Path $dir 'config.json') | Should -BeTrue
            @(Start-Juicer -Importar 'config.json' -Simular -Si 6>$null)[-1] | Should -Be 0
        } finally {
            Pop-Location
            Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    It 'un modificador solo no abre la ventana como si nada: dice con qué va' {
        Mock -ModuleName WinJuicer Show-JuicerGui { throw 'no debería abrirse' }
        $out = @(Start-Juicer -Prioridad Latencia -Juego 'cs2.exe' 6>&1)
        $out[-1] | Should -Be 2
        ($out -join ' ') | Should -BeLike '*no hace nada por sí solo*'
        @(Start-Juicer -Simular 6>$null)[-1] | Should -Be 2
    }

    It 'cambios junto a una acción que vuelve antes no se pierden en silencio' {
        @(Start-Juicer -Perfil Seguro -OptimizarJuegos -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -Equipo -Aplicar 'juegos.modo' -Si 6>$null)[-1] | Should -Be 2
        (Read-JuicerJournal).Count | Should -Be 0
    }

    It '-Fps y -MedirJuego se comprueban antes de cualquier acción' {
        @(Start-Juicer -OptimizarJuegos -Fps 14 -Si 6>$null)[-1] | Should -Be 2
        @(Start-Juicer -CalibrarJuego 'cs2.exe' -MedirJuego 3 -Si 6>$null)[-1] | Should -Be 2
    }

    It 'deshacer el ritmo de un juego quita también lo que esperaba a que se cerrara' {
        $M.Backend.State.FpsBackend = 'nvidia'
        [void](Add-JuicerFpsLimit 'cs2.exe' 141)
        [void](Add-JuicerPacerPending 'cs2.exe' 'Set' 144)
        (Undo-JuicerTweak 'fps:cs2.exe').Outcome | Should -Be 'Deshecho'
        @(Get-JuicerPacerPending) | Should -Not -Contain 'cs2.exe'
    }
}

Describe 'Ventana: la cola de tareas' {
    It 'lo de fondo que arranca al acabar otra tarea va detrás de lo que espera' {
        & (Get-Module WinJuicer) {
            $saved = $script:Gui
            try {
                $script:Gui = @{ Queue = (New-Object System.Collections.ArrayList); Task = $null }
                [void]$script:Gui.Queue.Add(@{ Status = 'Juego'; Work = 'GamePage'; Arguments = @{ Exe = 'cs2.exe' }; Quiet = $false })
                Start-JuicerGuiTask 'Portadas' 'Covers' @{ Batch = 2 } { } -Quiet
                $script:Gui.Queue.Count | Should -Be 2
                $script:Gui.Queue[0].Work | Should -Be 'GamePage'
                $script:Gui.Queue[1].Work | Should -Be 'Covers'
                $script:Gui.Task | Should -BeNullOrEmpty
            } finally {
                $script:Gui = $saved
            }
        }
    }
}
