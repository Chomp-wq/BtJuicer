# What CI runs, in whichever PowerShell it is started from: makes sure Pester 5
# is there and runs every test, failing the job if any test fails.

$PSVersionTable.PSVersion.ToString()
if (-not (Get-Module -ListAvailable Pester | Where-Object { $_.Version -ge [version]'5.5' })) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force -Scope CurrentUser | Out-Null
    Install-Module Pester -MinimumVersion 5.5 -Force -SkipPublisherCheck -Scope CurrentUser
}
Import-Module Pester -MinimumVersion 5.5
$c = New-PesterConfiguration
$c.Run.Path = $PSScriptRoot
$c.Run.Exit = $true
$c.Output.Verbosity = 'Detailed'
Invoke-Pester -Configuration $c
