BeforeDiscovery {
    $root = Split-Path -Parent $PSScriptRoot
    $script:Scripts = @(Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1', '*.psd1' |
            ForEach-Object { @{ Path = $_.FullName; Name = $_.FullName.Substring($root.Length + 1) } })
}

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
}

Describe 'Archivos' {
    # Without a BOM, Windows PowerShell 5.1 reads scripts as ANSI: accents turn
    # to garbage and a UTF-8 «—» contains the byte of a closing quote, which
    # breaks parsing outright.
    It '<Name> está en UTF-8 con BOM' -ForEach $Scripts {
        $b = [IO.File]::ReadAllBytes($Path)
        ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF) | Should -BeTrue
    }

    It '<Name> se analiza sin errores' -ForEach $Scripts {
        $tokens = $null
        $errors = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)
        $errors | Should -BeNullOrEmpty
    }

    It 'WinJuicer.cmd es ASCII con finales CRLF' {
        $b = [IO.File]::ReadAllBytes((Join-Path $Root 'WinJuicer.cmd'))
        @($b | Where-Object { $_ -gt 127 }).Count | Should -Be 0
        $text = [Text.Encoding]::ASCII.GetString($b)
        ($text -replace "`r`n", '') | Should -Not -Match "`n"
    }
}
