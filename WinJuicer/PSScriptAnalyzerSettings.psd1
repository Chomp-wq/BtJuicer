@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # A console UI: Write-Host is the point.
        'PSAvoidUsingWriteHost',
        # Confirmation happens in the menu, with what each change costs; -WhatIf
        # is -Simular.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
    Rules        = @{
        # Windows 11 ships Windows PowerShell 5.1; PowerShell 7 must work too.
        PSUseCompatibleSyntax   = @{ Enable = $true; TargetVersions = @('5.1', '7.0') }
        PSUseCompatibleCommands = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
        PSUseCompatibleTypes    = @{
            Enable         = $true
            TargetProfiles = @('win-8_x64_10.0.17763.0_5.1.17763.316_x64_4.0.30319.42000_framework')
        }
    }
}
