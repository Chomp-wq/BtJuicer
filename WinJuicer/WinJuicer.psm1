# Win Juicer: one module, split by concern. The entry point is WinJuicer.ps1.

# The folder Win Juicer runs from; version.txt, in releases only, is here.
$script:ModuleRoot = $PSScriptRoot

foreach ($file in 'Backend', 'Engine', 'Catalog', 'Native', 'Hardware', 'Audit', 'Tuning', 'Advisor', 'Startup', 'Games', 'Frames', 'Monitor', 'Limiter', 'FineTune',
    'Debloat', 'Network', 'Apps', 'Config', 'Measure', 'Version', 'Maintenance', 'Console', 'Gui') {
    $path = Join-Path (Join-Path $PSScriptRoot 'src') "$file.ps1"
    if (Test-Path -LiteralPath $path) { . $path }
}

Export-ModuleMember -Function *-Juicer*
