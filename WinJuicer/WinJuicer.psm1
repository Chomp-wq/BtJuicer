# Win Juicer: one module, split by concern. The entry point is WinJuicer.ps1.

foreach ($file in 'Backend', 'Engine', 'Catalog', 'Native', 'Hardware', 'Audit', 'Tuning', 'Advisor', 'Startup', 'Games',
    'Debloat', 'Network', 'Apps', 'Config', 'Maintenance', 'Console', 'Gui') {
    $path = Join-Path (Join-Path $PSScriptRoot 'src') "$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}

Export-ModuleMember -Function *-Juicer*
